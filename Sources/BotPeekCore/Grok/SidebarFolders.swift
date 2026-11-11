import Foundation

/// A folder ("section") in Grok Bot's sidebar and the bots filed in it.
///
/// Grok Bot 0.79 lets users group bots into folders. A collapsed folder's bots
/// aren't drawn at all, so their buttons don't exist in the Accessibility tree
/// until the folder is opened. Grok Bot caches the folders under the key
/// `<account>.sidebar.last-sections`:
/// ```json
/// { "schemaVersion": 1, "value": { "sections": [
///     { "id": "…", "name": "Research", "agentIds": ["<bot id>", …] } ] } }
/// ```
public struct SidebarSection: Equatable, Sendable {
    public var id: String
    public var name: String
    public var botIDs: [BotID]

    public init(id: String, name: String, botIDs: [BotID]) {
        self.id = id
        self.name = name
        self.botIDs = botIDs
    }
}

public enum SidebarSectionParser {
    public static func sections(in data: Data) -> [SidebarSection]? {
        guard let root = try? JSONValue.parse(data),
              let rows = root["value"]?["sections"]?.arrayValue ?? root["sections"]?.arrayValue
        else { return nil }
        return rows.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            let ids = (row["agentIds"]?.arrayValue ?? []).compactMap(\.stringValue).map(BotID.init)
            return SidebarSection(id: row["id"]?.stringValue ?? "", name: name, botIDs: ids)
        }
    }
}

/// Reads the sidebar folders of the account whose roster BotPeek uses. Read-only.
public final class SidebarSectionStore: @unchecked Sendable {
    public static let maximumFileSize = 1_024 * 1_024
    static let sectionsKeySuffix = ".sidebar.last-sections"

    public let paths: GrokBotPaths

    public init(paths: GrokBotPaths) {
        self.paths = paths
    }

    /// The folders file in the same account as `rosterFile`.
    public func fileURL(rosterFile: URL) -> URL? {
        guard let rosterKey = Base32.decodeKey(fileName: rosterFile.deletingPathExtension().lastPathComponent),
              rosterKey.hasSuffix(RosterStore.rosterKeySuffix)
        else { return nil }
        let account = rosterKey.dropLast(RosterStore.rosterKeySuffix.count)
        return paths.persistenceDirectory.appendingPathComponent(Base32.encode(Data((account + Self.sectionsKeySuffix).utf8)) + ".blob")
    }

    /// The folders, or `nil` when Grok Bot hasn't cached any or they can't be read.
    public func load() -> [SidebarSection]? {
        guard let roster = try? RosterStore(paths: paths).locateRosterFile(),
              let url = fileURL(rosterFile: roster.url)
        else { return nil }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= Self.maximumFileSize,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return SidebarSectionParser.sections(in: data)
    }
}

/// Finds the sidebar button of the folder a bot is filed in.
///
/// A collapsed folder's button is labelled "<folder> <number of bots>", an open
/// one just "<folder>". Matching is strict: BotPeek presses a folder button only
/// when exactly one button in the sidebar belongs to that folder name, and never
/// when the name could be confused with a bot or with the hidden-bots section.
public enum SidebarFolderMatcher {
    public enum Match: Equatable, Sendable {
        /// The bot's folder is collapsed; pressing this button opens it.
        case collapsed(nodeID: Int, folder: String)
        /// The bot's folder is already open (so it isn't why the bot is missing).
        case expanded
        /// The bot isn't filed in a folder.
        case noFolder
        /// The folder's button isn't in the sidebar (not drawn right now).
        case notShown
        /// It isn't safe to tell which button is the folder's.
        case unsafe
    }

