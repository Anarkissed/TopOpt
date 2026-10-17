// FlexibleLatticeCard — the Lattice split button's card: ① Preview ② Core ③ Export, and nothing else (task
// 2026-09-29-flexible-screens, round 7, batch R7-D1: his pick 1, A1's corner pair).
//
// His answer (2026-10-14): "Optimize on the Flexible stage: DROP both the muted Optimize row and the iPad/Mac compute
// chip; the Lattice card holds only Preview → Core → Export." His pick: the card opens from the split's ⌃ ("its ⌃ opens the
// card with Preview → Core → Export"); A1's card has NO scrim — the model stays live under it.
//
// ★ IT REPLACES THE FULL-SCREEN EXPORT STEP ON THIS STAGE (H31) — and says everything that step said (the reviewer's
// condition (a)): core's one line in every phase with its sentence behind the (i), the hold's second line, its 1–3 sends,
// the exports' wait and the two disabled exports, all drawn by the SAME rows (FlexibleExportRows). Plus what the step never
// had: the steps before core, so he can look without sending (Preview opens the card on ② — nothing is sent).
//   ① Preview  built · N face-prisms · depth   (a spinner while it builds)
//   ② Core     Ready: [Send to core] · Preview: the hold's sends · Sending: a progress line · core's answer, refusal
//              and its fixes · a blocker's sentence with [Show the fix] · no face-prism: the stated reason (ruling 4)
//   ③ Export   [Export STL] [Export G-code], disabled until core returns a mesh, said once
// Markers: done okGreen ✓; current an accent ring; blocked warning !; future textQuaternary.

import SwiftUI
import TopOptDesign

public enum FlexibleLatticeCard {
    public enum Marker: Equatable, Sendable { case done, current, blocked, future }
    public struct Step: Equatable, Sendable {
        public let id: String
        public let title: String
        public let marker: Marker
        /// The step's one line when it is words alone (nil: its rows say it — core's answer, the sends, the exports).
        public let line: String?
    }

    /// Core's step is still waiting for the preview.
    public static let waits = "Waits for the preview"
    /// Test control only (the reviewer's condition (a)): a card that drops the hold's second line.
    @MainActor static var controlDropsHoldNote = false

    /// The three steps, as values.
    @MainActor static func steps(state: FlexibleLatticeButton.State, status: FlexibleMainStatus, run: FlexibleCoreRun, preview: String) -> [Step] {
        let early = state == .opening || state == .building
        let previewStep = Step(id: "preview", title: "Preview", marker: early ? .current : (state == .viewOff || state == .idle ? .future : .done),
                               line: preview)
        let core: Step
        switch state {
        case .fix:
            core = Step(id: "core", title: "Core", marker: .blocked, line: status.fix?.oneLine ?? status.line)
        case .blocked:
            core = Step(id: "core", title: "Core", marker: .blocked, line: run.phase == .idle ? FlexibleRowCopy.noFacePrism : nil)
        case .opening, .building, .viewOff, .idle:
            core = Step(id: "core", title: "Core", marker: .future, line: waits)
        case .sent, .exports:
            core = Step(id: "core", title: "Core", marker: .done, line: nil)
        case .refused:
            core = Step(id: "core", title: "Core", marker: .blocked, line: nil)
        case .ready, .preview, .sending:
            core = Step(id: "core", title: "Core", marker: .current, line: nil)
        }
        let export = Step(id: "export", title: "Export", marker: state == .exports ? .current : .future, line: nil)
        return [previewStep, core, export]
    }

    /// The Core step's sends while core can't take the job as it stands (the hold's 1–3): what the card shows on Preview.
    @MainActor static func coreSends(state: FlexibleLatticeButton.State, status: FlexibleMainStatus, run: FlexibleCoreRun) -> [FlexibleCoreFix] {
        guard state == .preview || state == .refused || state == .ready || state == .sent else { return [] }
        return Array((run.hold?.fixes ?? []).prefix(3))
    }

