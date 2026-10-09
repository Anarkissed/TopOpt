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
//     dent(x)    = (squish ⊛ (w G_near + (1 − w) G_far))(x) / its deepest
//                  — two Gaussians over the face's own columns: the near one keeps each fingertip's
//                  FOCUS, the far one is the broad press
// ★ M2 VERIFICATION (his Face 3 lost its four foci): batch M2 tied σ_near to the lattice depth (0.25 ×
// depth, weight 0.3) — on his 100 mm-deep side 25 mm, wider than the fingertips' 17–19 mm spacing, so
// the Settings page drew ONE hill where the main page's sim shows four foci (correlation 0.36, 0.31 ×
// its swing). A fingertip's focus is as wide as the FINGERTIP, and on a deep lattice the broad press
// outweighs it. Now (Rule.shipped):
//     σ_near = min(0.25 × depth, 0.4 × the stamp's feature)   feature: the radius of the largest disc
//                                                              in its footprint (a fingertip ≈ 6 mm)
//     σ_far  = 0.5 × depth                                    depth: the face's mean lattice depth
//     w      = 0.35 × σ_near / σ_far                          (each σ ≥ one column pitch; ρ₀ = 0.25)
// FITTED jointly to the 3D sim's own map on six faces (FlexibleBatchM2Probe dumps both pages per stamp
// face; column for column, each over its face's deepest), whole-face RMS (batch M2 → now): C1's pad,
// four fingertips 3 kg / 6 mm 0.047 → 0.044, 10 kg / 3 mm 0.072 → 0.080, a thumb 0.051 → 0.066; his
// Face 3 0.088 → 0.064, Top A 0.167 → 0.147, Face 5 0.450 → 0.310. Along the fingertips the foci rise
// and dip with the sim's on the pad (correlation 0.98 / 0.98, 1.11 / 0.68 × its swing) AND on his Face 3
// (0.98, 0.87 ×). The deepest point is still his deepest squish.
// NOT matched: the OUTLINE — C1's pad holds its top's outline at 0.01–0.07 of the deepest (its side
// walls), the Settings page reads ~0.1 there (0.5 under a whole-face plate); his Top A and Face 3 do not
// hold theirs at all (their sim's edges 0.3–0.9) — a picture of one face does not know its walls. And a
// face whose group presses ANOTHER face beside it (his Group 1: Face 5's sim peaks at its top edge,
// pulled by the top's press) — one face's picture cannot carry the other's (core brief #35).
// ★ THE SCALARS, NOT core's per-column numbers: the footprint moves the instant the stamp is dragged,
// core's design follows a moment later — b and ρ are read from the last design as three numbers, so
// the dent follows his finger at once.
// ★ M2 VERIFICATION: the three numbers are read from the design's OWN press (Design.init), never under
// the stamp's current footprint — so nothing pops when core's new design lands after a drag; and before
// the FIRST design, b is the stamp's area over the face's (core's own reading, Design.beforeDesign), ρ even.
// ★ THE MAIN PAGE does not use this: there the 3D sim's own field is the dent (FlexibleMainStage+
// Squish.feMapValues). Core's design_stamp still designs the density under the stamp alone (core
// brief #33). Pure value math on the stack's column grid.

import Foundation
import TopOptKit

enum FlexibleStampSpread {

    /// The spread's rule: the two Gaussians' σ, the near one's weight, and a column's stiffness floor.
    struct Rule: Equatable {
        /// σ_near = min(this × the face's mean lattice depth, `nearShareOfFeature` × the stamp's feature)
        var nearShareOfDepth: Double
        /// … × `featureMM` (the radius of the largest disc inside the footprint); nil: the depth alone
        var nearShareOfFeature: Double?
        /// σ_far = this × the face's mean lattice depth
        var farShareOfDepth: Double
        var nearWeight: NearWeight
        /// ρ₀: a column's squish is its press over ρ₀ + ρ
        var stiffnessFloor: Double

        enum NearWeight: Equatable {
            /// a fixed share (batch M2: 0.3)
            case fixed(Double)
            /// k × σ_near / σ_far: on a deep lattice the broad press outweighs a fingertip's own
            case ofSigmas(Double)
        }

