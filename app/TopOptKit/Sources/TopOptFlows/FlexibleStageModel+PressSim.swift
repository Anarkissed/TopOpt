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
            let tuned = ps.compactMap { latticeTunedPresses[$0.id] }
            let targets = tuned.count == ps.count ? tuned : []
            var h = Hasher()
            h.combine(lattice?.generation)
            h.combine(targets.count)
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
        guard let base = feBase, let l = lattice, base.generation == l.generation, !latticeIsStale,
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

    /// ★ THE CHIP (the reviewer's interim-sim conditions): "Lattice not tuned for this press yet" while an edges group's squish is the
    /// interim sim (the lattice is not designed for its presses — always, while sending presses is parked). nil for a face group.
    /// ★ C1: gone once core designed the lattice for every press of the group (the sim then plays core's design).
    public func notTunedLine(simID: String?) -> String? {
        guard let simID, let w = pressSimWants.first(where: { $0.sim.id == simID }) else { return nil }
        return w.tuned ? nil : FlexibleRowCopy.latticeNotTunedForPress
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
