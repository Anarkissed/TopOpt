// FlexibleCurveEditor — the pen-tool squish curve, drawn ON THE MODEL along a face's own
// edge (task 2026-09-29-flexible-screens S2; M11, R12).
//
// ★ WHERE IT SITS. The curve's baseline is a line of points on the face — core's
// from_uv(u, v) + load × entry_t along the X edge (v = 0) or the Y edge (u = 0) — and
// the curve rises OUT of the part along −load, `amplitudeMM` at y = 1. Every frame the
// world points are projected through the live camera, so the curve turns with the part
// and its orientation is true (C1 problem #8: the frame's Y = load × X is a view from
// inside, so we draw on the model instead of mirroring a flat chart).
//
// ★ WHAT IS CORE'S. The curve through the points is core's `pen_curve_values`
// (Fritsch–Carlson); a move core's `pen_curve_error` refuses is not applied, and its
// sentence is shown. The editor only moves control points.
//
// Gestures: drag a handle; "+ point" adds one in the widest gap; double-tap an inner
// handle to delete it.
// The two end points stay at x = 0 and x = 1 (core's rule) and move only up and down.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

public struct FlexibleCurveBaseline: Equatable {
    /// World points along the edge at t = 0 … 1 (evenly spaced), on the face.
    public var points: [SIMD3<Double>]
    /// Unit direction the curve rises in (−load: out of the part).
    public var up: SIMD3<Double>
    public var amplitudeMM: Double

    public func at(_ t: Double) -> SIMD3<Double> {
        guard points.count > 1 else { return points.first ?? .zero }
        let x = max(0, min(1, t)) * Double(points.count - 1)
        let i = min(points.count - 2, Int(x)), f = x - Double(i)
        return points[i] + (points[i + 1] - points[i]) * f
    }
    public func world(_ t: Double, _ y: Double) -> SIMD3<Double> { at(t) + up * (y * amplitudeMM) }
}

/// The coordinate space the stage's overlays share with the projection (viewport points).
enum FlexibleStageSpace { static let name = "flexible-stage" }

struct FlexibleCurveEditor: View {
    let projection: CameraProjection?
    let baseline: FlexibleCurveBaseline
    let curve: FlexCurve
    let label: String
    let tint: Color
    let onChange: (FlexCurve) -> Void
    let onCommit: () -> Void
    @State private var dragIndex: Int?
    @State private var refusal: String?

    private func screen(_ w: SIMD3<Double>) -> CGPoint? {
        projection?.project(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
    }

    /// (t, y) under a screen point, in the projected frame at the nearest baseline point.
    private func param(at p: CGPoint, near t0: Double) -> (Double, Double)? {
        guard let s0 = screen(baseline.at(0)), let s1 = screen(baseline.at(1)),
              let a = screen(baseline.at(t0)), let b = screen(baseline.world(t0, 1)) else { return nil }
        let e = CGVector(dx: s1.x - s0.x, dy: s1.y - s0.y), n = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let d = CGVector(dx: p.x - s0.x, dy: p.y - s0.y)
        let det = e.dx * n.dy - e.dy * n.dx
        guard abs(det) > 1e-6 else { return nil }
        let t = (d.dx * n.dy - d.dy * n.dx) / det
        let dn = CGVector(dx: p.x - a.x - e.dx * (t - t0), dy: p.y - a.y - e.dy * (t - t0))
        let y = (e.dx * dn.dy - e.dy * dn.dx) / det
        return (Double(t), Double(y))
    }

    private var samples: [Double] {
        let t = stride(from: 0.0, through: 1.0, by: 1.0 / 60).map { $0 }
        return (try? FlexibleCore.penCurveValues(x: curve.x, y: curve.y, t: t)) ?? []
    }

    var body: some View {
        let ys = samples
        ZStack {
            Canvas { ctx, _ in
                // baseline (the face edge) and the y = 1 guide
                var base = Path(), top = Path()
                for (i, t) in stride(from: 0.0, through: 1.0, by: 1.0 / 30).enumerated() {
                    if let a = screen(baseline.world(t, 0)) { i == 0 ? base.move(to: a) : base.addLine(to: a) }
                    if let b = screen(baseline.world(t, 1)) { i == 0 ? top.move(to: b) : top.addLine(to: b) }
                }
                ctx.stroke(base, with: .color(DS.Color.textSecondary.color), lineWidth: 1.5)
                ctx.stroke(top, with: .color(DS.Color.textQuaternary.color),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                // core's curve
                var c = Path()
                for (i, y) in ys.enumerated() {
                    guard let p = screen(baseline.world(Double(i) / 60, y)) else { continue }
                    i == 0 ? c.move(to: p) : c.addLine(to: p)
                }
                ctx.stroke(c, with: .color(tint), lineWidth: 3)
                // verticals from the edge up to the curve: the drawing reads as "this much squish here"
                for i in stride(from: 0, to: ys.count, by: 6) {
                    guard let a = screen(baseline.world(Double(i) / 60, 0)),
                          let b = screen(baseline.world(Double(i) / 60, ys[i])) else { continue }
                    var v = Path(); v.move(to: a); v.addLine(to: b)
                    ctx.stroke(v, with: .color(tint.opacity(0.35)), lineWidth: 1)
                }
                // control points
                for k in curve.x.indices {
                    guard let p = screen(baseline.world(curve.x[k], curve.y[k])) else { continue }
                    let r: CGFloat = dragIndex == k ? 11 : 8
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(tint))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(DS.Color.background.color), lineWidth: 2)
                }
                if let s = screen(baseline.world(1, 0)) {
                    ctx.draw(Text(label).font(.system(size: 13, weight: .bold)).foregroundColor(tint),
                             at: CGPoint(x: s.x + 18, y: s.y))
                }
            }
            .allowsHitTesting(false)
            // ★ ONLY THE HANDLES TAKE TOUCHES, so a drag anywhere else still orbits the part.
            // Drag a handle to move it; double-tap an inner handle to delete it.
            ForEach(Array(curve.x.indices), id: \.self) { k in
                if let p = screen(baseline.world(curve.x[k], curve.y[k])) {
                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 44, height: 44)
                        .position(p)
                        .gesture(pointDrag(k))
                        .simultaneousGesture(TapGesture(count: 2).onEnded { deletePoint(k) })
                        .accessibilityIdentifier("flexible-curve-point-\(k)")
                }
            }
            if let r = refusal {
                VStack {
                    Spacer()
                    Text(r)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.Color.warning.color)
                        .padding(DS.Space.s)
                        .background(Capsule().fill(DS.Color.chipSolid.color))
                        .padding(.bottom, 120)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func pointDrag(_ k: Int) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                dragIndex = k
                guard k < curve.x.count, let (t, y) = param(at: g.location, near: curve.x[k]) else { return }
                var c = curve
                let last = c.x.count - 1
                if k > 0 && k < last {
                    // stay strictly between the neighbours (core's rule: x strictly increasing)
                    c.x[k] = max(c.x[k - 1] + 0.01, min(c.x[k + 1] - 0.01, t))
                }
                c.y[k] = max(0, min(1, y))
                apply(c)
            }
            .onEnded { _ in
                dragIndex = nil
                onCommit()
            }
    }

