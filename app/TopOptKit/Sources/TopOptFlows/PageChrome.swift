// PageChrome.swift — THE ONE chrome geometry every full-screen page shares
// (handoff 2026-08-02-smoothing-page, bar AE7).
//
// WHY THIS FILE EXISTS. The maintainer's round-3 feedback on the lattice page was
// that "all the buttons feel different" and that the position gizmo must ALWAYS
// sit in the same place on every page. The lattice page answered the first half
// for itself with `LatticeChromeLayout` — one spacing token, named per seam. But a
// per-page constant set only guarantees a page is consistent with ITSELF; the
// third page is exactly where a third look gets invented.
//
// So the numbers move here, once, and `LatticeChromeLayout` becomes a view onto
// them rather than a second copy. A page cannot pick its own button height or its
// own gizmo corner without editing a constant three pages read — which is what the
// AE7 test pins, both by value and by reading the sources for the token names.
//
// NOTHING HERE IS NEW GEOMETRY. Every value is the number the workspace and the
// lattice page already use; this file only gives them one home.

import CoreGraphics
import Foundation
import TopOptDesign

/// THE TRANSIENT TOP-CENTRE NOTE, for every full-screen page (task
/// 2026-08-04-smoothing-viewer-and-ui, bar U5).
///
/// THE THIRD ASK. The maintainer has now asked three times for the same thing:
/// round-3 lattice feedback, then the lattice page (which got `LatticeTransientNote`),
/// and now the smoothing page, which had drifted into THREE overlapping notices
/// stacked at the top of the screen at once. The first two answers were local, so
/// the third page had nothing to inherit and invented its own.
///
/// The rule, in one place, so a fourth page inherits it:
///
///   1. ONE AT A TIME. Posting replaces whatever is up; there is no stack.
///   2. TOP-CENTRE, and never underneath the left panel — `SmoothingPage` and
///      `LatticePage` both mount it in their top-centre column, which the panel
///      does not reach into in either orientation (asserted from the tokens).
///   3. AUTO-DISMISSING after at most `lifetime`, and dismissible by tap before
///      that.
///
/// `LatticeTransientNote` is an alias, so the lattice page and its tests keep
/// their exact names and behaviour while there is only one definition.
public struct PageTransientNote: Equatable, Sendable {
    public let text: String
    public let postedAt: Date
    public init(text: String, postedAt: Date) {
        self.text = text
        self.postedAt = postedAt
    }
    /// How long a note lives without interaction. The maintainer's ceiling is 60 s
    /// ("auto-dismissing after at most 60 seconds"), and this is that number for
    /// every page at once.
    public static let lifetime: TimeInterval = 60
    public func expired(now: Date) -> Bool {
        now.timeIntervalSince(postedAt) >= Self.lifetime
    }
}

/// One note, posted / dismissed / expired by the same three calls on every page.
/// A `struct` the page models hold, rather than three copies of the same three
/// methods.
public struct PageNoteBox: Equatable, Sendable {
    public private(set) var note: PageTransientNote?
    public init() {}

    /// Post a note. A different note REPLACES the current one (rule 1); posting
    /// the same text refreshes its clock.
    public mutating func post(_ text: String, now: Date = Date()) {
        note = PageTransientNote(text: text, postedAt: now)
    }
    /// Tap-to-dismiss (rule 3).
    public mutating func dismiss() { note = nil }
    /// Expire after the lifetime (rule 3). The view calls this on a timer; tests
    /// call it with an explicit clock.
    public mutating func tick(now: Date = Date()) {
        if let n = note, n.expired(now: now) { note = nil }
    }
}

/// ONE NOTE AT A TIME, AND THE REST WAIT THEIR TURN (task 2026-08-05, bar D5c).
///
/// `PageNoteBox` above answers "one note", by replacement: a second post
/// overwrites the first, which loses it. The maintainer's screenshots show why
/// that is not enough — several single-line notes on screen at once, overlapping
/// each other and the chrome — and his rule is a QUEUE: one visible, the others
/// behind it, each for a minute, each dismissible, and none of them shown late.
///
/// THE STALENESS RULE IS THE INTERESTING HALF. A note that has waited its turn
/// may be describing a state the user has already left ("nothing painted yet",
/// after he painted). Showing it then is worse than not showing it at all, so a
/// queued note is re-resolved at the moment it would become visible and DROPPED
/// if its topic no longer says anything. Notes with no topic (`""`) are plain
/// news — an outcome that happened — and are never stale.
public struct PageNoteQueue: Equatable, Sendable {

