// FlexibleFEVerifyGTests — the batch G verification's field findings, on HIS project as he left it
// for round 5 (his_project_0004_r5: 'Pad split top', Group 1 = Top A + Top B + Face 5's 10 kg
// thumb, Group 2 = Face 3's stamp, the bottom resting) — task 2026-09-29-flexible-screens. Each
// with its RED control:
//   * a group ALONE: the far end of its pressed stacks is its anvil (core designs the columns
//     against it) — Group 2 no longer pulls Face 5 in as a two-sided pinch — RED: bridge control
//     32768 (batch G's rule: the far end free beside a sliding rest);
//   * no field folds at the page's ×1: k · gmax(part) ≤ ½, the walls' pull-back converges
//     everywhere — RED: the same field uncapped (his Group 1 at k 2);
//   * a stamp press DRAGS its neighbours (his round-5 (b)) — RED: core's per-column squish, where
//     each column moves alone;
//   * the dent legend's line in FE mode is not "stamp: whole face" — RED: the column squish;
//   * the Squish legend's (i) says the band AND the cut, in one sentence.
#if canImport(MetalKit)
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleFEVerifyGTests: XCTestCase {

    /// His round-5 project through Save & Exit, every sim landed.
    func round5() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
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
        FlexibleSquishFixture.log(m, "his round 5")
        return (r, stage, m)
    }

    /// Face `t`'s mean surface motion INTO the part (along its own load) under `f`.
    static func inward(_ f: FlexibleFEField, _ t: FlexibleFEField.Target) -> Double {
        let load = SIMD3<Float>(t.stack.load)
        var sum = 0.0
        for c in t.stack.columns.indices {
            let e = FlexibleStackMembership.point(t.stack, column: c, t: t.stack.columns[c].entryT)
            sum += Double(simd_dot(f.sample(SIMD3<Float>(e)), load))
        }
        return sum / Double(max(1, t.stack.columns.count))
    }

    /// The walls' pull-back at scale `s` over the part's interior cells: (cells, missed by > 0.5 mm, worst mm).
    static func pullback(_ f: FlexibleFEField, _ s: Float) -> (Int, Int, Float) {
        var n = 0, bad = 0
        var worst: Float = 0
        for c in 0..<(f.nz - 1) { for b in 0..<(f.ny - 1) { for a in 0..<(f.nx - 1) {
            var all = true
            for dc in 0...1 { for db in 0...1 { for da in 0...1 where !f.solved[f.node(a + da, b + db, c + dc)] { all = false } } }
            guard all else { continue }
            let p0 = f.origin + (SIMD3<Float>(Float(a), Float(b), Float(c)) + 0.5) * f.spacing
            let e = simd_length(f.pullback(f.forward(p0, s), s) - p0)
            n += 1
            if e > 0.5 { bad += 1 }
            worst = max(worst, e)
        } } }
        return (n, bad, worst)
    }

    func testHisRound5GroupsAloneNeverFoldAndTheStampDrags() async throws {
        let (_, stage, m) = try await round5()
        let r = try XCTUnwrap(m.lastFERequest)
        let g1 = try XCTUnwrap(r.sims.first { $0.id == "group-1" }), g2 = try XCTUnwrap(r.sims.first { $0.id == "group-2" })
        let f1 = try XCTUnwrap(m.squish["group-1"]?.field), f2 = try XCTUnwrap(m.squish["group-2"]?.field)
        func target(_ sim: FlexibleFERequest.Sim, _ face: Int) throws -> FlexibleFEField.Target {
            let i = try XCTUnwrap(sim.pressed.firstIndex { $0.face == face }, "face \(face) in \(sim.id)")
            return sim.targets[i]
        }
        let face3 = try target(g2, 3), face5 = try target(g1, 5)

        // ── (a) a group ALONE: Face 3 pressed, its far end (Face 5) is its anvil ──
        let own = Self.inward(f2, face3), far = Self.inward(f2, face5)
        let (s32, _, _) = try await FlexibleSquishFixture.resolve(m, "group-2", control: 32768)
        let raw32 = FlexibleFEField(solution: s32, simID: "group-2", generation: r.generation)
        let own32 = Self.inward(raw32, face3), far32 = Self.inward(raw32, face5)
        print(String(format: "FLEX-GV ALONE group 2: Face 3 in %.3f mm · Face 5 (its far end) %.3f mm (%.1f%%) · control 32768: %.3f of %.3f (%.0f%%)",
                     own, far, 100 * far / own, far32, own32, 100 * far32 / own32))
        XCTAssertGreaterThan(own, 0)
        XCTAssertLessThanOrEqual(abs(far), 0.05 * own, "Group 2 alone: Face 5 stays where core's columns end")
        XCTAssertGreaterThanOrEqual(far32 / own32, 0.25, "control: batch G's rule pulled Face 5 in (a two-sided pinch)")

        // ── (b) never past its own fold at ×1 ──
        let k = Float(stage.channels?.exaggeration ?? 1)
        for f in [f1, f2] {
            let q = Self.pullback(f, k)
            print(String(format: "FLEX-GV FOLD %@: k %.3f (asked %.2f) · cut %@ · gmax part %.3f (×%.0f: %.2f) · pull-back %d cells, %d miss > 0.5 mm, worst %.3f mm",
                         f.simID, f.scale, f.coreRatio, f.foldShare.map { String(format: "to %.0f%%", 100 * $0) } ?? "none",
                         f.gmaxPart, k, Double(k) * f.gmaxPart, q.0, q.1, q.2))
            XCTAssertLessThanOrEqual(Double(k) * f.gmaxPart, FlexibleFE.safeGradient + 1e-6, "\(f.simID): s · gmax ≤ ½ in the part")
            XCTAssertEqual(q.1, 0, "\(f.simID): the walls' pull-back converges everywhere")
        }
        XCTAssertNotNil(f1.foldShare, "his Group 1 (the 10 kg thumb) is cut so it never folds")
        // ★ RED CONTROL: the same field uncapped (batch G: k 2 at the page's ×1)
        let (s1, _, _) = try await FlexibleSquishFixture.resolve(m, "group-1")
        let uncapped = FlexibleFEField(solution: s1, simID: "group-1", generation: r.generation)
            .calibrated(to: g1.targets, foldCap: false)
        let qRed = Self.pullback(uncapped, 1)
        print(String(format: "FLEX-GV FOLD control (uncapped group 1): k %.2f · s·gmax part %.2f · pull-back misses %d, worst %.2f mm",
                     uncapped.scale, uncapped.gmaxPart, qRed.1, qRed.2))
        XCTAssertGreaterThan(uncapped.gmaxPart, FlexibleFE.safeGradient, "control: uncapped, ×1 is past the fold bound")
        XCTAssertGreaterThan(qRed.1, 0, "control: …and the walls' pull-back misses")
        // a pressed face of its own group moving OUT (his "negative"): measured, for the handoff
        for (sim, f) in [(g1, f1), (g2, f2)] {
            for (i, t) in sim.targets.enumerated() {
                let load = SIMD3<Float>(t.stack.load)
                let rises = t.stack.columns.indices.map { c -> Float in
                    let e = FlexibleStackMembership.point(t.stack, column: c, t: t.stack.columns[c].entryT)
                    return -simd_dot(f.sample(SIMD3<Float>(e)), load)
                }.filter { $0 > 1e-4 }
                print(String(format: "FLEX-GV RISE %@ face %d: %d of %d columns move out · the most %.2f mm at ×%.0f",
                             sim.id, sim.pressed[i].face, rises.count, t.stack.columns.count, Double(rises.max() ?? 0) * Double(k), k))
            }
        }

        // ── (c) a stamp press drags its neighbours (his round-5 (b)) ──
        for (sim, f, face) in [(g1, f1, FlexibleHisProject.topA), (g2, f2, 3)] {
            let i = try XCTUnwrap(sim.pressed.firstIndex { $0.face == face })
            let t = sim.targets[i], p = sim.pressed[i].columnPressureMPa
            let cols = t.stack.columns
            let pmax = p.max() ?? 0
            let foot = cols.indices.filter { $0 < p.count && pmax > 0 && p[$0] >= 0.5 * pmax }
            XCTAssertFalse(foot.isEmpty)
            XCTAssertLessThan(foot.count, cols.count, "face \(face): a stamp, not the whole face")
            let footSet = Set(foot)
            let ring = cols.indices.filter { c in
                guard !footSet.contains(c) else { return false }
                let d = foot.map { hypot(cols[$0].uMM - cols[c].uMM, cols[$0].vMM - cols[c].vMM) }.min() ?? .infinity
                return d <= 3
            }
            let load = SIMD3<Float>(t.stack.load)
            func sink(_ c: Int) -> Double {
                Double(simd_dot(f.sample(SIMD3<Float>(FlexibleStackMembership.point(t.stack, column: c, t: cols[c].entryT))), load))
            }
            func core(_ c: Int) -> Double? { c < t.depthsMM.count ? t.depthsMM[c] : nil }
            let mean = { (a: [Double]) in a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
            let feIn = mean(foot.map(sink)), feRing = mean(ring.map(sink))
            let coreIn = mean(foot.compactMap(core)), coreRing = mean(ring.compactMap(core))
            print(String(format: "FLEX-GV DRAG %@ face %d: footprint %d, ring (≤ 3 mm) %d · FE inside %.3f, ring %.3f (%.0f%%) · core's columns inside %.3f, ring %.3f (%.0f%%)",
                         sim.id, face, foot.count, ring.count, feIn, feRing, 100 * feRing / feIn, coreIn, coreRing, 100 * coreRing / max(coreIn, 1e-9)))
            if face == FlexibleHisProject.topA {
                XCTAssertGreaterThanOrEqual(feRing / feIn, 0.45, "the stamp drags the lattice next to it in")
                // ★ RED CONTROL: core's per-column squish (the heat map's numbers) — each column alone
                XCTAssertLessThan(coreRing / coreIn, 0.45, "control: the column squish leaves the stamp an island")
            }
        }

        // ── (d) the dent legend's line in FE mode, (e) the (i) ──
        stage.pick("group-1")
        XCTAssertTrue(stage.fe.active)
        let title = stage.legendTitle(.dent)
        let info = stage.dentInfo
        print("FLEX-GV LEGEND group 1: '\(title)' · (i) '\(info)'")
        XCTAssertNotEqual(title, FlexibleRowCopy.stampMainLegend, "the 3D sim presses the stamp where it sits")
        XCTAssertTrue(info.contains("stiffer than core's columns"), "the band is said")
        XCTAssertTrue(info.contains("cut to"), "…and the cut")
        XCTAssertFalse(info.contains(". "), "one sentence")
        // ★ RED CONTROL: the column squish — the whole face sinks, and the legend says so
        stage.controlColumnSquish = true
        stage.refresh()
        XCTAssertEqual(stage.legendTitle(.dent), FlexibleRowCopy.stampMainLegend, "control: the column squish's own line")
        stage.controlColumnSquish = false
    }

    /// The Squish legend's (i) says the band's k AND the fold cut in every case, one sentence each.
    func testTheSquishInfoSaysTheBandAndTheCut() {
        let cut = FlexibleFE.info(exaggeration: 1, stiffer: 7.4, foldShare: 0.23)
        let cutBonded = FlexibleFE.info(exaggeration: 1, stiffer: 7.4, bonded: true, foldShare: 0.23)
        let cutOnly = FlexibleFE.info(exaggeration: 1, foldShare: 0.6)
        let large = FlexibleFE.info(exaggeration: 1, stiffer: 9.1, largeStrain: true)
        for l in [cut, cutBonded, cutOnly, large] {
            XCTAssertFalse(l.contains(". "), "one sentence: \(l)")
            XCTAssertTrue(l.hasSuffix("."))
        }
        print("FLEX-GV INFO: " + [cut, cutOnly, large].joined(separator: " | "))
        XCTAssertTrue(cut.contains("7× stiffer") && cut.contains("cut to 23%"))
        XCTAssertTrue(cutBonded.contains("every rest held fast") && cutBonded.contains("cut to 23%"))
        XCTAssertTrue(cutOnly.contains("cut to 60%") && !cutOnly.contains("stiffer"))
        XCTAssertTrue(large.contains("9× stiffer") && large.contains("small strain"), "the band is said in the large-strain case too")
        // ★ RED CONTROL: batch G's large-strain line never said the band
        XCTAssertFalse(FlexibleFE.info(exaggeration: 1, largeStrain: true).contains("stiffer"), "control: without the band")
    }
}
#endif
