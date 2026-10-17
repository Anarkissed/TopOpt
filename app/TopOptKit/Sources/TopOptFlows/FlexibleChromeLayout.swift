// FlexibleChromeLayout — the main Flexible page's frames after the redesign (task 2026-09-29-flexible-screens, round 7,
// batch R7-D1: his pick 1, "I like A2 but with the corner pair from A1 on the main Lattice screen").
//
// PURE, so FlexibleChromeLayoutTests measures it on the iPads he uses (13", 11", the mini; both orientations), and the
// views draw what it says. The numbers are the mockup's "Your pick" (config pk), which he chose:
//   * the CAPSULE "● Flexible ⌄ | Lattice | Squish" under the project name, at #354's own StageNavPlacement for the lattice
//     stage (x 24, top 22 + 42 + 12 = 76; H27 applies that modifier, a source pin keeps the two equal), 44 tall;
//   * the VIEWS row under the gizmo: six 44 pt icons 8 apart, one line (304) — three over three on the mini in portrait;
//   * the CORNER PAIR on the bottom-right corner, on 24/24: the Setup chip (48 tall, at most 240) and 12 pt right of it the
//     Lattice split (64 tall, 260 wide);
//   * its PANELS (the tray, the card, the callout) 12 above the pair, right-aligned on 24, 420 wide (336 on the mini: 12 pt
//     clear of the Selections panel's 24 + 348), as tall as their content but never above the views row's foot + 12 —
//     past that the body scrolls.
//   ★ LOOKED AT on the mini (2026-10-17): the 240 split and the 336 panels as first drawn cut his words — "Fa… Bal…" for
//     Quality, "+Z · assu…", "Print paramet…", "Send Group 2 only, Face 2 re…", "Export G-/code" on two lines, "Preview ·
//     core runs one group at a ti…" — against his rule (one line per setting, whole). The split takes 260 there too (the
//     Setup chip keeps 46 pt from the minimised pill); the panels keep 336 (wider would cover the Selections panel) and lay
//     their rows out for it: the tray's titles take their own width, the card's step bodies go under their titles.
// His img5 (2026-10-14): "When 'Selections' is minimized it touches the 'iPad' chip. Please ensure that the all chips are
// separated by equal padding between them." — the minimised Selections pill keeps ≥ 12 from the Setup chip everywhere.

import CoreGraphics
import TopOptDesign

public enum FlexibleChromeLayout {

    // MARK: the capsule (A2)

    /// #354's StageNavPlacement, the lattice stage: the identity row's top inset + its 42 pt + one gap.
    public static let capsuleTop: CGFloat = DS.Space.xl3 + 42 + PageChrome.gap
    public static let capsuleLeft: CGFloat = DS.Space.xl4
    public static let capsuleHeight: CGFloat = 44
    /// The capsule's widest ("● Flexible ⌄ | Lattice | Squish" is ~280 pt).
    public static let capsuleMaxWidth: CGFloat = 300
    /// The page segments inside it: 36 tall, 4 pt in.
    public static let segmentHeight: CGFloat = 36
    public static let segmentInset: CGFloat = 4

    public static func capsuleFrame(width: CGFloat) -> CGRect {
        CGRect(x: capsuleLeft, y: capsuleTop, width: min(width, capsuleMaxWidth), height: capsuleHeight)
    }

    // MARK: the views row

    /// His rule: 44 pt targets. The icons are drawn that size.
    public static let viewButton: CGFloat = 44
    public static let viewsGap: CGFloat = DS.Space.s

    /// The views row (FlexibleMainViewToggles draws it here): one line of six on the right edge under the gizmo, or three
    /// over three on a pad narrower than 800 pt (the mini in portrait).
    public static func viewsRow(viewport v: CGSize) -> CGRect {
        let n = FlexibleMainViewToggles.buttons
        let c = viewsColumns(viewport: v), r = (n + c - 1) / c
        let w = CGFloat(c) * viewButton + CGFloat(c - 1) * viewsGap
        let h = CGFloat(r) * viewButton + CGFloat(r - 1) * viewsGap
        return CGRect(x: v.width - PageChrome.edge - w, y: PageChrome.belowGizmo, width: w, height: h)
    }
    /// The icons per line: six, or three below 800 pt wide (the mockup's rule).
    public static func viewsColumns(viewport v: CGSize) -> Int {
        let n = FlexibleMainViewToggles.buttons
        return v.width < 800 ? (n + 1) / 2 : n
    }

    // MARK: the corner pair (A1)

    public static let setupHeight: CGFloat = PageChrome.compactButton
    public static let setupMaxWidth: CGFloat = 240
    /// ★ LOOKED AT (measured: FlexibleRound7FitHostedTests): 44, his target size — at 52 the main zone cut core's 44-character
    /// "Core designed it · Gyroid · 230 °C · 3 faces" by 3 pt.
    public static let latticeCaretWidth: CGFloat = 44
    public static let pairGap: CGFloat = PageChrome.gap
    /// The panels' gap above the pair.
    public static let panelGap: CGFloat = PageChrome.gap

