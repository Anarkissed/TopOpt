// LatticePreviewOccupancy.swift — the part-interior MASK the raymarched lattice
// preview is clipped to (handoff 2026-07-29-lattice-preview). The shader tiles the
// infinite lattice field everywhere; this occupancy grid is what makes the preview
// read as "the PART filled with lattice" and not a rectangular block of struts: a
// sphere-trace hit is only accepted where the hit point is inside the part.
//
// WHY A BAKED GRID, NOT A PER-FRAME PASS (bar P2 — PR 241's fix must not be undone):
// the grid is a pure function of the part mesh (occupancy) and the demand field
// (grading), so it is baked ONCE when that data changes — never during orbit. The
// interactive lattice PARAMETERS (cell size, density band, γ) are shader uniforms,
// so they re-shade with no re-bake at all (bar V3). Nothing regenerates geometry
// per frame; there is no geometry.
//
// WHY IT WORKS WITHOUT THE WORKER MESH (bar 4): occupancy comes from the PART mesh
// (always on device — it is what the viewer already draws), and demand from the
// on-device von Mises field. The worker-generated LATTICE mesh is never needed.
//
// Solid voxelisation is the standard column-parity method: cast a +Z ray through
// each (x,y) column, collect triangle crossings, fill the spans between entry/exit
// pairs. Pure Float math, headless-testable (no GPU): the renderer uploads the
// arrays to 3D textures.

import Foundation
import simd

/// A dense scalar field on a regular grid over an axis-aligned box. `values` is
/// row-major with x fastest, then y, then z. Uploaded to a Metal 3D texture.
public struct LatticeVoxelGrid: Equatable, Sendable {
    public let nx: Int, ny: Int, nz: Int
    public let origin: SIMD3<Float>     // world position of voxel (0,0,0) CENTRE
    public let spacing: SIMD3<Float>    // world mm between voxel centres, per axis
    public var values: [Float]          // nx*ny*nz, x fastest

    public init(nx: Int, ny: Int, nz: Int, origin: SIMD3<Float>, spacing: SIMD3<Float>, values: [Float]) {
        self.nx = nx; self.ny = ny; self.nz = nz
        self.origin = origin; self.spacing = spacing; self.values = values
    }

    public var count: Int { nx * ny * nz }
}

public enum LatticePreviewOccupancy {

    /// Choose grid dimensions for a box so the LONGEST axis has `maxDim` voxels and the
    /// others are proportional (min 2), giving near-isotropic voxels.
    public static func dims(for extent: SIMD3<Float>, maxDim: Int) -> (Int, Int, Int) {
        let e = SIMD3<Float>(Swift.max(extent.x, 1e-4), Swift.max(extent.y, 1e-4), Swift.max(extent.z, 1e-4))
        let longest = Swift.max(e.x, Swift.max(e.y, e.z))
        func d(_ v: Float) -> Int { Swift.max(2, Int((Float(maxDim) * v / longest).rounded())) }
        return (d(e.x), d(e.y), d(e.z))
    }

