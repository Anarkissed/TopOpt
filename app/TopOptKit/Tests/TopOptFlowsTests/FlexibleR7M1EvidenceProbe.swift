// FlexibleR7M1EvidenceProbe — round 7 batch M1's pictures, on HIS pad (A1_0003). Opt-in:
//     FLEX_R7M1_EVIDENCE_DIR=<dir> swift test --filter FlexibleR7M1EvidenceProbe
// ★ THE PAGE'S OWN PICTURE, BY THE SHIPPING RENDERER, UNDER THE PAGE'S OWN CHROME: MeshRenderer's offscreen render of exactly
// what the main Flexible page hands MetalMeshView (FlexibleMainStage's mesh / tints / dents / body alpha / lattice layer and
// — hook H15' — its `volumes`, the ONLY volumes on the Flexible stage now), with the page's SwiftUI chrome hosted offscreen
// over it (the view icons, the ONE legend card, the player slot, the bottom pill; the Export step where it is the subject).
// Offscreen frames, not device screenshots; the camera is the probe's (his img1 / img2 views). His pad as he SAVED it sets no
// face-prism; "his live lattice" is his simulator's copy of 2026-10-14 (Group C = Face 3 + Face 5, Lattice at 25 mm),
// applied through the main page's own setters (FlexibleR7M1Fixtures.hisLiveLattice). #354's Selections card and its
// bottom-right chip column are WorkspacePlaceholder's own views (not hosted here): the list's number is printed beside each
// picture instead, and H18's column is pinned by FlexibleR7M1Tests.
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import SwiftUI
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7M1ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7M1EvidenceProbe: XCTestCase {

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_R7M1_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)
    static let img2 = Cam(name: "img2 (front)", azimuth: 0, elevation: 0.16, zoom: 1)
    static let p13 = ("13p", CGSize(width: 1032, height: 1376)), l11 = ("11l", CGSize(width: 1194, height: 834))

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    func hostedPixels<V: View>(_ v: V, size: CGSize, settle: Double = 1.5) throws -> (px: [UInt8], w: Int, h: Int) {
        let hv = NSHostingView(rootView: AnyView(v.environment(\.colorScheme, .dark)))
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7M1ProbeWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.orderFrontRegardless()
        defer { w.orderOut(nil); w.contentView = nil }
        pump(settle)
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        var buf = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (buf, cg.width, cg.height)
    }

    /// The model (BGRA, n × n) under the chrome (RGBA), written as `name` (the chrome's ground made clear).
    func composite(model px: [UInt8], n: Int, chrome: (px: [UInt8], w: Int, h: Int), name: String) throws {
        guard let dir = Self.dir else { return }
        let bg = DS.Color.background
        let gr = UInt8((bg.r * 255).rounded()), gg = UInt8((bg.g * 255).rounded()), gb = UInt8((bg.b * 255).rounded())
        var model = px
        for i in stride(from: 0, to: model.count, by: 4) { model.swapAt(i, i + 2); model[i + 3] = 255 }
        let mctx = try XCTUnwrap(CGContext(data: &model, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let mimg = try XCTUnwrap(mctx.makeImage())
        var c = chrome.px
        for i in stride(from: 0, to: c.count, by: 4) where abs(Int(c[i]) - Int(gr)) <= 3 && abs(Int(c[i + 1]) - Int(gg)) <= 3
            && abs(Int(c[i + 2]) - Int(gb)) <= 3 && c[i + 3] == 255 {
            c[i] = 0; c[i + 1] = 0; c[i + 2] = 0; c[i + 3] = 0
        }
        let cctx = try XCTUnwrap(CGContext(data: &c, width: chrome.w, height: chrome.h, bitsPerComponent: 8, bytesPerRow: chrome.w * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: chrome.w, height: chrome.h, bitsPerComponent: 8, bytesPerRow: chrome.w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: chrome.w, height: chrome.h))
        let short = CGFloat(min(chrome.w, chrome.h))
        out.draw(mimg, in: CGRect(x: (CGFloat(chrome.w) - short) / 2, y: (CGFloat(chrome.h) - short) / 2, width: short, height: short))
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: chrome.w, height: chrome.h))
        let img = try XCTUnwrap(out.makeImage())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("FLEX-R7M1-EVIDENCE wrote \(url.path)")
    }

    func render(mesh: ViewerMesh, tints: [Float]?, dents: [Float]?, scale: Float, bodyAlpha: Float, settle: simd_quatf, cam: Cam,
                items: [ClearanceRenderItem], layer: FlexibleLatticeLayerInputs?, n: Int) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try FlexibleRound6EvidenceProbe().renderer(mesh: mesh, tints: tints, dents: dents, scale: scale, bodyAlpha: bodyAlpha,
                                                             settle: settle, cam: cam, device: device, items: items, layer: layer)
        let bg = DS.Color.background
        return try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
    }

    /// The main page's chrome M1 touches: the icon row, the ONE legend card, the player slot and the bottom pill (in the
    /// bottom bar's slot, right of centre — the bar's other chips are #354's).
    struct MainChrome: View {
        @ObservedObject var main: FlexibleMainStage
        var body: some View {
            ZStack {
                DS.Color.background.color.ignoresSafeArea()
                FlexibleMainViewToggles(main: main, openSettings: {})
                FlexibleMainLegends(main: main, mode: .constant(.groups), projection: nil, settle: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                                    bottomClearance: 94, chipColumnWidth: 0)
                FlexibleMainPlayerSlot(main: main, bottomClearance: 94, chipColumnWidth: 0)
                VStack { Spacer(); HStack { Spacer(); FlexibleMainStatusPill(main: main, open: {}) } }
                    .padding(.horizontal, DS.Space.xl4).padding(.bottom, 24)
            }
        }
    }

    func shot(_ s: FlexibleMainStage, _ p: ProjectModel, _ name: String, cam: Cam, size: (String, CGSize), lines: inout [String]) throws {
        s.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice) ?? p.viewerMesh)
        let n = Int(min(size.1.width, size.1.height) * 2)
        let items = s.volumes(p, on: .lattice, drilledIn: false)
        let model = try render(mesh: mesh, tints: s.tints(p, on: .lattice, roles: [:], stress: nil), dents: s.dents(p, on: .lattice),
                               scale: s.dentScale(p, on: .lattice), bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: cam,
                               items: items, layer: s.layer(p, stage: .lattice, pageUp: false), n: n)
        let chrome = try hostedPixels(MainChrome(main: s), size: size.1)
        try composite(model: model, n: n, chrome: chrome, name: name)
        let depths = items.compactMap { i -> String? in
            guard case .shell(let sh) = i.volume.shape else { return nil }
            return "Face \(i.volume.faceID) \(String(format: "%.1f mm", sh.reachedDepthMM))"
        }
        lines.append("\(name): prisms [\(depths.joined(separator: ", "))] · xray \(s.xrayOn) · walls hidden \(s.layer(p, stage: .lattice, pageUp: false)?.hidden ?? true) · dents \(s.dents(p, on: .lattice) != nil) · pill '\(s.status.line)' · legend row \(s.legendPrismsRow)")
    }

    func testTheMainPageOnHisPad() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7M1_EVIDENCE_DIR") }
        var lines: [String] = []
        // ★ his pad AS SAVED: no face-prism — the plain model, the pill's one line
        do {
            let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: false)
            let p = r.project
            s.didExitSettings()
            s.apply(p, owned: true, pageUp: false)
            try await Task.sleep(nanoseconds: 500_000_000)
            await m.waitForIdle()
            XCTAssertFalse(m.facePrismsSet)
            try shot(s, p, "R7M1_no_face_prism_plain_model_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
            try shot(s, p, "R7M1_no_face_prism_plain_model_img1_11l.png", cam: Self.img1, size: Self.l11, lines: &lines)
        }
        // the RED CONTROL: the same pad, the stage as it was (no gate from the scene's first open) — his img1 words: "when no
        // face-prism has been set, the entire object becomes a lattice"
        do {
            let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: false, wholePartControl: true)
            let p = r.project
            s.didExitSettings()
            s.apply(p, owned: true, pageUp: false)
            try await FlexibleHisProject.waitFor(240, "the control's lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
            try await FlexibleHisProject.waitFor(300, "the control's sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
            for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
            try shot(s, p, "R7M1_no_face_prism_CONTROL_whole_part_lattice_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        }
        // ★ his LIVE lattice: Group C's two 25 mm face-prisms
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        let p = r.project
        s.didExitSettings()
        s.apply(p, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        try shot(s, p, "R7M1_live_lattice_nothing_picked_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.setActive(c.id)
        let list = FlexibleR7M1Fixtures.facePrisms(p, group: c.id).map { "Face \($0.faceKey) row \(String(format: "%.1f mm", p.latticeSlabDepthMM($0.ref, in: c.id)))" }
        lines.append("Group C picked — the Selections modal's rows: \(list.joined(separator: ", "))")
        try shot(s, p, "R7M1_live_lattice_groupC_picked_img1_xray_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        try shot(s, p, "R7M1_live_lattice_groupC_picked_img1_xray_11l.png", cam: Self.img1, size: Self.l11, lines: &lines)
        s.toggleXray()
        try shot(s, p, "R7M1_live_lattice_groupC_picked_img1_xray_off_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.toggleXray()
        // the RED CONTROL: round 6's squish prisms under [Prisms] (img1's 24.5 mm on Face 3 — not the list's 25.0)
        s.controlSquishPrismsOnMain = true
        m.views.insert(.prisms)
        try shot(s, p, "R7M1_live_lattice_groupC_CONTROL_squish_prisms_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        m.views.remove(.prisms)
        s.controlSquishPrismsOnMain = false
        // [Prisms]: every face-prism of the picked group, the legend row
        s.togglePrisms()
        try shot(s, p, "R7M1_live_lattice_groupC_prisms_view_img1_13p.png", cam: Self.img1, size: Self.p13, lines: &lines)
        s.togglePrisms()
        // img2: the FRONT camera, the Top picked — no prism, no 12 mm (the Top is Off in Selections)
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        p.selection.setActive(top.id)
        try shot(s, p, "R7M1_img2_front_top_picked_no_12mm_13p.png", cam: Self.img2, size: Self.p13, lines: &lines)
        s.controlSquishPrismsOnMain = true
        try shot(s, p, "R7M1_img2_front_top_picked_CONTROL_squish_prism_13p.png", cam: Self.img2, size: Self.p13, lines: &lines)
        s.controlSquishPrismsOnMain = false
        p.selection.setActive(c.id)
        try shot(s, p, "R7M1_img2_front_groupC_picked_13p.png", cam: Self.img2, size: Self.p13, lines: &lines)
        print("FLEX-R7M1-EVIDENCE main\n  " + lines.joined(separator: "\n  "))
    }

    /// The Export step: no face-prism (the stated reason, nothing sent), and an edges group beside a face group (said first).
    func testTheExportStep() async throws {
        guard Self.dir != nil else { throw XCTSkip("opt-in: FLEX_R7M1_EVIDENCE_DIR") }
        var lines: [String] = []
        func sheet(_ run: FlexibleCoreRun, _ name: String, size: (String, CGSize)) throws {
            let chrome = try hostedPixels(ZStack { DS.Color.background.color; FlexibleExportSheet(run: run, onClose: {}) }, size: size.1)
            let n = 8
            try composite(model: [UInt8](repeating: 0, count: n * n * 4), n: n, chrome: chrome, name: name)
            lines.append("\(name): line '\(run.line)' · note '\(run.hold?.note ?? "-")' · buttons \(run.hold?.fixes.map(\.title) ?? []) · runs \(run.runs)")
        }
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"), facePrism: false)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: nil, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(60, "the pad's scene") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        XCTAssertTrue(m.press(top, kg: 10))
        try await FlexibleSquishFixture.settle(m, "the pad")
        let run = stage.coreRun
        run.runner = { _, _, _, _ in FlexRunInfo(refusal: nil, receiptJSON: "{\"faces\":[{}],\"topology\":\"gyroid\"}", files: []) }
        run.send(m)
        try sheet(run, "R7M1_export_no_face_prism_stated_reason_13p.png", size: Self.p13)
        run.close()
        pm.flexibleLatticeUnder(.newGroup(face: FaceID(top), region: nil, name: "Top", depthMM: 20))
        let px = FlexibleSquishFixture.face(mesh, axis: 0, value: 100), py = FlexibleSquishFixture.face(mesh, axis: 1, value: 100)
        _ = m.addPress(regions: [px, py], direction: simd_normalize(SIMD3(-1, -1, 0)), snap: nil, group: 2, kg: 5)
        try await FlexibleHisProject.waitFor(60, "the scene") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        try await FlexibleSquishFixture.settle(m, "the pad + an edge")
        stage.refresh()
        run.send(m)
        try sheet(run, "R7M1_export_edges_beside_said_first_13p.png", size: Self.p13)
        try sheet(run, "R7M1_export_edges_beside_said_first_11l.png", size: Self.l11)
        print("FLEX-R7M1-EVIDENCE export\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
