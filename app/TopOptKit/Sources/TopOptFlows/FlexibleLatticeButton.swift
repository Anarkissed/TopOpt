// FlexibleLatticeButton — the "Lattice" split button, the right half of A1's corner pair (task
// 2026-09-29-flexible-screens, round 7, batch R7-D1: his pick 1).
//
// His pick: "the corner pair from A1 on the main Lattice screen" — the Lattice split button: "main = the next step in one
// tap, status line under it, e.g. 'Preview · core runs one group at a time'; its ⌃ opens the card with Preview → Core →
// Export". His answer: "Optimize on the Flexible stage: DROP both the muted Optimize row and the iPad/Mac compute chip".
// His rules: blockers pop at once with 1–3 fixes; one visible line per setting.
//
// ★ THE MAIN ZONE (about 207 wide): "Lattice", never changing, over ONE status line; a tap does the next step —
//     Opening → a note (still opening)          Fix → the blocker callout, again even after he dismissed it
//     Building → a note (still building)         View off → the Lattice view on (it bakes)
//     Preview → the card on ② with its 1–3 sends — NOTHING is sent (core can't take the job as it stands)
//     Ready → sends to core ONCE (an unchanged job never re-sends: FlexibleCoreRun) and opens the card on ②
//     Sending / Sent / Refused / Exports → the card      No face-prism → disabled, its line the reason (ruling 4)
//     Nothing to squish yet → the Squish page (it never opens by itself)
// ★ THE ⌃ ZONE (52 wide): opens or closes the card and NEVER runs anything.
// The tones are today's pill's (FlexibleMainStatusPill.fill / .stroke). FlexibleMainStage.pillTapped stays the decider
// for the old pill on the other stages (H10); this button is the Flexible stage's.

import SwiftUI
import TopOptDesign

public enum FlexibleLatticeButton {
    public enum State: String, CaseIterable, Sendable { case opening, fix, building, viewOff, preview, ready, sending, sent, refused, exports, blocked, idle }
    public enum MainAction: Equatable, Sendable { case note(FlexibleMainNote.Kind), callout, showLattice, card, sendAndCard, openSquish, none }

    /// What the main zone and the ⌃ act through (the stage's own actions — tests stand in for them).
    public struct Hooks {
        let send: () -> Void
        let showCard: () -> Void
        let showLattice: () -> Void
        let note: (FlexibleMainNote.Kind) -> Void
        let openSquish: () -> Void
        let callout: () -> Void
    }

    /// The title, never changing.
    public static let title = "Lattice"
    /// Ready's line (the status's plain "Ready" says what a tap does here).
    public static let readyLine = "Ready \u{00B7} tap to send"
    /// Exports' line (core returns no mesh yet — FlexibleCoreRun.exportsWait).
    public static let exportsLine = "Export \u{00B7} STL \u{00B7} G-code"
    /// Core said no: the one line (its whole sentence and its fixes are the card's — his rule, one line ≤ 44).
    public static let refusedLine = "Core refused it \u{00B7} \u{2303} says why"
    public static let notSentLine = "Not sent \u{00B7} \u{2303} says why"
    public static let designedLine = "Core designed it \u{00B7} \u{2303} for details"

    /// The state from the main page's status and core's last answer (`answerIsCurrent`: that answer is for the lattice on
    /// screen — an answer for an older one is not "sent").
    public static func state(_ s: FlexibleMainStatus, phase: FlexibleCoreRun.Phase, answerIsCurrent: Bool) -> State {
        switch s.tone {
        case .fix: return .fix
        case .blocked: return .blocked
        case .building:
            if s.line == FlexibleMainStatus.opening { return .opening }
            return .building
        case .idle:
            if s.line == FlexibleMainStatus.deferred { return .viewOff }
            return .idle
        case .ready, .preview:
            if phase == .sending { return .sending }
            if answerIsCurrent {
                switch phase {
                case .ran(let r): return r.refusal == nil ? .sent : .refused
                case .notSent, .failed: return .refused
                case .idle, .sending: break
                }
            }
            return s.tone == .ready ? .ready : .preview
        }
    }

    /// The ONE status line under "Lattice".
    public static func line(_ s: FlexibleMainStatus, state: State, runLine: String) -> String {
        switch state {
        case .opening: return FlexibleMainStatus.opening
        case .building: return FlexibleMainStatus.building
        case .viewOff: return FlexibleMainStatus.deferred
        case .ready: return s.line == FlexibleMainStatus.ready ? readyLine : s.line
        case .sending: return FlexibleCoreRun.sendingLine
        case .sent: return runLine.count <= 44 ? runLine : designedLine
        case .refused:
            if runLine.hasPrefix("Core refused") { return refusedLine }
            if runLine.hasPrefix("Not sent") || runLine.count > 44 { return notSentLine }
            return runLine
        case .exports: return exportsLine
        case .fix, .preview, .blocked, .idle: return s.line
        }
    }

