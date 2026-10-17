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
// ★ ROUND 7, R7-D1 (H31): NOT on the Flexible stage — there core's answer and the exports are the corner card
// (FlexibleLatticeCard); Topology and Surface keep this step. Its rows moved to FlexibleExportRows, which the card draws
// too, so nothing it says can be dropped there.

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
                    Text("Export").font(.system(size: 27, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color).said("Export")
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(DS.Color.textSecondary.color).padding(DS.Space.s)
                            .background(Circle().fill(DS.Surface.dialog.color))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("flexible-export-close")
                }
                FlexibleExportRows.CoreRow(run: run)   // ★ R7-D1: the rows the corner card draws too (FlexibleExportRows)
                FlexibleExportRows.HoldNote(run: run)
                FlexibleExportRows.FixRow(run: run)
                FlexibleExportRows.Exports(run: run)
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
}
