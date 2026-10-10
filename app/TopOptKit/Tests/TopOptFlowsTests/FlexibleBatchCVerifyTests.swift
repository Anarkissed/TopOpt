// FlexibleBatchCVerifyTests — the batch C verification's findings, each proven on the code that
// runs (task 2026-09-29-flexible-screens, round 3 batch C verification). Every comparison has a
// control that goes RED on the defect it names.
//   * Stress on HIS project: the app's own context THROWS (a stale region nothing uses); the
//     Flexible solve sends only the regions the load case reaches, and solves;
//   * a failed / blocked solve is SAID (the legend's one line), and Retry runs it again;
//   * the first Save & Exit has the solver (it arrived only from the toggles' body), and Exit
//     solves only while Stress shows;
//   * Stress takes the map from Heat and leaves X-ray and the lattice alone;
//   * the subdivided overlay: the stress colour under a point is the number a tap reads there
//     (RED: his pad's 12 triangles), and the dent's geometry is exactly the unsubdivided one;
//   * MPa to three significant digits; the dent legend says "What you drew" for his drawing;
//   * H4' is inert off the Flexible stage; a legend tap never reorders the legends; the player
//     keeps off the Selections column; the squish holds still while a legend reads.
import XCTest
import CoreGraphics
#if canImport(MetalKit)
import MetalKit
#endif
import simd
import TopOptDesign
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleBatchCVerifyTests: XCTestCase {

    // MARK: helpers (FlexibleMainViewsTests uses them too)

    /// A stub solve: counts runs, and fails while `fail` is set.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs = 0
        private var _fail = false
        var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _fail }
            set { lock.lock(); _fail = newValue; lock.unlock() }
        }
        func hit() -> Bool { lock.lock(); defer { lock.unlock() }; _runs += 1; return _fail }
    }
    struct Refused: Error, CustomStringConvertible { var description: String { "face region 9 out of range" } }

    static func stubRunner(_ gate: Gate) -> LatticeSimModel.Runner {
        { _ in
            if gate.hit() { throw Refused() }
            return TopOptKit.SimAnalysisResult(accepted: true, nonConvergent: false, maxStressMPa: 1,
                                               marginWorstCase: 2, marginRequired: 1.5, maxDisplacementMM: 0.1,
                                               vonMisesField: [0.5, 1, 0.25, 0.75, 1, 0.5, 0.25, 1], gridNX: 2, gridNY: 2, gridNZ: 2,
                                               gridOrigin: .zero, spacingMM: 1)
        }
    }
    static func context(anchors: [Int] = [0], loads: Int = 1) -> LatticeSimModel.Context {
        LatticeSimModel.Context(modelPath: "/tmp/p.stl", material: "ABS", materialsPath: "m", rulesPath: "r",
                                resolution: 16, anchorFaceIDs: anchors,
                                loadGroups: (0..<loads).map { _ in .init(faceIDs: [1], force: SIMD3(0, 0, -98)) })
    }
    @MainActor
    static func settle(_ timeout: Double = 5, _ cond: @escaping () -> Bool) async throws {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // the phase reaches the stage on the next main-queue turn
        for _ in 0..<3 { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: Stress on HIS project

    /// ★ THE BLOCKER: the Stress button's solve on his project 0004, as the app builds it,
    /// THROWS — a stale region ('Face 23 & like it', add [23], on a 6-face pad) nothing uses. The
    /// Flexible solve sends the regions the load case reaches (Top = region 103, and its parent
    /// 102) and solves.
    @MainActor
    func testHisProjectsStressSolvesWithTheRegionsItsLoadsReach() throws {
        let r = try FlexibleHisProject.restore()
        defer { r.cleanup() }
        let app = try XCTUnwrap(r.app.makeLatticeSimContext(), "his project describes a solve")
        let flexible = FlexibleStressContext.reached(app)
        print("FLEX-STRESS his regions: sent by the app \(app.faceRegions.map(\.id)) · reached \(flexible.faceRegions.map(\.id)) · anchors \(app.anchorFaceIDs) · loads \(app.loadGroups.map { "\($0.faceIDs)/\($0.regionIDs)" })")
        XCTAssertEqual(Set(flexible.faceRegions.map(\.id)), [102, 103], "the loaded sector and its parent — nothing else")
        XCTAssertEqual(flexible.anchorFaceIDs, app.anchorFaceIDs)
        XCTAssertEqual(flexible.loadGroups, app.loadGroups, "the faces and forces are unchanged")
        XCTAssertNil(FlexibleStressContext.blocker(flexible))
        func solve(_ c: LatticeSimModel.Context) throws -> TopOptKit.SimAnalysisResult {
            try TopOptKit.analyzeSolidLoadCase(modelPath: c.modelPath, material: c.material, materialsPath: c.materialsPath,
                                               rulesPath: c.rulesPath, resolution: c.resolution, anchorFaceIDs: c.anchorFaceIDs,
                                               loadGroups: c.loadGroups, buildDirection: c.buildDirection,
                                               faceRegions: c.faceRegions, anchorRegionIDs: c.anchorRegionIDs)
        }
        // ★ RED CONTROL: the context the app builds (every region) is refused
        var refused = ""
        XCTAssertThrowsError(try solve(app), "control: his stale region refuses the whole solve") { refused = "\($0)" }
        print("FLEX-STRESS the app's context: THROWS '\(refused)'")
        XCTAssertTrue(refused.contains("101") || refused.contains("23"), "…on region 101 / face 23")
        let t0 = Date()
        let res = try solve(flexible)
        let peak = res.vonMisesField.max() ?? 0
        print(String(format: "FLEX-STRESS reached context: %.2f s, nonConvergent %@, peak %.4f MPa, grid %dx%dx%d @ %.2f mm",
                     Date().timeIntervalSince(t0), res.nonConvergent ? "yes" : "no", Double(peak), res.gridNX, res.gridNY, res.gridNZ, res.spacingMM))
        XCTAssertFalse(res.nonConvergent)
        XCTAssertGreaterThan(peak, 0, "Stress appears on his project")
    }

    /// The region filter keeps a sector's whole ancestry, and nothing unreached.
    func testTheReachedRegionsAreTheLoadsAndAnchorsAndTheirAncestors() {
        let regions = [TopOptKit.FaceRegionSpec(id: 1, addFaces: [0]), TopOptKit.FaceRegionSpec(id: 2, parentID: 1),
                       TopOptKit.FaceRegionSpec(id: 3, parentID: 2), TopOptKit.FaceRegionSpec(id: 4, addFaces: [99]),
                       TopOptKit.FaceRegionSpec(id: 5, addFaces: [2])]
        let ctx = LatticeSimModel.Context(modelPath: "p", material: "ABS", materialsPath: "m", rulesPath: "r", resolution: 16,
                                          anchorFaceIDs: [], loadGroups: [.init(faceIDs: [], force: SIMD3(0, 0, -1), regionIDs: [3])],
                                          faceRegions: regions, anchorRegionIDs: [5])
        XCTAssertEqual(FlexibleStressContext.reached(ctx).faceRegions.map(\.id), [1, 2, 3, 5])
        // what stops it before it starts — one line that says what to add, and where
        XCTAssertEqual(FlexibleStressContext.blocker(Self.context(anchors: [])), FlexibleStressContext.noAnchor)
        XCTAssertEqual(FlexibleStressContext.blocker(Self.context(loads: 0)), FlexibleStressContext.noLoad)
        XCTAssertEqual(FlexibleStressContext.blocker(nil), FlexibleStressContext.noFile)
        XCTAssertNil(FlexibleStressContext.blocker(Self.context()))
        XCTAssertEqual(FlexibleStressContext.noAnchor, "Stress needs an anchor on Topology")
    }

    // MARK: said, never silent

    @MainActor
    func testAFailedOrBlockedSolveIsSaidAndRetryRunsItAgain() async throws {
        let gate = Gate()
        gate.fail = true
        let sim = LatticeSimModel(runner: Self.stubRunner(gate))
        let stage = FlexibleMainStage()
        stage.attach(FlexibleStressSolver(sim: sim, context: { Self.context() }))
        stage.toggleStress()
        XCTAssertEqual(sim.phase, .running, "the solve starts")
        try await Self.settle { if case .failed = sim.phase { return true } else { return false } }
        XCTAssertEqual(gate.runs, 1)
        print("FLEX-STRESS failed: state \(stage.stressState) · line '\(stage.stressState.line ?? "")' · (i) '\(stage.stressInfo)'")
        XCTAssertEqual(stage.stressState, .failed("face region 9 out of range"), "the refusal reaches the Stress view")
        XCTAssertEqual(stage.stressState.line, "Couldn't simulate")
        XCTAssertTrue(stage.stressState.retries, "…with a Retry")
        XCTAssertTrue(stage.stressInfo.contains("face region 9 out of range"), "core's words behind the (i)")
        XCTAssertFalse(stage.stressDrawable, "nothing is painted over a refusal")
        // ★ RED CONTROL: the sim itself holds the failure — the stage said nothing before
        if case .failed = sim.phase {} else { XCTFail("control: the sim failed") }
        // Retry, once the cause is gone: it runs again and the field lands
        gate.fail = false
        stage.retryStress()
        XCTAssertEqual(sim.phase, .running, "Retry runs the solve again")
        try await Self.settle { if case .complete = sim.phase { return true } else { return false } }
        XCTAssertEqual(gate.runs, 2)
        XCTAssertEqual(stage.stressState, .ready)
        // blocked before it starts: said, and never run
        let blocked = FlexibleMainStage()
        let blockedSim = LatticeSimModel(runner: Self.stubRunner(gate))
        blocked.attach(FlexibleStressSolver(sim: blockedSim, context: { Self.context(anchors: []) }))
        blocked.toggleStress()
        XCTAssertEqual(blockedSim.phase, .idle, "a blocked solve never runs")
        XCTAssertEqual(blocked.stressState, .blocked(FlexibleStressContext.noAnchor))
        XCTAssertEqual(blocked.stressState.line, "Stress needs an anchor on Topology")
        XCTAssertFalse(blocked.stressState.retries, "its fix is on Topology, not a Retry")
        XCTAssertEqual(gate.runs, 2, "a blocked solve never runs")
        try await Self.settle { true }
        XCTAssertEqual(blocked.stressState, .blocked(FlexibleStressContext.noAnchor), "the sim's idle phase does not clear what was said")
    }

    // MARK: the first Save & Exit

    /// ★ The solver arrives with Save & Exit itself (H2) — the toggles, the only place it came
    /// from, had not rendered when Settings opened in the same action that made the stage
    /// Flexible. And Exit solves only while Stress shows.
    @MainActor
    func testTheFirstSaveAndExitHasTheSolverAndSolvesOnlyWhileStressShows() async throws {
        let gate = Gate()
        let sim = LatticeSimModel(runner: Self.stubRunner(gate))
        let solver = FlexibleStressSolver(sim: sim, context: { Self.context() })
        // Stress was left on (an earlier visit); Settings opened before the toggles ever rendered
        let shown = FlexibleMainStage()
        shown.stress = true
        // ★ RED CONTROL: batch C's Exit — no solver in hand, nothing starts
        shown.didExitSettings()
        XCTAssertEqual(sim.phase, .idle, "control: without the hand-over the first Exit starts nothing")
        shown.didExitSettings(solver: solver)
        XCTAssertEqual(sim.phase, .running, "the first Save & Exit solves while Stress shows")
        try await Self.settle { sim.phase != .running }
        XCTAssertEqual(gate.runs, 1)
        // Stress off: Exit starts nothing (an unasked solve competes with the lattice build)
        let sim2 = LatticeSimModel(runner: Self.stubRunner(Gate()))
        let off = FlexibleMainStage()
        off.didExitSettings(solver: FlexibleStressSolver(sim: sim2, context: { Self.context() }))
        XCTAssertEqual(sim2.phase, .idle, "Stress off: no solve on Exit")
        off.toggleStress()
        XCTAssertEqual(sim2.phase, .running, "…the Stress button starts it (the solver was handed over on Exit)")
        try await Self.settle { sim2.phase != .running }
    }

    // MARK: Stress takes the map from Heat; X-ray and the lattice stay

    @MainActor
    func testStressTakesTheMapFromHeatAndLeavesXrayAndTheLatticeAlone() {
        let stage = FlexibleMainStage()
        XCTAssertTrue(stage.xray && stage.heat && stage.latticeOn && !stage.stress, "premise: the defaults")
        stage.toggleStress()
        XCTAssertTrue(stage.stress)
        XCTAssertFalse(stage.heat, "one colouring of the map: Stress takes it from Heat")
        XCTAssertTrue(stage.xray, "X-ray is left alone")
        XCTAssertTrue(stage.latticeShown, "…and so are the walls (it turned X-ray off, and them with it)")
        stage.toggleHeat()
        XCTAssertTrue(stage.heat)
        XCTAssertFalse(stage.stress, "Heat takes the map back")
        XCTAssertTrue(stage.xray && stage.latticeShown)
        stage.toggleHeat()
        XCTAssertFalse(stage.heat || stage.stress, "both may be off")
        stage.toggleHeat()
        XCTAssertTrue(stage.heat)
    }

    // MARK: the colour under a point is the number a tap reads there

    /// ★ His pad is 12 triangles: Stress, sampled per vertex, painted each side from its four
    /// corners — the colour under a tap and the tap's reading were up to 0.62 of the ramp apart.
    /// The main page's overlay is subdivided for colour; the dent's geometry is unchanged.
    @MainActor
    func testTheStressColourUnderAPointIsTheNumberATapReadsThere() async throws {
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self)
        m.rest(5)   // (his shared stack, as FlexibleMainViewsTests prepares it)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "his designs") { !m.readiness.designing && !m.designsInFlight }
        await m.waitForIdle()
        let part = try XCTUnwrap(r.project.viewerMesh)
        let edge = FlexibleOverlayMesh.stressEdgeMM(part)
        let coarse = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let fine = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: edge))
        XCTAssertNil(coarse.subdivision, "the Settings page's overlay is not subdivided")
        let sub = try XCTUnwrap(fine.subdivision)
        // the real field: his solve (the reached regions)
        let c = FlexibleStressContext.reached(try XCTUnwrap(r.app.makeLatticeSimContext()))
        let res = try TopOptKit.analyzeSolidLoadCase(modelPath: c.modelPath, material: c.material, materialsPath: c.materialsPath,
                                                     rulesPath: c.rulesPath, resolution: c.resolution, anchorFaceIDs: c.anchorFaceIDs,
                                                     loadGroups: c.loadGroups, buildDirection: c.buildDirection,
                                                     faceRegions: c.faceRegions, anchorRegionIDs: c.anchorRegionIDs)
        let field = LatticeDemandField(vonMises: res.vonMisesField, nx: res.gridNX, ny: res.gridNY, nz: res.gridNZ,
                                       origin: res.gridOrigin, spacingMM: res.spacingMM, provenance: .solidSim(date: Date(), resolution: 64))
        let peak = LatticeStressTint.peakMPa(field)
        XCTAssertGreaterThan(peak, 0)
        /// Area-weighted points on the part's own triangles (not the map): the colour the GPU
        /// blends there (the vertices' ramp fractions, barycentric) against the reading's own.
        func gap(_ o: FlexibleOverlayMesh) -> (worst: Double, mean: Double, p99: Double, n: Int, maxVertexMPa: Double) {
            let pos = o.mesh.flat.positions
            func p(_ v: Int) -> SIMD3<Float> { SIMD3(pos[3 * v], pos[3 * v + 1], pos[3 * v + 2]) }
            func frac(_ q: SIMD3<Float>) -> Double { min(1, (FlexibleProbe.stress(field, at: q) ?? 0) / peak) }
            let tris = o.partFlatVertices / 3
            var areas: [Double] = [], total = 0.0
            for t in 0..<tris {
                let a = Double(simd_length(simd_cross(p(3 * t + 1) - p(3 * t), p(3 * t + 2) - p(3 * t)))) / 2
                total += a; areas.append(total)
            }
            var rng = FlexSeededRNG(seed: 42)
            var worst = 0.0, sum = 0.0, maxV = 0.0, all: [Double] = [], at = SIMD3<Float>.zero
            for v in 0..<(3 * tris) { maxV = max(maxV, FlexibleProbe.stress(field, at: p(v)) ?? 0) }
            let n = 2000
            for _ in 0..<n {
                let x = rng.unit() * total
                let t = areas.firstIndex { $0 >= x } ?? (tris - 1)
                var u = rng.unit(), w = rng.unit()
                if u + w > 1 { u = 1 - u; w = 1 - w }
                let b = SIMD3(1 - u - w, u, w)
                let q = Float(b.x) * p(3 * t) + Float(b.y) * p(3 * t + 1) + Float(b.z) * p(3 * t + 2)
                let shown = b.x * frac(p(3 * t)) + b.y * frac(p(3 * t + 1)) + b.z * frac(p(3 * t + 2))
                let d = abs(shown - frac(q))
                if d > worst { worst = d; at = q }
                sum += d; all.append(d)
            }
            all.sort()
            print("FLEX-STRESS gap distribution (\(tris) part triangles): p50 \(all[n / 2]) p90 \(all[n * 9 / 10]) p99 \(all[n * 99 / 100]) worst \(worst) at \(at)")
            return (worst, sum / Double(n), all[n * 99 / 100], n, maxV)
        }
        let before = gap(coarse), after = gap(fine)
        print(String(format: "FLEX-STRESS colour vs reading on his part (%d points): unsubdivided overlay p99 %.3f mean %.3f worst %.3f of the ramp (max at a vertex %.4f MPa) · subdivided to %.2f mm (%d part triangles) p99 %.3f mean %.4f worst %.3f (max at a vertex %.4f MPa) · peak %.4f MPa",
                     after.n, before.p99, before.mean, before.worst, before.maxVertexMPa, edge, fine.partFlatVertices / 3,
                     after.p99, after.mean, after.worst, after.maxVertexMPa, peak))
        // ★ RED CONTROL: his pad's own triangles (every vertex read 0.000 MPa)
        XCTAssertGreaterThan(before.p99, 0.4, "control: the unsubdivided overlay paints another number than a tap reads")
        XCTAssertGreaterThan(before.mean, 0.05, "control")
        XCTAssertEqual(before.maxVertexMPa, 0, accuracy: 1e-3, "control: every corner of his pad reads ~0 MPa — one flat blue")
        // the colour under 99 % of the part is within a tenth of the ramp of the number a tap
        // reads there (the worst points are the anchored corners' singularity, sharper than any
        // vertex spacing — the handoff says so)
        XCTAssertLessThan(after.p99, 0.1, "the colour under a point is the number read there")
        XCTAssertLessThan(after.mean, 0.01)
        XCTAssertGreaterThan(after.maxVertexMPa, 0.5 * peak, "the part shows its stress")
        XCTAssertLessThan(fine.partFlatVertices / 3, 60_000, "a bounded mesh")
        // ★ THE DENT IS UNCHANGED: every drawn vertex of the subdivided part lies on its kept
        // triangle's dented plane (the blend of that triangle's corner dents in the unsubdivided build)
        let dc = try XCTUnwrap(FlexiblePageChannels.channels(model: m, overlay: coarse, xray: true, drawnLattice: nil).dents)
        let df = try XCTUnwrap(FlexiblePageChannels.channels(model: m, overlay: fine, xray: true, drawnLattice: nil).dents)
        XCTAssertEqual(sub.source.count, coarse.partFlatVertices / 3, "one kept triangle per unsubdivided triangle, in order")
        var off = 0.0, moved = 0
        for v in 0..<fine.partFlatVertices {
            let i = sub.subOf[v / 3], b = sub.bary[v]
            var want = SIMD3<Double>.zero
            for j in 0..<3 { let u = 3 * i + j; want += b[j] * SIMD3(Double(dc[3 * u]), Double(dc[3 * u + 1]), Double(dc[3 * u + 2])) }
            let got = SIMD3(Double(df[3 * v]), Double(df[3 * v + 1]), Double(df[3 * v + 2]))
            off = max(off, simd_length(got - want))
            if simd_length(got) > 1e-6 { moved += 1 }
        }
        print(String(format: "FLEX-STRESS dent on the subdivided part: %d of %d vertices move; worst off the unsubdivided dented surface %.2e mm", moved, fine.partFlatVertices, off))
        XCTAssertGreaterThan(moved, 0, "premise: part vertices move with the dent")
        XCTAssertLessThan(off, 1e-4, "the drawn geometry is the unsubdivided one's")
        // the map quads are the same map
        XCTAssertEqual(fine.mesh.flat.vertexCount - fine.partFlatVertices, coarse.mesh.flat.vertexCount - coarse.partFlatVertices)
    }

    // MARK: Stress is SEEN in the default view

    /// ★ Tapping Stress in the default view (X-ray + Heat) changed nothing he could see: Heat
    /// kept the map, where the load goes in, and Stress got the part's ghosted sides. Now Stress
    /// takes the map (opaque, like the heat) — a render of his project before and after the tap.
    /// RED CONTROL: batch C's mix (Heat kept, Stress on the ghosted part) against the same default.
    #if canImport(MetalKit)
    @MainActor
    func testTappingStressShowsItInTheDefaultView() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "his stacks") {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
        }
        m.rest(5)
        await m.waitForIdle()
        try await FlexibleHisProject.waitFor(90, "his designs") { !m.readiness.designing && !m.designsInFlight }
        await m.waitForIdle()
        stage.refresh()
        let c = FlexibleStressContext.reached(try XCTUnwrap(r.app.makeLatticeSimContext()))
        let res = try TopOptKit.analyzeSolidLoadCase(modelPath: c.modelPath, material: c.material, materialsPath: c.materialsPath,
                                                     rulesPath: c.rulesPath, resolution: c.resolution, anchorFaceIDs: c.anchorFaceIDs,
                                                     loadGroups: c.loadGroups, buildDirection: c.buildDirection,
                                                     faceRegions: c.faceRegions, anchorRegionIDs: c.anchorRegionIDs)
        let field = LatticeDemandField(vonMises: res.vonMisesField, nx: res.gridNX, ny: res.gridNY, nz: res.gridNZ,
                                       origin: res.gridOrigin, spacingMM: res.spacingMM, provenance: .solidSim(date: Date(), resolution: 64))
        let size = 512
        func render(_ name: String) throws -> [UInt8] {
            let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
            mr.setMesh(try XCTUnwrap(stage.mesh(r.project, on: .lattice)))
            mr.beginSettle(to: r.project.force.settleRotation ?? simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), duration: 0)
            mr.camera.setOrientation(azimuth: 0.65, elevation: 0.42)
            if let d = stage.dents(r.project, on: .lattice) { mr.setFlexDisplacements(d) }
            mr.setFlexScale(Float(stage.channels?.exaggeration ?? 1))
            mr.setVertexTints(try XCTUnwrap(stage.tints(r.project, on: .lattice, roles: [:], stress: field)))
            mr.setBodyAlpha(stage.bodyAlpha(r.project, on: .lattice) ?? 1)
            let px = try XCTUnwrap(mr.renderOffscreen(size: size, clear: FlexibleLatticeEvidenceProbe.bg))
            if let dir = ProcessInfo.processInfo.environment["FLEX_EVIDENCE_DIR"] {
                try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: size, to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
            return px
        }
        /// Pixels whose colour moved by more than 30 of 255 in any channel.
        func moved(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var n = 0
            for i in stride(from: 0, to: a.count, by: 4) where (0..<3).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 30 }) { n += 1 }
            return n
        }
        XCTAssertNotNil(stage.overlay?.subdivision, "the main page draws the overlay subdivided for colour")
        XCTAssertTrue(stage.xray && stage.heat && !stage.stress, "premise: the default view")
        let base = try render("v1_default_xray_heat.png")
        // ★ RED CONTROL: batch C's mix — Heat keeps the map, Stress the ghosted part
        stage.stress = true
        XCTAssertTrue(stage.heat && stage.xray)
        let old = try render("v2_batchC_heat_plus_stress_xray.png")
        stage.stress = false
        // the Stress button, now
        stage.toggleStress()
        XCTAssertTrue(stage.xray && stage.stress && !stage.heat, "Stress took the map; X-ray stayed")
        let now = try render("v3_tap_stress_xray.png")
        let covered = (0..<(base.count / 4)).filter { i in
            let b = FlexibleLatticeEvidenceProbe.bg
            return abs(Double(base[4 * i + 2]) / 255 - b.red) > 0.02 || abs(Double(base[4 * i + 1]) / 255 - b.green) > 0.02
        }.count
        let movedOld = moved(base, old), movedNow = moved(base, now)
        print("FLEX-STRESS view: part covers \(covered) px of \(size * size); pixels moved > 30/255 by tapping Stress — batch C's mix \(movedOld) (control), now \(movedNow)")
        XCTAssertLessThan(movedOld, covered / 20, "control: batch C's Stress was all but invisible in the default view")
        XCTAssertGreaterThan(movedNow, covered / 4, "tapping Stress changes what he sees")
    }
    #endif

    // MARK: small ones

    /// ★ Every tapped value in the accent blue, in its own squircle (#354's LatticeLegendReading —
    /// "same with every single tapped value"), on both Flexible pages; each (i) one sentence.
    @MainActor
    func testEveryTappedValueIsInTheBlueSquircle() throws {
        let main = try FlexibleSource.code("FlexibleMainLegends.swift")
        let page = try FlexibleSource.code("FlexibleStagePage.swift")
        XCTAssertTrue(main.contains("LatticeLegendReading(value: reading.value, unit: reading.unit)"))
        XCTAssertTrue(main.contains("FlexibleReadingTag(reading: r)"), "the main page's callout")
        XCTAssertTrue(page.contains("FlexibleReadingTag(reading: r)"), "the Settings page's callout")
        // ★ RED CONTROL: batch C's white text in a capsule is gone from both
        XCTAssertFalse(main.contains("Text(r.text)"), "control")
        XCTAssertFalse(page.contains("Text(r.text)"), "control")
        for k in FlexibleReadKind.allCases { XCTAssertFalse(k.info.contains(". "), "\(k)'s (i) is one sentence") }
        #if canImport(AppKit)
        // the arrow sits on the point: the tag is ~2 × halfHeight tall
        for r in [FlexibleReading(kind: .dent, value: "2.01", unit: "mm", fraction: 0.5, anchor: .zero),
                  FlexibleReading(kind: .lattice, value: "22%", unit: "density · ≈6.1 mm cell", fraction: 0.3, anchor: .zero)] {
            let size = NSHostingView(rootView: FlexibleReadingTag(reading: r).environment(\.colorScheme, .dark)).fittingSize
            print("FLEX-TAG '\(r.text)': \(size)")
            XCTAssertEqual(size.height, 2 * FlexibleReadingTag.halfHeight, accuracy: 8)
            XCTAssertLessThan(size.width, 220)
        }
        #endif
    }

    func testMPaReadsToThreeSignificantDigits() {
        XCTAssertEqual(FlexibleProbe.mpa(0.046219), "0.0462")
        XCTAssertEqual(FlexibleProbe.mpa(1.5), "1.50")
        XCTAssertEqual(FlexibleProbe.mpa(12.34), "12.3")
        XCTAssertEqual(FlexibleProbe.mpa(123.4), "123")
        XCTAssertEqual(FlexibleProbe.mpa(0), "0")
        // ★ RED CONTROL: batch C's "%.2f" read his peak as a round number it is not
        XCTAssertEqual(String(format: "%.2f", 0.046219), "0.05", "control: two decimals lose his pad's stress")
    }

    @MainActor
    func testTheDentLegendSaysWhatYouDrewUnlessCoreDesignedTheLattice() {
        let designed = FlexibleSquishTests.generated()
        let shapeOnly = FlexibleGeneratedLattice(inputs: designed.inputs, faces: designed.faces, topology: "gyroid", tempC: 220,
                                                 settingsKey: 0, shapeOnlyLabel: "TPU 95A: shape only — no squish predicted")
        XCTAssertEqual(FlexibleReadKind.dentTitle(drawn: designed), "Squish · mm")
        XCTAssertEqual(FlexibleReadKind.dentTitle(drawn: shapeOnly), "What you drew · mm", "no squish predicted: it says so")
        XCTAssertEqual(FlexibleReadKind.dentTitle(drawn: nil), "What you drew · mm", "his live drawing")
        // the stage's legend line is this (the view reads legendTitle)
        let stage = FlexibleMainStage()
        XCTAssertEqual(stage.legendTitle(.dent), "What you drew · mm")
        XCTAssertEqual(stage.legendTitle(.stress), FlexibleReadKind.stress.title)
        XCTAssertFalse(stage.dentInfo.contains(". "), "the (i) is one sentence")
    }

    /// ★ H4' is INERT off the Flexible stage: no field noted, no roles evaluated. RED CONTROL:
    /// on the Flexible stage both happen.
    @MainActor
    func testTheTintHookIsInertOffTheFlexibleStage() throws {
        let field = FlexibleMainViewsTests.field()
        var evaluated = 0
        func roles() -> [FaceID: SIMD4<Float>] { evaluated += 1; return [:] }
        let octet = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        octet.lattice.flexible = nil
        let stage = FlexibleMainStage()
        XCTAssertNil(stage.tints(octet, on: .lattice, roles: roles(), stress: field))
        XCTAssertNil(stage.stressField, "nothing noted for an octet page")
        XCTAssertEqual(evaluated, 0, "…and its roles never evaluated")
        // ★ RED CONTROL: the Flexible stage notes the field and composes the roles in
        let flex = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        _ = stage.model(for: flex, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        stage.refresh()
        XCTAssertNotNil(stage.tints(flex, on: .lattice, roles: roles(), stress: field))
        XCTAssertNotNil(stage.stressField, "control: the Flexible stage notes it")
        XCTAssertEqual(evaluated, 1)
        XCTAssertNil(stage.tints(flex, on: .topology, roles: roles(), stress: field), "another stage of the same project: inert")
        XCTAssertEqual(evaluated, 1)
    }

    /// ★ A legend tap never moves the legends (at 11" landscape the tapped one jumped 260 pt).
    @MainActor
    func testALegendTapNeverReordersTheLegends() {
        let v = CGSize(width: 1194, height: 834), clearance: CGFloat = 50 + DS.Space.xl4
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: 221)
        let kinds: [FlexibleReadKind] = [.dent, .stress, .lattice]
        let before = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep, priority: nil)
        let stage = FlexibleMainStage()
        let mode = stage.legendTapped(.stress, mode: .groups)
        XCTAssertEqual(FlexibleReadKind(mode: mode), .stress, "the tap drills in")
        XCTAssertNil(stage.legendPriority, "…without asking for a new placement")
        let after = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep, priority: stage.legendPriority)
        XCTAssertEqual(before, after, "nothing moves under his finger")
        XCTAssertEqual(stage.legendTapped(.stress, mode: mode), .groups, "a second tap comes back out")
        // ★ RED CONTROL: batch C's tap set the priority, and at 11" landscape the legends swapped
        let swapped = FlexibleMainLegendLayout.place(kinds, minimized: [], viewport: v, keepOut: keep, priority: .stress)
        XCTAssertNotEqual(before[.stress]?.frame, swapped[.stress]?.frame, "control: the old tap moved the legend he tapped")
    }

    /// ★ The squish player keeps off the Selections column (at 11" portrait it sat at x 130).
    func testThePlayerKeepsOffTheSelectionsColumn() throws {
        let clearance: CGFloat = 50 + DS.Space.xl4
        for (name, v) in FlexibleLegendPlacementTests.viewports {
            for chip: CGFloat in [0, 221] {
                let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: chip)
                let legends = FlexibleMainLegendLayout.place([.dent, .stress, .lattice], minimized: [], viewport: v, keepOut: keep).values.map(\.frame)
                let p = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: clearance,
                                                                     keepOut: FlexibleMainPlayerSlot.keepOut(viewport: v, bottomClearance: clearance,
                                                                                                             chipColumnWidth: chip, legends: legends)),
                                      "a player place at \(name) chip \(chip)")
                print("FLEX-PLAYER \(name) chip \(Int(chip)): \(p.integral)")
                XCTAssertFalse(p.intersects(FlexibleMainLegendLayout.leftStrip(viewport: v)), "clear of the Selections column at \(name)")
                for f in legends { XCTAssertFalse(p.intersects(f), "clear of the legends at \(name)") }
            }
        }
        // ★ RED CONTROL: without the strip, 11" portrait put it inside the Selections column
        let v = CGSize(width: 834, height: 1194)
        let keep = FlexibleMainLegendLayout.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: 221)
        let legends = FlexibleMainLegendLayout.place([.dent, .stress, .lattice], minimized: [], viewport: v, keepOut: keep).values.map(\.frame)
        let old = FlexibleMainPlayerSlot.keepOut(viewport: v, bottomClearance: clearance, chipColumnWidth: 221, legends: legends)
            .filter { $0 != FlexibleMainLegendLayout.leftStrip(viewport: v) }
        let p = try XCTUnwrap(FlexibleLegendPlacement.player(viewport: v, bottomClearance: clearance, keepOut: old))
        XCTAssertTrue(p.intersects(FlexibleMainLegendLayout.leftStrip(viewport: v)), "control: batch C's player sat in the Selections column")
    }

    /// ★ While a legend reads, the squish holds still at full (the reading stays on its
    /// surface); when it stops reading the loop plays again. A loop he paused stays put.
    func testTheSquishHoldsStillWhileALegendReads() {
        let loop = FlexibleSquishLoop()
        var now: CFTimeInterval = 100
        loop.clock = { now }
        loop.play()
        now += 0.7
        XCTAssertTrue(loop.playing)
        loop.holdWhileReading(true)
        XCTAssertFalse(loop.playing, "reading: it holds still")
        XCTAssertEqual(loop.amount, 1, "…at the full squish")
        let a = loop.scale(at: now), b = loop.scale(at: now + 1.1)
        XCTAssertEqual(a, b, "the map does not move under the reading")
        loop.autoPlay(reduceMotion: false)   // a new lattice lands while he reads
        XCTAssertFalse(loop.playing, "…still held")
        loop.holdWhileReading(false)
        XCTAssertTrue(loop.playing, "done reading: it plays again")
        // a loop he paused stays paused, where he left it
        loop.scrub(to: 0.3)
        loop.holdWhileReading(true); loop.holdWhileReading(false)
        XCTAssertFalse(loop.playing)
        XCTAssertEqual(loop.amount, 0.3, accuracy: 1e-9)
        // ★ RED CONTROL: without the hold, the playing loop moves the map between two frames
        let free = FlexibleSquishLoop()
        free.clock = { now }
        free.play()
        XCTAssertNotEqual(free.scale(at: now + 0.3), free.scale(at: now + 1.1), "control: a playing loop moves the map")
    }
}

/// A seeded generator for repeatable samples (SplitMix64).
struct FlexSeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
