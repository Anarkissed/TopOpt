// FlexibleBatchNEvidenceProbe — the quick (linear, fold-cut) squish against the squish solved in
// STEPS, side by side (task 2026-09-29-flexible-screens, round 5 batch N). Opt-in:
//     FLEX_N_EVIDENCE_DIR=<dir> swift test --filter FlexibleBatchNEvidenceProbe
// The main page's own picture by the shipping renderer (FlexibleSquishEvidenceProbe.render: what
// FlexibleMainStage hands MetalMeshView, settled like the page), at rest / half / full, each group:
// "linear" = batch G / M's quick field with its fold cut (the stage's `controlNoRefineView`),
// "stepped" = its refined field. His round-5 project and the M2 stand. Offscreen frames, not
// device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchNEvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_N_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func sideBySide(_ stage: FlexibleMainStage, _ m: FlexibleStageModel, _ project: ProjectModel, case name: String,
                    views: [(String, Float, Float)], device: MTLDevice, dir: URL) throws {
        let probe = FlexibleSquishEvidenceProbe()
        for g in m.squishSims.map(\.sim.id) {
            stage.pick(g)
            for (tag, quick) in [("linear", true), ("stepped", false)] {
                stage.controlNoRefineView = quick
                stage.refresh()
                let f = stage.feShownField
                print(String(format: "FLEX-N-EVIDENCE %@ %@ %@: version %@ · k %.3f · cut %@ · ×k %.2f · gmax part %.3f · max|u| %.2f mm · note '%@' · (i) '%@'",
                             name, g, tag, f?.versionKey ?? "-", f?.scale ?? 0, f?.foldShare.map { String(format: "%.2f", $0) } ?? "none",
                             stage.channels?.exaggeration ?? 0, f?.gmaxPart ?? 0, f?.maxDisplacement ?? 0, stage.simNote ?? "-", stage.dentInfo))
                for v in views {
                    for a: Float in [0, 0.5, 1] {
                        try probe.render(stage, project, name: "N_\(name)_\(g)_\(tag)", amount: a, view: v, device: device, dir: dir)
                    }
                }
            }
        }
        stage.controlNoRefineView = false
        stage.refresh()
    }

    /// A main stage over `project` through Save & Exit, its quick sims landed (FlexibleSquishEvidenceProbe's).
    func stage(_ project: ProjectModel, _ what: String, prepare: (FlexibleStageModel) -> Void = { _ in }) async throws -> (FlexibleMainStage, FlexibleStageModel) {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                            persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "\(what): the scene") { m.sceneState == .ready }
        prepare(m)
        try await FlexibleSquishFixture.settle(m, what)
        stage.didExitSettings()
        stage.apply(project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(180, "\(what): the lattice") { m.lattice != nil || m.latticeError != nil }
        XCTAssertNil(m.latticeError, what)
        try await FlexibleHisProject.waitFor(300, "\(what): the sims") {
            stage.refresh()
            return !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        stage.refresh()
        FlexibleSquishFixture.log(m, what)
        return (stage, m)
    }

    /// Waits for the refines of the lattice shown.
    func refined(_ stage: FlexibleMainStage, _ m: FlexibleStageModel) async throws {
        let start = Date()
        while !m.squishSolver.refineIdle, Date().timeIntervalSince(start) < 900 {
            stage.refresh()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stage.refresh()
        for (id, st) in m.refine { print("FLEX-N-EVIDENCE refine \(id): \(String(describing: st).prefix(200))") }
    }

    func testHisRound5LinearAgainstStepped() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_N_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let (stage, m) = try await stage(r.project, "his round 5")
        try await refined(stage, m)
        try sideBySide(stage, m, r.project, case: "his_r5", views: [FlexibleSquishEvidenceProbe.views[0], ("faces5", .pi * 0.75, 0.35)],
                       device: device, dir: dir)
    }

    /// ★ BATCH N VERIFICATION — his call #1, on screen: his Group 1 as shipped (the band holds the load at
    /// 2× his weights: its Face 5 end leans and its top edge rises) against the same stepped sim at HIS
    /// weights (λ 1, the band [0.5, 1]), full squeeze, end-on and from Face 5's side; and the top layer's
    /// largest rise and sink for each.
    func testHisGroup1AtTheBandEdgeAgainstHisWeights() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_N_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir)
        addTeardownBlock { r.cleanup() }
        let (stage, m) = try await stage(r.project, "his round 5") { $0.keepFERequest = true }
        try await refined(stage, m)
        stage.pick("group-1")
        stage.refresh()
        let shipped = try XCTUnwrap(m.refinedField("group-1", generation: try XCTUnwrap(m.lattice?.generation)))
        let probe = FlexibleSquishEvidenceProbe()
        let views: [(String, Float, Float)] = [("front", 0, 0.03), ("faces5", .pi * 0.75, 0.35)]
        func shoot(_ tag: String, _ f: FlexibleFEField) throws {
            print("FLEX-NV-EVIDENCE his group-1 \(tag): λ \(String(format: "%.3f", f.scale)) · \(Self.motion(f)) · (i) '\(stage.dentInfo)'")
            for v in views { try probe.render(stage, r.project, name: "NV_his_g1_\(tag)", amount: 1, view: v, device: device, dir: dir) }
        }
        try shoot("shipped_lambda2", shipped)
        // the same stepped sim at HIS weights
        let req = try XCTUnwrap(m.lastFERequest)
        let ref = await m.squishWorker.sceneRef()
        let scene = try XCTUnwrap(ref)
        let sim = try XCTUnwrap(req.sims.first { $0.id == "group-1" })
        let lin = try XCTUnwrap(m.squish["group-1"]?.field)
        guard case .refined(let atOne) = FlexibleFERefine.run(sim, of: req, on: scene, linear: lin, band: 0.5...1) else {
            XCTFail("the refine at his weights"); return
        }
        m.refine["group-1"] = .ready(atOne)
        stage.forceOverlayRebuildForTests()
        stage.refresh()
        try shoot("his_weights_lambda1", atOne)
        for v in views { try probe.render(stage, r.project, name: "NV_his_g1_rest", amount: 0, view: v, device: device, dir: dir) }
    }

    /// Up / down motion of the field's top layer of solved nodes (z up in the part's frame).
    static func motion(_ f: FlexibleFEField) -> String {
        var zTop: Float = -.infinity
        for c in 0..<f.nz { for b in 0..<f.ny { for a in 0..<f.nx where f.solved[f.node(a, b, c)] {
            zTop = max(zTop, f.origin.z + Float(c) * f.spacing)
        } } }
        var up: Float = 0, down: Float = 0, upAt = SIMD3<Float>.zero, downAt = SIMD3<Float>.zero
        for c in 0..<f.nz { for b in 0..<f.ny { for a in 0..<f.nx where f.solved[f.node(a, b, c)] {
            let p = f.origin + SIMD3<Float>(Float(a), Float(b), Float(c)) * f.spacing
            guard p.z >= zTop - 1.01 * f.spacing else { continue }
            let u = f.u[f.node(a, b, c)]
            if u.z > up { up = u.z; upAt = p }
            if -u.z > down { down = -u.z; downAt = p }
        } } }
        return String(format: "top layer: rises up to %.2f mm at (%.0f, %.0f, %.0f), sinks up to %.2f mm at (%.0f, %.0f, %.0f) · max|u| %.2f mm",
                      up, upAt.x, upAt.y, upAt.z, down, downAt.x, downAt.y, downAt.z, f.maxDisplacement)
    }

    func testTheM2StandLinearAgainstStepped() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_N_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pm = try FlexibleSquishFixture.stlProject("app/TopOptKit/Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, 1))?.face)
        let bottom = try XCTUnwrap(FlexibleReadiness.suggestedFace(mesh: mesh, up: SIMD3(0, 0, -1))?.face)
        let (stage, m) = try await stage(pm, "the M2 stand") { m in
            _ = m.press(top, kg: 5)
            m.rest(bottom)
        }
        try await refined(stage, m)
        try sideBySide(stage, m, pm, case: "m2stand", views: [FlexibleSquishEvidenceProbe.views[0], FlexibleSquishEvidenceProbe.views[2]],
                       device: device, dir: dir)
    }
}
#endif
