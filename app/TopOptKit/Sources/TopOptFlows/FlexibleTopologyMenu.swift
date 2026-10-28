// FlexibleTopologyMenu — what Topology's ● menu says on a Flexible project (H59).

import Foundation

/// ★ H59 (the reviewer's overnight release ruling, 2026-10-26 07:42 UTC: "THE MENU SAYS FLEXIBLE"): on a Flexible project
/// Topology's ● menu names its lattice row for the stage it opens — "Flexible", not #354's "Lattice…" (no lattice type chosen)
/// or a type's name. H59 hands #354's row title through here at the row's call site (WorkspacePlaceholder,
/// topologyCapsuleOverlay); TopologyStageMenu stays #354's.
public enum FlexibleTopologyMenu {
    /// ★ RED CONTROL: #354's row as it is ("Lattice…" on a Flexible project).
    @MainActor static var controlLatticeTitle = false

    @MainActor public static func latticeRowTitle(_ title: String, project: ProjectModel) -> String {
        guard !controlLatticeTitle, project.lattice.flexible != nil else { return title }
        return FlexibleStageStyle.title
    }
}
