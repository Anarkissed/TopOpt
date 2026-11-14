// SurfaceRegionTool.swift — ★★ THE REGION TOOL'S RULES (the Regions task, approved 2026-10-08:
// "A new 'Region' tray tool"). The Regions sheet's region verbs, on the Surface stage where the
// regions are made: aim at a region (and step up to what it was cut from), take a split back, dissolve
// it, and tap faces to add to it or drop from it. Pure, so the rules are tested without a view.

import Foundation

public enum SurfaceRegionTool {

    /// What a tap does while a region is aimed at.
    public enum TapEdit: Equatable, Sendable {
        case add(FaceID)
        case drop(FaceID)
        case refused(String)
    }

    /// Children a split made — a union's parts hang off it too, and they are not a split of it.
    public static func splitChildren(_ id: RegionID, regions: FaceRegionModel) -> [RegionID] {
        let parts = Set(regions.region(id)?.parts ?? [])
        return regions.children(of: id).map(\.id).filter { !parts.contains($0) }
    }

    /// Whether Undo split is offered: the aim was divided (cut, pattern, detached pieces).
    public static func canUndoSplit(_ id: RegionID, regions: FaceRegionModel) -> Bool {
        !splitChildren(id, regions: regions).isEmpty
    }

    /// The region the aim was cut from, for "up" — nil at a root or under a union (a union's
    /// parts step up to the union by being tapped).
    public static func parent(of id: RegionID, regions: FaceRegionModel) -> RegionID? {
        guard let r = regions.region(id), r.parentID >= 0, let p = regions.region(r.parentID),
              !p.parts.contains(id) else { return nil }
        return p.id
    }

    /// Why faces cannot be added to or dropped from the aim, or nil when they can: only a WHOLE
    /// face region — not a union (its parts are its faces), not a cut piece (its faces are its
    /// parent face's), not a region a split has divided (its pieces hold the faces now).
    public static func editRefusal(_ id: RegionID, regions: FaceRegionModel) -> String? {
        guard let r = regions.region(id) else { return "That region no longer exists." }
        if r.isUnionOfParts { return "A union is its parts — dissolve it to change them." }
        if r.isCut { return "A cut piece keeps its face — undo the split to change it." }
        if canUndoSplit(id, regions: regions) { return "Its pieces hold the faces now — undo the split first." }
        return nil
    }

    /// The tap's edit: a face the region holds is dropped (never its last), any other is added.
    public static func tapEdit(aim id: RegionID, face: FaceID, regions: FaceRegionModel,
                               mesh: ViewerMesh) -> TapEdit {
        if let why = editRefusal(id, regions: regions) { return .refused(why) }
        guard let r = regions.region(id) else { return .refused("That region no longer exists.") }
        let members = FaceRegionGeometry.members(of: r, in: mesh)
        guard members.contains(face) else { return .add(face) }
        if members.count <= 1 { return .refused("A region keeps one face — dissolve it instead.") }
        return .drop(face)
    }

    /// The aim in one line: its name and what it holds.
    public static func label(_ id: RegionID, regions: FaceRegionModel, resolvedFaces: Int) -> String {
        guard let r = regions.region(id) else { return "" }
        let n = splitChildren(id, regions: regions).count
        let holds = n > 0 ? "\(n) piece\(n == 1 ? "" : "s")" : "\(resolvedFaces) face\(resolvedFaces == 1 ? "" : "s")"
        return "\(r.name) · \(holds)"
    }
}
