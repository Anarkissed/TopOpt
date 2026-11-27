// LibraryCompareTests.swift — Compare's steps (approved mockup 2026-10-25, his decision 1; ★ his iPad notes 11-05, ledger L3,
// his "Yes, as written").
//
// ★ L3 replaces the 10-25 "Better, then ›" step (his decision 2): Better under one side is the choice — the other side is
// rejected and the next result comes in on its side; the winner stays. Tie sets both aside and the next two come in; once
// every result has been seen, the set-aside ones come back against the winner so far, and a second Tie ends Compare with the
// ones still undecided In consideration. The last one left is the part's chosen result. Rejected results are skipped while the
// switch is on (decision 1). One optimization's results compare side by side, with one Best — unchanged.

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
        XCTAssertEqual(s.remaining, 3)
        XCTAssertTrue(s.canTie)
        XCTAssertNil(s.end)
    }

    /// ★ L3: Better rejects the other side and brings the next one in at once; the winner stays.
    func testBetterRejectsTheOtherAndTheNextComesIn() {
        var s = CompareSession(part: part, skipRejected: true)
        XCTAssertEqual(s.better(.left), item(b, 1), "★ the other side is the one rejected")
        XCTAssertEqual(s.left, item(b, 0), "the winner stays")
        XCTAssertEqual(s.right, item(b, 2), "★ the next one comes in on its side, no › to press")
        XCTAssertEqual(s.rejected, [item(b, 1)])
        XCTAssertEqual(s.better(.right), item(b, 0), "the challenger can win")
        XCTAssertEqual(s.right, item(b, 2))
        XCTAssertEqual(s.left, item(a, 0))
    }

    /// ★ L3: the last one left is the part's chosen; every other was rejected along the way.
    func testTheLastOneLeftIsChosen() {
        var s = CompareSession(part: part, skipRejected: true)
        while s.end == nil { s.better(.left) }
        XCTAssertEqual(s.end, .chosen(item(b, 0)), "★ b0 won every pair")
        XCTAssertEqual(s.rejected, [item(b, 1), item(b, 2), item(a, 0), item(a, 1)], "★ 4 rejected, in order")
        XCTAssertEqual(Set(s.seen).count, 5, "every result was seen")
        XCTAssertNil(s.better(.left), "it has ended")
    }

    /// ★ L3: Tie sets both aside and the next two come in; after the rest, they come back against the winner so far.
    func testTieSetsBothAsideAndTheyComeBackAtTheEnd() {
        var s = CompareSession(part: part, skipRejected: true)
        s.tie()                                                         // b0 = b1
        XCTAssertEqual(s.setAside, [item(b, 0), item(b, 1)])
        XCTAssertEqual(s.left, item(b, 2), "★ the next two")
        XCTAssertEqual(s.right, item(a, 0))
        XCTAssertFalse(s.secondLook)
        XCTAssertEqual(s.better(.left), item(a, 0))                     // b2 beats a0; a1 comes in
        XCTAssertEqual(s.right, item(a, 1))
        XCTAssertEqual(s.better(.left), item(a, 1))                     // b2 beats a1; nothing new: b0 comes back
        XCTAssertTrue(s.secondLook, "★ every result seen: the set-aside ones come back")
        XCTAssertEqual(s.right, item(b, 0), "against the winner so far")
        XCTAssertEqual(s.left, item(b, 2))
        XCTAssertEqual(s.better(.right), item(b, 2))                    // b0 beats b2; b1 comes back
        XCTAssertEqual(s.left, item(b, 1))
        XCTAssertEqual(s.better(.right), item(b, 1))
        XCTAssertEqual(s.end, .chosen(item(b, 0)))
    }

    /// ★ L3: a second Tie ends Compare; the ones still undecided stay In consideration, none chosen.
    func testASecondTieEndsInConsideration() {
        var s = CompareSession(part: part, skipRejected: true)
        s.tie()                                                         // b0 = b1 → b2 vs a0
        s.better(.left)                                                 // a0 rejected → b2 vs a1
        s.better(.left)                                                 // a1 rejected → b2 vs b0 (second look)
        XCTAssertTrue(s.secondLook)
        s.tie()                                                         // b2 = b0, with b1 still set aside
        XCTAssertEqual(s.end, .undecided([item(b, 2), item(b, 0), item(b, 1)]), "★ the two on screen and the one still waiting")
        XCTAssertEqual(s.rejected, [item(a, 0), item(a, 1)])
        XCTAssertFalse(s.canTie)
    }

    /// A Tie with nothing new to bring in shows the same two again (the second look); a Tie there ends.
    func testATieOnTheLastPairShowsThemAgainThenEnds() {
        var s = CompareSession(part: part, skipRejected: true)
        s.better(.left); s.better(.left); s.better(.left)              // b0 beats b1, b2, a0 → b0 vs a1
        XCTAssertEqual(s.right, item(a, 1))
        s.tie()
        XCTAssertTrue(s.secondLook, "★ nothing new: the ones he can't decide on come back")
        XCTAssertEqual([s.left, s.right], [item(b, 0), item(a, 1)])
        s.tie()
        XCTAssertEqual(s.end, .undecided([item(b, 0), item(a, 1)]))
    }

    func testOneResultAloneIsChosenWithBetter() {
        var one = LibraryVersion(folderID: a, number: 1, summary: [ResultSummary(massGrams: 90, worstCaseMargin: 13, accepted: true,
                                                                                 achievedVolumeFraction: 0.8)])
        one.setMark(ResultMark(result: 0))
        var s = CompareSession(part: LibraryPart(name: "Stand", modelHash: "y", versions: [one]), skipRejected: true)
        XCTAssertNil(s.right)
        XCTAssertFalse(s.canTie, "no Tie without a pair")
        s.better(.left)
        XCTAssertEqual(s.end, .chosen(item(a, 0)))
    }

    func testChoosingAResultByHandOnASide() {
        var s = CompareSession(part: part, skipRejected: true)
        s.set(.right, to: item(a, 1))
        XCTAssertEqual(s.right, item(a, 1))
        XCTAssertTrue(s.seen.contains(item(a, 1)))
        XCTAssertFalse(s.waiting.contains(item(a, 1)), "it is no longer waiting")
        XCTAssertEqual(s.waiting.first, item(b, 1), "★ the one it replaced waits its turn again")
    }

    func testThreeUpShowsOneOptimizationsResultsWithOneBest() {
        var s = CompareSession.threeUp(part.versions[0])
        XCTAssertEqual(s.items, [item(a, 0), item(a, 1), item(a, 2)], "all of them, rejected included")
        s.best = item(a, 1)
        s.toggleBest(item(a, 1))
        XCTAssertNil(s.best)
    }

    /// ★ L3: In consideration is a mark of its own; a library.json written before reads (and saves) as it was.
    func testInConsiderationIsAMarkAndOldMarksReadAsBefore() throws {
        var m = ResultMark(result: 1)
        XCTAssertTrue(m.isEmpty)
        m.inConsideration = true
        XCTAssertFalse(m.isEmpty, "★ a mark worth keeping")
        let old = try JSONDecoder().decode(ResultMark.self, from: Data(#"{"result":2,"stars":3,"printThis":false,"rejected":true}"#.utf8))
        XCTAssertFalse(old.inConsideration, "★ an old mark reads as before")
        let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(old)) as? [String: Any]
        XCTAssertNil(again?["considering"], "★ and saves as it was: no new key")
    }
}
