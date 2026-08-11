// ParametricArmingTests — ★ THE FRONT-END RUNS THE PARAMETRIC LEVEL SET, AND
// BOTH OF ITS PATHS SAY SO (task 2026-08-10-plsm-production).
//
// The app has TWO ways to optimise a part and they MUST NOT DISAGREE about which
// algorithm made it:
//
//   on-device   TopOptBridge's run_minimize_plastic sets
//               opts.plsm.mode = PlsmMode::Parametric
//   remote      RemoteRun.buildJobJSON sends "plsm": {"enabled": true} to the
//               worker, which hands it to topopt-cli
//
// This file pins the SECOND one, because it is the one that is expressible in
// Swift; the first is pinned by the C++ side. What makes the pair safe is that
// each site's comment names the other and this test's failure message says so —
// a change to one that forgets the other lands here.
//
// ★ EVERY TEST HERE DRIVES THE REAL SERIALIZER, for the reason
// DefaultArmingTests states and this project keeps re-learning: four consecutive
// PRs shipped app-side defects behind green checks, and one passed 31 tests
// against a code path the maintainer could not reach. So this goes through
// `RemoteRun.buildJobJSON()` — the function that produces the bytes a worker
// actually receives — and never against a dictionary the test assembled itself.
//
// ★ AND IT IS SENT EXPLICITLY RATHER THAN LEANING ON A DEFAULT, for the reason
// `project_cad_faces` is: `run_info` echoes the job it was given, so "the key
// was absent" and "the user asked for this" are the same bytes there. A part
// found in six months has to be attributable to the algorithm that made it —
// and during this changeover that is the single most valuable thing the receipt
// can carry.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ParametricArmingTests: XCTestCase {

    private static func optimizeJob() throws -> [String: Any] {
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "parametric",
            anchorFaceIDs: [3],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11],
                                                force: SIMD3(0, 0, -250))],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: nil,
            projectCADFaces: true)
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg, request: request,
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try run.buildJobJSON())
                as? [String: Any])
    }

    func testOptimizeJobSendsPlsmExplicitlyAndArmed() throws {
        let job = try Self.optimizeJob()
        // PRESENT — not merely correct-by-omission. Core's own default is OFF,
        // so an absent key would run SIMP on the worker while the iPad ran the
        // parametric level set, and the two front-ends would be producing
        // different parts from the same button.
        let plsm = try XCTUnwrap(
            job["plsm"] as? [String: Any],
            "the optimize job must SEND a \"plsm\" block — core defaults the "
            + "mode OFF, so omitting it puts the worker on SIMP while the "
            + "on-device path runs the parametric level set")
        XCTAssertEqual(plsm["enabled"] as? Bool, true,
                       "and it must be ARMED. If you are turning the front-end "
                       + "back to SIMP, change TopOptBridge's "
                       + "run_minimize_plastic IN THE SAME COMMIT — the "
                       + "on-device and remote paths must agree.")
    }

    // ★ THE KNOT SPACING IS DELIBERATELY ABSENT, AND THAT IS AN ASSERTION.
    //
    // Omitting it is what asks core for `plsm_knots_for_grid` — the production
    // rule that derives the spacing from the grid's own voxel size, PER AXIS, so
    // the feature scale the basis can express is the same LENGTH at every
    // resolution. Naming numbers here would pin it to one resolution and would
    // be a second opinion about a rule core owns.
    //
    // This test exists because "send the knots too, to be explicit" is exactly
    // the well-meaning change that would break it, and the same instinct that
    // made `project_cad_faces` right makes this wrong. The difference: that key
    // carries a USER'S ANSWER, this one would carry a DUPLICATED RULE.
    func testOptimizeJobDoesNotPinTheKnotSpacing() throws {
        let job = try Self.optimizeJob()
        let plsm = try XCTUnwrap(job["plsm"] as? [String: Any])
        XCTAssertNil(plsm["knots"],
                     "the app must NOT send plsm.knots — omitting it is what "
                     + "asks for plsm_knots_for_grid, the per-axis production "
                     + "rule. Sending three numbers pins the feature scale to "
                     + "one resolution and duplicates a rule core owns.")
    }

    // The block must be the physics and nothing else: the job schema is STRICT
    // (`reject_unknown_keys`), so a stray key here fails the run ON A DEVICE
    // rather than at build time — handoff 129's lesson, in a new block.
    func testPlsmBlockCarriesOnlySchemaKeys() throws {
        let job = try Self.optimizeJob()
        let plsm = try XCTUnwrap(job["plsm"] as? [String: Any])
        let allowed: Set<String> = ["enabled", "basis", "knots", "support",
                                    "eta_voxels", "max_iterations", "seed",
                                    "refit_every", "move",
                                    "cg_tolerance_loose", "warm_start"]
        for key in plsm.keys {
            XCTAssertTrue(allowed.contains(key),
                          "\"plsm.\(key)\" is not in core's job schema — the "
                          + "schema rejects unknown keys, so this fails the run "
                          + "on the device, not here")
        }
    }
}
