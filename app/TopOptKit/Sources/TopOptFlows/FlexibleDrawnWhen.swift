// FlexibleDrawnWhen — the one modifier hook H39 hangs on #354's Selections-card header (task 2026-09-29-flexible-screens,
// round 7, the H39 hotfix; the reviewer's ruling 1 of 2026-10-17 20:25, approved by the maintainer: "H39 (WorkspacePlaceholder):
// the Selections-card header's Regions toggle drawn only when !flexibleMain.owns(project, stage)").
//
// ★ THE LEAK. H26 took #354's Regions PANEL off the Flexible stage (his img6: "Remove regions as it is no longer necessary
// thanks to the Surface stage"), but its TOGGLE stayed in the Selections header: a tap there only turned the icon blue —
// and set the workspace's `regionsOpen`, so the Regions panel popped up the moment he went to Topology. With the toggle not
// drawn on the Flexible stage nothing there can set `regionsOpen` (the toggle is its only writer that opens it; the panel's
// Done only closes it), so no Flexible session leaves it open for Topology. Topology, the Structural / Aesthetic lattice
// stage and Surface draw the toggle exactly as before.
// (When D2's H25 replaces the Selections header on the Flexible stage, H39 stays only if #354's card can still draw there
// in some state — the ruling's words.)

import SwiftUI

extension View {
    /// The view as it is when `on`; nothing at all otherwise (no frame, no tap target, no accessibility element).
    @ViewBuilder func flexibleDrawn(when on: Bool) -> some View {
        if on { self }
    }
}