    /// The mini (744 × 1133): its shorter side is under 800 pt.
    public static func isMini(_ v: CGSize) -> Bool { min(v.width, v.height) < 800 }

    /// ★ LOOKED AT: 260 on every pad, the mini too (240 cut its line).
    public static func latticeButtonSize(_ v: CGSize) -> CGSize {
        CGSize(width: 260, height: PageChrome.actionButton)
    }

    /// The pair on the corner, bottoms aligned (#354's bar: an HStack aligned .bottom, 24 in from the trailing and bottom
    /// edges).
    public static func pair(viewport v: CGSize, setupWidth: CGFloat) -> (setup: CGRect, lattice: CGRect) {
        let ls = latticeButtonSize(v)
        let lattice = CGRect(x: v.width - PageChrome.edge - ls.width, y: v.height - PageChrome.edge - ls.height,
                             width: ls.width, height: ls.height)
        let w = min(setupWidth, setupMaxWidth)
        let setup = CGRect(x: lattice.minX - pairGap - w, y: v.height - PageChrome.edge - setupHeight, width: w, height: setupHeight)
        return (setup, lattice)
    }

    // MARK: the panels above it

    public static func panelWidth(_ v: CGSize) -> CGFloat { isMini(v) ? 336 : PageChrome.receiptDrawerWidth }
    /// A panel this narrow lays its rows out for it (the tray's titles their own width, the card's bodies under the titles).
    public static func panelIsNarrow(_ width: CGFloat) -> Bool { width < PageChrome.receiptDrawerWidth }

    /// A panel never rises above the views row's foot + 12.
    public static func panelTopLimit(_ v: CGSize) -> CGFloat { viewsRow(viewport: v).maxY + panelGap }

    /// The tallest a panel may be on this pad.
    public static func panelMaxHeight(_ v: CGSize) -> CGFloat {
        max(0, v.height - PageChrome.edge - PageChrome.actionButton - panelGap - panelTopLimit(v))
    }

    /// A panel of `contentHeight`: right-aligned on 24, its foot 12 above the pair, its top no higher than the limit (then
    /// its body scrolls).
    public static func panel(viewport v: CGSize, setupWidth: CGFloat, contentHeight: CGFloat) -> (frame: CGRect, scrolls: Bool) {
        let bottom = pair(viewport: v, setupWidth: setupWidth).lattice.minY - panelGap
        let maxH = panelMaxHeight(v)
        let h = min(contentHeight, maxH)
        let w = panelWidth(v)
        return (CGRect(x: v.width - PageChrome.edge - w, y: bottom - h, width: w, height: h), contentHeight > maxH)
    }

    // MARK: ★ the review of R7-D1 (stubs: tests first)

    /// The bar's clearance on this stage: the corner pair (64) and its 24 pt inset (#354's bottomBarClearance).
    public static let barClearance: CGFloat = PageChrome.actionButton + PageChrome.edge
    /// The name row and the capsule under it (top-left, up to the gizmo's clearance).
    public static func topLeftChrome(_ v: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: max(0, v.width - PageChrome.gizmoClearance), height: capsuleTop + capsuleHeight)
    }
    public static func panelTopLimit(_ v: CGSize, legend: CGRect?) -> CGFloat { panelTopLimit(v) }
    public static func panelMaxHeight(_ v: CGSize, legend: CGRect?) -> CGFloat { panelMaxHeight(v) }
    public static func panelFrame(viewport v: CGSize, contentHeight: CGFloat, legend: CGRect?) -> CGRect {
        panel(viewport: v, setupWidth: 0, contentHeight: contentHeight).frame
    }

    // MARK: the minimised Selections pill (#354's PageLeftModal: bottom-left, on `edge`)

    public static let selectionsPillHeight: CGFloat = 44

    public static func selectionsPill(viewport v: CGSize, width: CGFloat) -> CGRect {
        CGRect(x: PageChrome.edge, y: v.height - PageChrome.edge - selectionsPillHeight, width: width, height: selectionsPillHeight)
    }

    /// RED CONTROL only: today's bar on the Flexible stage — `widths` right to left as drawn ([iPad][Print Parameters]
    /// [Lattice][Optimize] in reading order), `spacing` apart, trailing on `edge`.
    public static func todaysBar(viewport v: CGSize, widths: [CGFloat], spacing: CGFloat) -> [CGRect] {
        var x = v.width - PageChrome.edge
        var out: [CGRect] = []
        for w in widths.reversed() {
            x -= w
            out.insert(CGRect(x: x, y: v.height - PageChrome.edge - selectionsPillHeight, width: w, height: selectionsPillHeight), at: 0)
            x -= spacing
        }
        return out
    }
}
