// FlexibleSettingsMigration — how a Flexible project saved before round 3 reads today (task
// 2026-09-29-flexible-screens, round 3; items 1.3, 2.1 and 5).
//
// ★ READ-THROUGH, NEVER A SILENT REWRITE. FlexibleStageModel reads its settings through
// `migrated(_:)`, so an old project SHOWS and RUNS the new way at once, while the file keeps
// its bytes until the user's next edit writes the migrated form. Undo can therefore never
// resurrect the pre-round-3 reading: undoing back to old bytes reads through the same rule.
//
// ★ WHAT CHANGES.
//   * beads: always 1 (item 2.1 — the chip is gone; 2-bead walls wait on coupons);
//   * mode: always "both" (his answer: "X and Y always combined"); curveX / curveY kept;
//   * frame rotation: always 0 (item 5 — the curves are drawn on the model's own edges);
//   * curves (item 1.3): the editor now draws a stored y at height 1 − y ("closer to the
//     face = squishier"). A curve he DREW before keeps its PICTURE, so its stored y flips
//     once (y → 1 − y); the untouched default dome is NOT flipped — under the new reading it
//     is the valley that touches the face in the middle, the dent's own shape.

import Foundation
import TopOptKit

public enum FlexibleSettingsMigration {

    /// 1 = round 3's reading: height 1 − y above the face (the face line is the squishiest).
    public static let currentCurveConvention = 1

    public static func migrated(_ s: FlexibleStageSettings) -> FlexibleStageSettings {
        // the fast path: already the round-3 shape (every edit writes it)
        if s.beadsPerWall == 1, s.curveConvention == currentCurveConvention,
           s.faces.allSatisfy({ $0.mode == "both" && $0.rotationDeg == 0 }) { return s }
        var out = s
        out.beadsPerWall = 1
        let flip = s.curveConvention == nil
        for i in out.faces.indices {
            var f = out.faces[i]
            f.mode = "both"
            f.rotationDeg = 0
            if flip {
                // a DRAWN curve keeps its picture; the untouched default is kept as it is
                if f.curveX != FlexibleFaceSettings.defaultCurve { f.curveX = flipped(f.curveX) }
                if f.curveY != FlexibleFaceSettings.defaultCurve { f.curveY = flipped(f.curveY) }
            }
            out.faces[i] = f
        }
        out.curveConvention = currentCurveConvention
        return out
    }

    /// y → 1 − y at every control point (the picture under the other reading).
    public static func flipped(_ c: FlexCurve) -> FlexCurve {
        FlexCurve(x: c.x, y: c.y.map { 1 - $0 })
    }
}
