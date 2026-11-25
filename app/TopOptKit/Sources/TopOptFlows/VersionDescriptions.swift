// VersionDescriptions.swift — ★ his iPad notes on release 18 (2026-11-24, img 83):
//   "very little difference between them... a guessing game" — and he asked for his own words on a version, everywhere he
//   meets one:
//   (a) a version card's ⋯ (and its long press) → "Edit description";
//   (b) its Details page: a pencil beside Description edits the words in place (LibraryVersionDetails.swift);
//   (c) saving a version (the version chip's Save) asks if he wants to edit its description, the editor prefilled with the
//       automatic differences;
//   (d) a new version made (Save and start a new version, an edit on a version with a result, New draft from vN, Optimize as
//       vN) asks if he wants to describe either one — the new one or the one it came from;
//   (e) the version chip in the workspace's top bar ("v8.1.1 draft") offers "Edit description" (VersionChipMenu.swift).
//
// The words live on the version's entry in library.json (`LibraryVersion.versionDescription`, optional, nil by default, so an
// older library.json reads as it was), beside his name for it; they are never a setting, so they make no version. The card
// shows them with the automatic differences on one line under them.
//
// The editor and the asks are centred cards over everything (his rule: asks are centred pop-ups, never a line at the
// bottom). The editor is its own layer (RootView mounts it beside AppPopupLayer), held by this shared model — never by the
// workspace's @State (its size is the iPad's main-thread stack's to pay).
import SwiftUI
import TopOptDesign

/// His words (captions at most five words).
public enum VersionDescriptionCopy {
    public static let edit = "Edit description"
    public static let heading = "Description"
    public static func title(_ v: String) -> String { "\(v) description" }
    public static let placeholder = "What is different about it"
    public static let save = "Save"
    public static let cancel = "Cancel"
    public static let notNow = "Not now"
    public static let none = "None yet"
    // (c) after a save
    public static func savedTitle(_ v: String) -> String { "\(v) saved" }
    public static let savedText = "Edit its description, so you can tell it apart in the Library?"
    // (d) after a new version
    public static func newTitle(_ v: String) -> String { "\(v) made" }
    public static func newText(_ v: String, from: String) -> String {
        "\(v) was made from \(from). Add a description to either, so you can tell them apart?"
    }
    public static func describe(_ v: String) -> String { "Describe \(v)" }
}

/// The centred description editor's state: which version, its title, and the words being typed.
@MainActor
public final class VersionDescriptionEditor: ObservableObject {
    public static let shared = VersionDescriptionEditor()
    public struct Editing: Equatable, Identifiable {
        public let id = UUID()
        public let folder: UUID
        public let title: String
        public static func == (a: Editing, b: Editing) -> Bool { a.id == b.id }
    }
    @Published public private(set) var editing: Editing?
    @Published public var text = ""
    private var save: ((String) -> Void)?
    /// Tests: every editor opened, while FlexibleSaid records.
    public static var recorded: [(folder: UUID, title: String, text: String)] = []

    public func open(folder: UUID, title: String, text: String, save: @escaping (String) -> Void) {
        if FlexibleSaid.recording { Self.recorded.append((folder, title, text)) }
        self.text = text
        self.save = save
        editing = Editing(folder: folder, title: title)
    }

    /// Save: the words go to the version (empty clears them).
    public func commit() {
        let run = save, t = text
        close()
        run?(t)
    }

    public func close() { editing = nil; save = nil }
}

/// The ways in: the editor on one version, and the two asks.
@MainActor
public enum VersionDescriptionEdit {
    /// RED CONTROL (VersionDescriptionTests): no ask after a save or a new version (as release 18).
    public static var controlNoAsks = false

    /// The editor on `folder`: his words, else the automatic differences (his (c)), saved to its entry.
    public static func open(library: LibraryModel, folder: UUID) {
        guard let v = library.version(folder) else { return }
        VersionDescriptionEditor.shared.open(folder: folder, title: VersionDescriptionCopy.title("v\(v.number)"),
                                             text: library.descriptionDraft(of: folder)) { [weak library] t in
            library?.setDescription(t, folder: folder)
        }
    }

