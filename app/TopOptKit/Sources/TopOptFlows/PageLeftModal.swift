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

    public init(canvasHeight: CGFloat, actionRows: Int = 1) {
        self.canvasHeight = canvasHeight
        self.actionRows = actionRows
    }

    public func body(content: Content) -> some View {
        content
            .frame(width: PageChrome.panelWidth)
            .frame(maxHeight: PageChrome.sidePanelBand(canvasHeight: canvasHeight))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.top, PageChrome.noteTop)
            .padding(.bottom, PageChrome.edge)
            .padding(.leading, PageChrome.edge)
    }
}

extension View {
    /// ★ §6 — centre-left, vertically centred, never touching top or bottom.
    public func pageLeftModal(canvasHeight: CGFloat, actionRows: Int = 1) -> some View {
        modifier(PageLeftModal(canvasHeight: canvasHeight, actionRows: actionRows))
    }
}
