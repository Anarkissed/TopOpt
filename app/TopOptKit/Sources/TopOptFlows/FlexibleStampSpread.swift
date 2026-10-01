// FlexibleStampSpread — a stamp's press SPREADS out and its foci merge into ONE input (task
// 2026-09-29-flexible-screens, round 5 batch M, M2; his words, img 4: "the stamps are seen as
// isolated areas, disconnected to the rest of the lattice, rather than pulling on the rest of the
// lattice with it. When squished, it should have foci but expand out, pulling lattice next to it
// in, combining the foci into a single input" — and "this and the graded dent colours should be in
// both views").
//
// ★ BATCH M2 (V10 of batch M's verification: "the Settings page's stamp dent is a steep trench with
// saw-tooth edges and disagrees with the main page"). Batch M drew the stamp sinking its FULL depth
// under all of its footprint, then falling off as e^(−r / 0.2·depth) — on C1's pad a 4 mm wall drawn
// ×2 deep, two flat triangles per 1.56 mm column: a trench whose edges zig-zag at the pitch, beside a
// main page (the 3D sim) whose press is broad and soft. Now the Settings page spreads the stamp the
// way the sim does, from what core designs:
//     press(x)   = foot(x) + b · (1 − foot(x))          — the stamp, plus core's even press round it
//     squish(x)  = press(x) / (ρ₀ + ρ(x))               — a denser column squishes less (ρ: core's
//                                                         density under the stamp / outside it)
//     dent(x)    = (squish ⊛ G_σ)(x) / its deepest       — one Gaussian of σ = 0.45 × the face's
//                                                         lattice depth, the face's own columns only
// The deepest point is still his deepest squish (each fingertip's focus); the fingertips merge into
// one press (the ground between them 0.9 of it on his Face 3), the dent fades with no edge, and the
// face's far ground sinks by core's even press — as the sim's does. FITTED to the 3D sim's own map
// (FlexibleBatchM2Probe, column for column, normalised by each page's top): C1's pad with four
// fingertips at 3 kg / 6 mm RMS 0.05 (batch M 0.12), at 10 kg / 3 mm 0.07 (0.27), a thumb 0.06
// (0.19), his Face 3 0.06 (0.19). NOT matched: a face whose group presses ANOTHER face beside it
// (his Group 1: Face 5's sim peaks at its top edge, pulled by the top's press) — one face's picture
// cannot carry the other's (core brief #35).
// ★ THE SCALARS, NOT core's per-column numbers: the footprint moves the instant the stamp is dragged,
// core's design follows a moment later — b and ρ are read from the last design as three numbers, so
// the dent follows his finger at once (no design yet: b = 0, ρ even — the footprint alone, spread).
// ★ THE MAIN PAGE does not use this: there the 3D sim's own field is the dent (FlexibleMainStage+
// Squish.feMapValues). Core's design_stamp still designs the density under the stamp alone (core
// brief #33). Pure value math on the stack's column grid.

import Foundation
import TopOptKit

enum FlexibleStampSpread {

    /// σ of the spread as a share of the face's mean lattice depth (≥ one column pitch) — FITTED to the
    /// 3D sim (see above): his 20 mm top and C1's pad spread over σ 9 mm, his 100 mm-deep sides 45 mm.
    static let sigmaShareOfDepth = 0.45
    /// ρ₀: the stiffness floor of a column (its squish is the press over ρ₀ + ρ) — FITTED with σ.
    static let stiffnessFloor = 0.2
    /// The Gaussian is cut at this many σ (e^−4.5 ≈ 1 %).
    static let reach = 3.0

    /// What core's design says round the stamp: its even press elsewhere over the stamp's peak, and the
    /// density it designed under the stamp and outside it (medians). `.none` before a design.
    struct Design: Equatable {
        var background = 0.0
        var densityUnder = 0.0
        var densityOutside = 0.0
        static let none = Design()

