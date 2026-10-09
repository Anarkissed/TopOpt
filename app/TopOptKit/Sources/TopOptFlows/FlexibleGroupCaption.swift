// FlexibleGroupCaption — the ONE line under a main-page Selections row whose group is a hand squeezed with another
// (task 2026-09-29-flexible-screens, round 6 item 4, hook H17): "Squeezed with Group 2 · Face 2". One line, the row's
// footnote style; it never wraps (the text is fitted by FlexibleMainStage.groupCaption).

import SwiftUI
import TopOptDesign

public struct FlexibleGroupCaption: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .dsStyle(DS.TypeScale.footnote)
            .foregroundStyle(DS.Color.textTertiary.color)
            .lineLimit(1).minimumScaleFactor(0.85)
            .accessibilityIdentifier("flexible-group-caption")
    }
}
