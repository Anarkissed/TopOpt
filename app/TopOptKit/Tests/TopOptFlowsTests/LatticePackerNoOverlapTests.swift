import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE PACKER OVERLAP (#358 on 3418E167's Aesthetic Stepped plan with base 14, relayed by the
/// reviewer 2026-10-10 20:05: "cell 10 (3.5 mm) overlaps cell 3 (4.667 mm) in the SAME region by
/// 2.333 x 3.5 x 1.167 mm. That's the app's packer … fix it red-first, and make the bake assert that
/// no two cells of one region overlap."). Measured on last round's plans: 141 on 3418E167, 329 on
/// 68BF7B74 (his own Stepped project), 0 on both Default Grade plans; in all 470 the smaller cell was
/// the region's finest tile — `packSlot`'s fill pass laid a whole finest cell over a base/12
/// position only PART free, after the slot had mixed families whose tiles do not nest (thirds every
/// 4 steps, quarters every 3). The preview drew the free sliver; the plan sent the whole cell.
final class LatticePackerNoOverlapTests: XCTestCase {

    /// A 40 mm block at 1 mm voxels; one include face per side given, 14 mm deep (his 3418E167
    /// region 1 depth and base), outline a 36 mm square, so most base slots are cut and packed.
    private func block(depthMM: Double = 14) -> (occ: LatticeVoxelGrid, demand: LatticeVoxelGrid, regions: [LatticeRegionSpec]) {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        func face(origin o: SIMD3<Double>, normal: SIMD3<Double>) -> LatticeRegionSpec {
            var r = LatticeRegionSpec(role: .include, kind: .face)
            r.origin = o; r.normal = normal
            r.halfUMM = 19; r.halfWMM = 19; r.depthMM = depthMM
            let h = 18.0
            r.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
            return r
        }
        let spacing = SIMD3<Float>(repeating: 1)
        return (LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vals),
                LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                 values: [Float](repeating: 0.3, count: vals.count)),
                [face(origin: SIMD3(20, 0, 20), normal: SIMD3(0, 1, 0)),
                 face(origin: SIMD3(0, 20, 20), normal: SIMD3(1, 0, 0))])
    }

    private func bake(cellMM: [Double], anyStep: Bool = true, printsOpen: Bool = true,
                      depthMM: Double = 14) throws -> (cells: [LatticeSteppedCell], stats: LatticePreviewOccupancy.OctreeBakeStats) {
        let s = block(depthMM: depthMM)
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: cellMM, lineWidthMM: 0.45,
            realFloorMM: 2.25, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: !anyStep, finestPrintsOpen: printsOpen,
            densityCap: LatticeSettings.jobDensityCap(topologyID: "octet", allowQuilt: false), stats: &st), "no bake")
        return (f.steppedCells, st)
    }

    private static func histogram(_ cells: [LatticeSteppedCell]) -> String {
        Dictionary(grouping: cells, by: { ($0.sizeMM * 1000).rounded() / 1000 }).mapValues(\.count)
            .sorted { $0.key > $1.key }.map { String(format: "%.3f=%d", $0.key, $0.value) }.joined(separator: " ")
    }

    /// ★ RED on the defect: the any-step bake of a 14 mm base (halves 7, thirds 4.667, quarters 3.5
    /// admitted at a 0.45 mm bead; sixths 2.333 dropped by prints-open) lays NO two cells of one
    /// region over each other — the overlap checker the bake and the writer share says 0.
    func testNoTwoCellsOfOneRegionOverlapUnderAnyStep() throws {
        for (label, cellMM, printsOpen) in [("14 mm, aesthetic", [14.0, 14.0], true),
                                            ("12.075 mm, aesthetic (68BF7B74's region 3)", [12.075, 12.075], true),
                                            ("10.31 mm, aesthetic (his 4/5)", [10.3122, 10.3122], true),
                                            ("12 mm, structural (floor alone: sixths in)", [12.0, 12.0], false)] {
            let b = try bake(cellMM: cellMM, printsOpen: printsOpen, depthMM: cellMM[0])
            XCTAssertFalse(b.cells.isEmpty, label)
            let over = LatticeSteppedCell.sameRegionOverlaps(b.cells)
            XCTAssertEqual(over.count, 0, "★ \(label): \(over.prefix(3))")
            XCTAssertEqual(b.stats.sameRegionOverlaps, 0, "★ the bake's own count: \(label)")
            print("PACK-NO-OVERLAP \(label): cells=\(b.cells.count) overlaps=\(over.count) | \(Self.histogram(b.cells))")
        }
    }

    /// Default Grade (halves only) never mixed families, and stays at 0 (control on the other menu).
    func testDefaultGradeStaysClean() throws {
        let b = try bake(cellMM: [14, 14], anyStep: false)
        XCTAssertEqual(LatticeSteppedCell.sameRegionOverlaps(b.cells).count, 0)
    }

    /// ★ The checker sees an overlap (its positive control), only within ONE region, and touching
    /// faces are not overlaps.
    func testTheCheckerSeesAnOverlapAndOnlyThat() {
        func c(_ r: Int, _ o: SIMD3<Double>, _ s: Double) -> LatticeSteppedCell { LatticeSteppedCell(region: r, originMM: o, sizeMM: s) }
        let over = LatticeSteppedCell.sameRegionOverlaps([c(0, .zero, 4.667), c(0, SIMD3(2.333, 0, 3.5), 3.5)])
        XCTAssertEqual(over.count, 1, "★ the 3418E167 pair, as #358 measured it")
        XCTAssertEqual(over.first?.region, 0)
        XCTAssertEqual(over.first.map { $0.extentMM.x } ?? 0, 2.334, accuracy: 1e-9)
        XCTAssertTrue(LatticeSteppedCell.sameRegionOverlaps([c(0, .zero, 4), c(0, SIMD3(4, 0, 0), 4)]).isEmpty, "touching faces")
        XCTAssertTrue(LatticeSteppedCell.sameRegionOverlaps([c(0, .zero, 4), c(1, SIMD3(1, 1, 1), 4)]).isEmpty,
                      "two regions: core's straddler rule decides those, not this check")
    }

    /// ★ The writer withholds a plan whose cells overlap in one region, in words, never sends it.
    func testTheWriterWithholdsOverlappingCells() {
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.normal = SIMD3(0, 0, 1); face.depthMM = 14; face.halfUMM = 20; face.halfWMM = 20
        func w(_ o: SIMD3<Double>, _ s: Double) -> LatticeSteppedCellWire {
            LatticeSteppedCellWire(regionID: 1, originMM: o, sizeMM: s, planBaseCellMM: 14)
        }
        let bad = [w(.zero, 14.0 / 3), w(SIMD3(14.0 / 3 - 2.333, 0, 3.5), 3.5)]
        guard case .failure(.cellsOverlap(let id, let n)) = LatticeSteppedCellWire.plannedRegions(bad, regions: [face]) else {
            return XCTFail("★ withheld")
        }
        XCTAssertEqual(id, 1); XCTAssertEqual(n, 1)
        XCTAssertTrue(LatticeSteppedCellWire.PlanWithheld.cellsOverlap(regionID: 1, count: 1).reason.contains("region 1"))
        guard case .success = LatticeSteppedCellWire.plannedRegions([w(.zero, 7), w(SIMD3(7, 0, 0), 7)], regions: [face]) else {
            return XCTFail("control: touching cells go")
        }
    }
}
