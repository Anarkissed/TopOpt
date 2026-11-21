// ★★ RULING 4 (item 6, maintainer 2026-09-30): "wherever 'nothing set to lattice' shows, add one
// tap that takes him to where walls are marked. Navigation only; never create a wall for him."
//
// The words stay the words (`LatticeJobIncludeGate.nothingSetToLattice`); the line gains a
// chevron so it reads as going somewhere, and the control that carries it stays greyed — the
// refusal is unchanged, only the tap is new. Where the tap goes is the workspace's
// `goToWallMarking`: the Lattice stage with its Selections open.

import SwiftUI
import TopOptDesign

/// A refusal line that, when `marks`, ends in a chevron: its tap goes to where walls are marked.
/// Colours and line limits come from the caller, and the font too unless a DS text style is
/// given, so the line looks as it did.
struct WallMarkingSubline: View {
    let text: String
    let marks: Bool
    var style: DS.TextStyle? = nil
    /// The VoiceOver hint of a control whose tap goes to the walls.
    static let hint = "Shows where walls are marked"

    private var line: Text { style.map { Text(text).dsStyle($0) } ?? Text(text) }

    var body: some View {
        if marks {
            HStack(spacing: DS.Space.xxs) {
                line
                // the caller's font, unless a DS style is given (`.font(nil)` would reset it)
                if let style {
                    Image(systemName: "chevron.right").imageScale(.small).font(style.font)
                } else {
                    Image(systemName: "chevron.right").imageScale(.small)
                }
            }
            .accessibilityIdentifier("wall-marking-chevron")
        } else {
            line
        }
    }
}

/// The workspace bottom bar's action capsule — "Lattice" and "Optimize" wear the same one (they
/// differ only in horizontal padding). One view, so the evidence renders the app's own label.
struct StageActionCapsuleLabel: View {
    let title: String
    let summary: String
    let ok: Bool
    /// ★ ruling 4 (item 6): greyed, and the tap goes to where walls are marked
    let marks: Bool
    let horizontalPadding: CGFloat

    var body: some View {
        VStack(spacing: 1) {
            Text(title).dsStyle(DS.TypeScale.bodyStrong).fontWeight(.semibold)
            WallMarkingSubline(text: summary, marks: marks)
                .font(.system(size: 10.5, weight: .semibold))
                .opacity(0.75)
        }
        .foregroundStyle((ok ? DS.Color.textPrimary : DS.Color.textDisabled).color)
        .padding(.vertical, 11).padding(.horizontal, horizontalPadding)
        .background(Capsule().fill(ok ? DS.Color.accent.color : DS.Color.fillDisabled.color)
            .overlay(Capsule().strokeBorder(ok ? .clear : DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(ok ? DS.Shadow.accentGlow : DS.Shadow.panel)
    }
}
