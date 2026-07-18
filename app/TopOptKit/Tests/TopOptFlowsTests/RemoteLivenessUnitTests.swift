// RemoteLivenessUnitTests — the parts of the handoff-101 liveness redesign that
// are PURE logic and run in the normal suite (no worker, no network): the "last
// update Xs ago" freshness cue and the re-attach job store. The end-to-end
// liveness behaviour (heartbeat, reconnect, dedup, unreachable, cancel) is proven
// against the real worker by RemoteRunnerE2ETests + the Python harness (handoff
// 101 §Evidence).

import XCTest
@testable import TopOptFlows

@MainActor
final class RemoteLivenessUnitTests: XCTestCase {

    // MARK: freshness cue (requirement 6)

    func testFreshnessNoteHiddenWhileFresh() {
        let now = Date()
        // A sub-2×-heartbeat gap is a healthy cadence → no cue (no crying wolf).
        XCTAssertNil(RunModel.remoteFreshnessNote(lastUpdate: now.addingTimeInterval(-5),
                                                  now: now, heartbeat: 20))
        XCTAssertNil(RunModel.remoteFreshnessNote(lastUpdate: now.addingTimeInterval(-39),
                                                  now: now, heartbeat: 20))
    }

    func testFreshnessNoteAppearsOnceStale() {
        let now = Date()
        // Past ~2× the heartbeat, the stalled worker becomes visible.
        let note = RunModel.remoteFreshnessNote(lastUpdate: now.addingTimeInterval(-41),
                                                now: now, heartbeat: 20)
        XCTAssertEqual(note, "last update 41s ago")
    }

    func testFreshnessNoteNilWithoutABaseline() {
        // Before any live signal there is nothing to be stale against.
        XCTAssertNil(RunModel.remoteFreshnessNote(lastUpdate: nil))
    }

    func testFreshnessScalesWithHeartbeat() {
        let now = Date()
        // A 3s gap is stale against a 1s heartbeat (harness) but fresh against 20s.
        XCTAssertEqual(RunModel.remoteFreshnessNote(lastUpdate: now.addingTimeInterval(-3),
                                                    now: now, heartbeat: 1),
                       "last update 3s ago")
        XCTAssertNil(RunModel.remoteFreshnessNote(lastUpdate: now.addingTimeInterval(-3),
                                                  now: now, heartbeat: 20))
    }

    // MARK: re-attach job store (requirement 5)

    private func scratchDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "topopt.test.\(UUID().uuidString)")!
        return d
    }

    func testJobStoreRoundTrips() {
        let d = scratchDefaults()
        XCTAssertNil(RemoteJobStore.load(defaults: d))
        let job = PersistedRemoteJob(host: "10.0.0.4", port: 8757,
                                     fingerprint: "abc123", jobID: "job-xyz")
        RemoteJobStore.save(job, defaults: d)
        XCTAssertEqual(RemoteJobStore.load(defaults: d), job,
                       "the active remote job survives so a slept iPad can re-attach")
    }

    func testJobStoreOverwriteAndClear() {
        let d = scratchDefaults()
        RemoteJobStore.save(PersistedRemoteJob(host: "h", port: 1, fingerprint: "f", jobID: "a"),
                            defaults: d)
        RemoteJobStore.save(PersistedRemoteJob(host: "h", port: 1, fingerprint: "f", jobID: "b"),
                            defaults: d)
        XCTAssertEqual(RemoteJobStore.load(defaults: d)?.jobID, "b", "single-slot: newest wins")
        RemoteJobStore.clear(defaults: d)
        XCTAssertNil(RemoteJobStore.load(defaults: d), "a resolved run clears the re-attach record")
    }

    // MARK: config defaults (no wall clock)

    func testConfigHasNoWallClockCeiling() {
        // The old fixed `timeout` is gone; liveness is the inactivity grace, which
        // is NOT a run ceiling. This documents the shape the redesign guarantees.
        let cfg = RemoteRunnerConfig(host: "h", expectedFingerprint: "f")
        XCTAssertEqual(cfg.inactivityGrace, 180, accuracy: 0.001)
        XCTAssertGreaterThan(cfg.requestTimeout, 0)
        XCTAssertGreaterThan(cfg.controlTimeout, 0)
    }
}
