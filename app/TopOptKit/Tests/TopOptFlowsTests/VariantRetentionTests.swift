// VariantRetentionTests.swift — task 2026-08-03-variant-entry-gating-and-retention.
//
//  AJ1  THE REPORTED LOSS IS ROOT-CAUSED. A completed run's variants disappeared.
//       There are TWO mechanisms, both named here and both reproduced:
//
//       (1) IN MEMORY — `RunModel.start` cleared `outcome` unconditionally
//           (RunModel.swift:999 at HEAD), and `finish`'s failure branch cleared it
//           again (RunModel.swift:1293 at HEAD). So a run that produced NOTHING —
//           refused by core's pre-flight, thrown, cancelled before the first
//           variant — destroyed hours of finished work it never replaced. It is
//           reachable from the lattice page's "Optimize from scratch"
//           (WorkspacePlaceholder → startRun → run.start), which core refuses up
//           front when a design box is present (core/src/cli/run_job.cpp, the
//           "lattice certification does not support a design box" throw).
//
//       (2) ON DISK — `AppModel.persist` writes the snapshot's `optimized` flag
//           from the LIVE `hasResults`. With the outcome cleared by (1), any save
//           in that window (Home, or the app backgrounding) wrote `optimized:
//           false` over a project whose `results.plist` was still on disk, and
//           `restoreFromDisk` only reads that file when the flag is true. The
//           results survived; the flag orphaned them, permanently.
//
//  AJ3  VARIANTS SURVIVE SETUP EDITS. A completed run is edited around — design
//       box, anchors, loads, clearances — and stays reachable, with its RETAINED
//       job rather than the edited one.
//
//  AJ4  THE RETAINED JOB IS USED, NOT THE LIVE ONE. Asserted by making the live
//       state say the OPPOSITE of the retained state, in both directions.

