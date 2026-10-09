// FlexibleMainStage+Groups — the main page's side of ONE SET OF GROUPS (task 2026-09-29-flexible-screens, round 6
// item 4): each Selections row's swatch in its squeeze group's colour (hook H16) and one caption on a hand that is
// squeezed with another (H17). TESTS FIRST: the API only — the implementation follows in the next commit.

import Foundation
import TopOptDesign

extension FlexibleMainStage {
    /// H16: the Selections row's swatch on the Flexible stage (nil: #354's own tint).
    public func groupTint(_ g: SelectionGroup, _ project: ProjectModel) -> RGBA? { nil }
    /// H17: "Squeezed with Group 2 · Face 2" on a hand squeezed with another (nil: no line).
    public func groupCaption(_ g: SelectionGroup, _ project: ProjectModel) -> String? { nil }
}
