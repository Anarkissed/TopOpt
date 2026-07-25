// PaintController.swift — the observable glue that drives paint mode from the
// viewer and persists it (handoff 2026-07-24).
//
// The pure pieces (PaintModel, PaintHistory, BrushHitTest) are unit-tested on
// their own; this is the thin ObservableObject a SwiftUI viewer binds to. It
// owns the paint overlay + undo history for ONE imported part, mints a painted
// face per group on first stroke, and writes the sidecar so the run and live
// tagging reproduce the paint. It deliberately does NOT own the SelectionModel:
// the caller adds the returned painted face id to the active group (via
// SelectionModel.pickFaces), keeping the group state machine the single owner of
// group membership.

import Combine
import CoreGraphics
import Foundation
import TopOptKit

@MainActor
public final class PaintController: ObservableObject {
    /// The paint overlay (triangle → painted face id) for `modelPath`.
    @Published public private(set) var paint: PaintModel
    /// The stroke undo/redo history.
    @Published public private(set) var history = PaintHistory()

    /// Brush radius, in view points (the viewer scales the on-screen ring to it).
    @Published public var brushRadiusPoints: CGFloat = 22
    /// Whether the brush is currently erasing (the modifier / two-finger gesture).
    @Published public var isErasing = false
    /// Whether paint mode is the active interaction (vs tap selection).
    @Published public var isActive = false

    /// The app-owned working-copy STL the sidecar is written next to.
    public let modelPath: String
    /// Segmentation tuning persisted alongside the paint (0 / -1 = core default).
    public var dihedralDeg: Double = 0
    public var coneDeg: Double = -1

    public init(modelPath: String, baseFaceCount: Int, paint: PaintModel? = nil) {
        self.modelPath = modelPath
        self.paint = paint ?? PaintModel(baseFaceCount: Int32(baseFaceCount))
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    /// Apply a brush stroke to the active group (add, or erase per `isErasing`),
    /// routing through `WorkspacePaint` so the group gets/loses its painted face
    /// as needed, and recording the edit for undo. `selection` is mutated in place;
    /// the caller persists afterwards (on stroke-end).
    public func stroke(triangles: [Int], selection: inout SelectionModel,
                       mode: PaintMode? = nil) {
        WorkspacePaint.stroke(mode ?? (isErasing ? .erase : .add), triangles: triangles,
                              paint: &paint, selection: &selection, history: &history)
    }

    public func undo() { history.undo(&paint) }
    public func redo() { history.redo(&paint) }

    /// The per-triangle face ids the viewer highlight and picker should use, with
    /// painted overrides applied over the imported `base` (ViewerMesh.faceIDs).
    public func effectiveFaceIDs(base: [Int32]) -> [Int32] {
        paint.effectiveFaceIDs(base: base)
    }

    /// Translate a (possibly painted) group face id to the id a resolved re-import
    /// will use — the id to pass to tagging / the run. See PaintModel.exportRemap.
    public func resolvedFaceID(_ id: FaceID) -> FaceID { paint.resolvedFaceID(id) }

    /// Persist the current paint + tuning to the sidecar next to `modelPath`.
    /// Call on stroke-end and before a run so live tagging and the run reproduce
    /// exactly what the user painted. Throws the bridge's diagnostic on failure.
    public func persist() throws {
        try TopOptKit.writeFaceOverrides(modelPath: modelPath, dihedralDeg: dihedralDeg,
                                         coneDeg: coneDeg, paintFaces: paint.paintFaceSets())
    }
}
