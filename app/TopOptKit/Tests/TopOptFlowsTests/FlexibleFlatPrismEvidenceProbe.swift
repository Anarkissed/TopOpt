// FlexibleFlatPrismEvidenceProbe — round 7, batch R7-E1: the flat prism's pictures on HIS pad (A1_0003), for the handoff
// (round7/batch_e1/). FLEX_E1_EVIDENCE_DIR=<dir> runs it (else it skips, counted). Each picture: the model by the shipping
// renderer (MeshRenderer offscreen, the page's own clearance list — the wedge true size — and tints), the on-model overlay
// (FlexibleFlatPrismOverlay: traces, arrow, chip, knob, boxes) hosted at the same viewport and laid over it, and the Squish
// panel (hosted) at the left as on the page. NOT device screenshots.
//   Edge 16 (Face 3 + Face 2) at 3 / 10.6 / 17 mm; tilt ±15°; twist +10° (▼ at the deep end); each stop with its line; the
//   corner 1 + 3 + 2; the knob's arcs mid-drag; the card with no Strip width; his Group 3 (Edge 16 + Edge 18 at 15 mm, M2's
//   saved form) read through — beside his img_edges_1018.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class E1HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleFlatPrismEvidenceProbe: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias A = FlexibleFlatPrismAngles
    typealias Cam = FlexibleRound6Tests.Cam

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_E1_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let sizes: [(String, CGSize)] = [("13p", CGSize(width: 1032, height: 1376)), ("11p", CGSize(width: 834, height: 1194))]
    /// Outside Edge 16 (Face 3 + Face 2), looking along its halfway from 31° above — the arrow comes toward the camera.
    static let his = Cam(name: "outside Edge 16", azimuth: .pi / 4, elevation: 0.55, zoom: 1.45)
    var lines: [String] = []

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func hosted<V: View>(_ v: V, size: CGSize, clear: Bool) -> CGImage? {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        let w = E1HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = !clear
        w.backgroundColor = clear ? .clear : NSColor(red: DS.Color.background.r, green: DS.Color.background.g, blue: DS.Color.background.b, alpha: 1)
        w.contentView = hv
        w.orderFrontRegardless()
        hv.layoutSubtreeIfNeeded()
        pump(0.8)
        defer { w.orderOut(nil); w.contentView = nil }
        guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { return nil }
        hv.cacheDisplay(in: hv.bounds, to: rep)
        return rep.cgImage
    }

    struct PanelHost: View {
        @ObservedObject var model: FlexibleStageModel
        @State var pad: String?
        @State var minimized = false
        var body: some View { FlexibleSettingsPanel(model: model, padTarget: $pad, minimized: $minimized) }
    }

    /// The model offscreen at `size` (the shipping renderer, the page's clearance list), and the projection the overlay uses.
    func renderModel(_ m: FlexibleStageModel, _ p: ProjectModel, cam: Cam, size: CGSize, device: MTLDevice) throws -> (CGImage, CameraProjection) {
        let part = try XCTUnwrap(p.viewerMesh)
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let o = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let c = FlexibleStagePage.composeTints(model: m, overlay: o)
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: o, channels: c, feCache: &cache)
        let k = FlexibleStageVolumes.prismK(sq.exaggeration)
        let items = FlexibleStageVolumes.items(model: m, k: k, part: part)
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(o.mesh)
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
        mr.camera.distance *= cam.zoom
        if let t = c.tints { mr.setVertexTints(t) }
        mr.setClearanceVolumes(items)
        // (the shipping renderer draws square offscreen: the stage's width, square)
        let w = Int(size.width), h = Int(size.width)
        let proj = CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: w, height: h))
        let bg = DS.Color.background
        var rgba = try XCTUnwrap(mr.renderOffscreen(size: w, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
        let ctx = try XCTUnwrap(CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        return (try XCTUnwrap(ctx.makeImage()), proj)
    }

    /// The frame: the panel (left), the model with the overlay laid over it.
    func write(_ name: String, _ m: FlexibleStageModel, _ p: ProjectModel, cam: Cam, size: CGSize, device: MTLDevice,
               drag: ((FlexibleStageModel) -> Void)? = nil) throws {
        guard let dir = Self.dir else { return }
        drag?(m)
        let (model, proj) = try renderModel(m, p, cam: cam, size: size, device: device)
        let sq = CGSize(width: size.width, height: size.width)
        let overlay = hosted(FlexibleFlatPrismOverlay(model: m, projection: proj, keepOut: [], padTarget: .constant(nil))
            .frame(width: sq.width, height: sq.height), size: sq, clear: true)
        let panelH = sq.height
        let panel = hosted(PanelHost(model: m).frame(width: FlexibleSettingsPanel.width, height: panelH, alignment: .top)
            .background(DS.Color.background.color), size: CGSize(width: FlexibleSettingsPanel.width, height: panelH), clear: false)
        let pw = FlexibleSettingsPanel.width
        let W = Int(pw + sq.width), H = Int(sq.height)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: DS.Color.background.r, green: DS.Color.background.g, blue: DS.Color.background.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        if let panel { ctx.draw(panel, in: CGRect(x: 0, y: 0, width: pw, height: CGFloat(H))) }
        ctx.draw(model, in: CGRect(x: pw, y: 0, width: sq.width, height: sq.height))
        if let overlay { ctx.draw(overlay, in: CGRect(x: pw, y: 0, width: sq.width, height: sq.height)) }
        let img = try XCTUnwrap(ctx.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        lines.append("wrote \(name)")
        print("FLEX-E1-EVIDENCE wrote \(url.path)")
    }

    func testEvidenceOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_E1_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, m) = try await F.hisLivePad(self)
        let p = r.project
        let pick = try await F.M2.pickMode(m)
        let c16 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 2]), "Edge 16")
        let press = try await F.commit(m, c16)
        try await FlexibleHisProject.waitFor(120, "registered") { m.pressStack(press.id) != nil }
        m.selectedPress = press.id
        let label = try XCTUnwrap(press.strip?.label)
        let st = try XCTUnwrap(press.strip)
        let f = try XCTUnwrap(FlexibleFlatPrismUI.frame(m, press.id))
        lines.append("\(label) · halfway \(press.direction) · lattice cap \(m.flatLatticeCap(press.id) ?? -1) mm")
        for (tag, size) in Self.sizes {
            // the depth: 3 / 10.6 / 17 mm (a preview — the drag's own state, never stored)
            for h in [3.0, 15 * sin(Double.pi / 4), 17] {
                try write("E1_\(tag)_\(label.replacingOccurrences(of: " ", with: ""))_depth_\(String(format: "%.1f", h))mm.png", m, p, cam: Self.his, size: size, device: device) {
                    $0.previewFlatCut(press.id, depthMM: h, direction: press.direction)
                }
            }
            // tilt ±15°, twist +10° (▼ at the deep end)
            for (name, th, ph) in [("tilt_+15", 15.0, 0.0), ("tilt_-15", -15, 0), ("twist_+10", 0, 10)] {
                try write("E1_\(tag)_\(label.replacingOccurrences(of: " ", with: ""))_\(name).png", m, p, cam: Self.his, size: size, device: device) {
                    $0.previewFlatCut(press.id, depthMM: 10.6, direction: A.compose(f, theta: th, phi: ph))
                }
            }
            m.flatPreview = nil
        }
        // each stop with its line (said beside the handle, in the overlay; the lattice stop on the card)
        let lim = m.flatLimits(press.id, withLattice: true)
        let name: (Int) -> String = { FlexibleFlatPrismUI.memberName(m, st, $0) }
        for (what, tilt, sign) in [("tilt +", true, 1.0), ("tilt −", true, -1.0), ("twist +", false, 1.0)] {
            let l = A.limit(st, frame: f, h: 10.6, at: (0, 0), tilt: tilt, sign: sign, limits: lim)
            lines.append("\(what) stops at \(String(format: "%.2f", l.deg))° · \(l.stop.map { A.line($0, strip: st, name: name) } ?? "-")")
        }
        let range = A.depthRange(st, d: press.direction, limits: lim)
        lines.append("depth \(String(format: "%.2f", range.min))…\(String(format: "%.2f", range.max)) mm · \(range.maxStop.map { A.line($0, strip: st, name: name) } ?? "-")")
        let why = await m.setFlatCut(press.id, depthMM: 20, direction: press.direction, snap: press.snap)
        lines.append("a release at 20 mm: \(why ?? "stored") · [Set \(m.lastFlatStop?.setMM ?? -1) mm]")
        try write("E1_13p_\(label.replacingOccurrences(of: " ", with: ""))_lattice_stop_card.png", m, p, cam: Self.his, size: Self.sizes[0].1, device: device)
        // the camera on [Done] (D-AP-13 as ruled): down the arrow, the knob drawn ≥ 56 pt from the head
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        if let g = FlexibleFlatPrismUI.camera(press: press, settle: settle) {
            lines.append("camera on [Done]: \(g.id)")
        }
        print("FLEX-E1-EVIDENCE " + lines.joined(separator: "\n  "))
        if let dir = Self.dir {
            try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("E1_evidence_lines.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// The corner (Face 1 + Face 3 + Face 2) at its halfway; and his Group 3 (Edge 16 + Edge 18 at 15 mm, M2's saved form)
    /// read through, beside his img_edges_1018.
    func testEvidenceCornerAndHisGroup3ReadThrough() async throws {
        guard let dir = Self.dir else { throw XCTSkip("FLEX_E1_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = Self.sizes[0].1
        // ── the corner
        do {
            let (r, m) = try await F.hisLivePad(self)
            let pick = try await F.M2.pickMode(m)
            let c = try XCTUnwrap(F.corner(m, pick, faces: [1, 3, 2]), "the corner of Face 1, Face 3 and Face 2")
            let press = try await F.commit(m, c)
            m.selectedPress = press.id
            let st = try XCTUnwrap(press.strip)
            let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: press))
            let legs = (0..<3).compactMap { FlexibleFlatPrism.reach(st, member: $0, cut) }
            let f = FlexibleFlatPrismUI.frame(m, press.id)
            lines.append("\(st.label): halfway \(press.direction) · legs \(legs.map { String(format: "%.2f", $0) }) mm at \(cut.depthMM) mm · up/down into \(f.map { FlexibleFlatPrismUI.memberName(m, st, $0.tiltMember) } ?? "-") · left/right toward \(f.flatMap { $0.twistMember }.map { FlexibleFlatPrismUI.memberName(m, st, $0) } ?? "-")")
            try write("E1_13p_\(st.label.replacingOccurrences(of: " ", with: ""))_corner_1_3_2.png", m, r.project, cam: Self.his, size: size, device: device) {
                $0.previewFlatCut(press.id, depthMM: 6, direction: nil)
            }
            m.flatPreview = nil
        }
        // ── his Group 3 in M2's saved form, read through
        let (r, m) = try await F.hisLivePad(self)
        let pick = try await F.M2.pickMode(m)
        let e16 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 2])), e18 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 4]))
        m.toggleEdgePick(e16.number); m.toggleEdgePick(e18.number)
        let why = try await F.M2.done(m, kg: 5 * 0.45359237)
        XCTAssertNil(why)
        var flex = try XCTUnwrap(r.project.lattice.flexible)
        flex.presses = flex.presses?.map { p in var q = p; q.strip?.widthMM = 15; q.strip?.halfway = nil; q.settings.deepestMM = 3; return q }
        let r2 = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(r2.project)
        r2.project.lattice.flexible = flex
        r2.project.seedUndoBaseline()
        let m2 = try await FlexibleAngledGoldens.openModel(self, r2.project, "his Group 3, M2's form")
        try await FlexibleSquishFixture.settle(m2, "his Group 3, M2's form")
        let g = try XCTUnwrap(m2.squeezeGroups.first { $0.kind == .edges })
        m2.rail = .group(g.id)
        m2.selectedPress = g.presses.first
        for p in m2.presses where p.strip != nil {
            let st = try XCTUnwrap(p.strip)
            let cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: p))
            lines.append("read through: \(st.label) widthMM \(st.widthMM ?? -1) → \(String(format: "%.4f", cut.depthMM)) mm deep · reach \((0..<2).compactMap { FlexibleFlatPrism.reach(st, member: $0, cut) }.map { String(format: "%.4f", $0) }) · toast \(m2.toast ?? "-")")
        }
        try write("E1_13p_his_Group3_read_through.png", m2, r2.project, cam: Self.his, size: size, device: device)
        // beside his screenshot
        let mine = try XCTUnwrap(CGImageSourceCreateWithURL(dir.appendingPathComponent("E1_13p_his_Group3_read_through.png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let hisURL = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-flexible-screens-track-9be87b/34b04738-a268-4a5a-ae7c-a988b298b7e9/scratchpad/r7e/img_edges_1018.png")
        if let src = CGImageSourceCreateWithURL(hisURL as CFURL, nil), let his = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let h = mine.height, hw = Int(Double(his.width) * Double(h) / Double(his.height))
            let W = hw + mine.width + 24
            let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: h, bitsPerComponent: 8, bytesPerRow: W * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: h))
            ctx.draw(his, in: CGRect(x: 0, y: 0, width: hw, height: h))
            ctx.draw(mine, in: CGRect(x: hw + 24, y: 0, width: mine.width, height: h))
            let img = try XCTUnwrap(ctx.makeImage())
            let url = dir.appendingPathComponent("E1_his_img_edges_1018_beside_the_read_through.png")
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, img, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            lines.append("wrote E1_his_img_edges_1018_beside_the_read_through.png")
        }
        print("FLEX-E1-EVIDENCE-2 " + lines.joined(separator: "\n  "))
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("E1_evidence_lines_2.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