    /// A note waiting its turn: what it said when it was posted, and the TOPIC
    /// whose current answer decides whether it is still worth saying.
    public struct Entry: Equatable, Sendable {
        public let topic: String
        public let text: String
        public init(topic: String, text: String) {
            self.topic = topic
            self.text = text
        }
    }

    public private(set) var visible: PageTransientNote?
    /// The topic of the visible note, so a re-post of the same topic refreshes it
    /// rather than queueing a duplicate behind itself.
    public private(set) var visibleTopic: String = ""
    public private(set) var queued: [Entry] = []

    public init() {}

    public var note: PageTransientNote? { visible }
    public var depth: Int { queued.count }

    /// Post a note. Shown immediately when the band is free, queued otherwise.
    /// A post on the topic that is already visible REPLACES its text in place
    /// (the state it describes moved on) without restarting anything else.
    public mutating func post(_ text: String, topic: String = "",
                              now: Date = Date()) {
        if visible != nil, !topic.isEmpty, topic == visibleTopic {
            visible = PageTransientNote(text: text, postedAt: visible!.postedAt)
            return
        }
        guard visible != nil else {
            visible = PageTransientNote(text: text, postedAt: now)
            visibleTopic = topic
            return
        }
        if !topic.isEmpty, let i = queued.firstIndex(where: { $0.topic == topic }) {
            queued[i] = Entry(topic: topic, text: text)
        } else {
            queued.append(Entry(topic: topic, text: text))
        }
    }

    /// Dismiss the visible note (the ✕, or the page tearing it down) and promote
    /// the next one that is still true.
    public mutating func dismiss(now: Date = Date(),
                                 resolve: (String) -> String? = { _ in nil }) {
        visible = nil
        visibleTopic = ""
        promote(now: now, resolve: resolve)
    }

    /// Expire the visible note after `PageTransientNote.lifetime`, then promote.
    public mutating func tick(now: Date = Date(),
                              resolve: (String) -> String? = { _ in nil }) {
        if let v = visible, v.expired(now: now) {
            visible = nil
            visibleTopic = ""
            promote(now: now, resolve: resolve)
        }
    }

    /// Drop everything — the page is resetting (Discard).
    public mutating func clear() {
        visible = nil
        visibleTopic = ""
        queued.removeAll()
    }

    private mutating func promote(now: Date, resolve: (String) -> String?) {
        while !queued.isEmpty {
            let next = queued.removeFirst()
            if next.topic.isEmpty {
                visible = PageTransientNote(text: next.text, postedAt: now)
                visibleTopic = ""
                return
            }
            // STALE ⇒ DROPPED, never shown late.
            guard let current = resolve(next.topic) else { continue }
            visible = PageTransientNote(text: current, postedAt: now)
            visibleTopic = next.topic
            return
        }
    }
}

public enum PageChrome {

    // MARK: - spacing

    /// The ONE gap between adjacent chrome elements on a full-screen page.
    /// Larger than the old chip stack's 9 pt, smaller than the old
    /// Preview→Optimize 16 pt (the lattice page's round-2 choice, kept).
    public static let gap: CGFloat = 12

    /// Screen-edge margin — the value of `DS.Space.xl4`, named here so a page's
    /// edge inset and the derived clearances come from one place.
    public static let edge: CGFloat = 24

    /// Top inset of the first chrome row — the value of `DS.Space.xl3`.
    public static let topInset: CGFloat = 22

    // MARK: - button sizing (the "all the buttons feel different" fix)

