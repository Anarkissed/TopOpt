// FlexibleMainStage+Groups — the main page's side of ONE SET OF GROUPS (task 2026-09-29-flexible-screens, round 6
// item 4; FlexibleGroupSync has the model):
//   * H16 — on the Flexible stage each Selections row's swatch is its squeeze group's colour (the Settings rail's), an
//     Anchor in Rests cyan; a Pending group keeps #354's own tint;
//   * H17 — ONE caption under a hand squeezed with another ("Squeezed with Group 2 · Face 2": a pinch's two rows);
//   * his answer of 2026-10-09: a group's prism and mm number show ONLY after he picks a group on the main page in this
//     session — nothing on open (his pad is saved with Group C active) — and a Pending group shows none. A pick is the
//     active group changing, or the same group tapped again (#354's row re-sets it: an equal write), from the stage's
//     first look at the project on (`ensure`), while no Settings page is up (Settings' own writes are never his pick).
// Off the Flexible stage every answer here is nil / unchanged, so #354's rows are exactly #354's.

import Foundation
import TopOptDesign

extension FlexibleMainStage {

    /// H16: the Selections row's swatch on the Flexible stage (nil: #354's own tint).
    public func groupTint(_ g: SelectionGroup, _ project: ProjectModel) -> RGBA? {
        guard visible, let m = current(project, .lattice) else { return nil }
        let k = project.force.kind(for: g.id)
        if k.isAnchor { return DS.Color.accentCyan }
        guard k.isLoad, let sq = m.squeezeGroup(ofHand: g.id) else { return nil }
        return m.groupColour(sq)
    }

    /// H17: "Squeezed with Group 2 · Face 2" on a hand squeezed with another (nil: no line). ★ ROUND 6 (item 4
    /// verification): OFF the Flexible stage — Topology, Optimize, where his load cases changed at restore — a row the
    /// restore's link made or changed says "Linked from Flexible Settings" until the one-time line has been shown.
    public func groupCaption(_ g: SelectionGroup, _ project: ProjectModel) -> String? {
        guard visible, let m = current(project, .lattice) else { return FlexibleGroupMigration.caption(g, project) }
        guard project.force.kind(for: g.id).isLoad, let sq = m.squeezeGroup(ofHand: g.id) else { return nil }
        let others = m.handIDs(sq).filter { $0 != g.id }.compactMap { id in project.selection.groups.first { $0.id == id }?.name }
        return others.isEmpty ? nil : FlexibleRowCopy.squeezedWith(others)
    }

    /// The group whose prism the main page may draw: the active one, once he has picked in this session — never a
    /// Pending group. (The red control restores S1b's rule: the active group, picked or not.)
    func pickedGroup(_ project: ProjectModel) -> SelectionGroup? {
        guard let g = project.selection.activeGroup else { return nil }
        if controlPrismOnOpen { return g }
        guard sessionPicked, !project.force.kind(for: g.id).isPending else { return nil }
        return g
    }

    /// The selection as #354 wrote it (H2's project, observed from `ensure`): a pick, unless a Settings page is up.
    func selectionMoved(_ new: SelectionModel) {
        defer { lastSelection = new }
        guard !frozen, let a = new.activeGroupID else { return }
        if a != lastSelection?.activeGroupID || new == lastSelection { sessionPicked = true }
    }
}
