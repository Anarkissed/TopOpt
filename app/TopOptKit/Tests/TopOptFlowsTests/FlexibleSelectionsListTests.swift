// FlexibleSelectionsListTests — round 7, batch R7-D2, THE LIST (B1's quiet list in #354's panel slot, hook H25), written
// BEFORE the code (red run: round7/batch_d2/d2_red_run.txt). His img6 (2026-10-14): "Remove regions … Remove "Keep Clear" at
// the top … Figure out a better designed way to set each face to be latticed/solid/off and have its depth/expand value."
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSelectionsListTests: XCTestCase {

    func testTheSummaryForms() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        func g(_ id: UUID) throws -> SelectionGroup { try XCTUnwrap(p.selection.groups.first { $0.id == id }) }
        XCTAssertEqual(FlexibleSelectionsSummary.summary(project: p, group: try g(c)), "▦ 2 · 25 mm", "★ two Lattice faces at 25")
        p.writeLatticeDepthMM(.face(group: c, face: 3), mm: 20)
        XCTAssertEqual(FlexibleSelectionsSummary.summary(project: p, group: try g(c)), "▦ 2 · 20–25 mm", "★ a range")
        FlexibleFaceCommits.setState(.exclude, ref: .face(group: c, face: 3), group: c, project: p)
        XCTAssertEqual(FlexibleSelectionsSummary.summary(project: p, group: try g(c)), "▦ 1 ■ 1", "★ mixed Lattice and Solid")
        FlexibleFaceCommits.setState(.off, ref: .face(group: c, face: 5), group: c, project: p)
        p.writeLatticeDepthMM(.face(group: c, face: 3), mm: 10)
        XCTAssertEqual(FlexibleSelectionsSummary.summary(project: p, group: try g(c)), "■ 1 · 10 mm", "★ Solid only")
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(FlexibleSelectionsSummary.summary(project: p, group: top), "—", "★ nothing latticed")
        XCTAssertEqual(FlexibleSelectionsSummary.common([25, 25, 25.01]), 25)
        XCTAssertNil(FlexibleSelectionsSummary.common([20, 25]), "★ the All line reads 'mixed'")
    }

    /// The header holds only the chevron, "Selections" and the count: the ids of Regions, Keep clear, kg | lbs, the eye and
    /// All / Some / None are NOT in the list. RED CONTROL: today's card (#354's selectionsLibraryCard) has Regions and Keep clear.
    func testTheHeaderHasNothingElseAndTodaysCardDid() throws {
        let src = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSelectionsList.swift"), encoding: .utf8)
        let code = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for id in ["regionsOpen", "keepClearQuickAction", "unitToggle", "groupHideToggle", "\"Regions\"", "square.on.square.dashed",
                   "WeightUnit.allCases", "eyeSymbol"] {
            XCTAssertFalse(code.contains(id), "★ not in the list: \(id)")
        }
        XCTAssertEqual(FlexibleSelectionsCopy.empty, "Tap a face on the model to start.")
        XCTAssertTrue(code.contains("\"Selections\""))
        XCTAssertTrue(code.contains("flexible-sel-pill"), "minimised: the pill 'Selections 3'")
        // ★ RED CONTROL: #354's card on the Flexible stage (img6): the Regions icon and Keep clear in its header
        let ws = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("WorkspacePlaceholder.swift"), encoding: .utf8)
        let card = try XCTUnwrap(ws.range(of: "private var selectionsLibraryCard: some View {"))
        let header = String(ws[card.upperBound...].prefix(4000))
        XCTAssertTrue(header.contains("Image(systemName: \"square.on.square.dashed\")") && header.contains("keepClearQuickAction"),
                      "★ RED CONTROL: today's header carries Regions and Keep clear")
    }

    /// Every line of the list is a 44 pt target; the boxes are his number boxes (tap = keypad, drag = scrub).
    func testLinesAre44AndBoxesAreNumberBoxes() throws {
        XCTAssertEqual(FlexibleSelectionsList.lineHeight, 44)
        let src = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("FlexibleSelectionsList.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("FlexNumberBox(key: key"), "the boxes are FlexNumberBox")
        XCTAssertTrue(src.contains("main.pickFace(r, group: g.id, project: project)"), "★ a box edits AND picks its face")
        XCTAssertTrue(src.contains("main.askDelete(g.id)"), "★ the trash asks first (his answer)")
    }
}
