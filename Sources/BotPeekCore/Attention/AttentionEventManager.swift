import Foundation

public struct AttentionRequest: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Waiting to be shown or currently shown.
        case pending
        /// Hidden until the date, then shown again if still unanswered.
        case snoozed(until: Date)
        /// Hidden by the user. Still listed in the menu bar; never popped again.
        case dismissed
        /// A reply is being delivered.
        case replying
        /// Delivered from BotPeek; waiting for Grok Bot to clear the request.
        case answered(at: Date)
    }

    public var id: RequestID
    public var bot: BotIdentity
    public var content: AttentionContent
    public var source: AttentionSource
    public var firstSeen: Date
    public var lastSeen: Date
    /// When this request last arrived for the user: first appearance, a new
    /// question from the same bot, or a snooze running out. The queue shows
    /// the most recent arrival first.
    public var queuedAt: Date
    public var status: Status

    public var botID: BotID { bot.id }

    /// Whether this request should be on screen as a character.
    public var isPresentable: Bool {
        switch status {
        case .pending, .replying: return true
        case .snoozed, .dismissed, .answered: return false
        }
    }
}

public enum ResolutionReason: String, Equatable, Sendable {
    /// Answered through BotPeek, and Grok Bot has confirmed it.
    case answeredHere
    /// The request disappeared without a reply from BotPeek: answered in
    /// Grok Bot, on another device, or withdrawn by the bot.
    case answeredElsewhere
    /// The bot no longer exists in the roster.
    case botRemoved
}

public enum AttentionEvent: Equatable, Sendable {
    case appeared(AttentionRequest)
    case updated(AttentionRequest)
    /// The same bot is now asking something else (or the same thing, read
    /// from a better source). The UI swaps content in place.
    case replaced(old: RequestID, new: AttentionRequest)
    case resolved(RequestID, ResolutionReason)
}

/// Remembers requests the user dismissed, by hash only, across restarts.
public protocol DismissedRequestStore: AnyObject {
    func contains(_ id: RequestID) -> Bool
    func insert(_ id: RequestID, at date: Date)
    func prune(olderThan date: Date)
}

/// Turns a stream of status snapshots into a stable queue of requests.
///
/// Guarantees:
/// - A request appears once per bot and question (deduplicated by fingerprint).
/// - A new signal must persist for `confirmationDelay` before it appears.
/// - Requests disappear when Grok Bot stops reporting them (answered elsewhere),
///   but never because of an incomplete read or during the grace period after wake.
/// - Dismissed or snoozed requests are kept, not lost.
public final class AttentionEventManager {
    public struct Configuration: Sendable {
        public var confirmationDelay: TimeInterval
        public var wakeGracePeriod: TimeInterval
        public var dismissedMemory: TimeInterval

        public init(confirmationDelay: TimeInterval = 0.5, wakeGracePeriod: TimeInterval = 8, dismissedMemory: TimeInterval = 7 * 24 * 3_600) {
            self.confirmationDelay = confirmationDelay
            self.wakeGracePeriod = wakeGracePeriod
            self.dismissedMemory = dismissedMemory
        }
    }

    public let configuration: Configuration
    public private(set) var requests: [AttentionRequest] = []
    private var candidates: [BotID: AttentionRequest] = [:]
    private var graceUntil: Date?
    private let dismissedStore: DismissedRequestStore?

    public init(configuration: Configuration = .init(), dismissedStore: DismissedRequestStore? = nil) {
        self.configuration = configuration
        self.dismissedStore = dismissedStore
    }

    /// Requests to show, newest arrival first.
    public var presentable: [AttentionRequest] { RequestQueue.ordered(requests.filter(\.isPresentable)) }

    public func request(_ id: RequestID) -> AttentionRequest? {
        requests.first { $0.id == id }
    }

