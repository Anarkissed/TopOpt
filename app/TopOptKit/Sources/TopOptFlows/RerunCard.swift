// RerunCard.swift — Flexible (PR #362) round 9: RE-RUN A FINISHED TO, HERE OR IN A COPY.
//
// ★ HIS WORDS (2026-10-24): "I need to be able to re-run a TO after one has completed - or at the
// very least be able to copy a project in the library view … if someone re-runs the TO, that it
// will clear the current optimizations and we should have a card saying so and asking if they
// really want to do it in the current project OR an option to Save As a new project."
//
// ★ THE BLOCK. `canOptimize` greyed Optimize out while the setup equalled the last run's request
// ("until the inputs change"), with no reason on the button — so a finished project could not be
// optimized again without nudging a setting. The grey-out now applies only when there is nothing
// to re-run over (`greysOut`); a project WITH results stays enabled, and the confirmation card is
// what stands between the tap and the loss.
//
// ★ THE CARD replaces the old "Replace your results?" alert's words and adds the third door:
//   [Re-run here]          destructive — today's `startRun()`
//   [Save as new project]  duplicate the setup without results (`AppModel.duplicateProject`),
//                          open the copy, and run there (`runOnOpen` → the workspace's onAppear)
//   [Cancel]
// The message stays `ResultsReplacementPrompt.message` (the count and lightest mass).

import Foundation
import TopOptKit

public enum RerunCard {

    public static let title = "Re-running clears this project’s results"
    public static let rerunHereLabel = "Re-run here"
    public static let saveAsNewLabel = "Save as new project"
    public static let cancelLabel = "Cancel"

    /// Said when the copy opened but its setup cannot start a run on its own (e.g. a stall in
    /// the restored setup): the copy is there, the user presses Optimize.
    public static let copyNotReadyToast = "The copy is open — press Optimize to run it."
    /// Said when the copy could not be made; the original is untouched.
    public static let copyFailedToast = "Couldn’t make a copy of this project — nothing was changed."

    /// Whether Optimize greys out for a setup identical to the last run's. Only when there is no
    /// finished result to re-run over: with results, the card confirms instead.
    public static func greysOut(sameInputsAsLastRun: Bool, existing: OptimizeOutcome?) -> Bool {
        guard sameInputsAsLastRun else { return false }
        return ResultsReplacementPrompt.forNewRun(existing: existing) == nil
    }

    // ── the run handed to the copy ──────────────────────────────────────────

    @MainActor private static var pendingRun: UUID?

    /// Ask the workspace that next opens `project` to start its run once (Save as new project).
    @MainActor public static func runOnOpen(_ project: UUID) { pendingRun = project }

    /// True exactly once, for the project that was asked for.
    @MainActor public static func takeRunOnOpen(for project: UUID) -> Bool {
        guard pendingRun == project else { return false }
        pendingRun = nil
        return true
    }
}
