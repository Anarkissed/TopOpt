// MinimisedPills — his iPad notes 2026-11-22 (afternoon, img 44): the two pills at the bottom left of Lattice Setup.
//
// His words: "When I minimize the 'Selections' modal, both get minimized to the bottom of the screen. But the 'Selections' is
// much smaller than the 'Topology' one. They should be the same size and colour. The same colour as 'Selections'. About half
// the width of 'Topology'."
//
// Where the two fold together (Lattice Setup, Topology closed, Selections minimised) the page sets `minimisedPillWidth`, and
// both pills read it: the Topology panel's folded header (DSPanel) and the Selections pill (SelectionsList) are then the same
// width (half of Topology's old 348 pt pill), the same height (the Selections pill's 44 pt) and the same colour (the Selections
// pill's: the panel glass with no blur behind it). Their content stays: the chevron, the title, the count.
import SwiftUI

public enum MinimisedPills {
    /// Half of the Topology pill's old width (it was the panel's 348 pt).
    public static let width: CGFloat = DSParts.panelWidth / 2
    /// The Selections pill's height (`SelectionsList.lineHeight`): a 44 pt touch target.
    public static let height: CGFloat = 44
    /// RED CONTROL (MinimisedPillsHostedTests): the page sets no shared width (as before his note).
    @MainActor public static var controlOldPills = false
}

private struct MinimisedPillWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// ★ his 11-22 (img 44): non-nil where Topology and Selections are minimised together — both pills take this width.
    public var minimisedPillWidth: CGFloat? {
        get { self[MinimisedPillWidthKey.self] }
        set { self[MinimisedPillWidthKey.self] = newValue }
    }
}

extension View {
    /// The page's one switch: `together` (both minimised) gives both pills the shared width.
    @MainActor func minimisedPillsTogether(_ together: Bool) -> some View {
        environment(\.minimisedPillWidth, together && !MinimisedPills.controlOldPills ? MinimisedPills.width : nil)
    }
}