        /// ★ M2 VERIFICATION — FITTED to the 3D sim on six faces (FlexibleBatchM2Probe's dumps: C1's pad
        /// with four fingertips at 3 kg / 6 mm and 10 kg / 3 mm, a thumb at 10 kg / 4 mm, his Face 3, Top A
        /// and Face 5), the foci held on the pad AND his Face 3 (see the file's header).
        static let shipped = Rule(nearShareOfDepth: 0.25, nearShareOfFeature: 0.4, farShareOfDepth: 0.5,
                                  nearWeight: .ofSigmas(0.35), stiffnessFloor: 0.25)
        /// Batch M2's rule (the verification's RED control): σ 0.25 / 0.6 × depth, the near one weighs 0.3.
        static let batchM2 = Rule(nearShareOfDepth: 0.25, nearShareOfFeature: nil, farShareOfDepth: 0.6,
                                  nearWeight: .fixed(0.3), stiffnessFloor: 0.2)

        /// The two σ (mm, each ≥ one column pitch) on a face's stack for a stamp of `featureMM`.
        func sigmasMM(_ st: FlexStackInfo, featureMM: Double) -> (near: Double, far: Double) {
            var near = nearShareOfDepth * st.latticeMMMean
            if let s = nearShareOfFeature { near = Swift.min(near, s * Swift.max(0, featureMM)) }
            return (Swift.max(st.pitchMM, near), Swift.max(st.pitchMM, farShareOfDepth * st.latticeMMMean))
        }

        /// The near Gaussian's weight (the far one weighs the rest).
        func nearWeight(_ s: (near: Double, far: Double)) -> Double {
            switch nearWeight {
            case .fixed(let w): return w
            case .ofSigmas(let k): return s.far > 0 ? Swift.min(1, Swift.max(0, k * s.near / s.far)) : 1
            }
        }
    }

    /// Test control only (the M2 verification's RED control): a rule other than the shipped one.
    @MainActor static var controlRule: Rule?
    /// A Gaussian is cut at this many σ (e^−8 ≈ 0.03 %).
    static let reach = 4.0

    /// What core's design says round the stamp: its even press elsewhere over the stamp's peak, and the
    /// density it designed under the stamp and outside it (medians). `.none` before a design.
    struct Design: Equatable {
        var background = 0.0
        var densityUnder = 0.0
        var densityOutside = 0.0
        static let none = Design()

        /// From core's design of a face of `columns` columns. ★ M2 VERIFICATION (a dragged stamp popped
        /// when core's new design landed): under / outside are read from the design's OWN press — a column
        /// at half its peak over core's even press or more is under the stamp, one at the even press is
        /// outside — never from the stamp's CURRENT footprint. Straight after a drag the last design still
        /// describes the old place; its columns under the new footprint carried the old "outside" density,
        /// so the three numbers jumped when the new design arrived (a thumb at 10 kg: 0.08 of the deepest).
        init(_ d: FlexFaceDesignInfo?, columns n: Int) {
            guard let d, d.refusal == nil, d.columns.count == n, n > 0 else { return }
            let p = d.columns.map(\.pressureMPa)
            guard let peak = p.max(), peak > 0 else { return }
            func median(_ x: [Double]) -> Double? {
                guard !x.isEmpty else { return nil }
                let s = x.sorted()
                return s[s.count / 2]
            }
            let rho = d.columns.map(\.targetDensity)
            let even = Swift.max(0, d.designPressureEvenMPa), span = peak - even
            guard span > 1e-9 * peak else {
                // pressed evenly all over (a whole-face stamp, or no stamp in the design): all of it is under
                densityUnder = Swift.max(0, median(rho) ?? 0)
                densityOutside = densityUnder
                return
            }
            let under = p.indices.filter { (p[$0] - even) / span >= 0.5 }
            let outside = p.indices.filter { abs(p[$0] - even) <= 1e-6 * peak }
            if !outside.isEmpty { background = Swift.min(1, even / peak) }
            let ru = median(under.map { rho[$0] }) ?? 0
            densityUnder = Swift.max(0, ru)
            densityOutside = Swift.max(0, median(outside.map { rho[$0] }) ?? ru)
        }
        init() {}

