// WorkspaceInteraction.swift — how a tap on the model routes into the selection
// during the M7.6 edit phase.
//
// The rule (from workspace UX feedback): a tap NEVER removes a selection — removal
// is the Selections-panel trash icon only. Concretely:
//   * Tapping a face that already belongs to a group RE-SELECTS that group (so its
//     weight/direction can be edited) — it never steals the face into another group
//     and never toggles the face off.
//   * Tapping a new (unowned) face GROWS the active selection only while it is still
//     pending (no Anchor/Load role yet); once a group is committed, a tap starts a
//     FRESH group instead of silently changing a set one.
//
// This is the pure decision layer over the M7.5 `SelectionModel` (whose lower-level
// pick/steal/remove machinery is unchanged and still covers its own tests); keeping
// it a free function lets the routing be unit-tested headlessly (the M7 /app/
// standard) while the SwiftUI workspace just calls it from its tap handler.

import Foundation

public enum WorkspaceTap {

    /// Route a tapped B-rep face (and its resolved loop) into `selection`, per the
    /// no-tap-removes rule above. `force` is read-only here (to tell a pending group
    /// from a committed one); the caller syncs `force` to the new groups afterward.
    public static func route(faceID: FaceID, loop: [FaceID],
                             selection: inout SelectionModel, force: ForceModel) {
        // 1. Tapping an already-grouped face re-selects its group — no steal, no
        //    toggle-off. If it is already the active group, do nothing.
        if let owner = selection.group(forFace: faceID) {
            if owner.id != selection.activeGroupID { selection.setActive(owner.id) }
            return
        }
        // 2. A new face: only faces not owned by any group are added (so a stray
        //    multi-face loop can never pull faces out of a set group).
        let fresh = loop.filter { selection.group(forFace: $0) == nil }
        guard !fresh.isEmpty else { return }

        // Grow the active group only while it is still pending; once it is a
        // committed Anchor/Load, start a fresh group instead of changing the set one.
        let growActive = selection.activeGroup.map { force.kind(for: $0.id).isPending } ?? false
        if !growActive { selection.clearActive() }
        selection.pickFaces(fresh)
    }
}
