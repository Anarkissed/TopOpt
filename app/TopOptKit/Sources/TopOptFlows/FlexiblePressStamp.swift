// FlexiblePressStamp — an edge's or corner's Shape = Stamp: ONE stamp sitting on the edge (or the corner), aligned to it alone (task
// 2026-09-29-flexible-screens, round 7 batch R7-E4). His words, 2026-10-14: "A stamp should work as on any face - except from the
// edge/corner and aligned to it alone." His ruling of 2026-10-19 ~14:50: FRONT-END FIRST — the stamp is drawn, placed and edited
// here; laying it on core's press grid (rasteriseStamps), design_stamp on the press entry and core's check_stamp wait for the
// back-end phase (FlexibleBackend.sendsPresses off: nothing of a press reaches core).
//
// ★ WHERE IT SITS (stored EDGE-RELATIVE, like the fold curves, so a depth or angle change keeps it on the edge): an edge's stamp
// centre is ON the edge's line — `centreU` = mm along the line from its start (the span's own measure), `centreV` = 0 always; its
// `rotationDeg` turns it FROM THE EDGE (0: its width runs along the edge). A corner's centre is the vertex (0, 0) and only its size
// and turn change; its turn is measured from the corner's first edge. Core's (u, v) of the centre (to_uvt) is the back-end's.
// ★ HOW IT MOVES: its handle slides ONLY along the edge, within [½ its reach along the edge, L − ½] of the span (a stamp longer than
// the edge sits at the middle). A corner stamp has no move handle.
// ★ WHAT IS DRAWN: the outline laid in the plane ⟂ the arrow through the centre, carried along the arrow onto the part (the first
// member face it meets) — so it folds over the edge as the press would meet it.
// ★ ITS DEFAULT: the library's order (the face stamp's: palm, thumb, fingertip, then the rest) — the first that fits 90 % of the
// flat prism's footprint with its long side along the edge; none fits → the smallest, scaled to fit.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public enum FlexiblePressStamp {
    /// ★ RED CONTROL only (FlexiblePressStampTests): the face handle's free (u, v) drag — a drag across the edge moves it off.
    nonisolated(unsafe) static var controlFreeDrag = false

    /// ★ R7-E5 (his answer of 2026-10-19 ~17:50: "Stamp turn: 0° = the long side along the edge (turning away counts up)"): the
    /// turn he reads and types is measured from the stamp's LONG side lying along the edge, whatever its own width/length axes
    /// (stored `rotationDeg` turns its width from the edge — unchanged, so saved stamps keep their place). 0 ≤ shown < 180 (a
    /// stamp's outline repeats every half turn).
    public static func longSideBase(_ p: FlexibleStampPlacement) -> Double { p.lengthMM > p.widthMM ? 90 : 0 }
    /// ★ RED CONTROL only: E4's box — the stored turn shown as it is (90° for a stamp whose length is its long side).
    nonisolated(unsafe) static var controlStoredTurn = false
    public static func shownTurn(_ p: FlexibleStampPlacement) -> Double {
        if controlStoredTurn { return p.rotationDeg }
        let t = (p.rotationDeg - longSideBase(p)).truncatingRemainder(dividingBy: 180)
        let u = t < 0 ? t + 180 : t
        return u >= 180 - 1e-9 ? 0 : u
    }
    /// The stored turn for a typed one (`deg` from the long side along the edge).
    public static func storedTurn(shown deg: Double, _ p: FlexibleStampPlacement) -> Double {
        if controlStoredTurn { return deg.truncatingRemainder(dividingBy: 360) }
        return (deg + longSideBase(p)).truncatingRemainder(dividingBy: 360)
    }

    /// The stamp's frame in the plane ⟂ the arrow: x = the edge (a corner: its first edge) seen down the arrow, y = d × x.
    public static func frame(_ s: FlexibleStrip, direction d: SIMD3<Double>) -> (x: SIMD3<Double>, y: SIMD3<Double>)? {
        let e: SIMD3<Double>?
        if let l = FlexibleFlatPrism.line(s) { e = l.dir } else { e = FlexibleFlatPrism.cornerEdges(s).first }
        guard let e, let x = FlexiblePressAim.unit(e - simd_dot(e, d) * d), let y = FlexiblePressAim.unit(simd_cross(d, x)) else { return nil }
        return (x, y)
    }

    /// ★ THE CENTRE on the part's edge (a corner: its vertex).
    public static func centre(_ s: FlexibleStrip, _ p: FlexibleStampPlacement) -> SIMD3<Double>? {
        if let l = FlexibleFlatPrism.line(s) { return l.origin + l.dir * p.centreU }
        return s.kind == .corner ? s.members.first?.origin : nil
    }

    /// How far the stamp reaches along the edge (its outline's extent along x after its turn).
    public static func reachAlong(_ p: FlexibleStampPlacement) -> Double {
        let th = p.rotationDeg * .pi / 180
        return Swift.abs(p.widthMM * cos(th)) + Swift.abs(p.lengthMM * sin(th))
    }

    /// Where its centre may go along the edge (mm from the line's start): [s0 + ½ reach, s1 − ½ reach], or the middle.
    public static func range(_ s: FlexibleStrip, _ p: FlexibleStampPlacement) -> ClosedRange<Double>? {
        guard let l = FlexibleFlatPrism.line(s) else { return nil }
        let half = reachAlong(p) / 2, lo = l.s0 + half, hi = l.s1 - half
        if lo > hi { let m = (l.s0 + l.s1) / 2; return m...m }
        return lo...hi
    }

    /// ★ A drag of the handle by `delta` (model mm, any direction): only its part along the edge moves the centre, clamped to
    /// `range`; across the edge it stays 0. A corner stamp does not move.
    public static func dragged(_ s: FlexibleStrip, _ p: FlexibleStampPlacement, by delta: SIMD3<Double>) -> FlexibleStampPlacement {
        guard let l = FlexibleFlatPrism.line(s), let r = range(s, p) else { return p }
        var q = p
        q.centreU = Swift.min(r.upperBound, Swift.max(r.lowerBound, p.centreU + simd_dot(delta, l.dir)))
        if controlFreeDrag {   // (RED CONTROL: the face handle's free drag)
            q.centreU = p.centreU + simd_dot(delta, l.dir)
            q.centreV = p.centreV + simd_length(delta - simd_dot(delta, l.dir) * l.dir)
        } else {
            q.centreV = 0
        }
        return q
    }

    /// A point carried along the arrow onto the part (the convex fold of the member faces): the deepest of the member planes it
    /// enters — nil when the arrow does not enter one.
    static func onPart(_ q: SIMD3<Double>, _ s: FlexibleStrip, direction d: SIMD3<Double>) -> SIMD3<Double>? {
        var t = -Double.infinity
        for m in s.members {
            guard let n = FlexibleFlatPrism.inwardNormal(m, toward: d) else { continue }
            let dn = simd_dot(d, n)
            guard dn > 1e-9 else { continue }
            t = Swift.max(t, simd_dot(m.origin - q, n) / dn)
        }
        return t.isFinite ? q + d * t : nil
    }

    /// ★ The outline as drawn: an ellipse of its width × length, turned from the edge, laid ⟂ the arrow and carried onto the part.
    public static func outline(_ s: FlexibleStrip, _ p: FlexibleStampPlacement, direction d: SIMD3<Double>, n: Int = 48) -> [SIMD3<Double>] {
        guard let c = centre(s, p), let f = frame(s, direction: d) else { return [] }
        let th = p.rotationDeg * .pi / 180
        let ax = f.x * cos(th) + f.y * sin(th), ay = f.y * cos(th) - f.x * sin(th)
        return (0...n).compactMap { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return onPart(c + ax * (cos(a) * p.widthMM / 2) + ay * (sin(a) * p.lengthMM / 2), s, direction: d)
        }
    }

    /// The flat prism's footprint seen down the arrow: (along the edge, across it) — a corner: its smallest leg, both ways.
    public static func footprint(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut) -> (along: Double, across: Double) {
        let d = c.direction
        if let l = FlexibleFlatPrism.line(s) {
            let mid = (l.s0 + l.s1) / 2
            var across = 0.0
            for k in s.members.indices {
                guard let a = s.members[k].away.first, let w = FlexibleFlatPrism.reach(s, member: k, c, along: mid), w.isFinite else { continue }
                across += w * simd_length(a - simd_dot(a, d) * d)
            }
            return (l.s1 - l.s0, across)
        }
        let legs = FlexibleFlatPrism.cornerEdges(s).compactMap { e -> Double? in
            let de = simd_dot(e, d)
            return de > 1e-9 ? (c.depthMM / de) * simd_length(e - de * d) : nil
        }
        let leg = legs.min() ?? 0
        return (leg, leg)
    }

    /// ★ THE DEFAULT: the library's order, the first that fits 90 % of the footprint with its long side along the edge (none: the
    /// smallest, scaled to fit); centred on the edge's middle (a corner: on its vertex); its press's weight.
    public static func seed(_ s: FlexibleStrip, _ c: FlexibleFlatPrism.Cut, library: FlexibleStampLibrary?, weightKg: Double) -> FlexibleStampPlacement? {
        guard let lib = library else { return nil }
        let fp = footprint(s, c)
        guard fp.along > 0, fp.across > 0 else { return nil }
        let order = ["palm", "thumb", "fingertip"].compactMap { lib.shape($0) } + lib.stamps.filter { $0.shape != "whole_face" }
        guard !order.isEmpty else { return nil }
        func placed(_ sh: FlexibleStampShape, scale: Double) -> FlexibleStampPlacement {
            let w = sh.naturalSizeMM.width * scale, l = sh.naturalSizeMM.length * scale
            let along = FlexibleFlatPrism.line(s).map { ($0.s0 + $0.s1) / 2 } ?? 0
            // its long side along the edge: rotation 0 when its width is the longer side, else a quarter turn
            return FlexibleStampPlacement(source: .library(sh.id), widthMM: w, lengthMM: l, rotationDeg: w >= l ? 0 : 90,
                                          centreU: along, centreV: 0, weightKg: weightKg, rigid: sh.press == "rigid")
        }
        for sh in order {
            let a = Swift.max(sh.naturalSizeMM.width, sh.naturalSizeMM.length), b = Swift.min(sh.naturalSizeMM.width, sh.naturalSizeMM.length)
            if a <= 0.9 * fp.along && b <= 0.9 * fp.across { return placed(sh, scale: 1) }
        }
        let smallest = order.min { $0.naturalSizeMM.width * $0.naturalSizeMM.length < $1.naturalSizeMM.width * $1.naturalSizeMM.length }!
        let a = Swift.max(smallest.naturalSizeMM.width, smallest.naturalSizeMM.length), b = Swift.min(smallest.naturalSizeMM.width, smallest.naturalSizeMM.length)
        let k = Swift.min(0.9 * fp.along / a, 0.9 * fp.across / b, 1)
        return placed(smallest, scale: k)
    }
}

