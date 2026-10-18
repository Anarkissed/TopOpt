// FlexibleR7E1FollowUpHostedTests — round 7, batch R7-E1, follow-up (1), the hosted half: HIS ANSWER of 2026-10-18 ~15:50
// ("On a Lattice group, Protect is LOCKED ON while any face of the group is Lattice"). The WHOLE app page offscreen on HIS pad
// (A1_0003 + his live lattice: Group C = Face 3 + Face 5, Protect + Lattice 25 mm), 13" portrait: a tap on Face 3 opens chip
// M for Group C; a click on its role capsule opens the role line; [Protect] is lit and carries the lock; a CLICK on it leaves
// Protect on and shows the one line "Protect stays on while a face is Lattice". Written BEFORE the code (red run:
// round7/batch_e1/e1a_red_run.txt).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class PLHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleR7E1FollowUpHostedTests: XCTestCase {
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = PLHostWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
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

    func testTheChipsProtectStaysOnWhileAFaceIsLattice() throws {
        let size = CGSize(width: 1032, height: 1376)
        Bundle.r7m1vSwap
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        let c = try FlexibleR7M1Fixtures.hisLiveLattice(p)
        let h = host(WorkspacePlaceholder(model: r.app, project: p), size: size)
        pump(4)
        click(h, CGPoint(x: size.width - PageChrome.gizmoClearance - 62, y: PageChrome.gizmoAlignedTop + PageChrome.compactButton / 2))
        pump(3)
        let s = try XCTUnwrap(FlexibleMainStage.lastMade, "the page's stage")
        if let m = s.model { addTeardownBlock { @MainActor in await m.waitForIdle() } }
        XCTAssertNotNil(h.frames.all["capsule"], "premise: the Flexible stage")
        let mesh = try XCTUnwrap(p.viewerMesh)
        s.tapFace(p, face: 3, point: nil, mesh: mesh)
        pump(1.5)
        XCTAssertEqual(s.facePick.scope, .face(group: c, ref: .face(group: c, face: 3)), "premise: chip M for Group C's Face 3")
        let capsule = try XCTUnwrap(h.frames.all["chipRole"], "the role capsule")
        click(h, CGPoint(x: capsule.midX, y: capsule.midY))
        pump(1)
        let protect = try XCTUnwrap(h.frames.all["chipRole-protect"], "the role line's [Protect]")
        XCTAssertNotNil(h.frames.all["chipRole-protect-lock"], "★ [Protect] carries the lock while a face is Lattice")
        XCTAssertGreaterThanOrEqual(min(protect.width, protect.height), 44, "a 44 pt target")
        click(h, CGPoint(x: protect.midX, y: protect.midY))
        pump(1)
        XCTAssertTrue(p.force.isProtected(c), "★ a click on [Protect] leaves Protect ON (the lattice is never exposed to Topology)")
        XCTAssertTrue(FlexibleFaceCommits.readsLattice(c, p), "the group still reads Lattice")
        let line = try XCTUnwrap(h.frames.all["chipProtectLocked"], "★ the one line says why")
        XCTAssertLessThanOrEqual(line.height, 44, "one line")
        print("FLEX-E1-PL-H capsule \(capsule) protect \(protect) line \(line) protected \(p.force.isProtected(c))")
    }
}
#endif