    /// Solid-voxelise a triangle soup into an occupancy grid (1 inside, 0 outside) over
    /// the mesh bounds padded by one voxel. `maxDim` caps the longest axis (default 96 —
    /// a ~2 mm voxel on the maintainer's 207 mm bracket; the bake is a handful of ms and
    /// happens only on a mesh change). Column-parity along +Z.
    public static func occupancy(positions: [Float], indices: [UInt32],
                                 bounds: MeshBounds, maxDim: Int = 96) -> LatticeVoxelGrid {
        let extent = bounds.max - bounds.min
        let (nx, ny, nz) = dims(for: extent, maxDim: maxDim)
        // One-voxel pad so the surface is not clipped by the box edge.
        let sp = SIMD3<Float>(extent.x / Float(nx - 1 == 0 ? 1 : nx - 1),
                              extent.y / Float(ny - 1 == 0 ? 1 : ny - 1),
                              extent.z / Float(nz - 1 == 0 ? 1 : nz - 1))
        let spacing = SIMD3<Float>(Swift.max(sp.x, 1e-4), Swift.max(sp.y, 1e-4), Swift.max(sp.z, 1e-4))
        let origin = bounds.min
        var vals = [Float](repeating: 0, count: nx * ny * nz)

        // Per-column sorted crossing z's (grid-index space along z).
        var crossings = [[Float]](repeating: [], count: nx * ny)

        func pos(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(positions[b], positions[b + 1], positions[b + 2])
        }

        var t = 0
        while t + 2 < indices.count {
            let p0 = pos(indices[t]), p1 = pos(indices[t + 1]), p2 = pos(indices[t + 2]); t += 3
            // Grid-space xy (columns) that the triangle spans.
            let gx = SIMD3<Float>((p0.x - origin.x) / spacing.x, (p1.x - origin.x) / spacing.x, (p2.x - origin.x) / spacing.x)
            let gy = SIMD3<Float>((p0.y - origin.y) / spacing.y, (p1.y - origin.y) / spacing.y, (p2.y - origin.y) / spacing.y)
            let iLo = Swift.max(0, Int(floor(Swift.min(gx.x, Swift.min(gx.y, gx.z)))))
            let iHi = Swift.min(nx - 1, Int(ceil(Swift.max(gx.x, Swift.max(gx.y, gx.z)))))
            let jLo = Swift.max(0, Int(floor(Swift.min(gy.x, Swift.min(gy.y, gy.z)))))
            let jHi = Swift.min(ny - 1, Int(ceil(Swift.max(gy.x, Swift.max(gy.y, gy.z)))))
            guard iLo <= iHi, jLo <= jHi else { continue }
            // Barycentric setup in XY (grid space).
            let ax = gx.x, ay = gy.x, bx = gx.y, by = gy.y, cx = gx.z, cy = gy.z
            let det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            guard abs(det) > 1e-9 else { continue }
            let zg = SIMD3<Float>((p0.z - origin.z) / spacing.z, (p1.z - origin.z) / spacing.z, (p2.z - origin.z) / spacing.z)
            // Sample each column at its grid point nudged by a tiny irrational offset,
            // so a column that lands exactly on a shared triangle edge/diagonal is not
            // double-counted (which would break the parity fill). Deterministic.
            for j in jLo...jHi {
                let py = Float(j) + 0.000713
                for i in iLo...iHi {
                    let px = Float(i) + 0.000371
                    let l0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / det
                    let l1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / det
                    let l2 = 1 - l0 - l1
                    // Inside (half-open on two edges to avoid double-counting shared edges).
                    if l0 >= 0 && l1 >= 0 && l2 >= 0 {
                        let z = l0 * zg.x + l1 * zg.y + l2 * zg.z
                        crossings[j * nx + i].append(z)
                    }
                }
            }
        }

        // Parity-fill each column: sort crossings, fill voxels between pairs (0-1, 2-3…).
        for j in 0..<ny {
            for i in 0..<nx {
                var zs = crossings[j * nx + i]
                guard zs.count >= 2 else { continue }
                zs.sort()
                var k = 0
                while k + 1 < zs.count {
                    let z0 = zs[k], z1 = zs[k + 1]; k += 2
                    let kLo = Swift.max(0, Int(ceil(z0)))
                    let kHi = Swift.min(nz - 1, Int(floor(z1)))
                    if kLo <= kHi {
                        for kk in kLo...kHi { vals[(kk * ny + j) * nx + i] = 1 }
                    }
                }
            }
        }
        return LatticeVoxelGrid(nx: nx, ny: ny, nz: nz, origin: origin, spacing: spacing, values: vals)
    }