// MARK: - the model

extension FlexibleStageModel {
    /// ★ R7-E4: an edge's or corner's Shape [Curves | Stamp] — Stamp lands ONE stamp on its edge (its default) unless it kept one.
    /// A tap on the chip already chosen changes nothing.
    public func setPressShape(_ id: UUID, _ shape: String) {
        guard let p = settings.press(id), let st = p.strip else { return }
        guard (shape == "stamp") != p.settings.isStampShape else { curvePoint = nil; return }
        let seed = shape == "stamp" && p.settings.designStamp == nil
            ? flatCut(id).flatMap { FlexiblePressStamp.seed(st, $0, library: library, weightKg: p.settings.weightKg) } : nil
        edit({ s in
            guard var q = s.press(id) else { return }
            if shape == "stamp" { if q.settings.designStamp == nil { q.settings.designStamp = seed }; q.settings.shape = "stamp" }
            else { q.settings.shape = "curves" }
            if q.foldCurves != true {   // the first edit writes the fold form (the curves the flat prism)
                q.settings.curveX = FlexiblePressCurveBaselines.ones; q.settings.curveY = FlexiblePressCurveBaselines.ones
                q.settings.curveCentreEdge = FlexiblePressCurveBaselines.ones; q.foldCurves = true
            }
            s.setPress(q)
        }, recompute: false)
        curvePoint = nil
    }

