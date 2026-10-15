// FlexibleMainStage+Play — the main Flexible page's Play and X-ray views (task 2026-09-29-flexible-screens, round 7
// batch R7-V). His words, 2026-10-14:
//   img1: "Instead, add a Play button icon to allow for the simulation view. This should be able to be on with any other
//          view simultaneously. When it is on the simulation plays - otherwise, remove the play-bar from the bottom of the
//          screen entirely." … "When the pause is selected for the simulator, any action taken anywhere automatically
//          re-starts the simulation. Only by pressing Play should the sim actually restart."
//   img5: "Please re-add the x-ray view icon."
// His answer: Play OFF on open — the model sits still AT REST (no squish, no play bar) until he taps Play; the heat
// colours keep their full-load values.
// ★ PLAY IS A VIEW, SHARED: `FlexibleStageViews.play` on the ONE model both pages read — Play on one page is Play on the
// other. The loop's gate follows it (`FlexibleSquishLoop.playView`): off, every hold is at rest and nothing automatic
// plays; his pause is the loop's own latch (`pausedByHim`), so a new lattice, its sims landing, Save & Exit or a Stress
// retry only POSITION the loop. Only his Play (this icon, or the player's ▶) plays.
// ★ THIN OVER THE STAGE: the icons call these; the coming Flexible redesign (the 04:17 ruling's mockups) re-houses the
// same toggles.

import Foundation

extension FlexibleMainStage {

    /// The Play view is on (the shared model's).
    public var playOn: Bool { model?.views.contains(.play) == true }

    /// His Play icon: on — the bar, and the sim plays from where it is (at rest: from rest); off — the bar leaves and
    /// the model sits at rest. His action: it plays under reduced motion too, and clears his pause.
    public func togglePlay() {
        guard let m = model else { return }
        if m.views.contains(.play) { m.views.remove(.play); return }   // (`viewsChanged`: at rest, the bar gone)
        loop.playView = true
        // something to play now: a drawn lattice whose squish is not still being simulated (pending: held at rest, it
        // plays from rest when the sims land — the gate is open)
        if drawn != nil, !fe.pending { loop.playByHim() } else { loop.forgetHisPause() }
        m.views.insert(.play)
    }

    /// His X-ray icon (on ⇄ off).
    public func toggleXray() { xrayOn.toggle() }

    /// The lattice SHOWN: the Lattice view on — the Lattice icon turning on, the note's [Show], Settings' Exit after the
    /// Lattice icon opened it, the bottom pill's "View off · tap to build". ★ ROUND 7, X1 (his Q9 answer, 2026-10-14: "The
    /// lattice should be visible without x-ray on as long as finish is set to something that isn't 'covered'"): never X-ray
    /// as well — the printed view shows the walls out of X-ray (R7-V turned X-ray on here; reversed). RED CONTROL
    /// `controlViewsForceXray`.
    public func showLatticeView() {
        latticeOn = true
        if controlViewsForceXray, !xrayOn { xrayOn = true }
    }

    /// His Lattice icon — ★ X1: a plain show / hide (lit = `latticeIconLit`, his view). RED CONTROL: R7-V's (lit while the
    /// walls are seen; turning on turned X-ray on).
    public func toggleLatticeView() {
        if controlViewsForceXray { if wallsShown { latticeOn = false } else { showLatticeView() }; return }
        latticeOn = !latticeShown
        // ★ X1 VERIFY (the verify: under Covered — every new project's finish — the icon lit and unlit with no visible change):
        // Covered hides the lattice out of X-ray (the print) — say so at once, with the one-tap fix (X-ray). Never X-ray by
        // itself. RED CONTROL `controlNoCoveredNote`.
        if latticeShown, !xrayOn, !finishLeavesLatticeOpen, !controlNoCoveredNote { note.post(.coveredHidesLattice) }
    }

    /// The sims are running or refining — the Play icon carries a small ring, so the status the hidden bar's note gave is
    /// not lost.
    public var simsWorking: Bool { fe.pending || fe.refining != nil }

    /// The model's views moved (either page's icons): the main page redraws, and the loop follows Play — off: at rest;
    /// on: the shown sequence starts from rest on the next refresh (the gate is open; a pause of his still holds).
    func viewsChanged(_ v: FlexibleStageViews) {
        objectWillChange.send()
        let on = v.contains(.play)
        guard on != loop.playView else { return }
        loop.playView = on
        guard on, !loop.playing else { return }
        playedGeneration = nil; fePlayedGeneration = nil; feStartedKey = nil; fallbackKey = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.frozen { self.playStartPending = true } else { self.refresh() }
        }
    }
}
