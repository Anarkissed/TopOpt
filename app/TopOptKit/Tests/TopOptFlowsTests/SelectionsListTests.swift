// SelectionsListTests — the quiet Selections list.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Tests/TopOptFlowsTests/FlexibleSelectionsListTests.swift,
// with SelectionsList (reviewer ruling 2026-10-24 07:30). The same assertions. Changed only where the source reached Flexible:
//   * testTheSummaryForms: the project is built here (a protected Lattice group with Faces 3 and 5, 25 mm, and an unlatticed
//     "Top"); the source restored his pad through FlexiblePressFixtures / FlexibleR7M1Fixtures and set a face's state with
//     FlexibleFaceCommits.setState — here `lattice.selectableRoles[ref.key]`, #354's own override (the role it reads);
//   * the source pins read SelectionsList.swift (was FlexibleSelectionsList.swift) through this file's own path (was
//     FlexibleRound7SelectionsHookTests.sources);
//   * dropped (Flexible-only): "the boxes are FlexNumberBox" and "a box edits AND picks its face" (`main.pickFace`) — the
//     picked group's rows are the caller's here; "the trash asks first" stays, as `askDelete(g.id)`.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class SelectionsListTests: XCTestCase {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/TopOptFlows")

    /// A protected Lattice group with Faces 3 and 5 at 25 mm, and "Top" (Face 1), nothing latticed.
    private func project() -> (ProjectModel, lattice: UUID) {
        let p = ProjectModel(id: UUID(), name: "Summary", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        let c = p.selection.addGroup()
        p.selection.pickFaces([3, 5])
        let top = p.selection.addGroup()
        p.selection.pickFaces([1])
        p.selection.rename(top, to: "Top")
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(c, true)
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 25
        p.lattice.groupRoles[c] = .include
        return (p, c)
    }

    func testTheSummaryForms() throws {
        let (p, c) = project()
        func g(_ id: UUID) throws -> SelectionGroup { try XCTUnwrap(p.selection.groups.first { $0.id == id }) }
        XCTAssertEqual(try g(c).faces.sorted(), [3, 5], "premise: the group holds Faces 3 and 5")
        XCTAssertEqual(SelectionsSummary.summary(project: p, group: try g(c)), "▦ 2 · 25 mm", "★ two Lattice faces at 25")
        p.writeLatticeDepthMM(.face(group: c, face: 3), mm: 20)
        XCTAssertEqual(SelectionsSummary.summary(project: p, group: try g(c)), "▦ 2 · 20–25 mm", "★ a range")
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: c, face: 3).key] = .exclude
        XCTAssertEqual(SelectionsSummary.summary(project: p, group: try g(c)), "▦ 1 ■ 1", "★ mixed Lattice and Solid")
        p.lattice.selectableRoles[LatticeSelectableRef.face(group: c, face: 5).key] = .off
        p.writeLatticeDepthMM(.face(group: c, face: 3), mm: 10)
        XCTAssertEqual(SelectionsSummary.summary(project: p, group: try g(c)), "■ 1 · 10 mm", "★ Solid only")
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(SelectionsSummary.summary(project: p, group: top), "—", "★ nothing latticed")
        XCTAssertEqual(SelectionsSummary.common([25, 25, 25.01]), 25)
        XCTAssertNil(SelectionsSummary.common([20, 25]), "★ the All line reads 'mixed'")
    }

    /// The header holds only the chevron, "Selections" and the count: the ids of Regions, Keep clear, kg | lbs, the eye and
    /// All / Some / None are NOT in the list. RED CONTROL: today's card (#354's selectionsLibraryCard) has Regions and Keep clear.
    func testTheHeaderHasNothingElseAndTodaysCardDid() throws {
        let src = try String(contentsOf: Self.sources.appendingPathComponent("SelectionsList.swift"), encoding: .utf8)
        let code = src.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for id in ["regionsOpen", "keepClearQuickAction", "unitToggle", "groupHideToggle", "\"Regions\"", "square.on.square.dashed",
                   "WeightUnit.allCases", "eyeSymbol"] {
            XCTAssertFalse(code.contains(id), "★ not in the list: \(id)")
        }
        XCTAssertEqual(SelectionsCopy.empty, "Tap a face on the model to start.")
        XCTAssertTrue(code.contains("\"Selections\""))
        XCTAssertTrue(code.contains("-sel-pill"), "minimised: the pill 'Selections 3'")
        // ★ RED CONTROL: #354's card (img6): the Regions icon and Keep clear in its header
        let ws = try String(contentsOf: Self.sources.appendingPathComponent("WorkspacePlaceholder.swift"), encoding: .utf8)
        let card = try XCTUnwrap(ws.range(of: "private var selectionsLibraryCard: some View {"))
        let header = String(ws[card.upperBound...].prefix(4000))
        XCTAssertTrue(header.contains("Image(systemName: \"square.on.square.dashed\")") && header.contains("keepClearQuickAction"),
                      "★ RED CONTROL: today's header carries Regions and Keep clear")
    }

    /// Every line of the list is a 44 pt target; the trash asks first.
    func testLinesAre44AndTheTrashAsksFirst() throws {
        XCTAssertEqual(SelectionsList.lineHeight, 44)
        let src = try String(contentsOf: Self.sources.appendingPathComponent("SelectionsList.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("askDelete(g.id)"), "★ the trash asks first (his answer)")
    }
}
