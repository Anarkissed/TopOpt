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

    /// The expand a drag reaches from `seed`: along the knob's outward direction, #354's clamp and snap to 0.
    /// ★ ROUND 7 · U21 (EXPAND-DRAG-DIR, found tracing his Img6): `knob` is the TRUE projected knob (#354's anchor on screen),
    /// never the disc as drawn — the drawn disc is pushed out to keep it clear of the depth handle, and out − drawn pointed
    /// BACKWARDS in 17 of 48 views on his l-bracket (a drag out shrank the expand). The sign and the direction always come
    /// from the unit vector knob → outward; the projected 10 mm only sets the millimetres per point, and when it projects
    /// shorter than 30 pt the scale is #354's fixed 0.05 mm per point — still along that direction (the old fallback was
    /// plain horizontal, so a knob pointing left dragged backwards too). No direction at all: horizontal.
    public static func dragExpand(seed: Double, translation t: CGSize, knob: CGPoint?, outward: CGPoint?) -> Double {
        var d = Double(t.width) * expandMMPerPoint
        if let a = knob, let b = outward {
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let len = hypot(v.dx, v.dy)
            if controlOldDrag {
                if len >= shortAxisPointsPer10MM { d = Double((t.width * v.dx + t.height * v.dy) / len / len) * 10 }
            } else if len > 1e-6 {
                let along = (t.width * v.dx + t.height * v.dy) / len
                d = len >= shortAxisPointsPer10MM ? Double(along / len) * 10 : Double(along) * expandMMPerPoint
            }
        }
        return LatticeSlabExpand.snapped(LatticeSlabExpand.clamp(seed + d))
    }
    /// RED CONTROL (U21 EXPAND-DRAG-DIR): today's rule — out − knob with the plain-horizontal fallback.
    nonisolated(unsafe) static var controlOldDrag = false

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

    // MARK: - ★ ROUND 7 · U21 batch C: the two handles' icons and where they sit (his Img6 of 2026-10-21)
    //
    // His words: "The expand and depth icons look too similar and are more often than not too close together. … having
    // expand be "+" and include it next to the input in the modal so that people will associate the two. … make sure that
    // there is a large enough buffer between the two so that tapping one doesn't open the other."

    /// ONE source for the two icons: the discs on the part and the Selections list's captions read these.
    /// (Was the same SF arrow turned 90°: "arrow.up.and.down" / "arrow.left.and.right".)
    public static let depthSymbol = "arrow.up.and.down"
    public static let expandSymbol = "plus"

    /// Two SF symbol names that are the same glyph turned (up/down ⇄ left/right …) — what he could not tell apart.
    public static func rotatedTwins(_ a: String, _ b: String) -> Bool {
        func bare(_ s: String) -> String {
            var t = s
            for w in ["up.and.down", "left.and.right", "up", "down", "left", "right", "forward", "backward"] {
                t = t.replacingOccurrences(of: w, with: "*")
            }
            return t
        }
        return a != b && bare(a) == bare(b)
    }

    /// The disc's gap to its box (the HStack's spacing).
    public static let boxGap: CGFloat = 8
    /// HANDLE-GAP: the clear band between the two handle units (each = the 44 pt disc + its box, 44 pt tall).
    public static let unitGap: CGFloat = 24
    /// The expand knob is pushed along its own direction in these steps, at most this far from the floor.
    public static let pushStep: CGFloat = 4
    public static let pushMax: CGFloat = 240
    /// A box's width before it has been measured (the widest of the two, "−3.0 mm ⇕" on his l-bracket: 88 pt).
    public static let boxWidthEstimate: CGFloat = 88
    /// Below this share of horizontal, the knob sits above / below the floor and both boxes go right (the usual side).
    public static let sideDeadZone: CGFloat = 0.25

    /// One handle as a touch unit: its disc (centre) and its box on one side, 44 pt tall (the box's real tap band).
    public struct Unit: Equatable, Sendable {
        public let disc: CGPoint
        public let boxOnLeft: Bool
        public let boxWidth: CGFloat
        public var rect: CGRect {
            let w = FlexibleLatticeHandles.hit + FlexibleLatticeHandles.boxGap + boxWidth
            return CGRect(x: boxOnLeft ? disc.x + FlexibleLatticeHandles.hit / 2 - w : disc.x - FlexibleLatticeHandles.hit / 2,
                          y: disc.y - FlexibleLatticeHandles.hit / 2, width: w, height: FlexibleLatticeHandles.hit)
        }
    }

    /// Where the two handles go: the depth disc stays on the prism's floor; the expand disc is drawn at `expand.disc`
    /// (pushed out along its own direction, or — last resort — the other way: `flipped`).
    public struct Layout: Equatable, Sendable {
        public let depth: Unit
        public let expand: Unit?
        public let flipped: Bool
        public var gap: CGFloat? { expand.map { FlexibleLatticeHandles.gap(depth.rect, $0.rect) } }
    }

    /// The clear band between two rects: > 0 the width of the empty band between them in x or in y (the larger);
    /// ≤ 0 they touch or overlap (minus the smaller overlap).
    public static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(b.minX - a.maxX, a.minX - b.maxX)
        let dy = max(b.minY - a.maxY, a.minY - b.maxY)
        return max(dx, dy)
    }

    /// RED CONTROL (U21 HANDLE-GAP): today's rule — #354's 72 pt disc floor (separated), both boxes to the right, a 92 pt box.
    nonisolated(unsafe) static var controlOldLayout = false

    /// HANDLE-GAP (pure): each handle is one unit (44 pt disc + its REAL box width, 44 pt tall); each box on the side away
    /// from the other handle; the expand disc pushed along its own direction in 4 pt steps (≤ 240 pt from the floor) until
    /// the units are ≥ 24 pt apart, inside the viewport and off `keepOut`. If that cannot be had, the boxes move (both right,
    /// both left, the other way round) before the knob ever flips to the other side of the floor (the last resort).
    /// With no expand knob (group scope): the depth box right, or left when right runs off the viewport.
    /// (#354's `LatticeSlabExpand.separated` is no longer called here; it is not edited.)
    public static func layout(floor f: CGPoint, rawKnob: CGPoint?, depthBox: CGFloat, expandBox: CGFloat,
                              viewport: CGSize, keepOut: [CGRect] = []) -> Layout {
        if controlOldLayout { return oldLayout(floor: f, rawKnob: rawKnob) }
        let bounds = CGRect(origin: .zero, size: viewport)
        func fits(_ r: CGRect) -> Bool { bounds.contains(r) }
        func depthUnit(left: Bool) -> Unit { Unit(disc: f, boxOnLeft: left, boxWidth: depthBox) }
        guard let raw = rawKnob else {
            let right = depthUnit(left: false)
            return Layout(depth: !fits(right.rect) && fits(depthUnit(left: true).rect) ? depthUnit(left: true) : right,
                          expand: nil, flipped: false)
        }
        let dx = raw.x - f.x, dy = raw.y - f.y
        let d0 = hypot(dx, dy)
        let u = d0 > 1e-6 ? CGVector(dx: dx / d0, dy: dy / d0) : CGVector(dx: 1, dy: 0)
        typealias Sides = (depthLeft: Bool, expandLeft: Bool)
        func arrangements(_ ux: CGFloat) -> [Sides] {
            let away: Sides = abs(ux) < sideDeadZone ? (false, false) : (ux > 0 ? (true, false) : (false, true))
            let all: [Sides] = [(false, false), (true, true), (true, false), (false, true)]
            return [away] + all.filter { $0 != away }
        }
        var best: (layout: Layout, gap: CGFloat)?
        for flip in [false, true] {
            let dir = flip ? CGVector(dx: -u.dx, dy: -u.dy) : u
            for arr in arrangements(dir.dx) {
                var t = d0
                while t <= pushMax + 1e-6 {
                    let k = CGPoint(x: f.x + dir.dx * t, y: f.y + dir.dy * t)
                    let a = depthUnit(left: arr.depthLeft)
                    let b = Unit(disc: k, boxOnLeft: arr.expandLeft, boxWidth: expandBox)
                    let g = gap(a.rect, b.rect)
                    let ok = fits(a.rect) && fits(b.rect) && !keepOut.contains { $0.intersects(b.rect) }
                    if g >= unitGap && ok { return Layout(depth: a, expand: b, flipped: flip) }
                    if ok, g > (best?.gap ?? -.infinity) { best = (Layout(depth: a, expand: b, flipped: flip), g) }
                    t += pushStep
                }
            }
        }
        if let best { return best.layout }
        // nothing fits the viewport at all (the part at the screen's edge): the away boxes, pushed as far as allowed
        let arr = arrangements(u.dx)[0]
        let k = CGPoint(x: f.x + u.dx * max(d0, pushMax), y: f.y + u.dy * max(d0, pushMax))
        return Layout(depth: depthUnit(left: arr.depthLeft), expand: Unit(disc: k, boxOnLeft: arr.expandLeft, boxWidth: expandBox),
                      flipped: false)
    }

    /// Today's rule (R7-D2 + #354's separated): the knob kept 72 pt from the floor, both boxes to the right, 92 pt wide.
    public static func oldLayout(floor f: CGPoint, rawKnob: CGPoint?) -> Layout {
        Layout(depth: Unit(disc: f, boxOnLeft: false, boxWidth: 92),
               expand: rawKnob.map { Unit(disc: LatticeSlabExpand.separated(knob: $0, from: f), boxOnLeft: false, boxWidth: 92) },
               flipped: false)
    }
}

/// ★ U21 HANDLE-ICONS: a Selections caption over its box — the handle's own icon + "Depth mm" / "Expand mm", so the box and
/// the disc on the part read as one thing (his "include it next to the input in the modal").
struct FlexibleHandleCaption: View {
    enum Kind: String { case depth, expand }
    let kind: Kind
    /// RED CONTROL: today's text-only caption.
    nonisolated(unsafe) static var controlTextOnly = false
    var body: some View {
        HStack(spacing: 3) {
            if !Self.controlTextOnly {
                Image(systemName: kind == .depth ? FlexibleLatticeHandles.depthSymbol : FlexibleLatticeHandles.expandSymbol)
                    .font(.system(size: 9, weight: .bold))
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["selCaptionIcon-\(kind.rawValue)": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityHidden(true)
            }
            Text(kind == .depth ? FlexibleSelectionsCopy.depthCaption : FlexibleSelectionsCopy.expandCaption)
                .lineLimit(1)
        }
    }
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

/// One handle: the disc (⇕ depth / + expand — FlexibleLatticeHandles.depthSymbol / expandSymbol) at its point; its number box
/// beside it, on the side the layout picks.
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
