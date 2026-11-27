// FlexibleFEStress — the Stress view of the main Flexible page from each squeeze group's OWN 3D
// sim (task 2026-09-29-flexible-screens, round 5 batch M, M3; his words, img 4: "Stress is not
// able to simulate; I imagine it should simulate the group that is playing/selected").
//
// ★ WHY IT FAILED ON HIS PAD (FlexibleBatchMProbe.testWhyHisStressCouldNotSimulate). The Stress view
// ran the SOLID part's load case (LatticeSimModel) with the main page's groups. His 'Top' group
// presses region 105 "Union of 2" (top A + top B). A union carries its members as `parts`, which the
// region spec handed to core does not have (FaceRegion.kitSpec: id, parent, add, remove, cuts,
// filter — no parts), so core received region 105 with NO faces and refused the whole solve:
// "face region 105 resolves to NO faces on this model … it is refused instead". (The context the
// app builds for the octet fails one step earlier, on his stale region 101: "face id 23 out of
// range".) Both are #354's region mapping, outside this track — reported in the handoff.
//
// ★ WHAT IT IS NOW. The group's sim already solved the whole part under THAT group's force
// (FlexibleFEField: nodal u, each element's secant modulus E — FlexibleSquishSolutionInfo.elementE).
// Per element: the small strain at its centre, ε = sym ∇u (the Hex8's trilinear field), from the
// RAW displacement (u / scale — the force the bridge applied is core's design force; k only scales
// the picture), σ = λ tr(ε) I + 2μ ε with ν = FlexibleFE.poisson, and von Mises. Per node: the mean
// over the solid elements round it (a smooth field the part's surface and the walls sample). It
// follows the picker (the shown group's field) and plays with "Play all" (each turn its own).
// Linear small strain — like the field it comes from (the Squish (i) says so).
// Pure value math.

import Foundation
import simd

public enum FlexibleFEStress {

    /// Von Mises (MPa) of a small-strain state ε (xx, yy, zz, xy, yz, zx — the TENSOR shears) in a
    /// linear isotropic material (E, ν).
    public static func vonMises(e: Double, nu: Double, xx: Double, yy: Double, zz: Double,
                                xy: Double, yz: Double, zx: Double) -> Double {
        let lambda = e * nu / ((1 + nu) * (1 - 2 * nu)), mu = e / (2 * (1 + nu))
        let tr = xx + yy + zz
        let sxx = lambda * tr + 2 * mu * xx, syy = lambda * tr + 2 * mu * yy, szz = lambda * tr + 2 * mu * zz
        let sxy = 2 * mu * xy, syz = 2 * mu * yz, szx = 2 * mu * zx
        let a = (sxx - syy) * (sxx - syy) + (syy - szz) * (syy - szz) + (szz - sxx) * (szz - sxx)
        return (0.5 * a + 3 * (sxy * sxy + syz * syz + szx * szx)).squareRoot()
    }

    /// Per ELEMENT: its centre's von Mises (MPa) from `f`'s RAW displacement and its modulus (0 where no
    /// solid). nil when the field carries no moduli (a field built from parts).
    public static func elementVonMises(_ f: FlexibleFEField, nu: Double = FlexibleFE.poisson) -> [Float]? {
        let ex = f.nx - 1, ey = f.ny - 1, ez = f.nz - 1
        guard ex > 0, ey > 0, ez > 0, f.elementE.count == ex * ey * ez, f.spacing > 0 else { return nil }
        let inv = 1 / Swift.max(1e-12, f.scale)   // raw = u / k
        let h = Double(f.spacing)
        var out = [Float](repeating: 0, count: f.elementE.count)
        for c in 0..<ez { for b in 0..<ey { for a in 0..<ex {
            let e = (c * ey + b) * ex + a
            let E = Double(f.elementE[e])
            guard E > 0 else { continue }
            // ∂u/∂x at the centre: the mean of the four x-edges' differences / h (and so on)
            var gx = SIMD3<Double>.zero, gy = SIMD3<Double>.zero, gz = SIMD3<Double>.zero
            for k in 0...1 { for j in 0...1 {
                gx += SIMD3<Double>(f.u[f.node(a + 1, b + j, c + k)] - f.u[f.node(a, b + j, c + k)])
            } }
            for k in 0...1 { for i in 0...1 {
                gy += SIMD3<Double>(f.u[f.node(a + i, b + 1, c + k)] - f.u[f.node(a + i, b, c + k)])
            } }
            for j in 0...1 { for i in 0...1 {
                gz += SIMD3<Double>(f.u[f.node(a + i, b + j, c + 1)] - f.u[f.node(a + i, b + j, c)])
            } }
            let s = inv / (4 * h)
            gx *= s; gy *= s; gz *= s
            // gx = ∂u/∂x (a vector: ∂ux/∂x, ∂uy/∂x, ∂uz/∂x), …
            let xx = gx.x, yy = gy.y, zz = gz.z
            let xy = 0.5 * (gy.x + gx.y), yz = 0.5 * (gz.y + gy.z), zx = 0.5 * (gx.z + gz.x)
            out[e] = Float(vonMises(e: E, nu: nu, xx: xx, yy: yy, zz: zz, xy: xy, yz: yz, zx: zx))
        } } }
        return out
    }