        /// From core's design of the face (`foot`: the stamp's footprint, to tell under from outside).
        init(_ d: FlexFaceDesignInfo?, foot: [Double]) {
            guard let d, d.refusal == nil, d.columns.count == foot.count, !foot.isEmpty else { return }
            let peak = d.columns.map(\.pressureMPa).max() ?? 0
            func median(_ x: [Double]) -> Double? {
                guard !x.isEmpty else { return nil }
                let s = x.sorted()
                return s[s.count / 2]
            }
            let under = foot.indices.filter { foot[$0] >= 0.5 }, outside = foot.indices.filter { foot[$0] < 0.05 }
            if peak > 0, let p = median(outside.map { d.columns[$0].pressureMPa }) { background = min(1, max(0, p / peak)) }
            let ru = median(under.map { d.columns[$0].targetDensity }) ?? 0
            densityUnder = max(0, ru)
            densityOutside = max(0, median(outside.map { d.columns[$0].targetDensity }) ?? ru)
        }
        init() {}
    }

    /// The spread's σ for a face's stack (mm).
    static func sigmaMM(_ st: FlexStackInfo) -> Double {
        Swift.max(st.pitchMM, sigmaShareOfDepth * st.latticeMMMean)
    }

    /// The stamp's designed dent per column (0…1, its deepest 1): the press over each column's
    /// stiffness, spread by one Gaussian of `sigmaMM` over the face's own columns.
    static func dent(_ foot: [Double], stack st: FlexStackInfo, design: Design, sigmaMM: Double) -> [Double] {
        guard foot.count == st.columns.count, !foot.isEmpty else { return foot }
        let squish = foot.map { f -> Double in
            let f = Swift.min(1, Swift.max(0, f))
            let press = f + design.background * (1 - f)
            let rho = f * design.densityUnder + (1 - f) * design.densityOutside
            return press / (stiffnessFloor + rho)
        }
        let s = gaussian(squish, stack: st, sigmaMM: sigmaMM)
        guard let top = s.max(), top > 1e-12 else { return foot }
        return s.map { Swift.max(0, $0 / top) }
    }

    /// `x` (one value per column) convolved with a Gaussian of `sigmaMM` on the stack's column grid —
    /// SEPARABLE (along u, then along v), zero where the face has no column (the face's own ground
    /// only, as its outline holds the sim's). O(cells × taps): a 64 × 64 face at σ 9 mm is ~0.3 M.
    static func gaussian(_ x: [Double], stack st: FlexStackInfo, sigmaMM: Double) -> [Double] {
        let nu = st.nu, nv = st.nv
        guard nu > 0, nv > 0, st.cell.count == nu * nv, st.pitchMM > 0, sigmaMM > 0, x.count == st.columns.count else { return x }
        let sig = sigmaMM / st.pitchMM
        let r = Swift.min(Swift.max(nu, nv), Int((reach * sig).rounded(.up)))
        let taps = (0...r).map { exp(-0.5 * Double($0 * $0) / (sig * sig)) }
        var grid = [Double](repeating: 0, count: nu * nv)
        for (i, c) in st.cell.enumerated() where c >= 0 && c < x.count { grid[i] = x[c] }
        var pass = [Double](repeating: 0, count: nu * nv)
        for iv in 0..<nv {
            let row = iv * nu
            for iu in 0..<nu {
                var s = grid[row + iu] * taps[0]
                for k in 1...Swift.max(1, r) where k <= r {
                    if iu - k >= 0 { s += grid[row + iu - k] * taps[k] }
                    if iu + k < nu { s += grid[row + iu + k] * taps[k] }
                }
                pass[row + iu] = s
            }
        }
        var out = [Double](repeating: 0, count: x.count)
        for iv in 0..<nv {
            for iu in 0..<nu {
                let c = st.cell[iv * nu + iu]
                guard c >= 0, c < out.count else { continue }
                var s = pass[iv * nu + iu] * taps[0]
                for k in 1...Swift.max(1, r) where k <= r {
                    if iv - k >= 0 { s += pass[(iv - k) * nu + iu] * taps[k] }
                    if iv + k < nv { s += pass[(iv + k) * nu + iu] * taps[k] }
                }
                out[c] = s
            }
        }
        return out
    }

