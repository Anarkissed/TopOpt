// CornerDrawers — his iPad notes 2026-11-22 (afternoon, img 45): the corner's two drawers, Settings and the ⌃.
//
// His words: "When the 'Settings' drawer is open, a tap to the background or opening up the ^ menu should automatically hide
// the Settings drawer. The same rule for the ^ menu. The menu colours are different - they should be the same colour as the ^
// menu colour. The ^ menu should start *above* the buttons like the Settings menu so it is not covering any buttons."
//
// So the ⌃ no longer opens the system's menu (the system placed it, and it covered the run button): it opens a drawer of its
// own, drawn where the Settings drawer is drawn — the corner pair's panel, its foot above the buttons (and above a fix line),
// right-aligned with the pair. The same items in the order he saw them (the system draws an upward menu with its first item
// nearest the button: so does the drawer), every row 44 pt or more. ONE drawer is open at a time (`CornerDrawers.open`):
// opening one closes the other; a tap on the 3D view (`closesCornerDrawers`) closes whichever is open, and a drag still turns
// the view (only the tap callbacks close it). Both drawers wear the ⌃ menu's colour, `DS.Surface.menu` (sampled from img 45).
//
// The state lives in a reference (the app model's, the results model's), never as a @State on the workspace
// (WorkspaceBodySizeTests); the workspace's `setupPanelOpen` reads and writes it.
import SwiftUI
import Combine
import TopOptDesign

/// Which corner drawer is open (none, the Settings drawer, or one ⌃ drawer by its key) and which ⌃ row's sub-list is open.
@MainActor
public final class CornerDrawers: ObservableObject {
    /// The Settings drawer's key (the corner pair's "setup" panel).
    public static let settings = "setup"
    /// The open drawer's key (nil: none). One at a time.
    @Published public private(set) var open: String?
    /// The ⌃ row whose sub-list is open ("Lattice an optimized result ›"); closed with its drawer.
    @Published public var expanded: String?
    /// Its changes, passed on to the model that holds it (the page observes that model).
    var relay: AnyCancellable?
    /// ★ his 11-22 (2): where a tap leaves the open drawer alone — the drawer itself and the corner's own chip and ⌃
    /// (global frames, from the page's published frames; CornerTapCloser). Not published: nothing redraws for it.
    var keepFrames: [CGRect] = []

    public init() {}

    public func isOpen(_ key: String) -> Bool { open == key }
    public var anyOpen: Bool { open != nil }

    /// Open `key` (closing any other) or close it.
    public func set(_ key: String, _ on: Bool) {
        let next: String? = on ? key : (open == key ? nil : open)
        guard next != open else { return }
        withAnimation(DS.Motion.emphasized) { open = next; expanded = nil }
    }
    public func toggle(_ key: String) { set(key, open != key) }
    /// A tap on the background: whichever is open closes.
    public func close() {
        guard open != nil else { return }
        withAnimation(DS.Motion.emphasized) { open = nil; expanded = nil }
    }
}

/// One row of a ⌃ drawer — the items the system menu held, as data the drawer draws.
public struct CornerMoreItem: Identifiable {
    public enum Kind {
        /// A run choice: a tap closes the drawer and runs it.
        case action(() -> Void)
        /// One of a set of choices, a check mark on the one in force ("Live preview" / "Click to refresh preview"); a tap
        /// picks it and closes the drawer (as the menu's picker did).
        case check(isOn: Bool, () -> Void)
        /// A switch ("Print-accurate preview"); a tap flips it and the drawer stays open to show it.
        case toggle(isOn: Bool, (Bool) -> Void)
        /// A sub-list ("Lattice an optimized result ›"), opened in place under its row.
        case list([CornerMoreItem])
        /// A thin line between groups of rows.
        case divider
    }
    /// The accessibility identifier and the frame key (the menu item's own id).
    public let id: String
    public let title: String
    /// The grey sub-line under the title (nil: none).
    public let line: String?
    public let enabled: Bool
    public let kind: Kind
    /// ★ notes28: an (i) at the row's end — its explanation in the centred card (nil: none).
    public var info: String? = nil

