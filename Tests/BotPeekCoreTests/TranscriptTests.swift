import XCTest
@testable import BotPeekCore

final class SidebarParserTests: XCTestCase {
    func testListsBotButtonsOnly() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research Bot, Waiting for you", "Writer"], heading: nil, messages: [])
        let entries = SidebarParser.entries(in: window)
        XCTAssertEqual(entries?.map(\.label), ["Research Bot, Waiting for you", "Writer"])
        XCTAssertEqual(SidebarParser.statusText(of: entries![0], botName: "Research Bot"), "Waiting for you")
        XCTAssertNil(SidebarParser.statusText(of: entries![1], botName: "Writer"))
    }

    func testMissingSidebarReturnsNil() {
        let ax = AXTreeBuilder()
        XCTAssertNil(SidebarParser.entries(in: ax.node("AXWindow")))
    }
}

final class BotIdentityMatcherTests: XCTestCase {
    func testExactMatchOnly() {
        let research = identity("r", "Research")
        let sidebar = [SidebarEntry(nodeID: 1, label: "Research Assistant"), SidebarEntry(nodeID: 2, label: "Research, Waiting for you")]
        XCTAssertEqual(BotIdentityMatcher.match(bot: research, roster: [research], sidebar: sidebar), .unique(sidebar[1]))
    }

    func testNoFuzzyMatching() {
        let bot = identity("r", "Res")
        let sidebar = [SidebarEntry(nodeID: 1, label: "Research Bot")]
        XCTAssertEqual(BotIdentityMatcher.match(bot: bot, roster: [bot], sidebar: sidebar), .notFound, "prefixes never match")
    }

    func testDuplicateNamesAreAmbiguous() {
        let a = identity("a", "Helper")
        let b = identity("b", "Helper")
        let sidebar = [SidebarEntry(nodeID: 1, label: "Helper"), SidebarEntry(nodeID: 2, label: "Helper")]
        XCTAssertEqual(BotIdentityMatcher.match(bot: a, roster: [a, b], sidebar: sidebar), .ambiguous)
    }

    func testOpenConversationNeedsUniqueName() {
        let a = identity("a", "Helper")
        let b = identity("b", "Helper")
        let c = identity("c", "Writer")
        XCTAssertTrue(BotIdentityMatcher.isOpen(bot: c, heading: "Writer", roster: [a, b, c]))
        XCTAssertFalse(BotIdentityMatcher.isOpen(bot: c, heading: "Helper", roster: [a, b, c]))
        XCTAssertFalse(BotIdentityMatcher.isOpen(bot: c, heading: nil, roster: [a, b, c]))
        XCTAssertFalse(BotIdentityMatcher.isOpen(bot: a, heading: "Helper", roster: [a, b, c]), "the open Helper may be the other one")
    }

    func testNamesContainingCommas() {
        let short = identity("a", "Ops")
        let long = identity("b", "Ops, Europe")
        let sidebar = [SidebarEntry(nodeID: 1, label: "Ops, Working"), SidebarEntry(nodeID: 2, label: "Ops, Europe, Waiting for you")]
        XCTAssertEqual(BotIdentityMatcher.match(bot: short, roster: [short, long], sidebar: sidebar), .unique(sidebar[0]))
        XCTAssertEqual(BotIdentityMatcher.match(bot: long, roster: [short, long], sidebar: sidebar), .unique(sidebar[1]))
    }
}

