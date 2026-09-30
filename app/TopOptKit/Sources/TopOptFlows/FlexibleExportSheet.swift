// FlexibleExportSheet — the Export step (task 2026-09-29-flexible-screens; maintainer: "an
// 'export' button that will pull up a modal to either export gcode or an stl").
//
// ★ ROUND 4 (C2 — his answer 2: "when Lattice Ready shows, tapping it should send to Core and
// the export path"): the main page's big Lattice button opens this step as it sends the job to
// core (FlexibleCoreRun). Its top line is core's answer, in ONE line — "Sending to core…",
// "Core designed it · Gyroid · 230 °C · 3 faces", "Core refused it: …", "Not sent: …" — with
// the whole sentence (or where core's receipt and heat maps are) behind the (i).
//
// ★ BOTH CARDS ARE DISABLED UNTIL CORE HAS THE FLEXIBLE LATTICE (maintainer, 2026-09-29:
// "The exports aren't supposed to happen until core gets to it"). Core's Flexible runner writes
// receipts and heat maps, no mesh; each card says so in ONE line
// (FlexibleCoreRun.exportsWait). Disabled look: the G-code button's fillDisabled / textDisabled.
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
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45)).ignoresSafeArea()
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
                HStack(alignment: .top, spacing: DS.Space.m) {
                    card("STL", button: "Export STL", id: "flexible-export-stl-disabled")
                    card("G-code", button: "Export G-code", id: "flexible-export-gcode-disabled")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.xl4)
            .frame(maxWidth: 820)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).fill(DS.Surface.sheet.color))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sheet, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
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

    private func card(_ title: String, button: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(DS.Color.textTertiary.color).frame(width: 10, height: 10)
                Text(title).font(.system(size: 21, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
            }
            Text(FlexibleCoreRun.exportsWait)
                .font(.system(size: 14)).foregroundStyle(DS.Color.textSecondary.color)
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: DS.Space.m)
            Text(button)
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textDisabled.color)
                .frame(maxWidth: .infinity).padding(.vertical, DS.Space.s + 6)
                .background(Capsule().fill(DS.Color.fillDisabled.color))
                .accessibilityIdentifier(id)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Surface.dialog.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .stroke(DS.Color.textTertiary.color.opacity(0.35), lineWidth: 1))
    }
}
