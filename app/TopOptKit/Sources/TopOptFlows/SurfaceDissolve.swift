// SurfaceDissolve.swift — ★★ DISSOLVE, ONE DEFINITION.
//
// The reviewer, 2026-10-08 (approved by the maintainer), the Regions task: "Dissolve: the faces go
// back to the group they came from." The Regions sheet's Dissolve used to hand the faces to the
// ACTIVE group (or to nobody when none was active), leave the dropped children's ids dangling in
// their groups, and — on a union of parts — delete the very pieces the user had combined. One
// function now, called by the sheet and by the Surface stage's Region tool:
//   • a face region (a face, a hand-picked set, a filter) is removed and its faces go back to the
//     group that held it — or, for a piece of something, the group that held its nearest ancestor;
//   • a union of parts gives its parts back under their own parents (`FaceRegion.partParents`);
//     they never left their groups, so the groups read as they did before the union;
//   • every region the dissolve removes is removed from every group, so no id is left dangling;
//   • a CUT piece is refused: its faces are its whole parent face, so "giving them back" would
//     lay the whole face over its sibling pieces — a cut is taken back with Undo split.

import Foundation

public enum SurfaceDissolve {

    public struct Result: Equatable, Sendable {
        /// The faces handed back (empty for a union of parts, whose parts come back instead).
        public var faces: [FaceID]
        /// The group they went to; nil when no group held the region or any ancestor.
        public var group: UUID?
        /// Every region the dissolve removed (the region, and anything that hung off it).
        public var dropped: [RegionID]
        /// A union's parts, back under their own parents.
        public var restoredParts: [RegionID]
    }

    /// Why `id` cannot be dissolved, or nil when it can.
    public static func refusal(_ id: RegionID, regions: FaceRegionModel) -> String? {
        guard let r = regions.region(id) else { return "That region no longer exists." }
        if r.isCut { return "A cut piece is taken back with Undo split." }
        return nil
    }

    /// The group a region came from: the one holding it, else the one holding its nearest ancestor.
    public static func sourceGroup(of id: RegionID, regions: FaceRegionModel,
                                   selection: SelectionModel) -> UUID? {
        var current: RegionID? = id
        var steps = 0
        while let c = current, steps <= regions.regions.count {
            steps += 1
            if let g = selection.group(forRegion: c) { return g.id }
            guard let r = regions.region(c), r.parentID >= 0 else { return nil }
            current = r.parentID
        }
        return nil
    }

    @discardableResult
    public static func apply(_ id: RegionID, regions: inout FaceRegionModel,
                             selection: inout SelectionModel, mesh: ViewerMesh) -> Result? {
        guard refusal(id, regions: regions) == nil, let r = regions.region(id) else { return nil }
        let source = sourceGroup(of: id, regions: regions, selection: selection)
        let faces = r.isUnionOfParts ? [] : FaceRegionGeometry.members(of: r, in: mesh)
        let restored = r.partParents == nil ? [] : r.parts
        let before = Set(regions.regions.map(\.id))
        _ = regions.dissolve(id, resolvedMembers: faces)
        let dropped = before.subtracting(regions.regions.map(\.id)).sorted()
        // faces first, so the group they return to is never swept as empty in between
        if let g = source, !faces.isEmpty { selection.addFaces(faces, to: g) }
        selection.removeRegions(dropped)
        return Result(faces: faces, group: faces.isEmpty ? nil : source,
                      dropped: dropped, restoredParts: restored)
    }
}
