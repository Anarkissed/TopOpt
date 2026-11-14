import XCTest
import simd
@testable import TopOptFlows

/// ★ WHAT THE STEPPED BAKE ACTUALLY WROTE, on his own part. No assertions about what it
/// ought to be — this prints the distribution so the grading is a measurement instead of
/// a claim. He reported "not seeing grading whatsoever" twice; that is the thing to
/// explain, and the numbers below are what explains it.
final class LatticeSteppedGradeProbe: XCTestCase {

    func testWhatTheSteppedBakeWrote() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        guard let r15 = LatticeRegionEmission.planeFor(face: FaceID(15), in: mesh),
              let s15 = LatticeRegionEmission.spec(for: r15, role: .include,
                                                  depthMM: 11.0, faceID: 15)
        else { throw XCTSkip("face 15 has no planar geometry") }
        let regions = [s15]
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: regions, whenEmpty: .latticeNothing)

        let occ = scene.occupancy
        let voxelMM = Double(max(occ.spacing.x, max(occ.spacing.y, occ.spacing.z)))
        let cand = occ.values.map { $0 > 0.5 }
        let inside = cand.filter { $0 }.count
        let perRegion = LatticeBoundaryDistance.inPlanePerRegion(
            regions: regions, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let d = perRegion.first.flatMap { $0 } ?? []
        XCTAssertFalse(d.isEmpty, "face 15 got no in-plane field — is it axis-aligned?")

        print("=== STEPPED GRADE PROBE ===")
        print("grid \(occ.nx)x\(occ.ny)x\(occ.nz)  voxel \(String(format: "%.3f", voxelMM)) mm")
        print("latticed voxels: \(inside)")
        let dv = d.enumerated().filter { cand[$0.offset] }.map { $0.element }.sorted()
        if !dv.isEmpty {
            func pct(_ p: Double) -> Double { dv[Int(p * Double(dv.count - 1))] }
            print(String(format: "boundary distance mm: min %.2f  p25 %.2f  p50 %.2f  p75 %.2f  max %.2f",
                         dv.first!, pct(0.25), pct(0.5), pct(0.75), dv.last!))
            print(String(format: "cell ceiling (2d) mm: min %.2f  p50 %.2f  max %.2f",
                         2 * dv.first!, 2 * pct(0.5), 2 * dv.last!))
        }

        // The region cell the stepped path would use, and what the grading can do with it.
        for regionCell in [4.33, 6.0, 12.0] {
            for floorMM in [voxelMM, 1.0] {
                var hist: [Int: Int] = [:]
                for i in 0..<d.count where cand[i] {
                    var s = regionCell
                    let ceiling = LatticeBoundaryDistance.cellCeilingMM(distanceMM: d[i])
                    if ceiling > 0, s > ceiling {
                        let wanted = Int((s / ceiling).rounded(.up))
                        let allowed = Int((s / floorMM).rounded(.down))
                        let n = Swift.max(1, Swift.min(wanted, allowed))
                        s /= Double(n)
                    }
                    hist[Int((regionCell / s).rounded()), default: 0] += 1
                }
                let parts = hist.keys.sorted().map {
                    "S/\($0)=\(hist[$0]!)"
                }.joined(separator: "  ")
                print(String(format: "regionCell %.2f  floor %.2f  ->  %@",
                             regionCell, floorMM, parts))
            }
        }

        // ★★★ AND NOW THROUGH THE REAL BAKE. The block above is my own arithmetic and
        // proves nothing about what ships; this calls `steppedCellField` itself and reads
        // the field it wrote. It is the check that would have caught the index-space bug
        // (the ceiling was sampled with the CELL grid's index against the OCCUPANCY
        // grid's array, so the grading was noise and the wall came out uniform).
        let regionCell = 6.0
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: regions,
            cellMM: [regionCell], baseCellMM: regionCell,
            boundaryDistancePerRegion: perRegion, finestCellMM: 1.5,
            shapeFitBandMM: 12) else {
            return XCTFail("stepped bake produced nothing")
        }
        var sizes: [Float: Int] = [:]
        for v in baked.steppedCellMM where v > 0 { sizes[v, default: 0] += 1 }
        print("BAKED stepped cell sizes: "
              + sizes.keys.sorted().map { String(format: "%.2f=%d", $0, sizes[$0]!) }
                    .joined(separator: "  "))

        XCTAssertGreaterThan(sizes.count, 1,
                             "★ the baked field has ONE cell size — grade-to-fit-shape "
                             + "is not reaching the wall, which is exactly what he sees")
        XCTAssertLessThan(sizes.keys.min()!, Float(regionCell),
                          "nothing was graded finer than the region's own cell")
        // ★ THE INTERIOR KEEPS THE BIGGEST CELL — "the main cells should be as large as
        // possible". A grade that takes the whole face is the ramp defect, not a grade.
        //
        // ★ RE-PINNED 2026-09-12: this used to demand the region's own cell be the MOST
        // COMMON size. It was, only because the stepped style silently dropped the outer
        // part of the band (a ramp of 2 was "a rung the ladder cannot express" and became
        // no step at all), so a 12 mm dial graded ~5 mm. Now the band does what it says
        // — every row within the dialled reach steps, the row against the ring finest —
        // and 12 mm from each edge of a wall ~38 mm across is most of the wall; the base
        // cell cannot be the most common at THAT dial. The defect this guards against is
        // the band SPILLING past what he dialled, so that is what is pinned: no cell
        // finer than the region's own sits beyond the band, and the base cell is what
        // fills everything beyond it.
        let bandMM = 12.0
        let outlineMM = baked.level
        var finerBeyond = 0, baseBeyond = 0, baseTotal = 0
        for n in 0..<baked.steppedCellMM.count where baked.steppedCellMM[n] > 0 {
            let sMM = Double(baked.steppedCellMM[n])
            if abs(sMM - regionCell) < 1e-3 { baseTotal += 1 }
            let d = Double(outlineMM[n])
            guard d > 0, d < 1e3, d > bandMM + 0.5 * regionCell else { continue }
            if sMM < regionCell - 1e-3 { finerBeyond += 1 } else { baseBeyond += 1 }
        }
        XCTAssertEqual(finerBeyond, 0,
                       "\(finerBeyond) cells finer than the region's own sit beyond the "
                       + "\(bandMM) mm band — the band is spilling past what he dialled")
        XCTAssertGreaterThan(baseBeyond, 0, "nothing beyond the band — vacuous")
        XCTAssertGreaterThan(baseTotal, 0, "the region's own cell must still be drawn")
        // ★ AND THE SOLID OUTLINE EXISTS — as a BAKED DISTANCE, which is the only
        // mechanism that can work. Deactivating a cell cannot: `anyActive` in the march
        // is a NEIGHBOURHOOD property, so a one-cell-wide inactive ring is surrounded by
        // active cells and still draws their struts.
        //
        // ★ AND THIS ASSERTION USED TO COUNT `field.values < 0`, which the MEMBER FLOOR
        // also produces — so it passed for reasons that had nothing to do with the
        // outline. It reads the `g` channel the shader actually consumes.
        let outline = baked.level
        XCTAssertEqual(outline.count, baked.field.values.count)
        let measured = outline.filter { $0 > 0 && $0 < 1e3 }
        XCTAssertFalse(measured.isEmpty,
                       "no cell carries an outline distance — the solid outline has "
                       + "nothing to key on")
        // Some painted cell must be close enough to the outline to go solid at the band
        // the renderer will use (finest cell, floored at one voxel).
        let band = Swift.max(1.5, Double(occ.spacing.x))
        // ★★★ THE RING IS EITHER A SMALL DISTANCE **OR** THE SOLID MARKER (2026-08-27).
        //
        // This used to ask only for a small POSITIVE outline distance, and that
        // predicate went blind the moment the grade started terminating in solid: a
        // cell that close to the outline now writes 0, the solid marker, which
        // `measured` filters out with `$0 > 0`. The test then reported "the ring is
        // empty" for a bake whose ring is the most solid it has ever been — a false
        // alarm that would have been silenced by loosening the bound, and the loosened
        // version would no longer catch a genuinely empty ring.
        //
        // Asking for either marker is strictly STRONGER: it fails if the outline band
        // carries neither a fine graded cell nor solid, which is the actual defect.
        let solidRing = zip(baked.steppedCellMM, outline)
            .filter { $0.0 > 0 && $0.1 == 0 }.count
        let gradedRing = measured.filter { Double($0) <= band }.count
        XCTAssertTrue(solidRing + gradedRing > 0,
                      "no painted cell within \(band) mm of the outline and none marked "
                      + "solid — the ring is empty. graded=\(gradedRing) solid=\(solidRing)")
        // ★ AND AN UNPAINTED CELL MUST STAY 0. `g` is the DYADIC LEVEL everywhere else;
        // a sentinel left in an unpainted cell makes the tap readout report
        // `baseCell * 2^1000`.
        for i in 0..<outline.count where baked.steppedCellMM[i] <= 0 {
            XCTAssertEqual(outline[i], 0,
                           "an unpainted cell carries an outline distance in the level "
                           + "channel — the dyadic reader will take it as a level")
        }
    }
}
