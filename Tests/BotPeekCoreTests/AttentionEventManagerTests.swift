import XCTest
@testable import BotPeekCore

final class AttentionEventManagerTests: XCTestCase {
    let research = identity("r", "Research Bot", shape: "cloud", color: "blue")
    let travel = identity("t", "Travel Planner", shape: "sparkle", color: "purple")
    let ops = identity("o", "Ops Bot")

    func makeManager(delay: TimeInterval = 0.5, store: DismissedRequestStore? = nil) -> AttentionEventManager {
        AttentionEventManager(configuration: .init(confirmationDelay: delay, wakeGracePeriod: 8), dismissedStore: store)
    }

    // MARK: Transitions

    func testSignalMustPersistBeforeAppearing() {
        let manager = makeManager()
        let obs = observation(research, "f1")
        XCTAssertTrue(manager.ingest(snapshot(at: 0, bots: [research], attention: [obs])).isEmpty, "first sighting is unconfirmed")
        let events = manager.ingest(snapshot(at: 1, bots: [research], attention: [obs]))
        XCTAssertEqual(events.count, 1)
        guard case .appeared(let request) = events.first else { return XCTFail("expected appeared") }
        XCTAssertEqual(request.bot, research)
        XCTAssertEqual(request.firstSeen, date(0))
    }

    func testFlickerNeverAppears() {
        let manager = makeManager()
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        manager.ingest(snapshot(at: 0.2, bots: [research], attention: []))
        let events = manager.ingest(snapshot(at: 1, bots: [research], attention: [observation(research, "f1")]))
        XCTAssertTrue(events.isEmpty, "a signal that disappeared restarts confirmation")
        XCTAssertTrue(manager.requests.isEmpty)
    }

    func testConversationQuestionAppearsOnFirstRead() {
        let manager = makeManager()
        let events = manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1", source: .conversation)]))
        XCTAssertEqual(events.count, 1, "a saved conversation question is already settled")
        XCTAssertNil(manager.nextConfirmationAt)
    }

    func testReportsWhenPendingSignalWillBeConfirmed() {
        let manager = makeManager()
        XCTAssertNil(manager.nextConfirmationAt)
        manager.ingest(snapshot(at: 10, bots: [research], attention: [observation(research, "f1", source: .accessibility)]))
        XCTAssertEqual(manager.nextConfirmationAt, date(10.5))
        manager.ingest(snapshot(at: 10.5, bots: [research], attention: [observation(research, "f1", source: .accessibility)]))
        XCTAssertNil(manager.nextConfirmationAt)
        XCTAssertEqual(manager.requests.count, 1)
    }

    func testWakeGraceStillHoldsConversationQuestions() {
        let manager = makeManager()
        manager.systemDidWake(at: date(0))
        XCTAssertTrue(manager.ingest(snapshot(at: 1, bots: [research], attention: [observation(research, "f1", source: .conversation)])).isEmpty)
        XCTAssertEqual(manager.ingest(snapshot(at: 9, bots: [research], attention: [observation(research, "f1", source: .conversation)])).count, 1)
    }

    func testDeduplicatesRepeatedSnapshots() {
        let manager = makeManager(delay: 0)
        var appeared = 0
        for second in 0..<10 {
            let events = manager.ingest(snapshot(at: Double(second), bots: [research], attention: [observation(research, "f1")]))
            appeared += events.filter { if case .appeared = $0 { return true } else { return false } }.count
        }
        XCTAssertEqual(appeared, 1)
        XCTAssertEqual(manager.requests.count, 1)
    }

