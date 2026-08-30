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
        // ★★★ ONE SPACING FOR ALL THREE AXES — THE VOXEL IS A CUBE (maintainer,
        // 2026-08-22: "Find every reason why the two walls aren't *entirely* being
        // latticed").
        //
        // ★ EACH AXIS USED TO BE ROUNDED INDEPENDENTLY and its spacing derived as
        // `extent / (n - 1)`, so the three spacings differed by the rounding — and the
        // SHORTER the axis, the worse it is. On his part: 1.22% at Fine 128, but 5.63%
        // at Fast 64 (23 voxels across the short axis).
        //
        // ★★ AND THAT SILENTLY DISABLED HALF THE PIPELINE. `lattice_member_thickness_mm`
        // takes ONE cubic spacing and refuses a grid whose axes disagree by more than
        // 2%, returning an EMPTY array. Empty member thickness means: no cells-per-member
        // floor, no per-local-member Auto cell, no measured region width (the declared
        // depth is used instead), and no Auto ceiling. So the preview did something
        // QUALITATIVELY DIFFERENT at Fast than at Fine, said nothing, and every fix
        // aimed at the floor looked inert because at 64 there was no floor to fix.
        //
        // A cube also makes the voxel isotropic for the SDF and the EDT, which every
        // consumer already assumed. Dimensions grow by at most one voxel per axis.
        let sp = longest / Float(Swift.max(1, maxDim - 1))
        func d(_ v: Float) -> Int { Swift.max(2, Int((v / sp).rounded(.up)) + 1) }
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
        // ★ THE SAME CUBIC SPACING `dims` SIZED THE GRID WITH — deriving it per axis
        // from `extent / (n - 1)` is what made the voxel a brick. See `dims`.
        let cubic = Swift.max(extent.x, Swift.max(extent.y, extent.z))
            / Float(Swift.max(1, Swift.max(nx, Swift.max(ny, nz)) - 1))
        let sp = SIMD3<Float>(repeating: cubic)
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
    /// ★★★ `originShiftMM` MOVES THE CELL GRID SO A DECLARED FACE LANDS ON A CELL
    /// BOUNDARY. Struts are trimmed flush at the region's cap planes, and a cap through
    /// the middle of a cell slices every strut at its fattest — a surface of X-shaped
    /// bosses rather than open cells. Zero is the old behaviour exactly.
    public static func cellField(occupancy occ: LatticeVoxelGrid, demand: LatticeVoxelGrid?,
                                 cellMM: Double, insideFraction: Double = 0.02,
                                 originShiftMM: SIMD3<Float> = .zero,
                                 memberThickness: [Double] = [],
                                 minCellsPerMember: Double = 0,
                                 // ★★ THE AESTHETIC FLOOR, PER OCCUPANCY VOXEL. Core's
                                 // aesthetic rule derives the floor from the measured
                                 // error curve and each voxel's OWN utilisation, so it
                                 // cannot be one scalar. Empty (or a non-positive
                                 // entry) falls back to `minCellsPerMember`, which is
                                 // the structural path bit-for-bit — see the
                                 // equivalence noted at the test below.
                                 cellsPerMemberFloor: [Double] = [],
                                 /// ★★★ THE CELL THE MEMBER FLOOR IS TESTED AGAINST.
                                 ///
                                 /// ★ THIS IS THE EMPTY BAND AT THE OUTLINE. The floor
                                 /// asks `thickness / cell >= N*`, and it was asked with
                                 /// the BASE cell — but a graded lattice may draw a much
                                 /// FINER cell right there, and a finer cell needs
                                 /// proportionally less material to clear the same floor.
                                 /// So cells the grade could easily have held were
                                 /// switched off before the grade ever ran, and grading
                                 /// only ever assigns sizes to cells that survived. The
                                 /// band that most needs fine cells is exactly the band
                                 /// that was deleted.
                                 ///
                                 /// 0 ⇒ test against `cellMM`, the historical behaviour.
                                 floorTestCellMM: Double = 0) -> LatticeVoxelGrid {
        let cell = Float(max(0.1, cellMM))
        let floorCell = Float(max(0.1, floorTestCellMM > 0 ? floorTestCellMM : cellMM))
        // ★ THE SHIFT MOVES THE WHOLE GRID — the cells it samples AND the origin it
        // reports — so activation and the march's tiling cannot disagree about where a
        // cell starts. It is at most one cell, and the extra cell below covers it.
        let gridOrigin = occ.origin - originShiftMM
        let extent = SIMD3<Float>(Float(occ.nx - 1) * occ.spacing.x,
                                  Float(occ.ny - 1) * occ.spacing.y,
                                  Float(occ.nz - 1) * occ.spacing.z)
        let ncx = Swift.max(1, Int(ceil(extent.x / cell)) + 2)
        let ncy = Swift.max(1, Int(ceil(extent.y / cell)) + 2)
        let ncz = Swift.max(1, Int(ceil(extent.z / cell)) + 2)
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
        // Returns the voxel's member thickness AND the floor that voxel is held to —
        // together, because the aesthetic floor varies per voxel and the two must be
        // read at the same place or a thin voxel gets paired with a loaded voxel's
        // floor.
        let perVoxelFloor = cellsPerMemberFloor.count == occ.values.count
                          ? cellsPerMemberFloor : []
        func memberAt(_ w: SIMD3<Float>) -> (thickness: Double, floor: Double)? {
            guard minCellsPerMember > 0, !memberThickness.isEmpty else { return nil }
            let g = (w - occ.origin) / occ.spacing
            let vi = Swift.min(Swift.max(Int(g.x.rounded()), 0), occ.nx - 1)
            let vj = Swift.min(Swift.max(Int(g.y.rounded()), 0), occ.ny - 1)
            let vk = Swift.min(Swift.max(Int(g.z.rounded()), 0), occ.nz - 1)
            let n = (vk * occ.ny + vj) * occ.nx + vi
            guard n >= 0, n < memberThickness.count else { return nil }
            // A non-positive per-voxel floor means core had no answer THERE; the
            // scene-wide floor stands rather than the voxel going unfloored.
            let f = !perVoxelFloor.isEmpty && perVoxelFloor[n] > 0
                  ? perVoxelFloor[n] : minCellsPerMember
            return (memberThickness[n], f)
        }

        let S = 4   // 4³ subsamples per cell
        for ck in 0..<ncz {
            for cj in 0..<ncy {
                for ci in 0..<ncx {
                    let center = gridOrigin + SIMD3<Float>(Float(ci), Float(cj), Float(ck)) * cell
                    var insideCount = 0
                    var demandSum: Float = 0
                    // ★ THE FLOOR IS DECIDED PER VOXEL, exactly as core decides it
                    // (`cpm = width[e] / cell; if (cpm < n_star) -> solid`): ANY voxel
                    // under the cell that cannot hold its OWN floor fails the cell.
                    // With a constant floor this is identical to the previous
                    // worst-thickness test — `min(t)/cell < N*` iff some `t/cell < N*`
                    // — so the structural path does not move. With a per-voxel floor it
                    // is the only formulation that pairs each thickness with the floor
                    // that actually applies to it.
                    var memberHoldsTheCell = true
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
                            // `+inf` is core's "thicker than measured" sentinel: it
                            // clears any floor, which is the conservative direction.
                            if let m = memberAt(w), m.thickness > 0, m.floor > 0,
                               m.thickness.isFinite,
                               m.thickness / Double(floorCell) < m.floor {
                                memberHoldsTheCell = false
                            }
                        }
                    } } }
                    let frac = Double(insideCount) / Double(S * S * S)
                    // ★★ CORE'S L4 FLOOR, APPLIED HERE TOO (task 2026-08-20). A member
                    // too thin to hold its floor in cells is left SOLID by the run;
                    // drawing lattice in it was the preview showing geometry that never
                    // gets built. Decided per voxel in the sample loop above.
                    if frac >= insideFraction, memberHoldsTheCell {
                        vals[(ck * ncy + cj) * ncx + ci] =
                            insideCount > 0 ? Swift.max(0, demandSum / Float(insideCount)) : 0
                    }
                }
            }
        }
        return LatticeVoxelGrid(nx: ncx, ny: ncy, nz: ncz, origin: gridOrigin,
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
    /// ★★★ STEPPED: the covering cell's size in mm, per base cell — 0 where this base
    /// cell is not in a stepped region. EMPTY on every other algorithm, which is what
    /// keeps doubled bit-identical.
    ///
    /// ★ WHY A SIZE AND NOT A LEVEL. `level` is a DYADIC exponent: the shader recovers
    /// the covering cell as `S0 · 2^L` and its index by integer division, and that
    /// encoding IS what doubled means. Stepped takes each region's derived cell
    /// VERBATIM — arbitrary reals like 5.31 mm — so no (base, level) pair expresses it,
    /// and that is the whole of why the preview could draw only one of core's three
    /// algorithms. The fix is not a second renderer: it is to stop insisting the size
    /// be dyadic. A real size per cell costs one more texture channel, and the frame
    /// the shader builds from it (`floor((p − origin)/S)`) is the same arithmetic with
    /// the power-of-two assumption removed.
    ///
    /// ★ THE SIZES ARE PRE-ROUNDED TO HALF PRECISION by the builder, because the
    /// texture is `rgba16Float` and a cell whose size differed in the last bit between
    /// the app and the shader would drift the tiling by a fraction of a millimetre per
    /// cell across the part.
    public let steppedCellMM: [Float]
    /// ★★★ STEPPED: WHERE THIS CELL'S TILING STARTS, packed as `axis + fraction`.
    ///
    /// ★ A SINGLE GRID ORIGIN CANNOT SERVE TWO FACES ON ONE AXIS. Struts are trimmed
    /// flush at a region's cap planes, and a cap through the middle of a cell slices every
    /// strut at its fattest — the quilt. Putting a face on a cell boundary is a shift of
    /// the tiling origin, and two declared faces normal to the SAME axis, with different
    /// cells and cap planes that are a whole number of neither, need two DIFFERENT
    /// shifts. Anchoring the one grid origin fixes one face and leaves the other exactly
    /// as mis-phased as before.
    ///
    /// ★ SO THE PHASE IS PER CELL, like the size beside it. `axis` (0/1/2) is the one the
    /// owning region's normal runs along and `fraction` is the shift in cells, in
    /// [0, 1) — so 2.25 means "a quarter of a cell along z". Both fit in the texture's
    /// spare `.a` channel: a half holds ~0.002 near 3, which is 0.014 mm of a 6.9 mm cell.
    /// EMPTY on every other algorithm, and 0 means no shift, which is the old behaviour.
    public let steppedPhase: [Float]
    public let baseCellMM: Double
    public let maxLevel: Int
    /// True when this came from core's plan rather than the uniform fallback — the
    /// preview says which, because "core had no plan" and "core planned one level"
    /// look identical in the picture and are not the same fact.
    public let fromCorePlan: Bool
}

extension LatticePreviewOccupancy {

