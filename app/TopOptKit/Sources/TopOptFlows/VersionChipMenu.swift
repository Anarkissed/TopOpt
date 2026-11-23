// VersionChipMenu.swift — ★ his iPad notes 2026-11-23 (img 2, the top bar's "v7 draft"):
//   "Tapping on "v7 draft" should open up two options: Save, and Save and Start a New Version - which saves what is currently
//    done to v7, then creates a v8 or v7.1 (I forget the naming conventions of the app) for the user to start up changes and
//    save whenever."
//
// A tap on the version in the top-left block opens a small drawer under it — the app's own drawer, the ⌃ menu's colour, opened
// as the Settings drawer opens (one corner drawer at a time: CornerDrawers), never a system alert or menu. Its two rows:
//   Save                          — what is on screen, saved to this version;
//   Save and start a new version  — saved, then the next version made from it (VersionNumber's rules: v8 from the newest
//                                   main-line version, v7.1 from an older one) and the workspace moved there.
// A tap outside it, or on the version again, shuts it (CornerTapCloser keeps it open for taps inside).
import SwiftUI
import TopOptDesign

public enum VersionChipCopy {
    public static let save = "Save"
    public static let saveAndNew = "Save and start a new version"
    /// The rows' grey lines (five words at most).
    public static func saveLine(_ v: String) -> String { "Saves to \(v)" }
    public static func newLine(_ v: String, next: String) -> String { "Saves \(v), then opens \(next)" }
    public static func saved(_ v: String) -> String { "\(v) saved" }
    public static let failedTitle = "Couldn\u{2019}t start a new version"
    public static let failedText = "This version was saved, but the new one couldn\u{2019}t be written. Free some space on the iPad, then try again."
}

/// Where the version chip is drawn (the top-left block's "v7 draft"), for the drawer under it.
struct VersionChipAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The version chip's drawer: Save, and Save and start a new version.
struct VersionChipMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryModel
    let folder: UUID

    /// The corner drawers' key (one drawer open at a time).
    static let key = "versionMenu"
    static let width: CGFloat = 300

    init(model: AppModel, folder: UUID) { self.model = model; self.library = model.library; self.folder = folder }

    private var current: String? { library.version(folder).map { "v\($0.number)" } }
    /// The number the next version will take, as the Library will give it.
    private var next: String? {
        guard let part = library.index.part(containing: folder), let v = part.version(folderID: folder) else { return nil }
        return "v\(part.nextNumber(from: v.number))"
    }
    private var busy: Bool { model.project?.run.phase == .running || model.runningIDs.contains(folder) }

    var body: some View {
        let v = current ?? "this version"
        VStack(alignment: .leading, spacing: 0) {
            row(VersionChipCopy.save, line: VersionChipCopy.saveLine(v), id: "versionMenuSave", enabled: true) {
                model.cornerDrawers.close()
                model.saveVersion()
            }
            Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1).padding(.horizontal, 12)
            row(VersionChipCopy.saveAndNew, line: next.map { VersionChipCopy.newLine(v, next: $0) }, id: "versionMenuNew",
                enabled: !busy) {
                model.cornerDrawers.close()
                model.saveAndStartNewVersion()
            }
        }
        .padding(.vertical, 6)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.menu.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .strokeBorder(DS.Color.strokePanel.color, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .background(DSParts.publish(Self.key + "Drawer"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.key + "-drawer")
    }

    private func row(_ title: String, line: String?, id: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15))
                    .foregroundStyle((enabled ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                    .fixedSize(horizontal: false, vertical: true)
                if let line {
                    Text(line).font(.system(size: 12)).foregroundStyle(DS.Color.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(CornerMoreRowStyle())
        .disabled(!enabled)
        .background(DSParts.publish(id))
        .accessibilityIdentifier(id)
    }
}

/// The drawer, drawn over the whole page under the chip it opened from (the page's last layer: nothing covers it).
struct VersionChipMenuLayer: View {
    @ObservedObject var model: AppModel
    @ObservedObject var drawers: CornerDrawers
    let folder: UUID
    let anchor: Anchor<CGRect>?

    init(model: AppModel, folder: UUID, anchor: Anchor<CGRect>?) {
        self.model = model; self.drawers = model.cornerDrawers; self.folder = folder; self.anchor = anchor
    }

    var body: some View {
        GeometryReader { g in
            if drawers.isOpen(VersionChipMenu.key), let anchor {
                let chip = g[anchor]
                VersionChipMenu(model: model, folder: folder)
                    .offset(x: Swift.max(PageChrome.edge, Swift.min(chip.minX - 16, g.size.width - VersionChipMenu.width - PageChrome.edge)),
                            y: chip.maxY + PageChrome.gap)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .allowsHitTesting(drawers.isOpen(VersionChipMenu.key))
    }
}

extension View {
    /// ★ his iPad notes 11-23: the version chip's drawer, over the page (the workspace's and Results' top-left block).
    func versionChipMenu(_ model: AppModel, folder: UUID) -> some View {
        overlayPreferenceValue(VersionChipAnchorKey.self) { VersionChipMenuLayer(model: model, folder: folder, anchor: $0) }
    }
}
