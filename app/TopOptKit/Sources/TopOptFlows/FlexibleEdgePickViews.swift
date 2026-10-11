// FlexibleEdgePickViews — round 6 item 2 on the Settings page (task 2026-10-08): [+ New] asks [Faces] [Edges/corners]
// on one line; Edges/corners turns the tab into the PICK CARD (the list: one numbered row per edge and corner, its dot
// in its colour on the model; the group's one squeeze force; the "keeps the rest" lines; [Done · N picked] [Cancel]);
// an edges/corners group's tab lists its presses with their "Strip width" boxes; and on the model the candidates are
// drawn — 6 pt strokes and 14 pt dots in their colours, a numbered tag on each (≥ 44 pt to hit), picked ones in the
// group's colour, thicker, with ✓; faint and untagged when they face away. One line per setting (≤ 44 characters).

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

extension FlexibleRowCopy.Info {
    public static let newKind = "Faces: a group of faces pressed straight in, as before. Edges/corners: pick where faces meet — each edge presses a strip along it on both its faces, each corner a square patch on every face there; the faces' own groups keep the rest. A group holds one or the other, never both."
    public static let edgePick = "Every edge and corner of the part, in colours that never repeat on touching ones, numbered as here. Tap a row or tap the part; tap the same spot again to reach the next one there. Grey rows can't be pressed — the line says why."
    public static let stripWidth = "How far the strip reaches from the edge into each face (a corner: the patch's side). It starts at the lattice depth under the faces, never more than half the face, so the face's own group keeps the rest. Changing it re-cuts this strip and any that meet it."
}

// MARK: - I2 RED STUBS (the views land with the rules)

struct FlexibleNewGroupKindLine: View {
    @ObservedObject var model: FlexibleStageModel
    var body: some View { EmptyView() }   // I2 RED STUB
}

struct FlexibleEdgePickCard: View {
    @ObservedObject var model: FlexibleStageModel
    @Binding var padTarget: String?
    var body: some View { EmptyView() }   // I2 RED STUB
}

struct FlexibleEdgeGroupRows: View {
    @ObservedObject var model: FlexibleStageModel
    let group: FlexibleSqueezeGroup
    @Binding var padTarget: String?
    var body: some View { EmptyView() }   // I2 RED STUB
}

struct FlexibleEdgePickOverlay: View {
    @ObservedObject var model: FlexibleStageModel
    @ObservedObject var proj: FlexibleProjectionBox
    var keepOut: [CGRect] = []
    var clip: [CGRect]? = nil

    struct Mark: Equatable {
        let number: Int
        let colour: RGBA
        let picked: Bool
        let greyed: Bool
        let front: Bool
        let projected: FlexibleEdgePickRules.Projected
        let text: String
        let target: CGRect?
    }

    @MainActor
    static func marks(model: FlexibleStageModel, projection: CameraProjection?, keepOut: [CGRect] = []) -> [Mark] { [] }   // I2 RED STUB

    var body: some View { EmptyView() }   // I2 RED STUB
}