        /// ★ M2 VERIFICATION: before core's FIRST design of the face lands (or while core refuses it), the
        /// even press round the stamp from the stamp itself. Core reads the face's weight over the face's
        /// area and the stamp's force (the same weight) over the stamp's, so b = the stamp's area / the
        /// face's (`stampAreaMM2`: soft, all of its grid; rigid, what lands on the face — core's own two
        /// readings). The densities stay even until core designs them. (Without it the first design's even press arrived as a jump: his
        /// Face 3's fingertips read 72 % of the deepest between them before it, 88 % after.)
        static func beforeDesign(stampAreaMM2: Double, faceAreaMM2: Double) -> Design {
            var d = Design()
            if stampAreaMM2 > 0, faceAreaMM2 > 0 { d.background = Swift.min(1, stampAreaMM2 / faceAreaMM2) }
            return d
        }
    }

    /// The stamp's FEATURE: the radius (mm) of the largest disc inside its footprint — the columns at ½
    /// or more; off the face counts as outside — between column centres, exact (Felzenszwalb–Huttenlocher's
    /// squared distance transform, rows then columns). A fingertip ≈ 6 mm, a thumb ≈ 9, a palm ≈ 40.
    /// 0 when no column is at ½.
    static func featureMM(_ foot: [Double], stack st: FlexStackInfo) -> Double {
        guard st.nu > 0, st.nv > 0, st.cell.count == st.nu * st.nv, foot.count == st.columns.count, st.pitchMM > 0 else { return 0 }
        // one ring of "outside" round the grid: off the face
        let nu = st.nu + 2, nv = st.nv + 2
        let big = Double(nu * nu + nv * nv) + 1
        var f = [Double](repeating: 0, count: nu * nv)
        var inside: [Int] = []
        for iv in 0..<st.nv {
            for iu in 0..<st.nu {
                let c = st.cell[iv * st.nu + iu]
                guard c >= 0, c < foot.count, foot[c] >= 0.5 else { continue }
                let g = (iv + 1) * nu + iu + 1
                f[g] = big; inside.append(g)
            }
        }
        guard !inside.isEmpty else { return 0 }
        func edt1(_ x: [Double]) -> [Double] {
            let n = x.count
            var v = [Int](repeating: 0, count: n), z = [Double](repeating: 0, count: n + 1), out = [Double](repeating: 0, count: n)
            var k = 0
            z[0] = -.infinity; z[1] = .infinity
            func cross(_ q: Int, _ r: Int) -> Double {
                ((x[q] + Double(q * q)) - (x[r] + Double(r * r))) / Double(2 * (q - r))
            }
            for q in 1..<n {
                var s = cross(q, v[k])
                while s <= z[k] { k -= 1; s = cross(q, v[k]) }
                k += 1; v[k] = q; z[k] = s; z[k + 1] = .infinity
            }
            k = 0
            for q in 0..<n {
                while z[k + 1] < Double(q) { k += 1 }
                out[q] = Double((q - v[k]) * (q - v[k])) + x[v[k]]
            }
            return out
        }
        for j in 0..<nv {
            let row = edt1(Array(f[(j * nu)..<((j + 1) * nu)]))
            for i in 0..<nu { f[j * nu + i] = row[i] }
        }
        for i in 0..<nu {
            let col = edt1((0..<nv).map { f[$0 * nu + i] })
            for j in 0..<nv { f[j * nu + i] = col[j] }
        }
        let worst = inside.map { f[$0] }.max() ?? 0
        return worst.squareRoot() * st.pitchMM
    }

    /// The spread's two σ for a face's stack and the stamp's footprint (mm).
    static func sigmasMM(_ st: FlexStackInfo, foot: [Double], rule: Rule = .shipped) -> (near: Double, far: Double) {
        rule.sigmasMM(st, featureMM: featureMM(foot, stack: st))
    }

