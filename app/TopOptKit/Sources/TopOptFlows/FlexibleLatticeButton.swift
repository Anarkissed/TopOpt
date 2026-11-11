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
// ★ THE ⌃ ZONE (44 wide — 52 until look-and-fix 3): opens or closes the card and NEVER runs anything.
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
    /// ★ B9 (J-1, round 2: "joints should come last"; the mockup's #flex-built): once core has made the lattice (Sent) the
    /// main button is Export part — its tap opens the card on its Export step, as Sent's always did — and where the part
    /// prints in pieces its line says the Print plan comes next. Every other state keeps "Lattice".
    public static let exportTitle = "Export part"
    public static let nextPrintPlan = "Next: the Print plan"
    public static func shownTitle(_ st: State) -> String { st == .sent ? exportTitle : title }
    public static func shownLine(_ line: String, state st: State, printPlanNext: Bool) -> String {
        st == .sent && printPlanNext ? nextPrintPlan : line
    }
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

    /// ★ B9 LOOK (his "look per screen"; §4.6 / §4.18, the mockup's #flex-lattice corner): the shared run button — "Lattice"
    /// over its line, never cut (it grows past 250 pt to the line: core's 44 characters make 272) — and the shared 64 pt ⌃,
    /// 12 pt apart; the same actions (`main`, `caret`) and frames ("latticeMain", "latticeMore"). `width` is the old split's
    /// slot (the run button sizes itself now).
    var body: some View {
        let title = FlexibleLatticeButton.shownTitle(state)   // ★ B9 (J-1): Export part once the lattice is made
        HStack(spacing: DSParts.cornerGap) {
            DSRunButton(title, subtitle: line, state: Self.runState(status, state: state, line: line),
                        key: "latticeMain", action: main)
                .background(FlexibleCornerPairStyle.publish("latticeMain"))
                .background(FlexibleCornerPairStyle.publish("latticeTitle:" + title))
                .accessibilityLabel("\(title): \(line)")
            DSSplitButton(key: "latticeMore", action: caret)
                .background(FlexibleCornerPairStyle.publish("latticeMore"))
                .accessibilityLabel(cardOpen ? "Hide the lattice steps" : "Show the lattice steps")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-lattice")
    }

    /// The run button's state for the Lattice button's: a ring while it opens, builds or sends; grey (and still tappable —
    /// the fix, the card) unless it is ready; greyed out only where a tap does nothing (blocked: no face-prism).
    static func runState(_ s: FlexibleMainStatus, state: FlexibleLatticeButton.State, line: String) -> DSRunButton.State {
        switch state {
        case .opening, .building, .sending: return .running(line)
        default: break
        }
        if FlexibleLatticeButton.action(state) == .none { return .disabled(line) }
        return FlexibleLatticeButton.tone(s, state: state) == .ready ? .ready : .grey(line)
    }
}