    /// A round icon button (back / undo / redo): 52 × 52.
    public static let circleButton: CGFloat = 52
    /// A bar/pill row's height (title bar, RUN SIM, primary controls): 52 → the
    /// same square the circle buttons occupy, so a row of mixed shapes lines up.
    public static let barHeight: CGFloat = 52
    /// A big two-line action button in the bottom-right cluster: 64 tall.
    public static let actionButton: CGFloat = 64
    /// A compact secondary control (segment, toggle chip): 48 tall.
    public static let compactButton: CGFloat = 48
    /// A read-only status/attribution bar: 40 tall.
    public static let infoBar: CGFloat = 40
    /// The side panel's width.
    public static let panelWidth: CGFloat = 348
    /// The bottom-right receipt drawer's width (bar U4). Wider than the side
    /// panel because the receipt is a three-column table, and it opens over the
    /// page's own empty right-hand space rather than over the model.
    public static let receiptDrawerWidth: CGFloat = 420

    // MARK: - the position gizmo (AE7's "always in the same place")

    /// The gizmo's edge size — `OrientationGizmoView.standardSize`, mirrored here
    /// so the placement constants below live beside it. The AE7 test asserts the
    /// two agree, so this can never drift from the view's own size.
    public static var gizmoSize: CGFloat { OrientationGizmoView.standardSize }
    /// ★ THE GIZMO'S FRAME INSET — DERIVED, SO ITS *GLASS* LANDS ON `edge`.
    ///
    /// The gizmo sits in the top-right corner (design-overhaul 109, round-2 item 4),
    /// and this is the inset of its FRAME on both edges. It used to be `DS.Space.s`
    /// (8) flat, which put the frame at 8 and therefore the visible housing at 18.5
    /// — while the bottom-right chip stack sits on `edge` (24) and the view toggles
    /// sat on 8. Three different right-hand edges on one screen.
    ///
    /// Maintainer, 2026-08-16: "the view buttons are too close to the edge. Please
    /// put them in-line with the gizmo and all the chips at the bottom-right corner.
    /// The padding to the right needs to be *exactly* the same … I am very
    /// particular about keeping things lined up perfectly."
    ///
    /// So the FRAME inset is now whatever puts the GLASS on `edge`. Everything
    /// visible on the right-hand side then shares one number, top and side alike —
    /// see `gizmoAlignedTop`, which reduces to `edge` for the same reason.
    public static var gizmoInset: CGFloat { edge - gizmoVisualInset }
    /// How far a page's own top-right chrome must stay clear of the gizmo so the
    /// two never overlap: the gizmo's width plus its insets.
    public static var gizmoClearance: CGFloat { gizmoSize + gizmoInset * 2 }

    /// ★ HOW FAR THE GIZMO'S *VISIBLE* TOP SITS BELOW ITS FRAME'S TOP.
    ///
    /// The widget's frame is `gizmoSize` square, but the frosted housing a user
    /// actually sees is `GizmoLayout.housingFraction` (0.90) of that and CENTRED —
    /// so there is a transparent margin of `(1 − 0.90) / 2` all round, about 10.5 pt
    /// at the standard 210.
    ///
    /// ★ AND THAT MARGIN IS WHY THE TOP BUTTONS LOOKED HIGH. They padded down by
    /// `gizmoInset`, exactly as the gizmo's FRAME does — so their tops lined up with
    /// a frame edge that is invisible, and sat ~10 pt above the glass edge beside
    /// them. Correct arithmetic against the wrong edge. Maintainer, 2026-08-16: "the
    /// 'Save' button is too high. The top of the button needs to be in-line with the
    /// top of the gizmo. I also noticed the 'Lattice' button is too high as well."
    public static var gizmoVisualInset: CGFloat {
        gizmoSize * (1 - GizmoLayout.housingFraction) / 2
    }

    /// The top padding for chrome that must line up with the gizmo's visible top
    /// edge. Every top-right control uses this rather than `gizmoInset`, so they
    /// cannot drift apart one page at a time.
    ///
    /// With `gizmoInset` derived from `edge`, this reduces to `edge` — the gizmo's
    /// glass is the same distance from the top as from the side, and so is
    /// everything aligned to it.
    public static var gizmoAlignedTop: CGFloat { gizmoInset + gizmoVisualInset }