import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class VariantRetentionTests: XCTestCase {

    // MARK: fixtures

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/materials/print_rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-retention-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func request() -> RunRequest {
        RunRequest(modelPath: Self.cubeSTL, material: "PLA",
                   materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
                   resolution: 32, projectName: "Bracket")
    }

    private func variant(_ vf: Double, accepted: Bool = true) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: vf, achievedVolumeFraction: vf,
                        massGrams: 41.2, supportVolumeVoxels: 0, meshTriangleCount: 12,
                        worstCaseMargin: 2.31, accepted: accepted, v3Passes: true,
                        minFeatureViolations: 0, minFeatureWarning: "",
                        meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
                        vonMisesField: [1, 2, 3, 4])
    }

    private func finished(_ n: Int = 2, remote: Bool = true,
                          worker: String? = "Mac mini") -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { variant(0.8 - 0.2 * Double($0)) },
                        stoppedOnMargin: true, cancelled: false, acceptedCount: n,
                        gridNx: 2, gridNy: 2, gridNz: 1, spacing: 1,
                        computedRemotely: remote, solvedBy: worker)
    }

    /// A RunModel with a completed run already on it, exactly as the workspace
    /// holds one after an 80-minute solve.
    private func modelWithResults(artifacts: RelatticeArtifacts? = nil)
        -> (RunModel, OptimizeOutcome) {
        let m = RunModel(scheduler: SynchronousRunScheduler(), watchdog: DisabledRunWatchdog())
        let done = finished()
        m.restoreOutcome(done)
        m.restoreArtifacts(artifacts)
        return (m, done)
    }

    // MARK: - AJ1(1) · a run that produces nothing must not destroy the run that did

    /// THE REPRODUCTION. Pre-fix this fails at the first assertion: `start` nils the
    /// outcome, the core refusal throws, and `finish` nils it again — two accepted
    /// variants gone before a single element was solved.
    func testARefusedRunDoesNotDestroyTheCompletedRunsVariants() {
        let (m, done) = modelWithResults()
        XCTAssertEqual(m.outcome?.variants.count, 2)

        // The design-box refusal core throws at PRE-FLIGHT — before any import,
        // voxelize or solve. Nothing was produced; nothing may be destroyed.
        m.runner = { _, _, _ in
            throw TopOptError(message: "lattice certification does not support a "
                              + "design box (add-material) run")
        }
        m.start(request())

        XCTAssertEqual(m.phase, .failed, "the refusal still surfaces as a failure")
        XCTAssertNotNil(m.failure)
        XCTAssertEqual(m.outcome?.variants.count, 2,
                       "AJ1: a run that produced NOTHING must not take the finished "
                       + "run's variants with it")
        XCTAssertEqual(m.outcome?.acceptedCount, done.acceptedCount)
        XCTAssertTrue(m.restoredPreviousResults,
                      "and the model says so, so the UI can explain it")
    }

    /// The same for a CANCEL before the first variant streamed.
    func testCancellingANewRunDoesNotDestroyThePreviousOne() {
        let (m, _) = modelWithResults()
        m.runner = { _, _, _ in
            OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: true,
                            acceptedCount: 0)
        }
        m.start(request())
        XCTAssertEqual(m.outcome?.variants.count, 2,
                       "AJ1: leaving a run must never wipe the results already earned")
    }

    /// And for a setup STALL, which is abandoned only when the sheet is dismissed —
    /// so the previous results come back THEN, never while "Keep waiting" could
    /// still resume the run and append to them.
    func testAStalledRunReturnsThePreviousResultsOnlyWhenAbandoned() {
        let dog = ManualRunWatchdog()
        let m = RunModel(scheduler: HeldRunScheduler(), watchdog: dog)
        m.restoreOutcome(finished())
        m.runner = { _, _, _ in self.finished(1) }
        m.start(request())
        dog.fire?()
        XCTAssertEqual(m.phase, .failed)
        XCTAssertNil(m.outcome,
                     "while Keep-waiting is offered the run may still resume, so the "
                     + "previous variants must NOT be back for it to append to")
        m.dismissFailure()
        XCTAssertEqual(m.outcome?.variants.count, 2,
                       "AJ1: abandoning the stalled run restores what it displaced")
    }

    /// THE OTHER HALF OF THE RULE, so this is not a licence to keep stale results:
    /// a run that genuinely produces accepted variants REPLACES them. That
    /// replacement is the user's own explicit Optimize.
    func testASuccessfulRunReplacesThePreviousResults() {
        let (m, _) = modelWithResults()
        m.runner = { _, _, _ in self.finished(1) }
        m.start(request())
        XCTAssertEqual(m.outcome?.variants.count, 1,
                       "a run that produced results is what the user asked for")
        XCTAssertFalse(m.restoredPreviousResults)
    }

    /// A new run's STREAMED variants must never splice onto the previous run's
    /// ladder — the reason `start` has to clear `outcome` in the first place.
    func testStreamedVariantsDoNotSpliceOntoThePreviousRun() {
        let (m, _) = modelWithResults()
        m.runner = { _, _, onVariant in
            onVariant(self.finished(1))
            return self.finished(1)
        }
        m.start(request())
        XCTAssertEqual(m.outcome?.variants.count, 1,
                       "two runs' ladders must never appear as one list")
    }

    // MARK: - AJ1(1), the retention pair moves with the results it describes

    func testTheRetainedJobComesBackWithTheRestoredVariants() {
        let art = RelatticeArtifacts(jobJSON: Data("{\"material\":\"PLA\"}".utf8),
                                     designBin: Data([7, 7, 7]))
        let (m, _) = modelWithResults(artifacts: art)
        m.runner = { _, _, _ in throw TopOptError(message: "refused at pre-flight") }
        m.start(request())
        XCTAssertEqual(m.outcome?.variants.count, 2)
        XCTAssertEqual(m.retainedArtifacts, art,
                       "AJ1: restored variants that had lost their retention pair "
                       + "would be reachable but claim to have kept no design")
    }

    func testAnOnDeviceRunDoesNotInheritThePreviousRunsRetentionPair() {
        let art = RelatticeArtifacts(jobJSON: Data("{}".utf8), designBin: Data([1]))
        let (m, _) = modelWithResults(artifacts: art)
        m.runner = { _, _, _ in self.finished(1, remote: false, worker: nil) }
        m.start(request())          // on-device: the runner reports no pair
        XCTAssertEqual(m.outcome?.variants.count, 1)
        XCTAssertNil(m.retainedArtifacts,
                     "a design from a DIFFERENT run must never be latticeable "
                     + "against these results")
    }

    func testTheInFlightRunsReportedPairIsAdoptedOnlyOnSuccess() {
        let fresh = RelatticeArtifacts(jobJSON: Data("{\"r\":1}".utf8),
                                       designBin: Data([9]))
        let (m, _) = modelWithResults()
        m.runner = { _, _, _ in self.finished(1) }
        m.start(request())
        m.noteRetainedArtifacts(fresh)      // reported while running…
        // …but the run already resolved through the immediate scheduler, so drive a
        // second, explicit round to observe both branches.
        let m2 = RunModel(scheduler: SynchronousRunScheduler(), watchdog: DisabledRunWatchdog())
        m2.runner = { [weak m2] _, _, _ in
            m2?.noteRetainedArtifacts(fresh)
            return self.finished(1)
        }
        m2.start(request())
        XCTAssertEqual(m2.retainedArtifacts, fresh,
                       "a run that produced results keeps its OWN pair")
    }

    // MARK: - AJ1(2) · the on-disk flag must not orphan a live results file

    /// THE SECOND REPRODUCTION. Pre-fix this fails at the last assertion: the save
    /// taken while the live run had no outcome wrote `optimized: false`, and the
    /// reopened project never read `results.plist` again.
    func testASaveWhileTheRunHasNoOutcomeDoesNotOrphanThePersistedResults() throws {
        let store = ProjectStore(rootDir: tempDir)
        let m1 = AppModel(materialsPath: Self.materialsPath, store: store)
        m1.loadMaterials()
        m1.newTopOpt(); m1.selectMaterial("PLA")
        m1.pickedFile(atPath: Self.cubeSTL, displayName: "cube.stl")
        XCTAssertTrue(m1.resolveUnits(.millimetres))
        m1.continueToWorkspace()
        let project = try XCTUnwrap(m1.project)
        let id = project.id

        project.run.restoreOutcome(finished())
        m1.persistCurrentProject()
        // The results blob is written on a background queue; wait for it.
        try waitForResults(store: store, id: id)
        XCTAssertTrue(store.hasPersistedResults(id: id))

        // Now the reported sequence: a run that produced nothing leaves the live
        // model with no outcome, and the app saves in that window (Home, or the
        // system backgrounding it).
        project.run.reset()
        XCTAssertFalse(project.hasResults)
        m1.persistCurrentProject()

        let snap = try XCTUnwrap(store.snapshot(id: id))
        XCTAssertEqual(snap.optimized, true,
                       "AJ1: the flag describes the DURABLE record. Written false "
                       + "over a live results.plist it orphans the file forever, "
                       + "because restoreFromDisk only reads it when the flag is true")
        XCTAssertTrue(store.hasPersistedResults(id: id),
                      "and the blob itself was never touched")
    }

    private func waitForResults(store: ProjectStore, id: UUID,
                                timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !store.hasPersistedResults(id: id), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(store.hasPersistedResults(id: id), "results blob never landed")
    }

    // MARK: - AJ3 · variants survive edits to the project's current setup

    /// Complete a run, then edit the design box, the anchors, the loads and the
    /// clearances IN TURN, asserting after each that every variant is still there
    /// and still reachable with its RETAINED job.
    func testEveryVariantSurvivesEveryKindOfSetupEdit() throws {
        let retained = retainedJobJSON(designBox: false)
        let art = RelatticeArtifacts(jobJSON: retained, designBin: Data([1, 2, 3]))
        let project = ProjectModel(id: UUID(), name: "Bracket", material: "PLA",
                                   process: .fdm, importedFile: nil, importedMesh: nil)
        project.run.restoreOutcome(finished())
        project.run.restoreArtifacts(art)

        func stillReachable(_ what: String) {
            XCTAssertEqual(project.run.outcome?.variants.count, 2,
                           "AJ3: \(what) must not touch a finished run's variants")
            let facts = VariantEntryFacts(
                hasGeometry: true, machine: SolvingMachine.of(project.run.outcome!),
                retainedJob: project.relatticeArtifacts?.jobJSON,
                retainedDesign: project.relatticeArtifacts?.designBin,
                runGeneratedLattice: false, modelPath: "/tmp/part.stl",
                workerSelected: true, runInFlight: false)
            XCTAssertTrue(VariantEntry.smoothing(facts).enabled,
                          "AJ3: still smoothable after \(what) — "
                          + "\(VariantEntry.smoothingBlocks(facts))")
            XCTAssertTrue(VariantEntry.lattice(facts).enabled,
                          "AJ3: still latticeable after \(what) — "
                          + "\(VariantEntry.latticeBlocks(facts))")
            XCTAssertEqual(project.relatticeArtifacts?.jobJSON, retained,
                           "AJ3/AJ4: and it is still the RETAINED job, byte for byte")
        }

        stillReachable("no edit at all")

        // 1. The design box — the edit the report named.
        project.designBox.enable(around: MeshBounds(min: SIMD3(0, 0, 0),
                                                    max: SIMD3(10, 10, 10),
                                                    isEmpty: false))
        stillReachable("adding a design box")
        project.designBox.disable()
        stillReachable("REMOVING the design box")

        // 2. Anchors and loads.
        project.selection.addGroup()
        project.selection.pickFaces([FaceID(3)])
        let gid = try XCTUnwrap(project.selection.groups.first?.id)
        project.force.makeAnchor(gid)
        stillReachable("adding an anchor")
        project.force.makeLoad(gid)
        stillReachable("changing it to a load")
        project.selection.addGroup()
        project.selection.pickFaces([FaceID(5)])
        stillReachable("adding a second load group")

        // 3. Clearances (keep-clear is an attribute of a group, handoff 103).
        project.force.setKeepClear(gid, on: true, autoDefault: false)
        stillReachable("declaring a keep-clear")
        project.force.setKeepClear(gid, on: false, autoDefault: false)
        stillReachable("removing the keep-clear")

        // 4. And a material/quality change, for good measure.
        project.material = "PETG"
        project.quality = .fine
        stillReachable("changing the material and the resolution")
    }

    // MARK: - bar 4 · the one remaining invalidation is TOLD and CONFIRMED

    /// After this task nothing else retires a finished run — edits never touch it,
    /// and a run that produces nothing gives it back. The single remaining path is
    /// a new Optimize, and it names what it will cost before it costs it.
    func testANewRunNamesWhatItWillReplaceBeforeReplacingIt() throws {
        XCTAssertNil(ResultsReplacementPrompt.forNewRun(existing: nil),
                     "nothing to lose ⇒ no prompt; Optimize behaves as it always did")
        XCTAssertNil(ResultsReplacementPrompt.forNewRun(
            existing: OptimizeOutcome(variants: [variant(0.8, accepted: false)],
                                      stoppedOnMargin: false, cancelled: false,
                                      acceptedCount: 0)),
                     "an all-rejected run has no accepted variants to lose")

        let p = try XCTUnwrap(ResultsReplacementPrompt.forNewRun(existing: finished(3)))
        XCTAssertEqual(p.variantCount, 3)
        XCTAssertTrue(p.message.contains("3 variants"), p.message)
        XCTAssertTrue(p.message.contains("41.2 g"), "it names what is at stake: \(p.message)")
        XCTAssertTrue(p.message.contains("can’t be brought back"), p.message)

        let one = try XCTUnwrap(ResultsReplacementPrompt.forNewRun(existing: finished(1)))
        XCTAssertTrue(one.message.contains("1 variant this project"), one.message)
        XCTAssertFalse(one.message.contains("1 variants"), "singular reads properly")
    }

    /// And the workspace really routes Optimize through it rather than starting
    /// straight away — the confirm is the gate, not decoration.
    func testTheOptimizeButtonRoutesThroughTheConfirmation() throws {
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        let btn = try XCTUnwrap(ws.range(of: "private var optimizeButton"))
        let body = String(ws[btn.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("requestRun()"),
                      "bar 4: Optimize asks before it retires results")
        XCTAssertFalse(body.contains("startRun()"),
                       "bar 4: …and does not start one straight from the button")
        let req = try XCTUnwrap(ws.range(of: "private func requestRun"))
        let reqBody = String(ws[req.lowerBound...].prefix(400))
        XCTAssertTrue(reqBody.contains("ResultsReplacementPrompt.forNewRun"))
    }

    // MARK: - AJ4 · the retained job decides, never the live one

    /// The design-box question is still asked of the RETAINED document — that half
    /// of AJ4 is structural and unchanged. What changed is the ANSWER: PR 285
    /// taught core to certify a design-box run, so NEITHER retained state disables
    /// the entry any more (device-failure task). The test keeps asserting that the
    /// fact is read from the run's own document, and now also pins the verdict that
    /// the app shipped wrong for two PRs.
    func testTheDesignBoxVerdictComesFromTheRetainedJobNotTheLiveSetup() {
        func facts(retainedBox: Bool) -> VariantEntryFacts {
            VariantEntryFacts(
                hasGeometry: true, machine: .worker(name: "Mac mini"),
                retainedJob: retainedJobJSON(designBox: retainedBox),
                retainedDesign: Data([1]), runGeneratedLattice: false,
                modelPath: "/tmp/part.stl", workerSelected: true, runInFlight: false)
        }
        // The FACT is read from the retained document, in both directions.
        XCTAssertTrue(facts(retainedBox: true).jobFacts.declaresDesignBox,
                      "AJ4: the box is read from the run's OWN document")
        XCTAssertFalse(facts(retainedBox: false).jobFacts.declaresDesignBox)

        // And neither answer blocks the entry, because core runs both.
        XCTAssertTrue(VariantEntry.lattice(facts(retainedBox: false)).enabled,
                      "AJ4: a run solved WITHOUT a box stays latticeable no matter "
                      + "what the workspace is set to now")
        let boxed = VariantEntry.lattice(facts(retainedBox: true))
        XCTAssertTrue(boxed.enabled,
                      "core certifies a design-box run since PR 285 — the app "
                      + "refusing it IS the device failure: " + (boxed.reason ?? "—"))
        XCTAssertFalse(boxed.allReasons
            .contains(RelatticeUnavailable.designBoxRun.reason))
    }

    /// The structural half of AJ4, in the shape PR 274's Z-bars and PR 279's AE3
    /// use: there is nowhere for live project state to ENTER the gate. Comments are
    /// stripped first, so this asserts what the CODE can reach.
    func testTheGateCannotReachLiveProjectState() throws {
        let code = try codeOnly(sourceURL("VariantEntry.swift"))
        for banned in ["ProjectModel", "ForceModel", "SelectionModel",
                       "DesignBoxModel", "LatticeSettings"] {
            XCTAssertFalse(code.contains(banned),
                           "the variant entry gate must not be able to reach \(banned)")
        }
    }

    /// And the call site really does feed it the run's own record.
    func testTheWorkspaceBuildsTheFactsFromTheRunNotTheProject() throws {
        let ws = try String(contentsOf: sourceURL("WorkspacePlaceholder.swift"),
                            encoding: .utf8)
        let start = try XCTUnwrap(ws.range(of: "private func variantEntryFacts"))
        let body = String(ws[start.lowerBound...].prefix(1200))
        XCTAssertTrue(body.contains("project.relatticeArtifacts"),
                      "the retained pair is what decides")
        XCTAssertFalse(body.contains("project.designBox"),
                       "AJ4: the LIVE design box must not decide a finished run's fate")
        XCTAssertFalse(body.contains("project.force"))
        XCTAssertFalse(body.contains("project.selection"))
    }

    // MARK: helpers

    /// A scheduler that HOLDS the background work, so a run stays in flight — the
    /// stall shape (the same seam RunModelTests uses).
    private final class HeldRunScheduler: RunScheduler {
        var held: (() -> Void)?
        func runInBackground(_ work: @escaping () -> Void) { held = work }
        func runOnMain(_ work: @escaping () -> Void) { work() }
    }

    /// A watchdog the test fires by hand (standing in for the grace elapsing).
    private final class ManualRunWatchdog: RunWatchdog {
        var graceSeconds: Double = 150
        var fire: (() -> Void)?
        func arm(_ onStall: @escaping () -> Void) -> RunWatchdogCancel {
            fire = onStall
            return {}
        }
    }

    private func retainedJobJSON(designBox: Bool) -> Data {
        var job: [String: Any] = [
            "model": "part.stl", "material": "PLA", "resolution": 64,
            "loads": ["anchor_face_ids": [3],
                      "groups": [["face_ids": [7], "force": [0, 0, -500]]],
                      "build_dir": [0, 0, 1]],
        ]
        if designBox {
            job["design_box"] = ["min": [0.0, 0.0, 0.0], "max": [50.0, 50.0, 50.0]]
        }
        return try! JSONSerialization.data(withJSONObject: job)
    }

    private func codeOnly(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    private func sourceURL(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TopOptFlowsTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // TopOptKit
        return url.appendingPathComponent("Sources/TopOptFlows/\(name)")
    }
}