    /// The stamp's designed dent per column (0…1, its deepest 1): the press over each column's
    /// stiffness, spread by the two Gaussians over the face's own columns.
    static func dent(_ foot: [Double], stack st: FlexStackInfo, design: Design, rule: Rule = .shipped) -> [Double] {
        guard foot.count == st.columns.count, !foot.isEmpty else { return foot }
        let squish = foot.map { f -> Double in
            let f = Swift.min(1, Swift.max(0, f))
            let press = f + design.background * (1 - f)
            let rho = f * design.densityUnder + (1 - f) * design.densityOutside
            return press / (rule.stiffnessFloor + rho)
        }
        let sig = sigmasMM(st, foot: foot, rule: rule)
        let wn = rule.nearWeight(sig)
        let near = gaussian(squish, stack: st, sigmaMM: sig.near), far = gaussian(squish, stack: st, sigmaMM: sig.far)
        let s = zip(near, far).map { wn * $0 + (1 - wn) * $1 }
        guard let top = s.max(), top > 1e-12 else { return foot }
        return s.map { Swift.max(0, $0 / top) }
    }

    /// `x` (one value per column) convolved with a Gaussian of `sigmaMM` on the stack's column grid —
    /// SEPARABLE (along u, then along v), zero where the face has no column (the face's own ground only,
    /// as its outline holds the sim's). O(cells × taps): a 64 × 64 face at σ 12 mm is ~0.4 M.
    static func gaussian(_ x: [Double], stack st: FlexStackInfo, sigmaMM: Double) -> [Double] {
        let nu = st.nu, nv = st.nv
        guard nu > 0, nv > 0, st.cell.count == nu * nv, st.pitchMM > 0, sigmaMM > 0, x.count == st.columns.count else { return x }
        let sig = sigmaMM / st.pitchMM
        let r = Swift.min(Swift.max(nu, nv), Int((reach * sig).rounded(.up)))
        // normalised over the WHOLE Gaussian (σ√(2π) per axis, exact for σ ≥ one pitch), not over the face —
        // a far σ wider than the face keeps its own weight beside the near one
        let norm = sig * (2 * Double.pi).squareRoot()
        let taps = (0...r).map { exp(-0.5 * Double($0 * $0) / (sig * sig)) / norm }
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
    /// stamp's press spread as the 3D sim spreads it, its foci merged and showing (FlexibleStampSpread.dent) — what
    /// the Settings page's map shows and dents by. nil for a Curves face or before the grid is laid.
    /// The depth prism still stands on the stamp itself (`stampFootprint`).
    public func stampDent(_ r: Int) -> [Double]? {
        guard let foot = stampFootprint(r), let st = stack(r) else { return nil }
        if FlexibleStampSpread.controlBatchMSpread {
            return FlexibleStampSpread.spread(foot, stack: st, lengthMM: FlexibleStampSpread.lengthMM(st))
        }
        let design: FlexibleStampSpread.Design
        if let d = key(r).flatMap({ designs[$0] }), d.refusal == nil {
            design = FlexibleStampSpread.Design(d, columns: foot.count)
        } else {
            design = .beforeDesign(stampAreaMM2: stampAreaMM2(r) ?? 0, faceAreaMM2: st.footprintAreaMM2)
        }
        return FlexibleStampSpread.dent(foot, stack: st, design: design, rule: FlexibleStampSpread.controlRule ?? .shipped)
    }

    /// The area (mm²) core reads a Stamp face's stamp over: a soft stamp's whole laid grid (its cells
    /// over the grid's peak), a rigid one's cover of the face's own columns. nil before the grid is laid.
    func stampAreaMM2(_ r: Int) -> Double? {
        guard let p = settings.face(r)?.activeStamp, let g = stampGrids[p.id], let peak = g.valuesMPa.max(), peak > 0 else { return nil }
        if p.rigid {
            guard let st = stack(r), let cov = stampCoverage(r), cov.count == st.columns.count else { return nil }
            return zip(cov, st.columns).map { $0 * $1.areaMM2 }.reduce(0, +)
        }
        return g.valuesMPa.map { $0 / peak }.reduce(0, +) * g.cellMM * g.cellMM
    }
}
