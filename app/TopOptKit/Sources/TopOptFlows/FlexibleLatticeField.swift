// FlexibleLatticeField — THE Flexible lattice's geometry, defined once (task
// 2026-09-29-flexible-screens, overnight round).
//
// ★ THE APP IS THE SOURCE OF TRUTH FOR THIS GEOMETRY (maintainer, 2026-09-29: "there is
// no core yet for Flexibles, so your preview will be the source of truth"). C2 (core's
// lattice recipe) does not exist; until it does, the preview AND the STL export both
// evaluate the function written here. It has three copies, held together by tests:
//   * this Swift reference (`FlexibleLatticeField.solid(at:)`),
//   * the Metal raymarcher (FlexibleLatticeRenderer's MSL `flx_field`),
//   * the C++ exporter's streaming mesher (flexible_lattice.cpp `flx_field`).
// A change here must be made in all three; the tests sample them at the same points and
// fail if they disagree: FlexibleLatticeExportTests (C++ — BIT-IDENTICAL on a graded,
// tilted field) and FlexibleLatticeRendererTests (MSL — within 2e-3 mm; the GPU's own
// sin/cos). FlexibleLatticeFieldTests pins what the field means on C1's pad.
//
// ── THE FIELD (all lengths mm, model space; negative = inside) ─────────────────────────
// Grids use the VOXEL-CENTRE convention: value i sits at c0 + i·spacing, sampled with
// trilinear interpolation of the continuous index u = (p − c0)/spacing, clamped to
// [0, n−1] per axis.
//   ρ(p)      = clamp(trilinear(rho), 0.05, 0.9)        — core's density, gaps filled
//   m(p)      = trilinear(mask)                          — 1 lattice voxel, 0 not
//   dRegion   = (0.5 − m(p)) · 2 · rhoSpacing            — ≤ 0 inside the lattice region
//   dPart     = trilinear(partSDF)                        — part surface, − inside
//   dSkin     = skinMM − trilinear(skinDist)             — ≤ 0 deeper than the skin
//   GYROID:     L = clamp(3.0915·t/ρ, Lmin, Lmax), k = 2π/L, q = k·p
//               g = sin qx cos qy + sin qy cos qz + sin qz cos qx
//               ∇ = k·(cos qx cos qy − sin qz sin qx, cos qy cos qz − sin qx sin qy,
//                      cos qz cos qx − sin qy sin qz)
//               wall = |g| / max(|∇|, 0.05·k) − t/2
//   HONEYCOMB:  e1, e2 ⟂ buildDir (e1 = normalize(buildDir × (|b.x| < 0.9 ? X : Y)),
//               e2 = buildDir × e1), v = (p·e1, p·e2), d = honeycombCellMM (across flats)
//               r = (d, √3·d), h = r/2, A = mod(v, r) − h, B = mod(v − h, r) − h,
//               q = |A|² < |B|² ? A : B,
//               n = max(|q.x|, |0.5 q.x + 0.8660254 q.y|, |−0.5 q.x + 0.8660254 q.y|)
//               wall = |d/2 − n| − t/2           (mod(x, y) = x − y·floor(x/y))
//   LATTICE:    F = max(wall, dRegion, dPart, dSkin)          — the preview draws F
//   EXPORT:     S = min(max(dPart, −max(dRegion, dSkin)), F)  — solid body ∪ lattice
//               (the solid outside the lattice region or inside the skin, plus the walls)
//               ★ MAX, not min (exporter round, 2026-09-29): the lattice may only be where
//               the point is in the region AND deeper than the skin, max(dRegion, dSkin) ≤ 0.
//               As first written (min) the body was the part outside the region AND inside
//               the skin: every skin was air and the part outside the region was hollow —
//               the exported 30 × 30 × 12 box was a skinless gyroid (2 022 mm³ of 10 800,
//               the skin's 2 592 mm³ missing). `solid` is the export's alone; the preview
//               draws `lattice`, which never read it.
//
// ★ GRADING. Walls stay whole beads (R1); the gyroid's cell follows ρ continuously
// (03-generators §3: L = 3.0915 t/ρ). A continuously varying k warps cells where ρ
// changes — continuous, so the surface stays closed, but not a perfect gyroid there.
// Honeycomb uses ONE cell for the whole part (03 §4: uniform d in v1), d = 2t/ρ̄.
// ★ SKIN. Faces with skin ON keep `skinMM` of solid under them (M15); `skinDist` is the
// distance to the triangles of every face EXCEPT the loaded faces whose skin is off, so
// the lattice runs to the surface only there.

