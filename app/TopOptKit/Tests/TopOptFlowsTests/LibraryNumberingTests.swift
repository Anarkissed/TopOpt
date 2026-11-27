// LibraryNumberingTests.swift — his decision 11 (2026-10-25 20:12): "if you decide to run an optimization
// for an older version - let's say most recent is v7 and I want to run v4 again - it should come out
// with 'v4.1' not 'v8' so that it's clear what it was."
//
// From the newest main-line version the main line continues (v7 → v8); from an older one it branches
// (v4 → v4.1, again → v4.2); a branch's child goes one level deeper (v4.1 → v4.1.1). Numbers are never
// reused. Grouped copies stay on the main line. A file written before branches existed still reads.

import XCTest
@testable import TopOptFlows

final class LibraryNumberingTests: XCTestCase {

    private func n(_ s: String) -> VersionNumber { VersionNumber(s)! }

    /// v1…v7 on the main line.
    private func mainLine(_ count: Int = 7) -> LibraryPart {
        LibraryPart(name: "Carriage Arms", modelHash: "x",
                    versions: (1...count).map { LibraryVersion(folderID: UUID(), number: VersionNumber($0), parentNumber: $0 > 1 ? VersionNumber($0 - 1) : nil) })
    }

    func testTheNumberReadsAndPrintsWithDots() {
        XCTAssertEqual(n("4.1.1").path, [4, 1, 1])
        XCTAssertEqual(n("4.1.1").description, "4.1.1")
        XCTAssertEqual(VersionNumber(7).description, "7")
        XCTAssertNil(VersionNumber("4..1"))
        XCTAssertNil(VersionNumber("0"))
        XCTAssertNil(VersionNumber("v4"))
        XCTAssertEqual(n("4.1").parent, n("4"))
        XCTAssertNil(n("4").parent)
        XCTAssertTrue(n("7").isMainLine)
        XCTAssertFalse(n("4.1").isMainLine)
    }

    func testTheTreeOrderPutsABranchRightAfterItsParent() {
        let sorted = ["5", "4.2", "4", "4.1.1", "4.1", "3", "10"].map(n).sorted()
        XCTAssertEqual(sorted.map(\.description), ["3", "4", "4.1", "4.1.1", "4.2", "5", "10"])
    }

    func testFromTheNewestTheMainLineContinues() {
        let p = mainLine()
        XCTAssertEqual(p.nextNumber(from: n("7")), n("8"))
        XCTAssertEqual(p.nextNumber(from: nil), n("8"), "a new folder with no parent joins the main line")
    }

    func testFromAnOlderVersionItBranches() {
        var p = mainLine()
        XCTAssertEqual(p.nextNumber(from: n("4")), n("4.1"))
        p.versions.append(LibraryVersion(folderID: UUID(), number: n("4.1"), parentNumber: n("4")))
        XCTAssertEqual(p.nextNumber(from: n("4")), n("4.2"), "a second branch from v4")
        XCTAssertEqual(p.nextNumber(from: n("4.1")), n("4.1.1"), "a branch's own child goes one level deeper")
        XCTAssertEqual(p.nextNumber(from: n("7")), n("8"), "the main line is unaffected")
    }

    func testNoNumberIsGivenTwiceAfterADeletion() {
        var p = mainLine()
        p.versions.append(LibraryVersion(folderID: UUID(), number: n("4.1"), parentNumber: n("4")))
        p.forget(p.versions.last!)        // v4.1 deleted
        XCTAssertEqual(p.nextNumber(from: n("4")), n("4.2"))
        p.forget(p.versions.first { $0.number == n("7") }!)   // v7 deleted: v6 is now the newest
        XCTAssertEqual(p.nextNumber(from: n("6")), n("8"), "the newest continues the main line, past the deleted v7")
    }

    func testAFileWrittenBeforeBranchesStillReadsAndAMainLineFileIsUnchanged() throws {
        let old = Data(#"{"folderID":"9B4C5C90-3871-4F7F-99C0-7AF13BB3466C","number":3,"parentNumber":2,"changes":[],"marks":[]}"#.utf8)
        let v = try JSONDecoder().decode(LibraryVersion.self, from: old)
        XCTAssertEqual(v.number, n("3"))
        XCTAssertEqual(v.parentNumber, n("2"))
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let again = String(decoding: try enc.encode(v), as: UTF8.self)
        XCTAssertTrue(again.contains(#""number":3"#), again)
        let branch = LibraryVersion(folderID: UUID(), number: n("4.1"), parentNumber: n("4"))
        let b = try JSONDecoder().decode(LibraryVersion.self, from: try enc.encode(branch))
        XCTAssertEqual(b.number, n("4.1"))
    }

    func testTheAutomaticNameCarriesTheDottedNumber() {
        XCTAssertEqual(VersionChanges.autoName(part: "Carriage Arms", number: n("4.1"), changes: [], resolution: 64),
                       "Carriage Arms · v4.1 · same settings")
    }
}
