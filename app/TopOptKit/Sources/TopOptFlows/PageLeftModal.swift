// PageLeftModal.swift — ★ THE MODAL GEOMETRY STANDARD, ON EVERY PAGE
// (task 2026-08-14-lattice-separation §6).
//
// ★ HIS WORDS: "EVERY page should always look the same with the modal that is in
// the center of the left side and doesn't reach the top or bottom."
//
// The smoothing page already did this and derived the band from the chrome tokens
// (`PageChrome.sidePanelBand`, bar D3) — but it did it in its own body, so the
// lattice settings modal ran the full height and the workspace's Selections panel
// hung off the bottom-left corner. A rule stated once inside one page is a rule
// the next page does not inherit; this is that rule as a modifier, so a page gets
// it by asking for it rather than by copying three lines correctly.
//
// THE GEOMETRY, derived rather than picked:
//   width    `PageChrome.panelWidth`
//   top      `PageChrome.noteTop` — below the identity rows, so a modal can never
//            cover the run identity
//   bottom   `PageChrome.edge`
//   height   at most the band between those two; the content hugs, and only a
//            modal that outgrew the band scrolls INSIDE it
//   position vertically CENTRED in that band, hard against the leading edge inset

import SwiftUI
import TopOptDesign

public struct PageLeftModal: ViewModifier {
    /// The canvas height the band is derived from.
    public let canvasHeight: CGFloat
    /// How many rows the page's bottom-right action cluster has, so a modal in a
    /// short canvas still clears them.
    public let actionRows: Int
    /// ★ MINIMIZED ⇒ OUT OF THE WAY, BOTTOM-LEFT (maintainer, 2026-08-17: "make
    /// the 'selections' modal minimize and *move to the bottom left* to be out of
    /// the way").
    ///
    /// ★ THIS REFINES §6 RATHER THAN REVERSING IT. His earlier standard — "EVERY
    /// page should always look the same with the modal that is in the center of
    /// the left side and doesn't reach the top or bottom" — is what an OPEN modal
    /// still does, unchanged, on every page. The new instruction is about the
    /// minimized state, which §6 never described: a collapsed header has no body
    /// to centre, and centring it leaves a stub floating in the middle of the
    /// canvas with nothing under it. Tucked to the bottom edge it is where a
    /// minimized thing belongs and stops covering the model.
    public let minimized: Bool
    /// The canvas WIDTH, so the minimized rest position can tell portrait from
    /// landscape. See `minimizedBottomInset`.
    public let canvasWidth: CGFloat

    public init(canvasHeight: CGFloat, actionRows: Int = 1,
                minimized: Bool = false, canvasWidth: CGFloat = 0) {
        self.canvasHeight = canvasHeight
        self.actionRows = actionRows
        self.minimized = minimized
        self.canvasWidth = canvasWidth
    }

    /// ★ HOW FAR ABOVE THE BOTTOM A MINIMIZED PANEL RESTS (maintainer,
    /// 2026-08-17).
    ///
    /// ★ HIS RULE, AND THE REASON FOR IT: "with these all moving to the left,
    /// there won't be any room for the Selections minimize to fit at the bottom
    /// left corner, exactly. So, please put it just above the bottom left corner,
    /// giving enough padding below it to not feel too cluttered. This is only
    /// when it is in portrait. In Landscape mode, there should be more than
    /// enough room for it to be at the bottom-left corner."
    ///
    /// So this is not a taste value — it is clearance for the action row that
    /// now holds BOTH `Lattice` and `Optimize`. In landscape that row does not
    /// reach the leading edge and the corner is free.
    public static let minimizedPortraitLift: CGFloat = 76

    var isLandscape: Bool { canvasWidth > canvasHeight }

    var minimizedBottomInset: CGFloat {
        PageChrome.edge + (minimized && !isLandscape ? Self.minimizedPortraitLift : 0)
    }

    public func body(content: Content) -> some View {
        content
            .frame(width: PageChrome.panelWidth)
            .frame(maxHeight: PageChrome.sidePanelBand(canvasHeight: canvasHeight))
            // ★★ THE PADDINGS COME BEFORE THE EXPANDING FRAME, AND THAT ORDER IS
            // THE WHOLE BUG (maintainer, 2026-08-17: "The Selections doesn't
            // minimize to the bottom left corner yet").
            //
            // They used to be applied AFTER `.frame(maxHeight: .infinity)`, which
            // pads a view that is already the size of its parent — so the padded
            // result OVERFLOWS the parent and SwiftUI centres the overflow. The
            // alignment was correct and had no effect, which is why setting it to
            // `.bottomLeading` changed nothing on screen. Padding first, then
            // expand, and the alignment finally means something.
            .padding(.top, minimized ? 0 : PageChrome.noteTop)
            .padding(.bottom, minimizedBottomInset)
            .padding(.leading, PageChrome.edge)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: minimized ? .bottomLeading : .leading)
    }
}

extension View {
    /// ★ §6 — centre-left, vertically centred, never touching top or bottom.
    public func pageLeftModal(canvasHeight: CGFloat, actionRows: Int = 1,
                              minimized: Bool = false,
                              canvasWidth: CGFloat = 0) -> some View {
        modifier(PageLeftModal(canvasHeight: canvasHeight, actionRows: actionRows,
                               minimized: minimized, canvasWidth: canvasWidth))
    }
}
