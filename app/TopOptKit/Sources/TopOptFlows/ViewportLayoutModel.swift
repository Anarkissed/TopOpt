// ViewportLayoutModel.swift — the SwiftUI-side owner of the keep-out pass (handoff
// 2026-07-27). `KeepOutSolver`/`KeepOutStabilizer` are pure value types; this thin
// `@MainActor` observable holds the per-frame temporal state (the stabilizer) and the
// resolved placements the overlays read back. `WorkspacePlaceholder` builds the
// element list each camera frame (in the `onProjection` publish path — exactly once
// per frame, so the stabilizer advances once per frame) and calls `resolve`; every
// overlay then draws at `placement(id)?.center` instead of a raw projected point.
//
// Kept deliberately tiny and side-effect-free beyond publishing `placements`, so the
// interesting logic stays in the headlessly-tested pure engine.

import Foundation
import CoreGraphics

@MainActor
public final class ViewportLayoutModel: ObservableObject {
    /// The resolved placement for every registered element, keyed by id. Overlays read
    /// `placements[id]` for the final centre + leader flag; a missing id (before the
    /// first resolve) means "fall back to the raw anchor".
    @Published public private(set) var placements: [String: KeepOutPlacement] = [:]

    private var stabilizer = KeepOutStabilizer()

    public init() {}

    /// Run the pass for this frame: resolve overlaps deterministically, then smooth toward
    /// the result. `anchors` carries each element's raw projected anchor so the stabilizer
    /// can compute the leader distance against where the element actually points.
    public func resolve(_ elements: [KeepOutElement], viewport: CGSize) {
        let anchors = Dictionary(elements.map { ($0.id, $0.anchor) }, uniquingKeysWith: { a, _ in a })
        let target = KeepOutSolver.resolve(elements, viewport: viewport)
        let smoothed = stabilizer.step(target, anchors: anchors)
        var map: [String: KeepOutPlacement] = [:]
        map.reserveCapacity(smoothed.count)
        for p in smoothed { map[p.id] = p }
        placements = map
    }

    /// The resolved placement for `id`, or nil before the first resolve / if the element
    /// wasn't registered this frame.
    public func placement(_ id: String) -> KeepOutPlacement? { placements[id] }

    /// Reset temporal memory — call when the whole overlay set changes wholesale (new model
    /// loaded) so nothing eases in from a stale position.
    public func reset() { stabilizer.reset(); placements = [:] }
}
