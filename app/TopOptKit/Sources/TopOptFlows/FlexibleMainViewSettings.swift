// FlexibleMainViewSettings — his two VIEW SETTINGS on the main Flexible page (task 2026-09-29-flexible-screens,
// round 6, batch V). His words, 2026-10-10, after item 4 (one set of groups) was reverted: his two answers of
// 2026-10-09 were built inside item 4 and went with it — "Bring both back as a view setting that can each be turned
// off at will."
//   ★ "Role colours off" (ON by default): no role colour on the main page's MODEL — #354's Selections colours (H4 hands
//     them over as `roles`; they are dropped HERE, in the Flexible code — H4's line is unchanged) and Flexible's own role
//     marks (the pressed green, the resting cyan, the selected face and its linked end). The Selections list keeps its
//     colours, and the Settings page keeps its marks (his answer: "colours show in the Selections list and on the
//     Settings page only"). OFF: the model as #354 and round 6 paint it.
//   ★ "Prism after a pick" (ON by default): the main page shows a group's prism and its mm number only once he has
//     picked a group in this session — nothing on open — and a Pending group (no role) shows none. A pick is the active
//     Selections group changing, or the active group tapped again (#354's row re-sets it: an equal write), from the
//     stage's first look at the project on, while no Settings page is up. OFF: the active Selections group's prism on
//     open, as S1b built it.
// ★ PER PROJECT, ON THIS DEVICE: kept in the app's defaults under the project's id — never in the project file, never an
//   undo step, never a Flexible setting or the lattice's key, never an action (the other view toggles — Dent heat,
//   Stress, Lattice, Prisms — are this session's only). Read when the stage makes the project's model (`ensure`).

import Combine
import Foundation

/// His two view settings on the main Flexible page (both ON by default).
public struct FlexibleMainViewSettings: Codable, Equatable, Sendable {
    /// "Role colours off": no role colour on the main page's model.
    public var roleColoursOff: Bool
    /// "Prism after a pick": a group's prism and number only after he picks a group in this session.
    public var prismAfterPick: Bool

    public init(roleColoursOff: Bool = true, prismAfterPick: Bool = true) {
        self.roleColoursOff = roleColoursOff
        self.prismAfterPick = prismAfterPick
    }
}

/// Where the two settings are kept: per project (by its id), on this device.
public struct FlexibleMainViewSettingsStore {
    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The app's own defaults.
    public static var standard: FlexibleMainViewSettingsStore { FlexibleMainViewSettingsStore(defaults: .standard) }

    /// The key a project's settings are kept under.
    static func key(_ project: UUID) -> String { "flexible.mainViewSettings." + project.uuidString }

    /// The project's settings (both ON when none are kept, or what is kept cannot be read).
    public func load(_ project: UUID) -> FlexibleMainViewSettings {
        guard let data = defaults.data(forKey: Self.key(project)),
              let s = try? JSONDecoder().decode(FlexibleMainViewSettings.self, from: data) else { return FlexibleMainViewSettings() }
        return s
    }

    /// Keep the project's settings.
    public func save(_ s: FlexibleMainViewSettings, for project: UUID) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.key(project))
    }
}

extension FlexibleMainStage {
    /// "Role colours off", on ⇄ off (his tap): kept for his project, and the model's colours composed again at once.
    public func setRoleColoursOff(_ on: Bool) {
        guard viewSettings.roleColoursOff != on else { return }
        objectWillChange.send()
        viewSettings.roleColoursOff = on
        keepViewSettings()
        composedKey = nil
        refresh()
    }

    /// "Prism after a pick", on ⇄ off (his tap): kept for his project; the prisms and their numbers follow at once.
    public func setPrismAfterPick(_ on: Bool) {
        guard viewSettings.prismAfterPick != on else { return }
        objectWillChange.send()
        viewSettings.prismAfterPick = on
        keepViewSettings()
        volumesCache = nil
    }

    private func keepViewSettings() {
        guard let id = model?.project.id else { return }
        viewStore.save(viewSettings, for: id)
    }

    /// The project's view settings, and a fresh session of picks (nothing picked as the stage first looks at it). Called by
    /// `ensure` when the stage makes the project's model — from a view's init: it publishes nothing.
    func openViewSettings(_ project: ProjectModel) {
        viewSettings = viewStore.load(project.id)
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

    /// The group whose prism and number the main page may draw: the active Selections group — under "Prism after a pick"
    /// only once he has picked in this session, and never a Pending group.
    func prismGroup(_ project: ProjectModel) -> SelectionGroup? {
        guard let g = project.selection.activeGroup else { return nil }
        guard viewSettings.prismAfterPick else { return g }
        guard sessionPicked, !project.force.kind(for: g.id).isPending else { return nil }
        return g
    }
}
