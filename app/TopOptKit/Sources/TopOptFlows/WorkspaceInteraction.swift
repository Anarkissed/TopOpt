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

        // Grow the ACTIVE group — pending or committed (round-2 T3). Committing a
        // role clears the active selection (M7.6), so a committed group is active
        // only when the user EXPLICITLY re-selected it (its row, or one of its
        // faces) — and then adding an empty face to it is exactly what they asked
        // for. Before this fix the only way to add a face to a committed group
        // was to delete it and rebuild it (the reported functional gap): a tap
        // silently started a FRESH group instead.
        if selection.activeGroup == nil { selection.clearActive() }
        selection.pickFaces(fresh)
    }
}

/// Route a paint stroke into the active group's painted pseudo-face — the paint-
/// mode counterpart of `WorkspaceTap.route` (handoff 2026-07-24). Pure decision
/// layer over `PaintModel` + `SelectionModel`, so the whole "brush adds to /
/// erases from the current group, one painted face per group" behaviour is
/// unit-tested headlessly; the SwiftUI viewer computes the covered `triangles`
/// with `BrushHitTest` and calls this, then persists via `PaintController`.
public enum WorkspacePaint {

    /// The painted face id owned by `group`, if it has one (a group owns at most
    /// one painted face by construction).
    public static func paintedFace(of group: SelectionGroup, in paint: PaintModel) -> FaceID? {
        group.faces.first { paint.isPainted($0) }
    }

    /// Apply a brush stroke to the active group.
    ///
    /// - `.add`  : ensures an active group (creating one if needed), mints that
    ///   group's painted face on first use, paints the triangles into it, and adds
    ///   the painted id to the group.
    /// - `.erase`: reverts the triangles to their native faces; if the group's
    ///   painted face is left empty it is removed from the group.
    ///
    /// Records the edit on `history` for undo. A stroke that changes nothing is a
    /// no-op (no group churn, no dead undo step).
    public static func stroke(_ mode: PaintMode, triangles: [Int],
                              paint: inout PaintModel, selection: inout SelectionModel,
                              history: inout PaintHistory) {
        guard !triangles.isEmpty else { return }

        switch mode {
        case .add:
            if selection.activeGroup == nil { selection.addGroup() }
            guard let active = selection.activeGroup else { return }
            let target = paintedFace(of: active, in: paint) ?? paint.mintFace()
            let edit = paint.apply(.add, target: target, triangles: triangles.map(Int32.init))
            history.record(edit)
            // Add the painted id to the active group (skip if already present —
            // pickFaces would TOGGLE an already-owned face off).
            if !(selection.activeGroup?.faces.contains(target) ?? false) {
                selection.pickFaces([target])
            }

        case .erase:
            guard let active = selection.activeGroup,
                  let target = paintedFace(of: active, in: paint) else { return }
            let edit = paint.apply(.erase, target: target, triangles: triangles.map(Int32.init))
            history.record(edit)
            // If the group's painted face is now empty, drop it from the group.
            if paint.triangles(ofPaintedFace: target).isEmpty,
               selection.activeGroup?.faces.contains(target) == true {
                selection.pickFaces([target])  // all-in-active → removes it
            }
        }
    }
}

/// ★ WHAT A TAP ON A REGION-OWNED PIECE DOES, on the Topology page.
///
/// Extracted from the view for one reason: the rule is two optionals compared, and
/// comparing two optionals is exactly where it went wrong.
///
/// ★ THE DEFECT THIS EXISTS TO PIN. The view asked
/// `owner?.id == selection.activeGroupID`, meaning "is this piece already in the
/// group I am building?". An ISOLATED piece belongs to no group, so `owner` is nil;
/// on a page where nothing has been selected yet `activeGroupID` is nil too — and
/// `nil == nil` is TRUE. So the tap took the "already mine, drop it and stop"
/// branch and did nothing whatsoever, every time, for the one kind of piece that is
/// unowned by design. The maintainer met it as "the face is still not selectable on
/// its own … it is impossible to highlight it as part of any group selection."
public enum TopologyPieceTap {

    public enum Outcome: Equatable, Sendable {
        /// The piece was in the active group: take it out, and stop.
        case removeOnly
        /// Anything else: take it from whoever had it and give it to the active
        /// group, starting one if there is none.
        case moveToActive
    }

    /// `owner` is the group holding the piece (nil = nobody); `active` is the group
    /// being built (nil = none yet).
    public static func route(owner: UUID?, active: UUID?) -> Outcome {
        // ★ AN OWNER IS REQUIRED. "No owner" can never mean "owned by the active
        // group", however the two optionals happen to compare.
        guard let owner, owner == active else { return .moveToActive }
        return .removeOnly
    }
}
