import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ K3 IN THE PREVIEW — the reviewer's ruling, 2026-10-11 00:35, item 2, approved by the maintainer: "K3 is in
/// core now (f0d8bf27, and 76f51204 on top). The preview should draw prism space that no cell covers as SOLID,
/// behind the K3 probe, as agreed, because the build prints it solid … so a slit can never again look like a hole
/// the print doesn't have." Core prints it solid only on a job that CARRIES the plan; without one it lattices that
/// space by its own law, so the preview's line already says the run builds core's own layout.
final class LatticeK3UncoveredSolidTests: XCTestCase {

    /// The probe, with its controls: a key every core takes passes, a nonsense key is refused, and the linked
    /// core (#358 through f9bbc4d6) takes K4's `emit_plan_laid` — so it carries K3.
    func testTheLinkedCoreCarriesK3() {
        XCTAssertTrue(TopOptKit.latticeSchemaAccepts(key: "emit_stl"), "control: the probe can say yes")
        XCTAssertFalse(TopOptKit.latticeSchemaAccepts(key: "emit_plan_laid_not_a_key"), "control: and no")
        XCTAssertTrue(TopOptKit.corePrintsWhatThePlanLeavesSolid, "★ the linked core carries K3")
    }

    /// The one predicate: solid only where the job carries the preview's plan AND core has K3.
    func testSolidOnlyOnAPlanJobOnACoreWithK3() {
        typealias W = LatticeSteppedCellWire
        XCTAssertTrue(W.uncoveredPrintsSolid(algorithm: "doubled", wired: true, k3: true, enabled: true), "★ a plan job, K3")
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "doubled", wired: true, k3: false, enabled: true), "no K3: air")
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "doubled", wired: false, k3: true, enabled: true),
                       "a core that cannot parse a plan gets none")
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "doubled", wired: true, k3: true, enabled: false),
                       "★ plans off (production today): core lattices that space by its own law — not solid")
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "stepped", wired: true, k3: true, enabled: true),
                       "Stepped never sends a plan in production")
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "organic", wired: true, k3: true, enabled: true))
        // production's own answer today: the switch is off
        XCTAssertFalse(W.uncoveredPrintsSolid(algorithm: "doubled", wired: TopOptKit.steppedCellsWired,
                                              k3: TopOptKit.corePrintsWhatThePlanLeavesSolid))
    }

    /// The march draws it (source pin): an uncovered stepped texel inside the clip is solid when `rimParams.z` is
    /// armed, and the renderer arms it only for a stepped bake under the predicate.
    func testTheMarchAndTheRendererCarryIt() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let dir = u.appendingPathComponent("Sources/TopOptFlows")
        let shader = try String(contentsOf: dir.appendingPathComponent("UnifiedShading.swift"), encoding: .utf8)
        XCTAssertTrue(shader.contains("if (LC.stepped == 0.0 && U.rimParams.z > 0.5) {\n            Fsolid = min(Fsolid, dClip);"))
        let renderer = try String(contentsOf: dir.appendingPathComponent("LatticeSDFMetal.swift"), encoding: .utf8)
        XCTAssertTrue(renderer.contains("steppedDrawn && uncoveredPrintsSolid ? 1 : 0, 0)"))
        XCTAssertTrue(renderer.contains("return LatticeSteppedCellWire.uncoveredPrintsSolid(algorithm: steppedDyadicSteps ? \"doubled\" : \"stepped\","))
    }
}
