// FlexibleFacePieces — a part triangle cut along the planes of a split face, so every piece
// lies on ONE side of every cut (task 2026-09-29-flexible-screens, round 3, item 2: "the
// hole in the model").
//
// ★ WHY. A split sector is a half-space of its face (FaceRegion.cuts). Asking "is this
// TRIANGLE in the sector?" by its centroid is wrong for any triangle the cut crosses: on
// his pad the top triangle (0,0)-(100,0)-(100,100) has its centroid in 'top A', so the
// overlay dropped all of it, including the x < 50 half no quad replaces — a 1250 mm² hole.
// Cutting first makes membership exact: a piece is wholly inside or wholly outside.
//
// ★ THE CUT IS THE SURFACE STAGE'S OWN (SurfacePatternAxis.clipPolygon, Sutherland–Hodgman,
// same module, not edited). Each piece keeps its source triangle and the barycentric
// weights of its corners in it, so anything interpolated over the part's own vertices —
// the dent's to_uv + t, which is affine — stays exact on a piece.

import Foundation
import simd

enum FlexibleFacePieces {

    /// One convex piece of a triangle: its corners and their barycentric weights in the
    /// source triangle (a, b, c).
    struct Piece {
        var points: [SIMD3<Double>]
        var weights: [SIMD3<Double>]
        /// The piece IS the whole source triangle (no plane crossed it).
        var whole: Bool
        var centroid: SIMD3<Double> { points.reduce(.zero, +) / Double(max(1, points.count)) }
    }

    /// Pieces smaller than this (mm²) are dropped: a vertex lying on a cut makes an empty
    /// piece on its far side.
    static let slivermm2 = 1e-7

    /// Cut triangle (a, b, c) along every plane. The pieces tile the triangle, each on one
    /// side of every plane; winding is kept.
    static func pieces(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                       planes: [RegionCut]) -> [Piece] {
        var polys: [[SIMD3<Double>]] = [[a, b, c]]
        var crossed = false
        for p in planes where simd_length(p.normal) > 1e-12 {
            var next: [[SIMD3<Double>]] = []
            let flipped = RegionCut(point: p.point, normal: -p.normal, strict: !p.strict)
            for poly in polys {
                let inside = SurfacePatternAxis.clipPolygon(poly, to: [p])
                let outside = SurfacePatternAxis.clipPolygon(poly, to: [flipped])
                let ai = SurfacePatternAxis.polygonArea(inside), ao = SurfacePatternAxis.polygonArea(outside)
                if ai > slivermm2, ao > slivermm2 { crossed = true }
                if ai > slivermm2 { next.append(ai > slivermm2 && ao <= slivermm2 ? poly : inside) }
                if ao > slivermm2 { next.append(ao > slivermm2 && ai <= slivermm2 ? poly : outside) }
            }
            polys = next
        }
        return polys.map { poly in
            Piece(points: poly, weights: poly.map { barycentric($0, a, b, c) }, whole: !crossed)
        }
    }

    /// Barycentric weights of `p` in triangle (a, b, c) — (1, 0, 0) at a.
    static func barycentric(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>,
                            _ c: SIMD3<Double>) -> SIMD3<Double> {
        let v0 = b - a, v1 = c - a, v2 = p - a
        let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1)
        let d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
        let den = d00 * d11 - d01 * d01
        guard abs(den) > 1e-18 else { return SIMD3(1, 0, 0) }
        let v = (d11 * d20 - d01 * d21) / den, w = (d00 * d21 - d01 * d20) / den
        return SIMD3(1 - v - w, v, w)
    }

    /// The fan triangulation of a convex piece, as corner indices into its points.
    static func fan(_ n: Int) -> [(Int, Int, Int)] {
        n < 3 ? [] : (1..<(n - 1)).map { (0, $0, $0 + 1) }
    }

    /// Every sector cut plane per face (FlexibleRegions' sectors) — what a face must be cut
    /// along so each piece belongs to exactly one sector. Duplicate planes (a sector and its
    /// sibling share one cut, flipped) are kept once.
    static func planes(of regions: FlexibleRegions, mesh: ViewerMesh?) -> [Int: [RegionCut]] {
        var out: [Int: [RegionCut]] = [:]
        for s in regions.sectors {
            for f in regions.faces(of: FlexibleRegions.wireID(s), mesh: mesh) {
                for c in s.cuts { add(c, to: &out[f, default: []]) }
            }
        }
        return out
    }

    static func add(_ c: RegionCut, to list: inout [RegionCut]) {
        let n = simd_normalize(c.normal)
        let dup = list.contains { e in
            let m = simd_normalize(e.normal)
            return abs(abs(simd_dot(m, n)) - 1) < 1e-9 && abs(simd_dot(c.point - e.point, m)) < 1e-6
        }
        if !dup { list.append(c) }
    }
}