    public func request(forBot botID: BotID) -> AttentionRequest? {
        requests.first { $0.botID == botID }
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(_ snapshot: StatusSnapshot) -> [AttentionEvent] {
        let now = snapshot.observedAt
        let inGrace = graceUntil.map { now < $0 } ?? false
        if let graceUntil, now >= graceUntil { self.graceUntil = nil }

        var observed: [BotID: AttentionObservation] = [:]
        // Observations from Grok Bot's data win over Accessibility ones for the same bot.
        for observation in snapshot.attention where observed[observation.bot.id].map({ rank($0.source) > rank(observation.source) }) ?? true {
            observed[observation.bot.id] = observation
        }
        // Snapshot order, one entry per bot, so new requests queue deterministically.
        var orderedBots: [BotID] = []
        for observation in snapshot.attention where !orderedBots.contains(observation.bot.id) {
            orderedBots.append(observation.bot.id)
        }
        let knownBots = Set(snapshot.bots.map(\.id))
        var events: [AttentionEvent] = []
        var handledBots = Set<BotID>()

        for index in requests.indices.reversed() {
            let request = requests[index]
            if let observation = observed[request.botID] {
                handledBots.insert(request.botID)
                if observation.fingerprint == request.id.fingerprint {
                    var updated = request
                    updated.lastSeen = now
                    updated.bot = observation.bot
                    if observation.content.hasReadableContent || !request.content.hasReadableContent {
                        updated.content = observation.content
                    }
                    requests[index] = updated
                    if updated.bot != request.bot || updated.content != request.content {
                        events.append(.updated(updated))
                    }
                } else if case .answered = request.status {
                    // The question we answered is gone; a new one follows.
                    requests.remove(at: index)
                    events.append(.resolved(request.id, .answeredHere))
                    handledBots.remove(request.botID)
                } else {
                    let replacement = AttentionRequest(
                        id: RequestID(botID: request.botID, fingerprint: observation.fingerprint),
                        bot: observation.bot,
                        content: observation.content.hasReadableContent || observation.source.isFromGrokBotData
                            ? observation.content : request.content,
                        source: observation.source,
                        firstSeen: request.firstSeen,
                        lastSeen: now,
                        queuedAt: now,
                        status: request.status == .dismissed && !observation.source.isFromGrokBotData ? .dismissed : .pending
                    )
                    requests[index] = replacement
                    events.append(.replaced(old: request.id, new: replacement))
                }
            } else if snapshot.isComplete && !inGrace {
                requests.remove(at: index)
                let reason: ResolutionReason
                if !knownBots.contains(request.botID) {
                    reason = .botRemoved
                } else {
                    switch request.status {
                    case .answered, .replying: reason = .answeredHere
                    default: reason = .answeredElsewhere
                    }
                }
                events.append(.resolved(request.id, reason))
            }
        }
        // Events above were collected newest-first; report in queue order.
        events.reverse()

        for botID in orderedBots where !handledBots.contains(botID) {
            guard let observation = observed[botID] else { continue }
            var candidate = candidates[botID]
            if candidate?.id.fingerprint != observation.fingerprint {
                candidate = AttentionRequest(
                    id: RequestID(botID: botID, fingerprint: observation.fingerprint),
                    bot: observation.bot,
                    content: observation.content,
                    source: observation.source,
                    firstSeen: now,
                    lastSeen: now,
                    queuedAt: now,
                    status: .pending
                )
            }
            guard var confirmed = candidate else { continue }
            confirmed.lastSeen = now
            confirmed.bot = observation.bot
            confirmed.content = observation.content
            confirmed.queuedAt = now
            let age = now.timeIntervalSince(confirmed.firstSeen)
            if !inGrace, age >= confirmationDelay(for: observation.source) {
                candidates[botID] = nil
                if dismissedStore?.contains(confirmed.id) == true {
                    confirmed.status = .dismissed
                }
                requests.append(confirmed)
                events.append(.appeared(confirmed))
            } else {
                candidates[botID] = confirmed
            }
        }
        if snapshot.isComplete {
            candidates = candidates.filter { observed[$0.key] != nil }
        }
        return events
    }

    /// A question in a cached conversation is already settled: Grok Bot saves
    /// it a couple of seconds after the bot posts it. Waiting again would only
    /// delay it, so it appears on the first read. Other signals must persist.
    private func confirmationDelay(for source: AttentionSource) -> TimeInterval {
        source == .conversation ? 0 : configuration.confirmationDelay
    }

    /// When a signal seen but not yet shown will have been confirmed, so the
    /// caller can read again right then instead of waiting for its next poll.
    public var nextConfirmationAt: Date? {
        candidates.values.map { $0.firstSeen.addingTimeInterval(confirmationDelay(for: $0.source)) }.min()
    }

    private func rank(_ source: AttentionSource) -> Int {
        switch source {
        case .roster, .conversation, .demo: return 0
        case .accessibility: return 1
        }
    }

    // MARK: - System events

    /// After wake, Grok Bot's caches and UI may briefly show stale state.
    /// Nothing new appears and nothing is resolved until the grace period ends.
    public func systemDidWake(at date: Date) {
        graceUntil = date.addingTimeInterval(configuration.wakeGracePeriod)
        candidates.removeAll()
    }

    public var isInWakeGracePeriod: Bool { graceUntil != nil }

    /// Wakes snoozed requests whose time is up.
    @discardableResult
    public func tick(now: Date) -> [AttentionEvent] {
        var events: [AttentionEvent] = []
        for index in requests.indices {
            if case .snoozed(let until) = requests[index].status, until <= now {
                requests[index].status = .pending
                requests[index].queuedAt = now
                events.append(.updated(requests[index]))
            }
        }
        return events
    }

    // MARK: - User actions

    @discardableResult
    public func snooze(_ id: RequestID, until date: Date) -> AttentionRequest? {
        setStatus(.snoozed(until: date), for: id)
    }

    @discardableResult
    public func snoozeAll(until date: Date) -> [AttentionRequest] {
        presentable.compactMap { snooze($0.id, until: date) }
    }

    @discardableResult
    public func dismiss(_ id: RequestID, at date: Date) -> AttentionRequest? {
        dismissedStore?.insert(id, at: date)
        dismissedStore?.prune(olderThan: date.addingTimeInterval(-configuration.dismissedMemory))
        return setStatus(.dismissed, for: id)
    }

    /// Brings back a snoozed or dismissed request (from the menu bar).
    @discardableResult
    public func restore(_ id: RequestID) -> AttentionRequest? {
        guard let request = request(id) else { return nil }
        switch request.status {
        case .snoozed, .dismissed:
            guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
            requests[index].status = .pending
            requests[index].queuedAt = Date()
            return requests[index]
        default: return request
        }
    }

    /// Replaces a request's content with a better reading, e.g. the question
    /// text read from the conversation when the roster had no details.
    ///
    /// A reading never lifts a request's "Grok Bot only" lock and never turns an
    /// approval or a handoff into a plain choice: those come from Grok Bot's own
    /// data, a window reading only guesses from button labels.
    @discardableResult
    public func updateContent(_ id: RequestID, _ content: AttentionContent) -> AttentionRequest? {
        guard let index = requests.firstIndex(where: { $0.id == id }), content.hasReadableContent else { return request(id) }
        let previous = requests[index].content
        var content = content
        if content.grokBotOnlyReason == nil { content.grokBotOnlyReason = previous.grokBotOnlyReason }
        if previous.kind == .approval || previous.kind == .handoff { content.kind = previous.kind }
        requests[index].content = content
        return requests[index]
    }

    @discardableResult
    public func markReplying(_ id: RequestID) -> AttentionRequest? {
        setStatus(.replying, for: id)
    }

    @discardableResult
    public func markAnswered(_ id: RequestID, at date: Date) -> AttentionRequest? {
        setStatus(.answered(at: date), for: id)
    }

    @discardableResult
    public func markReplyFailed(_ id: RequestID) -> AttentionRequest? {
        guard request(id)?.status == .replying else { return request(id) }
        return setStatus(.pending, for: id)
    }

    private func setStatus(_ status: AttentionRequest.Status, for id: RequestID) -> AttentionRequest? {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
        requests[index].status = status
        return requests[index]
    }

    /// Forgets everything, e.g. when switching between demo and live mode.
    public func reset() {
        requests.removeAll()
        candidates.removeAll()
        graceUntil = nil
    }
}

/// Navigation through the presentable queue.
public enum RequestQueue {
    /// Newest arrival first. Requests that arrived in the same read keep the
    /// reverse of their snapshot order, so the last one reported leads.
    public static func ordered(_ requests: [AttentionRequest]) -> [AttentionRequest] {
        requests.enumerated()
            .sorted { $0.element.queuedAt != $1.element.queuedAt ? $0.element.queuedAt > $1.element.queuedAt : $0.offset > $1.offset }
            .map(\.element)
    }

