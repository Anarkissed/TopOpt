// FlexibleAngledGoldenTests — the ruling's last test, from batch AP0 on: "every existing face press is
// unchanged: job bytes and stage hashes identical" (task 2026-10-07, angled presses; spec §14, §15).
// The goldens were recorded at 01ec5e3c, before any angled-press code (FlexibleAngledGoldenRecorder);
// S1 re-bases them after the #361 sync and every later batch must equal that base.
//
// Each comparison has its RED control beside it — a pin that can actually SEE the change it guards:
//   * run-job bytes: one face at +0.001 kg changes exactly ONE line (weight_n), and a one-byte edit
//     (deepest 4 → 5 mm) is caught as exactly one byte;
//   * lattice subtrees: groupColours = [:] instead of nil changes the bytes (the nil rule presses rely on);
//   * frames: one column's entry + 1 ulp is caught;
//   * the probe: each form is pinned to its OWN base text (the edge is refused for its missing
//     face_region_id, the tilt for its unknown press_direction — critique core-purity #1);
//   * stage jobs: a lattice-stage setting the stage job reads changes the bytes, while a Flexible face
//     weight does NOT — the stage job (and the LatticeJobJSONDump hashes) cannot see lattice.flexible,
//     so the run-job and subtree goldens carry the Flexible claim.
// FLEX_AP_MUTATE=weight | other-send | nil-rule | ulp | edge-as-tilt feeds a control's change into the MAIN
// comparison, to prove that comparison goes RED on it (FLEX_AP_GOLDEN_DIR = a perturbed copy proves the
// same for every golden file).
import XCTest
import CryptoKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleAngledGoldenTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

    /// His jobs carry lattice outlines whose loops come out in HASH order unless the process runs
    /// with SWIFT_DETERMINISTIC_HASHING=1 — without it their bytes measure the hash seed (memory).
    private func requireDeterministicHashing(_ what: String) throws {
        print("FLEX-AP \(what): \(G.hashingMode)")
        guard G.deterministicHashing else {
            throw FlexiblePressFixtures.skip("FlexibleAngledGoldenTests.\(what)",
                                             "needs SWIFT_DETERMINISTIC_HASHING=1 (his job's outline loops are in hash order)")
        }
    }

    // MARK: - job bytes

    /// C1's pad: the pure encoder (curves; a stamp) and the app's own model (top pressed, bottom resting).
    func testFacePressRunJobBytesUnchanged() async throws {
        let pure = try G.padPureRunJob(weightDeltaKg: G.mutation == "weight" ? 0.001 : 0)
        try G.assertGolden(pure, "c1_pad_pure_run_job.json")
        try G.assertGolden(try G.padPureStampRunJob(), "c1_pad_pure_stamp_run_job.json")
        let (m, _, _) = try await G.padModel(self)
        try G.assertGolden(try G.runJob(m, roots: [G.repo]), "c1_pad_model_run_job.json")
        XCTAssertFalse(try G.runJob(m, roots: [G.repo]).contains(FlexibleHisProject.repoRoot.path), "no machine path left in the bytes")

        // ★ RED CONTROL: the same settings with the pressed face at +0.001 kg
        let golden = try G.read("c1_pad_pure_run_job.json")
        let heavier = try G.padPureRunJob(weightDeltaKg: 0.001)
        let lines = G.lineDiff(heavier, golden)
        print("FLEX-AP control +0.001 kg: \(lines.count) line(s), \(G.byteDiff(heavier, golden)) byte(s) differ: "
              + lines.map { "'\($0.was.trimmingCharacters(in: .whitespaces))' → '\($0.now.trimmingCharacters(in: .whitespaces))'" }.joined(separator: "; "))
        XCTAssertNotEqual(heavier, golden, "control: +0.001 kg must not pass the golden")
        XCTAssertEqual(lines.count, 1, "control: exactly the one weight line moves")
        XCTAssertTrue(lines.first?.now.contains("\"weight_n\"") == true, "control: it is weight_n")
        // ★ RED CONTROL: ONE byte (deepest 4 → 5 mm) is caught
        let deeper = try G.padPureRunJob(deepestDeltaMM: 1)
        print("FLEX-AP control deepest +1 mm: \(G.byteDiff(deeper, golden)) byte(s) differ")
        XCTAssertNotEqual(deeper, golden)
        XCTAssertEqual(G.byteDiff(deeper, golden), 1, "control: a one-byte change is seen")
    }

    /// His round-5 pad AS SAVED: the job of the Export step's first send ("Send Group 1 only").
    func testHisRound5HeldSendBytesUnchanged() async throws {
        try requireDeterministicHashing("testHisRound5HeldSendBytesUnchanged")
        let (r, m, first) = try await G.hisRound5Model(self)
        let recorded = try G.read("his_r5_held_send.txt")
        print("FLEX-AP his r5 held send: [\(first.title)] resting \(first.resting)")
        XCTAssertTrue(recorded.hasPrefix("title \(first.title)\nresting \(first.resting)\n"), "the same send: \(recorded)")
        let sent = G.mutation == "other-send" ? try XCTUnwrap(m.coreHold?.fixes.last) : first
        let job = try G.runJob(m, resting: Set(sent.resting), roots: G.rootToken(r))
        XCTAssertFalse(job.contains(r.root.lastPathComponent), "no temp path left in the bytes")
        try G.assertGolden(job, "his_r5_held_send_run_job.json")
        // ★ RED CONTROL: the OTHER send (Group 2 only) is a different job
        let fixes = try XCTUnwrap(m.coreHold?.fixes)
        if fixes.count > 1 {
            let other = try G.runJob(m, resting: Set(fixes[1].resting), roots: G.rootToken(r))
            XCTAssertNotEqual(other, try G.read("his_r5_held_send_run_job.json"), "control: [\(fixes[1].title)] is not the golden")
        }
    }

    /// The scene jobs (C1's pad; his r5 under deterministic hashing).
    func testSceneJobBytesUnchanged() async throws {
        let (pad, top, _) = try await G.padModel(self)
        let padScene = try G.sceneJob(pad, roots: [G.repo])
        try G.assertGolden(padScene, "c1_pad_model_scene_job.json")
        // ★ RED CONTROL: the scene reads the FIRST pressed face; another face makes another document
        pad.rest(top)
        await pad.waitForIdle()
        XCTAssertNotEqual(try G.sceneJob(pad, roots: [G.repo]), padScene, "control: the scene job sees which face is pressed")

        try requireDeterministicHashing("testSceneJobBytesUnchanged (his r5 part)")
        let (r, m, _) = try await G.hisRound5Model(self)
        try G.assertGolden(try G.sceneJob(m, roots: G.rootToken(r)), "his_r5_scene_job.json")
    }

    // MARK: - the saved project

    /// The `lattice` subtree of 0004, 0004_r5 and 102117B9, decoded and re-encoded with the store's
    /// encoder settings (never re-saved: a save moves savedAt).
    /// ★ MEASURED: the WHOLE subtree's bytes depend on the hash seed — a UUID-keyed dictionary
    /// (groupDepthMM, groupRoles) encodes as a [key, value, …] array in hash order, so 0004_r5 (two
    /// groups) differed run to run without SWIFT_DETERMINISTIC_HASHING=1. The `flexible` block holds only
    /// arrays and string-keyed dictionaries (sorted), so ITS comparison runs always: both sides through
    /// one canonical serializer (JSONSerialization, sorted keys) — a `"presses":[]` would show on either.
    func testLatticeSubtreesReEncodeIdentically() throws {
        for s in G.subtreeSources {
            let now = try G.latticeSubtree(s.url, mutate: G.mutation == "nil-rule" ? { $0.flexible?.groupColours = [:] } : nil)
            XCTAssertEqual(try G.flexibleBlock(now), try G.flexibleBlock(try G.read(s.name)),
                           "\(s.name): the flexible block, canonical")
        }
        // ★ RED CONTROL: an EMPTY optional where nil was — the same nil rule `presses` will rely on
        for s in G.subtreeSources.prefix(2) {
            let empty = try G.latticeSubtree(s.url) { l in
                XCTAssertNil(l.flexible?.groupColours, "premise: \(s.name) saved no group colours")
                l.flexible?.groupColours = [:]
            }
            print("FLEX-AP control \(s.name) groupColours [:] → \(G.byteDiff(try G.flexibleBlock(empty), try G.flexibleBlock(try G.read(s.name)))) byte(s) of the flexible block differ")
            XCTAssertNotEqual(try G.flexibleBlock(empty), try G.flexibleBlock(try G.read(s.name)), "control: [:] instead of nil changes \(s.name)")
        }
        // the whole subtree, byte for byte, where the bytes are not the hash seed's
        print("FLEX-AP testLatticeSubtreesReEncodeIdentically (whole subtree): \(G.hashingMode)")
        guard G.deterministicHashing else {
            print("FLEX-AP PART-SKIP FlexibleAngledGoldenTests.testLatticeSubtreesReEncodeIdentically: the whole-subtree bytes need SWIFT_DETERMINISTIC_HASHING=1 (UUID-keyed dictionaries encode in hash order); the flexible blocks were compared")
            return
        }
        for s in G.subtreeSources {
            try G.assertGolden(try G.latticeSubtree(s.url, mutate: G.mutation == "nil-rule" ? { $0.flexible?.groupColours = [:] } : nil), s.name)
        }
    }

    // MARK: - core's frames

    /// Core's FlexStackInfo, bit for bit, for every region of C1's pad, his 0004 and 0004_r5 and the cube.
    func testFacePressFramesAreTheGolden() async throws {
        let (pad, _, _) = try await G.padModel(self)
        var mutated: ((FlexStackInfo) -> FlexStackInfo)?
        if G.mutation == "ulp" { mutated = { G.oneULP($0) } }
        let padText = try await G.frames(pad, label: "C1 pad (top pressed 30 kg, bottom resting)", perturb: mutated)
        try G.assertGolden(padText, "frames_c1_pad.txt")
        // ★ RED CONTROL: one column's entry + 1 ulp
        let ulp = try await G.frames(pad, label: "C1 pad (top pressed 30 kg, bottom resting)", perturb: G.oneULP)
        let d = G.lineDiff(ulp, try G.read("frames_c1_pad.txt"))
        print("FLEX-AP control 1 ulp: \(d.count) line(s) differ: \(d.map { "line \($0.line)" })")
        XCTAssertNotEqual(ulp, try G.read("frames_c1_pad.txt"), "control: one ulp is seen")

        let r3 = try FlexiblePressFixtures.his0004(self)
        let m3 = try await FlexibleHisProject.openedModel(r3.project, test: self)
        try G.assertGolden(try await G.frames(m3, label: "his 0004 as saved"), "frames_his_0004.txt")
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let m5 = try await FlexibleHisProject.openedModel(r5.project, test: self)
        try G.assertGolden(try await G.frames(m5, label: "his 0004_r5 as saved"), "frames_his_0004_r5.txt")
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "the 60 mm cube")
        try G.assertGolden(try await G.frames(cube, label: "60 mm cube (nothing pressed)"), "frames_cube60.txt")
    }

    /// The same on his M2 stand (STEP: skipped, printed and counted, when OCCT throws).
    func testFacePressFramesAreTheGoldenOnTheM2Stand() async throws {
        let m2 = try await G.m2Model(self, "FlexibleAngledGoldenTests.testFacePressFramesAreTheGoldenOnTheM2Stand")
        try G.assertGolden(try await G.frames(m2, label: "M2 stand (top pressed 5 kg, bottom resting)"), "frames_m2.txt")
    }

    // MARK: - the probe's base refusals

    /// The probe's documents (spec §10) through core's own parser: the control parses, and each angled
    /// form gets ITS OWN recorded base refusal. After S1 core accepts both: S1 flips this test and
    /// keeps probe_refusals_base.json for AP6's injected-probe test.
    func testProbeDocumentsGetTheRecordedBaseRefusals() throws {
        let golden = try G.read("probe_refusals_base.json")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? [String: Any])
        let tiltText = try XCTUnwrap(obj["tilt"] as? String, "the base refuses the tilt")
        let edgeText = try XCTUnwrap(obj["edge"] as? String, "the base refuses the edge")
        XCTAssertTrue(obj["control"] is NSNull, "the control parsed at the base")
        let now = try G.probeAnswers()
        print("FLEX-AP probe now: control \(String(describing: now["control"] ?? nil)) · tilt '\(now["tilt"].flatMap { $0 } ?? "accepted")' · edge '\(now["edge"].flatMap { $0 } ?? "accepted")'")
        XCTAssertNil(now["control"] ?? "missing", "★ the control (the entry exactly as faceEntry writes it) must parse")
        XCTAssertEqual(now["tilt"] ?? nil, tiltText)
        XCTAssertEqual((G.mutation == "edge-as-tilt" ? now["tilt"] : now["edge"]) ?? nil, edgeText)
        // ★ RED CONTROL: each form has its OWN text — the edge is refused before its direction is read
        XCTAssertNotEqual(tiltText, edgeText, "control: the two forms are told apart")
        XCTAssertTrue(tiltText.contains("press_direction"), tiltText)
        XCTAssertTrue(edgeText.contains("face_region_id"), edgeText)
        XCTAssertFalse(edgeText.contains("press_direction"), "the edge's base refusal is its missing id, not the direction")
    }

    // MARK: - the stage job (what LatticeJobJSONDump hashes)

    /// ★ POSITIVE CONTROL for the stage hashes: on his r5 a lattice-stage setting the stage job reads
    /// moves its bytes; a Flexible face weight does not — the stage job never reads lattice.flexible
    /// (previewBakeInputs strips it, RemoteRunner never reads it), so its hashes guard #354's job only.
    func testTheStageJobSeesALatticeSettingButNeverFlexible() throws {
        try requireDeterministicHashing("testTheStageJobSeesALatticeSettingButNeverFlexible")
        let r = try FlexiblePressFixtures.hisRound5(self)
        func job() throws -> String {
            let req = try XCTUnwrap(r.app.makeLatticeRunRequest(), "his r5's lattice job")
            let obj = try JSONSerialization.jsonObject(with: try RemoteRun.buildJobJSON(req))
            return String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        }
        let base = try job()
        XCTAssertEqual(try job(), base, "premise: the same project twice gives the same bytes")
        // a lattice-stage setting the stage job reads: the depth of his "Top" include group
        let group = Self.r5TopGroup
        let was = try XCTUnwrap(r.project.lattice.groupDepthMM[group], "premise: group \(group) has a stated depth")
        r.project.lattice.groupDepthMM[group] = was + 1
        let moved = try job()
        let d = G.lineDiff(moved, base)
        print("FLEX-AP stage control: group \(group) depth \(was) → \(was + 1) mm moves \(d.count) line(s): "
              + d.prefix(4).map { "'\($0.was.trimmingCharacters(in: .whitespaces))' → '\($0.now.trimmingCharacters(in: .whitespaces))'" }.joined(separator: "; "))
        XCTAssertNotEqual(moved, base, "★ positive control: a setting the stage job reads changes its bytes")
        r.project.lattice.groupDepthMM[group] = was
        XCTAssertEqual(try job(), base)
        var flex = try XCTUnwrap(r.project.lattice.flexible)
        let i = try XCTUnwrap(flex.faces.firstIndex(where: \.isLoaded))
        flex.faces[i].weightKg += 1
        r.project.lattice.flexible = flex
        XCTAssertEqual(try job(), base, "★ the stage job cannot see lattice.flexible: its hashes guard #354's job only")
    }

    /// His r5's "Top" Load group, latticed (include, 4 mm in his file).
    static let r5TopGroup = UUID(uuidString: "92E96F3A-D8F7-4FB0-AF8D-56230DFB6BC0")!
}
