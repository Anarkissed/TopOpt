// FlexibleLatticeHandles — the picked face-prism's NUMBERED handles on the main Flexible page (task 2026-09-29-flexible-
// screens, round 7, batch R7-D2; his img1 words, 2026-10-14: "The number on the face-prism should be tap to edit (bringing up
// a numeric keyboard for input)" and "The face-prism depth in the modal and on the face-prism are not equal? … they should
// *always* be equal."). Hook H20 takes #354's numberless knobs off this stage; these replace them.
//
// ★ ONE NUMBER, ONE STORE. The depth handle writes #354's `writeLatticeDepthMM` (GROUP scope: `writeGroupDepthMM`), the
// expand handle `writeLatticeExpandMM` — the very setters the list's boxes and #354's own rows write — and both read back
// through `latticeSlabDepthMM(ref, in:)` / `latticeExpandMM(ref)`, so the handle's box, the list's box and the drawn prism
// can never disagree (FlexibleMainPrismEqualityTests).
//
// ★ THE DRAG (pure, so FlexibleLatticeHandlesTests measures it):
//   * DEPTH: along the prism's normal as it is PROJECTED on screen (the floor and a point 10 mm deeper), with #354's
//     LatticeDepthDetent magnets (the certifying depth, round millimetres); when the normal projects shorter than 30 pt per
//     10 mm (the face seen edge-on… or head-on) the drag is screen-vertical instead, down = deeper, 0.1 mm per point;
//     clamped 1–50 (LatticeSlabDepth);
//   * EXPAND: along the in-plane direction the knob sits on (#354's LatticeSlabExpand.knobAnchor), projected, else
//     horizontal at #354's 0.05 mm per point; −50…+50, snapping to 0 (#354's own setter);
//   * live writes, ONE undo step per drag (sealed at its start and its end), the cards refreshed once on release; X-ray on
//     while it drags (the prism sits inside the part) and put back as it was on release.
// ★ 44 pt targets (his rule); the discs draw at 32.

import CoreGraphics
import Foundation
import simd
import SwiftUI
import TopOptDesign

public enum FlexibleLatticeHandles {
    /// The disc as drawn, and its touch target (his rule: 44 pt).
    public static let disc: CGFloat = 32
    public static let hit: CGFloat = 44
    /// The depth drag follows the projected normal only while it projects at least this long per 10 mm.
    public static let shortAxisPointsPer10MM: CGFloat = 30
    /// The screen-vertical fallback (down = deeper).
    public static let verticalMMPerPoint = 0.1
    /// The expand's horizontal fallback — #354's knob scrub.
    public static let expandMMPerPoint = 0.05
    /// How far outside the face's outline the expand knob sits.
    public static let expandOffset: CGFloat = 12

    /// The box texts: the list's and the handle's are this one function.
    public static func depthText(_ mm: Double) -> String { String(format: "%.1f mm", mm) }
    public static func expandText(_ mm: Double) -> String { String(format: "%@%.1f mm", mm < 0 ? "−" : "+", abs(mm)) }
    /// The boxes' number (the unit is the box's own): "25.0", "+0.0", "−2.0" — the list's and the handle's, one formatter.
    public static func boxNumber(_ mm: Double, signed: Bool) -> String {
        signed ? String(format: "%@%.1f", mm < 0 ? "−" : "+", abs(mm)) : String(format: "%.1f", mm)
    }

    /// The millimetres a drag of `translation` adds to the depth: along the normal projected from `floor` to `deeper` (the
    /// floor moved 10 mm deeper), or screen-vertically (down = deeper) when that projects under 30 pt.
    public static func depthDelta(translation t: CGSize, floor: CGPoint?, deeper: CGPoint?) -> (mm: Double, vertical: Bool) {
        if let a = floor, let b = deeper {
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let len = hypot(v.dx, v.dy)
            if len >= shortAxisPointsPer10MM {
                let along = (t.width * v.dx + t.height * v.dy) / len
                return (Double(along / len) * 10, false)
            }
        }
        return (Double(t.height) * verticalMMPerPoint, true)
    }

