// FlexibleStageVolumes — the ONE clearance list each Flexible page hands MetalMeshView (task
// 2026-09-29-flexible-screens, round 6, items 1 and 3).
//
// ★ THE SETTINGS PAGE: the prisms (FlexibleDepthPrism.renderItems — the selected pressed face's, faint at
// rest, the contact look while its chip is dragged; every pressed face's in the Prisms view) and the
// glass (FlexibleGroupWalls — the open group's; every group's in the Groups view). ★ THE MAIN PAGE
// (FlexibleMainStage.volumes, hook H15): the prisms only — the main page wears no group colour.
// Cached per model state: the page's body runs on every model change and every camera move.

import Foundation
import simd
import TopOptKit

@MainActor
enum FlexibleStageVolumes {

    private static var cache: (key: String, items: [ClearanceRenderItem])?

    /// ★ R6 REVIEW: the ONE k every prism-drawn thing on the page uses — the prisms, the depth chip, the stamp's
    /// handle, the tags and the legend's ×k: the dent's exaggeration, or 1 while nothing is dented (the verifier: the
    /// page's k is 0 then; the prism drew at 1 and the chip at 0 — on the face, deepest × 1 off its prism's floor).
    nonisolated static func prismK(_ dentExaggeration: Double) -> Double { dentExaggeration > 0 ? dentExaggeration : 1 }

    /// The Settings page's clearance volumes: the prisms, then the glass. `k`: the page's exaggeration
    /// (`prismK`: 1 while nothing is dented — the prism is then drawn at its true depth). `heat`: each pressed
    /// region's colours on the page (FlexibleGroupWalls.heatSamples — the glass's alpha is its colour's over them).
    /// ★ R7-V (his img3: the Heat view "adds a layer of a heat map? … Remove that"): `heated` — the regions whose heat the
    /// page shows wear NO glass (glass only where the heat is hidden), so the glass never lays a second colour on the heat.
    static func items(model: FlexibleStageModel, k: Double, part: ViewerMesh?,
                      heat: [Int: [SIMD3<Float>]] = [:], heated: Set<Int> = []) -> [ClearanceRenderItem] {
        // ★ R7-V: Bend ALONE shows the bent model only — no prism or glass standing at the rest pose beside it
        if FlexibleStagePage.overlaysHidden(views: model.views, edgePick: model.edgePick != nil) { return [] }
        let k = prismK(k)
        let key = "\(k)|\(model.frozenExaggeration ?? -1)|\(model.views.rawValue)|\(model.selectedRegion ?? -1)|\(model.rail)|"
            + "\(model.settings.hashValue)|\(model.stacks.count)|\(model.geometry.count)|\(model.stampGrids.count)|"
            + "\(part?.signature.contentHash ?? 0)|\(model.regions.key)|" + FlexibleGroupWalls.signature(heat) + "|\(heated.sorted())"
        if let c = cache, c.key == key { return c.items }
        let items = FlexibleDepthPrism.renderItems(model: model, k: k, views: model.views)
            + FlexibleGroupWalls.items(model: model, views: model.views, mesh: part, heat: heat)
                .filter { !($0.surfaceOnly && heated.contains($0.volume.faceID)) }
        cache = (key, items)
        return items
    }
}
