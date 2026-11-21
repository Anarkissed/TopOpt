// TinyCutPiece.swift — ★ his 11-16 (Install 3, his words: "Yes, please add to the install 3 list. Start right away but
// don't install until the rest is ready"): a cut piece a run USES that is too small for core, caught before the job is sent.
//
// Core builds every region a job declares and refuses the whole job when a CUT piece holds fewer than
// `kRegionSliverFloorVoxels` voxels at the job's resolution (core/src/cli/loadcase.cpp, the sliver guard): "region 101 "Face 25
// A" holds 3 voxels at resolution 96 — under the floor of 16". The app sends only the pieces a run uses and their ancestors
// (`FaceRegionSend.onWire`), so a leftover piece no longer stops a run; a piece an anchor, a load, a protection or a keep-clear
// USES still would. This counts each such piece the way core does and, when one is under the floor, the press stops with one
// line and one tap that undoes its cuts (`ProjectModel.surfaceMakeWhole`).
//
// ★ CORE'S COUNT, NOT AN AREA ESTIMATE. The pattern tool prices a split by area / voxel² (`FaceRegionGeometry.cellAreas`), which
// is fine for steering a slider but undercounts a tilted face (its staircase crosses more voxels), and this check REFUSES a run:
// an undercount would stop a run core accepts. So this is core's own rule, on the app's mesh:
//   * the grid: cubic voxels of the longest extent / resolution, from the mesh's lowest corner (voxelize.cpp `voxelize`);
//   * a voxel is the part's when the winding of the triangles above its centre, along +Z, is not zero (voxelize.cpp's fill);
//   * a piece holds the part's voxels whose centre lies within half a voxel of one of its faces' triangles
//     (face_region.cpp `region_member_voxels`, depth 1) and inside every cut (`cut_voxels`).

import Foundation
import simd
import TopOptKit

public enum TinyCutPiece {

    /// One used cut piece under core's floor, and the region whose split made it (undoing that split makes the face whole).
    public struct Hit: Equatable, Sendable {
        public let piece: RegionID
        public let voxels: Int
        public let resolution: Int
        /// The nearest region up its line that is not itself a cut and was split: nil when its split is gone (Edit faces'
        /// "Make it whole" card handles that piece).
        public let whole: RegionID?
    }

    /// ≤ 5 words (U6) on the corner's fix line.
    public static let words = "Cut piece too small"
    public static let fix = "Undo its cuts"
    public static let info = "One cut piece is too small for the engine at this Detail. Undo its cuts and the whole face takes its place, in the same group. Undo brings the cuts back."
    /// Where there is no fix line (the lattice page's run): the same, as a toast.
    public static let toast = "A cut piece is too small for the engine \u{00B7} undo its cuts in Edit faces"

    /// RED CONTROL (tests only): no check — the press sends what core will refuse (before his 11-16 ask).
    nonisolated(unsafe) public static var controlNoCheck = false

    /// The first piece `request` sends that is a cut and holds fewer than core's floor at the request's resolution.
    public static func first(in request: RunRequest, regions: FaceRegionModel, mesh: ViewerMesh) -> Hit? {
        guard !controlNoCheck, request.resolution > 0 else { return nil }
        var centresByMembers: [[FaceID]: [SIMD3<Double>]] = [:]
        for r in FaceRegionSend.onWire(request) where r.isCut {
            let members = FaceRegionGeometry.members(of: r, in: mesh)
            let centres = centresByMembers[members] ?? memberCentres(members: Set(members), in: mesh,
                                                                     resolution: request.resolution)
            centresByMembers[members] = centres
            let n = centres.reduce(0) { $0 + (FaceRegionGeometry.inside($1, r.cuts) ? 1 : 0) }
            if n < kRegionSliverFloorVoxels {
                return Hit(piece: r.id, voxels: n, resolution: request.resolution, whole: whole(of: r.id, in: regions))
            }
        }
        return nil
    }

    /// Core's count for one region at `resolution`: its member voxels inside every cut.
    static func count(_ r: FaceRegion, in mesh: ViewerMesh, resolution: Int) -> Int {
        memberCentres(members: Set(FaceRegionGeometry.members(of: r, in: mesh)), in: mesh, resolution: resolution)
            .reduce(0) { $0 + (FaceRegionGeometry.inside($1, r.cuts) ? 1 : 0) }
    }

    /// The region whose split made `piece`: up its line (a union's part goes up to the region it was cut from), the first
    /// region that is not a cut and was split. nil when there is none.
    public static func whole(of piece: RegionID, in regions: FaceRegionModel) -> RegionID? {
        var seen: Set<RegionID> = [piece]
        var cur = piece
        while true {
            let up = regions.origin(of: cur) ?? regions.region(cur).flatMap { $0.parentID >= 0 ? $0.parentID : nil }
            guard let u = up, seen.insert(u).inserted, let r = regions.region(u) else { return nil }
            if !r.isCut && SurfaceRegionTool.canUndoSplit(u, regions: regions) { return u }
            cur = u
        }
    }

