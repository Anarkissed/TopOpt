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
//     ★ "UNTOUCHED" IS THE SHAPE, NOT THE BYTES (verification of round 3): the old "+ point"
//     inserted a knot ON the curve, so his top B's curveX (x 0 · 0.25 · 0.5 · 1) is the
//     default dome with one more point — he drew nothing, yet it was flipped to firm-in-the-
//     middle beside the identical, unflipped curveY. A curve is drawn only when core's own
//     curve (pen_curve_values, 21 samples) leaves the default's by more than `drawnTolerance`
//     (0.04 in S: his top B's knot moves it 0.022, his top A's dragged peak 0.072).

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
                if isDrawn(f.curveX) { f.curveX = flipped(f.curveX) }
                if isDrawn(f.curveY) { f.curveY = flipped(f.curveY) }
            }
            out.faces[i] = f
        }
        out.curveConvention = currentCurveConvention
        return out
    }

    /// How far (in S) core's curve must leave the default dome's anywhere to count as drawn.
    /// Measured on his project: top B's inserted knot moves the curve ≤ 0.022 (Fritsch–Carlson
    /// re-slopes around it); top A's dragged peak moves it 0.072.
    public static let drawnTolerance = 0.04
    static let samples = (0...20).map { Double($0) / 20 }

    /// Did he DRAW this curve (its shape leaves the default dome), or is it the default —
    /// perhaps with a knot the old "+ point" inserted on it? Memoised: the migration runs on
    /// every settings read until the first edit writes the migrated form.
    public static func isDrawn(_ c: FlexCurve) -> Bool {
        if c == FlexibleFaceSettings.defaultCurve { return false }
        let key = "\(c.x)|\(c.y)" as NSString
        if let hit = drawnCache.object(forKey: key) { return hit.boolValue }
        let d = FlexibleFaceSettings.defaultCurve
        let drawn: Bool
        if let a = try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: samples),
           let b = try? FlexibleCore.penCurveValues(x: d.x, y: d.y, t: samples), a.count == b.count {
            drawn = zip(a, b).contains { abs($0 - $1) > drawnTolerance }
        } else {
            drawn = true   // core cannot read it: keep the old rule (not byte-equal ⇒ drawn)
        }
        drawnCache.setObject(NSNumber(value: drawn), forKey: key)
        return drawn
    }
    private static let drawnCache = NSCache<NSString, NSNumber>()

    /// y → 1 − y at every control point (the picture under the other reading).
    public static func flipped(_ c: FlexCurve) -> FlexCurve {
        FlexCurve(x: c.x, y: c.y.map { 1 - $0 })
    }
}