    /// ★ A/B SWITCH, INSTRUMENTATION ONLY (2026-08-26). Set
    /// `TOPOPT_LATTICE_FIT_OFF=1` in the launch environment to restore the
    /// PRE-fix fit distance (the raw footprint max, which never fires), so the
    /// two behaviours can be compared on the DEVICE, from one binary, at one
    /// camera. Read once — the bake runs per frame and this must not cost a
    /// dictionary lookup per cell.
    static let fitCorrectionDisabled: Bool =
        ProcessInfo.processInfo.environment["TOPOPT_LATTICE_FIT_OFF"] == "1"

    /// The deepest rung the shape grade may take before it goes SOLID — the
    /// AESTHETIC cap, always tighter than the printability cap `nCap`.
    /// `TOPOPT_LATTICE_SHAPE_CAP` overrides it for on-device A/B.
    /// ★★★ HOW MANY CELLS DEEP THE GRADE'S SOLID TERMINUS RUNS (2026-08-27).
    ///
    /// 2 (the current behaviour): every cell the ladder cannot satisfy goes solid —
    /// the ring that straddles the outline PLUS the ring just inside it, whose fit
    /// demands a finer cell than the ladder may take. About two cells wide, ~10 mm on
    /// his part, and 124 of 256 cells on the small fixture
    /// `testASliverNoLongerPinsTheWholeFace` guards.
    ///
    /// 1: only the straddling ring goes solid — a cell whose CENTRE has no room inside
    /// the outline at all. Everything with a measurement keeps grading, capped, and
    /// draws struts. The border is half as deep and the interior keeps more of its own
    /// cell, which is the invariant that test exists to protect.
    ///
    /// `TOPOPT_LATTICE_SOLID_RING` selects, so both can be seen on the DEVICE at one
    /// camera instead of argued about.
    /// ★★★ HOW FAR THE LATTICE IS GENERATED **PAST** THE FACE'S OUTLINE, in cells,
    /// before the prism cuts it (his ruling, 2026-08-27: *"extend the lattices out
    /// beyond the face-prism, then use the prism to cut off the excess"*).
    ///
    /// ★ WHY A WHOLE CELL AND NOT A HALF. The march prefetches a 3x3x3 neighbourhood
    /// and a strut is only evaluated where its OWNING cell is active, so material just
    /// inside the outline needs the ring of cells just OUTSIDE it to exist and to carry
    /// the same size. Half a cell painted only the straddlers; a full cell paints the
    /// ring beyond them, which is the one that reaches back in.
    ///
    /// It costs nothing outside the face: `dClip` unions the region's own SDF, so a
    /// strut out here is trimmed flush at the outline exactly as it was before.
    static let overshootCells: Double = {
        if let raw = ProcessInfo.processInfo.environment["TOPOPT_LATTICE_OVERSHOOT"],
           let v = Double(raw), v >= 0 { return v }
        return 1.0
    }()

    /// ★★★ ONE RING, NOT TWO (2026-08-28) — and the old 2 was compensating for a
    /// predicate that only fired on a quarter of the boundary.
    ///
    /// While the terminus asked `n > ladderCap` against a BFS distance quantised to
    /// the 1.72 mm voxel, it caught 25% (face 2) and 32% (face 15) of outline points,
    /// scattered — his 2026-08-28 screenshot of purple lumps along both curves. Two
    /// rings of a quarter-firing test is less solid than one ring of a correct one, so
    /// the constant was tuned against the bug. With the exact outline distance in
    /// place, the numbers on his part are:
    ///
    ///     rings   gradedToSolid   outline points with a solid cell (face 2 / face 15)
    ///       1          875              96% / 84%
    ///       2         1643             100% / 89%      <- 49% of the wall, far too much
    ///
    /// One ring IS his rule — *"ONLY WHEN NO MORE CAN FIT can you make the rest
    /// solid"* — because one ring is exactly the set of cells the outline CUTS, which
    /// is the set that provably cannot hold a strut node.
    static let solidRingCells: Int = {
        if let raw = ProcessInfo.processInfo.environment["TOPOPT_LATTICE_SOLID_RING"],
           let v = Int(raw), v >= 1 { return v }
        return 1
    }()

    static let shapeLadderCap: Int = {
        if let raw = ProcessInfo.processInfo.environment["TOPOPT_LATTICE_SHAPE_CAP"],
           let v = Int(raw), v >= 1 { return v }
        // ★★★ NO AESTHETIC CAP WHEN THE SHAPE IS BEING FITTED (his ruling, 2026-08-27):
        // *"If 'Grade to fit' is set, then no. It needs to break into smaller cells
        // before it can become solid."*
        //
        // A cap of 3 truncated the ladder to ONE visible rung and sent everything the
        // fit still could not satisfy straight to solid — so the border came out two
        // cells of flat solid where he had asked for a grade. The printability cap
        // `nCap` is the real floor, and what will not fit even at the finest PRINTABLE
        // cell is the only thing that has earned the solid terminus. That is also his
        // 2026-08-23 wording: *"get to the point where the lattice is as small as is
        // printable and fill the rest with solid material."*
        //
        // Kept as a knob so the two can still be compared on the device.
        return Int.max
    }()

    /// The uniform field, wrapped — one level, everywhere, which is what a Fixed or
    /// Auto job actually builds.
    public static func uniformCellField(_ grid: LatticeVoxelGrid,
                                        cellMM: Double) -> LatticeCellField {
        LatticeCellField(field: grid,
                         level: [Float](repeating: 0, count: grid.count),
                         steppedCellMM: [], steppedPhase: [],
                         baseCellMM: cellMM, maxLevel: 0, fromCorePlan: false)
    }

    /// ★★★ STEPPED — ONE CELL PER DECLARED REGION, VERBATIM (core's `LatticeAlgorithm`).
    ///
    /// Core's definition is "`Fit` WITHOUT THE DYADIC SNAP": each region's cell is
    /// whatever `lattice_region_derivation` returned for that region's own measured
    /// member width, used as-is. The caller supplies those cells — from CORE's
    /// derivation, one entry per region in `regions` order — so nothing about the law
    /// is re-derived here; this only paints them onto the base grid.
    ///
    /// ★ THE GRID IS ANCHORED AT THE ONE LATTICE ORIGIN, NOT PER REGION. Every region
    /// tiles the same axes from the same point with its OWN size, so two abutting
    /// regions at 5 and 6 mm do not share nodes at their boundary. That is not a
    /// rendering compromise — it IS stepped, and core counts the cost of it as
    /// `LatticeSteppedStats::floating_ends` (measured: 4 of 5 abutting region pairs
    /// mechanically disconnected). A preview that quietly aligned them would be
    /// drawing doubled and calling it stepped.
    ///
    /// Returns nil when no region states a cell — the caller then keeps the ladder it
    /// already had rather than drawing an empty part.
    /// ★ HOW FAR THE SHAPE BAND'S SMOOTHING MAY SUBDIVIDE, on top of whatever the
    /// FIT itself demands. Three keeps a visible grade at the outline (S, S/2, S/3)
    /// without turning a face into fabric — see the ramp's own note.
    static let shapeBandMaxDivisor = 3

