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

    /// ★ THE NUMBERS, ON HIS OWN SETTINGS.
    ///
    /// ★★ RE-MEASURED AGAINST CORE (2026-08-20), and the number MOVED A LOT. This
    /// floor is `relativeDensity(strutRadiusMM:)` at one bead, and that inverse now
    /// goes through core's measured octet diameter instead of the app's closed form
    /// `ρ = K·(r/L)²`. Core lays a FATTER strut at a given density, so the density
    /// needed to reach one bead is correspondingly LOWER:
    ///
    ///     0.42 mm line · 2.20 mm cell ....  43.7%  ->  20.2%
    ///     0.20 mm line · 2.20 mm cell ....   9.9%  ->   5.0%
    ///
    /// The old figures were the app's own law and are the same 1.4x-in-radius
    /// divergence, squared. His guess of ~0.5 was close to the app's answer and is
    /// nowhere near core's — which matters, because this floor is what the run
    /// actually enforces.
    ///
    /// ★ AND THE EXPONENT IS NO LONGER EXACTLY 2, which is worth saying plainly
    /// rather than hiding in a tolerance. The closed form was quadratic BY
    /// CONSTRUCTION; core's is a measured table and owes nobody an exponent. Fitted
    /// across this pair, 0.2021 / 0.0501 = 4.03 over a 2.1x width ratio, so
    ///
    ///     floor  ∝  w^1.88        (quadratic would be 4.41, linear 2.10)
    ///
    /// The advice to give him is unchanged and is the point of the test: a 0.2 mm
    /// nozzle does NOT halve the floor, it quarters it. What changed is that "the
    /// law is quadratic" was a property of the app's own arithmetic, not of the
    /// lattice.
    func testTheFloorFollowsTheLineWidthQuadratically() {
        let o = LatticeType.octet
        let his = o.printabilityDensityFloor(lineWidthMM: 0.42, cellMM: 2.20)
        let fine = o.printabilityDensityFloor(lineWidthMM: 0.20, cellMM: 2.20)
        XCTAssertEqual(his, 0.2021, accuracy: 0.001, "★ his settings, core's law")
        XCTAssertEqual(fine, 0.0501, accuracy: 0.001, "★ a 0.2 mm nozzle")
        let exponent = log(his / fine) / log(0.42 / 0.20)
        XCTAssertEqual(exponent, 1.88, accuracy: 0.03,
                       "★ core's floor goes as w^1.88 — near-quadratic, and measured "
                       + "rather than assumed")
        XCTAssertGreaterThan(his / fine, 3.0,
                             "★ the correction his ~0.25 guess needed: a finer nozzle "
                             + "does not scale the floor LINEARLY (that would be 2.1x)")
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
        // Core's floor, not the app's old 0.4374 — see the note above.
        XCTAssertEqual(fine.densityLo, 0.2021, accuracy: 0.001)
        XCTAssertNotNil(fine.densityLoReason, "★ …and say why it moved")
        XCTAssertTrue(fine.densityLoReason?.contains("extrusion") == true,
                      "the reason must name the printer, not the certification: "
                      + "\(fine.densityLoReason ?? "nil")")
    }
}
