import XCTest
@testable import BotPeekCore

/// Entries shaped like Grok Bot 0.78's cached conversations; all text is made up.
private enum Entry {
    static func human(_ id: String, _ text: String = "Sounds good") -> String {
        #"{"kind":"message","id":"\#(id)","role":"user","content":"\#(text)","timestampMs":1730000000500}"#
    }

    static func fromBot(_ id: String, botName: String = "Planner") -> String {
        #"{"kind":"message","id":"\#(id)","role":"user","content":"Please ask a question","fromAgent":{"id":"b-2","name":"\#(botName)"},"timestampMs":1730000000600}"#
    }

    static func text(_ id: String, _ text: String = "Here is an update.") -> String {
        #"{"kind":"send-message","id":"\#(id)","message":{"type":"text","content":"\#(text)"},"timestampMs":1730000000700}"#
    }

    static func widget(_ id: String, extra: String = "", widget: String = "") -> String {
        let body = widget.isEmpty
            ? #"{"prompt":"Which city first?","options":[{"label":"Lisbon","value":"lisbon","style":"primary"},{"label":"Porto","value":"porto"}],"allowCustom":true}"#
            : widget
        return #"{"kind":"send-message","id":"\#(id)","message":{"type":"widget","widget":\#(body)},"timestampMs":1730000000800\#(extra)}"#
    }
}

