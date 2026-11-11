import Foundation

/// Validates replies, routes them to the right bot, and tracks delivery.
@MainActor
public final class ReplyCoordinator {
    public static let maximumTextLength = 8_000

    private let service: ReplyService
    private let manager: AttentionEventManager
    private let allowInlineApprovals: () -> Bool
    private let clock: () -> Date
    private let log: DiagnosticsLog?

    public private(set) var states: [RequestID: DeliveryState] = [:]
    public var onStateChange: ((RequestID, DeliveryState) -> Void)?

    public init(
        service: ReplyService,
        manager: AttentionEventManager,
        allowInlineApprovals: @escaping () -> Bool,
        clock: @escaping () -> Date = Date.init,
        log: DiagnosticsLog? = nil
    ) {
        self.service = service
        self.manager = manager
        self.allowInlineApprovals = allowInlineApprovals
        self.clock = clock
        self.log = log
    }

    public var capabilities: ReplyCapabilities { service.capabilities }

    public func state(for id: RequestID) -> DeliveryState {
        states[id] ?? .idle
    }

    /// Whether approve/deny can be done inline for this request.
    public func canApproveInline(_ request: AttentionRequest) -> Bool {
        request.content.kind == .approval && allowInlineApprovals() && service.capabilities.approvals
    }

    public func validate(_ reply: Reply, for request: AttentionRequest?) -> ReplyError? {
        guard let request else { return .requestNoLongerActive }
        if case .answered = request.status { return .requestNoLongerActive }
        if states[request.id] == .sending || request.status == .replying { return .alreadySending }
        // Answered only in Grok Bot itself (cached approvals, forms), whatever the view offers.
        if request.content.grokBotOnlyReason != nil { return .approvalRequiresGrokBot }
        switch reply {
        case .text(let text):
            guard service.capabilities.text else { return .unsupported }
            if request.content.kind == .approval { return .approvalRequiresGrokBot }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .emptyMessage }
            if trimmed.count > Self.maximumTextLength { return .messageTooLong(limit: Self.maximumTextLength) }
        case .choice(let choice):
            guard service.capabilities.choices else { return .unsupported }
            if request.content.kind == .approval { return .approvalRequiresGrokBot }
            if !request.content.choices.contains(where: { $0.label == choice.label }) { return .choiceNotOffered }
        case .approval(let decision, let option):
            guard canApproveInline(request) else { return .approvalRequiresGrokBot }
            guard request.content.choices.contains(where: { $0.label == option.label }) else { return .choiceNotOffered }
            let matchesDecision = decision == .approve
                ? ApprovalHeuristics.isApproveLabel(option.label)
                : ApprovalHeuristics.isDenyLabel(option.label)
            if !matchesDecision { return .choiceNotOffered }
        }
        return nil
    }

    /// Sends a reply. Returns the final state. Never reports `.delivered`
    /// unless the reply service verified that the reply reached Grok Bot.
    @discardableResult
    public func send(_ reply: Reply, for id: RequestID) async -> DeliveryState {
        let request = manager.request(id)
        if let error = validate(reply, for: request) {
            // Don't overwrite an in-flight send with a validation error.
            if error != .alreadySending { setState(.failed(error), for: id) }
            log?.record(.warning, "reply", "Rejected \(reply.logDescription) for \(id): \(error)")
            return .failed(error)
        }
        guard let request else { return .failed(.requestNoLongerActive) }

        let normalized: Reply
        if case .text(let text) = reply {
            normalized = .text(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            normalized = reply
        }

        manager.markReplying(id)
        setState(.sending, for: id)
        log?.record(.info, "reply", "Sending \(normalized.logDescription) to \(id)")

        let target = ReplyTarget(requestID: id, bot: request.bot, content: request.content)
        do {
            let receipt = try await service.deliver(normalized, to: target)
            guard receipt.verified else {
                manager.markReplyFailed(id)
                setState(.failed(.deliveryUnconfirmed), for: id)
                log?.record(.warning, "reply", "Delivery to \(id) could not be confirmed (\(receipt.method))")
                return .failed(.deliveryUnconfirmed)
            }
            manager.markAnswered(id, at: receipt.completedAt)
            setState(.delivered(receipt), for: id)
            log?.record(.info, "reply", "Delivered to \(id) via \(receipt.method)")
            return .delivered(receipt)
        } catch {
            let replyError = (error as? ReplyError) ?? .other(String(describing: error))
            manager.markReplyFailed(id)
            setState(.failed(replyError), for: id)
            log?.record(.error, "reply", "Delivery to \(id) failed: \(replyError)")
            return .failed(replyError)
        }
    }

    public func clearState(for id: RequestID) {
        states[id] = nil
    }

    private func setState(_ state: DeliveryState, for id: RequestID) {
        states[id] = state
        onStateChange?(id, state)
    }
}
