// FlexibleMainLatticeView — the main Flexible page's Lattice VIEW button, its "ready" note and
// what the big bottom Lattice button's tap does (task 2026-09-29-flexible-screens, round 4
// batch C2). His words:
//   img 5:    "there's a bit of a confusion regarding the xray and lattice view - they both seem
//              to require one another. There is no point in that. Please remove the xray view
//              selector if the lattice view is going to use the rendering anyways."
//   img 6:    "When I clicked Lattice after already having a lattice preview, it brought me to
//              the settings page and showed this screen. I don't understand why?"
//   answer 2: "the large bottom buttons are for exports and starting the actual core process. So
//              when Lattice Ready shows, tapping it should send to Core and the export path. The
//              lattice VIEW button should show/hide the lattice and a notification should show
//              up when it is ready - however, tapping it without setting up the settings should
//              take you to the settings screen where exiting should automatically show the view."
//
// ★ ONE VIEW, NOT TWO. X-ray is the Lattice view's rendering (FlexibleMainStage.xray): shown,
// the part is the ghost with the walls inside; hidden, the solid part. The row is Dent heat ·
// Stress · Lattice.
// ★ THE LATTICE BUTTON: with a lattice to show (drawn, or on its way without Settings) it shows /
// hides it; with nothing that can come (nothing pressed, no filament, a failed build …) it opens
// Settings, and that Settings' Save & Exit turns the view on.
// ★ THE NOTE: once per build this page started, when it lands — "Lattice ready", with [Show]
// when the view is hidden — ★ C2 VERIFICATION: on the view row's OWN line, left of the three
// buttons (the band C2 reserved UNDER the row pushed two legends into a second column at 13"
// landscape with his Gravity chip column, for a note that shows 4 s). The whole note is [Show]'s
// target (it was the 13 pt word). It hides itself.
// ★ THE BIG BUTTON: Ready → core and the Export step (FlexibleCoreRun); the one thing to fix →
// Settings on its pop-up; building → nothing opens (the note says it is still building) —
// ★ C2 VERIFICATION: on another stage it takes him to the Lattice stage (builds start only
// there; C2's note was drawn only there, a dead tap on Topology).

import Foundation
import SwiftUI
import TopOptDesign

/// The Lattice view's rule, as values.
public enum FlexibleLatticeView {
    public enum Tap: Equatable, Sendable { case toggle, openSettings }

    /// A lattice to show: one drawn (and current), a build in flight — or one that will come
    /// without Settings: nothing blocks and no build failed on these settings.
    public static func available(fresh: Bool, building: Bool, sceneFailed: Bool, blocked: Bool, buildFailed: Bool) -> Bool {
        if fresh || building { return true }
        return !(sceneFailed || blocked || buildFailed)
    }

    @MainActor
    public static func available(model m: FlexibleStageModel) -> Bool {
        let failed: Bool = { if case .failed = m.sceneState { return true } else { return false } }()
        let fresh = m.lattice != nil && !m.latticeIsStale
        if fresh || m.latticeBuilding { return true }
        if failed { return false }
        return available(fresh: false, building: false, sceneFailed: false,
                         blocked: !m.readiness.blocking.isEmpty, buildFailed: m.latticeFailure != nil)
    }

    public static func tap(available: Bool) -> Tap { available ? .toggle : .openSettings }
}

/// The one-line note under the view row (his "notification … when it is ready").
@MainActor
public final class FlexibleMainNote: ObservableObject {
    public enum Kind: Equatable, Sendable { case ready, building }
    @Published public private(set) var kind: Kind?
    /// How many notes were posted (tests).
    var posts = 0
    /// How long a note stays (tests shorten or lengthen it).
    var seconds: Double = 4
    private var serial = 0

    public init() {}

    public func post(_ k: Kind) {
        posts += 1
        serial &+= 1
        kind = k
        let s = serial
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.serial == s else { return }   // a newer note keeps its own time
            self.kind = nil
        }
    }

    public func clear() {
        serial &+= 1
        if kind != nil { kind = nil }
    }

    public nonisolated static func line(_ k: Kind) -> String {
        switch k {
        case .ready: return "Lattice ready"
        case .building: return "Still building \u{2014} it shows here when ready"
        }
    }
    /// The note's size: ★ C2 VERIFICATION — as tall as the row's buttons (the whole note is
    /// [Show]'s target), at most 280 wide beside them (narrower where the left panel is near).
    public static let height: CGFloat = 40
    public static let width: CGFloat = 280
}

