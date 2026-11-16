// LatticePreviewMode.swift — ★ his ask 2026-11-16: "It kills my ipad when [I] have the lattice view on … It just gets impossibly
// slow and laggy and drops frames." His picks, all agreed the same night:
//   1. the Lattice button's ⌃ picks "Live preview" or "Click to refresh preview" (a check mark on the one in force);
//   2. DEFAULT = Click to refresh: a changed setting marks the preview out of date, nothing rebuilds and no stress check runs;
//      the Lattice button reads "Refresh Lattice" until he presses it, then goes back to Lattice;
//   3. the thin-wall glow breathes a few times, then holds (the view goes back to drawing only on a change);
//   4. Live preview rebuilds half a second after the last change, not on every tick;
//   5. the 0.2 mm nozzle check (a second full layout) runs only on Refresh, or when he asks for it;
//   6. while he turns the view with the lattice up, the view draws at half resolution; full again when he lets go.

import Foundation
import CoreGraphics

public enum LatticePreviewMode {
    // MARK: the words (one place)
    public static let live = "Live preview"
    public static let refresh = "Click to refresh preview"
    public static let refreshButton = "Refresh Lattice"
    public static let refreshLine = "Settings changed: tap to update the preview"
    public static let nozzleCheck = "Check a 0.2 mm nozzle"

    /// (4) Live preview: the rebuild waits this long after the last change.
    public static let liveDelay: Duration = .milliseconds(500)
    /// RED CONTROL (tests only): Live preview without the wait — every change lays at once.
    @MainActor public static var controlNoLiveDelay = false
    /// The wait Live preview uses (none under the red control).
    @MainActor public static var liveWait: Duration { controlNoLiveDelay ? .zero : liveDelay }

    /// (2) The Lattice button reads "Refresh Lattice": Click to refresh is in force, the lattice view is up, the preview is out
    /// of date, and no run is going (a run's own button wins).
    public static func showsRefresh(live: Bool, previewUp: Bool, stale: Bool, running: Bool) -> Bool {
        !live && previewUp && stale && !running
    }

    /// (5) The nozzle check runs after a layout only when asked for: on Refresh, or his tap on "Check a 0.2 mm nozzle".
    public static func nozzleAfterLay(asked: Bool) -> Bool { asked }

    /// (6) The view's drawing scale: half the screen's while he turns the view with a lattice in it, the screen's own
    /// otherwise. Never below 1.
    public static func drawScale(native: CGFloat, turning: Bool, latticeShown: Bool) -> CGFloat {
        guard turning, latticeShown, native > 1 else { return native }
        return Swift.max(1, native / 2)
    }

    /// (3) When the glow stops breathing (s, on the media clock): two full breaths after `now`, landing on a breath's PEAK so
    /// the held glow (its brightest) follows on without a jump. `period` is the breath's (2.6 s).
    public static func glowBreathEnd(now: Double, period: Double = 2.6) -> Double {
        let earliest = now + 2 * period
        var end = ((earliest / period).rounded(.down) + 0.25) * period   // sin peaks at a quarter period
        if end < earliest { end += period }
        return end
    }
}
