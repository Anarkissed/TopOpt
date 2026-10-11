// FlexibleStageModel+EdgePick — the stage model's side of round 6 item 2: [+ New] → [Edges/corners] (task 2026-10-08;
// the maintainer OKed the design directly, the reviewer: "build it as posted"; r6 spec §3).
//
// ★ TESTS FIRST: the API FlexibleEdgeGroupsTests drive, as RED STUBS (lines marked "I2 RED STUB"): pick mode lists
// nothing, a tap picks nothing, [Done] stores nothing. The rules land in the next commit.

import CoreGraphics
import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {

    /// ★ [+ New] → [Edges/corners]: pick mode. I2 RED STUB: an empty list.
    public func startEdgePick() {
        guard edgePick == nil else { return }
        var p = FlexibleEdgePick(groupID: FlexibleSqueezeGroups.nextID(settings), colour: .mint)
        p.loading = false   // I2 RED STUB
        edgePick = p
    }

    public func cancelEdgePick() { edgePick = nil }

    public func toggleEdgePick(_ n: Int) {
        guard var p = edgePick, p.pickable(n) else { return }
        if let i = p.picks.firstIndex(of: n) { p.picks.remove(at: i) } else { p.picks.append(n) }
        edgePick = p
    }

    /// I2 RED STUB: a tap picks nothing.
    @discardableResult
    public func edgePickTap(at point: CGPoint, projection: CameraProjection) -> String? { nil }

    public func setEdgePickWeight(_ kg: Double) { edgePick?.weightKg = kg }

    /// I2 RED STUB: no line.
    public func edgePickKeepsTheRest() -> [String] { [] }

    /// I2 RED STUB: nothing is stored.
    @discardableResult
    public func finishEdgePick() async -> String? { "I2 RED STUB" }

    /// I2 RED STUB: nothing is re-cut.
    @discardableResult
    public func setStripWidth(_ id: UUID, mm: Double) async -> String? { "I2 RED STUB" }

    @discardableResult
    public func removeStripPresses(_ ids: [UUID]) async -> String? { "I2 RED STUB" }

    /// I2 RED STUB: no line.
    public func keepsTheRest(press id: UUID) -> [String] { [] }
}
