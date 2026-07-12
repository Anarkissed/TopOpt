// LoadPath.swift — the M7.viz.4 load-path visualization's pure-data derivation.
//
// Load path = "how force travels from the loaded region to the anchors": at each
// point in the part, the direction along which material is most stressed. That is
// the PRINCIPAL-STRESS direction, and drawing a short segment along it at sampled
// voxels traces the flow of force through the structure — revealing WHY the
// optimizer kept material where it did.
//
// HONEST DERIVATION (INTERFACE FREEZE — consumes only fields the bridge already
// exposes, per the M7.viz.4 brief option (a)). The bridge gives the app the
// per-node FEA displacement field (M7.disp) and the per-voxel von Mises SCALAR
// (M7.0b) — NOT a directional stress tensor. So this file derives the directions
// from the displacement field:
//
//   1. The infinitesimal strain tensor is the symmetric gradient of displacement,
//      ε = ½(∇u + ∇uᵀ). This is pure kinematics — a spatial derivative of the
//      ALREADY-SOLVED displacement field, no new solve and no material model. It
//      is the same category of post-processing as deriving vertex normals from
//      positions or the von Mises magnitude from the solved field.
//   2. For an isotropic linear-elastic material the principal-STRESS axes coincide
//      with the principal-STRAIN axes (σ and ε share eigenvectors when the
//      stiffness is isotropic), so the eigenvectors of ε give the principal-stress
//      directions. The dominant one (largest |eigenvalue|) is the local load-path
//      axis; the sign of its eigenvalue says tension (+) vs compression (−).
//
// APPROXIMATION & LIMITS (stated for the handoff):
//   • Directions come from a finite-difference gradient of the nodal displacement
//     (trilinear element-centre gradient), so they are a discrete estimate, not an
//     analytic tensor field.
//   • Principal-stress = principal-strain holds EXACTLY for isotropic material; the
//     core also models transverse isotropy (M4.1 z_knockdown), for which this is an
//     approximation on the layer-normal axis. v1 treats the field as isotropic.
//   • This is a DIRECTION field (one dominant axis per sampled voxel), not
//     integrated streamlines — it reads as a load-path "hedgehog", the standard
//     principal-stress-trajectory overlay, not curved flow tubes.
//   • Colouring is the von Mises magnitude on the shared M7.viz.1 scale, so a hot
//     path reads red exactly as the heatmap does.
// A directional stress tensor from /core/ would remove the isotropy caveat; that is
// a future core field (the disp→viz.3 pattern), deliberately NOT added here.
//
// Everything here is GPU-free value-type math so it is unit-tested headlessly (the
// M7 /app/ standard); the Metal line draw that consumes the glyphs is device QA.

import Foundation
import simd

/// A symmetric 3×3 real matrix eigen-solver (cyclic Jacobi rotations). Symmetric
/// matrices have real eigenvalues and an orthonormal eigenvector basis; Jacobi is
/// the standard robust choice at this tiny fixed size. Kept separate so the
/// numerics are tested in isolation.
public enum SymmetricEigen {
    /// Eigen-decompose the symmetric matrix whose rows are `m` (only the symmetric
    /// part is used). Returns three `(value, vector)` pairs with unit, mutually
    /// orthogonal `vector`s satisfying `m · vector ≈ value · vector`, sorted by
    /// DESCENDING eigenvalue. Uses Double internally for stability.
    public static func decompose(_ m: [[Double]]) -> [(value: Double, vector: SIMD3<Double>)] {
        // Work on a mutable symmetric copy `a`; accumulate rotations in `v`.
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { a[r][c] = 0.5 * (m[r][c] + m[c][r]) } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

        // Sweep the three off-diagonals, zeroing the largest each pass. 100 rotations
        // is far beyond the handful a 3×3 needs to converge to machine precision.
        for _ in 0..<100 {
            var p = 0, q = 1
            var maxOff = abs(a[0][1])
            if abs(a[0][2]) > maxOff { maxOff = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > maxOff { maxOff = abs(a[1][2]); p = 1; q = 2 }
            if maxOff < 1e-18 { break }

            // Rotation that zeros a[p][q] (Numerical Recipes' stable form).
            let apq = a[p][q]
            let theta = (a[q][q] - a[p][p]) / (2 * apq)
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            // a ← Jᵀ a J, updating the affected rows then columns (keeps a symmetric).
            for i in 0..<3 {
                let aip = a[i][p], aiq = a[i][q]
                a[i][p] = c * aip - s * aiq
                a[i][q] = s * aip + c * aiq
            }
            for i in 0..<3 {
                let api = a[p][i], aqi = a[q][i]
                a[p][i] = c * api - s * aqi
                a[q][i] = s * api + c * aqi
            }
            // v ← v J (columns are the eigenvectors).
            for i in 0..<3 {
                let vip = v[i][p], viq = v[i][q]
                v[i][p] = c * vip - s * viq
                v[i][q] = s * vip + c * viq
            }
        }

        var pairs: [(value: Double, vector: SIMD3<Double>)] = []
        for k in 0..<3 {
            let vec = SIMD3<Double>(v[0][k], v[1][k], v[2][k])
            let len = simd_length(vec)
            pairs.append((value: a[k][k], vector: len > 0 ? vec / len : SIMD3<Double>(0, 0, 0)))
        }
        pairs.sort { $0.value > $1.value }
        return pairs
    }
}

/// One load-path glyph: at a sampled printed voxel, the dominant principal-stress
/// direction (the local load-path axis) plus the data to colour it. `direction` is
/// a unit vector (its sign is arbitrary — a load-path axis has no head/tail).
public struct LoadPathGlyph: Equatable, Sendable {
    /// Voxel-centre world position (mm) the segment is centred on.
    public let position: SIMD3<Float>
    /// Unit dominant principal-stress axis (the direction force travels here).
    public let direction: SIMD3<Float>
    /// Von Mises stress at the voxel (MPa) — colours the segment on the shared scale.
    public let stressMPa: Float
    /// Signed dominant principal strain (>0 tension, <0 compression); its magnitude
    /// is how strongly this axis dominates.
    public let principalStrain: Float