    func testAnsweredElsewhereResolves() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let events = manager.ingest(snapshot(at: 5, bots: [research], attention: []))
        XCTAssertEqual(events, [.resolved(RequestID(botID: research.id, fingerprint: "f1"), .answeredElsewhere)])
        XCTAssertTrue(manager.requests.isEmpty)
    }

    func testAnsweredHereResolvesAsAnsweredHere() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        manager.markReplying(id)
        manager.markAnswered(id, at: date(1))
        // Grok Bot may lag; the request stays but is no longer on screen.
        XCTAssertTrue(manager.ingest(snapshot(at: 2, bots: [research], attention: [observation(research, "f1")])).isEmpty)
        XCTAssertTrue(manager.presentable.isEmpty)
        XCTAssertEqual(manager.ingest(snapshot(at: 3, bots: [research], attention: [])), [.resolved(id, .answeredHere)])
    }

    func testBotDeletion() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let events = manager.ingest(snapshot(at: 1, bots: [], attention: []))
        XCTAssertEqual(events, [.resolved(RequestID(botID: research.id, fingerprint: "f1"), .botRemoved)])
    }

    func testNewQuestionFromSameBotReplacesInPlace() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research, travel], attention: [observation(research, "f1"), observation(travel, "t1")]))
        let events = manager.ingest(snapshot(at: 1, bots: [research, travel], attention: [observation(research, "f2", prompt: "Another?"), observation(travel, "t1")]))
        guard case .replaced(let old, let new) = events.first else { return XCTFail("expected replacement, got \(events)") }
        XCTAssertEqual(old.fingerprint, "f1")
        XCTAssertEqual(new.id.fingerprint, "f2")
        XCTAssertEqual(manager.requests.map(\.bot.name), ["Research Bot", "Travel Planner"], "queue order is preserved")
    }

    func testRenamedOrRestyledBotUpdatesIdentity() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        var renamed = research
        renamed.name = "Vendor Scout"
        renamed.avatar = AvatarDescriptor(rawShape: "gem", rawColor: "red")
        let events = manager.ingest(snapshot(at: 1, bots: [renamed], attention: [observation(renamed, "f1")]))
        guard case .updated(let request) = events.first else { return XCTFail("expected update") }
        XCTAssertEqual(request.bot.name, "Vendor Scout")
        XCTAssertEqual(request.bot.avatar.shape, .gem)
    }

    // MARK: Reliability

    func testIncompleteSnapshotNeverResolves() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        XCTAssertTrue(manager.ingest(.incomplete(at: date(1))).isEmpty, "unreadable roster must not hide a real question")
        XCTAssertEqual(manager.requests.count, 1)
    }

    func testWakeGraceSuppressesChangesThenResumes() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        manager.systemDidWake(at: date(100))
        // Stale state right after wake: nothing new, nothing resolved.
        XCTAssertTrue(manager.ingest(snapshot(at: 101, bots: [research, travel], attention: [observation(travel, "t1")])).isEmpty)
        XCTAssertEqual(manager.requests.map(\.bot.name), ["Research Bot"])
        // After the grace period the real state applies.
        let events = manager.ingest(snapshot(at: 109, bots: [research, travel], attention: [observation(travel, "t1")]))
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains(.resolved(RequestID(botID: research.id, fingerprint: "f1"), .answeredElsewhere)))
        XCTAssertFalse(manager.isInWakeGracePeriod)
    }

    func testReconnectAfterGrokBotRestartKeepsRequests() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        // Grok Bot quits: roster temporarily unreadable.
        manager.ingest(.incomplete(at: date(5)))
        manager.ingest(.incomplete(at: date(10)))
        // Grok Bot is back with the same question pending.
        let events = manager.ingest(snapshot(at: 15, bots: [research], attention: [observation(research, "f1")]))
        XCTAssertTrue(events.isEmpty, "no duplicate popup after reconnecting")
        XCTAssertEqual(manager.requests.count, 1)
    }

    // MARK: User actions

    func testSnoozeHidesThenReturns() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        manager.snooze(id, until: date(60))
        XCTAssertTrue(manager.presentable.isEmpty)
        XCTAssertTrue(manager.tick(now: date(30)).isEmpty)
        XCTAssertEqual(manager.tick(now: date(61)).count, 1)
        XCTAssertEqual(manager.presentable.map(\.id), [id])
    }

    func testDismissKeepsRequestAndSurvivesRestart() {
        let store = PersistentDismissedStore(store: InMemoryKeyValueStore())
        let first = makeManager(delay: 0, store: store)
        first.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        first.dismiss(id, at: date(1))
        XCTAssertEqual(first.requests.count, 1, "dismissed requests are kept in the menu, not lost")
        XCTAssertTrue(first.presentable.isEmpty)

        // BotPeek restarts: the same question must not pop up again…
        let second = makeManager(delay: 0, store: store)
        second.ingest(snapshot(at: 10, bots: [research], attention: [observation(research, "f1")]))
        XCTAssertEqual(second.requests.first?.status, .dismissed)
        // …but a new question from the same bot does.
        second.ingest(snapshot(at: 11, bots: [research], attention: [observation(research, "f2")]))
        XCTAssertEqual(second.presentable.map(\.id.fingerprint), ["f2"])
    }

    func testRestoreBringsBackDismissed() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        manager.dismiss(id, at: date(1))
        manager.restore(id)
        XCTAssertEqual(manager.presentable.map(\.id), [id])
    }

    func testFailedReplyReturnsToPending() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1")]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        manager.markReplying(id)
        manager.markReplyFailed(id)
        XCTAssertEqual(manager.request(id)?.status, .pending)
    }

    // MARK: Grok Bot-only requests

    /// An approval without a summary and a form without a title, as read from
    /// Grok Bot's cached conversation, then read again from its window.
    func testGrokBotOnlyRequestsKeepTheirLockAfterAWindowReading() {
        let cases: [(AttentionKind, String)] = [
            (.approval, "Review this approval in Grok Bot."),
            (.handoff, "Fill this in securely in Grok Bot."),
        ]
        for (kind, reason) in cases {
            let manager = makeManager(delay: 0)
            let cached = AttentionObservation(
                bot: ops, fingerprint: "o1",
                content: AttentionContent(kind: kind, prompt: nil, source: .conversation, grokBotOnlyReason: reason),
                source: .conversation
            )
            manager.ingest(snapshot(at: 0, bots: [ops], attention: [cached]))
            let id = RequestID(botID: ops.id, fingerprint: "o1")
            XCTAssertFalse(manager.request(id)!.content.hasReadableContent)

            let fromWindow = AttentionContent(
                kind: .choice, prompt: "Uruchomić?",
                choices: [AttentionChoice(label: "Tak"), AttentionChoice(label: "Nie")], source: .transcript
            )
            manager.updateContent(id, fromWindow)
            XCTAssertEqual(manager.request(id)?.content.grokBotOnlyReason, reason, "\(kind)")
            XCTAssertEqual(manager.request(id)?.content.kind, kind, "never lowered to a plain choice")

            // The next read of the cache doesn't lose it either.
            manager.ingest(snapshot(at: 1, bots: [ops], attention: [cached]))
            XCTAssertEqual(manager.request(id)?.content.grokBotOnlyReason, reason, "\(kind)")
            XCTAssertEqual(manager.request(id)?.content.kind, kind)
        }
    }

    func testWindowReadingStillFillsInOrdinaryRequests() {
        let manager = makeManager(delay: 0)
        manager.ingest(snapshot(at: 0, bots: [research], attention: [observation(research, "f1", prompt: nil)]))
        let id = RequestID(botID: research.id, fingerprint: "f1")
        manager.updateContent(id, AttentionContent(kind: .choice, prompt: "Który?", choices: [AttentionChoice(label: "Acme")], source: .transcript))
        XCTAssertEqual(manager.request(id)?.content.kind, .choice)
        XCTAssertEqual(manager.request(id)?.content.prompt, "Który?")
        XCTAssertNil(manager.request(id)?.content.grokBotOnlyReason)
    }
}