    /// ★★★ ONE PHASE RULE. The cap-flush tiling shift for ONE region at ONE cell
    /// size, as `axis + fraction` (see `LatticeCellField.steppedPhase`). This is
    /// the single implementation behind BOTH the per-region encoder
    /// (`LatticeSDFRenderer.faceTilingPhase`) and the per-cell write in the
    /// stepped bake — the 2026-08-25 quilt round was exactly these two speaking
    /// different units (the encoder measured in REGION cells, the shader shifted
    /// by the LOCAL cell), and two implementations is how they drift apart again.
    ///
    /// nil when the region has no axis-aligned face plane to anchor to; the
    /// caller then keeps whatever phase it already had.
    static func tilingPhase(region: LatticeRegionSpec, cellMM: Double,
                            origin: SIMD3<Float>) -> Float? {
        guard region.role == .include, region.kind == .face else { return nil }
        let n = simd_normalize(region.normal)
        guard simd_length(n) > 0.5, cellMM > 0 else { return nil }
        let a = abs(n)
        let axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2)
        guard a[axis] > 0.99 else { return nil }
        // The cap's coordinate along the grid's own axis — `dot(·, n)` is the
        // same number with `n[axis]`'s sign, which the flip below cancels.
        let s0 = simd_dot(region.origin - SIMD3<Double>(origin), n)
        let t = s0 / cellMM
        var frac = t - t.rounded(.down)                 // in [0, 1)
        if n[axis] < 0, frac != 0 { frac = 1 - frac }
        // ★ KEPT OFF THE INTEGER BOUNDARY — packed as `axis + fraction` into one
        // half channel, a fraction of 0.9995 packs as the NEXT axis with no
        // shift. A cap within a thousandth of a cell of a boundary IS on it.
        if frac > 0.999 || frac < 0.001 { frac = 0 }
        return Float(axis) + Float(frac)
    }

    public static func steppedCellField(occupancy occ: LatticeVoxelGrid,
                                        demand: LatticeVoxelGrid?,
                                        regions: [LatticeRegionSpec],
                                        cellMM: [Double],
                                        baseCellMM: Double,
                                        originShiftMM: SIMD3<Float> = .zero,
                                        /// Per region, packed `axis + fraction` — see
                                        /// `LatticeCellField.steppedPhase`. Empty ⇒ none.
                                        regionPhase: [Float] = [],
                                        memberThickness: [Double] = [],
                                        minCellsPerMember: Double = 0,
                                        cellsPerMemberFloor: [Double] = [],
                                        /// ★★★ GRADE TO FIT SHAPE, IN STEPPED. Distance
                                        /// from each voxel to the edge of the latticed
                                        /// region (`LatticeBoundaryDistance`). Empty ⇒
                                        /// one cell per region exactly as before, so
                                        /// every existing bake is byte-identical.
                                        boundaryDistancePerRegion: [[Double]?] = [],
                                        /// ★★★ THE WALL'S THICKNESS PER OCCUPANCY VOXEL,
                                        /// along each region's own normal (his ruling,
                                        /// 2026-08-24: "it should read the actual depth
                                        /// of that area. so preferably per voxel"). A
                                        /// cell whose own material is thinner than the
                                        /// region's cell divides down to what it holds,
                                        /// so one thin sliver no longer pins — or is
                                        /// pinned by — the rest of the face. Empty ⇒
                                        /// region cell everywhere, exactly as before.
                                        widthPerRegion: [[Double]?] = [],
                                        /// ★ THE RIM'S OWN DISTANCE — in-plane distance
                                        /// to the ATTACHED outline only (his rule,
                                        /// 2026-08-24: solid where a wall meets material
                                        /// — chamfers, wall-to-floor — never on edges
                                        /// open to the air; those are the finish's job).
                                        /// The FIT keeps reading the full outline via
                                        /// `boundaryDistancePerRegion` — a cell must fit
                                        /// the shape at open edges too. Empty ⇒ the rim
                                        /// reads the fit's field, exactly as before.
                                        rimDistancePerRegion: [[Double]?] = [],
                                        /// The finest cell the grading may fall to — the
                                        /// printable floor. 0 ⇒ no grading.
                                        finestCellMM: Double = 0,
                                        /// How many cells in from the outline the grade
                                        /// keeps stepping down. 0 ⇒ fit only.
                                        shapeFitBandMM: Double = 0,
                                        /// ★★★ THE DENSITY RISES WITH THE GRADE. A finer
                                        /// cell at a FIXED density is a thinner strut, so
                                        /// grading the cell down without touching the
                                        /// density draws struts the printer cannot lay —
                                        /// his 0.16 mm back wall. These let the bake lift
                                        /// each graded cell's density to whatever keeps
                                        /// one extrusion across its struts. 0 line width
                                        /// ⇒ inert, exactly as before.
                                        lineWidthMM: Double = 0,
                                        densityLo: Double = 0,
                                        densityHi: Double = 0,
                                        densityGamma: Double = 1,
                                        latticeID: String = "",
                                        /// ★ THE GRADING OPTIONS (2026-08-25).
                                        /// `shapeFit: false` ⇒ "No grade": the
                                        /// outline never subdivides a cell; the
                                        /// rim, the per-spot material rule and
                                        /// the printability lift all still run.
                                        shapeFit: Bool = true,
                                        /// ★ Dyadic stepping: every fit-shape
                                        /// division is a power of two, so each
                                        /// graded cell shares nodes with its
                                        /// parent. Default keeps the stepped
                                        /// integer divisors.
                                        dyadicSteps: Bool = false,
                                        /// ★ Per region: TRUE where `cellMM[r]`
                                        /// is the USER'S OWN number. A stated
                                        /// cell is honoured as stated — the
                                        /// per-spot rule only CAPS it at
                                        /// min(declared depth, local wall),
                                        /// never re-derives it.
                                        cellIsUserStated: [Bool] = [])
        -> LatticeCellField? {
        guard baseCellMM > 0, cellMM.count == regions.count,
              cellMM.contains(where: { $0 > 0 }) else { return nil }
        // The activation + demand the base grid already gets on the uniform path — the
        // cells-per-member and printability floors are applied there, once.
        let grid = cellField(occupancy: occ, demand: demand, cellMM: baseCellMM,
                             originShiftMM: originShiftMM,
                             memberThickness: memberThickness,
                             minCellsPerMember: minCellsPerMember,
                             cellsPerMemberFloor: cellsPerMemberFloor,
                             // ★ A CELL THE GRADE CAN SHRINK MUST NOT BE KILLED AT THE
                             // COARSE SIZE. Where grading is available the floor is
                             // tested at the finest cell it can reach; the per-voxel
                             // grading below then hands each survivor a size its own
                             // member really can hold.
                             floorTestCellMM: finestCellMM)
        // ★ HALF-REPRESENTABLE, so the shader's S is the app's S exactly. See the field.
        let sizes = cellMM.map { Double(halfRepresentable(Float($0))) }
        // ★★★ AND THE CELL **AS DERIVED**, FOR THE FIT ARITHMETIC ONLY — 2026-08-26,
        // and this was 26% of his wall.
        //
        // `halfRepresentable` rounds the region cell UP: his face 15 derives
        // 10.312240362167358 mm and stores 10.3125, a rise of 260 NANOMETRES. The
        // per-spot rule below then asks "does this cell fit the wall under it" — and
        // on this part the region cell IS the p50 of that wall, so the two are THE
        // SAME NUMBER and the most common wall value on the part reads as a
        // 1.0000252 overshoot. `ceil` answers that with 2, and the cell HALVES.
        // Measured: 34,271 of 66,838 wall voxels (51.3%) divided on that rounding,
        // producing 5.16 mm and 6.02 mm cells — exactly S/2, the one divisor stepped
        // may never produce (his rule, 2026-08-26: "any number but 1/2 is ok"), and
        // exactly the sizes his tap callouts kept reporting.
        //
        // The write below stays half-representable, so the shader's S is unchanged
        // and nothing about the encoding moves. Only the COMPARISON is done in the
        // precision the cell was derived at — which is not slack against the wall,
        // it is the number being compared with itself. Never-overshoot is untouched:
        // a wall genuinely thinner than its cell (the other 9.5%, closest ratio
        // 1.1667) still divides exactly as before.
        let exact = cellMM
        // ★★★ ONE WALL, ONE LATTICE (his 3:45 PM report, 2026-08-25: "a quilt
        // with open space where lattice is supposed to be"). Two include faces
        // declared on OPPOSITE sides of the same wall — his face 15 (front,
        // 12 mm) and face 2 (the inner curve, 13 mm, normal anti-parallel) —
        // carve overlapping slabs, and every cell whose centre slipped past the
        // first region's declared depth was claimed by the SECOND: a second
        // lattice at a different size, anchor and phase, interleaved with the
        // first. The tap callout named it — a 13.00 mm cell standing in face
        // 15's wall. Such a pair is ONE wall: the later region keeps its own
        // OUTLINE (its curve still grades and rims), but inherits the earlier
        // one's cell size, declared depth, stated flag and tiling anchor, so
        // the shared material carries one coherent lattice and both mouths
        // land flush through the per-spot rule.
        var primary = Array(0..<regions.count)
        for r in 0..<regions.count where regions[r].role == .include
            && regions[r].kind == .face {
            let nr = LatticeRegionMask.unit(regions[r].normal)
            guard simd_length(nr) > 0.5 else { continue }
            for q in 0..<r where regions[q].role == .include
                && regions[q].kind == .face && primary[q] == q {
                let nq = LatticeRegionMask.unit(regions[q].normal)
                guard simd_dot(nr, nq) < -0.99 else { continue }
                // Overlap along the shared axis: r's slab reaches back through
                // q's ([sOnQ − depth_r, sOnQ] against q's [0, depth_q]).
                let sOnQ = simd_dot(regions[r].origin - regions[q].origin, nq)
                if sOnQ > -1e-6, sOnQ - regions[r].depthMM < regions[q].depthMM + 1e-6 {
                    primary[r] = q
                    break
                }
            }
        }
        var stepped = [Float](repeating: 0, count: grid.count)
        var phase = [Float](repeating: 0, count: grid.count)
        // A copy of the activation, so a cell the outline cannot hold at any printable
        // size can be turned OFF here and left as solid material.
        var activation = grid.values
        /// ★ ANY PART MATERIAL WITHIN HALF A BASE CELL OF THIS BASE CELL'S CENTRE.
        /// The occupancy grid is much finer than the cell grid (1.72 mm against 5–12 mm
        /// on his part), so this asks "does the cell overlap the part at all", which is
        /// the question `grid.values[i] >= 0` was standing in for and getting wrong
        /// wherever the boundary curves.
        func occupancyNear(_ x: Int, _ j: Int, _ k: Int) -> Bool {
            let p = SIMD3<Float>(
                grid.origin.x + Float(x) * grid.spacing.x,
                grid.origin.y + Float(j) * grid.spacing.y,
                grid.origin.z + Float(k) * grid.spacing.z)
            let g = (p - occ.origin) / occ.spacing
            let half = SIMD3<Int>(
                Int((grid.spacing.x * 0.5 / occ.spacing.x).rounded(.up)),
                Int((grid.spacing.y * 0.5 / occ.spacing.y).rounded(.up)),
                Int((grid.spacing.z * 0.5 / occ.spacing.z).rounded(.up)))
            let c0 = SIMD3<Int>(Int(g.x.rounded()), Int(g.y.rounded()), Int(g.z.rounded()))
            for dz in -half.z...half.z {
                let c = c0.z + dz
                guard c >= 0, c < occ.nz else { continue }
                for dy in -half.y...half.y {
                    let b = c0.y + dy
                    guard b >= 0, b < occ.ny else { continue }
                    for dx in -half.x...half.x {
                        let a = c0.x + dx
                        guard a >= 0, a < occ.nx else { continue }
                        if occ.values[(c * occ.ny + b) * occ.nx + a] > 0.5 { return true }
                    }
                }
            }
            return false
        }
        /// The boundary distance at a WORLD point, read off the occupancy grid it was
        /// measured on. 0 (⇒ no ceiling, no grading) outside it.
        /// ★★★ THE BEST FIT ANYWHERE IN THE CELL, not the value under its centre.
        ///
        /// ★ THE CENTRE SAMPLE IS AN ARTEFACT AND IT WAS A BIG ONE. The cell grid is as
        /// coarse as the cell (6 mm) while the distance field is on the occupancy grid
        /// (1.72 mm), and the wall is 11 mm thick — so a cell straddling the face very
        /// often has its centre in NO candidate voxel at all and reads distance 0. That
        /// is a sampling miss, not "nothing fits here": it put 503 of 964 cells at the
        /// printable floor (and, before that, turned them solid outright).
        ///
        /// Taking the MAX over the occupancy voxels the cell covers asks the question
        /// that is actually being asked — how much room is there in this cell — and it
        /// degrades gracefully, because a cell genuinely outside the material still
        /// reports 0.
        func boundaryAt(_ w: SIMD3<Double>, _ r: Int, cellMM: Double) -> Double {
            guard r < boundaryDistancePerRegion.count,
                  let field = boundaryDistancePerRegion[r] else { return 0 }
            let g = (SIMD3<Float>(w) - occ.origin) / occ.spacing
            let half = SIMD3<Int>(
                Int((Float(cellMM) * 0.5 / occ.spacing.x).rounded(.up)),
                Int((Float(cellMM) * 0.5 / occ.spacing.y).rounded(.up)),
                Int((Float(cellMM) * 0.5 / occ.spacing.z).rounded(.up)))
            let c0 = SIMD3<Int>(Int(g.x.rounded()), Int(g.y.rounded()), Int(g.z.rounded()))
            var best = 0.0
            for dz in -half.z...half.z {
                let c = c0.z + dz
                guard c >= 0, c < occ.nz else { continue }
                for dy in -half.y...half.y {
                    let b = c0.y + dy
                    guard b >= 0, b < occ.ny else { continue }
                    for dx in -half.x...half.x {
                        let a = c0.x + dx
                        guard a >= 0, a < occ.nx else { continue }
                        let idx = (c * occ.ny + b) * occ.nx + a
                        if idx < field.count, field[idx] > best { best = field[idx] }
                    }
                }
            }
            return best
        }
        /// The in-plane distance AT THE CELL'S OWN CENTRE.
        ///
        /// ★ TWO QUESTIONS, TWO SAMPLES. `boundaryAt` takes the MAX over the cell — the
        /// best fit available anywhere in it — which is the right optimism for "how fine
        /// must this cell be": it refuses to shrink a cell on the strength of one corner
        /// poking out. The SOLID test is the opposite question — "can anything at all
        /// live here" — and the max answers it far too generously: on his part the max
        /// never drops below 1.72 mm, so no cell would ever be solid however close to
        /// the outline it sits.
        ///
        /// 0 means the centre has no measurement (outside the latticed material), and
        /// that is NOT taken as "solid": a coarse cell straddling a thin wall reads 0 at
        /// its centre from the DEPTH, and solidifying on it is what turned 503 of 964
        /// cells solid on the first attempt.
        /// The FIT's own in-plane distance at the cell's centre — the same field
        /// `boundaryAt` maxes over, sampled honestly at one point. Distinct from
        /// `boundaryAtCentre`, which prefers the RIM field when the caller split one
        /// out; the rim's BFS is seeded only from attached material, so it carries an
        /// unreachable sentinel wherever nothing is attached and must never reach the
        /// fit. 0 means "no measurement here", exactly as it does everywhere else.
        func fitAtCentre(_ w: SIMD3<Double>, _ r: Int) -> Double {
            guard r < boundaryDistancePerRegion.count,
                  let field = boundaryDistancePerRegion[r] else { return 0 }
            let g = (SIMD3<Float>(w) - occ.origin) / occ.spacing
            let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
            guard a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz else { return 0 }
            let idx = (c * occ.ny + b) * occ.nx + a
            return idx < field.count ? field[idx] : 0
        }
        func boundaryAtCentre(_ w: SIMD3<Double>, _ r: Int) -> Double {
            // The RIM's field when the caller split it out (attached edges only);
            // the fit's field otherwise — one lookup, two possible sources.
            let source = !rimDistancePerRegion.isEmpty
                ? rimDistancePerRegion : boundaryDistancePerRegion
            guard r < source.count, let field = source[r] else { return 0 }
            let g = (SIMD3<Float>(w) - occ.origin) / occ.spacing
            let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
            guard a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz else { return 0 }
            let idx = (c * occ.ny + b) * occ.nx + a
            return idx < field.count ? field[idx] : 0
        }
        /// ★ THE WALL AT THE CELL'S OWN CENTRE — where the cell SITS — with the min
        /// over its footprint only as the fallback when the centre has no
        /// measurement (a cell straddling the outline).
        ///
        /// ★★ NOT THE FOOTPRINT MINIMUM FIRST. Under the never-overshoot ceil
        /// (2026-08-24 evening) the min turned one thin voxel anywhere within a
        /// cell's reach into a divided cell: measured on his face 2, 140 of 150
        /// cells divided, because near a curved outline the along-normal walk
        /// legitimately shortens and every cell's footprint touches SOME short
        /// read. The centre is where the cell is; the fit near the outline is the
        /// SHAPE grade's job, which already handles it with its own distance.
        func widthUnderCell(_ w: SIMD3<Double>, _ r: Int, cellMM: Double) -> Double {
            guard r < widthPerRegion.count, let field = widthPerRegion[r] else { return 0 }
            let g = (SIMD3<Float>(w) - occ.origin) / occ.spacing
            let c0 = SIMD3<Int>(Int(g.x.rounded()), Int(g.y.rounded()), Int(g.z.rounded()))
            guard c0.x >= 0, c0.x < occ.nx, c0.y >= 0, c0.y < occ.ny,
                  c0.z >= 0, c0.z < occ.nz else { return 0 }
            let idx = (c0.z * occ.ny + c0.y) * occ.nx + c0.x
            guard idx < field.count, field[idx] > 0 else { return 0 }
            // ★ NO MEASUREMENT AT THE CENTRE ⇒ NO CONSTRAINT — the same rule
            // `boundaryAtCentre` already lives by ("0 means no measurement, and
            // that is NOT taken as solid"). A footprint-MIN fallback here read
            // "thin" for every cell straddling a curved surface — on his face 15,
            // ALL of them — and divided a wall that holds its cell everywhere.
            // Outline-straddling cells belong to the SHAPE fit, which has its own
            // distance; the width rule constrains only where the wall under the
            // cell's own centre was actually measured.
            return field[idx]
        }
        /// The stage's cells-per-member floor AT this voxel — the per-voxel override
        /// when the scene carries one, the scene floor otherwise, and never below 1:
        /// whatever the accuracy question, a cell larger than its own wall is
        /// geometric nonsense, so 1 is the floor's floor.
        func memberFloorAt(_ w: SIMD3<Double>) -> Double {
            var f = minCellsPerMember
            if !cellsPerMemberFloor.isEmpty {
                let g = (SIMD3<Float>(w) - occ.origin) / occ.spacing
                let a = Int(g.x.rounded()), b = Int(g.y.rounded()), c = Int(g.z.rounded())
                if a >= 0, a < occ.nx, b >= 0, b < occ.ny, c >= 0, c < occ.nz {
                    let idx = (c * occ.ny + b) * occ.nx + a
                    if idx < cellsPerMemberFloor.count, cellsPerMemberFloor[idx] > 0 {
                        f = cellsPerMemberFloor[idx]
                    }
                }
            }
            return Swift.max(1, f)
        }
        var painted = 0
        var i = 0
        // Instrumentation for the grade audit: what `d` and `n` actually came out as.
        var dbgD: [Double] = []
        var dbgN: [Int: Int] = [:]
        var dbgSkipped = 0
        // ★ HOW MANY CELLS THE GRADE TERMINATES IN **SOLID** — the last rung of his
        // rule. Distinct from `solidRim`, which counts cells whose CENTRE is within a
        // voxel of the outline; this counts the ones whose fit demanded finer than the
        // ladder may go, which is what actually writes the 0 marker.
        var dbgSolid = 0
        var solidRim = 0
        var dbgCentre: [Double] = []
        var dbgW: [Double] = []
        var dbgWidthShrunk = 0
        // The g channel on the stepped path: mm to the face's outline. See the shader.
        var outline = [Float](repeating: 0, count: grid.count)
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for x in 0..<grid.nx {
                    // ★★★ A CELL IS PAINTABLE IF IT **OVERLAPS** THE MATERIAL, NOT ONLY
                    // IF ITS CENTRE SITS ON IT (2026-08-27, his diagnosis).
                    //
                    //   "Basically, the issue is curves. And curves are a problem due to
                    //    resolution. So you need to extend the lattices out *beyond* the
                    //    face-prism, then use the prism to cut off the excess."
                    //
                    // ★ THE OCCUPANCY GATE WAS THE ONE THAT BOUND. `grid.values[i]` is
                    // −1 wherever the base cell's CENTRE misses the part, so along a
                    // CURVED outline — where a straight cell grid necessarily straddles
                    // the boundary — the outermost cells were skipped entirely and
                    // emitted nothing. That is the row of holes down the sides, and it
                    // is why widening the REGION's ownership alone changed almost
                    // nothing (6,288 pixels of 2.4 M): the region let those cells
                    // through and the occupancy still refused them.
                    //
                    // Overlap is the honest test, and it is safe by construction: the
                    // march's `dClip` unions the part SDF and the region's own field, so
                    // a strut out here is trimmed flush at both. Extend, then cut.
                    //
                    // An overlapping cell with no demand of its own takes 0 — active,
                    // no stress demand — rather than the −1 that means "the run leaves
                    // this solid", which would have hidden it behind the solid branch.
                    let centreHasMaterial = grid.values[i] >= 0
                    let overlapsMaterial = centreHasMaterial
                        || occupancyNear(x, j, k)
                    if overlapsMaterial {
                        if !centreHasMaterial { activation[i] = 0 }
                        let p = SIMD3<Double>(
                            Double(grid.origin.x) + Double(x) * Double(grid.spacing.x),
                            Double(grid.origin.y) + Double(j) * Double(grid.spacing.y),
                            Double(grid.origin.z) + Double(k) * Double(grid.spacing.z))
                        // First match wins — the same rule the density demand uses, so
                        // an overlap resolves the same way in both.
                        // ★★★ OWNERSHIP REACHES HALF THIS REGION'S CELL PAST THE
                        // OUTLINE (2026-08-27) — see `LatticeRegionMask.contains(_:
                        // region:inPlaneReachMM:)` for the whole argument. A base cell
                        // whose CENTRE fell just outside was owned by nobody and emitted
                        // nothing, leaving a band up to half a cell wide with no struts:
                        // the "empty areas just at the ends". Half the cell is exactly
                        // the condition for the cell to still overlap the face, and the
                        // march's `dClip` cuts whatever it draws flush at the true
                        // outline — so this can only ADD material inside what he
                        // declared, never place any outside it.
                        for (r, region) in regions.enumerated()
                        where region.role == .include && sizes[r] > 0
                              && LatticeRegionMask.contains(
                                    p, region: region,
                                    inPlaneReachMM: Self.overshootCells * sizes[r]) {
                            // ★★★ THE REGION'S CELL, DIVIDED A WHOLE NUMBER OF TIMES
                            // TOWARD ITS OWN EDGE — S/2, S/3, S/4, …
                            //
                            // ★ NOT DYADIC (maintainer, 2026-08-23: *"Why dyadic?
                            // Shouldn't it just change to *any* number?"*). He is right
                            // that halving is too strong, and the first cut of this was
                            // wrong to use it. The dyadic rule belongs to core's OCTREE
                            // ladder, where 2:1 balance is a property of the octree
                            // itself. Nothing here builds an octree — this picks a cell
                            // per voxel — so the only rule that actually binds is the
                            // one below, and it admits every integer divisor. That is a
                            // far smoother gradient: S, S/2, S/3, S/4 instead of S, S/2,
                            // S/4, S/8.
                            //
                            // ★ WHY NOT *ANY REAL NUMBER*, THOUGH — and this is the one
                            // constraint that is real. The cap planes are only flush
                            // because every cell in the region divides the declared depth
                            // a whole number of times at the region's own phase; that is
                            // what killed the quilt. S/n keeps every graded cell on that
                            // same grid — the coarse nodes at multiples of S are still
                            // nodes of the S/n grid — so the caps stay flush and the
                            // grading costs nothing. An arbitrary real does not divide
                            // the depth, so it walks the caps back off the boundary and
                            // brings the quilt back with it.
                            //
                            // ★ AND IT IS HONEST ABOUT WHAT IT STILL COSTS. Two
                            // neighbouring zones at S/2 and S/3 share only the coarse
                            // S-nodes, so a transition between them leaves unshared nodes
                            // — floating strut ends. Stepped is the algorithm that
                            // declares it does no transition handling and COUNTS them
                            // (`LatticeSteppedStats::floating_ends`), so this is inside
                            // its stated contract rather than a defect hidden in it.
                            //
                            // ★ AND IT STOPS AT THE PRINTABLE FLOOR rather than at the
                            // edge. A cell finer than `finestCellMM` has struts thinner
                            // than a bead, so the division stops and the rim keeps the
                            // finest cell that can actually be built.
                            // ★★★ FILL THE FACE BY FITTING CELLS TO IT, largest first
                            // (his spec, 2026-08-23: *"the OUTLINE needs to create
                            // smaller and smaller cells to create finer and finer
                            // resolution for the arcs and straight lines required to FIT
                            // THE SHAPE OF THE FACE. We want the lattice to fill the
                            // space that was REMOVED from the model."*).
                            //
                            // ★ IT IS A FILL, NOT A RAMP. The cell shrinks because it
                            // does not FIT, not because of where it happens to be — so
                            // the interior keeps the biggest cell and only the outline
                            // pays. The ramp I invented before this graded the whole face
                            // off a number with no physical meaning and threw away the
                            // member-derived cell over half the wall.
                            //
                            //   n_fit  the fewest whole divisions that fit inside the
                            //          outline: a cell of side S/n needs S/2n of room,
                            //          so n ≥ S / 2d.
                            //   +1     one further level inside a band one cell wide, so
                            //          the grade reads as deliberate instead of only
                            //          where the geometry forces it (his "Both — fit
                            //          first, then smooth").
                            //   never  n == 2 — the step is "at least by 1/3".
                            //   cap    S/n ≥ the finest printable cell.
                            //
                            // ★ AND WHAT STILL WILL NOT FIT GOES **SOLID**, which is the
                            // other half of his rule: "get to the point where the lattice
                            // is as small as is printable and fill the rest with solid
                            // material". Marked by deactivating the cell (−1), the same
                            // marker the member floor already uses.
                            // ★ THE PAIR'S PRIMARY (see `primary` above): the
                            // wall's one cell law. `r` keeps its own outline
                            // and rim fields below.
                            let prime = primary[r]
                            let primeRegion = regions[prime]
                            // ★ THE DERIVED CELL, NOT THE HALF-ROUNDED ONE — see
                            // `exact` above. What is WRITTEN is still half.
                            var s = exact[prime]
                            // ★★★ HIS RULING (2026-08-25, closing the far-cap
                            // conflict): "per-spot cell = min(prism depth, local
                            // material depth), both directions, stepped algorithm
                            // only — Default's dyadic rule untouched."
                            //
                            // The region's stated cell is the MEDIAN wall's fit;
                            // each cell now re-fits to ITS OWN material. Thinner
                            // wall → smaller cell (never overshoot, as before);
                            // thicker wall → the cell GROWS to span it (his corner
                            // rule: "a corner that truly measures 15 gets 15"),
                            // capped at the declared depth. Divided by the
                            // per-voxel cells-per-member floor so a structural
                            // member still holds its count. The far cut is then
                            // flush BY CONSTRUCTION: where the wall is thinner
                            // than the declaration, the material's own back face
                            // is the last cell boundary; where it is thicker, the
                            // declared cap plane is — which closes the 0.97 mm /
                            // 1.70 mm sliced band the cap probe measured at the
                            // back of BOTH his faces. An unmeasured centre keeps
                            // the region's cell (his ruling: unmeasured is
                            // unconstrained).
                            let stated = prime < cellIsUserStated.count
                                && cellIsUserStated[prime]
                            let wLocal = widthUnderCell(p, r, cellMM: s)
                            if wLocal > 1e-6 {
                                let declared = primeRegion.depthMM > 0
                                    ? primeRegion.depthMM : wLocal
                                // ★ A USER-STATED CELL IS HONOURED AS STATED
                                // (2026-08-25, the grading options): the
                                // per-spot rule only CAPS it — never-overshoot
                                // is a ruling, a typed number is not a licence
                                // past the wall — and never divides it by the
                                // floor: the number typed is the cell meant.
                                let target = stated
                                    ? Swift.min(s, Swift.min(declared, wLocal))
                                    : Swift.min(declared, wLocal) / memberFloorAt(p)
                                // ★★★ ONLY WHOLE-NUMBER DIVISIONS OF THE REGION'S
                                // CELL (his 2026-08-25 close-up: struts in pieces,
                                // cut on flat planes with no nodes joining them —
                                // IDENTICAL at 64³ and 128³, so not sampling).
                                //
                                // Two cells share nodes only when one size divides
                                // the other a whole number of times. The first cut
                                // of his per-spot ruling took each cell's own
                                // material VERBATIM, so a wall carried 12.00 beside
                                // 13.00 beside 10.31 — tilings that can never meet,
                                // and the march cuts every strut that crosses
                                // between them. Measured on his own two faces
                                // (`LatticeNeighbourMeshProbe`): 13 distinct sizes
                                // and 15.7% of neighbour boundaries unable to mesh,
                                // against 0.5% with the rule off.
                                //
                                // ★★★ SUPERSEDED 2026-08-26 — THE S/n QUANTISATION
                                // **WAS** THE QUILT, AND HE RESTATED THE RULE:
                                //
                                //   "single-cell/member means make the largest
                                //    single cell across the entire model — per
                                //    voxel. So this will change based on the
                                //    thickness of the area it's in. If the area is
                                //    13 mm, the cell is 13 mm; if the area next to
                                //    it is 12 mm, the cell next to it is 12 mm."
                                //
                                // The rule that stood here divided the REGION's
                                // cell by a whole number, so a wall measuring
                                // 10.31 mm under a 12.03 mm region cell could not
                                // be given a 10.31 mm cell — the nearest permitted
                                // size was 6.02 mm, HALF the wall. Measured on his
                                // own part: 181 of 528 cells landed at exactly S/2
                                // (5.16 and 6.02 mm), which is also the one divisor
                                // stepped may never produce ("any number but 1/2 is
                                // ok"). A wall carrying S beside S/2 beside S/3
                                // beside S/6 is the fabric he has been calling the
                                // quilt, and no density or resolution setting could
                                // ever have touched it.
                                //
                                // The cell now IS the material under it, capped at
                                // the declared depth (his 2026-08-26 note: the
                                // face-prism "only makes what's solid into lattice,
                                // it cannot make walls thicker") and divided by the
                                // cells-per-member floor, which is 1 under
                                // single-cell and 2 otherwise.
                                //
                                // ★ NEVER-OVERSHOOT (§8) IS SATISFIED BY
                                // CONSTRUCTION, more strictly than before:
                                // `s = min(declared, wall) / floor <= wall`, with
                                // no epsilon and no slack anywhere.
                                //
                                // ★ AND THE SPREAD OF SIZES IS SMALL, not the 13
                                // that `14e5eca3` measured. The wall field is a
                                // walk in whole occupancy voxels, so it only takes
                                // values k·h — on his part {10.31, 12.03, 13.75} —
                                // and the declared cap collapses those to two or
                                // three cells per region, each following real
                                // material rather than an arithmetic ladder.
                                if target > 1e-6, abs(target - s) > 1e-9 {
                                    s = target
                                    dbgWidthShrunk += 1
                                }
                                dbgW.append(wLocal)
                            }
                            if boundaryDistancePerRegion.isEmpty || finestCellMM <= 0 {
                                dbgSkipped += 1
                            }
                            if !boundaryDistancePerRegion.isEmpty, finestCellMM > 0 {
                                // ★★★ THE FOOTPRINT'S OWN HALF-EXTENT COMES BACK OFF —
                                // and this is the EMPTY SPACE at the wall's edge.
                                //
                                // `boundaryAt` takes the MAX over the occupancy voxels
                                // the cell covers, and it is right to: the centre alone
                                // often lands in no candidate voxel and reads 0, which
                                // is a sampling miss, not "nothing fits here". But a max
                                // over a box of half-width h on a locally linear
                                // distance field is `d_centre + h`, so the number handed
                                // to the FIT and the BAND is offset by half the cell's
                                // footprint.
                                //
                                // Measured on his part: `d[min = 6.87]` against
                                // `dCentre[min = 1.72]`, and the footprint half-extent
                                // for a 10.31 mm cell on a 1.72 mm grid is exactly
                                // 3 voxels = 5.16 mm. 1.72 + 5.16 = 6.88. The offset is
                                // not approximately the half-extent, it IS the
                                // half-extent.
                                //
                                // ★ WHAT IT COST. `n_fit = ceil(s / 2d)` needs
                                // `s > 2d` to fire at all, and with `d >= 6.87` and
                                // `s <= 12` that is `s/2d <= 0.87` — so the FIT TERM
                                // NEVER FIRED ANYWHERE ON THE PART. The cells at the
                                // face's edge stayed full size, and a full-size cell
                                // centred 1.72 mm from the outline has almost all of
                                // itself outside the region, so `dClip` cut its struts
                                // away and left a BARE BAND up to half a cell wide
                                // between the last node and the chamfer. That band is
                                // the "empty space" at the wall's edge, and it is the
                                // very thing "grade to shape" exists to fill:
                                // *"as it gets closer, it is graded more and more, until
                                // it becomes a solid and connects the sides"*.
                                //
                                // Subtracting the half-extent restores a distance that
                                // reaches 0 at the outline while keeping the max's
                                // robustness against the sampling miss. Never below the
                                // FIT's own centre reading where one exists — the max is
                                // an over-estimate, so the correction must not fall
                                // under the honest sample.
                                //
                                // ★ AND IT READS THE **FIT'S OWN** FIELD AT THE CENTRE,
                                // not `boundaryAtCentre` — that one prefers the RIM
                                // field (attached edges only), whose BFS leaves an
                                // unreachable sentinel wherever nothing is attached.
                                // Mixing them put 1e6 into `d`. Two fields, two
                                // questions; never cross them.
                                let voxelH = Double(Swift.max(occ.spacing.x,
                                    Swift.max(occ.spacing.y, occ.spacing.z)))
                                let halfExtent = voxelH
                                    * (s * 0.5 / voxelH).rounded(.up)
                                let dRaw = boundaryAt(p, r, cellMM: s)
                                let dFitCentre = fitAtCentre(p, r)
                                // ★ A/B SWITCH, INSTRUMENTATION ONLY (2026-08-26).
                                // `TOPOPT_LATTICE_FIT_OFF=1` restores the PRE-fix
                                // distance so the two behaviours can be compared on the
                                // DEVICE from one binary, at one camera. Judging a
                                // render of mine against a memory of his screen is how
                                // the last regression shipped.
                                let d = dRaw > 0
                                    ? (Self.fitCorrectionDisabled
                                       ? dRaw
                                       : Swift.max(dFitCentre, Swift.max(0, dRaw - halfExtent)))
                                    : 0
                                dbgD.append(d)
                                // ★★★ THE HALF-FLOAT ROUNDING WAS EATING A WHOLE RUNG.
                                //
                                // `sizes[r]` is `halfRepresentable(...)` — the cell the
                                // SHADER can hold exactly — so a 4.3333 mm cell arrives
                                // here as 4.332. Against an unrounded 2.16667 floor that
                                // is 1.99938, and `.rounded(.down)` makes it 1: no
                                // subdivision permitted, `levels` collapses to 0, and n
                                // is 1 for every cell on the face. The DIAGNOSTIC
                                // computed the same ratio from the UNROUNDED cell and
                                // printed 2, so the log and the bake disagreed and the
                                // band looked inert for no visible reason.
                                //
                                // A relative epsilon is the fix, not a fudge: the two
                                // numbers describe the same ladder and differ only by
                                // one half-float step.
                                // ★ A RELATIVE TOLERANCE, SIZED TO HALF PRECISION. An
                                // absolute 1e-4 was too small — the actual gap on his
                                // 4.3333 mm cell is 6.2e-4, so the rung stayed lost. A
                                // half's relative precision is ~2^-11 (4.9e-4), and 2e-3
                                // clears that with room while being three orders below a
                                // real rung ratio, so it can never invent a rung.
                                let nCap = Swift.max(1, Int((s / finestCellMM * (1 + 2e-3)).rounded(.down)))
                                // ★ NO MEASUREMENT AT THE CENTRE ⇒ TAKE THE FINEST
                                // PRINTABLE CELL, NOT SOLID. The cell grid is coarse
                                // (6 mm) against a 1.72 mm occupancy grid, so a cell that
                                // straddles the outline often has its CENTRE outside the
                                // candidate set — that is a sampling artefact, not a
                                // statement that nothing fits. Solidifying on it turned
                                // 503 of 964 cells to solid and emptied the very band he
                                // wants filled.
                                // ★ "NO GRADE" (2026-08-25): the fit never
                                // subdivides — n stays 1 and only the outline
                                // rim, the per-spot material rule and the
                                // printability checks below apply.
                                // ★★★ IS THIS CELL'S CENTRE ACTUALLY INSIDE THE FACE?
                                // The ownership test above reaches PAST the outline on
                                // purpose; this is the strict question, and the two must
                                // not be confused.
                                let centreInside = LatticeRegionMask.contains(p, region: region)
                                var n = 1
                                if shapeFit {
                                    // ★★★ THE OVERSHOOT RING IS NOT GRADED — IT IS CUT
                                    // (his ruling, 2026-08-27):
                                    //
                                    //   "the issue is curves. And curves are a problem due
                                    //    to resolution. So for stress grade alone, you need
                                    //    to extend the lattices out *beyond* the face-prism,
                                    //    then use the prism to cut off the excess."
                                    //
                                    // ★ AND SUBDIVIDING IT BROKE THE JOIN. A cell whose
                                    // centre falls outside the outline has no fit distance,
                                    // and the `: nCap` branch below read that as "no room —
                                    // take the finest printable cell". So the ring just
                                    // outside carried 1.29 mm while the wall inside carried
                                    // 5.16, and the march's `sameLattice` test — which on
                                    // the stepped path compares CELL SIZE — rejected it as
                                    // a different lattice. Its struts were never evaluated
                                    // in the neighbourhood of the cells inside, so the
                                    // material at the outline lost the contribution that
                                    // should have reached it from beyond, and what did draw
                                    // had nothing to join to. That is his
                                    // "lattices with single-cell members that don't fully
                                    // connect... that's not physically possible."
                                    //
                                    // Keeping the region's own cell out here is what makes
                                    // the overshoot MESH with the interior; `dClip` then
                                    // trims it flush at the prism, which is the "cut off
                                    // the excess" half of the same sentence.
                                    if !centreInside {
                                        n = 1
                                    } else {
                                        n = d > 1e-6
                                            ? Swift.max(1, Int((s / (2 * d)).rounded(.up)))
                                            : nCap
                                    }
                                }
                                // Smooth: one more level while still inside a band one
                                // fitted cell wide of the outline.
                                // ★★★ THE BAND IS A RAMP INSIDE ITSELF, NOT A FLAG.
                                //
                                // ★ THE FIRST CUT STEPPED DOWN ANYWHERE INSIDE THE BAND,
                                // so a 4-cell band with a 3.6 mm cell caught everything
                                // within 14 mm of the outline — which on his wall is the
                                // WHOLE wall. Every cell went to the floor at once: not
                                // a gradient, just a uniformly finer lattice, and the
                                // "main cells as large as possible" rule broken.
                                //
                                // Inside the band the divisor ramps from the finest
                                // printable at the outline to 1 at the band's inner edge,
                                // so the grade is visible AND confined to the band he set.
                                if shapeFit, shapeFitBandMM > 0 {
                                    // ★★★ THE BAND IS A DISTANCE IN MILLIMETRES (his
                                    // ruling, 2026-08-23), and it is measured that way
                                    // because BOTH cell-counted readings failed on his
                                    // own face and for opposite reasons:
                                    //
                                    //   band x BASE cell   4 x 6.0  = 24 mm -> the fine
                                    //     cells took the space the 6 mm cells should
                                    //     have had, on a face only ~38 mm deep.
                                    //   band x FINEST cell 4 x 1.5  =  6 mm -> a border
                                    //     3% of the face; reads as no grade at all.
                                    //
                                    // A millimetre cannot drift when the cell changes,
                                    // and it is the only reading he can dial to what he
                                    // can actually see.
                                    let reach = shapeFitBandMM
                                    if d < reach {
                                        let t = Swift.max(0, Swift.min(1, d / reach))
                                        // ★★★ THE WHOLE BAND STEPS DOWN, NOT HALF OF IT.
                                        //
                                        // ★ ROUNDING THE RAMP THREW AWAY MOST OF THE BAND
                                        // WHENEVER THERE WERE FEW LEVELS. With `nCap = 2`
                                        // — which is what his printer and density band
                                        // actually allow — `round(2 - t)` only reaches 2
                                        // while t <= 0.5, so a 10 mm band graded 5 mm and
                                        // touched 4.6% of the face. Every tap landed on
                                        // the base cell and it read as no grade at all.
                                        //
                                        // `ceil` over the levels ABOVE the base instead:
                                        // at the outline it is `nCap`, and it stays >= 2
                                        // right up to the band's inner edge, returning to
                                        // the full cell only OUTSIDE the band. That is
                                        // what "a band N mm wide" has to mean.
                                        // ★★★ THE BAND SMOOTHS; IT DOES NOT DRIVE TO
                                        // THE FLOOR (his 2026-08-25 tap: a 12.03 mm
                                        // region cell reading 2.01 mm — S/6 — with a
                                        // 0.45 mm strut, one bead, over most of the
                                        // face. That is the quilt: a correctly meshed
                                        // lattice subdivided into bead-thin threads).
                                        //
                                        // ★ THE RAMP RAN TO `nCap`, the FINEST PRINTABLE
                                        // cell. With his 10 mm reach on a face only a few
                                        // tens of millimetres across, most of the wall sits
                                        // inside the band, so most of the wall went to the
                                        // floor — under every algorithm and every toggle,
                                        // because the band does not read either.
                                        //
                                        // The FIT term above is the one that must be free:
                                        // it subdivides exactly where a cell will not fit
                                        // inside the outline, which is geometry. This ramp
                                        // is the aesthetic on top of it — "fit first, then
                                        // smooth" — so it is capped at a couple of steps.
                                        // The shape is still fitted; the wall is no longer
                                        // fabric.
                                        //
                                        // ★★★ AND THAT CAP IS GONE (2026-08-26). It was
                                        // fighting the WRONG FABRIC.
                                        //
                                        // The fabric `00af9728` capped this against was
                                        // the band COMPOUNDING with a per-spot rule that
                                        // was halving 51% of the wall on 260 nanometres of
                                        // half-float rounding (see `exact` at the top of
                                        // this function). With that fixed the band no
                                        // longer has a spurious halving to multiply, and
                                        // the cap's only remaining effect was to FLATTEN
                                        // THE GRADE: `ramp >= 3` as soon as
                                        // `d <= 0.714 * reach`, so 86% of the band sat at
                                        // exactly S/3 — one wide ring, not a grade.
                                        //
                                        // ★ AND A WIDE RING OF S/3 IS NOT WHAT HE ASKED
                                        // FOR (2026-08-26): "the grade is to SOLID. We
                                        // want the shape to be exact to the face-prism. So
                                        // as it gets closer, it is graded more and more,
                                        // until it becomes a solid and connects the
                                        // sides." Uncapped, each rung occupies
                                        // `reach / (nCap - 1)` of the band — on his 10 mm
                                        // band that is 1.4 mm per rung — so the finest
                                        // cells are a thin ring AT the outline and the
                                        // solid rim closes it. That is a grade; S/3
                                        // everywhere was a step.
                                        let levels = Double(nCap - 1) * (1 - t)
                                        let ramp = 1 + Int(levels.rounded(.up))
                                        // ★★★ THE BAND'S FIRST RUNG IS S/3, AND IT IS
                                        // NOT TAKEN TWICE (2026-08-26).
                                        //
                                        // On the stepped path S/2 is not a size he
                                        // allows ("any number but 1/2 is ok"), so the
                                        // `n == 2 -> n = 3` bump below turns the ramp's
                                        // FIRST rung into a third as well as its second
                                        // — two adjacent rungs both landing on S/3, i.e.
                                        // a DOUBLE-WIDTH ring of the finest step the
                                        // ladder can take. On a wall whose cell is
                                        // already half the material (single-cell OFF,
                                        // where `nCap` is only 4) that ring is two
                                        // thirds of the band, and 1.72 mm cells with
                                        // one-bead struts covered 333 of ~3,285 painted
                                        // cells — measured, and it reads as fabric.
                                        //
                                        // A rung the ladder cannot express is not a
                                        // rung: where the ramp asks for a HALVING the
                                        // cell simply does not step yet. The grade then
                                        // starts where a third is genuinely called for,
                                        // which is also what he asked of it — "as it
                                        // gets closer, it is graded more and more".
                                        // Strictly coarser than before, never finer, so
                                        // it cannot reintroduce fabric anywhere.
                                        //
                                        // ★ THE FIT TERM IS UNTOUCHED. `n` already
                                        // carries the geometric requirement (a cell that
                                        // will not fit inside the outline), and that is
                                        // not negotiable — this only declines to ADD an
                                        // aesthetic step the ladder cannot take.
                                        let rung = (!dyadicSteps && ramp == 2) ? 1 : ramp
                                        n = Swift.max(n, rung)
                                    }
                                }
                                if dyadicSteps {
                                    // ★ DYADIC STEPPING (2026-08-25): round the
                                    // division UP to a power of two, so every
                                    // graded cell's nodes land on its parent's —
                                    // the conformity Doubled's ladder has. The
                                    // "never S/2" bump is stepped's aesthetic
                                    // and does not apply: halving IS the step.
                                    var p2 = 1
                                    while p2 < n { p2 <<= 1 }
                                    n = p2
                                } else if n == 2 {
                                    // "At least by 1/3" — S/2 is never a size.
                                    n = 3
                                }
                                // ★ THE OLD PER-VOXEL WIDTH DIVISOR STOOD HERE — a
                                // SHRINK-ONLY integer divide of the region's cell.
                                // Superseded by his 2026-08-25 ruling, applied at the
                                // top of this block: the per-spot BASE is
                                // min(prism depth, local wall)/floor in BOTH
                                // directions, so a thin sliver still gets a smaller
                                // cell and a thick corner now gets a bigger one.
                                // ★ CLAMPED, NOT SOLIDIFIED. The finest printable cell
                                // is the floor; the sliver too thin for even that is
                                // below this grid's resolution and the region clip
                                // already trims it. Going solid here is a separate,
                                // measured step — not a side effect of a sampling miss.
                                // ★★★ AND WHAT WILL NOT FIT AT THE FINEST PRINTABLE
                                // CELL GOES **SOLID** — the last step of his rule
                                // (2026-08-26): *"as it gets closer, it is graded more
                                // and more, until it becomes a solid and connects the
                                // sides"*, and 2026-08-23: *"get to the point where the
                                // lattice is as small as is printable and fill the rest
                                // with solid material"*.
                                //
                                // The clamp below is what stood here alone, and it lies
                                // quietly: a cell whose fit demands S/12 when only S/8
                                // is printable was silently given S/8 and drew a strut
                                // that does not fit inside the outline. At the face's
                                // edge that is a band of bead-thin rubble instead of the
                                // solid that ties the lattice into the chamfer.
                                //
                                // ★ AND IT CANNOT BE THE RIM'S JOB. The rim band is a
                                // fraction of the LOCAL cell, and the local cell here is
                                // the FINEST one — 0.33 x 1.29 mm = 0.43 mm, far below
                                // the 1.72 mm floor the in-plane field can express, so
                                // the rim can never fire exactly where the grade has
                                // bottomed out. The two rules would cancel.
                                //
                                // 0 in the `g` channel is the marker: it is never
                                // written otherwise (an unmeasured cell writes the 1e3
                                // sentinel, a measured one writes `dCentre > 1e-6`), and
                                // the march's own test `dOutline - band <= 0` makes it
                                // solid for any band.
                                // ★★★ THE GRADE MUST END IN **SOLID**, NOT IN FABRIC
                                // (2026-08-26, measured on the device).
                                //
                                // Restoring the honest fit distance (see `halfExtent`
                                // above) put far more of the wall inside his 10 mm band
                                // — d[p25] 8.59 -> 5.16 mm — and the ladder answered by
                                // running all the way down to the printable floor:
                                // n = [1851, S/3 x 652, S/4 x 146] against
                                // [2499, S/3 x 150] before. S/3 and S/4 of a 5.16 mm
                                // cell are 1.72 and 1.29 mm, one-bead struts, and at his
                                // working zoom that is exactly the fabric he calls the
                                // quilt. The A/B is in evidence/2026-08-26-quilt-fixed.
                                //
                                // His rule names the terminus, and it is not the floor:
                                // *"as it gets closer, it is graded more and more, until
                                // it becomes a SOLID and connects the sides"*. So the
                                // ladder is allowed a bounded number of visible rungs and
                                // everything below its last rung goes solid — which is
                                // also the only reading under which "grade to shape"
                                // makes the shape EXACT to the face-prism, since a solid
                                // fills the outline and a subdivided cell only
                                // approximates it.
                                //
                                // `nCap` stays the PRINTABILITY cap and is untouched;
                                // this is the AESTHETIC one, and it is the tighter of the
                                // two.
                                let ladderCap = Swift.min(nCap, Self.shapeLadderCap)
                                // ★★★ "NO ROOM" IS AN OVERLAP TEST, NOT A CENTRE TEST
                                // (2026-08-28, his screenshot of purple blobs scattered
                                // along both curved outlines).
                                //
                                // ★ A CENTRE TEST MAKES A DOTTED LINE, NOT A RING. This
                                // was `!(d > 1e-6)` — solid only where the fit distance
                                // measured AT THE CELL CENTRE was exactly zero. `d` is a
                                // BFS distance on the 1.72 mm occupancy grid sampled once
                                // per 5.16 mm base cell, so `d == 0` catches roughly one
                                // boundary cell in three, and WHICH third depends on where
                                // the cell grid happens to fall against the boundary. On a
                                // straight, phase-aligned edge that is all-or-nothing; on
                                // a CURVE the distance slides smoothly and the ring breaks
                                // into scattered cell-sized lumps. That is the same 3:1
                                // lottery as the rim band of 2026-08-26 ("a 6:1 lottery
                                // makes a scatter, not a ring"), and the same centre-test
                                // error as region ownership and the occupancy gate before
                                // it: along a curved outline a straight cell grid
                                // NECESSARILY straddles, so any question asked only at the
                                // centre answers for a sample, not for the cell.
                                //
                                // ★ THE FILE ALREADY STATES THE RIGHT RULE, in
                                // `solidOutlineCellFraction`: *"a cell whose centre sits
                                // closer than S/2 to the outline cannot hold a strut
                                // node"*. So "no room" is `d < S/2` — and `S` is the size
                                // this cell will actually be DRAWN at, after the ladder
                                // has stepped it down as far as it is permitted to. That
                                // is his rule exactly: grade down as far as it can fit,
                                // and only when even the finest permitted cell cannot hold
                                // a node does it become "a solid and connect the sides".
                                //
                                // ★ IT CANNOT EAT THE INTERIOR. `d` is the distance to the
                                // outline, so this is false everywhere but the boundary
                                // row, and `centreInside` below still keeps the overshoot
                                // ring out of solid entirely.
                                // ★★★ AND IT IS ASKED OF THE **EXACT** OUTLINE, not of
                                // the BFS field. `d` is a voxel-grid distance quantised
                                // to 1.72 mm, and the threshold it is compared against is
                                // half a cell — 2.58 mm. A +/-0.86 mm slop on a 2.58 mm
                                // decision is a 33% relative error on the very number
                                // that says "ring or no ring", so the ring came out as a
                                // dotted line: measured on his part, only 25% (face 2)
                                // and 32% (face 15) of outline points had a solid cell
                                // just inside them. `LatticeFaceOutline.signedDistance`
                                // is the analytic polygon distance — the same function
                                // `LatticeRegionMask` decides membership with — so the
                                // ring is exact and cannot alias against the cell grid.
                                //
                                // ★ IT IS AFFORDABLE HERE. The note in
                                // `LatticeRegionMask.signedDistance` about this being the
                                // expensive term is about calling it PER VOXEL over the
                                // whole bbox; this loop runs per BASE CELL (24k of them,
                                // ~70 outline vertices), which is nothing.
                                //
                                // ★ AND `n > ladderCap` IS GONE FROM THIS BRANCH ON
                                // PURPOSE. That was the same quantised `d` in disguise
                                // (`n_fit = ceil(s/2d)`, so `n > 1` IS `d < s/2`), so
                                // keeping it as a conjunct would have re-imposed the
                                // scatter this replaces. The new test is the complete
                                // statement of the rule on its own: at the size this cell
                                // will actually be DRAWN, is there room for a node.
                                // ★ NOTE FOR THE DYADIC PATH (2026-08-28 sweep). This
                                // sizes the ring from the cell the SPOT is drawn at.
                                // That is right for stepped, where `n` is 1 almost
                                // everywhere, and it is NOT sufficient on Default Grade
                                // with single-cell members ON: ring 57% and a 1.1%
                                // clipped residue that survives every sample depth,
                                // against 87% / 0.2% on stepped. Rounding `n` to its
                                // dyadic value here first was TRIED and measured as a
                                // no-op — at n = 2 the rounding is the identity. The
                                // real mismatch is that solid is decided per BASE cell
                                // while the geometry is drawn per SUB-cell, and those
                                // only disagree when n > 1, which stepped never does
                                // because S/2 is banned. Left open deliberately rather
                                // than papered over.
                                let drawnCellMM = s / Double(Swift.max(1, Swift.min(n, ladderCap)))
                                var dOutlineExact = Double.nan
                                if region.kind == .face, !region.outlineLoops.isEmpty {
                                    let rn = LatticeRegionMask.unit(region.normal)
                                    let (bu, bv) = LatticeRegionMask.basis(rn)
                                    let rel = p - region.origin
                                    // `signedDistance` is negative INSIDE, so negate to
                                    // get "how far in from the outline this centre sits".
                                    dOutlineExact = -(LatticeFaceOutline.signedDistance(
                                        SIMD2<Double>(simd_dot(rel, bu), simd_dot(rel, bv)),
                                        loops: region.outlineLoops) - region.inPlaneOffsetMM)
                                }
                                // ★ THE RING DEPTH, IN WHOLE CELLS. One ring is exactly
                                // the cells the outline CUTS — centre within half a cell
                                // of it — which is the set that provably cannot hold a
                                // node, and so is precisely his *"ONLY WHEN NO MORE CAN
                                // FIT can you make the rest solid."* Each further ring
                                // adds one more full cell inward.
                                let ringDepthMM =
                                    (Double(Self.solidRingCells) - 0.5) * drawnCellMM
                                let noRoomAtAll = dOutlineExact.isNaN
                                    ? (n > ladderCap && !(d > 1e-6))   // no outline: as before
                                    : dOutlineExact < ringDepthMM
                                // ★ AND THE OVERSHOOT RING IS NEVER SOLID. Solid is the
                                // terminus for a cell INSIDE the face that cannot fit a
                                // printable lattice — "ONLY WHEN NO MORE CAN FIT can you
                                // make the rest solid" (2026-08-27). A cell outside the
                                // outline is not "unable to fit"; it is excess, and the
                                // prism cuts it.
                                // ★ ONE RULE FOR EVERY RING COUNT. The ring count is now
                                // a DEPTH in `noRoomAtAll` (see `ringDepthMM`), so the
                                // old split — `n > ladderCap` for two rings, the centre
                                // test for one — is gone. That split is what let the
                                // shipping default (2) run on the quantised `d` and never
                                // reach the exact test at all.
                                //
                                // ★★★ AND THE GATE IS "DOES THE OUTLINE CUT THIS CELL",
                                // NOT `centreInside` — the last break in the ring.
                                //
                                // A cell whose centre falls just OUTSIDE the outline is
                                // the one the outline cuts hardest, and `centreInside`
                                // refused it. So along the boundary the cut cells
                                // alternated — centre in, centre out — and the ring came
                                // out as a 50/50 dotted line: measured 51% and 52% of
                                // outline points with the exact depth test but this gate
                                // still in place. Half a ring is not a ring.
                                //
                                // ★ IT ADDS NO MATERIAL OUTSIDE THE FACE, which is the
                                // whole of the 2026-08-27 ruling this looks like it
                                // crosses. Solid is still clipped by `dClip`, which
                                // unions the region's own SDF — so a straddling cell
                                // marked solid fills only the part of itself INSIDE the
                                // prism, and the excess is cut exactly as before. What
                                // the ruling forbids is solid standing in for the
                                // overshoot ring; a cell entirely outside the face is
                                // still excluded here, by the `-0.5 · cell` bound.
                                let cutsTheOutline = dOutlineExact.isNaN
                                    ? centreInside
                                    : dOutlineExact > -0.5 * drawnCellMM
                                let fitWantedFinerThanPrintable = cutsTheOutline && noRoomAtAll
                                if fitWantedFinerThanPrintable { dbgSolid += 1 }
                                n = Swift.min(n, ladderCap)
                                if dyadicSteps, n > 1 {
                                    // The printable cap may land between rungs —
                                    // fall to the largest power of two under it.
                                    var p2 = 1
                                    while p2 * 2 <= n { p2 <<= 1 }
                                    n = p2
                                }
                                dbgN[n, default: 0] += 1
                                // ★ THE DIVISION'S BASE IS THE PER-SPOT CELL, and the
                                // printability backoff below must re-divide the SAME
                                // base — `sizes[r]` here would silently re-inflate a
                                // cell the per-spot rule shrank.
                                let sBase = s
                                s = sBase / Double(n)

                                // ★★★ THE SOLID OUTLINE — THE SHAPE FIT'S LAST STEP.
                                //
                                // His rule, 2026-08-23: "6mm cells can't make the face
                                // prism's exact shape, so it gets smaller at the ends to
                                // make the shape until it becomes a complete solid
                                // outline of the shape. But it's not the depth! It's the
                                // shape of the face!"
                                //
                                // ★ SO IT USES THE SAME IN-PLANE DISTANCE THE GRADE DOES,
                                // and it is decided HERE, not in the shader. Every shader
                                // attempt drove it off `dRegion` — and a face region is an
                                // EXTRUSION, `q = (inPlane, along)`, so `dRegion` reaches
                                // 0 at the DEPTH CAP PLANES every bit as much as at the
                                // outline. That banded the wall's front and back surfaces:
                                // the depth, which is precisely what he said it is not.
                                //
                                // ★ AND AN INACTIVE CELL IS ALREADY SOLID — the march
                                // draws `F = dClip` wherever no cell is active. So marking
                                // the cell here IS the solid: no new field, no new texture,
                                // and nothing that can disagree with the struts about where
                                // the region ends. The band is half the finest printable
                                // cell, which is exactly the sliver no cell can occupy — a
                                // cell centred closer than S/2 to the outline has no room
                                // for a node.
                                // ★ ONE FINAL CELL, NOT HALF OF ONE — because half is
                                // below what the grid can say. The in-plane field is
                                // measured on the occupancy grid, whose smallest non-zero
                                // distance inside the material IS one voxel (1.72 mm on
                                // his part). A 0.75 mm threshold can therefore never be
                                // met by any cell centre, and `solidRim` came back 0 for
                                // exactly that reason. One cell is the granularity the
                                // solid can actually be expressed at, and it is the ring
                                // whose cell has no room for a node of its own size.
                                // ★★★ THE SOLID OUTLINE IS A **BAKED DISTANCE**, NOT A
                                // DEACTIVATED CELL. Two reasons the deactivation could
                                // never have worked, both confirmed in the march:
                                //
                                //   1. `anyActive` IS A NEIGHBOURHOOD PROPERTY. It is set
                                //      true if ANY of the 3x3x3 neighbours is active, so a
                                //      one-cell-wide inactive RING is surrounded by active
                                //      cells and still draws their struts. Only a large
                                //      contiguous inactive area (the member floor's case)
                                //      ever reads as solid.
                                //   2. A deactivated cell also lost its `stepped` size, so
                                //      the shader stopped treating it as stepped at all and
                                //      fell to the dyadic path at the BASE cell — a
                                //      different lattice, not solid.
                                //
                                // So the distance to the outline is written into the cell
                                // field instead and the march UNIONS a solid term from it.
                                // Additive, so it cannot be undone by a neighbour.
                                let dCentre = boundaryAtCentre(p, r)
                                if dCentre > 1e-6 { dbgCentre.append(dCentre) }
                                // ★★★ 0 IS "NO MEASUREMENT", AND AS A DISTANCE 0 MEANS
                                // "ON THE OUTLINE" — the same number cannot mean both.
                                // Written raw, every cell whose centre falls outside the
                                // candidate set would read as distance 0 and turn SOLID,
                                // which is every cell outside every region. A far
                                // sentinel keeps "unmeasured" out of the band.
                                //
                                // ★ AND ONLY PAINTED CELLS GET ONE. The `g` channel is
                                // the DYADIC LEVEL on every other path — an unpainted
                                // cell must stay 0 or `lsdf_cell_frame_at` reads a level
                                // of 12 and the tap readout reports `baseCell * 2^12`.
                                // ★ 0 ⇒ SOLID, whatever the band. See the clamp above.
                                outline[i] = fitWantedFinerThanPrintable
                                    ? 0
                                    : (dCentre > 1e-6 ? Float(Swift.min(dCentre, 1e3))
                                                      : 1e3)
                                if dCentre > 1e-6, dCentre <= Swift.max(finestCellMM,
                                        Double(Swift.max(occ.spacing.x,
                                          Swift.max(occ.spacing.y, occ.spacing.z)))) {
                                    solidRim += 1
                                }

                                // ★★★ HOLD THE STRUT AT ONE BEAD (his ruling: option 1).
                                //
                                // `rho* = printabilityDensityFloor(cell)` is the density
                                // at which a strut of this cell is exactly one extrusion.
                                // Below it the lattice is undrawable, which is what the
                                // 0.16 mm strut was. So the cell's DEMAND is lifted until
                                // the shader's own law
                                //     rho = lo + (hi - lo)·demand^gamma
                                // lands at or above rho*.
                                //
                                // ★ AND IF THE BAND CANNOT REACH IT, THE CELL BACKS OFF
                                // rather than drawing something unprintable — coarsening
                                // is always available, and a coarser cell needs LESS
                                // density, so this terminates.
                                if lineWidthMM > 0, densityHi > densityLo, !latticeID.isEmpty {
                                    let lat = LatticeType.named(latticeID)
                                    var rhoStar = lat.printabilityDensityFloor(
                                        lineWidthMM: lineWidthMM, cellMM: s)
                                    while rhoStar > densityHi + 1e-9, n > 1 {
                                        n -= 1
                                        s = sBase / Double(n)
                                        rhoStar = lat.printabilityDensityFloor(
                                            lineWidthMM: lineWidthMM, cellMM: s)
                                    }
                                    if rhoStar > densityLo {
                                        let t = (rhoStar - densityLo) / (densityHi - densityLo)
                                        let clamped = Swift.max(0, Swift.min(1, t))
                                        let dem = densityGamma > 0
                                            ? pow(clamped, 1 / densityGamma) : clamped
                                        // Never LOWER a cell's own demand — the stress
                                        // field still owns the upper hand.
                                        activation[i] = Swift.max(activation[i], Float(dem))
                                    }
                                }
                            }
                            stepped[i] = halfRepresentable(Float(s)); painted += 1
                            // ★ THE OWNING REGION'S TILING PHASE TRAVELS WITH ITS SIZE.
                            // Same first-match rule, same cell, so the two can never
                            // describe different regions.
                            //
                            // ★★★ AND THE FRACTION IS RE-MEASURED IN THIS CELL'S OWN
                            // UNITS, from the region spec itself — `tilingPhase`, the
                            // SAME implementation the per-region encoder uses. The
                            // 2026-08-25 quilt round was the encoder measuring in
                            // REGION cells while the shader shifted by the LOCAL cell
                            // (face 15, frac 0.1011: 107 of 304 shrunk cells, caps
                            // 0.51–0.68 mm off a boundary). Computing per cell from
                            // the region origin is exact at ANY size ratio — which
                            // the per-spot both-directions rule above now produces —
                            // where the earlier integer rescale was exact only at
                            // whole divisions of the region cell.
                            if let ph = tilingPhase(region: primeRegion, cellMM: s,
                                                    origin: occ.origin - originShiftMM) {
                                phase[i] = ph
                            } else if prime < regionPhase.count {
                                phase[i] = regionPhase[prime]
                            }
                            break
                        }
                    }
                    i += 1
                }
            }
        }
        // ★ WHAT ACTUALLY SURVIVED INTO THE ARRAY THE TEXTURE IS BUILT FROM. The
        // solid marker is a 0 in `outline`, which ships as the cell texture's `g`
        // channel; `gradedToSolid` counts the DECISION, this counts the WRITE. If the
        // two disagree the write is being lost, and no amount of shader reading will
        // find a marker that is not there.
        var dbgSolidWritten = 0
        for n in 0..<stepped.count where stepped[n] > 0 && outline[n] == 0 {
            dbgSolidWritten += 1
        }
        NSLog("DIAG steppedSolid decided=\(dbgSolid) written=\(dbgSolidWritten) "
              + "painted=\(painted)")
        if !dbgD.isEmpty {
            let sorted = dbgD.sorted()
            func q(_ f: Double) -> Double { sorted[Int(f * Double(sorted.count - 1))] }
            let ns = dbgN.keys.sorted().map { "n\($0)=\(dbgN[$0]!)" }.joined(separator: " ")
            NSLog("DIAG steppedGrade painted=\(painted) skipped=\(dbgSkipped) "
                  + "d[min=\(String(format: "%.2f", sorted.first!)) "
                  + "p25=\(String(format: "%.2f", q(0.25))) "
                  + "p50=\(String(format: "%.2f", q(0.5))) "
                  + "max=\(String(format: "%.2f", sorted.last!))] "
                  + "finest=\(String(format: "%.3f", finestCellMM)) "
                  + "bandMM=\(shapeFitBandMM) solidRim=\(solidRim) gradedToSolid=\(dbgSolid) ladderCap=\(Self.shapeLadderCap) fitOff=\(Self.fitCorrectionDisabled) "
                  + "dCentre[min=\(String(format: "%.2f", dbgCentre.min() ?? -1)) "
                  + "n=\(dbgCentre.count)] n=[\(ns)] "
                  + "w[min=\(String(format: "%.2f", dbgW.min() ?? -1)) "
                  + "max=\(String(format: "%.2f", dbgW.max() ?? -1)) "
                  + "n=\(dbgW.count) shrunk=\(dbgWidthShrunk)]")
        } else {
            NSLog("DIAG steppedGrade NO SAMPLES painted=\(painted) skipped=\(dbgSkipped) "
                  + "perRegion=\(boundaryDistancePerRegion.count) finest=\(finestCellMM)")
        }
        guard painted > 0 else { return nil }
        var outGrid = grid
        outGrid.values = activation
        return LatticeCellField(field: outGrid,
                                // ★ ON STEPPED THE `g` CHANNEL IS THE OUTLINE DISTANCE,
                                // not a dyadic level — stepped has no ladder, the shader's
                                // stepped branch sets `L = 0` regardless, and since the
                                // same-lattice test now keys on the CELL SIZE, nothing
                                // reads `g` as a level here. It is the only free channel.
                                level: outline,
                                steppedCellMM: stepped, steppedPhase: phase,
                                baseCellMM: baseCellMM,
                                // ★ THE RAY-BOX PAD MUST COVER THE BIGGEST COVERING
                                // CELL (`gridDims.w = 2^maxLevel`, in BASE cells).
                                // Stepped declared 0 — one base cell — which was
                                // already optimistic for a second region's coarser
                                // cell and is wrong outright now that the per-spot
                                // rule can GROW a cell past the region's stated one:
                                // a strut of a grown cell near the volume's edge
                                // would be clipped out of the march's padded box.
                                maxLevel: {
                                    let maxMM = stepped.max() ?? 0
                                    guard maxMM > 0, baseCellMM > 0 else { return 0 }
                                    let ratio = Double(maxMM) / baseCellMM
                                    return ratio > 1
                                        ? Int(log2(ratio).rounded(.up)) : 0
                                }(),
                                fromCorePlan: false)
    }

    /// Round to the nearest value an IEEE half can hold exactly — see
    /// `LatticeCellField.steppedCellMM`.
    static func halfRepresentable(_ v: Float) -> Float {
        Float(Float16(v))
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
        return LatticeCellField(field: grid, level: lvl, steppedCellMM: [], steppedPhase: [],
                                baseCellMM: plan.baseCellMM,
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
            level: lvl,
            // The ceiling reshapes a DYADIC plan; it is never reached on the stepped
            // path, so the sizes pass through untouched rather than being invented.
            steppedCellMM: field.steppedCellMM, steppedPhase: field.steppedPhase,
            baseCellMM: field.baseCellMM,
            maxLevel: Swift.max(field.maxLevel, ceilingLevel), fromCorePlan: true)
    }
}
