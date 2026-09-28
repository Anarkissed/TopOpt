import XCTest
import simd
@testable import TopOptFlows

/// ★ HIS 2026-09-28 OCTET REPORT, pinned: "face2 is entirely quilted. It should not have the
/// strut thickness it has if it quilts - unless 'allow quilting' is selected. It should be
/// avoided at all costs - meaning make the cells smaller"; "The bottom back corner is
/// completely gone now"; the octet's blue rims "a lot wrong … which also does not have the
/// chips". Each test has a control that must go red.
final class LatticeOctetQuiltAndBandTests: XCTestCase {

    // MARK: - one more cell across a wall drawn at the quilt ceiling

    /// His restored project (`LatticeHisSteppedBakeProbe`, DIAG regionDrawnDensity): face 2
    /// p90 0.219 against a 0.219 ceiling over a [0.050, 0.900] band; face 15 p90 0.080; the
    /// leg's facets 0.120–0.182. Face 2 steps (12.03 → 6.015 mm), the others do not.
    func testAWallDrawnAtTheCeilingStepsAndTheOthersDoNot() {
        let lo = 0.05, ceiling = 0.219
        let open = 0.10           // the smaller cell's bead-wide strut density: prints open
        XCTAssertTrue(LatticeRegionCells.quiltTrips(p90: 0.219, lo: lo, ceiling: ceiling, smallerCellFloor: open), "face 2")
        XCTAssertFalse(LatticeRegionCells.quiltTrips(p90: 0.080, lo: lo, ceiling: ceiling, smallerCellFloor: open), "face 15")
        XCTAssertFalse(LatticeRegionCells.quiltTrips(p90: 0.182, lo: lo, ceiling: ceiling, smallerCellFloor: open), "face 23's middle facet")
        // the trip sits at the top fifth of [floor, ceiling]
        let trip = lo + LatticeRegionCells.quiltTripFraction * (ceiling - lo)
        XCTAssertTrue(LatticeRegionCells.quiltTrips(p90: trip + 1e-6, lo: lo, ceiling: ceiling, smallerCellFloor: open))
        XCTAssertFalse(LatticeRegionCells.quiltTrips(p90: trip - 1e-3, lo: lo, ceiling: ceiling, smallerCellFloor: open))
        // ★ never into a cell whose bead-wide strut would itself quilt (the floor would push
        // the smaller cell back over the ceiling)
        XCTAssertFalse(LatticeRegionCells.quiltTrips(p90: 0.219, lo: lo, ceiling: ceiling,
                                                     smallerCellFloor: LatticePreviewOccupancy.finestRungMaxDensity + 0.01))
        // ★ the octet's 6.015 mm cell prints open with his 0.45 mm bead; a 2.0 mm one does not
        let law = LatticeType.named("octet")
        XCTAssertLessThanOrEqual(law.printabilityDensityFloor(lineWidthMM: 0.45, cellMM: 6.015), LatticePreviewOccupancy.finestRungMaxDensity)
        XCTAssertGreaterThan(law.printabilityDensityFloor(lineWidthMM: 0.45, cellMM: 2.0), LatticePreviewOccupancy.finestRungMaxDensity)
    }

    // MARK: - the octree: a tilted face gets its ladder; the grade band stays under the ceiling

