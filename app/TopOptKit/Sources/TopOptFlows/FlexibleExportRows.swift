// FlexibleExportRows — core's answer, the hold's line and sends, and the exports: the rows the full-screen Export step
// (FlexibleExportSheet — Topology and Surface, through H10's pill) and the Flexible stage's corner card (FlexibleLatticeCard
// — H31 stops the step there) BOTH draw (task 2026-09-29-flexible-screens, round 7, batch R7-D1).
//
// ★ LIFTED, NOT COPIED (the reviewer's condition (a) on H31: "EVERY warning, refusal and answer from core that the
// full-screen step shows today must appear in the corner card — nothing dropped"). Every word the step showed lives here
// once: core's ONE line in each phase (FlexibleCoreRun.line) with its whole sentence behind the (i), the hold's second
// line (an edges group beside face groups: "Edges and faces go in separate exports for now."), the hold's 1–3 sends (his
// rule: "1-3 fix buttons"), the exports' one wait line and the two disabled exports (core writes no printable file yet).
// FlexibleRound7CardMessagesTests hosts the sheet and the card over the same run and finds each message in both.

import SwiftUI
import TopOptDesign

enum FlexibleExportRows {

    /// Core's answer, ONE line, its sentence behind the (i).
    struct CoreRow: View {
        @ObservedObject var run: FlexibleCoreRun
        var size: CGFloat = 15
        /// ★ R7-D1 look-and-fix 3: the corner card's narrower column lets core's line take two lines rather than cut it
        /// ("Core refused it: no squish data for this filament yet" needs ~340 pt).
        var wraps = false

        var body: some View {
            HStack(spacing: DS.Space.s) {
                switch run.phase {
                case .sending:
                    ProgressView().controlSize(.small).tint(DS.Color.textPrimary.color)
                case .ran(let r) where r.refusal == nil:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: size + 1, weight: .semibold))
                        .foregroundStyle(FlexibleStageStyle.accentToken.color)
                case .idle:
                    EmptyView()
                default:
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: size + 1, weight: .semibold))
                        .foregroundStyle(DS.Color.warning.color)
                }
                Text(run.line)
                    .font(.system(size: size, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(wraps ? 2 : 1).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: wraps)
                    .said(run.line)
                    .accessibilityIdentifier("flexible-export-core-line")
                Spacer(minLength: 0)
                if let info = run.info {
                    FlexInfoButton(title: "Core", text: info, id: "flexible-export-core-info")
                        .said("#flexible-export-core-info")
                }
            }
            .frame(minHeight: FlexInfoButton<EmptyView>.target)
        }
    }

    /// ★ ROUND 7, M1 (5 — the reviewer's ruling 4): an edges group beside the face groups is SAID under core's line, before
    /// anything is sent ("Edges and faces go in separate exports for now.").
    struct HoldNote: View {
        @ObservedObject var run: FlexibleCoreRun
        var size: CGFloat = 14

        var body: some View {
            if let note = run.hold?.note {
                Text(note)
                    .font(.system(size: size)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .said(note)
                    .accessibilityIdentifier("flexible-export-hold-note")
            }
        }
    }

    /// ★ R7-E2 (the ruling's item 5 — "Show that in plain words"): the job sent carried a SIDE press — one line under core's line,
    /// the ruling's whole sentence behind its (i).
    struct PressNote: View {
        @ObservedObject var run: FlexibleCoreRun
        var size: CGFloat = 14

        var body: some View {
            EmptyView()   // ★ R7-E2 STUB
        }
    }

    /// ★ C2 VERIFICATION: what core CAN run (or the filament with data), 1–3 big buttons.
    struct FixRow: View {
        @ObservedObject var run: FlexibleCoreRun
        /// The card's narrower buttons (it wraps them, never truncates his group's name).
        var compact = false

        var body: some View {
            if let fixes = run.hold?.fixes, !fixes.isEmpty {
                let buttons = ForEach(Array(fixes.prefix(3).enumerated()), id: \.offset) { i, f in
                    let sent = run.sentFix == f
                    Button { run.onFix?(f) } label: {
                        Text(f.title)
                            .font(.system(size: compact ? 14 : 15, weight: .semibold))
                            .foregroundStyle(i == 0 ? FlexibleStageStyle.onAccent : DS.Color.textPrimary.color)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .padding(.vertical, compact ? 0 : 12).padding(.horizontal, DS.Space.l)
                            .frame(minWidth: compact ? 44 : 120, minHeight: compact ? 44 : nil)
                            .background(Capsule().fill(i == 0 ? FlexibleStageStyle.accent : DS.Color.chipSolid.color))
                            // ★ ROUND 7, the review of R7-D1: in the corner card a secondary send wears the hairline (it read as
                            // text); the full-screen step (Topology, Surface) keeps its look
                            .overlay { if compact { FlexibleCornerPairStyle.secondaryEdge(i == 0) } }
                            .overlay(Capsule().strokeBorder(DS.Color.textPrimary.color, lineWidth: 1.5).opacity(sent ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .disabled(run.isSending)
                    .saidWhole(f.title, minScale: 0.8)
                    .accessibilityIdentifier("flexible-export-fix-\(f.id)")
                }
                if compact {
                    VStack(alignment: .leading, spacing: DS.Space.s) { buttons }
                } else {
                    HStack(spacing: DS.Space.s) { buttons }
                }
            }
        }
    }

    /// The exports: one line that says why they wait, then the two (disabled until core returns a printable file).
    struct Exports: View {
        @ObservedObject var run: FlexibleCoreRun
        var compact = false

        /// Both exports wait on core (its Flexible runner writes receipts, heat maps and CSVs — no mesh yet).
        static var disabled: Bool { true }

        var body: some View {
            let wait = FlexibleCoreRun.exportsWait
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(wait)
                    .font(.system(size: compact ? 13 : 14)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .saidWhole(wait, minScale: 0.85)
                    .accessibilityIdentifier("flexible-export-wait")
                HStack(spacing: DS.Space.m) {
                    card("Export STL", id: "flexible-export-stl-disabled")
                    card("Export G-code", id: "flexible-export-gcode-disabled")
                }
            }
        }

        /// A disabled export (core writes no printable file yet): the G-code button's disabled look.
        private func card(_ button: String, id: String) -> some View {
            Text(button)
                .font(.system(size: compact ? 14 : 16, weight: .semibold)).foregroundStyle(DS.Color.textDisabled.color)
                .frame(maxWidth: .infinity).padding(.vertical, compact ? DS.Space.s + 4 : DS.Space.s + 6)
                .frame(minHeight: compact ? 44 : nil)
                .background(Capsule().fill(DS.Color.fillDisabled.color))
                .saidWhole(button)
                .accessibilityIdentifier(id)
        }
    }
}
