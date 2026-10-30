// FlexibleSetupTray — the Setup chip "▦ Fast · ↑ +Z · ↓ −Z ⌃" and its tray, the left half of A1's corner pair (task
// 2026-09-29-flexible-screens, round 7, batch R7-D1: his pick 1).
//
// His words: img1 (2026-10-14) "Remove the 'Protect 3mm' chip at the bottom right corner. There is no need for it." and "Is
// there any need for 'Minimize Plastic' for this process at all?" (answered: no — it is Topology's objective); his answer
// "CAD surfaces — leave it OFF the Flexible stage (it only changes Topology's export)"; his img5 "the bottom right corner
// expanding with all the options to select"; and his pick: "the corner pair from A1 on the main Lattice screen".
//
// ★ THE CHIP reads what the three live inputs are — the quality (the scene's grid), which way is up on the plate
// (`build_direction`) and which way gravity points (the loads' `build_dir`) — so nothing needs opening to read them.
// ★ THE TRAY unfolds into one-line rows: Quality [Fast 64³ | Balanced | Fine], Plate up [Change] (the tray's body becomes
// the Flexible plate page — FlexiblePlatePage, ★ the review of R7-D1: one question, six big buttons — with ‹ back), Gravity [Change] (H30's closure: #354's own gravity setup; every card folds),
// Print parameters › (today's sheet). NOTHING ELSE: Protect N mm, Minimize plastic, CAD surfaces and the compute chip are
// his removals, and the Flexible stage reads none of them. Topology keeps them all (H24 leaves its column untouched).

import SwiftUI
import TopOptDesign

/// The chip's words, live.
public enum FlexibleSetupChip {
    @MainActor public static func parts(project: ProjectModel) -> (quality: String, plate: String, gravity: String) {
        let g = project.force.gravity
        let gravity: String
        if let g {
            gravity = GravityDirectionGizmo.snap(SIMD3<Double>(g), toleranceDeg: 0.25).label ?? "custom"
        } else {
            gravity = "not set"
        }
        return (project.quality.title, BuildOrientation.label(project.buildOrientation.resolved(gravity: g)), gravity)
    }

    /// "Fast · +Z · −Z" (the chip draws a glyph before each part).
    @MainActor public static func label(project: ProjectModel) -> String {
        let p = parts(project: project)
        return "\(p.quality) \u{00B7} \(p.plate) \u{00B7} \(p.gravity)"
    }
}

/// The tray's rows, in order: exactly four.
public enum FlexibleSetupRow: String, CaseIterable, Sendable {
    case quality, plateUp, gravity, printParameters

    public var title: String {
        switch self {
        case .quality: return "Quality"
        case .plateUp: return "Plate up"
        case .gravity: return "Gravity"
        case .printParameters: return "Print parameters"
        }
    }
    /// The #354 chip this row stands in for (Print parameters was the bar's button, not a chip).
    public var chip: SettingsChipID? {
        switch self {
        case .quality: return .quality
        case .plateUp: return .buildOrientation
        case .gravity: return .gravity
        case .printParameters: return nil
        }
    }
    var glyph: String {
        switch self {
        case .quality: return "square.grid.3x3.fill"
        case .plateUp: return "square.3.layers.3d.top.filled"
        case .gravity: return "arrow.down.to.line"
        case .printParameters: return "slider.horizontal.3"
        }
    }
    var id: String {
        switch self {
        case .quality: return "flexible-setup-quality"
        case .plateUp: return "flexible-setup-plate"
        case .gravity: return "flexible-setup-gravity"
        case .printParameters: return "flexible-setup-print"
        }
    }
}

/// Which body the tray shows: its rows, or the plate picker.
@MainActor
public final class FlexibleSetupTrayState: ObservableObject {
    public enum Page: Equatable, Sendable { case rows, plate }
    @Published public var page: Page = .rows
    public init() {}
}

/// What the rows do (the view calls these; the tests call them too).
@MainActor
public enum FlexibleSetupActions {
    /// Gravity [Change]: #354's own gravity setup (H30's closure), and every card folds.
    static func changeGravity(chrome: FlexibleChromeState, tray: FlexibleSetupTrayState, changeGravity: () -> Void) {
        changeGravity()
        tray.page = .rows
        chrome.foldAll()
    }
    /// Print parameters ›: today's sheet; the tray folds under it.
    static func printParameters(app: AppModel, chrome: FlexibleChromeState) {
        app.openPrintParams()
        chrome.foldAll()
    }
    static func plateUp(tray: FlexibleSetupTrayState) { tray.page = .plate }
    static func back(tray: FlexibleSetupTrayState) { tray.page = .rows }
    static func quality(_ q: RunQuality, project: ProjectModel) { if project.quality != q { project.quality = q } }
}

/// The chip.
struct FlexibleSetupChipView: View {
    @ObservedObject var project: ProjectModel
    let open: Bool
    let tap: () -> Void

