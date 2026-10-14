// FlexibleMainPickSession — "a group's prism and number only after a pick" on the main Flexible page (task
// 2026-09-29-flexible-screens). ★ ROUND 7, BATCH R7-V — his answer of 2026-10-14, after he removed the two worded view
// toggles ("All view buttons should be icons - never full words. Remove the two full worded view icons. I've decided
// against them."): with the toggles gone, the main page keeps BOTH behaviours fixed — no Selections role colour on its
// model (FlexibleMainStage.tints never reads #354's roles), and a group's prism and number only AFTER he picks a group in
// this session: nothing on open, none for a Pending group. Batch V's view settings (FlexibleMainViewSettings, kept in the
// app's defaults per project — 2026-10-10) are gone with their chips; his stale keys are removed once (`ensure`).
// A pick is the active Selections group changing, or the active group tapped again (#354's row re-sets it: an equal
// write), from the stage's first look at the project on, while no Settings page is up — never an Undo / Redo's re-write
// of the selection (batch V review).

import Combine
import Foundation

extension FlexibleMainStage {

    /// A fresh session of picks (nothing picked as the stage first looks at the project). Called by `ensure` when the
    /// stage makes the project's model — from a view's init: it publishes nothing.
    func openPickSession(_ project: ProjectModel) {
        sessionPicked = false
        lastSelection = project.selection
        restoreWritePending = false
        // ★ BATCH V REVIEW: the undo history first — an Undo / Redo moves it just BEFORE it re-writes the selection
        // (ProjectModel.performUndo / performRedo → applyEditSnapshot: `selection = s.selection`, always)
        lastUndo = project.undo
        undoObservation = project.$undo.dropFirst()
            .sink { [weak self] h in self?.undoMoved(h) }
        selectionObservation = project.$selection.dropFirst()
            .sink { [weak self] s in self?.selectionMoved(s) }
    }

    /// The selection as #354 wrote it: a pick (the active group changed, or the same one re-set), unless a Settings page is
    /// up (its writes are never his pick), or an Undo / Redo restored it (★ batch V review: every restore re-writes the
    /// selection, an equal write as often as not — he never touched Selections).
    func selectionMoved(_ new: SelectionModel) {
        defer { lastSelection = new }
        if restoreWritePending {
            restoreWritePending = false
            if !controlUndoIsAPick { return }
        }
        guard !frozen, let a = new.activeGroupID else { return }
        if a != lastSelection?.activeGroupID || new == lastSelection { sessionPicked = true }
    }

    /// The undo history as ProjectModel moved it: an Undo or a Redo (never a commit, a reset or a no-op) marks the selection
    /// write that follows it as a restore's. (Cleared on the next turn of the run loop if no write came — it always does.)
    func undoMoved(_ new: UndoHistory) {
        defer { lastUndo = new }
        guard let old = lastUndo, Self.isUndoOrRedo(from: old, to: new) else { return }
        restoreWritePending = true
        DispatchQueue.main.async { [weak self] in self?.restoreWritePending = false }
    }

    /// An Undo moves one step from the past onto the future; a Redo one step back. A commit appends to the past and CLEARS
    /// the future — with one step undone that looks like a Redo by the counts, and the baseline tells them apart: a Redo
    /// restores exactly the state it had undone.
    nonisolated static func isUndoOrRedo(from old: UndoHistory, to new: UndoHistory) -> Bool {
        if new.future.count == old.future.count + 1, new.past.count + 1 == old.past.count { return true }
        if new.future.count + 1 == old.future.count, new.past.count == old.past.count + 1, let undone = old.future.last,
           new.baseline == undone { return true }
        return false
    }

    /// ★ ROUND 7, M1 (H15'): the group whose LATTICE face-prisms the main page draws — the active Selections group, only once
    /// he has picked in this session (his fixed rule), whatever its role: a group with no face-prism draws nothing (a Pending
    /// group cannot hold one — LatticeFaceRoleGate), and a Protect-only group with a Lattice face draws it (batch V's Pending
    /// test hid his Group C).
    func pickedGroup(_ project: ProjectModel) -> SelectionGroup? {
        guard let g = project.selection.activeGroup else { return nil }
        if controlPrismOnOpen { return g }   // RED CONTROL: S1b's rule — the active group's prism on open
        return sessionPicked ? g : nil
    }

    /// The group whose SQUISH prism round 6 drew (the RED CONTROL `controlSquishPrismsOnMain` only, since M1): the active
    /// Selections group, only once he has picked in this session, and never a Pending group.
    func prismGroup(_ project: ProjectModel) -> SelectionGroup? {
        guard let g = project.selection.activeGroup else { return nil }
        if controlPrismOnOpen { return g }   // RED CONTROL: S1b's rule — the active group's prism on open
        guard sessionPicked, !project.force.kind(for: g.id).isPending else { return nil }
        return g
    }

    /// Batch V's two view settings were kept in the app's defaults under this key (2026-10-10 → R7-V).
    nonisolated static func batchVSettingsKey(_ project: UUID) -> String { "flexible.mainViewSettings." + project.uuidString }
}
