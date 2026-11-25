// SettingToChange — ★ notes25 (his 11-23 ~18:55 on the print file's failure pop-up): "Change settings" must "lead to the
// settings page, scrolling to and highlighting the field to change along with what to try". The ask is one value — the page,
// the field's key, the words to try — set by the workspace's ONE function (`openSettingToChange`); the page marks the field
// with a clear accent outline and the words under it, and says them at the page's top (where Auto hides the field).
// ★ notes25 B6 (merged): the fix wizard's "Solve" goes the same ONE way (his "Solve should send the user exactly to the right
// page to fix it, and highlight the field to fix, making sure to scroll to a position so that the field is close to the
// middle"). So, for both buttons: the Lattice page opens Manual when the field lives only there (a view pick, never a setting),
// opens the field's group tab (Organic's settings are per group), scrolls the field to the middle of its rows (as far as they
// scroll), and the field is lit — the accent outline with a tint, brightest for a few seconds, then the plain outline while
// the ask stands.
import SwiftUI
import TopOptDesign

@MainActor
public final class SettingToChange: ObservableObject {
    public static let shared = SettingToChange()

    public struct Ask: Equatable, Sendable {
        public enum Page: Equatable, Sendable { case lattice, topologySettings, selections }
        public var page: Page
        /// The field's key (the Lattice page's `LatticeWizardSetting` raw value, a Settings row's `TopologySetupRow`, or an
        /// Organic setting's own name: `organicFields`).
        public var field: String
        /// What to try, five words at most.
        public var tryText: String
        /// ★ notes25 B6: the lattice group whose tab holds the field (nil: the Part tab, or a page with no tabs).
        public var group: UUID?
        public init(page: Page, field: String, tryText: String, group: UUID? = nil) {
            self.page = page; self.field = field; self.tryText = tryText; self.group = group
        }
    }

    @Published public var ask: Ask? {
        didSet {
            if ask != nil { serial += 1; lit = true } else { lit = false }
        }
    }
    /// ★ B6: bumped on every ask (the page brings the field into view each time — the same ask again too).
    @Published public private(set) var serial = 0
    /// ★ B6: the field at its brightest (the outline and a tint) until the page has shown it a few seconds.
    @Published public private(set) var lit = false
    public init() {}

    nonisolated static let holdSeconds = 3.0, fadeSeconds = 1.0
    /// The Organic settings Solve can ask for (LatticeOrganicControls' rows, by their names).
    nonisolated public static let organicFields: Set<String> = ["Strut thickness", "Cell size"]
    /// The field's row on its page (its scroll target).
    nonisolated static func rowID(_ field: String) -> String { "setting-to-change-row-" + field }
    /// The Lattice page's fields drawn only in Manual: the page opens Manual for them.
    nonisolated static func needsManual(_ field: String) -> Bool {
        organicFields.contains(field)
            || [LatticeWizardSetting.cellSize, .density, .thickness].map(\.rawValue).contains(field)
    }

    /// The page has brought the field into view: it stays at its brightest a few seconds, then eases to the plain outline.
    func shown(_ serial: Int) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.holdSeconds * 1_000_000_000))
            guard let self, self.serial == serial, self.ask != nil else { return }
            withAnimation(.easeOut(duration: Self.fadeSeconds)) { self.lit = false }
        }
    }
}

/// The field asked for, marked: an accent outline round it (with a tint while lit) and what to try under it. `also`: other
/// keys that mean this field (the Organic Cell size answers the lattice's `cellSize` too). Its row is the page's scroll target.
struct SettingToChangeMark: ViewModifier {
    @ObservedObject var asks = SettingToChange.shared
    let field: String
    var also: [String] = []

    func body(content: Content) -> some View {
        let asked = asks.ask?.field
        let on = asked == field || (asked.map { also.contains($0) } ?? false)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            content
            if on, let t = asks.ask?.tryText {
                Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("setting-to-change-try")
            }
        }
        .padding(on ? 6 : 0)
        .background(shape.fill(on && asks.lit ? DS.Color.accent.opacity(0.12).color : Color.clear).allowsHitTesting(false))
        .overlay(shape.strokeBorder(on ? DS.Color.accent.color : Color.clear, lineWidth: on && asks.lit ? 2.5 : 2)
            .allowsHitTesting(false))
        .background(on ? CornerPairStyle.publish("settingToChange-" + (asked ?? field)) : nil)
        .id(SettingToChange.rowID(field))
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
    /// ★ notes25: this field is the one "Change settings" (or the fix wizard's Solve) asks for (SettingToChange).
    func settingToChange(_ field: String, also: [String] = []) -> some View { modifier(SettingToChangeMark(field: field, also: also)) }
}
