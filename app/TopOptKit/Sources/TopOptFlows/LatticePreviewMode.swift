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
import Combine
import SwiftUI
import simd

public enum LatticePreviewMode {
    // MARK: the words (one place)
    public static let live = "Live preview"
    public static let refresh = "Click to refresh preview"
    public static let refreshButton = "Refresh Lattice"
    public static let refreshLine = "Settings changed: tap to update the preview"
    public static let nozzleCheck = "Check a 0.2 mm nozzle"

    // MARK: his picks 11-21 (the preview-speed research): the Organic lay said on the Lattice button, five words at most
    // with the time: the Draft first (the last lattice dimmed), then "Draft · checking print" while the exact lattice is
    // made with the Draft on screen.
    /// ★ his ask 11-21: the ⌃ menu's switch between the quick stand-in (off) and the print file's own lattice (on).
    public static let printAccurate = "Print-accurate preview"
    public static let layingDraft = "Laying Draft"
    public static let draftChecking = "Draft \u{00B7} checking print"
    public static let layingExact = "Laying the lattice"
    /// The button's ring and words for an Organic lay under way.
    public static func buttonProgress(_ p: LatticeLayoutPreview.LayProgress) -> DSRunButton.Progress {
        DSRunButton.Progress(started: p.started, expected: p.expectedS,
                             words: p.quality == .draft ? layingDraft : p.draftShown ? draftChecking : layingExact)
    }

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

    // MARK: his second ask 11-16 ("still seeing some lag while tapping on something or dragging around the model … when the
    // lattice is turned on"), his picks A-E (F, hiding the lattice while turning, he ruled OUT):
    //   A. a drag moves the camera only: the page does not re-read itself on every step, and the chips and legends HIDE while
    //      the camera moves (his note), back where the model now is when he lets go;
    //   B. a tap reads one pixel instead of drawing a whole extra frame, and no longer re-colours the lattice's tint volume
    //      (nothing has read it since the lattice's hue became its structure);
    //   C. while turning, the lattice's own layer is drawn smaller (both engines);
    //   D. while turning, no soft shading in the gaps and no edge lines;
    //   E. while turning, at most 60 frames a second.

    /// (C) The lattice layer's long side while turning, in pixels (at rest the old engine's is 1152 and the new engine's
    /// bars have none).
    public static let turningGBufferMaxPixels = 576

    /// (C) The lattice layer's long-side cap: nil = the screen's own size. `marched` = the old engine's or Flexible's march
    /// is in the frame (capped at `restCap` always); `bars` = the new engine's bars (uncapped at rest).
    public static func gbufferCap(turning: Bool, marched: Bool, bars: Bool, restCap: Int) -> Int? {
        if turning, marched || bars, !controlFullDetailWhileTurning { return Swift.min(restCap, turningGBufferMaxPixels) }
        return marched ? restCap : nil
    }

    /// (D) Whether the soft shading in the gaps and the edge lines are drawn this frame.
    public static func aoDrawn(turning: Bool, latticeShown: Bool) -> Bool {
        !(turning && latticeShown) || controlFullDetailWhileTurning
    }

    /// (E) The shortest time between two frames while turning: 60 a second.
    public static let turnFrameGap: Double = 1.0 / 60
    /// (E) How long a frame asked for now must wait (s): nothing once a frame's gap has passed since the last one.
    public static func turnFrameWait(now: Double, lastDraw: Double) -> Double {
        guard !controlFullDetailWhileTurning else { return 0 }
        return Swift.max(0, turnFrameGap - (now - lastDraw))
    }

    /// (B) The pick matrix: clip space of a `width`×`height` view mapped so that pixel (`px`, `py`) (from the top left) fills
    /// a 1×1 target. Multiplied in front of the view's own clip-from-model; depth is untouched.
    public static func pixelPick(px: Int, py: Int, width: Int, height: Int) -> simd_float4x4 {
        let W = Float(width), H = Float(height)
        let cx = 2 * (Float(px) + 0.5) / W - 1
        let cy = 1 - 2 * (Float(py) + 0.5) / H
        return simd_float4x4(columns: (SIMD4<Float>(W, 0, 0, 0), SIMD4<Float>(0, H, 0, 0),
                                       SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(-cx * W, -cy * H, 0, 1)))
    }
    /// RED CONTROL (tests only) for B: a tap draws whole frames as before (and bakes the lattice's tint volume).
    nonisolated(unsafe) public static var controlTapDrawsWholeFrames = false

    /// RED CONTROL (tests only) for C, D and E: turning draws exactly as at rest.
    nonisolated(unsafe) public static var controlFullDetailWhileTurning = false
    /// RED CONTROL (tests only) for A: the page follows every camera step and keeps its chips and legends while turning.
    nonisolated(unsafe) public static var controlPageFollowsCamera = false

    /// (3) When the glow stops breathing (s, on the media clock): two full breaths after `now`, landing on a breath's PEAK so
    /// the held glow (its brightest) follows on without a jump. `period` is the breath's (2.6 s).
    public static func glowBreathEnd(now: Double, period: Double = 2.6) -> Double {
        let earliest = now + 2 * period
        var end = ((earliest / period).rounded(.down) + 0.25) * period   // sin peaks at a quarter period
        if end < earliest { end += period }
        return end
    }
}

/// ★ his pick 11-16 (A): the page's view of its camera. The page (a very large view) re-reads itself on a camera change only
/// while no lattice is being turned; while one is, the 3D view and the gizmos follow the camera themselves (they hold the model
/// directly), and the page catches up ONCE when he lets go.
@MainActor
final class PageCameraRelay: ObservableObject {
    let model: OrbitCameraModel
    private(set) var quiet = false
    private var forward: AnyCancellable?

    init(model: OrbitCameraModel) {
        self.model = model
        forward = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.quiet else { return }
                self.objectWillChange.send()
            }
        }
    }

    /// Quiet while a lattice turns; going back to loud re-reads the page once.
    func setQuiet(_ q: Bool) {
        guard q != quiet else { return }
        quiet = q
        if !q { objectWillChange.send() }
    }
}

private struct LatticeTurningKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// ★ his pick 11-16 (A): he is turning the view with a lattice drawn: chips and legends that read it hide themselves.
    public var latticeTurning: Bool {
        get { self[LatticeTurningKey.self] }
        set { self[LatticeTurningKey.self] = newValue }
    }
}
