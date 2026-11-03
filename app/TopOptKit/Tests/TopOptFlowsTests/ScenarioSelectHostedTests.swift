// ScenarioSelectHostedTests — B3 (approved design 2026-11-02: ledger R5 and O3, plan.md §B3, mockup #topo-scen).
//
// R5, his words: "When one load scenario is selected, it hides all the other ones. All can be expanded, but only one selected
// at a time." The ▶ opens a folder (any number open); the folder's NAME selects its scenario — the part shows only it, a toast
// and the hint say which, its header reads as selected, and the folders he opened stay open. A tap on a line in another
// folder shows that folder's scenario, and only that folder's line is the picked one (a shared anchor is listed in each).
// O3: the anchor's per-scenario switch is labelled "Used here", and an anchor off in a scenario says "Off here" there.
// RED before B3 (saved: scratchpad b2red/ScenarioSelect.txt): no toast, the shown folder closed when another was selected,
// a shared anchor's line in another folder left the shown scenario as it was, and the switch had no label.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ScenarioSelectHostedTests: XCTestCase {

    struct Scenarios {
        let r: FlexibleHisProject.Restored
        /// Normal use, Held by left plate, Held by right plate.
        let s: [UUID]
        let bottom: UUID, c: UUID, top: UUID
        /// Each later scenario's own load (a face of the pad no other group holds).
        let loads: [UUID]
    }

    /// His A1 pad: Bottom and Group C hold in every scenario (shared anchors); Top pushes in Normal use; the two "held by"
    /// scenarios each push on their own face and switch one anchor off. Normal use is shown.
    static func threeScenarios(_ test: XCTestCase) throws -> Scenarios {
        let r = try FlexiblePressFixtures.a1Project(3, test, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        let id = { (name: String) in try XCTUnwrap(p.selection.groups.first { $0.name == name }, name).id }
        let bottom = try id("Bottom"), c = try id("Group C"), top = try id("Top")
        p.force.makeAnchor(bottom); p.force.makeAnchor(c)
        var loads: [UUID] = []
        var s: [UUID] = []
        for (name, face) in [("Held by left plate", FaceID(2)), ("Held by right plate", FaceID(4))] {
            let sc = p.force.addScenario()
            p.force.renameScenario(sc, to: name)
            let g = p.selection.addGroup()
            p.selection.addFaces([face], to: g)
            p.force.makeLoad(g)
            p.force.setWeight(g, kg: 10)
            s.append(sc); loads.append(g)
        }
        let first = p.force.scenarioList[0].id
        p.force.renameScenario(first, to: "Normal use")
        let order = p.selection.groups.map(\.id)
        XCTAssertNil(p.force.setAnchor(c, on: false, in: s[0], order: order))
        XCTAssertNil(p.force.setAnchor(bottom, on: false, in: s[1], order: order))
        p.force.openScenario(first)
        p.selection.clearActive()
        return Scenarios(r: r, s: [first] + s, bottom: bottom, c: c, top: top, loads: loads)
    }

    func testANameShowsOnlyItsScenarioAndTheOpenFoldersStayOpen() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13, AppBuildHost.landscape11] {
            let x = try Self.threeScenarios(self)
            let p = x.r.project
            let h = AppBuildHost(WorkspacePlaceholder(model: x.r.app, project: p), size: size, test: self)
            h.pump(3)
            let what = "\(size)"
            // ▶ opens "Held by left plate" too; Normal use is shown and open
            try h.tap("scenarioFolderOpen-1", "\(what): Held by left plate's ▶")
            XCTAssertEqual(p.force.activeScenarioID, x.s[0], "\(what): ▶ opens, it never selects")
            _ = try h.onScreen("selGroup-\(x.loads[0].uuidString)", "\(what): its load's line, opened by ▶")

            // ★ its NAME selects it (a tap on the name, past the ▶)
            let head = try h.onScreen("scenarioFolder-1", "\(what): Held by left plate's folder row")
            h.click(CGPoint(x: head.minX + 60, y: head.midY), settle: 0.3)
            XCTAssertEqual(p.force.activeScenarioID, x.s[1], "\(what): ★ the name selects the scenario")
            XCTAssertEqual(x.r.app.toast, "Showing Held by left plate", "\(what): ★ a toast says which is shown")
            XCTAssertNil(p.selection.activeGroupID, "\(what): no group is picked")
            _ = try h.onScreen("selLine-\(x.s[0].uuidString)-\(x.top.uuidString)",
                               "\(what): ★ R5 — Normal use's folder stays open (all can be expanded)")
            _ = try h.onScreen("selOutline-folder-\(x.s[1].uuidString)", "\(what): ★ the shown scenario's folder reads as selected")
            XCTAssertNil(h.frames.all["selOutline-folder-\(x.s[0].uuidString)"], "\(what): only one is selected")
            XCTAssertEqual(try h.onScreen("scenarioFolder-1", "\(what): its folder row").height, SelectionsList.lineHeight, accuracy: 0.5,
                           "\(what): ★ U3 — a folder row is 44 pt")
            _ = try h.probe("scenarioFolderName-1", "\(what): ★ the name is its own 44 pt target", minHit: 44)

            // ★ the shared anchor's line in Normal use's folder shows Normal use, and only that line is picked
            let line = try h.onScreen("selLine-\(x.s[0].uuidString)-\(x.c.uuidString)", "\(what): Group C's line under Normal use")
            h.click(CGPoint(x: line.minX + 80, y: line.midY))
            XCTAssertEqual(p.force.activeScenarioID, x.s[0], "\(what): ★ a line in another folder shows that folder's scenario")
            XCTAssertEqual(p.selection.activeGroupID, x.c, "\(what): and picks the line")
            let outline = try h.onScreen("selOutline-\(x.c.uuidString)", "\(what): the picked line's outline")
            let picked = try h.onScreen("selLine-\(x.s[0].uuidString)-\(x.c.uuidString)", "\(what): Group C's line under Normal use")
            XCTAssertEqual(outline.minY, picked.minY + SelectionsList.outlineInset, accuracy: 1,
                           "\(what): ★ the outline is on Normal use's line, not on the copy in another folder")
            _ = try h.onScreen("selLine-\(x.s[1].uuidString)-\(x.loads[0].uuidString)", "\(what): Held by left plate stays open")
            XCTAssertNil(h.frames.all["selOutline-folder-\(x.s[0].uuidString)"], "\(what): a picked line, so no folder reads as selected")
        }
    }

    func testTheAnchorSwitchSaysUsedHereAndAnOffAnchorSaysOffHere() throws {
        for size in [AppBuildHost.landscape13, AppBuildHost.landscape11] {
            let x = try Self.threeScenarios(self)
            let p = x.r.project
            let h = AppBuildHost(WorkspacePlaceholder(model: x.r.app, project: p), size: size, test: self)
            h.pump(3)
            try h.tap("scenarioFolderOpen-1", "\(size): Held by left plate's ▶")
            let used = try h.onScreen("scenarioAnchorUsedHere-\(x.c.uuidString)", "\(size): ★ O3 — the switch's label")
            let sw = try h.onScreen("scenarioAnchorSwitch-\(x.c.uuidString)", "\(size): the switch")
            XCTAssertLessThan(used.maxX, sw.minX + 1, "\(size): the label sits before its switch")
            XCTAssertEqual(used.midY, sw.midY, accuracy: 2, "\(size): on its line")
            _ = try h.onScreen("scenarioAnchorOffHere-\(x.s[1].uuidString)-\(x.c.uuidString)",
                               "\(size): ★ Group C is off in Held by left plate, and says so there")
            XCTAssertNil(h.frames.all["scenarioAnchorOffHere-\(x.s[0].uuidString)-\(x.c.uuidString)"], "\(size): it holds in Normal use")
            XCTAssertFalse(p.force.anchorIsOn(x.c, in: x.s[1]))
        }
    }

    /// The hint names the shown scenario, and the words are the design's.
    func testTheHintAndTheWords() throws {
        XCTAssertEqual(ScenarioSelectCopy.hint("Held by right plate"), "Showing Held by right plate · tap a face")
        XCTAssertEqual(ScenarioSelectCopy.showing("Normal use"), "Showing Normal use")
        XCTAssertEqual(ScenarioSelectCopy.usedHere, "Used here")
        XCTAssertEqual(ScenarioSelectCopy.offHere, "Off here")
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let ws = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(ws.contains("if scenariosApply, force.hasScenarios { return ScenarioSelectCopy.hint(force.activeScenario.name) }"),
                      "★ the hint says which scenario the part shows")
    }
}
#endif
