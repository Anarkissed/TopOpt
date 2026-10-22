// FlexibleStageModel+PressSim — round 7 batch R7-E3: an edges group SQUISHES when played (task 2026-09-29-flexible-screens).
// His notes of 2026-10-19 ~14:40 (binding): "Also, the edges do not seem to actually squish when played? Why is that? It should
// absolutely have a simulation going. Can you look into why?" — WHY: an edges group's presses are kept out of everything sent to
// core while sending presses is parked (his ruling of 2026-10-19 ~14:50, R7-E2 PARKED), so the lattice's sims (one per squeeze
// group, built with the lattice from the faces it designed) never had one for an edges group: nothing to play.
//
// ★ THE INTERIM SIM (the reviewer's AP ruling (a), approved by him, with its three conditions): the app's 3D squish — core's FE
// solver on the CURRENT lattice, each voxel's stiffness from core's curves — pushes ALONG each press's arrow over its whole flat-prism
// footprint (the strip pieces the flat cut made), with the group's force; no column, frame or design for the press is asked of core;
// no prediction to calibrate to, so the field keeps the solve's own size (cut only so it never folds). It NEVER writes a job (nothing
// here touches the job or the export), and the chip "Lattice not tuned for this press yet" shows while it plays (FlexibleRowCopy).
// ★ C1 (his words of 2026-10-20: "the edge/corner squishes barely squish … Is that mainly because it does not go to core? Please go
// ahead and finalize the send to core now."): with the presses SENT (FlexibleBackend.sendsPresses on), once the lattice carries
// core's design for every press of the group (latticeTunedPresses), the same sim is CALIBRATED to core's depths on each press stack,
// as a face group's is — Play, Bend and Heat show core's squish, the chip goes; the uncalibrated interim sim is only the fallback.
// ★ X20b (his answer of 2026-10-20 ~19:10: "Edge Play shows CORE'S FULL DESIGN DEPTH (e.g. Edge 12 5.6 mm, Edge 9 3.3 mm)"): the
// tuned sim's targets are core's own design depths (not the press as built), it is solved PER PRESS and each press scaled to its
// design depth (FlexibleFERequest.solve → FlexibleFEField.designDepth) — no band, no ½ cut, shown at × 1; only a true fold (a part
// cell turned inside out) would cut it, and the chip says so.
// ★ ONE ID PER GROUP: "group-N" (the tab's number), like a face group's sim, so the Squish page's player, the main page's selector,
// "All (one after another)" and the views find it exactly as a face group's. Solved again when the group's presses change (pieces,
// arrow bits, depth, force) or a new lattice lands — never while one is still solving for that group.

