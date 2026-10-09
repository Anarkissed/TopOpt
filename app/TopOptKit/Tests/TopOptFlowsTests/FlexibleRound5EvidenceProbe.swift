// FlexibleRound5EvidenceProbe — the round-5 S renders of the MODEL (task 2026-09-29-flexible-screens,
// round 5 batch S1 / S2). Opt-in:
//     FLEX_S_EVIDENCE_DIR=<dir> swift test --filter FlexibleRound5EvidenceProbe
//
// ★ THE PAGES' OWN PICTURE, BY THE SHIPPING RENDERER: MeshRenderer's offscreen render of exactly what
// each page hands MetalMeshView — the Settings page (its overlay, its tints WITH the group frames, the
// playing group's dent, X-ray body alpha) and the main Flexible page (FlexibleMainStage's mesh / tints
// / dents after a Save & Exit). HIS project 0004 restored, split as his img 4 (Face 3 in its own group).
// BEFORE = round 4's tints (no frames) and every group's dent at once. They are offscreen frames, not
// device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound5EvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_S_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static let size = 900
    static let views: [(String, Float, Float)] = [("iso", .pi / 4, .pi / 6), ("top", .pi / 5, 1.1)]

    func render(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf,
                view: (String, Float, Float), device: MTLDevice, to url: URL, layer: FlexibleLatticeLayerInputs? = nil) throws {
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(mesh)
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(bodyAlpha)
        if let layer { mr.applyFlexibleLattice(layer, device: device) }
        if let d = dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(scale)
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: Self.size, to: url)
    }

    func testTheGroupColoursAndThePlayingGroupOnBothPages() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_S_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        stage.controlColumnSquish = true   // the main page's picture without waiting for the sims
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                            persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the scene") { m.sceneState == .ready }
        m.newGroup(with: 3)   // his img 4: Face 3 its own squeeze group
        try await FlexibleSquishFixture.settle(m, "his split")
        try await FlexibleHisProject.waitFor(30, "the maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        // ── the Settings page
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        for (tag, sel) in [("group1_topA", FlexibleHisProject.topA), ("group2_face3", 3)] {
            m.select(sel)
            var c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
            let before = c
            FlexibleGroupFrames.paint(&c.tints, overlay: o, model: m)
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
            for v in Self.views {
                try render(mesh: o.mesh, tints: c.tints, dents: sq.dents, scale: Float(sq.exaggeration), bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                           settle: settle, view: v, device: device, to: dir.appendingPathComponent("S_settings_\(tag)_after_\(v.0).png"))
                try render(mesh: o.mesh, tints: before.tints, dents: before.dents, scale: Float(before.exaggeration),
                           bodyAlpha: FlexibleStagePage.xrayBodyAlpha, settle: settle, view: v, device: device,
                           to: dir.appendingPathComponent("S_settings_\(tag)_before_\(v.0).png"))
            }
            print("FLEX-R5-EVIDENCE settings \(tag): playing Group \(sq.groupNumber ?? -1) · k \(sq.exaggeration) · FE \(sq.fe)")
        }
        // his pick: Group 2 in blue, Group 1 in terracotta (★ C5: S's red is gone)
        m.setGroupColour(2, .blue); m.setGroupColour(1, .terracotta)
        m.select(3)
        var c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        FlexibleGroupFrames.paint(&c.tints, overlay: o, model: m)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        try render(mesh: o.mesh, tints: c.tints, dents: sq.dents, scale: Float(sq.exaggeration), bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                   settle: settle, view: Self.views[0], device: device, to: dir.appendingPathComponent("S_settings_picked_red_blue_iso.png"))
        m.setGroupColour(1, .green); m.setGroupColour(2, .pink)
        // ── the main Flexible page after Save & Exit (the column squish; the lattice built)
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(180, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        stage.refresh()
        let mesh = try XCTUnwrap(stage.mesh(r.project, on: .lattice))
        for (lattice, heat) in [(false, true), (true, true), (false, false)] {
            stage.latticeOn = lattice
            stage.heat = heat
            stage.refresh()
            let tints = stage.tints(r.project, on: .lattice, roles: [:], stress: nil)
            for v in Self.views.prefix(1) {
                try render(mesh: mesh, tints: tints, dents: stage.dents(r.project, on: .lattice), scale: Float(stage.channels?.exaggeration ?? 1),
                           bodyAlpha: stage.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, view: v, device: device,
                           to: dir.appendingPathComponent("S_main_\(lattice ? "xray" : "solid")_\(heat ? "heat" : "noheat")_\(v.0).png"),
                           layer: stage.layer(r.project, stage: .lattice, pageUp: false))
            }
        }
        print("FLEX-R5-EVIDENCE main: groups \(m.squeezeGroups.map { "\($0.number)=\(FlexibleSqueezeGroups.colourChoice(of: $0, in: m.settings))" })")
    }
}
#endif
