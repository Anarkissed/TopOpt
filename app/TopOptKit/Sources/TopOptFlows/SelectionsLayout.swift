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

/// ★ his 11-22: a hold of half a second on a name asks for its new one, with the full keyboard; empty or unchanged keeps it.
/// nil `rename`: the row is not renamable (nothing changes).
struct RenameOnHold: ViewModifier {
    let name: String
    let key: String
    let rename: ((String) -> Void)?
    @State private var asking = false
    @State private var draft = ""

    @ViewBuilder func body(content: Content) -> some View {
        if let rename {
            content
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in draft = name; asking = true })
                .alert(RenameCopy.title, isPresented: $asking) {
                    TextField(RenameCopy.placeholder, text: $draft)
                    Button(RenameCopy.cancel, role: .cancel) {}
                    Button(RenameCopy.save) { if let t = RenameCopy.accepted(draft, was: name) { rename(t) } }
                }
                .background(DSParts.publish(key + "-renames"))   // the hosted tests' mark: this row renames
        } else {
            content
        }
    }
}
