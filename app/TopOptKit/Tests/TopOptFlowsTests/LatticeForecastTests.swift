// LatticeForecastTests — task 2026-08-03-variant-postprocessing-fix, defects
// 2/3/4 (bars F1–F5, V2, P3).
//
// These run against the REAL forecast documents core produced, committed under
// evidence/2026-08-03-variant-postprocessing-fix/ — not hand-written fixtures.
// Each one was checked against the actual lattice_variant run of the same job
// (f3_forecast_vs_run.txt: five configurations, every count EXACT), so what these
// tests assert about the copy is asserted about numbers that were measured.

import XCTest
@testable import TopOptFlows

final class LatticeForecastTests: XCTestCase {

    private static let evidence: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("evidence/2026-08-03-variant-postprocessing-fix")
    }()

    private func forecast(_ name: String) throws -> LatticeForecast {
        let url = Self.evidence.appendingPathComponent("f3_forecast_\(name).json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(LatticeForecast.parse(data),
                             "core's own forecast document must parse")
    }

    // MARK: - F1 · the per-reason breakdown, not an aggregate

    func testTheReasonsAreSeparateAndSumToTheFallback() throws {
        for name in ["A_auto_w042", "B_auto_w010", "C_swept_w010",
                     "D_fixed2mm", "E_include"] {
            let f = try forecast(name)
            XCTAssertEqual(f.memberTooThinVoxels + f.strutUnprintableVoxels,
                           f.wouldStaySolidVoxels,
                           "\(name): the reasons must account for EVERY fallback "
                           + "voxel — an aggregate that does not decompose is the "
                           + "defect, not the fix")
            XCTAssertLessThanOrEqual(f.irrecoverableVoxels, f.memberTooThinVoxels,
                                     "\(name): irrecoverable is a subset")
            XCTAssertEqual(f.wouldLatticeVoxels + f.wouldStaySolidVoxels,
                           f.regionVoxels, "\(name): every region voxel is accounted")
        }
    }

    /// The maintainer's shape: a configuration where NOTHING is latticed, and the
    /// reason is one predicate, named, with its count.
    func testAConfigurationThatLatticesNothingSaysWhyWithCounts() throws {
        let f = try forecast("A_auto_w042")
        XCTAssertEqual(f.wouldLatticeVoxels, 0)
        XCTAssertEqual(f.memberTooThinVoxels, f.regionVoxels,
                       "every voxel failed the SAME predicate")
        XCTAssertEqual(f.strutUnprintableVoxels, 0,
                       "on a cell at the printability floor, an unprintable strut "
                       + "is structurally impossible — the count is 0 because it "
                       + "cannot be anything else")
        XCTAssertTrue(f.headline.contains("NOTHING"), f.headline)
        let reasons = f.reasonLines
        XCTAssertTrue(reasons.contains { $0.contains("too thin") }, "\(reasons)")
        // The COUNT, grouped the way a reader reads it (7,652 — not 7652).
        XCTAssertTrue(reasons.contains { $0.contains("7,652") },
                      "the reason must carry its COUNT: \(reasons)")
        // …and the two numbers that make it actionable: what was needed and what
        // the best of the failures actually was.
        XCTAssertTrue(reasons.contains { $0.contains("23.01 mm") && $0.contains("15.00 mm") },
                      "the reason must say how thick the material had to be and how "
                      + "thick the thickest failure was: \(reasons)")
    }

    // MARK: - P3 · a configuration that mostly turns solid is REFUSED up front

    func testAConfigurationThatTurnsMostOfItsRegionSolidIsRefusedBeforeTheRun() throws {
        let bad = try forecast("A_auto_w042")
        XCTAssertTrue(bad.isRefused,
                      "P3: 0% latticed must be reported as a refusal BEFORE the run")
        let partial = try forecast("D_fixed2mm")
        XCTAssertTrue(partial.isRefused,
                      "P3: 35.8% latticed — under half the region — is a refusal too")
        let ok = try forecast("B_auto_w010")
        XCTAssertFalse(ok.isRefused,
                       "…and a configuration that latticed 50.4% is NOT refused: a "
                       + "gate that fires on everything is not a gate")
    }

    // MARK: - F4/F5 · remedies are EVALUATED, and absent when nothing helps

    func testARemedyIsOnlyOfferedWhenItWasMeasuredToHelp() throws {
        let d = try forecast("D_fixed2mm")
        let advice = d.adviceLines()
        XCTAssertTrue(advice.contains { $0.contains("Halve the cell size") },
                      "\(advice)")
        XCTAssertTrue(advice.contains { $0.contains("Measured, not estimated") })
        // The remedy that makes it WORSE is not offered as advice, though core
        // evaluated and reported it.
        XCTAssertTrue(d.remedies.contains { $0.change.contains("double") },
                      "core evaluated the harmful direction too")
        XCTAssertFalse(advice.contains { $0.contains("Double the cell size") },
                       "a change that latticed LESS is not advice: \(advice)")
    }

    func testWhenNoCellSizeCanHelpItSaysSoAndNamesTheRealCause() throws {
        let f = try forecast("A_auto_w042")
        XCTAssertTrue(f.remedies.isEmpty,
                      "core offers no cell remedy when every rejection is "
                      + "irrecoverable — a wrong suggestion is worse than none")
        let advice = f.adviceLines(combinedPathAvailable: false)
        XCTAssertTrue(advice.contains { $0.contains("No cell size can lattice") },
                      "\(advice)")
        XCTAssertTrue(advice.contains { $0.contains("optimized assuming SOLID") },
                      "F5: the honest cause is that the optimizer never left "
                      + "latticeable members: \(advice)")
        // F5's second half: the combined path is only OFFERED once it exists.
        XCTAssertFalse(advice.contains { $0.contains("Run the combined") },
                       "until multiscale-lattice-to lands, the limitation is STATED "
                       + "and no path is offered")
        let withPath = f.adviceLines(combinedPathAvailable: true)
        XCTAssertTrue(withPath.contains { $0.contains("Run the combined") })
    }

    // MARK: - V2 · include regions landing on void, before the run

    func testIncludeRegionsOnVoidAreCountedAndExplained() throws {
        let f = try forecast("E_include")
        XCTAssertGreaterThan(f.includeRegionVoidVoxels, 0)
        XCTAssertEqual(f.includeRegionVoidVoxels, 59_932,
                       "the number core's own run receipt reports for the same job")
        let reasons = f.reasonLines
        XCTAssertTrue(reasons.contains { $0.contains("no material in this variant") },
                      "\(reasons)")
        // …and a job with no include regions does not manufacture the line.
        let none = try forecast("D_fixed2mm")
        XCTAssertEqual(none.includeRegionVoidVoxels, 0)
        XCTAssertFalse(none.reasonLines.contains { $0.contains("no material in this") })
    }

    // MARK: - S1 · the boundary choice, before the run

    func testTheForecastSaysWhenTheBoundaryChoiceCanEmitNothing() throws {
        // Every committed forecast used "diagrid", which CAN emit.
        let f = try forecast("D_fixed2mm")
        XCTAssertTrue(f.boundaryCanEmit)
        XCTAssertNil(f.boundaryNote)
        // The rim verdict is the app's own mirror of the same core fact, asserted
        // structurally against core/src in VariantEntryGatingTests.
        XCTAssertNotNil(LatticeCoreCapability.boundaryProducesNothing(
            skinJobValue: "rim", voxelDerived: true))
    }

    // MARK: - P3 · the Optimize button itself says it, before the run

    /// The refusal has to reach the CONTROL, not just the value type. This is the
    /// sub-line under Optimize on the lattice page.
    func testTheOptimizeButtonStatesTheRefusalAndTheMeasuredRemedy() throws {
        func surface(_ f: LatticeForecast?) -> LatticeOptimizeSurface {
            LatticeOptimizeSurface.compute(
                baseCanOptimize: true, baseSummary: "3 rungs", latticeEnabled: true,
                densityMode: .uniform, topologyDisplayName: "Octet", cellMM: 2,
                bounds: nil, running: false, lineWidthMM: 0.42, forecast: f)
        }
        let d = try forecast("D_fixed2mm")
        let warned = surface(d)
        XCTAssertTrue(warned.sub.contains("36% of the region"),
                      "P3: the count reaches the button: \(warned.sub)")
        XCTAssertTrue(warned.sub.contains("Halve the cell size"),
                      "…with the measured remedy: \(warned.sub)")
        XCTAssertTrue(warned.enabled,
                      "it WARNS, it does not forbid — a partial lattice can be what "
                      + "the user wants; what must not happen is silence")

        // A configuration that latticed most of its region says nothing extra…
        let quiet = surface(try forecast("B_auto_w010"))
        XCTAssertFalse(quiet.sub.contains("of the region"), quiet.sub)
        // …and neither does one with no forecast yet.
        XCTAssertEqual(surface(nil).sub, quiet.sub,
                       "no forecast must read exactly like a healthy one — the "
                       + "sub-line is unchanged until there is something to say")

        // The zero case names the cause instead of a cell size.
        let zero = surface(try forecast("A_auto_w042"))
        XCTAssertTrue(zero.sub.contains("NOTHING"), zero.sub)
        XCTAssertTrue(zero.sub.contains("No cell size can lattice"), zero.sub)
    }

    // MARK: - the parse refuses what it cannot read

    func testAnUnreadableDocumentIsNotAPrediction() {
        XCTAssertNil(LatticeForecast.parse(Data()))
        XCTAssertNil(LatticeForecast.parse(Data("{}".utf8)))
        XCTAssertNil(LatticeForecast.parse(Data("not json".utf8)))
    }

    // MARK: - the forecast job is the run's job plus ONE key

    func testTheForecastJobDiffersFromTheRealJobByExactlyOneKey() throws {
        let original = Data("""
        {"model":"p.stl","material":"PLA","resolution":64,
         "loads":{"anchor_face_ids":[3],"groups":[]}}
        """.utf8)
        let spec = LatticeSpec(topologyID: "octet", cellMM: 4, strutRadiusMM: 0.5,
                                  generateRelativeDensity: 0.3,
                                  minRelativeDensity: 0.1, maxRelativeDensity: 0.5)
        let run = try RelatticeJobBuilder.build(original: original,
                                                variantVolumeFraction: 0.5,
                                                designFileName: "design.bin",
                                                lattice: spec)
        let fc = try RelatticeJobBuilder.build(original: original,
                                               variantVolumeFraction: 0.5,
                                               designFileName: "design.bin",
                                               lattice: spec, forecastOnly: true)
        XCTAssertNotEqual(run, fc)
        var a = try XCTUnwrap(JSONSerialization.jsonObject(with: run) as? [String: Any])
        var b = try XCTUnwrap(JSONSerialization.jsonObject(with: fc) as? [String: Any])
        var la = try XCTUnwrap(a["lattice"] as? [String: Any])
        let lb = try XCTUnwrap(b["lattice"] as? [String: Any])
        XCTAssertEqual(lb["forecast_only"] as? Bool, true)
        la["forecast_only"] = true
        a["lattice"] = la
        b["lattice"] = lb
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]),
            "the forecast must be THE SAME JOB but for `forecast_only` — that "
            + "identity is the whole basis for believing what it predicts")
    }
}
