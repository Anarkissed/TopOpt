// FlexiblePressCurveBaselines — the two sides of a curve INSIDE an edge's or corner's flat prism, and the two views it is edited
// in (task 2026-09-29-flexible-screens, round 7 batch R7-E4). His words, 2026-10-14: "create two sides of a curve/add a stamp. The
// curve should be viewable from the top and from a 45 degree angle on the side of the body." His default (2026-10-18 ~16:50, told
// to him): the two-sided curve starts as the flat prism's own straight lines, one side on each face, bendable softer but never past
// the flat face; seen from [Top] and [45°]. His ruling of 2026-10-19 ~14:50 (a core tenet): FRONT-END FIRST — nothing of this goes
// to core until the back-end phase (FlexibleBackend.sendsPresses stays off; the design's F × M map, rasterised press stamps,
// design_stamp and check_stamp are the back-end backlog).
//
// ★ STORED AS MULTIPLIERS of the flat prism (0…1, all ones = the flat prism), in FOLD coordinates, so a depth or angle change keeps
// his shape and the drawn curve follows the prism: press.settings.curveY = ACROSS (0 = the first face's trace, ½ = the edge, 1 =
// the second face's trace), curveX = ALONG (the edge's span, start → stop), curveCentreEdge = a CORNER's one curve (core holds one:
// rim 0 → vertex 1). A press never edited (`FlexiblePress.foldCurves` nil) reads as all ones, whatever it saved before E4.
// ★ DRAWN with FlexibleCurveEditor unchanged: its baseline is ON the flat face P (the traces and the point of P under the edge),
// up = −d, amplitude = h — so a stored y = 1 (the editor's "squishiest", drawn on its baseline) lies on the flat face, and y < 1
// lifts toward the part (softer). A multiplier never passes 1 (storedY clamps; `clamped`), so no point ever passes the flat face.
// ★ THE VIEWS: [Top] = the gizmo's top view; [45°] = 45° up from the side the arrow comes from. Down the arrow (D-AP-13's turn) the
// curve has no height, so it is never offered for editing.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public enum FlexiblePressCurveBaselines {
    /// The flat prism itself: every multiplier 1.
    public static let ones = FlexCurve(x: [0, 1], y: [1, 1])

    /// Which curve of a press.
    public enum Axis: String, CaseIterable, Hashable, Sendable { case across, along, corner }

    /// ★ RED CONTROL only (FlexiblePressCurveTests): ABSOLUTE squish stored (y × the flat prism's fraction at the point) — a deeper
    /// prism leaves the drawing behind.
    nonisolated(unsafe) static var controlAbsolute = false
    /// ★ RED CONTROL only: the face's own X / Y baselines on one member's rim (the face press's rule), not the fold over the edge.
    nonisolated(unsafe) static var controlFaceBaselines = false
    /// ★ RED CONTROL only: a corner drawn as three independent sides.
    nonisolated(unsafe) static var controlThreeCornerSides = false

    /// The curves he edits on a press: an edge's across and along, a corner's one.
    public static func axes(_ s: FlexibleStrip) -> [Axis] { s.kind == .corner ? [.corner] : [.across, .along] }

    /// ★ THE STORED MULTIPLIERS (ones until he first bends one).
    public static func multipliers(_ p: FlexiblePress, _ axis: Axis) -> FlexCurve {
        guard p.foldCurves == true else { return ones }
        switch axis {
        case .across: return p.settings.curveY
        case .along: return p.settings.curveX
        case .corner: return p.settings.curveCentreEdge
        }
    }

    /// A multiplier never passes the flat face (≤ 1) nor goes negative.
    public static func clamped(_ c: FlexCurve) -> FlexCurve { FlexCurve(x: c.x, y: c.y.map { Swift.min(1, Swift.max(0, $0)) }) }

    /// ★ THE ONE WRITE: curve `axis` of `p` set to `c` (clamped). The first write turns every curve into multipliers (the others ones).
    public static func set(_ p: inout FlexiblePress, _ axis: Axis, _ c: FlexCurve, fraction: (Double) -> Double = { _ in 1 }) {
        if p.foldCurves != true {
            p.settings.curveX = ones; p.settings.curveY = ones; p.settings.curveCentreEdge = ones
            p.foldCurves = true
        }
        var m = clamped(c)
        if controlAbsolute { m = FlexCurve(x: m.x, y: zip(m.x, m.y).map { $1 * fraction($0) }) }   // (RED CONTROL: absolute)
        switch axis {
        case .across: p.settings.curveY = m
        case .along: p.settings.curveX = m
        case .corner: p.settings.curveCentreEdge = m
        }
    }

    // MARK: - the baselines (on the flat face P)

    /// Points per baseline.
    static let samples = 32

    /// ★ ACROSS: the fold over the edge at its middle — the first face's trace (0) → the point of P under the edge along the arrow
    /// (½) → the second face's trace (1); up = −d, amplitude = h.
    public static func across(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut) -> FlexibleCurveBaseline? {
        guard let l = FlexibleFlatPrism.line(s), s.members.count == 2,
              let aa = s.members[0].away.first, let ab = s.members[1].away.first else { return nil }
        let mid = (l.s0 + l.s1) / 2
        let e = l.origin + l.dir * mid
        guard let wa = FlexibleFlatPrism.reach(s, member: 0, c, along: mid), let wb = FlexibleFlatPrism.reach(s, member: 1, c, along: mid),
              wa.isFinite, wb.isFinite, wa >= 0, wb >= 0 else { return nil }
        let ta = e + aa * wa, tb = e + ab * wb, foot = c.onPlane(e)
        if controlFaceBaselines {   // (RED CONTROL: a face press's baseline — one member's rim, on the face)
            let pts = (0...samples).map { i -> SIMD3<Double> in e + aa * (wa * Double(i) / Double(samples)) }
            return FlexibleCurveBaseline(points: pts, up: SIMD3<Double>.zero - c.direction, amplitudeMM: c.depthMM)
        }
        let pts = (0...samples).map { i -> SIMD3<Double> in
            let t = Double(i) / Double(samples)
            return t <= 0.5 ? simd_mix(ta, foot, SIMD3(repeating: 2 * t)) : simd_mix(foot, tb, SIMD3(repeating: 2 * t - 1))
        }
        return FlexibleCurveBaseline(points: pts, up: SIMD3<Double>.zero - c.direction, amplitudeMM: c.depthMM)
    }

    /// ★ ALONG: the edge's span carried along the arrow onto P (start 0 → stop 1).
    public static func along(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut) -> FlexibleCurveBaseline? {
        guard let l = FlexibleFlatPrism.line(s), l.s1 > l.s0 else { return nil }
        let pts = (0...samples).map { i -> SIMD3<Double> in
            c.onPlane(l.origin + l.dir * (l.s0 + (l.s1 - l.s0) * Double(i) / Double(samples)))
        }
        return FlexibleCurveBaseline(points: pts, up: SIMD3<Double>.zero - c.direction, amplitudeMM: c.depthMM)
    }

    /// ★ A CORNER's side on member k: the middle of its trace (0, the rim) → the point of P over the vertex (1, core's centre).
    public static func cornerSide(_ s: FlexibleStrip, member k: Int, _ c: FlexibleFlatPrism.Cut) -> FlexibleCurveBaseline? {
        guard s.kind == .corner, k < s.members.count else { return nil }
        let legs = FlexibleFlatPrism.edges(s.members[k]).compactMap { e -> SIMD3<Double>? in
            let de = simd_dot(e, c.direction)
            return de > 1e-9 ? c.apex + e * (c.depthMM / de) : nil
        }
        guard legs.count == 2 else { return nil }
        let rim = (legs[0] + legs[1]) / 2, top = c.onPlane(c.apex)
        let pts = (0...samples).map { i in simd_mix(rim, top, SIMD3(repeating: Double(i) / Double(samples))) }
        return FlexibleCurveBaseline(points: pts, up: SIMD3<Double>.zero - c.direction, amplitudeMM: c.depthMM)
    }

    /// ★ A CORNER's one curve, drawn two-sided on the two faces that face the camera most (the largest on screen): the same curve on
    /// each side (core holds one). `project` is the page's projection (nil: members 0 and 1).
    public static func cornerSides(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut,
                                   project: ((SIMD3<Double>) -> CGPoint?)? = nil) -> [Int] {
        guard s.kind == .corner else { return [] }
        let all = Array(s.members.indices)
        if controlThreeCornerSides { return all }   // (RED CONTROL: three sides)
        guard let project else { return Array(all.prefix(2)) }
        func area(_ k: Int) -> Double {
            let legs = FlexibleFlatPrism.edges(s.members[k]).map { c.apex + $0 * c.depthMM }
            guard legs.count == 2, let a = project(c.apex), let b = project(legs[0]), let d = project(legs[1]) else { return 0 }
            return Swift.abs(Double((b.x - a.x) * (d.y - a.y) - (b.y - a.y) * (d.x - a.x))) / 2
        }
        return Array(all.sorted { area($0) > area($1) }.prefix(2)).sorted()
    }

    // MARK: - the two views

    /// [Top] and [45°]: the curve's two editing views (icons, never words).
    public enum View: String, CaseIterable, Hashable, Sendable { case top, deg45 }

    /// ★ The eye direction (the stage's settled space, Y up) of a view of a press whose arrow is `arrow` (settled, into the part).
    /// [Top]: the gizmo's top. [45°]: 45° up from the side the arrow comes from (an arrow straight up or down: from the front).
    public static func eye(_ v: View, arrow: SIMD3<Float>) -> SIMD3<Float> {
        switch v {
        case .top: return OrientationGizmo.region("Top")?.direction ?? SIMD3(0, 1, 0)
        case .deg45:
            let out = SIMD3<Float>.zero - arrow
            let h = SIMD3<Float>(out.x, 0, out.z)
            let base = simd_length(h) > 1e-4 ? simd_normalize(h) : SIMD3<Float>(0, 0, 1)
            return simd_normalize(base * Float(0.5).squareRoot() + SIMD3<Float>(0, 1, 0) * Float(0.5).squareRoot())
        }
    }

    /// ★ What the two views frame (found by looking: on his live pad the whole part filled the view and Edge 16's 3 mm curves were a
    /// few points under the panel): the press's curves and its arrow's reach — their centre and radius (model mm).
    public static func focus(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut) -> (centre: SIMD3<Double>, radius: Double) {
        var pts: [SIMD3<Double>] = [c.apex, c.onPlane(c.apex), c.apex - c.direction * c.depthMM]
        let bs = s.kind == .corner ? s.members.indices.compactMap { cornerSide(s, member: $0, c) } : [across(s, c), along(s, c)].compactMap { $0 }
        for b in bs { pts += [b.at(0), b.at(0.5), b.at(1), b.world(0.5, 1)] }
        if let l = FlexibleFlatPrism.line(s) { pts += [l.origin + l.dir * l.s0, l.origin + l.dir * l.s1] }
        let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
        return ((lo + hi) / 2, Swift.max(simd_length(hi - lo) / 2, 2 * c.depthMM, 5))
    }

    /// ★ Where the press goes on screen when the page turns to it (found by the suite: E4's Shape row makes the panel one line
    /// taller, and at 11" and the mini in portrait the press, centred on the stage, sat under it — its knob and boxes hidden): the
    /// middle of the larger free area, right of the panel or above it, below the top line. nil: no panel (the stage's centre).
    public static func freeCentre(stage: CGSize, panel: CGRect?, top: CGFloat, obstacles: [CGRect] = []) -> CGPoint? {
        guard let p = panel, stage.width > 0, stage.height > 0 else { return nil }
        let right = CGRect(x: p.maxX, y: top, width: Swift.max(0, stage.width - p.maxX), height: Swift.max(0, stage.height - top))
        let above = CGRect(x: 0, y: top, width: stage.width, height: Swift.max(0, p.minY - top))
        // found by looking: the legend's pill sat across the right area's middle and hid the stamp's handle — each area is split
        // by the chrome that crosses it, and the tallest piece wins
        func pieces(_ r: CGRect) -> [CGRect] {
            var out = [r]
            for o in obstacles where !o.isNull && !o.isEmpty {
                out = out.flatMap { a -> [CGRect] in
                    guard a.intersects(o) else { return [a] }
                    return [CGRect(x: a.minX, y: a.minY, width: a.width, height: Swift.max(0, o.minY - a.minY)),
                            CGRect(x: a.minX, y: o.maxY, width: a.width, height: Swift.max(0, a.maxY - o.maxY))]
                }
            }
            return out
        }
        let all = (pieces(right) + pieces(above)).filter { $0.width > 88 && $0.height > 88 }
        guard let pick = all.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return CGPoint(x: pick.midX, y: pick.midY)
    }

    /// The camera target that puts world point `w` at screen point `at` (stage `size`), for a camera looking from `rot` at `distance`.
    public static func target(placing w: SIMD3<Float>, at: CGPoint, size: CGSize, rot: simd_float3x3, distance: Float, fovY: Float) -> SIMD3<Float> {
        guard size.height > 0 else { return w }
        let perPoint = 2 * distance * tan(fovY / 2) / Float(size.height)
        let dx = Float(at.x - size.width / 2) * perPoint, dy = Float(at.y - size.height / 2) * perPoint
        // the view rotation's rows: screen right and screen up in the world
        let right = SIMD3<Float>(rot[0][0], rot[1][0], rot[2][0]), up = SIMD3<Float>(rot[0][1], rot[1][1], rot[2][1])
        return w - right * dx + up * dy
    }

    /// ★ How much of the curve's height shows from `eye` (1: all of it, 0: none — looking down the arrow).
    public static func heightOnScreen(eye: SIMD3<Float>, arrow: SIMD3<Float>) -> Double {
        let e = simd_normalize(eye), d = simd_normalize(arrow)
        return Double(simd_length(d - simd_dot(d, e) * e))
    }
}

