import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ BATCH E on HIS project (the Flexible track's copies of 'Pad split top', restored the way the
/// app restores them — `FlexibleHisProject`, `asSaved`): kept apart from `LatticeSectorOutlineTests`
/// so the #354 commit cherry-picks without this branch's fixtures.
@MainActor
final class LatticeSectorHisProjectTests: XCTestCase {

    // MARK: - HIS project, restored the way the app restores it

    /// ★ HIS IMG 4 STATE ('Pad split top', round 3 copy: 'Top' = region 103 'top A', Lattice, 25 mm,
    /// a 10 kg load, NOT protected). Before: 'top A' did not reach the run, the row said "Frozen, not
    /// latticed" and nothing was emitted. Now: one prism on x ≥ 50, 25 mm deep, half of face 1.
    func testHisImg4StateLatticesTopAOnItsOwnHalf() throws {
        let his = try FlexibleHisProject.restore(FlexibleHisProject.dir, asSaved: true)
        defer { his.cleanup() }
        let p = his.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(top.regionIDs, [103], "control: his round 3 copy")
        XCTAssertFalse(p.force.isProtected(top.id), "control: his Top group is not protected")
        XCTAssertTrue(p.latticeReachesTheRun(.region(group: top.id, region: 103)), "★ no 'Frozen' chip on top A")
        let e = p.latticeJobRegions()
        XCTAssertEqual(e.skippedRegionNames, [], "★ nothing left out")
        let inc = e.regions.filter { $0.role == .include }
        XCTAssertEqual(inc.count, 1, "★ one prism: top A")
        let r = try XCTUnwrap(inc.first)
        XCTAssertEqual(r.selectableKey, LatticeSelectableRef.region(group: top.id, region: 103).key)
        XCTAssertEqual(r.depthMM, 25, accuracy: 1e-9)
        XCTAssertEqual(LatticeSectorOutlineTests.area(r), 5000, accuracy: 1, "★ half of the 100 × 100 top")
        for v in LatticeSectorOutlineTests.worldVertices(r) { XCTAssertGreaterThanOrEqual(v.x, 50 - 1e-4, "★ x ≥ 50 only") }
        print("E-HIS-R3 include \(inc.count) area \(LatticeSectorOutlineTests.area(r)) depth \(r.depthMM) x-range "
              + "\(LatticeSectorOutlineTests.worldVertices(r).map(\.x).min() ?? -1)…\(LatticeSectorOutlineTests.worldVertices(r).map(\.x).max() ?? -1)")
    }

    /// ★ HIS ROUND 5 STATE (the live store: 'Top' = 103 'top A' + 105 'Union of 2' = top A + top B).
    /// The union speaks for its pieces: face 1's two halves at the union's depth, a seam between them,
    /// and 'top A' told ONCE (it is folded under the union with the same role — ruling (g)'s test).
    func testHisRound5UnionLatticesBothHalvesOnce() throws {
        let his = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir, asSaved: true)
        defer { his.cleanup() }
        let p = his.project
        let top = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        XCTAssertEqual(top.regionIDs, [103, 105], "control: his round 5 copy")
        XCTAssertTrue(p.latticeReachesTheRun(.region(group: top.id, region: 105)))
        let e = p.latticeJobRegions()
        XCTAssertEqual(e.skippedRegionNames, [], "★ neither 'Union of 2' nor 'top A' is left out")
        let unionKey = LatticeSelectableRef.region(group: top.id, region: 105).key
        let aKey = LatticeSelectableRef.region(group: top.id, region: 103).key
        let inc = e.regions.filter { $0.role == .include }
        XCTAssertEqual(inc.filter { $0.selectableKey == unionKey }.count, 2, "★ the union's two halves")
        XCTAssertEqual(inc.filter { $0.selectableKey == aKey }.count, 0, "★ top A is told once, by its union")
        XCTAssertEqual(inc.map { LatticeSectorOutlineTests.area($0) }.reduce(0, +), 10000, accuracy: 1, "★ the whole top, no overlap")
        for r in inc {
            XCTAssertEqual(r.depthMM, p.latticeSlabDepthMM(.region(group: top.id, region: 105), in: top.id), accuracy: 1e-9,
                           "the union row's own depth")
            XCTAssertTrue(r.outlineSeams.joined().contains(true), "★ the cut between the halves is a seam")
        }
        print("E-HIS-R5 include \(inc.count) areas \(inc.map { LatticeSectorOutlineTests.area($0) }) depth \(inc.map(\.depthMM))")
    }
}
