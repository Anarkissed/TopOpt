// DefaultArmingTests — the two features are ARMED, and the app SAYS SO IN THE
// JOB rather than leaning on core's default
// (task 2026-08-06-arm-projection-and-void-check).
//
//   output.project_cad_faces                      — PR 307, was false
//   lattice.require_lattice_void_reaches_exterior — PR 305, was false
//
// ★ EVERY TEST HERE DRIVES THE REAL SERIALIZER, for the reason
// LatticeRetentionControlTests states and this project keeps re-learning: four
// consecutive PRs shipped app-side defects behind green checks, and one passed
// 31 tests against a code path the maintainer could not reach. So these go
// through `RemoteRun.buildJobJSON()` and `RelatticeJobBuilder.build` — the two
// functions that produce the bytes a worker actually receives — and never
// against a dictionary a test assembled itself.
//
// ★ WHY THE APP SENDS THE KEYS AT ALL, when core defaults both to true and
// omitting them would run identically. `run_info` echoes the job it was given,
// so "the key was absent" and "the user asked for this" are the same bytes
// there. Writing them makes the receipt able to distinguish what was ASKED FOR
// from what was DEFAULTED — which is the only way a run months from now can be
// attributed, and it is the thing the dropped outer wall line width cost a week
// over. Core still OWNS the default; the app states the user's answer.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class DefaultArmingTests: XCTestCase {

    // MARK: - harness: the REAL job-building paths

    private static func request(lattice: LatticeSpec?,
                                projectCADFaces: Bool = true) -> RunRequest {
        RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "",
            rulesPath: "", resolution: 64, projectName: "arming",
            anchorFaceIDs: [3],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11],
                                                force: SIMD3(0, 0, -250))],
            minimizePlastic: true,
            buildDirection: SIMD3(0, 0, 1),
            infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: lattice,
            projectCADFaces: projectCADFaces)
    }

    private static func optimizeJob(lattice: LatticeSpec?,
                                    projectCADFaces: Bool = true) throws
        -> [String: Any] {
        let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757,
                                     expectedFingerprint: "test")
        let run = RemoteRun(config: cfg,
                            request: request(lattice: lattice,
                                             projectCADFaces: projectCADFaces),
                            progress: { _, _, _ in true }, onVariant: { _ in })
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: try run.buildJobJSON())
                as? [String: Any])
    }

    private static func relatticeJob(lattice: LatticeSpec?) throws
        -> [String: Any] {
        let original = try JSONSerialization.data(
            withJSONObject: try optimizeJob(lattice: nil), options: [.sortedKeys])
        let data = try RelatticeJobBuilder.build(
            original: original, designFingerprint: 0xDEAD_BEEF,
            achievedVolumeFraction: 0.42, designFileName: "design.bin",
            lattice: lattice)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A runnable uniform lattice spec — the shape that actually reaches a
    /// worker. Built through `LatticeSettings.runSpec` rather than by calling
    /// `LatticeSpec.init` directly, so the test exercises the same resolution
    /// path the app uses and cannot pass against a spec the app never builds.
    private static func spec(requireVoid: Bool) throws -> LatticeSpec {
        var s = LatticeSettings(enabled: true)
        s.densityMode = .uniform
        s.requireVoidReachesExterior = requireVoid
        return try XCTUnwrap(s.runSpec(lineWidthMM: 0.45),
                             "the uniform lattice settings must produce a spec")
    }

    // MARK: - output.project_cad_faces

    func testOptimizeJobSendsProjectCADFacesExplicitlyAndArmed() throws {
        let job = try Self.optimizeJob(lattice: nil)
        let output = try XCTUnwrap(job["output"] as? [String: Any])
        // PRESENT — not merely correct-by-omission. This is the assertion that
        // fails today, before the app was taught to write the key at all.
        XCTAssertNotNil(output["project_cad_faces"],
                        "the optimize job must SEND output.project_cad_faces, "
                        + "not rely on core's default — the receipt cannot "
                        + "otherwise tell an ask from an assumption")
        XCTAssertEqual(output["project_cad_faces"] as? Bool, true,
                       "and it must be ARMED by default")
    }

    func testProjectCADFacesOffControlReachesTheJob() throws {
        let job = try Self.optimizeJob(lattice: nil, projectCADFaces: false)
        let output = try XCTUnwrap(job["output"] as? [String: Any])
        XCTAssertEqual(output["project_cad_faces"] as? Bool, false,
                       "the OFF control must reach the worker — he has to be "
                       + "able to run the same job both ways")
    }

    /// The chain the user actually touches: the project setting, through
    /// `AppModel.makeRunRequest`'s field, into the emitted job. A test that only
    /// drove `RunRequest` directly would pass with the project setting wired to
    /// nothing.
    func testProjectSettingDefaultsArmedAndSurvivesTheRequest() {
        let project = ProjectModel(id: UUID(), name: "P", material: "PLA",
                                   process: .fdm, importedFile: nil,
                                   importedMesh: nil)
        XCTAssertTrue(project.projectCADFaces,
                      "a fresh project asks for CAD-face projection")
        XCTAssertTrue(Self.request(lattice: nil).projectCADFaces,
                      "and a request built with no opinion carries it")
        XCTAssertFalse(Self.request(lattice: nil, projectCADFaces: false)
                        .projectCADFaces,
                       "while an explicit off survives into the request")
    }

    /// Flipping it must re-enable Optimize rather than leave a result on screen
    /// that was produced the other way. `RunRequest` is `Equatable` and the
    /// workspace gates on that equality, so this is the whole mechanism.
    func testProjectCADFacesIsPartOfTheRequestIdentity() {
        XCTAssertNotEqual(Self.request(lattice: nil, projectCADFaces: true),
                          Self.request(lattice: nil, projectCADFaces: false),
                          "two requests differing only in CAD-face projection "
                          + "must not compare equal, or the workspace would "
                          + "leave Optimize disabled after the switch moved")
    }

    // MARK: - lattice.require_lattice_void_reaches_exterior

    func testOptimizeJobSendsVoidRuleExplicitlyAndArmed() throws {
        let job = try Self.optimizeJob(lattice: try Self.spec(requireVoid: true))
        let lat = try XCTUnwrap(job["lattice"] as? [String: Any])
        XCTAssertNotNil(lat["require_lattice_void_reaches_exterior"],
                        "the optimize job must SEND the enclosed-void rule — "
                        + "this is the switch that can refuse a rung, so the "
                        + "record must say whether it was asked for")
        XCTAssertEqual(lat["require_lattice_void_reaches_exterior"] as? Bool, true,
                       "and it must be ARMED by default")
    }

    /// ★ THE RE-LATTICE PATH WRITES IT TOO, and this is not redundant with the
    /// test above. `RelatticeJobBuilder` WIPES `job["lattice"]` and rebuilds it
    /// from the current settings, so an inherited key would not survive — the
    /// key has to be written at BOTH sites. A re-lattice also THROWS on a sealed
    /// cavity rather than skipping a rung, because it exists to make one object.
    func testRelatticeJobSendsVoidRuleExplicitlyAndArmed() throws {
        let job = try Self.relatticeJob(lattice: try Self.spec(requireVoid: true))
        let lat = try XCTUnwrap(job["lattice"] as? [String: Any])
        XCTAssertEqual(lat["require_lattice_void_reaches_exterior"] as? Bool, true,
                       "the re-lattice job must carry the armed rule as well — "
                       + "it rebuilds the lattice block from scratch, so an "
                       + "inherited key would be silently dropped")
    }

    func testVoidRuleOffControlReachesBothJobPaths() throws {
        let opt = try Self.optimizeJob(lattice: try Self.spec(requireVoid: false))
        let optLat = try XCTUnwrap(opt["lattice"] as? [String: Any])
        XCTAssertEqual(optLat["require_lattice_void_reaches_exterior"] as? Bool,
                       false, "the OFF control must reach the optimize job")

        let re = try Self.relatticeJob(lattice: try Self.spec(requireVoid: false))
        let reLat = try XCTUnwrap(re["lattice"] as? [String: Any])
        XCTAssertEqual(reLat["require_lattice_void_reaches_exterior"] as? Bool,
                       false, "and the re-lattice job")
    }

    func testLatticeSettingsDefaultsArmed() {
        XCTAssertTrue(LatticeSettings(enabled: true).requireVoidReachesExterior,
                      "fresh lattice settings ask for the enclosed-void rule")
    }

    // MARK: - the two are INDEPENDENT

    /// They are not one switch and must never become one. Projection changes
    /// geometry; the void rule refuses runs. If turning one off moved the other,
    /// an evaluation of one would silently be an evaluation of both.
    func testTheTwoSwitchesAreIndependentInTheEmittedJob() throws {
        let a = try Self.optimizeJob(lattice: try Self.spec(requireVoid: true),
                                     projectCADFaces: false)
        XCTAssertEqual((a["output"] as? [String: Any])?["project_cad_faces"] as? Bool,
                       false)
        XCTAssertEqual((a["lattice"] as? [String: Any])?[
                        "require_lattice_void_reaches_exterior"] as? Bool, true,
                       "disarming projection must leave the void rule armed")

        let b = try Self.optimizeJob(lattice: try Self.spec(requireVoid: false),
                                     projectCADFaces: true)
        XCTAssertEqual((b["output"] as? [String: Any])?["project_cad_faces"] as? Bool,
                       true,
                       "disarming the void rule must leave projection armed")
        XCTAssertEqual((b["lattice"] as? [String: Any])?[
                        "require_lattice_void_reaches_exterior"] as? Bool, false)
    }

    // MARK: - persistence: a reopened project must not silently opt out

    /// ★ A PROJECT SAVED BEFORE THIS TASK MUST REOPEN ARMED. Both settings
    /// decode nil → TRUE, which is the opposite of how every other optional
    /// flag on these types decodes, and deliberately so: those meant "off" when
    /// they were absent, and these mean "the maintainer armed it". Decoding to
    /// false would opt every existing project out of the change without saying
    /// anything.
    func testProjectsSavedBeforeThisTaskReopenArmed() throws {
        // A snapshot with NEITHER field, exactly as one written before this task.
        var settings = LatticeSettings(enabled: true)
        settings.requireVoidReachesExterior = true
        let encoded = try JSONEncoder().encode(settings)
        var dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        dict.removeValue(forKey: "requireVoidReachesExterior")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(LatticeSettings.self, from: stripped)
        XCTAssertTrue(decoded.requireVoidReachesExterior,
                      "lattice settings with no stored value reopen ARMED")

        // And the round trip preserves an explicit OFF, or the control would be
        // a setting the user can change but not keep.
        settings.requireVoidReachesExterior = false
        let off = try JSONDecoder().decode(
            LatticeSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertFalse(off.requireVoidReachesExterior,
                       "an explicit OFF survives a save/reopen")
    }
}
