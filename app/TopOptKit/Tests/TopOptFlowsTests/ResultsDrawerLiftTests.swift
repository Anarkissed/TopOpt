// ResultsDrawerLiftTests — LOOK PER SCREEN, Results (mockup #topo-results-details: "The model moved up so the whole part stays
// in view (the drawer never covers it)"). Opening Details lifts the model into the page above the drawer: the camera draws its
// picture scaled into the uncovered part of the page (OrbitCamera.frameLift, folded into projectionMatrix, so the renderer,
// picking, `project` and `ray` all agree), and closing it puts the picture back. RED before (scratchpad
// b2red/ResultsDrawerLift.txt): no frameLift; the drawer covered the lower part of the model.
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsDrawerLiftTests: XCTestCase {

    func camera() -> OrbitCamera {
        var c = OrbitCamera()
        c.frame(MeshBounds(min: SIMD3<Float>(-50, -50, -10), max: SIMD3<Float>(50, 50, 10), isEmpty: false))
        return c
    }

    func testNoLiftIsTodaysPicture() {
        let c = camera()
        var l = c; l.frameLift = 0
        XCTAssertEqual(c.projectionMatrix(aspect: 1.3), l.projectionMatrix(aspect: 1.3), "★ 0 changes nothing")
    }

    /// The part's middle moves to the middle of the page above the drawer, scaled to that height.
    func testTheLiftPutsThePictureAboveTheDrawer() throws {
        let size = CGSize(width: 1376, height: 1032)
        var c = camera()
        let mid = try XCTUnwrap(CameraProjection(camera: c, viewportSize: size).project(c.target))
        XCTAssertEqual(mid.y, size.height / 2, accuracy: 1, "premise: centred")
        let f: Float = 0.4
        c.frameLift = f
        let p = CameraProjection(camera: c, viewportSize: size)
        let lifted = try XCTUnwrap(p.project(c.target))
        XCTAssertEqual(lifted.y, size.height * CGFloat(1 - f) / 2, accuracy: 1, "★ the middle of the page above the drawer")
        XCTAssertEqual(lifted.x, size.width / 2, accuracy: 1, "still centred across")
        // the way back: a tap there is the ray through the same point
        let corner = c.target + SIMD3<Float>(50, 50, 10)
        let s = try XCTUnwrap(p.project(corner))
        let ray = try XCTUnwrap(p.ray(throughViewPoint: s))
        let back = simd_normalize(corner - ray.origin)
        XCTAssertEqual(simd_dot(back, ray.dir), 1, accuracy: 1e-4, "★ picking agrees with the lifted picture")
    }

    /// Opening Details lifts the model by the drawer's share of the page; closing it puts it back.
    func testDetailsLiftsTheModelAndCloseLowersIt() throws {
        var lifts: [Float] = []
        ResultsScreen.frameLiftProbe = { lifts.append($0) }
        addTeardownBlock { @MainActor in ResultsScreen.frameLiftProbe = nil }
        let r = ResultsRedesignHostedTests()
        let size = CGSize(width: 1376, height: 1032)
        let (h, _) = try r.screen(size)
        let button = try r.frame(h, "resultsDetailsButton")
        r.ui.click(h, CGPoint(x: button.midX, y: button.midY))
        r.ui.pump(0.6)
        let drawer = try r.frame(h, "resultsDetailsPanel")
        let up = try XCTUnwrap(lifts.last, "★ the model was lifted")
        XCTAssertEqual(CGFloat(up), drawer.height / size.height, accuracy: 0.02, "★ by the drawer's share of the page")
        let close = try r.frame(h, "resultsDetailsClose")
        r.ui.click(h, CGPoint(x: close.midX, y: close.midY))
        r.ui.pump(0.6)
        XCTAssertEqual(lifts.last, 0, "★ closed: the model comes back down")
    }
}
#endif
