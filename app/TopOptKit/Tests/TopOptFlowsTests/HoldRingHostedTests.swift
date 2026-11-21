// HoldRingHostedTests — B2, round 1 (design-system §4.2: "A 3-second hold fills a ring round the button; its release is not
// also a tap").
//
// On the Lattice stage, a real press held on Lattice preview shows the ring round the button while it is held, and a release
// before 3 s takes it away. RED control: today's hold (no ring). Plus the panel accordion's rule (R2.1).
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class HoldRingHostedTests: XCTestCase {

    func press(_ h: AppBuildHost, _ f: CGRect, _ t: NSEvent.EventType) {
        let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: f.midX, y: h.size.height - f.midY), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: h.window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        h.window.sendEvent(e)
    }

    func lattice(_ size: CGSize) throws -> AppBuildHost {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: false)
        let p = r.project
        p.lattice.flexible = nil
        p.lattice.chooseLatticeType(.structural)
        let h = AppBuildHost(WorkspacePlaceholder(model: r.app, project: p), size: size, test: self)
        h.pump(3)
        try h.pickFromMenu("capsuleMenu", "Structural", what: "the stage menu")
        h.pump(1)
        return h
    }

    func testAHeldViewButtonFillsItsRing() throws {
        addTeardownBlock { @MainActor in HoldRing.controlOff = false }
        // ★ RED CONTROL: today's hold — no ring
        HoldRing.controlOff = true
        let hc = try lattice(AppBuildHost.landscape13)
        let bc = try hc.onScreen("view-Lattice preview", "the control: Lattice preview")
        press(hc, bc, .leftMouseDown); hc.pump(1)
        XCTAssertNil(hc.frames.all["holdRing"], "the control: no ring")
        press(hc, bc, .leftMouseUp); hc.pump(0.5)
        HoldRing.controlOff = false

        for size in [AppBuildHost.landscape13, AppBuildHost.portrait13] {
            let h = try lattice(size)
            let b = try h.onScreen("view-Lattice preview", "\(size): Lattice preview")
            press(h, b, .leftMouseDown); h.pump(1)
            let ring = try h.onScreen("holdRing", "\(size): ★ the ring, while it is held")
            XCTAssertEqual(ring.midX, b.midX, accuracy: 1, "\(size): round the button")
            XCTAssertEqual(ring.midY, b.midY, accuracy: 1)
            XCTAssertGreaterThan(ring.width, b.width, "\(size): outside its edge")
            press(h, b, .leftMouseUp); h.pump(0.5)
            XCTAssertNil(h.frames.all["holdRing"], "\(size): released before 3 s, the ring goes")
        }
    }
}

/// The accordion (R2.1, §4.3): opening one panel folds the other.
final class PanelAccordionTests: XCTestCase {
    func testOpeningOnePanelFoldsTheOther() {
        var a = PanelAccordion()
        XCTAssertTrue(a.isOpen(.selections), "the Topology panel sits on top, closed by default")
        XCTAssertFalse(a.isOpen(.topology))
        a.tap(.topology)
        XCTAssertTrue(a.isOpen(.topology)); XCTAssertFalse(a.isOpen(.selections), "★ opening Topology folds Selections")
        a.tap(.selections)
        XCTAssertTrue(a.isOpen(.selections)); XCTAssertFalse(a.isOpen(.topology), "★ and the other way round")
        a.tap(.selections)
        XCTAssertNil(a.open, "a tap on the open one folds it")
    }
}
#endif
