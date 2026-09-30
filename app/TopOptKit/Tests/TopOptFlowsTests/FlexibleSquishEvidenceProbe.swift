// FlexibleSquishEvidenceProbe — BEFORE / AFTER renders of the squish (task
// 2026-09-29-flexible-screens, round 5 batch G, §13). Opt-in:
//     FLEX_G_EVIDENCE_DIR=<dir> swift test --filter FlexibleSquishEvidenceProbe
//
// ★ THE MAIN PAGE'S OWN PICTURE, BY THE SHIPPING RENDERER. Each frame is MeshRenderer's offscreen
// render of exactly what FlexibleMainStage hands MetalMeshView (H3 / H4: the overlay mesh, its
// tints, the X-ray body alpha, the lattice layer and the dents), SETTLED like the page, at rest /
// half / full squish (k × amount — the page's own ×k). BEFORE = today's column squish (the stage's
// test switch `controlColumnSquish`); AFTER = the squeeze group's 3D sim (the field bound and its
// mesh displacements swapped in, as the renderer's loop does at a cycle's start).
// Cases: HIS project 0004 restored (as saved: one group — Top A + Top B + the Face 3 | Face 5
// pinch, 0 / 2 / 4 resting; split into two groups, top | sides; and the scratch variant after
// [Face 5 rests]); C1's plain pad (top pressed, bottom resting, bare and covered; a ±X pinch with
// nothing resting). They are offscreen frames of the shipping renderer, not device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import ImageIO
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishEvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_G_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static let size = 900
    static let views: [(String, Float, Float)] = [("iso", .pi / 4, .pi / 6), ("right", .pi / 2, 0.05), ("front", 0, 0.35)]

    /// A main stage over `project`, its lattice built through Save & Exit and its sims landed.
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
        stage.refresh()
        try await FlexibleHisProject.waitFor(300, "\(what): the sims") {
            stage.refresh()
            return !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        stage.refresh()
        FlexibleSquishFixture.log(m, what)
        return (stage, m)
    }

    func render(_ stage: FlexibleMainStage, _ project: ProjectModel, name: String, amount: Float, view: (String, Float, Float),
                device: MTLDevice, dir: URL) throws {
        guard let mesh = stage.mesh(project, on: .lattice), let ch = stage.channels else { XCTFail("\(name): no overlay"); return }
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(mesh)
        let settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = stage.tints(project, on: .lattice, roles: [:], stress: nil) { mr.setVertexTints(t) }
        mr.setBodyAlpha(stage.bodyAlpha(project, on: .lattice) ?? 1)
        let layer = stage.layer(project, stage: .lattice, pageUp: false)
        mr.applyFlexibleLattice(layer, device: device)
        if let l = layer, !l.feSequence.isEmpty, let pass = mr.flexibleLattice {
            // what the loop's renderer step does as a cycle begins: the field and its mesh together
            let i = l.feSequence[0]
            pass.bindFE(i)
            mr.setFlexDisplacements(l.feMesh[i])
        } else if let d = stage.dents(project, on: .lattice) {
            mr.setFlexDisplacements(d)
        }
        mr.setFlexScale(Float(ch.exaggeration) * amount)
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: Self.size, to: dir.appendingPathComponent("\(name)_\(view.0)_a\(Int(amount * 100)).png"))
    }

    /// BEFORE (the column squish) and AFTER (the group's 3D sim), for every group of the lattice.
    func beforeAfter(_ stage: FlexibleMainStage, _ m: FlexibleStageModel, _ project: ProjectModel, case name: String,
                     device: MTLDevice, dir: URL, views: [(String, Float, Float)] = views) throws {
        let groups = m.squishSims.map(\.sim.id)
        for g in groups {
            if groups.count > 1 { stage.pick(g) }
            for (tag, column) in [("before", true), ("after", false)] {
                stage.controlColumnSquish = column
                stage.refresh()
                print("FLEX-G-EVIDENCE \(name) \(g) \(tag): k \(stage.channels?.exaggeration ?? 0) · FE \(stage.fe.active) · note '\(stage.simNote ?? "-")' · (i) '\(stage.dentInfo)'")
                for v in views {
                    for a: Float in [0, 0.5, 1] {
                        try render(stage, project, name: "G_\(name)_\(g)_\(tag)", amount: a, view: v, device: device, dir: dir)
                    }
                }
            }
        }
        stage.controlColumnSquish = false
        stage.refresh()
    }

    func testHisProjectBeforeAndAfter() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_G_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // as saved: one group, the top and the 3 | 5 pinch; 0, 2, 4 resting
        do {
            let r = try FlexibleHisProject.restore()
            addTeardownBlock { r.cleanup() }
            let (stage, m) = try await stage(r.project, "his 0004 as saved")
            try beforeAfter(stage, m, r.project, case: "his0004", device: device, dir: dir)
        }
        // his img 4: the sides in their own group (two sims; Play all plays them in turn)
        do {
            let r = try FlexibleHisProject.restore()
            addTeardownBlock { r.cleanup() }
            let (stage, m) = try await stage(r.project, "his 0004 top | sides") { m in
                m.edit { s in
                    _ = FlexibleSqueezeGroups.newGroup(with: 3, in: &s)
                    FlexibleSqueezeGroups.move(5, to: FlexibleSqueezeGroups.group(of: 3, in: s)!.id, in: &s)
                }
            }
            try beforeAfter(stage, m, r.project, case: "his0004split", device: device, dir: dir)
        }
        // the scratch variant: [Face 5 rests]
        do {
            let r = try FlexibleHisProject.restore()
            addTeardownBlock { r.cleanup() }
            let (stage, m) = try await stage(r.project, "his 0004 face 5 rests") { $0.rest(5) }
            try beforeAfter(stage, m, r.project, case: "his0004rest5", device: device, dir: dir, views: [Self.views[0], Self.views[1]])
        }
    }

    func testGenericPadBeforeAndAfter() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_G_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for finish in ["none", "covered"] {
            let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
            let mesh = try XCTUnwrap(pm.viewerMesh)
            let (stage, m) = try await stage(pm, "pad top \(finish)") { m in
                _ = m.press(FlexibleHisProject.topFace(mesh), kg: 30)
                m.rest(FlexibleSquishFixture.bottomFace(mesh))
                m.edit { $0.finish = finish }
            }
            try beforeAfter(stage, m, pm, case: "padTop_\(finish)", device: device, dir: dir)
        }
        // a ±X pinch with nothing resting (bare)
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let (stage, m) = try await stage(pm, "pad ±X pinch") { m in
            _ = m.press(FlexibleSquishFixture.face(mesh, axis: 0, value: 0), kg: 10)
            _ = m.press(FlexibleSquishFixture.face(mesh, axis: 0, value: 100), kg: 10)
            m.edit { $0.finish = "none" }
        }
        try beforeAfter(stage, m, pm, case: "padPinchX", device: device, dir: dir)
    }

    /// The M2 stand, its top pressed at 5 kg on its resting bottom: a slender, all-lattice part
    /// whose multigrid stagnates (the work budget lets Jacobi-CG land it) and whose field is steep.
    func testTheM2StandBeforeAndAfter() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_G_EVIDENCE_DIR") }
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
        try beforeAfter(stage, m, pm, case: "m2stand", device: device, dir: dir)
    }
}
#endif
