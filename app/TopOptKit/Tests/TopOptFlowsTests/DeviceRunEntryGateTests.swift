// DeviceRunEntryGateTests.swift — task 2026-08-03-retention-designbox-device-failure.
//
// WHY THIS FILE EXISTS. PRs 284 and 285 both passed their bars and both failed in
// the maintainer's hands on the very next run. The reason is the same for both:
// every existing gate test feeds the gate a HAND-WRITTEN job dictionary
// (`VariantEntryGatingTests.job(designBox:)` builds one from four literal keys),
// so the suite proved the gate's arithmetic and never once proved the gate's
// VERDICT on a document a real run actually produced.
//
// So this file gates on the REAL ARTIFACT: `evidence/.../device_run_job.json` is
// the byte-for-byte job document from the maintainer's WallMount ShelfBracket run
// of 2026-08-02 01:23 (worker job b56bbf4421f34212), the run whose two refusals
// are the whole reason for this task. Nothing here constructs a job.
//
// It fails against the broken state: on `main` at ce4e181 the LATTICE assertion
// below reports `.designBoxRun` for a run core now certifies happily.

import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class DeviceRunEntryGateTests: XCTestCase {

    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    /// The maintainer's own run, as the worker stored it. A design-box run on a Mac
    /// worker with a declared load case — the exact configuration both PRs claimed
    /// to have unblocked.
    private func deviceJob() throws -> Data {
        try Data(contentsOf: Self.repoRoot.appendingPathComponent(
            "evidence/2026-08-03-retention-designbox-device-failure/device_run_job.json"))
    }

    /// The facts as the workspace builds them for that run: worker-solved, both
    /// retention halves present (the worker served `out/design.bin`, 1 573 112
    /// bytes), geometry exported, a worker still selected.
    private func deviceFacts(job: Data) -> VariantEntryFacts {
        VariantEntryFacts(
            hasGeometry: true,
            machine: .worker(name: "Mac mini"),
            retainedJob: job,
            retainedDesign: Data([1, 2, 3, 4]),
            runGeneratedLattice: false,
            modelPath: "/tmp/WallMount_ShelfBracket.stl",
            workerSelected: true,
            runInFlight: false)
    }

    // MARK: - the artifact itself

    /// The retention pair is not the thing that broke. The document the run kept is
    /// readable, declares its design box, and carries the load case a
    /// re-certification needs — so any refusal that blames retention is misreporting
    /// its own cause.
    func testTheDeviceRunsRetainedJobIsCompleteAndReadable() throws {
        let job = try deviceJob()
        XCTAssertTrue(RetainedJobFacts.parse(job).declaresDesignBox,
                      "this run DID use a design box — that is the premise")
        let lc = try SmoothRecertLoadCase.fromRetainedJob(job)
        XCTAssertEqual(lc.material, "PLA")
        XCTAssertEqual(lc.resolution, 64)
        XCTAssertEqual(lc.anchorFaceIDs, [8, 14, 12])
        XCTAssertEqual(lc.loadGroups.count, 1)
        XCTAssertEqual(lc.freeze.count, 3, "the three keep-clear bores survive")
    }

    // MARK: - the two entries, on the real document

    /// SMOOTH. A worker run that kept a parseable job document has a load case to
    /// re-certify under, so the entry is ENABLED.
    func testSmoothIsAvailableOnTheDeviceRun() throws {
        let v = VariantEntry.smoothing(deviceFacts(job: try deviceJob()))
        XCTAssertTrue(v.enabled,
                      "Smooth is blocked on a run that kept everything it needed: "
                      + (v.allReasons.first ?? "—"))
    }

    /// LATTICE — THE REGRESSION PR 285 LEFT BEHIND.
    ///
    /// PR 285 removed core's design-box lattice refusal (`run_job.cpp`'s
    /// "lattice certification does not support a design box" throw, both the
    /// optimize pre-flight and `lattice_variant_job`). The app's block was written
    /// as a MIRROR of that refusal and was never dropped with it, so the app is now
    /// the last one holding a rule the solver no longer has.
    ///
    /// On `main` at ce4e181 this reports:
    ///   "this run used a design box — the certification load case can’t be rebuilt
    ///    on the expanded grid, so the core refuses to lattice it…"
    /// which is a statement about core that is no longer true.
    func testLatticeIsAvailableOnTheDeviceRunBecauseCoreNoLongerRefusesIt() throws {
        let v = VariantEntry.lattice(deviceFacts(job: try deviceJob()))
        XCTAssertFalse(
            v.allReasons.contains(RelatticeUnavailable.designBoxRun.reason),
            "the app still refuses a design-box run that core now certifies")
        XCTAssertTrue(v.enabled,
                      "Lattice is blocked on a design-box run: "
                      + (v.allReasons.first ?? "—"))
    }

    /// AND THE MIRROR MUST BE HONEST ABOUT ITSELF. `designBoxRefused` is the
    /// constant the source-reading tripwire tells you to flip; it is only worth
    /// flipping if the gate actually consults it. Before this task it did not — the
    /// gate appended `.designBoxRun` unconditionally — so the documented remedy was
    /// inert and flipping it would have changed nothing a user can see.
    func testTheGateActuallyConsultsTheCoreCapabilityConstant() throws {
        XCTAssertFalse(LatticeCoreCapability.designBoxRefused,
                       "core dropped the refusal in PR 285; the mirror must follow")
        let blocks = VariantEntry.latticeBlocks(deviceFacts(job: try deviceJob()))
        XCTAssertFalse(blocks.contains(RelatticeUnavailable.designBoxRun.reason))
    }
}
