#if canImport(AppKit)
import AppKit
import Combine
import OSLog
import BotPeekCore

/// The app's state: settings, the active integration, the request queue and
/// delivery progress. Views and windows observe it; it never draws anything.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: BotPeekSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.save(settings)
            applySettings(previous: oldValue)
        }
    }
    @Published private(set) var health: IntegrationHealth
    @Published private(set) var requests: [AttentionRequest] = []
    @Published private(set) var deliveryStates: [RequestID: DeliveryState] = [:]
    @Published private(set) var loadingContent: Set<RequestID> = []
    @Published private(set) var contentErrors: [RequestID: String] = [:]
    /// The request the user chose to look at; otherwise the oldest is shown.
    @Published var focusedRequestID: RequestID?
    /// Bumped when the user explicitly asks to see a request (menu or reopen).
    @Published private(set) var showRequestToken = 0
    /// Whether the global shortcut is active (another app may own it).
    @Published var globalShortcutRegistered = false

    let log = DiagnosticsLog()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BotPeek", category: "app")
    private let settingsStore: SettingsStore
    private let dismissedStore: PersistentDismissedStore
    /// The queue in use: live and demo requests are kept apart, so trying the
    /// demo never touches real snoozes, dismissals or wait times, and demo
    /// dismissals aren't remembered.
    private var manager: AttentionEventManager
    private let liveManager: AttentionEventManager
    private let demoManager = AttentionEventManager()
    private let live: LiveGrokIntegration
    private var demo: DemoIntegration?
    private(set) var integration: GrokIntegration
    private var replies: ReplyCoordinator!
    private var timer: Timer?
    /// A one-off read at the moment a pending question becomes due, so it
    /// shows then rather than at the next poll.
    private var followUpTimer: Timer?
    private var watcher: DirectoryWatcher?
    private var isAsleep = false
    private var lastSnapshotAt = Date.distantPast
    /// True while the user is writing a reply; new arrivals wait in the stack
    /// instead of replacing the request being answered.
    private var isComposing = false
    private var arrivedWhileComposing = false

    /// Called after every change the character window and menu care about.
    var onEvents: (([AttentionEvent]) -> Void)?

    init(defaults: UserDefaults = .standard) {
        settingsStore = SettingsStore(store: defaults)
        dismissedStore = PersistentDismissedStore(store: defaults)
        let settings = settingsStore.load()
        self.settings = settings
        liveManager = AttentionEventManager(dismissedStore: dismissedStore)
        manager = liveManager
        live = LiveGrokIntegration(log: log)
        integration = live
        health = live.health(now: Date())
        log.sink = { [logger] entry in
            switch entry.level {
            case .debug: logger.debug("\(entry.category, privacy: .public): \(entry.message, privacy: .public)")
            case .info: logger.info("\(entry.category, privacy: .public): \(entry.message, privacy: .public)")
            case .warning: logger.warning("\(entry.category, privacy: .public): \(entry.message, privacy: .public)")
            case .error: logger.error("\(entry.category, privacy: .public): \(entry.message, privacy: .public)")
            }
        }
        configureIntegration()
    }

    // MARK: Lifecycle

    func start() {
        log.record(.info, "app", "BotPeek \(AppInfo.version) started on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        refresh()
        scheduleTimer()
    }

    private func configureIntegration() {
        live.useSidebarSignal = settings.useSidebarSignal
        live.showsPlainTextQuestions = settings.showsPlainTextQuestions
        live.deliveryMethod = settings.deliveryMethod
        if settings.demoMode {
            let demo = self.demo ?? DemoIntegration()
            self.demo = demo
            integration = demo
            manager = demoManager
            watcher = nil
        } else {
            integration = live
            manager = liveManager
            watcher = DirectoryWatcher(url: live.paths.persistenceDirectory) { [weak self] in
                self?.fileSystemChanged()
            }
        }
        replies = ReplyCoordinator(
            service: integration.replyService,
            manager: manager,
            allowInlineApprovals: { [weak self] in self?.settings.allowInlineApprovals ?? false },
            log: log
        )
        replies.onStateChange = { [weak self] id, state in
            self?.deliveryStates[id] = state
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval: TimeInterval = settings.demoMode ? 0.5 : (health.grokBotRunning ? 1.5 : 5)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var pendingFileRefresh = false
    private func fileSystemChanged() {
        // Coalesce bursts of writes into one read. Grok Bot replaces files
        // atomically, so a short pause is enough.
        guard !pendingFileRefresh else { return }
        pendingFileRefresh = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.pendingFileRefresh = false
            self?.refresh()
        }
    }

    func refresh() {
        guard !isAsleep else { return }
        let now = Date()
        // Timers fire in a burst after a long pause (e.g. lid closed without a
        // sleep notification). Treat a large gap like a wake.
        if now.timeIntervalSince(lastSnapshotAt) > 30, lastSnapshotAt != .distantPast {
            manager.systemDidWake(at: now)
        }
        lastSnapshotAt = now

        let wasRunning = health.grokBotRunning
        let snapshot = integration.currentSnapshot(now: now)
        var events = manager.ingest(snapshot)
        events += manager.tick(now: now)
        let newHealth = integration.health(now: now)
        if newHealth != health { health = newHealth }
        if wasRunning != health.grokBotRunning, !settings.demoMode { scheduleTimer() }

        apply(events)
        scheduleFollowUp(now: now)
    }

    private func scheduleFollowUp(now: Date) {
        followUpTimer?.invalidate()
        followUpTimer = nil
        let plainQuestion = integration.isDemo ? nil : live.nextPlainQuestionAt
        // A deadline already passed means this read couldn't settle it (an
        // incomplete read, say); the regular poll tries again.
        guard let due = [manager.nextConfirmationAt, plainQuestion].compactMap({ $0 }).filter({ $0 > now }).min() else { return }
        // A little after the deadline, so the read lands on the far side of it.
        let timer = Timer(timeInterval: due.timeIntervalSince(now) + 0.02, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followUpTimer = timer
    }

    private func apply(_ events: [AttentionEvent]) {
        for event in events {
            switch event {
            case .appeared(let request):
                log.record(.info, "attention", "Request \(request.id) appeared (\(request.content.kind.rawValue), source \(request.source.rawValue))")
                autoloadContent(for: request)
            case .replaced(let old, let new):
                log.record(.info, "attention", "Request \(old) replaced by \(new.id)")
                moveState(from: old, to: new.id)
                autoloadContent(for: new)
            case .resolved(let id, let reason):
                log.record(.info, "attention", "Request \(id) resolved: \(reason.rawValue)")
                if focusedRequestID == id { focusedRequestID = nil }
                loadingContent.remove(id)
                contentErrors[id] = nil
                // Keep a delivered state briefly for the celebration; drop the rest.
                if case .some(.delivered) = deliveryStates[id] {} else { deliveryStates[id] = nil; replies.clearState(for: id) }
            case .updated:
                break
            }
        }
        let before = Set(presentable.map(\.id))
        if requests != manager.requests { requests = manager.requests }
        bringArrivalsToFront(since: before)
        onEvents?(events)
    }

    /// New notifications always come first: a request that wasn't on screen
    /// before (new, a new question, back from snooze) becomes the current one,
    /// unless the user is in the middle of a reply.
    private func bringArrivalsToFront(since before: Set<RequestID>) {
        guard presentable.contains(where: { !before.contains($0.id) }) else { return }
        if isComposing {
            arrivedWhileComposing = true
        } else {
            focusedRequestID = nil
        }
    }

    /// The character window reports when a reply is being written, so the
    /// request stays put until the user is done.
    func setComposing(_ composing: Bool, request id: RequestID?) {
        guard composing != isComposing else { return }
        isComposing = composing
        if composing {
            if let id { focusedRequestID = id }
        } else if arrivedWhileComposing {
            arrivedWhileComposing = false
            focusedRequestID = nil
            Task { @MainActor [weak self] in self?.onEvents?([]) }
        }
    }

    private func moveState(from old: RequestID, to new: RequestID) {
        if focusedRequestID == old { focusedRequestID = new }
        deliveryStates[old] = nil
        replies.clearState(for: old)
    }

    // MARK: Queue

    /// What the characters show, newest arrival first.
    var presentable: [AttentionRequest] {
        charactersActive ? waiting : []
    }

    /// Requests still waiting on screen-worthy attention, whether or not
    /// characters are currently shown. The menu bar counts these.
    var waiting: [AttentionRequest] {
        RequestQueue.ordered(requests.filter(\.isPresentable))
    }

    var charactersActive: Bool {
        settings.isEnabled && !settings.isPaused(at: Date())
    }

    func pause(until date: Date?) {
        settings.pausedUntil = date
        log.record(.info, "app", date == nil ? "Characters resumed" : "Characters paused")
        onEvents?([])
    }

    var currentRequest: AttentionRequest? {
        RequestQueue.current(in: presentable, preferred: focusedRequestID)
    }

    func request(_ id: RequestID) -> AttentionRequest? {
        requests.first { $0.id == id }
    }

    func avatarSource(for bot: BotIdentity) -> AvatarSource {
        integration.avatarSource(for: bot)
    }

    func deliveryState(for id: RequestID) -> DeliveryState {
        deliveryStates[id] ?? .idle
    }

    func showNext() {
        guard let current = currentRequest else { return }
        focus(RequestQueue.next(after: current.id, in: presentable))
    }

    func showPrevious() {
        guard let current = currentRequest else { return }
        focus(RequestQueue.previous(before: current.id, in: presentable))
    }

    /// The user picked a request (switcher or stack); that choice wins over
    /// anything that arrived meanwhile.
    func focus(_ id: RequestID?) {
        arrivedWhileComposing = false
        focusedRequestID = id
        onEvents?([])
    }

    /// From the menu bar: show this request now, even if snoozed or dismissed.
    func show(_ id: RequestID) {
        if !settings.isEnabled { settings.isEnabled = true }
        if settings.isPaused(at: Date()) { settings.pausedUntil = nil }
        arrivedWhileComposing = false
        manager.restore(id)
        requests = manager.requests
        focusedRequestID = id
        showRequestToken += 1
        onEvents?([])
    }

    func snooze(_ id: RequestID) {
        manager.snooze(id, until: Date().addingTimeInterval(TimeInterval(settings.snoozeMinutes * 60)))
        log.record(.info, "attention", "Snoozed \(id) for \(settings.snoozeMinutes) min")
        if focusedRequestID == id { focusedRequestID = nil }
        requests = manager.requests
        onEvents?([])
    }

    func snoozeAll() {
        manager.snoozeAll(until: Date().addingTimeInterval(TimeInterval(settings.snoozeMinutes * 60)))
        focusedRequestID = nil
        requests = manager.requests
        onEvents?([])
    }

    func dismiss(_ id: RequestID) {
        manager.dismiss(id, at: Date())
        log.record(.info, "attention", "Dismissed \(id)")
        if focusedRequestID == id { focusedRequestID = nil }
        requests = manager.requests
        onEvents?([])
    }

    // MARK: Replies

    func canApproveInline(_ request: AttentionRequest) -> Bool {
        replies.canApproveInline(request)
    }

    func validate(_ reply: Reply, for id: RequestID) -> ReplyError? {
        replies.validate(reply, for: manager.request(id))
    }

    @discardableResult
    func send(_ reply: Reply, for id: RequestID) async -> DeliveryState {
        let state = await replies.send(reply, for: id)
        requests = manager.requests
        if case .delivered = state {
            // Grok Bot usually clears the request right away; check soon.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.refresh()
            }
        }
        return state
    }

    func clearDeliveryState(_ id: RequestID) {
        deliveryStates[id] = nil
        replies.clearState(for: id)
    }

    // MARK: Conversation

    private func autoloadContent(for request: AttentionRequest) {
        guard !request.content.hasReadableContent, request.content.grokBotOnlyReason == nil, !integration.isDemo else { return }
        Task { await loadContent(for: request.id, allowNavigation: false) }
    }

    /// Reads the question from Grok Bot's conversation. With navigation, this
    /// switches Grok Bot to the bot's chat (in the background). Requests that
    /// must be answered in Grok Bot (cached approvals, forms) are never read
    /// from the window: they are only ever opened there.
    func loadContent(for id: RequestID, allowNavigation: Bool) async {
        guard let request = manager.request(id), request.content.grokBotOnlyReason == nil,
              !loadingContent.contains(id) else { return }
        loadingContent.insert(id)
        contentErrors[id] = nil
        defer { loadingContent.remove(id) }
        do {
            if let content = try await integration.loadContent(for: request, allowNavigation: allowNavigation) {
                manager.updateContent(id, content)
                requests = manager.requests
                log.record(.info, "conversation", "Loaded \(content.kind.rawValue) for \(id) from \(content.source.rawValue)")
            } else if allowNavigation {
                contentErrors[id] = "Couldn't find the question in the conversation."
            }
        } catch {
            let message = (error as? ReplyError)?.userMessage ?? "Couldn't read the conversation."
            if allowNavigation { contentErrors[id] = message }
            log.record(.warning, "conversation", "Loading content for \(id) failed: \(error)")
        }
        onEvents?([])
    }

    func openInGrokBot(_ request: AttentionRequest?) {
        log.record(.info, "app", "Opening Grok Bot\(request.map { " for \($0.id)" } ?? "")")
        let integration = integration
        Task { await integration.openInGrokBot(bot: request?.bot) }
        // The user is handling it in Grok Bot now (a sign-in form, say), so step
        // aside: it resolves once Grok Bot records it as done, or the character
        // comes back after the snooze time if it is still waiting.
        if let request { snooze(request.id) }
    }

    // MARK: Permissions

    var accessibilityTrusted: Bool { live.driver.isTrusted }

    func requestAccessibility() {
        live.driver.requestTrust()
        SystemLinks.openAccessibilitySettings()
        // Permission changes don't notify; re-check for a while.
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if live.driver.isTrusted {
                    log.record(.info, "permissions", "Accessibility permission granted")
                    refresh()
                    return
                }
            }
        }
    }

    // MARK: Settings

    private func applySettings(previous: BotPeekSettings) {
        if previous.demoMode != settings.demoMode {
            log.record(.info, "app", settings.demoMode ? "Demo mode on" : "Demo mode off")
            if settings.demoMode {
                demoManager.reset()
                demo?.restart(at: Date())
            }
            deliveryStates = [:]
            focusedRequestID = nil
            configureIntegration()
            requests = manager.requests
            scheduleTimer()
            refresh()
        } else {
            live.useSidebarSignal = settings.useSidebarSignal
            live.showsPlainTextQuestions = settings.showsPlainTextQuestions
            live.deliveryMethod = settings.deliveryMethod
            if previous.showsPlainTextQuestions != settings.showsPlainTextQuestions { refresh() }
        }
        onEvents?([])
    }

    func replayDemo() {
        guard settings.demoMode else { return }
        manager.reset()
        requests = []
        deliveryStates = [:]
        demo?.restart(at: Date())
        refresh()
    }

    // MARK: System

    func systemWillSleep() {
        isAsleep = true
        log.record(.info, "system", "Sleeping")
    }

    func systemDidWake() {
        isAsleep = false
        manager.systemDidWake(at: Date())
        log.record(.info, "system", "Woke; grace period started")
        refresh()
    }

    // MARK: Diagnostics

    func diagnosticsReport() -> String {
        var header = [
            "BotPeek version": AppInfo.version,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Architecture": AppInfo.architecture,
            "Mode": settings.demoMode ? "demo" : "live",
            "Status": health.summary,
            "Grok Bot installed": String(health.grokBotInstalled),
            "Grok Bot running": String(health.grokBotRunning),
            "Grok Bot version": health.grokBotVersion ?? "unknown",
            "Signed in": health.signedIn.map(String.init) ?? "unknown",
            "Accessibility": health.accessibility.rawValue,
            "Pending requests": String(requests.count),
            "Uploaded avatars unavailable": String(health.photoAvatarsUnavailable),
            "Unrecognized avatar shapes": String(health.unrecognizedAvatarShapes.count),
            "Delivery method": settings.deliveryMethod.rawValue,
            "Sidebar signal": String(settings.useSidebarSignal),
        ]
        if case .ok(let count, let known) = health.roster {
            header["Roster"] = "\(count) bots, schema \(known ? "tested" : "untested") (v\(live.lastRoster?.schemaVersion.map(String.init) ?? "?"))"
        } else if case .failed(let error) = health.roster {
            header["Roster"] = "error: \(error)"
        }
        return log.export(header: header)
    }
}

enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static let repositoryURL = URL(string: "https://github.com/Szewowsky/botpeek")!
}

enum SystemLinks {
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
