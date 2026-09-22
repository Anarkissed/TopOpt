import Foundation
import simd

// ★★★ A CURVED FACE AS A FAN OF PLANAR FACETS (his 2026-09-22 01:05: "face 23 does not
// get a lattice generated at all through the wall it has defined … there should be no
// issue at all"). Face 23 is the stand's inner curve: not a plane, so `planeFor` gave
// nothing and the emission counted it as skipped — no region, no lattice, no card. Core's
// face regions are planes; a curved wall is many nearly-planar patches. So the face's
// triangles are grouped by normal within a tolerance, and each group becomes its own
// planar face region — its own tangent plane, centroid and outline — under the same face
// id. The prisms overlap by a sliver at the seams (a union), the lattice fills each, and
// the run gets ordinary face regions.
public enum LatticeFaceFacets {

    /// The facets of `face`, as resolved planar faces; empty when the face has no triangles.
    public static func facets(face: FaceID, in mesh: ViewerMesh,
                              toleranceDeg: Double = 12) -> [LatticeRegionEmission.ResolvedFace] {
        let want = Int32(face)
        var tris: [(index: Int, n: SIMD3<Double>, area: Double, c: SIMD3<Double>)] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == want {
                let p = (0..<3).compactMap { k -> SIMD3<Double>? in
                    let b = Int(mesh.indices[t + k]) * 3
                    guard b + 2 < mesh.positions.count else { return nil }
                    return SIMD3<Double>(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
                }
                if p.count == 3 {
                    let cr = simd_cross(p[1] - p[0], p[2] - p[0])
                    let a = 0.5 * simd_length(cr)
                    if a > 1e-12 { tris.append((tri, cr / (2 * a), a, (p[0] + p[1] + p[2]) / 3)) }
                }
            }
            t += 3
        }
        guard !tris.isEmpty else { return [] }
        // greedy clusters by normal, the largest triangles seeding first
        let cosTol = cos(toleranceDeg * .pi / 180)
        var seeds: [SIMD3<Double>] = []
        var members: [[Int]] = []
        for tr in tris.sorted(by: { $0.area > $1.area }) {
            if let k = seeds.firstIndex(where: { simd_dot($0, tr.n) >= cosTol }) {
                members[k].append(tr.index)
            } else {
                seeds.append(tr.n); members.append([tr.index])
            }
        }
        let byIndex = Dictionary(uniqueKeysWithValues: tris.map { ($0.index, $0) })
        var out: [LatticeRegionEmission.ResolvedFace] = []
        for group in members {
            var nSum = SIMD3<Double>.zero, cSum = SIMD3<Double>.zero, aSum = 0.0
            for i in group { if let tr = byIndex[i] { nSum += tr.n * tr.area; cSum += tr.c * tr.area; aSum += tr.area } }
            guard aSum > 1e-9, simd_length(nSum) > 1e-12 else { continue }
            let normal = simd_normalize(nSum), centre = cSum / aSum
            let set = Set(group)
            let lw = LatticeFaceOutline.loopsWithNeighbours(triangles: { set.contains($0) }, in: mesh, normal: normal, origin: centre)
            guard !lw.isEmpty else { continue }
            // the bounding rectangle in the facet's own plane, as `planeFor` reports it
            var hu = 0.0, hv = 0.0
            for e in lw { for q in e.loop { hu = Swift.max(hu, abs(q.x)); hv = Swift.max(hv, abs(q.y)) } }
            // the edge to the NEXT facet of this same face reads the face itself: a seam
            out.append(.plane(center: centre, normal: normal, halfUMM: hu, halfWMM: hv,
                              outlineLoops: lw.map { $0.loop }, neighbours: lw.map { $0.neighbours }))
        }
        return out
    }
}
