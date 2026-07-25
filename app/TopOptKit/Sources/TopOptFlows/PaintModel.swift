// PaintModel.swift — the paint-mode SAFETY NET for face selection (handoff
// 2026-07-24).
//
// Auto-segmentation is "usually right" but never guaranteed; when it merges
// regions a human reads as distinct (the shelf-bracket hole that also grabbed
// the Load face), the user must have an escape that is NOT "abandon the model".
// Paint mode is that escape: brush across the surface to add triangles to the
// current group, hold the erase modifier to remove them. A painted selection is
// just a SET OF TRIANGLES, and this model turns it into the SAME face-id contract
// everything downstream already speaks:
//
//   * each group's painted region is ONE pseudo-face, minted with an id ABOVE the
//     imported face count (`baseFaceCount`), so it never collides with a native
//     pseudo-face;
//   * `assignments` overrides a triangle's face id, so the viewer highlight, the
//     picker, tagging, clearance and the optimizer all see the painted face
//     exactly as if the segmenter had produced it;
//   * on persist the painted sets become the `face` lines of the core sidecar
//     (see face_overrides.hpp / TopOptBridge.write_face_overrides), so a re-import
//     — live tagging AND the run — reproduces them. "Painted == tapped" all the
//     way to the voxel grid (proven in core/tests/unit/test_face_overrides.cpp).
//
// A pure value type — no SwiftUI, no GPU, no bridge — so the whole apply / erase /
// undo / determinism story is unit-tested headlessly (the /app/ standard). The
// gesture layer (BrushHitTest) feeds it triangle indices; the SwiftUI/Metal glue
// renders `effectiveFaceIDs` over it.

import Foundation

/// Add triangles to the target painted face, or erase them back to their native
/// face. Erase is the modifier/second-finger gesture.
public enum PaintMode: String, Sendable, Codable {
    case add
    case erase
}

/// The change a single triangle undergoes in one edit: from `oldFace` (nil ==
/// it was on its NATIVE segmentation face) to `newFace` (nil == reverted to
/// native). Storing both ends is what makes an edit exactly invertible — the
/// undo unit the undo/redo coordinator replays.
public struct PaintChange: Equatable, Sendable, Codable {
    public var triangle: Int32
    public var oldFace: FaceID?
    public var newFace: FaceID?

    public init(triangle: Int32, oldFace: FaceID?, newFace: FaceID?) {
        self.triangle = triangle
        self.oldFace = oldFace
        self.newFace = newFace
    }
}

/// One brush stroke's worth of change — a reversible command. `changes` are in
/// ascending triangle order (determinism), and a stroke that touched only
/// already-correct triangles produces an empty, no-op edit.
public struct PaintEdit: Equatable, Sendable, Codable {
    public var changes: [PaintChange]
    public var isEmpty: Bool { changes.isEmpty }
    public init(changes: [PaintChange] = []) { self.changes = changes }
}

/// The paint overlay for one imported part: which triangles have been painted
/// onto which minted pseudo-face, plus the id-minting cursor.
public struct PaintModel: Equatable, Sendable, Codable {
    /// The number of NATIVE (segmentation) pseudo-faces. Painted ids start here,
    /// so `id >= baseFaceCount` iff `id` is a painted face.
    public let baseFaceCount: Int32
    /// triangle index → painted face id, for painted triangles ONLY. A triangle
    /// absent from this map renders/tags on its native `faceIDs[triangle]`.
    public private(set) var assignments: [Int32: FaceID]
    /// Monotonic id cursor. Never rewound (even when a painted face is fully
    /// erased), so ids are stable and unique for the life of the model — a
    /// re-used id would silently merge two different painted regions across undo.
    private var nextPaintedID: FaceID

    public init(baseFaceCount: Int32, assignments: [Int32: FaceID] = [:]) {
        self.baseFaceCount = baseFaceCount
        self.assignments = assignments
        let maxUsed = assignments.values.max().map { $0 + 1 } ?? baseFaceCount
        self.nextPaintedID = Swift.max(baseFaceCount, maxUsed)
    }

    /// True iff `id` names a painted face (vs a native segmentation face).
    public func isPainted(_ id: FaceID) -> Bool { id >= baseFaceCount }

    /// Mint a fresh painted face id (does not touch `assignments` — the caller
    /// paints into it). Use once per group that starts painting.
    public mutating func mintFace() -> FaceID {
        let id = nextPaintedID
        nextPaintedID += 1
        return id
    }

