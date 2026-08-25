import XCTest
@testable import TopOptFlows

final class TmpTriCountProbe: XCTestCase {
    func testCounts() {
        for k in [1, 2] {
            let m = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 10.31, cells: 8,
                                            relativeDensity: 0.35, boundary: .fullSkin,
                                            transition: .stepped,
                                            steppedCoarsePerHalf: k)
            print("CNS k=\(k) tris=\(m.indices.count / 3)")
        }
        let u = LatticeSamplePatch.mesh(lattice: .octet, cellMM: 10.31, cells: 8,
                                        relativeDensity: 0.35, boundary: .fullSkin)
        print("UNIFORM 8 tris=\(u.indices.count / 3)")
    }
}
