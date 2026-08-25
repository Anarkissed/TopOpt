import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ MEASUREMENT, NOT CLAIM — three of his standing reports, measured on his own part
/// through the SHIPPING stepped bake (`steppedCellField` with every production input,
/// replicated from `rebakeCellField`):
///
///   1. THE QUILT'S FOURTH MECHANISM (§4A.4 of the 2026-08-25 handoff): a cell the
///      per-voxel width divisor (or the shape-fit grade) shrinks tiles at S/n, but the
///      shader shifts its tiling by `pfrac × LOCAL cell` (UnifiedShading ~322) while
///      `pfrac` was measured in units of the REGION cell (`faceTilingPhase`). Flushness
///      at S/n needs `(n·frac mod 1) × S/n`; the shader applies `frac × S/n`. So every
///      shrunk cell's caps slice mid-cell whenever frac ≠ 0. This probe prints, per
///      painted cell size, HOW FAR the region's two cap planes sit from the nearest
///      local cell boundary — 0 everywhere means no mechanism; a spread means the quilt
///      re-created exactly in the shrunk bands.
///
///   2. THE UNFILLED PRISM DEPTH (§4C.2): the carve takes the DECLARED depth; does the
///      candidate set reach it? Prints the occupancy's extent along each region's own
///      normal against [0, declared].
///
///   3. THE RIM'S SEEDS (§4B.1): does `attachedSeed` find any attached outline on his
///      real geometry, and how many painted cells carry a rim distance inside the band?
///
/// Stated cells are the ones the never-overshoot fit produced on his two walls,
/// verified in-sim 2026-08-24 (10.31 / 12.03 mm) — fixture facts, not derivation.
final class LatticeSteppedCapPhaseAndDepthProbe: XCTestCase {

    private struct FaceCase {
        let face: Int
        let declaredMM: Double   // his project.json depth (face 15 → 12, face 2 → 13)
        let statedCellMM: Double // the fit's stated cell, seen in the sim 2026-08-24
    }
    private let cases = [FaceCase(face: 15, declaredMM: 12.0, statedCellMM: 10.31),
                         FaceCase(face: 2, declaredMM: 13.0, statedCellMM: 12.03)]
    private let lineWidthMM = 0.45
    private let shapeFitBandMM = 10.0   // his project.json stores 10