    public static func match(
        bot: BotIdentity,
        sections: [SidebarSection],
        roster: [BotIdentity],
        in root: AXNodeSnapshot
    ) -> Match {
        let folders = sections.filter { $0.botIDs.contains(bot.id) }
        guard !folders.isEmpty else { return .noFolder }
        guard folders.count == 1 else { return .unsafe }
        let name = folders[0].name
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !GrokBotLabels.hiddenBotsSection.contains(name),
              !roster.contains(where: { $0.name == name }),
              sections.filter({ $0.name == name }).count == 1
        else { return .unsafe }

        guard let buttons = buttons(named: name, in: root, roster: roster) else { return .unsafe }
        switch (buttons.collapsed.count, buttons.expanded.count) {
        case (1, 0): return .collapsed(nodeID: buttons.collapsed[0], folder: name)
        case (0, 1): return .expanded
        case (0, 0): return .notShown
        default: return .unsafe
        }
    }

    /// The open folder button to press to collapse `folder` again, if exactly one.
    public static func expandedButton(folder: String, roster: [BotIdentity], in root: AXNodeSnapshot) -> Int? {
        guard let buttons = buttons(named: folder, in: root, roster: roster),
              buttons.collapsed.isEmpty, buttons.expanded.count == 1
        else { return nil }
        return buttons.expanded[0]
    }

    /// Whether `label` is a collapsed folder's: the name, a space and a count.
    static func isCollapsedLabel(_ label: String, folder: String) -> Bool {
        guard label.hasPrefix(folder + " ") else { return false }
        let count = label.dropFirst(folder.count + 1)
        return !count.isEmpty && count.allSatisfy(\.isASCIIDigit)
    }

    /// Sidebar buttons belonging to `folder`, or `nil` without a sidebar. A
    /// button whose label could be a bot's never counts as a folder.
    static func buttons(named folder: String, in root: AXNodeSnapshot, roster: [BotIdentity]) -> (collapsed: [Int], expanded: [Int])? {
        guard let sidebar = SidebarParser.findSidebar(in: root) else { return nil }
        var collapsed: [Int] = []
        var expanded: [Int] = []
        for (node, _) in sidebar.descendants() where node.role == "AXButton" {
            let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if label == folder {
                expanded.append(node.id)
            } else if isCollapsedLabel(label, folder: folder) {
                if roster.contains(where: { BotIdentityMatcher.labelMatches(label, name: $0.name) }) { return nil }
                collapsed.append(node.id)
            }
        }
        return (collapsed, expanded)
    }
}

/// Whether Grok Bot's sidebar is full or compact.
///
/// A compact sidebar (Grok Bot uses it in narrow windows, or the user picks it)
/// shows pinned bots and open folders only: no folder buttons and no search
/// button. The toggle between the modes reports `AXExpanded` true when the
/// sidebar is full. BotPeek trusts the mode only when that and the search button
/// agree.
public enum SidebarMode: Equatable, Sendable {
    case full
    case compact
    case unknown

    /// The full/compact toggle button, if the sidebar has exactly one.
    public static func toggle(in root: AXNodeSnapshot) -> AXNodeSnapshot? {
        let toggles = sidebarButtons(in: root).filter { GrokBotLabels.compactSidebarToggle.contains($0.label) }
        return toggles.count == 1 ? toggles[0] : nil
    }

    /// - Parameter toggleExpanded: the toggle's live `AXExpanded`, if it has one.
    public static func detect(in root: AXNodeSnapshot, toggleExpanded: Bool?) -> SidebarMode {
        guard toggle(in: root) != nil else { return .unknown }
        let hasSearch = sidebarButtons(in: root).contains { GrokBotLabels.searchButton.contains($0.label) }
        switch (toggleExpanded, hasSearch) {
        case (true, true), (nil, true): return .full
        case (false, false): return .compact
        default: return .unknown
        }
    }

    static func sidebarButtons(in root: AXNodeSnapshot) -> [AXNodeSnapshot] {
        guard let sidebar = SidebarParser.findSidebar(in: root) else { return [] }
        return sidebar.descendants().map(\.node).filter { $0.role == "AXButton" }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
