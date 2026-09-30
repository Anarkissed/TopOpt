// FlexibleCurveEditor — the pen-tool squish curve, drawn ON THE MODEL along a face's own
// edge (task 2026-09-29-flexible-screens S2; M11, R12).
//
// ★ WHERE IT SITS. The curve's baseline is a line of points on the face — core's
// from_uv(u, v) + load × entry_t along the X edge (v = 0) or the Y edge (u = 0) — and
// the dashed guide sits `amplitudeMM` OUT of the part along −load. Every frame the
// world points are projected through the live camera, so the curve turns with the part
// and its orientation is true (C1 problem #8: the frame's Y = load × X is a view from
// inside, so we draw on the model instead of mirroring a flat chart).
//
// ★ WHAT IS CORE'S. The curve through the points is core's `pen_curve_values`
// (Fritsch–Carlson); a move core's `pen_curve_error` refuses is not applied, and its
// sentence is shown. The editor only moves control points.
//
// ★ ROUND 3 (items 1.3 and 8, maintainer 2026-09-29): "a curve point nearer the object =
// squishier" — the editor draws a stored y at height 1 − y above the face (the face line is
// the squishiest, the dashed guide the firmest); storage, the job and core's S keep their
// meaning. "Tap the line adds a point, tap a point shows an x that deletes it": a tap on the
// curve adds a point THERE, on the curve; a tap on a point selects it and shows an ×; the
// double-tap and the panel's "+ point" are gone. A drag moves a point.
// The two end points stay at x = 0 and x = 1 (core's rule), move only up and down, and have
// no ×.

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
    /// The point showing its × (held by the model, so a tap elsewhere on the part clears it).
    @Binding var selected: Int?
    let onChange: (FlexCurve) -> Void
    let onCommit: () -> Void
    /// ★ VERIFICATION OF D1 (img 6's class, for the curves): the page's chrome — the panel, the
    /// legend, the player — in stage points. The curve, its guide and labels are clipped out of
    /// them (they showed through the 62 %-opaque panel), and no point, line band or × is mounted
    /// under them (the chrome took the touch anyway): a point under the chrome is hidden, as the
    /// depth chip is, until the part is turned.
    var keepOut: [CGRect] = []
    @State private var dragIndex: Int?
    /// Finger − point at the drag's start: the point moves WITH the finger, never jumps to it.
    @State private var grab: CGSize = .zero
    @State private var refusal: String?

    private func screen(_ w: SIMD3<Double>) -> CGPoint? {
        projection?.project(SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
    }

    /// Where stored value y at t is drawn: height 1 − y above the face (round 3).
    private func drawn(_ t: Double, _ y: Double) -> SIMD3<Double> {
        baseline.world(t, Self.displayHeight(y))
    }

    /// (t, height) under a screen point, in the projected frame at the nearest baseline point.
    private func param(at p: CGPoint, near t0: Double) -> (Double, Double)? {
        guard let s0 = screen(baseline.at(0)), let s1 = screen(baseline.at(1)),
              let a = screen(baseline.at(t0)), let b = screen(baseline.world(t0, 1)) else { return nil }
        let e = CGVector(dx: s1.x - s0.x, dy: s1.y - s0.y), n = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let d = CGVector(dx: p.x - s0.x, dy: p.y - s0.y)
        let det = e.dx * n.dy - e.dy * n.dx
        guard abs(det) > 1e-6 else { return nil }
        let t = (d.dx * n.dy - d.dy * n.dx) / det
        let dn = CGVector(dx: p.x - a.x - e.dx * (t - t0), dy: p.y - a.y - e.dy * (t - t0))
        let h = (e.dx * dn.dy - e.dy * dn.dx) / det
        return (Double(t), Double(h))
    }

    static let sampleCount = 60
    private var samples: [Double] {
        let t = (0...Self.sampleCount).map { Double($0) / Double(Self.sampleCount) }
        return (try? FlexibleCore.penCurveValues(x: curve.x, y: curve.y, t: t)) ?? []
    }

    var body: some View {
        let ys = samples
        let line: [CGPoint] = ys.enumerated().compactMap { i, y in screen(drawn(Double(i) / Double(Self.sampleCount), y)) }
        ZStack {
            Canvas { ctx, size in
                var clip = Path(CGRect(origin: .zero, size: size))
                for r in keepOut { clip.addRect(r) }
                ctx.clip(to: clip, style: FillStyle(eoFill: true))
                // the face line (squishiest) and the dashed guide (firmest)
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
                for (i, p) in line.enumerated() { i == 0 ? c.move(to: p) : c.addLine(to: p) }
                ctx.stroke(c, with: .color(tint), lineWidth: 3)
                // verticals from the firm guide down to the curve: "this much squish here"
                for i in stride(from: 0, to: ys.count, by: 6) {
                    let t = Double(i) / Double(Self.sampleCount)
                    guard let a = screen(baseline.world(t, 1)), let b = screen(drawn(t, ys[i])) else { continue }
                    var v = Path(); v.move(to: a); v.addLine(to: b)
                    ctx.stroke(v, with: .color(tint.opacity(0.35)), lineWidth: 1)
                }
                // control points
                for k in curve.x.indices {
                    guard let p = screen(drawn(curve.x[k], curve.y[k])) else { continue }
                    let r: CGFloat = dragIndex == k || selected == k ? 11 : 8
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(tint))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(DS.Color.background.color), lineWidth: 2)
                }
                if let s = screen(baseline.world(1, 0)) {
                    ctx.draw(Text(label).font(.system(size: 13, weight: .bold)).foregroundColor(tint),
                             at: CGPoint(x: s.x + 18, y: s.y))
                }
                // which way reads which (two tiny words at the curve's end)
                if let s = screen(baseline.world(0, 0)) {
                    ctx.draw(Text("soft").font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Color.textTertiary.color), at: CGPoint(x: s.x - 20, y: s.y))
                }
                if let s = screen(baseline.world(0, 1)) {
                    ctx.draw(Text("firm").font(.system(size: 10, weight: .semibold))
                                .foregroundColor(DS.Color.textTertiary.color), at: CGPoint(x: s.x - 20, y: s.y))
                }
            }
            .allowsHitTesting(false)
            // ★ A THIN BAND ALONG THE CURVE takes a tap (a point lands there); everywhere else
            // a drag still orbits. SpatialTapGesture: iOS 16 has no onTapGesture(coordinateSpace:).
            Color.white.opacity(0.001)
                .contentShape(FlexibleCurveBand(runs: Self.runsOutside(line, keepOut: keepOut, margin: Self.bandWidth / 2),
                                                width: Self.bandWidth))
                .gesture(SpatialTapGesture(coordinateSpace: .named(FlexibleStageSpace.name))
                    .onEnded { v in tapLine(v.location, line: line) })
                .accessibilityIdentifier("flexible-curve-line")
            // ★ THE HANDLES: drag to move, tap to select (the × appears beside it)
            ForEach(Array(curve.x.indices), id: \.self) { k in
                if let p = screen(drawn(curve.x[k], curve.y[k])), dragIndex == k || Self.reachable(p, keepOut: keepOut) {
                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: 44, height: 44)
                        .position(p)
                        .gesture(pointDrag(k))
                        .simultaneousGesture(TapGesture().onEnded { selected = selected == k ? nil : k })
                        .accessibilityIdentifier("flexible-curve-point-\(k)")
                }
            }
            if let k = selected, Self.deletable(k, in: curve), k < curve.x.count,
               let p = screen(drawn(curve.x[k], curve.y[k])), Self.reachable(p, keepOut: keepOut),
               Self.reachable(CGPoint(x: p.x + 30, y: p.y - 30), keepOut: keepOut) {
                Button { delete(k) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.Color.textPrimary.color)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(DS.Color.danger.color))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .position(x: p.x + 30, y: p.y - 30)
                .accessibilityIdentifier("flexible-curve-point-delete-\(k)")
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

    /// The tap band's width (pt): thin, so a drag that starts off the line still orbits.
    static let bandWidth: CGFloat = 24

    /// A point outside every keep-out (the chrome over the part).
    static func reachable(_ p: CGPoint, keepOut: [CGRect]) -> Bool {
        p.x.isFinite && p.y.isFinite && !keepOut.contains { $0.contains(p) }
    }

    /// The curve's screen points split into the runs that stay `margin` clear of every keep-out:
    /// the tap band is laid only along them.
    static func runsOutside(_ line: [CGPoint], keepOut: [CGRect], margin: CGFloat) -> [[CGPoint]] {
        var runs: [[CGPoint]] = [], cur: [CGPoint] = []
        for p in line {
            if keepOut.contains(where: { $0.insetBy(dx: -margin, dy: -margin).contains(p) }) {
                if !cur.isEmpty { runs.append(cur); cur = [] }
            } else {
                cur.append(p)
            }
        }
        if !cur.isEmpty { runs.append(cur) }
        return runs
    }

    private func tapLine(_ p: CGPoint, line: [CGPoint]) {
        guard !line.isEmpty else { return }
        let i = line.indices.min { hypot(line[$0].x - p.x, line[$0].y - p.y) < hypot(line[$1].x - p.x, line[$1].y - p.y) } ?? 0
        let t0 = Double(i) / Double(max(1, line.count - 1))
        let t = param(at: p, near: t0).map { max(0, min(1, $0.0)) } ?? t0
        if let k = Self.pointNear(t: t, in: curve) { selected = k; return }
        selected = nil
        guard let (c, _) = Self.inserting(at: t, into: curve) else { return }
        apply(c)
        onCommit()
    }

    /// ★ A TAP IS NOT A DRAG (verification of round 3): at 1 pt a tap that wobbled 1–2 pt
    /// jumped the point to the finger (the 44 pt target is off-centre) and saved it, beside
    /// the × it asked for. A drag starts at `dragStartPoints` and is RELATIVE to the grab.
    static let dragStartPoints: CGFloat = 6

    /// Where the dragged point goes: the finger, minus where on the point it was grabbed.
    static func dragged(location: CGPoint, grab: CGSize) -> CGPoint {
        CGPoint(x: location.x - grab.width, y: location.y - grab.height)
    }

    private func pointDrag(_ k: Int) -> some Gesture {
        DragGesture(minimumDistance: Self.dragStartPoints, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                if dragIndex != k, k < curve.x.count, let p = screen(drawn(curve.x[k], curve.y[k])) {
                    grab = CGSize(width: g.startLocation.x - p.x, height: g.startLocation.y - p.y)
                }
                dragIndex = k
                if selected != nil { selected = nil }
                guard k < curve.x.count,
                      let (t, h) = param(at: Self.dragged(location: g.location, grab: grab), near: curve.x[k]) else { return }
                var c = curve
                let last = c.x.count - 1
                if k > 0 && k < last {
                    // stay strictly between the neighbours (core's rule: x strictly increasing)
                    c.x[k] = max(c.x[k - 1] + Self.minGap, min(c.x[k + 1] - Self.minGap, t))
                }
                c.y[k] = Self.storedY(height: h)
                apply(c)
            }
            .onEnded { _ in
                dragIndex = nil
                grab = .zero
                onCommit()
            }
    }

    private func delete(_ k: Int) {
        guard let c = Self.removing(k, from: curve) else { return }
        selected = nil
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

    // MARK: the pure rules (FlexibleCurveEditTests)

    /// Core's gap between neighbouring x (x strictly increasing).
    static let minGap = 0.01

    /// ★ ROUND 3, ITEM 1.3 — "CLOSER TO THE FACE = SQUISHIER". The height (× amplitude)
    /// above the face at which a stored y (core's fraction of the deepest squish) is drawn:
    /// y = 1 on the face line, y = 0 on the dashed guide. Storage, the job and core's S keep
    /// their meaning; only the editor reads it upside down from before.
    static func displayHeight(_ y: Double) -> Double { 1 - y }
    /// The stored y for a height (× amplitude) the finger dragged to — the inverse.
    static func storedY(height h: Double) -> Double { 1 - max(0, min(1, h)) }

    /// The point a tap at t is on (within core's gap), or nil.
    static func pointNear(t: Double, in c: FlexCurve) -> Int? {
        c.x.indices.filter { abs(c.x[$0] - t) < minGap }.min { abs(c.x[$0] - t) < abs(c.x[$1] - t) }
    }

    /// ★ ITEM 8: a tap on the curve line at t adds a point AT t, ON the curve (its y is core's
    /// curve value there, so the shape stays), strictly between its neighbours. nil when the
    /// tap is on an existing point (the tap selects that point instead).
    static func inserting(at t: Double, into c: FlexCurve) -> (curve: FlexCurve, index: Int)? {
        guard c.x.count >= 2, pointNear(t: t, in: c) == nil else { return nil }
        guard let i = c.x.indices.dropLast().last(where: { c.x[$0] < t }) else { return nil }
        let lo = c.x[i] + minGap, hi = c.x[i + 1] - minGap
        guard lo <= hi else { return nil }
        let tt = min(max(t, lo), hi)
        let y = (try? FlexibleCore.penCurveValues(x: c.x, y: c.y, t: [tt]).first) ?? nil
        var out = c
        out.x.insert(tt, at: i + 1)
        out.y.insert(max(0, min(1, y ?? (c.y[i] + c.y[i + 1]) / 2)), at: i + 1)
        return (out, i + 1)
    }

    /// The end points stay (core: x[0] = 0, x[n−1] = 1).
    static func deletable(_ k: Int, in c: FlexCurve) -> Bool { k > 0 && k < c.x.count - 1 }

    /// The curve without point k, or nil for an end point.
    static func removing(_ k: Int, from c: FlexCurve) -> FlexCurve? {
        guard deletable(k, in: c) else { return nil }
        var out = c
        out.x.remove(at: k); out.y.remove(at: k)
        return out
    }
}

/// The tap band along the projected curve (each run of it clear of the page's chrome).
struct FlexibleCurveBand: Shape {
    let runs: [[CGPoint]]
    let width: CGFloat
    init(points: [CGPoint], width: CGFloat) { self.runs = [points]; self.width = width }
    init(runs: [[CGPoint]], width: CGFloat) { self.runs = runs; self.width = width }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for run in runs {
            guard let f = run.first else { continue }
            p.move(to: f)
            for q in run.dropFirst() { p.addLine(to: q) }
        }
        return p.strokedPath(StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
