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
