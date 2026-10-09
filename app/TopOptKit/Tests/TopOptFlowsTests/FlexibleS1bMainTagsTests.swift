// FlexibleS1bMainTagsTests — the S1b verification of round 6 item 3's MAIN page (task 2026-09-29-flexible-screens;
// the verifier's findings of 2026-10-09 on the main page's faint prisms and read-only mm tags). Written BEFORE the fix,
// each with its red run; on HIS projects (A1_0003 — his img1–img4 — and his round-5 pad), at HIS layout (iPad Pro 13"
// portrait, 1032 × 1376 pt, the status bar's 24 pt and the home indicator's 20 pt of safe area, his img4's chrome).
//   S1bV-1  every main-page tag is JOINED TO ITS FACE: a leader from the tag along the prism's axis to the face, drawn
//           over the part (his img3's red line) — in his everyday Lattice view the faint prism itself cannot be seen;
//   S1bV-2  [Prisms] shows EVERY number at his 13" portrait (5 of 5 on A1_0003, 4 of 4 on r5; it showed 3 and 1): the
//           greedy pass reads the tag AS DRAWN (not Settings' 84 × 44 tap target), and a tag whose floor is hidden slides
//           along its prism's axis toward its face; never over his chrome, over many cameras (the verifier's hunt);
//   S1bV-3  under [Prisms], picking a group BRIGHTENS its prisms and places its tags first (spec §2: "the selected one
//           brighter");
//   S1bV-4  the tags keep out of the chrome WHERE IT IS DRAWN (the safe area), not where the full-screen MTKView would
//           put it (24 pt off at the top, 20 at the bottom).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class S1bTagsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleS1bMainTagsTests: XCTestCase {

    // MARK: - his layout (iPad Pro 13" portrait; the verifier's measurements of his img4)

    nonisolated static let vp = CGSize(width: 1032, height: 1376)
    nonisolated static let safeTop: CGFloat = 24, safeBottom: CGFloat = 20
    /// The chrome's frame in the MTKView's space (WorkspacePlaceholder lays the chrome out in the safe area).
    nonisolated static var chrome: CGRect { CGRect(x: 0, y: safeTop, width: vp.width, height: vp.height - safeTop - safeBottom) }
    static let bottomClearance: CGFloat = 78, chipColumnWidth: CGFloat = 222
    /// #354's chrome as drawn on HIS img4 (points, the MTKView's space): what no tag may cover.
    static let hisChrome: [String: CGRect] = [
        "topbar": CGRect(x: 13.8, y: 48.2, width: 798.1, height: 99.8),
        "gizmo": CGRect(x: 817.3, y: 53.7, width: 194.0, height: 195.4),
        "selections": CGRect(x: 20.6, y: 558.7, width: 354.3, height: 428.6),
        "chips": CGRect(x: 782.9, y: 1097.4, width: 228.4, height: 174.1),
        "bottombar": CGRect(x: 196.1, y: 1274.2, width: 815.3, height: 61.9),
    ]

    // MARK: - helpers

    final class Marks { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let marks: Marks }

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
        let marks = Marks()
        let root = AnyView(v.onPreferenceChange(FlexibleViewMarksKey.self) { marks.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = S1bTagsWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, marks: marks)
    }

    /// A model over `project` (the main stage's own), its scene, stacks and designs settled (no lattice).
    func settled(_ project: ProjectModel, _ stage: FlexibleMainStage) -> FlexibleStageModel {
        stage.reduceMotion = { true }
        let m = stage.model(for: project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        XCTAssertTrue(pumpUntil(180) {
            m.sceneState == .ready && m.loadedKeys.allSatisfy { m.stacks[$0] != nil && m.geometry[$0] != nil }
                && !m.readiness.designing && !m.designsInFlight
        }, "the scene, stacks and designs")
        pump(0.3)
        return m
    }

    /// His project through Save & Exit, until the lattice and every group's sim have landed (R6-1a's route): the
    /// main page as he sees it — the card with its scales, the squish player.
    func mainPage(_ label: String, _ r: FlexibleHisProject.Restored) async throws -> (FlexibleMainStage, FlexibleStageModel) {
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath,
                            stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, label)
        stage.didExitSettings()
        stage.apply(r.project, owned: true, pageUp: false)
        let start = Date()
        while Date().timeIntervalSince(start) < 600 {
            if m.lattice != nil, !m.latticeBuilding, !m.squish.isEmpty, !m.squish.values.contains(.pending), m.squishSolver.isIdle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(m.lattice, "\(label): the lattice built")
        stage.refresh()
        return (stage, m)
    }

    /// His camera (img1: azimuth π/4, elevation 0.62) on the main page's drawn mesh, the renderer's own framing.
    @MainActor final class Camera {
        let mr: MeshRenderer
        let baseDistance: Float
        let settle: simd_quatf
        init(_ stage: FlexibleMainStage, _ project: ProjectModel) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
            mr.setMesh(try XCTUnwrap(stage.mesh(project, on: .lattice) ?? project.viewerMesh))
            settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
            mr.beginSettle(to: settle, duration: 0)
            baseDistance = mr.camera.distance
        }
        func projection(az: Float = .pi / 4, el: Float = 0.62, zoom: Float = 1, size: CGSize = FlexibleS1bMainTagsTests.vp) -> CameraProjection {
            mr.camera.setOrientation(azimuth: az, elevation: el)
            mr.camera.distance = baseDistance * zoom
            return CameraProjection(camera: mr.camera, viewportSize: size)
        }
    }

    /// The tags the main page draws at his layout, through the camera `proj`.
    func tags(_ stage: FlexibleMainStage, _ project: ProjectModel, _ proj: CameraProjection, settle: simd_quatf,
              chrome: CGRect? = FlexibleS1bMainTagsTests.chrome) -> [FlexibleStageViewTags.Tag] {
        stage.noteView(projection: proj, settle: settle)
        return FlexibleMainPrismTagsLayer.tags(main: stage, project: project, view: stage.viewFrame, drilledIn: false,
                                               bottomClearance: Self.bottomClearance, chipColumnWidth: Self.chipColumnWidth, chrome: chrome)
    }

    /// The Flexible chrome AS DRAWN at his layout (laid out in the safe area, then put on screen): the four view buttons,
    /// the nav column and gizmo, the bottom bar, the left panel strip, the chip column, the ONE card and the player.
    func drawnFlexibleChrome(_ stage: FlexibleMainStage) -> [String: CGRect] {
        let s = Self.chrome
        func screen(_ r: CGRect) -> CGRect { r.offsetBy(dx: s.minX, dy: s.minY) }
        var out: [String: CGRect] = ["buttons": screen(FlexibleMainViewToggles.rowFrame(viewport: s.size)),
                                     "leftStrip": screen(FlexibleMainLegendLayout.leftStrip(viewport: s.size))]
        if let c = stage.legendCard(viewport: s.size, bottomClearance: Self.bottomClearance, chipColumnWidth: Self.chipColumnWidth) {
            out["card"] = screen(c.frame)
        }
        if let p = FlexibleMainPlayerSlot.frame(main: stage, viewport: s.size, bottomClearance: Self.bottomClearance,
                                                chipColumnWidth: Self.chipColumnWidth) { out["player"] = screen(p) }
        return out
    }

    /// The distance (pt) from `p` to the line through `a` and `b`.
    static func offLine(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-6 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / len
    }

    // MARK: - S1bV-1 — every tag is joined to its face

    /// ★ HIS IMG3'S RED LINE, ON THE MAIN PAGE: the tag sits at the prism's FLOOR, inside the part, and a side face's floor
    /// lands over the top face; in his Lattice view the faint prism cannot be seen. So the tag carries a LEADER along the
    /// prism's axis to its FACE (the prism's base centre), drawn over the part — always visible. RED before: no face, no
    /// leader.
    func testEveryMainPageTagIsJoinedToItsFace() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        let m = settled(r.project, stage)
        let cam = try Camera(stage, r.project)
        let proj = cam.projection()
        var lines: [String] = []
        for (name, want) in [("Group C", 3), ("Top", 1)] {
            let g = try XCTUnwrap(r.project.selection.groups.first { $0.name == name }, "his group \(name)")
            r.project.selection.setActive(g.id)
            let item = try XCTUnwrap(stage.volumes(r.project, on: .lattice, drilledIn: false).first, "\(name): its prism")
            let h = try XCTUnwrap(FlexibleDepthPrism.handle(item.volume))
            let t = try XCTUnwrap(tags(stage, r.project, proj, settle: cam.settle).first, "\(name): its tag")
            XCTAssertEqual(t.region, want)
            let view = try XCTUnwrap(stage.viewFrame)
            let face = try XCTUnwrap(view.project(h.planeOrigin))
            let floor = try XCTUnwrap(view.project(h.anchor))
            XCTAssertEqual(t.point.x, floor.x, accuracy: 1e-3, "\(name): the tag at its prism's floor")
            XCTAssertEqual(t.point.y, floor.y, accuracy: 1e-3)
            let f = try XCTUnwrap(t.face, "\(name): the tag knows its face")
            XCTAssertEqual(f.x, face.x, accuracy: 1e-3, "\(name): the face end is the prism's base centre")
            XCTAssertEqual(f.y, face.y, accuracy: 1e-3)
            let end = try XCTUnwrap(t.leaderEnd, "\(name): a leader is drawn")
            XCTAssertEqual(end.x, face.x, accuracy: 1e-3, "\(name): nothing hides it: the leader reaches the face")
            XCTAssertEqual(end.y, face.y, accuracy: 1e-3)
            XCTAssertGreaterThan(hypot(face.x - floor.x, face.y - floor.y), FlexibleStageViewTags.mainSize.height,
                                 "\(name): premise — the floor lands away from its face (his img3)")
            // the facing test is the hidden-line convention's (a face that turns away: dashed)
            let dir = try XCTUnwrap(view.viewDirection(at: h.planeOrigin))
            XCTAssertEqual(t.away, simd_dot(dir, -h.planeNormal) > FlexibleStageViewTags.awayDot, "\(name): away")
            lines.append("\(name) face \(t.region) \(t.text) tag \(t.point) → face \(f) away \(t.away)")
        }
        // hosted: the leader is ON the page, from the tag to the face
        let g = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Group C" })
        r.project.selection.setActive(g.id)
        let h = host(FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: proj, settle: cam.settle,
                                         bottomClearance: Self.bottomClearance, chipColumnWidth: Self.chipColumnWidth), size: Self.vp)
        pump(0.5)
        let t = try XCTUnwrap(tags(stage, r.project, proj, settle: cam.settle, chrome: nil).first)
        let leader = try XCTUnwrap(h.marks.all["leader-3"], "the leader is drawn on the page")
        let face = try XCTUnwrap(t.face)
        XCTAssertTrue(leader.insetBy(dx: -1, dy: -1).contains(t.point) && leader.insetBy(dx: -1, dy: -1).contains(face),
                      "from the tag \(t.point) to the face \(face): \(leader)")
        XCTAssertEqual(m.views, [], "never a view switch")
        lines.append("hosted leader-3 \(leader.integral)")
        print("FLEX-S1bV-1 " + lines.joined(separator: " · "))
    }

    // MARK: - S1bV-2 — every number shows, at his layout, over many cameras

    /// ★ [Prisms] SHOWS EVERY NUMBER on his 13" portrait (the verifier: 3 of 5 on A1_0003, 1 of 4 on r5 — two floors under
    /// the Selections strip, one dropped against a neighbour 44 pt away by the TAP target's 84 × 44). Each tag sits at its
    /// floor, or on its prism's axis toward its face (still on the leader's line); none covers his chrome (his img4) or the
    /// Flexible chrome as drawn, none overlaps another; and over the verifier's camera hunt, never. RED before: 3 and 1.
    func testThePrismsViewShowsEveryNumberAtHisLayout() async throws {
        var lines: [String] = []
        for (label, r, want) in [("A1_0003", try FlexiblePressFixtures.a1Project(3, self), 5),
                                 ("r5", try FlexiblePressFixtures.hisRound5(self), 4)] {
            let (stage, m) = try await mainPage(label, r)
            stage.togglePrisms()
            XCTAssertTrue(m.views.contains(.prisms) && stage.latticeShown, "\(label): [Prisms], the Lattice view with it")
            let cam = try Camera(stage, r.project)
            let items = stage.volumes(r.project, on: .lattice, drilledIn: false)
            XCTAssertEqual(items.count, want, "\(label): every pressed face's prism")
            func check(_ ts: [FlexibleStageViewTags.Tag], _ at: String) -> Int {
                var bad = 0
                let drawn = drawnFlexibleChrome(stage).merging(Self.hisChrome) { a, _ in a }
                for t in ts {
                    let fr = FlexibleStageViewTags.mainFrame(t.point)
                    for (k, c) in drawn where c.intersects(fr) {
                        bad += 1
                        XCTFail("\(label) \(at): face \(t.region)'s tag \(fr.integral) over the \(k) \(c.integral)")
                    }
                    if !CGRect(origin: .zero, size: Self.vp).contains(fr) { bad += 1; XCTFail("\(label) \(at): face \(t.region) off screen") }
                    // on its prism's axis (the floor → the face line), or beside its face with the leader reaching the face's
                    // dot: either way the leader points at its face
                    if let item = items.first(where: { $0.volume.faceID == t.region }), let hd = FlexibleDepthPrism.handle(item.volume),
                       let a = stage.viewFrame?.project(hd.anchor), let b = stage.viewFrame?.project(hd.planeOrigin) {
                        let reaches = t.leaderEnd.map { hypot($0.x - b.x, $0.y - b.y) < 0.5 } ?? false
                        if Self.offLine(t.point, a, b) > 1, !reaches { bad += 1; XCTFail("\(label) \(at): face \(t.region)'s tag neither on its prism's axis nor joined to its face") }
                    }
                    if t.face == nil { bad += 1; XCTFail("\(label) \(at): face \(t.region)'s tag has no face") }
                }
                for (i, a) in ts.enumerated() { for b in ts[(i + 1)...] where FlexibleStageViewTags.mainFrame(a.point).intersects(FlexibleStageViewTags.mainFrame(b.point)) {
                    bad += 1
                    XCTFail("\(label) \(at): tags \(a.region) and \(b.region) overlap")
                } }
                return bad
            }
            for heat in [true, false] {
                stage.heat = heat
                stage.refresh()
                let ts = tags(stage, r.project, cam.projection(), settle: cam.settle)
                XCTAssertEqual(ts.count, want, "\(label) heat \(heat): every number shows at his camera (\(ts.map(\.region)))")
                _ = check(ts, "img1 heat \(heat)")
                let hidden = items.filter { it in !ts.contains { $0.region == it.volume.faceID } }.map { it -> String in
                    let hd = FlexibleDepthPrism.handle(it.volume)
                    let a = hd.flatMap { stage.viewFrame?.project($0.anchor) }, b = hd.flatMap { stage.viewFrame?.project($0.planeOrigin) }
                    return "f\(it.volume.faceID) floor \(a.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-") face \(b.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-")"
                }
                lines.append("\(label) heat \(heat): " + ts.map { "f\($0.region) \($0.text) at (\(Int($0.point.x)),\(Int($0.point.y)))\($0.leaderEnd == nil ? "" : " leader→(\(Int($0.leaderEnd!.x)),\(Int($0.leaderEnd!.y)))")" }.joined(separator: ", ")
                             + (hidden.isEmpty ? "" : " · HIDDEN " + hidden.joined(separator: ", ")))
            }
            // the verifier's hunt: many cameras, never over the chrome, never overlapping, never off its axis
            var cameras = 0, bad = 0, shown = 0, possible = 0
            for az in stride(from: Float(0), to: 2 * .pi, by: .pi / 10) {
                for el in [Float(0.2), 0.45, 0.62, 0.85, 1.1] {
                    for zoom in [Float(0.45), 0.7, 1] {
                        let ts = tags(stage, r.project, cam.projection(az: az, el: el, zoom: zoom), settle: cam.settle)
                        bad += check(ts, String(format: "az %.2f el %.2f zoom %.2f", az, el, zoom))
                        cameras += 1; shown += ts.count; possible += want
                        if bad > 5 { break }
                    }
                }
            }
            XCTAssertEqual(bad, 0, "\(label): the hunt")
            lines.append("\(label) hunt: \(cameras) cameras, \(shown) of \(possible) numbers shown, \(bad) bad")
            stage.togglePrisms()
        }
        print("FLEX-S1bV-2 " + lines.joined(separator: " · "))
    }

    // MARK: - S1bV-3 — under [Prisms], the picked group is brighter

    /// ★ SPEC §2, the Prisms view: "every pressed face's prism, faint; the selected one brighter". On the main page the
    /// selected one is the active Selections group's: picking Top, then Group C, moves the bright prisms, and their tags
    /// are placed first. RED before: identical lists, every prism at rest.
    func testPickingAGroupUnderPrismsBrightensItsPrisms() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        let m = settled(r.project, stage)
        let cam = try Camera(stage, r.project)
        m.views = [.prisms]
        var lines: [String] = []
        var seen: [Set<Int>] = []
        for (name, faces) in [("Top", Set([1])), ("Group C", Set([3]))] {
            let g = try XCTUnwrap(r.project.selection.groups.first { $0.name == name })
            r.project.selection.setActive(g.id)
            let items = stage.volumes(r.project, on: .lattice, drilledIn: false)
            XCTAssertEqual(Set(items.map(\.volume.faceID)), [1, 4, 2, 3, 5], "\(name): every prism")
            let bright = Set(items.filter { $0.faceAlpha == FlexibleDepthPrism.viewSelectedFaceAlpha }.map(\.volume.faceID))
            XCTAssertEqual(bright, faces, "\(name): its faces' prisms brighter")
            for it in items where !faces.contains(it.volume.faceID) {
                XCTAssertEqual(it.faceAlpha, FlexibleDepthPrism.restFaceAlpha, "\(name): face \(it.volume.faceID) faint")
                XCTAssertEqual(it.edgeAlpha, FlexibleDepthPrism.restEdgeAlpha)
            }
            for it in items where faces.contains(it.volume.faceID) {
                XCTAssertEqual(it.edgeAlpha, FlexibleDepthPrism.viewSelectedEdgeAlpha)
                XCTAssertTrue(it.selected)
            }
            let ts = tags(stage, r.project, cam.projection(), settle: cam.settle)
            XCTAssertEqual(ts.first.map { faces.contains($0.region) }, true, "\(name): its tag placed first (\(ts.map(\.region)))")
            XCTAssertEqual(Set(ts.filter(\.bright).map(\.region)), faces.intersection(ts.map(\.region)), "\(name): its tags marked")
            seen.append(bright)
            lines.append("\(name) bright \(bright.sorted()) tags \(ts.map { "\($0.region)\($0.bright ? "*" : "")" })")
        }
        XCTAssertNotEqual(seen.first, seen.last, "the bright prisms MOVE with the pick")
        // with no group active: none brighter; and without [Prisms] the active group's own prisms stay faint (not 'brighter')
        r.project.selection.clearActive()
        XCTAssertTrue(stage.volumes(r.project, on: .lattice, drilledIn: false).allSatisfy { $0.faceAlpha == FlexibleDepthPrism.restFaceAlpha })
        m.views = []
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        r.project.selection.setActive(top.id)
        XCTAssertEqual(stage.volumes(r.project, on: .lattice, drilledIn: false).map(\.faceAlpha), [FlexibleDepthPrism.restFaceAlpha])
        print("FLEX-S1bV-3 " + lines.joined(separator: " · "))
    }

    // MARK: - S1bV-4 — the keep-outs are where the chrome is drawn

    /// ★ THE TAGS' KEEP-OUTS IN THE CHROME'S SPACE: the tags layer ignores the safe area (its points are the MTKView's), but
    /// the buttons, the card and the player it keeps clear of are laid out IN the safe area — 24 pt lower at the top, 20 pt
    /// higher at the bottom on his 13" portrait (the verifier found a tag over the player). Hosted under that safe area,
    /// the layer reads the chrome's frame, keeps out of the buttons, card and player where they are drawn, and still puts
    /// each tag at the point the page projects. RED before: the full screen (0, 0, 1032, 1376), the buttons 24 pt high.
    func testTheTagsKeepOutOfTheChromeWhereItIsDrawn() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let stage = FlexibleMainStage()
        let m = settled(r.project, stage)
        let cam = try Camera(stage, r.project)
        let proj = cam.projection()
        m.views = [.prisms]
        let top = try XCTUnwrap(r.project.selection.groups.first { $0.name == "Top" })
        r.project.selection.setActive(top.id)
        // the page's own arrangement: the MTKView full screen, the chrome in the safe area
        let page = ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                FlexibleMainViewToggles(main: stage, openSettings: {})
                FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: proj, settle: cam.settle,
                                    bottomClearance: Self.bottomClearance, chipColumnWidth: Self.chipColumnWidth)
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Self.safeTop) }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: Self.safeBottom) }
        }
        .frame(width: Self.vp.width, height: Self.vp.height)
        let h = host(page, size: Self.vp)
        pump(0.6)
        let chrome = try XCTUnwrap(h.marks.all["chrome"], "the layer names the chrome's frame it keeps out of")
        XCTAssertEqual(chrome.minY, Self.chrome.minY, accuracy: 0.5, "the chrome starts under the status bar")
        XCTAssertEqual(chrome.height, Self.chrome.height, accuracy: 0.5, "…and ends over the home indicator")
        let keep = FlexibleMainPrismTagsLayer.keepOut(main: stage, viewport: Self.vp, bottomClearance: Self.bottomClearance,
                                                      chipColumnWidth: Self.chipColumnWidth, chrome: chrome)
        for (k, drawn) in drawnFlexibleChrome(stage) {
            XCTAssertTrue(keep.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(drawn) }, "the \(k) as drawn \(drawn.integral) is kept out of")
        }
        // the tags themselves still sit where the page projects (the MTKView's space)
        let tagMarks = h.marks.all.filter { $0.key.hasPrefix("tag-") }
        XCTAssertFalse(tagMarks.isEmpty, "tags on the hosted page")
        let expected = tags(stage, r.project, proj, settle: cam.settle, chrome: chrome)
        for t in expected {
            let mk = try XCTUnwrap(tagMarks["tag-\(t.region)"], "face \(t.region)'s tag")
            XCTAssertEqual(mk.midX, t.point.x, accuracy: 1)
            XCTAssertEqual(mk.midY, t.point.y, accuracy: 1)
        }
        m.views = []
        print("FLEX-S1bV-4 chrome \(chrome.integral) · tags " + expected.map { "f\($0.region) (\(Int($0.point.x)),\(Int($0.point.y)))" }.joined(separator: ", "))
    }
    // MARK: - evidence (opt-in): the page as he sees it

    /// ★ EVIDENCE (FLEX_R6_EVIDENCE_DIR=<dir>, optional FLEX_R6_CHROME=<his img4's chrome cut to a 2064 × 2752 PNG>): the
    /// main page at his 13" portrait — the SHIPPING renderer's frame of exactly what FlexibleMainStage hands the viewer
    /// (mesh, tints, dents, X-ray, the lattice layer, H15's prisms), under his chrome, under the REAL Flexible SwiftUI layers
    /// laid out in the safe area (the four buttons, the card with its tags layer, the player). Measures each leader against
    /// the frame without it (max-channel Δ, 0–255) beside the faint prisms'. Offscreen frames, not device screenshots.
    func testEvidenceTheMainPageAsHeSeesIt() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FLEX_R6_EVIDENCE_DIR"].map({ URL(fileURLWithPath: $0, isDirectory: true) })
        else { throw XCTSkip("FLEX_R6_EVIDENCE_DIR") }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let chrome: CGImage? = ProcessInfo.processInfo.environment["FLEX_R6_CHROME"].flatMap {
            CGImageSourceCreateWithURL(URL(fileURLWithPath: $0) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        var log: [String] = []
        for (label, r) in [("A1_0003", try FlexiblePressFixtures.a1Project(3, self)), ("r5", try FlexiblePressFixtures.hisRound5(self))] {
            let (stage, m) = try await mainPage(label, r)
            let p = r.project
            let groups = p.selection.groups.filter { g in p.selection.setActive(g.id); return !stage.volumes(p, on: .lattice, drilledIn: false).isEmpty }
            let last = groups.last?.name ?? "-"
            var states: [(String, () -> Void)] = []
            for g in groups.reversed() {
                let slug = g.name.replacingOccurrences(of: " ", with: "")
                states.append(("\(slug)_heatOff_lattice", { p.selection.setActive(g.id); stage.heat = false; stage.latticeOn = true; m.views = [] }))
                states.append(("\(slug)_heatOn_lattice", { p.selection.setActive(g.id); stage.heat = true; stage.latticeOn = true; m.views = [] }))
            }
            if let g = groups.first {
                states.append(("\(g.name.replacingOccurrences(of: " ", with: ""))_model", { p.selection.setActive(g.id); stage.heat = false; stage.latticeOn = false; m.views = [] }))
            }
            if let g = groups.last {
                states.append(("prisms_heatOff_\(last.replacingOccurrences(of: " ", with: ""))_active", { p.selection.setActive(g.id); stage.heat = false; stage.latticeOn = true; m.views = [.prisms] }))
                states.append(("prisms_heatOn_\(last.replacingOccurrences(of: " ", with: ""))_active", { p.selection.setActive(g.id); stage.heat = true; stage.latticeOn = true; m.views = [.prisms] }))
            }
            for (name, set) in states {
                set()
                stage.refresh()
                let line = try evidenceState("R6_S1bV_\(label)_\(name)", stage, m, p, device: device, chrome: chrome, dir: dir)
                log.append(line)
                print("FLEX-S1bV-EVIDENCE " + line)
            }
            m.views = []
        }
        try log.joined(separator: "\n").write(to: dir.appendingPathComponent("R6_S1bV_evidence_log.txt"), atomically: true, encoding: .utf8)
    }

    final class Holder: ObservableObject { @Published var metal: CGImage? }

    struct EvidencePage: View {
        @ObservedObject var holder: Holder
        let chrome: CGImage?
        let stage: FlexibleMainStage
        let proj: CameraProjection
        let settle: simd_quatf
        var body: some View {
            ZStack {
                if let m = holder.metal { Image(decorative: m, scale: 2).resizable().frame(width: FlexibleS1bMainTagsTests.vp.width, height: FlexibleS1bMainTagsTests.vp.height) }
                if let c = chrome { Image(decorative: c, scale: 2).resizable().frame(width: FlexibleS1bMainTagsTests.vp.width, height: FlexibleS1bMainTagsTests.vp.height) }
                ZStack {
                    FlexibleMainViewToggles(main: stage, openSettings: {})
                    FlexibleMainLegends(main: stage, mode: .constant(.groups), projection: proj, settle: settle,
                                        bottomClearance: FlexibleS1bMainTagsTests.bottomClearance, chipColumnWidth: FlexibleS1bMainTagsTests.chipColumnWidth)
                    FlexibleMainPlayerSlot(main: stage, bottomClearance: FlexibleS1bMainTagsTests.bottomClearance,
                                           chipColumnWidth: FlexibleS1bMainTagsTests.chipColumnWidth)
                }
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: FlexibleS1bMainTagsTests.safeTop) }
                .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: FlexibleS1bMainTagsTests.safeBottom) }
            }
            .frame(width: FlexibleS1bMainTagsTests.vp.width, height: FlexibleS1bMainTagsTests.vp.height)
            .background(Color.black)
        }
    }

    /// One state: the frame (with and without the prisms), the hosted page over it, written; the leaders' and the
    /// prisms' visibility, measured.
    func evidenceState(_ name: String, _ stage: FlexibleMainStage, _ m: FlexibleStageModel, _ p: ProjectModel, device: MTLDevice,
                       chrome: CGImage?, dir: URL) throws -> String {
        let side = 2752, cropW = 2064
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 4))
        mr.setMesh(try XCTUnwrap(stage.mesh(p, on: .lattice)))
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        mr.beginSettle(to: settle, duration: 0)
        mr.camera.setOrientation(azimuth: .pi / 4, elevation: 0.62)
        if let t = stage.tints(p, on: .lattice, roles: [:], stress: nil) { mr.setVertexTints(t) }
        mr.setBodyAlpha(stage.bodyAlpha(p, on: .lattice) ?? 1)
        if let layer = stage.layer(p, stage: .lattice, pageUp: false) { _ = mr.applyFlexibleLattice(layer, device: device) }
        if let d = stage.dents(p, on: .lattice) { mr.setFlexDisplacements(d) }
        mr.setFlexScale(Float(stage.channels?.exaggeration ?? 1))
        let items = stage.volumes(p, on: .lattice, drilledIn: false)
        func grab() throws -> [UInt8] {
            let bg = DS.Color.background
            let px = try XCTUnwrap(mr.renderOffscreen(size: side, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)))
            var rgba = [UInt8](repeating: 255, count: cropW * side * 4)
            let x0 = (side - cropW) / 2
            for y in 0..<side { for x in 0..<cropW {
                let s = (y * side + x + x0) * 4, d = (y * cropW + x) * 4
                rgba[d] = px[s + 2]; rgba[d + 1] = px[s + 1]; rgba[d + 2] = px[s]
            } }
            return rgba
        }
        mr.setClearanceVolumes(items)
        var with = try grab()
        mr.setClearanceVolumes([])
        let without = try grab()
        func delta(_ a: [UInt8], _ b: [UInt8], at pts: [(Int, Int)]? = nil) -> (n: Int, median: Int, p10: Int, p90: Int) {
            var d: [Int] = []
            if let pts {
                for (x, y) in pts where x >= 0 && y >= 0 && x < cropW && y < side {
                    let i = (y * cropW + x) * 4
                    d.append((0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max() ?? 0)
                }
            } else {
                for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
                    let v = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max() ?? 0
                    if v > 2 { d.append(v) }
                }
            }
            d.sort()
            let q = { (f: Double) -> Int in d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count) * f))] }
            return (d.count, q(0.5), q(0.1), q(0.9))
        }
        let prisms = delta(with, without)
        let ctx = try XCTUnwrap(CGContext(data: &with, width: cropW, height: side, bitsPerComponent: 8, bytesPerRow: cropW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let holder = Holder()
        holder.metal = try XCTUnwrap(ctx.makeImage())
        let proj = CameraProjection(camera: mr.camera, viewportSize: Self.vp)
        let h = host(EvidencePage(holder: holder, chrome: chrome, stage: stage, proj: proj, settle: settle), size: Self.vp)
        pump(0.8)
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(name).png"))
        // the leaders: the composite against the frame under it, along each leader's centre line (@2x)
        var page = [UInt8](repeating: 0, count: cropW * side * 4)
        if rep.pixelsWide == cropW, rep.pixelsHigh == side, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3, let data = rep.bitmapData {
            let spp = rep.samplesPerPixel, row = rep.bytesPerRow
            for y in 0..<side { for x in 0..<cropW {
                let s = y * row + x * spp, i = (y * cropW + x) * 4
                page[i] = data[s]; page[i + 1] = data[s + 1]; page[i + 2] = data[s + 2]
            } }
        }
        let tags = tags(stage, p, proj, settle: settle)
        var leaders: [String] = []
        for t in tags {
            guard let e = t.leaderEnd else { leaders.append("f\(t.region) no leader"); continue }
            // the run outside the tag's capsule
            let n = max(2, Int(hypot(e.x - t.point.x, e.y - t.point.y) * 2))
            var pts: [(Int, Int)] = []
            for i in 0...n {
                let q = CGPoint(x: t.point.x + (e.x - t.point.x) * CGFloat(i) / CGFloat(n), y: t.point.y + (e.y - t.point.y) * CGFloat(i) / CGFloat(n))
                if FlexibleStageViewTags.mainFrame(t.point).insetBy(dx: -2, dy: -2).contains(q) { continue }
                pts.append((Int((q.x * 2).rounded()), Int((q.y * 2).rounded())))
            }
            let d = rep.pixelsWide == cropW ? delta(page, with, at: pts) : (0, -1, -1, -1)
            leaders.append("f\(t.region) \(t.text) at (\(Int(t.point.x)),\(Int(t.point.y))) → (\(Int(e.x)),\(Int(e.y)))\(t.away ? " away" : "")\(t.bright ? " bright" : "") · leader Δ over \(pts.count) px: median \(d.1) p10 \(d.2)")
        }
        let shown = Set(tags.map(\.region))
        let hidden = items.map(\.volume.faceID).filter { !shown.contains($0) }
        return "\(name): active \(p.selection.activeGroup?.name ?? "-") · heat \(stage.heat) lattice \(stage.latticeShown) · views \(m.views.rawValue) · prisms "
            + items.map { "f\($0.volume.faceID)\($0.selected ? "*" : "") a\($0.faceAlpha.map { String(format: "%.2f", $0) } ?? "-")" }.joined(separator: " ")
            + " · prisms' Δ \(prisms.n) px median \(prisms.median) p90 \(prisms.p90) · tags \(tags.count) of \(items.count)"
            + (hidden.isEmpty ? "" : " HIDDEN \(hidden)") + " · " + leaders.joined(separator: "; ")
    }
}
#endif
