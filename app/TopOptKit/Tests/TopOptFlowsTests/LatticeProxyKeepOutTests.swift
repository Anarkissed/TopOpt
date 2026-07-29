// V4 — the lattice-proxy legend does not fight the PR-217 keep-out system or the
// gizmo. Driven through the real KeepOutSolver with a BUSY scene (transform gizmo,
// settings chips, a clearance knob) plus the legend, asserting the legend floats
// clear and never displaces a rigid control. Pure engine, headless (PR-217's own
// verification standard).

import XCTest
import CoreGraphics
@testable import TopOptFlows

final class LatticeProxyKeepOutTests: XCTestCase {

    private func rectsOverlap(_ aC: CGPoint, _ aS: CGSize, _ bC: CGPoint, _ bS: CGSize) -> Bool {
        let a = CGRect(x: aC.x - aS.width / 2, y: aC.y - aS.height / 2, width: aS.width, height: aS.height)
        let b = CGRect(x: bC.x - bS.width / 2, y: bC.y - bS.height / 2, width: bS.width, height: bS.height)
        return a.intersects(b)
    }

    /// In a busy scene, the legend is placed so its home anchor overlaps the gizmo;
    /// the pass must move the LEGEND (not the gizmo) until they no longer overlap.
    func testLegendFloatsClearOfGizmoInBusyScene() {
        let viewport = CGSize(width: 1024, height: 1366)
        let gizmoCenter = CGPoint(x: 512, y: 640)
        let gizmoSize = CGSize(width: 330, height: 330)          // the big transform gizmo box

        // A busy scene: rigid gizmo + two rigid chips + a movable clearance knob, and
        // the legend anchored right ON the gizmo so it is forced to resolve.
        let elements: [KeepOutElement] = [
            KeepOutElement(id: "gizmo.transform", anchor: gizmoCenter, bounds: gizmoSize,
                           touch: gizmoSize, priority: .gizmo),
            KeepOutElement(id: "chrome.orientationGizmo", anchor: CGPoint(x: 950, y: 90),
                           bounds: CGSize(width: 96, height: 96), touch: CGSize(width: 96, height: 96),
                           priority: .chrome),
            KeepOutElement(id: "clr.knob.a", anchor: CGPoint(x: 560, y: 690),
                           bounds: CGSize(width: 44, height: 44), touch: CGSize(width: 60, height: 60),
                           priority: .handle),
            LatticeProxyLayout.keepOutElement(anchor: gizmoCenter),   // wants to sit on the gizmo
        ]

        let placements = KeepOutSolver.resolve(elements, viewport: viewport)
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })

        let gizmo = byID["gizmo.transform"]!
        let legend = byID["lattice.legend"]!

        // The gizmo (rigid) did not move.
        XCTAssertEqual(gizmo.center, gizmoCenter)
        // The legend is NOT hidden and no longer overlaps the gizmo's touch rect.
        XCTAssertFalse(legend.hidden)
        XCTAssertFalse(rectsOverlap(legend.center, LatticeProxyLayout.panelSize, gizmoCenter, gizmoSize),
                       "legend must float clear of the gizmo")
        // It moved off its anchor to do so (it yielded, the gizmo did not).
        XCTAssertGreaterThan(legend.displacementLength, 0)
    }

    /// The legend clears the whole busy set — it overlaps NONE of the other elements
    /// after the pass (touch-rect disjoint).
    func testLegendClearsEveryControl() {
        let viewport = CGSize(width: 1024, height: 1366)
        let others: [KeepOutElement] = [
            KeepOutElement(id: "gizmo.transform", anchor: CGPoint(x: 400, y: 500),
                           bounds: CGSize(width: 300, height: 300), touch: CGSize(width: 300, height: 300),
                           priority: .gizmo),
            KeepOutElement(id: "load.pill", anchor: CGPoint(x: 300, y: 420),
                           bounds: CGSize(width: 120, height: 40), touch: CGSize(width: 120, height: 40),
                           priority: .pill),
        ]
        let legend = LatticeProxyLayout.keepOutElement(anchor: CGPoint(x: 380, y: 470))
        let placements = KeepOutSolver.resolve(others + [legend], viewport: viewport)
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        let legendP = byID["lattice.legend"]!
        for o in others {
            let op = byID[o.id]!
            XCTAssertFalse(rectsOverlap(legendP.center, LatticeProxyLayout.panelSize, op.center, o.touch),
                           "legend overlaps \(o.id)")
        }
    }

    /// The legend never has enough priority to move a rigid control: it is a `.label`,
    /// strictly below `.handle`/`.pill`/`.gizmo`/`.chrome`.
    func testLegendPriorityIsLowest() {
        XCTAssertEqual(LatticeProxyLayout.keepOutElement(anchor: .zero).priority, .label)
        XCTAssertLessThan(KeepOutPriority.label, KeepOutPriority.handle)
        XCTAssertLessThan(KeepOutPriority.label, KeepOutPriority.gizmo)
    }
}
