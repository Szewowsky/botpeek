import Foundation

// The transcript layout handled here (message groups labelled "<sender> <time>",
// a "Conversation transcript" container, "Dismiss question" next to choice
// buttons, and a "Prompt" text area) was documented by grok-bot-mcp,
// Copyright (c) 2026 Ryan Thomas, MIT License. See THIRD_PARTY_NOTICES.md.

public struct TranscriptMessage: Equatable, Sendable {
    /// The group's accessible label, "<sender> <time>". Unique enough to tell
    /// messages apart within the rendered window of the transcript.
    public var label: String
    public var sender: String
    public var time: String
    public var text: String
}

public struct OpenQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var nodeID: Int
    }

    public var prompt: String?
    public var options: [Option]
}

/// What BotPeek can see of the conversation currently open in Grok Bot.
public struct ConversationSnapshot: Equatable, Sendable {
    /// The open conversation's title (the bot's name).
    public var heading: String?
    public var hasTranscript: Bool
    /// Rendered messages, oldest first. Grok Bot only renders recent messages.
    public var messages: [TranscriptMessage]
    public var openQuestion: OpenQuestion?
    public var composerNodeID: Int?
    public var sendButtonNodeID: Int?

    public static let empty = ConversationSnapshot(
        heading: nil, hasTranscript: false, messages: [], openQuestion: nil, composerNodeID: nil, sendButtonNodeID: nil
    )
}

public enum TranscriptParser {
    /// The sender labels Grok Bot uses for the user's own messages, one per language.
    public static let defaultUserSenders = GrokBotLabels.userSenders
    static let dismissQuestionLabels = GrokBotLabels.dismissQuestion
    static let customAnswerLabels = GrokBotLabels.customAnswer
    static let sendButtonLabels = GrokBotLabels.sendButtons

    // "<sender> 9:55:21 PM" or "<sender> 21:55:21". `\s` also matches the
    // narrow no-break space macOS puts before AM/PM.
    private static let messageLabelPattern = try! NSRegularExpression(
        pattern: #"^(.+?)\s(\d{1,2}:\d{2}:\d{2}(?:\s?[AaPp][Mm])?)$"#
    )
    private static let timePattern = try! NSRegularExpression(
        pattern: #"^\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AaPp][Mm])?$"#
    )

    public static func parse(window root: AXNodeSnapshot) -> ConversationSnapshot {
        let heading = root.first { $0.role == "AXHeading" }.map { node -> String in
            [node.axDescription, node.title, node.value]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        }
        let composer = root.first {
            $0.role == "AXTextArea"
                && [$0.axDescription, $0.title].contains { $0.map(GrokBotLabels.composer.contains) ?? false }
        }
        let sendButton = root.first { $0.role == "AXButton" && sendButtonLabels.contains($0.label) }

        guard let transcript = root.first(where: { $0.axDescription.map(GrokBotLabels.transcript.contains) ?? false }) else {
            return ConversationSnapshot(
                heading: heading, hasTranscript: false, messages: [], openQuestion: nil,
                composerNodeID: composer?.id, sendButtonNodeID: sendButton?.id
            )
        }

        let groups = messageGroups(in: transcript)
        let messages = groups.map(parseMessage)
        return ConversationSnapshot(
            heading: heading,
            hasTranscript: true,
            messages: messages,
            openQuestion: openQuestion(in: transcript),
            composerNodeID: composer?.id,
            sendButtonNodeID: sendButton?.id
        )
    }

    // MARK: - Messages

    static func parseLabel(_ label: String) -> (sender: String, time: String)? {
        let range = NSRange(label.startIndex..., in: label)
        guard let match = messageLabelPattern.firstMatch(in: label, range: range),
              let senderRange = Range(match.range(at: 1), in: label),
              let timeRange = Range(match.range(at: 2), in: label)
        else { return nil }
        return (String(label[senderRange]), String(label[timeRange]))
    }

