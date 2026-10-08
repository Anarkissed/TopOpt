// FlexibleGroupWalls — round 6, item 1 (task 2026-09-29-flexible-screens, round 6). TESTS-FIRST STUB:
// the walls are not built yet (FlexibleRound6Tests / FlexibleRound6HostedTests are red against it).

import Foundation
import simd
import TopOptDesign
import TopOptKit

enum FlexibleGroupWalls {

    /// How far the glass stands proud of its face (mm).
    static let epsMM = 0.3
    /// The glass's alphas: every shown group, and the OPEN group while the Groups view is on.
    static let faceAlpha: Float = 0.10
    static let edgeAlpha: Float = 0.45
    static let openFaceAlpha: Float = 0.16
    static let openEdgeAlpha: Float = 0.65
    /// The welding key (mm).
    static let weldMM = 1e-4
    /// The renderer's front face, seen from OUTSIDE the part (Metal's default winding, read in its y-up clip
    /// space): pinned on the GPU by FlexibleRound6Tests (R6-1d's reversed-winding control).
    static let frontIsCounterClockwiseFromOutside = false

    /// Test controls only: every group walled whatever is open; every group numbered once there are
    /// more groups than colours (the count rule, not the shared-colour rule).
    @MainActor static var controlEveryGroup = false
    @MainActor static var controlNumberByCount = false

    /// One walled group: its key ("group-N" / "rests"), its colour, its regions, and whether it is the open one.
    struct Shown: Equatable {
        let key: String
        let colour: RGBA
        let regions: [Int]
        let open: Bool
    }

    /// A number disc on a member's glass (the Groups view, a group whose colour another also wears).
    struct Disc: Equatable {
        let number: Int
        let colour: RGBA
        let region: Int
        let anchor: SIMD3<Float>
        let normal: SIMD3<Float>
    }

    static func shell(region: Int, regions: FlexibleRegions, mesh: ViewerMesh, epsMM: Double = epsMM,
                      ignoringCuts: Bool = false, welded: Bool = true) -> FaceOffsetShell? { nil }

    @MainActor static func shown(model: FlexibleStageModel, views: FlexibleStageViews) -> [Shown] { [] }

    @MainActor static func items(model: FlexibleStageModel, views: FlexibleStageViews, mesh: ViewerMesh?) -> [ClearanceRenderItem] { [] }

    @MainActor static func discs(model: FlexibleStageModel, views: FlexibleStageViews, mesh: ViewerMesh?) -> [Disc] { [] }
}
