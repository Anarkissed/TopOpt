// AppInfo — ★ the ONE (i), app-wide (his iPad notes on release 20, 2026-11-25):
//   "The icon should look the same across the ENTIRE app."
//   "In the regular lattices, the (i) notifications look like the error notification … HOWEVER under 'Organic' and only in the
//    groups' page, they open a notification, front and centre. We need to unify this look — please follow the front-and-centre
//    notification version across the ENTIRE APP. … instead of an 'OK' add a big bold line that says 'Tap anywhere to
//    continue', allowing any tap anywhere on the screen to close out that notification."
//
// Every (i) in the app is drawn by `AppInfoGlyph` and tapped through `AppInfoButton`: one glyph, one size, one colour, one
// 44 pt target, and one answer — the centred notification (`AppPopups.help`, drawn by `AppPopupLayer`). The older helpers
// (`InfoTip`, `FlexInfoButton`, `OrganicInfoButton`, `ResultsDetailInfo`, …) keep their names for their callers and are each
// a thin wrapper round this one (AppInfoUnifiedTests walks the sources to hold it). Error pop-ups keep their own buttons.
import SwiftUI
import TopOptDesign

/// The drawn (i): the one glyph, size and colour. `lit` (an (i) whose card is open beside it) takes the accent.
struct AppInfoGlyph: View {
    var lit = false
    /// The glyph's point size, everywhere.
    static let pointSize: CGFloat = 15
    static let symbol = "info.circle"
    static let litSymbol = "info.circle.fill"
    static var colour: RGBA { DS.Color.textTertiary }

    var body: some View {
        Image(systemName: lit ? Self.litSymbol : Self.symbol)
            .font(.system(size: Self.pointSize, weight: .regular))
            .foregroundStyle((lit ? DS.Color.accent : Self.colour).color)
            .accessibilityHidden(true)
    }
}

/// The one (i) button: the glyph in a 44 pt target; its tap opens the setting's explanation in the centred notification.
/// `tap` replaces the notification only where the (i) opens a live card of numbers (the Flexible face's numbers).
struct AppInfoButton: View {
    let title: String
    let text: String
    /// VoiceOver's words (default "About <title>").
    var label: String? = nil
    /// The accessibility identifier, where a caller's tests read one.
    var id: String? = nil
    /// An action the notification offers beside its words (e.g. "Mark as tested").
    var action: (title: String, run: () -> Void)? = nil
    /// More content under the words (built at the tap: a Flexible row's core detail).
    var extra: (() -> AnyView)? = nil
    var lit = false
    var tap: (() -> Void)? = nil

    /// The hit target (pt): his 44.
    static let target: CGFloat = 44

    var body: some View {
        Button {
            if let tap { tap() } else { AppPopups.shared.help(title, text, action: action, extra: extra?()) }
        } label: {
            AppInfoGlyph(lit: lit)
                .frame(width: Self.target, height: Self.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? "About \(title)")
        .modifier(AppInfoID(id: id))
    }
}

private struct AppInfoID: ViewModifier {
    let id: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

/// The slot the notification keeps for an action it offers (its button is laid over the card there, above the card's own tap).
struct AppInfoActionSlot: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// ★ notes29: the notification's own measures — wide enough that the words never scroll, narrower for a short sentence.
enum AppInfoCard {
    /// His words for the close line (no OK button on an (i)).
    static let tapAnywhere = "Tap anywhere to continue"
    /// The narrowest and widest card (pt), and the margin it keeps from the screen's edges.
    static let minWidth: CGFloat = 340
    static let maxWidth: CGFloat = 680
    static let margin: CGFloat = 24

    /// The card's width for these words in a room this wide: about 70 characters a line for a long text, so it grows wider
    /// before it grows tall; a short one stays narrow.
    static func width(for text: String, title: String = "", room: CGFloat) -> CGFloat {
        let n = CGFloat(max(text.count, title.count * 2))
        let want: CGFloat
        switch n {
        case ..<90: want = minWidth
        case ..<240: want = 440
        case ..<520: want = 540
        default: want = maxWidth
        }
        let roomLeft = max(minWidth, room - 2 * margin)
        return min(want, roomLeft)
    }
}
