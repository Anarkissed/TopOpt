import XCTest
import simd
@testable import TopOptFlows

/// ★ HIS REPORT (2026-08-24 evening): a tapped 2.00 mm cell at 5% shows an 0.18 mm
/// strut — under half the bead. The printability lift exists to forbid exactly that
/// (raise the cell's demand until the strut clears one bead, or coarsen). This probe
/// bakes his exact scene and reads the ACTIVATION the shader is handed, per cell
/// size — so "the lift didn't run" and "the lift ran but the readout ignores it"
/// stop being the same symptom.
final class LatticeLiftProbe: XCTestCase {

    func testWhatDensityTheBakeActuallyWrote() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane") }
            specs.append(spec)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: specs, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = specs.map {
            Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: $0, occupancy: occ, partSDF: scene.partSDF))
        }
        // His screen: single-cell ON -> [12.0, 13.0]; band 5%..90%; bead 0.45.
        let lo = 0.05, hi = 0.90, gamma = 1.0, bead = 0.45
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: scene.demand, regions: specs,
            cellMM: [12.0, 13.0], baseCellMM: 12.0,
            minCellsPerMember: 1,
            boundaryDistancePerRegion: boundary,
            widthPerRegion: widths,
            finestCellMM: 1.5,
            shapeFitBandMM: 10.0,
            lineWidthMM: bead,
            densityLo: lo, densityHi: hi, densityGamma: gamma,
            latticeID: "octet") else {
            return XCTFail("bake produced nothing")
        }
        let lat = LatticeType.named("octet")
        // Per cell size: activation -> the rho the SHADER computes -> the strut mm.
        var bySize: [Float: [Double]] = [:]
        for i in 0..<baked.steppedCellMM.count where baked.steppedCellMM[i] > 0 {
            let act = Double(baked.field.values[i])
            guard act >= 0 else { continue }   // inactive = solid, no strut
            let rho = lo + (hi - lo) * pow(Swift.min(Swift.max(act, 0), 1), gamma)
            bySize[baked.steppedCellMM[i], default: []].append(rho)
        }
        print("=== LIFT PROBE (bead \(bead)) ===")
        var unprintable = 0
        for (size, rhos) in bySize.sorted(by: { $0.key < $1.key }) {
            let s = rhos.sorted()
            let minR = s.first!, medR = s[s.count / 2]
            let strutMin = 2 * lat.strutRadiusMM(relativeDensity: minR,
                                                 cellMM: Double(size))
            let rhoStar = lat.printabilityDensityFloor(lineWidthMM: bead,
                                                       cellMM: Double(size))
            // ★ THE TEST IS THE STRUT, NOT THE RHO. The lift stores its demand as a
            // Float, so the reconstructed rho sits a few 1e-8 under rho* — a strut
            // 0.4499999 mm wide, which no printer can distinguish from a bead. A
            // millimetre tolerance of one micron separates a real failure (his
            // 0.18 mm reading would miss by 270 microns) from float rounding.
            if strutMin < bead - 1e-3 { unprintable += s.count }
            print(String(format:
                "cell %5.2f  n=%3d  rho[min %.3f med %.3f]  strut@min %.2f mm  "
                + "rho* %.3f",
                size, s.count, minR, medR, strutMin, rhoStar))
        }
        XCTAssertEqual(unprintable, 0,
            "every graded cell's activation must draw a strut of at least one "
            + "bead — the printability lift's whole contract")
    }
}
