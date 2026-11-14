// FlexibleStampFootprint — a Stamp face's footprint, smoothed on its column grid, and the
// ½ contour its depth prism stands on (task 2026-09-29-flexible-screens, round 4 batch D1
// verification).
//
// ★ WHY (the verifier's renders of his top A under a thumb pad): the stamp's cover is a 0/1
// step one column wide. The dent's corners are each the mean of the four columns round them
// (FlexibleOverlayMesh.displacements), so along the STAIRCASE of the stamp's edge the corners
// alternate ¼ / ¾ of a 12 mm (3 mm × 4) cliff over a 1.6 mm pitch — the pit's far wall drew
// as a row of teeth, and the purple prism (on the ≥ ½ columns, a stair-stepped outline) wore a
// sawtooth crown. So:
//   * `smoothed`: the cover, blurred on the column grid by `passes` binomial [1 4 6 4 1] / 16
//     passes (normalised over the columns that exist, so the face's own edge does not pull the
//     stamp down), then scaled so its peak is 1 again (a fingertip still sinks the deepest
//     squish at its middle). The wall slopes over a few pitches, and corners at one distance
//     from the stamp's edge sink alike (FlexibleSettingsVerifyD1Tests measures that spread);
//   * `contour`: the prism's base is the smoothed footprint's ½ contour, marching squares on
//     the grid of column CENTRES (so the base follows a curved face too) — a smooth outline,
//     not a staircase of whole columns.
// Pure value math.

import Foundation
import simd
import TopOptKit

enum FlexibleStampFootprint {

    /// Binomial passes (σ ≈ 1 pitch each; two ≈ 1.4 pitches).
    static let passes = 2
    /// The prism stands where the footprint is at least this.
    static let level = 0.5

    /// The cover `raw` (per column, 0…1) blurred on the stack's column grid, peak 1.
    static func smoothed(_ raw: [Double], stack st: FlexStackInfo, passes: Int = passes) -> [Double] {
        guard st.nu > 0, st.nv > 0, raw.count == st.columns.count, passes > 0 else { return raw }
        let nu = st.nu, nv = st.nv
        var v = [Double](repeating: 0, count: nu * nv), w = [Double](repeating: 0, count: nu * nv)
        for (c, col) in st.columns.enumerated() where col.iu >= 0 && col.iv >= 0 && col.iu < nu && col.iv < nv {
            v[col.iv * nu + col.iu] = raw[c]
            w[col.iv * nu + col.iu] = 1
        }
        let k: [Double] = [1, 4, 6, 4, 1]
        func pass(_ a: [Double], alongU: Bool) -> [Double] {
            var out = a
            for j in 0..<nv {
                for i in 0..<nu where w[j * nu + i] > 0 {
                    var s = 0.0, ws = 0.0
                    for (t, kt) in k.enumerated() {
                        let d = t - 2
                        let ii = alongU ? i + d : i, jj = alongU ? j : j + d
                        guard ii >= 0, jj >= 0, ii < nu, jj < nv else { continue }
                        let n = jj * nu + ii
                        guard w[n] > 0 else { continue }
                        s += kt * a[n]; ws += kt
                    }
                    out[j * nu + i] = ws > 0 ? s / ws : a[j * nu + i]
                }
            }
            return out
        }
        for _ in 0..<passes { v = pass(pass(v, alongU: true), alongU: false) }
        var out = st.columns.map { col -> Double in
            guard col.iu >= 0, col.iv >= 0, col.iu < nu, col.iv < nv else { return 0 }
            return v[col.iv * nu + col.iu]
        }
        if let peak = out.max(), peak > 1e-9 { out = out.map { min(1, $0 / peak) } }
        return out
    }

    /// The ½ contour of `values` as a triangulated base: points on the face (each a column's
    /// surface point, or a crossing between two neighbouring columns' points) and triangles
    /// wound as the depth prism's (out of the part, along −load). Marching squares on the grid
    /// of column centres; a cell with a missing corner column is skipped (the base stops half a
    /// pitch inside the face's own edge). Shared corners and crossings are ONE vertex, so the
    /// base is closed and its only boundary is the contour.
    static func contour(stack st: FlexStackInfo, surface: [SIMD3<Double>], values: [Double],
                        level: Double = level) -> (points: [SIMD3<Double>], triangles: [UInt32])? {
        guard values.count == st.columns.count, surface.count == st.columns.count, st.nu > 1, st.nv > 1 else { return nil }
        var points: [SIMD3<Double>] = []
        var tri: [UInt32] = []
        var cornerIndex: [Int: UInt32] = [:]
        struct EdgeKey: Hashable { let a: Int; let b: Int }
        var edgeIndex: [EdgeKey: UInt32] = [:]
        func corner(_ c: Int) -> UInt32 {
            if let i = cornerIndex[c] { return i }
            points.append(surface[c]); cornerIndex[c] = UInt32(points.count - 1)
            return UInt32(points.count - 1)
        }
        func crossing(_ a: Int, _ b: Int) -> UInt32 {
            let lo = min(a, b), hi = max(a, b), key = EdgeKey(a: lo, b: hi)
            if let i = edgeIndex[key] { return i }
            let vl = values[lo], vh = values[hi]
            let t = abs(vh - vl) > 1e-12 ? max(0, min(1, (level - vl) / (vh - vl))) : 0.5
            points.append(surface[lo] + (surface[hi] - surface[lo]) * t)
            edgeIndex[key] = UInt32(points.count - 1)
            return UInt32(points.count - 1)
        }
        for iv in 0..<(st.nv - 1) {
            for iu in 0..<(st.nu - 1) {
                // counter-clockwise in (u, v): A (iu, iv), B (iu+1, iv), C (iu+1, iv+1), D (iu, iv+1)
                let cs = [st.column(iu, iv), st.column(iu + 1, iv), st.column(iu + 1, iv + 1), st.column(iu, iv + 1)]
                guard cs.allSatisfy({ $0 >= 0 && $0 < values.count }) else { continue }
                let inside = cs.map { values[$0] >= level }
                guard inside.contains(true) else { continue }
                var poly: [UInt32] = []
                for e in 0..<4 {
                    let p = cs[e], q = cs[(e + 1) % 4]
                    if inside[e] { poly.append(corner(p)) }
                    if inside[e] != inside[(e + 1) % 4] { poly.append(crossing(p, q)) }
                }
                guard poly.count >= 3 else { continue }
                // convex in every case (the saddle's connected hexagon too): a fan from the first,
                // wound as the prism's quads (FlexibleDepthPrism: [a, c, b, a, d, c])
                for i in 1..<(poly.count - 1) { tri += [poly[0], poly[i + 1], poly[i]] }
            }
        }
        return tri.isEmpty ? nil : (points, tri)
    }
}