    /// Per NODE: the mean von Mises of the solid elements round it (0 where none) — the field the
    /// part's surface and the walls are coloured by, and a tap reads (LatticeStressTint.sample: node
    /// (0,0,0) at the field's corner, trilinear). nil when the field carries no moduli.
    public static func field(_ f: FlexibleFEField) -> LatticeDemandField? {
        guard let el = elementVonMises(f) else { return nil }
        let ex = f.nx - 1, ey = f.ny - 1
        var sum = [Float](repeating: 0, count: f.nx * f.ny * f.nz), n = [Float](repeating: 0, count: sum.count)
        for e in el.indices where f.elementE[e] > 0 {
            let a = e % ex, b = (e / ex) % ey, c = e / (ex * ey)
            for k in 0...1 { for j in 0...1 { for i in 0...1 {
                let q = f.node(a + i, b + j, c + k)
                sum[q] += el[e]; n[q] += 1
            } } }
        }
        let vm = zip(sum, n).map { $1 > 0 ? $0 / $1 : 0 }
        return LatticeDemandField(vonMises: vm, nx: f.nx, ny: f.ny, nz: f.nz, origin: SIMD3<Double>(f.origin),
                                  spacingMM: Double(f.spacing), provenance: .solidSim(date: Date(), resolution: f.nx))
    }

    /// ★ BATCH M VERIFICATION (the UX finding: Group 1's Stress — and "Play all"'s, the default — was ONE
    /// flat colour: the scale's top was the single peak, a 0.799 MPa hot spot at Face 5's edge, so 97.9 %
    /// of his part sat in the bottom fifth of the ramp). The colour scale's TOP: this percentile of the
    /// stressed nodes' von Mises. Above it the ramp's last colour; the legend's end says "≥"; a tap still
    /// reads the true MPa.
    public static let scalePercentile = 0.95

    /// The colour scale's top for a stress field (MPa): the `percentile` of its nodes above 0 (0: none).
    public static func scaleTop(_ s: LatticeDemandField, percentile q: Double = scalePercentile) -> Double {
        var v = s.vonMises.filter { $0 > 0 && $0.isFinite }
        guard !v.isEmpty else { return 0 }
        v.sort()
        let i = Swift.min(v.count - 1, Swift.max(0, Int((q * Double(v.count - 1)).rounded())))
        return Double(v[i])
    }

    /// ★ BATCH M VERIFICATION: the Stress line while the lattice the group sims run on cannot come yet (a
    /// blocker the pill names, or a failed build) — never "Simulating…" for ever.
    public static let waitsForLattice = "Simulates once the lattice is built"

    /// The Stress legend's one line while it cannot draw: why, in ONE line (core's words behind the (i)).
    public static func failedLine(_ why: String) -> String {
        let w = why.lowercased()
        if w.contains("deadline") || w.contains("time") { return "Couldn't simulate: it took too long" }
        if w.contains("converge") || w.contains("tolerance") || w.contains("stagnat") { return "Couldn't simulate: the sim did not settle" }
        if w.contains("opening") { return "Couldn't simulate: the part is still opening" }
        return "Couldn't simulate: the sim failed"
    }
}