import Foundation
import simd
import TopOptKit

/// A scalar field on a regular grid (voxel-centre convention, x fastest).
public struct FlexGrid: Equatable, Sendable {
    public let nx: Int, ny: Int, nz: Int
    public let c0: SIMD3<Float>      // centre of voxel (0,0,0)
    public let spacing: Float
    public var values: [Float]

    public init(nx: Int, ny: Int, nz: Int, c0: SIMD3<Float>, spacing: Float, values: [Float]) {
        self.nx = nx; self.ny = ny; self.nz = nz; self.c0 = c0; self.spacing = spacing; self.values = values
    }

    @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Float { values[(k * ny + j) * nx + i] }

    /// Trilinear at a model point (the one sampling rule all three copies use).
    public func sample(_ p: SIMD3<Float>) -> Float {
        let u = (p - c0) / spacing
        let ux = Swift.min(Swift.max(u.x, 0), Float(nx - 1))
        let uy = Swift.min(Swift.max(u.y, 0), Float(ny - 1))
        let uz = Swift.min(Swift.max(u.z, 0), Float(nz - 1))
        let i0 = Swift.min(Int(ux), Swift.max(0, nx - 2)), j0 = Swift.min(Int(uy), Swift.max(0, ny - 2))
        let k0 = Swift.min(Int(uz), Swift.max(0, nz - 2))
        let i1 = Swift.min(i0 + 1, nx - 1), j1 = Swift.min(j0 + 1, ny - 1), k1 = Swift.min(k0 + 1, nz - 1)
        let fx = ux - Float(i0), fy = uy - Float(j0), fz = uz - Float(k0)
        let c00 = at(i0, j0, k0) * (1 - fx) + at(i1, j0, k0) * fx
        let c10 = at(i0, j1, k0) * (1 - fx) + at(i1, j1, k0) * fx
        let c01 = at(i0, j0, k1) * (1 - fx) + at(i1, j0, k1) * fx
        let c11 = at(i0, j1, k1) * (1 - fx) + at(i1, j1, k1) * fx
        let c0v = c00 * (1 - fy) + c10 * fy, c1v = c01 * (1 - fy) + c11 * fy
        return c0v * (1 - fz) + c1v * fz
    }
}

/// Everything the lattice needs, prepared once when the user presses Generate.
public struct FlexibleLatticeInputs: Equatable, Sendable {
    public enum Topology: Int32, Sendable { case gyroid = 0, honeycomb = 1 }
    public var topology: Topology
    public var wallMM: Float          // t = beads × bead width
    public var lMinMM: Float          // gyroid cell clamp
    public var lMaxMM: Float
    public var honeycombCellMM: Float // uniform d (honeycomb only)
    public var buildDir: SIMD3<Float>
    public var skinMM: Float
    public var rho: FlexGrid          // filled ρ (> 0 everywhere)
    public var mask: FlexGrid         // 1 lattice / 0 not
    public var partSDF: FlexGrid      // mm, − inside
    public var skinDist: FlexGrid     // mm, unsigned distance to the skinned surfaces
    public var boundsMin: SIMD3<Float>
    public var boundsMax: SIMD3<Float>
}

public enum FlexibleLatticeField {
    /// The default skin under a skin-on face: four 0.2 mm layers (Iacob's specimens
    /// carried 4 + 4 layers of 0.2 mm). A default, recorded in the handoff for a ruling.
    public static let defaultSkinMM: Float = 0.8

    @inline(__always) static func fmod(_ x: Float, _ y: Float) -> Float { x - y * (x / y).rounded(.down) }

