#if canImport(AppKit)
import AppKit
import ApplicationServices
import BotPeekCore

/// Reads and drives Grok Bot's window through the macOS Accessibility API,
/// the same interface VoiceOver uses.
///
/// Approach adapted from grok-bot-mcp (Copyright (c) 2026 Ryan Thomas, MIT):
/// open a bot by pressing its sidebar button, confirm the conversation heading,
/// press choice buttons directly, and type replies by pasting into the
/// "Prompt" box while preserving the clipboard. BotPeek adds strict identity
/// matching, draft protection, focus restoration and delivery verification.
///
/// Methods are `nonisolated async`, so the Accessibility IPC runs off the main
/// thread; anything touching AppKit state hops to the main actor.
final class GrokAccessibilityDriver: @unchecked Sendable {
    private let log: DiagnosticsLog
    private let sectionStore: SidebarSectionStore
    private var enabledPIDs = Set<pid_t>()
    /// Sidebar folders BotPeek opened to reach a bot, to close again afterwards.
    private var openedFolders: [String] = []
    /// Whether BotPeek switched a compact sidebar to full, to switch back afterwards.
    private var expandedSidebar = false
    private let lock = NSLock()

    init(log: DiagnosticsLog, paths: GrokBotPaths) {
        self.log = log
        sectionStore = SidebarSectionStore(paths: paths)
    }

