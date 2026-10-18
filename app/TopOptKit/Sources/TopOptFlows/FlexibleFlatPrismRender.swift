// FlexibleFlatPrismRender — R7-E1 STUB (the tests' red run): the wedge and the on-model handles. Signatures only.
import CoreGraphics
import Foundation
import simd
import TopOptKit

@MainActor
enum FlexibleFlatPrismRender {
    static var controlTimesK = false
    static func items(model: FlexibleStageModel, k: Double) -> [ClearanceRenderItem] { [] }
}

@MainActor
enum FlexibleFlatPrismUI {
    struct Shown: Equatable { let depthMM: Double; let chipText: String; let tilt: Double; let twist: Double }
    static func shown(model: FlexibleStageModel, press: UUID) -> Shown? { nil }
    static var lastArrowEnds: (head: CGPoint, tail: CGPoint)?
    static var lastPad: String?
    static func camera(press: FlexiblePress, settle: simd_quatf) -> GizmoRegion? { nil }
}
