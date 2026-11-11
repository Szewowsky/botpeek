#if canImport(AppKit)
import AppKit
import BotPeekCore

/// The real integration with the Grok Bot desktop app.
///
/// - Bots, avatars and attention state: read-only from Grok Bot's local roster cache.
/// - Questions asked in chat, with answer buttons or in plain text: read-only
///   from Grok Bot's cached conversations.
/// - Optional second attention signal: the sidebar label, via Accessibility.
/// - Question text, choices and replies: Grok Bot's window, via Accessibility.
final class LiveGrokIntegration: GrokIntegration {
    let isDemo = false
    let paths: GrokBotPaths
    let driver: GrokAccessibilityDriver
    private let rosterStore: RosterStore
    private let conversationStore: ConversationStore
    private let statusReader: DesktopStatusReader
    private let log: DiagnosticsLog

    var useSidebarSignal = true
    var showsPlainTextQuestions = true
    var deliveryMethod: DeliveryMethod = .background

    private(set) var lastRoster: RosterSnapshot?
    private(set) var lastRosterError: RosterStoreError?
    private var sidebar: [SidebarEntry]?
    private var sidebarRequestedAt: Date = .distantPast
    private var sidebarTask: Task<Void, Never>?
    static let sidebarInterval: TimeInterval = 6
    /// A plain-text question shows only once the bot has been quiet this long,
    /// so a bot that asks and then keeps going doesn't pop up.
    static let plainQuestionSettleTime: TimeInterval = 8
    /// When the earliest plain-text question still settling may be shown.
    private(set) var nextPlainQuestionAt: Date?

    private lazy var replies = GrokReplyService(integration: self)
    var replyService: ReplyService { replies }

    init(paths: GrokBotPaths = .standard(homeDirectory: FileManager.default.homeDirectoryForCurrentUser), log: DiagnosticsLog) {
        self.paths = paths
        self.log = log
        rosterStore = RosterStore(paths: paths)
        conversationStore = ConversationStore(paths: paths)
        statusReader = DesktopStatusReader(paths: paths)
        driver = GrokAccessibilityDriver(log: log, paths: paths)
    }

    var rosterIdentities: [BotIdentity] {
        (lastRoster?.bots ?? []).filter { !$0.isHiddenFromSidebar }.map(\.identity)
    }

    // MARK: BotStatusMonitor

    func currentSnapshot(now: Date) -> StatusSnapshot {
        let roster: RosterSnapshot
        do {
            roster = try rosterStore.load()
        } catch {
            let storeError = (error as? RosterStoreError) ?? .unreadable
            if storeError != lastRosterError {
                log.record(.warning, "roster", "Roster unavailable: \(storeError)")
            }
            lastRosterError = storeError
            return .incomplete(at: now)
        }
        if lastRosterError != nil || lastRoster?.modifiedAt != roster.modifiedAt {
            log.record(.debug, "roster", "Roster loaded: \(roster.bots.count) bots, schema \(roster.schemaVersion.map(String.init) ?? "?")")
        }
        if lastRoster == nil, !roster.isKnownSchema {
            log.record(.warning, "roster", "Untested roster schema \(roster.schemaVersion.map(String.init) ?? "?")")
        }
        lastRoster = roster
        lastRosterError = nil

        let running = driver.runningApp != nil
        let sidebarAllowed = useSidebarSignal && running && driver.isTrusted
        if sidebarAllowed {
            refreshSidebarIfNeeded(now: now)
        } else {
            sidebar = nil
        }
        let visible = roster.bots.filter { !$0.isHiddenFromSidebar }.map(\.id)
        var settlesAt: Date?
        let conversations = conversationStore.openRequests(for: visible, rosterFile: roster.fileURL).filter { _, request in
            guard request.isPlainText else { return true }
            guard showsPlainTextQuestions else { return false }
            guard let postedAt = request.postedAt else { return true }
            let settled = postedAt.addingTimeInterval(Self.plainQuestionSettleTime)
            if settled <= now { return true }
            settlesAt = min(settlesAt ?? settled, settled)
            return false
        }
        nextPlainQuestionAt = settlesAt
        return AttentionDetector.snapshot(
            roster: roster.bots,
            conversations: conversations,
            sidebar: sidebarAllowed ? sidebar : nil,
            observedAt: now
        )
    }

