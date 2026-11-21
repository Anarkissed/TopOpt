// LatticeSignedDistanceTests — ★ THE PARALLEL SCATTER MUST GIVE THE SERIAL ANSWER
// (maintainer, 2026-08-20: "I'm counting about 10 seconds for the lattice to turn on.
// Is there any way to shorten that time?").
//
// ★★ WHAT CHANGED AND WHY IT IS SAFE. `signedDistance` min-combines each triangle's
// exact point-to-triangle distance into every voxel of its padded AABB. Splitting
// that by TRIANGLE would race on the shared voxel; splitting by Z-SLAB gives each
// worker a disjoint write range, so the arithmetic is untouched and only the order of
// the min-combines changes — and min is associative and commutative.
//
// Measured on his own part (128x31x117 occupancy):
//
//     base scene bake ....  2.74s -> 1.34s
//     with a region ......  3.38s -> 1.78s
//
// ★ THIS TEST IS THE PRICE OF THAT. A speed-up that quietly changes the field would
// move every strut radius in the preview, so the result is checked against a
// brute-force reference rather than against "it still looks right".

import XCTest
import simd
@testable import TopOptFlows

final class LatticeSignedDistanceTests: XCTestCase {

    /// A cube, built exactly as `LatticeSDFAlignmentTests` builds one — indices are
    /// `Int32` here, which is what `ViewerMesh` takes.
    private func cubeMesh(side s: Float) -> (mesh: ViewerMesh, pos: [Float], idx: [UInt32]) {
        let c: [SIMD3<Float>] = [
            [0, 0, 0], [s, 0, 0], [s, s, 0], [0, s, 0],
            [0, 0, s], [s, 0, s], [s, s, s], [0, s, s]]
        let faces = [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
                     [1, 5, 6, 2], [4, 5, 1, 0], [3, 2, 6, 7]]
        var verts: [Float] = []; var idx: [Int32] = []; var ids: [Int32] = []
        for (f, quad) in faces.enumerated() {
            let base = Int32(verts.count / 3)
            for vi in quad { verts += [c[vi].x, c[vi].y, c[vi].z] }
            idx += [base, base + 1, base + 2, base, base + 2, base + 3]
            ids += [Int32(f), Int32(f)]
        }
        return (ViewerMesh(vertices: verts, indices: idx, faceIDs: ids),
                verts, idx.map(UInt32.init))
    }

    /// ★ THE REFERENCE: every voxel against every triangle, no partitioning at all.
    private func brute(_ pos: [Float], _ idx: [UInt32],
                       like occ: LatticeVoxelGrid, band: Int) -> [Float] {
        func p(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(pos[b], pos[b + 1], pos[b + 2])
        }
        let minSp = Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z))
        let far = Float(band) * minSp
        var out = [Float](repeating: 0, count: occ.count)
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let q = occ.origin + SIMD3<Float>(Float(i) * occ.spacing.x,
                                                      Float(j) * occ.spacing.y,
                                                      Float(k) * occ.spacing.z)
                    var best = Float.greatestFiniteMagnitude
                    for t in 0..<(idx.count / 3) {
                        let d2 = LatticePreviewOccupancy.pointTriangleDistSq(
                            q, p(idx[t * 3]), p(idx[t * 3 + 1]), p(idx[t * 3 + 2]))
                        best = Swift.min(best, d2)
                    }
                    let n = (k * occ.ny + j) * occ.nx + i
                    let d = Swift.min(best.squareRoot(), far)
                    out[n] = occ.values[n] > 0.5 ? -d : d
                }
            }
        }
        return out
    }

    func testTheParallelScatterMatchesABruteForceReference() throws {
        let (mesh, pos, idx) = cubeMesh(side: 20)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet", maxDim: 24)
        let occ = scene.occupancy

        let got = LatticePreviewOccupancy.signedDistance(positions: pos, indices: idx,
                                                          like: occ, bandVoxels: 3)
        let want = brute(pos, idx, like: occ, band: 3)
        XCTAssertEqual(got.values.count, want.count)

        var worst: Float = 0
        for i in 0..<want.count { worst = Swift.max(worst, abs(got.values[i] - want[i])) }
        XCTAssertLessThan(worst, 1e-4,
                          "★ the slab-parallel scatter must equal the brute-force field "
                          + "everywhere — worst disagreement \\(worst). A speed-up that "
                          + "moves this field moves every strut radius in the preview.")
    }
}
