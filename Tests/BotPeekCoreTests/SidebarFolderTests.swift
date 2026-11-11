import XCTest
@testable import BotPeekCore

final class SidebarFolderTests: XCTestCase {
    let writer = identity("w", "Writer")
    let planner = identity("p", "Planner")
    let loose = identity("l", "Loose")
    var roster: [BotIdentity] { [writer, planner, loose] }

    var sections: [SidebarSection] {
        [
            SidebarSection(id: "s1", name: "Research", botIDs: [writer.id]),
            SidebarSection(id: "s2", name: "Travel 2026", botIDs: [planner.id]),
        ]
    }

    func testParsesCachedSections() throws {
        let json = #"{"schemaVersion":1,"value":{"sections":[{"id":"a","name":"Research","agentIds":["w","x"]},{"id":"b","name":"Empty","agentIds":[]},{"id":"c"}]}}"#
        let parsed = try XCTUnwrap(SidebarSectionParser.sections(in: Data(json.utf8)))
        XCTAssertEqual(parsed, [
            SidebarSection(id: "a", name: "Research", botIDs: [BotID("w"), BotID("x")]),
            SidebarSection(id: "b", name: "Empty", botIDs: []),
        ], "a section without a name is skipped")
        XCTAssertNil(SidebarSectionParser.sections(in: Data("not json".utf8)))
    }

    func testStoreReadsTheRosterAccountsSections() throws {
        let folder = try TemporaryGrokFolder()
        try folder.writeBlob(key: "acct.roster.last-roster", data: Data("{}".utf8))
        try folder.writeBlob(key: "acct.sidebar.last-sections", data: Data(#"{"value":{"sections":[{"id":"a","name":"Research","agentIds":["w"]}]}}"#.utf8))
        try folder.writeBlob(key: "other.sidebar.last-sections", data: Data(#"{"value":{"sections":[]}}"#.utf8))
        XCTAssertEqual(SidebarSectionStore(paths: folder.paths).load()?.map(\.name), ["Research"])
    }

    func testCollapsedFolderEnglish() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Loose", "Research 3", "Travel 2026 1"], heading: nil, messages: [])
        guard case .collapsed(let id, let folder) = SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: window) else {
            return XCTFail("expected a collapsed folder")
        }
        XCTAssertEqual(folder, "Research")
        XCTAssertEqual(SidebarParser.entries(in: window)?.first { $0.nodeID == id }?.label, "Research 3")
        // A folder name that ends in a number keeps it; only the count is cut.
        guard case .collapsed(_, let travel) = SidebarFolderMatcher.match(bot: planner, sections: sections, roster: roster, in: window) else {
            return XCTFail("expected a collapsed folder")
        }
        XCTAssertEqual(travel, "Travel 2026")
    }

    func testCollapsedFolderPolish() {
        let ax = AXTreeBuilder(strings: .polish)
        let polishSections = [SidebarSection(id: "s1", name: "Badania", botIDs: [writer.id])]
        let window = ax.window(sidebar: ["Badania 4", "Ukryte Boty 2"], heading: nil, messages: [])
        guard case .collapsed(_, let folder) = SidebarFolderMatcher.match(bot: writer, sections: polishSections, roster: roster, in: window) else {
            return XCTFail("expected a collapsed folder in a Polish sidebar")
        }
        XCTAssertEqual(folder, "Badania")
    }

    func testExpandedFolderIsLeftAlone() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research", "Loose"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: window), .expanded)
        XCTAssertNotNil(SidebarFolderMatcher.expandedButton(folder: "Research", roster: roster, in: window))
        let collapsed = ax.window(sidebar: ["Research 3"], heading: nil, messages: [])
        XCTAssertNil(SidebarFolderMatcher.expandedButton(folder: "Research", roster: roster, in: collapsed), "already closed")
    }

    func testFolderNotDrawn() {
        let ax = AXTreeBuilder(strings: .polish)
        let window = ax.window(sidebar: ["Loose"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: window), .notShown)
    }

    func testBotWithoutFolder() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research 3"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: loose, sections: sections, roster: roster, in: window), .noFolder)
    }

    func testFolderNamedLikeABotIsNeverPressed() {
        let ax = AXTreeBuilder()
        let named = [SidebarSection(id: "s1", name: "Loose", botIDs: [writer.id])]
        let window = ax.window(sidebar: ["Loose 2"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: named, roster: roster, in: window), .unsafe)
    }

