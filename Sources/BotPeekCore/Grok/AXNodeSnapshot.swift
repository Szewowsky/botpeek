import Foundation

/// A platform-independent copy of part of an Accessibility tree.
///
/// The macOS layer walks Grok Bot's live `AXUIElement` tree once, copies the
/// attributes BotPeek needs into these values, and keeps a side table from
/// `id` back to the live element. All interpretation happens on these plain
/// values, which keeps the logic testable on any platform.
public struct AXNodeSnapshot: Equatable, Sendable {
    public var id: Int
    public var role: String
    /// `AXTitle`
    public var title: String?
    /// `AXDescription`
    public var axDescription: String?
    /// `AXValue` when it is a string.
    public var value: String?
    public var children: [AXNodeSnapshot]

    public init(
        id: Int,
        role: String,
        title: String? = nil,
        axDescription: String? = nil,
        value: String? = nil,
        children: [AXNodeSnapshot] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.axDescription = axDescription
        self.value = value
        self.children = children
    }

    /// The accessible name: the title, else the description.
    public var label: String {
        if let title, !title.isEmpty { return title }
        return axDescription ?? ""
    }

    /// Breadth-first search for the first node matching `predicate`.
    public func first(maxDepth: Int = 40, where predicate: (AXNodeSnapshot) -> Bool) -> AXNodeSnapshot? {
        var level: [AXNodeSnapshot] = [self]
        var depth = 0
        while !level.isEmpty, depth <= maxDepth {
            var next: [AXNodeSnapshot] = []
            for node in level {
                if predicate(node) { return node }
                next.append(contentsOf: node.children)
            }
            level = next
            depth += 1
        }
        return nil
    }

    /// All descendants (not including `self`) in depth-first order, with their parent.
    public func descendants() -> [(node: AXNodeSnapshot, parent: AXNodeSnapshot)] {
        var result: [(AXNodeSnapshot, AXNodeSnapshot)] = []
        func visit(_ node: AXNodeSnapshot) {
            for child in node.children {
                result.append((child, node))
                visit(child)
            }
        }
        visit(self)
        return result
    }
}

// MARK: - Sidebar

/// One bot button in Grok Bot's sidebar.
public struct SidebarEntry: Equatable, Sendable {
    /// Node id of the button, for pressing it.
    public var nodeID: Int
    /// The button's full accessible label, e.g. "Research Bot, Waiting for you".
    public var label: String
}

public enum SidebarParser {
    /// Buttons inside the sidebar list that are not bots.
    static let nonBotLabels = GrokBotLabels.nonBotButtons

    static let attentionPhrases = GrokBotLabels.attentionPhrases

    public static func findSidebar(in root: AXNodeSnapshot) -> AXNodeSnapshot? {
        root.first { node in
            [node.axDescription, node.title].contains { $0.map(GrokBotLabels.sidebar.contains) ?? false }
        }
    }

    public static func entries(in root: AXNodeSnapshot) -> [SidebarEntry]? {
        guard let sidebar = findSidebar(in: root) else { return nil }
        return sidebar.descendants()
            .map(\.node)
            .filter { $0.role == "AXButton" }
            .compactMap { node in
                let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let firstPart = label.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard !label.isEmpty, !nonBotLabels.contains(firstPart) else { return nil }
                return SidebarEntry(nodeID: node.id, label: label)
            }
    }

    /// Status text that follows the bot name in a sidebar label, if any.
    public static func statusText(of entry: SidebarEntry, botName: String) -> String? {
        guard entry.label.count > botName.count, entry.label.hasPrefix(botName) else { return nil }
        let rest = entry.label.dropFirst(botName.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        return rest.isEmpty ? nil : rest
    }

    public static func statusIndicatesAttention(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return attentionPhrases.contains { status.contains($0) }
    }
}

// MARK: - Identity matching

public enum BotMatch: Equatable, Sendable {
    case unique(SidebarEntry)
    case ambiguous
    case notFound
}

/// Matches a roster bot to its sidebar button by exact name.
///
/// Matching is deliberately strict. Prefix or substring matching could send a
/// reply to the wrong bot, so BotPeek refuses whenever the match is not unique
/// and offers to open Grok Bot instead.
public enum BotIdentityMatcher {
    public static func labelMatches(_ label: String, name: String) -> Bool {
        label == name || label.hasPrefix(name + ",")
    }

    /// - Parameters:
    ///   - bot: the bot to reply to.
    ///   - roster: all bots in the roster, used to detect duplicate names.
    ///   - sidebar: the sidebar buttons currently visible.
    /// Whether the conversation already open, titled `heading`, is `bot`'s.
    /// The heading shows only the name, so this holds only when no other bot shares it.
    public static func isOpen(bot: BotIdentity, heading: String?, roster: [BotIdentity]) -> Bool {
        heading == bot.name && !roster.contains { $0.name == bot.name && $0.id != bot.id }
    }

    public static func match(bot: BotIdentity, roster: [BotIdentity], sidebar: [SidebarEntry]) -> BotMatch {
        let sameName = roster.filter { $0.name == bot.name }
        if sameName.count > 1 { return .ambiguous }

        // A longer roster name that starts with this one ("Ops" vs "Ops, Europe")
        // would also match the prefix rule; exclude its buttons.
        let longerNames = roster.map(\.name).filter { $0 != bot.name && $0.hasPrefix(bot.name) }
        let candidates = sidebar.filter { entry in
            labelMatches(entry.label, name: bot.name)
                && !longerNames.contains { labelMatches(entry.label, name: $0) }
        }
        switch candidates.count {
        case 1: return .unique(candidates[0])
        case 0: return .notFound
        default: return .ambiguous
        }
    }
}