    /// The exports wait until core returns a mesh (it returns none yet — FlexibleCoreRun.exportsWait).
    @MainActor static func exportsDisabled(run: FlexibleCoreRun) -> Bool { FlexibleExportRows.Exports.disabled }

    /// The hold's line while he only LOOKS (nothing was sent): "Core runs one squeeze group at a time", not "Not sent: …".
    static func lookLine(_ line: String) -> String {
        let p = "Not sent: "
        guard line.hasPrefix(p) else { return line }
        let rest = line.dropFirst(p.count)
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// ① Preview's line: what was built, from the face-prisms the job sends (ruling 4: only a face-prism makes lattice).
    @MainActor static func previewLine(state: FlexibleLatticeButton.State, project: ProjectModel) -> String {
        switch state {
        case .opening: return "opening the part\u{2026}"
        case .building: return "building\u{2026}"
        case .viewOff: return "waits for the Lattice view"
        case .blocked: return "no face-prism yet"
        case .idle: return "nothing to squish yet"
        default:
            let inc = project.latticeJobRegions().regions.filter { $0.role == .include }
            guard !inc.isEmpty else { return "built" }
            let depths = Array(Set(inc.map { String(format: "%.1f", $0.depthMM) })).sorted()
            let n = inc.count == 1 ? "1 face-prism" : "\(inc.count) face-prisms"
            return "built \u{00B7} \(n) \u{00B7} \(depths.joined(separator: " / ")) mm"
        }
    }
}

/// The card's view.
struct FlexibleLatticeCardView: View {
    @ObservedObject var run: FlexibleCoreRun
    let status: FlexibleMainStatus
    let state: FlexibleLatticeButton.State
    let preview: String
    var width: CGFloat = PageChrome.receiptDrawerWidth
    var maxHeight: CGFloat = 800
    var close: () -> Void = {}
    var send: () -> Void = {}
    var showFix: () -> Void = {}
    /// ★ R7-D1 look-and-fix 3: the mini's 336 pt card puts each step's body UNDER its title (nil: from `width`). Beside a
    /// 64 pt title column the body had 194 pt and the mini cut "Send Group 2 only, Face 2 re…" and broke "Export G-code".
    var narrow: Bool? = nil
    private var stacked: Bool { narrow ?? FlexibleChromeLayout.panelIsNarrow(width) }