    /// The voxel centres core gives a region with these member faces at `resolution`, before its cuts.
    static func memberCentres(members: Set<FaceID>, in mesh: ViewerMesh, resolution: Int) -> [SIMD3<Double>] {
        let tris = triangles(mesh)
        guard let g = Grid(tris, resolution: resolution) else { return [] }
        let h = g.h
        let thr = 0.5 * h
        let thr2 = thr * thr + 1e-9 * h * h
        // the cells whose centre lies within half a voxel of a member triangle
        var near: Set<Int> = []
        for (t, f) in zip(tris, mesh.faceIDs) where members.contains(f) {
            let lo = simd_min(t.a, simd_min(t.b, t.c)) - SIMD3(repeating: thr)
            let hi = simd_max(t.a, simd_max(t.b, t.c)) + SIMD3(repeating: thr)
            let i0 = g.cell(lo, up: true), i1 = g.cell(hi, up: false)
            guard i0.x <= i1.x, i0.y <= i1.y, i0.z <= i1.z else { continue }
            for k in i0.z...i1.z { for j in i0.y...i1.y { for i in i0.x...i1.x {
                let c = g.centre(i, j, k)
                if distance2(c, t) <= thr2 { near.insert(g.index(i, j, k)) }
            } } }
        }
        guard !near.isEmpty else { return [] }
        // core's fill, on the columns those cells stand in: every triangle crossing a column, with its winding
        var columns: [Int: [(z: Double, sign: Int)]] = [:]
        for idx in near { columns[idx % (g.n.x * g.n.y), default: []] = [] }
        for t in tris {
            let a = t.a, b = t.b, c = t.c
            let area2 = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(area2) < 1e-18 { continue }
            let sign = area2 > 0 ? 1 : -1
            var i0 = Int(floor((min(a.x, b.x, c.x) - g.lo.x) / h - 0.5)), i1 = Int(ceil((max(a.x, b.x, c.x) - g.lo.x) / h - 0.5))
            var j0 = Int(floor((min(a.y, b.y, c.y) - g.lo.y) / h - 0.5)), j1 = Int(ceil((max(a.y, b.y, c.y) - g.lo.y) / h - 0.5))
            i0 = max(i0, 0); j0 = max(j0, 0); i1 = min(i1, g.n.x - 1); j1 = min(j1, g.n.y - 1)
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                let py = g.lo.y + (Double(j) + 0.5) * h
                for i in i0...i1 {
                    let col = j * g.n.x + i
                    guard columns[col] != nil else { continue }
                    let px = g.lo.x + (Double(i) + 0.5) * h
                    let e0 = (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)
                    let e1 = (c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x)
                    let e2 = (a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x)
                    guard (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0) else { continue }
                    columns[col]?.append(((e1 * a.z + e2 * b.z + e0 * c.z) / area2, sign))
                }
            }
        }
        var out: [SIMD3<Double>] = []
        for idx in near.sorted() {
            let col = idx % (g.n.x * g.n.y)
            let k = idx / (g.n.x * g.n.y)
            let cz = g.lo.z + (Double(k) + 0.5) * h
            // the winding strictly above the centre (core subtracts the crossings at or below it)
            let above = (columns[col] ?? []).reduce(0) { $0 + ($1.z > cz ? $1.sign : 0) }
            if above != 0 { out.append(g.centre(col % g.n.x, col / g.n.x, k)) }
        }
        return out
    }

    // MARK: - internals

    struct Tri { let a, b, c: SIMD3<Double> }

    static func triangles(_ mesh: ViewerMesh) -> [Tri] {
        let p = mesh.positions, idx = mesh.indices
        func v(_ i: UInt32) -> SIMD3<Double> { let b = Int(i) * 3; return SIMD3(Double(p[b]), Double(p[b + 1]), Double(p[b + 2])) }
        var out: [Tri] = []
        out.reserveCapacity(idx.count / 3)
        var i = 0
        while i + 2 < idx.count { out.append(Tri(a: v(idx[i]), b: v(idx[i + 1]), c: v(idx[i + 2]))); i += 3 }
        return out
    }

    /// Core's grid for the mesh at `resolution` (voxelize.cpp `voxelize`).
    struct Grid {
        let lo: SIMD3<Double>
        let h: Double
        let n: SIMD3<Int>
        init?(_ tris: [Tri], resolution: Int) {
            guard let f = tris.first, resolution > 0 else { return nil }
            var lo = f.a, hi = f.a
            for t in tris { lo = simd_min(lo, simd_min(t.a, simd_min(t.b, t.c))); hi = simd_max(hi, simd_max(t.a, simd_max(t.b, t.c))) }
            let ext = hi - lo
            let m = max(ext.x, ext.y, ext.z)
            guard m > 0 else { return nil }
            let h = m / Double(resolution)
            func count(_ e: Double) -> Int { max(1, Int(ceil(e / h - 1e-9))) }
            self.lo = lo; self.h = h; self.n = SIMD3(count(ext.x), count(ext.y), count(ext.z))
        }
        func centre(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Double> {
            lo + (SIMD3(Double(i), Double(j), Double(k)) + 0.5) * h
        }
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n.y + j) * n.x + i }
        /// The first (up) or last (down) cell whose centre is at or past `p`, clamped to the grid.
        func cell(_ p: SIMD3<Double>, up: Bool) -> SIMD3<Int> {
            let r = (p - lo) / h - 0.5
            let c = up ? SIMD3<Int>(Int(ceil(r.x)), Int(ceil(r.y)), Int(ceil(r.z)))
                       : SIMD3<Int>(Int(floor(r.x)), Int(floor(r.y)), Int(floor(r.z)))
            return c.clamped(lowerBound: .zero, upperBound: n &- 1)
        }
    }

    /// The squared distance from `p` to the triangle (Ericson, Real-Time Collision Detection §5.1.5).
    static func distance2(_ p: SIMD3<Double>, _ t: Tri) -> Double {
        let a = t.a, b = t.b, c = t.c
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(p - a) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(p - b) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 { let v = d1 / (d1 - d3); return simd_length_squared(p - (a + v * ab)) }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(p - c) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 { let w = d2 / (d2 - d6); return simd_length_squared(p - (a + w * ac)) }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(p - (b + w * (c - b)))
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return simd_length_squared(p - (a + ab * v + ac * w))
    }
}
