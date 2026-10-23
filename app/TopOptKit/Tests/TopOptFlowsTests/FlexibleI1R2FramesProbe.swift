// FlexibleI1R2FramesProbe — round 7 · U21 batch I, part I1: the R2 FRAMES for his morning decision (NOT shipped).
//   His decision of 2026-10-22 ~02:50: "The Rest-gripping change (R2: a Rest bonded; far anvil removed for rest groups) waits:
//   render his pad's unbalanced groups under that rule beside today's and send the frames to him + the reviewer in the morning
//   for a separate yes/no." The reviewer's R2 (06:38): provisional, frames first.
// R2 is behind a TEST-ONLY switch: the solver's existing control bits 2048 (every Rest bonded) | 32768 (no far anvil) — the
// rule for an UNBALANCED group (a balanced one would keep its non-anvil Rests sliding); nothing of it is in the app.
// His live pad of 10-21 (Rests on the bottom sections), the Squish page at 13" portrait, Play held at FULL load at ×1, the SAME
// camera for every frame (v2: from the side, raised, the panel collapsed; + his l-bracket links on/off from behind), refines off (the quick linear field in both, apples to apples). Frames only with FLEX_I1_DIR=<dir>.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class I1Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleI1R2FramesProbe: XCTestCase {
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_I1_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    func testR2FramesOnHisPad() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_I1_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        let strips = m.presses.filter { $0.strip != nil }
        pumpUntil(240) { strips.allSatisfy { m.pressKey($0.id) != nil } }
        pumpUntil(60) { !m.readiness.designing }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice")
        let groups = m.squeezeGroups
        log.append("his pad: groups \(groups.map { "\(m.groupName($0)) \($0.kind) regions \($0.regions) presses \($0.presses.count)" }) · rests \(m.holdResting)")
        func solveAll(_ what: String) throws {
            let ids = groups.map { FlexibleSim.groupID($0.number) }
            for id in ids { m.startSquishSims(first: id) }
            XCTAssertTrue(pumpUntil(600) { ids.allSatisfy { m.squish[$0] != nil && m.squish[$0] != .pending } }, "\(what): the sims")
            for g in groups {
                let id = FlexibleSim.groupID(g.number)
                if let f = m.squish[id]?.field {
                    log.append(String(format: "%@ %@: bc %@ · k %.3f (asked %.3f%@) · fold share %@ · s·gmax(part) %.3f · max|u| %.2f mm · line '%@'",
                                      what, m.groupName(g), f.bcMode, f.scale, f.coreRatio, f.clamped ? ", clamped" : "",
                                      f.foldShare.map { String(format: "%.3f", $0) } ?? "none", f.gmaxPart, f.maxDisplacement, m.holdLine(g)))
                } else { log.append("\(what) \(m.groupName(g)): \(m.squish[id]?.failure ?? "no sim")") }
            }
        }
        try solveAll("TODAY")
        // which groups are unbalanced (the bridge's own receipt)
        if let req = m.lastFERequest, let scene = waitScene(m) {
            for sim in req.sims {
                let q = try scene.squishSolve(req.request(sim))
                log.append(String(format: "balance %@: |Σf| %.2f of Σ|f| %.2f N (%.1f %%) · far anvils %d", sim.id, simd_length(q.appliedForceN),
                                  q.appliedForceAbsN, 100 * simd_length(q.appliedForceN) / max(q.appliedForceAbsN, 1e-9), q.farAnvils))
            }
            // the edges group's presses, each alone as its sim solves them (today vs R2's bits)
            if let base = m.feBase {
                for w in m.pressSimWants {
                    for (i, p) in w.presses.enumerated() {
                        let one = FlexibleFERequest.pressSim(id: w.sim.id, presses: [p], voxels: base.rho.count)
                        let a = try scene.squishSolve(base.request(one))
                        let b = try scene.squishSolve(base.request(one, control: FlexibleFE.bondedRests | 32768))
                        log.append(String(format: "%@ press %d: today bc %@ · far anvils %d · free modes %d · held nodes %d · |Σf| %.1f of %.1f N · R2 free modes %d · held nodes %d · fields identical %@",
                                          w.sim.id, i + 1, a.bcMode, a.farAnvils, a.freeModes, a.heldNodes.count, simd_length(a.appliedForceN), a.appliedForceAbsN,
                                          b.freeModes, b.heldNodes.count, "\(a.u == b.u)"))
                    }
                }
            }
        }
        let loop = FlexibleSquishLoop()
        m.views.insert(.play)
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        // ★ v2 (the first frames were unreadable: the camera below the part, the panel over half of it): ONE camera for both
        // frames, from the SIDE at a raised angle (across the Face 5 ↔ Face 3 pinch, a little toward Face 5, the thumb), the
        // Squish panel collapsed to its header line
        try collapsePanel(h)
        var cam: OrbitCamera?
        if let cm = cameraModel(h), let mesh = r.project.viewerMesh, let n5 = mesh.faceNormal(5) {
            var c = cm.camera
            let eye = sideEye(n5, toward: 0.45, side: 0.8, up: 0.6)
            log.append(String(format: "v2 camera: Face 5 normal (%.2f %.2f %.2f) · eye (%.2f %.2f %.2f)", n5.x, n5.y, n5.z, eye.x, eye.y, eye.z))
            let ae = OrbitCamera.azimuthElevation(forDirection: eye, currentAzimuth: c.azimuth)
            c.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
            c.distance *= 1.25
            cm.adopt(c)
            cam = c
        }
        func frame(_ g: FlexibleSqueezeGroup, _ name: String) throws {
            m.rail = .group(g.id)
            if g.kind == .edges { m.selectedPress = g.presses.first } else if let r0 = g.regions.first { m.select(r0) }
            pump(1.5)   // (a pick may move the camera: the one camera is put back after it settles)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c) }
            loop.exaggeration = 1
            loop.hold(1)
            pump(0.5)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c); log.append("\(name): camera az \(cm.camera.azimuth) el \(cm.camera.elevation) d \(cm.camera.distance)") }
            log.append("\(name): playing \(m.playingGroup.map { m.groupName($0) } ?? "-") · ×\(loop.exaggeration) · held \(loop.held) · panel collapsed \(h.frames.all["panelScroll"] == nil)")
            try shot(name, h, settle: 2.5)
        }
        let faceGroup = groups.first { $0.kind == .faces }
        // ★ v2: only Group 1 (Group 2 is byte-identical under both rules — its lines above say so)
        if let g = faceGroup { try frame(g, "I1_R2_01_13p_\(slug(m.groupName(g)))_TODAY_v2.png") }
        // ★ the R2 rule (NOT shipped): every Rest bonded, the far anvil removed — the same lattice, the sims solved again
        m.squishSolver.controlBits = FlexibleFE.bondedRests | 32768
        m.latticeLanded(m.lastFERequest)
        try solveAll("R2")
        if let g = faceGroup { try frame(g, "I1_R2_02_13p_\(slug(m.groupName(g)))_R2_v2.png") }
        m.squishSolver.controlBits = 0
        flush("I1_R2_lines_v2.txt")
    }

    // ★ ROUND 7 · MANUAL follow-up (renders MF_02, MF_03, with FLEX_I1_DIR + FLEX_MF): his pad's Squish page — a group card with
    // its own density in Manual ("Type and cell follow the part"); and a link added to his rest group, Play ×1 at full load (links
    // and Rests both hold — his answer of 2026-10-22 ~16:10, "All hold").
    func testManualFollowUpFramesOnHisPad() throws {
        guard Self.dir != nil, ProcessInfo.processInfo.environment["FLEX_MF"] != nil else { throw XCTSkip("frames only with FLEX_I1_DIR + FLEX_MF") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.padDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        let strips = m.presses.filter { $0.strip != nil }
        pumpUntil(240) { strips.allSatisfy { m.pressKey($0.id) != nil } }
        pumpUntil(60) { !m.readiness.designing }
        // his link: Face 5's lattice floor → the solid under it (FlexibleI3LinkSimTests 3/4), in Auto (his rest group)
        let key5 = LatticeSelectableRef.face(group: FlexibleI2AttachTests.groupC, face: 5).key
        XCTAssertTrue(FlexibleFaceCommits.addLink(lattice: key5, wall: "floor", target: "under", project: r.project))
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice")
        let groups = m.squeezeGroups
        let g = try XCTUnwrap(groups.first { $0.kind == .faces })
        let id = FlexibleSim.groupID(g.number)
        for x in groups { m.startSquishSims(first: FlexibleSim.groupID(x.number)) }
        XCTAssertTrue(pumpUntil(600) { m.squish[id] != nil && m.squish[id] != .pending }, "the sim")
        if let f = m.squish[id]?.field {
            log.append(String(format: "%@: bc %@ · walls held %@ · exits held %@ · max|u| %.2f mm · line '%@' · rests %@",
                              m.groupName(g), f.bcMode, "\(f.wallNodes)", "\(f.exitsHeld)", f.maxDisplacement, m.holdLine(g), "\(m.holdResting)"))
        }
        let loop = FlexibleSquishLoop()
        m.views = [.play]
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(g.id)
        if let r0 = g.regions.first { m.select(r0) }
        pump(1.5)
        loop.exaggeration = 1
        loop.hold(1)
        pump(0.5)
        log.append("MF_03: playing \(m.playingGroup.map { m.groupName($0) } ?? "-") · ×\(loop.exaggeration) · held \(loop.held)")
        try shot("MF_03_13p_pad_link_plus_rests_play_full.png", h, settle: 2.5)

        // a group card with its own density, in Manual
        m.views = [.heatOff]
        m.setManual(true)
        m.rail = .group(g.id)
        m.setGroupOwnLattice(g.id, own: true)
        m.setManualDensity(0.30, group: g.id)
        pump(1.5)
        let own = try XCTUnwrap(m.manualLattice(group: g.id))
        log.append(String(format: "MF_02 %@ own: %@ · cell %.2f mm · density %.3f · walls %.3f beads · rows %@", m.groupName(g), own.topology, own.cellMM,
                          own.density, m.manualWalls(group: g.id) ?? -1, "\(FlexibleManualLatticeRows.rows(group: g.id))"))
        try shot("MF_02_13p_pad_MANUAL_group_own_density.png", h, settle: 1.5)
        flush("MF_lines.txt")
    }

    // ★ v2: HIS l-bracket, the 4 border walls linked vs not (FlexibleI3FramesProbe's scene), seen from the side, a little below
    // and behind, so Face 2's (the plate's underside) bow reads in silhouette; the panel collapsed; Play ×1 at full load; the same camera for both
    func testLBracketLinksFromBehind() throws {
        guard Self.dir != nil else { throw XCTSkip("frames only with FLEX_I1_DIR") }
        let r = try FlexibleHisProject.restore(FlexibleU21DeleteUndoTests.lbracketDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.keepFERequest = true
        m.squishSolver.controlNoRefine = true
        m.openScene()
        XCTAssertTrue(pumpUntil(180) { m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil } }, "scene")
        pumpUntil(60) { !m.readiness.designing }
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        XCTAssertTrue(pumpUntil(400) { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }, "lattice")
        let g = try XCTUnwrap(m.squeezeGroups.first)
        let id = FlexibleSim.groupID(g.number)
        func solved(_ what: String) {
            m.startSquishSims(first: id)
            XCTAssertTrue(pumpUntil(600) { m.squish[id] != nil && m.squish[id] != .pending }, "\(what): the sim")
            if let f = m.squish[id]?.field {
                let face6 = f.sample(SIMD3<Float>(75, 0, 87.5)).x, face2 = f.sample(SIMD3<Float>(100, 0, 87.5)).x
                log.append(String(format: "%@: bc %@ · k %.3f · shown u_x Face 6 %.2f mm · Face 2 %.2f mm · max|u| %.2f mm · line '%@'",
                                  what, f.bcMode, f.scale, face6, face2, f.maxDisplacement, m.holdLine(g)))
            } else { log.append("\(what): \(m.squish[id]?.failure ?? "no sim")") }
        }
        solved("NO LINK (as saved)")
        let loop = FlexibleSquishLoop()
        m.views.insert(.play)
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        try collapsePanel(h)
        var cam: OrbitCamera?
        // Face 6 is the latticed plate's TOP and Face 2 its UNDERSIDE (the sim's x is the plate's thickness: Face 6 at x 75, Face 2
        // at x 100; on screen the plate lies flat, the upright at the back, the plate running to the front). A first try from
        // behind and above hid the underside; so: from the RIGHT, a little BELOW and a little from BEHIND (the screen's world,
        // y up), the plate's bottom edge in silhouette — where Face 2's bow shows
        if let cm = cameraModel(h) {
            var c = cm.camera
            let eye = simd_normalize(SIMD3<Float>(1, -0.22, -0.3))
            log.append(String(format: "v2 camera: eye (%.2f %.2f %.2f) · from the right, a little below and behind", eye.x, eye.y, eye.z))
            let ae = OrbitCamera.azimuthElevation(forDirection: eye, currentAzimuth: c.azimuth)
            c.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
            c.distance *= 1.3
            cm.adopt(c)
            cam = c
        }
        func frame(_ name: String) throws {
            m.rail = .group(g.id)
            if let r0 = g.regions.first { m.select(r0) }
            pump(1.5)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c) }
            loop.exaggeration = 1
            loop.hold(1)
            pump(0.5)
            if let c = cam, let cm = cameraModel(h) { cm.adopt(c) }
            log.append("\(name): playing \(m.playingGroup.map { m.groupName($0) } ?? "-") · ×\(loop.exaggeration) · held \(loop.held) · line '\(m.holdLine(g))' · panel collapsed \(h.frames.all["panelScroll"] == nil)")
            try shot(name, h, settle: 2.5)
        }
        try frame("I1_R2_05_13p_lbracket_NO_LINK_behind_v2.png")
        let w = try XCTUnwrap(FlexibleLatticeWalls.walls(project: r.project, key: LatticeSelectableRef.face(group: FlexibleI2AttachTests.groupB, face: 6).key))
        FlexibleFaceCommits.addSuggested(lattice: w.key, sides: try XCTUnwrap(w.suggestion(linked: [])), project: r.project)
        m.relinkIfNeeded()
        solved("4 LINKED WALLS")
        try frame("I1_R2_06_13p_lbracket_4_LINKED_behind_v2.png")
        flush("I1_R2_lbracket_lines_v2.txt")
    }

    /// An eye direction (y up) `toward` along the face normal `n`, `side` across it (horizontal), `up` above.
    func sideEye(_ n: SIMD3<Float>, toward: Float, side: Float, up: Float) -> SIMD3<Float> {
        let y = SIMD3<Float>(0, 1, 0)
        var a = n - simd_dot(n, y) * y
        if simd_length(a) < 0.3 { a = SIMD3<Float>(1, 0, 0) }   // a top/bottom face: its "side" is any horizontal
        a = simd_normalize(a)
        let t = simd_normalize(simd_cross(y, a))
        return simd_normalize(toward * a + side * t + up * y)
    }

    /// The Squish panel folded to its header line: a click on its chevron (just right of [Reset all]); asserted folded.
    func collapsePanel(_ h: Host) throws {
        let reset = try XCTUnwrap(h.frames.all["resetAll"], "the panel's [Reset all]")
        XCTAssertNotNil(h.frames.all["panelScroll"], "premise: the panel open")
        click(h, CGPoint(x: reset.maxX + 28, y: reset.midY))
        pump(1.0)
        XCTAssertNil(h.frames.all["panelScroll"], "★ the panel collapsed")
    }
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    func slug(_ s: String) -> String { s.lowercased().replacingOccurrences(of: " ", with: "") }
    func waitScene(_ m: FlexibleStageModel) -> FlexibleScene? {
        var out: FlexibleScene?
        var done = false
        Task { @MainActor in out = await m.squishWorker.sceneRef(); done = true }
        pumpUntil(30) { done }
        return out
    }

    // MARK: the harness (FlexibleR7U21CHandlesHostedTests', from FlexibleU1Tests)

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = I1Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func stageMTK(_ h: Host) -> MTKView? {
        mtkViews(h.view).filter { $0.delegate is MeshRenderer }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    func cameraModel(_ h: Host) -> OrbitCameraModel? {
        guard let mtk = stageMTK(h) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }
    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func flush(_ file: String) {
        print("FLEX-I1R2 " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    /// The page as he sees it: its renderer offscreen (its camera, its viewport) under the hosted chrome (FlexibleU1Tests.shot).
    func shot(_ name: String, _ h: Host, settle: Double = 0.8) throws {
        pump(settle)
        guard Self.dir != nil else { return }
        let hv = h.view
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let PW = cg.width, PH = cg.height
        let scale = CGFloat(PW) / h.size.width
        var chrome = [UInt8](repeating: 0, count: PW * PH * 4)
        let cctx0 = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cctx0.draw(cg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        let bg = DS.Color.background
        let gr = Int((bg.r * 255).rounded()), gg = Int((bg.g * 255).rounded()), gb = Int((bg.b * 255).rounded())
        var probe = (0, 0, 0, 0)
        var modelImg: CGImage?
        var placed = CGRect.zero
        if let mtk = stageMTK(h), let r = mtk.delegate as? MeshRenderer {
            var vf = mtk.convert(mtk.bounds, to: hv)
            if !hv.isFlipped { vf.origin.y = hv.bounds.height - vf.maxY }
            let cx = Int(vf.midX * scale), cy = Int(vf.midY * scale)
            let i = (cy * PW + cx) * 4
            probe = (Int(chrome[i]), Int(chrome[i + 1]), Int(chrome[i + 2]), Int(chrome[i + 3]))
            if probe.0 + probe.1 + probe.2 > 60 { probe = (0, 0, 0, 0) }
            let saved = r.camera
            var cam = saved
            let W = vf.width, H = vf.height
            let side: CGFloat
            if W > H { cam.fovY = 2 * atan(tan(saved.fovY / 2) * Float(W / H)); side = W } else { side = H }
            r.camera = cam
            let n = Int((side * scale).rounded())
            let px = r.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
            r.camera = saved
            if var m = px {
                for k in stride(from: 0, to: m.count, by: 4) { m.swapAt(k, k + 2); m[k + 3] = 255 }
                let mctx = try XCTUnwrap(CGContext(data: &m, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                modelImg = mctx.makeImage()
                placed = CGRect(x: (vf.midX - side / 2) * scale, y: (h.size.height - vf.midY - side / 2) * scale, width: side * scale, height: side * scale)
            }
        }
        for k in stride(from: 0, to: chrome.count, by: 4) {
            let a = chrome[k + 3]
            let isBG = abs(Int(chrome[k]) - gr) <= 3 && abs(Int(chrome[k + 1]) - gg) <= 3 && abs(Int(chrome[k + 2]) - gb) <= 3 && a == 255
            let isProbe = probe.3 > 0 && abs(Int(chrome[k]) - probe.0) <= 2 && abs(Int(chrome[k + 1]) - probe.1) <= 2 && abs(Int(chrome[k + 2]) - probe.2) <= 2 && Int(a) == probe.3
            if isBG || isProbe { chrome[k] = 0; chrome[k + 1] = 0; chrome[k + 2] = 0; chrome[k + 3] = 0 }
        }
        let cctx = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: PW, height: PH))
        if let mi = modelImg { out.draw(mi, in: placed) }
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        try writePNG(try XCTUnwrap(out.makeImage()), name)
    }
}
#endif
