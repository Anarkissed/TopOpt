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
import TopOptDesign
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

    /// ★ THE DENT FOLLOWS THE CHIP (verification of round 3): while the depth chip is dragged
    /// the designs still hold the OLD deepest squish, so the map is the drawing × the NEW one —
    /// the dent fills the prism as it moves, on a filament with data too (varioShore).
    @MainActor
    func testTheDentFollowsTheChipWhileItIsDragged() throws {
        let p = try FlexibleSquishTests.pad()
        let n = p.stack.columns.count
        let s = p.design.columns.map(\.s)
        XCTAssertEqual(s.count, n)
        let face = FlexibleFaceSettings(faceRegionID: 101, weightKg: 30, deepestMM: 6)   // dragged from 3 to 6
        var inp = FlexibleShownValues.Inputs(loadedFaces: [face], stacks: [p.key: p.stack], designs: [p.key: p.design],
                                             liveS: [p.key: s], checks: [:], checkStamps: [], checkStampShown: nil,
                                             showBuildable: false, editingDepth: true)
        let dragging = FlexibleShownValues(inp, drawnLattice: nil)
        let got = (dragging.values[p.key] ?? []).compactMap { if case .depth(let d) = $0 { return d } else { return nil } }
        XCTAssertEqual(got.max() ?? 0, (s.max() ?? 0) * 6, accuracy: 1e-9, "S × the new deepest")
        XCTAssertEqual(dragging.label, "What you drew")
        // ★ RED CONTROL: not editing, the design's target (the OLD 3 mm) is shown
        inp.editingDepth = false
        let design = FlexibleShownValues(inp, drawnLattice: nil)
        let old = (design.values[p.key] ?? []).compactMap { if case .depth(let d) = $0 { return d } else { return nil } }
        XCTAssertLessThan(old.max() ?? 0, (s.max() ?? 0) * 6 - 1, "control: the design lags at the old deepest")
    }

    /// ★ "EVERYTHING IS THE SAME GREEN" (verification of round 3): the curves, their points,
    /// the depth chip and prism, the selected face and the X-ray ghost are drawn in the neutral
    /// on-part colour, so the dent's ramp (blue → cyan → white since 2026-09-30) reads against
    /// them. RED CONTROL: the ghost's old cyan sits inside the ramp's own hue family.
    @MainActor
    func testWhatIsDrawnOnThePartIsNotTheMapsGreen() throws {
        let ramp = FlexibleColours.depthStops.map(Self.hueSat).filter { $0.s > 0.15 }
        let rampHue = ramp.map(\.h).reduce(0, +) / Double(max(1, ramp.count))
        func inRamp(_ c: RGBA) -> Bool { let (h, s) = Self.hueSat(c); return s > 0.15 && abs(h - rampHue) < 30 }
        let sel = FlexibleColours.selectedFace
        for (name, c) in [("on-part", FlexibleStageStyle.onPartToken),
                          ("selected face", RGBA(Double(sel.x) * 255, Double(sel.y) * 255, Double(sel.z) * 255))] {
            XCTAssertFalse(inRamp(c), "\(name) is not the map's green")
            XCTAssertFalse(Self.isPurple(c), "\(name) is never purple")
        }
        // the X-ray ghost is not the map's hue either (it was cyan until the ramp went blue)
        let g = FlexibleColours.ghost
        XCTAssertFalse(inRamp(RGBA(Double(g.x) * 255, Double(g.y) * 255, Double(g.z) * 255)), "the ghost is not the map's hue")
        // ★ RED CONTROL: the ghost's old cyan IS in the ramp's family
        XCTAssertTrue(inRamp(DS.Color.accentCyan), "control: the old cyan ghost is the map's hue")
        // the call sites use it
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        func src(_ f: String) throws -> String { try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) }
        XCTAssertTrue(try src("FlexibleStagePage.swift").contains("tint: FlexibleStageStyle.onPart,"), "the curves")
        XCTAssertTrue(try src("FlexibleDepthPrism.swift").contains("let t = FlexibleStageStyle.onPartToken"), "the prism")
        let chips = try src("FlexibleDepthChips.swift")
        XCTAssertTrue(chips.contains("FlexibleStageStyle.onPart.opacity"), "the chip")
        XCTAssertFalse(chips.contains("FlexibleStageStyle.accent"), "the chip is not green")
    }

    // MARK: the dent's own ramp (his answer: never purple; Stress keeps its rainbow)

    /// Hue (degrees) and saturation of an RGBA.
    static func hueSat(_ c: RGBA) -> (h: Double, s: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 1e-9 else { return (0, 0) }
        var h: Double
        if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
        h *= 60; if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0)
    }
    static func isPurple(_ c: RGBA) -> Bool { let (h, s) = hueSat(c); return s > 0.15 && h >= 250 && h <= 330 }

    @MainActor
    func testTheDentRampIsItsOwnAndNeverPurple() {
        let samples = (0...20).map { FlexibleColours.depthColour(fraction: Double($0) / 20) }
        XCTAssertFalse(samples.contains(where: Self.isPurple), "never purple")
        XCTAssertFalse(FlexibleColours.depthStops.contains(where: Self.isPurple))
        // ★ RED CONTROL: the instrument sees purple when it is there
        XCTAssertTrue(Self.isPurple(DS.Color.accentPurple), "control: the DS purple is purple")
        // its own ramp: one hue family (≤ 40° of hue), brighter = deeper — unlike Stress's rainbow
        let hues = samples.filter { Self.hueSat($0).s > 0.15 }.map { Self.hueSat($0).h }
        let span = (hues.max() ?? 0) - (hues.min() ?? 0)
        let stress = (0...20).map { ResultsModel.stressColor(fraction: Double($0) / 20) }.map { Self.hueSat($0).h }
        let stressSpan = (stress.max() ?? 0) - (stress.min() ?? 0)
        func lum(_ c: RGBA) -> Double { 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
        print(String(format: "FLEX-RAMP dent ramp hue span %.0f° (Stress rainbow %.0f°), luminance %.2f → %.2f", span, stressSpan,
                     lum(samples.first!), lum(samples.last!)))
        XCTAssertLessThan(span, 40)
        XCTAssertGreaterThan(stressSpan, 150, "control: the Stress rainbow spans the hues")
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { lum($1) >= lum($0) - 1e-9 }, "brighter = deeper")
        XCTAssertNotEqual(FlexibleColours.depthColour(fraction: 0.5), ResultsModel.stressColor(fraction: 0.5),
                          "no longer the Stress rainbow")
    }
}