    public init(id: String, title: String, line: String? = nil, enabled: Bool = true, kind: Kind, info: String? = nil) {
        self.id = id; self.title = title; self.line = line; self.enabled = enabled; self.kind = kind; self.info = info
    }
    public static func action(_ title: String, line: String? = nil, enabled: Bool = true, id: String, info: String? = nil,
                              _ run: @escaping () -> Void) -> CornerMoreItem {
        CornerMoreItem(id: id, title: title, line: line, enabled: enabled, kind: .action(run), info: info)
    }
    public static func check(_ title: String, isOn: Bool, id: String, _ pick: @escaping () -> Void) -> CornerMoreItem {
        CornerMoreItem(id: id, title: title, kind: .check(isOn: isOn, pick))
    }
    public static func toggle(_ title: String, isOn: Bool, id: String, _ set: @escaping (Bool) -> Void) -> CornerMoreItem {
        CornerMoreItem(id: id, title: title, kind: .toggle(isOn: isOn, set))
    }
    public static func list(_ title: String, line: String? = nil, enabled: Bool = true, id: String,
                            _ children: [CornerMoreItem]) -> CornerMoreItem {
        CornerMoreItem(id: id, title: title, line: line, enabled: enabled, kind: .list(children))
    }
    public static func divider(_ id: String) -> CornerMoreItem { CornerMoreItem(id: id, title: "", kind: .divider) }

    var isDivider: Bool { if case .divider = kind { return true }; return false }
    var isCheck: Bool { if case .check = kind { return true }; return false }
    /// On, for a check or a switch.
    var isOn: Bool {
        switch kind { case .check(let on, _), .toggle(let on, _): return on; default: return false }
    }
}

/// The ⌃'s drawer: its rows on the ⌃ menu's colour, the first item nearest the buttons (as the system drew the menu), scrolling
/// past `maxHeight` (opened at its foot, where the first items are). Frames: "<key>Drawer", each row under its id.
public struct CornerMoreDrawer: View {
    @ObservedObject var drawers: CornerDrawers
    let key: String
    let items: [CornerMoreItem]
    var width: CGFloat = DSParts.panelWidth
    var maxHeight: CGFloat = 620

    public init(drawers: CornerDrawers, key: String, items: [CornerMoreItem], width: CGFloat = DSParts.panelWidth,
                maxHeight: CGFloat = 620) {
        self.drawers = drawers; self.key = key; self.items = items; self.width = width; self.maxHeight = maxHeight
    }

    /// RED CONTROL (CornerDrawersHostedTests): the drawer drawn in code order (its first item at the top).
    @MainActor static var controlTopDown = false

    /// The rows each open drawer offers, in the items' order (the hosted tests read it, as they read the menu's items).
    struct ProbeRow: Equatable { let title: String; let line: String?; let enabled: Bool; let id: String; let isOn: Bool }
    @MainActor static var probe: [String: [ProbeRow]] = [:]