    // MARK: batch M's spread (the RED control of batch M2's test, and batch M's probe)

    /// Batch M's L as a share of the face's mean lattice depth (fitted to the sim's 0–8 mm rings).
    static let shareOfDepth = 0.2
    /// Test control only (batch M2's RED control): batch M's spread, whatever the page's rule.
    @MainActor static var controlBatchMSpread = false
    /// Batch M's kernel cut (e^−5).
    static let batchMReach = 5.0

    /// Batch M's decay length: `shareOfDepth` × the face's mean lattice depth, ≥ one column pitch.
    static func lengthMM(_ st: FlexStackInfo) -> Double {
        Swift.max(st.pitchMM, shareOfDepth * st.latticeMMMean)
    }

    /// Batch M's spread: max(foot, softCap(foot ⊛ e^(−r / L) / the same at the stamp's outline)) — the
    /// full sink under all of the footprint, a wall of decay length L outside it.
    static func spread(_ foot: [Double], stack st: FlexStackInfo, lengthMM L: Double) -> [Double] {
        let cols = st.columns
        guard foot.count == cols.count, st.nu > 0, st.nv > 0, st.pitchMM > 0, L > 0 else { return foot }
        let p = st.pitchMM
        let r = Int((batchMReach * L / p).rounded(.up))
        var taps: [(du: Int, dv: Int, w: Double)] = []
        var total = 0.0
        for dv in -r...r { for du in -r...r {
            let d = (Double(du * du + dv * dv)).squareRoot() * p
            guard d <= batchMReach * L else { continue }
            let w = exp(-d / L)
            taps.append((du, dv, w)); total += w
        } }
        guard total > 0 else { return foot }
        var conv = [Double](repeating: 0, count: cols.count)
        for (c, f) in foot.enumerated() where f > 1e-9 {
            let col = cols[c]
            for t in taps {
                let n = st.column(col.iu + t.du, col.iv + t.dv)
                guard n >= 0, n < conv.count else { continue }
                conv[n] += f * t.w / total
            }
        }
        var edge: [Double] = []
        for (c, col) in cols.enumerated() where foot[c] >= 0.5 {
            let ring = [(1, 0), (-1, 0), (0, 1), (0, -1)].map { st.column(col.iu + $0.0, col.iv + $0.1) }
            if ring.contains(where: { $0 < 0 || $0 >= foot.count || foot[$0] < 0.5 }) { edge.append(conv[c]) }
        }
        edge.sort()
        let level = edge.isEmpty ? 0.5 : edge[edge.count / 2]
        guard level > 1e-12 else { return foot }
        return foot.indices.map { Swift.max(foot[$0], softCap(conv[$0] / level)) }
    }

    /// Batch M's full-sink cap, smooth (C¹).
    static let capBlend = 0.3
    static func softCap(_ x: Double) -> Double {
        let d = capBlend
        if x <= 1 - d { return x }
        if x >= 1 + d { return 1 }
        let t = x - (1 - d)
        return x - t * t / (4 * d)
    }
}

extension FlexibleStageModel {
    /// ★ BATCH M (M2) → ★ BATCH M2: a Stamp face's DESIGNED squish per column (0…1, its deepest 1) — the
    /// stamp's press spread as the 3D sim spreads it, its foci merged (FlexibleStampSpread.dent) — what
    /// the Settings page's map shows and dents by. nil for a Curves face or before the grid is laid.
    /// The depth prism still stands on the stamp itself (`stampFootprint`).
    public func stampDent(_ r: Int) -> [Double]? {
        guard let foot = stampFootprint(r), let st = stack(r) else { return nil }
        if FlexibleStampSpread.controlBatchMSpread {
            return FlexibleStampSpread.spread(foot, stack: st, lengthMM: FlexibleStampSpread.lengthMM(st))
        }
        let design = FlexibleStampSpread.Design(key(r).flatMap { designs[$0] }, foot: foot)
        return FlexibleStampSpread.dent(foot, stack: st, design: design, sigmaMM: FlexibleStampSpread.sigmaMM(st))
    }
}
