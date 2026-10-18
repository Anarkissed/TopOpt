// FlexibleFaceStatsPopover — the (i) beside each face on the main Flexible page (task 2026-09-29-flexible-screens, round 7,
// batch R7-D2; his change (b) to B1, 2026-10-14: "I want an (i) next to each face that will show the details of the
// lattice that was in the previous design", and his correction the same day: "The per-face (i) shows ONLY: Cell, Density,
// Strut, Cells across. (Not Hands over, As lattice or Saved.)"; the reviewer's (e): the caption "The current preview's
// numbers at this depth." yes).
//
// ★ THE NUMBERS ARE #354's. Built with #354's PUBLIC `LatticeRegionDrawer.make(card:depthMM:held:latticeReachesTheRun:)`
// from the card WorkspacePlaceholder already computes for that face (`latticeSelectableCards[ref.key]`, else the group's
// `latticeFaceCards[group]`, handed in by H25 / H32), at the depth the face's box shows (`latticeSlabDepthMM(ref, in:)`):
// exactly the old drawer's rows, filtered to his four, with the drawer's own "(estimate)" note when Cells across is the
// bake's estimate. It holds FACTS, never a setting. No card yet → "No numbers yet for this face". An Off face has no (i).
// No grams anywhere (his answer: hidden until core reports the real per-face lattice weight).

import SwiftUI
import TopOptDesign

public enum FlexibleFaceStats {
    /// His four, in the drawer's order.
    public static let labels = ["Cell", "Density", "Strut", "Cells across"]

    public struct Rows: Equatable, Sendable {
        public let rows: [LatticeDrawerRow]
        /// The drawer's estimate note under Cells across ("estimate, core checks it"), when it is the bake's estimate.
        public let note: String?
    }

    /// The (i)'s rows for one face — #354's drawer for that card at that depth, his four rows only; nil without a card.
    public static func rows(card: LatticeFaceCard?, depthMM: Double, held: Bool, reaches: Bool = true) -> Rows? {
        guard let card else { return nil }
        let d = LatticeRegionDrawer.make(card: card, depthMM: depthMM, held: held, latticeReachesTheRun: reaches)
        let mine = labels.compactMap { l in d.rows.first { $0.label == l } }
        guard !mine.isEmpty else { return nil }
        return Rows(rows: mine, note: mine.first { $0.label == "Cells across" }?.note)
    }

    /// The card for a face: its own (per selectable), else its group's.
    public static func card(_ ref: LatticeSelectableRef, group: UUID, cards: [String: LatticeFaceCard],
                            groupCards: [UUID: LatticeFaceCard]) -> LatticeFaceCard? {
        cards[ref.key] ?? groupCards[group]
    }
}

/// The (i)'s card: the face's name, his four rows, the note, the one caption — drawn by the on-model layer beside the (i)
/// it opened from (the list's or the chip's).
struct FlexibleFaceStatsCard: View {
    let title: String
    let rows: FlexibleFaceStats.Rows?
    let close: () -> Void
    static let width: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FlexibleStageStyle.facePrismToken.color)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.textSecondary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -10).padding(.trailing, -10)
                .accessibilityLabel("Close the numbers")
                .accessibilityIdentifier("flexible-face-info-close")
            }
            if let rows {
                VStack(spacing: 6) {
                    ForEach(rows.rows, id: \.label) { r in
                        HStack {
                            Text(r.label).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                            Spacer(minLength: DS.Space.s)
                            Text(r.value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("flexible-face-info-row-\(r.label)")
                    }
                }
                if let n = rows.note {
                    Text(n).font(.system(size: 11.5)).foregroundStyle(DS.Color.textTertiary.color).lineLimit(1)
                }
                Text(FlexibleSelectionsCopy.statsCaption)
                    .font(.system(size: 11.5)).foregroundStyle(DS.Color.textTertiary.color)
                    .lineLimit(1).minimumScaleFactor(0.9)
                    .accessibilityIdentifier("flexible-face-info-caption")
            } else {
                Text(FlexibleSelectionsCopy.noNumbers)
                    .font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .accessibilityIdentifier("flexible-face-info-none")
            }
        }
        .padding(DS.Space.m)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Color.chipSolid.color.opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-face-info-card")
    }
}
