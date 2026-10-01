// FlexibleGroupPaletteEvidenceProbe — the round-5 C5 renders of the MODEL (task
// 2026-09-29-flexible-screens, round 5 batch C5: the eight group colours and the ninth group's
// number). Opt-in:
//     FLEX_C5_EVIDENCE_DIR=<dir> swift test --filter FlexibleGroupPaletteEvidenceProbe
//
// ★ THE PAGE'S OWN PICTURE, BY THE SHIPPING RENDERER: MeshRenderer's offscreen render of exactly what
// the Settings page hands MetalMeshView (its overlay, its tints WITH the group frames, the playing
// group's dent, the X-ray body). HIS project 0004 restored with batch S's six groups; and an octagonal
// prism with nine groups, where group 9 wears group 1's green — groups 1 and 9 carry their number,
// painted into the same tints (FlexibleGroupNumbers). Offscreen frames, not device screenshots.
#if canImport(MetalKit)
import XCTest
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleGroupPaletteEvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_C5_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static let size = 900
    static let views: [(String, Float, Float)] = [("iso", .pi / 4, .pi / 6), ("top", .pi / 5, 1.1)]

    /// Renders and returns the renderer's own clip-from-model (for the discs).
    @discardableResult
    func render(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf,
                view: (String, Float, Float), device: MTLDevice, to url: URL) throws -> CameraProjection {
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(mesh)
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: view.1, elevation: view.2)
        if let t = tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(bodyAlpha)
        if let d = dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(scale)
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        try FlexibleLatticeEvidenceProbe.writeBGRA(px, size: Self.size, to: url)
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: Self.size, height: Self.size))
    }

    func settingsPicture(_ m: FlexibleStageModel) throws -> (FlexibleOverlayMesh, [Float]?, FlexibleSettingsSquish.Shown) {
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        var c = FlexiblePageChannels.channels(model: m, overlay: o, xray: true, drawnLattice: nil)
        FlexibleGroupFrames.paint(&c.tints, overlay: o, model: m)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        return (o, c.tints, sq)
    }

    func testSixGroupsOnHisPadAndNineOnAPrism() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_C5_EVIDENCE_DIR") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // ── his pad, batch S's six groups
        let r = try FlexibleHisProject.restore()
        addTeardownBlock { r.cleanup() }
        let m = try await FlexibleHisProject.openedModel(r.project, test: self, timeout: 90)
        for f in [2, 4] { _ = m.press(f) }
        for f in [3, 5, FlexibleHisProject.topB, 2, 4] { m.newGroup(with: f) }
        try await FlexibleSquishFixture.settle(m, "six groups")
        try await FlexibleHisProject.waitFor(60, "the maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        m.select(3)
        let (o, tints, sq) = try settingsPicture(m)
        for v in Self.views {
            try render(mesh: o.mesh, tints: tints, dents: sq.dents, scale: Float(sq.exaggeration), bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                       settle: settle, view: v, device: device, to: dir.appendingPathComponent("C5_settings_six_groups_\(v.0).png"))
        }
        print("FLEX-C5-EVIDENCE his pad: groups \(m.squeezeGroups.map { "\($0.number)=\(FlexibleSqueezeGroups.colourChoice(of: $0, in: m.settings).rawValue):\($0.regions)" }) · playing \(sq.groupNumber ?? -1)")
        // ── an octagonal prism, nine groups (group 9 wears green, as group 1 does)
        let (pm, pdir) = try FlexibleGroupPaletteHostedTests.prismProject()
        addTeardownBlock { try? FileManager.default.removeItem(at: pdir) }
        let (s, _, _) = try FlexibleGroupPaletteHostedTests.nineGroups(pm)
        pm.lattice.flexible = s
        let pmModel = try await FlexibleHisProject.openedModel(pm, test: self, timeout: 120)
        try await FlexibleSquishFixture.settle(pmModel, "nine groups")
        let pSettle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let (po, ptints, psq) = try settingsPicture(pmModel)
        for v in Self.views {
            let url = dir.appendingPathComponent("C5_prism_nine_groups_\(v.0).png")
            try render(mesh: po.mesh, tints: ptints, dents: psq.dents, scale: Float(psq.exaggeration), bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                       settle: pSettle, view: v, device: device, to: url)
        }
        print("FLEX-C5-EVIDENCE prism: groups \(pmModel.squeezeGroups.map { "\($0.number)=\(FlexibleSqueezeGroups.colourChoice(of: $0, in: pmModel.settings).rawValue)" }) · numbered \(FlexibleGroupNumbers.shared(in: pmModel.settings).sorted())")
    }
}
#endif
