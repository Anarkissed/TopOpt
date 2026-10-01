// LatticePrintabilityFloorTests — ★★ THE PREVIEW STOPS DRAWING STRUTS THE NOZZLE
// CANNOT LAY (task 2026-08-20, item 2 — the underside speckle he reported, and the
// printability half of the preview↔algorithm audit; they are ONE defect).
//
// ★ THE MECHANISM. `LatticeBounds` has always raised the band's floor to the
// printability floor when handed a line width — "stating a line width must RAISE the
// floor". `proxyParams`, which is what actually feeds the preview, never handed it
// one. So the band's bottom fell to core's certifiable minimum, the thin end of the
// ramp landed inside a declared region, and the struts there came out thinner than a
// bead: sub-pixel geometry that read as speckle and that the run does not build.
//
// ★ AND THE REMEDY IS CORE'S ORDER — densify first, delete last. The floor rises so
// those cells print; only a cell that cannot print at ANY certifiable density is left
// solid. Deleting first would show him LESS lattice than the run builds, which is the
// mistake the member-floor task had to have corrected a day later.

import XCTest
import Metal
@testable import TopOptFlows
@testable import TopOptKit

final class LatticePrintabilityFloorTests: XCTestCase {

    private var limits: TopOptKit.LatticeLimits {
        TopOptKit.latticeLimits(topology: "octet")
    }

    private func hisSettings() -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"
        s.cellMM = 2.20
        s.minRelativeDensity = 0.05      // below what the printer can lay
        s.maxRelativeDensity = 0.90
        s.densityMode = .sim
        return s
    }

    /// ★ THE THINNEST STRUT THE PREVIEW WILL DRAW IS ONE BEAD — stated as the
    /// property rather than as a pixel count, because that is the thing that was
    /// wrong. With a positive control that it was NOT true before.
    func testTheThinnestPreviewedStrutIsOneBead() {
        let s = hisSettings()
        let bead = 0.42
        let octet = LatticeType.octet

        let blind = s.proxyParams(limits: limits)                       // as it was
        let thinnest = 2 * octet.strutRadiusMM(relativeDensity: blind.densitySpan.lo,
                                               cellMM: s.cellMM)
        XCTAssertLessThan(thinnest, bead,
                          "★ positive control: with no bead stated the band's floor "
                          + "draws struts under one extrusion — the speckle")

        let aware = s.proxyParams(limits: limits, lineWidthMM: bead)
        let now = 2 * octet.strutRadiusMM(relativeDensity: aware.densitySpan.lo,
                                          cellMM: s.cellMM)
        XCTAssertGreaterThanOrEqual(now, bead - 1e-6,
                                    "★ every strut the preview draws must be at "
                                    + "least one bead wide")
        // ★ AND THE FLOOR IS CORE'S, not a number this test invented.
        XCTAssertEqual(aware.densitySpan.lo,
                       octet.printabilityDensityFloor(lineWidthMM: bead, cellMM: s.cellMM),
                       accuracy: 1e-9)
        // ★ THE TOP IS UNTOUCHED — this raises a floor, it does not squeeze the band.
        XCTAssertEqual(aware.densitySpan.hi, blind.densitySpan.hi, accuracy: 1e-9)
    }

    /// ★ A FINER NOZZLE DRAWS SPARSER — the floor must follow the printer, not sit
    /// at a constant. Otherwise this is a hardcoded clamp wearing a law's name.
    func testTheFloorFollowsTheNozzle() {
        let s = hisSettings()
        let coarse = s.proxyParams(limits: limits, lineWidthMM: 0.42).densitySpan.lo
        let fine = s.proxyParams(limits: limits, lineWidthMM: 0.20).densitySpan.lo
        XCTAssertLessThan(fine, coarse,
                          "a 0.2 mm nozzle prints a sparser lattice than a 0.42 mm one")
        XCTAssertGreaterThan(coarse, 0)
    }

    /// ★★ AND THE HALF DENSIFYING CANNOT COVER: when even core's densest certifiable
    /// density cannot reach one bead at this cell, nothing in the band prints and the
    /// run leaves it SOLID. The preview must draw nothing rather than a lattice that
    /// cannot be built — core's `fallback_strut_unprintable`.
    func testACellNoDensityCanPrintDrawsNothing() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        renderer.setScene(scene)

        // A workable cell first — the positive control, so "nothing drawn" below is
        // a decision and not simply an empty scene.
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 8,
                                             minRelativeDensity: 0.2,
                                             maxRelativeDensity: 0.55)
        renderer.lineWidthMM = 0.42
        let drawn = try XCTUnwrap(renderer.cellField).field.values.filter { $0 >= 0 }.count
        XCTAssertFalse(renderer.cellUnprintable)
        XCTAssertGreaterThan(drawn, 0, "positive control: an 8 mm cell prints")

        // Now a cell so fine that core's own ceiling cannot reach a 0.42 mm bead.
        let tiny = 0.35
        let rhoStar = LatticeType.octet.printabilityDensityFloor(lineWidthMM: 0.42,
                                                                 cellMM: tiny)
        try XCTSkipUnless(rhoStar > 0.55,
                          "fixture must be genuinely unprintable: \(rhoStar)")
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: tiny,
                                             minRelativeDensity: 0.2,
                                             maxRelativeDensity: 0.55)
        // ★★ AND IT MUST BE FAST. The first version of this guard baked an EMPTY
        // field AT THE REJECTED CELL — 631³ ≈ 251 M cells at 0.35 mm over his part —
        // and took twenty minutes to build a volume it had already decided was
        // entirely inactive. That is not a test artefact: a fine cell with a coarse
        // nozzle is a setting anyone can type, and it hung the app.
        let t0 = Date()
        XCTAssertTrue(renderer.cellUnprintable,
                      "★ the preview must KNOW it drew nothing, so the viewport can "
                      + "say why rather than looking broken")
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 1.0,
                          "★ refusing a cell must cost nothing — there is no volume "
                          + "to size when nothing is drawn (took \(elapsed)s)")
        let none = try XCTUnwrap(renderer.cellField).field.values.filter { $0 >= 0 }.count
        XCTAssertEqual(none, 0,
                       "★ no certifiable density prints at this cell — the run leaves "
                       + "it solid and so must the picture")
    }

    /// ★ HIS OWN CONFIGURATION, MEASURED — because "your stated density may now be
    /// clamped" is a claim about HIS part and it should be a number, not a worry.
    /// Face 2 on his verticalStand states 17% at a 2.60 mm cell; Face 1 states 25%.
    func testHisStatedDensitiesAgainstHisOwnPrintableFloor() {
        let octet = LatticeType.octet
        let bead = 0.42
        let floor260 = octet.printabilityDensityFloor(lineWidthMM: bead, cellMM: 2.60)
        let floor220 = octet.printabilityDensityFloor(lineWidthMM: bead, cellMM: 2.20)
        print("HIS FLOOR cell=2.60mm bead=0.42mm -> \(floor260)  "
              + "(cell 2.20mm -> \(floor220));  stated 17% and 25%")
        // A coarser cell prints a sparser lattice — the relationship the whole
        // grading law rests on, checked here on his two numbers rather than assumed.
        XCTAssertLessThan(floor260, floor220,
                          "★ the floor must fall as the cell grows")
        XCTAssertGreaterThan(floor260, 0)
        XCTAssertLessThan(floor260, 0.30,
                          "a floor above 30% at his own cell would mean his stated "
                          + "densities are BOTH unprintable, which is a different "
                          + "conversation and one he would need to have")
    }
}