    var body: some View {
        let steps = FlexibleLatticeCard.steps(state: state, status: status, run: run, preview: preview)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Text(FlexibleLatticeButton.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: 0)
                FlexibleCornerPairStyle.x44("chevron.down", label: "Fold the card", id: "flexible-card-fold", action: close)
            }
            .frame(minHeight: 44)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        stepRow(i + 1, s)
                    }
                }
            }
            .frame(maxHeight: max(0, maxHeight - 44 - 2 * DS.Space.m))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Space.ml).padding(.vertical, DS.Space.m)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .dsShadow(DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-lattice-card")
    }

    @ViewBuilder private func stepRow(_ n: Int, _ s: FlexibleLatticeCard.Step) -> some View {
        Group {
            if stacked {
                // the mini: the title on its own line, the body under it (indented to the title's text)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: DS.Space.s) {
                        FlexibleStepMarker(n: n, marker: s.marker)
                        stepTitle(s)
                    }
                    .padding(.top, 11)
                    stepBody(s).padding(.leading, 22 + DS.Space.s)
                }
            } else {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    FlexibleStepMarker(n: n, marker: s.marker).padding(.top, 11)
                    stepTitle(s).frame(width: 64, alignment: .leading).padding(.top, 13)
                    stepBody(s)
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(DS.Color.strokeSubtle.color).frame(height: 1) }
        .background(FlexibleCornerPairStyle.publish("cardStep-\(s.id)"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-card-step-\(s.id)")
    }

    private func stepTitle(_ s: FlexibleLatticeCard.Step) -> some View {
        Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            .lineLimit(1)
            .saidWhole(s.title)
    }

    private func stepBody(_ s: FlexibleLatticeCard.Step) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            switch s.id {
            case "preview": previewBody(s)
            case "core": coreBody(s)
            default: FlexibleExportRows.Exports(run: run, compact: true)
            }
        }
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func previewBody(_ s: FlexibleLatticeCard.Step) -> some View {
        HStack(spacing: DS.Space.s) {
            if s.marker == .current { ProgressView().controlSize(.mini).tint(DS.Color.textPrimary.color) }
            Text(s.line ?? "").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .saidWhole(s.line ?? "", minScale: 0.8)
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private func coreBody(_ s: FlexibleLatticeCard.Step) -> some View {
        switch state {
        case .fix:
            Text(s.line ?? status.line).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                .fixedSize(horizontal: false, vertical: true)
                .said(s.line ?? status.line)
                .accessibilityIdentifier("flexible-card-fix-line")
            FlexibleCornerPairStyle.small("Show the fix", id: "flexible-card-show-fix", action: showFix)
        case .opening, .building, .viewOff, .idle:
            Text(s.line ?? "").font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color).frame(minHeight: 28)
                .said(s.line ?? "")
        case .blocked:
            if run.phase != .idle {
                FlexibleExportRows.CoreRow(run: run, size: 13.5, wraps: true)
            } else {
                Text(FlexibleRowCopy.noFacePrism).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.warning.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .said(FlexibleRowCopy.noFacePrism)
                    .accessibilityIdentifier("flexible-card-no-prism")
            }
        default:
            if run.phase != .idle {
                FlexibleExportRows.CoreRow(run: run, size: 13.5, wraps: true)
            } else if state == .preview, let h = run.hold {
                // looked at, nothing sent: the hold's sentence, its (i)
                HStack(spacing: DS.Space.s) {
                    Text(FlexibleLatticeCard.lookLine(h.line)).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .said(FlexibleLatticeCard.lookLine(h.line))
                        .accessibilityIdentifier("flexible-card-hold-line")
                    Spacer(minLength: 0)
                    FlexInfoButton(title: "Core", text: h.why, id: "flexible-card-hold-info")
                }
            } else if state == .preview, let f = status.fix {
                // ★ batch E's advisory (a pressed face with no lattice under it): said, and the send still offered
                Text(f.oneLine).font(.system(size: 13)).foregroundStyle(DS.Color.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .said(f.oneLine)
            }
            if !FlexibleLatticeCard.controlDropsHoldNote { FlexibleExportRows.HoldNote(run: run, size: 13) }
            FlexibleExportRows.FixRow(run: run, compact: true)
            if (state == .ready || (state == .preview && run.hold == nil)) && !run.isSending {
                Button(action: send) {
                    Text("Send to core").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlexibleStageStyle.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(Capsule().fill(FlexibleStageStyle.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .said("Send to core")
                .accessibilityIdentifier("flexible-card-send")
            }
        }
    }
}

/// A step's marker: done ✓ (okGreen), current (an accent ring), blocked ! (warning), future (a faint ring).
struct FlexibleStepMarker: View {
    let n: Int
    let marker: FlexibleLatticeCard.Marker
    var body: some View {
        ZStack {
            switch marker {
            case .done:
                Circle().fill(DS.Color.okGreen.color)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(DS.Color.background.color)
            case .current:
                Circle().strokeBorder(DS.Color.accent.color, lineWidth: 2)
                Text("\(n)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(DS.Color.accent.color)
            case .blocked:
                Circle().fill(DS.Color.warning.color)
                Text("!").font(.system(size: 12, weight: .heavy)).foregroundStyle(DS.Color.background.color)
            case .future:
                Circle().strokeBorder(DS.Color.textQuaternary.color, lineWidth: 1.5)
                Text("\(n)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(DS.Color.textQuaternary.color)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
