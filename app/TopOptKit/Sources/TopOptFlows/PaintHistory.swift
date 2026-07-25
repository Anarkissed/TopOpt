// PaintHistory.swift — the undo/redo stack for paint strokes (handoff
// 2026-07-24).
//
// The task requires painted strokes to be undo STEPS, coordinated with the
// undo/redo work. There is no app-wide undo stack yet, so this is the seam: a
// pure, self-contained history of `PaintEdit` commands (each already exactly
// invertible — see PaintModel), driving a `PaintModel` back and forth. When the
// app grows a global undo coordinator, a painted stroke is one `PaintEdit` and
// this is the adapter it wraps; nothing here assumes a paint-only world.
//
// Pure value type, unit-tested headlessly.

import Foundation

/// A linear undo/redo history of paint edits over a single `PaintModel`.
public struct PaintHistory: Equatable, Sendable, Codable {
    public private(set) var undoStack: [PaintEdit] = []
    public private(set) var redoStack: [PaintEdit] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Record a stroke the caller has ALREADY applied to the model. A no-op stroke
    /// (an empty edit — the user brushed only already-correct triangles) is
    /// dropped so it never becomes a dead undo step. Recording clears the redo
    /// branch, the standard linear-history rule.
    public mutating func record(_ edit: PaintEdit) {
        guard !edit.isEmpty else { return }
        undoStack.append(edit)
        redoStack.removeAll()
    }

    /// Undo the most recent stroke against `model`, returning the edit undone (nil
    /// if nothing to undo).
    @discardableResult
    public mutating func undo(_ model: inout PaintModel) -> PaintEdit? {
        guard let edit = undoStack.popLast() else { return nil }
        model.undo(edit)
        redoStack.append(edit)
        return edit
    }

    /// Redo the most recently undone stroke against `model`.
    @discardableResult
    public mutating func redo(_ model: inout PaintModel) -> PaintEdit? {
        guard let edit = redoStack.popLast() else { return nil }
        model.redo(edit)
        undoStack.append(edit)
        return edit
    }
}
