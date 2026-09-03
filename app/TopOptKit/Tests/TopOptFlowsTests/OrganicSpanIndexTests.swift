import XCTest
import simd
@testable import TopOptFlows

final class OrganicSpanIndexTests: XCTestCase {

    private let file = """
    GRID 1 2 3 0.5 10 20 30
    SKIN 1.2
    SEG 0 0 0 10 0 0 0.5
    SEG 10 0 0 10 10 0 0.5
    BC 0 0 0 1 0
    """

    func testParsesTheDriverFormatAndCarriesItsReceipt() throws {
        let ix = try OrganicSpanIndex.parse(file)
        XCTAssertEqual(ix.gridOrigin, SIMD3(1, 2, 3)); XCTAssertEqual(ix.gridSpacing, 0.5)
        XCTAssertEqual(ix.gridDims, SIMD3(10, 20, 30))
        XCTAssertEqual(ix.count, 2)
        XCTAssertEqual(ix.totalLengthMM, 20, accuracy: 1e-6, "★ the number held against span_length_mm")
    }

    func testRefusesAnEmptyOrHeaderlessFile() {
        XCTAssertThrowsError(try OrganicSpanIndex.parse("GRID 0 0 0 1 1 1 1\n")) {
            XCTAssertEqual($0 as? OrganicSpanIndex.ReadError, .noSpans,
                           "★ zero spans must be an ERROR, never an empty preview (§2B)")
        }
        XCTAssertThrowsError(try OrganicSpanIndex.parse("SEG 0 0 0 1 0 0 0.5\n")) {
            XCTAssertEqual($0 as? OrganicSpanIndex.ReadError, .noGridHeader)
        }
    }

    func testTheIndexFindsEveryCapsuleAQueryTouches() throws {
        let ix = try OrganicSpanIndex.parse(file, cellMM: 4)
        // On the first strut: inside it.
        XCTAssertLessThan(ix.distance(SIMD3(5, 0.2, 0)), 0)
        // Just past its radius: outside, and close.
        XCTAssertEqual(ix.distance(SIMD3(5, 0.9, 0)), 0.4, accuracy: 1e-5)
        // At the shared node both struts are candidates.
        XCTAssertTrue(ix.candidates(near: SIMD3(10, 0, 0)).contains(0))
        XCTAssertTrue(ix.candidates(near: SIMD3(10, 0, 0)).contains(1))
        // Far away: nothing indexed there, and the distance says so.
        XCTAssertEqual(ix.distance(SIMD3(100, 100, 100)), .infinity)
        // Brute force agrees with the index everywhere the index has cells.
        for _ in 0..<500 {
            let p = SIMD3<Float>(Float.random(in: -3...13), Float.random(in: -3...13), Float.random(in: -2...2))
            let brute = ix.segments.map { s -> Float in
                let ab = s.b - s.a, t = max(0, min(1, simd_dot(p - s.a, ab) / simd_dot(ab, ab)))
                return simd_length(p - (s.a + ab * t)) - s.r
            }.min()!
            let d = ix.distance(p)
            if d.isFinite { XCTAssertEqual(d, brute, accuracy: 1e-4) }
            else { XCTAssertGreaterThan(brute, 0, "★ index said nothing near, but a capsule is") }
        }
    }
}

extension OrganicSpanIndexTests {
    func testTheBakedFieldIsTheCapsuleMinAtEveryVoxelCentre() throws {
        let ix = try OrganicSpanIndex.parse("GRID 0 0 0 1 1 1 1\nSEG 0 0 0 10 0 0 0.5\nSEG 10 0 0 10 10 0 0.5\n")
        let origin = SIMD3<Float>(-2, -2, -2), spacing = SIMD3<Float>(0.5, 0.5, 0.5)
        let dims = SIMD3<Int>(30, 30, 9)
        let g = ix.bakeField(origin: origin, spacing: spacing, dims: dims, bandMM: 3)
        XCTAssertEqual(g.values.count, 30 * 30 * 9)
        var k = 0
        for z in 0..<9 { for y in 0..<30 { for x in 0..<30 {
            let p = origin + SIMD3<Float>(Float(x), Float(y), Float(z)) * spacing
            let brute = min(3, ix.segments.map { s -> Float in
                let ab = s.b - s.a, t = max(0, min(1, simd_dot(p - s.a, ab) / simd_dot(ab, ab)))
                return simd_length(p - (s.a + ab * t)) - s.r
            }.min()!)
            XCTAssertEqual(g.values[k], brute, accuracy: 1e-4, "voxel (\(x),\(y),\(z))")
            k += 1
        } } }
        // Inside a strut the field is negative; the band holds far away.
        XCTAssertLessThan(g.values[(4 + 30 * (4 + 30 * 4))], 0)     // (0,0,0) mm = the first node
        // The origin corner (-2,-2,-2) is 3.46 mm from the first node — INSIDE the
        // 3.5 mm reach — so it correctly reads 2.96, not the band. The far corner is
        // 4.06 mm from the nearest node and must read the band exactly.
        XCTAssertEqual(g.values.last!, 3)
    }
}