    func testCapPhaseDepthAndRimOnHisPart() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        for fc in cases { try measure(mesh: mesh, fc: fc) }
    }

    /// The renderer's own halving rule (`steppedFinestPrintableCellMM`), replicated:
    /// halve while the band's CEILING can still print a bead-wide strut at the half.
    private func finestPrintable(_ finest: Double, lat: LatticeType,
                                 densityHi: Double) -> Double {
        var s = finest
        while s > 0 {
            let half = s / 2
            let rhoStar = lat.printabilityDensityFloor(lineWidthMM: lineWidthMM,
                                                       cellMM: half)
            if rhoStar > densityHi + 1e-9 { break }
            s = half
        }
        return s
    }

    /// Distance from a cap-plane coordinate (grid-axis mm from the occupancy origin)
    /// to the nearest tiling boundary of a cell of size `sLocal` shifted by `pfrac`
    /// cells — the shader's own rule: boundaries at origin + (k + pfrac) · sLocal.
    private func capOffset(cap: Double, sLocal: Double, pfrac: Double) -> Double {
        var r = (cap - pfrac * sLocal).truncatingRemainder(dividingBy: sLocal)
        if r < 0 { r += sLocal }
        return Swift.min(r, sLocal - r)
    }

    private func measure(mesh: ViewerMesh, fc: FaceCase) throws {
        guard let plane = LatticeRegionEmission.planeFor(face: FaceID(fc.face), in: mesh),
              let spec = LatticeRegionEmission.spec(for: plane, role: .include,
                                                   depthMM: fc.declaredMM,
                                                   faceID: fc.face)
        else { throw XCTSkip("face \(fc.face) has no planar geometry") }
        let regions = [spec]
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: regions, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let n = simd_normalize(spec.normal)
        let a = abs(n)
        let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)

        print("=== CAP/DEPTH/RIM PROBE face \(fc.face) ===")
        print(String(format: "declared %.2f mm  stated cell %.2f mm  normal (%.2f,%.2f,%.2f) axis %d",
                     fc.declaredMM, fc.statedCellMM, n.x, n.y, n.z, axis))
        print(String(format: "grid %dx%dx%d  voxel %.3f mm",
                     occ.nx, occ.ny, occ.nz, Double(occ.spacing[axis])))

        // ── 2. DEPTH: the candidate set along the region's own normal ────────────
        // Occupancy is region-clipped, so in this single-region scene every candidate
        // voxel belongs to this slab. s = depth INTO the wall from the face plane.
        var sMin = Double.infinity
        var sMax = -Double.infinity
        var count = 0
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let idx = (k * occ.ny + j) * occ.nx + i
                    guard occ.values[idx] > 0.5 else { continue }
                    let wx = Double(occ.origin.x) + Double(i) * Double(occ.spacing.x)
                    let wy = Double(occ.origin.y) + Double(j) * Double(occ.spacing.y)
                    let wz = Double(occ.origin.z) + Double(k) * Double(occ.spacing.z)
                    let s = (wx - spec.origin.x) * n.x + (wy - spec.origin.y) * n.y
                          + (wz - spec.origin.z) * n.z
                    if s < sMin { sMin = s }
                    if s > sMax { sMax = s }
                    count += 1
                }
            }
        }
        print(String(format: "occupancy: %d voxels  depth span [%.2f, %.2f] of [0, %.2f]"
                     + "  (voxel-centre sampling; ±half voxel at each end)",
                     count, sMin, sMax, fc.declaredMM))
        XCTAssertGreaterThan(count, 0, "face \(fc.face): the region clipped away everything")

        // ── the bake, with every production input ────────────────────────────────
        // The band the way `proxyParams` builds it: the stored range (his project
        // stores 0…1) clamped through `LatticeBounds.compute` into core's certifiable
        // band, floored at the printability floor. NOT the aesthetic display band.
        let lat = LatticeType.named("octet")
        var settings = LatticeSettings()
        settings.topologyID = "octet"
        settings.cellMM = fc.statedCellMM
        settings.minRelativeDensity = 0
        settings.maxRelativeDensity = 1
        let bounds = LatticeBounds.compute(settings: settings,
                                           limits: TopOptKit.latticeLimits(topology: "octet"),
                                           lineWidthMM: lineWidthMM)
        let densityLo = bounds.densityLo
        let densityHi = bounds.densityHi
        let finest = finestPrintable(fc.statedCellMM, lat: lat, densityHi: densityHi)
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: regions, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let seed = LatticeSDFRenderer.attachedSeed(scene: scene)
        let seedCount = seed?.filter { $0 }.count ?? -1
        let rim = LatticeBoundaryDistance.inPlanePerRegion(
            regions: regions, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing, seed: seed)
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: regions, cellMM: [fc.statedCellMM],
            fallbackCellMM: fc.statedCellMM, origin: occ.origin)
        print(String(format: "band [%.4f, %.4f]  finest printable %.3f mm  "
                     + "attached seeds %d  regionPhase %.4f",
                     densityLo, densityHi, finest, seedCount, phase.first ?? -1))

        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: regions,
            cellMM: [fc.statedCellMM], baseCellMM: fc.statedCellMM,
            regionPhase: phase,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: 0, cellsPerMemberFloor: [],
            boundaryDistancePerRegion: boundary,
            widthPerRegion: [LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: spec, occupancy: occ, partSDF: scene.partSDF)],
            rimDistancePerRegion: rim,
            finestCellMM: finest, shapeFitBandMM: shapeFitBandMM,
            lineWidthMM: lineWidthMM, densityLo: densityLo, densityHi: densityHi,
            densityGamma: 1, latticeID: "octet") else {
            return XCTFail("face \(fc.face): stepped bake produced nothing")
        }

        // ── 1. CAP FLUSHNESS per painted cell size ───────────────────────────────
        // The shader tiles this cell's struts at boundaries
        //     world[axis] = occ.origin[axis] + (k + pfrac) * s_local
        // (lsdf_cell_frame_at: phase[axis] = pfrac * m, blk = floor((cb - phase)/m)).
        // A cap plane is flush iff its coordinate lands on one of those boundaries.
        let capNear: Double = spec.origin[axis] - Double(occ.origin[axis])
        let capFar: Double = capNear + fc.declaredMM * n[axis]
        var sizeCount: [Float: Int] = [:]
        var sizePhase: [Float: Float] = [:]
        for idx in 0..<baked.steppedCellMM.count {
            let s = baked.steppedCellMM[idx]
            guard s > 0 else { continue }
            sizeCount[s, default: 0] += 1
            sizePhase[s] = baked.steppedPhase[idx]
        }
        for key in sizeCount.keys.sorted() {
            let sLocal = Double(key)
            let packed = Double(sizePhase[key] ?? 0)
            let paxis = Int(packed + 1e-4)
            let pfrac = packed - Double(paxis)
            let nearOff = paxis == axis
                ? capOffset(cap: capNear, sLocal: sLocal, pfrac: pfrac)
                : capOffset(cap: capNear, sLocal: sLocal, pfrac: 0)
            let farOff = paxis == axis
                ? capOffset(cap: capFar, sLocal: sLocal, pfrac: pfrac)
                : capOffset(cap: capFar, sLocal: sLocal, pfrac: 0)
            let ratio = fc.statedCellMM / sLocal
            print(String(format: "cell %.3f mm (S/%.2f)  cells %d  phaseFrac %.4f  "
                         + "capNear off %.3f mm  capFar off %.3f mm",
                         sLocal, ratio, sizeCount[key]!, pfrac, nearOff, farOff))
        }

        // ── 3. RIM: what the attached-only distance gave the painted cells ───────
        var measuredCount = 0
        var measuredMin = Double.infinity
        var inBand = 0
        let voxel = Double(Swift.max(occ.spacing.x, Swift.max(occ.spacing.y, occ.spacing.z)))
        let band = Swift.max(finest, voxel)
        for idx in 0..<baked.level.count {
            guard baked.steppedCellMM[idx] > 0 else { continue }
            let v = Double(baked.level[idx])
            guard v > 0, v < 1e3 else { continue }
            measuredCount += 1
            if v < measuredMin { measuredMin = v }
            if v <= band { inBand += 1 }
        }
        print(String(format: "rim: %d painted cells carry a distance (min %.2f)  band %.2f mm  in-band %d",
                     measuredCount, measuredCount > 0 ? measuredMin : -1, band, inBand))
    }
}