    /// ★ R7-E4: one curve of a flat press (multipliers ≤ 1) — the page's undo seals it; `save` on the drag's end.
    public func setPressCurve(_ id: UUID, _ axis: FlexiblePressCurveBaselines.Axis, _ c: FlexCurve) {
        edit({ s in
            guard var q = s.press(id), q.strip != nil else { return }
            FlexiblePressCurveBaselines.set(&q, axis, c)
            s.setPress(q)
        }, recompute: false)
    }

    /// ★ R7-E4: the flat press's stamp changed (size, turn, which one, or slid along the edge).
    public func updatePressStamp(_ id: UUID, save saving: Bool = true, _ change: (inout FlexibleStampPlacement) -> Void) {
        edit({ s in
            guard var q = s.press(id), let st = q.strip, var p = q.settings.designStamp else { return }
            change(&p)
            if st.kind == .edge, let r = FlexiblePressStamp.range(st, p) {   // it stays on the edge, within its span
                p.centreU = Swift.min(r.upperBound, Swift.max(r.lowerBound, p.centreU)); p.centreV = 0
            } else if st.kind == .corner { p.centreU = 0; p.centreV = 0 }
            q.settings.designStamp = p
            s.setPress(q)
        }, recompute: false)
        if saving { save() }
    }

    /// ★ R7-E4: [Top] / [45°] — the page turns the camera there.
    public func showPressCurve(_ id: UUID, _ view: FlexiblePressCurveBaselines.View) {
        pressViewRequest = FlexiblePressViewRequest(press: id, view: view, token: (pressViewRequest?.token ?? 0) + 1)
    }
}

