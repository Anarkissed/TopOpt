// FlexibleOnModelLayer — STUB (round 7, batch R7-D2: tests first).
import SwiftUI
import simd
import TopOptDesign

public struct FlexibleOnModelLayer: View {
    public init(main: FlexibleMainStage, project: ProjectModel, projection: CameraProjection?, settle: simd_quatf,
                bottomClearance: CGFloat, cards: [String: LatticeFaceCard], groupCards: [UUID: LatticeFaceCard],
                cardsChanged: @escaping () -> Void) {}
    public var body: some View { Color.black.opacity(0.001) }
}
