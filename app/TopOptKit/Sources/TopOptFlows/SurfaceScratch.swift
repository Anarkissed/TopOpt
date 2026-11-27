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
// and restored together — and since 2026-10-08 the second is the WHOLE group layer (below).

import Foundation
import TopOptKit

/// The model state a Surface session can throw away.
///
/// ★★ THE WHOLE GROUP LAYER SINCE 2026-10-08 (the Regions task ruling: "The Surface scratchpad
/// carries groups, so Dissolve reverts cleanly"). It held only each group's REGION list, on the
/// premise that no surface tool touches a group's faces. Two do: Dissolve hands faces back to their
/// group, and Isolate takes them out of every group — and any add or drop can SWEEP a group left
/// empty, which also drops its role, load and protection from the force model. So the snapshot is
/// now every group as it was (faces, regions, name, colour, order), the active group, and the force
/// model, from which a group the session swept gets its entries back.
public struct SurfaceScratch: Equatable, Sendable {

    /// LAYER 2 in full — every region, its cuts, its parts, its edges.
    public var regions: FaceRegionModel
    /// Every group as it was: faces AND regions, name, colour, order.
    public var groups: [SelectionGroup]
    /// The group that was active.
    public var activeGroupID: UUID?
    /// The force model as it was — only a group the session SWEPT takes its entries back from it, so
    /// a live group's role or load is never overwritten by the revert.
    public var force: ForceModel

    /// Which regions each group held, by group id (the pre-2026-10-08 view of the snapshot).
    public var groupRegions: [UUID: [RegionID]] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.regionIDs) })
    }

    public init(regions: FaceRegionModel, groups: [SelectionGroup], activeGroupID: UUID?, force: ForceModel) {
        self.regions = regions
        self.groups = groups
        self.activeGroupID = activeGroupID
        self.force = force
    }

    /// Take the snapshot. Called on ENTERING the stage and again after each save,
    /// so "since when" is always "since the last point the user committed to".
    public static func capture(regions: FaceRegionModel, selection: SelectionModel,
                               force: ForceModel) -> SurfaceScratch {
        SurfaceScratch(regions: regions, groups: selection.groups,
                       activeGroupID: selection.activeGroupID, force: force)
    }

    /// Whether anything this snapshot covers has changed since it was taken. Used
    /// for the Save button's enabled state, so "Save" is never offered for nothing
    /// and never withheld when there is something.
    public func differs(regions other: FaceRegionModel, groups now: [SelectionGroup]) -> Bool {
        regions != other || groups != now
    }
}
