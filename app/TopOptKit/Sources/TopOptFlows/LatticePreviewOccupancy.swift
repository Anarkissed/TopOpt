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
import Dispatch
import simd
import TopOptKit
import TopOptBridge

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
    /// - Parameters:
    ///   - memberThickness: core's local member thickness (mm) per OCCUPANCY voxel,
    ///     or empty when core had no answer. See `minCellsPerMember`.
    ///   - minCellsPerMember: core's N*. A cell whose member cannot hold this many
    ///     cells is NOT latticed — the run leaves it SOLID (grading.hpp bar L4), and
    ///     a preview that draws lattice there is showing a part that will not be
    ///     built. 0 (or no thickness) disables the gate, which is the old behaviour.
    public static func cellField(occupancy occ: LatticeVoxelGrid, demand: LatticeVoxelGrid?,
                                 cellMM: Double, insideFraction: Double = 0.02,
                                 memberThickness: [Double] = [],
                                 minCellsPerMember: Double = 0) -> LatticeVoxelGrid {
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

        // ★★ THE FLOOR IS EVALUATED OVER THE CELL'S OWN MATERIAL, NOT ITS CENTRE
        // (measured on his part, 2026-08-20).
        //
        // ★ THE CENTRE SAMPLE LET THROUGH CELLS NOTHING SUPPORTS. It read ONE voxel
        // and the gate said `if t > 0` — so where a cell's centre landed OUTSIDE the
        // solid, thickness came back 0 and "no measurement here" was taken as "no
        // objection". On his 13.9 mm wall at a 4 mm cell that is most of them: ZERO
        // voxels in the region clear N* = 5 (a 4 mm cell needs 20 mm of member) and
        // 374 cells survived anyway. Manual 4 mm looked the most complete of every
        // mode BECAUSE it was the most wrong — the preview drawing lattice the run
        // will not build, which is the whole defect this floor exists to end.
        //
        // ★ CORE'S RULE IS EVERY VOXEL, and it is asked that way here: the WORST
        // thickness under the cell decides. `+inf` is core's "thicker than measured"
        // sentinel and clears it, the conservative direction; free space measures
        // nothing and gets no vote.
        func thicknessAt(_ w: SIMD3<Float>) -> Double? {
            guard minCellsPerMember > 0, !memberThickness.isEmpty else { return nil }
            let g = (w - occ.origin) / occ.spacing
            let vi = Swift.min(Swift.max(Int(g.x.rounded()), 0), occ.nx - 1)
            let vj = Swift.min(Swift.max(Int(g.y.rounded()), 0), occ.ny - 1)
            let vk = Swift.min(Swift.max(Int(g.z.rounded()), 0), occ.nz - 1)
            let n = (vk * occ.ny + vj) * occ.nx + vi
            guard n >= 0, n < memberThickness.count else { return nil }
            return memberThickness[n]
        }

        let S = 4   // 4³ subsamples per cell
        for ck in 0..<ncz {
            for cj in 0..<ncy {
                for ci in 0..<ncx {
                    let center = occ.origin + SIMD3<Float>(Float(ci), Float(cj), Float(ck)) * cell
                    var insideCount = 0
                    var demandSum: Float = 0
                    var worstThickness = Double.infinity
                    for sz in 0..<S { for sy in 0..<S { for sx in 0..<S {
                        let off = SIMD3<Float>((Float(sx) + 0.5) / Float(S) - 0.5,
                                               (Float(sy) + 0.5) / Float(S) - 0.5,
                                               (Float(sz) + 0.5) / Float(S) - 0.5)
                        let w = center + off * cell
                        if occAt(w) {
                            insideCount += 1
                            demandSum += demandAt(w)
                            // Only material INSIDE the cell gets a say — a sample in
                            // free space measures nothing and must not vote either way.
                            if let t = thicknessAt(w), t > 0, t < worstThickness {
                                worstThickness = t
                            }
                        }
                    } } }
                    let frac = Double(insideCount) / Double(S * S * S)
                    // ★★ CORE'S L4 FLOOR, APPLIED HERE TOO (task 2026-08-20). A member
                    // too thin to hold N* cells is left SOLID by the run; drawing
                    // lattice in it was the preview showing geometry that never gets
                    // built. `+inf` is core's "thicker than measured" sentinel and
                    // clears the floor, which is the conservative direction.
                    var memberHoldsTheCell = true
                    if minCellsPerMember > 0, !memberThickness.isEmpty,
                       worstThickness.isFinite,
                       worstThickness / Double(cell) < minCellsPerMember {
                        memberHoldsTheCell = false
                    }
                    if frac >= insideFraction, memberHoldsTheCell {
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
        // ★★ PARALLEL BY Z-SLAB (maintainer, 2026-08-20: "I'm counting about 10
        // seconds for the lattice to turn on. Is there any way to shorten that
        // time?"). Measured on this fixture, the base scene bake was 2.74s of a 3.38s
        // total — this scatter is the bulk of it, and it is the same exact
        // point-to-triangle work either way.
        //
        // ★ WHY SLABS AND NOT TRIANGLES. The loop MIN-COMBINES into shared voxels, so
        // splitting the triangles would race on `dist2`. Splitting the VOXELS by k
        // gives every worker a disjoint write range — no locks, no atomics, identical
        // output — at the cost of each worker AABB-rejecting the triangles that miss
        // its slab, which is a handful of compares against work measured in voxels.
        let slabCount = Swift.max(1, Swift.min(occ.nz,
                                               ProcessInfo.processInfo.activeProcessorCount))
        dist2.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: slabCount) { slab in
                let kStart = occ.nz * slab / slabCount
                let kEnd = occ.nz * (slab + 1) / slabCount        // exclusive
                guard kStart < kEnd else { return }
                for t in 0..<triCount {
                    let a = pos(indices[t * 3]), b = pos(indices[t * 3 + 1]), c = pos(indices[t * 3 + 2])
                    let lo = (simd_min(a, simd_min(b, c)) - occ.origin) / occ.spacing - padF
                    let hi = (simd_max(a, simd_max(b, c)) - occ.origin) / occ.spacing + padF
                    let k0 = Swift.max(kStart, Int(lo.z.rounded(.down)))
                    let k1 = Swift.min(kEnd - 1, Int(hi.z.rounded(.up)))
                    guard k0 <= k1 else { continue }
                    let i0 = Swift.max(0, Int(lo.x.rounded(.down))), i1 = Swift.min(occ.nx - 1, Int(hi.x.rounded(.up)))
                    let j0 = Swift.max(0, Int(lo.y.rounded(.down))), j1 = Swift.min(occ.ny - 1, Int(hi.y.rounded(.up)))
                    guard i0 <= i1, j0 <= j1 else { continue }
                    for k in k0...k1 {
                        let pz = occ.origin.z + Float(k) * occ.spacing.z
                        for j in j0...j1 {
                            let py = occ.origin.y + Float(j) * occ.spacing.y
                            let rowBase = (k * occ.ny + j) * occ.nx
                            for i in i0...i1 {
                                let p = SIMD3<Float>(occ.origin.x + Float(i) * occ.spacing.x, py, pz)
                                let d2 = Self.pointTriangleDistSq(p, a, b, c)
                                if d2 < buf[rowBase + i] { buf[rowBase + i] = d2 }
                            }
                        }
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

    /// A normalised demand grid (0…1) sampled onto the SAME grid as `occupancy`, for
    /// the shader's grading. Returns nil when there is no field — the caller then
    /// previews a uniform lattice (bar 4 honest no-field case). Sampling is
    /// nearest-cell from the field (the shader trilerps between grid voxels).
    ///
    /// ★ THE NORMALISATION COMES FROM CORE, NOT FROM HERE (amendment bar R15).
    /// This used to be `vonMises / field.peak()` — the PEAK-RELATIVE law, which core
    /// stopped using: STRUCTURAL divides by the material allowable, AESTHETIC by a
    /// percentile of the field. Left as it was, the preview would shade one lattice
    /// while core built another. The strut-diameter law has ALREADY drifted 1.4–1.7×
    /// by being re-derived in Swift, so the denominator and the clamp are both taken
    /// from `topoptbridge.grading_demand_fraction_field`, which calls core's own
    /// `grading_demand_fraction`. Nothing about the law is restated here.
    ///
    /// `intent` 0 = structural, 1 = aesthetic (core's default for a lattice-only job).
    /// `allowableMPa` is yield / margin_stop — `SimAnalysisResult.marginRequired`
    /// carries the divisor the run actually used.
    public static func demand(like occ: LatticeVoxelGrid, field: StressField?,
                              intent: Int = 1, allowableMPa: Double = 0,
                              percentile: Double = 0,
                              utilisationTarget: Double = 1) -> LatticeVoxelGrid? {
        guard let field = field, !field.isEmpty else { return nil }
        // Sample the field onto the occupancy grid FIRST, then let core normalise the
        // samples — so the percentile is taken over exactly the values that will be
        // shaded, which is what makes the app's number comparable to core's receipt.
        var raw = [Float](repeating: 0, count: occ.count)
        for k in 0..<occ.nz {
            for j in 0..<occ.ny {
                for i in 0..<occ.nx {
                    let p = occ.origin + SIMD3<Float>(Float(i) * occ.spacing.x,
                                                      Float(j) * occ.spacing.y,
                                                      Float(k) * occ.spacing.z)
                    raw[(k * occ.ny + j) * occ.nx + i] = field.value(at: p)
                }
            }
        }
        var vals = [Float](repeating: 0, count: occ.count)
        raw.withUnsafeBufferPointer { src in
            vals.withUnsafeMutableBufferPointer { dst in
                topoptbridge.grading_demand_fraction_into(
                    src.baseAddress, src.count, Int32(intent), allowableMPa,
                    percentile, utilisationTarget, dst.baseAddress)
            }
        }
        return LatticeVoxelGrid(nx: occ.nx, ny: occ.ny, nz: occ.nz,
                                origin: occ.origin, spacing: occ.spacing, values: vals)
    }
}

// ★★ THE GRADED CELL FIELD — CORE'S DYADIC PLAN, BAKED FOR THE MARCH
// (maintainer, 2026-08-19: "I was talking about the PREVIEW when I asked about the
// cell size being able to grade. Is there *NO* way to make the *PREVIEW* lattice
// grade cell size?").
//
// ★ THE PREVIEW DREW ONE CELL FOR THE WHOLE PART. A swept run does not: core's
// `plan_cell_sizes` puts every region on the FINEST dyadic cell whose thinnest strut
// still prints, so a lightly loaded region — thin struts — is forced onto a coarser
// cell, and a loaded one stays fine. That plan is read here, never re-derived: the
// app deciding cell sizes for itself is the divergence this whole pass exists to
// close.
//
// ★ WHY THE FIELD STAYS ON THE BASE GRID. A level-L cell occupies an ALIGNED 2^L
// block of the base grid, so every base cell in a block carries that block's level
// and that block's demand. One texture, one lookup, and the shader recovers the
// octree by integer division — no second grid, and no way for the two to disagree
// about where a cell starts, which is what would put a strut end in the middle of a
// neighbour's face.
public struct LatticeCellField: Sendable {
    /// Per BASE cell: the demand (≥ 0) of the octree cell covering it, −1 where the
    /// run leaves the material SOLID.
    public let field: LatticeVoxelGrid
    /// Per base cell, same layout: the dyadic level of the covering octree cell.
    /// All zero on the ungraded path, which is exactly what "one cell size" means.
    public let level: [Float]
    public let baseCellMM: Double
    public let maxLevel: Int
    /// True when this came from core's plan rather than the uniform fallback — the
    /// preview says which, because "core had no plan" and "core planned one level"
    /// look identical in the picture and are not the same fact.
    public let fromCorePlan: Bool
}

extension LatticePreviewOccupancy {

    /// The uniform field, wrapped — one level, everywhere, which is what a Fixed or
    /// Auto job actually builds.
    public static func uniformCellField(_ grid: LatticeVoxelGrid,
                                        cellMM: Double) -> LatticeCellField {
        LatticeCellField(field: grid,
                         level: [Float](repeating: 0, count: grid.count),
                         baseCellMM: cellMM, maxLevel: 0, fromCorePlan: false)
    }

    /// Bake core's plan onto its OWN base grid.
    ///
    /// Activation comes from the plan (`level < 0` ⇒ the run leaves it solid), so the
    /// cells-per-member floor and the printability floor are core's here, not a
    /// second copy of them — `plan_cell_sizes` enforces both per cell before it
    /// returns. Demand is averaged over each octree cell, because a level-L cell is
    /// ONE cell and grades to ONE density; sampling its centre would let an 8 mm cell
    /// take the density of whichever 1.7 mm voxel happened to sit in the middle.
    public static func gradedCellField(occupancy occ: LatticeVoxelGrid,
                                       demand: LatticeVoxelGrid?,
                                       plan: LatticeCellSizePlan) -> LatticeCellField {
        let n = plan.count
        let S0 = Float(plan.baseCellMM)
        // Core's base grid is CORNER-based: base cell i spans [origin + i·S0,
        // origin + (i+1)·S0). The march's grid is CENTRE-based, so the centre of
        // base cell i is origin + (i + ½)·S0 — half a cell apart, and getting that
        // wrong shifts every block by half a cell and unpicks the whole ladder.
        let originCorner = SIMD3<Float>(Float(plan.origin.x), Float(plan.origin.y),
                                        Float(plan.origin.z))

        func demandAt(_ w: SIMD3<Float>) -> Float {
            guard let dem = demand else { return 0 }
            let g = (w - dem.origin) / dem.spacing
            let i = Swift.min(Swift.max(Int(g.x.rounded()), 0), dem.nx - 1)
            let j = Swift.min(Swift.max(Int(g.y.rounded()), 0), dem.ny - 1)
            let k = Swift.min(Swift.max(Int(g.z.rounded()), 0), dem.nz - 1)
            return dem.values[(k * dem.ny + j) * dem.nx + i]
        }

        // Pass 1 — each base cell's own demand, sampled at its centre.
        var own = [Float](repeating: 0, count: n)
        for k in 0..<plan.nz {
            for j in 0..<plan.ny {
                for i in 0..<plan.nx {
                    let idx = plan.index(i, j, k)
                    guard plan.level[idx] >= 0 else { continue }
                    let c = originCorner + (SIMD3<Float>(Float(i), Float(j), Float(k))
                                            + SIMD3<Float>(repeating: 0.5)) * S0
                    own[idx] = demandAt(c)
                }
            }
        }

        // Pass 2 — average over each octree cell, keyed by its min-corner base cell.
        var sum = [Float](repeating: 0, count: n)
        var cnt = [Float](repeating: 0, count: n)
        func corner(_ i: Int, _ j: Int, _ k: Int, _ m: Int) -> Int {
            plan.index((i / m) * m, (j / m) * m, (k / m) * m)
        }
        for k in 0..<plan.nz {
            for j in 0..<plan.ny {
                for i in 0..<plan.nx {
                    let idx = plan.index(i, j, k)
                    let L = plan.level[idx]
                    guard L >= 0 else { continue }
                    let c = corner(i, j, k, 1 << Int(L))
                    sum[c] += own[idx]; cnt[c] += 1
                }
            }
        }

        // Pass 3 — write the octree cell's value back to every base cell it covers.
        var vals = [Float](repeating: -1, count: n)
        var lvl = [Float](repeating: 0, count: n)
        for k in 0..<plan.nz {
            for j in 0..<plan.ny {
                for i in 0..<plan.nx {
                    let idx = plan.index(i, j, k)
                    let L = plan.level[idx]
                    guard L >= 0 else { continue }
                    let c = corner(i, j, k, 1 << Int(L))
                    vals[idx] = cnt[c] > 0 ? Swift.max(0, sum[c] / cnt[c]) : 0
                    lvl[idx] = Float(L)
                }
            }
        }

        let grid = LatticeVoxelGrid(
            nx: plan.nx, ny: plan.ny, nz: plan.nz,
            origin: originCorner + SIMD3<Float>(repeating: 0.5 * S0),
            spacing: SIMD3<Float>(repeating: S0), values: vals)
        return LatticeCellField(field: grid, level: lvl, baseCellMM: plan.baseCellMM,
                                maxLevel: plan.maxLevel, fromCorePlan: true)
    }
}

/// The swept cell window a job carries, as the preview needs to ask for it: the
/// ladder's ends plus the bead the printability floor is measured against. All three
/// are the user's own numbers — the preview states none of them itself.
public struct LatticeCellSweep: Equatable, Sendable {
    public var minMM: Double
    public var maxMM: Double
    public var minExtrudableWidthMM: Double
    /// ★★★ AUTO: EVERY VOXEL GETS THE COARSEST CELL ITS OWN MEMBER CAN HOLD
    /// (his ruling, 2026-08-20 — "per local member. That will also help with grading").
    ///
    /// ★ WHY A FLAG AND NOT A WINDOW. A window cannot express this, and two attempts to
    /// make it proved that on his own part. ONE cell size cannot serve a part whose
    /// walls run 3.69 mm to 55.38 mm — measured on `M2_verticalStand_THICK`:
    ///
    ///     wall        biggest cell it can hold (W / N*)
    ///      3.69 mm ....  0.74 mm
    ///     22–24 mm .... ~4.6 mm     <- 34% of the part, his "20 mm walls"
    ///     44–46 mm .... ~9.0 mm     <- 29% of the part
    ///     55.38 mm .... 11.08 mm
    ///
    /// Take the widest and one rung at 11.08 mm needs 55 mm of member, so ~99% of the
    /// part is culled — sparse clumps in an empty wall. Take a swept window instead and
    /// core's `plan_cell_sizes` descends to the FINEST rung that prints (`need_max == L`),
    /// which on his older part planned every one of 5,556 cells at 3.00 mm and refused
    /// 8,906 base cells as "member too thin", because 3.00 mm needs 15 mm and his median
    /// wall is 10.39 mm. Both failures are the same failure: a cell imposed on material
    /// that was never asked what it could hold.
    ///
    /// ★ SO THE CELL IS DERIVED PER VOXEL AND CORE ALREADY KNOWS HOW TO USE IT.
    /// `plan_cell_sizes_fit` takes a per-voxel `desired_cell_mm` and picks, per base
    /// cell, "the coarsest ladder rung at or below its own derived cell. Never above
    /// (that would put fewer cells across the member than the derivation asked for)."
    /// That IS his rule, in core's own words, already implemented. All the app has to do
    /// is hand it `width / N*` per voxel instead of one number for the whole part.
    ///
    /// ★ AND IT ROUNDS DOWN, WHICH MATTERS MORE THAN IT LOOKS. The preview's occupancy
    /// grid is 1.84 mm on his part, so the granulometric opening reads his 20 mm walls
    /// as 22–24 mm — about +10%. A rule that rounded UP would turn that over-read into a
    /// cell the wall cannot hold, and the floor would then cull it. Rounding down to a
    /// rung absorbs the quantisation instead of amplifying it.
    ///
    /// nil / false ⇒ the swept window is used verbatim, which is what Swept means and
    /// what a user who typed the ends is owed.
    public var perLocalMember: Bool
    public init(minMM: Double, maxMM: Double, minExtrudableWidthMM: Double,
                perLocalMember: Bool = false) {
        self.minMM = minMM; self.maxMM = maxMM
        self.minExtrudableWidthMM = minExtrudableWidthMM
        self.perLocalMember = perLocalMember
    }
}

// ★★ SUB-FLOOR RETENTION IN THE PREVIEW (maintainer, 2026-08-20: "Why does that rule
// exist for a wall that does not need to certify?").
//
// ★ HE IS RIGHT, AND CORE ALREADY AGREED. `retain_subfloor_in_unloaded_regions` keeps
// lattice in material too thin to hold N* cells, PROVIDED the region's measured peak
// stress is at or under core's ceiling as a fraction of the part's peak. The app has
// carried that switch since the retention task; the preview had never heard of it, so
// the member floor added yesterday removed cells a run with retention armed keeps.
// One divergence closed and its mirror image left open.
//
// ★ WHAT RETENTION NEVER DOES, and this preview does not either: it never rescues an
// UNPRINTABLE strut. That is a fact about the nozzle, not about load — core rejects
// those cells with reason 2 and retention has nothing to say about them.
//
// ★ THE UNION READING, DELIBERATELY. Core evaluates the fraction per declared region
// only when the caller hands it region ids; its DEFAULT — and every job this app
// currently emits — measures the whole candidate set as one. Union is the
// conservative end: one loud region vetoes the rest. The preview matches the job it
// is previewing, not the job core could be asked for.
public struct LatticeSubfloorRetention: Equatable, Sendable {
    /// Off ⇒ the floor applies everywhere, which is the shipped behaviour.
    public var armed: Bool
    /// The ceiling, ONLY when the user moved it off core's own number. nil ⇒ read
    /// core's constant at bake time, so the app never authors it.
    public var stressFractionMax: Double?
    public init(armed: Bool, stressFractionMax: Double? = nil) {
        self.armed = armed; self.stressFractionMax = stressFractionMax
    }
}

extension LatticePreviewOccupancy {

    /// Does the declared set qualify? `regionPeak / partPeak <= ceiling`, exactly
    /// core's arithmetic — including its guard that NO DEMAND FIELD MEANS NO
    /// RETENTION. An all-zero demand reads as "carries nothing" and means "nothing
    /// was measured", and the difference is the whole safety of the feature.
    public static func subfloorQualifies(regionPeak: Double, partPeak: Double,
                                         ceiling: Double) -> Bool {
        guard partPeak > 0, ceiling > 0, ceiling <= 1 else { return false }
        return min(1, regionPeak / partPeak) <= ceiling
    }

    /// The peaks core measures: over the part's PRINTED voxels, and over the
    /// candidate set. `inside` is negative-inside part distance.
    public static func subfloorPeaks(demand: LatticeVoxelGrid?,
                                     partSDF: LatticeVoxelGrid,
                                     occupancy: LatticeVoxelGrid) -> (part: Double, region: Double) {
        guard let d = demand, d.count == partSDF.count,
              occupancy.count == partSDF.count else { return (0, 0) }
        var part = 0.0, region = 0.0
        for i in 0..<d.count {
            let v = Double(d.values[i])
            guard v.isFinite else { continue }
            if partSDF.values[i] <= 0 { part = Swift.max(part, v) }
            if occupancy.values[i] > 0.5 { region = Swift.max(region, v) }
        }
        return (part, region)
    }

    /// ★ RETAIN, ON THE GRADED PATH. Core's swept form gives a retained voxel the
    /// FINEST level of the plan's own ladder at which its own density still prints.
    ///
    /// ★ CAPPED AT ONE LEVEL ABOVE THE BASE, deliberately. A retained block is not
    /// part of the octree the planner balanced, so nothing guarantees it differs from
    /// its neighbours by at most one level — and the march's step cap is built on
    /// exactly that 2:1 guarantee (it halves the step for a level-L cell because the
    /// finest thing that can touch it is S/2). A two-level jump would let the ray
    /// march over a fine neighbour and punch holes in it. One level is safe, it is
    /// the coarsening his own part needs (2 mm → 4 mm), and where it is not enough
    /// the cell stays SOLID — the preview showing less than the run, never more.
    public static func retainSubfloorCells(_ field: LatticeCellField,
                                           plan: LatticeCellSizePlan,
                                           demand: LatticeVoxelGrid?,
                                           densityLo: Double, densityHi: Double,
                                           gamma: Double,
                                           minExtrudableWidthMM: Double,
                                           topology: String) -> LatticeCellField {
        guard minExtrudableWidthMM > 0, plan.count == field.field.count else { return field }
        var vals = field.field.values
        var lvl = field.level
        let S0 = Float(plan.baseCellMM)
        let originCorner = SIMD3<Float>(Float(plan.origin.x), Float(plan.origin.y),
                                        Float(plan.origin.z))

        func demandAt(_ w: SIMD3<Float>) -> Double {
            guard let dem = demand else { return 0 }
            let g = (w - dem.origin) / dem.spacing
            let i = Swift.min(Swift.max(Int(g.x.rounded()), 0), dem.nx - 1)
            let j = Swift.min(Swift.max(Int(g.y.rounded()), 0), dem.ny - 1)
            let k = Swift.min(Swift.max(Int(g.z.rounded()), 0), dem.nz - 1)
            return Double(dem.values[(k * dem.ny + j) * dem.nx + i])
        }

        // Finest level whose strut prints, per cell, then placed block-by-block from
        // fine to coarse so a coarse block never lands on a cell the plan already owns.
        let ceilingLevel = Swift.min(1, Swift.max(0, plan.maxLevel))
        var retained = 0
        for L in 0...ceilingLevel {
            let m = 1 << L
            let cellMM = plan.baseCellMM * pow(2, Double(L))
            for k in 0..<plan.nz {
                for j in 0..<plan.ny {
                    for i in 0..<plan.nx {
                        let idx = plan.index(i, j, k)
                        // Only cells core rejected for a THIN MEMBER, and only ones
                        // still unclaimed after the finer passes.
                        guard plan.level[idx] < 0, plan.rejectReason[idx] == 1,
                              vals[idx] < 0 else { continue }
                        let centre = originCorner
                            + (SIMD3<Float>(Float(i), Float(j), Float(k))
                               + SIMD3<Float>(repeating: 0.5)) * S0
                        let t = Swift.max(0, Swift.min(1, demandAt(centre)))
                        let rho = densityLo + (densityHi - densityLo) * pow(t, gamma)
                        let dia = TopOptKit.latticeStrutDiameterMM(
                            topology: topology, relativeDensity: rho, cellMM: cellMM)
                        guard dia > 0, dia >= minExtrudableWidthMM else { continue }
                        // The whole aligned block must be free, or the shader's
                        // block reconstruction disagrees with what is stored.
                        let bi = (i / m) * m, bj = (j / m) * m, bk = (k / m) * m
                        guard bi + m <= plan.nx, bj + m <= plan.ny, bk + m <= plan.nz
                        else { continue }
                        var free = true
                        for kk in bk..<(bk + m) where free {
                            for jj in bj..<(bj + m) where free {
                                for ii in bi..<(bi + m) where free {
                                    if vals[plan.index(ii, jj, kk)] >= 0 { free = false }
                                }
                            }
                        }
                        guard free else { continue }
                        for kk in bk..<(bk + m) {
                            for jj in bj..<(bj + m) {
                                for ii in bi..<(bi + m) {
                                    let n = plan.index(ii, jj, kk)
                                    vals[n] = Float(t)
                                    lvl[n] = Float(L)
                                }
                            }
                        }
                        retained += m * m * m
                    }
                }
            }
        }
        guard retained > 0 else { return field }
        let g = field.field
        return LatticeCellField(
            field: LatticeVoxelGrid(nx: g.nx, ny: g.ny, nz: g.nz, origin: g.origin,
                                    spacing: g.spacing, values: vals),
            level: lvl, baseCellMM: field.baseCellMM,
            maxLevel: Swift.max(field.maxLevel, ceilingLevel), fromCorePlan: true)
    }
}
