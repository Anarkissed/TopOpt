import XCTest
@testable import TopOptFlows

/// ★ THE GRADE'S STRENGTH (his 2026-09-18): a slider with 0 at the middle, an exponent
/// on the band fraction, saved with the project and carried to both bakes.
final class LatticeGradeStrengthTests: XCTestCase {
    func testTheAmountIsOneAtZeroDoubleAtPlusOneHalfAtMinusOne() {
        XCTAssertEqual(LatticeSettings.gradeAmount(strength: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeAmount(strength: 1), 2, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeAmount(strength: -1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeAmount(strength: 7), 2, accuracy: 1e-12, "clamped")
    }
    func testItPersistsAndReachesTheWizardAndTheProxyParams() throws {
        var s = LatticeSettings()
        XCTAssertEqual(s.shapeFitGradeStrength, 0)
        s.shapeFitGradeStrength = 0.6
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.shapeFitGradeStrength, 0.6, accuracy: 1e-12)
        let m = LatticeWizardModel(settings: back)
        XCTAssertEqual(m.shapeFitGradeStrength, 0.6, accuracy: 1e-12)
        XCTAssertEqual(m.applied(to: LatticeSettings()).shapeFitGradeStrength, 0.6, accuracy: 1e-12)
    }
}

extension LatticeGradeStrengthTests {
    /// The octet: at +1 the band's cells are raised twice as far toward the quilt as at
    /// 0 (clamped at the drawn top); at −1 half as far. The band's reach is unchanged.
    func testTheStrengthScalesTheOctetRaiseNotTheBand() throws {
        // a 30 mm slab, 6 mm cell, band 6, floor 2.6 — the same fixture the band tests use
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        let nx = 34, ny = 20, nz = 34
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        let faceY = Double(origin.y) + 1.8
        for k in 2..<(nz - 2) { for j in 0..<ny {
            let y = Double(origin.y) + Double(j)
            guard y >= faceY - 0.5, y <= faceY + 12.5 else { continue }
            for i in 2..<(nx - 2) { vals[(k * ny + j) * nx + i] = 1 }
        }}
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1), values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1),
                                      values: [Float](repeating: 0.1, count: vals.count))
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        spec.origin = SIMD3<Double>(Double(origin.x) + 17, faceY, Double(origin.z) + 17)
        spec.normal = SIMD3(0, 1, 0); spec.halfUMM = 40; spec.halfWMM = 40; spec.depthMM = 12
        let h = 14.5
        spec.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
        func mean(_ amount: Double) throws -> Double {
            var st = LatticePreviewOccupancy.OctreeBakeStats()
            let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
                occupancy: occ, demand: demand, regions: [spec], cellMM: [6], lineWidthMM: 0.45,
                realFloorMM: 2.6, shapeFitBandMM: 6, shapeFit: true, solidBandMM: 0.45,
                densityLo: 0.073, densityHi: 0.9, densityGamma: 1, latticeID: "octet",
                bandAmount: amount, stats: &st))
            let a = f.field.values.filter { $0 >= 0 }
            return a.reduce(0) { $0 + Double($1) } / Double(max(a.count, 1))
        }
        let base = try mean(1), strong = try mean(2), weak = try mean(0.5)
        print("STRENGTH mean activation: ×0.5 \(weak) · ×1 \(base) · ×2 \(strong)")
        XCTAssertGreaterThan(strong, base, "×2: thicker in the band")
        XCTAssertLessThan(weak, base, "×½: thinner in the band")
    }
}
