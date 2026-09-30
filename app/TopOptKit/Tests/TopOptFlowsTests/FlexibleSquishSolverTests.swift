// FlexibleSquishSolverTests — the squish sims' queue, cache and gates on HIS project 0004 (task
// 2026-09-29-flexible-screens, round 5 batch G, §4, §7), each with its RED control:
//   * one solve at a time, the shown sim first — RED: two in flight;
//   * a superseded generation is never stored, and a pick of a solved sim never re-solves — RED:
//     a cache without the generation check;
//   * never beside another core solve: no sim starts while one runs, and the Stress solve waits
//     for the sims — RED: the gates off;
//   * a failed sim plays the column squish with one line and core's words behind the (i), and
//     Play all skips it — RED: no fallback (the player holds, nothing plays);
//   * the main page's dents follow the sim the RENDERER shows (a mesh rebuild mid Play all), and a
//     tap on the bent map reads the column under the finger — RED: the dents of sim 0.
import XCTest
import Combine
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishSolverTests: XCTestCase {

    /// His project split into `groups` (top | 3 | 5, or top | sides), the lattice built, nothing solved.
    func his(threeGroups: Bool) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        try await FlexibleSquishFixture.his(self, threeGroups ? "his three groups" : "his top | sides", solve: false) { m in
            m.edit { s in
                _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
                if threeGroups {
                    _ = FlexibleSqueezeGroups.newGroup(with: 5, in: &s)
                } else {
                    FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
                }
            }
        }
    }

    func testOneSolveAtATimeShownFirst() async throws {
        let (_, m) = try await his(threeGroups: true)
        XCTAssertEqual(m.squishSims.count, 3)
        var order: [String] = []
        let c = m.$squish.sink { s in
            for (id, st) in s where st != .pending && !order.contains(id) { order.append(id) }
        }
        FlexibleSquishSolver.inFlight.resetPeak()
        try await FlexibleSquishFixture.solve(m, first: "group-3", "three groups")
        c.cancel()
        let peak = FlexibleSquishSolver.maxObservedConcurrency
        print("FLEX-G QUEUE: landed in the order \(order) (group-3 shown first) · at most \(peak) in core at once · \(m.squishSolver.solveCount) solves")
        XCTAssertEqual(order.first, "group-3", "the shown sim first")
        XCTAssertEqual(Array(order.dropFirst()), ["group-1", "group-2"], "then the others in group order")
        XCTAssertEqual(peak, 1, "one solve at a time")
        // ★ RED CONTROL: two in flight — the counter sees both
        m.squishSolver.controlConcurrency = 2
        m.latticeLanded(m.lastFERequest)
        FlexibleSquishSolver.inFlight.resetPeak()
        try await FlexibleSquishFixture.solve(m, "three groups, concurrency 2")
        print("FLEX-G QUEUE control (concurrency 2): at most \(FlexibleSquishSolver.maxObservedConcurrency) at once")
        XCTAssertEqual(FlexibleSquishSolver.maxObservedConcurrency, 2, "control: the counter sees two")
        m.squishSolver.controlConcurrency = 1
    }

    func testSupersededGenerationIsDropped() async throws {
        let (_, m) = try await his(threeGroups: false)
        try await FlexibleSquishFixture.solve(m, "top | sides")
        let g = try XCTUnwrap(m.lattice?.generation)
        let before = m.squish
        // a sim of an older lattice lands late: dropped
        m.squishLanded(g - 1, "group-1", .failed("stale"))
        XCTAssertEqual(m.squish, before, "a superseded generation is never stored")
        // a pick of a solved sim never re-solves
        let solves = m.squishSolver.solveCount
        m.startSquishSims(first: "group-2")
        m.startSquishSims(first: "group-1")
        await m.squishSolver.waitForIdle()
        XCTAssertEqual(m.squishSolver.solveCount, solves, "picks of solved sims do not re-solve")
        print("FLEX-G CACHE: generation \(g) · a late result of \(g - 1) dropped · \(solves) solves, none after two picks")
        // ★ RED CONTROL: a cache without the generation check shows the stale field
        m.controlIgnoreSquishGeneration = true
        m.squishLanded(g - 1, "group-1", .failed("stale"))
        XCTAssertEqual(m.squish["group-1"], .failed("stale"), "control: without the check the stale result is shown")
        m.controlIgnoreSquishGeneration = false
    }

    func testWaitsForOtherCoreSolves() async throws {
        let (_, m) = try await his(threeGroups: false)
        // another core solve runs: no sim starts
        var busy = true
        m.squishSolver.busy = { busy }
        m.startSquishSims(first: nil)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(m.squishSolver.solveCount, 0, "no sim starts beside another core solve")
        XCTAssertTrue(m.squish.values.allSatisfy { $0 == .pending })
        // it ends: the sims run
        busy = false
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.values.contains(.pending) }
        XCTAssertEqual(m.squishSolver.solveCount, 2)
        // the Stress solve waits while a sim is inside core, and starts when the sims go idle
        let gate = FlexibleBatchCVerifyTests.Gate()
        let sim = LatticeSimModel(runner: FlexibleBatchCVerifyTests.stubRunner(gate))
        let stage = FlexibleMainStage()
        stage.attach(FlexibleStressSolver(sim: sim, context: { FlexibleBatchCVerifyTests.context() }))
        FlexibleSquishSolver.inFlight.increment()
        stage.toggleStress()
        let waited = gate.runs
        XCTAssertTrue(stage.stressWaiting, "the Stress solve waits for the sim")
        FlexibleSquishSolver.inFlight.decrement()
        stage.squishIdle()
        try await FlexibleBatchCVerifyTests.settle { gate.runs == 1 }
        print("FLEX-G GATE: busy 1 s → \(0) solves · then 2 · Stress beside a sim: \(waited) runs, after it \(gate.runs)")
        XCTAssertEqual(waited, 0)
        XCTAssertEqual(gate.runs, 1, "…and runs once the sims are idle")
        // ★ RED CONTROL: the gates off — the sims start at once, and so does the Stress solve
        let (_, m2) = try await his(threeGroups: false)
        m2.squishSolver.busy = { false }
        m2.startSquishSims(first: nil)
        try await FlexibleHisProject.waitFor(30, "a sim started") { m2.squishSolver.solveCount > 0 }
        XCTAssertGreaterThan(m2.squishSolver.solveCount, 0, "control: without the gate a sim starts")
        await m2.squishSolver.waitForIdle()
        let gate2 = FlexibleBatchCVerifyTests.Gate()
        let stage2 = FlexibleMainStage()
        stage2.attach(FlexibleStressSolver(sim: LatticeSimModel(runner: FlexibleBatchCVerifyTests.stubRunner(gate2)),
                                           context: { FlexibleBatchCVerifyTests.context() }))
        stage2.toggleStress()
        try await FlexibleBatchCVerifyTests.settle { gate2.runs == 1 }
        XCTAssertEqual(gate2.runs, 1, "control: with no sim in core the Stress solve runs at once")
    }

    // MARK: the fallback

    /// A main stage over his top | sides project, its lattice built through Save & Exit.
    func stage(failing: Set<String>, noFallback: Bool = false) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        stage.controlNoFallback = noFallback
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlFailSimIDs = failing
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his")
        m.edit { s in
            _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
            FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
        }
        try await FlexibleSquishFixture.settle(m, "his split")
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(300, "the sims") { stage.refresh(); return !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        stage.refresh()
        return (r, stage, m)
    }

    func testFailureFallsBackToTheColumnSquish() async throws {
        let (r, stage, m) = try await stage(failing: ["group-2"])
        FlexibleSquishFixture.log(m, "fallback")
        // Play all skips the failed sim; it stays pickable
        XCTAssertEqual(stage.shownLattice?.shownSim?.kind, .playAll, "Play all is the default")
        XCTAssertTrue(stage.fe.active)
        XCTAssertEqual(stage.fe.sequence.map { stage.fe.fields[$0].simID }, ["group-1"], "Play all skips the failed sim")
        stage.pick("group-2")
        XCTAssertFalse(stage.fe.active, "group 2 plays the column squish")
        XCTAssertEqual(stage.simNote, FlexibleFE.failed)
        XCTAssertTrue(stage.dentInfo.contains("deadline"), "core's words behind the Squish legend's (i): \(stage.dentInfo)")
        XCTAssertFalse(stage.dentInfo.contains(". "), "one sentence")
        let layer = try XCTUnwrap(stage.layer(r.project, stage: .lattice, pageUp: false))
        XCTAssertTrue(layer.feSequence.isEmpty)
        XCTAssertFalse(layer.faces.isEmpty, "the column squish's faces")
        XCTAssertTrue(stage.loop.playing, "…and it plays")
        print("FLEX-G FALLBACK group-2: note '\(stage.simNote ?? "-")' · (i) '\(stage.dentInfo)' · playing \(stage.loop.playing)")
        // ★ RED CONTROL: without the fallback the player holds and nothing plays for it
        let (_, s2, _) = try await self.stage(failing: ["group-2"], noFallback: true)
        s2.pick("group-2")
        XCTAssertFalse(s2.loop.playing, "control: no fallback — nothing plays")
        XCTAssertEqual(s2.loop.held, 0)
    }

    func testMainPageDentsFollowTheShownSim() async throws {
        let (r, stage, m) = try await stage(failing: [])
        XCTAssertEqual(stage.fe.sequence.count, 2)
        // the renderer shows group 2 (Play all's second turn); a mesh rebuild re-uploads THAT sim
        stage.loop.shownIndex = 1
        stage.forceOverlayRebuildForTests()
        stage.refresh()
        let d = try XCTUnwrap(stage.dents(r.project, on: .lattice))
        XCTAssertEqual(d, stage.fe.mesh[1], "H4 hands the mesh of the sim the renderer shows")
        // …LIVE: the renderer moves on without a refresh (the next wrap) and H4 follows it
        stage.loop.shownIndex = 0
        XCTAssertEqual(stage.dents(r.project, on: .lattice), stage.fe.mesh[0], "H4 follows the renderer, not a copy")
        stage.loop.shownIndex = 1
        // the stage's own overlay is cut to the sim's grid (a big flat triangle bends with the skin)
        let info = try XCTUnwrap(m.sceneInfo)
        let hFE = Float(FlexibleFE.spacing(sceneNX: info.nx, ny: info.ny, nz: info.nz, spacing: info.spacing))
        let ov = try XCTUnwrap(stage.overlay)
        var longest: Float = 0
        for t in 0..<(ov.partFlatVertices / 3) {
            let q = (0..<3).map { j in SIMD3<Float>(ov.mesh.flat.positions[9 * t + 3 * j], ov.mesh.flat.positions[9 * t + 3 * j + 1], ov.mesh.flat.positions[9 * t + 3 * j + 2]) }
            longest = max(longest, simd_distance(q[0], q[1]), simd_distance(q[1], q[2]), simd_distance(q[2], q[0]))
        }
        XCTAssertLessThanOrEqual(longest, hFE + 1e-4, "the main page's overlay edge ≤ the sim's spacing")
        // a tap on face 3's bent map reads face 3's column under the finger (core's number)
        let o = try XCTUnwrap(stage.overlay)
        let k3 = FlexFaceKey(region: 3, rotation: 0)
        let st = try XCTUnwrap(m.stacks[k3])
        let start = try XCTUnwrap(o.flatStart[k3])
        let col = st.columns.count / 2
        let v = start + col * 6
        let rest = SIMD3<Float>(o.mesh.flat.positions[3 * v], o.mesh.flat.positions[3 * v + 1], o.mesh.flat.positions[3 * v + 2])
        let quad = (0..<6).map { j -> SIMD3<Float> in
            let w = start + col * 6 + j
            return SIMD3(o.mesh.flat.positions[3 * w], o.mesh.flat.positions[3 * w + 1], o.mesh.flat.positions[3 * w + 2])
        }
        let centre = quad.reduce(.zero, +) / 6
        let s = Float(stage.channels?.exaggeration ?? 1)
        let bent = centre + s * SIMD3(d[3 * v], d[3 * v + 1], d[3 * v + 2])
        let dir = -SIMD3<Float>(st.load)
        let reading = FlexibleProbe.dentReading(model: m, overlay: o, dents: d, scale: s, drawnLattice: stage.shownLattice,
                                                point: bent, dir: -dir, onlyIfOnMap: false)
        let want = stage.shownLattice?.columnDepths[k3]?[col] ?? nil
        print("FLEX-G DENTS: shown sim 1 · H4 == fe.mesh[1] · tap on face 3 column \(col) at \(bent) reads \(reading?.value ?? "-") mm (core \(want.map { String(format: "%.2f", $0) } ?? "-")) · rest \(rest)")
        XCTAssertEqual(reading?.value, want.map { String(format: "%.2f", $0) }, "the tap reads the column under the finger")
        // ★ RED CONTROL: sim 0's dents are another mesh while group 2 plays
        XCTAssertNotEqual(stage.fe.mesh[0], stage.fe.mesh[1], "control: sim 0's dents would not match the screen")
    }
}