    /// The painted face ids currently carrying at least one triangle, ascending.
    public var activePaintedFaces: [FaceID] {
        Array(Set(assignments.values)).sorted()
    }

    /// The triangles of painted face `id`, ascending (empty if none / not painted).
    public func triangles(ofPaintedFace id: FaceID) -> [Int32] {
        assignments.filter { $0.value == id }.map { $0.key }.sorted()
    }

    /// The painted triangle sets in the order they persist to the sidecar
    /// (ascending painted id, ascending triangles within each) — the SAME order
    /// `apply_face_overrides` appends them, so the i-th set re-imports as face id
    /// `baseFaceCount + i`.
    public func paintFaceSets() -> [[Int32]] {
        activePaintedFaces.map { triangles(ofPaintedFace: $0) }
    }

    /// The id each LIVE painted face takes after a resolved re-import (which packs
    /// painted faces densely from `baseFaceCount`). A live session can leave gaps
    /// (a fully-erased region frees no id — ids never rewind, to keep them stable),
    /// but the persisted sidecar is dense, so a group that references a live
    /// painted id must translate through this before it reaches the bridge/run, or
    /// it would tag the wrong face. A native id (`< baseFaceCount`) maps to itself.
    /// With no gaps (the common case) this is the identity.
    public var exportRemap: [FaceID: FaceID] {
        var map: [FaceID: FaceID] = [:]
        for (i, id) in activePaintedFaces.enumerated() {
            map[id] = baseFaceCount + FaceID(i)
        }
        return map
    }

    /// `faceID` as the resolved re-import will number it (see `exportRemap`).
    public func resolvedFaceID(_ faceID: FaceID) -> FaceID {
        faceID < baseFaceCount ? faceID : (exportRemap[faceID] ?? faceID)
    }

    /// The effective face id of `triangle`: its painted override if any, else its
    /// native id from `base` (the imported `ViewerMesh.faceIDs`).
    public func effectiveFaceID(_ triangle: Int, base: [Int32]) -> FaceID {
        if let painted = assignments[Int32(triangle)] { return painted }
        return (triangle >= 0 && triangle < base.count) ? base[triangle] : -1
    }

    /// `base` with every painted override applied — the per-triangle face id array
    /// the viewer highlight and the picker consume so a painted face behaves like
    /// any other. Same length as `base`.
    public func effectiveFaceIDs(base: [Int32]) -> [Int32] {
        var out = base
        for (tri, face) in assignments where tri >= 0 && Int(tri) < out.count {
            out[Int(tri)] = face
        }
        return out
    }

    // MARK: - editing (the undoable commands)

    /// Apply a brush stroke and return the exact inverse-able edit.
    ///
    /// - `.add`  : every triangle in `triangles` becomes `target` (a painted id,
    ///             which the caller minted for the active group).
    /// - `.erase`: every triangle in `triangles` currently painted reverts to its
    ///             native face; `target` is ignored.
    ///
    /// Triangles are sorted and de-duplicated, and a triangle already at its
    /// destination contributes NO change — so the returned `PaintEdit` is minimal
    /// and deterministic, and re-painting the same stroke is a no-op.
    @discardableResult
    public mutating func apply(_ mode: PaintMode, target: FaceID,
                               triangles: [Int32]) -> PaintEdit {
        var changes: [PaintChange] = []
        let ordered = Array(Set(triangles)).sorted()
        for tri in ordered {
            let old = assignments[tri]
            switch mode {
            case .add:
                if old == target { continue }
                changes.append(PaintChange(triangle: tri, oldFace: old, newFace: target))
                assignments[tri] = target
            case .erase:
                if old == nil { continue }
                changes.append(PaintChange(triangle: tri, oldFace: old, newFace: nil))
                assignments[tri] = nil
            }
        }
        return PaintEdit(changes: changes)
    }

    /// Re-apply an edit (redo): drive each triangle to its `newFace`.
    public mutating func redo(_ edit: PaintEdit) {
        for c in edit.changes { set(c.triangle, c.newFace) }
    }

    /// Reverse an edit (undo): drive each triangle back to its `oldFace`.
    public mutating func undo(_ edit: PaintEdit) {
        for c in edit.changes { set(c.triangle, c.oldFace) }
    }

    private mutating func set(_ triangle: Int32, _ face: FaceID?) {
        if let f = face { assignments[triangle] = f } else { assignments[triangle] = nil }
    }
}