    /// (c) A version was saved: ask if he wants to edit its description (nothing asked while another pop-up is up).
    public static func askAfterSave(library: LibraryModel, folder: UUID) {
        guard !controlNoAsks, AppPopups.shared.current == nil, let v = library.version(folder) else { return }
        let name = "v\(v.number)"
        AppPopups.shared.choose(VersionDescriptionCopy.savedTitle(name), VersionDescriptionCopy.savedText,
                                first: (VersionDescriptionCopy.edit, { [weak library] in
                                    if let library { open(library: library, folder: folder) }
                                }),
                                second: (VersionDescriptionCopy.notNow, {}), dismiss: nil)
        AppPopups.shared.current?.info = true   // an ask, not a warning: the (i)'s icon
    }

    /// (d) A new version `made` came from `from`: ask if he wants to describe either one.
    public static func askAfterNewVersion(library: LibraryModel, made: UUID, from: UUID) {
        guard !controlNoAsks, AppPopups.shared.current == nil, let m = library.version(made), let f = library.version(from)
        else { return }
        let new = "v\(m.number)", old = "v\(f.number)"
        AppPopups.shared.choose(VersionDescriptionCopy.newTitle(new), VersionDescriptionCopy.newText(new, from: old),
                                first: (VersionDescriptionCopy.describe(new), { [weak library] in
                                    if let library { open(library: library, folder: made) }
                                }),
                                second: (VersionDescriptionCopy.describe(old), { [weak library] in
                                    if let library { open(library: library, folder: from) }
                                }),
                                third: (VersionDescriptionCopy.notNow, {}), dismiss: nil)
        AppPopups.shared.current?.info = true   // an ask, not a warning: the (i)'s icon
    }
}

/// The centred editor, over everything (RootView mounts it beside AppPopupLayer).
struct VersionDescriptionLayer: View {
    @ObservedObject var editor = VersionDescriptionEditor.shared
    @FocusState private var focused: Bool

    var body: some View {
        if let e = editor.editing {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.35)).ignoresSafeArea()
                    .onTapGesture { editor.close() }
                GlassPanel {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text(e.title).dsStyle(DS.TypeScale.title).foregroundStyle(DS.Color.textPrimary.color)
                            .accessibilityIdentifier("version-description-title")
                        descriptionField
                            .background(DSParts.publish("versionDescriptionField"))
                        HStack(spacing: DS.Space.s) {
                            PillButton(VersionDescriptionCopy.cancel, style: .secondary) { editor.close() }
                                .background(DSParts.publish("versionDescriptionCancel"))
                                .accessibilityIdentifier("version-description-cancel")
                            PillButton(VersionDescriptionCopy.save) { editor.commit() }
                                .background(DSParts.publish("versionDescriptionSave"))
                                .accessibilityIdentifier("version-description-save")
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .padding(DS.Space.xl2)
                    .frame(maxWidth: 520)
                }
                .padding(DS.Space.xl)
                .background(DSParts.publish("versionDescriptionEditor"))
            }
            .transition(.opacity)
            .zIndex(101)
            .onAppear { focused = true }
        }
    }

    @ViewBuilder private var descriptionField: some View {
        let field = Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                TextField(VersionDescriptionCopy.placeholder, text: $editor.text, axis: .vertical).lineLimit(3...8)
            } else {
                TextField(VersionDescriptionCopy.placeholder, text: $editor.text)
            }
        }
        field
            .textFieldStyle(.plain)
            .focused($focused)
            .font(DS.TypeScale.body.font)
            .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.sm)
            .frame(minHeight: 88, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DS.Color.strokeStrong.color, lineWidth: 1))
            .accessibilityIdentifier("version-description-field")
    }
}
