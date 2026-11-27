// FaceRegionSend.swift — ★ B1 (ledger note 38, the app half; O1's cause), approved design 2026-11-02.
//
// His screenshot A7C1E0C9: "topopt-cli: job.json: face region 107 …". Core refuses a job whose face region "declares neither a
// filter nor any "add" faces — it would resolve to nothing and tag nothing" (job.cpp). Such a region is left behind by face
// edits, and by every UNION of pieces (it owns no faces; its `parts` are not a thing core knows). Such a region is never sent
// (`kept`); a role names a union by its pieces instead (`ProjectModel.runRegionIDs`). A child keeps its `parent_id` (core only
// reports the lineage). If a role is left naming only a piece with no faces, the run is refused on the button in one line:
// sending it would be refused, and dropping it would silently drop that role's faces.

import Foundation
import TopOptKit

public enum FaceRegionSend {

    /// The regions core would refuse: neither a filter nor any added face.
    public static func empty(_ regions: [FaceRegion]) -> Set<RegionID> {
        Set(regions.filter { $0.add.isEmpty && !$0.filter.any }.map(\.id))
    }

    /// The regions that go on the wire: every one but the empty ones.
    public static func kept(_ regions: [FaceRegion]) -> [FaceRegion] {
        let e = empty(regions)
        return e.isEmpty ? regions : regions.filter { !e.contains($0.id) }
    }

    /// The region ids a request NAMES for a role: anchors, loads (every scenario's too) and protections.
    public static func named(by r: RunRequest) -> Set<RegionID> {
        var ids = Set(r.anchorRegionIDs)
        ids.formUnion(r.faceProtectionRegionIDs)
        for g in r.loadGroups { ids.formUnion(g.regionIDs) }
        for s in r.scenarios { for g in s.loadGroups { ids.formUnion(g.regionIDs) } }
        return ids
    }

    /// ★ his 11-16 (jobs e84c7315, 79b695c5 and five before): the pieces a run SENDS are the ones it USES — an anchor, a load
    /// (any scenario's), a protection or a keep-clear names them. Core builds every declared region, so a leftover piece no
    /// group uses, under core's smallest-piece floor, refused his whole run ("region 101 "Face 25 A" holds 3 voxels at
    /// resolution 96 — under the floor of 16") although nothing in it needed that piece. Never an empty one either (`kept`).
    public static func onWire(_ r: RunRequest) -> [FaceRegion] {
        guard !controlSendEveryPiece else { return r.faceRegions }
        var used = named(by: r)
        for c in r.clearances where c.regionID >= 0 { used.insert(c.regionID) }
        return kept(withAncestors(used, in: r.faceRegions))
    }

    /// The lattice's quick stress solve: only the pieces its anchors and loads name, never an empty one.
    public static func used(_ regions: [FaceRegion], anchors: [RegionID], loads: [TopOptKit.LoadGroupSpec]) -> [FaceRegion] {
        guard !controlSendEveryPiece else { return regions }
        var used = Set(anchors)
        for g in loads { used.formUnion(g.regionIDs) }
        return kept(withAncestors(used, in: regions))
    }

    /// The used pieces and every piece they were cut from (Flexible's quick solve keeps a sector's ancestry the same way,
    /// `FlexibleStressContext.reached`). A parent holds at least what its piece holds, so it never trips core's floor where
    /// the piece does not; a union parent owns no faces and is dropped by `kept`. In the project's order.
    static func withAncestors(_ used: Set<RegionID>, in regions: [FaceRegion]) -> [FaceRegion] {
        let byID = Dictionary(regions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keep = Set<RegionID>()
        for id in used {
            var cur: RegionID? = id
            while let c = cur, let r = byID[c], keep.insert(c).inserted { cur = r.parentID >= 0 ? r.parentID : nil }
        }
        return regions.filter { keep.contains($0.id) }
    }

    /// RED CONTROL (tests only): every piece the project holds is sent, used or not (before his 11-16 jobs).
    nonisolated(unsafe) public static var controlSendEveryPiece = false

    /// The one line on Optimize (or Lattice) when a role holds a piece with no faces.
    public static let refusalLine = "A cut piece has no faces left \u{00B7} redo it in Edit faces"
}
