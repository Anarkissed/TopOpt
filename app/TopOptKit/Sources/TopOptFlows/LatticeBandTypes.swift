import Foundation
import simd

/// ★★★ THE BAND SECTION'S CONTRACT (2026-09-26 redesign, organic capsule preview).
///
/// Under every unselected face the lattice runs ALONGSIDE: grey skin (the body's own
/// surface), then ONE blue rim of constant thickness in the model's shape, then the green
/// grade leading into it, then lattice. The fields below are continuous, geometrically
/// signed distances (never occupancy-signed, never sentinel-gated), so a trilinear read
/// reproduces constant-thickness offsets at any grid phase.
///
/// `LatticeBandFields` (CPU) fills these; the renderer (`LatticeSDFRenderer.setScene`,
/// `lsdf_march`'s rim term, the rim normal and the shell's band rule) reads them.
///
/// The FINE grid is the rim's own: half the preview voxel, padded with air on every side
/// (so clamp-to-edge only ever repeats air), channel layout rgba, x fastest:
///   r = B_r  — the rim zone's inner-boundary SDF: < 0 inside skin ∪ rim (within its
///              footprint), 0 on the rim's inner face, > 0 toward the lattice
///   g = K_s  — ≥ 0 beyond the skin's inner face (the rim starts at 0), < 0 in the skin
///              and in the air beyond an alongside face
///   b = dMat — the part's material SDF (< 0 inside the part), exact distance, geometric sign
///   a = q    — the pocket SDF (whole-prism union, < 0 inside the pocket)
/// The drawn rim is { max(B_r, dMat, q, dBox) ≤ 0 } ∩ { K_s ≥ 0 } (the veil drops the K_s term).
public struct LatticeBandFine: Sendable {
    public var origin: SIMD3<Float>
    public var spacing: Float
    public var dims: SIMD3<Int32>
    /// 4 × dims.x × dims.y × dims.z values, rgba per texel, x fastest
    public var texels: [Float16]

    public init(origin: SIMD3<Float>, spacing: Float, dims: SIMD3<Int32>, texels: [Float16]) {
        self.origin = origin; self.spacing = spacing; self.dims = dims; self.texels = texels
    }

    public var texelCount: Int { Int(dims.x) * Int(dims.y) * Int(dims.z) }

    /// CPU twin of the GPU's linear, clamp-to-edge read at `p` (texel centre i ↔ origin + i·spacing,
    /// the same mapping as `((p − origin)/spacing + 0.5)/dims`). Returns rgba.
    public func sample(_ p: SIMD3<Float>) -> SIMD4<Float> {
        let g = (p - origin) / spacing
        let nx = Int(dims.x), ny = Int(dims.y), nz = Int(dims.z)
        func clampI(_ v: Int, _ n: Int) -> Int { Swift.max(0, Swift.min(n - 1, v)) }
        let fx = g.x.rounded(.down), fy = g.y.rounded(.down), fz = g.z.rounded(.down)
        let tx = g.x - fx, ty = g.y - fy, tz = g.z - fz
        let x0 = clampI(Int(fx), nx), x1 = clampI(Int(fx) + 1, nx)
        let y0 = clampI(Int(fy), ny), y1 = clampI(Int(fy) + 1, ny)
        let z0 = clampI(Int(fz), nz), z1 = clampI(Int(fz) + 1, nz)
        func at(_ x: Int, _ y: Int, _ z: Int) -> SIMD4<Float> {
            let b = 4 * ((z * ny + y) * nx + x)
            return SIMD4(Float(texels[b]), Float(texels[b + 1]), Float(texels[b + 2]), Float(texels[b + 3]))
        }
        let c00 = at(x0, y0, z0) * (1 - tx) + at(x1, y0, z0) * tx
        let c10 = at(x0, y1, z0) * (1 - tx) + at(x1, y1, z0) * tx
        let c01 = at(x0, y0, z1) * (1 - tx) + at(x1, y0, z1) * tx
        let c11 = at(x0, y1, z1) * (1 - tx) + at(x1, y1, z1) * tx
        let c0 = c00 * (1 - ty) + c10 * ty, c1 = c01 * (1 - ty) + c11 * ty
        return c0 * (1 - tz) + c1 * tz
    }
}

/// The band's switches — read ONCE per scene build from the environment; every default is
/// production. The morning options are `capRim`, `veil` and `skinTaper`; the rest are
/// controls that must turn a check red.
public struct LatticeBandOptions: Sendable, Equatable {
    /// `LATTICE_BAND_OFF=1`: the legacy band block, byte for byte (A/B in one binary)
    public var off = false
    /// `LATTICE_BAND_CAP_RIM=1`: a rim facing the solid where a prism's depth cap ends inside material
    public var capRim = false
    /// `LATTICE_BAND_VEIL=1`: draw the skin (grey) over the rim in the lattice layer
    public var veil = false
    /// `LATTICE_BAND_SKIN_TAPER=0`: keep the full skin up to a footprint clip (a 1.2 mm notch)
    public var skinTaper = true
    /// `LATTICE_BAND_K1=1`: the fine grid at the preview voxel (control)
    public var fineAtCoarse = false
    /// `LATTICE_BAND_NO_PAD=1`: fine grid origin on bounds.min (control)
    public var noPad = false
    /// `LATTICE_BAND_SIGN_FROM_SOLID=1`: sign the alongside distance by occupancy (control)
    public var signFromSolid = false
    /// `LATTICE_BAND_PER_TRIANGLE=1`: the old per-triangle passed-through rule (control)
    public var perTriangle = false
    /// `LATTICE_BAND_NO_FOOTPRINT=1`: bands round every edge (control)
    public var noFootprint = false
    /// `LATTICE_BAND_NO_RIMFOOT=1`: green not gated by the rim's foot lying in the pocket (control)
    public var noRimFoot = false
    /// `LATTICE_BAND_INCLUDE_SELECTED=1`: selected faces banded too (control)
    public var includeSelected = false

    public init() {}

    public static func fromEnvironment() -> LatticeBandOptions {
        let e = ProcessInfo.processInfo.environment
        func on(_ k: String) -> Bool { e[k] == "1" }
        var o = LatticeBandOptions()
        o.off = on("LATTICE_BAND_OFF")
        o.capRim = on("LATTICE_BAND_CAP_RIM")
        o.veil = on("LATTICE_BAND_VEIL")
        o.skinTaper = e["LATTICE_BAND_SKIN_TAPER"] != "0"
        o.fineAtCoarse = on("LATTICE_BAND_K1")
        o.noPad = on("LATTICE_BAND_NO_PAD")
        o.signFromSolid = on("LATTICE_BAND_SIGN_FROM_SOLID")
        o.perTriangle = on("LATTICE_BAND_PER_TRIANGLE")
        o.noFootprint = on("LATTICE_BAND_NO_FOOTPRINT")
        o.noRimFoot = on("LATTICE_BAND_NO_RIMFOOT")
        o.includeSelected = on("LATTICE_BAND_INCLUDE_SELECTED")
        return o
    }
}