    static func isTime(_ text: String) -> Bool {
        timePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func messageGroups(in transcript: AXNodeSnapshot) -> [AXNodeSnapshot] {
        var groups: [AXNodeSnapshot] = []
        func collect(_ node: AXNodeSnapshot, depth: Int) {
            guard depth <= 4 else { return }
            for child in node.children {
                if parseLabel(child.title ?? "") != nil {
                    groups.append(child)
                } else {
                    collect(child, depth: depth + 1)
                }
            }
        }
        collect(transcript, depth: 0)
        return groups
    }

    static func parseMessage(_ group: AXNodeSnapshot) -> TranscriptMessage {
        let label = group.title ?? ""
        let (sender, time) = parseLabel(label) ?? ("", "")
        var texts: [String] = []
        var skippedSender = false

        func visit(_ node: AXNodeSnapshot, insideButton: Bool) {
            for child in node.children {
                if child.role == "AXButton" {
                    visit(child, insideButton: true)
                    continue
                }
                if !insideButton, child.role == "AXStaticText" || child.role == "AXListMarker" {
                    let text = (child.value ?? child.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, !isTime(text) {
                        if !skippedSender, text == sender {
                            skippedSender = true
                        } else {
                            texts.append(text)
                        }
                    }
                }
                visit(child, insideButton: insideButton)
            }
        }
        visit(group, insideButton: false)
        return TranscriptMessage(label: label, sender: sender, time: time, text: joinListMarkers(texts))
    }

    /// Joins list markers ("1.", "•") with the text that follows them.
    static func joinListMarkers(_ texts: [String]) -> String {
        var joined: [String] = []
        for text in texts {
            if text.range(of: #"^(\d+\.|[•\-])$"#, options: .regularExpression) != nil {
                joined.append(text + " ")
            } else if let last = joined.last, last.hasSuffix(" ") {
                joined[joined.count - 1] = last + text
            } else {
                joined.append(text)
            }
        }
        return joined.joined(separator: "\n\n")
    }

    // MARK: - Open question

    /// Finds the newest question that has selectable answers.
    ///
    /// Only questions with a "Dismiss question" button count. Other buttons in
    /// the transcript (copy, retry, links) are never mistaken for answers.
    static func openQuestion(in transcript: AXNodeSnapshot) -> OpenQuestion? {
        dismissibleQuestion(in: transcript) ?? inlineQuestion(in: transcript)
    }

    static func dismissibleQuestion(in transcript: AXNodeSnapshot) -> OpenQuestion? {
        var questionGroup: AXNodeSnapshot?
        for (node, parent) in transcript.descendants()
        where node.role == "AXButton" && dismissQuestionLabels.contains(node.label) {
            questionGroup = parent
        }
        guard let group = questionGroup else { return nil }

        let options = group.descendants()
            .map(\.node)
            .filter { $0.role == "AXButton" && !$0.label.isEmpty && !dismissQuestionLabels.contains($0.label) }
            .map { OpenQuestion.Option(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), nodeID: $0.id) }
        guard !options.isEmpty else { return nil }

        let message = parseMessage(AXNodeSnapshot(id: group.id, role: group.role, title: nil, children: group.children))
        let prompt = message.text.components(separatedBy: "\n\n").last { !$0.isEmpty }
        return OpenQuestion(prompt: prompt, options: options)
    }

    /// Grok Bot 0.78 shows a question's options as buttons in a group labelled
    /// with the question, optionally with a "Custom answer" box, and no dismiss
    /// button. Only the newest message counts: older unanswered questions stay
    /// on screen with working buttons, and the bot has moved on from them.
    static func inlineQuestion(in transcript: AXNodeSnapshot, userSenders: Set<String> = defaultUserSenders) -> OpenQuestion? {
        guard let newest = messageGroups(in: transcript).last,
              !userSenders.contains(parseLabel(newest.title ?? "")?.sender ?? "")
        else { return nil }
        let group = newest.descendants().map(\.node).last { node in
            let label = node.axDescription ?? ""
            let buttons = node.children.filter { $0.role == "AXButton" && !$0.label.isEmpty }
            let hasCustomAnswer = node.first(maxDepth: 2) { $0.role == "AXTextArea" && customAnswerLabels.contains($0.label) } != nil
            return node.role == "AXGroup" && !label.isEmpty && !GrokBotLabels.hasMessageActionsPrefix(label)
                && !buttons.isEmpty && (buttons.count >= 2 || hasCustomAnswer)
        }
        guard let group else { return nil }
        let options = group.children
            .filter { $0.role == "AXButton" && !$0.label.isEmpty }
            .map { OpenQuestion.Option(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), nodeID: $0.id) }
        return OpenQuestion(prompt: group.axDescription, options: options)
    }

    // MARK: - Content

    /// Turns what is visible in the conversation into a request BotPeek can show.
    public static func content(
        from conversation: ConversationSnapshot,
        userSenders: Set<String> = defaultUserSenders
    ) -> AttentionContent? {
        if let question = conversation.openQuestion {
            let choices = question.options.map { AttentionChoice(label: $0.label) }
            let kind: AttentionKind = ApprovalHeuristics.looksLikeApproval(choices) ? .approval : .choice
            return AttentionContent(kind: kind, prompt: question.prompt, choices: choices, source: .transcript)
        }
        guard let last = conversation.messages.last, !userSenders.contains(last.sender), !last.text.isEmpty else {
            return nil
        }
        return AttentionContent(kind: .question, prompt: last.text, choices: [], source: .transcript)
    }
}

/// Confirms that a reply actually reached the conversation.
public enum DeliveryVerifier {
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when a new message from the user containing `text` has appeared.
    public static func textDelivered(
        _ text: String,
        before: ConversationSnapshot,
        after: ConversationSnapshot,
        userSenders: Set<String> = TranscriptParser.defaultUserSenders
    ) -> Bool {
        let known = Set(before.messages.map(\.label))
        let needle = String(normalize(text).prefix(60))
        return after.messages.contains { message in
            guard !known.contains(message.label) else { return false }
            let body = normalize(message.text)
            return (userSenders.contains(message.sender) && (needle.isEmpty || body.contains(needle) || body.isEmpty))
                || (!needle.isEmpty && body.contains(needle))
        }
    }

    /// True when the chosen option has been accepted: the question is gone or a
    /// new message repeats the choice.
    public static func choiceDelivered(
        _ choice: String,
        before: ConversationSnapshot,
        after: ConversationSnapshot
    ) -> Bool {
        guard before.openQuestion != nil else { return false }
        let stillOffered = after.openQuestion?.options.contains { $0.label == choice } ?? false
        if !stillOffered, after.hasTranscript { return true }
        let known = Set(before.messages.map(\.label))
        let needle = normalize(choice)
        return after.messages.contains { !known.contains($0.label) && normalize($0.text).contains(needle) }
    }
}