    /// What the main zone does.
    public static func action(_ st: State) -> MainAction {
        switch st {
        case .opening: return .note(.opening)
        case .fix: return .callout
        case .building: return .note(.building)
        case .viewOff: return .showLattice
        case .preview: return .card
        case .ready: return .sendAndCard
        case .sending, .sent, .refused, .exports: return .card
        case .blocked: return .none
        case .idle: return .openSquish
        }
    }

    /// The main zone's tap.
    @MainActor static func perform(_ a: MainAction, chrome: FlexibleChromeState, hooks: Hooks) {
        switch a {
        case .note(let k): hooks.note(k)
        case .callout: chrome.show(.callout); hooks.callout()
        case .showLattice: hooks.showLattice()
        case .card: hooks.showCard(); chrome.show(.latticeCard)
        case .sendAndCard: hooks.send(); hooks.showCard(); chrome.show(.latticeCard)
        case .openSquish: chrome.foldAll(); hooks.openSquish()
        case .none: break
        }
    }

    /// The ⌃: the card, open ⇄ closed — never a send.
    @MainActor static func caret(chrome: FlexibleChromeState, hooks: Hooks) {
        if chrome.open != .latticeCard { hooks.showCard() }
        chrome.toggle(.latticeCard)
    }

    /// The button's tone for its fill and outline (today's pill's): Sent / Refused keep the status's.
    static func tone(_ s: FlexibleMainStatus, state: State) -> FlexibleMainStatus.Tone {
        state == .refused ? .fix : s.tone
    }
}

/// The split button: "Lattice" over its line | ⌃.
struct FlexibleLatticeButtonView: View {
    let status: FlexibleMainStatus
    let state: FlexibleLatticeButton.State
    let line: String
    let width: CGFloat
    let cardOpen: Bool
    let main: () -> Void
    let caret: () -> Void

    var body: some View {
        let tone = FlexibleLatticeButton.tone(status, state: state)
        let ready = tone == .ready
        HStack(spacing: 0) {
            Button(action: main) {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        if state == .building || state == .opening || state == .sending {
                            ProgressView().controlSize(.mini).tint(DS.Color.textPrimary.color)
                        }
                        if state == .fix || state == .blocked || state == .refused {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13, weight: .bold))
                                .foregroundStyle((ready ? DS.Color.textPrimary : DS.Color.warning).color)
                        }
                        Text(FlexibleLatticeButton.title).font(.system(size: 17, weight: .semibold))
                    }
                    Text(line)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(DS.Color.textPrimary.opacity(ready ? 0.88 : 0.62).color)
                        .lineLimit(1).minimumScaleFactor(0.78).truncationMode(.tail)   // (his ≤ 44-character lines read whole)
                        .accessibilityIdentifier("flexible-lattice-line")
                }
                .foregroundStyle(DS.Color.textPrimary.color)
                .padding(.horizontal, DS.Space.s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(FlexibleLatticeButton.action(state) == .none)
            .background(FlexibleCornerPairStyle.publish("latticeMain"))
            .accessibilityLabel("Lattice: \(line)")
            .accessibilityIdentifier("flexible-lattice-main")
            Rectangle().fill((ready ? DS.Color.textPrimary.opacity(0.35) : DS.Color.strokeStrong).color).frame(width: 1)
            Button(action: caret) {
                Image(systemName: cardOpen ? "chevron.down" : "chevron.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                    .frame(width: FlexibleChromeLayout.latticeCaretWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(FlexibleCornerPairStyle.publish("latticeMore"))
            .accessibilityLabel(cardOpen ? "Hide the lattice steps" : "Show the lattice steps")
            .accessibilityIdentifier("flexible-lattice-more")
        }
        .frame(width: width, height: PageChrome.actionButton)
        .background(Capsule().fill(FlexibleMainStatusPill.fill(tone).color))
        .overlay(Capsule().strokeBorder(FlexibleMainStatusPill.stroke(tone).color, lineWidth: ready ? 0 : 1.5))
        .clipShape(Capsule())
        .dsShadow(ready ? DS.Shadow.accentGlow : DS.Shadow.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-lattice")
    }
}
