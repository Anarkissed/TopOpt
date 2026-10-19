// FlexibleBackend — R7-E2 PARKED (task 2026-09-29-flexible-screens, round 7, 2026-10-19). His words: "Please finalize the sending
// edges to core as soon as possible - as we are more focussed on the front-end now. The back-end will come AFTER we have
// implemented the actual process."
//
// ★ THE ONE SWITCH. Off: every edge and corner press (a flat prism) is kept OUT of every request to core — the scene's designs and
// conflicts (pressDesignTargets), Auto's request, the preview lattice and its key (designInputs, latticeSettingsKey), the run job
// and the export (FlexiblePressSupport's gate: never in the job, so sentPresses is empty) — exactly E1's rule. The FRONT-END stays:
// the flat prism, its handles, its limits (core's stack is still read for those: registerPresses), the card says "Shape only ·
// core support comes later". On: R7-E2 as built (31788815..4f735cff; its 18 findings are the back-end backlog, the half-done fix
// parked on claude/flexible-screens-e2fix-wip). E2's own tests turn it on.

import Foundation

public enum FlexibleBackend {
    /// Edge and corner presses are sent to core (R7-E2). Off until the back-end phase.
    nonisolated(unsafe) public static var sendsPresses = false
}
