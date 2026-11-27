import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE CUBE IS SOLVED ONCE, NOT ONCE PER LAUNCH (his walk, 2026-09-07: "Took 12
/// seconds to load — why is a cached item taking so long? It should take a MAXIMUM of
/// two seconds"). A variant cache HIT already skips the solve; a MISS had to run it,
/// and the only cache was a static in memory.
final class OrganicSampleFieldCacheTests: XCTestCase {

    /// ★ THE TRAP THIS AVOIDS. `String.hashValue` is seeded per PROCESS, so a file
    /// named from one is written under a name that will never be looked for again —
    /// a cache that misses every launch and grows without bound.
    func testTheCachedFieldsNameIsStableAcrossLaunches() {
        let a = OrganicSampleCube.fieldFileName
        XCTAssertEqual(a, OrganicSampleCube.fieldFileName)
        XCTAssertTrue(a.hasPrefix("field-v"), a)
        XCTAssertTrue(a.hasSuffix(".bin"), a)
        // It names the field it holds, so a different load case cannot read it.
        XCTAssertTrue(a.contains("TestCube20"), a)
        XCTAssertTrue(a.contains("res64"), a)
        XCTAssertFalse(a.contains("|"), "no separators a file system would object to")
        XCTAssertFalse(a.contains(":"), a)
        // …and no digits from a per-process hash: every character comes from the
        // identity or the version.
        let allowed = Set("field-v1-.bin" + OrganicSampleCube.fieldIdentity.map {
            $0.isLetter || $0.isNumber ? $0 : "-" })
        XCTAssertTrue(a.allSatisfy { allowed.contains($0) }, a)
    }

    /// The solve is asked for exactly once, and the disk is consulted before it.
    func testTheDiskIsReadBeforeTheSolve() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/OrganicSampleCube.swift"), encoding: .utf8)
        guard let r = src.range(of: "let t = Task.detached(priority: .userInitiated) { () -> Field? in") else {
            return XCTFail("the solve moved")
        }
        let body = String(src[r.lowerBound...].prefix(700))
        XCTAssertTrue(body.contains("if let f = readFieldFromDisk() { return f }"),
                      "★ the disk is read first")
        guard let disk = body.range(of: "readFieldFromDisk()"),
              let solve = body.range(of: "analyzeSolidLoadCase") else {
            return XCTFail("could not order the two")
        }
        XCTAssertLessThan(disk.lowerBound, solve.lowerBound, "★ …before the solve, not after")
        XCTAssertTrue(src.contains("writeFieldToDisk(f)"), "★ and a fresh solve is kept")
    }
}