final class TranscriptParserTests: XCTestCase {
    func testParsesMessagesAndOpenQuestion() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research Bot"], heading: "Research Bot", messages: [
            ax.message("You", "9:50:01 PM", ["Find me vendors"]),
            ax.message("Research Bot", "9:55:21\u{202F}PM", ["I found three.", "Which should I contact?"],
                       buttons: ["Northwind", "Acme", "Globex"], dismiss: true),
        ])
        let conversation = TranscriptParser.parse(window: window)
        XCTAssertEqual(conversation.heading, "Research Bot")
        XCTAssertTrue(conversation.hasTranscript)
        XCTAssertNotNil(conversation.composerNodeID)
        XCTAssertEqual(conversation.messages.map(\.sender), ["You", "Research Bot"])
        XCTAssertEqual(conversation.messages[1].text, "I found three.\n\nWhich should I contact?", "button text and timestamps are excluded")
        XCTAssertEqual(conversation.openQuestion?.options.map(\.label), ["Northwind", "Acme", "Globex"])

        let content = TranscriptParser.content(from: conversation)
        XCTAssertEqual(content?.kind, .choice)
        XCTAssertEqual(content?.choices.count, 3)
        XCTAssertEqual(content?.source, .transcript)
    }

    func testButtonsWithoutDismissAreNotChoices() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: [], heading: "Writer", messages: [
            ax.message("Writer", "10:00:00", ["Draft ready. Any changes?"], buttons: ["Copy", "Retry"]),
        ])
        let conversation = TranscriptParser.parse(window: window)
        XCTAssertNil(conversation.openQuestion, "copy/retry buttons are not answers")
        let content = TranscriptParser.content(from: conversation)
        XCTAssertEqual(content?.kind, .question)
        XCTAssertEqual(content?.prompt, "Draft ready. Any changes?")
    }

    func testApprovalButtonsAreRecognized() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: [], heading: "Ops Bot", messages: [
            ax.message("Ops Bot", "8:00:00 AM", ["Run the migration?"], buttons: ["Approve", "Deny"], dismiss: true),
        ])
        XCTAssertEqual(TranscriptParser.content(from: TranscriptParser.parse(window: window))?.kind, .approval)
    }

    func testLastMessageFromUserIsNotAQuestion() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: [], heading: "Writer", messages: [ax.message("You", "10:00:00", ["Thanks!"])])
        XCTAssertNil(TranscriptParser.content(from: TranscriptParser.parse(window: window)))
    }

    func testInlineQuestionButtons() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: [], heading: "Travel Planner", messages: [
            ax.inlineQuestion("Travel Planner", "12:54:10\u{202F}AM", prompt: "How many travelers?", buttons: ["1", "2", "3"]),
            ax.message("Message from Planner", "1:52:36\u{202F}PM", ["Message from"], buttons: ["Open exchange with Planner"]),
            ax.inlineQuestion("Travel Planner", "1:56:10\u{202F}PM", prompt: "Which cabin?", buttons: ["Economy", "Business"]),
        ])
        let question = TranscriptParser.parse(window: window).openQuestion
        XCTAssertEqual(question?.prompt, "Which cabin?", "only the newest message's question counts")
        XCTAssertEqual(question?.options.map(\.label), ["Economy", "Business"])
    }

    func testOlderInlineQuestionIsNotOpen() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: [], heading: "Travel Planner", messages: [
            ax.inlineQuestion("Travel Planner", "12:54:10 AM", prompt: "How many travelers?", buttons: ["1", "2"]),
            ax.message("Travel Planner", "1:52:40 PM", ["Still here."]),
        ])
        XCTAssertNil(TranscriptParser.parse(window: window).openQuestion)
    }

    func testSingleInlineButtonNeedsCustomAnswerBox() {
        let ax = AXTreeBuilder()
        let withBox = ax.window(sidebar: [], heading: "Travel Planner", messages: [
            ax.inlineQuestion("Travel Planner", "1:00:00 PM", prompt: "Ready?", buttons: ["Yes"]),
        ])
        XCTAssertEqual(TranscriptParser.parse(window: withBox).openQuestion?.options.map(\.label), ["Yes"])
        let lone = ax.window(sidebar: [], heading: "Travel Planner", messages: [
            ax.inlineQuestion("Travel Planner", "1:00:00 PM", prompt: "Ready?", buttons: ["Yes"], customAnswer: false),
        ])
        XCTAssertNil(TranscriptParser.parse(window: lone).openQuestion, "a lone button could be a link or action")
    }

    func testListMarkersAreJoined() {
        XCTAssertEqual(TranscriptParser.joinListMarkers(["Options:", "1.", "Alpha", "2.", "Beta"]), "Options:\n\n1. Alpha\n\n2. Beta")
    }
}

/// The send button is looked for only next to the message box, never in the
/// transcript, where a bot's own option can carry the same label.
final class SendButtonTests: XCTestCase {
    /// A window whose message box sits in its own group with `composerExtras`,
    /// below a transcript holding `transcriptExtras`.
    func window(_ ax: AXTreeBuilder, transcriptExtras: [AXNodeSnapshot] = [], composerExtras: [AXNodeSnapshot]) -> AXNodeSnapshot {
        ax.node("AXWindow", title: "Grok Bot", [
            ax.node("AXList", desc: ax.strings.bots, [ax.button(ax.strings.newChat)]),
            ax.node("AXGroup", [
                ax.node("AXHeading", desc: "Mail Bot"),
                ax.node("AXGroup", desc: ax.strings.transcript, transcriptExtras + [ax.node("AXGroup", [
                    ax.message("Mail Bot", "21:55:21", ["Wysłać maila do klienta?"], buttons: ["Wyślij", "Anuluj"], dismiss: true),
                ])]),
                ax.node("AXGroup", [ax.node("AXTextArea", desc: ax.strings.prompt)] + composerExtras),
            ]),
        ])
    }

