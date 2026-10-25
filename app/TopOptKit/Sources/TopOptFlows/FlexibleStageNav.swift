// FlexibleStageNav — the Surface button on the main Flexible page, and the way back (task
// 2026-09-29-flexible-screens, round 3 batch C, item S; his ask: "a Surface button on the main
// Flexible page"). Hook H9 in #354's WorkspacePlaceholder puts it beside [‹ Topology] with
// #354's own `stageNavButton` (identical chrome); WorkspaceStage is untouched.

import Foundation

/// ★ THE SURFACE BUTTON ON THE MAIN FLEXIBLE PAGE (item S; his ask). Beside [‹ Topology] on the
/// Flexible lattice stage: [Surface]; on Surface, a Flexible project gets [‹ Flexible] straight
/// back. #354's WorkspaceStage.forward / back are untouched (SurfaceStageTests pins them).
public struct FlexibleStageNavExtra: Equatable, Sendable {
    public let dest: WorkspaceStage
    public let icon: String
    public let title: String
}

public enum FlexibleStageNav {
    public static func extra(_ stage: WorkspaceStage, flexible: Bool) -> FlexibleStageNavExtra? {
        guard flexible else { return nil }
        // ★ SYNC #354 (89af86dd) COMPILE FIX ONLY: B5 (3f293974) removed WorkspaceStage.surface and deleted H9's call
        // site, so there is no [Surface] / [‹ Flexible] button to offer. P5 retires this file (Edit faces' Done is the way back).
        switch stage {
        case .lattice: return nil
        case .topology: return nil
        }
    }
}
