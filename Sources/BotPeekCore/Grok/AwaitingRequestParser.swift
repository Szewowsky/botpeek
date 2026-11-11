import Foundation

/// Extracts a readable request from Grok Bot's `awaitingUserResponse` payload.
///
/// The payload's structure is not documented. This parser looks for the usual
/// places a question, its options and an approval flag would be stored, and
/// degrades to `AttentionContent.opaque` (bot is waiting, details unknown) when
/// nothing recognizable is present. BotPeek then reads the question from the
/// conversation transcript instead, or offers to open Grok Bot.
public enum AwaitingRequestParser {
    static let promptKeys = ["question", "prompt", "message", "text", "title", "body", "summary", "description", "reason"]
    static let choiceKeys = ["choices", "options", "answers", "buttons", "suggestions"]
    static let labelKeys = ["label", "title", "text", "name", "value", "description"]
    static let identifierKeys = ["id", "requestId", "questionId", "toolCallId", "approvalId", "messageId"]
    static let typeKeys = ["type", "kind", "reason", "status"]

    static let maximumDepth = 6
    static let maximumTextLength = 2_000
    static let maximumChoices = 12

    public static func parse(_ payload: JSONValue) -> AttentionContent {
        let prompt = findPrompt(in: payload, depth: 0)
        let choices = findChoices(in: payload, depth: 0)
        let typeText = findTypeText(in: payload, depth: 0).lowercased()

        let kind: AttentionKind
        if isApprovalType(typeText) || ApprovalHeuristics.looksLikeApproval(choices) {
            kind = .approval
        } else if !choices.isEmpty {
            kind = .choice
        } else if typeText.contains("handoff") || typeText.contains("takeover") || typeText.contains("instruction") {
            kind = .handoff
        } else if prompt != nil {
            kind = .question
        } else {
            kind = .unknown
        }

        if prompt == nil, choices.isEmpty, kind == .unknown {
            return .opaque
        }
        return AttentionContent(kind: kind, prompt: prompt, choices: choices, source: .roster)
    }

    /// A fingerprint that identifies *this* question, used for deduplication.
    ///
    /// It is built from the payload's identifier fields and readable content
    /// only, so timestamps or counters that change while the same question is
    /// pending do not make BotPeek pop up again.
    public static func fingerprint(of payload: JSONValue) -> String {
        let content = parse(payload)
        var parts: [String] = []
        if let identifier = findIdentifier(in: payload, depth: 0) { parts.append("id:" + identifier) }
        parts.append("kind:" + content.kind.rawValue)
        if let prompt = content.prompt { parts.append("prompt:" + prompt) }
        parts.append(contentsOf: content.choices.map { "choice:" + $0.label })
        return StableHash.fnv1a(parts.joined(separator: "\u{1F}"))
    }

    // MARK: - Search

    static func findPrompt(in value: JSONValue, depth: Int) -> String? {
        guard depth <= maximumDepth else { return nil }
        switch value {
        case .string(let text) where depth == 0:
            return clean(text)
        case .object(let object):
            for key in promptKeys {
                if let text = object[key]?.stringValue.flatMap(clean) { return text }
            }
            for key in object.keys.sorted() where !choiceKeys.contains(key) {
                if let nested = object[key], nested.objectValue != nil,
                   let text = findPrompt(in: nested, depth: depth + 1) {
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }

    static func findChoices(in value: JSONValue, depth: Int) -> [AttentionChoice] {
        guard depth <= maximumDepth, let object = value.objectValue else { return [] }
        for key in choiceKeys {
            if let array = object[key]?.arrayValue {
                let choices = array.compactMap(choice(from:))
                if !choices.isEmpty { return dedupe(Array(choices.prefix(maximumChoices))) }
            }
        }
        for key in object.keys.sorted() {
            if let nested = object[key], nested.objectValue != nil {
                let choices = findChoices(in: nested, depth: depth + 1)
                if !choices.isEmpty { return choices }
            }
        }
        return []
    }

    static func choice(from value: JSONValue) -> AttentionChoice? {
        if let text = value.stringValue.flatMap(clean) {
            return AttentionChoice(label: text)
        }
        guard let object = value.objectValue else { return nil }
        for key in labelKeys {
            if let label = object[key]?.stringValue.flatMap(clean) {
                let detail = ["description", "detail", "subtitle"]
                    .filter { $0 != key }
                    .compactMap { object[$0]?.stringValue.flatMap(clean) }
                    .first
                return AttentionChoice(label: label, detail: detail)
            }
        }
        return nil
    }

    static func findTypeText(in value: JSONValue, depth: Int) -> String {
        guard depth <= maximumDepth, let object = value.objectValue else { return "" }
        var found: [String] = []
        for key in typeKeys {
            if let text = object[key]?.stringValue { found.append(text) }
        }
        for key in ["approval", "permission", "toolApproval", "requiresApproval"] where object[key] != nil {
            if object[key]?.isEmptySignal == false { found.append("approval") }
        }
        for key in object.keys.sorted() {
            if let nested = object[key], nested.objectValue != nil {
                let text = findTypeText(in: nested, depth: depth + 1)
                if !text.isEmpty { found.append(text) }
            }
        }
        return found.joined(separator: " ")
    }

    static func findIdentifier(in value: JSONValue, depth: Int) -> String? {
        guard depth <= maximumDepth, let object = value.objectValue else { return nil }
        for key in identifierKeys {
            if let identifier = object[key]?.identifierString { return identifier }
        }
        for key in object.keys.sorted() {
            if let nested = object[key], nested.objectValue != nil,
               let identifier = findIdentifier(in: nested, depth: depth + 1) {
                return identifier
            }
        }
        return nil
    }

    static func isApprovalType(_ text: String) -> Bool {
        ["approval", "approve", "permission", "confirm"].contains { text.contains($0) }
    }

    static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maximumTextLength ? String(trimmed.prefix(maximumTextLength)) + "…" : trimmed
    }

    static func dedupe(_ choices: [AttentionChoice]) -> [AttentionChoice] {
        var seen = Set<String>()
        return choices.filter { seen.insert($0.label).inserted }
    }
}

/// Recognizes approve/deny style options.
public enum ApprovalHeuristics {
    static let approveWords = GrokBotLabels.approveWords
    static let denyWords = GrokBotLabels.denyWords

    public static func isApproveLabel(_ label: String) -> Bool {
        let text = label.lowercased()
        return approveWords.contains { text.hasPrefix($0) }
    }

    public static func isDenyLabel(_ label: String) -> Bool {
        let text = label.lowercased()
        return denyWords.contains { text.hasPrefix($0) }
    }

    /// True when the options contain both an approve-like and a deny-like label.
    public static func looksLikeApproval(_ choices: [AttentionChoice]) -> Bool {
        choices.contains { isApproveLabel($0.label) } && choices.contains { isDenyLabel($0.label) }
    }
}
