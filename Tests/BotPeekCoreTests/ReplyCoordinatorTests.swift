import XCTest
@testable import BotPeekCore

@MainActor
final class ReplyCoordinatorTests: XCTestCase {
    let research = identity("r", "Research Bot")
    let travel = identity("t", "Travel Planner")
    let ops = identity("o", "Ops Bot")

    var manager: AttentionEventManager!
    var service: RecordingReplyService!
    var approvalsAllowed = false

    override func setUp() async throws {
        manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        service = RecordingReplyService()
        approvalsAllowed = false
        let approval = AttentionObservation(
            bot: ops,
            fingerprint: "o1",
            content: AttentionContent(kind: .approval, prompt: "Run migration?", choices: [AttentionChoice(label: "Approve"), AttentionChoice(label: "Deny")], source: .roster),
            source: .roster
        )
        manager.ingest(snapshot(at: 0, bots: [research, travel, ops], attention: [
            observation(research, "r1", prompt: "Which vendor?", choices: ["Acme", "Globex"]),
            observation(travel, "t1", prompt: "Budget?"),
            approval,
        ]))
    }

    func coordinator() -> ReplyCoordinator {
        ReplyCoordinator(service: service, manager: manager, allowInlineApprovals: { [unowned self] in approvalsAllowed })
    }

    func id(_ bot: BotIdentity, _ fingerprint: String) -> RequestID { RequestID(botID: bot.id, fingerprint: fingerprint) }

    // MARK: Routing

    func testRepliesReachTheExactBotAndRequest() async {
        let replies = coordinator()
        await replies.send(.text("Under $200"), for: id(travel, "t1"))
        await replies.send(.choice(AttentionChoice(label: "Acme")), for: id(research, "r1"))
        XCTAssertEqual(service.deliveries.map(\.target.bot), [travel, research])
        XCTAssertEqual(service.deliveries.map(\.target.requestID), [id(travel, "t1"), id(research, "r1")])
        XCTAssertEqual(service.deliveries[0].reply, .text("Under $200"))
    }

    func testTextIsTrimmed() async {
        await coordinator().send(.text("  hi there \n"), for: id(travel, "t1"))
        XCTAssertEqual(service.deliveries.first?.reply, .text("hi there"))
    }

    func testVerifiedDeliveryMarksAnswered() async {
        let replies = coordinator()
        let state = await replies.send(.text("ok"), for: id(travel, "t1"))
        guard case .delivered(let receipt) = state else { return XCTFail("expected delivered") }
        XCTAssertTrue(receipt.verified)
        if case .answered = manager.request(id(travel, "t1"))?.status {} else { XCTFail("request should be answered") }
    }

    // MARK: Failures

    func testUnverifiedDeliveryIsNeverReportedAsSent() async {
        service.outcomes = [.unverified]
        let replies = coordinator()
        let state = await replies.send(.text("ok"), for: id(travel, "t1"))
        XCTAssertEqual(state, .failed(.deliveryUnconfirmed))
        XCTAssertEqual(manager.request(id(travel, "t1"))?.status, .pending)
        XCTAssertFalse(ReplyError.deliveryUnconfirmed.isSafeToRetry)
    }

    func testServiceErrorsAreSurfaced() async {
        service.outcomes = [.fail(.grokBotNotRunning)]
        let state = await coordinator().send(.text("ok"), for: id(travel, "t1"))
        XCTAssertEqual(state, .failed(.grokBotNotRunning))
        XCTAssertEqual(manager.request(id(travel, "t1"))?.status, .pending)
    }

    func testPermissionFailure() async {
        service.outcomes = [.fail(.accessibilityPermissionMissing)]
        let replies = coordinator()
        let state = await replies.send(.choice(AttentionChoice(label: "Acme")), for: id(research, "r1"))
        XCTAssertEqual(state, .failed(.accessibilityPermissionMissing))
        XCTAssertTrue(ReplyError.accessibilityPermissionMissing.isSafeToRetry)
        // Retrying after granting permission works.
        let retry = await replies.send(.choice(AttentionChoice(label: "Acme")), for: id(research, "r1"))
        if case .delivered = retry {} else { XCTFail("retry should deliver") }
    }

    // MARK: Validation

    func testRejectsEmptyAndUnknownChoices() async {
        let replies = coordinator()
        let empty = await replies.send(.text("   "), for: id(travel, "t1"))
        XCTAssertEqual(empty, .failed(.emptyMessage))
        let unknown = await replies.send(.choice(AttentionChoice(label: "Initech")), for: id(research, "r1"))
        XCTAssertEqual(unknown, .failed(.choiceNotOffered))
        XCTAssertTrue(service.deliveries.isEmpty, "invalid replies never reach Grok Bot")
    }

