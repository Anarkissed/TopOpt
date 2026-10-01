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
    /// the depth chip and prism, the selected face and the X-ray ghost are drawn apart from the
    /// dent's ramp so the map reads against them.
    /// ★ RE-PINNED (batch M, M7): the dent's ramp is now the FEA rainbow — it spans blue … red, so a
    /// hue window no longer says "apart". The rule is now: the on-part marks, the selected face and
    /// the ghost are NEUTRAL (unsaturated — no rainbow colour is), and the prism (his lattice-stage
    /// purple, by his explicit request) is no ramp colour (≥ 0.2 RGB from every one).
    /// RED CONTROLS: the ghost's old cyan is saturated (it would read as the map); a ramp colour
    /// itself sits at distance 0.
    @MainActor
    func testWhatIsDrawnOnThePartIsNotTheMapsColour() throws {
        let ramp = (0...40).map { FlexibleColours.depthColour(fraction: Double($0) / 40) }
        func nearestRamp(_ c: RGBA) -> Double {
            ramp.map { r in ((r.r - c.r) * (r.r - c.r) + (r.g - c.g) * (r.g - c.g) + (r.b - c.b) * (r.b - c.b)).squareRoot() }.min() ?? 1
        }
        func neutral(_ c: RGBA) -> Bool { Self.hueSat(c).s < 0.15 }
        let sel = FlexibleColours.selectedFace, g = FlexibleColours.ghost
        for (name, c) in [("on-part", FlexibleStageStyle.onPartToken),
                          ("selected face", RGBA(Double(sel.x) * 255, Double(sel.y) * 255, Double(sel.z) * 255)),
                          ("the X-ray ghost", RGBA(Double(g.x) * 255, Double(g.y) * 255, Double(g.z) * 255))] {
            XCTAssertTrue(neutral(c), "\(name) is neutral — never a rainbow colour")
            XCTAssertFalse(Self.isPurple(c), "\(name) is never purple")
        }
        let prism = nearestRamp(FlexibleStageStyle.facePrismToken)
        print(String(format: "FLEX-RAMP the prism's nearest ramp colour: %.3f RGB", prism))
        XCTAssertGreaterThan(prism, 0.2, "the prism is no ramp colour")
        // ★ RED CONTROLS: the old cyan ghost is saturated; a ramp colour is at distance 0
        XCTAssertFalse(neutral(DS.Color.accentCyan), "control: the old cyan ghost would read as the map")
        XCTAssertLessThan(nearestRamp(ResultsModel.stressColor(fraction: 0.5)), 1e-9, "control: the instrument finds a ramp colour")
        // the call sites use them
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        func src(_ f: String) throws -> String { try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8) }
        XCTAssertTrue(try src("FlexibleStagePage.swift").contains("tint: FlexibleStageStyle.onPart,"), "the curves")
        // ★ RE-PINNED (round 4, batch D1 — HIS explicit request, img 2: "please use the same purple
        // used in the rest of the lattice area's face-prisms"): the depth prism and its chip are the
        // lattice stage's face prism and depth knob (FlexibleSettingsRound4Tests reads #354's line)
        XCTAssertTrue(try src("FlexibleDepthPrism.swift").contains("tint: FlexibleStageStyle.facePrismTint)"), "the prism")
        let chips = try src("FlexibleDepthChips.swift")
        XCTAssertTrue(chips.contains("FlexibleStageStyle.facePrismKnob"), "the chip")
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

    /// ★ BATCH M (M7, his round-5 img 6): "the FEA physics view and the dent view can't be viewed
    /// together … we can use the same colours. Please switch the dent colours to the original FEA
    /// legend colours" — "and this is in BOTH views". The dent's ramp IS ResultsModel.stressColor, on
    /// the Settings page (its map and its legend) and the main page (its map, its legend), and the
    /// main page's Stress view reads the SAME ramp (one rainbow on the page — the two views are never
    /// on together). This deliberately overturns his earlier "deep blue → cyan → white" and the
    /// round-3 rule "the dent ramp is its own, never the Stress rainbow". Never purple.
    /// RED CONTROLS: the old ramp (accentDeep → accentCyan → textPrimary) is caught by the same
    /// assertions; the DS purple is caught by the purple instrument.
    @MainActor
    func testTheDentRampIsTheFEARainbowOnBothPagesAndNeverPurple() throws {
        let fractions = (0...40).map { Double($0) / 40 }
        func same(_ a: RGBA, _ b: RGBA) -> Bool { abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9 }
        let fea = fractions.map { ResultsModel.stressColor(fraction: $0) }
        XCTAssertTrue(zip(fractions, fea).allSatisfy { same(FlexibleColours.depthColour(fraction: $0), $1) }, "the dent's ramp is the FEA rainbow")
        // every legend that shows the dent, and the main page's Stress view, read it
        XCTAssertTrue(zip(fractions, fea).allSatisfy { same(FlexibleReadKind.dent.rampColour($0), $1) }, "the main page's dent legend")
        XCTAssertTrue(zip(fractions, fea).allSatisfy { same(FlexibleReadKind.stress.rampColour($0), $1) }, "the Stress view: the SAME rainbow")
        for (f, c) in zip(fractions, fea) {
            let s = FlexibleColours.stressTint(fraction: f)
            XCTAssertLessThan(abs(Double(s.x) - c.r) + abs(Double(s.y) - c.g) + abs(Double(s.z) - c.b), 1e-6, "the Stress tint")
        }
        // the map on the part: a quad's colour at value v is the ramp at v / the scale
        let mm = FlexibleColours.depth(3, max: 12)
        let at = ResultsModel.stressColor(fraction: 0.25)
        XCTAssertLessThan(abs(Double(mm.x) - at.r) + abs(Double(mm.y) - at.g) + abs(Double(mm.z) - at.b), 1e-6, "the map's quads")
        // the Settings page's legend and panel read depthColour (source: they follow it)
        let root = FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Sources/TopOptFlows")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("FlexibleStagePage.swift"), encoding: .utf8)
            .contains("FlexibleColours.depthColour(fraction: Double(i) / 23)"), "the Settings page's legend")
        // never purple
        XCTAssertFalse(fea.contains(where: Self.isPurple), "never purple")
        XCTAssertFalse(FlexibleColours.depthStops.contains(where: Self.isPurple))
        XCTAssertTrue(Self.isPurple(DS.Color.accentPurple), "control: the DS purple is purple")
        // ★ RED CONTROL: the old ramp is caught by the first assertion's instrument
        func old(_ f: Double) -> RGBA {
            let stops = [DS.Color.accentDeep, DS.Color.accentCyan, DS.Color.textPrimary]
            let x = min(1, max(0, f)) * 2
            let i = min(1, Int(x)), t = x - Double(i)
            let a = stops[i], b = stops[i + 1]
            return RGBA((a.r + (b.r - a.r) * t) * 255, (a.g + (b.g - a.g) * t) * 255, (a.b + (b.b - a.b) * t) * 255)
        }
        XCTAssertFalse(zip(fractions, fea).allSatisfy { same(old($0), $1) }, "control: the old deep blue → white ramp is not the FEA rainbow")
        let hues = fea.filter { Self.hueSat($0).s > 0.15 }.map { Self.hueSat($0).h }
        print(String(format: "FLEX-RAMP the dent ramp = the FEA rainbow: hue %.0f° … %.0f°", hues.min() ?? 0, hues.max() ?? 0))
        XCTAssertGreaterThan((hues.max() ?? 0) - (hues.min() ?? 0), 150, "a rainbow: blue … red")
    }

}
