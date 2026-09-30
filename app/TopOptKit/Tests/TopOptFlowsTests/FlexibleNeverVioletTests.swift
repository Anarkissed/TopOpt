// FlexibleNeverVioletTests — never violet under Flexible (task 2026-09-29-flexible-screens,
// round 3 batch C; the plan's optional recolour, his standing rule "never purple"). Hook H13 in
// #354's WorkspacePlaceholder: the lattice-depth prism's tint and the depth / expand knobs.
// RED CONTROL: #354's own colours there are the violet family.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows

final class FlexibleNeverVioletTests: XCTestCase {

    // MARK: H13 — never violet under Flexible

    func testTheDepthPrismAndKnobsTakeTheFlexibleAccent() throws {
        let green = FlexibleStageStyle.accentToken
        XCTAssertEqual(FlexibleMainTints.depthPlane(.include, flexible: true), SIMD3<Float>(Float(green.r), Float(green.g), Float(green.b)))
        XCTAssertNotNil(FlexibleMainTints.depthPlane(.exclude, flexible: true))
        XCTAssertNil(FlexibleMainTints.depthPlane(.include, flexible: false), "Structural / Aesthetic keep #354's colour")
        XCTAssertNil(FlexibleMainTints.depthPlane(nil, flexible: true), "no role: the clearance red stays")
        let octet = LatticeDensityProxy.densityColor(fraction: 0.6)
        XCTAssertEqual(FlexibleMainTints.knob(flexible: true, octet), green)
        XCTAssertEqual(FlexibleMainTints.knob(flexible: false, octet), octet)
        for c in [FlexibleMainTints.knob(flexible: true, octet), DS.Color.textQuaternary] {
            let h = FlexibleShownValuesTests.hueSat(c)
            XCTAssertFalse(h.s > 0.15 && h.h >= 240 && h.h <= 330, "under Flexible: no violet / indigo / purple")
        }
        // ★ RED CONTROL: the octet's depth knob and include-volume colours ARE the violet family
        // (the expand knob's 0.25 stop is a pale lavender-blue, hue 232°, and is replaced too)
        for c in [octet, RGBA(124, 111, 214)] {
            let h = FlexibleShownValuesTests.hueSat(c)
            XCTAssertTrue(h.s > 0.15 && h.h >= 240 && h.h <= 330, "control: #354's colour is violet (hue \(Int(h.h))°)")
        }
        let ws = try FlexibleSource.text("WorkspacePlaceholder.swift")
        XCTAssertEqual(ws.components(separatedBy: "if let t = FlexibleMainTints.depthPlane(role, flexible: project.lattice.flexible != nil) { return t }").count - 1, 1)
        XCTAssertEqual(ws.components(separatedBy: "FlexibleMainTints.knob(flexible: project.lattice.flexible != nil, LatticeDensityProxy.densityColor(fraction: ").count - 1, 2,
                       "both knobs (depth, expand)")
    }
}
