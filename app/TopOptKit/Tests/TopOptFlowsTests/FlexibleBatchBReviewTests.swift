// FlexibleBatchBReviewTests — the batch B review's findings, each reproduced on the code
// before it was fixed (task 2026-09-29-flexible-screens, round 3 batch B verification).
//   * a failed build is LATCHED and SAID: one attempt per (settings, scene), the pill and the
//     Settings line carry core's words. RED: it retried for ever behind "Building the lattice…";
//   * the lattice is keyed by the SCENE too: a new grid (quality) or a new lattice region on
//     the main page leaves it stale and it rebuilds. RED: "Lattice ready" on the old one;
//   * an undo on the main page rebuilds. RED: stale, walls hidden, no build ever started;
//   * the renderer gives the view back when the loop is taken away mid-play (battery) and
//     restores the view's own squish. RED: continuous frames and a dent frozen mid-cycle;
//   * no wall outside the part's SDF grid (the edge texel lies ON his face 3, skin off).
//     RED: F = 0 on the gyroid sheets beyond the edge — walls 12 mm outside the part.
// Each comparison carries a positive control.
import XCTest
import Combine
import simd
#if canImport(MetalKit)
import MetalKit
#endif
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleBatchBReviewTests: XCTestCase {

    // MARK: his project, ready (Face 5 rests), on the main page

    @MainActor
    private func hisStage(material: String) throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        r.project.lattice.flexible?.materialID = material
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        return (r, stage, m)
    }

    /// Open the scene, rest Face 5, wait until nothing blocks and the designs are in.
    @MainActor
    private func ready(_ material: String) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, stage, m) = try hisStage(material: material)
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        m.rest(5)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(60, "ready") { m.readiness.isReady && !m.readiness.designing }
        await m.waitForIdle()
        return (r, stage, m)
    }

    /// Exit (the main page shows the stage), then wait for the first lattice.
    @MainActor
    private func built(_ material: String) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, stage, m) = try await ready(material)
        stage.didExitSettings()
        try await FlexibleHisProject.waitFor(120, "the first lattice") { m.lattice != nil || m.latticeError != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        XCTAssertNotNil(m.lattice, "premise: Exit built the lattice")
        return (r, stage, m)
    }

    @MainActor
    private func spin(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: C1 — a failed build is latched and said

    @MainActor
    func testAFailedBuildIsTriedOnceAndSaid() async throws {
        let (_, stage, m) = try await ready("tpu95a_generic")
        m.controlFailBuild = "The lattice builder refused: no printable cell. More words."
        var starts = 0
        let c = m.$latticeBuilding.sink { if $0 { starts += 1 } }
        stage.didExitSettings()
        try await spin(4)
        c.cancel()
        await m.waitForIdle()
        let s = stage.status
        print("FLEX-REVIEW failed build: starts in 4 s \(starts) · error \(m.latticeError ?? "nil") · pill '\(s.line)' \(s.tone) · Settings line '\(m.readiness.oneLine)'")
        XCTAssertEqual(starts, 1, "one attempt per (settings, scene) — never a loop")
        XCTAssertNotNil(m.latticeError)
        XCTAssertNotEqual(s.line, FlexibleMainStatus.building, "the pill must not promise a build that failed")
        XCTAssertEqual(s.tone, .fix)
        XCTAssertTrue(s.line.contains("no printable cell"), "the pill says core's first sentence: \(s.line)")
        XCTAssertFalse(s.line.contains("More words"), "…only the first")
        XCTAssertTrue(m.readiness.oneLine.contains("no printable cell"), "the Settings line says it too: \(m.readiness.oneLine)")
        XCTAssertTrue(m.readiness.isReady, "a failed build never blocks Exit")
        // his Save & Exit asks again — ONE more attempt, never a loop
        starts = 0
        let c2 = m.$latticeBuilding.sink { if $0 { starts += 1 } }
        stage.didExitSettings()
        try await spin(3)
        c2.cancel()
        await m.waitForIdle()
        XCTAssertEqual(starts, 1, "Exit retries once")
        XCTAssertEqual(stage.status.tone, .fix, "…and says it again")
        // a new edit clears the latch: the next build is tried (and, unforced, lands)
        m.controlFailBuild = nil
        m.setWeight(3, kg: 12)
        try await FlexibleHisProject.waitFor(120, "the rebuild after an edit") { m.lattice != nil }
        await m.waitForIdle()
        XCTAssertNil(m.latticeError)
        // ★ RE-PINNED (round 4 C2 verification): TPU 95A's shape-only lattice is a PREVIEW (core
        // refuses the filament) — built, not failed, and never the green Ready
        XCTAssertEqual(stage.status.tone, .preview)
    }

    /// ★ POSITIVE CONTROL for the count: an unforced build starts exactly once.
    @MainActor
    func testAGoodBuildStartsOnce() async throws {
        let (_, stage, m) = try await ready("tpu95a_generic")
        var starts = 0
        let c = m.$latticeBuilding.sink { if $0 { starts += 1 } }
        stage.didExitSettings()
        try await spin(4)
        c.cancel()
        await m.waitForIdle()
        print("FLEX-REVIEW control build: starts \(starts) · pill '\(stage.status.line)'")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stage.status.line, "TPU 95A: shape only — no squish predicted")
    }

    /// The pop-up that stands on opening waits for the design run (designs AND core's
    /// conflicts): the model says when one is in flight.
    @MainActor
    func testThePipelineSaysWhenADesignRunIsInFlight() async throws {
        let (_, _, m) = try hisStage(material: "tpu95a_generic")
        m.openScene()
        try await FlexibleHisProject.waitFor(60, "his scene and stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil }
        }
        await m.waitForIdle()
        XCTAssertFalse(m.designsInFlight, "idle: nothing in flight")
        XCTAssertFalse(m.conflicts.isEmpty, "premise: his 3/5 conflict landed with the run")
        m.rest(5)
        XCTAssertTrue(m.designsInFlight, "an action schedules a run: in flight at once")
        await m.waitForIdle()
        XCTAssertFalse(m.designsInFlight, "…and it lands")
    }

    // MARK: C2 — the lattice is keyed by the scene too

    @MainActor
    func testANewGridOnTheMainPageRebuilds() async throws {
        let (r, stage, m) = try await built("varioshore_tpu")
        let g1 = try XCTUnwrap(m.lattice?.generation)
        let grid1 = m.sceneInfo.map { "\($0.nx)x\($0.ny)x\($0.nz)" } ?? "-"
        r.project.quality = r.project.quality == .fine ? .fast : .fine
        try await FlexibleHisProject.waitFor(150, "a lattice on the new grid") {
            (m.lattice?.generation ?? g1) > g1 && !m.latticeIsStale && !m.latticeBuilding
        }
        await m.waitForIdle()
        let grid2 = m.sceneInfo.map { "\($0.nx)x\($0.ny)x\($0.nz)" } ?? "-"
        print("FLEX-REVIEW new grid: \(grid1) → \(grid2) · generation \(g1) → \(m.lattice?.generation ?? -1) · stale \(m.latticeIsStale) · pill '\(stage.status.line)'")
        XCTAssertNotEqual(grid1, grid2, "premise: the scene re-opened on the new grid")
        XCTAssertGreaterThan(m.lattice?.generation ?? g1, g1, "a new lattice, not 'Lattice ready' on the old one")
        XCTAssertEqual(stage.status.line, FlexibleMainStatus.ready)
    }

    @MainActor
    func testANewLatticeRegionOnTheMainPageRebuilds() async throws {
        let (r, stage, m) = try await built("varioshore_tpu")
        let g1 = try XCTUnwrap(m.lattice?.generation)
        let v1 = m.sceneInfo?.latticeVoxels ?? -1
        let k1 = m.openedKey
        let sides = try XCTUnwrap(r.project.selection.groups.first { $0.name == "sides" }?.id)
        let before = r.project.latticeJobRegions().regions.count
        r.project.lattice.groupRoles[sides] = .include
        XCTAssertNotEqual(r.project.latticeJobRegions().regions.count, before, "premise: the lattice regions changed")
        try await FlexibleHisProject.waitFor(150, "a lattice on the new region") {
            (m.lattice?.generation ?? g1) > g1 && !m.latticeIsStale && !m.latticeBuilding
        }
        await m.waitForIdle()
        print("FLEX-REVIEW new region: latticeVoxels \(v1) → \(m.sceneInfo?.latticeVoxels ?? -1) · generation \(g1) → \(m.lattice?.generation ?? -1) · pill '\(stage.status.line)'")
        // ★ RE-PINNED (batch E): the scene re-opened on the new regions — by its KEY (the regions are in
        // it). The voxel count was the old premise: his restored pad now carries lattice under every
        // pressed face (FlexibleHisProject's [Lattice under it] taps), the whole part, so a new region
        // over it moves no voxel.
        XCTAssertNotEqual(m.openedKey, k1, "premise: the scene re-opened on the new region")
        XCTAssertGreaterThan(m.lattice?.generation ?? g1, g1)
    }

    /// The bead width reaches the scene job (min_extrudable_width_mm): it is in the scene key.
    @MainActor
    func testTheSceneKeyFollowsTheBeadWidth() throws {
        let (r, _, m) = try hisStage(material: "varioshore_tpu")
        let k1 = m.currentSceneKey
        r.project.printParams.strutLineWidthMM = 0.6
        XCTAssertNotEqual(m.currentSceneKey, k1)
        // ★ CONTROL: a Flexible edit is NOT a scene change
        let k2 = m.currentSceneKey
        m.edit({ $0.checkStamps = [] }, recompute: false)
        r.project.lattice.flexible?.faces.append(FlexibleFaceSettings(faceRegionID: 77, weightKg: 3))
        XCTAssertEqual(m.currentSceneKey, k2)
    }

    // MARK: C3 — an undo on the main page rebuilds

    @MainActor
    func testAnUndoOnTheMainPageRebuilds() async throws {
        let (r, stage, m) = try await built("varioshore_tpu")
        // an edit of his (face 3 heavier), sealed, rebuilt
        let g1 = try XCTUnwrap(m.lattice?.generation)
        m.setWeight(3, kg: 14)
        m.save()
        try await FlexibleHisProject.waitFor(120, "the rebuild after the edit") {
            (m.lattice?.generation ?? g1) > g1 && !m.latticeIsStale && !m.latticeBuilding
        }
        await m.waitForIdle()
        try await spin(1)            // every debounced reaction to the rebuild has run
        let g2 = try XCTUnwrap(m.lattice?.generation)
        // the two-finger tap on the main page
        var starts = 0
        let c = m.$latticeBuilding.sink { if $0 { starts += 1 } }
        r.project.performUndo()
        XCTAssertEqual(m.settings.face(3)?.weightKg, 10, "premise: the undo restored face 3's weight")
        XCTAssertTrue(m.latticeIsStale, "premise: the lattice no longer matches")
        try await spin(3)
        let startsIn3s = starts
        try await FlexibleHisProject.waitFor(120, "the rebuild after the undo") {
            (m.lattice?.generation ?? g2) > g2 && !m.latticeIsStale && !m.latticeBuilding
        }
        c.cancel()
        await m.waitForIdle()
        print("FLEX-REVIEW undo: builds started in 3 s \(startsIn3s) · generation \(g2) → \(m.lattice?.generation ?? -1) · stale \(m.latticeIsStale) · pill '\(stage.status.line)'")
        XCTAssertGreaterThanOrEqual(startsIn3s, 1, "the undo is noticed: a build starts")
        XCTAssertFalse(m.latticeIsStale)
        XCTAssertEqual(stage.status.line, FlexibleMainStatus.ready)
        // ★ ONE MORE UNDO takes back [Face 5 rests]: faces 3 and 5 press the same material
        // again. ★ RE-PINNED (round 4 batch D2, his img 3): that is a PINCH now, which builds —
        // the undo must be noticed and REBUILT (round 3 said "share a stack" on the pill), never
        // "Building…" for ever
        let g3 = try XCTUnwrap(m.lattice?.generation)
        try await spin(1)
        r.project.performUndo()
        XCTAssertEqual(m.settings.face(5)?.isLoaded, true, "premise: Face 5 presses again")
        try await FlexibleHisProject.waitFor(120, "the pinch rebuilt") {
            (m.lattice?.generation ?? g3) > g3 && !m.latticeIsStale && !m.latticeBuilding
        }
        await m.waitForIdle()
        print("FLEX-REVIEW undo of [Face 5 rests]: pill '\(stage.status.line)' \(stage.status.tone) · pinches \(m.pinches.count)")
        // ★ RE-PINNED (round 4 C2 verification): rebuilt — and, the pinch being the app's preview
        // only (core brief #6), the pill is a PREVIEW, never the green Ready (nor "Building…")
        XCTAssertEqual(stage.status.line, FlexibleCoreHold.pill(.pinch, shapeOnlyLabel: nil))
        XCTAssertEqual(stage.status.tone, .preview)
        XCTAssertEqual(m.pinches.map { "\($0.a)|\($0.b)" }, ["3|5"], "control: the conflict round 3 blocked on is still core's")
    }

    // MARK: C4 — the renderer gives the view back

    #if canImport(MetalKit)
    @MainActor
    private func playing() throws -> (MeshRenderer, MTKView, FlexibleSquishLoop, FlexibleLatticeLayerInputs, MTLDevice) {
        let device = try FlexibleLatticeFixtures.device()
        let r = try FlexibleLatticeFixtures.renderer(device: device)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        let l = FlexibleSquishLoop()
        l.clock = { 10 }
        l.exaggeration = 4
        var layer = FlexibleLatticeFixtures.layer(FlexibleLatticeFixtures.boxInputs(.gyroid), token: 1)
        layer.loop = l
        r.applyFlexibleLattice(layer, device: device)
        l.play()
        XCTAssertTrue(r.stepFlexibleLoop(in: view, now: 10.3))
        XCTAssertFalse(view.isPaused, "premise: playing ⇒ continuous frames")
        return (r, view, l, layer, device)
    }

    @MainActor
    func testTheLoopTakenAwayMidPlayGivesTheViewBack() throws {
        // Settings goes up / the lattice goes stale: the layer hands no loop
        do {
            let (r, view, l, layerIn, device) = try playing()
            var layer = layerIn
            layer.loop = nil; layer.hidden = true
            r.applyFlexibleLattice(layer, device: device)
            _ = r.stepFlexibleLoop(in: view, now: 10.4)
            print("FLEX-REVIEW loop detached mid-play: paused \(view.isPaused) · setNeedsDisplay \(view.enableSetNeedsDisplay)")
            XCTAssertTrue(view.isPaused, "no loop to drive ⇒ on-demand drawing (battery)")
            XCTAssertTrue(view.enableSetNeedsDisplay)
            XCTAssertFalse(l.renderingContinuously)
        }
        // he leaves the stage: the pass is torn down
        do {
            let (r, view, _, _, device) = try playing()
            r.applyFlexibleLattice(nil, device: device)
            _ = r.stepFlexibleLoop(in: view, now: 10.4)
            print("FLEX-REVIEW pass torn down mid-play: paused \(view.isPaused)")
            XCTAssertTrue(view.isPaused, "no pass ⇒ on-demand drawing")
        }
        // ★ CONTROL: a pause does it through the step
        do {
            let (r, view, l, _, _) = try playing()
            l.pause()
            _ = r.stepFlexibleLoop(in: view, now: 10.4)
            XCTAssertTrue(view.isPaused)
        }
    }

    /// The loop's last scale must not outlive it: the view's own flexScale comes back, so the
    /// dent is drawn where the page says (k × held), not frozen mid-cycle.
    @MainActor
    func testTheLoopTakenAwayRestoresTheViewsOwnSquish() throws {
        let device = try FlexibleLatticeFixtures.device()
        let box = FlexibleLatticeFixtures.boxMesh()
        let n = box.flatCount
        var dent = [Float](repeating: 0, count: n * 3)
        for v in box.topStart..<n { dent[v * 3] = 8 }          // the top slides 8 mm along X at scale 1
        func render(loopMidway: Bool) throws -> [UInt8] {
            guard let r = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
            let coord = MetalMeshView.Coordinator()
            coord.renderer = r
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 128, height: 128), device: device)
            var inputs = LatticePreviewConfettiTests.baseInputs()
            inputs.mesh = box.mesh
            inputs.flexDisplacements = dent
            inputs.flexScale = 1                                // the page's static k × held
            var layer = FlexibleLatticeFixtures.layer(FlexibleLatticeFixtures.boxInputs(.gyroid), token: 1)
            if loopMidway {
                let l = FlexibleSquishLoop()
                l.clock = { 10 }
                l.exaggeration = 1
                layer.loop = l
                inputs.flexibleLattice = layer
                coord.apply(inputs, to: view)
                l.play()
                _ = r.stepFlexibleLoop(in: view, now: 10.3)     // mid-squish: k × 0.85
                layer.loop = nil
            }
            layer.hidden = true
            inputs.flexibleLattice = layer
            coord.apply(inputs, to: view)
            return try XCTUnwrap(r.renderOffscreen(size: 128))
        }
        let reference = try render(loopMidway: false)
        let after = try render(loopMidway: true)
        let d = FlexibleLatticeFixtures.differing(reference, after)
        print("FLEX-REVIEW squish after the loop left: \(d.differ) of \(d.of) px differ from the page's own scale")
        XCTAssertEqual(d.differ, 0, "the view's own flexScale is back")
    }

    // MARK: U1 — no wall outside the part's SDF grid

    /// The box, its part SDF on a grid whose LAST texel lies on x = 40 (the preview's occupancy
    /// grid has no margin — his pad's edge texel lies on face 3), no skin (face 3's skin off).
    private static func edgeGridBox() -> FlexibleLatticeInputs {
        var f = FlexibleLatticeFixtures.boxInputs(.gyroid)
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(40, 40, 20)
        let centre = (lo + hi) * 0.5, half = (hi - lo) * 0.5
        let sp: Float = 0.5
        let c0 = SIMD3<Float>(-3, -3, -3)
        let n = SIMD3<Int>(Int((43 / sp).rounded()) + 1, Int((46 / sp).rounded()) + 1, Int((26 / sp).rounded()) + 1)
        var sdf = [Float](repeating: 0, count: n.x * n.y * n.z)
        for k in 0..<n.z { for j in 0..<n.y { for i in 0..<n.x {
            let p = c0 + SIMD3<Float>(Float(i), Float(j), Float(k)) * sp
            let q = abs(p - centre) - half
            sdf[(k * n.y + j) * n.x + i] = simd_length(simd_max(q, .zero)) + Swift.min(Swift.max(q.x, Swift.max(q.y, q.z)), 0)
        } } }
        f.partSDF = FlexGrid(nx: n.x, ny: n.y, nz: n.z, c0: c0, spacing: sp, values: sdf)
        precondition(abs(c0.x + Float(n.x - 1) * sp - 40) < 1e-4, "the last texel lies on x = 40")
        return f
    }

    @MainActor
    func testNoWallOutsideThePartsGrid() throws {
        let device = try FlexibleLatticeFixtures.device()
        let f = Self.edgeGridBox()
        let pass = try FlexibleLatticePass(device: device)
        pass.upload(FlexibleLatticeFixtures.layer(f, faces: [FlexibleLatticeFixtures.topFace(depth: 3)], token: 1))
        var outside: [SIMD3<Float>] = [], inside: [SIMD3<Float>] = []
        for x in stride(from: Float(40.5), through: 52, by: 0.5) {
            for y in stride(from: Float(1), through: 39, by: 1) { for z in stride(from: Float(1), through: 19, by: 1) {
                outside.append(SIMD3(x, y, z))
            } }
        }
        for x in stride(from: Float(34), through: 39.5, by: 0.5) {
            for y in stride(from: Float(1), through: 39, by: 1) { for z in stride(from: Float(1), through: 19, by: 1) {
                inside.append(SIMD3(x, y, z))
            } }
        }
        for s: Float in [0, 2, 4] {
            let gpu = try XCTUnwrap(pass.probeSquished(outside, squish: s))
            let onZero = gpu.filter { $0 <= 0.001 }.count
            let swift = outside.filter { FlexibleLatticeField.lattice(at: $0, f) <= 0.001 }.count
            print("FLEX-REVIEW beyond the grid's last texel, s=\(s): GPU F ≤ 0.001 at \(onZero) of \(outside.count) (min \(gpu.min() ?? 0)) · Swift \(swift)")
            XCTAssertEqual(onZero, 0, "no wall outside the part (s = \(s))")
            XCTAssertEqual(swift, 0, "the Swift twin agrees")
            // ★ POSITIVE CONTROL: just inside the same face the probe finds walls — STRICTLY
            // inside (F < 0): a first version of this fix took max(SDF, 0) inside the grid too,
            // every interior F became ≥ 0 and no wall was drawn anywhere; a `<= 0` count here
            // passed on that (FlexibleLatticePassTests caught it)
            let inGPU = try XCTUnwrap(pass.probeSquished(inside, squish: s))
            let inSwift = inside.filter { FlexibleLatticeField.lattice(at: $0, f) < -0.01 }.count
            XCTAssertGreaterThan(inGPU.filter { $0 < -0.01 }.count, 100, "control: walls inside the part (s = \(s))")
            XCTAssertGreaterThan(inSwift, 100, "control: the Swift twin has walls inside too")
        }
        // ★ the undeformed probe agrees with the Swift reference everywhere it did before
        let pts = FlexibleLatticeFixtures.probePoints(4000)
        let g = try XCTUnwrap(pass.probe(pts))
        let worst = zip(pts, g).map { abs(FlexibleLatticeField.lattice(at: $0.0, f) - $0.1) }.max() ?? 0
        XCTAssertLessThan(worst, 0.02, "GPU/Swift parity (mm)")
    }
    #endif
}