    /// The depth a drag reaches from `seed`: the delta, #354's magnets (with their hysteresis), clamped 1–50.
    public static func dragDepth(seed: Double, translation: CGSize, floor: CGPoint?, deeper: CGPoint?,
                                 candidates: [LatticeDepthDetent.Candidate],
                                 held: LatticeDepthDetent.Candidate?) -> (mm: Double, held: LatticeDepthDetent.Candidate?, snapped: Bool) {
        let raw = LatticeSlabDepth.clamp(seed + depthDelta(translation: translation, floor: floor, deeper: deeper).mm)
        let r = LatticeDepthDetent.resolve(rawMM: raw, candidates: candidates, current: held)
        return (LatticeSlabDepth.clamp(r.mm), r.snapped, r.didSnap)
    }

    /// The expand a drag reaches from `seed`: along the knob's outward direction (projected from `knob` to `outward`, the
    /// knob moved 10 mm out), else horizontal; #354's clamp and snap to 0.
    public static func dragExpand(seed: Double, translation t: CGSize, knob: CGPoint?, outward: CGPoint?) -> Double {
        var d = Double(t.width) * expandMMPerPoint
        if let a = knob, let b = outward {
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let len = hypot(v.dx, v.dy)
            if len >= shortAxisPointsPer10MM { d = Double((t.width * v.dx + t.height * v.dy) / len / len) * 10 }
        }
        return LatticeSlabExpand.snapped(LatticeSlabExpand.clamp(seed + d))
    }

    /// The model-space points a handle needs (from #354's own plane): the floor (the knob), 10 mm deeper, the face's
    /// centre, and the expand knob with a point 10 mm further out.
    public struct Geometry: Equatable, Sendable {
        public let floor: SIMD3<Float>
        public let deeper: SIMD3<Float>
        public let faceCentre: SIMD3<Float>
        public let expandKnob: SIMD3<Float>?
        public let expandOut: SIMD3<Float>?
    }

    public static func geometry(_ plane: ProjectModel.LatticeDepthPlane, expandMM: Double) -> Geometry {
        let h = plane.handle
        let n = simd_length(h.planeNormal) > 1e-6 ? simd_normalize(h.planeNormal) : SIMD3<Float>(0, 0, -1)
        let knob = LatticeSlabExpand.knobAnchor(anchor: h.anchor, normal: h.planeNormal,
                                                baseMM: FlexibleLatticeHandles.expandBaseMM, expandMM: expandMM)
        var out: SIMD3<Float>? = nil
        if let k = knob {
            let d = k - h.anchor
            let l = simd_length(d)
            if l > 1e-6 { out = k + d / l * 10 }
        }
        return Geometry(floor: h.anchor, deeper: h.anchor + n * 10, faceCentre: h.planeOrigin, expandKnob: knob, expandOut: out)
    }
    /// #354's own base offset for the expand knob (WorkspacePlaceholder.latticeExpandKnobBaseMM is private: the same 8 mm).
    public static let expandBaseMM: Float = 8
}

// MARK: - the stage's side: one undo step per drag, X-ray while it drags

extension FlexibleMainStage {
    /// A handle drag starts: the step before it is sealed (so the drag is ONE undo step), X-ray turns on (the prism sits
    /// inside the part) — his choice remembered to put back.
    func beginHandleDrag(_ project: ProjectModel, key: String) {
        guard faceUI.dragging == nil else { return }
        project.sealUndoStep()
        faceUI.dragging = key
        faceUI.xrayBeforeDrag = xrayOn
        if !xrayOn { xrayOn = true }
    }

    /// …and ends: sealed as one step, X-ray back as it was, the cards refreshed once.
    func endHandleDrag(_ project: ProjectModel, cardsChanged: () -> Void) {
        guard faceUI.dragging != nil else { return }
        project.sealUndoStep()
        faceUI.dragging = nil
        faceUI.held = nil
        if let x = faceUI.xrayBeforeDrag, x != xrayOn { xrayOn = x }
        faceUI.xrayBeforeDrag = nil
        cardsChanged()
    }
}

// MARK: - the views

/// One handle: the disc (⇕ depth / ↔ expand) at its point, and its number box beside it.
struct FlexibleHandleDisc: View {
    let symbol: String
    let active: Bool
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(DS.Color.textPrimary.color)
            .frame(width: FlexibleLatticeHandles.disc, height: FlexibleLatticeHandles.disc)
            .background(Circle().fill(DS.Color.chipSolid.color.opacity(0.94))
                .overlay(Circle().strokeBorder((active ? DS.Color.accent : DS.Color.strokeStrong).color, lineWidth: active ? 2 : 1)))
            .dsShadow(DS.Shadow.panel)
            .frame(width: FlexibleLatticeHandles.hit, height: FlexibleLatticeHandles.hit)
            .contentShape(Circle())
    }
}