    public var body: some View {
        let _ = Self.record(key, items)
        let checks = items.contains { $0.isCheck }
        let shown = Self.controlTopDown ? items : Array(items.reversed())
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { item in
                        row(item, checks: checks, indent: 0)
                        if case .list(let children) = item.kind, drawers.expanded == item.id {
                            ForEach(children) { c in row(c, checks: checks, indent: Self.childIndent) }
                        }
                    }
                    Color.clear.frame(height: 0).id(Self.footID(key))
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: Swift.max(DSParts.target, maxHeight))
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { DispatchQueue.main.async { reader.scrollTo(Self.footID(key), anchor: .bottom) } }
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.menu.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .background(DSParts.publish(key + "Drawer"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(key + "-drawer")
    }

    static let childIndent: CGFloat = 16
    static let rowMinHeight: CGFloat = 44
    static func footID(_ key: String) -> String { key + "-drawer-foot" }

    @MainActor private static func record(_ key: String, _ items: [CornerMoreItem]) {
        probe[key] = items.map { ProbeRow(title: $0.title, line: $0.line, enabled: $0.enabled, id: $0.id, isOn: $0.isOn) }
    }

    @ViewBuilder private func row(_ item: CornerMoreItem, checks: Bool, indent: CGFloat) -> some View {
        if item.isDivider {
            Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1).padding(.vertical, 4)
                .accessibilityHidden(true)
        } else {
            Button { tap(item) } label: {
                HStack(alignment: .center, spacing: 8) {
                    if checks {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .opacity(item.isCheck && item.isOn ? 1 : 0)
                            .frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 15))
                            .foregroundStyle((item.enabled ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                            .fixedSize(horizontal: false, vertical: true)
                        if let line = item.line, !line.isEmpty {
                            Text(line).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(item)
                }
                .padding(.leading, 16 + indent).padding(.trailing, 14).padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: Self.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(CornerMoreRowStyle())
            .disabled(!item.enabled)
            .background(DSParts.publish(item.id))
            .accessibilityIdentifier(item.id)
            .accessibilityValue(accessibilityValue(item))
            .overlay(alignment: .trailing) {
                // ★ notes28: the row's (i), its own 44 pt target over the row's end (the row's tap stays the row's)
                if let info = item.info {
                    AppInfoButton(title: item.title, text: info, label: "About \(item.title)", id: item.id + "-info")   // ★ notes29
                    .padding(.trailing, 4)
                    .background(DSParts.publish(item.id + "-info"))
                }
            }
        }
    }

    @ViewBuilder private func trailing(_ item: CornerMoreItem) -> some View {
        switch item.kind {
        case .toggle(let on, _):
            ZStack(alignment: on ? .trailing : .leading) {   // DSSwitch's small face (the row is the button)
                Capsule().fill(on ? DS.Color.okGreen.color : Color.white.opacity(0.16)).frame(width: 42, height: 26)
                Circle().fill(Color.white).frame(width: 22, height: 22).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            }
        case .list:
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                .foregroundStyle((item.enabled ? DS.Color.textSecondary : DS.Color.textTertiary).color)
                .rotationEffect(.degrees(drawers.expanded == item.id ? 90 : 0))
        default:
            EmptyView()
        }
    }

    private func accessibilityValue(_ item: CornerMoreItem) -> String {
        switch item.kind {
        case .toggle(let on, _): return on ? "On" : "Off"
        case .check(let on, _): return on ? "Selected" : ""
        default: return ""
        }
    }

    private func tap(_ item: CornerMoreItem) {
        guard item.enabled else { return }
        switch item.kind {
        case .action(let run): drawers.close(); run()
        case .check(_, let pick): pick(); drawers.close()
        case .toggle(let on, let set): set(!on)
        case .list: withAnimation(DS.Motion.emphasized) { drawers.expanded = drawers.expanded == item.id ? nil : item.id }
        case .divider: break
        }
    }
}

/// A ⌃ drawer row's press: the row lights faintly while the finger is down (the menu's highlight).
struct CornerMoreRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DS.Color.fillSelected.color : Color.clear)
    }
}

private struct CornerDrawerLookKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// ★ his 11-22 (img 45): a panel opened from the corner (the Settings drawer) wears the ⌃ menu's colour.
    public var cornerDrawerLook: Bool {
        get { self[CornerDrawerLookKey.self] }
        set { self[CornerDrawerLookKey.self] = newValue }
    }
}

#if canImport(MetalKit)
extension MetalMeshView {
    /// ★ his 11-22 (img 45): a tap on the 3D view — on the part or on empty space — first closes the open corner drawer, then
    /// does what it always did. Only the tap callbacks are wrapped (each one the view already had; none is added), so a drag
    /// still turns the view and no recognizer changes.
    @MainActor
    func closesCornerDrawers(_ drawers: CornerDrawers) -> MetalMeshView {
        var copy = self
        let close: () -> Void = { [weak drawers] in drawers?.close() }
        if let f = copy.inputs.onPickFace { copy.inputs.onPickFace = { close(); f($0) } }
        if let f = copy.inputs.onPickPoint { copy.inputs.onPickPoint = { close(); return f($0, $1) } }
        if let f = copy.inputs.onMiss { copy.inputs.onMiss = { close(); f() } }
        if let f = copy.inputs.onEmptyTap { copy.inputs.onEmptyTap = { close(); f() } }
        if let f = copy.inputs.onTapRay { copy.inputs.onTapRay = { close(); return f($0, $1, $2) } }
        if let f = copy.inputs.onSurfacePoint { copy.inputs.onSurfacePoint = { close(); f($0) } }
        return copy
    }
}
#endif