    public init(position: SIMD3<Float>, direction: SIMD3<Float>,
                stressMPa: Float, principalStrain: Float) {
        self.position = position
        self.direction = direction
        self.stressMPa = stressMPa
        self.principalStrain = principalStrain
    }

    /// Whether the dominant axis is in tension (vs compression).
    public var isTensile: Bool { principalStrain >= 0 }
}

/// A sampled load-path field: the dominant-principal-direction glyphs plus the
/// world length each glyph's segment should be drawn at (sized to the sampling
/// stride so neighbouring segments nearly meet and read as flow lines).
public struct LoadPath: Sendable {
    public let glyphs: [LoadPathGlyph]
    public let segmentLength: Float

    public init(glyphs: [LoadPathGlyph], segmentLength: Float) {
        self.glyphs = glyphs
        self.segmentLength = segmentLength
    }

    public var isEmpty: Bool { glyphs.isEmpty }
    public var count: Int { glyphs.count }
}

/// The load-path overlay's user-facing key copy, kept beside the derivation so it
/// is asserted headlessly (the M7 /app/ standard) and stays honest about being an
/// estimate from the deflection field, not a directly-solved tensor.
public enum LoadPathCopy {
    /// What the lines mean.
    public static let what =
        "Lines follow the principal-stress direction — how force travels from the loads to the anchors."
    /// How they are coloured + derived (the honesty note).
    public static let how =
        "Colour = stress on the same scale as the heatmap. Estimated from the deflection field."
}

/// Builds a `LoadPath` from the FEA displacement field + the von Mises scalar. Pure
/// math (no bridge, no GPU), so the derivation is verified headlessly.
public enum LoadPathField {
    /// Glyph budget for phone legibility + draw cost. The sampling stride is chosen
    /// so the printed voxels sampled stay near this count.
    public static let defaultMaxGlyphs = 260

    /// Below this dominant-principal-strain magnitude a voxel carries no meaningful
    /// direction (void/unloaded nodes have ~zero displacement gradient) and is
    /// skipped. Strains are dimensionless (mm/mm) and typically ~1e-3, so this only
    /// drops the genuinely undeformed set.
    static let strainFloor: Float = 1e-9

