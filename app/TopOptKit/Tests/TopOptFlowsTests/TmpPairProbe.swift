import XCTest
import simd
@testable import TopOptFlows

final class TmpPairProbe: XCTestCase {
    func testPairHistogram() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let s = LatticeRegionEmission.spec(for: r, role: .include,
                                                    depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("no plane") }
            specs.append(s)
        }
        print("PAIR n0=\(specs[0].normal) n1=\(specs[1].normal) o0=\(specs[0].origin) o1=\(specs[1].origin)")
        let n0 = simd_normalize(specs[0].normal)
        let sOnQ = simd_dot(specs[1].origin - specs[0].origin, n0)
        print("PAIR dot=\(simd_dot(simd_normalize(specs[1].normal), n0)) sOnQ=\(sOnQ) d0=\(specs[0].depthMM) d1=\(specs[1].depthMM)")
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: specs, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }
        let boundary = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let widths = specs.map { r in
            Optional(LatticeMeasuredRegionWidth.wallWidthFieldAlongNormalMM(
                region: r, occupancy: occ, partSDF: scene.partSDF))
        }
        let phase = LatticeSDFRenderer.faceTilingPhase(
            regions: specs, cellMM: [10.31, 12.03], fallbackCellMM: 10.31,
            origin: occ.origin)
        guard let baked = LatticePreviewOccupancy.steppedCellField(
            occupancy: occ, demand: nil, regions: specs,
            cellMM: [10.31, 12.03], baseCellMM: 10.31, regionPhase: phase,
            memberThickness: scene.memberThicknessMM,
            boundaryDistancePerRegion: boundary,
            widthPerRegion: widths,
            finestCellMM: 1.29, shapeFitBandMM: 10) else { return XCTFail("no bake") }
        var hist: [Float: Int] = [:]
        for v in baked.steppedCellMM where v > 0 { hist[v, default: 0] += 1 }
        print("PAIR sizes=" + hist.keys.sorted().map {
            String(format: "%.2f=%d", $0, hist[$0]!) }.joined(separator: " "))
    }
}
