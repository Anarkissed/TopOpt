// WorkspaceInteraction.swift — how a tap on the model routes into the selection
// during the M7.6 edit phase.
//
// The rule (round-4 device note, item 1 — supersedes the old "a tap never removes"):
//   * Tapping a face in the ACTIVE (pending/selected) group DESELECTS it — the face
//     (and its co-selected loop members) leave that group; if the group empties it is
//     dropped (the existing empty-group cleanup). This is the natural tap-toggle the
//     `SelectionModel` already implements; the router now lets it through for the
//     active group instead of short-circuiting it.
//   * Tapping a face that belongs to ANOTHER (inactive) group RE-SELECTS that group
//     (so its weight/direction can be edited) — it never steals the face and never
//     toggles it off; removal there is still the Selections-panel trash icon only.
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
        // 1. Tapping an already-grouped face:
        //    * in the ACTIVE group → DESELECT it (item 1). Remove the tapped face and any
        //      co-selected loop members that live in the active group; `pickFaces` removes
        //      when every key is already in the active group (tap-again-to-deselect). If the
        //      group is left empty, drop it (matching the model's empty-group cleanup).
        //    * in ANOTHER group → re-select that group, no steal, no toggle-off.
        if let owner = selection.group(forFace: faceID) {
            guard owner.id == selection.activeGroupID else {
                selection.setActive(owner.id)
                return
            }
            let owned = loop.filter { owner.faces.contains($0) }
            selection.pickFaces(owned.isEmpty ? [faceID] : owned)
            if selection.activeGroup?.faces.isEmpty == true { selection.clearActive() }
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