    func testRequestAnsweredElsewhereCannotBeSent() async {
        manager.ingest(snapshot(at: 1, bots: [research, travel, ops], attention: []))
        let state = await coordinator().send(.text("late"), for: id(travel, "t1"))
        XCTAssertEqual(state, .failed(.requestNoLongerActive))
        XCTAssertTrue(service.deliveries.isEmpty)
    }

    func testNoDoubleSend() async {
        manager.markReplying(id(travel, "t1"))
        let state = await coordinator().send(.text("again"), for: id(travel, "t1"))
        XCTAssertEqual(state, .failed(.alreadySending))
        XCTAssertTrue(service.deliveries.isEmpty)
    }

    func testApprovalsRequireOptInAndExplicitDecision() async {
        let replies = coordinator()
        let approve = Reply.approval(.approve, option: AttentionChoice(label: "Approve"))
        let notOptedIn = await replies.send(approve, for: id(ops, "o1"))
        XCTAssertEqual(notOptedIn, .failed(.approvalRequiresGrokBot))
        let asChoice = await replies.send(.choice(AttentionChoice(label: "Approve")), for: id(ops, "o1"))
        XCTAssertEqual(asChoice, .failed(.approvalRequiresGrokBot), "approvals can't be smuggled through as a plain choice")
        let asText = await replies.send(.text("yes"), for: id(ops, "o1"))
        XCTAssertEqual(asText, .failed(.approvalRequiresGrokBot))

        approvalsAllowed = true
        let mismatched = Reply.approval(.approve, option: AttentionChoice(label: "Deny"))
        let mismatchedState = await replies.send(mismatched, for: id(ops, "o1"))
        XCTAssertEqual(mismatchedState, .failed(.choiceNotOffered), "decision must match the button pressed")
        if case .delivered = await replies.send(approve, for: id(ops, "o1")) {} else { XCTFail("opted-in approval should deliver") }
        XCTAssertEqual(service.deliveries.count, 1)
    }

    func testApprovalsBlockedWhenServiceCannotDoThem() async {
        approvalsAllowed = true
        service.capabilities = ReplyCapabilities(text: true, choices: true, approvals: false)
        let state = await coordinator().send(.approval(.deny, option: AttentionChoice(label: "Deny")), for: id(ops, "o1"))
        XCTAssertEqual(state, .failed(.approvalRequiresGrokBot))
    }

    func testGrokBotOnlyRequestsRejectEveryReply() async {
        approvalsAllowed = true
        let form = AttentionObservation(
            bot: research, fingerprint: "r2",
            content: AttentionContent(kind: .handoff, prompt: "Hasło", choices: [AttentionChoice(label: "Dalej")], source: .conversation,
                                      grokBotOnlyReason: "Fill this in securely in Grok Bot."),
            source: .conversation
        )
        let approval = AttentionObservation(
            bot: travel, fingerprint: "t2",
            content: AttentionContent(kind: .approval, prompt: "Run it?", choices: [AttentionChoice(label: "Approve"), AttentionChoice(label: "Deny")],
                                      source: .conversation, grokBotOnlyReason: "Review this approval in Grok Bot."),
            source: .conversation
        )
        manager.ingest(snapshot(at: 1, bots: [research, travel, ops], attention: [form, approval]))
        let replies = coordinator()
        let replyCases: [(Reply, RequestID)] = [
            (.text("sekret123"), id(research, "r2")),
            (.choice(AttentionChoice(label: "Dalej")), id(research, "r2")),
            (.approval(.approve, option: AttentionChoice(label: "Approve")), id(travel, "t2")),
            (.choice(AttentionChoice(label: "Approve")), id(travel, "t2")),
        ]
        for (reply, requestID) in replyCases {
            let state = await replies.send(reply, for: requestID)
            XCTAssertEqual(state, .failed(.approvalRequiresGrokBot), reply.logDescription)
        }
        XCTAssertTrue(service.deliveries.isEmpty, "Grok Bot-only requests are answered only in Grok Bot")
    }

    func testStateChangesAreReported() async {
        let replies = coordinator()
        var seen: [DeliveryState] = []
        replies.onStateChange = { _, state in seen.append(state) }
        await replies.send(.text("ok"), for: id(travel, "t1"))
        XCTAssertEqual(seen.first, .sending)
        if case .delivered = seen.last {} else { XCTFail("ends delivered") }
    }
}
