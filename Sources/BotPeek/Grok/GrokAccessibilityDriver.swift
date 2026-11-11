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
    private var enabledPIDs = Set<pid_t>()
    private let lock = NSLock()

    init(log: DiagnosticsLog) {
        self.log = log
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
    func openConversation(for bot: BotIdentity, roster: [BotIdentity], settle: TimeInterval = 0) async throws -> (ConversationSnapshot, AXSnapshot) {
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
        case .notFound: throw ReplyError.botNotFound
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

    // MARK: Choices

    func pressChoice(_ label: String, for bot: BotIdentity, roster: [BotIdentity]) async throws -> DeliveryReceipt {
        let (before, snapshot) = try await waitForQuestion(in: openConversation(for: bot, roster: roster), bot: bot)
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
        // Give the message box time to show this conversation's draft, so the
        // check below sees it.
        let (before, snapshot) = try await openConversation(for: bot, roster: roster, settle: 0.25)
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
