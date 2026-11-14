// FlexibleH59MenuTitleTests — the reviewer's overnight release ruling (2026-10-26 07:42 UTC), item 2: THE MENU SAYS FLEXIBLE.
// On a Flexible project Topology's ● menu names its lattice row "Flexible" (the stage it opens), not #354's "Lattice…" (a
// project with no lattice type chosen yet). Hook H59 at the row's call site in WorkspacePlaceholder (topologyCapsuleOverlay);
// TopologyStageMenu.latticeTitle(typeInUse:) is #354's and unchanged. The lattice stage's own ● menu (LatticeStageMenu) is
// never drawn on a Flexible project: H27 draws ● Flexible there instead. Written before the code (red: the helper absent).
import XCTest
@testable import TopOptFlows

@MainActor
final class FlexibleH59MenuTitleTests: XCTestCase {

    func project(flexible: Bool, mode: LatticeStageMode? = nil) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "P", material: "ABS", process: .fdm, importedFile: nil, importedMesh: nil)
        if flexible { p.lattice.flexible = FlexibleStageSettings() }
        p.lattice.stageMode = mode
        return p
    }

    /// The row's words: "Flexible" on a Flexible project; #354's own title anywhere else. RED CONTROL: #354's title as it is.
    func testTopologysLatticeRowSaysFlexibleOnAFlexibleProject() {
        let none = TopologyStageMenu.latticeTitle(typeInUse: nil)
        XCTAssertEqual(none, "Lattice\u{2026}", "premise: #354's row before a type is chosen")
        XCTAssertEqual(FlexibleTopologyMenu.latticeRowTitle(none, project: project(flexible: true)), "Flexible",
                       "★ a Flexible project: the row names the Flexible stage")
        XCTAssertEqual(FlexibleTopologyMenu.latticeRowTitle(none, project: project(flexible: false)), none, "no lattice type yet: #354's words")
        let structural = TopologyStageMenu.latticeTitle(typeInUse: .structural)
        XCTAssertEqual(FlexibleTopologyMenu.latticeRowTitle(structural, project: project(flexible: false, mode: .structural)), structural,
                       "a Structural project: #354's words")
        XCTAssertEqual(FlexibleTopologyMenu.latticeRowTitle(structural, project: project(flexible: true, mode: .structural)), "Flexible",
                       "★ Flexible wins (it owns the lattice stage whenever it is set)")
        // ★ RED CONTROL: the row as #354 builds it — "Lattice…" on his Flexible project
        FlexibleTopologyMenu.controlLatticeTitle = true
        defer { FlexibleTopologyMenu.controlLatticeTitle = false }
        XCTAssertEqual(FlexibleTopologyMenu.latticeRowTitle(none, project: project(flexible: true)), "Lattice\u{2026}",
                       "★ RED CONTROL: without H59 the row reads Lattice…")
    }

    /// H59 is the one line at the call site, gated on the lattice row; the RED control is the line taken out.
    func testTheHookIsAtTheRowsCallSite() throws {
        let ws = try String(contentsOf: FlexibleRound7SelectionsHookTests.sources.appendingPathComponent("WorkspacePlaceholder.swift"), encoding: .utf8)
        let line = "StageCapsule.Item(id: r.id, title: r.target == .lattice ? FlexibleTopologyMenu.latticeRowTitle(r.title, project: project) : r.title,"
        func hooked(_ text: String) -> Bool {
            guard let call = text.range(of: "let rows = TopologyStageMenu.rows(typeInUse: project.lattice.stageMode, latticeGate: gate).map { r in") else { return false }
            let next = String(text[call.upperBound...].prefix(600))
            return next.contains(line) && next.contains("// Flexible (PR #362) H59:")
        }
        XCTAssertTrue(hooked(ws), "★ H59: Topology's lattice row reads FlexibleTopologyMenu.latticeRowTitle")
        XCTAssertEqual(ws.components(separatedBy: "Flexible (PR #362) H59:").count - 1, 1, "one H59 line")
        // ★ RED CONTROL: the call site as #354 wrote it
        let before = ws.replacingOccurrences(of: line, with: "StageCapsule.Item(id: r.id, title: r.title,")
        XCTAssertFalse(hooked(before), "★ RED CONTROL: #354's own call site is caught")
    }
}