private func transcript(_ entries: [String]) -> Data {
    Data(#"{"schemaVersion":1,"value":{"entries":[\#(entries.joined(separator: ","))],"persistedAt":1730000001000}}"#.utf8)
}

private func open(_ entries: [String]) -> ConversationRequestParser.OpenRequest? {
    ConversationRequestParser.openRequest(in: transcript(entries))
}

final class ConversationRequestParserTests: XCTestCase {
    func testOpenChoiceWidget() throws {
        let request = try XCTUnwrap(open([Entry.human("t1u"), Entry.widget("t1s0")]))
        XCTAssertEqual(request.content.kind, .choice)
        XCTAssertEqual(request.content.prompt, "Which city first?")
        XCTAssertEqual(request.content.choices.map(\.label), ["Lisbon", "Porto"])
        XCTAssertEqual(request.content.source, .conversation)
        XCTAssertNil(request.content.grokBotOnlyReason)
    }

    func testAnsweredSkippedOrDismissedWidgetsAreClosed() {
        XCTAssertNil(open([Entry.widget("t1s0", extra: #","respondedValue":"lisbon""#)]))
        XCTAssertNil(open([Entry.widget("t1s0", extra: #","widgetSkipped":true"#)]))
        XCTAssertNil(open([Entry.widget("t1s0", extra: #","widgetDismissed":true"#)]))
        XCTAssertNotNil(open([Entry.widget("t1s0", extra: #","widgetSkipped":false"#)]), "a false flag is not a resolution")
    }

    func testOnlyTheLatestTurnCounts() {
        XCTAssertNil(open([Entry.widget("t1s0"), Entry.human("t2u")]), "the user wrote after the question")
        XCTAssertNil(open([Entry.widget("t1s0"), Entry.text("t1s1")]), "the bot moved on")
        XCTAssertNil(open([Entry.widget("t1s0"), Entry.human("t2u"), Entry.text("t2s0")]))
        XCTAssertNotNil(open([Entry.widget("t1s0"), Entry.fromBot("t2u")]), "messages between bots don't answer it")
        XCTAssertNil(open([Entry.human("t1u"), Entry.text("t1s0")]), "plain messages that ask nothing never count")
        XCTAssertNil(open([]))
    }

    func testMultiSelectOffersItsOptionsToPickSeveral() throws {
        let widget = #"{"prompt":"Which days work?","options":[{"label":"Mon","value":"mon"},{"label":"Tue","value":"tue"}],"multiSelect":true,"allowCustom":true}"#
        let request = try XCTUnwrap(open([Entry.widget("t1s0", widget: widget)]))
        XCTAssertEqual(request.content.kind, .choice)
        XCTAssertTrue(request.content.allowsMultipleChoices)
        XCTAssertEqual(request.content.choices.map(\.label), ["Mon", "Tue"])
        XCTAssertEqual(request.content.prompt, "Which days work?")
        XCTAssertFalse(request.isPlainText)
    }

    func testMultiSelectWithApprovalLabelsIsNotAnApproval() throws {
        let widget = #"{"prompt":"Which steps?","options":[{"label":"Approve"},{"label":"Deny"}],"multiSelect":true}"#
        XCTAssertEqual(try XCTUnwrap(open([Entry.widget("t1s0", widget: widget)])).content.kind, .choice)
    }

    func testMultiStepAsksForATypedAnswer() throws {
        let widget = #"{"prompt":"Plan the trip","options":[{"label":"Mon"},{"label":"Tue"}],"steps":[{"prompt":"Day"},{"prompt":"Time"}]}"#
        let request = try XCTUnwrap(open([Entry.widget("t1s0", widget: widget)]))
        XCTAssertEqual(request.content.kind, .question)
        XCTAssertEqual(request.content.choices, [])
        XCTAssertEqual(request.content.prompt, "Plan the trip\n\n• Mon\n• Tue")
    }

    func testPlainTextQuestionIsOpen() throws {
        let request = try XCTUnwrap(open([Entry.human("t1u"), Entry.text("t1s0", "Got it. What text should the badge show?")]))
        XCTAssertEqual(request.content.kind, .question)
        XCTAssertEqual(request.content.prompt, "Got it. What text should the badge show?")
        XCTAssertTrue(request.isPlainText)
        XCTAssertEqual(request.postedAt, Date(timeIntervalSince1970: 1_730_000_000.7))
    }

    func testPlainTextQuestionClosesWhenAnswered() {
        XCTAssertNil(open([Entry.text("t1s0", "Which city first?"), Entry.human("t2u", "Lisbon")]))
        XCTAssertNil(open([Entry.text("t1s0", "Which city first?"), Entry.text("t1s1", "Never mind, I picked Lisbon.")]))
    }

    func testPlainQuestionHeuristics() {
        XCTAssertTrue(PlainQuestion.isQuestion("Which stores give you receipt surveys?"))
        XCTAssertTrue(PlainQuestion.isQuestion("Should I book it? 🙂"))
        XCTAssertTrue(PlainQuestion.isQuestion("Here's the plan.\n\n**Want me to start now?**"))
        XCTAssertTrue(PlainQuestion.isQuestion("I can't tell which one you meant (\"A\" or \"B\")?"))
        XCTAssertFalse(PlainQuestion.isQuestion("Your search is saved."))
        XCTAssertFalse(PlainQuestion.isQuestion("Is it ready? Yes, it's ready."), "only the ending counts")
        XCTAssertFalse(PlainQuestion.isQuestion("All done. Anything else?"))
        XCTAssertFalse(PlainQuestion.isQuestion("Done! Is there anything else I can help with?"))
        XCTAssertFalse(PlainQuestion.isQuestion(""))
    }

    func testPolishPlainQuestionHeuristics() {
        XCTAssertTrue(PlainQuestion.isQuestion("Które sklepy dają ankiety na paragonie?"))
        XCTAssertTrue(PlainQuestion.isQuestion("Gotowe. Czy mam to wysłać teraz? 🙂"))
        XCTAssertFalse(PlainQuestion.isQuestion("Gotowe. Coś jeszcze?"))
        XCTAssertFalse(PlainQuestion.isQuestion("Zrobione! Czy mogę jeszcze w czymś pomóc?"))
        XCTAssertFalse(PlainQuestion.isQuestion("W czym jeszcze mogę pomóc?"))
        XCTAssertFalse(PlainQuestion.isQuestion("Potrzebujesz czegoś jeszcze?"))
        XCTAssertFalse(PlainQuestion.isQuestion("Masz jakieś pytania?"))
    }

    func testApprovalLabelsBecomeAnApproval() throws {
        let widget = #"{"prompt":"Send the invoice?","options":[{"label":"Approve"},{"label":"Deny"}]}"#
        XCTAssertEqual(try XCTUnwrap(open([Entry.widget("t1s0", widget: widget)])).content.kind, .approval)
    }

    func testFormsOpenOnlyInGrokBot() throws {
        let form = #"{"kind":"send-message","id":"t3s4","message":{"type":"user-form","formRequest":{"secureValues":true,"title":"Sign in to Example","fields":[{"id":"otp","type":"otp","secret":true}]}},"timestampMs":1730000000900,"formRequestId":"f-1"}"#
        let request = try XCTUnwrap(open([form]))
        XCTAssertEqual(request.content.kind, .handoff)
        XCTAssertEqual(request.content.prompt, "Sign in to Example")
        XCTAssertNotNil(request.content.grokBotOnlyReason)

        let submitted = form.replacingOccurrences(of: #","formRequestId""#, with: #","formResolution":"submitted","formRequestId""#)
        XCTAssertNil(open([submitted]))
    }

    func testOnlyPendingApprovalsAreOpen() throws {
        func approval(_ status: String) -> String {
            #"{"kind":"send-message","id":"a-1","message":{"type":"auto-review-approval","approval":{"requestId":"r-1","summary":"Use the calendar tool","status":"\#(status)"}},"timestampMs":1730000000900}"#
        }
        let request = try XCTUnwrap(open([approval("pending")]))
        XCTAssertEqual(request.content.kind, .approval)
        XCTAssertEqual(request.content.prompt, "Use the calendar tool")
        XCTAssertNotNil(request.content.grokBotOnlyReason)
        XCTAssertNil(open([approval("expired")]))
        XCTAssertNil(open([approval("approved")]))
    }

    func testFingerprintIdentifiesTheQuestion() throws {
        let first = try XCTUnwrap(open([Entry.widget("t1s0")]))
        let again = try XCTUnwrap(open([Entry.fromBot("t0u"), Entry.widget("t1s0")]))
        let next = try XCTUnwrap(open([Entry.widget("t2s0")]))
        XCTAssertEqual(first.fingerprint, again.fingerprint)
        XCTAssertNotEqual(first.fingerprint, next.fingerprint)
    }

    func testRejectsNonTranscripts() {
        XCTAssertNil(ConversationRequestParser.openRequest(in: Data("not json".utf8)))
        XCTAssertNil(ConversationRequestParser.openRequest(in: Data(#"{"value":{}}"#.utf8)))
    }
}

final class ConversationStoreTests: XCTestCase {
    let account = "sand.client.slice.account.grok%7Cuser_TEST"

    func testFindsOpenRequestsForTheRosterAccount() throws {
        let folder = try TemporaryGrokFolder()
        let roster = try folder.writeBlob(key: account + ".roster.last-roster", data: Fixture.data("roster-v4.json"))
        try folder.writeBlob(key: account + ".transcript.replicas.bot-a", data: transcript([Entry.widget("t1s0")]))
        try folder.writeBlob(key: account + ".transcript.replicas.bot-b", data: transcript([Entry.text("t1s0")]))
        try folder.writeBlob(key: "sand.client.slice.account.grok%7Cuser_OTHER.transcript.replicas.bot-c", data: transcript([Entry.widget("t1s0")]))

        let store = ConversationStore(paths: folder.paths)
        let found = store.openRequests(for: [BotID("bot-a"), BotID("bot-b"), BotID("bot-c"), BotID("bot-missing")], rosterFile: roster)
        XCTAssertEqual(Set(found.keys), [BotID("bot-a")], "other accounts' conversations are never read")
    }

    func testNoticesWhenTheQuestionIsAnswered() throws {
        let folder = try TemporaryGrokFolder()
        let roster = try folder.writeBlob(key: account + ".roster.last-roster", data: Fixture.data("roster-v4.json"))
        let key = account + ".transcript.replicas.bot-a"
        try folder.writeBlob(key: key, data: transcript([Entry.widget("t1s0")]), modified: date(1_000))
        let store = ConversationStore(paths: folder.paths)
        XCTAssertNotNil(store.openRequests(for: [BotID("bot-a")], rosterFile: roster)[BotID("bot-a")])

        try folder.writeBlob(key: key, data: transcript([Entry.widget("t1s0", extra: #","respondedValue":"porto""#)]), modified: date(2_000))
        XCTAssertNil(store.openRequests(for: [BotID("bot-a")], rosterFile: roster)[BotID("bot-a")])
    }

    func testBotIDsCannotEscapeTheFolder() throws {
        let folder = try TemporaryGrokFolder()
        let roster = try folder.writeBlob(key: account + ".roster.last-roster", data: Fixture.data("roster-v4.json"))
        let url = try XCTUnwrap(ConversationStore(paths: folder.paths).fileURL(for: BotID("../../etc/passwd"), rosterFile: roster))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.paths.persistenceDirectory.standardizedFileURL)
    }
}

final class ConversationAttentionTests: XCTestCase {
    func testConversationQuestionTriggersAttention() throws {
        let bot = Bot(identity: identity("a", "Travel"), hasUnread: true, unreadCount: 2)
        let open = try XCTUnwrap(ConversationRequestParser.openRequest(in: transcript([Entry.widget("t1s0")])))
        let result = AttentionDetector.snapshot(roster: [bot], conversations: [bot.id: open], sidebar: nil, observedAt: date(0))
        XCTAssertEqual(result.attention.count, 1)
        XCTAssertEqual(result.attention.first?.source, .conversation)
        XCTAssertEqual(result.attention.first?.content.choices.map(\.label), ["Lisbon", "Porto"])
    }

    func testRosterPayloadStillWins() throws {
        let bot = Bot(identity: identity("a", "Travel"), awaitingUserResponse: .object(["question": .string("Budget?")]))
        let open = try XCTUnwrap(ConversationRequestParser.openRequest(in: transcript([Entry.widget("t1s0")])))
        let result = AttentionDetector.snapshot(roster: [bot], conversations: [bot.id: open], sidebar: nil, observedAt: date(0))
        XCTAssertEqual(result.attention.map(\.source), [.roster])
    }

    func testHiddenBotsAreIgnored() throws {
        let bot = Bot(identity: identity("a", "Travel"), isHiddenFromSidebar: true)
        let open = try XCTUnwrap(ConversationRequestParser.openRequest(in: transcript([Entry.widget("t1s0")])))
        XCTAssertEqual(AttentionDetector.snapshot(roster: [bot], conversations: [bot.id: open], sidebar: nil, observedAt: date(0)).attention, [])
    }
}