    public static func current(in presentable: [AttentionRequest], preferred: RequestID?) -> AttentionRequest? {
        if let preferred, let match = presentable.first(where: { $0.id == preferred }) { return match }
        return presentable.first
    }

    public static func position(of id: RequestID, in presentable: [AttentionRequest]) -> (index: Int, count: Int)? {
        guard let index = presentable.firstIndex(where: { $0.id == id }) else { return nil }
        return (index, presentable.count)
    }

    public static func next(after id: RequestID, in presentable: [AttentionRequest]) -> RequestID? {
        guard !presentable.isEmpty else { return nil }
        guard let index = presentable.firstIndex(where: { $0.id == id }) else { return presentable.first?.id }
        return presentable[(index + 1) % presentable.count].id
    }

    public static func previous(before id: RequestID, in presentable: [AttentionRequest]) -> RequestID? {
        guard !presentable.isEmpty else { return nil }
        guard let index = presentable.firstIndex(where: { $0.id == id }) else { return presentable.first?.id }
        return presentable[(index - 1 + presentable.count) % presentable.count].id
    }
}

/// Short, human wording for how long a bot has been waiting.
public enum WaitTime {
    public static func describe(since start: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        switch minutes {
        case 0: return "just now"
        case 1..<60: return "\(minutes) min"
        case 60..<(24 * 60):
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
        default:
            let days = minutes / (24 * 60)
            return days == 1 ? "1 day" : "\(days) days"
        }
    }
}
