// FlexibleMainStage+Stress — the main Flexible page's Stress view from each squeeze group's OWN 3D
// sim (task 2026-09-29-flexible-screens, round 5 batch M, M3; his words, img 4: "Stress is not able
// to simulate; I imagine it should simulate the group that is playing/selected").
//
// ★ WHAT HE SEES. With squeeze groups, Stress colours the part by the von Mises of the group the
// player shows — from that group's own sim (FlexibleFEStress: its displacement, each element's own
// modulus), on the body and, while the lattice shows, on its walls; "Play all" colours each group's
// turn with its own field. The legend reads "Stress · Group 2 · MPa"; a tap reads MPa at the rest
// point. While the sim runs (or the lattice rebuilds): "Simulating…"; a failed sim: ONE line why
// ("Couldn't simulate: the sim did not settle") with Retry, core's words behind the (i).
// ★ BATCH M VERIFICATION. (1) The route is the page's GROUPS, not the lattice's freshness: Save & Exit
// with Stress on used to make the old lattice stale, fall to the solid part's solve ("Stress in the
// solid part · Couldn't simulate" — his img 4 again) and hold core while the group sims waited. (2)
// Each field on ITS OWN scale, topped at a percentile (FlexibleFEStress.scaleTop): one peak at Face
// 5's edge left 97.9 % of his part in the bottom fifth — one flat blue — and under "Play all" Group
// 2's turn sat at 7 % of Group 1's scale. The row names the turn playing and its own top ("≥ x MPa").
// ★ WITHOUT ANY SQUEEZE GROUP (nothing to simulate per group) — or a shape-only filament (no squish
// predicted, so no sim) — the Stress view keeps the solid part's solve it had (FlexibleStressSolver).

import Foundation
import simd

extension FlexibleMainStage {

    /// The Stress view reads the squeeze groups' sims: a current lattice with group sims, or — stale,
    /// rebuilding, or the first build on its way — squeeze groups set (its new sims follow it).
    var feStressRoute: Bool {
        guard let m = model, !controlStressRouteNeedsFreshLattice || (m.lattice != nil && !m.latticeIsStale) else { return false }
        if let g = m.lattice, !m.latticeIsStale {
            return !g.shapeOnly && g.sims.contains { if case .group = $0.kind { return true }; return false }
        }
        return m.material?.noPrediction == nil && !m.sentSqueezeGroups.isEmpty   // ★ AP1: something sent
    }

    /// One field's stress (cached per field): its node field, its true peak and its colour scale's top.
    func feStress(_ f: FlexibleFEField) -> (field: LatticeDemandField, peak: Double, top: Double)? {
        let key = "\(f.serial)|\(f.scale)"
        if let c = feStressCache[f.versionKey], c.key == key { return (c.field, c.peak, c.top) }   // ★ BATCH N: per VERSION
        guard let field = FlexibleFEStress.field(f) else { return nil }
        let peak = LatticeStressTint.peakMPa(field)
        let top = controlStressScaleIsPeak ? peak : FlexibleFEStress.scaleTop(field)
        feStressCache[f.versionKey] = (key, field, peak, top)
        return (field, peak, top)
    }

    /// What the Stress view is doing — the sims' state on the FE route, else the solid solve's.
    public var stressView: FlexibleStressState {
        guard feStressRoute else { return stressState }
        if fe.active { return (feShownStress?.top ?? 0) > 0 ? .ready : .failed("the sim's field carries no stress") }
        if let m = model, m.lattice == nil || m.latticeIsStale || m.latticeBuilding {
            // the lattice (and with it the group sims) is on its way — or cannot come until a fix
            return latticeAvailable ? .running : .blocked(FlexibleFEStress.waitsForLattice)
        }
        if fe.pending || fe.requested.isEmpty { return .running }
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

    /// The stress field a tap reads and the base tints are coloured by now: the field on screen's, on
    /// its own scale (`top` — the colour's 1; `peak` — the true maximum).
    var feShownStress: (field: LatticeDemandField, peak: Double, top: Double)? {
        guard feStressRoute, let f = feShownField, let s = feStress(f) else { return nil }
        return s
    }

    /// The group the Stress view shows: the pick, or under "Play all" the turn PLAYING (nil before
    /// a turn plays — "each group in turn").
    var stressShownGroup: FlexibleSim? {
        guard let m = model else { return nil }
        let all = m.lattice?.sims ?? m.sims
        let groups = all.filter { $0.kind != .playAll }
        let picked: FlexibleSim? = {
            if let g = shownLattice?.shownSim { return g }
            // no lattice yet: the pick, else the first build's default (Play all with two groups)
            if let id = playingSim, let s = all.first(where: { $0.id == id }) { return s }
            return groups.count > 1 ? all.first { $0.kind == .playAll } : groups.first
        }()
        guard let p = picked else { return groups.first }
        guard p.kind == .playAll else { return p }
        // ★ "Play all": the turn on screen (the renderer's swap names it — loop.playingSimID)
        guard playAllLive, let id = loop.playingSimID, let g = groups.first(where: { $0.id == id }) else { return nil }
        return g
    }

    /// The legend's group words: "Group 2"; under "Play all" the turn playing, or "each group in turn"
    /// before one plays (the sims still running included — it read "Group 1" then).
    var stressGroupWords: String? {
        guard feStressRoute else { return nil }
        if controlStressWordsByActiveOnly {   // RED CONTROL: batch M's words (Play all only once the sims landed)
            if playAllLive { return "each group in turn" }
            return shownLattice?.shownSim.flatMap { $0.kind == .playAll ? nil : $0.short } ?? sims.first { $0.kind != .playAll }?.short
        }
        return stressShownGroup?.short ?? "each group in turn"
    }
}
