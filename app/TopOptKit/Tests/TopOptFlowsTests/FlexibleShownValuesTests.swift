// FlexibleShownValuesTests — "the heat map bends in 3D" (task 2026-09-29-flexible-screens,
// round 3, item 1; his img 1: a flat plane seen edge-on from the RIGHT view).
//   * a calibrate-first filament (TPU 95A, 9 of 10 in the catalogue) with the default curves
//     DENTS on the pad: the model seeds its drawn map from core's squish_fraction as the stack
//     arrives, and the page's own channels displace the top face. RED CONTROL: no drawn map ⇒
//     no dent at all (what his TPU 95A page showed);
//   * ONE integer exaggeration k: a 100 mm face at 3 mm is × 7; a 10 mm lattice caps it at ×2
//     so the dent never passes 65 % of the stack. RED CONTROL: uncapped, it would;
//   * HIS project with only top A pressed: the dented quads span k × (min … max) of the shown
//     depths along the load — the bend that reads edge-on from the RIGHT view.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleShownValuesTests: XCTestCase {

    func testOneIntegerExaggerationCappedByTheThinnestStack() {
        XCTAssertEqual(FlexibleShownValues.exaggerationRule(maxDepthMM: 3, extentMM: 100), 7, "a 100 mm face at 3 mm")
        XCTAssertEqual(FlexibleShownValues.exaggerationRule(maxDepthMM: 0.5, extentMM: 100), 10, "never past × 10")
        XCTAssertEqual(FlexibleShownValues.exaggerationRule(maxDepthMM: 30, extentMM: 100), 1, "never below × 1")
        // a 10 mm lattice under a 3 mm dent: k·3 ≤ 0.65·10 ⇒ k = 2
        let cap = FlexibleShownValues.thinCap(depthMM: 3, latticeMM: 10)
        XCTAssertEqual(cap, 2)
        let k = min(FlexibleShownValues.exaggerationRule(maxDepthMM: 3, extentMM: 100), cap)
        XCTAssertLessThanOrEqual(k * 3, 0.65 * 10)
        // ★ RED CONTROL: the rule alone (the cap removed) pushes the dent past 65 % of the stack
        XCTAssertGreaterThan(FlexibleShownValues.exaggerationRule(maxDepthMM: 3, extentMM: 100) * 3, 0.65 * 10)
        // at × 1 the dent is the drawing itself (never below 1)
        XCTAssertEqual(FlexibleShownValues.thinCap(depthMM: 3, latticeMM: 2), 1)
    }

    /// ★ CALIBRATE-FIRST BENDS. TPU 95A has no squish data, so core designs nothing — and
    /// the map still dents: the drawn map (S × deepest) from core's squish_fraction.
    @MainActor
    func testACalibrateFirstFilamentsDrawnMapDentsOnThePad() async throws {
        var s = FlexibleStageSettings(materialID: "tpu95a_generic")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top))
        let pm = try FlexibleHisProject.padProject(s)
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        let k = FlexFaceKey(region: top, rotation: 0)
        try await FlexibleHisProject.waitFor(30, "the drawn map") { m.liveS[k] != nil }
        XCTAssertNotNil(m.material?.noPrediction, "premise: TPU 95A is calibrate-first")
        XCTAssertTrue(m.designs.isEmpty, "premise: core designs nothing for it")
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        let dents = try XCTUnwrap(c.dents, "the drawn map must dent")
        let st = try XCTUnwrap(m.stacks[k])
        let start = try XCTUnwrap(o.flatStart[k])
        var deepest = 0.0
        for v in start..<(start + st.columns.count * 6) {
            deepest = max(deepest, simd_dot(SIMD3(Double(dents[3 * v]), Double(dents[3 * v + 1]), Double(dents[3 * v + 2])), st.load))
        }
        print(String(format: "FLEX-BEND TPU 95A pad, default curves: deepest quad dent %.2f mm (× %.0f shown), legend \"%@\", animated %@",
                     deepest, c.exaggeration, c.legendLine, c.animated ? "yes" : "no"))
        XCTAssertGreaterThan(deepest, 1, "the top face bends")
        XCTAssertFalse(c.animated, "it holds still while he edits")
        XCTAssertTrue(c.legendLine.hasPrefix("What you drew · shown ×"))
        // ★ RED CONTROL: with no drawn map (what his TPU 95A page had) nothing is shown or dented
        var inp = FlexibleShownValues.inputs(m)
        inp.liveS = [:]
        let none = FlexibleShownValues(inp, drawnLattice: nil)
        XCTAssertTrue(none.values.isEmpty)
        XCTAssertFalse(none.showsDent, "control: an empty drawn map dents nothing")
    }

    /// ★ HIS PROJECT, only top A pressed (img 1's state): the dented quads' displacement along
    /// the load spans k × (min … max) of the shown depths — the bend is there to be seen edge-on.
    @MainActor
    func testHisTopABendsAlongItsLoad() async throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        var s = try XCTUnwrap(r.project.lattice.flexible)
        s.faces = s.faces.filter { $0.faceRegionID == FlexibleHisProject.topA }
        s.checkStamps = []
        r.project.lattice.flexible = s
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        let k = FlexFaceKey(region: FlexibleHisProject.topA, rotation: 0)
        try await FlexibleHisProject.waitFor(30, "the drawn map") { m.liveS[k] != nil }
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        let shown = FlexibleShownValues(model: m)
        let depths = (shown.values[k] ?? []).compactMap { if case .depth(let d) = $0 { return d } else { return nil } }
        let dents = try XCTUnwrap(c.dents)
        let st = try XCTUnwrap(m.stacks[k]), start = try XCTUnwrap(o.flatStart[k])
        var lo = Double.infinity, hi = -Double.infinity
        for v in start..<(start + st.columns.count * 6) {
            let d = simd_dot(SIMD3(Double(dents[3 * v]), Double(dents[3 * v + 1]), Double(dents[3 * v + 2])), st.load) * c.exaggeration
            lo = min(lo, d); hi = max(hi, d)
        }
        let want = c.exaggeration * ((depths.max() ?? 0) - (depths.min() ?? 0))
        print(String(format: "FLEX-BEND his top A: shown depths %.2f–%.2f mm × %.0f; the quads' shown dent spans %.2f–%.2f mm along the load (want a span ≥ %.2f × corner-averaging)",
                     depths.min() ?? 0, depths.max() ?? 0, c.exaggeration, lo, hi, want))
        XCTAssertGreaterThan(c.exaggeration, 1)
        XCTAssertGreaterThan(hi, 3, "the bend reads edge-on: several mm along the load")
        // corners are the mean of up to four columns, so the span is at least half of k·range
        XCTAssertGreaterThanOrEqual(hi - lo, 0.5 * want)
    }
}
