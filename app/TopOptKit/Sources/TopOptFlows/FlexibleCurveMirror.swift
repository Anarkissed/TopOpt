// FlexibleCurveMirror — the curve window's Mirror and Copy buttons (task 2026-09-29-flexible-screens, round 7 · U21 batch B,
// CURVE-MIRROR). His notes of 2026-10-21, "Img16 finally" (27.png): "in the curves should have some buttons available to make
// things a little easier for the user - please figure out good single or dual named buttons for them. Place them to the side like
// a legend. … Copy the left side of the curve and paste to thee right side · Copy the right side and paste to the left side · Copy
// the top curve and paste to the bottom curve · Copy the bottom curve and paste to the top curve."
//
// ★ MIRROR (one curve, beside its own chart): [Left → Right] keeps the left half's points BIT-EXACT and puts their reflection
// (x → 1 − x) on the right; [Right → Left] the other way. The middle point: his own when one sits within core's gap (0.01) of ½
// (its y kept, placed at ½), else core's own curve value at ½ (`pen_curve_values`, the Fritsch–Carlson curve he sees), so the
// kept half's shape moves as little as core's curve allows. Kept points within the gap of the middle are dropped (core: x strictly
// increasing by ≥ 0.01). The result is reflection-symmetric.
// ★ COPY (between the two charts): the top chart's curve onto the bottom one ([X → Y ↓]; an edge's [Across → Along]) or back.
// A corner has one curve: no buttons.
// ★ DRAFT ONLY: both write the window's draft (FlexibleStageModel.mirrorDraftCurve / copyDraftCurve); [OK] keeps (one undo step),
// [Cancel] drops it, as every drag in the window.

import Foundation
import TopOptKit

public enum FlexibleCurveMirror {
    public enum Side: String, CaseIterable, Hashable, Sendable { case leftToRight, rightToLeft }

    /// ★ RED CONTROL only: a naive flip (y read backwards onto the same x) — not symmetric when his points are not.
    nonisolated(unsafe) static var controlNaiveFlip = false

    /// Core's gap between neighbouring x.
    static var gap: Double { FlexibleCurveEditor.minGap }

    /// The index of HIS middle point: the interior point nearest ½ within the gap, or nil.
    static func ownMiddle(_ c: FlexCurve) -> Int? {
        guard c.x.count > 2 else { return nil }
        return (1..<(c.x.count - 1)).filter { abs(c.x[$0] - 0.5) < gap }.min { abs(c.x[$0] - 0.5) < abs(c.x[$1] - 0.5) }
    }

