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
import TopOptDesign

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

    // MARK: - the position gizmo (AE7's "always in the same place")

    /// The gizmo's edge size — `OrientationGizmoView.standardSize`, mirrored here
    /// so the placement constants below live beside it. The AE7 test asserts the
    /// two agree, so this can never drift from the view's own size.
    public static var gizmoSize: CGFloat { OrientationGizmoView.standardSize }
    /// The gizmo sits in the ABSOLUTE top-right corner with this inset on BOTH
    /// edges — the workspace's own placement (design-overhaul 109, round-2 item
    /// 4), now the shared one. Every page that shows a gizmo shows it here.
    public static let gizmoInset: CGFloat = DS.Space.s
    /// How far a page's own top-right chrome must stay clear of the gizmo so the
    /// two never overlap: the gizmo's width plus its insets.
    public static var gizmoClearance: CGFloat { gizmoSize + gizmoInset * 2 }

    // MARK: - derived

    /// Clearance a bottom-anchored panel needs above the bottom-right action
    /// cluster — DERIVED from the tokens above rather than a magic number.
    public static var panelBottomClearance: CGFloat { edge + actionButton + gap }
}
