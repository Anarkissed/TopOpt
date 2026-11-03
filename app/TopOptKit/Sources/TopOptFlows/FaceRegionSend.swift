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

    /// The one line on Optimize (or Lattice) when a role holds a piece with no faces.
    public static let refusalLine = "A cut piece has no faces left \u{00B7} redo it in Edit faces"
}