final class MultiBotQueueTests: XCTestCase {
    let bots = (1...3).map { identity("b\($0)", "Bot \($0)") }

    func testQueueIsNewestFirstAndNavigable() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        for index in bots.indices {
            manager.ingest(snapshot(at: Double(index), bots: bots, attention: bots[...index].map { observation($0, "f-" + $0.id.rawValue) }))
        }
        let queue = manager.presentable
        XCTAssertEqual(queue.map(\.bot.name), ["Bot 3", "Bot 2", "Bot 1"])
        XCTAssertEqual(RequestQueue.current(in: queue, preferred: nil)?.bot.name, "Bot 3", "the newest request leads")
        XCTAssertEqual(RequestQueue.next(after: queue[2].id, in: queue), queue[0].id, "wraps around")
        XCTAssertEqual(RequestQueue.previous(before: queue[0].id, in: queue), queue[2].id)
        XCTAssertEqual(RequestQueue.position(of: queue[1].id, in: queue)?.index, 1)
        XCTAssertEqual(RequestQueue.current(in: queue, preferred: queue[1].id)?.bot.name, "Bot 2")
    }

    func testNewQuestionFromWaitingBotMovesToFront() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        manager.ingest(snapshot(at: 0, bots: bots, attention: [observation(bots[0], "a")]))
        manager.ingest(snapshot(at: 1, bots: bots, attention: [observation(bots[0], "a"), observation(bots[1], "a")]))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 2", "Bot 1"])
        manager.ingest(snapshot(at: 2, bots: bots, attention: [observation(bots[0], "b"), observation(bots[1], "a")]))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 1", "Bot 2"], "a new question is a new arrival")
        XCTAssertEqual(manager.presentable.first?.firstSeen, date(0), "but the bot has been waiting since its first question")
    }

    func testSnoozeEndingMovesToFront() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        manager.ingest(snapshot(at: 0, bots: bots, attention: [observation(bots[0], "a")]))
        let first = RequestID(botID: bots[0].id, fingerprint: "a")
        manager.snooze(first, until: date(10))
        manager.ingest(snapshot(at: 5, bots: bots, attention: [observation(bots[0], "a"), observation(bots[1], "a")]))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 2"])
        manager.tick(now: date(11))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 1", "Bot 2"])
    }

    func testRequestsFromOneReadLeadWithTheLastReported() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        manager.ingest(snapshot(at: 0, bots: bots, attention: bots.map { observation($0, "f") }))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 3", "Bot 2", "Bot 1"])
    }

    func testEachRequestKeepsItsOwnIdentity() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        let attention = bots.map { observation($0, "f-" + $0.id.rawValue, prompt: "Question for \($0.name)") }
        manager.ingest(snapshot(at: 0, bots: bots, attention: attention))
        for request in manager.presentable {
            XCTAssertEqual(request.content.prompt, "Question for \(request.bot.name)")
            XCTAssertEqual(request.id.botID, request.bot.id)
        }
    }

    func testAnsweringOneLeavesOthers() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        manager.ingest(snapshot(at: 0, bots: bots, attention: bots.map { observation($0, "f") }))
        manager.ingest(snapshot(at: 1, bots: bots, attention: [observation(bots[0], "f"), observation(bots[2], "f")]))
        XCTAssertEqual(manager.presentable.map(\.bot.name), ["Bot 3", "Bot 1"])
    }

    func testCurrentFallsBackWhenPreferredIsGone() {
        let manager = AttentionEventManager(configuration: .init(confirmationDelay: 0))
        manager.ingest(snapshot(at: 0, bots: bots, attention: bots.map { observation($0, "f") }))
        let gone = RequestID(botID: BotID("missing"), fingerprint: "x")
        XCTAssertEqual(RequestQueue.current(in: manager.presentable, preferred: gone)?.bot.name, "Bot 3")
    }
}

final class WaitTimeTests: XCTestCase {
    func testWording() {
        XCTAssertEqual(WaitTime.describe(since: date(0), now: date(30)), "just now")
        XCTAssertEqual(WaitTime.describe(since: date(0), now: date(5 * 60 + 10)), "5 min")
        XCTAssertEqual(WaitTime.describe(since: date(0), now: date(2 * 3_600)), "2 h")
        XCTAssertEqual(WaitTime.describe(since: date(0), now: date(3_600 + 7 * 60)), "1 h 7 min")
        XCTAssertEqual(WaitTime.describe(since: date(0), now: date(26 * 3_600)), "1 day")
        XCTAssertEqual(WaitTime.describe(since: date(10), now: date(0)), "just now", "clock skew never goes negative")
    }
}
