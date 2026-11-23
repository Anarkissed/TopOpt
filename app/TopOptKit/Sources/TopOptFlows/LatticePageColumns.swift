// LatticePageColumns.swift — ★ his iPad notes 2026-11-23 (img 3, the Lattice page's 40 mm cube sample):
//   "The background of the sample should expand to the rest of the screen behind everything - rather than just stopping and
//    having a black bar on top and on the left side."
//   "The named Group names on the left side has too small an area. Please allow the left column to expand automatically a
//    little bit so that it doesn't feel crowded"
//
// The sample's 3D view now fills the whole page behind the panel and the top rows (its floor, grid and colour edge to edge);
// the picture itself is drawn in the part of the page the panel leaves free (OrbitCamera.frameRegion), framed exactly as it
// was. The panel's left column (Part · each group) widens by itself to its longest name on one line, up to `tabsMost`; a
// longer name wraps inside it as before. The panel widens with it, so the settings beside it keep their room.
import CoreText
import Foundation
import SwiftUI

enum LatticePageColumns {
    /// The most the left column widens to (a name longer than this wraps, never cut).
    static let tabsMost: CGFloat = 104
    /// A tab's name size (DSFolderTabs) and the room around a name in the column: its 6 pt sides, the tab's 4 pt sides, and
    /// a little air so it never reads crowded.
    static let titleSize: CGFloat = 10.5
    static let titleRoom: CGFloat = 2 * 6 + 2 * 4 + 6
    /// RED CONTROL (LatticePageNotes1123Tests): the column stays 62 pt (release 15).
    @MainActor static var controlFixedColumn = false

    /// The column's width for these names: the longest on one line, between the old 62 pt and `tabsMost`.
    @MainActor static func tabsWidth(_ titles: [String]) -> CGFloat {
        guard !controlFixedColumn else { return DSParts.tabsWidth }
        let widest = titles.map { textWidth($0, size: titleSize) }.max() ?? 0
        return Swift.min(tabsMost, Swift.max(DSParts.tabsWidth, (widest + titleRoom).rounded(.up)))
    }

    /// The panel's width with that column (the settings beside it keep the width they had).
    static func panelWidth(tabs: CGFloat) -> CGFloat { PageChrome.widePanelWidth + Swift.max(0, tabs - DSParts.tabsWidth) }

    /// One line of the system font at `size`, measured as it is drawn.
    static func textWidth(_ s: String, size: CGFloat) -> CGFloat {
        guard !s.isEmpty, let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return 0 }
        let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil))
    }
}
