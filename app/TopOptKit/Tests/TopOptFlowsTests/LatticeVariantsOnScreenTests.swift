// LatticeVariantsOnScreenTests — the latticed variants an OPTIMIZE run produced,
// brought within reach of the app (task 2026-08-07-lattice-variants-on-screen).
//
// EVERY TEST HERE IS DRIVEN BY THE MAINTAINER'S OWN RUN. Worker job
// ca62f91cba4b422d (M2_verticalStand.step, four rungs, all accepted): its
// `report.json`, its four `variant_XXX_lattice.report.json` certification
// receipts, its `fields.bin` scalars and the exact `VARIANT`/`LATTICE` checkpoint
// lines its CLI printed are captured verbatim under
// evidence/2026-08-07-lattice-variants-on-screen/run_his/ and replayed here
// through the app's REAL `RemoteRun` against a real HTTP server (`StubWorker`).
// The two things that are not verbatim are stated where they are used: the
// solid meshes are stand-in cubes (their geometry is not what is under test and
// his are 14–17 MB each), and the four latticed meshes are represented by their
// real BYTE COUNTS via HEAD rather than their 5.17 GB of bytes.

import XCTest
import TopOptKit
@testable import TopOptFlows

final class LatticeVariantsOnScreenTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static let runDir = repoRoot.appendingPathComponent(
        "evidence/2026-08-07-lattice-variants-on-screen/run_his")

    /// His four rungs in ladder order (heaviest solid first), with the two masses
    /// the two objects actually have. The solid figures are the `fields.bin`
    /// scalars; the lattice figures are `lattice_mass_grams` from each rung's own
    /// certification receipt. Both sets are read from the captured files at run
    /// time — these are here so a reader can see the shape without opening them.
    ///
    ///   rung   solid (g)   latticed (g)   latticed mesh (bytes)
    ///   0.68     543.73        215.16       1 954 879 484
    ///   0.52     473.32        239.93       1 420 059 884
    ///   0.38     412.47        244.78       1 058 859 084
    ///   0.26     360.30        246.38         740 360 884   ← RECOMMENDED
    static let latticedMeshBytes: [String: Int] = [
        "variant_068_lattice.stl": 1_954_879_484,
        "variant_052_lattice.stl": 1_420_059_884,
        "variant_038_lattice.stl": 1_058_859_084,
        "variant_026_lattice.stl": 740_360_884,
    ]

    // MARK: - the fixture

    /// A directory the stub worker serves: his captured artifacts, plus stand-in
    /// solid meshes.
    private func makeFilesDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lattice-onscreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["report.json", "fields.bin",
                     "variant_026_lattice.report.json",
                     "variant_038_lattice.report.json",
                     "variant_052_lattice.report.json",
                     "variant_068_lattice.report.json"] {
            try FileManager.default.copyItem(
                at: Self.runDir.appendingPathComponent(name),
                to: dir.appendingPathComponent(name))
        }
        // STAND-IN SOLID MESHES. His are 14–17 MB of real isosurface; what the
        // client does with them (fetch, parse, keep) is covered by the existing
        // remote-runner tests and is not what this task changed. A 12-triangle cube
        // is enough for `fetchMesh` to accept the variant as real geometry, which
        // is all these tests need from the solid side.
        for tag in ["026", "038", "052", "068"] {
            try cubeSTL().write(to: dir.appendingPathComponent("variant_\(tag).stl"))
        }
        return dir
    }

    private func cubeSTL() -> Data {
        let s: Float = 10
        let v: [(Float, Float, Float)] = [
            (0, 0, 0), (s, 0, 0), (s, s, 0), (0, s, 0),
            (0, 0, s), (s, 0, s), (s, s, s), (0, s, s)]
        let faces = [(0, 3, 2), (0, 2, 1), (4, 5, 6), (4, 6, 7),
                     (0, 1, 5), (0, 5, 4), (2, 3, 7), (2, 7, 6),
                     (1, 2, 6), (1, 6, 5), (0, 4, 7), (0, 7, 3)]
        var d = Data(count: 80)
        var count = UInt32(faces.count).littleEndian
        withUnsafeBytes(of: &count) { d.append(contentsOf: $0) }
        for (a, b, c) in faces {
            for _ in 0..<3 { var z = Float(0); withUnsafeBytes(of: &z) { d.append(contentsOf: $0) } }
            for i in [a, b, c] {
                for comp in [v[i].0, v[i].1, v[i].2] {
                    var f = comp
                    withUnsafeBytes(of: &f) { d.append(contentsOf: $0) }
                }
            }
            var attr = UInt16(0)
            withUnsafeBytes(of: &attr) { d.append(contentsOf: $0) }
        }
        return d
    }

    /// His run's stdout, replayed as the SSE events the worker produces from it:
    /// a `VARIANT` line becomes a typed `variant` event, and a `LATTICE` line —
    /// which the worker has no typed event for — falls through its `_line_to_event`
    /// catch-all as `{"type": "log", "line": …}`, verbatim. That fall-through is
    /// the whole mechanism this task turned out to need, so the fixture reproduces
    /// it exactly rather than inventing a typed lattice event.
    private func eventsFromHisRun() throws -> [String] {
        let text = try String(contentsOf: Self.runDir.appendingPathComponent(
            "checkpoint_lines.txt"), encoding: .utf8)
        var events: [String] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("VARIANT ") {
                var kv: [String: String] = [:]
                for tok in s.dropFirst("VARIANT ".count).split(separator: " ") {
                    guard let eq = tok.firstIndex(of: "=") else { continue }
                    kv[String(tok[tok.startIndex..<eq])] = String(tok[tok.index(after: eq)...])
                }
                let mesh = (kv["mesh"]! as NSString).lastPathComponent
                events.append("""
                {"type":"variant","vf":\(kv["vf"]!),"achieved":\(kv["achieved"]!),\
                "printed":\(kv["printed"]!),"margin":\(kv["margin"]!),\
                "accepted":true,"mesh":"\(mesh)"}
                """)
            } else if s.hasPrefix("LATTICE ") {
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                events.append("{\"type\":\"log\",\"line\":\"\(escaped)\"}")
            }
        }
        events.append("{\"type\":\"done\"}")
        return events
    }

    private func makeRequest() throws -> RunRequest {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lattice-onscreen-model.step")
        try Data("ISO-10303-21;\nENDSEC;\n".utf8).write(to: URL(fileURLWithPath: path))
        return RunRequest(modelPath: path, material: "PLA", materialsPath: "",
                          rulesPath: "", resolution: 128, projectName: "M2 vertical stand",
                          anchorFaceIDs: [18], loadGroups: [], minimizePlastic: true)
    }

    /// Run his four-rung ladder through the app's real remote runner against the
    /// stub, and hand back the outcome plus everything the client asked for.
    private func runHisLadder(sizeOverrides: [String: Int] = latticedMeshBytes)
        throws -> (outcome: OptimizeOutcome, requests: [String]) {
        let dir = try makeFilesDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let worker = try StubWorker(filesDir: dir, events: try eventsFromHisRun(),
                                    fingerprint: CoreFingerprint.value,
                                    sizeOverrides: sizeOverrides)
        defer { worker.stop() }
        let config = RemoteRunnerConfig(
            host: "127.0.0.1", port: Int(worker.port),
            expectedFingerprint: CoreFingerprint.value,
            inactivityGrace: 3, requestTimeout: 30, controlTimeout: 5)
        let defaults = UserDefaults(suiteName: "lattice-onscreen-\(UUID().uuidString)")!
        let run = RemoteRun(config: config, request: try makeRequest(),
                            progress: { _, _, _ in true }, onVariant: { _ in },
                            defaults: defaults)
        let outcome = try run.run()
        return (outcome, worker.log())
    }

    // ══════════════════════════════════════════════════════════════════════
    // R2 — THE GAP, AS AN ASSERTION
    // ══════════════════════════════════════════════════════════════════════

    /// *** THE FAILING TEST (bar R2). ***
    ///
    /// Two claims, and before this task the app satisfied only the second.
    ///
    ///  1. Every accepted rung that produced a lattice carries that lattice's own
    ///     mass. On his run: 246.38 g, 244.78 g, 239.93 g, 215.16 g. Before this
    ///     task `RemoteRun` dropped the `LATTICE` checkpoint at `handleEvent`'s
    ///     `default:` and fetched no per-rung receipt, so every
    ///     `latticeAlternative` was nil and this assertion failed four times.
    ///
    ///  2. Not one byte of a latticed MESH was transferred to get there. That was
    ///     true before and MUST STAY true: the four are 5.17 GB, and the measured
    ///     cost of an in-memory GET of just the 1.42 GB one is 4.30 GB resident
    ///     (`LatticeMeshTransferProfileTests`). The masses come from receipts.
    func testEveryLatticedRungIsReachableAndNoMeshWasTransferred() throws {
        let (outcome, requests) = try runHisLadder()

        let accepted = outcome.variants.filter { $0.accepted }
        XCTAssertEqual(accepted.count, 4, "his run accepted four rungs")

        // (1) each rung's latticed alternative, with the mass off its own receipt.
        let expected: [Double: Double] = [0.68: 215.16, 0.52: 239.93,
                                          0.38: 244.78, 0.26: 246.38]
        for v in accepted {
            let alt = try XCTUnwrap(
                v.latticeAlternative,
                "rung vf=\(v.requestedVolumeFraction) announced a lattice on its "
                + "LATTICE checkpoint line, so the app must carry that latticed "
                + "object — this is the gap: the optimize path fetched the report "
                + "and never made the lattice reachable")
            let want = try XCTUnwrap(expected[v.requestedVolumeFraction])
            XCTAssertEqual(alt.massGrams, want, accuracy: 0.01,
                           "the latticed mass must be lattice_mass_grams from "
                           + "variant_\(String(format: "%03d", Int(v.requestedVolumeFraction * 100)))"
                           + "_lattice.report.json, not the solid's")
            XCTAssertTrue(alt.accepted,
                          "every one of his four lattices was accepted")
            XCTAssertFalse(alt.meshName.isEmpty,
                           "the latticed mesh must be NAMED even though it is not fetched")
        }

        // (2) and no latticed mesh crossed the wire.
        let meshGETs = requests.filter {
            $0.hasPrefix("GET ") && $0.hasSuffix("_lattice.stl")
        }
        XCTAssertTrue(meshGETs.isEmpty,
                      "no latticed mesh may be transferred to show a latticed "
                      + "variant's numbers — these four are 5.17 GB. Saw: \(meshGETs)")
        // The RECEIPTS, on the other hand, must all have been read — that is where
        // the masses came from, and a test that passed without them would be
        // passing on invented numbers.
        for tag in ["026", "038", "052", "068"] {
            XCTAssertTrue(
                requests.contains { $0.hasSuffix("variant_\(tag)_lattice.report.json") },
                "rung \(tag)'s certification receipt must be fetched")
        }
    }

    /// The solid rung's own mass is untouched by any of this — 360.30 g for the
    /// recommended rung, the number his app showed. The defect was never that this
    /// figure was wrong; it was that it was the only figure.
    func testTheSolidMassesAreUnchanged() throws {
        let (outcome, _) = try runHisLadder()
        let byRung = Dictionary(uniqueKeysWithValues:
            outcome.variants.filter { $0.accepted }
                .map { ($0.requestedVolumeFraction, $0.massGrams) })
        XCTAssertEqual(byRung[0.68] ?? 0, 543.730, accuracy: 0.01)
        XCTAssertEqual(byRung[0.52] ?? 0, 473.317, accuracy: 0.01)
        XCTAssertEqual(byRung[0.38] ?? 0, 412.466, accuracy: 0.01)
        XCTAssertEqual(byRung[0.26] ?? 0, 360.304, accuracy: 0.01)
    }

    /// The size probe is a HEAD, and it is the ONLY thing the app learns about a
    /// latticed mesh before someone asks for it. Without a size there is no way to
    /// decide whether the device can hold it, so its absence must be visible.
    func testTheLatticedMeshSizeIsProbedByHeadNotByFetching() throws {
        let (outcome, requests) = try runHisLadder()
        let sizes = Dictionary(uniqueKeysWithValues:
            outcome.variants.compactMap { v -> (String, Int)? in
                guard let a = v.latticeAlternative else { return nil }
                return (a.meshName, a.meshBytes)
            })
        XCTAssertEqual(sizes["variant_068_lattice.stl"], 1_954_879_484)
        XCTAssertEqual(sizes["variant_026_lattice.stl"], 740_360_884)
        for name in Self.latticedMeshBytes.keys {
            XCTAssertTrue(requests.contains("HEAD /jobs/stubjob/files/\(name)"),
                          "\(name)'s size must come from a HEAD")
        }
    }

    /// A worker that will not answer HEAD leaves the size unknown — and unknown
    /// must NOT read as "small". The variant still appears, with its mass and its
    /// verdict; only the transfer is refused, and the refusal says why.
    func testAnUnreportedSizeRefusesRatherThanGuessing() throws {
        let (outcome, _) = try runHisLadder(sizeOverrides: [:])
        // With no override the stub serves from disk, where the latticed meshes do
        // not exist → 404 on the HEAD → size 0.
        let alt = try XCTUnwrap(outcome.variants.first?.latticeAlternative)
        XCTAssertEqual(alt.meshBytes, 0, "an unanswerable HEAD leaves the size unknown")
        XCTAssertGreaterThan(alt.massGrams, 0,
                             "and the mass is still known — it came from the receipt")
        let verdict = LatticeMeshBudget.displayVerdict(
            fileBytes: alt.meshBytes, available: 64 << 30)
        XCTAssertFalse(verdict.fits,
                       "an unknown size must refuse even on a machine with 64 GB free")
        XCTAssertTrue(verdict.refusalReason?.contains("did not report") == true)
    }

    // ══════════════════════════════════════════════════════════════════════
    // The checkpoint line itself
    // ══════════════════════════════════════════════════════════════════════

    /// Parsed against his own lines, byte for byte.
    func testHisCheckpointLinesParse() throws {
        let text = try String(contentsOf: Self.runDir.appendingPathComponent(
            "checkpoint_lines.txt"), encoding: .utf8)
        let lattice = text.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("LATTICE ") }
        XCTAssertEqual(lattice.count, 4)
        let parsed = lattice.compactMap(LatticeCheckpoint.parse)
        XCTAssertEqual(parsed.count, 4, "every LATTICE line must parse")
        let first = try XCTUnwrap(parsed.first)
        XCTAssertEqual(first.requestedVolumeFraction, 0.68, accuracy: 1e-9)
        XCTAssertEqual(first.topologyID, "octet")
        XCTAssertEqual(first.cellMM, 2, accuracy: 1e-9)
        XCTAssertTrue(first.graded, "his run graded the density 0.265–0.900")
        XCTAssertEqual(first.triangles, 38_994_180)
        XCTAssertEqual(first.latticedCells, 48302)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.meshName, "variant_068_lattice.stl")
        XCTAssertEqual(first.reportName, "variant_068_lattice.report.json")
    }

    /// A VARIANT line is not a LATTICE line, and neither is a log line that merely
    /// mentions one. The parser is the thing standing between a log channel and the
    /// outcome, so it must not be loose.
    func testNonCheckpointLinesAreNotParsedAsLattices() {
        XCTAssertNil(LatticeCheckpoint.parse(
            "VARIANT vf=0.680000 achieved=0.679952 margin=2169.62 accepted=1 mesh=x.stl"))
        XCTAssertNil(LatticeCheckpoint.parse("[lattice] vf=0.68 NO LATTICE EMITTED"))
        XCTAssertNil(LatticeCheckpoint.parse(""))
        // A LATTICE line with no mesh names is an announcement nothing can act on.
        XCTAssertNil(LatticeCheckpoint.parse(
            "LATTICE vf=0.68 topology=octet cells=1 tris=2 lattice_accepted=1"))
    }

    // ══════════════════════════════════════════════════════════════════════
    // S2 — what the screen shows
    // ══════════════════════════════════════════════════════════════════════

    @MainActor
    private func hisResultsModel() throws -> ResultsModel {
        let (outcome, _) = try runHisLadder()
        return ResultsModel(projectName: "M2 vertical stand", outcome: outcome,
                            materialName: "PLA", yieldStrengthMPa: 50,
                            materialDensityGCm3: 1.24)
    }

    /// EIGHT TABS FOR FOUR RUNGS: each rung's solid and, right beside it, the
    /// latticed object the same rung produced.
    @MainActor
    func testEachRungOffersItsLatticedAlternativeInTheVariantList() throws {
        let model = try hisResultsModel()
        XCTAssertEqual(model.tabs.count, 8,
                       "four rungs, each with a solid and a latticed tab")
        for i in stride(from: 0, to: 8, by: 2) {
            XCTAssertFalse(model.tabs[i].isLatticed, "tab \(i) is the solid")
            XCTAssertTrue(model.tabs[i + 1].isLatticed, "tab \(i + 1) is its lattice")
            XCTAssertEqual(model.tabs[i].variantIndex, model.tabs[i + 1].variantIndex,
                           "both tabs of a rung name the same rung")
        }
    }

    /// *** THE NUMBER THAT SHOWED THE COST. *** His app displayed the recommended
    /// variant at 360 g. The latticed object of that same rung weighs 246.38 g, and
    /// selecting it must show THAT — not the solid's mass under a different label.
    @MainActor
    func testSelectingALatticedVariantShowsTheLatticedMass() throws {
        let model = try hisResultsModel()
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        XCTAssertEqual(recommended.massGrams, 360.304, accuracy: 0.01,
                       "the recommendation is the vf=0.26 rung, 360 g solid")

        let latticed = try XCTUnwrap(
            model.tabs.first { $0.isLatticed && $0.variantIndex == recommended.variantIndex })
        model.select(latticed.index)
        XCTAssertEqual(model.selected?.massGrams ?? 0, 246.38, accuracy: 0.01)
        XCTAssertEqual(model.selected?.massLabel, "246 g")
        XCTAssertEqual(model.selected?.headlineLabel, "246 g",
                       "a latticed tab leads with its mass, not the rung's savings")
        XCTAssertEqual(model.selectedLattice?.massGrams ?? 0, 246.38, accuracy: 0.01)
    }

    /// And the mass says where it came from. The solid's caption offers a
    /// mesh-derived cross-check; the latticed one cannot, because a latticed mesh
    /// is an interpenetrating soup with no enclosed volume — so it states its
    /// single source instead of implying a second opinion exists.
    @MainActor
    func testTheLatticedMassStatesItsProvenanceAndOffersNoMeshCrossCheck() throws {
        let model = try hisResultsModel()
        let latticed = try XCTUnwrap(model.tabs.first { $0.isLatticed })
        model.select(latticed.index)
        let line = try XCTUnwrap(model.latticeMassProvenanceLine)
        XCTAssertTrue(line.contains("certification receipt"), line)
        XCTAssertTrue(line.contains("interpenetrating soup"), line)
        XCTAssertNil(model.selectedMassComparison,
                     "the mesh-vs-voxel comparison is meaningless on a soup and "
                     + "must not be offered")
        XCTAssertEqual(model.selectedMeshVolumeMM3, 0,
                       "…and neither is its enclosed volume")
    }

    /// A latticed selection NEVER falls back to the solid's geometry. With no mesh
    /// transferred there is nothing to draw, and the caption explains it — showing
    /// the solid under a latticed label is the substitution this task removed.
    @MainActor
    func testALatticedSelectionNeverDrawsTheSolid() throws {
        let model = try hisResultsModel()
        let solidTab = try XCTUnwrap(model.tabs.first { !$0.isLatticed })
        model.select(solidTab.index)
        XCTAssertNotNil(model.selectedMesh, "the solid draws, as it always did")

        let latticed = try XCTUnwrap(model.tabs.first { $0.isLatticed })
        model.select(latticed.index)
        XCTAssertNil(model.selectedMesh,
                     "no latticed geometry has been transferred, so there is "
                     + "nothing to draw — and the solid is not a substitute")
        XCTAssertEqual(model.selectedLatticeMeshState, .idle)
    }

    /// The export writes the LATTICED file, under a name that cannot collide with
    /// the solid's — and it is available even though the geometry is not, because
    /// an export streams and never decodes.
    @MainActor
    func testExportTargetsTheLatticedFileUnderItsOwnName() throws {
        let model = try hisResultsModel()
        let solidTab = try XCTUnwrap(model.tabs.first { !$0.isLatticed })
        model.select(solidTab.index)
        let solidName = model.exportFilename
        XCTAssertFalse(model.exportIsStreamed)
        XCTAssertNotNil(model.exportSTLData(), "the solid exports its own bytes")

        let latticed = try XCTUnwrap(
            model.tabs.first { $0.isLatticed && $0.variantIndex == solidTab.variantIndex })
        model.select(latticed.index)
        XCTAssertTrue(model.canExport,
                      "a latticed variant is exportable even when it cannot be shown")
        XCTAssertTrue(model.exportIsStreamed)
        XCTAssertNotEqual(model.exportFilename, solidName,
                          "the two objects must not share a filename")
        XCTAssertTrue(model.exportFilename.hasSuffix("-latticed.stl"),
                      model.exportFilename)
        XCTAssertNil(model.exportSTLData(),
                     "a latticed export must not fall through to the solid's bytes")
    }

    /// A REFUSED transfer is stated, with the numbers. This is the one behaviour
    /// the task names as non-negotiable: the app may not show the solid as though
    /// it were everything.
    @MainActor
    func testARefusedTransferSaysTheLatticeExistsAndWhyItCannotComeOver() throws {
        let model = try hisResultsModel()
        let latticed = try XCTUnwrap(model.tabs.first { $0.isLatticed })
        model.select(latticed.index)
        // An iPad-sized budget against his 1.95 GB rung.
        model.latticeAvailableBytesOverride = 3 << 30
        model.bringLatticedMeshOver()
        guard case .refused(let reason)? = model.selectedLatticeMeshState else {
            return XCTFail("a 1.95 GB mesh must be refused with 3 GB of headroom; "
                           + "state was \(String(describing: model.selectedLatticeMeshState))")
        }
        XCTAssertTrue(reason.contains("exists on the worker"), reason)
        XCTAssertTrue(reason.contains("GB"), "the refusal must carry the numbers: \(reason)")
        XCTAssertTrue(reason.contains("Export"),
                      "…and must say what IS still possible: \(reason)")
        // The numbers are untouched by the refusal.
        XCTAssertEqual(model.selected?.massGrams ?? 0, 215.16, accuracy: 0.01)
    }

    /// The same rung on a machine with room: the budget agrees, and the transfer is
    /// attempted rather than refused.
    @MainActor
    func testAMachineWithRoomIsNotRefused() throws {
        let model = try hisResultsModel()
        let latticed = try XCTUnwrap(model.tabs.first { $0.isLatticed })
        model.select(latticed.index)
        model.latticeAvailableBytesOverride = 64 << 30
        model.bringLatticedMeshOver()
        // No transfer was wired in this test, so it stops at "cannot reach the
        // run" — the point is that it did NOT stop at the budget.
        guard case .failed(let reason)? = model.selectedLatticeMeshState else {
            return XCTFail("expected the budget to pass; state was "
                           + "\(String(describing: model.selectedLatticeMeshState))")
        }
        XCTAssertTrue(reason.contains("no longer has a connection"), reason)
    }

    // ══════════════════════════════════════════════════════════════════════
    // S2(c) — THE FINDING THE RECOMMENDER GETS BACKWARDS
    // ══════════════════════════════════════════════════════════════════════

    /// *** REPORTED, NOT FIXED. *** On his run the latticed masses FALL as the
    /// solid rung gets heavier, because a heavier rung has more material to replace
    /// with a 26–90 %-density lattice. So "the last accepted rung" — the lightest
    /// SOLID, and the rule the recommendation has always used — lands on the
    /// HEAVIEST of the four latticed objects.
    ///
    /// This test PINS the inversion rather than correcting it: which object the
    /// recommendation should rank once a lattice exists is the maintainer's ruling,
    /// and the task says not to change the rule without it. If someone later
    /// changes the rule, this test fails and makes them say so out loud.
    @MainActor
    func testTheRecommendationPointsAtTheHeaviestLatticedObject() throws {
        let model = try hisResultsModel()
        let recommended = try XCTUnwrap(model.tabs.first { $0.isRecommended })
        XCTAssertFalse(recommended.isLatticed,
                       "the recommendation stays on a SOLID tab — its rule is "
                       + "still true there")
        XCTAssertEqual(recommended.massGrams, 360.304, accuracy: 0.01,
                       "…and it is the lightest solid, as it always was")

        let latticedMasses = model.tabs.filter { $0.isLatticed }.map { $0.massGrams }
        XCTAssertEqual(latticedMasses.count, 4)
        // Ladder order is heaviest-solid-first, and the latticed masses ASCEND
        // along it: 215.16, 239.93, 244.78, 246.38.
        XCTAssertEqual(latticedMasses, latticedMasses.sorted(),
                       "lattice mass rises as the solid rung gets lighter — the "
                       + "inverse of the ordering the recommendation assumes")
        let recommendedLattice = try XCTUnwrap(
            model.tabs.first { $0.isLatticed && $0.variantIndex == recommended.variantIndex })
        XCTAssertEqual(recommendedLattice.massGrams, try XCTUnwrap(latticedMasses.max()),
                       accuracy: 0.01,
                       "the recommended rung's lattice is the HEAVIEST of the four "
                       + "(246.38 g against 215.16 g on the vf=0.68 rung) — a 31 g, "
                       + "12.6 % penalty for following the recommendation")
    }

    // ══════════════════════════════════════════════════════════════════════
    // Round trip
    // ══════════════════════════════════════════════════════════════════════

    /// A reopened project must still know about its latticed variants. Losing them
    /// on the round trip would restore the original defect one launch later.
    @MainActor
    func testLatticedAlternativesSurviveThePersistenceRoundTrip() throws {
        let (outcome, _) = try runHisLadder()
        // The REAL on-disk path: the same binary-plist codec a reopened project
        // decodes through, not a hand-rolled JSON round trip.
        let bytes = try OutcomeCodec.encode(OutcomeCodec.dto(from: outcome))
        let back = try OutcomeCodec.decode(bytes)
        let alts = back.variants.compactMap { $0.latticeAlternative }
        XCTAssertEqual(alts.count, 4, "all four latticed alternatives survive")
        for (got, want) in zip(alts.map { $0.massGrams }.sorted(),
                               [215.16, 239.93, 244.78, 246.38]) {
            XCTAssertEqual(got, want, accuracy: 0.01, "…with their own masses")
        }
        XCTAssertEqual(back.variants.first?.latticeAlternative?.meshBytes,
                       1_954_879_484, "…and their sizes")
    }

    /// A run with no lattice is unchanged in every observable way — one tab per
    /// rung, no alternative, the solid export path.
    @MainActor
    func testANonLatticeRunIsUnchanged() throws {
        let v = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
            massGrams: 100, supportVolumeVoxels: 0, meshTriangleCount: 1,
            worstCaseMargin: 2, accepted: true, v3Passes: true,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2])
        let model = ResultsModel(
            projectName: "P",
            outcome: OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                     cancelled: false, acceptedCount: 1),
            materialName: "PLA", materialDensityGCm3: 1.24)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertFalse(model.tabs[0].isLatticed)
        XCTAssertEqual(model.tabs[0].index, 0)
        XCTAssertEqual(model.tabs[0].variantIndex, 0)
        XCTAssertNil(model.selectedLattice)
        XCTAssertNil(model.latticeMassProvenanceLine)
        XCTAssertFalse(model.exportIsStreamed)
        XCTAssertFalse(model.exportFilename.contains("latticed"))
    }
}
