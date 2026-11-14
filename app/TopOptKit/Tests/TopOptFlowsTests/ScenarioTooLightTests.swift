import XCTest
import simd
import AppKit
import SwiftUI
@testable import TopOptFlows
@testable import TopOptKit

/// ★ HIS DECISION (2026-10-28, via TO-core): a scenario under 10% of the heaviest scenario's load can't shape the part and is
/// refused with a notice — the app's words are core's, verbatim, and the app says it before ▶ and in the scenario's folder.
@MainActor
final class ScenarioTooLightTests: XCTestCase {
    func testTheLineIsCoresWordForWord() {
        XCTAssertEqual(LoadScenarioRule.tooLightLine("Scenario 4", kg: 5, heaviest: "Scenario 1", heaviestKg: 51),
                       "Scenario “Scenario 4” is too light: its load is 5 kg, but it needs at least 5.1 kg (10% of Scenario “Scenario 1”'s 51 kg). Raise it or remove the scenario.",
                       "★ TO-core's example (his 10%), character for character")
        // ★ core's kg, its examples character for character (TO-core 2026-10-28), plus his 1534 kg and 9.996 kg
        for (v, t) in [(0.5, "0.5"), (1.53, "1.53"), (0.2437, "0.244"), (8.1577, "8.16"), (51.0, "51"), (46.02, "46"),
                       (1533.96, "1530"), (9.996, "10"), (1534, "1530")] {
            XCTAssertEqual(LoadScenarioRule.kg(v), t, "kg(\(v))")
        }
        XCTAssertTrue(LoadScenarioRule.tooLightLine("B", kg: 1, heaviest: "A", heaviestKg: 1534).contains("'s 1530 kg)"),
                      "never an exponent: 1530 kg, like core's pinned test")
        XCTAssertTrue(LoadScenarioRule.tooLightLine("B", kg: 1, heaviest: "A", heaviestKg: 1534).contains("at least 153 kg (10% of Scenario “A”'s 1530 kg)"))
    }

    func testTheTenPercentEdge() {
        XCTAssertNil(LoadScenarioRule.tooLight([("A", 100), ("B", 10)]), "exactly 10% runs")
        XCTAssertNotNil(LoadScenarioRule.tooLight([("A", 100), ("B", 9.99)]), "under 10% is refused")
        XCTAssertNil(LoadScenarioRule.tooLight([("A", 1)]), "one scenario: never")
        XCTAssertEqual(LoadScenarioRule.tooLightScenario([("A", 100), ("B", 50), ("C", 1)])?.name, "C")
    }

    /// The request check sums FORCE SIZES per scenario, so a twist of two opposite pushes is not zero — as core does.
    func testOptimizeRefusesATooLightScenarioWithCoresLine() {
        let g = 9.80665
        func req(_ s2: [TopOptKit.LoadGroupSpec]) -> RunRequest {
            var r = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/x", rulesPath: "/y", resolution: 40,
                               projectName: "p", anchorFaceIDs: [1], loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -51 * g))])
            r.scenarios = [LoadScenarioWire(name: "Scenario 1", anchorFaceIDs: [1], loadGroups: [.init(faceIDs: [5], force: SIMD3(0, 0, -51 * g))]),
                           LoadScenarioWire(name: "Scenario 2", anchorFaceIDs: [1], loadGroups: s2)]
            return r
        }
        let light = req([.init(faceIDs: [7], force: SIMD3(5 * g, 0, 0))])   // his Scenario 4: 5 kg against 51 (9.8%)
        XCTAssertEqual(LoadScenarioRule.refusal(for: light, workerSelected: true),
                       LoadScenarioRule.tooLightLine("Scenario 2", kg: 5, heaviest: "Scenario 1", heaviestKg: 51))
        // a twist: two opposite 3 kg pushes are 6 kg of load, not zero — over 10% of 51 kg (5.1 kg), so it runs
        let twist = req([.init(faceIDs: [7], force: SIMD3(3 * g, 0, 0)), .init(faceIDs: [8], force: SIMD3(-3 * g, 0, 0))])
        XCTAssertNil(LoadScenarioRule.refusal(for: twist, workerSelected: true), "★ a twist's pushes add up — it runs")
    }

    /// ★ On his screen: the light scenario's folder carries the line, with the minimum kg, the moment it drops under.
    func testTheLightScenarioSaysSoInItsFolder() throws {
        let ui = LoadScenarioHostedTests()
        let r = try ui.project()
        let p = r.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.force.setWeight(top.id, kg: 51)
        _ = p.force.addScenario()                                  // Scenario 2 open
        var sel = p.selection
        let free = try XCTUnwrap(FaceTopology.faceIDs(in: XCTUnwrap(p.viewerMesh)).first { f in sel.groups.allSatisfy { !$0.faces.contains(f) } })
        let g = sel.addGroup(); sel.pickFaces([free]); p.selection = sel
        p.force.makeLoad(g); p.force.setWeight(g, kg: 0.5)          // Scenario 2's load: 0.5 kg against 51
        p.force.sync(groups: p.selection.groups)
        let h = ui.host(WorkspacePlaceholder(model: r.app, project: p), size: CGSize(width: 1032, height: 1376))
        ui.pump(3)
        XCTAssertTrue(p.force.group(g, isIn: p.force.activeScenarioID), "premise: the light load is Scenario 2's")
        _ = try ui.onScreen(h, "scenarioFolderOpen-1", "Scenario 2's open folder")
        let line = try ui.onScreen(h, "scenarioTooLight", "★ the too-light line in Scenario 2's folder")
        XCTAssertGreaterThan(line.height, 14, "it is drawn, not a zero-height stub")
        try ui.picture(h, "scenario_too_light.png")
        // raise it past 10% and the line goes
        p.force.setWeight(g, kg: 6); ui.pump(1)
        XCTAssertNil(h.frames.all["scenarioTooLight"], "raised to 6 kg (over 5.1 kg): no line")
    }
}
