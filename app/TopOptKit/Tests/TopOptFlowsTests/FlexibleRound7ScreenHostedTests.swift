// FlexibleRound7ScreenHostedTests — round 7, batch R7-D1, the hosted half (offscreen, never the app), on HIS pad (A1_0003,
// FlexiblePressFixtures.a1Project(3, self): Bottom anchors, Top carries 22 lb, Group C's Face 3 + Face 5 face-prisms) with
// the WHOLE app page hosted (WorkspacePlaceholder), so the hooks put what they mount where the layout says.
//
// His pick 1 (2026-10-14): "I like A2 but with the corner pair from A1 on the main Lattice screen". His answers: Optimize
// and the iPad/Mac chip DROPPED on this stage; "Settings" is "Squish"; the Squish page NEVER opens by itself.
//   S1  on the Flexible stage: the capsule (● Flexible ⌄ | Lattice | Squish) under the name, the views row, the corner
//       pair (today's [‹ Topology][Surface], Settings, chip column, iPad chip, Print Parameters, pill and Optimize are gone
//       by the hooks — FlexibleRound7ScreenHookTests — and the pictures); the Squish page did not open by itself (H37);
//       measured frames = FlexibleChromeLayout within 1 pt.
//   S2  the Setup chip opens the tray (four rows) right-aligned 12 above the pair; the ⌃ opens the card and folds the
//       tray (one card at a time); the card holds Preview, Core, Export and nothing named Optimize.
//   S3  the capsule's Squish opens the Squish page, which wears the same capsule (Squish lit) at (24, 76).
//   S4  at 11" portrait the Squish page's notice band and its panel's top clear the capsule. RED CONTROL: the old
//       exitRow-only keep-out (the band lands on the capsule).
//   S5  the views row's order: Heat, Stress, X-ray, Lattice, Prisms, Play (the mockup's), 44 pt each. RED CONTROL: R7-V's.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class R7D1HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleRound7ScreenHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:]; var said: [String] = [] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    override func tearDown() {
        FlexibleStagePage.controlExitRowOnlyKeepOut = false
        FlexibleMainViewToggles.controlR7VOrder = false
        FlexibleSaid.recording = false
        super.tearDown()
    }

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
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }
            .onPreferenceChange(FlexibleSaidKey.self) { frames.said = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = R7D1HostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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
        let loc = NSPoint(x: p.x, y: h.size.height - p.y)
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            h.window.sendEvent(e)
            pump(0.06)
        }
        pump(0.6)
    }
    /// A frame the page published (FlexibleKeepOutKey), in the window's own coordinates. (A test process builds no
    /// accessibility tree for SwiftUI on macOS, so the new views publish their frames, as every hosted Flexible test reads.)
    func frame(_ h: Host, _ key: String) -> CGRect? {
        guard let f = h.frames.all[key], f.width > 0 else { return nil }
        return f
    }
    func press(_ h: Host, _ key: String) -> Bool {
        guard let f = frame(h, key) else { return false }
        click(h, CGPoint(x: f.midX, y: f.midY))
        return true
    }
    static func close(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// His pad, the whole app page, on the Flexible stage (Topology's top-right Lattice button).
    func flexibleStage(_ size: CGSize) throws -> (Host, FlexibleHisProject.Restored) {
        let r = try FlexiblePressFixtures.a1Project(3, self)
        let h = host(WorkspacePlaceholder(model: r.app, project: r.project), size: size)
        pump(3)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(3)
        if let s = FlexibleMainStage.lastMade { addTeardownBlock { @MainActor in await s.model?.waitForIdle() } }
        return (h, r)
    }

    // MARK: - S1 + S2 + S3

    func testTheFlexibleStageWearsTheCapsuleTheViewsAndTheCornerPair() throws {
        var report: [String] = []
        FlexibleSaid.recording = true
        for (tag, size) in [("13p", CGSize(width: 1032, height: 1376)), ("11p", CGSize(width: 834, height: 1194))] {
            let (h, _) = try flexibleStage(size)
            XCTAssertNil(h.frames.all["exitRow"], "★ \(tag): the Squish page did not open by itself (H37)")
            for key in ["capsule", "capsuleMenu", "capsuleLattice", "capsuleSquish", "setupChip", "latticeSplit", "latticeMain", "latticeMore", "mainViews"] {
                XCTAssertNotNil(frame(h, key), "★ \(tag): \(key) is drawn")
            }
            // the frames
            let cap = try XCTUnwrap(frame(h, "capsule"), "\(tag): the capsule's frame")
            XCTAssertEqual(cap.minX, FlexibleChromeLayout.capsuleLeft, accuracy: 1, tag)
            XCTAssertEqual(cap.minY, FlexibleChromeLayout.capsuleTop, accuracy: 1, tag)
            XCTAssertEqual(cap.height, FlexibleChromeLayout.capsuleHeight, accuracy: 1, tag)
            XCTAssertLessThanOrEqual(cap.width, FlexibleChromeLayout.capsuleMaxWidth + 1, tag)
            let setup = try XCTUnwrap(frame(h, "setupChip")), lat = try XCTUnwrap(frame(h, "latticeSplit"))
            let want = FlexibleChromeLayout.pair(viewport: size, setupWidth: setup.width)
            XCTAssertTrue(Self.close(setup, want.setup), "\(tag): the Setup chip \(setup) ≈ \(want.setup)")
            XCTAssertTrue(Self.close(lat, want.lattice), "\(tag): the Lattice split \(lat) ≈ \(want.lattice)")
            let row = try XCTUnwrap(frame(h, "mainViews"))
            XCTAssertTrue(Self.close(row, FlexibleChromeLayout.viewsRow(viewport: size)), "\(tag): the views row \(row) ≈ \(FlexibleChromeLayout.viewsRow(viewport: size))")
            report.append("\(tag): capsule \(cap) · setup \(setup) · lattice \(lat) · views \(row)")
            // S2: the tray, then the card (one at a time)
            XCTAssertTrue(press(h, "setupChip"), "\(tag): the Setup chip")
            let tray = try XCTUnwrap(frame(h, "setupTray"), "★ \(tag): the tray opens")
            XCTAssertEqual(tray.maxX, size.width - 24, accuracy: 1, "\(tag): right-aligned on 24")
            XCTAssertEqual(tray.maxY, want.lattice.minY - 12, accuracy: 1, "\(tag): 12 above the pair")
            XCTAssertEqual(tray.width, FlexibleChromeLayout.panelWidth(size), accuracy: 1, tag)
            for r in ["setupRow-quality", "setupRow-plateUp", "setupRow-gravity", "setupRow-printParameters"] {
                XCTAssertNotNil(frame(h, r), "\(tag): the tray's \(r)")
            }
            XCTAssertEqual(h.frames.all.keys.filter { $0.hasPrefix("setupRow-") }.count, 4, "\(tag): exactly four rows")
            XCTAssertTrue(press(h, "latticeMore"), "\(tag): the ⌃")
            XCTAssertNotNil(frame(h, "latticeCard"), "★ \(tag): the card opens")
            XCTAssertNil(frame(h, "setupTray"), "★ \(tag): … and the tray folded (one card at a time)")
            XCTAssertEqual(h.frames.all.keys.filter { $0.hasPrefix("cardStep-") }.sorted(), ["cardStep-core", "cardStep-export", "cardStep-preview"],
                           "\(tag): three steps")
            XCTAssertFalse(h.frames.said.contains { $0.localizedCaseInsensitiveContains("optimize") }, "★ \(tag): nothing says Optimize")
            // S3: the capsule's Squish → the Squish page with the same capsule
            XCTAssertTrue(press(h, "capsuleSquish"), "\(tag): Squish")
            XCTAssertTrue(pumpUntil(10) { h.frames.all["exitRow"] != nil }, "★ \(tag): the Squish page opens")
            XCTAssertNil(frame(h, "latticeCard"), "\(tag): the card folded as the page opened")
            let sq = try XCTUnwrap(frame(h, "capsule"), "★ \(tag): the Squish page wears the capsule")
            let page = h.frames.all["page"] ?? .zero
            XCTAssertEqual(sq.minX - page.minX, 24, accuracy: 1, tag)
            XCTAssertEqual(sq.minY - page.minY, 76, accuracy: 1, tag)
            report.append("\(tag): tray \(tray) · Squish page capsule \(sq)")
            h.window.orderOut(nil)
        }
        print("FLEX-R7D1-HOSTED-S1 " + report.joined(separator: " | "))
    }

    // MARK: - S4: the Squish page's notice band clears the capsule at 11" portrait

    func testOnTheSquishPageTheNoticeBandAndThePanelClearTheCapsule() throws {
        var report: [String] = []
        for control in [false, true] {
            FlexibleStagePage.controlExitRowOnlyKeepOut = control
            let stage = FlexibleMainStage()
            let r = try FlexiblePressFixtures.a1Project(3, self)
            let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
            addTeardownBlock { @MainActor in await m.waitForIdle() }
            m.openScene()
            _ = pumpUntil(120) { m.sceneState == .ready }
            let size = CGSize(width: 834, height: 1194)
            let h = host(FlexibleStagePage(project: r.project, model: m, onLeave: { _ in }, onAbout: {}, onExit: {}), size: size)
            pump(2.5)
            let page = h.frames.all["page"] ?? .zero
            let cap = try XCTUnwrap(h.frames.all["capsule"], "the capsule").offsetBy(dx: -page.minX, dy: -page.minY)
            let notice = try XCTUnwrap(h.frames.all["notice"], "the top line").offsetBy(dx: -page.minX, dy: -page.minY)
            let panel = h.frames.all["panel"].map { $0.offsetBy(dx: -page.minX, dy: -page.minY) }
            report.append("\(control ? "control" : "now"): capsule \(cap) · notice \(notice) · panel \(panel.map { "\($0)" } ?? "none")")
            if control {
                XCTAssertTrue(notice.intersects(cap), "★ RED CONTROL: the exitRow-only band lands on the capsule")
            } else {
                XCTAssertFalse(notice.intersects(cap), "★ the top line clears the capsule (\(notice) vs \(cap))")
                XCTAssertGreaterThanOrEqual(notice.minY, cap.maxY + 12 - 0.5, "★ … one gap below it")
                if let p = panel { XCTAssertGreaterThanOrEqual(p.minY, cap.maxY, "★ the panel's top clears the capsule") }
            }
            h.window.orderOut(nil)
        }
        print("FLEX-R7D1-HOSTED-S4 " + report.joined(separator: " | "))
    }

    // MARK: - S5: the views row's order and size

    func testTheViewsRowIsHeatStressXrayLatticePrismsPlay() {
        XCTAssertEqual(FlexibleMainViewToggles.order, [.heat, .stress, .xray, .lattice, .prisms, .play], "the mockup's order")
        FlexibleMainViewToggles.controlR7VOrder = true
        XCTAssertEqual(FlexibleMainViewToggles.order, [.heat, .stress, .lattice, .prisms, .xray, .play], "★ RED CONTROL: R7-V's order")
        FlexibleMainViewToggles.controlR7VOrder = false
        XCTAssertEqual(FlexibleViewButton.side, 44, "44 pt targets (his rule)")
    }
}
#endif
