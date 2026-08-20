// LatticeSubfloorRetentionPreviewTests — ★★ THE FLOOR STANDS DOWN WHERE THE RUN
// STANDS IT DOWN (maintainer, 2026-08-20: "Why does that rule exist for a wall that
// does not need to certify?").
//
// He was right, and core had already agreed: `retain_subfloor_in_unloaded_regions`
// keeps lattice in material too thin to hold N* cells when the region MEASURES as
// unloaded. The app has carried that switch since the retention task and the preview
// had never heard of it — so the member floor added the day before removed cells a
// run with retention armed keeps. This is the mirror-image divergence, closed.

import XCTest
import Metal
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class LatticeSubfloorRetentionPreviewTests: XCTestCase {

    /// The ceiling is CORE's, and the app must not carry a copy of it.
    func testTheCeilingIsReadFromCore() {
        let f = TopOptKit.latticeSubfloorRetentionStressFraction()
        XCTAssertGreaterThan(f, 0, "core must state a ceiling")
        XCTAssertLessThanOrEqual(f, 1)
    }

    /// Core's arithmetic: the region's measured peak over the part's, against the
    /// ceiling — including the guard that decides the whole safety of the feature.
    func testQualificationIsCoresArithmeticIncludingTheNoDemandGuard() {
        let c = 0.25
        XCTAssertTrue(LatticePreviewOccupancy.subfloorQualifies(
            regionPeak: 10, partPeak: 100, ceiling: c), "10% of peak is quiet")
        XCTAssertFalse(LatticePreviewOccupancy.subfloorQualifies(
            regionPeak: 30, partPeak: 100, ceiling: c), "30% is not")
        XCTAssertTrue(LatticePreviewOccupancy.subfloorQualifies(
            regionPeak: 25, partPeak: 100, ceiling: c), "the ceiling is inclusive")
        // ★ NO DEMAND FIELD, NO RETENTION. An all-zero demand READS as "carries
        // nothing" and MEANS "nothing was measured" — core's own words, and the
        // difference between a measured decision and a blind one.
        XCTAssertFalse(LatticePreviewOccupancy.subfloorQualifies(
            regionPeak: 0, partPeak: 0, ceiling: c),
            "★ an unmeasured region is not an unloaded one")
    }

    /// ★★ AND IT BRINGS HIS CELLS BACK. Same part, same 8 mm cell, same declared
    /// slab: the only difference is the switch the job already had. Measured:
    ///
    ///     part peak ......... 1.00      (the demand field is peak-normalised)
    ///     region peak ....... 0.01      the load is elsewhere in the part
    ///     core's ceiling .... 0.20
    ///     cells drawn ....... 228 with the floor  ->  417 retained
    ///
    /// 417 is exactly what the preview drew BEFORE the member floor existed — which
    /// is the right answer: retention drops the cells-per-member ceiling outright for
    /// a qualified region, and at an 8 mm cell nothing here is unprintable, so every
    /// cell the floor took comes back.
    func testRetentionRestoresTheCellsTheFloorRemoved() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60

        // A part with its load somewhere ELSE: hot at the far x end, quiet across the
        // declared slab. That is the shape of his question — the back wall nothing
        // pushes on.
        let probe = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let occ = probe.occupancy
        var loX = Float.greatestFiniteMagnitude
        for i in 0..<occ.count where occ.values[i] > 0.5 {
            loX = Swift.min(loX, occ.origin.x + Float(i % occ.nx) * occ.spacing.x)
        }
        let b = mesh.bounds
        let n = 32
        let sp = Swift.max(1e-3, (b.max.x - b.min.x) / Float(n - 1))
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let x = b.min.x + Float(i) * sp
            // The load lives in the part but OUTSIDE the declared slab, which sits
            // at the high-x face — his quiet back wall, with the work happening
            // somewhere else entirely.
            vals[(k * n + j) * n + i] = x < loX - 5 ? 100 : 1
        } } }
        let field = StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: vals)
        let scene = LatticeSDFScene(mesh: mesh, field: field, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        try XCTSkipIf(scene.memberThicknessMM.isEmpty, "core gave no member widths")

        let peaks = LatticePreviewOccupancy.subfloorPeaks(
            demand: scene.demand, partSDF: scene.partSDF, occupancy: scene.occupancy)
        try XCTSkipUnless(peaks.part > 0, "the fixture must measure a part peak")

        renderer.setScene(scene)
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 8)

        renderer.subfloorRetention = nil
        let withFloor = try XCTUnwrap(renderer.cellField).field.values.filter { $0 >= 0 }.count
        XCTAssertFalse(renderer.subfloorRetained)

        renderer.subfloorRetention = LatticeSubfloorRetention(armed: true)
        let retained = try XCTUnwrap(renderer.cellField).field.values.filter { $0 >= 0 }.count
        print("RETENTION peaks part=\(peaks.part) region=\(peaks.region) "
              + "fraction=\(peaks.region / Swift.max(peaks.part, 1e-9)) "
              + "ceiling=\(TopOptKit.latticeSubfloorRetentionStressFraction()) "
              + "cells floor=\(withFloor) retained=\(retained)")
        XCTAssertTrue(renderer.subfloorRetained,
                      "★ a quiet region must qualify — otherwise this test measures nothing")
        XCTAssertGreaterThan(retained, withFloor,
                             "★ the cells the member floor removed must come back when "
                             + "the run would keep them. This is the divergence the "
                             + "member-floor task opened in the other direction.")

        // ★ AND A LOADED REGION MUST NOT QUALIFY — the negative control, because a
        // switch that always says yes is not a measurement.
        var loud = vals
        for i in 0..<loud.count { loud[i] = 100 }
        let loudField = StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: loud)
        let loudScene = LatticeSDFScene(mesh: mesh, field: loudField, latticeID: "octet",
                                        regions: [region], whenEmpty: .latticeNothing)
        renderer.setScene(loudScene)
        renderer.subfloorRetention = LatticeSubfloorRetention(armed: true)
        XCTAssertFalse(renderer.subfloorRetained,
                       "★ a region at the part's own peak stress must NOT be retained")
    }

    /// ★★ A STATED DENSITY IS NOT A STRESS READING (his screenshot, 2026-08-20: two
    /// face cards at 25% and 17% on a job marked "no optimization").
    ///
    /// `LatticeSDFScene.demand` has TWO sources and the scene deliberately lets a
    /// stated per-region density OUTRANK the field, so the shader draws the density
    /// the user asked for. Retention must never key on that: it would decide "this
    /// wall carries nothing" from a number that never described load. Core's rule is
    /// that an unmeasured region is not an unloaded one, and a stated 17% is
    /// unmeasured.
    func testAStatedRegionDensityNeverArmsRetention() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = LatticeSDFRenderer(device: device) else {
            throw XCTSkip("no Metal device")
        }
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        region.relativeDensity = 0.17            // his own card's number

        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        XCTAssertNotNil(scene.demand,
                        "positive control: there IS a demand field to be fooled by")
        XCTAssertFalse(scene.demandIsMeasuredStress,
                       "★ a stated density must not pass as a stress measurement")

        renderer.setScene(scene)
        renderer.params = LatticeProxyParams(latticeID: "octet", cellMM: 8)
        renderer.subfloorRetention = LatticeSubfloorRetention(armed: true)
        XCTAssertFalse(renderer.subfloorRetained,
                       "★ retention must stay disarmed on a job with no measured "
                       + "stress, however the switch is set")
    }
}
