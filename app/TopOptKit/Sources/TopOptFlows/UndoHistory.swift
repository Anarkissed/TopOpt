// UndoHistory.swift — round-6 item 4: snapshot-based undo/redo for the workspace edit state.
//
// The workspace's undoable state is three value structs on `ProjectModel` — the face
// SELECTIONS + groups (`SelectionModel`), the FORCE / clearance / keep-clear / protect load
// case (`ForceModel`), and the DESIGN-BOX + keep-outs (`DesignBoxModel`). All three are
// Equatable/Codable, so an `EditSnapshot` is a cheap by-value copy and equality is exact.
// `ProjectModel` records a snapshot whenever an edit SETTLES (a debounced auto-commit, so a
// handle drag or a scrub coalesces into one step), and the undo/redo controls / two-finger
// taps step the baseline back and forth. This history is PURE — no SwiftUI, no ProjectModel —
// so its push / coalesce / undo / redo / branch transitions are unit-tested headlessly (the
// /app/ verification standard).
//
// PAINT COORDINATION (paint-mode UI, handoff 2026-07-25): a painted stroke changes TWO things —
// the active group's membership (a `SelectionModel` delta, captured for free by the slice) AND
// the triangle→painted-face map (`PaintModel.assignments`), which is NOT in `SelectionModel`.
// The membership delta alone is insufficient: extending an already-painted group's face leaves
// `selection` UNCHANGED (the painted id is already in the group), so a selection-only snapshot
// would silently drop that stroke from history. The paint overlay is therefore folded into the
// slice as its own field, so a settled stroke — first or Nth — is one undo step that restores the
// exact painted triangles. This is the "register on the round-6 UndoHistory, don't fork" contract:
// ONE snapshot stack owns paint undo, not a second `PaintHistory`.

import Foundation

/// One undoable slice of the project's edit state (round-6 item 4). The value types a
/// workspace edit mutates, snapshotted together so undo restores a coherent moment.
public struct EditSnapshot: Equatable, Sendable {
    public var selection: SelectionModel
    public var force: ForceModel
    public var designBox: DesignBoxModel
    /// The paint overlay (triangle → painted pseudo-face) for the imported part, or nil for a
    /// project with no paintable mesh. Part of the slice so a painted stroke is undoable through
    /// the SAME history as every other edit (see PAINT COORDINATION above).
    public var paint: PaintModel?

    public init(selection: SelectionModel, force: ForceModel, designBox: DesignBoxModel,
                paint: PaintModel? = nil) {
        self.selection = selection
        self.force = force
        self.designBox = designBox
        self.paint = paint
    }
}

/// A bounded, snapshot-based undo/redo stack over `EditSnapshot`.
///
/// Model: `baseline` is the last COMMITTED state — equal to the live state at rest. `commit`
/// folds the old baseline onto the `past` stack, but ONLY when the incoming snapshot actually
/// differs, so an unrelated republish (a camera tick, a `quality` toggle, a run progress
/// forward) never manufactures a phantom step, and a burst that settles back to the same value
/// collapses to nothing. `undo`/`redo` move the baseline between `past` and `future` and RETURN
/// the slice the caller must apply to the model. A fresh `commit` clears `future` — a new edit
/// forks the timeline, the conventional undo/redo contract.
public struct UndoHistory: Equatable, Sendable {
    /// Committed states older than the baseline, oldest first; the top is one undo away.
    public private(set) var past: [EditSnapshot] = []
    /// States undone away, ready to redo; the top is one redo away.
    public private(set) var future: [EditSnapshot] = []
    /// The last committed state (== the live state at rest); nil until first seeded.
    public private(set) var baseline: EditSnapshot?
    /// Maximum retained undo steps — older steps drop off the bottom once exceeded.
    public let depth: Int

    /// - Parameter depth: how many undo steps to retain (default 50).
    public init(depth: Int = 50) {
        self.depth = Swift.max(1, depth)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Seed the baseline WITHOUT recording a step, clearing all history — used when a project
    /// opens or is restored so the loaded state is the floor undo can reach, never "before load".
    public mutating func reset(to snapshot: EditSnapshot) {
        past.removeAll()
        future.removeAll()
        baseline = snapshot
    }

    /// Record `snapshot` as the settled state. If it differs from the baseline, the old baseline
    /// becomes an undo step and the redo stack is cleared; equal snapshots are ignored, so this is
    /// safe to call on every republish. Returns true iff a step was actually recorded.
    @discardableResult
    public mutating func commit(_ snapshot: EditSnapshot) -> Bool {
        guard let base = baseline else { baseline = snapshot; return false }
        guard snapshot != base else { return false }
        past.append(base)
        if past.count > depth { past.removeFirst() }
        future.removeAll()
        baseline = snapshot
        return true
    }

    /// Step back one edit: returns the slice to restore (and moves the current baseline onto the
    /// redo stack), or nil at the bottom of the history.
    public mutating func undo() -> EditSnapshot? {
        guard let prev = past.popLast(), let current = baseline else { return nil }
        future.append(current)
        baseline = prev
        return prev
    }

    /// Step forward one undone edit: returns the slice to restore (and moves the current baseline
    /// back onto the undo stack), or nil at the top of the history.
    public mutating func redo() -> EditSnapshot? {
        guard let next = future.popLast(), let current = baseline else { return nil }
        past.append(current)
        baseline = next
        return next
    }
}
