// FlexibleExportSheet — the Export step (task 2026-09-29-flexible-screens; maintainer: "an
// 'export' button that will pull up a modal to either export gcode or an stl").
//
// ★ ROUND 4 (C2 — his answer 2: "when Lattice Ready shows, tapping it should send to Core and
// the export path"): the main page's big Lattice button opens this step as it sends the job to
// core (FlexibleCoreRun). Its top line is core's answer, in ONE line — "Sending to core…",
// "Core designed it · Gyroid · 230 °C · 3 faces", "Core refused it: …", "Not sent: …" — with
// the whole sentence (or where core's receipt and heat maps are) behind the (i).
//
// ★ BOTH EXPORTS ARE DISABLED UNTIL CORE HAS THE FLEXIBLE LATTICE (maintainer, 2026-09-29:
// "The exports aren't supposed to happen until core gets to it"). Core's Flexible runner writes
// receipts and heat maps, no mesh; ★ C2 VERIFICATION: the step says so ONCE, under core's line
// (it was said once per card), and the two exports are bare disabled buttons.
// ★ C2 VERIFICATION: when core can't take the job as it stands (FlexibleCoreHold — his pinch,
// two squeeze groups, a calibrate-first filament), 1–3 buttons under core's line send what it
// CAN run or use the filament with squish data (his rule: "1-3 fix buttons"). DS tokens only
// (the scrim, the stroke and the shadow were raw colours).
//
// Mounted by one #354 line in WorkspacePlaceholder (FlexibleExportMount — on any stage, since
// the pill is on every stage's bottom bar).

import SwiftUI
import TopOptDesign

/// The mount (the WorkspacePlaceholder hook): the step while it is up, else nothing.
public struct FlexibleExportMount: View {
    @ObservedObject var run: FlexibleCoreRun

    public init(run: FlexibleCoreRun) { self.run = run }

    public var body: some View {
        if run.shown {
            FlexibleExportSheet(run: run, onClose: { run.close() })
                .transition(.opacity)
        }
    }
}

public struct FlexibleExportSheet: View {
    @ObservedObject var run: FlexibleCoreRun
    let onClose: () -> Void

    public init(run: FlexibleCoreRun, onClose: @escaping () -> Void) {
        self.run = run
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(DS.Color.scrim.color).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: DS.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Export").font(.system(size: 27, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color).padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-export-close")
                }
                coreRow
                if let fixes = run.hold?.fixes, !fixes.isEmpty {
                    fixRow(fixes)
                }
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(FlexibleCoreRun.exportsWait)
                        .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityIdentifier("flexible-export-wait")
                    HStack(spacing: DS.Space.m) {
                        card("Export STL", id: "flexible-export-stl-disabled")
                        card("Export G-code", id: "flexible-export-gcode-disabled")
                    }
                }
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 820)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).stroke(DS.Color.strokePanel.color, lineWidth: 1))
            .dsShadow(DS.Shadow.sheet)
            .padding(.horizontal, PageChrome.edge)
        }
        .accessibilityIdentifier("flexible-export-sheet")
    }

    /// Core's answer, ONE line, its sentence behind the (i).
    private var coreRow: some View {
        HStack(spacing: DS.Space.s) {
            switch run.phase {
            case .sending:
                ProgressView().controlSize(.small).tint(DS.Color.textPrimary.color)
            case .ran(let r) where r.refusal == nil:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(FlexibleStageStyle.accentToken.color)
            case .idle:
                EmptyView()
            default:
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DS.Color.warning.color)
            }
            Text(run.line)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("flexible-export-core-line")
            Spacer(minLength: 0)
            if let info = run.info {
                FlexInfoButton(title: "Core", text: info, id: "flexible-export-core-info")
            }
        }
        .frame(minHeight: FlexInfoButton<EmptyView>.target)
    }

    /// ★ C2 VERIFICATION: what core CAN run (or the filament with data), 1–3 big buttons.
    private func fixRow(_ fixes: [FlexibleCoreFix]) -> some View {
        HStack(spacing: DS.Space.s) {
            ForEach(Array(fixes.prefix(3).enumerated()), id: \.offset) { i, f in
                let sent = run.sentFix == f
                Button { run.onFix?(f) } label: {
                    Text(f.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(i == 0 ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.vertical, 12).padding(.horizontal, DS.Space.l)
                        .frame(minWidth: 120)
                        .background(Capsule().fill(i == 0 ? FlexibleStageStyle.accent : DS.Color.chipSolid.color))
                        .overlay(Capsule().strokeBorder(DS.Color.textPrimary.color, lineWidth: 1.5).opacity(sent ? 1 : 0))
                }
                .buttonStyle(.plain)
                .disabled(run.isSending)
                .accessibilityIdentifier("flexible-export-fix-\(f.id)")
            }
        }
    }

    /// A disabled export (core writes no printable file yet): the G-code button's disabled look.
    private func card(_ button: String, id: String) -> some View {
        Text(button)
            .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textDisabled.color)
            .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s + 6)
            .background(Capsule().fill(DS.Color.fillDisabled.color))
            .accessibilityIdentifier(id)
    }
}
