// FlexibleLatticeIsProtectedHostedTests — round 7, HIS RULING of 2026-10-18 ("We do not want any lattices to be affected by
// topology optimization. This is why I set it within 'protect' in the first place. These two things should behave the same
// way."), the hosted half of FlexibleLatticeIsProtectedTests: the WHOLE app page (WorkspacePlaceholder) offscreen on HIS pad
// (A1_0003 + his live lattice: Group C = Face 3 + Face 5 at 25 mm), the lattice built, 13" portrait. A tap on Face 2 (no group
// holds it) opens chip N; a CLICK on its [▦ Lattice] makes a group of Face 2 — Lattice, Protect underneath — and the chip
// stays on Face 2 as that group's face. Written BEFORE the code (red run: round7/batch_lp/lp_red_run.txt — R7-D2's greyed,
// disabled button: the click made nothing).
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

private final class LPHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleLatticeIsProtectedHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

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
        let w = LPHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func testTheChipsLatticeButtonMakesAProtectedLatticeGroup() throws {
        let size = CGSize(width: 1032, height: 1376)
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        _ = try FlexibleR7M1Fixtures.hisLiveLattice(p)
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
        let mesh = try XCTUnwrap(p.viewerMesh)
        let groupsBefore = Set(p.selection.groups.map(\.id))

        // Face 2: no group holds it → chip N
        s.tapFace(p, face: 2, point: nil, mesh: mesh)
        pump(1.5)
        XCTAssertEqual(s.facePick.scope, .pending([.face(2)]), "premise: Face 2 is a new face")
        let chipN = try XCTUnwrap(h.frames.all["faceChip"], "premise: chip N is drawn")
        let button = try XCTUnwrap(h.frames.all["chipNew-lattice"], "chip N's [▦ Lattice]")
        XCTAssertTrue(chipN.contains(CGPoint(x: button.midX, y: button.midY)), "the button sits in the chip")
        click(h, CGPoint(x: button.midX, y: button.midY))
        pump(1.5)

        let made = p.selection.groups.filter { !groupsBefore.contains($0.id) }
        XCTAssertEqual(made.count, 1, "★ a click on [▦ Lattice] makes ONE group (R7-D2's greyed button made none)")
        let g = try XCTUnwrap(made.first)
        XCTAssertTrue(g.faces.contains(2), "it holds Face 2")
        XCTAssertTrue(p.force.isProtected(g.id), "★ Protect underneath — Topology never touches this lattice")
        XCTAssertEqual(p.latticeSelectableRole(.face(group: g.id, face: 2), in: g.id), .include, "★ Face 2 is Lattice")
        XCTAssertTrue(FlexibleFaceCommits.readsLattice(g.id, p), "★ the group reads Lattice")
        XCTAssertTrue(p.force.canOptimize(in: p.selection.groups, minimizePlastic: p.minimizePlastic,
                                          latticeRoleGroups: Set(p.latticeEligibleRoles().keys)), "★ Topology's Optimize is not blocked")
        XCTAssertEqual(s.facePick.scope, .face(group: g.id, ref: .face(group: g.id, face: 2)), "★ the chip stays, on the new group's face")
        XCTAssertNotNil(h.frames.all["faceChip"], "the chip is still drawn")
        XCTAssertNil(h.frames.all["chipNew-lattice"], "chip N is gone (chip M now)")
        print("FLEX-LP-H chipN \(chipN) button \(button) group \(g.name) protected \(p.force.isProtected(g.id)) chip \(String(describing: h.frames.all["faceChip"]))")
    }
}
#endif
