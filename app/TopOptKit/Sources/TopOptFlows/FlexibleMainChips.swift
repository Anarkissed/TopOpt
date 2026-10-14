// FlexibleMainChips — the bottom-right chips Topology owns, kept off the main Flexible page (task
// 2026-09-29-flexible-screens, round 7 batch M1; hook H18 in #354's WorkspacePlaceholder, approved by the reviewer on
// 2026-10-14 for exactly these two chips).
//
// His img1 words (2026-10-14): "Remove the "Protect 3mm" chip at the bottom right corner. There is no need for it." and
// "Is there any need for "Minimize Plastic" for this process at all? I don't think so" — answered: no, it is Topology's
// objective; remove it from this stage.
// ★ WHY THESE TWO. "Protect 3 mm" (.faceProtectDepth) steps `force.faceProtectDepthMM`, read only by
// ProjectModel.faceProtectionSpecs — Topology's run; no Flexible job sends it. "Minimize plastic" (.minimizePlastic) flips
// `project.minimizePlastic`, Topology's ladder; no Flexible file reads it. On the Flexible stage both are controls over
// nothing. The STORED values stay: Optimize on Topology keeps the depth and the ladder he set there.
// ★ NOT HERE: "CAD surfaces" (.cadFaces). His answer (2026-10-14) leaves it OFF the Flexible stage too, but the reviewer's
// ruling dropped it from H18; it goes with the redesign's shared-file list (H24). Fast · 64³, Plate up and Gravity stay:
// each is a live Flexible input (the scene's grid, `build_direction`, the loads' `build_dir`).
// ★ THE HOOK (H18, +1 −0) is the first statement of WorkspacePlaceholder.visibleSettingsChips' filter:
//     if flexibleMain.owns(project, stage), FlexibleMainChips.hidden.contains(id) { return false }
// so every other stage's chips are exactly today's.

import Foundation

public enum FlexibleMainChips {
    /// The chips hidden on the Flexible stage (H18). RED CONTROL `controlNothingHidden`: today's column (img1's five rows).
    public static var hidden: Set<SettingsChipID> {
        controlNothingHidden ? [] : []   // STUB (red run): today's column
    }

    /// Test control only: nothing hidden — the column as it was before H18 (his img1: "Protect 3 mm", "Minimize plastic").
    nonisolated(unsafe) static var controlNothingHidden = false

    /// The chips a stage shows, of `ids` (the workspace's own filter runs after this one): on the Flexible stage
    /// (`owned`) without `hidden`; elsewhere every one.
    public static func visible(_ ids: [SettingsChipID], owned: Bool) -> [SettingsChipID] {
        owned ? ids.filter { !hidden.contains($0) } : ids
    }
}
