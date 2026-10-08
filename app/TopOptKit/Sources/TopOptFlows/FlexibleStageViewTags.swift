// FlexibleStageViewTags — round 6: the Prisms view's mm tags and the Groups view's number discs, placed on
// screen (task 2026-09-29-flexible-screens, round 6). TESTS-FIRST STUB.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

enum FlexibleStageViewTags {

    /// One read-only "%.1f mm" tag at a prism's floor.
    struct Tag: Equatable {
        let region: Int
        let text: String
        let point: CGPoint
    }

    /// The Prisms view's tags on screen.
    @MainActor
    static func tags(model: FlexibleStageModel, k: Double, projection: CameraProjection?, keepOut: [CGRect]) -> [Tag] { [] }

    /// A tag's frame on screen (its hit area).
    static func frame(_ t: Tag) -> CGRect { .zero }

    /// A tag's tap: that face is selected (its draggable chip replaces the tag).
    @MainActor
    static func tap(_ t: Tag, model: FlexibleStageModel) {}
}
