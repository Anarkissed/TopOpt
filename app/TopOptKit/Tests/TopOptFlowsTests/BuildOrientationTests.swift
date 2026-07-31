// BuildOrientationTests — the app side of THE SECOND QUESTION
// (docs/handoffs/2026-08-01-build-direction-separation.md).
//
// The app has always asked "which way is down in service" (the gravity widget) and
// never "which way is up on the printer", so the pipeline assumed the second was
// the opposite of the first. On the test part that assumption picks the WORST of
// 26 orientations and, at the finer grid, turns a passing part into a failing one.
//
// WHAT THIS PINS:
//
//   U1  AN UNTOUCHED PROJECT SHIPS THE IDENTICAL JOB. Declaring nothing must emit
//       job.json with NO `build_direction` key and a zero plate direction on the
//       bridge, so every existing project's run is byte-identical. This is the
//       load-bearing bar and it is asserted first.
//
//   U5  *** THE RANKING NEVER CHANGES A VERDICT. *** The decoder is handed a
//       receipt whose recommendation would PASS while the orientation actually
//       built FAILED, and the test asserts the app still reports the as-built
//       verdict — that the two facts stay separate all the way to the UI layer.
//
//   U6  THE TWO DIRECTIONS ARE INDEPENDENT. Setting the plate normal must not
//       move the service-gravity direction, and vice versa; and an undeclared
//       plate normal must report itself as ASSUMED, not as a choice.
//
// Pure model-level tests — no worker, no bridge, no GPU.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class BuildOrientationTests: XCTestCase {

    // MARK: - U6: the two questions are separate

    func testAnUndeclaredPlateNormalIsAssumedFromGravityAndSaysSo() {
        var o = BuildOrientation()
        XCTAssertTrue(o.isInferredFromGravity,
                      "an undeclared plate normal must report itself as assumed")
        // The documented fallback, mirroring the core's resolve_build_direction:
        // build = -gravity. This is today's behaviour, unchanged.
        XCTAssertEqual(o.resolved(gravity: SIMD3(0, -1, 0)), SIMD3(0, 1, 0))
        // With nothing at all to go on, +Z — the same default the loadcase builder
        // applies, so the app and the core agree about "nothing was said".
        XCTAssertEqual(o.resolved(gravity: nil), SIMD3(0, 0, 1))

        o.plateUp = SIMD3(0, 0, 1)
        XCTAssertFalse(o.isInferredFromGravity,
                       "a declared plate normal is a CHOICE, not an assumption")
    }

    func testTheTwoDirectionsAreIndependent() {
        var o = BuildOrientation(plateUp: SIMD3(0, 0, 1))
        // Service gravity points -Y (so the old inference would have said +Y).
        // The declared plate normal must win, and must NOT be dragged toward it.
        XCTAssertEqual(o.resolved(gravity: SIMD3(0, -1, 0)), SIMD3(0, 0, 1),
                       "an explicit plate normal is used verbatim")
        // Changing gravity does not move the plate normal — the whole separation.
        XCTAssertEqual(o.resolved(gravity: SIMD3(-1, 0, 0)), SIMD3(0, 0, 1))
        // And clearing the plate normal hands control back to gravity.
        o.plateUp = nil
        XCTAssertEqual(o.resolved(gravity: SIMD3(-1, 0, 0)), SIMD3(1, 0, 0))
    }

    func testANonUnitPlateNormalIsNormalized() {
        let o = BuildOrientation(plateUp: SIMD3(0, 0, 4))
        XCTAssertEqual(o.resolved(gravity: nil), SIMD3(0, 0, 1))
    }

    // MARK: - U1: an untouched project ships the identical job

    func testAnUndeclaredPlateNormalEmitsNoBuildDirectionKey() throws {
        let job = try jobDict(plate: SIMD3(0, 0, 0), wantsRanking: false)
        XCTAssertNil(job["build_direction"],
                     "U1: a project that declared no plate orientation must emit NO "
                     + "build_direction key, so its job.json is unchanged")
        XCTAssertNil(job["build_orientation_report"],
                     "U1: and must not arm the scorer")
        // The LEGACY service-side field is untouched — moving it would change every
        // existing project's self-weight.
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        let bd = try XCTUnwrap(loads["build_dir"] as? [Double])
        XCTAssertEqual(bd, [0, 0, 1], "loads.build_dir keeps its existing meaning")
    }

    func testADeclaredPlateNormalEmitsTheRootKey() throws {
        let job = try jobDict(plate: SIMD3(1, 0, 0), wantsRanking: true)
        let bd = try XCTUnwrap(job["build_direction"] as? [Double])
        XCTAssertEqual(bd, [1, 0, 0])
        XCTAssertEqual(job["build_orientation_report"] as? Bool, true)
        // At the ROOT, not inside `loads`: `loads.build_dir` answers the service
        // question and the root key answers the plate question. Two keys, two
        // questions — that is the separation.
        let loads = try XCTUnwrap(job["loads"] as? [String: Any])
        XCTAssertNil(loads["build_direction"],
                     "the plate normal belongs at the job root, not in `loads`")
    }

    // MARK: - U5: a recommendation never changes a verdict

    /// A receipt in exactly the shape the core emits for the case that matters:
    /// the orientation ACTUALLY BUILT was REJECTED and the RECOMMENDED one would
    /// have been ACCEPTED.
    private var flippingReceipt: Data {
        Data("""
        {
          "as_built": {"build_direction": [0, 1, 0], "source": "assumed_from_gravity",
                       "margin_effective": 0.6968, "verdict": "REJECTED"},
          "recommended": {"build_direction": [0, 0, 1], "differs_from_as_built": true,
                          "margin_effective": 1.3285, "verdict": "ACCEPTED"},
          "verdict_would_change": true,
          "statement": "as built: REJECTED; as recommended: ACCEPTED. THE VERDICT THAT STANDS IS THE AS-BUILT ONE.",
          "self_checks": {"strut_in_plane_invariant": true,
                          "cube_axes_strut_interlayer_identical": true,
                          "cube_axes_scored": 6},
          "sweep_seconds": 0.0015,
          "candidates": [
            {"build_direction": [0, 1, 0], "on_cube_axis": true, "is_as_built": true,
             "is_recommended": false, "support_voxels": 48,
             "macro_interlayer_margin": 0.6968, "margin_effective": 0.6968,
             "would_be_accepted": false, "strut_evaluated": true,
             "strut_in_plane_margin": 0.46164486, "strut_interlayer_margin": 0.28850357,
             "horizontal_strut_length_fraction": 0.3333,
             "min_feature_violations": 0, "build_height_layers": 48,
             "first_layer_footprint_voxels": 96},
            {"build_direction": [0, 0, 1], "on_cube_axis": true, "is_as_built": false,
             "is_recommended": true, "support_voxels": 0,
             "macro_interlayer_margin": 6.3494, "margin_effective": 1.3285,
             "would_be_accepted": true, "strut_evaluated": true,
             "strut_in_plane_margin": 0.46164486, "strut_interlayer_margin": 0.28850357,
             "horizontal_strut_length_fraction": 0.3333,
             "min_feature_violations": 0, "build_height_layers": 8,
             "first_layer_footprint_voxels": 440}
          ]
        }
        """.utf8)
    }

    func testTheRecommendationDoesNotBecomeTheVerdict() throws {
        let r = try XCTUnwrap(OrientationRanking.decode(flippingReceipt))

        // *** THE BAR. The two verdicts are carried SEPARATELY and the as-built one
        // is the one the part was certified under. Nothing in the decode path may
        // let the recommendation stand in for it. ***
        XCTAssertFalse(r.asBuiltAccepted, "the part as built was REJECTED")
        XCTAssertTrue(r.recommendedAccepted, "the recommendation would be ACCEPTED")
        XCTAssertTrue(r.verdictWouldChange,
                      "and the app must know the two disagree, so it can say so")
        XCTAssertTrue(r.recommendationDiffers)

        // The as-built ROW agrees with the as-built VERDICT — a decoder that mixed
        // the rows up would show a passing row for a failing part.
        let built = try XCTUnwrap(r.candidates.first { $0.isAsBuilt })
        XCTAssertEqual(built.buildDirection, SIMD3(0, 1, 0))
        XCTAssertFalse(built.wouldBeAccepted)
        let rec = try XCTUnwrap(r.candidates.first { $0.isRecommended })
        XCTAssertTrue(rec.wouldBeAccepted)
        XCTAssertNotEqual(built.buildDirection, rec.buildDirection)

        // The receipt's own sentence is carried through verbatim rather than
        // re-composed, so the app cannot phrase it differently from the file.
        XCTAssertTrue(r.statement.contains("THE VERDICT THAT STANDS IS THE AS-BUILT ONE"))
        // And the fallback is labelled, not hidden.
        XCTAssertTrue(r.asBuiltWasAssumed)
    }

    func testTheSixCriteriaSurviveDecodingSeparately() throws {
        let r = try XCTUnwrap(OrientationRanking.decode(flippingReceipt))
        let built = try XCTUnwrap(r.candidates.first { $0.isAsBuilt })
        let rec = try XCTUnwrap(r.candidates.first { $0.isRecommended })
        // Every criterion arrives as its own number. PR 266 measured that they
        // disagree; a UI that collapsed them would hide exactly that.
        XCTAssertEqual(built.supportVoxels, 48)                       // S-a
        XCTAssertEqual(rec.supportVoxels, 0)
        XCTAssertEqual(built.macroInterlayerMargin, 0.6968, accuracy: 1e-9)  // S-b
        XCTAssertEqual(rec.macroInterlayerMargin, 6.3494, accuracy: 1e-9)
        XCTAssertEqual(built.strutInPlaneMargin, rec.strutInPlaneMargin)     // S-c
        XCTAssertEqual(built.strutInterlayerMargin, rec.strutInterlayerMargin) // S-d
        XCTAssertEqual(built.horizontalStrutFraction, rec.horizontalStrutFraction) // S-e
        XCTAssertEqual(built.buildHeightLayers, 48)                   // S-f
        XCTAssertEqual(rec.buildHeightLayers, 8)
        // The self-checks arrive too, so a wiring drift is visible in the UI.
        XCTAssertTrue(r.strutInPlaneInvariant)
        XCTAssertTrue(r.cubeAxesStrutInterlayerIdentical)
    }

    func testTheDissentReportNamesWhereTheCriteriaDisagree() throws {
        let r = try XCTUnwrap(OrientationRanking.decode(flippingReceipt))
        // On this receipt the recommendation is best on every moving criterion, so
        // nothing dissents. The point of the assertion is that the report EXISTS
        // and is computed from the rows, not that it is always empty.
        XCTAssertTrue(r.dissentingCriteria.isEmpty)
    }

    func testAMalformedReceiptIsShownAsAbsentNotAsHalfARanking() {
        XCTAssertNil(OrientationRanking.decode(Data("{}".utf8)))
        XCTAssertNil(OrientationRanking.decode(Data("not json".utf8)))
        XCTAssertNil(OrientationRanking.decode(Data("""
        {"as_built": {"build_direction": [0,1,0]}, "recommended": {}, "candidates": []}
        """.utf8)), "a receipt with no candidates is not a ranking")
    }

    // MARK: - helper

    private func jobDict(plate: SIMD3<Double>, wantsRanking: Bool) throws -> [String: Any] {
        let request = RunRequest(
            modelPath: "/tmp/part.stl", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "build-orientation",
            anchorFaceIDs: [1], loadGroups: [],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1),
            plateDirection: plate, wantsOrientationRanking: wantsRanking)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        let data = try run.buildJobJSON()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
