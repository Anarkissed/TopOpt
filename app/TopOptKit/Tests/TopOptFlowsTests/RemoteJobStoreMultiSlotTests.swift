// RemoteJobStoreMultiSlotTests — the handoff-121 MULTI-SLOT remote job store.
//
// The reproduction incident: the pre-121 store held ONE slot, so a second submitted
// remote job OVERWROTE the first's record — the app relaunched with no path back to
// the orphaned run. 121 makes the store multi-slot (keyed by jobID); these tests
// prove the round-trip, per-job removal, legacy single-slot migration, and that a
// relaunched AppModel surfaces EVERY outstanding job as a re-attach list.
//
// The M7 /app/ standard is `xcodebuild test` on this package; these are headless.

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RemoteJobStoreMultiSlotTests: XCTestCase {

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("topopt-multislot-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func scratch() -> UserDefaults {
        UserDefaults(suiteName: "topopt.multislot.\(UUID().uuidString)")!
    }

    private func job(_ id: String, project: String? = nil,
                     submittedAt: Date? = Date()) -> PersistedRemoteJob {
        PersistedRemoteJob(host: "10.0.0.4", port: 8757, fingerprint: "fp",
                           jobID: id, submittedAt: submittedAt,
                           projectID: UUID(), projectName: project ?? id)
    }

    // MARK: - round-trip + upsert + remove

    func testTwoJobsRoundTripNewestLast() {
        let d = scratch()
        RemoteJobStore.save(job("A"), defaults: d)
        RemoteJobStore.save(job("B"), defaults: d)
        let all = RemoteJobStore.loadAll(defaults: d)
        XCTAssertEqual(all.map(\.jobID), ["A", "B"], "both survive; newest last")
        XCTAssertEqual(RemoteJobStore.load(defaults: d)?.jobID, "B",
                       "single-slot back-compat load returns the most recent")
    }

    /// The exact bug: a SECOND submit must NOT overwrite the first.
    func testSecondSubmitDoesNotOverwriteFirst() {
        let d = scratch()
        RemoteJobStore.save(job("first"), defaults: d)
        RemoteJobStore.save(job("second"), defaults: d)
        let all = RemoteJobStore.loadAll(defaults: d)
        XCTAssertEqual(all.count, 2, "the first record is NOT clobbered by the second")
        XCTAssertTrue(all.contains { $0.jobID == "first" })
        XCTAssertTrue(all.contains { $0.jobID == "second" })
    }

    func testSaveSameJobIDUpsertsInPlace() {
        let d = scratch()
        RemoteJobStore.save(job("A", project: "Old"), defaults: d)
        RemoteJobStore.save(job("A", project: "New"), defaults: d)
        let all = RemoteJobStore.loadAll(defaults: d)
        XCTAssertEqual(all.count, 1, "same jobID replaces, not appends")
        XCTAssertEqual(all.first?.projectName, "New", "the record is updated in place")
    }

    func testRemoveOneLeavesTheOthers() {
        let d = scratch()
        RemoteJobStore.save(job("A"), defaults: d)
        RemoteJobStore.save(job("B"), defaults: d)
        RemoteJobStore.save(job("C"), defaults: d)
        RemoteJobStore.remove(jobID: "B", defaults: d)
        XCTAssertEqual(RemoteJobStore.loadAll(defaults: d).map(\.jobID), ["A", "C"],
                       "removing one job (a terminal resolution) leaves the rest")
    }

    func testClearRemovesEverything() {
        let d = scratch()
        RemoteJobStore.save(job("A"), defaults: d)
        RemoteJobStore.save(job("B"), defaults: d)
        RemoteJobStore.clear(defaults: d)
        XCTAssertTrue(RemoteJobStore.loadAll(defaults: d).isEmpty)
    }

    // MARK: - legacy single-slot migration (the 119 pattern)

    /// A pre-121 record written under the OLD single-slot key migrates into the
    /// multi-slot store on first read, exactly once, and the legacy key is dropped.
    func testLegacySingleSlotMigratesOnDecode() throws {
        let d = scratch()
        // The pre-121 shape: a single PersistedRemoteJob under the legacy key.
        let legacy = PersistedRemoteJob(host: "h", port: 8757, fingerprint: "f",
                                        jobID: "legacy-1", submittedAt: nil,
                                        projectID: nil, projectName: nil)
        d.set(try JSONEncoder().encode(legacy), forKey: RemoteJobStore.legacyKey)

        let all = RemoteJobStore.loadAll(defaults: d)
        XCTAssertEqual(all.map(\.jobID), ["legacy-1"], "the legacy record is folded in")
        XCTAssertNil(d.data(forKey: RemoteJobStore.legacyKey),
                     "the legacy key is dropped after migration")
        XCTAssertNotNil(d.data(forKey: RemoteJobStore.multiKey),
                        "the record is rewritten under the multi-slot key")

        // A second read is stable (migration is idempotent) and finds it in v2 only.
        XCTAssertEqual(RemoteJobStore.loadAll(defaults: d).map(\.jobID), ["legacy-1"])
    }

    /// Legacy + a v2 record coexisting: both surface, deduped by jobID.
    func testLegacyMergesWithExistingMultiSlot() throws {
        let d = scratch()
        RemoteJobStore.save(job("v2-job"), defaults: d)
        let legacy = PersistedRemoteJob(host: "h", port: 8757, fingerprint: "f",
                                        jobID: "legacy-1", submittedAt: nil)
        d.set(try JSONEncoder().encode(legacy), forKey: RemoteJobStore.legacyKey)

        let ids = Set(RemoteJobStore.loadAll(defaults: d).map(\.jobID))
        XCTAssertEqual(ids, ["v2-job", "legacy-1"], "both the migrated and existing records survive")
    }

    // MARK: - AppModel surfaces the list on relaunch

    func testRelaunchedAppSurfacesAllOutstandingJobs() {
        let d = scratch()
        RemoteJobStore.save(job("A", project: "Bracket"), defaults: d)
        RemoteJobStore.save(job("B", project: "Mount"), defaults: d)

        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d)
        XCTAssertEqual(app.pendingReattachJobs.count, 2,
                       "a relaunched app surfaces EVERY outstanding remote job")
        XCTAssertEqual(app.pendingReattach?.jobID, "A",
                       "the single-banner convenience returns the first")
    }

    func testDismissOneJobLeavesTheOthersOnAppModel() {
        let d = scratch()
        RemoteJobStore.save(job("A"), defaults: d)
        RemoteJobStore.save(job("B"), defaults: d)
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d)
        let a = app.pendingReattachJobs.first { $0.jobID == "A" }!

        app.dismissReattach(a)

        XCTAssertEqual(app.pendingReattachJobs.map(\.jobID), ["B"],
                       "dismissing one job leaves the others in the list")
        XCTAssertEqual(RemoteJobStore.loadAll(defaults: d).map(\.jobID), ["B"],
                       "and removes only that job's persisted record")
    }

    func testDismissAllClearsListAndStore() {
        let d = scratch()
        RemoteJobStore.save(job("A"), defaults: d)
        RemoteJobStore.save(job("B"), defaults: d)
        let app = AppModel(materialsPath: nil, store: ProjectStore(rootDir: tempDir),
                           remoteJobDefaults: d)
        app.dismissAllReattach()
        XCTAssertTrue(app.pendingReattachJobs.isEmpty)
        XCTAssertTrue(RemoteJobStore.loadAll(defaults: d).isEmpty)
    }
}
