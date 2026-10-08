import XCTest
import simd
@testable import TopOptFlows

/// ★★★ THE SOLID RIM ONLY WHERE THE WALL IS ATTACHED — his rule (2026-08-24): solid
/// at chamfers and wall-to-floor junctions, "never on faces open to the world —
/// those are the finish's job."
///
/// The rim keys on a distance field seeded ONLY by the part's material outside the
/// latticed set. ★ THE SEED READS `memberThicknessMM`, NOT `partSDF`: that SDF's
/// sign comes from the REGION-CLIPPED occupancy, so nothing outside the regions is
/// ever negative — a seed read off it was empty (0 of 416,490 empty voxels) and the
/// first version of this test crashed the suite on the empty field it produced. The
/// thickness field is computed over the WHOLE-PART solid on the same grid.
final class LatticeAttachedRimTests: XCTestCase {

    func testTheRimFieldExistsOnlyAlongAttachedEdges() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (face, depth) in [(FaceID(15), 12.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: face, in: mesh),
                  let spec = LatticeRegionEmission.spec(for: r, role: .include,
                                                        depthMM: depth, faceID: Int(face))
            else { throw XCTSkip("face \(face) has no planar geometry") }
            specs.append(spec)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: specs, whenEmpty: .latticeNothing)
        let occ = scene.occupancy
        let cand = occ.values.map { $0 > 0.5 }

        guard let seed = LatticeSDFRenderer.attachedSeed(scene: scene) else {
            return XCTFail("the scene carries a thickness field — the seed must exist")
        }
        let seedCount = seed.filter { $0 }.count
        let emptyCount = cand.filter { !$0 }.count
        XCTAssertGreaterThan(seedCount, 0,
                             "his walls meet the base — attached material must exist")
        XCTAssertLessThan(seedCount, emptyCount,
                          "air must NOT seed the rim — only material does")

        let fit = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing)
        let rim = LatticeBoundaryDistance.inPlanePerRegion(
            regions: specs, candidate: cand,
            nx: occ.nx, ny: occ.ny, nz: occ.nz, spacing: occ.spacing, seed: seed)

        let voxel = Double(max(occ.spacing.x, max(occ.spacing.y, occ.spacing.z)))
        for r in 0..<specs.count {
            guard let f = fit[r], !f.isEmpty, let a = rim[r], !a.isEmpty else {
                return XCTFail("region \(r) lost its field (fit \(fit[r]?.count ?? -1), "
                               + "rim \(rim[r]?.count ?? -1))")
            }
            var nearFit = 0, nearRim = 0, finiteRim = 0
            for i in 0..<f.count where cand[i] {
                // Removing seeds can only push the boundary AWAY.
                XCTAssertGreaterThanOrEqual(a[i], f[i] - 1e-9)
                if f[i] <= 2 * voxel { nearFit += 1 }
                if a[i] <= 2 * voxel { nearRim += 1 }
                if a[i] < 500 { finiteRim += 1 }
            }
            XCTAssertGreaterThan(nearRim, 0,
                                 "region \(r): the attached junction must still rim")
            XCTAssertLessThan(nearRim, nearFit,
                              "region \(r): open edges must have dropped out of the rim")
            XCTAssertGreaterThan(finiteRim, 0)
        }
    }
}
