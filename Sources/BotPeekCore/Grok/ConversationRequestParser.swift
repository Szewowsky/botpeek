import Foundation

/// Finds a request still waiting for the user in a bot's cached conversation
/// (`<account>.transcript.replicas.<bot id>`).
///
/// Grok Bot 0.78 does not set the roster's `awaitingUserResponse` for questions
/// asked in chat. They are stored as conversation entries instead:
/// ```json
/// { "kind": "send-message", "id": "t3s0", "timestampMs": 1730000000000,
///   "message": { "type": "widget",
///     "widget": { "prompt": "…", "options": [ { "label": "…", "value": "…" } ],
///                 "allowCustom": true, "multiSelect": false } } }
/// ```
/// Grok Bot marks what happened to a question on the entry itself:
/// `respondedValue` (answered), `widgetSkipped` (the user wrote something else)
/// or `widgetDismissed`. Approvals (`auto-review-approval`) carry a `status`,
/// forms (`user-form`) a `formResolution`.
///
/// Bots also ask in plain text (`"message": { "type": "text", "content": "…?" }`),
/// which Grok Bot doesn't mark as waiting at all. Those count when the message
/// ends with a real question (see `PlainQuestion`); they are flagged so the app
/// can wait a moment, in case the bot keeps talking, and let users turn them off.
///
/// A request counts as open only when it is the latest turn in the
/// conversation, so an old question the user moved past never pops up.
public enum ConversationRequestParser {
    public struct OpenRequest: Equatable, Sendable {
        public var fingerprint: String
        public var content: AttentionContent
        /// Asked in an ordinary message rather than with answer buttons.
        public var isPlainText = false
        /// When the bot posted it, if Grok Bot recorded that.
        public var postedAt: Date?
    }

    static let widgetResolutionKeys = ["respondedValue", "widgetSkipped", "widgetDismissed"]
    static let formResolutionKeys = ["formResolution", "formSubmissionEffect"]
    static let pendingApprovalStatuses = ["pending", "open", "requested", "awaiting", "waiting"]

    public static func openRequest(in data: Data) -> OpenRequest? {
        guard let root = try? JSONValue.parse(data),
              let entries = root["value"]?["entries"]?.arrayValue ?? root["entries"]?.arrayValue
        else { return nil }
        return openRequest(entries: entries)
    }

    public static func openRequest(entries: [JSONValue]) -> OpenRequest? {
        guard let last = entries.last(where: isTurn),
              last["kind"]?.stringValue == "send-message",
              let message = last["message"]
        else { return nil }

        let content: AttentionContent?
        var isPlainText = false
        switch message["type"]?.stringValue {
        case "text":
            guard let text = message["content"]?.stringValue, PlainQuestion.isQuestion(text) else { return nil }
            content = AttentionContent(kind: .question, prompt: AwaitingRequestParser.clean(text), source: .conversation)
            isPlainText = true
        case "widget":
            guard !isResolved(last, keys: widgetResolutionKeys), let widget = message["widget"] else { return nil }
            content = widgetContent(widget)
        case "auto-review-approval":
            let status = message["approval"]?["status"]?.stringValue?.lowercased() ?? ""
            guard pendingApprovalStatuses.contains(where: status.hasPrefix) else { return nil }
            let approval = message["approval"]
            content = AttentionContent(
                kind: .approval,
                prompt: (approval?["summary"]?.stringValue ?? approval?["reason"]?.stringValue).flatMap(AwaitingRequestParser.clean),
                source: .conversation,
                grokBotOnlyReason: "Review this approval in Grok Bot."
            )
        case "user-form":
            guard !isResolved(last, keys: formResolutionKeys) else { return nil }
            // Forms can ask for passwords and codes: those never pass through BotPeek.
            content = AttentionContent(
                kind: .handoff,
                prompt: message["formRequest"]?["title"]?.stringValue.flatMap(AwaitingRequestParser.clean),
                source: .conversation,
                grokBotOnlyReason: "Fill this in securely in Grok Bot."
            )
        default:
            content = nil
        }
        guard let content else { return nil }

        let identity = [last["id"]?.identifierString ?? "", last["timestampMs"]?.identifierString ?? ""]
        let postedAt = last["timestampMs"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1_000) }
        return OpenRequest(
            fingerprint: StableHash.fnv1a(identity.joined(separator: "|")),
            content: content,
            isPlainText: isPlainText,
            postedAt: postedAt
        )
    }

    /// Entries that move the conversation on: the bot posting to the user, or
    /// the user writing or attaching something. Messages between bots don't count.
    static func isTurn(_ entry: JSONValue) -> Bool {
        switch entry["kind"]?.stringValue {
        case "send-message", "user-attachment":
            return true
        case "message":
            return entry["role"]?.stringValue == "user" && (entry["fromAgent"]?.isEmptySignal ?? true)
        default:
            return false
        }
    }

    static func isResolved(_ entry: JSONValue, keys: [String]) -> Bool {
        keys.contains { entry[$0].map { !$0.isEmptySignal } ?? false }
    }

    static func widgetContent(_ widget: JSONValue) -> AttentionContent {
        let prompt = widget["prompt"]?.stringValue.flatMap(AwaitingRequestParser.clean)
        let choices = AwaitingRequestParser.dedupe(Array(
            (widget["options"]?.arrayValue ?? []).compactMap(AwaitingRequestParser.choice(from:))
                .prefix(AwaitingRequestParser.maximumChoices)
        ))
        // A multi-step widget can't be answered from one list, so show its
        // options and take a typed answer instead.
        let isMultiStep = widget["steps"]?.arrayValue?.isEmpty == false
        if isMultiStep || choices.isEmpty {
            let list = choices.map { "• " + $0.label }.joined(separator: "\n")
            let text = [prompt, list.isEmpty ? nil : list].compactMap { $0 }.joined(separator: "\n\n")
            return AttentionContent(kind: .question, prompt: text.isEmpty ? nil : text, source: .conversation)
        }
        // Several answers are picked in BotPeek and sent as one typed reply.
        if widget["multiSelect"]?.boolValue == true {
            return AttentionContent(kind: .choice, prompt: prompt, choices: choices, source: .conversation, allowsMultipleChoices: true)
        }
        let kind: AttentionKind = ApprovalHeuristics.looksLikeApproval(choices) ? .approval : .choice
        return AttentionContent(kind: kind, prompt: prompt, choices: choices, source: .conversation)
    }
}

