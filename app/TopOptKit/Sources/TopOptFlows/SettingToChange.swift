// SettingToChange — ★ notes25 (his 11-23 ~18:55 on the print file's failure pop-up): "Change settings" must "lead to the
// settings page, scrolling to and highlighting the field to change along with what to try". The ask is one value — the page,
// the field's key, the words to try — set by the workspace's ONE function (`openSettingToChange`); the page marks the field
// with a clear accent outline and the words under it, and says them at the page's top (where Auto hides the field). Builder B
// builds the same for the fix wizard's "Solve" this round: 362 merges the two onto one implementation (this outline is a
// stand-in, not a second style to keep).
import SwiftUI
import TopOptDesign

@MainActor
public final class SettingToChange: ObservableObject {
    public static let shared = SettingToChange()

    public struct Ask: Equatable, Sendable {
        public enum Page: Equatable, Sendable { case lattice, topologySettings, selections }
        public var page: Page
        /// The field's key (the Lattice page's `LatticeWizardSetting` raw value, a Settings row's `TopologySetupRow`).
        public var field: String
        /// What to try, five words at most.
        public var tryText: String
        public init(page: Page, field: String, tryText: String) { self.page = page; self.field = field; self.tryText = tryText }
    }

    @Published public var ask: Ask?
    public init() {}
}

/// The field asked for, marked: an accent outline round it and what to try under it.
struct SettingToChangeMark: ViewModifier {
    @ObservedObject var asks = SettingToChange.shared
    let field: String

    func body(content: Content) -> some View {
        let on = asks.ask?.field == field
        VStack(alignment: .leading, spacing: 4) {
            content
            if on, let t = asks.ask?.tryText {
                Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .accessibilityIdentifier("setting-to-change-try")
            }
        }
        .padding(on ? 6 : 0)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(on ? DS.Color.accent.color : Color.clear, lineWidth: 2))
        .background(on ? CornerPairStyle.publish("settingToChange-" + field) : nil)
    }
}

/// At the page's top while a field is asked for on it: its name and what to try, outlined the same way (Auto hides some
/// fields; the words are always there).
struct SettingToChangeNote: View {
    @ObservedObject var asks = SettingToChange.shared
    let page: SettingToChange.Ask.Page
    let name: (String) -> String

    var body: some View {
        if let a = asks.ask, a.page == page {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(DS.Color.accent.color)
                Text("\(name(a.field)): \(a.tryText)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(DS.Space.s)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Color.accent.color, lineWidth: 2))
            .background(CornerPairStyle.publish("settingToChangeNote"))
            .accessibilityIdentifier("setting-to-change-note")
        }
    }
}

extension View {
    /// ★ notes25: this field is the one "Change settings" asks for (SettingToChange).
    func settingToChange(_ field: String) -> some View { modifier(SettingToChangeMark(field: field)) }
}