    /// The PER-CELL activation + demand field the shader actually consumes — the
    /// worker's whole-cell emission made previewable. One value per LATTICE CELL
    /// (cells centred at `occupancy.origin + i·cellMM`, matching the shader's fold):
    ///   • `-1`  — cell inactive: none of its struts render.
    ///   • `d ≥ 0` — cell active, with its mean demand fraction (0 when no field).
    /// A cell is ACTIVE when at least `insideFraction` of its volume lies inside the
    /// part (4³ subsamples against the occupancy grid). The default is near zero —
    /// ANY meaningful overlap — because the renderer trims the struts flush against
    /// the part's signed-distance field (round 3): every boundary cell contributes
    /// struts right up to the surface, so edges are consistently LINED at every cell
    /// size, and the trim (not a threshold) decides where they stop. No thin region
    /// can lose cells to a knife-edge test. Rebaked only when the mesh, field, or
    /// cell size changes — never per frame (P2).
    public static func cellField(occupancy occ: LatticeVoxelGrid, demand: LatticeVoxelGrid?,
                                 cellMM: Double, insideFraction: Double = 0.02) -> LatticeVoxelGrid {
        let cell = Float(max(0.1, cellMM))
        let extent = SIMD3<Float>(Float(occ.nx - 1) * occ.spacing.x,
                                  Float(occ.ny - 1) * occ.spacing.y,
                                  Float(occ.nz - 1) * occ.spacing.z)
        let ncx = Swift.max(1, Int(ceil(extent.x / cell)) + 1)
        let ncy = Swift.max(1, Int(ceil(extent.y / cell)) + 1)
        let ncz = Swift.max(1, Int(ceil(extent.z / cell)) + 1)
        var vals = [Float](repeating: -1, count: ncx * ncy * ncz)

        func occAt(_ w: SIMD3<Float>) -> Bool {
            let g = (w - occ.origin) / occ.spacing
            let i = Int(g.x.rounded()), j = Int(g.y.rounded()), k = Int(g.z.rounded())
            guard i >= 0, i < occ.nx, j >= 0, j < occ.ny, k >= 0, k < occ.nz else { return false }
            return occ.values[(k * occ.ny + j) * occ.nx + i] > 0.5
        }
        func demandAt(_ w: SIMD3<Float>) -> Float {
            guard let dem = demand else { return 0 }
            let g = (w - dem.origin) / dem.spacing
            let i = Swift.min(Swift.max(Int(g.x.rounded()), 0), dem.nx - 1)
            let j = Swift.min(Swift.max(Int(g.y.rounded()), 0), dem.ny - 1)
            let k = Swift.min(Swift.max(Int(g.z.rounded()), 0), dem.nz - 1)
            return dem.values[(k * dem.ny + j) * dem.nx + i]
        }

        let S = 4   // 4³ subsamples per cell
        for ck in 0..<ncz {
            for cj in 0..<ncy {
                for ci in 0..<ncx {
                    let center = occ.origin + SIMD3<Float>(Float(ci), Float(cj), Float(ck)) * cell
                    var insideCount = 0
                    var demandSum: Float = 0
                    for sz in 0..<S { for sy in 0..<S { for sx in 0..<S {
                        let off = SIMD3<Float>((Float(sx) + 0.5) / Float(S) - 0.5,
                                               (Float(sy) + 0.5) / Float(S) - 0.5,
                                               (Float(sz) + 0.5) / Float(S) - 0.5)
                        let w = center + off * cell
                        if occAt(w) {
                            insideCount += 1
                            demandSum += demandAt(w)
                        }
                    } } }
                    let frac = Double(insideCount) / Double(S * S * S)
                    if frac >= insideFraction {
                        vals[(ck * ncy + cj) * ncx + ci] =
                            insideCount > 0 ? Swift.max(0, demandSum / Float(insideCount)) : 0
                    }
                }
            }
        }
        return LatticeVoxelGrid(nx: ncx, ny: ncy, nz: ncz, origin: occ.origin,
                                spacing: SIMD3<Float>(repeating: cell), values: vals)
    }