    /// Sample the dominant principal-stress direction across the printed region.
    ///
    /// `stress` (von Mises, per voxel) is used both to colour glyphs and — when
    /// present — to restrict sampling to the printed material (stress > 0). With no
    /// stress field, void voxels are still excluded implicitly: their nodes carry
    /// zero displacement, hence zero strain, hence fall below `strainFloor`.
    public static func build(displacement: DisplacementField, stress: StressField?,
                             maxGlyphs: Int = defaultMaxGlyphs) -> LoadPath {
        guard !displacement.isEmpty else { return LoadPath(glyphs: [], segmentLength: 0) }
        let nx = displacement.nx, ny = displacement.ny, nz = displacement.nz
        let spacing = displacement.spacing
        let origin = displacement.origin
        guard nx > 0, ny > 0, nz > 0, spacing > 0 else {
            return LoadPath(glyphs: [], segmentLength: 0)
        }

        // Stride so the total voxel lattice yields ~maxGlyphs samples (the printed
        // subset is smaller, so this stays safely under budget). At least 1.
        let budget = max(1, maxGlyphs)
        let total = Double(nx) * Double(ny) * Double(nz)
        // Cube-root scaling: sampling every `stride`-th voxel per axis gives
        // ~total/stride³ samples, so stride = ⌈(total/budget)^⅓⌉ lands near budget.
        let stride = max(1, Int(pow(max(1.0, total / Double(budget)), 1.0 / 3.0).rounded(.up)))
        let hasStress = !(stress?.isEmpty ?? true)

        var glyphs: [LoadPathGlyph] = []
        var k = 0
        while k < nz {
            var j = 0
            while j < ny {
                var i = 0
                while i < nx {
                    let center = origin + SIMD3<Float>(Float(i) + 0.5, Float(j) + 0.5, Float(k) + 0.5) * spacing
                    // Printed-material gate (skip void voxels) when stress is available.
                    let sv: Float = hasStress ? stress!.value(at: center) : 0
                    if hasStress && sv <= 0 { i += stride; continue }

                    if let g = glyph(displacement: displacement, i: i, j: j, k: k,
                                     center: center, spacing: spacing, stressMPa: sv) {
                        glyphs.append(g)
                    }
                    i += stride
                }
                j += stride
            }
            k += stride
        }

        // Segment ≈ one stride wide so adjacent glyphs read as a continuous path.
        let segLen = spacing * Float(stride) * 0.9
        return LoadPath(glyphs: glyphs, segmentLength: segLen)
    }

    /// The glyph at voxel `(i, j, k)`, or nil when the voxel carries no meaningful
    /// load direction (undeformed / degenerate).
    static func glyph(displacement d: DisplacementField, i: Int, j: Int, k: Int,
                      center: SIMD3<Float>, spacing: Float, stressMPa: Float) -> LoadPathGlyph? {
        let eps = strainTensor(displacement: d, i: i, j: j, k: k, spacing: spacing)
        let pairs = SymmetricEigen.decompose(eps)
        // Dominant axis = largest |eigenvalue| (the strongest principal direction),
        // keeping its signed value for tension/compression.
        var dominant = pairs[0]
        for p in pairs where abs(p.value) > abs(dominant.value) { dominant = p }
        let mag = Float(abs(dominant.value))
        guard mag > strainFloor else { return nil }
        let dir = SIMD3<Float>(dominant.vector)
        let len = simd_length(dir)
        guard len > 1e-6 else { return nil }
        return LoadPathGlyph(position: center, direction: dir / len,
                             stressMPa: stressMPa, principalStrain: Float(dominant.value))
    }

    /// The infinitesimal strain tensor ε = ½(∇u + ∇uᵀ) at voxel `(i, j, k)`'s centre,
    /// returned as symmetric rows. The displacement gradient ∇u is the trilinear
    /// hex-element gradient evaluated at the element centre — for each axis, the mean
    /// forward difference across the voxel's four opposite-face node pairs:
    ///   ∂u/∂x = (1/4h) Σ_{b,c∈{0,1}} [u(i+1, j+b, k+c) − u(i, j+b, k+c)], etc.
    static func strainTensor(displacement d: DisplacementField, i: Int, j: Int, k: Int,
                             spacing: Float) -> [[Double]] {
        let inv = 1.0 / (4.0 * Double(spacing))
        // Columns of the gradient: ∂u/∂x, ∂u/∂y, ∂u/∂z (each a displacement 3-vector).
        var dudx = SIMD3<Double>(repeating: 0)
        var dudy = SIMD3<Double>(repeating: 0)
        var dudz = SIMD3<Double>(repeating: 0)
        for b in 0...1 {
            for c in 0...1 {
                dudx += SIMD3<Double>(d.node(i + 1, j + b, k + c) - d.node(i, j + b, k + c))
            }
        }
        for a in 0...1 {
            for c in 0...1 {
                dudy += SIMD3<Double>(d.node(i + a, j + 1, k + c) - d.node(i + a, j, k + c))
            }
        }
        for a in 0...1 {
            for b in 0...1 {
                dudz += SIMD3<Double>(d.node(i + a, j + b, k + 1) - d.node(i + a, j + b, k))
            }
        }
        dudx *= inv; dudy *= inv; dudz *= inv
        // Gradient G with G[r][c] = ∂u_r/∂x_c (columns are dudx/dudy/dudz).
        let g: [[Double]] = [
            [dudx.x, dudy.x, dudz.x],
            [dudx.y, dudy.y, dudz.y],
            [dudx.z, dudy.z, dudz.z],
        ]
        // ε = ½(G + Gᵀ).
        var eps = [[Double]](repeating: [0, 0, 0], count: 3)
        for r in 0..<3 { for c in 0..<3 { eps[r][c] = 0.5 * (g[r][c] + g[c][r]) } }
        return eps
    }
}
