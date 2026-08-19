// LatticeThicknessAndFloorTests — ★ B2 + B3: THE THICKNESS SLIDER AND THE
// PRINTABILITY FLOOR ACTUALLY REACH THE PREVIEW.
//
// Both were asked for in the same breath (maintainer, 2026-08-19):
//   "there should also be a way to manually override the sim's thickness control
//    to whatever the user sets … Off makes a sliding number value visible;
//    controlling the thickness of the cell on screen"
//   "It should be based on the printing parameters. I have mine set at a 0.42
//    line width, so 0.5-0.95 makes sense. But if I change to a 0.2 nozzle that
//    can change, so I would expect the floor to change with it"
//
// ★ WHAT MAKES THESE WORTH ASSERTING RATHER THAN EYEBALLING. A control that is
// stored but not consumed looks identical on screen to one that is consumed —
// that is precisely how `boundary` sat unread for weeks. These check the value
// arrives at `LatticeProxyParams`, which is what the renderer grades from.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeThicknessAndFloorTests: XCTestCase {

    private var limits: TopOptKit.LatticeLimits { TopOptKit.latticeLimits(topology: "octet") }

    // MARK: - B2 · the hand-set thickness

    func testAManualThicknessPinsTheDensityTheRendererGradesFrom() {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellMM = 2.20
        s.simulateStresses = false
        s.densityMode = .uniform

        let derived = s.proxyParams(limits: limits)
        s.manualStrutThicknessMM = 0.60
        let pinned = s.proxyParams(limits: limits)

        // ★ The band collapses onto the requested thickness — with the sim off
        // there is no field to grade by, so a ramp would be a lie.
        XCTAssertEqual(pinned.minRelativeDensity, pinned.maxRelativeDensity, accuracy: 1e-9,
                       "★ a hand-set thickness is ONE lattice, not a graded band")
        // ★ …and it is the density that law produces for a 0.60 mm strut.
        let expect = LatticeType.octet.relativeDensity(strutRadiusMM: 0.30, cellMM: 2.20)
        XCTAssertEqual(pinned.uniformRelativeDensity, expect, accuracy: 1e-6,
                       "★ the slider's millimetres must convert through the SAME law "
                       + "the renderer inverts, not a second one")
        XCTAssertNotEqual(derived.uniformRelativeDensity, pinned.uniformRelativeDensity,
                          "★ it must actually MOVE the preview")

        // Thicker strut ⇒ denser lattice, monotonically.
        s.manualStrutThicknessMM = 0.80
        XCTAssertGreaterThan(s.proxyParams(limits: limits).uniformRelativeDensity,
                             pinned.uniformRelativeDensity)
    }

    /// ★ AND IT IS IGNORED WHILE THE SIM IS ON — the FEA owns the density then,
    /// and a hand-set number quietly overriding it would be the opposite defect.
    func testTheSimOwnsTheDensityWhenItIsOn() {
        var s = LatticeSettings(enabled: true)
        s.cellMM = 2.20
        s.manualStrutThicknessMM = 0.60
        s.simulateStresses = true
        XCTAssertNil(s.manualThicknessDensity(limits: limits),
                     "★ with the sim on, the hand-set thickness must not bite")
        s.simulateStresses = false
        XCTAssertNotNil(s.manualThicknessDensity(limits: limits))
    }

    /// The slider's range is the printable one, at both ends.
    func testTheSliderCannotAskForAnUnprintableStrut() {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellMM = 2.20
        let r = s.manualThicknessRangeMM(limits: limits, lineWidthMM: 0.42)
        XCTAssertEqual(r.lowerBound, 0.42, accuracy: 1e-9,
                       "★ the thinnest strut is ONE extruded bead")
        // The top is the thickness at core's certifiable ceiling.
        let top = 2 * LatticeType.octet.strutRadiusMM(relativeDensity: limits.rhoMax,
                                                      cellMM: 2.20)
        XCTAssertEqual(r.upperBound, top, accuracy: 1e-9,
                       "★ …and the thickest is core's own density ceiling")
        // A finer nozzle lowers the floor.
        let fine = s.manualThicknessRangeMM(limits: limits, lineWidthMM: 0.20)
        XCTAssertLessThan(fine.lowerBound, r.lowerBound)
    }

    // MARK: - B3 · the density floor follows the printer

    /// ★ THE NUMBERS, ON HIS OWN SETTINGS. His guess of ~0.5 for a 0.42 mm line at
    /// a 2.20 mm cell lands at 43.7%; the one correction is that the law is
    /// QUADRATIC in the width, so a 0.2 mm nozzle gives 9.9%, not the ~0.25 a
    /// linear scaling suggests.
    func testTheFloorFollowsTheLineWidthQuadratically() {
        let o = LatticeType.octet
        XCTAssertEqual(o.printabilityDensityFloor(lineWidthMM: 0.42, cellMM: 2.20),
                       0.4374, accuracy: 0.001, "★ his settings")
        XCTAssertEqual(o.printabilityDensityFloor(lineWidthMM: 0.20, cellMM: 2.20),
                       0.0992, accuracy: 0.001, "★ a 0.2 mm nozzle — quadratic, not linear")
        // A coarser cell prints a much LOWER density — which is why an unloaded
        // wall wants a coarse cell.
        XCTAssertLessThan(o.printabilityDensityFloor(lineWidthMM: 0.42, cellMM: 8.0),
                          o.printabilityDensityFloor(lineWidthMM: 0.42, cellMM: 2.20))
    }

    /// And the floor reaches the BAND the preview grades between.
    func testTheFloorReachesTheBand() {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellMM = 2.20
        s.minRelativeDensity = 0.05          // below what the printer can lay
        s.maxRelativeDensity = 0.90

        let coarse = LatticeBounds.compute(settings: s, limits: limits, lineWidthMM: 0)
        let fine = LatticeBounds.compute(settings: s, limits: limits, lineWidthMM: 0.42)
        XCTAssertGreaterThan(fine.densityLo, coarse.densityLo,
                             "★ stating a line width must RAISE the floor")
        XCTAssertEqual(fine.densityLo, 0.4374, accuracy: 0.001)
        XCTAssertNotNil(fine.densityLoReason, "★ …and say why it moved")
        XCTAssertTrue(fine.densityLoReason?.contains("extrusion") == true,
                      "the reason must name the printer, not the certification: "
                      + "\(fine.densityLoReason ?? "nil")")
    }
}