    /// A new point in the widest gap, on the curve (the "+ point" button).
    static func addingPoint(to c: FlexCurve) -> FlexCurve {
        guard c.x.count >= 2 else { return c }
        var best = 0
        for i in 0..<(c.x.count - 1) where c.x[i + 1] - c.x[i] > c.x[best + 1] - c.x[best] { best = i }
        let t = (c.x[best] + c.x[best + 1]) / 2
        let y = (try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: [t]).first) ?? nil
        var out = c
        out.x.insert(t, at: best + 1)
        out.y.insert(y ?? (c.y[best] + c.y[best + 1]) / 2, at: best + 1)
        return out
    }

    private func deletePoint(_ k: Int) {
        guard k > 0, k < curve.x.count - 1 else { return }
        var c = curve
        c.x.remove(at: k)
        c.y.remove(at: k)
        apply(c)
        onCommit()
    }

    private func apply(_ c: FlexCurve) {
        let err = FlexibleCore.penCurveError(x: c.x, y: c.y)
        if err.isEmpty {
            refusal = nil
            onChange(c)
        } else {
            refusal = err
        }
    }
}

/// The face frame's X / Y and the load, as arrows ON THE MODEL (C1 problem #8).
struct FlexibleFrameArrows: View {
    let projection: CameraProjection?
    let origin: SIMD3<Double>
    let xAxis: SIMD3<Double>
    let yAxis: SIMD3<Double>
    let load: SIMD3<Double>
    let lengthMM: Double

    var body: some View {
        Canvas { ctx, _ in
            func s(_ w: SIMD3<Double>) -> CGPoint? {
                projection?.project(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
            }
            func arrow(_ dir: SIMD3<Double>, _ label: String, _ colour: Color, from o: SIMD3<Double>) {
                guard let a = s(o), let b = s(o + dir * lengthMM) else { return }
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(colour), lineWidth: 2.5)
                let ang = atan2(b.y - a.y, b.x - a.x)
                var h = Path()
                h.move(to: b)
                h.addLine(to: CGPoint(x: b.x - 10 * cos(ang - 0.45), y: b.y - 10 * sin(ang - 0.45)))
                h.move(to: b)
                h.addLine(to: CGPoint(x: b.x - 10 * cos(ang + 0.45), y: b.y - 10 * sin(ang + 0.45)))
                ctx.stroke(h, with: .color(colour), lineWidth: 2.5)
                ctx.draw(Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(colour),
                         at: CGPoint(x: b.x + 10 * cos(ang), y: b.y + 10 * sin(ang)))
            }
            arrow(xAxis, "X", DS.Color.textPrimary.color, from: origin)
            arrow(yAxis, "Y", DS.Color.textSecondary.color, from: origin)
            // the load pushes INTO the part: drawn arriving at the face
            arrow(load, "load", DS.Color.accentGreen.color, from: origin - load * lengthMM * 1.1)
        }
        .allowsHitTesting(false)
    }
}
