// FlexibleStageVolumes — the ONE clearance list each Flexible page hands MetalMeshView (task
// 2026-09-29-flexible-screens, round 6, items 1 and 3).
//
// ★ THE SETTINGS PAGE: the prisms (FlexibleDepthPrism.renderItems — the selected pressed face's, faint at
// rest, the contact look while its chip is dragged; every pressed face's in the Prisms view) and the
// glass (FlexibleGroupWalls — the open group's; every group's in the Groups view). ★ THE MAIN PAGE
// (FlexibleMainStage.volumes, hook H15): the prisms only — the main page wears no group colour.
// Cached per model state: the page's body runs on every model change and every camera move.

import Foundation
import TopOptKit

@MainActor
enum FlexibleStageVolumes {

    private static var cache: (key: String, items: [ClearanceRenderItem])?

    /// The Settings page's clearance volumes: the prisms, then the glass. `k`: the page's exaggeration
    /// (1 while nothing is dented — the prism is then drawn at its true depth).
    static func items(model: FlexibleStageModel, k: Double, part: ViewerMesh?) -> [ClearanceRenderItem] {
        let k = k > 0 ? k : 1
        let key = "\(k)|\(model.frozenExaggeration ?? -1)|\(model.views.rawValue)|\(model.selectedRegion ?? -1)|\(model.rail)|"
            + "\(model.settings.hashValue)|\(model.stacks.count)|\(model.geometry.count)|\(model.stampGrids.count)|"
            + "\(part?.signature.contentHash ?? 0)|\(model.regions.key)"
        if let c = cache, c.key == key { return c.items }
        let items = FlexibleDepthPrism.renderItems(model: model, k: k, views: model.views)
            + FlexibleGroupWalls.items(model: model, views: model.views, mesh: part)
        cache = (key, items)
        return items
    }
}
