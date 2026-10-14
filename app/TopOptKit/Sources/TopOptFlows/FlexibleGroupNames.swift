// FlexibleGroupNames — every squeeze group's NAME, tapped to rename, and its TRASH (task 2026-09-29-flexible-screens,
// round 7 batch S; his img3 words of 2026-10-14: "All groups should have a trash icon next to them and their names should
// be editable by tapping "group 1" or whatever the default name is.").
//
// RED STUBS (tests first): today's rules, so FlexibleR7SettingsTests fail for their stated reasons.

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// The name group `g` shows on the Settings page.
    public func groupName(_ g: FlexibleSqueezeGroup) -> String { FlexibleRowCopy.groupName(g.number) }

    /// His name for group `groupID` (stored id).
    public func setGroupName(_ groupID: Int, _ name: String) {}
}

extension FlexibleSqueezeGroups {
    /// ★ RED CONTROL: a name is not carried to the group's new number when groups renumber.
    nonisolated(unsafe) static var controlNoNameRemap = false
}

extension FlexibleSqueezeGroupRows {
    /// ★ RED CONTROL: today's rule — the × only with two or more groups (the only group has none).
    @MainActor static var controlRemovableOnlyWithTwo = false
}
