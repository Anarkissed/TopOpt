// LatticeStressTintTests.swift — ★ THE STRESS VIEW (maintainer, 2026-08-17:
// "Once you save and exit, an FEA should run and a Stress view should now be
// accessible below the preview button").

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeStressTintTests: XCTestCase {

    /// A 2×2×2 field on a unit grid, values supplied corner-first.
    private func field(_ v: [Float]) -> LatticeDemandField {
        LatticeDemandField(vonMises: v, nx: 2, ny: 2, nz: 2,
                           origin: .zero, spacingMM: 1,
                           provenance: .solidSim(date: Date(timeIntervalSince1970: 0),
                                                 resolution: 64))
    }

    // MARK: the ramp

    /// ★ COOL WHERE IT IS IDLE, HOT WHERE THE LOAD RUNS — and the ramp is
    /// DELIBERATELY not the density ramp. That one is the lattice's own colour
    /// language ("this much material"); reusing it would make two different
    /// quantities look like one.
    func testTheRampRunsCoolToHot() {
        let idle = LatticeStressTint.colour(fraction: 0)
        let peak = LatticeStressTint.colour(fraction: 1)
        XCTAssertGreaterThan(idle.z, idle.x, "★ idle is BLUE-dominant")
        XCTAssertGreaterThan(peak.x, peak.z, "★ peak is RED-dominant")
    }

    /// Out-of-range fractions clamp instead of running off the ramp.
    func testTheRampClampsRatherThanExtrapolating() {
        XCTAssertEqual(LatticeStressTint.colour(fraction: -5),
                       LatticeStressTint.colour(fraction: 0))
        XCTAssertEqual(LatticeStressTint.colour(fraction: 5),
                       LatticeStressTint.colour(fraction: 1))
    }

    /// Every stop is opaque — a translucent tint would read as a shading
    /// artefact rather than a measurement.
    func testEveryColourIsOpaque() {
        for i in 0...10 {
            XCTAssertEqual(LatticeStressTint.colour(fraction: Double(i) / 10).w,
                           1, accuracy: 1e-6)
        }
    }

    // MARK: sampling

    func testItSamplesTheGridTrilinearly() throws {
        // 0 at the origin corner, 1 at the far x corner, 0 elsewhere.
        let f = field([0, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(try XCTUnwrap(LatticeStressTint.sample(f, at: .zero)),
                       0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(LatticeStressTint.sample(f, at: SIMD3(1, 0, 0))),
                       1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(LatticeStressTint.sample(f, at: SIMD3(0.5, 0, 0))),
                       0.5, accuracy: 1e-6, "★ interpolated, not nearest")
    }

    /// ★ A POINT THE SOLVE NEVER COVERED HAS NO STRESS TO REPORT. Returning nil
    /// rather than clamping to an edge value is the fabricated-number rule: this
    /// project has already paid for a readout that looked like a measurement.
    func testAPointOutsideTheGridIsRefused() {
        let f = field([Float](repeating: 1, count: 8))
        XCTAssertNil(LatticeStressTint.sample(f, at: SIMD3(-0.001, 0, 0)))
        XCTAssertNil(LatticeStressTint.sample(f, at: SIMD3(1.001, 0, 0)))
        XCTAssertNil(LatticeStressTint.sample(f, at: SIMD3(0, 0, 99)))
    }

    // MARK: the buffer

    private func mesh(_ pts: [Float]) -> ViewerMesh {
        let n = pts.count / 3
        return ViewerMesh(vertices: pts,
                          indices: n >= 3 ? [0, 1, 2] : [],
                          faceIDs: n >= 3 ? [0] : [])
    }

    /// ★★ ONE `SIMD4` PER *FLAT* VERTEX — the count `mesh.flat` states, because
    /// `mesh.flat` is what the renderer draws.
    ///
    /// ★ THIS BUFFER HAS BEEN WRONG TWICE, in two different ways, and both were
    /// dropped IN SILENCE: cut 1 sized an 8-float buffer by unique positions;
    /// cut 2 fixed the count but kept the wrong CHANNEL (`vertexTints`, the
    /// Surface stage's state buffer, not a colour channel at all). The renderer
    /// discards a mis-sized array without a word, so both times the view looked
    /// plausible and was simply absent.
    func testTheTintsAreSizedByFlatVertexCount() {
        // A welded quad: six indices over four positions, so a buffer sized by
        // unique positions would be the wrong length.
        let m = ViewerMesh(vertices: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                           indices: [0, 1, 2, 0, 2, 3],
                           faceIDs: [0, 0])
        let t = LatticeStressTint.tints(for: m, field: field([0, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(t.count, m.flat.vertexCount,
                       "★ the count the renderer actually draws")
        XCTAssertNotEqual(t.count, m.positions.count / 3,
                          "★ …and NOT unique positions, which was cut 1's bug")
    }

    /// ★ AND THE COLOURS ARE THE RAMP, keyed to the field — the assertion that
    /// makes this a measurement rather than a wash.
    func testTheHottestFlatVertexIsAtThePeak() {
        let m = ViewerMesh(vertices: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                           indices: [0, 1, 2, 0, 2, 3],
                           faceIDs: [0, 0])
        let t = LatticeStressTint.tints(for: m, field: field([0, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertFalse(t.isEmpty)
        let hottest = t.max { $0.x < $1.x }!
        XCTAssertEqual(hottest.x, LatticeStressTint.colour(fraction: 1).x,
                       accuracy: 1e-5)
    }

    /// A flat field still refuses — normalising it would paint the whole part
    /// peak-red, which looks like a finding and is a divide-by-nothing.
    func testAFlatFieldStillDrawsNothingThroughTheColourChannel() {
        let m = ViewerMesh(vertices: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0],
                           indices: [0, 1, 2, 0, 2, 3], faceIDs: [0, 0])
        XCTAssertTrue(LatticeStressTint.tints(
            for: m, field: field([Float](repeating: 0, count: 8))).isEmpty)
    }

    // MARK: ★ THE LEGEND

    /// ★ A PLOT WITHOUT A SCALE IS A PICTURE. The ticks read in MPa, not 0…1:
    /// the surface is normalised to its own peak so the SHAPE is legible, but a
    /// normalised axis cannot answer "is this near yield?".
    func testTheLegendReadsInAbsoluteMPaAndPeaksAtThePeak() {
        let t = LatticeStressTint.legendTicks(peakMPa: 42.5, count: 5)
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(Double(t.first!)!, 42.5, accuracy: 0.05,
                       "★ the top tick IS the peak")
        XCTAssertEqual(Double(t.last!)!, 0, accuracy: 0.05)
    }

    /// A degenerate peak yields no ticks rather than a scale of zeros.
    func testANonPositivePeakHasNoLegend() {
        XCTAssertTrue(LatticeStressTint.legendTicks(peakMPa: 0).isEmpty)
        XCTAssertTrue(LatticeStressTint.legendTicks(peakMPa: .nan).isEmpty)
    }

    /// ★ THE BAR AND THE SURFACE SHARE ONE RAMP, so the key cannot disagree
    /// with the thing it is a key to.
    func testTheLegendBarIsTheSameRampHotAtTheTop() {
        let c = LatticeStressTint.legendColours()
        XCTAssertEqual(c.count, LatticeStressTint.legendStops)
        XCTAssertEqual(c.first!, LatticeStressTint.colour(fraction: 1),
                       "★ hot at the TOP")
        XCTAssertEqual(c.last!, LatticeStressTint.colour(fraction: 0))
    }

    /// The peak the legend reports is the field's own maximum.
    func testThePeakIsTheFieldsMaximum() {
        XCTAssertEqual(LatticeStressTint.peakMPa(field([0, 3, 1, 0, 0, 0, 0, 2])),
                       3, accuracy: 1e-6)
    }




}

// ─────────────────────────────────────────────────────────────────────────
// MARK: ★ THE SOLVE TRIGGER REFUSES, AND SAYS SO IN SOURCE

final class LatticeSimSolveTriggerTests: XCTestCase {

    /// ★★ THE THREE REFUSALS ARE THE POINT OF THE TRIGGER, not decoration on it.
    /// An FEA is a real CG solve; firing one nothing will read is a cost with no
    /// consumer, and this project has a standing rule against exactly that.
    ///
    /// The trigger lives on a SwiftUI view, so its guards are not reachable from
    /// a value test — but they ARE readable, and the alternative failure (a
    /// trigger that quietly solves on every save) is invisible to a value test
    /// and is what a careless edit would produce.
    func testTheTriggerRefusesOnAllThreeGrounds() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
            encoding: .utf8)
        let r = try XCTUnwrap(src.range(of: "private func startStressSolveIfNeeded()"))
        let body = String(src[r.lowerBound...].prefix(900))

        XCTAssertTrue(body.contains("needsStressSolve"),
                      "★ nothing asking ⇒ no solve")
        XCTAssertTrue(body.contains("makeLatticeSimContext()"),
                      "★ no describable solve ⇒ no solve")
        XCTAssertTrue(body.contains("isStale(against: ctx.fingerprint)"),
                      "★ a FRESH field for these exact inputs IS the answer — "
                      + "re-solving identical inputs produces an identical field")
        XCTAssertTrue(body.contains("latticeSim.run(ctx)"),
                      "★ …and otherwise it actually runs")
    }

    /// ★ IT IS WIRED TO SAVE & EXIT, which is the whole of his "Once you save
    /// and exit, an FEA should run". A trigger nothing calls is the decorative
    /// control in its purest form.
    func testSaveAndExitIsWhatCallsIt() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"),
            encoding: .utf8)
        let r = try XCTUnwrap(src.range(of: "LatticeSetupWizard(project: project)"))
        let head = String(src[r.lowerBound...].prefix(700))
        XCTAssertTrue(head.contains("startStressSolveIfNeeded()"),
                      "★ the wizard's exit is the call site")
    }
}