    /// Core's curve value at t (the curve he sees); the straight line between neighbours if core refuses.
    static func coreValue(_ c: FlexCurve, at t: Double) -> Double {
        if let v = (try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: [t]))?.first, v.isFinite { return Swift.min(1, Swift.max(0, v)) }
        guard let i = c.x.indices.dropLast().last(where: { c.x[$0] <= t }), i + 1 < c.x.count else { return c.y.first ?? 1 }
        let f = (t - c.x[i]) / Swift.max(c.x[i + 1] - c.x[i], 1e-12)
        return c.y[i] + (c.y[i + 1] - c.y[i]) * f
    }

    /// ★ The curve with one half copied onto the other (see the header).
    public static func mirrored(_ c: FlexCurve, _ side: Side) -> FlexCurve {
        guard c.x.count >= 2, c.x.count == c.y.count else { return c }
        if controlNaiveFlip {   // (RED CONTROL: y read backwards on the same x)
            return FlexCurve(x: c.x, y: side == .leftToRight ? Array(c.y.reversed()) : c.y)
        }
        let mid = ownMiddle(c)
        let yMid = mid.map { c.y[$0] } ?? coreValue(c, at: 0.5)
        let eps = 1e-12
        // the kept half (bit-exact), without his middle and without anything within the gap of ½
        let kept: [Int] = c.x.indices.filter { i in
            guard i != mid else { return false }
            return side == .leftToRight ? c.x[i] <= 0.5 - gap + eps : c.x[i] >= 0.5 + gap - eps
        }
        var x: [Double] = [], y: [Double] = []
        switch side {
        case .leftToRight:
            for i in kept { x.append(c.x[i]); y.append(c.y[i]) }
            x.append(0.5); y.append(yMid)
            for i in kept.reversed() { x.append(1 - c.x[i]); y.append(c.y[i]) }
        case .rightToLeft:
            for i in kept.reversed() { x.append(1 - c.x[i]); y.append(c.y[i]) }
            x.append(0.5); y.append(yMid)
            for i in kept { x.append(c.x[i]); y.append(c.y[i]) }
        }
        return FlexCurve(x: x, y: y)
    }

    /// Whether [Mirror] would change the curve (greyed when not).
    public static func changes(_ c: FlexCurve, _ side: Side) -> Bool { mirrored(c, side) != c }

    /// The largest |x_i + x_(n−1−i) − 1| and |y_i − y_(n−1−i)|: 0 for a reflection-symmetric curve.
    public static func asymmetry(_ c: FlexCurve) -> Double {
        let n = c.x.count
        guard n == c.y.count, n > 0 else { return .infinity }
        return (0..<n).map { i in Swift.max(abs(c.x[i] + c.x[n - 1 - i] - 1), abs(c.y[i] - c.y[n - 1 - i])) }.max() ?? 0
    }

    /// The largest |f(t) − f(1 − t)| of core's curve over 201 samples (what he sees): 0 for a symmetric curve.
    public static func curveAsymmetry(_ c: FlexCurve) -> Double {
        let t = (0...200).map { Double($0) / 200 }
        guard let v = try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: t), v.count == t.count else { return .infinity }
        return (0...200).map { abs(v[$0] - v[200 - $0]) }.max() ?? 0
    }

    /// The largest change of core's curve over the half `side` keeps (201 samples over that half).
    public static func keptHalfMoved(_ before: FlexCurve, _ after: FlexCurve, _ side: Side) -> Double {
        let start: Double = side == .leftToRight ? 0 : 0.5
        let t: [Double] = (0...200).map { (k: Int) -> Double in start + 0.5 * Double(k) / 200 }
        guard let a = try? FlexibleCore.penCurveValues(x: before.x, y: before.y, t: t),
              let b = try? FlexibleCore.penCurveValues(x: after.x, y: after.y, t: t), a.count == b.count else { return .infinity }
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    // MARK: the pairs a window offers

    typealias Axis = FlexiblePressCurveBaselines.Axis

    /// The curves a window copies between, top chart first (a face: X then Y; an edge: across then along); none for a corner.
    static func copyPair(face: Bool, strip: FlexibleStrip?) -> (top: Axis, bottom: Axis)? {
        if face { return (.along, .across) }
        guard let st = strip, st.kind != .corner else { return nil }
        return (.across, .along)
    }

    /// The curves that get [Mirror] (in their charts' order); none for a corner.
    static func mirrorAxes(face: Bool, strip: FlexibleStrip?) -> [Axis] {
        guard let p = copyPair(face: face, strip: strip) else { return [] }
        return [p.top, p.bottom]
    }
}

extension FlexibleStageModel {
    /// ★ RED CONTROL only (FlexibleR7U21BCurveTests): Mirror / Copy write the face or press at once ([Cancel] keeps it).
    nonisolated(unsafe) static var controlActionWritesAtOnce = false

    /// ★ U21 B: [Mirror] on one curve of the open window — the draft only.
    public func mirrorDraftCurve(_ axis: FlexiblePressCurveBaselines.Axis, _ side: FlexibleCurveMirror.Side) {
        guard let d = curveDraft else { return }
        let c = d.curves[axis] ?? FlexiblePressCurveBaselines.ones
        applyDraftAction(axis, FlexibleCurveMirror.mirrored(c, side))
    }

    /// ★ U21 B: [Copy] one curve of the open window onto the other — the draft only.
    public func copyDraftCurve(from: FlexiblePressCurveBaselines.Axis, to: FlexiblePressCurveBaselines.Axis) {
        guard let d = curveDraft, from != to else { return }
        applyDraftAction(to, d.curves[from] ?? FlexiblePressCurveBaselines.ones)
    }

    private func applyDraftAction(_ axis: FlexiblePressCurveBaselines.Axis, _ c: FlexCurve) {
        guard curvesAreInput else { return }   // ★ MANUAL (M2): no Mirror, no Copy in Manual
        guard var d = curveDraft else { return }
        let m = FlexiblePressCurveBaselines.clamped(c)
        guard d.curves[axis] != m else { return }
        d.curves[axis] = m
        d.resets += 1   // the tables' selected point is cleared (their selection is their own state)
        curveDraft = d
        if Self.controlActionWritesAtOnce {   // (RED CONTROL: written at once)
            if let id = d.press { setPressCurve(id, axis, m) } else if let r = d.face { setFaceCurve(r, axis, m) }
            save()
        }
    }
}
