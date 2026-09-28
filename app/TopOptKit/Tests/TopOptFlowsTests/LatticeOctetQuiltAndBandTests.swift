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

    private func bake(tiltDeg: Double, bandCeiling: Double = 1, band: Double = 8, amount: Double = 1,
                      slabFollowsTheFace: Bool = false)
        -> (LatticeCellField?, LatticePreviewOccupancy.OctreeBakeStats) {
        var (occ, demand, spec) = slab(tiltDeg: tiltDeg)
        if slabFollowsTheFace {
            // the material starts AT the tilted face and runs 12 mm in along its normal (his foot
            // facet: the surface lies in front of the facet's centre plane on one side)
            let n = LatticeRegionMask.unit(spec.normal)
            for k in 0..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx {
                let p = SIMD3<Double>(occ.origin + SIMD3<Float>(Float(i), Float(j), Float(k)))
                let s = simd_dot(p - spec.origin, n)
                let inside = s >= 0 && s <= 12 && i >= 2 && i < occ.nx - 2 && k >= 2 && k < occ.nz - 2
                occ.values[(k * occ.ny + j) * occ.nx + i] = inside ? 1 : 0
            } } }
        }
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let baked = LatticePreviewOccupancy.octreeCellField(
            occupancy: occ, demand: demand, regions: [spec], cellMM: [6], lineWidthMM: 0.45, realFloorMM: 2.6,
            shapeFitBandMM: band, shapeFit: true, solidBandMM: 0.45, densityLo: 0.073, densityHi: 0.9, densityGamma: 1,
            latticeID: "octet", dyadicSteps: false, bandAmount: amount, bandQuiltCeiling: bandCeiling, stats: &st)
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

    /// ★ A tilted face's WHOLE cells reach its surface (2026-09-28 review). The slots used to be
    /// anchored at the facet's centre plane, so where the surface lies in front of that plane
    /// only the finest fill reached it; the slot range now spans the prism's real extent along
    /// the axis, so whole cells stand there too. (Coverage was never the issue: the fill pass
    /// paints every occupied texel either way — his project: 0 of 10,928 near-surface voxels
    /// bare with or without — so this pins the whole-cell volume, and the control is the old
    /// centre-plane anchoring.)
    func testATiltedFacesWholeCellsReachItsSurface() {
        func run() -> (painted: Int, total: Int, keptVolume: Double) {
            var st = LatticePreviewOccupancy.OctreeBakeStats()
            let (b, st0) = bake(tiltDeg: 18, band: 0, slabFollowsTheFace: true)
            st = st0
            guard let baked = b else { return (0, 1, 0) }
            let (_, _, spec) = slab(tiltDeg: 18)
            let n = LatticeRegionMask.unit(spec.normal)
            let g = baked.field, pitch = Double(g.spacing.x), go = SIMD3<Double>(g.origin)
            var painted = 0, total = 0
            for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx {
                let mid = go + (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5) * pitch
                let s = simd_dot(mid - spec.origin, n)
                guard s > 0.3, s < 3, mid.y < spec.origin.y else { continue }   // in front of the centre plane
                total += 1
                if baked.steppedCellMM[(k * g.ny + j) * g.nx + i] > 0 { painted += 1 }
            } } }
            let vol = st.slotsKept.reduce(0.0) { $0 + pow($1.key, 3) * Double($1.value) }
            return (painted, Swift.max(total, 1), vol)
        }
        let now = run()
        LatticePreviewOccupancy.tiltedSpanEnabled = false
        let old = run()
        LatticePreviewOccupancy.tiltedSpanEnabled = true
        print(String(format: "TILTSURF in front of the centre plane: painted now %d/%d, old %d/%d · whole-cell volume now %.0f mm³, old %.0f mm³",
                     now.painted, now.total, old.painted, old.total, now.keptVolume, old.keptVolume))
        XCTAssertGreaterThan(now.total, 20, "vacuous: no texels in front of the centre plane")
        XCTAssertGreaterThanOrEqual(now.painted, old.painted, "the span left part of the tilted face's surface layer without a cell")
        XCTAssertGreaterThan(now.keptVolume, old.keptVolume,
                             "control: the centre-plane anchoring must stand fewer whole cells — the span changes nothing otherwise")
    }

    /// ★ With Allow quilt off the grade band stops at the ceiling — it grades by smaller cells,
    /// never by closing the windows; the control (ceiling 1, today's) raises the band's finest
    /// cells toward the quilt.
    func testTheGradeBandStopsAtTheCeilingWithoutAllowQuilt() throws {
        let ceiling = LatticeType.named("octet").aestheticDensityCeiling()
        func maxBandDensity(_ bc: Double, amount: Double = 1) throws -> Double {
            let (b, _) = bake(tiltDeg: 0, bandCeiling: bc, amount: amount)
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
        // ★ and at the strongest grade (strength 1 ⇒ amount 2): the raise doubles but never passes q
        let cappedStrong = try maxBandDensity(ceiling, amount: 2)
        let quilted = try maxBandDensity(1)
        print(String(format: "BANDCAP densest drawn cell: ceiling %.3f → %.3f (amount 2: %.3f) · control (no cap) %.3f", ceiling, capped, cappedStrong, quilted))
        XCTAssertLessThanOrEqual(capped, ceiling + 0.01, "a cell in the band was drawn over the ceiling with Allow quilt off")
        XCTAssertLessThanOrEqual(cappedStrong, ceiling + 0.01, "a strong grade pushed a band cell over the ceiling")
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
        // the octet's rim and solid-backed side rim are its legacy width (the skin, ~1.2 mm), never
        // organic's solid rim (3.41 on his stand) — read off the band itself
        XCTAssertEqual(band.bandRimMM, band.unselectedSkinMM, accuracy: 1e-9)
        XCTAssertEqual(band.bandSideRimMM, band.unselectedSkinMM, accuracy: 1e-9)
        XCTAssertGreaterThan(band.bandRimMM, 0.4); XCTAssertLessThan(band.bandRimMM, 2.0)
    }
}