    func testBotOptionInTranscriptIsNeverTheSendButton() {
        let ax = AXTreeBuilder(strings: .polish)
        // The bot's option is shallower in the tree than Grok Bot's own button.
        let send = ax.button("Wyślij wiadomość")
        let root = window(ax, transcriptExtras: [ax.button("Wyślij")], composerExtras: [
            ax.node("AXGroup", [ax.node("AXGroup", [ax.node("AXGroup", [send])])]),
        ])
        XCTAssertEqual(TranscriptParser.parse(window: root).sendButtonNodeID, send.id)
    }

    func testOnlyBotOptionsGiveNoSendButton() {
        // Grok Bot draws its button only once the box has text; until then only
        // the bot's "Wyślij" option is on screen, and it must not be pressed.
        let ax = AXTreeBuilder(strings: .polish)
        let root = window(ax, transcriptExtras: [ax.button("Wyślij")], composerExtras: [])
        XCTAssertNil(TranscriptParser.parse(window: root).sendButtonNodeID)
    }

    func testNoSendButtonGivesNil() {
        let ax = AXTreeBuilder()
        XCTAssertNil(TranscriptParser.parse(window: window(ax, composerExtras: [])).sendButtonNodeID)
    }

    func testTwoSendButtonsNextToTheBoxGiveNil() {
        let ax = AXTreeBuilder(strings: .polish)
        let root = window(ax, composerExtras: [ax.button("Wyślij wiadomość"), ax.node("AXGroup", [ax.button("Wyślij")])])
        XCTAssertNil(TranscriptParser.parse(window: root).sendButtonNodeID, "anything unclear means nothing is pressed")
    }

    func testSendButtonElsewhereInTheWindowIsNotUsed() {
        let ax = AXTreeBuilder()
        var root = window(ax, composerExtras: [])
        root.children.append(ax.button("Send"))
        XCTAssertNil(TranscriptParser.parse(window: root).sendButtonNodeID)
    }

    func testSendButtonNextToTheBoxInBothLanguages() {
        for (strings, label) in [(GrokUIStrings.english, "Send message"), (.polish, "Wyślij wiadomość")] {
            let ax = AXTreeBuilder(strings: strings)
            let send = ax.button(label)
            let root = window(ax, composerExtras: [ax.node("AXGroup", [send])])
            XCTAssertEqual(TranscriptParser.parse(window: root).sendButtonNodeID, send.id, label)
        }
    }
}

final class DeliveryVerifierTests: XCTestCase {
    func conversation(_ messages: [(String, String, String)], question: [String]? = nil) -> ConversationSnapshot {
        ConversationSnapshot(
            heading: "Bot",
            hasTranscript: true,
            messages: messages.map { TranscriptMessage(label: "\($0.0) \($0.1)", sender: $0.0, time: $0.1, text: $0.2) },
            openQuestion: question.map { OpenQuestion(prompt: "?", options: $0.enumerated().map { .init(label: $1, nodeID: $0) }) },
            composerNodeID: 1,
            sendButtonNodeID: nil
        )
    }

    func testTextDeliveryNeedsANewMessage() {
        let before = conversation([("Bot", "1:00:00", "Budget?")])
        let same = conversation([("Bot", "1:00:00", "Budget?")])
        let after = conversation([("Bot", "1:00:00", "Budget?"), ("You", "1:00:09", "Under   $200 please")])
        XCTAssertFalse(DeliveryVerifier.textDelivered("Under $200 please", before: before, after: same))
        XCTAssertTrue(DeliveryVerifier.textDelivered("Under $200 please", before: before, after: after))
    }

    func testOldIdenticalMessageDoesNotCount() {
        let before = conversation([("You", "1:00:00", "yes")])
        XCTAssertFalse(DeliveryVerifier.textDelivered("yes", before: before, after: before))
    }

    func testChoiceDelivery() {
        let before = conversation([("Bot", "1:00:00", "Pick")], question: ["A", "B"])
        let stillOpen = conversation([("Bot", "1:00:00", "Pick")], question: ["A", "B"])
        let answered = conversation([("Bot", "1:00:00", "Pick"), ("You", "1:00:05", "A")])
        XCTAssertFalse(DeliveryVerifier.choiceDelivered("A", before: before, after: stillOpen))
        XCTAssertTrue(DeliveryVerifier.choiceDelivered("A", before: before, after: answered))
    }
}

/// Grok Bot follows the system language. Labels as seen in Grok Bot 0.79.4 on a Polish Mac.
final class PolishInterfaceTests: XCTestCase {
    func testPolishSidebar() {
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.window(sidebar: ["Research Bot, Czeka na Ciebie", "Writer"], heading: nil, messages: [])
        let entries = SidebarParser.entries(in: window)
        XCTAssertEqual(entries?.map(\.label), ["Research Bot, Czeka na Ciebie", "Writer"], "Polish sidebar buttons are not bots")
        let status = SidebarParser.statusText(of: entries![0], botName: "Research Bot")
        XCTAssertEqual(status, "Czeka na Ciebie")
        XCTAssertTrue(SidebarParser.statusIndicatesAttention(status))
        XCTAssertTrue(SidebarParser.statusIndicatesAttention("Wymaga Twojego zatwierdzenia"))
        XCTAssertFalse(SidebarParser.statusIndicatesAttention("Pracuje"))
    }

