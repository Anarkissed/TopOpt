// FlexibleChromeLayout — STUB (R7-D1 tests first). Replaced by the real frames in the code commit.

import CoreGraphics
import TopOptDesign

public enum FlexibleChromeLayout {
    public static let capsuleTop: CGFloat = 0
    public static let capsuleLeft: CGFloat = 0
    public static let capsuleHeight: CGFloat = 0
    public static let capsuleMaxWidth: CGFloat = 0
    public static let segmentHeight: CGFloat = 0
    public static let segmentInset: CGFloat = 0
    public static let viewButton: CGFloat = 40
    public static let viewsGap: CGFloat = 0
    public static let setupHeight: CGFloat = 0
    public static let setupMaxWidth: CGFloat = 0
    public static let latticeCaretWidth: CGFloat = 0
    public static let pairGap: CGFloat = 0
    public static let panelGap: CGFloat = 0
    public static let selectionsPillHeight: CGFloat = 44

    public static func isMini(_ v: CGSize) -> Bool { false }
    public static func latticeButtonSize(_ v: CGSize) -> CGSize { .zero }
    public static func capsuleFrame(width: CGFloat) -> CGRect { .zero }
    public static func viewsRow(viewport v: CGSize) -> CGRect { .zero }
    public static func pair(viewport v: CGSize, setupWidth: CGFloat) -> (setup: CGRect, lattice: CGRect) { (.zero, .zero) }
    public static func panelWidth(_ v: CGSize) -> CGFloat { 0 }
    public static func panelTopLimit(_ v: CGSize) -> CGFloat { 0 }
    public static func panel(viewport v: CGSize, setupWidth: CGFloat, contentHeight: CGFloat) -> (frame: CGRect, scrolls: Bool) { (.zero, false) }
    public static func selectionsPill(viewport v: CGSize, width: CGFloat) -> CGRect { .zero }
    public static func todaysBar(viewport v: CGSize, widths: [CGFloat], spacing: CGFloat) -> [CGRect] { [] }
}
