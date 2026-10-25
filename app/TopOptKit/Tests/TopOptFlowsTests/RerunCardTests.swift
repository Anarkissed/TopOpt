// RerunCardTests.swift — re-run a finished TO, here or in a copy.
//
// Lifted from #362 (claude/flexible-screens) at b472880b, app/TopOptKit/Tests/TopOptFlowsTests/RerunCardTests.swift, with
// RerunCard (reviewer ruling 2026-10-24 07:30). Copied unchanged; every assertion kept.
//
// His words (2026-10-24): "I need to be able to re-run a TO after one has completed … a card
// saying so and asking if they really want to do it in the current project OR an option to Save
// As a new project."

import XCTest
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RerunCardTests: XCTestCase {

    private func variant(accepted: Bool = true) -> OptimizeVariant {
        OptimizeVariant(requestedVolumeFraction: 0.5, achievedVolumeFraction: 0.5,
                        massGrams: 41.2, supportVolumeVoxels: 0, meshTriangleCount: 12,
                        worstCaseMargin: 2.31, accepted: accepted, v3Passes: true,
                        minFeatureViolations: 0, minFeatureWarning: "",
                        meshVertices: [0, 0, 0, 1, 0, 0, 0, 1, 0], meshIndices: [0, 1, 2],
                        vonMisesField: [1, 2, 3, 4])
    }

    private func finished(_ n: Int, accepted: Bool = true) -> OptimizeOutcome {
        OptimizeOutcome(variants: (0..<n).map { _ in variant(accepted: accepted) },
                        stoppedOnMargin: true, cancelled: false, acceptedCount: accepted ? n : 0,
                        gridNx: 2, gridNy: 2, gridNz: 1, spacing: 1,
                        computedRemotely: false, solvedBy: nil)
    }

    // ── the card's words ────────────────────────────────────────────────────

    func testTheCardSaysTheResultsAreCleared() {
        XCTAssertEqual(RerunCard.title, "Re-running clears this project’s results")
        XCTAssertEqual(RerunCard.rerunHereLabel, "Re-run here")
        XCTAssertEqual(RerunCard.saveAsNewLabel, "Save as new project")
        XCTAssertEqual(RerunCard.cancelLabel, "Cancel")
    }

    // ── the block: identical inputs no longer grey out a finished project ───

    func testSameInputsWithResultsStayEnabled() {
        XCTAssertFalse(RerunCard.greysOut(sameInputsAsLastRun: true, existing: finished(2)))
    }

    func testSameInputsWithoutResultsStillGreyOut() {
        XCTAssertTrue(RerunCard.greysOut(sameInputsAsLastRun: true, existing: nil))
        XCTAssertTrue(RerunCard.greysOut(sameInputsAsLastRun: true,
                                         existing: finished(2, accepted: false)))
    }

    func testChangedInputsNeverGreyOut() {
        XCTAssertFalse(RerunCard.greysOut(sameInputsAsLastRun: false, existing: nil))
    }

    // ── the run handed to the copy ──────────────────────────────────────────

    func testAPendingRunIsTakenOnceAndOnlyByItsProject() {
        let copy = UUID(), other = UUID()
        RerunCard.runOnOpen(copy)
        XCTAssertFalse(RerunCard.takeRunOnOpen(for: other))
        XCTAssertTrue(RerunCard.takeRunOnOpen(for: copy))
        XCTAssertFalse(RerunCard.takeRunOnOpen(for: copy))
    }
}
