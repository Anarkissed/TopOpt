import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ A REGION'S CELL IS NEVER UNDER THE JOB'S TILE FLOOR. Proof arm 3, 2026-10-10 (102117B9,
/// converted to Default Grade, core 3952c411): 20,986 of 22,210 plan cells were 2.06 / 2.00 / 1.72 mm,
/// under the 2.25 mm floor core's E1 gives at a 0.45 mm bead and the octet cap — and under the 2.371
/// prints-open bound. Core's capped derivation handed the fit ≥ 2.25; the fit then took the NEAREST
/// whole number of cells across the wall, and rounding UP put depth/n under the floor (4.12 / 2 = 2.06).
/// The Default Grade ladder never tested its base against the floor, so the preview drew (and the plan
/// sent) quilt cells D5 refuses.
final class LatticeRegionCellTileFloorTests: XCTestCase {

    private var floor: Double {
        LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: 0.45, allowQuilt: false) ?? 0
    }

    /// ★ The fit, as a rule: the nearest whole number of cells, then fewer while a cell would be under
    /// the floor; a wall thinner than one printable cell gets none (0).
    func testTheWholeCellFitNeverGoesUnderTheFloor() {
        XCTAssertEqual(floor, 2.25, accuracy: 1e-9)
        // his 102117B9 numbers: core asked for ≥ 2.25 on a ~4.12 mm wall
        let c = LatticeRegionCells.wholeCellsAcross(depthMM: 4.1248, derivedCellMM: 2.25, tileFloorMM: floor)
        XCTAssertGreaterThanOrEqual(c, floor - 1e-9, "★ never under the floor: \(c)")
        XCTAssertEqual(c, 4.1248, accuracy: 1e-9, "one whole cell across, not two of 2.06")
        // controls: the rounding still lands a whole number of cells where the floor allows
        XCTAssertEqual(LatticeRegionCells.wholeCellsAcross(depthMM: 12.03, derivedCellMM: 2.4, tileFloorMM: floor),
                       12.03 / 5, accuracy: 1e-9, "12.03 / 2.4 = 5.01 ⇒ 5 cells of 2.406")
        XCTAssertEqual(LatticeRegionCells.wholeCellsAcross(depthMM: 14, derivedCellMM: 4.6667, tileFloorMM: floor),
                       14.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(LatticeRegionCells.wholeCellsAcross(depthMM: 2.0, derivedCellMM: 2.25, tileFloorMM: floor), 0,
                       "★ a 2 mm wall holds no printable cell: none, never a 2 mm quilt")
        XCTAssertEqual(LatticeRegionCells.wholeCellsAcross(depthMM: 4.0, derivedCellMM: 2.0, tileFloorMM: 0), 2.0,
                       "no floor stated (Allow quilt off a type with no law): the old nearest-n fit")
    }

    /// ★ The bake lays no ladder whose base is under the floor (a stated cell can be), and says so.
    func testTheBakeLaysNoLadderUnderTheFloor() throws {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 0, 20); r.normal = SIMD3(0, 1, 0); r.halfUMM = 19; r.halfWMM = 19; r.depthMM = 12
        r.outlineLoops = [[SIMD2(-18, -18), SIMD2(18, -18), SIMD2(18, 18), SIMD2(-18, 18)]]
        let sp = SIMD3<Float>(repeating: 1)
        let occ = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: sp, values: vals)
        let dem = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: sp, values: [Float](repeating: 0.3, count: vals.count))
        func bake(_ cell: Double) -> (cells: Int, under: [Int]) {
            var st = LatticePreviewOccupancy.OctreeBakeStats()
            let f = LatticePreviewOccupancy.octreeCellField(
                occupancy: occ, demand: dem, regions: [r], cellMM: [cell], lineWidthMM: 0.45, realFloorMM: floor,
                shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3, densityGamma: 1, latticeID: "octet",
                dyadicSteps: true, stats: &st)
            return (f?.steppedCells.count ?? 0, st.baseUnderFloorRegions)
        }
        let under = bake(2.0)
        XCTAssertEqual(under.cells, 0, "★ no 2 mm cell is laid")
        XCTAssertEqual(under.under, [0], "★ and the bake names the region")
        let control = bake(6.0)
        XCTAssertGreaterThan(control.cells, 0, "control: a 6 mm base is laid")
        XCTAssertEqual(control.under, [])
    }

    /// The fit is the region cells' one rule (source pin): `regionCells` calls it.
    func testRegionCellsUseTheFit() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/LatticeRegionCells.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("var cell = Self.wholeCellsAcross(depthMM: effDepth"))
        XCTAssertTrue(src.contains("return RegionCell(measuredWidthMM: w, cellMM: cell)"))
    }
}
