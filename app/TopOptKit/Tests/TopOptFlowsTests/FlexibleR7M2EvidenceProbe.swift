// FlexibleR7M2EvidenceProbe — round 7 batch M2's pictures, on HIS pad (A1_0003) with HIS LIVE LATTICE (Group C = Face 3 +
// Face 5 at 25 mm), written with FLEX_M2_EVIDENCE_DIR=<dir> (skipped otherwise). NOT device screenshots: the Squish page
// HOSTED at 13" portrait (its chrome: the panel, the top line and the toast, the legend card, the view icons) composited over
// the part as the page's OWN MeshRenderer draws it offscreen (its tints, its dent, its prisms), at his img3 camera.
// FLEX_M2_SIMCOPY=<dir> (his simulator's projects, copied read-only) also prints what M2 does to each of them.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class M2EvidenceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7M2EvidenceProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_M2_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var simCopy: URL? { ProcessInfo.processInfo.environment["FLEX_M2_SIMCOPY"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { return false }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = M2EvidenceWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }

    func renderer(_ v: NSView) -> MeshRenderer? {
        if let m = v as? MTKView, let r = m.delegate as? MeshRenderer { return r }
        for s in v.subviews { if let r = renderer(s) { return r } }
        return nil
    }

    /// The page as he sees it: the page's renderer offscreen at `cam` (his img3 camera), the hosted chrome over it.
    func composite(_ h: Host, _ name: String, cam: FlexibleRound6Tests.Cam = FlexibleRound6Tests.topCam) {
        guard let dir = Self.dir else { return }
        pump(0.8)
        h.view.layoutSubtreeIfNeeded()
        // (the camera set right before the offscreen draw: a page update in between re-applies the page's own camera)
        if let mr = renderer(h.view) { mr.camera.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation) }
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        guard let page = rep.cgImage else { return }
        let W = page.width, H = page.height
        var pg = [UInt8](repeating: 0, count: W * H * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let pctx = CGContext(data: &pg, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        pctx.draw(page, in: CGRect(x: 0, y: 0, width: W, height: H))
        let bg = (pg[4 * (W + 1)], pg[4 * (W + 1) + 1], pg[4 * (W + 1) + 2])
        var out = [UInt8](repeating: 0, count: W * H * 4)
        if let mr = renderer(h.view), W <= H,
           var rgba = mr.renderOffscreen(size: H, clear: MTLClearColor(red: Double(bg.0) / 255, green: Double(bg.1) / 255, blue: Double(bg.2) / 255, alpha: 1)) {
            for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2); rgba[i + 3] = 255 }
            let x0 = (H - W) / 2
            for y in 0..<H { for x in 0..<W {
                let a = 4 * (y * H + x + x0), d = 4 * (y * W + x)
                out[d] = rgba[a]; out[d + 1] = rgba[a + 1]; out[d + 2] = rgba[a + 2]; out[d + 3] = 255
            } }
        }
        for i in stride(from: 0, to: pg.count, by: 4) {
            let isBg = abs(Int(pg[i]) - Int(bg.0)) <= 3 && abs(Int(pg[i + 1]) - Int(bg.1)) <= 3 && abs(Int(pg[i + 2]) - Int(bg.2)) <= 3
            if !isBg || out[i + 3] == 0 { out[i] = pg[i]; out[i + 1] = pg[i + 1]; out[i + 2] = pg[i + 2]; out[i + 3] = 255 }
        }
        guard let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let img = octx.makeImage() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        }
        log.append("wrote \(name)")
    }

    func settled(_ m: FlexibleStageModel, _ t: Double = 240) -> Bool {
        pumpUntil(t) { m.sceneState == .ready && m.openedKey == m.currentSceneKey
            && m.loadedKeys.allSatisfy { (m.stacks[$0] != nil && m.geometry[$0] != nil) || m.stackErrors[$0] != nil }
            && !m.readiness.designing && !m.designsInFlight }
    }

    /// His pad opened the app's way (the main page's shared model), synchronously; `live`: with his live lattice.
    func pad(live: Bool) throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        if live { try FlexibleR7M1Fixtures.hisLiveLattice(r.project) }
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(settled(m), "the scene, stacks and designs")
        pump(0.5)
        return (r, m)
    }

    func describe(_ m: FlexibleStageModel) -> String {
        let mesh = m.project.viewerMesh
        return m.settings.faces.map { f in
            let faces = m.regions.faces(of: f.faceRegionID, mesh: mesh)
            return "\(m.displayName(f.faceRegionID)) [\(f.faceRegionID), face \(faces)] \(f.role) \(String(format: "%.3f", f.weightKg)) kg"
                + (f.squeezeGroup.map { " group \($0)" } ?? "") + (f.isStampShape ? " stamp" : " curves")
        }.joined(separator: " | ")
    }

    func testEvidenceOnHisPad() throws {
        guard Self.dir != nil else { throw XCTSkip("FLEX_M2_EVIDENCE_DIR") }
        let size = CGSize(width: 1032, height: 1376)
        defer {
            if let dir = Self.dir {
                try? (log.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("r7m2_evidence_log.txt"), atomically: true, encoding: .utf8)
            }
            print("FLEX-M2-EVIDENCE\n  " + log.joined(separator: "\n  "))
        }
        // ── his live lattice: the Top and Faces 2, 4 cut into lattice sections (the carry pressed the sections)
        do {
            let (r, m) = try pad(live: true)
            let mesh = try XCTUnwrap(r.project.viewerMesh)
            log.append("live: sections " + (m.regions.flexible?.pieces ?? []).map { "\($0.wireID) \($0.region.name) (\($0.key))" }.joined(separator: " · "))
            log.append("live: faces " + describe(m))
            log.append("live: toast after the open '\(m.toast ?? "")'")
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            composite(h, "R7M2_13p_01_img3_lattice_sections_middle_solid.png")
            // the Top's Face 3 section picked: its curves span 25 mm, its prism and dent there only
            let b = mesh.bounds
            func top(_ x: Double) -> SIMD3<Double> { SIMD3(Double(b.min.x) + x, Double(b.min.y + b.max.y) / 2, Double(b.max.z)) }
            m.tapFace(1, point: top(Double(b.max.x - b.min.x) - 10))
            pump(0.4)
            if let g = m.squeezeGroup(of: m.selectedRegion ?? -1) { m.rail = .group(g.id) }
            m.views = [.prisms]
            XCTAssertTrue(settled(m))
            pump(1.0)
            let sec = m.selectedRegion ?? -1
            let k = m.key(sec)
            let bx = k.flatMap { m.geometry[$0] }.map { g in zip(g.baselineX.points, g.baselineX.points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
            let by = k.flatMap { m.geometry[$0] }.map { g in zip(g.baselineY.points, g.baselineY.points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
            log.append(String(format: "picked %d (%@): curve baselines %.2f × %.2f mm · prism columns %d of %d", sec, m.displayName(sec),
                              bx ?? 0, by ?? 0, m.prismColumns(sec)?.count ?? -1, k.flatMap { m.stacks[$0]?.columns.count } ?? -1))
            composite(h, "R7M2_13p_02_face3_section_picked_curves_25mm_prisms.png")
            m.views = []
            pump(0.5)
            // the Group 1 tab: the Top's two lattice sections, half the Top's weight each
            composite(h, "R7M2_13p_03_group1_two_sections_half_each.png")
            log.append("group 1: " + (m.squeezeGroups.first.map { g in g.regions.map { "\(m.displayName($0)) \(String(format: "%.3f", m.settings.face($0)?.weightKg ?? 0)) kg" }.joined(separator: ", ") } ?? ""))
            // a tap on the solid middle: the line and its one fix
            m.tapFace(1, point: top(Double(b.max.x - b.min.x) / 2))
            pump(0.8)
            composite(h, "R7M2_13p_04_solid_tap_line_and_go_to_lattice.png")
            log.append("solid tap: toast '\(m.toast ?? "")' fix \(m.toastFix.map(\.rawValue) ?? "none") · selected \(m.selectedRegion.map(String.init) ?? "none")")
            // violet where a tap works: Face 2's bands (the FRONT face at his img2 camera) unpressed — an edit, not the trash
            // (the trash is an action: its new blocker would pop up over the part)
            let f2 = m.settings.faces.map(\.faceRegionID).filter { m.regions.faces(of: $0, mesh: mesh) == [2] }
            m.edit { s in for id in f2 { s.removeFace(id) }; FlexibleSqueezeGroups.normalise(&s) }
            m.selectedRegion = nil
            XCTAssertTrue(settled(m))
            pump(1.0)
            composite(h, "R7M2_13p_05_violet_where_a_tap_works_face2_unpressed.png", cam: FlexibleRound6Tests.iso)
            log.append("violet: Face 2's bands \(f2) unpressed (the same page: its map rebuilt)")
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // ── Edge 14 nested inside Face 2's band
        do {
            let (r, m) = try pad(live: true)
            m.rail = .newGroup
            m.startEdgePick()
            XCTAssertTrue(pumpUntil(240) { m.edgePick.map { !$0.loading && !$0.checking } ?? false })
            let mesh = try XCTUnwrap(r.project.viewerMesh)
            let c = try XCTUnwrap(m.edgePick?.candidates.first { c in
                c.kind == .edge && Set(c.members.flatMap { m.regions.faces(of: $0, mesh: mesh) }) == [2, 3] })
            m.toggleEdgePick(c.number)
            m.setEdgePickWeight(2)
            var done = false, why: String?
            Task { @MainActor in why = await m.finishEdgePick(); done = true }
            XCTAssertTrue(pumpUntil(240) { done } && settled(m))
            XCTAssertNil(why)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            composite(h, "R7M2_13p_06_edge14_nested_in_face2s_band.png", cam: FlexibleRound6Tests.iso)
            log.append("edge 14: press \(m.presses.first { $0.strip != nil }?.regions ?? []) · pieces " + (m.regions.flexible?.pieces ?? []).filter { $0.kind != .section }.map { "\($0.wireID) \($0.kind) \($0.region.name)" }.joined(separator: " · "))
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // ── a depth change keeps the section and its curves
        do {
            let (r, m) = try pad(live: true)
            let mesh = try XCTUnwrap(r.project.viewerMesh)
            let b = mesh.bounds
            m.tapFace(1, point: SIMD3(Double(b.max.x) - 5, Double(b.min.y + b.max.y) / 2, Double(b.max.z)))
            let sec = try XCTUnwrap(m.selectedRegion)
            m.edit { s in guard var f = s.face(sec) else { return }; f.shape = "curves"; f.curveX = FlexCurve(x: [0, 0.3, 1], y: [0.2, 0.9, 0.4]); f.deepestMM = 6; s.setFace(f) }
            if let g = m.squeezeGroup(of: sec) { m.rail = .group(g.id) }
            let c = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Group C" })
            r.project.writeLatticeDepthMM(.face(group: c.id, face: 3), mm: 17.26)
            m.openScene()
            XCTAssertTrue(settled(m))
            m.tapFace(1, point: SIMD3(Double(b.max.x) - 5, Double(b.min.y + b.max.y) / 2, Double(b.max.z)))
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            composite(h, "R7M2_13p_07_face3_at_17mm_same_section_curves_kept.png")
            log.append(String(format: "depth 25 → 17.26: section %d → %d · curve kept %@ · area %.1f mm²", sec, m.selectedRegion ?? -1,
                              m.settings.face(sec)?.curveX == FlexCurve(x: [0, 0.3, 1], y: [0.2, 0.9, 0.4]) ? "yes" : "no",
                              FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: 1, mesh: mesh), m.regions.cuts(of: sec))))
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // ── RED CONTROL: today's whole Face 1 — its curves run 100 mm across the model
        do {
            FlexibleLatticeSections.controlWholeFace = true
            defer { FlexibleLatticeSections.controlWholeFace = false }
            let (r, m) = try pad(live: true)
            m.select(1)
            if let g = m.squeezeGroup(of: 1) { m.rail = .group(g.id) }
            m.setShape(1, "curves")
            XCTAssertTrue(settled(m))
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            composite(h, "R7M2_13p_08_CONTROL_whole_face1_curves_100mm.png")
            log.append("control: Face 1 whole — " + describe(m))
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // ── his pad as saved (no face-prism): the page unchanged by M2
        do {
            let (r, m) = try pad(live: false)
            let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: size)
            pump(2.5)
            composite(h, "R7M2_13p_09_no_face_prism_unchanged.png")
            log.append("no face-prism: sections \(m.sectorSet.pieces.count) · top line '\(m.readiness.oneLine)'")
            h.window.orderOut(nil); h.window.contentView = nil
        }
        // ── his simulator's projects (a read-only copy): what M2 moves and cuts in each
        if let sim = Self.simCopy, let dirs = try? FileManager.default.contentsOfDirectory(at: sim, includingPropertiesForKeys: nil) {
            for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard FileManager.default.fileExists(atPath: d.appendingPathComponent("project.json").path) else { continue }
                do {
                    let r = try FlexibleHisProject.restore(d, asSaved: true)
                    addTeardownBlock { r.cleanup() }
                    guard r.project.lattice.flexible != nil else { log.append("sim \(d.lastPathComponent) '\(r.project.name)': not a Flexible project"); continue }
                    let legacy = FlexibleSectorMigration.isLegacy(r.project.lattice.flexible!)
                    let stage = FlexibleMainStage()
                    stage.reduceMotion = { true }
                    let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
                    addTeardownBlock { @MainActor in await m.waitForIdle() }
                    pump(0.3)
                    m.openScene()
                    _ = settled(m)
                    log.append("sim \(d.lastPathComponent) '\(r.project.name)': I2 strips to move: \(legacy ? "yes" : "none")"
                               + (m.migrationReport.map { " · Report: " + FlexibleSectorMigration.lines($0).joined(separator: "; ") } ?? ""))
                    log.append("  sections: " + (m.regions.flexible?.pieces ?? []).map { "\($0.wireID) \($0.region.name)" }.joined(separator: " · "))
                    log.append("  faces after the open: " + describe(m))
                } catch {
                    log.append("sim \(d.lastPathComponent): \(error)")
                }
            }
        }
    }
}
#endif
