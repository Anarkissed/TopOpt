// SurfaceScratch.swift — ★ THE SURFACE STAGE IS A SCRATCHPAD UNTIL YOU SAVE IT.
//
// Maintainer, 2026-08-16:
//
//   "I think we should have a 'Save' button on the 'Surfaces' page. This way
//    someone can fuck around and mess things up, and just go back and nothing is
//    saved. Everything should reset when you leave and come back — unless it has
//    been saved."
//
// ── WHY THIS IS A VALUE TYPE AND NOT AN UNDO STACK ──────────────────────────
//
// The page already has undo, and undo is the wrong shape for this. Undo answers
// "take back the last thing"; this answers "take back EVERYTHING since I walked
// in", which is one decision the user makes once, at the door. Expressed as undo
// it would be "press it n times, and n is whatever you happen to remember" — and
// a cut that spawned two regions, was patterned into six and then unioned is not
// a number anyone is holding.
//
// ★ AND WHAT HAS TO BE CAPTURED IS BOTH LAYERS. The regions themselves are the
// obvious half. The other half is which GROUP each region belongs to: a cut hands
// its pieces to the group that held the parent, isolating pulls faces out of every
// region that held them, and a piece can be moved between groups on the Topology
// page. Restoring the regions while leaving the group membership as the edits left
// it would reinstate the old regions under new ownership — worse than either state
// on its own, because nothing would then resolve to what it did before.
//
// So the snapshot is exactly the two things surface edits touch, taken together
// and restored together.

import Foundation
import TopOptKit

/// The model state a Surface session can throw away.
public struct SurfaceScratch: Equatable, Sendable {

    /// LAYER 2 in full — every region, its cuts, its parts, its edges.
    public var regions: FaceRegionModel
    /// Which regions each group held, by group id. Faces are NOT captured: no
    /// surface tool adds or removes a raw face from a group, so restoring them
    /// would overwrite Topology-page work done in another tab of the same session.
    public var groupRegions: [UUID: [RegionID]]

    public init(regions: FaceRegionModel, groupRegions: [UUID: [RegionID]]) {
        self.regions = regions
        self.groupRegions = groupRegions
    }

    /// Take the snapshot. Called on ENTERING the stage and again after each save,
    /// so "since when" is always "since the last point the user committed to".
    public static func capture(regions: FaceRegionModel,
                               groups: [SelectionGroup]) -> SurfaceScratch {
        var byGroup: [UUID: [RegionID]] = [:]
        for g in groups { byGroup[g.id] = g.regionIDs }
        return SurfaceScratch(regions: regions, groupRegions: byGroup)
    }

    /// Whether anything this snapshot covers has changed since it was taken. Used
    /// for the Save button's enabled state, so "Save" is never offered for nothing
    /// and never withheld when there is something.
    public func differs(regions other: FaceRegionModel,
                        groups: [SelectionGroup]) -> Bool {
        if regions != other { return true }
        if groups.count != groupRegions.count { return true }
        for g in groups where groupRegions[g.id] != g.regionIDs { return true }
        return false
    }
}
