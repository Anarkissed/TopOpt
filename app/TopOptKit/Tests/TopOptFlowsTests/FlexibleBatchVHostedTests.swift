// FlexibleBatchVHostedTests — round 6, batch V (2026-10-10): his two view settings on the main Flexible page, and the
// Settings page's overlays kept out of its chrome (the item-4 verifier's m19). On HIS projects — A1_0003 (his img1–4
// pad) and his r5 — restored as he saved them, hosted offscreen (never the app). Written BEFORE the code; each with its
// red control.
//   ★ R7-V (his 2026-10-14 words: "Remove the two full worded view icons. I've decided against them.") — the two view
//   settings are gone and both behaviours fixed ON: V1a keeps its fixed state (no role colour on the main model; Settings
//   keeps its marks), V1b its fixed state (nothing on open, the picked group's prism, none for a Pending group); V1c (kept
//   per project) and V1d (their chips) are gone — the legend card's places beside the icon row stay pinned.
//   V2a m19: NOTHING DRAWN ON THE PART SHOWS INSIDE THE SETTINGS PANEL OR THE LEGEND — the hosted page rendered with and
//       without that layer (the dashed outlines, the curves, the stamp, the chips, the tags) differs by 0 pixels inside
//       them, nor inside the pop-up, the top line, the Exit row or the view buttons; and it differs somewhere (the layer
//       drew: the measurement measures something). His pad at 13" portrait and 11" landscape — [Rests], Group 2 (face 4),
//       Group 3 (face 3), both views — and his r5's curves.
//   V2b the clip is every piece of the page's chrome, in the stage's frame (which ignores the safe area).
// FLEX_BV_EVIDENCE_DIR=<dir> also writes the hosted pages.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class BVHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleBatchVHostedTests: XCTestCase {

    // MARK: - hosting (FlexibleRound6HostedTests' own)

    final class Frames { var all: [String: CGRect] = [:]; var marks: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_BV_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let sizes: [(String, CGSize)] = FlexibleGroupPaletteHostedTests.sizes
    static let mini = ("mini", CGSize(width: 744, height: 1133))
    /// His 13" portrait (the verifier's screens) and 11" landscape.
    static var his13p: (String, CGSize) { sizes.first { $0.0 == "13p" }! }
    static var his11l: (String, CGSize) { sizes.first { $0.0 == "11l" }! }

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
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleViewMarksKey.self) { frames.marks = $0 }
            .environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = BVHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func local(_ h: Host, _ name: String) -> CGRect? {
        guard let f = h.frames.all[name] else { return nil }
        guard let page = h.frames.all["page"] else { return f }
        return f.offsetBy(dx: -page.minX, dy: -page.minY)
    }

    func snapshot(_ h: Host, _ name: String) {
        guard let dir = Self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        h.view.layoutSubtreeIfNeeded()
        guard let rep = h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds) else { return }
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent(name))
            print("FLEX-BV wrote \(dir.appendingPathComponent(name).path)")
        }
    }

    /// A click at `p` (the page's points, y down) through the window.
    func click(_ h: Host, _ p: CGPoint) {
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
    }

    /// A main stage (★ R7-V: batch V's view settings and their store are gone — his 2026-10-14 words).
    func mainStage() -> FlexibleMainStage {
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        return s
    }

    /// A model over `project` (the main stage's own), its scene, stacks and designs settled.
    func settledModel(_ project: ProjectModel, stage given: FlexibleMainStage? = nil) -> FlexibleStageModel {
        let stage = given ?? mainStage()
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

    /// HIS pad: A1_0003 as he saved it (img1–img4): Group 1 = the top (face 1), Group 2 = faces 4 and 2 (pink), Group 3 =
    /// faces 3 and 5 (teal, his pick), face 0 rests. Main page: Bottom (Anchor), Top (Load), Group C (Pending, face 3).
    func his(_ stage: FlexibleMainStage? = nil) throws -> (FlexibleHisProject.Restored, FlexibleStageModel) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let m = settledModel(r.project, stage: stage)
        XCTAssertEqual(m.squeezeGroups.map(\.regions), [[1], [4, 2], [3, 5]], "his three groups")
        return (r, m)
    }

    func projection(_ project: ProjectModel, size: CGFloat = 900, elevation: Float = .pi / 6, azimuth: Float = .pi / 4) throws -> CameraProjection {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let mr = try XCTUnwrap(MeshRenderer(device: device, sampleCount: 1))
        mr.setMesh(try XCTUnwrap(project.viewerMesh))
        mr.beginSettle(to: project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: azimuth, elevation: elevation)
        return CameraProjection(viewProjection: mr.clipFromModel(aspect: 1), viewportSize: CGSize(width: size, height: size))
    }

    static func rgba(_ t: [Float], _ v: Int) -> SIMD4<Float> { SIMD4(t[v * 8], t[v * 8 + 1], t[v * 8 + 2], t[v * 8 + 3]) }
    static func inked(_ t: [Float], _ ink: Set<SIMD4<Float>>) -> Int {
        (0..<(t.count / 8)).filter { ink.contains(rgba(t, $0)) }.count
    }
    /// #354's Selections role colours as the workspace composes them (WorkspacePlaceholder.roleTints, the solid model):
    /// each shown group's tint on every face it holds, by either membership.
    static func roleTints(_ p: ProjectModel) -> [FaceID: SIMD4<Float>] {
        var out: [FaceID: SIMD4<Float>] = [:]
        for g in p.selection.groups where !p.groupView.isHidden(g.id) {
            let c = p.force.tint(for: g)
            for f in Set(g.faces).union(p.latticeRegionCoveredFaces(g)) { out[f] = SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), 1) }
        }
        return out
    }

    // MARK: - V1a: no role colour on the main page's model (★ R7-V: fixed — the toggle is gone)

    /// ★ HIS ANSWER OF 2026-10-09 ("no group or role colour on the main page model; colours show in the Selections list and
    /// on the Settings page only") — batch V's view setting, ★ RE-PINNED by R7-V (his 2026-10-14 words: "Remove the two full
    /// worded view icons"; his answer: the behaviour fixed ON): the fixed-state cases kept, the OFF flips gone; the positive
    /// control is the red control `controlRolesOnMain` (the roles and marks passed through).
    func testNoRoleColourIsOnTheMainModelAndTheSettingsPageKeepsItsMarks() throws {
        let s = mainStage()
        let (r, m) = try his(s)
        s.apply(r.project, owned: true, pageUp: false)
        m.selectedRegion = nil   // (a selected face would tint face 0 as its linked other end)
        s.latticeOn = false; s.heat = true; s.stress = false
        s.refresh()
        let o = try XCTUnwrap(s.overlay)
        let none = SIMD4<Float>(0, 0, 0, 0)
        let tris0 = o.keptFace.indices.filter { o.keptFace[$0] == 0 }
        XCTAssertFalse(tris0.isEmpty, "premise: face 0 (his resting bottom) is in the overlay")
        func face0(_ t: [Float]) -> Set<SIMD4<Float>> { Set(tris0.flatMap { tri in (0..<3).map { Self.rgba(t, 3 * tri + $0) } }) }
        var lines: [String] = []
        let marks: Set<SIMD4<Float>> = [FlexibleColours.restingFace, FlexibleColours.loadedFace, FlexibleColours.selectedFace, FlexibleColours.linkedEnd]
        XCTAssertEqual(face0(try XCTUnwrap(s.channels?.tints)), [none], "★ his resting bottom wears no mark")
        let onMarks = Self.inked(try XCTUnwrap(s.channels?.tints), marks)
        XCTAssertEqual(onMarks, 0, "★ no role mark anywhere on the model")
        s.controlRolesOnMain = true
        s.refresh()
        XCTAssertEqual(face0(try XCTUnwrap(s.channels?.tints)), [FlexibleColours.restingFace], "control (the marks passed through): the resting cyan")
        let controlMarks = Self.inked(try XCTUnwrap(s.channels?.tints), marks)
        s.controlRolesOnMain = false
        s.refresh()
        XCTAssertGreaterThan(controlMarks, 0, "control: the marks")
        lines.append("marks: \(onMarks) vertices (control \(controlMarks))")
        // the Settings page keeps them (his answer): its composed tints, the same model
        let settings = FlexibleStagePage.composeTints(model: m, overlay: FlexiblePageChannels.overlay(model: m))
        XCTAssertGreaterThan(Self.inked(try XCTUnwrap(settings.tints), [FlexibleColours.restingFace]), 0, "the Settings page keeps the resting cyan")
        for (id, t) in s.playAllBaseTints(m, scaleMM: 1) { XCTAssertEqual(face0(t), [none], "★ \(id)'s turn — no mark") }
        // #354's Selections colours, where they would show: a face Flexible does not tint
        m.edit({ st in st.removeFace(0) }, recompute: false)
        s.refresh()
        let roles = Self.roleTints(r.project), roleInk = Set(roles.values)
        for (name, lattice, heat) in [("the model", false, false), ("the model, heat on", false, true), ("Lattice", true, false)] {
            s.latticeOn = lattice; s.xrayOn = lattice; s.heat = heat; s.stress = false
            s.refresh()
            let t = try XCTUnwrap(s.tints(r.project, on: .lattice, roles: roles, stress: nil))
            XCTAssertTrue(face0(t).isDisjoint(with: roleInk), "★ \(name): no role colour on face 0")
            XCTAssertEqual(Self.inked(t, roleInk), 0, "★ \(name): no role colour on the model")
            lines.append("roles, \(name): \(Self.inked(t, roleInk)) role-coloured vertices")
        }
        print("FLEX-BV-1a (fixed, R7-V)\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - V1b: a group's prism after a pick (★ R7-V: fixed — the toggle is gone)

    /// ★ HIS ANSWER OF 2026-10-09 ("the main page shows a group's prism and mm number ONLY AFTER he picks a group in this
    /// session; nothing on open; a Pending group shows no number") — ★ RE-PINNED by R7-V: the fixed-state cases kept, the
    /// OFF flips gone (their positive control is `controlPrismOnOpen`, S1b's rule).
    func testAGroupsPrismShowsNothingOnOpenThenThePickedGroupsPrismAndNumber() throws {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let p = r.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        let groupC = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        XCTAssertTrue(p.force.kind(for: groupC.id).isPending, "premise: Group C is Pending")
        p.selection.setActive(top.id)
        let s = mainStage()
        let m = settledModel(p, stage: s)
        s.apply(p, owned: true, pageUp: false)
        let proj = try projection(p)
        let size = CGSize(width: 900, height: 900)
        func prisms() -> [Int] { s.volumes(p, on: .lattice, drilledIn: false).map(\.volume.faceID) }
        func tags() -> [Int] {
            s.prismTags(p, on: .lattice, drilledIn: false, viewport: size, keepOut: [], projector: { proj.project($0) }).map(\.region)
        }
        XCTAssertFalse(s.sessionPicked, "nothing picked as the page opens")
        XCTAssertEqual(prisms(), [], "★ on open: no prism (the Top is active, but he has not picked it)")
        XCTAssertEqual(tags(), [], "★ on open: no number")
        s.controlPrismOnOpen = true
        XCTAssertEqual(prisms(), [1], "control (S1b's rule): the active Top's prism on open")
        s.controlPrismOnOpen = false
        XCTAssertEqual(prisms(), [], "none until a pick")
        p.selection.setActive(top.id)
        XCTAssertTrue(s.sessionPicked, "his tap on the Top's row")
        XCTAssertEqual(prisms(), [1], "★ after his pick: the Top's prism")
        XCTAssertEqual(tags(), [1], "★ …and its number")
        let f1 = try XCTUnwrap(m.settings.face(1))
        XCTAssertEqual(s.prismTags(p, on: .lattice, drilledIn: false, viewport: size, keepOut: [], projector: { proj.project($0) }).first?.text,
                       String(format: "%.1f mm", f1.deepestMM), "his deepest, read-only")
        p.selection.setActive(groupC.id)
        XCTAssertEqual(prisms(), [], "★ a Pending group: no prism")
        XCTAssertEqual(tags(), [], "★ …and no number")
        p.selection.setActive(top.id)
        XCTAssertEqual(prisms(), [1], "the Top again")
        m.views = [.prisms]
        let all = s.volumes(p, on: .lattice, drilledIn: false)
        XCTAssertEqual(Set(all.map(\.volume.faceID)), [1, 4, 2, 3, 5], "[Prisms]: every pressed face")
        XCTAssertEqual(all.filter(\.selected).map(\.volume.faceID), [1], "the picked Top brighter")
        m.views = []
        print("FLEX-BV-1b (fixed, R7-V) after his pick: Top [1] · Group C [] · [Prisms] \(all.map(\.volume.faceID).sorted())")
    }

    // MARK: - V1c / V1d (★ R7-V: gone with the two toggles — his 2026-10-14 words)
    // V1c pinned the two settings kept per project in the app's defaults, and V1d their two worded chips under the view
    // buttons. Both are gone; the icon row and its keep-outs are pinned by FlexibleRound7ViewsHostedTests (H1) and by the
    // re-pinned FlexibleMainPageRound4 tests; the legend card's two places beside the row:

    func testTheLegendCardKeepsItsPlacesBesideTheIconRow() throws {
        for (tag, size) in Self.sizes + [Self.mini] {
            let keep = FlexibleMainLegendLayout.keepOut(viewport: size, bottomClearance: 94, chipColumnWidth: 222)
            for rows in 1...2 {
                let folded = FlexibleMainLegendLayout.placeCard(rows: rows, minimized: true, viewport: size, keepOut: keep,
                                                                edge: FlexibleMainLegendLayout.foldedEdge)
                XCTAssertEqual(folded?.frame.maxX ?? 0, size.width, accuracy: 0.5, "\(tag): the folded card (\(rows) rows) on the very edge")
                let open = FlexibleMainLegendLayout.placeCard(rows: rows, minimized: false, viewport: size, keepOut: keep)
                XCTAssertEqual(open?.frame.maxX ?? 0, size.width - PageChrome.edge, accuracy: 0.5, "\(tag): the open card (\(rows) rows) in the trailing column")
                if let f = open?.frame { XCTAssertFalse(f.intersects(FlexibleMainViewToggles.frame(viewport: size)), "\(tag): the card clear of the icon row") }
            }
            XCTAssertTrue(FlexibleMainPlayerSlot.keepOut(viewport: size).contains { $0.contains(FlexibleMainViewToggles.rowFrame(viewport: size)) },
                          "\(tag): the player keeps out of the icon row")
        }
    }

    // MARK: - V2a: m19 — nothing drawn on the part shows inside the Settings panel or the legend

    /// The hosted page's pixels (RGBA8, the top row first).
    struct Shot { let w: Int; let h: Int; let scale: CGFloat; let px: [UInt8] }
    func shot(_ h: Host) throws -> Shot {
        h.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(h.view.bitmapImageRepForCachingDisplay(in: h.view.bounds))
        h.view.cacheDisplay(in: h.view.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let w = cg.width, hh = cg.height
        var buf = [UInt8](repeating: 0, count: w * hh * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: w, height: hh, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: hh))
        return Shot(w: w, h: hh, scale: CGFloat(w) / h.view.bounds.width, px: buf)
    }
    /// Pixels inside `r` (points, y down) whose largest channel differs by more than `t` (of 255).
    static func differing(_ a: Shot, _ b: Shot, in r: CGRect, threshold t: Int = 12) -> Int {
        guard a.w == b.w, a.h == b.h else { return -1 }
        let x0 = max(0, Int((r.minX * a.scale).rounded(.up))), x1 = min(a.w, Int((r.maxX * a.scale).rounded(.down)))
        let y0 = max(0, Int((r.minY * a.scale).rounded(.up))), y1 = min(a.h, Int((r.maxY * a.scale).rounded(.down)))
        guard x0 < x1, y0 < y1 else { return 0 }
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * a.w + x) * 4
                let d = max(abs(Int(a.px[i]) - Int(b.px[i])), abs(Int(a.px[i + 1]) - Int(b.px[i + 1])), abs(Int(a.px[i + 2]) - Int(b.px[i + 2])))
                if d > t { n += 1 }
            }
        }
        return n
    }

    /// The chrome a test asserts on (the player animates: printed, not asserted).
    static let chrome = ["panel", "legend", "popup", "notice", "exitRow", "viewButtons"]

    /// One state of the page: rendered with the layer of everything drawn on the part, again (the noise), and without it
    /// (FlexibleStagePage.controlNoOverlays) — the pixels that differ inside each piece of chrome, and over the whole page.
    func measure(_ h: Host, _ m: FlexibleStageModel) throws -> (inside: [String: Int], noise: [String: Int], total: Int, player: Int) {
        FlexibleStagePage.controlNoOverlays = false
        m.objectWillChange.send()
        pump(1.2)
        let a = try shot(h)
        pump(0.2)
        let a2 = try shot(h)
        FlexibleStagePage.controlNoOverlays = true
        m.objectWillChange.send()
        pump(1.2)
        let b = try shot(h)
        FlexibleStagePage.controlNoOverlays = false
        m.objectWillChange.send()
        pump(0.6)
        var inside: [String: Int] = [:], noise: [String: Int] = [:]
        for name in Self.chrome {
            guard let r = local(h, name), r.width > 4, r.height > 4 else { continue }
            let k = r.insetBy(dx: 1, dy: 1)
            inside[name] = Self.differing(a, b, in: k)
            noise[name] = Self.differing(a, a2, in: k)
        }
        let player = local(h, "player").map { Self.differing(a, b, in: $0.insetBy(dx: 1, dy: 1)) } ?? 0
        return (inside, noise, Self.differing(a, b, in: CGRect(origin: .zero, size: h.size)), player)
    }

    /// ★ m19 (the item-4 verifier's screens, reproduced here first): the dashed group outlines ran across the Settings
    /// panel (Group 3, [Rests]) and through the legend (Group 2, [Rests]) — the 62 %-opaque chrome let them read as drawn
    /// OVER it. On his pad and his r5 (the curves), at his 13" portrait and 11" landscape.
    func testNothingDrawnOnThePartShowsInsideThePanelOrTheLegend() throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlNoOverlays = false; FlexibleStagePage.controlOverlaysOverChrome = false }
        let (r, m) = try his()
        typealias State = (name: String, set: () -> Void)
        let states: [State] = [
            ("Rests", { m.views = []; m.selectedRegion = nil; m.rail = .rests }),
            ("Group 2 · face 4", { m.views = []; m.rail = .group(2); m.select(4) }),
            ("Group 3 · face 3", { m.views = []; m.rail = .group(3); m.select(3) }),
            ("both views", { m.selectedRegion = nil; m.rail = .model; m.views = [.prisms, .groups] }),
        ]
        var lines: [String] = []
        var failures = 0
        func run(_ tag: String, _ size: CGSize, _ project: ProjectModel, _ model: FlexibleStageModel, _ states: [State], prefix: String) throws {
            let h = host(FlexibleStagePage(project: project, model: model, onExit: {}), size: size)
            pump(2.5)
            for st in states {
                st.set()
                pump(1.0)
                let got = try measure(h, model)
                let shown = got.inside.filter { $0.value > 0 }
                XCTAssertGreaterThan(got.total, 0, "\(prefix) \(tag) · \(st.name): the layer drew something (else this measures nothing)")
                for (name, n) in got.inside.sorted(by: { $0.key < $1.key }) {
                    XCTAssertEqual(n, 0, "★ \(prefix) \(tag) · \(st.name): \(n) pixels drawn on the part show inside the \(name)")
                }
                failures += shown.count
                lines.append("\(prefix) \(tag) · \(st.name): inside " + got.inside.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                             + " · noise " + got.noise.filter { $0.value > 0 }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                             + " · player \(got.player) · the whole page \(got.total)")
                snapshot(h, "BV_\(prefix)_\(tag)_\(st.name.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "·", with: "_")).png")
            }
        }
        for (tag, size) in [Self.his13p, Self.his11l] { try run(tag, size, r.project, m, states, prefix: "A1_0003") }
        // his r5: Top B (Curves) in Group 1 — the curves (and the fix pop-up he saved with)
        let r5 = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir, asSaved: true)
        addTeardownBlock { r5.cleanup() }
        let m5 = settledModel(r5.project)
        let curves = try XCTUnwrap(m5.settings.loadedFaces.first { !$0.isStampShape }, "premise: a face drawn with Curves on r5")
        let r5States: [State] = [("curves · region \(curves.faceRegionID)", { m5.views = []; m5.select(curves.faceRegionID) })]
        for (tag, size) in [Self.his13p, Self.his11l] { try run(tag, size, r5.project, m5, r5States, prefix: "r5") }
        print("FLEX-BV-2a (pixels of the page with the part's overlays vs without, inside each piece of chrome; 0 = nothing shows there)\n  "
              + lines.joined(separator: "\n  ") + "\n  states with an overlay inside the chrome: \(failures)")
    }

    /// ★ RED CONTROL of V2a: the same page, the layer drawn over the chrome again (`controlOverlaysOverChrome` — the clip
    /// left out): the verifier's [Rests] on his pad at 13" portrait shows through the panel and the legend once more.
    func testTheRedControlTheLayerOverTheChromeAgain() throws {
        addTeardownBlock { @MainActor in FlexibleStagePage.controlNoOverlays = false; FlexibleStagePage.controlOverlaysOverChrome = false }
        let (r, m) = try his()
        let h = host(FlexibleStagePage(project: r.project, model: m, onExit: {}), size: Self.his13p.1)
        pump(2.5)
        m.views = []; m.selectedRegion = nil; m.rail = .rests
        pump(1.0)
        let clipped = try measure(h, m)
        FlexibleStagePage.controlOverlaysOverChrome = true
        let over = try measure(h, m)
        FlexibleStagePage.controlOverlaysOverChrome = false
        XCTAssertEqual(clipped.inside["panel"], 0, "the clip: nothing inside the panel")
        XCTAssertEqual(clipped.inside["legend"], 0, "…nor the legend")
        XCTAssertGreaterThan(over.inside["panel"] ?? 0, 0, "★ control (no clip): the bottom's dashed outline inside the panel again")
        XCTAssertGreaterThan(over.inside["legend"] ?? 0, 0, "★ control (no clip): …and inside the legend")
        // ★ THE CLIP CHANGES NOTHING OUTSIDE THE CHROME — only the lines are cut, never the chip, the stamp's handle or the
        // tags (a first cut masked the whole layer, which put the depth chip's glass in an offscreen pass): Group 3 with face 3
        // selected (the chip, the stamp, the dashed outline), with the clip and without it, pixel for pixel outside the chrome
        m.views = []; m.rail = .group(3); m.select(3)
        pump(1.0)
        func page(_ overChrome: Bool) throws -> Shot {
            FlexibleStagePage.controlOverlaysOverChrome = overChrome
            m.objectWillChange.send()
            pump(1.2)
            return try shot(h)
        }
        let a = try page(false), a2 = try page(false), b = try page(true)
        FlexibleStagePage.controlOverlaysOverChrome = false
        let holes = (Self.chrome + ["player", "playerTopRow", "playerCapsule", "toast"]).compactMap { local(h, $0)?.insetBy(dx: -2, dy: -2) }
            + [FlexibleLegendPlacement.gizmoFrame(viewport: h.size).insetBy(dx: -2, dy: -2)]
        let outside = Self.differingOutside(a, b, holes: holes), noise = Self.differingOutside(a, a2, holes: holes)
        XCTAssertNotNil(h.frames.all["legend"], "premise: the legend shows")
        XCTAssertEqual(noise, 0, "premise: the page is still between two shots")
        XCTAssertEqual(outside, 0, "★ outside the chrome the clip changes no pixel (the chip's glass, the stamp, the outline)")
        print("FLEX-BV-2a control 13p [Rests]: clipped panel \(clipped.inside["panel"] ?? -1) legend \(clipped.inside["legend"] ?? -1) · "
              + "no clip panel \(over.inside["panel"] ?? -1) legend \(over.inside["legend"] ?? -1) · Group 3 · face 3 outside the chrome: "
              + "clip vs none \(outside) px (noise \(noise))")
    }


    /// Pixels outside every rect of `holes` (points, y down) whose largest channel differs by more than `t`.
    static func differingOutside(_ a: Shot, _ b: Shot, holes: [CGRect], threshold t: Int = 12) -> Int {
        guard a.w == b.w, a.h == b.h else { return -1 }
        var n = 0
        for y in 0..<a.h {
            for x in 0..<a.w {
                let i = (y * a.w + x) * 4
                let d = max(abs(Int(a.px[i]) - Int(b.px[i])), abs(Int(a.px[i + 1]) - Int(b.px[i + 1])), abs(Int(a.px[i + 2]) - Int(b.px[i + 2])))
                guard d > t else { continue }
                let p = CGPoint(x: (CGFloat(x) + 0.5) / a.scale, y: (CGFloat(y) + 0.5) / a.scale)
                if !holes.contains(where: { $0.contains(p) }) { n += 1 }
            }
        }
        return n
    }

    // MARK: - V2b: the clip

    /// ★ The clip is EVERY piece of the page's chrome — the panel, the legend, the view buttons, the player (as its two
    /// drawn parts or whole), the pop-up, the top line and its toast, the Exit row — and the gizmo, each moved into the
    /// stage's frame (the stage ignores the safe area: on his 13" portrait it starts 24 pt above the page).
    func testTheClipIsEveryPieceOfTheChromeInTheStagesFrame() {
        let v = CGSize(width: 1032, height: 1376 - 44)
        let page = CGRect(x: 0, y: 24, width: v.width, height: v.height)
        let stage = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        var frames: [String: CGRect] = ["page": page, "stage": stage]
        let named: [String: CGRect] = [
            "panel": CGRect(x: 24, y: 700, width: 400, height: 600), "legend": CGRect(x: 760, y: 600, width: 260, height: 120),
            "viewButtons": CGRect(x: 920, y: 260, width: 88, height: 40), "playerTopRow": CGRect(x: 500, y: 1230, width: 200, height: 30),
            "playerCapsule": CGRect(x: 460, y: 1262, width: 280, height: 50), "popup": CGRect(x: 160, y: 100, width: 420, height: 110),
            "notice": CGRect(x: 280, y: 40, width: 380, height: 34), "toast": CGRect(x: 360, y: 78, width: 220, height: 26),
            "exitRow": CGRect(x: 24, y: 40, width: 226, height: 44),
        ]
        frames.merge(named) { $1 }
        let clip = FlexibleStagePage.chromeClip(frames, viewport: v)
        func has(_ r: CGRect) -> Bool { clip.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(r) } }
        for (name, r) in named.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(has(r.offsetBy(dx: -stage.minX, dy: -stage.minY)), "\(name) is clipped, in the stage's frame")
        }
        let gizmo = FlexibleLegendPlacement.gizmoFrame(viewport: v).offsetBy(dx: page.minX - stage.minX, dy: page.minY - stage.minY)
        XCTAssertTrue(has(gizmo), "the gizmo, moved from the page's frame into the stage's")
        // everything the chips and handles keep out of is clipped too
        for r in FlexibleStagePage.stageKeepOut(frames) { XCTAssertTrue(has(r), "the keep-out \(r) is clipped") }
        print("FLEX-BV-2b clip \(clip.count) rects: \(clip.map(\.integral))")
    }
}
#endif