/// Decides whether an ordinary bot message is a question waiting for the user.
///
/// The message must end with a question: its last sentence ends in "?". Sign-off
/// lines like "Anything else?" don't count, since nothing is blocked on them.
public enum PlainQuestion {
    static let signOffs = [
        "anything else", "any other questions", "any questions", "anything i can help",
        "help with anything", "else i can do", "else i can help",
        // Polish: "Coś jeszcze?", "Czy mogę jeszcze w czymś pomóc?", "Masz jakieś pytania?"
        "coś jeszcze", "jeszcze coś", "czegoś jeszcze", "jeszcze czegoś", "w czymś jeszcze",
        "jeszcze w czymś", "w czym jeszcze", "jakieś pytania", "jakieś inne pytania",
    ]

    public static func isQuestion(_ text: String) -> Bool {
        // Closing quotes, brackets and emoji may follow the question mark.
        // Swift's own Unicode data, unlike Foundation's symbol set on Linux,
        // covers every emoji.
        var trimmed = Substring(text)
        while let last = trimmed.last, isTrailingDecoration(last) { trimmed.removeLast() }
        guard trimmed.hasSuffix("?") || trimmed.hasSuffix("？") else { return false }
        let lastSentence = trimmed.dropLast()
            .split(whereSeparator: { ".!?\n".contains($0) })
            .last.map(String.init)?
            .lowercased() ?? ""
        return !signOffs.contains { lastSentence.contains($0) }
    }

    /// Whitespace, closing punctuation, and symbols such as emoji (with their
    /// skin tones, variation selectors and joiners).
    static func isTrailingDecoration(_ character: Character) -> Bool {
        if character.isWhitespace || "\"'”’)]*_".contains(character) { return true }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol, .nonspacingMark, .enclosingMark, .format:
                return true
            default:
                return false
            }
        }
    }
}

/// Reads bots' cached conversations, re-parsing a file only when it changes.
public final class ConversationStore: @unchecked Sendable {
    public static let maximumFileSize = 8 * 1_024 * 1_024
    static let transcriptKeyInfix = ".transcript.replicas."

    public let paths: GrokBotPaths
    private let lock = NSLock()
    private var cache: [URL: (modified: Date?, size: Int, request: ConversationRequestParser.OpenRequest?)] = [:]

    public init(paths: GrokBotPaths) {
        self.paths = paths
    }

    /// The conversation file for `botID` in the same account as `rosterFile`.
    public func fileURL(for botID: BotID, rosterFile: URL) -> URL? {
        guard let rosterKey = Base32.decodeKey(fileName: rosterFile.deletingPathExtension().lastPathComponent),
              rosterKey.hasSuffix(RosterStore.rosterKeySuffix)
        else { return nil }
        let account = rosterKey.dropLast(RosterStore.rosterKeySuffix.count)
        let key = account + Self.transcriptKeyInfix + botID.rawValue
        // Base32 output is [a-z2-7] only, so bot ids can't escape the folder.
        return paths.persistenceDirectory.appendingPathComponent(Base32.encode(Data(key.utf8)) + ".blob")
    }

    /// Open requests by bot. Bots without a conversation file are left out.
    public func openRequests(for bots: [BotID], rosterFile: URL) -> [BotID: ConversationRequestParser.OpenRequest] {
        var result: [BotID: ConversationRequestParser.OpenRequest] = [:]
        var seen = Set<URL>()
        for bot in bots {
            guard let url = fileURL(for: bot, rosterFile: rosterFile) else { continue }
            seen.insert(url)
            if let request = openRequest(at: url) { result[bot] = request }
        }
        lock.lock()
        cache = cache.filter { seen.contains($0.key) }
        lock.unlock()
        return result
    }

    func openRequest(at url: URL) -> ConversationRequestParser.OpenRequest? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumFileSize
        else { return nil }
        let modified = values.contentModificationDate

        lock.lock()
        if let cached = cache[url], cached.modified == modified, cached.size == size {
            lock.unlock()
            return cached.request
        }
        lock.unlock()

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let request = ConversationRequestParser.openRequest(in: data)
        lock.lock()
        cache[url] = (modified, size, request)
        lock.unlock()
        return request
    }
}