    /// A truncated SIGNED-DISTANCE field of the part on the occupancy's grid (mm,
    /// negative inside), for the shader's flush boundary trim (round-3 maintainer
    /// feedback: edges must be STRAIGHT at every cell size). Near the surface (within
    /// `bandVoxels`) the distance is EXACT point-to-triangle against the real mesh —
    /// and because distance-to-a-plane is affine, trilinear interpolation reproduces
    /// the part's flat faces exactly, which is precisely why the trimmed edge renders
    /// straight where a binary-mask clip (round 1) rendered ragged. Beyond the band
    /// the value is clamped to ±band (the trim only needs accuracy near the surface).
    /// Sign comes from the parity-filled occupancy. Baked once per mesh (P2).
    public static func signedDistance(positions: [Float], indices: [UInt32],
                                      like occ: LatticeVoxelGrid, bandVoxels: Int = 3) -> LatticeVoxelGrid {
        let minSp = Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z))
        let farValue = Float(bandVoxels) * minSp

        func pos(_ i: UInt32) -> SIMD3<Float> {
            let b = Int(i) * 3
            return SIMD3<Float>(positions[b], positions[b + 1], positions[b + 2])
        }

        // SCATTER: each triangle writes its exact distance into every voxel of its
        // AABB padded by the band, min-combined. Any voxel within `bandVoxels` of the
        // surface is inside its nearest triangle's padded AABB (∞-norm ≥ euclidean),
        // so band voxels get the EXACT distance; untouched voxels are beyond the band
        // and take the clamped far value. No search structures, ~O(tris × local box).
        var dist2 = [Float](repeating: .greatestFiniteMagnitude, count: occ.count)
        let triCount = indices.count / 3
        let padF = SIMD3<Float>(repeating: Float(bandVoxels)) * (SIMD3<Float>(repeating: minSp) / occ.spacing)
        for t in 0..<triCount {
            let a = pos(indices[t * 3]), b = pos(indices[t * 3 + 1]), c = pos(indices[t * 3 + 2])
            let lo = (simd_min(a, simd_min(b, c)) - occ.origin) / occ.spacing - padF
            let hi = (simd_max(a, simd_max(b, c)) - occ.origin) / occ.spacing + padF
            let i0 = Swift.max(0, Int(lo.x.rounded(.down))), i1 = Swift.min(occ.nx - 1, Int(hi.x.rounded(.up)))
            let j0 = Swift.max(0, Int(lo.y.rounded(.down))), j1 = Swift.min(occ.ny - 1, Int(hi.y.rounded(.up)))
            let k0 = Swift.max(0, Int(lo.z.rounded(.down))), k1 = Swift.min(occ.nz - 1, Int(hi.z.rounded(.up)))
            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }
            for k in k0...k1 {
                let pz = occ.origin.z + Float(k) * occ.spacing.z
                for j in j0...j1 {
                    let py = occ.origin.y + Float(j) * occ.spacing.y
                    let rowBase = (k * occ.ny + j) * occ.nx
                    for i in i0...i1 {
                        let p = SIMD3<Float>(occ.origin.x + Float(i) * occ.spacing.x, py, pz)
                        let d2 = Self.pointTriangleDistSq(p, a, b, c)
                        if d2 < dist2[rowBase + i] { dist2[rowBase + i] = d2 }
                    }
                }
            }
        }

        var vals = [Float](repeating: 0, count: occ.count)
        for vi in 0..<occ.count {
            let inside = occ.values[vi] > 0.5
            let d2 = dist2[vi]
            let d = d2 == .greatestFiniteMagnitude ? farValue : Swift.min(d2.squareRoot(), farValue)
            vals[vi] = inside ? -d : d
        }
        return LatticeVoxelGrid(nx: occ.nx, ny: occ.ny, nz: occ.nz,
                                origin: occ.origin, spacing: occ.spacing, values: vals)
    }

    /// Squared distance from `p` to triangle `abc` (Ericson, Real-Time Collision
    /// Detection §5.1.5 — the standard closest-point-on-triangle case analysis).
    static func pointTriangleDistSq(_ p: SIMD3<Float>, _ a: SIMD3<Float>,
                                    _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length_squared(ap - ab * v)
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length_squared(ap - ac * w)
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(bp + (c - b) * w)
        }
        let denom = 1 / (va + vb + vc)
        let v = vb * denom, w = vc * denom
        return simd_length_squared(p - (a + ab * v + ac * w))
    }

    /// A normalised demand grid (0…1 = von Mises / peak) sampled onto the SAME grid as
    /// `occupancy`, for the shader's grading. Returns nil when there is no field — the
    /// caller then previews a uniform lattice (bar 4 honest no-field case). Sampling is
    /// nearest-cell from the field (the shader trilerps between grid voxels).
    public static func demand(like occ: LatticeVoxelGrid, field: StressField?) -> LatticeVoxelGrid? {
        guard let field = field, !field.isEmpty, let peak = field.peak()?.valueMPa, peak > 0 else { return nil }
        let inv = 1.0 / Float(peak)
        var vals = [Float](repeating: 0, count: occ.count)
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let p = occ.origin + SIMD3<Float>(Float(i) * occ.spacing.x,
                                                      Float(j) * occ.spacing.y,
                                                      Float(k) * occ.spacing.z)
                    let d = Swift.max(0, Swift.min(1, field.value(at: p) * inv))
                    vals[(k * occ.ny + j) * occ.nx + i] = d
                }
            }
        }
        return LatticeVoxelGrid(nx: occ.nx, ny: occ.ny, nz: occ.nz,
                                origin: occ.origin, spacing: occ.spacing, values: vals)
    }
}