    /// ★ THE TOP INSET FOR A CONTROL THAT SITS *UNDER* THE GIZMO.
    ///
    /// Two things have to be true and they do not give the same number:
    ///
    ///   * it must clear the gizmo's FRAME, because the frame is what takes the
    ///     orbit gesture (`contentShape(Rectangle())` over the full square) — a
    ///     control overlapping it would be un-tappable in its top strip;
    ///   * it should read as one `gap` below the gizmo's GLASS, which is what the
    ///     eye measures from.
    ///
    /// The frame is the larger, so it decides — and the remaining distance from the
    /// glass then lands within a couple of points of `edge`, which is why this
    /// looks even rather than merely being safe. Taking the glass alone would leave
    /// 1.5 pt of the gizmo's own touch target underneath the control.
    public static var belowGizmo: CGFloat {
        max(gizmoInset + gizmoSize,                       // clear the touch target
            gizmoAlignedTop + gizmoSize - gizmoVisualInset * 2)  // …and the glass
            + gap
    }

    // MARK: - derived

    /// Clearance a bottom-anchored panel needs above a bottom-right action
    /// cluster of `actionRows` rows — DERIVED from the tokens above rather than a
    /// magic number.
    ///
    /// THE ROW COUNT IS A PARAMETER because the smoothing page's cluster became
    /// TWO rows (bar U3 put Discard and Lattice this above Re-certify), and the
    /// one-row constant left its portrait panel running underneath them. A
    /// clearance that silently assumes one row is a clearance that stops being
    /// one the moment a page adds a button.
    public static func panelBottomClearance(actionRows: Int) -> CGFloat {
        edge + (actionButton + gap) * CGFloat(max(actionRows, 1))
    }

    /// The one-row case — the lattice page's cluster, and this token's original
    /// value, unchanged.
    public static var panelBottomClearance: CGFloat {
        panelBottomClearance(actionRows: 1)
    }

    /// THE BAND A CENTRED SIDE PANEL MAY OCCUPY in landscape (task 2026-08-05,
    /// bar D3): everything below the identity rows and above the bottom edge.
    ///
    /// The smoothing page used `height − 200` — a number with no relationship to
    /// what is actually on the screen — and then centred the panel in the FULL
    /// height, which put its top edge over the run-identity bars. Deriving the
    /// band from the same tokens the rows are built from is what makes "the panel
    /// cannot cover the identity" a property of the layout rather than of how
    /// tall the panel happens to be today.
    public static func sidePanelBand(canvasHeight: CGFloat) -> CGFloat {
        max(canvasHeight - noteTop - edge, 0)
    }

    /// The height of a page's top-left identity stack: the title bar, then the
    /// "working on" bar, then the load-case bar, with a gap between each.
    public static var topRowsHeight: CGFloat {
        barHeight + gap + infoBar + gap + infoBar
    }

    /// WHERE THE TOP-CENTRE NOTE SITS (task 2026-08-04, bars U5/B4).
    ///
    /// Not at `topInset`. A note centred in the FULL width shares that row with
    /// the top-left identity stack and the top-right tabs, and on a portrait iPad
    /// — 1024 pt wide, with a 620 pt note — the three do not fit: the note lands
    /// on top of the title bar and the tabs, which is one of the overlaps the
    /// maintainer has been reporting.
    ///
    /// Dropping it BELOW those rows makes the clearance a property of the layout
    /// rather than of the canvas width: there is nothing else on that band at any
    /// size, in either orientation, so no width can make them collide.
    public static var noteTop: CGFloat { topInset + topRowsHeight + gap }

    /// How wide a top-centre note may be on a canvas `width` points across.
    ///
    /// The gizmo is 210 pt square and sits in the absolute top-right corner, so a
    /// note centred in the full width has to stop short of `gizmoClearance` on
    /// BOTH sides to stay centred and stay clear. On a portrait iPad that binds
    /// (1024 − 2 × 226 = 572, under the 620 cap); on a landscape one it does not.
    /// Derived rather than picked, so a different gizmo size cannot silently
    /// reintroduce the overlap.
    public static func noteWidth(for width: CGFloat, cap: CGFloat) -> CGFloat {
        max(min(cap, width - gizmoClearance * 2), 0)
    }
}