import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {
    /// ★ RED CONTROL only: today's bug — no sim for an edges group (nothing plays).
    @MainActor static var controlNoPressSims = false

    /// One edges group's interim sim as wanted now: its sim (the player's entry), its presses and their key.
    struct PressSimWant {
        let sim: FlexibleSim
        let presses: [FlexibleFERequest.PressPush]
        let key: Int
        /// ★ C1: core's depths on each press stack when the lattice carries core's design for EVERY press of the group (the sim is
        /// calibrated to them, as a face group's is); empty: the interim sim (its own size, the chip).
        var targets: [FlexibleFEField.Target] = []
        var tuned: Bool { !targets.isEmpty }
    }

    /// Every edges group with a flat-prism press that has a footprint and a force — what plays along its arrow.
    var pressSimWants: [PressSimWant] {
        guard !Self.controlNoPressSims else { return [] }
        return squeezeGroups.filter { $0.kind == .edges }.compactMap { g -> PressSimWant? in
            let ps = g.presses.compactMap { settings.press($0) }.filter { $0.strip != nil && !$0.regions.isEmpty && $0.settings.weightN > 0 }
            guard !ps.isEmpty else { return nil }
            // ★ R7-E5: each press pushes WHERE HE DREW (its curves or its stamp — FlexiblePressPush), not evenly
            let pushes = ps.map { p -> FlexibleFERequest.PressPush in
                let s = flatCut(p.id).map { FlexiblePressPush.samples(p, $0) } ?? FlexiblePressPush.Samples()
                return FlexibleFERequest.PressPush(regions: p.regions, direction: p.direction, weightN: p.settings.weightN,
                                                   pushXYZ: s.xyz, pushWeight: s.weight)
            }
            // ★ C1: core's design for every press of the group in this lattice — the sim reads core's press stacks
            // ★ U21 (BEND-EDGES): on a lattice out of date (edited since Save & Exit), core's LIVE design of each press as it is now —
            // never the old build's design for a press edited since; with any press not designed yet: the interim sim and its chip
            let targets: [FlexibleFEField.Target]
            if latticeIsStale, !Self.controlStaleUsesOldTuned {
                let live = ps.compactMap { liveDesignTarget($0.id) }
                targets = live.count == ps.count ? live : []
            } else {
                let tuned = ps.compactMap { latticeTunedPresses[$0.id] }
                targets = tuned.count == ps.count ? tuned : []
            }
            var h = Hasher()
            h.combine(lattice?.generation)
            h.combine(targets.count)
            for t in targets { h.combine(t.depthsMM) }   // ★ U21: a new live design solves again
            h.combine(openedKey)
            for (p, q) in zip(ps, pushes) {
                h.combine(p.regions)
                h.combine(FlexiblePressAim.bits(p.direction))
                h.combine(p.settings.weightN)
                h.combine(p.settings.deepestMM)
                h.combine(q.pushWeight)   // ★ R7-E5: a new drawing solves again
                h.combine(q.pushXYZ)
            }
            let name = groupName(g)
            let labels = ps.compactMap { $0.strip?.label }
            let sim = FlexibleSim(id: FlexibleSim.groupID(g.number), kind: .group(g.number),
                                  title: FlexibleRowCopy.simTitle(name: name, names: labels), short: name, keys: [])
            return PressSimWant(sim: sim, presses: pushes, key: h.finalize(), targets: targets)
        }
    }

    /// The edges groups' sims (the player's entries), in group order.
    public var pressSims: [FlexibleSim] { pressSimWants.map(\.sim) }

    /// Is `simID` an edges group's interim sim?
    public func isPressSim(_ simID: String?) -> Bool {
        guard let simID else { return false }
        return pressSimWants.contains { $0.sim.id == simID }
    }

    /// ★ What can be played: the lattice's group sims and the edges groups', in group order, and "All (one after another)" with two
    /// or more. nil without a lattice.
    public var playLattice: FlexibleGeneratedLattice? {
        guard let l = lattice else { return nil }
        let extra = pressSims
        guard !extra.isEmpty else { return l }
        func number(_ s: FlexibleSim) -> Int { if case .group(let n) = s.kind { return n }; return Int.max }
        let groups = (l.sims.filter { $0.kind != .playAll } + extra).sorted { number($0) < number($1) }
        var sims = groups
        if groups.count > 1 {
            let all = l.sims.first { $0.kind == .playAll }
            sims.append(FlexibleSim(id: FlexibleSim.allID, kind: .playAll, title: all?.title ?? FlexibleRowCopy.simAll,
                                    short: all?.short ?? FlexibleRowCopy.simAllShort, keys: all?.keys ?? []))
        }
        return l.withSims(sims)
    }

    /// ★ Solve the edges groups' interim sims the current lattice lacks (or whose presses changed). Cheap on every refresh; only
    /// once the lattice's own sims were handed to the solver (so a new lattice's schedule never drops them).
    func startPressSims() {
        // ★ U21 (BEND-EDGES): on a lattice edited since Save & Exit but built on the scene open now, the edges groups keep a sim on
        // that LAST BUILT lattice with their presses as they are now — solved again once his drag ends (k frozen while he drags)
        guard let base = feBase, let l = lattice, base.generation == l.generation,
              !latticeIsStale || (edgesSimOnStaleLattice && frozenExaggeration == nil),
              squishScheduled == l.generation, feRequest == nil else { return }
        let wants = pressSimWants
        let wanted = Set(wants.map(\.sim.id))
        // a group no longer an edges group (or gone): its interim state goes
        for id in pressSimKeys.keys where !wanted.contains(id) && !pressSimInFlight.contains(id) {
            pressSimKeys[id] = nil
            if squish[id] != nil, !(lattice?.sims.contains { $0.id == id } ?? false) { squish[id] = nil }
        }
        var todo: [FlexibleFERequest.Sim] = []
        for w in wants where pressSimKeys[w.sim.id] != w.key && !pressSimInFlight.contains(w.sim.id) {
            pressSimKeys[w.sim.id] = w.key
            pressSimInFlight.insert(w.sim.id)
            if refine[w.sim.id] != nil { refine[w.sim.id] = nil }
            squish[w.sim.id] = .pending
            todo.append(FlexibleFERequest.pressSim(id: w.sim.id, presses: w.presses, voxels: base.rho.count, targets: w.targets))
        }
        guard !todo.isEmpty else { return }
        squishSolver.onResult = { [weak self] gen, id, state in self?.squishLanded(gen, id, state) }
        squishSolver.linearField = { [weak self] id in self?.squish[id]?.field }
        let worker = squishWorker
        track(Task { @MainActor [weak self] in
            let scene = await worker.sceneRef()
            guard let self else { return }
            guard let scene, self.feBase?.generation == base.generation else {
                for s in todo {
                    self.pressSimInFlight.remove(s.id)
                    self.squishLanded(base.generation, s.id, .failed("The part is still opening."))
                }
                return
            }
            self.squishSolver.add(todo, base: base, scene: scene)
        })
    }

    /// An interim sim landed (squishLanded's hook): its group may have changed meanwhile — solve again for what is wanted now.
    func pressSimLanded(_ id: String) {
        guard pressSimInFlight.remove(id) != nil else { return }
        if let w = pressSimWants.first(where: { $0.sim.id == id }), w.key != pressSimKeys[id] {
            DispatchQueue.main.async { [weak self] in self?.startPressSims() }
        }
    }

    // MARK: ★ U21 (BEND-EDGES, his note of 2026-10-21, Img2: "The bend view doesn't bend the edges/corners")
    // WHY it was still: an edges group has no column preview; its Bend / Play / Heat came only from its sim on a CURRENT lattice, and
    // since C1 any press edit puts the lattice out of date until Save & Exit — the sim was rejected (the probe: 6.275 mm → 0.000 mm
    // after ONE stamp move on Edge 12).

    /// ★ RED CONTROL only: today's rule — an edges group plays nothing on a lattice out of date.
    @MainActor static var controlEdgesStillWhenStale = false
    /// ★ RED CONTROL only: the old build's designs calibrate a press edited since.
    @MainActor static var controlStaleUsesOldTuned = false

    /// The lattice is out of date but was built on the scene open now, its sims' base is that lattice: an edges group may play on it.
    var edgesSimOnStaleLattice: Bool {
        guard !Self.controlEdgesStillWhenStale, latticeIsStale, let l = lattice, l.sceneKey == openedKey,
              let b = feBase, b.generation == l.generation else { return false }
        return true
    }

    /// Core's design of press `id` as it is NOW (its current registration, the designs settled): its depths on the press stack.
    func liveDesignTarget(_ id: UUID) -> FlexibleFEField.Target? {
        guard !designsInFlight, let r = pressRegistrations[id], let d = pressDesign(id), d.refusal == nil,
              d.columns.count == r.stack.columns.count else { return nil }
        return FlexibleFEField.Target(stack: r.stack, depthsMM: FlexiblePinch.core(d, stack: r.stack).buildableDepthMM, pinched: [])
    }

    /// The edges group's landed sim answers its presses as they are now (solved for the current wants, nothing in flight).
    func pressSimIsCurrent(_ id: String) -> Bool {
        guard let w = pressSimWants.first(where: { $0.sim.id == id }) else { return false }
        return pressSimKeys[id] == w.key && !pressSimInFlight.contains(id)
    }

    /// The playing edges group's sim is calibrated to core's design (the legend says which).
    public var playingPressSimTuned: Bool {
        guard let g = playingGroup, g.kind == .edges else { return false }
        return pressSimWants.first { $0.sim.id == FlexibleSim.groupID(g.number) }?.tuned ?? false
    }

    /// ★ THE CHIP (the reviewer's interim-sim conditions): "Lattice not tuned for this press yet" while an edges group's squish is the
    /// interim sim (the lattice is not designed for its presses — always, while sending presses is parked). nil for a face group.
    /// ★ C1: gone once core designed the lattice for every press of the group (the sim then plays core's design).
    public func notTunedLine(simID: String?) -> String? {
        guard let simID, let w = pressSimWants.first(where: { $0.sim.id == simID }) else { return nil }
        guard w.tuned else { return FlexibleRowCopy.latticeNotTunedForPress }
        // ★ X20b: core's full design depth is shown — said only when a TRUE fold held it back
        if let cut = squish[simID]?.field?.trueFoldCut { return FlexibleRowCopy.pressFoldCut(percent: Swift.max(1, Int((cut * 100).rounded(.down)))) }
        return nil
    }
}

extension FlexibleGeneratedLattice {
    /// ★ R7-E3: this lattice with `sims` as its player's entries (the walls, faces and keys unchanged).
    public func withSims(_ sims: [FlexibleSim]) -> FlexibleGeneratedLattice {
        FlexibleGeneratedLattice(inputs: inputs, faces: faces, keys: keys, columnDepths: columnDepths, columnNoLattice: columnNoLattice,
                                 extentMM: extentMM, generation: generation, topology: topology, tempC: tempC, settingsKey: settingsKey,
                                 squishedKeys: squishedKeys, shapeOnlyLabel: shapeOnlyLabel, sceneKey: sceneKey, sims: sims,
                                 simNotes: simNotes, sharedVoxels: sharedVoxels, shownSimID: shownSimID, pinchedWith: pinchedWith)
    }
}
