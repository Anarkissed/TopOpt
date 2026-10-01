// FlexibleStampSpread — a stamp's press SPREADS out and its foci merge into ONE input (task
// 2026-09-29-flexible-screens, round 5 batch M, M2; his words, img 4: "the stamps are seen as
// isolated areas, disconnected to the rest of the lattice, rather than pulling on the rest of the
// lattice with it. When squished, it should have foci but expand out, pulling lattice next to it
// in, combining the foci into a single input" — and "this and the graded dent colours should be in
// both views").
//
// ★ WHAT IT IS. The Settings page draws a Stamp face's designed squish (FlexibleShownValues: "What
// you drew"). It was the stamp's smoothed footprint × the deepest squish — four fingertips were four
// pits with flat ground between them. Now each focus GRADES OUT: the footprint is convolved with an
// isotropic exponential kernel of decay length L, and
//     w(x) = min(1, max(foot(x), 2 · (foot ⊛ K_L)(x)))
// — under the stamp it is 1 (the full sink), at a straight edge 2 · ½ = 1 (no step at the outline),
// and outside it falls with the distance. Where two foci's spreads overlap their tails ADD (a linear
// body's sinks superpose) up to the full sink — so close fingertips merge into one press (one force:
// the stamp is one rigid or soft press, never four), far ones keep their own spots.
// ★ THE SPREAD WIDTH, AND WHY (`lengthMM`): L = 0.2 × the face's mean lattice depth, at least one
// column pitch — a press into an elastic layer drags its neighbours over a distance set by the
// layer's THICKNESS (a thin pad barely spreads, a deep one spreads wide), and 0.2 is what the 3D sim
// of his own pad gives (`shareOfDepth`): his 20 mm top spreads over L = 4 mm, his 100 mm-deep sides
// over L = 20 mm (the four fingertips 8–10 mm apart merge into one press).
// ★ THE MAIN PAGE does not use this: there the 3D sim's own field is the dent (it spreads by the
// physics — FlexibleMainStage+Squish.feMapValues). Core's design_stamp still designs the density
// under the stamp alone (core brief #33).
// Pure value math on the stack's column grid.

import Foundation
import TopOptKit

enum FlexibleStampSpread {

    /// L as a share of the face's mean lattice depth — FITTED to the 3D sim of his round-5 pad
    /// (FlexibleBatchMProbe.testFEStampSpreadProfile): the sim's sink 0–2 / 2–4 / 4–8 mm outside each
    /// stamp, over the sink under it, is matched best at 0.2 — Face 5's thumb (100 mm deep, L 20 mm)
    /// within 0.05 rms, Face 3's four fingertips (L 20 mm) within 0.08, Top A's elbow (20 mm deep,
    /// L 4 mm) within 0.13 (its ring also carries Top B's own press, which a per-face spread cannot).
    static let shareOfDepth = 0.2
    /// The kernel is cut at this many L (e^−5 ≈ 0.7 %).
    static let reach = 5.0

    /// The decay length for a face's stack (mm): `shareOfDepth` × its mean lattice depth, never under
    /// one column pitch (the grid cannot draw a finer grade).
    static func lengthMM(_ st: FlexStackInfo) -> Double {
        Swift.max(st.pitchMM, shareOfDepth * st.latticeMMMean)
    }

    /// The footprint `foot` (per column, 0…1) spread with decay length `L` on the stack's column
    /// grid: max(foot, softCap(foot ⊛ K / the same at the stamp's outline)), K ∝ e^(−r / L).
    static func spread(_ foot: [Double], stack st: FlexStackInfo, lengthMM L: Double) -> [Double] {
        let cols = st.columns
        guard foot.count == cols.count, st.nu > 0, st.nv > 0, st.pitchMM > 0, L > 0 else { return foot }
        let p = st.pitchMM
        let r = Int((reach * L / p).rounded(.up))
        // the kernel on the grid, normalised over the full (unclipped) disc of radius reach·L
        var taps: [(du: Int, dv: Int, w: Double)] = []
        var total = 0.0
        for dv in -r...r { for du in -r...r {
            let d = (Double(du * du + dv * dv)).squareRoot() * p
            guard d <= reach * L else { continue }
            let w = exp(-d / L)
            taps.append((du, dv, w)); total += w
        } }
        guard total > 0 else { return foot }
        // scatter from the pressed columns only (a stamp covers a fraction of the face)
        var conv = [Double](repeating: 0, count: cols.count)
        for (c, f) in foot.enumerated() where f > 1e-9 {
            let col = cols[c]
            for t in taps {
                let n = st.column(col.iu + t.du, col.iv + t.dv)
                guard n >= 0, n < conv.count else { continue }
                conv[n] += f * t.w / total
            }
        }
        // ★ normalised at the stamp's OWN EDGE (the median over its outline columns: pressed, beside
        // one that is not) — a big stamp's edge reads ½ of its inside, a fingertip far less; either way
        // the spread starts at the full sink exactly at the outline, and falls from there
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

    /// The spread's full-sink cap, SMOOTH (C¹): x below 1 − δ, 1 above 1 + δ, a parabola between (a
    /// hard min(1, x) creased the ground between merged fingertips). Under the stamp the footprint itself
    /// is 1, so the stamp still sinks the full depth.
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
    /// ★ BATCH M (M2): a Stamp face's DESIGNED squish per column (0…1) — the stamp's footprint
    /// spread out and its foci merged (FlexibleStampSpread) — what the Settings page's map shows and
    /// dents by. nil for a Curves face or before the grid is laid. The depth prism still stands on
    /// the stamp itself (`stampFootprint`).
    public func stampDent(_ r: Int) -> [Double]? {
        guard let foot = stampFootprint(r), let st = stack(r) else { return nil }
        return FlexibleStampSpread.spread(foot, stack: st, lengthMM: FlexibleStampSpread.lengthMM(st))
    }
}
