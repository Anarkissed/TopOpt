import Foundation
import SwiftUI
import TopOptDesign

/// ★ WHAT THE 3D VIEW SHOWS FOR THE SELECTION (his iPad, 2026-10-26, Topology > Setup on "CarriageArms repaired2 copy 5").
///
/// 2) "I have nothing selected but ALL the arrows are visible … Make it so if there is nothing selected, the arrows
///    disappear." Nothing selected ⇒ no load, anchor or clearance arrows and no mm value chips; a selected group shows only
///    its own.
/// 3) "I can drill into the group to look at the individual primitives/pieces, but I can't actually select them." A
///    selected PIECE (a clearance primitive row inside the expanded group) shows ONLY that piece's arrows.
/// 4) "I CANNOT get rid of the '51 kg gravity/push/pull' chip." The load chip shows only while its group is selected.
/// 5) "If I tap into nothing: deselect whatever was selected … APP WIDE." A tap on empty space clears the selection; a tap
///    on the model, a handle or a chip never does, and an orbit drag never does.
public enum SelectionArrowRule {

    /// A picked piece: its group and its key (a face id, or a manual primitive's sentinel key).
    public struct PieceRef: Hashable, Sendable {
        public let group: UUID
        public let key: Int
        public init(group: UUID, key: Int) { self.group = group; self.key = key }
    }

    /// A group's arrows and chips (load arrow, weight chip, clearance arrows and their mm chips) show only while it is the
    /// selected group.
    public static func groupShows(_ group: UUID, selectedGroup: UUID?) -> Bool {
        selectedGroup == group
    }

    /// One piece's clearance arrows (and mm chip): its group must be selected, and when a piece is selected, only that piece.
    public static func pieceShows(group: UUID, piece: Int, selectedGroup: UUID?, selectedPiece: Int?) -> Bool {
        guard groupShows(group, selectedGroup: selectedGroup) else { return false }
        return selectedPiece == nil || selectedPiece == piece
    }

    /// ★ his ask 2026-10-26: a piece inside a group (a face, a keep-out cylinder or slab) can be hidden on its own. View
    /// only, like the group's eye: the piece still counts in the run.
    public static func pieceDrawn(group: UUID, piece: Int, hidden: Set<PieceRef>) -> Bool {
        !hidden.contains(PieceRef(group: group, key: piece))
    }

    /// The keep-out volumes as drawn: a hidden piece or a group outside the open scenario draws none; a switched-off
    /// anchor's are FAINT (his iPad 14:13). `pieces` is index-aligned with `items` (the same resolve, the same order).
    public static func keepOuts(_ items: [ClearanceRenderItem], pieces: [(groupID: UUID, piece: Int)],
                                hidden: Set<PieceRef>, draw: (UUID) -> ScenarioDraw) -> [ClearanceRenderItem] {
        guard pieces.count == items.count else { return items }
        return zip(items, pieces).compactMap { item, p in
            guard pieceDrawn(group: p.groupID, piece: p.piece, hidden: hidden) else { return nil }
            switch draw(p.groupID) {
            case .hidden: return nil
            case .shown: return item
            case .dimmed: return ClearanceRenderItem(volume: item.volume, selected: false, tint: item.tint,
                                                     faceAlpha: faintFaceAlpha, edgeAlpha: faintEdgeAlpha)
            }
        }
    }
    public static let faintFaceAlpha: Float = 0.08
    public static let faintEdgeAlpha: Float = 0.16

    /// A tap clears the selection only when it lands on EMPTY space: no face of the model, no handle, no chip, and it was a
    /// tap, not an orbit drag.
    public static func tapClearsSelection(hitModel: Bool, hitControl: Bool, wasDrag: Bool) -> Bool {
        !hitModel && !hitControl && !wasDrag
    }
}


/// ★ his iPad 10-26 (3) + 14:13 ("separated out into rows so that there are clear separators and it is obviously
/// selectable … make it look like it makes sense"): each piece inside an open group is its own CARD — a rounded tile on
/// the panel, a hair outline, 8 pt between tiles — tap it to pick it (only its arrows show), tap again for the whole group.
/// The picked card fills with the accent and takes the accent outline.
/// ★ his iPad 14:13 ("make sure the primitives are also indented in the groups"): a group's pieces sit tabbed in from its
/// line, a guide line down their edge — the same look as a scenario's groups under its folder.
extension Array where Element == ClearanceRenderItem {
    /// `SelectionArrowRule.keepOuts` as a step on the drawn list; nil pieces: nothing filters (no scenarios, nothing hidden).
    func keepOutsDrawn(_ pieces: [(groupID: UUID, piece: Int)]?, hidden: Set<SelectionArrowRule.PieceRef>,
                       draw: (UUID) -> ScenarioDraw) -> [ClearanceRenderItem] {
        guard let pieces else { return self }
        return SelectionArrowRule.keepOuts(self, pieces: pieces, hidden: hidden, draw: draw)
    }
}

struct PieceIndent: ViewModifier {
    static let indent: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(.leading, Self.indent)
            .overlay(alignment: .leading) {
                Rectangle().fill(DS.Color.strokeSubtle.color).frame(width: 1).padding(.leading, Self.indent / 2).padding(.vertical, 4)
            }
    }
}

struct PieceRowPick: ViewModifier {
    let picked: Bool
    let id: String
    let action: () -> Void
    static let spacing: CGFloat = 8
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                .fill(picked ? DS.Color.accent.opacity(0.16).color : DS.Color.fillSubtle.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                .strokeBorder(picked ? DS.Color.accent.color : DS.Color.strokeSubtle.color, lineWidth: picked ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ChromeKeepOutKey.self, value: ["piecePick-\(id)": geo.frame(in: .global)])
            }.allowsHitTesting(false))
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(id)
    }
}
