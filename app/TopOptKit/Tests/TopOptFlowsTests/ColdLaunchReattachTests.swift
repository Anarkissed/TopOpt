// ColdLaunchReattachTests — the handoff-119 cold-launch re-attach flow.
//
// The incident: a 7-hour remote run's client was Jetsam-killed overnight; the Mac
// finished the job, but the relaunched app had NO UI path back to it. These tests
// prove the app-side half the mechanism was missing — launch detection of a live
// `RemoteJobStore` record, re-attach into the owning project (a COMPLETED job
// replays its full outcome and lands on results), and the honest failure + clear
// semantics of a dead job. The real re-attach against a live worker is device QA
// (the maintainer's 60 seconds); here the runner is stubbed so the flow is driven
// synchronously and headlessly, exactly like RunModelTests.
//
// The M7 /app/ standard is `xcodebuild test` on this package.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class ColdLaunchReattachTests: XCTestCase {

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-reattach-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// A UserDefaults suite unique per test — the RemoteJobStore lives here, isolated.
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "topopt.reattach.\(UUID().uuidString)")!
    }

    private func job(projectID: UUID? = UUID(), name: String? = "Bracket",
                     submittedAt: Date? = Date()) -> PersistedRemoteJob {
        PersistedRemoteJob(host: "10.0.0.4", port: 8757, fingerprint: "abc123",
                           jobID: "job-xyz", submittedAt: submittedAt,
                           projectID: projectID, projectName: name)
    }

    private func acceptedVariant() -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
                        massGrams: 0, supportVolumeVoxels: 0, meshTriangleCount: 12,
                        worstCaseMargin: 3, accepted: true, v3Passes: true,
                        meshVertices: [0, 0, 0], meshIndices: [0])
    }

    // MARK: - store round-trip across a "relaunch"

    /// The full 101 record — now carrying the 119 banner/routing metadata — survives a
    /// save/load, and a BRAND-NEW AppModel (a relaunch) reads it into `pendingReattach`.
    func testLiveJobSurfacesOnRelaunchAsPendingReattach() {
        let d = scratchDefaults()
        let j = job()
        RemoteJobStore.save(j, defaults: d)

        // A separate model instance == a fresh launch reading the persisted record.
        let relaunched = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                                  remoteJobDefaults: d)
        XCTAssertEqual(relaunched.pendingReattach, j,
                       "a relaunched app surfaces the still-live remote job")
    }

    /// No record → no banner (the common case: the app died with no run in flight, or
    /// the last run resolved and `RemoteRun` cleared the record).
    func testNoRecordMeansNoBanner() {
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: scratchDefaults())
        XCTAssertNil(app.pendingReattach)
    }

    /// A PRE-119 record (no submittedAt/projectID/projectName) still decodes — the
    /// `.v1` store key is unchanged and the new fields are optional. Proven by
    /// round-tripping a bytes-compatible record built with only the old fields.
    func testPre119RecordStillDecodes() throws {
        let d = scratchDefaults()
        // The pre-119 shape: exactly the four original keys.
        let legacy: [String: Any] = ["host": "h", "port": 8757, "fingerprint": "f", "jobID": "j"]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        d.set(data, forKey: RemoteJobStore.key)

        let loaded = try XCTUnwrap(RemoteJobStore.load(defaults: d),
                                   "a pre-119 record must still decode")
        XCTAssertEqual(loaded.jobID, "j")
        XCTAssertNil(loaded.submittedAt)
        XCTAssertNil(loaded.projectID)
        XCTAssertNil(loaded.projectName)
    }

    // MARK: - banner copy (pure)

    func testBannerNamesProjectAgeAndWorker() {
        let now = Date()
        let j = job(name: "Bracket", submittedAt: now.addingTimeInterval(-7 * 3600))
        let text = AppModel.reattachBannerText(for: j, now: now)
        XCTAssertTrue(text.contains("Bracket"), "names the project")
        XCTAssertTrue(text.contains("about 7 hours ago"), "names the age")
        XCTAssertTrue(text.contains("10.0.0.4"), "names the worker")
    }

    func testBannerWithoutMetadataStaysHonest() {
        let j = job(projectID: nil, name: nil, submittedAt: nil)
        let text = AppModel.reattachBannerText(for: j, now: Date())
        XCTAssertTrue(text.contains("10.0.0.4"))
        XCTAssertFalse(text.contains("started"), "no age phrase when the submit time is unknown")
    }

    func testRelativeAgeBuckets() {
        XCTAssertEqual(AppModel.relativeAge(10), "just now")
        XCTAssertEqual(AppModel.relativeAge(5 * 60), "5 min ago")
        XCTAssertEqual(AppModel.relativeAge(3600), "about 1 hour ago")
        XCTAssertEqual(AppModel.relativeAge(7 * 3600), "about 7 hours ago")
        XCTAssertEqual(AppModel.relativeAge(2 * 86_400), "about 2 days ago")
    }

    // MARK: - re-attach ON A COMPLETED JOB lands on results

    /// The exact incident recovery: the Mac FINISHED the run while the app was dead.
    /// Re-attach reopens the project, the (stubbed) runner replays the full outcome
    /// like the worker's `/events` replay would, and the run lands on results
    /// (`.succeeded` with accepted variants) — no orphaned workdir dig required.
    func testReattachOnCompletedJobBuildsOutcomeAndLandsOnResults() {
        let d = scratchDefaults()
        let pid = UUID()
        let j = job(projectID: pid)
        RemoteJobStore.save(j, defaults: d)

        // A stub factory standing in for `remoteReattachRunner`: it streams one
        // accepted variant (the replay) then returns the authoritative final outcome.
        let completedReplay: (RemoteRunnerConfig, String) -> RunModel.Runner = { _, _ in
            { _, _, onVariant in
                let v = self.acceptedVariant()
                let partial = OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                              cancelled: false, acceptedCount: 1,
                                              computedRemotely: true)
                onVariant(partial)
                return OptimizeOutcome(variants: [v], stoppedOnMargin: false,
                                       cancelled: false, acceptedCount: 1,
                                       computedRemotely: true)
            }
        }
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d, reattachRunnerFactory: completedReplay)
        seedProject(app, id: pid)
        XCTAssertNotNil(app.pendingReattach)

        app.reattach()

        XCTAssertNil(app.pendingReattach, "the banner is spent once acted on")
        XCTAssertEqual(app.project?.id, pid, "re-attach reopened the owning project")
        XCTAssertEqual(app.project?.run.phase, .succeeded, "a completed replay lands on results")
        XCTAssertEqual(app.project?.run.outcome?.variants.count, 1)
        XCTAssertTrue(app.project?.run.outcome?.computedRemotely ?? false,
                      "the re-attached outcome is flagged remote")
    }

    /// Handoff 134, item 2 — what the re-attached result must LOOK like once it lands.
    /// The worker serves fields.bin whether the client watched the run or re-attached
    /// to a finished job, so the results screen that opens after a re-attach shows the
    /// stress overlay, flex, the load-path overlay and a REAL mass. The "computed on
    /// Mac" note may name only what genuinely stayed on the Mac (the playback
    /// keyframes) — it must not claim the fields are missing when they are here.
    /// The network half (the actual fetch after a replay) is the E2E `reattach` case.
    func testReattachedResultsShowFieldsAndTheWorkersDuration() {
        let d = scratchDefaults()
        let pid = UUID()
        RemoteJobStore.save(job(projectID: pid), defaults: d)

        // The outcome shape `RemoteRun.assembleFinalOutcome` builds when fields.bin
        // was fetched: per-voxel arrays + grid metadata + the worker's own duration.
        let nx = 2, ny = 2, nz = 2
        let nodes = (nx + 1) * (ny + 1) * (nz + 1)
        let enriched = OptimizeVariant(
            requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
            massGrams: 41.5, supportVolumeVoxels: 120, meshTriangleCount: 12,
            worstCaseMargin: 3, accepted: true, v3Passes: true,
            maxStressMPa: 12,
            meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
            vonMisesField: (0..<(nx * ny * nz)).map { 1 + Float($0) },
            displacementField: [Float](repeating: 0.01, count: 3 * nodes))
        let finished = OptimizeOutcome(
            variants: [enriched], stoppedOnMargin: false, cancelled: false,
            acceptedCount: 1, voxelVolumeMM3: 15.625,
            gridNx: nx, gridNy: ny, gridNz: nz, gridOrigin: .zero, spacing: 2.5,
            computedRemotely: true,
            timing: RunTiming(queuedSeconds: 252, solveSeconds: 2453))
        let replay: (RemoteRunnerConfig, String) -> RunModel.Runner = { _, _ in
            { _, _, _ in finished }
        }

        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d, reattachRunnerFactory: replay)
        seedProject(app, id: pid)
        app.reattach()

        let outcome = app.project?.run.outcome
        XCTAssertEqual(app.project?.run.phase, .succeeded)
        XCTAssertFalse(outcome?.variants.first?.vonMisesField.isEmpty ?? true)
        XCTAssertGreaterThan(outcome?.variants.first?.massGrams ?? 0, 0)

        let results = ResultsModel(projectName: "Bracket", outcome: try! XCTUnwrap(outcome),
                                   materialName: "PLA", yieldStrengthMPa: 50)
        XCTAssertTrue(results.hasStress, "stress overlay is live on a re-attached result")
        XCTAssertTrue(results.hasFlex, "flex is live on a re-attached result")
        XCTAssertTrue(results.hasLoadPath, "load path is live on a re-attached result")
        XCTAssertNotEqual(results.tabs.first?.massLabel, ResultsModel.remoteNA,
                          "mass reads real, not “computed on Mac”")
        let note = results.remoteComputeNote ?? ""
        XCTAssertFalse(note.contains("stress"), "the note must not claim missing fields")
        XCTAssertFalse(note.contains("mass"), "the note must not claim a missing mass")

        // And the duration is the worker's, not the moment of re-attach.
        XCTAssertEqual(results.runDurationLabel, "waited 4m 12s · solved 40m 53s")
    }

    // MARK: - unreachable / dead job: honest failure, clears on Dismiss only

    /// A dead/unknown job: the (stubbed) runner fails with the 101 worker-unreachable
    /// message. The run surfaces a failure sheet, and — per the 101 rule that a
    /// client-side path never destroys the Mac's job — the persisted record is NOT
    /// cleared, so the offer can be retried next launch. Only Dismiss clears it.
    func testUnreachableJobFailsHonestlyAndClearsOnDismissOnly() {
        let d = scratchDefaults()
        let pid = UUID()
        RemoteJobStore.save(job(projectID: pid), defaults: d)

        let deadWorker: (RemoteRunnerConfig, String) -> RunModel.Runner = { _, _ in
            { _, _, _ in throw RemoteRunError(RemoteRun.workerUnreachableMessage) }
        }
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d, reattachRunnerFactory: deadWorker)
        seedProject(app, id: pid)

        app.reattach()

        XCTAssertEqual(app.project?.run.phase, .failed, "a dead job surfaces a failure sheet")
        if case .solver(let msg)? = app.project?.run.failure {
            XCTAssertTrue(msg.contains("unreachable") || msg.contains("Mac"),
                          "the honest 101 message, not a timeout")
        } else {
            XCTFail("expected a solver failure carrying the unreachable message")
        }
        XCTAssertNotNil(RemoteJobStore.load(defaults: d),
                        "a client-side failure must NOT clear the record (retry next launch)")

        app.dismissReattach()
        XCTAssertNil(RemoteJobStore.load(defaults: d), "Dismiss is the only user clear")
        XCTAssertNil(app.pendingReattach)
    }

    /// Dismiss without ever re-attaching clears the record and hides the banner.
    func testDismissClearsWithoutReattaching() {
        let d = scratchDefaults()
        RemoteJobStore.save(job(), defaults: d)
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d)
        XCTAssertNotNil(app.pendingReattach)
        app.dismissReattach()
        XCTAssertNil(app.pendingReattach)
        XCTAssertNil(RemoteJobStore.load(defaults: d))
    }

    /// If the owning project is gone (deleted), re-attach can't host the result: it
    /// says so honestly and leaves the record for a Dismiss rather than silently
    /// dropping it.
    func testReattachWithMissingProjectIsHonest() {
        let d = scratchDefaults()
        RemoteJobStore.save(job(projectID: UUID()), defaults: d)   // id not seeded
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d)
        app.reattach()
        XCTAssertNil(app.pendingReattach)
        XCTAssertNotNil(app.toast, "an honest note that the project couldn't be reopened")
        XCTAssertNotNil(RemoteJobStore.load(defaults: d), "record left for a Dismiss")
    }

    // MARK: - helper

    /// Seed a live project whose RunModel runs synchronously, so `reattach()` resolves
    /// and drives it inline.
    private func seedProject(_ app: AppModel, id: UUID) {
        let run = RunModel(scheduler: SynchronousRunScheduler())
        let pm = ProjectModel(id: id, name: "Bracket", material: "PLA", process: .fdm,
                              importedFile: nil, importedMesh: nil, run: run)
        app.testSeedLiveProject(pm, recent: RecentProject(id: id, name: "Bracket",
                                                          materialName: "PLA", process: .fdm))
    }
}
