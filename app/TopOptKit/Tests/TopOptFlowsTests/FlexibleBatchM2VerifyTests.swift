// FlexibleBatchM2VerifyTests — batch M2's verification (task 2026-09-29-flexible-screens, round 5):
// what the verifier found in batch M2's Settings-page stamp dent (FlexibleStampSpread), pinned on HIS
// project and on C1's pad.
//   * His Face 3 lost its four fingertip foci: σ_near was 0.25 × the face's lattice depth — 25 mm on his
//     100 mm-deep side, wider than the fingertips' 17–19 mm spacing — so the Settings page drew ONE hill
//     where the main page's sim shows four foci. The pad test (20 mm deep, σ 5 mm) never saw it.
//   * A dragged stamp popped when core's new design landed: the spread's three numbers were read from
//     the LAST design under the stamp's NEW footprint (its "outside" density under the new place).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchM2VerifyTests: XCTestCase {

    /// One face's dent SHAPE on both pages — each over the face's own deepest: the main page's map per
    /// column (the mean of its quad's six vertex values: the sim's mm) and the Settings page's column dent.
    static func shapes(_ stage: FlexibleMainStage, _ m: FlexibleStageModel, region: Int) throws
        -> (main: [Double], settings: [Double], foot: [Double], st: FlexStackInfo, key: FlexFaceKey) {
        let key = try XCTUnwrap(m.key(region)), st = try XCTUnwrap(m.stacks[key])
        let o = try XCTUnwrap(stage.overlay), start = try XCTUnwrap(o.flatStart[key])
        let heat = try XCTUnwrap(stage.heatValues)
        func shape(_ x: [Double]) -> [Double] {
            let top = x.filter(\.isFinite).max() ?? 0
            return x.map { $0.isFinite && top > 0 ? $0 / top : .nan }
        }
        let mainMM: [Double] = st.columns.indices.map { c in
            let v = (0..<6).map { Double(heat[start + 6 * c + $0]) }
            return v.allSatisfy(\.isFinite) ? v.reduce(0, +) / 6 : .nan
        }
        let v = FlexibleShownValues(model: m).values[key] ?? []
        let settingsMM: [Double] = st.columns.indices.map { c in
            if c < v.count, case .depth(let d) = v[c] { return d }
            return .nan
        }
        return (shape(mainMM), shape(settingsMM), try XCTUnwrap(m.stampFootprint(region)), st, key)
    }

    /// The whole face's RMS between two shapes (columns where both have a value).
    static func rms(_ a: [Double], _ b: [Double]) -> Double {
        let d = zip(a, b).compactMap { $0.isFinite && $1.isFinite ? $0 - $1 : nil }
        return d.isEmpty ? .nan : (d.map { $0 * $0 }.reduce(0, +) / Double(d.count)).squareRoot()
    }

    /// The row of columns through most of the stamp's footprint, in u order.
    static func row(_ st: FlexStackInfo, foot: [Double]) throws -> [Int] {
        var sum: [Int: Double] = [:]
        for (c, col) in st.columns.enumerated() { sum[col.iv, default: 0] += foot[c] }
        let iv = try XCTUnwrap(sum.max { $0.value < $1.value }?.key)
        return st.columns.indices.filter { st.columns[$0].iv == iv }.sorted { st.columns[$0].iu < st.columns[$1].iu }
    }

    /// His round-5 project through Save & Exit, every sim landed.
    func hisRound5Landed() async throws -> (FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (stage, m)
    }

    /// ★ The verifier's finding: on HIS Face 3 (Group 2's four fingertips, a 100 mm-deep lattice) the
    /// Settings page drew one hill and no foci, where the main page's sim shows four. Along the row through
    /// the fingertips, each page over the face's own deepest (the SHAPE — the colours agree only when both
    /// legends top at the face, see FlexibleBatchM2Tests), the Settings dent now rises and dips where the
    /// sim's does, about as much; the whole face agrees column for column.
    /// RED CONTROL (same instrument, same project): batch M2's rule — σ_near 0.25 × 100 mm = 25 mm.
    func testHisFace3KeepsItsFourFingertipFociOnTheSettingsPage() async throws {
        defer { FlexibleStampSpread.controlRule = nil }
        let (stage, m) = try await hisRound5Landed()
        stage.pick("group-2"); stage.refresh()
        XCTAssertTrue(stage.fe.active, "premise: the main page's map is the 3D sim")
        let now = try Self.shapes(stage, m, region: 3)
        let row = try Self.row(now.st, foot: now.foot)
        let fNow = FlexibleBatchM2Tests.foci(now.settings, now.main, line: row, foot: now.foot)
        let rNow = Self.rms(now.settings, now.main)
        let sig = FlexibleStampSpread.sigmasMM(now.st, foot: now.foot)
        FlexibleStampSpread.controlRule = .batchM2
        let m2 = try Self.shapes(stage, m, region: 3)
        FlexibleStampSpread.controlRule = nil
        let fM2 = FlexibleBatchM2Tests.foci(m2.settings, m2.main, line: row, foot: now.foot)
        let rM2 = Self.rms(m2.settings, m2.main)
        func line(_ x: [Double]) -> String { stride(from: 0, to: row.count, by: 3).map { String(format: "%.2f", x[row[$0]]) }.joined(separator: " ") }
        print("FLEX-M2V FACE3 row main:     \(line(now.main))")
        print("FLEX-M2V FACE3 row settings: \(line(now.settings))")
        print("FLEX-M2V FACE3 row batch M2: \(line(m2.settings))")
        print(String(format: "FLEX-M2V FACE3 (lattice %.0f mm, feature %.1f mm, σ %.1f / %.1f mm): foci correlation %.2f, %.2f × the sim's swing · whole face RMS %.3f | batch M2's rule %.2f, %.2f ×, RMS %.3f",
                     now.st.latticeMMMean, FlexibleStampSpread.featureMM(now.foot, stack: now.st), sig.near, sig.far,
                     fNow.corr, fNow.size, rNow, fM2.corr, fM2.size, rM2))
        // the other stamp faces of his project (Group 1: Top A and Face 5) — printed, and Face 5 no worse
        stage.pick("group-1"); stage.refresh()
        for r in [FlexibleHisProject.topA, 5] {
            let a = try Self.shapes(stage, m, region: r)
            FlexibleStampSpread.controlRule = .batchM2
            let b = try Self.shapes(stage, m, region: r)
            FlexibleStampSpread.controlRule = nil
            print(String(format: "FLEX-M2V face %d: whole face RMS %.3f | batch M2's rule %.3f", r, Self.rms(a.settings, a.main), Self.rms(b.settings, b.main)))
            XCTAssertLessThanOrEqual(Self.rms(a.settings, a.main), Self.rms(b.settings, b.main) + 1e-9, "face \(r): no worse than batch M2")
        }
        XCTAssertGreaterThan(row.count, 40)
        XCTAssertGreaterThan(fNow.corr, 0.9, "his Face 3: the fingertips' foci are where the main page's are")
        XCTAssertTrue(fNow.size > 0.5 && fNow.size < 1.5, "his Face 3: …and about as strong (\(fNow.size) × the main page's)")
        XCTAssertLessThanOrEqual(rNow, 0.08, "his Face 3: the whole face agrees with the sim column for column")
        XCTAssertLessThan(sig.near, 0.25 * now.st.latticeMMMean, "a fingertip's focus is as wide as the fingertip, not the 100 mm depth")
        // ★ RED CONTROL: batch M2's rule draws one hill — the foci gone
        XCTAssertFalse(fM2.corr > 0.9 && fM2.size > 0.5 && fM2.size < 1.5, "control: batch M2's rule loses the foci (\(fM2.corr), \(fM2.size) ×)")
    }

    // MARK: - a whole-face rigid plate

    /// C1's pad with the library stamp `id` on its top through Save & Exit, the main page's sim landed.
    func landedPad(_ id: String, kg: Double, deepest: Double) async throws -> (FlexibleMainStage, FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        _ = m.press(top, kg: kg)
        m.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleHisProject.waitFor(60, "the top's stack") { m.stack(top) != nil }
        m.setShape(top, "stamp")
        let shape = try XCTUnwrap(m.library?.stamps.first { $0.id == id })
        m.setStamp(top, source: .library(shape.id), shape: shape)
        m.edit { s in if var f = s.face(top) { f.deepestMM = deepest; s.setFace(f) } }
        try await FlexibleHisProject.waitFor(60, "the stamp's grid") { m.stampDent(top) != nil }
        try await FlexibleSquishFixture.settle(m, "the \(id) pad")
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "the \(id) pad's sim") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (stage, m, top)
    }

    /// ★ The verifier's finding (minor): the library's RIGID "Flat plate (whole face)" draws as a dome on the
    /// Settings page, where "a rigid plate moves the face as one plane". Measured against the main page's
    /// 3D sim of the very same plate (core reads a rigid design stamp as its force over its area — an even
    /// press): the sim does NOT sink the face as one plane either — its middle is flat (0.93–0.98) and C1's
    /// side walls hold the outline at ~0.07 of the deepest. So the Settings page keeps the spread: its
    /// middle flat like the sim's, its outline lower than its middle. A full sink under the plate (the
    /// suggested fix) is FURTHER from the main page — the RED control, by the same instrument.
    /// NOT matched (stated): the outline's depth (~0.5 here, the sim's ~0.07 — the walls).
    func testAWholeFaceRigidPlateFollowsTheMainPagesSim() async throws {
        let (stage, m, top) = try await landedPad("flat_plate", kg: 10, deepest: 4)
        XCTAssertTrue(stage.fe.active, "premise: the main page's map is the 3D sim")
        XCTAssertEqual(m.settings.face(top)?.activeStamp?.rigid, true, "premise: the library's flat plate is rigid")
        let s = try Self.shapes(stage, m, region: top)
        XCTAssertTrue(s.foot.allSatisfy { $0 >= 0.99 }, "premise: the plate covers the whole face")
        let full = s.foot.map { $0 >= 0.5 ? 1.0 : 0.0 }          // the control: one plane, the full sink
        let middle = s.st.columns.indices.filter { (16..<48).contains(s.st.columns[$0].iu) && (16..<48).contains(s.st.columns[$0].iv) }
        let outline = s.st.columns.indices.filter { let c = s.st.columns[$0]; return c.iu == 0 || c.iv == 0 || c.iu == s.st.nu - 1 || c.iv == s.st.nv - 1 }
        func spread(_ x: [Double]) -> Double { let v = middle.map { x[$0] }; return (v.max() ?? 0) - (v.min() ?? 0) }
        func median(_ x: [Double], _ ids: [Int]) -> Double { let v = ids.map { x[$0] }.sorted(); return v[v.count / 2] }
        let rNow = Self.rms(s.settings, s.main), rFull = Self.rms(full, s.main)
        print(String(format: "FLEX-M2V PLATE flat plate 10 kg / 4 mm on C1's pad: the middle half's spread main %.3f · Settings %.3f · one plane %.3f | the outline's median main %.3f · Settings %.3f · one plane %.3f | whole face RMS vs main: Settings %.3f · one plane %.3f",
                     spread(s.main), spread(s.settings), spread(full), median(s.main, outline), median(s.settings, outline), median(full, outline), rNow, rFull))
        XCTAssertLessThan(spread(s.main), 0.1, "premise: the sim's middle sinks evenly under the plate")
        XCTAssertLessThan(spread(s.settings), 0.1, "the Settings page's middle sinks evenly too")
        XCTAssertLessThan(median(s.main, outline), 0.5 * median(s.main, middle), "premise: the sim's outline stays up (C1's walls)")
        XCTAssertLessThan(median(s.settings, outline), 0.9, "the Settings page's outline stays above the middle, as the sim's does")
        XCTAssertLessThanOrEqual(rNow, 0.26, "the whole face is closer to the main page than a single plane is")
        // ★ RED CONTROL: one plane (the full sink under the plate) is further from the main page
        XCTAssertGreaterThan(rFull, 0.26, "control: a full sink under the plate is not what the main page shows")
        XCTAssertGreaterThanOrEqual(median(full, outline), 0.9, "control: a full sink pulls the outline all the way down")
    }

    // MARK: - a dragged stamp

    /// C1's pad (100 × 100 × 20) with the library stamp `id` on its top (`kg`, `deepest`), its bottom
    /// resting; core's design landed (no lattice built).
    func stampPad(_ id: String, kg: Double, deepest: Double) async throws -> (FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        _ = m.press(top, kg: kg)
        m.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleHisProject.waitFor(60, "the top's stack") { m.stack(top) != nil }
        m.setShape(top, "stamp")
        let shape = try XCTUnwrap(m.library?.stamps.first { $0.id == id })
        m.setStamp(top, source: .library(shape.id), shape: shape)
        m.edit { s in if var f = s.face(top) { f.deepestMM = deepest; s.setFace(f) } }
        try await FlexibleHisProject.waitFor(60, "the stamp's grid") { m.stampDent(top) != nil }
        try await FlexibleSquishFixture.settle(m, "the \(id) pad")
        return (m, top)
    }

    /// ★ The verifier's finding: a dragged stamp POPPED when core's new design landed — the three numbers
    /// (even press, density under / outside) were read from the last design under the stamp's NEW
    /// footprint. A thumb at 10 kg / 4 mm (the worst case measured), dragged 20 mm: the dent the page draws
    /// at once (core's design still the old place's) against the dent once the new design lands.
    /// RED CONTROL (same instrument): the M2 rule's three numbers — the old design read under the new footprint.
    func testADraggedStampDoesNotPopWhenCoresDesignLands() async throws {
        let (m, top) = try await stampPad("thumb", kg: 10, deepest: 4)
        let key = try XCTUnwrap(m.key(top)), st = try XCTUnwrap(m.stacks[key])
        let old = try XCTUnwrap(m.designs[key], "premise: core designed the stamp's place")
        let before = try XCTUnwrap(m.stampDent(top))
        let feature = FlexibleStampSpread.featureMM(try XCTUnwrap(m.stampFootprint(top)), stack: st)
        m.updateStamp(top) { $0.centreU += 20 }
        XCTAssertEqual(m.designs[key], old, "premise: the page draws before core's new design lands")
        let atOnce = try XCTUnwrap(m.stampDent(top))
        let foot = try XCTUnwrap(m.stampFootprint(top))
        // the control: the M2 rule's numbers — the old design's columns under the NEW footprint
        var stale = FlexibleStampSpread.Design()
        do {
            func median(_ x: [Double]) -> Double? { x.isEmpty ? nil : x.sorted()[x.count / 2] }
            let peak = old.columns.map(\.pressureMPa).max() ?? 0
            let under = foot.indices.filter { foot[$0] >= 0.5 }, outside = foot.indices.filter { foot[$0] < 0.05 }
            if peak > 0, let p = median(outside.map { old.columns[$0].pressureMPa }) { stale.background = min(1, max(0, p / peak)) }
            let ru = median(under.map { old.columns[$0].targetDensity }) ?? 0
            stale.densityUnder = max(0, ru)
            stale.densityOutside = max(0, median(outside.map { old.columns[$0].targetDensity }) ?? ru)
        }
        let control = FlexibleStampSpread.dent(foot, stack: st, design: stale)
        try await FlexibleHisProject.waitFor(60, "core's new design") { m.designs[key] != old }
        try await FlexibleSquishFixture.settle(m, "the dragged thumb")
        let landed = try XCTUnwrap(m.stampDent(top))
        func pop(_ a: [Double], _ b: [Double]) -> (rms: Double, max: Double) {
            let d = zip(a, b).map { $0 - $1 }
            return ((d.map { $0 * $0 }.reduce(0, +) / Double(max(1, d.count))).squareRoot(), d.map(abs).max() ?? 0)
        }
        let p = pop(atOnce, landed), c = pop(control, landed), moved = pop(before, atOnce)
        let now = FlexibleStampSpread.Design(m.designs[key], columns: foot.count)
        print(String(format: "FLEX-M2V DRAG thumb 10 kg / 4 mm (feature %.1f mm), 20 mm: the dent moved at once by RMS %.3f · the pop when the new design lands RMS %.3f max %.3f | the M2 rule's numbers RMS %.3f max %.3f (background %.3f→%.3f, under %.3f→%.3f)",
                     feature, moved.rms, p.rms, p.max, c.rms, c.max, stale.background, now.background, stale.densityUnder, now.densityUnder))
        XCTAssertGreaterThan(moved.rms, 0.05, "premise: the dent follows the finger at once")
        XCTAssertLessThan(p.rms, 0.01, "nothing jumps when core's new design lands")
        XCTAssertLessThan(p.max, 0.03, "…anywhere on the face")
        XCTAssertTrue((8.0...11.0).contains(feature), "a thumb pad's feature is about half its 20 mm width (\(feature) mm)")
        // ★ RED CONTROL: the M2 rule's numbers pop
        XCTAssertGreaterThan(c.rms, 0.04, "control: the old design read under the new footprint pops")
    }
}
#endif
