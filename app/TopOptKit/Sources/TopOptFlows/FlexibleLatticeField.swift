// FlexibleLatticeField — THE Flexible lattice's geometry, defined once (task
// 2026-09-29-flexible-screens, overnight round).
//
// ★ THE APP IS THE SOURCE OF TRUTH FOR THIS GEOMETRY (maintainer, 2026-09-29: "there is
// no core yet for Flexibles, so your preview will be the source of truth"). C2 (core's
// lattice recipe) does not exist; until it does, the preview evaluates the function
// written here. It has TWO copies, held together by tests:
//   * this Swift reference (`FlexibleLatticeField.lattice(at:)`),
//   * the Metal G-buffer march (FlexibleLatticeShader's MSL `flx_field`, drawn by
//     FlexibleLatticePass inside MeshRenderer's passes).
// A change here must be made in both; FlexibleLatticePassTests samples them at the same
// points and fails if they disagree by more than 5e-3 mm (the GPU's half-float SDF and its
// own sin/cos).
// FlexibleLatticeFieldTests pins what the field means on C1's pad. (Exports wait on core —
// maintainer, 2026-09-29 — so the app's STL exporter and its C++ copy were removed; they
// are recoverable at 85b1bdc0.)
//
// ── THE FIELD (all lengths mm, model space; negative = inside) ─────────────────────────
// Grids use the VOXEL-CENTRE convention: value i sits at c0 + i·spacing, sampled with
// trilinear interpolation of the continuous index u = (p − c0)/spacing, clamped to
// [0, n−1] per axis.
//   ρ(p)      = clamp(trilinear(rho), 0.05, 0.9)        — core's density, gaps filled
//   m(p)      = trilinear(mask)                          — 1 lattice voxel, 0 not
//   dRegion   = (0.5 − m(p)) · 2 · rhoSpacing            — ≤ 0 inside the lattice region
//   dPart     = trilinear(partSDF)                        — part surface, − inside; BEYOND the
//               grid's box, max(that, |p − box|) (the grid has no margin — batch B review)
//   dSkin     = skinMM − trilinear(skinDist)             — ≤ 0 deeper than the skin
//   GYROID:     L = clamp(3.0915·t/ρ, Lmin, Lmax)
//               THE LADDER: j = 4·log2(L/Lmin), j0 = floor(j), La = Lmin·2^(j0/4),
//               Lb = Lmin·2^((j0+1)/4), w = smoothstep(¼, ¾, j − j0)
//               per rung (k = 2π/L_rung, ONE k, q = k·p):
//                 g = sin qx cos qy + sin qy cos qz + sin qz cos qx
//                 ∇ = k·(cos qx cos qy − sin qz sin qx, cos qy cos qz − sin qx sin qy,
//                        cos qz cos qx − sin qy sin qz)
//               G = (1−w)·gA + w·gB, ∇G = (1−w)·∇A + w·∇B, k̄ = (1−w)·kA + w·kB
//               wall = |G| / max(|∇G|, 0.05·k̄) − t/2
//   HONEYCOMB:  e1, e2 ⟂ buildDir (e1 = normalize(buildDir × (|b.x| < 0.9 ? X : Y)),
//               e2 = buildDir × e1), v = (p·e1, p·e2), d = honeycombCellMM (across flats)
//               r = (d, √3·d), h = r/2, A = mod(v, r) − h, B = mod(v − h, r) − h,
//               q = |A|² < |B|² ? A : B,
//               n = max(|q.x|, |0.5 q.x + 0.8660254 q.y|, |−0.5 q.x + 0.8660254 q.y|)
//               wall = |d/2 − n| − t/2           (mod(x, y) = x − y·floor(x/y))
//   LATTICE:    F = max(wall, dRegion, dPart, dSkin)          — the preview draws F
//
// ★ GRADING. Walls stay whole beads (R1); the gyroid's cell follows ρ (03-generators §3:
// L = 3.0915 t/ρ) on a LADDER of true gyroids 19 % apart, blended between neighbouring
// rungs over the middle half of each step (03 §3(a)). It was q = k(p)·p — §3(b)'s naive
// form, whose cells shrink or swell with the distance from the ORIGIN (3× on his pad's far
// end; FlexibleLatticeGradingTests). Continuous either way; in a blend it is a hybrid of
// two gyroids, elsewhere exactly one.
// Honeycomb uses ONE cell for the whole part (03 §4: uniform d in v1), d = 2t/ρ̄.
// ★ SKIN. Faces with skin ON keep `skinMM` of solid under them (M15); `skinDist` is the
// distance to the triangles of every face EXCEPT the loaded faces whose skin is off, so
// the lattice runs to the surface only there. ★ ROUND 4 (D1): the model-wide FINISH decides
// (FlexibleFinish): Covered is this grid; None, Rim and Skin bring their own skinDist and
// thickness through the same dSkin — so this field and its MSL twin are unchanged.

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

    /// Trilinear at a model point (the one sampling rule both copies use).
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

    /// How far `p` lies OUTSIDE the grid's box (its first and last voxel centres), 0 inside.
    /// ★ THE PART'S SDF IS CLAMPED AT ITS GRID'S EDGE, and the preview's grid has no margin
    /// (its last texel lies ON a face): beyond it the part's distance is at least this far
    /// (batch B review — the shader's flx_part_distance, the twin).
    public func outsideDistance(_ p: SIMD3<Float>) -> Float {
        let lo = c0, hi = c0 + SIMD3<Float>(Float(nx - 1), Float(ny - 1), Float(nz - 1)) * spacing
        return simd_length(simd_max(simd_max(lo - p, p - hi), .zero))
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

    /// Rungs per doubling of the gyroid's cell: Lmin·2^(j/4), 19 % apart (03 §3: ≤ 20 % per step).
    public static let ladderStepsPerOctave: Float = 4
    /// The share of each rung-to-rung interval (in log L) that BLENDS; the rest is a pure rung.
    public static let blendLo: Float = 0.25, blendHi: Float = 0.75

    /// The gyroid g and ∇g at ONE constant wavenumber k (a true gyroid, cell 2π/k).
    @inline(__always) static func gyroid(_ p: SIMD3<Float>, k: Float) -> (g: Float, grad: SIMD3<Float>) {
        let q = p * k
        let s = SIMD3<Float>(sin(q.x), sin(q.y), sin(q.z))
        let c = SIMD3<Float>(cos(q.x), cos(q.y), cos(q.z))
        let g = s.x * c.y + s.y * c.z + s.z * c.x
        let grad = k * SIMD3<Float>(c.x * c.y - s.z * s.x, c.y * c.z - s.x * s.y, c.z * c.x - s.y * s.z)
        return (g, grad)
    }

    /// The two bracketing rungs of the ladder for the intended cell L, the blend weight of
    /// the upper one (0 = the lower rung alone, 1 = the upper alone), and dw/dj.
    public static func rungs(L: Float, lMin: Float) -> (La: Float, Lb: Float, w: Float, dwdj: Float, j: Float) {
        let j = Swift.max(0, ladderStepsPerOctave * log2(L / lMin))
        let j0 = j.rounded(.down), fr = j - j0
        let x = Swift.min(Swift.max((fr - blendLo) / (blendHi - blendLo), 0), 1)
        let w = x * x * (3 - 2 * x)   // MSL smoothstep
        return (lMin * exp2(j0 / ladderStepsPerOctave), lMin * exp2((j0 + 1) / ladderStepsPerOctave), w,
                6 * x * (1 - x) / (blendHi - blendLo), j)
    }

    /// `FlexGrid.sample` AND its gradient (mm⁻¹): the trilinear's own, from the same eight
    /// values, 0 along an axis where p is clamped to the grid.
    public static func sampleWithGradient(_ g: FlexGrid, _ p: SIMD3<Float>) -> (value: Float, grad: SIMD3<Float>) {
        let u = (p - g.c0) / g.spacing
        let nx = g.nx, ny = g.ny, nz = g.nz
        let ux = Swift.min(Swift.max(u.x, 0), Float(nx - 1))
        let uy = Swift.min(Swift.max(u.y, 0), Float(ny - 1))
        let uz = Swift.min(Swift.max(u.z, 0), Float(nz - 1))
        let i0 = Swift.min(Int(ux), Swift.max(0, nx - 2)), j0 = Swift.min(Int(uy), Swift.max(0, ny - 2))
        let k0 = Swift.min(Int(uz), Swift.max(0, nz - 2))
        let i1 = Swift.min(i0 + 1, nx - 1), j1 = Swift.min(j0 + 1, ny - 1), k1 = Swift.min(k0 + 1, nz - 1)
        let fx = ux - Float(i0), fy = uy - Float(j0), fz = uz - Float(k0)
        let c000 = g.at(i0, j0, k0), c100 = g.at(i1, j0, k0), c010 = g.at(i0, j1, k0), c110 = g.at(i1, j1, k0)
        let c001 = g.at(i0, j0, k1), c101 = g.at(i1, j0, k1), c011 = g.at(i0, j1, k1), c111 = g.at(i1, j1, k1)
        let c00 = c000 * (1 - fx) + c100 * fx, c10 = c010 * (1 - fx) + c110 * fx
        let c01 = c001 * (1 - fx) + c101 * fx, c11 = c011 * (1 - fx) + c111 * fx
        let c0v = c00 * (1 - fy) + c10 * fy, c1v = c01 * (1 - fy) + c11 * fy
        let value = c0v * (1 - fz) + c1v * fz
        var gx = ((c100 - c000) * (1 - fy) + (c110 - c010) * fy) * (1 - fz) + ((c101 - c001) * (1 - fy) + (c111 - c011) * fy) * fz
        var gy = (c10 - c00) * (1 - fz) + (c11 - c01) * fz
        var gz = c1v - c0v
        if u.x < 0 || u.x > Float(nx - 1) { gx = 0 }
        if u.y < 0 || u.y > Float(ny - 1) { gy = 0 }
        if u.z < 0 || u.z > Float(nz - 1) { gz = 0 }
        return (value, SIMD3(gx, gy, gz) / g.spacing)
    }

    /// The blended SHEET function G at p, its gradient, the blended wavenumber and the blend
    /// weight — from the SAMPLED ρ and its gradient (the MSL `flx_wall`).
    /// ★ A LADDER OF TRUE GYROIDS, NOT q = k(p)·p. A varying k times ABSOLUTE p has the local
    /// wavenumber k + p·∇k (03 §3(b)): on his mirror-symmetric pad the far end drew cells 3×
    /// finer than the near end at the same ρ (FlexibleLatticeGradingTests). Each rung has ONE
    /// k, so its cell is its cell everywhere; between two rungs the sheet functions blend
    /// (03 §3(a)), G = (1−w)·gA + w·gB, and ∇G is the WHOLE gradient — including
    /// (gB − gA)·∇w, the blend weight's own gradient through ρ, without which the walls inside
    /// a blend are drawn off t (`blendGradient: false` is only a test's red control).
    public static func gyroidSheet(_ p: SIMD3<Float>, rhoRaw: Float, gradRho: SIMD3<Float>, _ f: FlexibleLatticeInputs,
                                   blendGradient: Bool = true) -> (G: Float, grad: SIMD3<Float>, k: Float, w: Float) {
        let t = f.wallMM
        let rhoIn = rhoRaw > 0.05 && rhoRaw < 0.9
        let rho = Swift.min(Swift.max(rhoRaw, 0.05), 0.9)
        let Lraw = 3.0915 * t / rho
        let L = Swift.min(Swift.max(Lraw, f.lMinMM), f.lMaxMM)
        let r = rungs(L: L, lMin: f.lMinMM)
        let ka = 2 * Float.pi / r.La, kb = 2 * Float.pi / r.Lb
        var g: Float = 0, grad = SIMD3<Float>.zero
        var gA: Float = 0, gB: Float = 0
        if r.w < 1 { let a = gyroid(p, k: ka); gA = a.g; g += (1 - r.w) * a.g; grad += (1 - r.w) * a.grad }
        if r.w > 0 { let b = gyroid(p, k: kb); gB = b.g; g += r.w * b.g; grad += r.w * b.grad }
        if blendGradient, r.w > 0, r.w < 1, rhoIn, Lraw > f.lMinMM, Lraw < f.lMaxMM, r.j > 0 {
            // ∇j = 4/ln2 · ∇L/L, ∇L = −L/ρ·∇ρ (zero wherever a clamp holds)
            let gradJ = -(ladderStepsPerOctave / Float(M_LN2)) * gradRho / rho
            grad += (gB - gA) * r.dwdj * gradJ
        }
        return (g, grad, (1 - r.w) * ka + r.w * kb, r.w)
    }

    /// The gyroid wall: the gradient-normalised sheet, t thick.
    static func gyroidWall(_ p: SIMD3<Float>, rhoRaw: Float, gradRho: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let s = gyroidSheet(p, rhoRaw: rhoRaw, gradRho: gradRho, f)
        return abs(s.G) / Swift.max(simd_length(s.grad), 0.05 * s.k) - 0.5 * f.wallMM
    }

    public static func wall(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let t = f.wallMM
        switch f.topology {
        case .gyroid:
            let s = sampleWithGradient(f.rho, p)
            return gyroidWall(p, rhoRaw: s.value, gradRho: s.grad, f)
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
        Swift.max(Swift.max(wall(p, f), dRegion(p, f)), Swift.max(dPart(p, f), dSkin(p, f)))
    }
    /// The part's distance: the SDF — and beyond its grid's box never less than the distance
    /// to that box. Inside the box the SDF stands as it is (a max with 0 would erase every wall).
    public static func dPart(_ p: SIMD3<Float>, _ f: FlexibleLatticeInputs) -> Float {
        let sdf = f.partSDF.sample(p), out = f.partSDF.outsideDistance(p)
        return out > 0 ? Swift.max(sdf, out) : sdf
    }
}

// MARK: - building the inputs

public enum FlexibleLatticeBuilder {

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The part's SKINNED surface — every part of a face that keeps its skin (M15) — as
    /// positions + indices for the skin's distance field. `allSkinned` when nothing is
    /// skin-off (the part's own distance is reused then).
    /// ★ ROUND 3, ITEM 2: a triangle a skin-off sector's cut crosses is CUT along it
    /// (FlexibleFacePieces) and only its pieces outside the sector stay skinned — by
    /// centroid, skin-off on 'top A' took the skin off half of 'top B' as well.
    public static func skinnedTriangles(part: ViewerMesh, skinOffFaces: [(face: Int, cuts: [RegionCut])])
        -> (positions: [Float], indices: [UInt32], allSkinned: Bool) {
        let indices = part.indices
        guard !skinOffFaces.isEmpty else { return (part.positions, indices, true) }
        var positions = part.positions
        var skinnedIdx: [UInt32] = []
        skinnedIdx.reserveCapacity(indices.count)
        var planes: [Int: [RegionCut]] = [:]
        for s in skinOffFaces { for c in s.cuts { FlexibleFacePieces.add(c, to: &planes[s.face, default: []]) } }
        let fids = part.faceIDs
        func v(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(part.positions[b]), Double(part.positions[b + 1]), Double(part.positions[b + 2]))
        }
        var allSkinned = true
        for t in 0..<(indices.count / 3) {
            let fid = t < fids.count ? Int(fids[t]) : -1
            let off = skinOffFaces.filter { $0.face == fid }
            let i0 = indices[3 * t], i1 = indices[3 * t + 1], i2 = indices[3 * t + 2]
            guard !off.isEmpty else { skinnedIdx += [i0, i1, i2]; continue }
            allSkinned = false
            if off.contains(where: { $0.cuts.isEmpty }) { continue }       // the whole face
            for piece in FlexibleFacePieces.pieces(v(i0), v(i1), v(i2), planes: planes[fid] ?? []) {
                if off.contains(where: { FaceRegionGeometry.inside(piece.centroid, $0.cuts) }) { continue }
                if piece.whole { skinnedIdx += [i0, i1, i2]; continue }
                let base = UInt32(positions.count / 3)
                for p in piece.points { positions += [Float(p.x), Float(p.y), Float(p.z)] }
                for (a, b, c) in FlexibleFacePieces.fan(piece.points.count) {
                    skinnedIdx += [base + UInt32(a), base + UInt32(b), base + UInt32(c)]
                }
            }
        }
        return (positions, skinnedIdx, allSkinned)
    }

    /// Prepare the grids from core's density field and the part (off the main thread).
    /// `skinOffFaces` are the B-rep/pseudo face ids whose skin is off (M15);
    /// each entry's `cuts` narrow a split sector to its own half-spaces (the face is cut
    /// along them, `skinnedTriangles`).
    /// ★ ROUND 4 (D1): `finish` — the whole model's finish (FlexibleFinish). Covered keeps the
    /// grid below (the distance to every skinned surface, `skinOffFaces` honoured); None, Rim
    /// and Skin replace it with their own skin-distance grid and thickness.
    public static func inputs(field: FlexDensityField, part: ViewerMesh, topology: String,
                              beadsPerWall: Int, beadWidthMM: Double, buildDir: SIMD3<Double>,
                              skinOffFaces: [(face: Int, cuts: [RegionCut])],
                              finish: FlexibleFinish = .covered,
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
        let skinGrid: FlexGrid
        var skinThickness = skinMM
        if let f = FlexibleFinish.skin(finish, part: part, sdf: sdf, bandVoxels: band) {
            skinGrid = f.grid
            skinThickness = f.skinMM
        } else {
            let skinned = skinnedTriangles(part: part, skinOffFaces: skinOffFaces)
            if skinned.allSkinned {
                skinGrid = FlexGrid(nx: sdf.nx, ny: sdf.ny, nz: sdf.nz, c0: sdf.origin, spacing: sdf.spacing.x,
                                    values: sdf.values.map { abs($0) })
            } else {
                let sd = LatticePreviewOccupancy.signedDistance(positions: skinned.positions, indices: skinned.indices,
                                                                like: occ, bandVoxels: band)
                skinGrid = FlexGrid(nx: sd.nx, ny: sd.ny, nz: sd.nz, c0: sd.origin, spacing: sd.spacing.x,
                                    values: sd.values.map { abs($0) })
            }
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
            buildDir: SIMD3<Float>(simd_normalize(buildDir)), skinMM: skinThickness,
            rho: rhoGrid, mask: maskGrid, partSDF: sdfGrid, skinDist: skinGrid,
            boundsMin: part.bounds.min, boundsMax: part.bounds.max)
    }
}
