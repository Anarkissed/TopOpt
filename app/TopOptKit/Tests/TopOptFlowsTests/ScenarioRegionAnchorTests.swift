// ScenarioRegionAnchorTests — B3 (core 35764048bba3, TO-core's per-scenario "anchor_region_ids", e37bf009).
//
// A cut piece (a region) can be an anchor. Before core took the key, every region anchor held in EVERY scenario, so its
// "Used here" switch did nothing for a cut piece. Now each scenario names its region anchors that are on — "[]" where none is,
// because once ANY scenario carries the key, core holds a region only where it is listed. With no region anchor anywhere,
// nothing new is sent. RED before B3 (saved: scratchpad b2red/ScenarioRegionAnchor.txt): no scenario carried the key.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ScenarioRegionAnchorTests: XCTestCase {

    func scenarios(_ job: [String: Any]) -> [[String: Any]] {
        ((job["loads"] as? [String: Any])?["scenarios"] as? [[String: Any]]) ?? []
    }

    func testARegionAnchorHoldsOnlyInTheScenariosItIsOnIn() throws {
        let x = try ScenarioSelectHostedTests.threeScenarios(self)
        let p = x.r.project
        let face = try XCTUnwrap(p.selection.groups.first { $0.id == x.bottom }?.faces.first)
        var m = p.faceRegions
        let piece = m.union(faces: [face], named: "Bottom face")
        p.faceRegions = m
        p.selection.addRegions([piece], to: x.bottom)   // Bottom holds by its cut piece too; it is off in Held by right plate

        let req = try XCTUnwrap(x.r.app.makeRunRequest())
        XCTAssertNil(LoadScenarioRule.refusal(for: req, workerSelected: true))
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
        let sc = scenarios(job)
        XCTAssertEqual(sc.map { $0["name"] as? String }, ["Normal use", "Held by left plate", "Held by right plate"])
        XCTAssertEqual(sc.map { $0["anchor_region_ids"] as? [Int] }, [[piece], [piece], []],
                       "★ the piece holds where Bottom is on, and every scenario says so ([] where it is off)")
        XCTAssertEqual((job["loads"] as? [String: Any])?["anchor_region_ids"] as? [Int], [piece], "the top level mirrors Normal use")
    }

    func testNoRegionAnchorSendsTheScenariosAsBefore() throws {
        let x = try ScenarioSelectHostedTests.threeScenarios(self)
        let req = try XCTUnwrap(x.r.app.makeRunRequest())
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: RemoteRun.buildJobJSON(req)) as? [String: Any])
        XCTAssertEqual(scenarios(job).count, 3)
        XCTAssertTrue(scenarios(job).allSatisfy { $0["anchor_region_ids"] == nil }, "★ no region anchor: today's bytes")
    }

    /// Core's rule: a scenario held only by a piece has an anchor on; with neither faces nor pieces it has none.
    func testAScenarioHeldOnlyByAPieceIsNotRefused() {
        let load = [TopOptKit.LoadGroupSpec(faceIDs: [5], force: SIMD3(0, 0, -10))]
        func request(_ s: [LoadScenarioWire]) -> RunRequest {
            var r = RunRequest(modelPath: "/m.step", material: "PLA", materialsPath: "/x", rulesPath: "/y", resolution: 40,
                               projectName: "p", anchorFaceIDs: [1], loadGroups: load)
            r.scenarios = s
            return r
        }
        let held = LoadScenarioWire(name: "Normal use", anchorFaceIDs: [1], loadGroups: load)
        XCTAssertNil(LoadScenarioRule.refusal(for: request([held, LoadScenarioWire(name: "By the piece", anchorFaceIDs: [],
                                                                                    loadGroups: load, anchorRegionIDs: [107])]),
                                              workerSelected: true), "★ a piece is an anchor")
        XCTAssertEqual(LoadScenarioRule.refusal(for: request([held, LoadScenarioWire(name: "Nothing", anchorFaceIDs: [], loadGroups: load)]),
                                                workerSelected: true), LoadScenarioRule.noAnchorLine("Nothing"))
    }
}
#endif
