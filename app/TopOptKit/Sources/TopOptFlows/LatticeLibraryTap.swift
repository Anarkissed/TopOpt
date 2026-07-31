// LatticeLibraryTap.swift — how a model tap routes into the ONE selection model
// while the LATTICE page's Selections library is open (round-2 L18/L22/L23, M2).
//
// The lattice page BUILDS ON what the TO page made; it never starts over and it
// never takes anything away. The rules, versus the TO page's `WorkspaceTap`:
//   * A face that belongs to a group — ANY group, active or not — SELECTS that
//     group. Never a toggle-off, never a steal: removal happens only back on the
//     TO page (L23 — "selecting such a face must be non-destructive").
//   * A free (unowned) face grows the active group, or starts a fresh one when
//     none is active. Only unowned faces are added, so nothing can be stolen
//     from an existing group.
//   * Nothing here removes a face or drops a group, so every TO-page group and
//     face SURVIVES any tap sequence — bar M2 asserts this exhaustively.
//
// Pure decision layer over `SelectionModel` (the M7 /app/ headless-test standard);
// the workspace's `handlePick` calls it while `latticePageModel.libraryOpen`.

import Foundation

public enum LatticeLibraryTap {

    /// Route a tapped face (and its resolved loop) into `selection`,
    /// non-destructively. Returns the id of the group the tap ended up
    /// selecting or growing (for chip-reveal bookkeeping).
    @discardableResult
    public static func route(faceID: FaceID, loop: [FaceID],
                             selection: inout SelectionModel) -> UUID? {
        // An owned face — wherever it lives — selects its group. Nothing moves.
        if let owner = selection.group(forFace: faceID) {
            selection.setActive(owner.id)
            return owner.id
        }
        // A free face (with its free loop members) grows the active group, or
        // starts a fresh one. Only unowned faces are added — no steal possible.
        let fresh = loop.filter { selection.group(forFace: $0) == nil }
        let keys = fresh.isEmpty ? [faceID] : fresh
        if selection.activeGroup == nil { selection.addGroup() }
        guard let id = selection.activeGroupID else { return nil }
        selection.addFaces(keys, to: id)
        return id
    }
}