    /// A slab 34 × 20 × 34 voxels (1 mm), its face region 12 mm deep along +y, the face's
    /// normal tilted `tiltDeg` about x.
    private func slab(tiltDeg: Double, cell: Double = 6) -> (LatticeVoxelGrid, LatticeVoxelGrid, LatticeRegionSpec) {
        let nx = 34, ny = 20, nz = 34
        let origin = SIMD3<Float>(0.37, 0.63, 0.11)
        var vals = [Float](repeating: 0, count: nx * ny * nz)
        for k in 2..<(nz - 2) { for j in 2..<16 { for i in 2..<(nx - 2) { vals[(k * ny + j) * nx + i] = 1 } } }
        var spec = LatticeRegionSpec(role: .include, kind: .face)
        let t = tiltDeg * .pi / 180
        spec.origin = SIMD3<Double>(Double(origin.x) + 17, Double(origin.y) + 2.5, Double(origin.z) + 17)
        spec.normal = SIMD3<Double>(0, cos(t), sin(t))
        spec.halfUMM = 40; spec.halfWMM = 40
        spec.depthMM = 12
        let h = 14.5
        spec.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
        let occ = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1), values: vals)
        let demand = LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: SIMD3(repeating: 1),
                                      values: [Float](repeating: 0.177, count: vals.count))
        return (occ, demand, spec)
    }

    private func bake(tiltDeg: Double, bandCeiling: Double = 1, band: Double = 8)
        -> (LatticeCellField?, LatticePreviewOccupancy.OctreeBakeStats) {
        let (occ, demand, spec) = slab(tiltDeg: tiltDeg)
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let baked = LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: demand, regions: [spec], cellMM: [6], lineWidthMM: 0.45, realFloorMM: 2.6,
            shapeFitBandMM: band, shapeFit: true, solidBandMM: 0.45, densityLo: 0.073, densityHi: 0.9, densityGamma: 1,
            latticeID: "octet", dyadicSteps: false, bandQuiltCeiling: bandCeiling, stats: &st)
        return (baked, st)
    }

    /// ★ His face 23 is three facets; the foot's is tilted 18° and got NO ladder under a 0.99
    /// gate — no cells, a hole through the part. An 18° face bakes now; the control (40°,
    /// past the 30° gate) is still refused, so the test sees the gate.
    func testATiltedFaceGetsItsLadder() {
        let (b18, st18) = bake(tiltDeg: 18)
        XCTAssertNotNil(b18, "an 18° face baked nothing")
        XCTAssertTrue(st18.noLadderRegions.isEmpty)
        XCTAssertGreaterThan(st18.texelsPainted, 100, "an 18° face painted \(st18.texelsPainted) texels")
        let (b40, st40) = bake(tiltDeg: 40)
        XCTAssertNil(b40, "control: a 40° face is past the gate and must get no ladder")
        XCTAssertEqual(st40.noLadderRegions, [0])
        print("TILT 18°: texels \(st18.texelsPainted), kept \(st18.slotsKept) · 40°: no ladder \(st40.noLadderRegions)")
    }

    /// ★ With Allow quilt off the grade band stops at the ceiling — it grades by smaller cells,
    /// never by closing the windows; the control (ceiling 1, today's) raises the band's finest
    /// cells toward the quilt.
    func testTheGradeBandStopsAtTheCeilingWithoutAllowQuilt() throws {
        let ceiling = LatticeType.named("octet").aestheticDensityCeiling()
        func maxBandDensity(_ bc: Double) throws -> Double {
            let (b, _) = bake(tiltDeg: 0, bandCeiling: bc)
            let baked = try XCTUnwrap(b)
            let top = baked.drawnDensityHi > 0 ? baked.drawnDensityHi : 0.9
            var m = 0.0
            for (i, a) in baked.field.values.enumerated() where a >= 0 && baked.steppedCellMM[i] > 0 {
                let s = Double(baked.steppedCellMM[i])
                // what the printability floor alone would force at this cell
                let floor = LatticeType.named("octet").printabilityDensityFloor(lineWidthMM: 0.45, cellMM: s)
                let rho = 0.073 + (top - 0.073) * Double(a)
                m = Swift.max(m, rho - Swift.max(0, floor - ceiling))
            }
            return m
        }
        let capped = try maxBandDensity(ceiling)
        let quilted = try maxBandDensity(1)
        print(String(format: "BANDCAP densest drawn cell: ceiling %.3f → %.3f · control (no cap) %.3f", ceiling, capped, quilted))
        XCTAssertLessThanOrEqual(capped, ceiling + 0.01, "a cell in the band was drawn over the ceiling with Allow quilt off")
        XCTAssertGreaterThan(quilted, ceiling + 0.1, "control: without the cap the band must raise a cell toward the quilt")
    }

    // MARK: - the octet on the continuous band

    /// ★ The octet takes the band (fine rim grid, chips) when the app asks for it
    /// (`octetBand`); a fixture that does not ask keeps the legacy block.
    func testTheOctetTakesTheBandWhenAsked() {
        let legacy = LatticeSDFScene(mesh: LatticeBandLegacyGoldenTests.boxMesh(), field: nil, latticeID: "octet", maxDim: 64,
                                     regions: [LatticeBandLegacyGoldenTests.topRegion()], whenEmpty: .latticeNothing)
        let band = LatticeSDFScene(mesh: LatticeBandLegacyGoldenTests.boxMesh(), field: nil, latticeID: "octet", maxDim: 64,
                                   regions: [LatticeBandLegacyGoldenTests.topRegion()], whenEmpty: .latticeNothing,
                                   octetBand: true, bandGradeMM: 10)
        XCTAssertNil(legacy.bandFine, "control: without the opt-in the octet keeps the legacy block")
        XCTAssertNotNil(band.bandFine, "the octet did not take the band")
        // the octet keeps its legacy part fields (the per-region cells, and so the run, read them)
        XCTAssertEqual(band.partMaterialSDF.values, legacy.partMaterialSDF.values)
        XCTAssertEqual(band.partSDF.values, legacy.partSDF.values)
        // the octet's rim is its legacy width: skin = rim
        XCTAssertEqual(band.unselectedRimMM, band.unselectedSkinMM, accuracy: 1e-9)
    }
}