extension FlexibleMainStage {

    /// The Lattice VIEW button (H5): show / hide the lattice — or, with nothing that can show,
    /// open Settings; its Save & Exit then turns the view on (`didExitSettings`).
    public func latticeButtonTapped(openSettings: () -> Void) {
        if let m = model { latticeAvailable = FlexibleLatticeView.available(model: m) }
        switch FlexibleLatticeView.tap(available: latticeAvailable) {
        case .toggle:
            toggleLattice()
        case .openSettings:
            showLatticeOnExit = true
            openSettings()
        }
    }

    /// The note's [Show]: the view on, the note gone.
    public func showFromNote() {
        latticeOn = true
        note.clear()
    }

    /// A build this stage started has landed (or failed): say it once.
    func noteBuildLanded(_ m: FlexibleStageModel) {
        guard awaitingReady, !m.latticeBuilding else { return }
        if m.lattice != nil, !m.latticeIsStale {
            awaitingReady = false
            note.post(.ready)
        } else if m.latticeFailure != nil {
            awaitingReady = false   // the pill says the failure
        }
    }

    /// The big bottom Lattice button (H10's pill): Ready → core and the Export step; the one
    /// thing to fix → Settings on its pop-up; building → nothing opens (his img 6), the note says
    /// it is still building. ★ C2 VERIFICATION: `goToLattice` (H10) — on another stage "Building…"
    /// takes him to the Lattice stage (builds start only there), and so does a Ready whose
    /// lattice his edits there have made stale (`sendToCore`).
    public func pillTapped(_ s: FlexibleMainStatus, open: () -> Void, goToLattice: @escaping () -> Void = {}) {
        self.goToLattice = goToLattice
        switch s.tap {
        case .send:
            sendToCore()
        case .openSettings:
            if s.fix != nil { openFix() }
            open()
        case .wait:
            if !visible { goToLattice() }
            note.post(.building)
        }
    }
}

extension FlexibleMainViewToggles {
    /// The note's band: ★ C2 VERIFICATION — on the row's own line, left of the three buttons, clear
    /// of the left panel (inside `frame`, which every legend and the player keep out of — and
    /// which now ends where the row ends, so the note costs the legends nothing).
    public static func noteFrame(viewport: CGSize) -> CGRect {
        let row = rowFrame(viewport: viewport)
        let room = row.minX - DS.Space.s - (FlexibleMainLegendLayout.leftStrip(viewport: viewport).maxX + DS.Space.s)
        let w = max(0, min(FlexibleMainNote.width, room))
        return CGRect(x: row.minX - DS.Space.s - w, y: row.midY - FlexibleMainNote.height / 2,
                      width: w, height: FlexibleMainNote.height)
    }
}

/// The note, drawn beside the view row. It observes only the note (and the stage's view flag).
struct FlexibleMainNoteView: View {
    @ObservedObject var note: FlexibleMainNote
    @ObservedObject var main: FlexibleMainStage
    /// Its band's width (FlexibleMainViewToggles.noteFrame).
    var maxWidth: CGFloat = FlexibleMainNote.width

    var body: some View {
        if let k = note.kind {
            let showable = k == .ready && !main.latticeShown
            Group {
                if showable {
                    // ★ C2 VERIFICATION: the WHOLE note is [Show] (the word alone was ~36 × 16 pt)
                    Button { main.showFromNote() } label: { capsule(k, showable: true) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-main-note-show")
                } else {
                    capsule(k, showable: false)
                }
            }
            .latticeBandChipKeepOut()
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .transition(.opacity)
        }
    }

    private func capsule(_ k: FlexibleMainNote.Kind, showable: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: k == .ready ? "checkmark.circle.fill" : "hourglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle((k == .ready ? FlexibleStageStyle.accentToken : DS.Color.textSecondary).color)
            Text(FlexibleMainNote.line(k))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityIdentifier("flexible-main-note")
            if showable {
                Text("Show")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Color.accent.color)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: FlexibleMainNote.height)
        .background(Capsule().fill(DS.Surface.panel.color.opacity(0.94))
            .overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .contentShape(Capsule())
    }
}