    public static func wall(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let t = f.wallMM
        switch f.topology {
        case .gyroid:
            let rho = Swift.min(Swift.max(f.rho.sample(p), 0.05), 0.9)
            let L = Swift.min(Swift.max(3.0915 * t / rho, f.lMinMM), f.lMaxMM)
            let k = 2 * Float.pi / L
            let q = p * k
            let s = SIMD3<Float>(sin(q.x), sin(q.y), sin(q.z))
            let c = SIMD3<Float>(cos(q.x), cos(q.y), cos(q.z))
            let g = s.x * c.y + s.y * c.z + s.z * c.x
            let grad = k * SIMD3<Float>(c.x * c.y - s.z * s.x, c.y * c.z - s.x * s.y, c.z * c.x - s.y * s.z)
            return abs(g) / Swift.max(simd_length(grad), 0.05 * k) - 0.5 * t
        case .honeycomb:
            let b = simd_normalize(f.buildDir)
            let ref: SIMD3<Float> = abs(b.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let e1 = simd_normalize(simd_cross(b, ref)), e2 = simd_cross(b, e1)
            let v = SIMD2<Float>(simd_dot(p, e1), simd_dot(p, e2))
            let d = f.honeycombCellMM
            let r = SIMD2<Float>(d, 1.7320508 * d), h = r * 0.5
            let A = SIMD2<Float>(fmod(v.x, r.x), fmod(v.y, r.y)) - h
            let B = SIMD2<Float>(fmod(v.x - h.x, r.x), fmod(v.y - h.y, r.y)) - h
            let q = simd_length_squared(A) < simd_length_squared(B) ? A : B
            let n = Swift.max(abs(q.x), Swift.max(abs(0.5 * q.x + 0.8660254 * q.y), abs(-0.5 * q.x + 0.8660254 * q.y)))
            return abs(0.5 * d - n) - 0.5 * t
        }
    }

    public static func dRegion(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        (0.5 - f.mask.sample(p)) * 2 * f.mask.spacing
    }
    public static func dSkin(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        f.skinMM - f.skinDist.sample(p)
    }

    /// The lattice walls (what the preview draws). Negative inside.
    public static func lattice(at p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        Swift.max(Swift.max(wall(p, f), dRegion(p, f)), Swift.max(f.partSDF.sample(p), dSkin(p, f)))
    }

    /// The exported solid: the part outside the lattice region (or inside the skin) plus
    /// the walls. Negative inside.
    public static func solid(at p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let dPart = f.partSDF.sample(p)
        let open = Swift.max(dRegion(p, f), dSkin(p, f))   // ≤ 0 where the lattice may be
        return Swift.min(Swift.max(dPart, -open), lattice(at: p, f))
    }
}

// MARK: - building the inputs

public enum FlexibleLatticeBuilder {

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Prepare the grids from core's density field and the part (off the main thread).
    /// `skinOffFaces` are the B-rep/pseudo face ids whose skin is off (M15);
    /// `skinOffCuts` narrows a split sector to its own half-spaces (a triangle counts when
    /// its centroid passes every cut).
    public static func inputs(field: FlexDensityField, part: ViewerMesh, topology: String,
                              beadsPerWall: Int, beadWidthMM: Double, buildDir: SIMD3<Double>,
                              skinOffFaces: [(face: Int, cuts: [RegionCut])],
                              skinMM: Float = FlexibleLatticeField.defaultSkinMM,
                              sdfMaxDim: Int = 128) throws -> FlexibleLatticeInputs {
        guard field.nx > 1, field.ny > 1, field.nz > 1, field.density.count == field.nx * field.ny * field.nz
        else { throw Refusal(description: "The density field is empty — design a face first.") }
        let n = field.density.count
        // ρ with its gaps filled: every non-positive voxel takes the value of the nearest
        // assigned voxel (breadth-first over the 6-neighbourhood), so trilinear filtering
        // never pulls a sentinel into the lattice.
        var rho = [Float](repeating: 0, count: n)
        var mask = [Float](repeating: 0, count: n)
        var queue: [Int] = []
        queue.reserveCapacity(n)
        var assignedSum: Double = 0, assignedN = 0
        for i in 0..<n {
            let d = field.density[i]
            if d > -0.5 { mask[i] = 1 }
            if d > 0 { rho[i] = d; queue.append(i); assignedSum += Double(d); assignedN += 1 }
        }
        guard assignedN > 0 else {
            throw Refusal(description: "No lattice voxel has a density yet — design a loaded face first.")
        }
        var head = 0
        let nx = field.nx, ny = field.ny, nz = field.nz
        while head < queue.count {
            let v = queue[head]; head += 1
            let i = v % nx, j = (v / nx) % ny, k = v / (nx * ny)
            for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let a = i + di, b = j + dj, c = k + dk
                guard a >= 0, b >= 0, c >= 0, a < nx, b < ny, c < nz else { continue }
                let w = (c * ny + b) * nx + a
                if rho[w] <= 0 { rho[w] = rho[v]; queue.append(w) }
            }
        }
        let sp = Float(field.spacing)
        let c0 = SIMD3<Float>(field.origin) + SIMD3<Float>(repeating: 0.5 * sp)   // core's origin is the CORNER
        let rhoGrid = FlexGrid(nx: nx, ny: ny, nz: nz, c0: c0, spacing: sp, values: rho)
        let maskGrid = FlexGrid(nx: nx, ny: ny, nz: nz, c0: c0, spacing: sp, values: mask)