    func testCountedLabelThatCouldBeABotIsNeverPressed() {
        let ax = AXTreeBuilder()
        let numbered = identity("n", "Research 3")
        let window = ax.window(sidebar: ["Research 3"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster + [numbered], in: window), .unsafe)
    }

    func testTwoMatchingButtonsAreAmbiguous() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research 3", "Research 5"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: window), .unsafe)
        let mixed = ax.window(sidebar: ["Research 3", "Research"], heading: nil, messages: [])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: mixed), .unsafe)
        XCTAssertNil(SidebarFolderMatcher.expandedButton(folder: "Research", roster: roster, in: mixed))
    }

    func testUnclearSectionsAreRefused() {
        let ax = AXTreeBuilder()
        let window = ax.window(sidebar: ["Research 3", "Ukryte Boty 2"], heading: nil, messages: [])
        let twice = sections + [SidebarSection(id: "s3", name: "Other", botIDs: [writer.id])]
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: twice, roster: roster, in: window), .unsafe, "filed in two folders")
        let sameName = sections + [SidebarSection(id: "s3", name: "Research", botIDs: [])]
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sameName, roster: roster, in: window), .unsafe, "two folders share the name")
        let hidden = [SidebarSection(id: "s1", name: "Ukryte Boty", botIDs: [writer.id])]
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: hidden, roster: roster, in: window), .unsafe, "the hidden-bots section")
    }

    func testFolderButtonsOutsideTheSidebarDontCount() {
        let ax = AXTreeBuilder()
        let window = ax.node("AXWindow", [ax.node("AXGroup", [ax.button("Research 3")])])
        XCTAssertEqual(SidebarFolderMatcher.match(bot: writer, sections: sections, roster: roster, in: window), .unsafe)
    }
}

final class SidebarModeTests: XCTestCase {
    func testFullAndCompactEnglish() {
        let ax = AXTreeBuilder()
        let full = ax.window(sidebar: ["Search", "Research 3"], heading: nil, messages: [])
        XCTAssertNotNil(SidebarMode.toggle(in: full))
        XCTAssertEqual(SidebarMode.detect(in: full, toggleExpanded: true), .full)
        XCTAssertEqual(SidebarMode.detect(in: full, toggleExpanded: nil), .full, "the search button alone means full")
        let compact = ax.window(sidebar: ["Writer"], heading: nil, messages: [])
        XCTAssertEqual(SidebarMode.detect(in: compact, toggleExpanded: false), .compact)
    }

    func testFullAndCompactPolish() {
        let ax = AXTreeBuilder(strings: .polish)
        let full = ax.window(sidebar: ["Szukaj", "Badania 4"], heading: nil, messages: [])
        XCTAssertEqual(SidebarMode.detect(in: full, toggleExpanded: true), .full)
        let compact = ax.window(sidebar: ["Writer"], heading: nil, messages: [])
        XCTAssertEqual(SidebarMode.detect(in: compact, toggleExpanded: false), .compact)
    }

    func testUnclearModeIsUnknown() {
        let ax = AXTreeBuilder(strings: .polish)
        let compact = ax.window(sidebar: ["Writer"], heading: nil, messages: [])
        XCTAssertEqual(SidebarMode.detect(in: compact, toggleExpanded: nil), .unknown, "no AXExpanded and no search button")
        XCTAssertEqual(SidebarMode.detect(in: compact, toggleExpanded: true), .unknown, "signals disagree")
        let full = ax.window(sidebar: ["Szukaj"], heading: nil, messages: [])
        XCTAssertEqual(SidebarMode.detect(in: full, toggleExpanded: false), .unknown, "signals disagree")
    }

    func testNoToggle() {
        let ax = AXTreeBuilder()
        let window = ax.node("AXWindow", [ax.node("AXList", desc: "Bots", [ax.button("Search"), ax.button("Writer")])])
        XCTAssertNil(SidebarMode.toggle(in: window))
        XCTAssertEqual(SidebarMode.detect(in: window, toggleExpanded: true), .unknown)
        XCTAssertEqual(SidebarMode.detect(in: ax.node("AXWindow"), toggleExpanded: true), .unknown, "no sidebar")
    }
}
