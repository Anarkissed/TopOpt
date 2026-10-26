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
    public struct PieceRef: Equatable, Sendable {
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

    /// A tap clears the selection only when it lands on EMPTY space: no face of the model, no handle, no chip, and it was a
    /// tap, not an orbit drag.
    public static func tapClearsSelection(hitModel: Bool, hitControl: Bool, wasDrag: Bool) -> Bool {
        !hitModel && !hitControl && !wasDrag
    }
}


/// ★ his iPad 10-26 (3): a piece row inside an expanded group is a selectable row: tap to pick it (only its arrows show),
/// tap again to go back to the whole group. The picked row carries the accent outline.
struct PieceRowPick: ViewModifier {
    let picked: Bool
    let id: String
    let action: () -> Void
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: DS.Radius.field)
                .fill(picked ? DS.Color.accent.opacity(0.14).color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field)
                .strokeBorder(picked ? DS.Color.accent.color : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier(id)
    }
}