/// ★ R7-E4: the page turns the camera to one of the two curve views (FlexibleStagePage).
public struct FlexiblePressViewRequest: Equatable, Sendable {
    public let press: UUID
    public let view: FlexiblePressCurveBaselines.View
    public let token: Int
}

/// ★ R7-E4: the working flat press's curves ON THE PART — an edge's across (the fold) and along, a corner's one curve on its two
/// faces nearest the camera — each with FlexibleCurveEditor unchanged; only under Curves; never under the chrome. Mounted BEFORE the
/// flat prism's own handles, so the depth chip and the knob stay on top.
struct FlexiblePressCurveLayer: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    let keepOut: [CGRect]
    var clip: [CGRect]? = nil

    struct Drawn: Identifiable {
        let id: String
        let axis: FlexiblePressCurveBaselines.Axis
        let baseline: FlexibleCurveBaseline
        let label: String
    }

    /// ★ U1, RED CONTROL only: the "Across" / "Along" words at the curves' end handles (R7-E4).
    nonisolated(unsafe) static var controlCurveWords = false

    /// What is drawn for press `id` (pure: the hosted tests read it).
    static func drawn(model m: FlexibleStageModel, press id: UUID, projection: CameraProjection?) -> [Drawn] {
        guard let p = m.press(id), let st = p.strip, !p.settings.isStampShape, let c = m.flatCut(id) else { return [] }
        if st.kind == .corner {
            let sides = FlexiblePressCurveBaselines.cornerSides(st, c, project: projection.map { pr in { pr.project(SIMD3<Float>($0)) } })
            return sides.compactMap { k in
                FlexiblePressCurveBaselines.cornerSide(st, member: k, c).map { Drawn(id: "corner-\(k)", axis: .corner, baseline: $0, label: "") }
            }
        }
        var out: [Drawn] = []
        // ★ U1 (his notes of 2026-10-20, img_1020_8: "What does "long" and "cross" mean here? … It should be the same table as
        // any face"): no word at the curve's end handle (its first letter hid under the point); RED CONTROL `controlCurveWords`
        let across = Self.controlCurveWords ? "Across" : "", along = Self.controlCurveWords ? "Along" : ""
        if let b = FlexiblePressCurveBaselines.across(st, c) { out.append(Drawn(id: "across", axis: .across, baseline: b, label: across)) }
        if let b = FlexiblePressCurveBaselines.along(st, c) { out.append(Drawn(id: "along", axis: .along, baseline: b, label: along)) }
        return out
    }

    var body: some View {
        if let id = FlexibleFlatPrismUI.workingPress(model), let p = model.press(id) {
            ZStack {
                ForEach(Self.drawn(model: model, press: id, projection: projection)) { d in
                    FlexibleCurveEditor(projection: projection, baseline: d.baseline,
                                        curve: FlexiblePressCurveBaselines.multipliers(p, d.axis),
                                        label: d.label, tint: FlexibleStageStyle.onPart,
                                        selected: selection(id, d.id),
                                        onChange: { c in model.setPressCurve(id, d.axis, c) },
                                        onCommit: { model.save() },
                                        keepOut: keepOut, clip: clip)
                }
            }
        }
    }

    /// The × of one curve, held by the model (region −1: a press's, its axis keyed by the press).
    private func selection(_ id: UUID, _ key: String) -> Binding<Int?> {
        let tag = "press:\(id.uuidString):\(key)"
        return Binding(get: { model.curvePoint.flatMap { $0.region == -1 && $0.axis == tag ? $0.index : nil } },
                       set: { model.curvePoint = $0.map { FlexCurvePoint(region: -1, axis: tag, index: $0) } })
    }
}