    var body: some View {
        let p = FlexibleSetupChip.parts(project: project)
        Button(action: tap) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: FlexibleSetupRow.quality.glyph).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
                Text(p.quality)
                Text("\u{00B7}").foregroundStyle(DS.Color.textTertiary.color)
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                Text(p.plate)
                Text("\u{00B7}").foregroundStyle(DS.Color.textTertiary.color)
                Image(systemName: FlexibleSetupRow.gravity.glyph).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
                Text(p.gravity)
                Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Color.textSecondary.color)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(DS.Color.textPrimary.color)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.ml)
            .frame(height: FlexibleChromeLayout.setupHeight)
            .frame(maxWidth: FlexibleChromeLayout.setupMaxWidth)
            .background(Capsule().fill(DS.Surface.bar.color)
                .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            // ★ the review of R7-D1 (minor d: thin vertical hairlines at the chip's frame edges, outside its capsule — drawn in a
            // key window and in one that is not, so not a focus ring): nothing is drawn outside the capsule
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Setup: \(p.quality), plate up \(p.plate), gravity \(p.gravity)")
        .accessibilityValue(open ? "Open" : "Folded")
        .accessibilityIdentifier("flexible-setup-chip")
    }
}

/// The tray: four one-line rows (or the plate picker).
struct FlexibleSetupTray: View {
    @ObservedObject var project: ProjectModel
    @ObservedObject var tray: FlexibleSetupTrayState
    let chrome: FlexibleChromeState
    let app: AppModel
    let changeGravity: () -> Void
    /// ★ R7-D1 look-and-fix 3: the mini's 336 pt tray (FlexibleChromeLayout.panelIsNarrow). Its titles take their own width
    /// (no 130 pt column) and the Quality segments sit closer, so every row reads whole — at the 130 pt column the mini cut
    /// them to "Fa… Bal…", "+Z · assu…" and "Print paramet…".
    var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                if tray.page == .plate {
                    FlexibleCornerPairStyle.x44("chevron.left", label: "Back to Setup", id: "flexible-setup-back") { FlexibleSetupActions.back(tray: tray) }
                }
                Text(tray.page == .plate ? "Plate up" : "Setup").font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: 0)
                FlexibleCornerPairStyle.x44("chevron.down", label: "Fold Setup", id: "flexible-setup-fold") { chrome.close(.setup) }
            }
            .frame(minHeight: 44)
            if tray.page == .plate {
                // ★ ROUND 7, the review of R7-D1: the Flexible plate page — one question, six big buttons, the current one lit
                // (it was #354's BuildOrientationView: paragraphs, 40 × 28 pt chips, "Down in service +Z" over a −Z gravity)
                FlexiblePlatePageView(project: project, done: { FlexibleSetupActions.back(tray: tray) })
            } else {
                ForEach(FlexibleSetupRow.allCases, id: \.self) { row($0) }
            }
        }
    }

    @ViewBuilder private func row(_ r: FlexibleSetupRow) -> some View {
        let parts = FlexibleSetupChip.parts(project: project)
        let content = HStack(spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: r.glyph).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle((r == .plateUp || r == .printParameters ? DS.Color.textSecondary : DS.Color.accent).color)
                    .frame(width: 18)
                Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .fixedSize()   // the title never gives way (it did to a Spacer at the mini's width)
                    .saidWhole(r.title)
            }
            .frame(minWidth: narrow ? 0 : 130, alignment: .leading)
            .layoutPriority(1)
            switch r {
            case .quality:
                Spacer(minLength: 0)
                qualitySegments.layoutPriority(1)
            case .plateUp:
                let plate = parts.plate + (project.buildOrientation.isInferredFromGravity ? " \u{00B7} assumed" : "")
                Text(plate)
                    .font(.system(size: 13.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .saidWhole(plate)
                Spacer(minLength: 0)
                FlexibleCornerPairStyle.small("Change", id: "flexible-setup-plate-change") { FlexibleSetupActions.plateUp(tray: tray) }
            case .gravity:
                Text(parts.gravity).font(.system(size: 13.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .saidWhole(parts.gravity)
                Spacer(minLength: 0)
                FlexibleCornerPairStyle.small("Change", id: "flexible-setup-gravity-change") {
                    FlexibleSetupActions.changeGravity(chrome: chrome, tray: tray, changeGravity: changeGravity)
                }
            case .printParameters:
                let bead = String(format: "bead %.2f mm", project.printParams.strutLineWidthMM)
                Text(bead)
                    .font(.system(size: 13.5)).foregroundStyle(DS.Color.textSecondary.color)
                    .saidWhole(bead)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .saidWhole("Setup row \u{00B7} \(r.title)")   // the whole row fits its tray: drawn as wide as the tray, needing no more
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
        .background(FlexibleCornerPairStyle.publish("setupRow-\(r.rawValue)"))
        if r == .printParameters {
            Button { FlexibleSetupActions.printParameters(app: app, chrome: chrome) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityIdentifier(r.id)
        } else {
            content.accessibilityElement(children: .contain).accessibilityIdentifier(r.id)
        }
    }

    private var qualitySegments: some View {
        HStack(spacing: 2) {
            ForEach(RunQuality.allCases, id: \.self) { q in
                let lit = project.quality == q
                let title = q == .fast ? "\(q.title) \(q.resolution)\u{00B3}" : q.title
                Button { FlexibleSetupActions.quality(q, project: project) } label: {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle((lit ? DS.Color.textPrimary : DS.Color.textTertiary).color)
                        .fixedSize()
                        .saidWhole(title)
                        .padding(.horizontal, narrow ? DS.Space.s : DS.Space.sm)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(lit ? DS.Color.fillSelected.color : Color.clear))
                        .frame(height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(lit ? .isSelected : [])
                .accessibilityIdentifier("flexible-setup-quality-\(q.rawValue)")
            }
        }
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.background.opacity(0.35).color).frame(height: 40)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.Color.strokeSubtle.color, lineWidth: 1).frame(height: 40)))
    }
}
