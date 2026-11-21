// FlexibleRound6EvidenceProbe — round 6's renders of the MODEL (task 2026-09-29-flexible-screens, round 6, items
// 1 and 3). Opt-in:
//     FLEX_R6_EVIDENCE_DIR=<dir> swift test --filter FlexibleRound6EvidenceProbe
//
// ★ THE PAGES' OWN PICTURE, BY THE SHIPPING RENDERER: MeshRenderer's offscreen render of exactly what each page
// hands MetalMeshView — the Settings page (its composed tints, its dent, X-ray, `FlexibleStageVolumes.items`:
// the prisms and the glass) and the main Flexible page after Save & Exit (FlexibleMainStage's mesh / tints /
// dents / lattice layer). HIS pad A1_0003 restored as he saved it (his img1–img4). The chip and the mm tags are
// SwiftUI on the device: here they are drawn onto the frame at the points the page projects them to (marked).
// BEFORE = round 5's frames (`controlRound5Frames`). Offscreen frames, not device screenshots.
// ★ R6 REVIEW: the glass over the page's own heat (FlexibleGroupWalls.heatSamples — its alpha is its colour's over it),
// ONE k (`prismK`), and the dashed outline of every shown member that faces away (FlexibleStageViewTags.hidden — SwiftUI
// on the device, drawn here at the points the page projects); the tabs of all three groups and [Rests].
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleRound6EvidenceProbe: XCTestCase {

    static var dir: URL? {
        ProcessInfo.processInfo.environment["FLEX_R6_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static let size = 900
    typealias Cam = FlexibleRound6Tests.Cam

    struct Mark { let point: CGPoint; let text: String; let fill: RGBA; var opacity: CGFloat = 1 }

    func renderer(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf,
                  cam: Cam, device: MTLDevice, items: [ClearanceRenderItem], layer: FlexibleLatticeLayerInputs? = nil) throws -> MeshRenderer {
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(mesh)
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        if let t = tints { mr.setVertexTints(t) }
        mr.setBodyAlpha(bodyAlpha)
        if let layer { _ = mr.applyFlexibleLattice(layer, device: device) }
        if let d = dents { mr.setFlexDisplacements(d) }
        mr.setFlexScale(scale)
        mr.setClearanceVolumes(items)
        return mr
    }

    /// The renderer's own clip-from-model, as a page projection over the 900 pt frame.
    func projection(_ mr: MeshRenderer) -> CameraProjection {
        CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: Self.size, height: Self.size))
    }

    /// Write the frame with `marks` drawn on it (the SwiftUI chip / tags / discs the page places there).
    func write(_ mr: MeshRenderer, _ name: String, marks: [Mark] = [], dashed: [FlexibleStageViewTags.Hidden] = []) throws {
        guard let dir = Self.dir else { return }
        let bg = DS.Color.background
        let px = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        var rgba = px
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let n = Self.size
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)   // y down, as the page
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for h in dashed {   // ★ R6 REVIEW: as FlexibleStageViewTagsLayer strokes them
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: h.colour.r, green: h.colour.g, blue: h.colour.b, alpha: 1))
            ctx.setLineWidth(FlexibleStageViewTags.hiddenLineWidth)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: FlexibleStageViewTags.hiddenDash)
            for loop in h.paths { ctx.addLines(between: loop); ctx.closePath() }
            ctx.strokePath()
            ctx.restoreGState()
        }
        for m in marks {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: m.text, attributes: attrs)
            let sz = s.size()
            let r = CGRect(x: m.point.x - sz.width / 2 - 10, y: m.point.y - sz.height / 2 - 6, width: sz.width + 20, height: sz.height + 12)
            ctx.setAlpha(m.opacity)
            ctx.setFillColor(CGColor(red: m.fill.r, green: m.fill.g, blue: m.fill.b, alpha: 0.85))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
            ctx.fillPath()
            s.draw(at: CGPoint(x: r.minX + 10, y: r.minY + 6))
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-R6-EVIDENCE wrote \(url.path)")
    }

    func testTheSettingsPageAndTheMainPageOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R6_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                            persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        try await FlexibleHisProject.waitFor(60, "the maps") { m.loadedKeys.allSatisfy { m.liveS[$0] != nil } }
        let part = try XCTUnwrap(r.project.viewerMesh)
        let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let iso = FlexibleRound6Tests.iso, top = FlexibleRound6Tests.topCam
        // ── the Settings page, as the page composes it for the model's state now
        func settings(_ name: String, _ cam: Cam, frames: Bool = false, chip: Bool = false, tags: Bool = false) throws {
            FlexibleStagePage.controlRound5Frames = frames
            defer { FlexibleStagePage.controlRound5Frames = false }
            let c = FlexibleStagePage.composeTints(model: m, overlay: o)
            var cache: (key: String, dents: [Float])?
            let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
            let k = FlexibleStageVolumes.prismK(sq.exaggeration)
            let heat = FlexibleGroupWalls.heatSamples(tints: c.tints, overlay: o, model: m)
            let items = frames ? [] : FlexibleStageVolumes.items(model: m, k: k, part: part, heat: heat)
            let mr = try renderer(mesh: o.mesh, tints: c.tints, dents: sq.dents, scale: Float(sq.exaggeration), bodyAlpha: FlexibleStagePage.xrayBodyAlpha,
                                  settle: settle, cam: cam, device: device, items: items)
            let proj = projection(mr)
            let dashed = frames ? [] : FlexibleStageViewTags.hidden(model: m, projection: proj)
            var marks: [Mark] = []
            if chip, let h = FlexibleDepthChips.handle(model: m, k: k), let p = proj.project(h.anchor), let f = m.selectedRegion.flatMap({ m.settings.face($0) }) {
                marks.append(Mark(point: p, text: String(format: "↓ %.1f mm", f.deepestMM), fill: FlexibleStageStyle.facePrismKnob))
            }
            if tags {
                for t in FlexibleStageViewTags.tags(model: m, k: k, projection: proj, keepOut: []) {
                    marks.append(Mark(point: t.point, text: t.text, fill: DS.Surface.panel))
                }
            }
            try write(mr, name, marks: marks, dashed: dashed)
            print("FLEX-R6-EVIDENCE \(name): dashed \(dashed.map(\.id)) · rail \(m.rail) · selected \(m.selectedRegion.map(String.init) ?? "—") · views \(m.views.rawValue) · items " +
                  items.map { "\($0.volume.faceID)\($0.surfaceOnly ? "g" : "p")\($0.faceAlpha.map { String(format: "%.2f", $0) } ?? "nil")" }.joined(separator: ","))
        }
        // img2: Group 2's tab open (face 4 selected — its faint prism too)
        m.rail = .group(2)
        try settings("R6_S_img2_before_round5_frames_iso.png", iso, frames: true)
        try settings("R6_S_img2_after_group2_glass_iso.png", iso, chip: true)
        // img3: [Model] with face 2 selected — its faint prism, its chip, Group 2's glass
        m.selectedRegion = 2
        m.rail = .model
        try settings("R6_S_img3_before_round5_frames_top.png", top, frames: true)
        try settings("R6_S_img3_after_face2_prism_top.png", top, chip: true)
        try settings("R6_S_img3_after_face2_prism_iso.png", iso, chip: true)
        // ★ R6 REVIEW: each group's tab (nothing selected), and [Rests] (the bottom faces away: dashed)
        m.selectedRegion = nil
        for (g, cam) in [(1, iso), (2, iso), (3, iso), (1, top)] {
            m.rail = .group(g)
            try settings("R6R_S_group\(g)_tab_\(cam.name == top.name ? "top" : "iso").png", cam)
        }
        m.rail = .rests
        try settings("R6R_S_rests_tab_iso.png", iso)
        try settings("R6R_S_rests_tab_top.png", top)
        m.rail = .model
        m.views = [.groups]
        try settings("R6R_S_groups_view_none_open_iso.png", iso)
        // the Groups view
        m.rail = .group(2)
        m.views = [.groups]
        try settings("R6_S_groups_view_iso.png", iso)
        try settings("R6_S_groups_view_top.png", top)
        // the Prisms view (face 2 selected: its chip; the others' tags)
        m.select(2)
        m.views = [.prisms]
        try settings("R6_S_prisms_view_iso.png", iso, chip: true, tags: true)
        try settings("R6_S_prisms_view_top.png", top, chip: true, tags: true)
        // Group 2's glass zoomed out and grazing
        m.views = []
        m.rail = .group(2)
        try settings("R6_S_group2_zoomed_out.png", Cam(name: "zoomed out", azimuth: .pi / 4, elevation: .pi / 6, zoom: 4))
        try settings("R6_S_group2_grazing.png", Cam(name: "grazing", azimuth: .pi / 4, elevation: 0.12, zoom: 1))

        // ── the main page after Save & Exit (img1's view): round 5's frames before, none after
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding }
        stage.refresh()
        let mesh = try XCTUnwrap(stage.mesh(r.project, on: .lattice))
        let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        for (name, frames) in [("before_round5_frames", true), ("after", false)] {
            stage.latticeOn = true
            stage.heat = false
            stage.controlRound5Frames = frames
            stage.refresh()
            let tints = stage.tints(r.project, on: .lattice, roles: [:], stress: nil)
            let mr = try renderer(mesh: mesh, tints: tints, dents: stage.dents(r.project, on: .lattice), scale: Float(stage.channels?.exaggeration ?? 1),
                                  bodyAlpha: stage.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: img1, device: device, items: [],
                                  layer: stage.layer(r.project, stage: .lattice, pageUp: false))
            try write(mr, "R6_M_img1_lattice_on_heat_off_\(name).png")
        }
        stage.controlRound5Frames = false
        // the main page's Prisms view (the list hook H15 will hand the viewer on the S1 base — not yet drawn there)
        m.views = [.prisms]
        let vols = stage.volumes(r.project, on: .lattice, drilledIn: false)
        let mr = try renderer(mesh: mesh, tints: stage.tints(r.project, on: .lattice, roles: [:], stress: nil),
                              dents: stage.dents(r.project, on: .lattice), scale: Float(stage.channels?.exaggeration ?? 1),
                              bodyAlpha: stage.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: img1, device: device, items: vols,
                              layer: stage.layer(r.project, stage: .lattice, pageUp: false))
        try write(mr, "R6_M_prisms_view_awaiting_H15.png")
        m.views = []
        print("FLEX-R6-EVIDENCE main: \(vols.count) prisms in the Prisms view")
    }

    /// ★ S1b (round 6 item 3, the main page, H15 in): what the main Flexible page hands the viewer now — FlexibleMainStage's
    /// mesh / tints / dents / lattice layer AND its `volumes` (H15's list: the active Selections group's faint prisms, or
    /// every one with [Prisms]) — with the read-only mm tags drawn where the page projects them (`prismTags`, marked;
    /// SwiftUI on the device). His A1_0003 (img1–img4) and his round-5 pad, each as saved, after Save & Exit. #354's own
    /// depth planes (`stageVolumeItems`, the other half of H15's line) are not drawn here. Offscreen frames, not device
    /// screenshots.
    func testTheMainPagesPrismsAndTagsOnHisPadAndHisRound5() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R6_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
        for (label, r) in [("A1_0003", try FlexiblePressFixtures.a1Project(3, self)), ("r5", try FlexiblePressFixtures.hisRound5(self))] {
            let stage = FlexibleMainStage()
            stage.reduceMotion = { true }
            let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath,
                                persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            m.openScene()
            try await FlexibleSquishFixture.settle(m, label)
            stage.didExitSettings()
            stage.apply(r.project, owned: true, pageUp: false)
            try await FlexibleHisProject.waitFor(240, "the lattice (\(label))") { m.lattice != nil && !m.latticeBuilding }
            stage.refresh()
            let mesh = try XCTUnwrap(stage.mesh(r.project, on: .lattice))
            let settle = r.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
            func main(_ name: String, latticeOn: Bool) throws {
                stage.latticeOn = latticeOn
                stage.refresh()
                let items = stage.volumes(r.project, on: .lattice, drilledIn: false)
                let mr = try renderer(mesh: mesh, tints: stage.tints(r.project, on: .lattice, roles: [:], stress: nil),
                                      dents: stage.dents(r.project, on: .lattice), scale: Float(stage.channels?.exaggeration ?? 1),
                                      bodyAlpha: stage.bodyAlpha(r.project, on: .lattice) ?? 1, settle: settle, cam: img1, device: device,
                                      items: items, layer: stage.layer(r.project, stage: .lattice, pageUp: false))
                let proj = projection(mr)
                let tags = stage.prismTags(r.project, on: .lattice, drilledIn: false, viewport: proj.viewportSize, keepOut: [],
                                           projector: { proj.project($0) })
                try write(mr, name, marks: tags.map { Mark(point: $0.point, text: $0.text, fill: DS.Surface.panel) })
                // ★ how visible the faint prisms are on the main page (round 6's open check): the same frame without
                // them, the max-channel Δ (0-255) over the pixels they change
                let bg = DS.Color.background
                let clear = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
                let with = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: clear))
                mr.setClearanceVolumes([])
                let without = try XCTUnwrap(mr.renderOffscreen(size: Self.size, clear: clear))
                var deltas: [Int] = []
                for i in stride(from: 0, to: min(with.count, without.count), by: 4) {
                    let d = (0..<3).map { abs(Int(with[i + $0]) - Int(without[i + $0])) }.max() ?? 0
                    if d > 2 { deltas.append(d) }
                }
                deltas.sort()
                let q = { (p: Double) -> Int in deltas.isEmpty ? 0 : deltas[min(deltas.count - 1, Int(Double(deltas.count) * p))] }
                // every shown prism's floor on screen, kept or dropped (greedy: the larger face first)
                let floors = items.compactMap { it -> String? in
                    guard let h = FlexibleDepthPrism.handle(it.volume), let p = proj.project(h.anchor) else { return "face \(it.volume.faceID) off screen" }
                    let kept = tags.contains { $0.region == it.volume.faceID }
                    return String(format: "face %d at (%.0f, %.0f)%@", it.volume.faceID, p.x, p.y, kept ? "" : " DROPPED (overlaps a larger face's tag)")
                }
                print("FLEX-R6-S1b-EVIDENCE \(name): active \(r.project.selection.activeGroup?.name ?? "—") · views \(m.views.rawValue) · "
                      + "lattice \(stage.latticeShown) · prisms \(items.map(\.volume.faceID)) k \(stage.prismK) · tags "
                      + tags.map { "face \($0.region) \($0.text)" }.joined(separator: ", ")
                      + " · floors " + floors.joined(separator: ", ")
                      + " · prisms' Δ over \(deltas.count) px: median \(q(0.5)) p90 \(q(0.9)) max \(deltas.last ?? 0)")
            }
            m.views = []
            print("FLEX-R6-S1b-EVIDENCE \(label) groups: " + r.project.selection.groups.map { "\($0.name) faces \($0.faces) regions \($0.regionIDs.count)" }.joined(separator: " · "))
            // each main-page group that presses something, picked in Selections: its squish at once
            for g in r.project.selection.groups {
                r.project.selection.setActive(g.id)
                guard !stage.volumes(r.project, on: .lattice, drilledIn: false).isEmpty else { continue }
                let slug = g.name.replacingOccurrences(of: " ", with: "_")
                try main("R6_S1b_M_\(label)_\(slug)_active_lattice_on.png", latticeOn: true)
                try main("R6_S1b_M_\(label)_\(slug)_active_lattice_off.png", latticeOn: false)
            }
            // [Prisms]: every prism, the Lattice view with it
            stage.latticeOn = false
            stage.togglePrisms()
            try main("R6_S1b_M_\(label)_prisms_view.png", latticeOn: stage.latticeOn)
            stage.togglePrisms()
            m.views = []
        }
    }

    /// ★ THE NINE-GROUP DISCS: the octagonal prism, nine groups (1 and 9 share green), the Groups view.
    func testTheNineGroupDiscs() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_R6_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (pm, dir) = try FlexibleGroupPaletteHostedTests.prismProject()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let (s, _, _) = try FlexibleGroupPaletteHostedTests.nineGroups(pm)
        pm.lattice.flexible = s
        let m = try await FlexibleHisProject.openedModel(pm, test: self, timeout: 120)
        try await FlexibleSquishFixture.settle(m, "prism")
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        m.rail = .group(9)
        m.views = [.groups]
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mr = try renderer(mesh: o.mesh, tints: c.tints, dents: nil, scale: 0, bodyAlpha: FlexibleStagePage.xrayBodyAlpha, settle: settle,
                              cam: FlexibleRound6Tests.Cam(name: "iso", azimuth: .pi / 3, elevation: 0.5, zoom: 1), device: device,
                              items: FlexibleStageVolumes.items(model: m, k: 1, part: pm.viewerMesh))
        let marks = FlexibleStageViewTags.discs(model: m, projection: projection(mr), keepOut: []).map {
            Mark(point: $0.point, text: "\($0.disc.number)", fill: $0.disc.colour, opacity: $0.facesAway ? 0.4 : 1)   // (40 % facing away, as the page)
        }
        try write(mr, "R6_S_nine_groups_discs.png", marks: marks)
        print("FLEX-R6-EVIDENCE nine groups: discs \(marks.map(\.text))")
    }
}
#endif
