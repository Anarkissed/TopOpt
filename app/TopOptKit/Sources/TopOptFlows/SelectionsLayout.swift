// SelectionsLayout.swift — ★ his iPad notes 2026-11-22 on the Selections panel, in every stage:
//   "We should add handles to expand or shrink the different columns in Selections"
//   "Please add a way to expand/shrink the width/height of the entire Selections modal"
//   "If a person taps and holds onto a name (i.e. Group 2 or Union of faces) it should open up the full alpha-numeric keyboard to
//    rename the group/face/zone"
// One place for the panel's size and its name / value split, remembered across launches (Topology's and Lattice Setup's lists
// read the same), and the hold-to-rename every row uses.
import SwiftUI
import TopOptDesign

@MainActor
public final class SelectionsLayout: ObservableObject {
    public static let shared = SelectionsLayout()
    static let widthKey = "topopt.selections.extraWidth.v1"
    static let valueKey = "topopt.selections.valueWidth.v1"
    static let heightKey = "topopt.selections.latticeHeight.v1"
    /// The most the panel widens past its 348 pt (his corner grip).
    public static let maxExtra: CGFloat = 320
    /// The value column's range (his column handle): from a short word to a long one.
    public static let valueRange: ClosedRange<CGFloat> = 36 ... 220
    private let defaults: UserDefaults

    /// Points the panel is wider than PageChrome.panelWidth (0: as before).
    @Published public var extraWidth: CGFloat {
        didSet { defaults.set(Double(extraWidth), forKey: Self.widthKey) }
    }
    /// The value column's width; nil: each row's value whole, as before (the handle was never dragged).
    @Published public var valueWidth: CGFloat? {
        didSet { if let v = valueWidth { defaults.set(Double(v), forKey: Self.valueKey) } else { defaults.removeObject(forKey: Self.valueKey) } }
    }
    /// Lattice Setup's list height (nil: as tall as its rows). Topology keeps its own (it always had a grip).
    @Published public var latticeHeight: CGFloat? {
        didSet { if let v = latticeHeight { defaults.set(Double(v), forKey: Self.heightKey) } else { defaults.removeObject(forKey: Self.heightKey) } }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        extraWidth = Self.clampExtra(CGFloat(defaults.double(forKey: Self.widthKey)))
        valueWidth = defaults.object(forKey: Self.valueKey) == nil ? nil : Self.clampValue(CGFloat(defaults.double(forKey: Self.valueKey)))
        latticeHeight = defaults.object(forKey: Self.heightKey) == nil ? nil : CGFloat(defaults.double(forKey: Self.heightKey))
    }

    public static func clampExtra(_ w: CGFloat) -> CGFloat { Swift.min(maxExtra, Swift.max(0, w.isFinite ? w : 0)) }
    public static func clampValue(_ w: CGFloat) -> CGFloat { Swift.min(valueRange.upperBound, Swift.max(valueRange.lowerBound, w)) }
    /// Back to the panel as it was (a test's reset; no control does it).
    public func reset() { extraWidth = 0; valueWidth = nil; latticeHeight = nil }
}

/// The value column's width under a Selections panel (nil: each row's own).
private struct DSRowValueWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var dsRowValueWidth: CGFloat? {
        get { self[DSRowValueWidthKey.self] }
        set { self[DSRowValueWidthKey.self] = newValue }
    }
}

public enum RenameCopy {
    public static let title = "Rename"
    public static let placeholder = "Name"
    public static let cancel = "Cancel"
    public static let save = "Rename"
    /// The name to keep: trimmed, never empty, nil when nothing changed.
    public static func accepted(_ draft: String, was: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == was ? nil : t
    }
}

/// ★ his 11-22: a hold of half a second on a name turns the row into its name field, in place, with the full keyboard (no
/// alert: U6/U7, confirm in place). Return or a tap away keeps the new name; empty or unchanged keeps the old one.
/// ★ his 11-22 (img 42-43): ONE box and nothing behind it — the row's own words and icons are hidden while it is up (no "Group
/// 1" or "Name" showing through), and the row grows to hold the whole box (its line stays under it).
/// The one name being renamed (a row's key) and its draft, so the row that shows the field can be wider than the name the
/// hold is on (a Selections group line: the whole line, its eye and trash hidden too).
final class RenameInPlace: ObservableObject {
    static let shared = RenameInPlace()
    @Published var key: String?
    @Published var draft = ""
    func start(_ key: String, name: String) { draft = name; self.key = key }
    /// ★ his iPad notes 11-23: the field's own scroll identity (a list brings it into view: SelectionsList).
    static func scrollID(_ key: String) -> String { "rename-" + key }
}

/// The hold on a name. `field` false: the row draws the field itself (`RenameField` on the whole line).
/// nil `rename`: the row is not renamable (nothing changes).
struct RenameOnHold: ViewModifier {
    let name: String
    let key: String
    let rename: ((String) -> Void)?
    var field = true

    @ViewBuilder func body(content: Content) -> some View {
        if let rename {
            let held = content
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in RenameInPlace.shared.start(key, name: name) })
                .background(DSParts.publish(key + "-renames"))   // the hosted tests' mark: this row renames
            if field { held.modifier(RenameField(name: name, key: key, rename: rename)) } else { held }
        } else {
            content
        }
    }
}

/// The field, in place of everything the modified view draws while its key is being renamed.
struct RenameField: ViewModifier {
    let name: String
    let key: String
    let rename: (String) -> Void
    @ObservedObject private var state = RenameInPlace.shared
    @FocusState private var focused: Bool
    /// The box's height and the room around it inside its row (the row grows to the box plus this).
    static let boxHeight: CGFloat = 44, inset: CGFloat = 4

    private var editing: Bool { state.key == key }

    func body(content: Content) -> some View {
        content
            .opacity(editing ? 0 : 1)   // ★ nothing behind the box: not the old name, not its icons
            .allowsHitTesting(!editing)
            .accessibilityHidden(editing)
            .frame(minHeight: editing ? Self.boxHeight + 2 * Self.inset : nil)   // ★ the row holds the whole box
            .overlay {
                if editing {
                    TextField(RenameCopy.placeholder, text: $state.draft)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: Self.boxHeight, maxHeight: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                            .fill(Color(.sRGB, red: 32 / 255, green: 32 / 255, blue: 38 / 255, opacity: 1))   // opaque: one box only
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.field, style: .continuous)
                                .strokeBorder(DS.Color.accent.color, lineWidth: 1.5)))
                        .background(DSParts.publish(key + "-field"))   // the box itself (the hosted tests')
                        .padding(.vertical, Self.inset)
                        .focused($focused)
                        .onSubmit { finish() }
                        .onChange(of: focused) { on in if !on { finish() } }
                        .onAppear { focused = true }
                        .accessibilityLabel(RenameCopy.title)
                        .accessibilityIdentifier(key + "-renaming")
                }
            }
            .id(RenameInPlace.scrollID(key))   // ★ 11-23: the row (with its box), found by a list to bring it above the keyboard
    }

    private func finish() {
        guard state.key == key else { return }
        let d = state.draft
        state.key = nil
        if let t = RenameCopy.accepted(d, was: name) { rename(t) }
    }
}
