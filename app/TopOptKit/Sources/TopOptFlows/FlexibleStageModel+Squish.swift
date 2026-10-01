// FlexibleStageModel+Squish — the squeeze groups' squish sims on the model (task
// 2026-09-29-flexible-screens, round 5 batch G, §4).
//
// ★ WHEN. A lattice landing (Save & Exit, or a main-page group / load change rebuilt it) brings
// its own FE request (built in its build task); the MAIN page starts the sims when it shows that
// lattice (`startSquishSims` — never per frame, never while the Settings page draws: the lattice
// only builds on Exit). A new generation discards every field and every pending sim of the old
// one; a pick of a solved sim never re-solves (the cache is keyed by the generation and the sim).

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// A new lattice (or none) landed: its own sims, none of the old one's.
    func latticeLanded(_ request: FlexibleFERequest?) {
        squishSolver.cancel()
        feRequest = request
        if keepFERequest { keepLastFERequest(request) }
        squishScheduled = nil
        squishGeneration = request?.generation ?? lattice?.generation
        if !squish.isEmpty { squish = [:] }
    }

    /// The squish sims of the lattice shown: start them (the shown sim `first`), once per
    /// generation. Cheap to call on every refresh.
    public func startSquishSims(first: String?) {
        guard let r = feRequest, let g = lattice, r.generation == g.generation, !latticeIsStale,
              squishScheduled != r.generation else {
            if let first, squish[first] == .pending { squishSolver.promote(first) }
            return
        }
        squishScheduled = r.generation
        var s = squish
        for sim in r.sims where s[sim.id] == nil { s[sim.id] = .pending }
        if s != squish { squish = s }   // one publish: "Simulating the squish…"
        squishSolver.onResult = { [weak self] gen, id, state in self?.squishLanded(gen, id, state) }
        let worker = squishWorker
        // (tracked: `waitForIdle` waits for the hand-over too, so no sim starts after it returned)
        track(Task { @MainActor [weak self] in
            let scene = await worker.sceneRef()
            guard let self, self.feRequest?.generation == r.generation, self.lattice?.generation == r.generation else { return }
            guard let scene else {
                for sim in r.sims { self.squishLanded(r.generation, sim.id, .failed("The part is still opening.")) }
                return
            }
            self.squishSolver.schedule(r, scene: scene, first: first)
            self.feRequest = nil   // the solver holds it until its last sim
        })
    }

    /// ★ BATCH M (M3): the Stress legend's Retry — re-run a failed sim of the lattice shown (its request
    /// is kept while one has failed); without it, the lattice is rebuilt (its sims come with it).
    public func retrySquishSim(_ id: String) {
        guard squish[id]?.failure != nil else { return }
        squish[id] = .pending
        if !squishSolver.retry(id) { generateLattice() }
    }

    /// One sim finished: kept only if it is for the lattice still shown.
    func squishLanded(_ generation: Int, _ id: String, _ state: FlexibleSquishState) {
        guard controlIgnoreSquishGeneration || (generation == lattice?.generation && generation == squishGeneration) else { return }
        squish[id] = state
    }

    /// The group sims of the current lattice, in group order, with their states.
    public var squishSims: [(sim: FlexibleSim, state: FlexibleSquishState?)] {
        (lattice?.sims ?? []).filter { if case .group = $0.kind { return true }; return false }
            .map { ($0, squish[$0.id]) }
    }
}
