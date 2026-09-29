// FlexiblePageChannels — what the Flexible Settings page hands MetalMeshView: the overlay
// mesh (the part with every loaded face's column quads) and its per-vertex channels
// (task 2026-09-29-flexible-screens, round 3).
//
// ★ ONE PLACE, CALLED BY THE PAGE. These were private methods of FlexibleStagePage; they
// live here so a test can build EXACTLY the page's overlay on his restored project (memory:
// "value-type tests miss call sites" — FlexibleOverlayClipTests pins the page's call).

import Foundation
import simd
import TopOptKit

@MainActor
public enum FlexiblePageChannels {

    /// The overlay the page draws: every loaded face that has a stack and geometry, on the
    /// part CUT along every declared sector's planes — so each kept piece is on one side of
    /// every cut, and a sector's tint (and its map) stops exactly at the cut (round 3, item
    /// 2). nil only when there is neither a map nor a sector (the page then tints the part's
    /// own triangles, which no cut crosses).
    public static func overlay(model: FlexibleStageModel) -> FlexibleOverlayMesh? {
        guard let part = model.project.viewerMesh else { return nil }
        let regions = model.regions
        let faces: [FlexibleOverlayFace] = model.loadedKeys.compactMap { k in
            guard let st = model.stacks[k], let g = model.geometry[k] else { return nil }
            return FlexibleOverlayFace(key: k, faces: Set(regions.faces(of: k.region, mesh: part)),
                                       cuts: regions.cuts(of: k.region), stack: st, centres: g.centres)
        }
        let planes = FlexibleFacePieces.planes(of: regions, mesh: part)
        guard !faces.isEmpty || !planes.isEmpty else { return nil }
        return FlexibleOverlayMesh.build(part: part, faces: faces, splitPlanes: planes)
    }
}
