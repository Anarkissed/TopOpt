// FlexibleRound7DesignIntegrationHostedTests — round 7, batch R7-D3, the hosted half of FlexibleRound7DesignIntegrationTests:
// the WHOLE app page (WorkspacePlaceholder) offscreen on HIS pad (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at
// 25 mm; Bottom anchors; Top 22 lb), the lattice built, at 13" and 11", portrait and landscape, and the mini in portrait (added
// after the pure test found it, before any code) — D1's corner pair and D2's
// Selections wired together by the page itself. Written BEFORE the code (red run: round7/batch_d3/d3_red_run.txt).
//   H1  "Lattice ready" (the note, posted as a build lands) sits on the views row's line, left of the icons, never under
//       them, never on the legend or the capsule (the reviewer's 2026-10-17 ruling 3) — RED at 0e66bf47 at 11" portrait
//   H2  one card at a time, live: chip M → the Setup chip's tray (the chip folds, the pick and its prisms stay) → a face tap
//       (the tray folds, the chip back) → the ⌃'s card (the chip folds; the card never on the legend) → a click on the list's
//       depth box (its keypad folds the card) → the tray's Gravity [Change] (every card folds, the pick goes: no chip over
//       #354's gravity picker — RED at 0e66bf47)
//   H3  the minimised Selections pill stays ≥ 12 pt from the Setup chip while a chip is open
//   H4  no panel (the tray, the card, the callout) ever covers the legend, at every size
// (A model tap is H22's call — the page's onPickPoint hands it to `flexibleMain.tapFace` — made directly, as the earlier hosted
// tests do. Frames come from FlexibleKeepOutKey.)
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class D3HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7DesignIntegrationHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    typealias Cam = FlexibleRound6Tests.Cam
    static let img1 = Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)

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
        let w = D3HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
    func click(_ h: Host, _ p: CGPoint) {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: p.x, y: h.size.height - p.y), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.8)
    }
    func press(_ h: Host, _ key: String, _ what: String, at: ((CGRect) -> CGPoint)? = nil) throws {
        let f = try XCTUnwrap(h.frames.all[key], "no frame '\(key)' for \(what)")
        click(h, at?(f) ?? CGPoint(x: f.midX, y: f.midY))
    }
    func pageView(_ v: NSView) -> MTKView? {
        var all: [MTKView] = []
        func walk(_ v: NSView) {
            if let m = v as? MTKView, m.delegate is MeshRenderer, !m.isHidden { all.append(m) }
            for s in v.subviews { walk(s) }
        }
        walk(v)
        guard let maxA = all.map({ $0.bounds.width * $0.bounds.height }).max() else { return nil }
        return all.first { $0.bounds.width * $0.bounds.height >= maxA - 1 }
    }
    @discardableResult
    func setCam(_ h: Host, _ cam: Cam) -> Bool {
        guard let v = pageView(h.view) else { return false }
        for g in v.gestureRecognizers {
            guard let t = g.target else { continue }
            var mirror: Mirror? = Mirror(reflecting: t)
            while let mm = mirror {
                if let c = mm.children.first(where: { $0.label == "cameraModel" })?.value as? OrbitCameraModel {
                    var cc = c.camera
                    cc.setOrientation(azimuth: cam.azimuth, elevation: cam.elevation)
                    c.adopt(cc)
                    pump(1.5)
                    return true
                }
                mirror = mm.superclassMirror
            }
        }
        return false
    }

    /// His pad on the Flexible stage, hosted, the lattice built, img1's camera.
    func flexibleStage(_ size: CGSize) throws -> (ProjectModel, Host, FlexibleMainStage, FlexibleStageModel, UUID) {
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        try FlexiblePressFixtures.enterLatticeStage(r.project, click: { click(h, $0) })   // ★ SYNC #354 (89af86dd): no forward buttons since B5 — the ● Topology menu's lattice row
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        let m = try XCTUnwrap(s.model, "the stage's model")
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        XCTAssertTrue(pumpUntil(420) { m.sceneState == .ready && !m.latticeBuilding && !m.readiness.designing && !m.designsInFlight && m.lattice != nil },
                      "premise: his lattice is built")
        pump(2)
        XCTAssertTrue(setCam(h, Self.img1), "premise: img1's camera")
        return (p, h, s, m, c)
    }

    func legend(_ s: FlexibleMainStage, _ v: CGSize) -> CGRect? {
        s.legendCard(viewport: v, bottomClearance: FlexibleChromeLayout.barClearance, chipColumnWidth: 0)?.frame
    }

    func run(_ tag: String, _ size: CGSize) throws {
        let (p, h, s, _, c) = try flexibleStage(size)
        let mesh = try XCTUnwrap(p.viewerMesh)
        let r3 = LatticeSelectableRef.face(group: c, face: 3)
        var log: [String] = []

        // H1 — "Lattice ready" beside the icons
        s.note.seconds = 60
        s.note.post(.ready)
        pump(1.2)
        let row = try XCTUnwrap(h.frames.all["mainViews"], "\(tag): the views row")
        if let note = h.frames.all["mainNote"], note.width > 0 {
            XCTAssertLessThan(note.minY, row.maxY, "★ H1 \(tag): the note on the row's line, never under the icons (\(note) vs \(row))")
            XCTAssertFalse(note.intersects(row), "★ H1 \(tag): off the icons")
            for (k, f) in [("the capsule", h.frames.all["capsule"]), ("the legend", legend(s, size)), ("the Selections list", h.frames.all["selectionsList"])] {
                if let f { XCTAssertFalse(note.intersects(f), "★ H1 \(tag): the note is not on \(k) (\(note) vs \(f))") }
            }
            log.append("note \(note) row \(row)")
        } else {
            XCTFail("★ H1 \(tag): the note's frame ('mainNote') — the note as drawn")
        }
        s.note.clear()
        pump(0.6)

        // H2 — one card at a time, live
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        // where the chip goes, frame by frame, until it has stayed put 0.6 s (the list grows as Group C opens under the pick)
        let t0 = Date()
        var track: [String] = []
        var last: CGRect?, still = Date()
        while Date().timeIntervalSince(t0) < 6 {
            pump(0.05)
            let f = h.frames.all["faceChip"]
            if f != last { track.append(String(format: "%.3f %@", Date().timeIntervalSince1970, f.map { "\($0)" } ?? "none")); last = f; still = Date() }
            if f != nil, Date().timeIntervalSince(still) > 0.6 { break }
        }
        log.append("chip track t0 \(t0.timeIntervalSince1970) \(track) list \(String(describing: h.frames.all["selectionsList"]))")
        let chipM = try XCTUnwrap(h.frames.all["faceChip"], "premise \(tag): chip M")
        // the chip's automatic spot keeps off D1's chrome and D2's list (★ the mini in portrait: nothing is clear of the list's
        // whole column there — the list as drawn decides; RED at 0e66bf47: the chip fell back onto the views row)
        for (k, key) in [("the views row", "mainViews"), ("the capsule", "capsule"), ("the Setup chip", "setupChip"),
                         ("the Lattice button", "latticeSplit"), ("the Selections list", "selectionsList")] {
            if let f = h.frames.all[key] {
                let handles = h.frames.all.filter { $0.key.hasPrefix("numberBox-handle-") }.map { "\($0.key) \($0.value)" }
                XCTAssertFalse(chipM.intersects(f), "★ H2 \(tag): chip M is not on \(k) (\(chipM) vs \(f); handles \(handles))")
            }
        }
        if let l = legend(s, size) { XCTAssertFalse(chipM.intersects(l), "★ H2 \(tag): chip M is not on the legend") }
        XCTAssertFalse(chipM.intersects(FlexibleLegendPlacement.gizmoFrame(viewport: size)), "★ H2 \(tag): chip M is not on the cube")
        log.append("chip M \(chipM)")
        let pick = s.facePick
        let prisms = s.volumes(p, on: .lattice, drilledIn: false).count
        try press(h, "setupChip", "the Setup chip")
        pump(0.6)
        XCTAssertNotNil(h.frames.all["setupTray"], "\(tag): the tray")
        XCTAssertNil(h.frames.all["faceChip"], "★ H2 \(tag): the tray folds the chip")
        XCTAssertEqual(s.facePick, pick, "★ H2 \(tag): the pick stays")
        XCTAssertEqual(s.volumes(p, on: .lattice, drilledIn: false).count, prisms, "★ H2 \(tag): its prisms stay")
        if let tray = h.frames.all["setupTray"], let l = legend(s, size) { XCTAssertFalse(tray.intersects(l), "★ H4 \(tag): the tray is not on the legend (\(tray) vs \(l))") }
        s.tapFace(p, face: 5, point: nil, mesh: mesh)
        pump(1.2)
        XCTAssertNil(h.frames.all["setupTray"], "★ H2 \(tag): a face tap folds the tray")
        XCTAssertNotNil(h.frames.all["faceChip"], "★ H2 \(tag): the chip is back")
        try press(h, "latticeMore", "the ⌃")
        pump(1.0)
        let card = try XCTUnwrap(h.frames.all["latticeCard"], "\(tag): the card")
        XCTAssertNil(h.frames.all["faceChip"], "★ H2 \(tag): the card folds the chip")
        if let l = legend(s, size) { XCTAssertFalse(card.intersects(l), "★ H4 \(tag): the card is not on the legend (\(card) vs \(l))") }
        let r5 = LatticeSelectableRef.face(group: c, face: 5)
        try press(h, "numberBox-list-depth-\(r5.key)", "Face 5's depth box in the list")
        XCTAssertEqual(s.faceUI.padTarget, "list-depth-\(r5.key)", "premise \(tag): the box's keypad")
        pump(0.6)
        XCTAssertEqual(s.chrome.open, .keypad, "★ H2 \(tag): the keypad is the one card")
        XCTAssertNil(h.frames.all["latticeCard"], "★ H2 \(tag): the keypad folds the card")
        s.faceUI.padTarget = nil
        pump(0.6)

        // H3 — the minimised pill with a chip open
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.0)
        try press(h, "selHeader", "the Selections header (minimise)")
        pump(1.0)
        if let pill = h.frames.all["selectionsList"], let setup = h.frames.all["setupChip"] {
            XCTAssertGreaterThanOrEqual(setup.minX - pill.maxX, PageChrome.gap, "★ H3 \(tag): the minimised pill ≥ 12 pt from the Setup chip (\(pill) vs \(setup))")
            log.append("pill \(pill) setup \(setup)")
        } else { XCTFail("\(tag): the pill and the Setup chip") }
        XCTAssertNotNil(h.frames.all["faceChip"], "\(tag): the chip still open")
        try press(h, "selHeader", "the Selections pill (open)")
        pump(1.0)

        // H2 — chip N (a free face: the tallest chip, with the join; R7-D2's route line went with his 2026-10-18 ruling) keeps
        // off the chrome and the list
        // too (★ found LOOKING at the mini in portrait: no tier was clear and it docked on the cube, the views row and the legend)
        s.pickGroup(c, project: p); pump(0.8)
        s.tapFace(p, face: 2, point: nil, mesh: mesh)
        pump(1.5)
        if let chipN = h.frames.all["faceChip"] {
            for (k, f) in [("the views row", h.frames.all["mainViews"]), ("the capsule", h.frames.all["capsule"]), ("the Setup chip", h.frames.all["setupChip"]),
                           ("the Lattice button", h.frames.all["latticeSplit"]), ("the Selections list", h.frames.all["selectionsList"]),
                           ("the legend", legend(s, size)), ("the cube", FlexibleLegendPlacement.gizmoFrame(viewport: size))] {
                if let f { XCTAssertFalse(chipN.intersects(f), "★ H2 \(tag): chip N is not on \(k) (\(chipN) vs \(f))") }
            }
            log.append("chip N \(chipN)")
        } else { XCTFail("\(tag): chip N") }
        s.missTap(); pump(0.6)

        // H4 — the callout (the main zone on a blocker shows it; here shown as the one card) never on the legend
        s.chrome.show(.callout)
        pump(0.8)
        if let co = h.frames.all["callout"], let l = legend(s, size) { XCTAssertFalse(co.intersects(l), "★ H4 \(tag): the callout is not on the legend") }
        s.chrome.foldAll()
        pump(0.5)

        // H2 — gravity setup: every card folds and the pick goes
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.0)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: r3), "premise \(tag): Face 3 picked")
        try press(h, "setupChip", "the Setup chip")
        pump(0.6)
        try press(h, "setupRow-gravity", "Gravity's [Change]", at: { CGPoint(x: $0.maxX - 36, y: $0.midY) })
        pump(1.2)
        XCTAssertNil(s.chrome.open, "★ H2 \(tag): gravity setup folds every card")
        XCTAssertTrue(s.facePick.scope.isNone, "★ H2 \(tag): … and clears the pick (RED at 0e66bf47)")
        XCTAssertNil(h.frames.all["faceChip"], "★ H2 \(tag): no chip over #354's gravity picker")
        print("FLEX-R7D3-H \(tag) " + log.joined(separator: " · "))
    }

    func test13Portrait() throws { try run("13p", CGSize(width: 1032, height: 1376)) }
    func test13Landscape() throws { try run("13l", CGSize(width: 1376, height: 1032)) }
    func test11Portrait() throws { try run("11p", CGSize(width: 834, height: 1194)) }
    func test11Landscape() throws { try run("11l", CGSize(width: 1194, height: 834)) }
    func testMiniPortrait() throws { try run("minip", CGSize(width: 744, height: 1133)) }
}
#endif