        // The part's signed distance and the skinned surfaces' distance, on the preview's
        // own occupancy grid (LatticePreviewOccupancy — the same code the octet preview uses).
        let indices = part.indices
        let occ = LatticePreviewOccupancy.occupancy(positions: part.positions, indices: indices,
                                                    bounds: part.bounds, maxDim: sdfMaxDim)
        let band = 6
        let sdf = LatticePreviewOccupancy.signedDistance(positions: part.positions, indices: indices,
                                                         like: occ, bandVoxels: band)
        var skinnedIdx: [UInt32] = []
        skinnedIdx.reserveCapacity(indices.count)
        let fids = part.faceIDs
        for t in 0..<(indices.count / 3) {
            let fid = t < fids.count ? Int(fids[t]) : -1
            var skinOff = false
            for s in skinOffFaces where s.face == fid {
                if s.cuts.isEmpty { skinOff = true; break }
                let a = Int(indices[3 * t]), b = Int(indices[3 * t + 1]), c = Int(indices[3 * t + 2])
                func v(_ i: Int) -> SIMD3<Double> {
                    SIMD3(Double(part.positions[3 * i]), Double(part.positions[3 * i + 1]), Double(part.positions[3 * i + 2]))
                }
                if FaceRegionGeometry.inside((v(a) + v(b) + v(c)) / 3, s.cuts) { skinOff = true; break }
            }
            if !skinOff { skinnedIdx += [indices[3 * t], indices[3 * t + 1], indices[3 * t + 2]] }
        }
        let skinGrid: FlexGrid
        if skinnedIdx.count == indices.count {
            skinGrid = FlexGrid(nx: sdf.nx, ny: sdf.ny, nz: sdf.nz, c0: sdf.origin, spacing: sdf.spacing.x,
                                values: sdf.values.map { abs($0) })
        } else {
            let sd = LatticePreviewOccupancy.signedDistance(positions: part.positions, indices: skinnedIdx,
                                                            like: occ, bandVoxels: band)
            skinGrid = FlexGrid(nx: sd.nx, ny: sd.ny, nz: sd.nz, c0: sd.origin, spacing: sd.spacing.x,
                                values: sd.values.map { abs($0) })
        }
        let sdfGrid = FlexGrid(nx: sdf.nx, ny: sdf.ny, nz: sdf.nz, c0: sdf.origin, spacing: sdf.spacing.x,
                               values: sdf.values)
        let t = Float(Double(beadsPerWall) * beadWidthMM)
        let meanRho = Float(assignedSum / Double(assignedN))
        let topo: FlexibleLatticeInputs.Topology = topology == "honeycomb" ? .honeycomb : .gyroid
        return FlexibleLatticeInputs(
            topology: topo, wallMM: t,
            lMinMM: 3.0915 * t / 0.9, lMaxMM: 3.0915 * t / 0.05,
            honeycombCellMM: 2 * t / Swift.max(meanRho, 0.05),
            buildDir: SIMD3<Float>(simd_normalize(buildDir)), skinMM: skinMM,
            rho: rhoGrid, mask: maskGrid, partSDF: sdfGrid, skinDist: skinGrid,
            boundsMin: part.bounds.min, boundsMax: part.bounds.max)
    }
}
