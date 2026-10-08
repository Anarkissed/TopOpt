// FlexibleAngledGoldenTests — the ruling's last test, from batch AP0 on: "every existing face press is
// unchanged: job bytes and stage hashes identical" (task 2026-10-07, angled presses; spec §14, §15).
// The goldens were recorded at 01ec5e3c, before any angled-press code (FlexibleAngledGoldenRecorder);
// S1 re-bases them after the #361 sync and every later batch must equal that base.
//
// Each comparison has its RED control beside it — a pin that can actually SEE the change it guards:
//   * run-job bytes: one face at +0.001 kg changes exactly ONE line (weight_n), and a one-byte edit
//     (deepest 4 → 5 mm) is caught as exactly one byte; every send of a held project is its own job;
//   * lattice subtrees: groupColours = [:] instead of nil changes the bytes (the nil rule presses rely on);
//     the canonical form sees one changed group depth and is blind only to the UUID pairs' ORDER;
//   * frames: one column's entry + 1 ulp is caught;
//   * fields: one voxel's owner + 1 is caught;
//   * the probe: each form is pinned to its OWN base text (the edge is refused for its missing
//     face_region_id, the tilt for its unknown press_direction — critique core-purity #1);
//   * stage jobs: a lattice-stage setting the stage job reads changes the bytes, while a Flexible face
//     weight does NOT — the stage job (and the LatticeJobJSONDump hashes) cannot see lattice.flexible,
//     so the run-job and subtree goldens carry the Flexible claim.
// FLEX_AP_MUTATE=weight | other-send | nil-rule | ulp | edge-as-tilt | send-weight | owner | depth feeds
// a control's change into the MAIN comparison, to prove that comparison goes RED on it
// (FLEX_AP_GOLDEN_DIR = a perturbed copy proves the same for every golden file).
//
// ★ AP0 FIX-UP (verifier, 2026-10-07): every comparison runs under ANY hash seed — CI's `swift test`
// sets none — except the subtrees' RAW bytes (UUID-keyed dictionaries encode in hash order; measured:
// 0004 / r5 differed in 2 of 3 unseeded launches, while his r5's jobs were identical in 3 of 3 and in
// the verifier's 12 of 12). The subtrees are compared canonically in every run instead. No compared
// golden carries core's fingerprint (the repo HEAD when build_core.sh ran).
import XCTest
import CryptoKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleAngledGoldenTests: XCTestCase {
    typealias G = FlexibleAngledGoldens

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
    /// ★ AP0 FIX-UP: runs under ANY hash seed (CI's) — its outlines' loop order is fixed at the source
    /// (LatticeFaceOutline, ruling 1); a launch whose bytes differed would break that ruling, so it FAILS.
    func testHisRound5HeldSendBytesUnchanged() async throws {
        print("FLEX-AP testHisRound5HeldSendBytesUnchanged: \(G.hashingMode)")
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

    /// C1's pad's scene job.
    func testSceneJobBytesUnchanged() async throws {
        let (pad, top, _) = try await G.padModel(self)
        let padScene = try G.sceneJob(pad, roots: [G.repo])
        try G.assertGolden(padScene, "c1_pad_model_scene_job.json")
        // ★ RED CONTROL: the scene reads the FIRST pressed face; another face makes another document
        pad.rest(top)
        await pad.waitForIdle()
        XCTAssertNotEqual(try G.sceneJob(pad, roots: [G.repo]), padScene, "control: the scene job sees which face is pressed")
    }

    /// His r5's scene job (AP0 fix-up: its own test, run under any hash seed).
    func testHisRound5SceneJobBytesUnchanged() async throws {
        print("FLEX-AP testHisRound5SceneJobBytesUnchanged: \(G.hashingMode)")
        let (r, m, _) = try await G.hisRound5Model(self)
        try G.assertGolden(try G.sceneJob(m, roots: G.rootToken(r)), "his_r5_scene_job.json")
    }

    /// ★ AP0 FIX-UP: EVERY send the Export step offers today, and the scene job, of his 0004 and r5 as
    /// saved and of the A1 store's three Flexible projects (frozen; the M2 stand's face 2, the pad's
    /// five stamped presses in three groups, the later save of 'Pad split top'): the sends are the
    /// recorded ones, and each one's job bytes are the golden's.
    func testEveryExistingSendKeepsItsJobBytes() async throws {
        print("FLEX-AP testEveryExistingSendKeepsItsJobBytes: \(G.hashingMode)")
        var checked = 0, crossChecked = 0
        for label in G.sendSets {
            let (roots, m) = try await G.sendSetModel(label, self)
            if G.mutation == "send-weight", let k = m.loadedKeys.first {
                m.edit({ s in if var f = s.face(k.region) { f.weightKg += 0.001; s.setFace(f) } }, recompute: false)
            }
            let s = G.sends(m)
            print("FLEX-AP \(label): \(s.count) send(s) \(s.map { "\($0.title) resting \($0.resting)" })")
            XCTAssertEqual(G.sendIndex(label, s), try G.read("\(label)_sends.txt"), "\(label): the sends offered are the recorded ones")
            var jobs: [String] = []
            for (n, send) in s.enumerated() {
                let job = try G.runJob(m, resting: Set(send.resting), roots: roots)
                try G.assertGolden(job, G.sendFile(label, n + 1))
                jobs.append(job)
                checked += 1
            }
            try G.assertGolden(try G.sceneJob(m, roots: roots), G.sceneFile(label))
            // ★ RED CONTROL: each send is its own job — send 2's bytes are not send 1's golden
            if jobs.count > 1 {
                XCTAssertNotEqual(jobs[1], try G.read(G.sendFile(label, 1)), "control: \(label) send 2 is not send 1's golden")
                crossChecked += 1
            }
        }
        print("FLEX-AP every existing send: \(checked) job(s) over \(G.sendSets.count) projects; \(crossChecked) cross-send control(s)")
        XCTAssertGreaterThan(crossChecked, 0, "premise: a held project offers more than one send")
    }

    // MARK: - the saved project

    /// The `lattice` subtree of 0004, 0004_r5, 102117B9 and the A1 store's three Flexible projects,
    /// decoded and re-encoded with the store's encoder settings (never re-saved: a save moves savedAt).
    /// ★ AP0 FIX-UP: the WHOLE subtree is compared in EVERY run (CI included), canonically: a UUID-keyed
    /// dictionary (groupDepthMM, groupRoles, …) encodes as a [key, value, …] array in HASH order, so its
    /// raw bytes are compared only under SWIFT_DETERMINISTIC_HASHING=1; the canonical form makes each such
    /// array an object and sorts every key (G.canonicalSubtree). The `flexible` block is also compared
    /// on its own (one canonical serializer — a `"presses":[]` would show on either side).
    func testLatticeSubtreesReEncodeIdentically() throws {
        let mutate: ((inout LatticeSettings) -> Void)? = G.mutation == "nil-rule" ? { $0.flexible?.groupColours = [:] }
            : G.mutation == "depth" ? { l in if let k = l.groupDepthMM.keys.min(by: { $0.uuidString < $1.uuidString }) { l.groupDepthMM[k]! += 1 } }
            : nil
        for s in G.subtreeSources {
            let now = try G.latticeSubtree(s.url, mutate: mutate)
            let golden = try G.read(s.name)
            XCTAssertEqual(try G.flexibleBlock(now), try G.flexibleBlock(golden), "\(s.name): the flexible block, canonical")
            let (a, b) = (try G.canonicalSubtree(now), try G.canonicalSubtree(golden))
            if a != b {
                let d = G.lineDiff(a, b)
                print("FLEX-AP SUBTREE \(s.name) canonical: DIFFERS — \(d.count) line(s); first: \(d.prefix(4).map { "line \($0.line): now '\($0.now)' was '\($0.was)'" })")
            }
            XCTAssertEqual(a, b, "\(s.name): the whole subtree, canonical")
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
        // ★ RED CONTROL: the canonical form sees ONE changed value (his Top group's depth + 1 mm) …
        let r5 = G.subtreeSources[1], top = Self.r5TopGroup
        let deeper = try G.latticeSubtree(r5.url) { $0.groupDepthMM[top]! += 1 }
        let dd = G.lineDiff(try G.canonicalSubtree(deeper), try G.canonicalSubtree(try G.read(r5.name)))
        print("FLEX-AP control r5 Top depth + 1 mm: \(dd.count) canonical line(s) differ: \(dd.map { "'\($0.was.trimmingCharacters(in: .whitespaces))' → '\($0.now.trimmingCharacters(in: .whitespaces))'" })")
        XCTAssertEqual(dd.count, 1, "control: one depth is one canonical line")
        // … and is blind ONLY to the order of the UUID pairs (what the hash seed moves)
        let raw = try G.read(r5.name)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let pairs = try XCTUnwrap(obj["groupDepthMM"] as? [Any])
        XCTAssertGreaterThanOrEqual(pairs.count, 4, "premise: r5 states two group depths")
        var swapped = obj
        swapped["groupDepthMM"] = Array(pairs[2...]) + Array(pairs[..<2])
        let swappedText = String(decoding: try JSONSerialization.data(withJSONObject: swapped, options: [.sortedKeys]), as: UTF8.self)
        let unswappedText = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertNotEqual(swappedText, unswappedText, "premise: the swap is a real edit of the bytes")
        XCTAssertEqual(try G.canonicalSubtree(swappedText), try G.canonicalSubtree(raw), "the pairs' order is all the canonical form forgets")
        // the whole subtree, byte for byte, where the bytes are not the hash seed's
        print("FLEX-AP testLatticeSubtreesReEncodeIdentically (raw bytes): \(G.hashingMode)")
        guard G.deterministicHashing else {
            print("FLEX-AP PART-SKIP FlexibleAngledGoldenTests.testLatticeSubtreesReEncodeIdentically: the RAW subtree bytes need SWIFT_DETERMINISTIC_HASHING=1 (UUID-keyed dictionaries encode in hash order); the canonical subtrees and the flexible blocks were compared")
            return
        }
        for s in G.subtreeSources {
            try G.assertGolden(try G.latticeSubtree(s.url, mutate: mutate), s.name)
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

    /// ★ AP0 FIX-UP: core's STEP cube (B-rep faces, tied squares — what principal_2d decides) and his
    /// 'l bracket 3' (frozen S0), nothing pressed (STEP: skipped, printed and counted, when OCCT throws).
    func testFramesAreTheGoldenOnStepParts() async throws {
        for (file, label, m) in try await G.stepFrameModels(self, "FlexibleAngledGoldenTests.testFramesAreTheGoldenOnStepParts") {
            try G.assertGolden(try await G.frames(m, label: label), file)
        }
    }

    // MARK: - core's designs and fields

    /// ★ AP0 FIX-UP: the base S1 attributes ownership against — core's `in_stack` becomes
    /// `stack_owns_projection` with #361's addendum (spec §0, §15.2, §20). On C1's pad and his 0004 /
    /// r5 as saved: core's design of every loaded key, core's assembled field of each squeeze group (or
    /// its refusal), its voxel counts and handovers, and the field the app's lattice is built from.
    func testCoreFieldsAndDesignsAreTheGolden() async throws {
        print("FLEX-AP testCoreFieldsAndDesignsAreTheGolden: \(G.hashingMode)")
        for label in G.fieldSets {
            let m = try await G.fieldSetModel(label, self)
            let text = try await G.fieldsText(m, label: label, perturbOwner: G.mutation == "owner")
            try G.assertGolden(text, "fields_\(label).txt")
            // ★ RED CONTROL: ONE voxel's owner + 1 is seen by the digest the golden holds
            guard let g = m.squeezeGroups.first else { continue }
            let keys = m.loadedKeys.filter { g.regions.contains($0.region) }.sorted { ($0.region, $0.rotation) < ($1.region, $1.rotation) }
            let build = m.build
            guard let f = try? await m.workerForTests.withScene({
                try $0.densityField(faces: keys.map(\.region), rotations: keys.map(\.rotation), build: build)
            }) else { continue }
            let plain = G.fieldLines(f), moved = G.fieldLines(f, perturbOwner: true)
            XCTAssertTrue(text.contains(plain[1]), "premise: \(label) group \(g.number)'s digest is the golden's")
            XCTAssertNotEqual(plain, moved, "control: \(label): one voxel's owner is seen")
            print("FLEX-AP control \(label) one owner + 1: \(zip(plain, moved).filter { $0 != $1 }.count) line(s) differ")
        }
    }

    // MARK: - the fingerprint is never compared

    /// ★ AP0 FIX-UP: core's fingerprint is the repo HEAD when build_core.sh ran (CI builds at the PR's
    /// head; every rebuild at another commit changes it with no change to core), so no golden a test
    /// compares may carry it — only MANIFEST.txt (and the probe's JSON, whose "core" key no test reads).
    func testNoComparedGoldenCarriesTheCoreFingerprint() throws {
        // this build's fingerprint and the one the goldens were recorded against (MANIFEST.txt)
        let manifest = try G.read("MANIFEST.txt")
        let recorded = try XCTUnwrap(manifest.components(separatedBy: "built against core ").dropFirst().first
            .map { tail in String(tail.prefix { c in c.isLetter || c.isNumber }) }, "the manifest names the core the goldens were built against")
        let prints = Set([CoreFingerprint.value, recorded].filter { $0.count >= 7 })   // ("dev" = no git: nothing to scan for)
        func carries(_ text: String) -> Bool { prints.contains { text.contains($0) } }
        let files = try FileManager.default.contentsOfDirectory(atPath: G.dir.path).sorted()
        var scanned = 0
        for f in files where f != "MANIFEST.txt" && !f.hasPrefix("probe_") {
            XCTAssertFalse(carries(try G.read(f)), "\(f) carries a core fingerprint \(prints.sorted())")
            scanned += 1
        }
        print("FLEX-AP fingerprints \(prints.sorted()) (this build's, the goldens'): absent from \(scanned) compared golden(s)")
        XCTAssertGreaterThan(scanned, 20)
        // ★ RED CONTROL: the scan sees the header form AP0 first recorded, which carried it
        XCTAssertTrue(carries("# FlexStackInfo golden · C1 pad (top pressed 30 kg, bottom resting) · core \(recorded)"),
                      "control: the scan sees a fingerprint in a golden line")
    }

    // MARK: - the probe's base refusals

    /// The probe's documents (spec §10) through core's own parser: the control parses, and each angled
    /// form gets ITS OWN recorded base refusal. After S1 core accepts both: S1 flips this test and
    /// keeps probe_refusals_base.json for AP6's injected-probe test (the recorder never overwrites it).
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
    /// (AppModel.makeLatticeRunRequest and RemoteRun.buildJobJSON have no `.flexible`; previewBakeInputs,
    /// H12, is the octet PREVIEW's trigger, not this job), so its hashes guard #354's job only.
    /// ★ AP0 FIX-UP: runs under ANY hash seed: the two jobs are built in one process, and the premise
    /// "the same project twice gives the same bytes" would catch a hash-ordered job.
    func testTheStageJobSeesALatticeSettingButNeverFlexible() throws {
        print("FLEX-AP testTheStageJobSeesALatticeSettingButNeverFlexible: \(G.hashingMode)")
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
