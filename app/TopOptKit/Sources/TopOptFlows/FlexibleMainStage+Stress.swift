// FlexibleMainStage+Stress — the main Flexible page's Stress view from each squeeze group's OWN 3D
// sim (task 2026-09-29-flexible-screens, round 5 batch M, M3; his words, img 4: "Stress is not able
// to simulate; I imagine it should simulate the group that is playing/selected").
//
// ★ WHAT HE SEES. With a lattice built, Stress colours the part by the von Mises of the group the
// player shows — from that group's own sim (FlexibleFEStress: its displacement, each element's own
// modulus), on the body and, while the lattice shows, on its walls; "Play all" colours each group's
// turn with its own field (one scale over the groups, so turns compare). The legend reads "Stress ·
// Group 2 · MPa"; a tap reads MPa at the rest point. While the sim runs: "Simulating…"; a failed sim:
// ONE line why ("Couldn't simulate: the sim did not settle") with Retry, core's words behind the (i).
// ★ WITHOUT A LATTICE (nothing to simulate per group yet) the Stress view keeps the solid part's
// solve it had (FlexibleStressSolver) — the old route, unchanged.

import Foundation
import simd

extension FlexibleMainStage {

    /// The Stress view reads the squeeze groups' sims: a current lattice with at least one group.
    var feStressRoute: Bool {
        guard let m = model, let g = m.lattice, !m.latticeIsStale else { return false }
        return g.sims.contains { if case .group = $0.kind { return true }; return false }
    }

    /// One field's stress (cached per field): its node field and peak.
    func feStress(_ f: FlexibleFEField) -> (field: LatticeDemandField, peak: Double)? {
        let key = "\(f.serial)|\(f.scale)"
        if let c = feStressCache[f.simID], c.key == key { return (c.field, c.peak) }
        guard let field = FlexibleFEStress.field(f) else { return nil }
        let peak = LatticeStressTint.peakMPa(field)
        feStressCache[f.simID] = (key, field, peak)
        return (field, peak)
    }

    /// The ONE stress scale over the sequence on screen (Play all's turns compare).
    var feStressPeak: Double {
        fe.sequence.compactMap { i in i < fe.fields.count ? feStress(fe.fields[i])?.peak : nil }.max() ?? 0
    }

    /// What the Stress view is doing — the sims' state on the FE route, else the solid solve's.
    public var stressView: FlexibleStressState {
        guard feStressRoute else { return stressState }
        if fe.active { return feStressPeak > 0 ? .ready : .failed("the sim's field carries no stress") }
        if let m = model, fe.pending || m.latticeBuilding || fe.requested.isEmpty { return .running }
        if let why = fe.failure { return .failed(why) }
        return .running
    }

    /// The Stress legend's one line when it cannot draw (nil: it draws).
    public var stressLine: String? {
        if feStressRoute, case .failed(let why) = stressView { return FlexibleFEStress.failedLine(why) }
        return stressView.line
    }

    /// The sim a Retry re-runs (the shown group's — a failed one).
    var feStressRetryID: String? {
        guard feStressRoute, !fe.active, fe.failure != nil else { return nil }
        return fe.requested.first
    }

    /// The stress field a tap reads and the base tints are coloured by now: the field on screen's.
    var feShownStress: (field: LatticeDemandField, peak: Double)? {
        guard feStressRoute, let f = feShownField, let s = feStress(f) else { return nil }
        return (s.field, feStressPeak)
    }

    /// The legend's group words: "Group 2", or "each group in turn" under Play all.
    var stressGroupWords: String? {
        guard feStressRoute else { return nil }
        if playAllLive { return "each group in turn" }
        return shownLattice?.shownSim.flatMap { $0.kind == .playAll ? nil : $0.short } ?? sims.first { $0.kind != .playAll }?.short
    }
}