    private func refreshSidebarIfNeeded(now: Date) {
        guard sidebarTask == nil, now.timeIntervalSince(sidebarRequestedAt) >= Self.sidebarInterval else { return }
        sidebarRequestedAt = now
        let driver = driver
        sidebarTask = Task { [weak self] in
            let entries = await driver.sidebarEntries()
            await self?.applySidebar(entries)
        }
    }

    @MainActor
    private func applySidebar(_ entries: [SidebarEntry]?) {
        sidebar = entries
        sidebarTask = nil
    }

    // MARK: AvatarProvider

    func avatarSource(for bot: BotIdentity) -> AvatarSource {
        AvatarResolver.resolve(bot.avatar, paths: paths)
    }

    // MARK: ConversationProvider

    func loadContent(for request: AttentionRequest, allowNavigation: Bool) async throws -> AttentionContent? {
        guard driver.isTrusted else {
            if allowNavigation { throw ReplyError.accessibilityPermissionMissing }
            return nil
        }
        guard driver.runningApp != nil else {
            if allowNavigation { throw ReplyError.grokBotNotRunning }
            return nil
        }
        let conversation: ConversationSnapshot
        if allowNavigation {
            let roster = await MainActor.run { rosterIdentities }
            conversation = try await driver.openConversation(for: request.bot, roster: roster).0
        } else {
            conversation = try await driver.currentConversation().0
            guard conversation.heading == request.bot.name else { return nil }
        }
        return TranscriptParser.content(from: conversation)
    }

    func openInGrokBot(bot: BotIdentity?) async {
        let roster = await MainActor.run { rosterIdentities }
        await driver.open(bot: bot, roster: roster)
    }

    // MARK: Health

    func health(now: Date) -> IntegrationHealth {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotApp.bundleIdentifier)
        let version = appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let status = statusReader.load()
        let rosterHealth: RosterHealth
        if let lastRosterError {
            rosterHealth = .failed(lastRosterError)
        } else if let lastRoster {
            rosterHealth = .ok(botCount: rosterIdentities.count, knownSchema: lastRoster.isKnownSchema)
        } else {
            rosterHealth = .failed(.rosterNotFound)
        }
        let identities = rosterIdentities
        let unavailablePhotos = identities.filter {
            if case .photoUnavailable = avatarSource(for: $0) { return true }
            return false
        }.count
        let unrecognized = Array(Set(identities.compactMap { $0.avatar.isShapeRecognized ? nil : $0.avatar.rawShape })).sorted()

        return IntegrationHealth(
            isDemo: false,
            grokBotInstalled: appURL != nil || FileManager.default.fileExists(atPath: paths.supportDirectory.path),
            grokBotVersion: version ?? status?.appVersion,
            grokBotRunning: driver.runningApp != nil,
            signedIn: status?.signedIn,
            roster: rosterHealth,
            accessibility: driver.isTrusted ? .granted : .denied,
            photoAvatarsUnavailable: unavailablePhotos,
            unrecognizedAvatarShapes: unrecognized
        )
    }
}

/// Delivers replies through Grok Bot's window.
final class GrokReplyService: ReplyService {
    private unowned let integration: LiveGrokIntegration

    init(integration: LiveGrokIntegration) {
        self.integration = integration
    }

    let capabilities = ReplyCapabilities(text: true, choices: true, approvals: true)

    func deliver(_ reply: Reply, to target: ReplyTarget) async throws -> DeliveryReceipt {
        let (roster, method) = await MainActor.run { (integration.rosterIdentities, integration.deliveryMethod) }
        guard roster.contains(where: { $0.id == target.bot.id }) else { throw ReplyError.botNotFound }
        let driver = integration.driver
        switch reply {
        case .text(let text):
            return try await driver.sendText(text, to: target.bot, roster: roster, method: method)
        case .choice(let choice):
            return try await driver.pressChoice(choice.label, for: target.bot, roster: roster)
        case .approval(_, let option):
            // Presses exactly the button the user reviewed and confirmed.
            return try await driver.pressChoice(option.label, for: target.bot, roster: roster)
        }
    }
}

/// Calls `onChange` when files in a directory are added, removed or replaced.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
#endif