// MARK: - on the part

/// ★ R7-E4: the working flat press's stamp — its outline folded over the edge and ONE handle that slides along the edge (a corner:
/// the outline only). Never under the chrome.
struct FlexiblePressStampHandle: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    let keepOut: [CGRect]
    var clip: [CGRect]? = nil
    /// ★ U21 FIX 1 (the checker of batch G: "the thumb pad's dashed outline stays at rest while Edge 12 dents under it"): with Bend
    /// on, the outline sits on the bent edge (`drawnOutline`). Its handle stays on the surface he grabs.
    var pose: FlexibleBendPose? = nil
    @State private var dragging: FlexibleStampPlacement?

    /// ★ RED CONTROL only: an edge press's outline (and indent) drawn at rest under Bend (batch G).
    nonisolated(unsafe) static var controlEdgeOutlineAtRest = false

    /// The outline as drawn, in the world: on the part, at the full bend while Bend shows (pure: the tests read it). On the edge
    /// preview (`pose.edges`) the outline of `cut`'s stamp sits on the pocket's floor (`EdgePush.whole`); in the 3D sim, the field.
    static func drawnOutline(_ st: FlexibleStrip, _ stamp: FlexibleStampPlacement, cut c: FlexibleFlatPrism.Cut, pose: FlexibleBendPose?) -> [SIMD3<Double>] {
        let o = FlexiblePressStamp.outline(st, stamp, direction: c.direction)
        guard let pose, !controlEdgeOutlineAtRest else { return o }
        if !FlexibleBendPose.controlNearestVertexEdges, !FlexibleBendPose.controlNearestVertexPose, let e = pose.edges.first(where: { $0.cut == c }) {
            return o.map { $0 + e.whole($0) * Double(pose.k) }
        }
        return o.map { pose.apply($0) }
    }

    private func screen(_ w: SIMD3<Double>) -> CGPoint? { projection?.project(SIMD3<Float>(w)) }

    var body: some View {
        let id = FlexibleFlatPrismUI.workingPress(model)
        let p = id.flatMap { model.press($0) }
        let vp = projection?.viewportSize ?? .zero
        if let id, let p, let st = p.strip, p.settings.isStampShape, let stamp = p.settings.designStamp, let c = model.flatCut(id) {
            ZStack {
                Canvas { ctx, size in
                    FlexibleChromeClip.apply(&ctx, size: size, holes: clip ?? keepOut)
                    var path = Path()
                    for (i, q) in Self.drawnOutline(st, stamp, cut: c, pose: pose).compactMap(screen).enumerated() {
                        i == 0 ? path.move(to: q) : path.addLine(to: q)
                    }
                    ctx.stroke(path, with: .color(FlexibleStageStyle.onPart), style: StrokeStyle(lineWidth: 2, dash: stamp.rigid ? [] : [6, 4]))
                }
                .allowsHitTesting(false)
                // found by looking: on his Edge 16 the stamp's centre sat under the depth chip (the arrow's head, drawn over it) — the
                // handle keeps the face stamp's 56 pt from the chip, with a leader to the centre (its drag is relative)
                if st.kind == .edge, let w = FlexiblePressStamp.centre(st, stamp).flatMap({ FlexiblePressStamp.onPart($0 - c.direction * 0.01, st, direction: c.direction) }),
                   let at = screen(w),   // (★ U21 fix 1: the handle stays on the surface — posed, an edge stamp's centre lands on the arrow's head, under the depth chip)
                   case let q = FlexibleFaceStampHandle.handlePoint(centre: at, chip: screen(FlexibleFlatPrismUI.arrow(st, c, lengthMM: 0).head)),
                   FlexibleDepthChipLayout.shows(q, dragging: dragging != nil, keepOut: keepOut, viewport: vp) {
                    if q != at {
                        Path { p in p.move(to: at); p.addLine(to: q) }
                            .stroke(FlexibleStageStyle.onPart.opacity(0.7), lineWidth: 1.5).allowsHitTesting(false)
                    }
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.chipSolid.color)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(FlexibleStageStyle.onPart))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(q)
                        .gesture(drag(id, st, stamp))
                        .accessibilityIdentifier("flexible-press-stamp-handle")
                }
            }
        }
    }

    /// Screen drag → mm along the edge (through the edge's projected direction at the centre).
    private func drag(_ id: UUID, _ st: FlexibleStrip, _ stamp: FlexibleStampPlacement) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                if dragging == nil { dragging = stamp }
                guard let start = dragging, let l = FlexibleFlatPrism.line(st), let c0 = FlexiblePressStamp.centre(st, start),
                      let a = screen(c0), let b = screen(c0 + l.dir * 10) else { return }
                let e = CGVector(dx: b.x - a.x, dy: b.y - a.y), len2 = e.dx * e.dx + e.dy * e.dy
                guard len2 > 1e-6 else { return }
                let mm = Double((g.translation.width * e.dx + g.translation.height * e.dy) / len2) * 10
                let moved = FlexiblePressStamp.dragged(st, start, by: l.dir * mm)
                model.updatePressStamp(id, save: false) { $0.centreU = moved.centreU; $0.centreV = moved.centreV }
            }
            .onEnded { _ in dragging = nil; model.save() }
    }
}