    func testPolishSidebarWithNestedLists() {
        // Live layout: an AXGroup "Boty" holding "Lista Botów", "Przypięte Boty" and "Ukryte Boty".
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.node("AXWindow", title: "Grok Bot", [
            ax.node("AXGroup", desc: "Boty", [
                ax.button("Szukaj"),
                ax.node("AXGroup", desc: "Przypięte Boty", [ax.button("Główny Bot")]),
                ax.node("AXGroup", desc: "Lista Botów", [ax.button("Writer"), ax.button("Połącz aplikacje")]),
            ]),
        ])
        XCTAssertEqual(SidebarParser.entries(in: window)?.map(\.label), ["Główny Bot", "Writer"])
    }

    func testPolishConversation() {
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.window(sidebar: ["Research Bot"], heading: "Research Bot", messages: [
            ax.message("Ty", "21:50:01", ["Znajdź dostawców"]),
            ax.message("Research Bot", "21:55:21", ["Znalazłem trzech.", "Z którym się skontaktować?"],
                       buttons: ["Northwind", "Acme", "Globex"], dismiss: true),
        ])
        let conversation = TranscriptParser.parse(window: window)
        XCTAssertTrue(conversation.hasTranscript)
        XCTAssertNotNil(conversation.composerNodeID)
        XCTAssertEqual(conversation.messages.map(\.sender), ["Ty", "Research Bot"])
        XCTAssertEqual(conversation.messages[0].time, "21:50:01")
        XCTAssertEqual(conversation.openQuestion?.options.map(\.label), ["Northwind", "Acme", "Globex"], "Ukryj pytanie is not an option")
        XCTAssertEqual(TranscriptParser.content(from: conversation)?.kind, .choice)
    }

    func testPolishInlineQuestion() {
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.window(sidebar: [], heading: "Travel Planner", messages: [
            ax.inlineQuestion("Travel Planner", "13:56:10", prompt: "Gotowe?", buttons: ["Tak"]),
        ])
        let question = TranscriptParser.parse(window: window).openQuestion
        XCTAssertEqual(question?.prompt, "Gotowe?")
        XCTAssertEqual(question?.options.map(\.label), ["Tak"], "a single button counts next to Własna odpowiedź")
    }

    func testPolishLastMessageFromUserIsNotAQuestion() {
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.window(sidebar: [], heading: "Writer", messages: [
            ax.message("Writer", "10:00:00", ["Czy mam zacząć?"]),
            ax.message("Ty", "10:00:05", ["Tak"]),
        ])
        XCTAssertNil(TranscriptParser.content(from: TranscriptParser.parse(window: window)))
        let question = ax.window(sidebar: [], heading: "Writer", messages: [ax.message("Writer", "10:00:00", ["Czy mam zacząć?"])])
        XCTAssertEqual(TranscriptParser.content(from: TranscriptParser.parse(window: question))?.kind, .question)
    }

    func testPolishSendButton() {
        let ax = AXTreeBuilder(strings: .polish)
        var window = ax.window(sidebar: [], heading: "Writer", messages: [])
        // Next to the message box, in the same group.
        window.children[1].children.append(ax.button("Prześlij"))
        window.children[1].children.append(ax.button("Wyślij wiadomość"))
        let conversation = TranscriptParser.parse(window: window)
        XCTAssertEqual(conversation.sendButtonNodeID, window.children[1].children.last?.id, "Prześlij also means Upload, so it is never the send button")
    }

    func testPolishDelivery() {
        func conversation(_ messages: [(String, String, String)]) -> ConversationSnapshot {
            ConversationSnapshot(
                heading: "Bot", hasTranscript: true,
                messages: messages.map { TranscriptMessage(label: "\($0.0) \($0.1)", sender: $0.0, time: $0.1, text: $0.2) },
                openQuestion: nil, composerNodeID: 1, sendButtonNodeID: nil
            )
        }
        let before = conversation([("Bot", "13:00:00", "Budżet?")])
        let after = conversation([("Bot", "13:00:00", "Budżet?"), ("Ty", "13:00:09", "")])
        XCTAssertTrue(DeliveryVerifier.textDelivered("Do 800 zł", before: before, after: after), "an empty new message from Ty counts")
        XCTAssertFalse(DeliveryVerifier.textDelivered("Do 800 zł", before: before, after: before))
    }
}