    // MARK: Permission and process

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: GrokBotApp.bundleIdentifier).first
    }

    private func prepare() throws -> pid_t {
        guard isTrusted else { throw ReplyError.accessibilityPermissionMissing }
        guard let app = runningApp else { throw ReplyError.grokBotNotRunning }
        let pid = app.processIdentifier
        lock.lock()
        let isNew = enabledPIDs.insert(pid).inserted
        lock.unlock()
        if isNew { AXTree.enableManualAccessibility(pid: pid) }
        return pid
    }

    // MARK: Reading

    /// Snapshots Grok Bot's main window, retrying while Chromium builds its tree.
    func windowSnapshot() async throws -> AXSnapshot {
        let pid = try prepare()
        for attempt in 0..<4 {
            if let window = AXTree.windows(of: pid).first {
                let snapshot = AXTree.snapshot(window)
                if SidebarParser.findSidebar(in: snapshot.root) != nil { return snapshot }
            }
            if attempt == 0 { AXTree.enableManualAccessibility(pid: pid) }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw ReplyError.grokBotWindowUnavailable
    }

    /// Sidebar buttons, or `nil` when they can't be read right now.
    func sidebarEntries() async -> [SidebarEntry]? {
        guard let snapshot = try? await windowSnapshot() else { return nil }
        return SidebarParser.entries(in: snapshot.root)
    }

    /// The conversation currently open, without navigating anywhere.
    func currentConversation() async throws -> (ConversationSnapshot, AXSnapshot) {
        let snapshot = try await windowSnapshot()
        return (TranscriptParser.parse(window: snapshot.root), snapshot)
    }

    /// Opens `bot`'s existing conversation by pressing its sidebar button and
    /// confirms the heading matches. Never creates bots or conversations.
    ///
    /// `settle` is the least time to let the conversation render after the
    /// heading changes, for callers that read more than the transcript (the
    /// message box's draft). It returns sooner otherwise, once the rendered
    /// messages are the bot's own, and waits at most 400 ms either way.
    ///
    /// A sidebar folder opened to reach the bot is closed again before returning.
    func openConversation(for bot: BotIdentity, roster: [BotIdentity], settle: TimeInterval = 0) async throws -> (ConversationSnapshot, AXSnapshot) {
        try await restoringSidebar(roster: roster) {
            try await openConversationKeepingFolders(for: bot, roster: roster, settle: settle)
        }
    }

    /// Like `openConversation`, but leaves a folder it opened open; callers wrap
    /// their whole operation in `restoringSidebar`.
    private func openConversationKeepingFolders(for bot: BotIdentity, roster: [BotIdentity], settle: TimeInterval = 0) async throws -> (ConversationSnapshot, AXSnapshot) {
        var snapshot = try await windowSnapshot()
        var conversation = TranscriptParser.parse(window: snapshot.root)
        log.record(.debug, "ax", "Heading before opening \(bot.id.logTag): \(Self.describe(conversation.heading, bot: bot, roster: roster))")
        if BotIdentityMatcher.isOpen(bot: bot, heading: conversation.heading, roster: roster) {
            // In the background Grok Bot redraws only while Accessibility
            // actions arrive, so an already-open conversation can still show
            // what it looked like minutes ago. Nudge it and read it again.
            if let composer = snapshot.element(conversation.composerNodeID) { AXTree.nudge(composer) }
            try await Task.sleep(nanoseconds: 150_000_000)
            snapshot = try await windowSnapshot()
            conversation = TranscriptParser.parse(window: snapshot.root)
            guard conversation.heading == bot.name else { throw ReplyError.conversationMismatch }
            return (conversation, snapshot)
        }

        guard let entries = SidebarParser.entries(in: snapshot.root) else { throw ReplyError.grokBotWindowUnavailable }
        let entry: SidebarEntry
        switch BotIdentityMatcher.match(bot: bot, roster: roster, sidebar: entries) {
        case .unique(let match): entry = match
        case .ambiguous: throw ReplyError.ambiguousBot
        case .notFound: (snapshot, entry) = try await revealInFolder(bot, roster: roster, snapshot: snapshot)
        }
        guard let button = snapshot.element(entry.nodeID), AXTree.press(button) else {
            throw ReplyError.botNotFound
        }
        log.record(.info, "ax", "Opened conversation for \(bot.id.logTag)")

        let pressedAt = Date()
        var lastHeading: String?? = .none
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 100_000_000)
            snapshot = try await windowSnapshot()
            conversation = TranscriptParser.parse(window: snapshot.root)
            if lastHeading != .some(conversation.heading) {
                lastHeading = .some(conversation.heading)
                log.record(.debug, "ax", "Heading after \(Self.milliseconds(since: pressedAt)) ms: \(Self.describe(conversation.heading, bot: bot, roster: roster))")
            }
            if conversation.heading == bot.name {
                return try await settleConversation(for: bot, roster: roster, minimum: settle, from: (conversation, snapshot))
            }
        }
        throw ReplyError.conversationMismatch
    }

    /// The heading can change before the transcript below it does, so the
    /// previous bot's messages (and answer buttons) may still be drawn. Waits
    /// until the messages shown are this bot's, or for 400 ms when that can't
    /// be told (a new conversation, or a group).
    private func settleConversation(
        for bot: BotIdentity,
        roster: [BotIdentity],
        minimum: TimeInterval,
        from opened: (ConversationSnapshot, AXSnapshot)
    ) async throws -> (ConversationSnapshot, AXSnapshot) {
        let start = Date()
        var (conversation, snapshot) = opened
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if elapsed >= 0.4 || (elapsed >= minimum && Self.showsOwnMessages(conversation, of: bot)) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            snapshot = try await windowSnapshot()
            conversation = TranscriptParser.parse(window: snapshot.root)
            guard conversation.heading == bot.name else {
                log.record(.warning, "ax", "Heading changed while settling: \(Self.describe(conversation.heading, bot: bot, roster: roster))")
                throw ReplyError.conversationMismatch
            }
        }
        log.record(.debug, "ax", "Conversation settled after \(Self.milliseconds(since: start)) ms")
        return (conversation, snapshot)
    }

    /// Whether every rendered message is from `bot` or the user, and at least
    /// one is from `bot`.
    static func showsOwnMessages(_ conversation: ConversationSnapshot, of bot: BotIdentity) -> Bool {
        let senders = Set(conversation.messages.map(\.sender))
        return senders.contains(bot.name) && senders.isSubset(of: TranscriptParser.defaultUserSenders.union([bot.name]))
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }

    /// Describes a heading for the log without writing bot names.
    private static func describe(_ heading: String?, bot: BotIdentity, roster: [BotIdentity]) -> String {
        guard let heading else { return "none" }
        if heading == bot.name { return "target" }
        if let other = roster.first(where: { $0.name == heading }) { return "other bot \(other.id.logTag)" }
        return "unrecognized (\(heading.count) characters)"
    }

    // MARK: Sidebar folders

    /// A bot filed in a collapsed sidebar folder has no button until the folder
    /// opens. Opens exactly that folder (see `SidebarFolderMatcher`) and waits
    /// for the bot's button. Never presses anything when the folder is unclear.
    private func revealInFolder(_ bot: BotIdentity, roster: [BotIdentity], snapshot: AXSnapshot) async throws -> (AXSnapshot, SidebarEntry) {
        var snapshot = snapshot
        let sections = sectionStore.load()
        var match = sections.map { SidebarFolderMatcher.match(bot: bot, sections: $0, roster: roster, in: snapshot.root) }
        // In the background Grok Bot may expose a sidebar it hasn't finished
        // redrawing, without the folder buttons. Nudge it and read it again.
        for _ in 0..<5 where match == .notShown {
            if let sidebar = SidebarParser.findSidebar(in: snapshot.root), let element = snapshot.element(sidebar.id) {
                AXTree.nudge(element)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            snapshot = try await windowSnapshot()
            if let entries = SidebarParser.entries(in: snapshot.root),
               case .unique(let entry) = BotIdentityMatcher.match(bot: bot, roster: roster, sidebar: entries) {
                return (snapshot, entry)
            }
            match = sections.map { SidebarFolderMatcher.match(bot: bot, sections: $0, roster: roster, in: snapshot.root) }
        }
        // A compact sidebar has no folder buttons: switch it to full first.
        if match == .notShown, let full = try await expandCompactSidebar(snapshot) {
            snapshot = full
            if let entries = SidebarParser.entries(in: snapshot.root),
               case .unique(let entry) = BotIdentityMatcher.match(bot: bot, roster: roster, sidebar: entries) {
                return (snapshot, entry)
            }
            match = sections.map { SidebarFolderMatcher.match(bot: bot, sections: $0, roster: roster, in: snapshot.root) }
        }
        guard case .collapsed(let nodeID, let folder) = match else {
            log.record(.debug, "ax", "No folder to open for \(bot.id.logTag): \(match.map { "\($0)" } ?? "folders unavailable")")
            throw ReplyError.botNotFound
        }
        guard let button = snapshot.element(nodeID), AXTree.press(button) else { throw ReplyError.botNotFound }
        rememberOpenedFolder(folder)
        log.record(.info, "ax", "Opened a sidebar folder to reach \(bot.id.logTag)")

        let pressedAt = Date()
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = try await windowSnapshot()
            if let entries = SidebarParser.entries(in: current.root) {
                switch BotIdentityMatcher.match(bot: bot, roster: roster, sidebar: entries) {
                case .unique(let entry):
                    log.record(.debug, "ax", "Bot shown \(Self.milliseconds(since: pressedAt)) ms after opening its folder")
                    return (current, entry)
                case .ambiguous:
                    throw ReplyError.ambiguousBot
                case .notFound:
                    break
                }
            }
            AXTree.nudge(button)
        }
        log.record(.warning, "ax", "\(bot.id.logTag) not shown after opening its folder")
        throw ReplyError.botNotFound
    }

    /// The sidebar's mode, from the snapshot and the toggle's live `AXExpanded`.
    private func sidebarMode(_ snapshot: AXSnapshot) -> (mode: SidebarMode, toggle: AXUIElement?) {
        guard let node = SidebarMode.toggle(in: snapshot.root), let toggle = snapshot.element(node.id) else { return (.unknown, nil) }
        let expanded = AXTree.copy(toggle, "AXExpanded") as? Bool
        return (SidebarMode.detect(in: snapshot.root, toggleExpanded: expanded), toggle)
    }

    /// Switches a compact sidebar to full and returns the new snapshot, or `nil`
    /// when the sidebar isn't (recognizably) compact. Remembers to switch back.
    private func expandCompactSidebar(_ snapshot: AXSnapshot) async throws -> AXSnapshot? {
        let (mode, toggle) = sidebarMode(snapshot)
        guard mode == .compact, let toggle, AXTree.press(toggle) else {
            log.record(.debug, "ax", "Sidebar not expanded: mode \(mode)")
            return nil
        }
        setExpandedSidebar(true)
        let pressedAt = Date()
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = try await windowSnapshot()
            if sidebarMode(current).mode == .full {
                log.record(.info, "ax", "Switched the compact sidebar to full (\(Self.milliseconds(since: pressedAt)) ms)")
                return current
            }
            AXTree.nudge(toggle)
        }
        log.record(.warning, "ax", "Sidebar didn't switch to full")
        return nil
    }

    /// Runs `body`, then undoes what BotPeek changed in the sidebar during it, in
    /// reverse order: closes the folders it opened, then makes the sidebar compact
    /// again if BotPeek expanded it. Whatever the user had open stays open.
    private func restoringSidebar<T>(roster: [BotIdentity], _ body: () async throws -> T) async throws -> T {
        let result: T
        do {
            result = try await body()
        } catch {
            await restoreSidebar(roster: roster)
            throw error
        }
        await restoreSidebar(roster: roster)
        return result
    }

    private func restoreSidebar(roster: [BotIdentity]) async {
        await closeOpenedFolders(roster: roster)
        guard takeExpandedSidebar() else { return }
        guard let snapshot = try? await windowSnapshot() else { return }
        let (mode, toggle) = sidebarMode(snapshot)
        if mode == .compact { return }
        guard mode == .full, let toggle, AXTree.press(toggle) else {
            log.record(.warning, "ax", "Couldn't make the sidebar compact again (mode \(mode))")
            return
        }
        var compact = false
        for _ in 0..<20 where !compact {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let current = try? await windowSnapshot() { compact = sidebarMode(current).mode == .compact }
            if !compact { AXTree.nudge(toggle) }
        }
        log.record(compact ? .info : .warning, "ax", compact ? "Made the sidebar compact again" : "Sidebar not compact yet; in a narrow background window Grok Bot has applied this up to ~30 s later")
    }

    private func setExpandedSidebar(_ value: Bool) {
        lock.lock()
        expandedSidebar = value
        lock.unlock()
    }

    private func takeExpandedSidebar() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = expandedSidebar
        expandedSidebar = false
        return value
    }

    private func rememberOpenedFolder(_ folder: String) {
        lock.lock()
        if !openedFolders.contains(folder) { openedFolders.append(folder) }
        lock.unlock()
    }

    private func takeOpenedFolders() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let folders = openedFolders
        openedFolders = []
        return folders
    }

    private func closeOpenedFolders(roster: [BotIdentity]) async {
        for folder in takeOpenedFolders() {
            guard let snapshot = try? await windowSnapshot(),
                  let id = SidebarFolderMatcher.expandedButton(folder: folder, roster: roster, in: snapshot.root),
                  let button = snapshot.element(id), AXTree.press(button)
            else {
                log.record(.warning, "ax", "Couldn't close a sidebar folder BotPeek opened")
                continue
            }
            // Like other presses in the background, give Grok Bot a few nudges
            // until the folder shows as closed.
            var closed = false
            for _ in 0..<10 where !closed {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let current = try? await windowSnapshot() {
                    closed = SidebarFolderMatcher.expandedButton(folder: folder, roster: roster, in: current.root) == nil
                }
                if !closed { AXTree.nudge(button) }
            }
            log.record(closed ? .info : .warning, "ax", closed ? "Closed the sidebar folder BotPeek opened" : "Sidebar folder BotPeek opened may still be open")
        }
    }

    // MARK: Choices

    func pressChoice(_ label: String, for bot: BotIdentity, roster: [BotIdentity]) async throws -> DeliveryReceipt {
        try await restoringSidebar(roster: roster) {
            try await pressChoiceKeepingFolders(label, for: bot, roster: roster)
        }
    }

    private func pressChoiceKeepingFolders(_ label: String, for bot: BotIdentity, roster: [BotIdentity]) async throws -> DeliveryReceipt {
        let (before, snapshot) = try await waitForQuestion(in: openConversationKeepingFolders(for: bot, roster: roster), bot: bot)
        guard let question = before.openQuestion else { throw ReplyError.questionNotFound }
        guard let option = question.options.first(where: { $0.label == label }),
              let element = snapshot.element(option.nodeID)
        else { throw ReplyError.choiceNotOffered }

        guard AXTree.press(element) else { throw ReplyError.choiceNotOffered }
        log.record(.info, "ax", "Pressed a choice for \(bot.id.logTag)")
        // From here on, never retry: the press reached Grok Bot.
        return await verify(method: "accessibility-press", keepAwake: snapshot.element(before.composerNodeID)) { after in
            after.heading == bot.name && DeliveryVerifier.choiceDelivered(label, before: before, after: after)
        }
    }

    /// A question can reach Grok Bot's cache before its window draws it,
    /// especially in the background. Keep nudging for up to three seconds.
    private func waitForQuestion(
        in opened: (ConversationSnapshot, AXSnapshot),
        bot: BotIdentity
    ) async throws -> (ConversationSnapshot, AXSnapshot) {
        var (conversation, snapshot) = opened
        for _ in 0..<24 where conversation.openQuestion == nil {
            if let composer = snapshot.element(conversation.composerNodeID) { AXTree.nudge(composer) }
            try await Task.sleep(nanoseconds: 125_000_000)
            snapshot = try await windowSnapshot()
            conversation = TranscriptParser.parse(window: snapshot.root)
            guard conversation.heading == bot.name else { throw ReplyError.conversationMismatch }
        }
        if conversation.openQuestion == nil { log.record(.warning, "ax", "Question for \(bot.id.logTag) not drawn after waiting") }
        return (conversation, snapshot)
    }

    // MARK: Text

    /// Grok Bot's editor may add a trailing newline to the value it reports.
    static func normalizedText(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sendText(_ text: String, to bot: BotIdentity, roster: [BotIdentity], method: DeliveryMethod) async throws -> DeliveryReceipt {
        try await restoringSidebar(roster: roster) {
            try await sendTextKeepingFolders(text, to: bot, roster: roster, method: method)
        }
    }

    private func sendTextKeepingFolders(_ text: String, to bot: BotIdentity, roster: [BotIdentity], method: DeliveryMethod) async throws -> DeliveryReceipt {
        // Give the message box time to show this conversation's draft, so the
        // check below sees it.
        let (before, snapshot) = try await openConversationKeepingFolders(for: bot, roster: roster, settle: 0.25)
        guard let composer = snapshot.element(before.composerNodeID) else { throw ReplyError.composerNotFound }

        // Never overwrite something the user was typing in Grok Bot.
        if let draft = AXTree.string(composer, kAXValueAttribute),
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ReplyError.other("Grok Bot has an unsent draft in this conversation. BotPeek won't overwrite it.")
        }

        switch method {
        case .background:
            return try await sendInBackground(text, composer: composer, snapshot: snapshot, before: before, bot: bot)
        case .paste:
            return try await sendByPasting(text, composer: composer, before: before, bot: bot)
        }
    }

    private func sendInBackground(_ text: String, composer: AXUIElement, snapshot: AXSnapshot, before: ConversationSnapshot, bot: BotIdentity) async throws -> DeliveryReceipt {
        let unsupported = ReplyError.other("Background sending isn't supported by this Grok Bot version. Switch Reply delivery to “Paste into Grok Bot” in Settings.")
        guard AXTree.setValue(composer, text) else { throw unsupported }
        // Grok Bot shows its Send button only once the message box has text, so
        // look for it again after the text has landed.
        var send: AXUIElement?
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            guard Self.normalizedText(AXTree.string(composer, kAXValueAttribute)) == Self.normalizedText(text) else { continue }
            let current = try await windowSnapshot()
            let conversation = TranscriptParser.parse(window: current.root)
            guard conversation.heading == bot.name else {
                _ = AXTree.setValue(composer, "")
                throw ReplyError.conversationMismatch
            }
            send = current.element(conversation.sendButtonNodeID)
            if send != nil { break }
        }
        guard let send else {
            _ = AXTree.setValue(composer, "")
            throw unsupported
        }
        guard AXTree.press(send) else {
            _ = AXTree.setValue(composer, "")
            throw ReplyError.composerNotFound
        }
        log.record(.info, "ax", "Sent text in background to \(bot.id.logTag)")
        return await verify(method: "accessibility-value", keepAwake: composer) { after in
            after.heading == bot.name && DeliveryVerifier.textDelivered(text, before: before, after: after)
        }
    }

    private func sendByPasting(_ text: String, composer: AXUIElement, before: ConversationSnapshot, bot: BotIdentity) async throws -> DeliveryReceipt {
        guard let grok = runningApp else { throw ReplyError.grokBotNotRunning }
        let previous = await MainActor.run { FocusKeeper.capture(excluding: grok) }

        await MainActor.run { _ = grok.activate(options: []) }
        try await Task.sleep(nanoseconds: 350_000_000)
        AXTree.focus(composer)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Only type if Grok Bot really is in front: keystrokes go to the
        // frontmost app, and they must never land anywhere else.
        let isFront = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == grok.processIdentifier
        }
        guard isFront else {
            await MainActor.run { previous?.restore() }
            throw ReplyError.grokBotWindowUnavailable
        }

        let clipboard = await MainActor.run { ClipboardGuard.save() }
        await MainActor.run { ClipboardGuard.put(text) }
        KeyboardEvents.paste()
        try? await Task.sleep(nanoseconds: 400_000_000)
        KeyboardEvents.pressReturn()
        log.record(.info, "ax", "Pasted text and pressed Return for \(bot.id.logTag)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await MainActor.run {
            ClipboardGuard.restore(clipboard)
            previous?.restore()
        }

        return await verify(method: "paste-and-return", keepAwake: composer) { after in
            after.heading == bot.name && DeliveryVerifier.textDelivered(text, before: before, after: after)
        }
    }

    // MARK: Verification

    /// Polls the conversation until `check` sees the reply in it, for up to
    /// ~7 seconds.
    ///
    /// In the background, Grok Bot 0.78 shows an answer at once but only sends
    /// it while Accessibility actions keep arriving, so `keepAwake` (the message
    /// box) is nudged throughout, and for two more seconds after the reply shows
    /// up. That tail runs on its own, so "Delivered" isn't held back by it.
    private func verify(method: String, keepAwake: AXUIElement?, _ check: (ConversationSnapshot) -> Bool) async -> DeliveryReceipt {
        let start = Date()
        for _ in 0..<56 {
            try? await Task.sleep(nanoseconds: 125_000_000)
            if let keepAwake { AXTree.nudge(keepAwake) }
            if let current = try? await currentConversation(), check(current.0) {
                log.record(.debug, "ax", "Reply showed up after \(Self.milliseconds(since: start)) ms")
                if let keepAwake { Self.keepAwake(keepAwake, for: 2) }
                return DeliveryReceipt(verified: true, completedAt: Date(), method: method)
            }
        }
        log.record(.warning, "ax", "Could not verify delivery (\(method))")
        return DeliveryReceipt(verified: false, completedAt: Date(), method: method)
    }

    private static func keepAwake(_ element: AXUIElement, for seconds: Double) {
        Task.detached(priority: .utility) {
            for _ in 0..<Int(seconds * 4) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                AXTree.nudge(element)
            }
        }
    }

    // MARK: Fallback

    /// Brings Grok Bot forward, opening the bot's conversation when possible.
    func open(bot: BotIdentity?, roster: [BotIdentity]) async {
        if let app = runningApp {
            await MainActor.run { _ = app.activate(options: [.activateAllWindows]) }
            if let bot, isTrusted {
                _ = try? await openConversation(for: bot, roster: roster)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: GrokBotApp.bundleIdentifier) {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            await MainActor.run { _ = NSWorkspace.shared.open(GrokBotApp.downloadURL) }
        }
    }
}

// MARK: - Focus, clipboard and keyboard helpers

/// Remembers the app the user was in, to return to it afterwards.
@MainActor
struct FocusKeeper {
    let app: NSRunningApplication

    static func capture(excluding other: NSRunningApplication) -> FocusKeeper? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != other.processIdentifier,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return FocusKeeper(app: front)
    }

    func restore() {
        guard !app.isTerminated else { return }
        _ = app.activate(options: [])
    }
}

/// Saves and restores every item and type on the general pasteboard.
@MainActor
enum ClipboardGuard {
    typealias Saved = [[(NSPasteboard.PasteboardType, Data)]]

    static func save() -> Saved {
        let pasteboard = NSPasteboard.general
        return (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    static func put(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Ask clipboard managers not to record the reply.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    static func restore(_ saved: Saved) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.compactMap { entries in
            guard !entries.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

enum KeyboardEvents {
    private static let vKey: CGKeyCode = 9
    private static let returnKey: CGKeyCode = 36

    static func paste() {
        post(vKey, flags: .maskCommand)
    }

    static func pressReturn() {
        post(returnKey, flags: [])
    }

    private static func post(_ key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
#endif
