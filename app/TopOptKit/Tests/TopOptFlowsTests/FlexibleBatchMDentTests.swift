// FlexibleBatchMDentTests — the dent visuals of his round-5 feedback, on BOTH pages, on HIS project
// as he left it for round 5 (his_project_0004_r5: Group 1 = Top A's elbow + Top B + Face 5's thumb,
// Group 2 = Face 3's four fingertips) — task 2026-09-29-flexible-screens, round 5 batch M.
//   M5 (img 5): "The dent colours are not expanding out and graded. They are a singular colour and
//       have a direct cut between colours" — "in both views": the heat is coloured PER VERTEX by the
//       value at that point, continuous across every quad edge. RED: one colour per column.
//   M2 (img 4): "the stamps are seen as isolated areas … it should have foci but expand out, pulling
//       lattice next to it in, combining the foci into a single input" — the Settings page's designed
//       squish spreads out of each fingertip and the four merge; the main page's heat is the 3D sim's
//       own dent, which spreads. RED: the footprint alone (D1's rule) / core's per-column numbers.
//   A tap reads the colour under it (the value blended as the GPU blends the colour).
#if canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchMDentTests: XCTestCase {

    /// The largest colour difference between map vertices of `key` that sit at the SAME place (two
    /// quads' shared corner) — 0 for a continuous heat, the step between two columns for blocks.
    /// `only`: the columns to compare (nil: every column of the face).
    static func seamJump(_ tints: [Float], overlay o: FlexibleOverlayMesh, key: FlexFaceKey, columns: Int,
                         only: Set<Int>? = nil) -> (jump: Float, shared: Int) {
        guard let start = o.flatStart[key] else { return (0, 0) }
        let pos = o.mesh.flat.positions
        var byPlace: [SIMD3<Int32>: [Int]] = [:]
        for v in start..<(start + columns * 6) where v * 8 + 3 < tints.count && tints[v * 8 + 3] > 0
            && only.map({ $0.contains((v - start) / 6) }) != false {
            let p = SIMD3<Float>(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2])
            byPlace[SIMD3<Int32>(p * 1000, rounding: .toNearestOrEven), default: []].append(v)
        }
        var jump: Float = 0, shared = 0
        for vs in byPlace.values where vs.count > 1 {
            shared += 1
            for a in vs { for b in vs {
                let d = simd_length(SIMD3(tints[a * 8], tints[a * 8 + 1], tints[a * 8 + 2]) - SIMD3(tints[b * 8], tints[b * 8 + 1], tints[b * 8 + 2]))
                jump = max(jump, d)
            } }
        }
        return (jump, shared)
    }

    /// The four-fingertip stamp's VALLEYS: columns inside the stamp's box that it does not cover.
    static func valleys(_ m: FlexibleStageModel, _ r: Int) throws -> [Int] {
        let st = try XCTUnwrap(m.stack(r)), p = try XCTUnwrap(m.settings.face(r)?.activeStamp)
        let cov = try XCTUnwrap(m.stampCoverage(r))
        return st.columns.indices.filter { c in
            abs(st.columns[c].uMM - p.centreU) < p.widthMM / 2 && abs(st.columns[c].vMM - p.centreV) < p.lengthMM / 2 && cov[c] < 0.05
        }
    }

    // MARK: the Settings page (M5 + M2)

    func testTheSettingsPageHeatIsGradedAndTheFingertipsMergeIntoOnePress() async throws {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        try await FlexibleHisProject.waitFor(60, "the stamps' grids") { m.stampFootprint(3) != nil && m.stampFootprint(5) != nil }
        await m.waitForIdle()
        let key = try XCTUnwrap(m.key(3)), st = try XCTUnwrap(m.stacks[key])
        let f = try XCTUnwrap(m.settings.face(3))
        // the page's own call (FlexibleStagePage.refreshChannels: X-ray, no lattice drawn)
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let now = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: nil)
        let old = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: true, drawnLattice: nil, controlColumnColours: true)
        let tNow = try XCTUnwrap(now.tints), tOld = try XCTUnwrap(old.tints)
        // ── M5: continuous — a shared quad corner carries ONE colour ──
        let a = Self.seamJump(tNow, overlay: overlay, key: key, columns: st.columns.count)
        let b = Self.seamJump(tOld, overlay: overlay, key: key, columns: st.columns.count)
        print(String(format: "FLEX-M SETTINGS heat on Face 3: largest colour step at a shared corner %.4f (%d corners) · one colour per column (D1): %.4f",
                     a.jump, a.shared, b.jump))
        XCTAssertGreaterThan(a.shared, 500)
        XCTAssertLessThan(a.jump, 1e-4, "no step between neighbouring quads: the heat is graded across the map")
        XCTAssertGreaterThan(b.jump, 0.05, "control: one colour per column steps at every quad edge")
        // ── M2: the designed squish spreads out of each fingertip and the four merge ──
        let shown = FlexibleShownValues(model: m)
        let depth: [Double] = (shown.values[key] ?? []).map { if case .depth(let d) = $0 { return d } else { return 0 } }
        var inputs = FlexibleShownValues.inputs(m)
        inputs.stampFootprints[key] = try XCTUnwrap(m.stampFootprint(3))   // ★ RED: D1's footprint (no spread)
        let d1: [Double] = (FlexibleShownValues(inputs, drawnLattice: nil).values[key] ?? []).map { if case .depth(let d) = $0 { return d } else { return 0 } }
        let vs = try Self.valleys(m, 3)
        func mean(_ x: [Double], _ ids: [Int]) -> Double { ids.isEmpty ? 0 : ids.map { x[$0] }.reduce(0, +) / Double(ids.count) }
        print(String(format: "FLEX-M SETTINGS Face 3 (σ %.1f mm): between the fingertips (%d columns) the dent is %.0f%% of the deepest · the footprint alone %.0f%%",
                     FlexibleStampSpread.sigmaMM(st), vs.count, 100 * mean(depth, vs) / f.deepestMM, 100 * mean(d1, vs) / f.deepestMM))
        XCTAssertGreaterThan(vs.count, 10)
        XCTAssertGreaterThanOrEqual(mean(depth, vs) / f.deepestMM, 0.85, "the four fingertips merge into one press")
        XCTAssertLessThan(mean(d1, vs) / f.deepestMM, 0.5, "control: the footprint alone leaves four pits")
        XCTAssertEqual(depth.max() ?? 0, f.deepestMM, accuracy: 1e-9, "the deepest squish is still the stamp's sink")
        // no hard cut at the footprint's edge: the largest step between neighbouring columns
        func step(_ x: [Double]) -> Double {
            var s = 0.0
            for (c, col) in st.columns.enumerated() {
                for n in [st.column(col.iu + 1, col.iv), st.column(col.iu, col.iv + 1)] where n >= 0 && n < x.count { s = max(s, abs(x[c] - x[n])) }
            }
            return s / f.deepestMM
        }
        print(String(format: "FLEX-M SETTINGS Face 3: the largest step between neighbouring columns %.0f%% of the deepest · the footprint alone %.0f%%",
                     100 * step(depth), 100 * step(d1)))
        XCTAssertLessThan(step(depth), 0.25, "graded out of the stamp, no cut")
        XCTAssertGreaterThan(step(d1), 0.25, "control: the footprint's own wall")
        // Top A's elbow on a 20 mm top spreads less than Face 3's fingertips on a 100 mm-deep side.
        // ★ RE-PINNED BY BATCH M2 (V10 of batch M's verification: the Settings dent was a steep trench that
        // disagreed with the main page's sim): the spread is now ONE Gaussian of σ = 0.45 × the face's
        // lattice depth over core's press / stiffness (FlexibleStampSpread.dent, fitted to the 3D sim —
        // FlexibleBatchM2Tests), no longer batch M's e^(−r / 0.2·depth) wall; the depth rule is the same
        let ka = try XCTUnwrap(m.key(FlexibleHisProject.topA)), sa = try XCTUnwrap(m.stacks[ka])
        let la = FlexibleStampSpread.sigmaMM(sa), ls = FlexibleStampSpread.sigmaMM(st)
        print(String(format: "FLEX-M SETTINGS spread σ: Top A (lattice %.1f mm) %.1f mm · Face 3 (lattice %.1f mm) %.1f mm",
                     sa.latticeMMMean, la, st.latticeMMMean, ls))
        XCTAssertEqual(la, 0.45 * sa.latticeMMMean, accuracy: 1e-9)
        XCTAssertEqual(ls, 0.45 * st.latticeMMMean, accuracy: 1e-9)
        // ── a tap reads the colour under it (the blend of its triangle's corners) ──
        let start = try XCTUnwrap(overlay.flatStart[key])
        let vals = try XCTUnwrap(now.mapValues)
        var checked = 0, off = 0
        for c in stride(from: 0, to: st.columns.count, by: 37) {
            let q = start + c * 6
            let pos = overlay.mesh.flat.positions
            func p(_ v: Int) -> SIMD3<Float> { SIMD3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]) }
            let at = 0.6 * p(q) + 0.25 * p(q + 1) + 0.15 * p(q + 2)   // off the column's centre
            guard let reading = FlexibleProbe.dentReading(model: m, overlay: overlay, dents: nil, scale: 0, drawnLattice: nil,
                                                          point: at, dir: SIMD3<Float>(st.load)) else { continue }
            let expect = 0.6 * vals[q] + 0.25 * vals[q + 1] + 0.15 * vals[q + 2]
            guard expect.isFinite, let got = Double(reading.value) else { continue }
            checked += 1
            XCTAssertEqual(got, Double(expect), accuracy: 0.006, "the reading is the colour's own value there")
            if abs(depth[c] - Double(expect)) > 0.01 { off += 1 }
        }
        print("FLEX-M SETTINGS taps: \(checked) read the blended value · \(off) of them differ from the column's own number (the old reading)")
        XCTAssertGreaterThan(checked, 10)
        XCTAssertGreaterThan(off, 0, "control: the per-column reading is another number off the column's centre")
    }

    // MARK: the main page (M5 + M2: the 3D sim's own dent)

    /// His round-5 project through Save & Exit, every sim landed.
    func round5() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his round 5")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "his round 5: the sims") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (r, stage, m)
    }

    func testTheMainPageHeatIsTheSimsDentGradedAndSpreadOutOfEachStamp() async throws {
        let (r, stage, m) = try await round5()
        let overlay = try XCTUnwrap(stage.overlay)
        for (g, face) in [("group-2", 3), ("group-1", FlexibleHisProject.topA)] {
            stage.pick(g)
            stage.controlColumnHeat = false
            stage.refresh()
            XCTAssertTrue(stage.fe.active, g)
            let key = try XCTUnwrap(m.key(face)), st = try XCTUnwrap(m.stacks[key])
            let start = try XCTUnwrap(overlay.flatStart[key])
            let tNow = try XCTUnwrap(stage.channels?.tints)
            let vals = try XCTUnwrap(stage.heatValues)
            // every column of the stamp face is the sim's (no "no number" grey)
            let col = { (c: Int) -> Double in
                let vs = (0..<6).map { Double(vals[start + c * 6 + $0]) }
                return vs.allSatisfy(\.isFinite) ? vs.reduce(0, +) / 6 : .nan
            }
            let sim = st.columns.indices.map(col)
            let missing = sim.filter { !$0.isFinite }.count
            // ── M5: continuous ──
            // ★ MERGE WITH BATCH S: the face's outermost columns are S1's group FRAME (a uniform band in
            // the group's colour, then a near-black gap — deliberately NOT the heat; D-R5-S1), so the
            // heat's grading is measured over the heat band; the whole face reads the frame's edge
            let heatBand = Set(FlexibleGroupFrames.bands(st).enumerated().filter { $0.element == .heat }.map(\.offset))
            let a = Self.seamJump(tNow, overlay: overlay, key: key, columns: st.columns.count, only: heatBand)
            let whole = Self.seamJump(tNow, overlay: overlay, key: key, columns: st.columns.count)
            XCTAssertGreaterThanOrEqual(a.shared, st.columns.count / 2, "\(g): the heat band's shared corners are measured")
            XCTAssertGreaterThan(whole.jump, 0.05, "\(g): the frame's edge is a step (S1) — the band excluded is the frame")
            // ── M2: spread out of the stamp (its ring 0–3 mm outside, over under it) ──
            let cov = try XCTUnwrap(m.stampCoverage(face))
            let inside = st.columns.indices.filter { cov[$0] >= 0.5 }
            let ring = st.columns.indices.filter { c in
                guard cov[c] < 0.5 else { return false }
                let d = inside.map { hypot(st.columns[$0].uMM - st.columns[c].uMM, st.columns[$0].vMM - st.columns[c].vMM) }.min()! - st.pitchMM / 2
                return d <= 3
            }
            func mean(_ x: [Double], _ ids: [Int]) -> Double {
                let v = ids.map { x[$0] }.filter(\.isFinite)
                return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
            }
            // ★ RED CONTROL: one colour per column from core's numbers (batch G's heat)
            stage.controlColumnHeat = true
            stage.refresh()
            let tOld = try XCTUnwrap(stage.channels?.tints)
            let b = Self.seamJump(tOld, overlay: overlay, key: key, columns: st.columns.count, only: heatBand)
            let shownOld = FlexibleShownValues(model: m, drawnLattice: stage.drawn)
            let core: [Double] = (shownOld.values[key] ?? []).map { if case .depth(let d) = $0 { return d } else { return .nan } }
            let grey = core.filter { !$0.isFinite }.count
            stage.controlColumnHeat = false
            stage.refresh()
            print(String(format: "FLEX-M MAIN %@ face %d: heat = the sim's dent on %d of %d columns (core's numbers: %d grey 'no number') · step at a shared corner of the heat band %.4f (core's columns %.4f; the whole face with S1's frame %.4f) · ring 0–3 mm %.0f%% of under the stamp (core's %.0f%%) · scale %.2f mm",
                         g, face, st.columns.count - missing, st.columns.count, grey, a.jump, b.jump, whole.jump,
                         100 * mean(sim, ring) / mean(sim, inside), 100 * mean(core, ring) / mean(core, inside), stage.dentMaxMM))
            XCTAssertEqual(missing, 0, "\(g): the sim colours every column of its face")
            XCTAssertLessThan(a.jump, 1e-4, "\(g): graded — no step between quads")
            XCTAssertGreaterThan(b.jump, 0.05, "\(g): control: core's per-column colours step")
            XCTAssertGreaterThanOrEqual(mean(sim, ring) / mean(sim, inside), 0.45, "\(g): the press drags the face round it")
            XCTAssertLessThan(mean(core, ring) / mean(core, inside), 0.45, "\(g): control: core's columns leave the stamp an island")
            // the colour IS the ramp at value / the one scale
            let v = start + 6 * inside[inside.count / 2]
            let c = FlexibleColours.depth(Double(vals[v]), max: stage.dentMaxMM)
            XCTAssertLessThan(simd_distance(SIMD3(tNow[v * 8], tNow[v * 8 + 1], tNow[v * 8 + 2]), SIMD3(c.x, c.y, c.z)), 1e-5)
            // ── a tap reads the sim's dent there (the blend of the colour's corners) ──
            let pos = overlay.mesh.flat.positions
            func p(_ v: Int) -> SIMD3<Float> { SIMD3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]) }
            let q = start + 6 * inside[inside.count / 3]
            let at = 0.5 * p(q) + 0.3 * p(q + 1) + 0.2 * p(q + 2)
            let reading = try XCTUnwrap(FlexibleProbe.dentReading(model: m, overlay: overlay, dents: nil, scale: 0, drawnLattice: stage.drawn,
                                                                  point: at, dir: SIMD3<Float>(st.load), mapValues: stage.shownHeatValues,
                                                                  maxMM: stage.dentMaxMM))
            let expect = 0.5 * vals[q] + 0.3 * vals[q + 1] + 0.2 * vals[q + 2]
            XCTAssertEqual(try XCTUnwrap(Double(reading.value)), Double(expect), accuracy: 0.006, "\(g): the reading is the colour's value")
        }
        _ = r
    }
}
#endif
