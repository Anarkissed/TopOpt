// LibraryCompareTests.swift — Compare's winner-stays steps (approved mockup 2026-10-25, his decisions 1-2).
//
// He taps Better under one model; a › appears on the other; › brings in the next result AND clears
// Better, so every pair is an active choice (decision 2). Rejected results are skipped while the switch
// is on (decision 1). One optimization's results compare side by side, with one Best.

import XCTest
@testable import TopOptFlows

final class LibraryCompareTests: XCTestCase {

    private let a = UUID(), b = UUID(), c = UUID()
    private func item(_ f: UUID, _ r: Int) -> CompareItem { CompareItem(folder: f, result: r) }

    /// v1 (a): 3 results; v2 (b): 3 results; v3 (c): a draft with none.
    private var part: LibraryPart {
        func summary(_ n: Int) -> [ResultSummary] {
            (0..<n).map { ResultSummary(massGrams: 100 + Double($0), worstCaseMargin: 2, accepted: true, achievedVolumeFraction: 1) }
        }
        var v1 = LibraryVersion(folderID: a, number: 1, summary: summary(3))
        v1.setMark(ResultMark(result: 2, rejected: true))
        var v2 = LibraryVersion(folderID: b, number: 2, parentNumber: 1, summary: summary(3))
        v2.setMark(ResultMark(result: 0, stars: 4.5))
        v2.setMark(ResultMark(result: 1, stars: 2))
        let v3 = LibraryVersion(folderID: c, number: 3, parentNumber: 2)
        return LibraryPart(name: "Carriage Arms", modelHash: "x", versions: [v1, v2, v3])
    }

    func testTheQueueIsBestRatedThenNewestAndSkipsRejectedAndDrafts() {
        XCTAssertEqual(CompareSession.queue(part, skipRejected: true),
                       [item(b, 0), item(b, 1), item(b, 2), item(a, 0), item(a, 1)])
        XCTAssertEqual(CompareSession.queue(part, skipRejected: false).count, 6)
    }

    func testItOpensOnTheTwoBest() {
        let s = CompareSession(part: part, skipRejected: true)
        XCTAssertEqual(s.left, item(b, 0))
        XCTAssertEqual(s.right, item(b, 1))
        XCTAssertNil(s.kept)
        XCTAssertFalse(s.showsNext(on: .left) || s.showsNext(on: .right), "no › until he picks")
    }

    func testNextReplacesTheOtherSideAndClearsBetter() {
        var s = CompareSession(part: part, skipRejected: true)
        s.pick(.left)
        XCTAssertTrue(s.showsNext(on: .right))
        XCTAssertFalse(s.showsNext(on: .left))
        XCTAssertTrue(s.next())
        XCTAssertEqual(s.left, item(b, 0), "the one he picked stays")
        XCTAssertEqual(s.right, item(b, 2), "the next one he has not seen")
        XCTAssertNil(s.kept, "his decision 2: he chooses again before moving on")
        XCTAssertFalse(s.next(), "no › without a pick")
    }

    func testTheChallengerCanWinAndTheOldWinnerIsReplaced() {
        var s = CompareSession(part: part, skipRejected: true)
        s.pick(.left); _ = s.next()          // b0 vs b2
        s.pick(.right); _ = s.next()         // b2 stays; b0 is replaced
        XCTAssertEqual(s.right, item(b, 2))
        XCTAssertEqual(s.left, item(a, 0))
    }

    func testItSaysWhenEveryResultHasBeenSeen() {
        var s = CompareSession(part: part, skipRejected: true)
        var steps = 0
        while true {
            s.pick(.left)
            guard s.next() else { break }
            steps += 1
        }
        XCTAssertEqual(steps, 3, "5 results: the two shown, then 3 more")
        XCTAssertEqual(s.remaining, 0)
        XCTAssertEqual(Set(s.seen).count, 5)
    }

    func testPickingTheSameSideAgainUndoesIt() {
        var s = CompareSession(part: part, skipRejected: true)
        s.pick(.left); s.pick(.left)
        XCTAssertNil(s.kept)
    }

    func testChoosingAResultByHandOnASide() {
        var s = CompareSession(part: part, skipRejected: true)
        s.pick(.left)
        s.set(.right, to: item(a, 1))
        XCTAssertEqual(s.right, item(a, 1))
        XCTAssertNil(s.kept, "a new pair is a new choice")
        XCTAssertTrue(s.seen.contains(item(a, 1)))
    }

    func testThreeUpShowsOneOptimizationsResultsWithOneBest() {
        var s = CompareSession.threeUp(part.versions[0])
        XCTAssertEqual(s.items, [item(a, 0), item(a, 1), item(a, 2)], "all of them, rejected included")
        s.best = item(a, 1)
        s.toggleBest(item(a, 1))
        XCTAssertNil(s.best)
    }
}
