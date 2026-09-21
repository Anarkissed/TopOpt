import SwiftUI
import simd
import TopOptDesign

// ★★★ THE WALL EDITOR IN THE VIEWER — his design `Lattice Wall Thickness.dc.html`
// (2026-09-21): each wall drawn as its own box (width × thickness, OUTER SURFACE on top,
// INNER SURFACE below, the mid-plane dashed), the START line green in the outer half and
// the END line red in the inner half, the lattice living between them.
//
//   thickness stage  two full-width bars to drag — "how much of each wall may become
//                    lattice" (the allowed range, in mm)
//   grade stage      the profile: PEN taps add points on the half tapped, MOVE drags them,
//                    a selected point shows its tangent handles (drag, 45° detents), the
//                    rail flips Curved/Straight (hold ½ s: every point of the line),
//                    mirrors start ↔ end (hold: the selected point's half onto the other),
//                    shifts, flattens, deletes, resets.
//
// The maths is the design's, ported to `LatticeWallProfile`; this file is the touch.

public struct LatticeWallEditorFace: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let tint: Color
    public let widthMM: Double
    public let thickMM: Double
    public init(id: String, name: String, tint: Color, widthMM: Double, thickMM: Double) {
        self.id = id; self.name = name; self.tint = tint; self.widthMM = widthMM; self.thickMM = thickMM
    }
}

public enum LatticeWallEditorStage: Equatable { case thickness, grade }

public struct LatticeWallProfileEditor: View {
    public let faces: [LatticeWallEditorFace]
    public let stage: LatticeWallEditorStage
    @Binding public var ask: LatticeWallThickness
    public let onCancel: () -> Void
    public let onSave: () -> Void

    public init(faces: [LatticeWallEditorFace], stage: LatticeWallEditorStage,
                ask: Binding<LatticeWallThickness>, onCancel: @escaping () -> Void, onSave: @escaping () -> Void) {
        self.faces = faces; self.stage = stage; self._ask = ask; self.onCancel = onCancel; self.onSave = onSave
    }

    private enum Tool { case pen, move }
    private struct SelPt: Equatable { var face: String; var side: LatticeWallProfile.Side; var idx: Int }
    private enum DragKind: Equatable { case thick(LatticeWallProfile.Side), point(LatticeWallProfile.Side, Int), wing(LatticeWallProfile.Side, Int, Double), none }
    private struct Drag: Equatable { var face: String; var kind: DragKind; var moved: Bool; var startAt: CGPoint }

    @State private var activeFace: String? = nil
    @State private var tool: Tool = .pen
    @State private var side: LatticeWallProfile.Side = .start
    @State private var selPt: SelPt? = nil
    @State private var showWings = true
    @State private var drag: Drag? = nil
    @State private var holdAll = false
    @State private var holdMirror = false
    @State private var pressBegan: Date? = nil

    private static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    private static let red = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
    private static let bx: CGFloat = 70, by: CGFloat = 34, padR: CGFloat = 70, padB: CGFloat = 34

    public var body: some View {
        GeometryReader { geo in
            let grade = stage == .grade
            let railW: CGFloat = grade ? 128 : 0
            let stageW = geo.size.width - railW - 16, stageH = geo.size.height - 90
            let maxW = faces.map(\.widthMM).max() ?? 1
            let sumT = faces.map(\.thickMM).reduce(0, +)
            let S = max(1.5, min(5, (stageW - Self.bx - Self.padR) / CGFloat(max(1, maxW)),
                                    (stageH - CGFloat(faces.count) * (Self.by + Self.padB + 40)) / CGFloat(max(1, sumT))))
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 30) {
                    ForEach(faces) { f in faceView(f, scale: S, grade: grade) }
                    HStack(spacing: 12) {
                        Button(action: onCancel) {
                            Text("Cancel").font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 22).frame(minHeight: 50)
                                .background(Capsule().fill(Color(white: 0.11).opacity(0.7))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12))))
                                .foregroundStyle(DS.Color.textPrimary.color)
                        }.buttonStyle(.plain).accessibilityIdentifier("wall-editor-cancel")
                        Button(action: onSave) {
                            Text(grade ? "Save profile" : "Save thickness").font(.system(size: 16, weight: .bold))
                                .padding(.horizontal, 30).frame(minHeight: 50)
                                .background(Capsule().fill(DS.Color.accent.color))
                                .foregroundStyle(.white)
                        }.buttonStyle(.plain).accessibilityIdentifier("wall-editor-save")
                    }.padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if grade { rail }
            }
            .padding(.horizontal, 16)
        }
        .onAppear { if activeFace == nil { activeFace = faces.first?.id } }
    }

    // MARK: per-face state

    private func faceAsk(_ id: String) -> LatticeFaceWallThickness { ask.faces[id] ?? LatticeFaceWallThickness() }
    private func setFace(_ id: String, _ mutate: (inout LatticeFaceWallThickness) -> Void) {
        var f = faceAsk(id); mutate(&f); ask.faces[id] = f
    }
    /// The profile the grade stage edits: the drawn one, or flat lines at the allowed range.
    private func profile(_ f: LatticeWallEditorFace) -> LatticeWallProfile {
        let a = faceAsk(f.id)
        if let p = a.profile { return p }
        let t = max(f.thickMM, 1e-9)
        return .flat(start: a.startMM / t, end: (a.endMM ?? f.thickMM) / t)
    }
    private func setProfile(_ f: LatticeWallEditorFace, _ mutate: (inout LatticeWallProfile) -> Void) {
        var p = profile(f); mutate(&p); setFace(f.id) { $0.profile = p }
    }
    private func shares(_ f: LatticeWallEditorFace) -> (start: Double, end: Double) {
        let a = faceAsk(f.id), t = max(f.thickMM, 1e-9)
        return (min(max(0, a.startMM / t), 1), min(max(0, (a.endMM ?? f.thickMM) / t), 1))
    }

    // MARK: one wall

    @ViewBuilder private func faceView(_ f: LatticeWallEditorFace, scale S: CGFloat, grade: Bool) -> some View {
        let bw = CGFloat(f.widthMM) * S, bh = CGFloat(f.thickMM) * S
        let svgW = Self.bx + bw + Self.padR, svgH = Self.by + bh + Self.padB
        let isActive = f.id == activeFace
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(f.tint).frame(width: 10, height: 10)
                Text(f.name).font(.system(size: 15, weight: .bold))
                Text(String(format: "%.0f × %.1f mm wall", f.widthMM, f.thickMM))
                    .font(.system(size: 13)).foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                if grade && isActive {
                    Text("● editing").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1))
                }
            }
            .padding(.leading, Self.bx)
            Canvas { ctx, _ in draw(f, in: &ctx, bw: bw, bh: bh, grade: grade, isActive: isActive) }
                .frame(width: svgW, height: svgH)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in dragChanged(f, g, bw: bw, bh: bh, grade: grade) }
                    .onEnded { g in dragEnded(f, g, bw: bw, bh: bh, grade: grade) })
                .accessibilityIdentifier("wall-editor-canvas-\(f.id)")
        }
        .foregroundStyle(DS.Color.textPrimary.color)
        .onTapGesture { if activeFace != f.id { activeFace = f.id } }
    }

    private func pxPath(_ pts: [SIMD2<Double>], bw: CGFloat, bh: CGFloat) -> Path {
        var p = Path()
        for (i, q) in pts.enumerated() {
            let pt = CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    private func draw(_ f: LatticeWallEditorFace, in ctx: inout GraphicsContext, bw: CGFloat, bh: CGFloat,
                      grade: Bool, isActive: Bool) {
        let box = CGRect(x: Self.bx, y: Self.by, width: bw, height: bh)
        ctx.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(.white.opacity(0.05)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 6),
                   with: .color(grade && isActive ? Color(red: 0.5, green: 0.75, blue: 1).opacity(0.8) : .white.opacity(0.22)),
                   lineWidth: 1.5)
        var mid = Path(); mid.move(to: CGPoint(x: box.minX, y: box.midY)); mid.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        ctx.stroke(mid, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
        let labelFont = Font.system(size: 11, weight: .semibold)
        ctx.draw(Text("OUTER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.minY - 10), anchor: .leading)
        ctx.draw(Text("INNER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.maxY + 16), anchor: .leading)

        let prof = profile(f)
        let sh = shares(f)
        let startPts: [SIMD2<Double>] = grade
            ? LatticeWallProfile.polyline(prof.start, curved: prof.curveStart, side: .start)
            : [SIMD2(0, sh.start), SIMD2(1, sh.start)]
        let endPts: [SIMD2<Double>] = grade
            ? LatticeWallProfile.polyline(prof.end, curved: prof.curveEnd, side: .end)
            : [SIMD2(0, sh.end), SIMD2(1, sh.end)]
        // the region between the lines
        var region = pxPath(startPts, bw: bw, bh: bh)
        for q in endPts.reversed() { region.addLine(to: CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)) }
        region.closeSubpath()
        if grade {
            ctx.fill(region, with: .linearGradient(Gradient(colors: [Self.green.opacity(0.45), Self.red.opacity(0.45)]),
                                                   startPoint: CGPoint(x: box.midX, y: box.minY),
                                                   endPoint: CGPoint(x: box.midX, y: box.maxY)))
        } else {
            ctx.fill(region, with: .color(Color(red: 79 / 255, green: 168 / 255, blue: 1).opacity(0.16)))
        }
        ctx.stroke(pxPath(startPts, bw: bw, bh: bh), with: .color(Self.green), style: StrokeStyle(lineWidth: grade ? 3 : 2.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(pxPath(endPts, bw: bw, bh: bh), with: .color(Self.red), style: StrokeStyle(lineWidth: grade ? 3 : 2.5, lineCap: .round, lineJoin: .round))

        let readX = box.maxX + 14
        let readFont = Font.system(size: 12.5, weight: .bold)
        if !grade {
            // the two handles, and the mm readouts beside them
            for (y, col) in [(sh.start, Self.green), (sh.end, Self.red)] {
                let c = CGPoint(x: box.midX, y: Self.by + CGFloat(y) * bh)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)), with: .color(col))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)), with: .color(Color(white: 0.02)), lineWidth: 3)
                ctx.draw(Text(String(format: "%.1f mm", y * f.thickMM)).font(readFont).foregroundColor(col),
                         at: CGPoint(x: readX, y: c.y), anchor: .leading)
            }
        } else {
            ctx.draw(Text("start").font(readFont).foregroundColor(Self.green),
                     at: CGPoint(x: readX, y: Self.by + CGFloat(prof.start.first?.y ?? 0) * bh), anchor: .leading)
            ctx.draw(Text("end").font(readFont).foregroundColor(Self.red),
                     at: CGPoint(x: readX, y: Self.by + CGFloat(prof.end.first?.y ?? 1) * bh), anchor: .leading)
            // tangent wings of the selected point
            if showWings, let sp = selPt, sp.face == f.id {
                let pts = sp.side == .start ? prof.start : prof.end
                if sp.idx < pts.count, pts[sp.idx].smooth, (sp.side == .start ? prof.curveStart : prof.curveEnd) {
                    let p = pts[sp.idx], t = LatticeWallProfile.tangent(pts, sp.idx)
                    let c = CGPoint(x: Self.bx + CGFloat(p.x) * bw, y: Self.by + CGFloat(p.y) * bh)
                    let col = sp.side == .start ? Self.green : Self.red
                    for dir: CGFloat in [1, -1] where (dir == 1 && sp.idx < pts.count - 1) || (dir == -1 && sp.idx > 0) {
                        let e = CGPoint(x: c.x + CGFloat(t.x) * bw * dir, y: c.y + CGFloat(t.y) * bh * dir)
                        var l = Path(); l.move(to: c); l.addLine(to: e)
                        ctx.stroke(l, with: .color(col.opacity(0.55)), lineWidth: 1.2)
                        var d = Path(); d.move(to: CGPoint(x: e.x, y: e.y - 6)); d.addLine(to: CGPoint(x: e.x + 6, y: e.y))
                        d.addLine(to: CGPoint(x: e.x, y: e.y + 6)); d.addLine(to: CGPoint(x: e.x - 6, y: e.y)); d.closeSubpath()
                        ctx.fill(d, with: .color(Color(white: 0.02))); ctx.stroke(d, with: .color(col), lineWidth: 1.6)
                    }
                }
            }
            // the points
            for s in [LatticeWallProfile.Side.start, .end] {
                let pts = s == .start ? prof.start : prof.end
                let col = s == .start ? Self.green : Self.red
                for (i, p) in pts.enumerated() {
                    let sel = selPt == SelPt(face: f.id, side: s, idx: i)
                    let c = CGPoint(x: Self.bx + CGFloat(p.x) * bw, y: Self.by + CGFloat(p.y) * bh)
                    let r: CGFloat = sel ? 10 : 7
                    let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    ctx.fill(circle, with: .color(sel ? .white : (p.smooth ? col : Color(white: 0.02))))
                    if sel || !p.smooth { ctx.stroke(circle, with: .color(col), lineWidth: sel ? 3 : 2.2) }
                }
            }
        }
        ctx.draw(Text("0 mm").font(.system(size: 11)).foregroundColor(.white.opacity(0.35)),
                 at: CGPoint(x: readX, y: box.minY - 6), anchor: .leading)
        ctx.draw(Text(String(format: "%.1f mm", f.thickMM)).font(.system(size: 11)).foregroundColor(.white.opacity(0.35)),
                 at: CGPoint(x: readX, y: box.maxY + 14), anchor: .leading)
    }

    // MARK: touch

    private func norm(_ p: CGPoint, bw: CGFloat, bh: CGFloat) -> SIMD2<Double> {
        SIMD2(Double((p.x - Self.bx) / bw), Double((p.y - Self.by) / bh))
    }
    private func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }

    private func hit(_ f: LatticeWallEditorFace, at p: CGPoint, bw: CGFloat, bh: CGFloat, grade: Bool) -> DragKind {
        if !grade {
            let sh = shares(f)
            let ys = Self.by + CGFloat(sh.start) * bh, ye = Self.by + CGFloat(sh.end) * bh
            let inX = p.x >= Self.bx - 22 && p.x <= Self.bx + bw + 22
            if inX, abs(p.y - ys) <= 22, abs(p.y - ys) <= abs(p.y - ye) { return .thick(.start) }
            if inX, abs(p.y - ye) <= 22 { return .thick(.end) }
            return .none
        }
        let prof = profile(f)
        // a wing of the selected point first
        if showWings, let sp = selPt, sp.face == f.id {
            let pts = sp.side == .start ? prof.start : prof.end
            if sp.idx < pts.count, pts[sp.idx].smooth {
                let q = pts[sp.idx], t = LatticeWallProfile.tangent(pts, sp.idx)
                let c = CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)
                for dir: CGFloat in [1, -1] where (dir == 1 && sp.idx < pts.count - 1) || (dir == -1 && sp.idx > 0) {
                    let e = CGPoint(x: c.x + CGFloat(t.x) * bw * dir, y: c.y + CGFloat(t.y) * bh * dir)
                    if hypot(p.x - e.x, p.y - e.y) <= 16 { return .wing(sp.side, sp.idx, Double(dir)) }
                }
            }
        }
        var best: (DragKind, CGFloat)? = nil
        for s in [LatticeWallProfile.Side.start, .end] {
            let pts = s == .start ? prof.start : prof.end
            for (i, q) in pts.enumerated() {
                let c = CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)
                let d = hypot(p.x - c.x, p.y - c.y)
                if d <= 22, best == nil || d < best!.1 { best = (.point(s, i), d) }
            }
        }
        return best?.0 ?? .none
    }

    private func dragChanged(_ f: LatticeWallEditorFace, _ g: DragGesture.Value, bw: CGFloat, bh: CGFloat, grade: Bool) {
        if drag == nil || drag?.face != f.id {
            let kind = hit(f, at: g.startLocation, bw: bw, bh: bh, grade: grade)
            drag = Drag(face: f.id, kind: kind, moved: false, startAt: g.startLocation)
            activeFace = f.id
            if case let .point(s, i) = kind { side = s; selPt = SelPt(face: f.id, side: s, idx: i) }
            if case let .wing(s, _, _) = kind { side = s }
            if kind == .none, grade, tool == .pen { return }
        }
        guard var d = drag else { return }
        if hypot(g.translation.width, g.translation.height) > 3 { d.moved = true; drag = d }
        let n = norm(g.location, bw: bw, bh: bh)
        let nx = clamp(n.x, 0, 1), ny = clamp(n.y, 0, 1)
        switch d.kind {
        case let .thick(s):
            setFace(f.id) { a in
                let t = f.thickMM
                let cur = (a.startMM / t, (a.endMM ?? t) / t)
                if s == .start { a.startMM = min(ny, cur.1 - 0.02) * t }
                else { a.endMM = max(ny, cur.0 + 0.02) * t }
            }
        case let .point(s, i):
            guard tool == .move || d.moved else { return }
            setProfile(f) { p in
                var arr = s == .start ? p.start : p.end
                guard i < arr.count else { return }
                var q = arr[i]
                q.y = s == .start ? min(ny, 0.5) : max(ny, 0.5)
                if i != 0, i != arr.count - 1 { q.x = clamp(nx, arr[i - 1].x + 0.02, arr[i + 1].x - 0.02) }
                arr[i] = q
                if s == .start { p.start = arr } else { p.end = arr }
            }
        case let .wing(s, i, dir):
            setProfile(f) { p in
                var arr = s == .start ? p.start : p.end
                guard i < arr.count else { return }
                var q = arr[i]
                // work in px so angles are true on screen, then snap to 0/45/90 detents
                var dx = (Double(g.location.x) - (Double(Self.bx) + q.x * Double(bw))) * dir
                var dy = (Double(g.location.y) - (Double(Self.by) + q.y * Double(bh))) * dir
                let len = hypot(dx, dy), ang = atan2(dy, dx), step = Double.pi / 4
                let snapped = (ang / step).rounded() * step
                if abs(ang - snapped) < 0.14 { dx = cos(snapped) * len; dy = sin(snapped) * len }
                q.tx = dx / Double(bw); q.ty = dy / Double(bh)
                arr[i] = q
                if s == .start { p.start = arr } else { p.end = arr }
            }
        case .none: break
        }
    }

    private func dragEnded(_ f: LatticeWallEditorFace, _ g: DragGesture.Value, bw: CGFloat, bh: CGFloat, grade: Bool) {
        defer { drag = nil }
        guard let d = drag, d.face == f.id else { return }
        // a tap on empty canvas with the pen adds a point on the half tapped
        if grade, tool == .pen, d.kind == .none, !d.moved {
            let n = norm(g.location, bw: bw, bh: bh)
            guard n.x > 0.02, n.x < 0.98, n.y > -0.1, n.y < 1.1 else { return }
            let tapSide: LatticeWallProfile.Side = n.y < 0.5 ? .start : .end
            side = tapSide
            setProfile(f) { p in
                var arr = tapSide == .start ? p.start : p.end
                var i = arr.firstIndex { $0.x > n.x } ?? (arr.count - 1)
                if i < 0 { i = 0 }
                arr.insert(.init(x: n.x, y: tapSide == .start ? clamp(n.y, 0, 0.5) : clamp(n.y, 0.5, 1)), at: i)
                if tapSide == .start { p.start = arr } else { p.end = arr }
                selPt = SelPt(face: f.id, side: tapSide, idx: i)
            }
        }
    }

    // MARK: the rail (grade stage)

    private var activeFaceModel: LatticeWallEditorFace? { faces.first { $0.id == activeFace } ?? faces.first }
    private var sideTint: Color { side == .start ? Self.green : Self.red }
    private var selectedPoint: LatticeWallProfilePoint? {
        guard let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) else { return nil }
        let pts = sp.side == .start ? profile(f).start : profile(f).end
        return sp.idx < pts.count ? pts[sp.idx] : nil
    }

    private func sideOp(_ fn: ([LatticeWallProfilePoint]) -> [LatticeWallProfilePoint]) {
        guard let f = activeFaceModel else { return }
        setProfile(f) { p in if side == .start { p.start = fn(p.start) } else { p.end = fn(p.end) } }
    }

    @ViewBuilder private var rail: some View {
        let selSmooth = selectedPoint?.smooth ?? true
        let selLeft = (selectedPoint?.x ?? 0) <= 0.5
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                railButton("✎", "Pen", on: tool == .pen) { tool = .pen }
                railButton("✥", "Move", on: tool == .move) { tool = .move }
            }
            railButton("⌖", "Handles", on: showWings) { showWings.toggle() }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Circle().fill(sideTint).frame(width: 8, height: 8)
                Text((side == .start ? "Start" : "End") + " line").font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(sideTint)
            }
            holdButton(glyph: selSmooth ? "∿" : "⟋", label: selSmooth ? "Curved" : "Straight",
                       hint: holdAll ? "all points" : (selPt == nil ? "select a point" : "this point"),
                       lit: holdAll, id: "wall-editor-curve",
                       onHold: { holdAll = true },
                       onRelease: { held in
                           if held {
                               let target = !selSmooth
                               sideOp { $0.map { var q = $0; q.smooth = target; return q } }
                               holdAll = false
                           } else if let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) {
                               setProfile(f) { p in
                                   var arr = sp.side == .start ? p.start : p.end
                                   guard sp.idx < arr.count else { return }
                                   arr[sp.idx].smooth.toggle()
                                   if sp.side == .start { p.start = arr } else { p.end = arr }
                               }
                           }
                       })
            holdButton(glyph: holdMirror ? "⇋" : "⇅",
                       label: holdMirror ? (selLeft ? "Mirror →" : "← Mirror") : (side == .start ? "Mirror → End" : "Mirror → Start"),
                       hint: holdMirror ? (selLeft ? "left half → right" : "right half → left") : (side == .start ? "start → end" : "end → start"),
                       lit: holdMirror, id: "wall-editor-mirror",
                       onHold: { holdMirror = true },
                       onRelease: { held in
                           if held {
                               sideOp { arr in
                                   let src = arr.filter { selLeft ? $0.x <= 0.5 : $0.x >= 0.5 }
                                   let refl = src.filter { abs($0.x - 0.5) > 0.001 }.map { q -> LatticeWallProfilePoint in
                                       var r = q; r.x = 1 - q.x; if let ty = q.ty { r.ty = -ty }; return r
                                   }
                                   return (src + refl).sorted { $0.x < $1.x }
                               }
                               holdMirror = false
                           } else if let f = activeFaceModel {
                               setProfile(f) { p in
                                   let from = side == .start ? p.start : p.end
                                   let other: LatticeWallProfile.Side = side == .start ? .end : .start
                                   let mapped = from.map { q -> LatticeWallProfilePoint in
                                       var r = q
                                       r.y = other == .start ? clamp(1 - q.y, 0, 0.5) : clamp(1 - q.y, 0.5, 1)
                                       if let ty = q.ty { r.ty = -ty }
                                       return r
                                   }
                                   if other == .start { p.start = mapped; p.curveStart = p.curveEnd }
                                   else { p.end = mapped; p.curveEnd = p.curveStart }
                               }
                           }
                       })
            railButton("←", "Shift ◁") { shift(-1) }
            railButton("→", "Shift ▷") { shift(1) }
            railButton("—", "Flatten") {
                sideOp { arr in
                    var y = arr.map(\.y).reduce(0, +) / Double(max(1, arr.count))
                    y = side == .start ? min(y, 0.5) : max(y, 0.5)
                    return [.init(x: 0, y: y), .init(x: 1, y: y)]
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            let canDelete: Bool = {
                guard let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) else { return false }
                let n = (sp.side == .start ? profile(f).start : profile(f).end).count
                return sp.idx != 0 && sp.idx != n - 1
            }()
            Button {
                guard let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) else { return }
                setProfile(f) { p in
                    var arr = sp.side == .start ? p.start : p.end
                    guard sp.idx != 0, sp.idx != arr.count - 1, sp.idx < arr.count else { return }
                    arr.remove(at: sp.idx)
                    if sp.side == .start { p.start = arr } else { p.end = arr }
                }
                selPt = nil
            } label: {
                Text("Delete pt").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Self.red.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Self.red.opacity(0.3))))
                    .foregroundStyle(Color(red: 1, green: 0.41, blue: 0.38))
            }.buttonStyle(.plain).opacity(canDelete ? 1 : 0.35).accessibilityIdentifier("wall-editor-delete")
            Button {
                guard let f = activeFaceModel else { return }
                let sh = shares(f)
                setFace(f.id) { $0.profile = .flat(start: sh.start, end: sh.end) }
            } label: {
                Text("Reset face").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09)))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.6).color)
            }.buttonStyle(.plain).accessibilityIdentifier("wall-editor-reset")
        }
        .padding(10)
        .frame(width: 112)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 22 / 255, green: 24 / 255, blue: 34 / 255).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.09))))
        .foregroundStyle(DS.Color.textPrimary.color)
    }

    private func shift(_ dir: Double) {
        sideOp { arr in
            arr.enumerated().map { i, p in
                guard i != 0, i != arr.count - 1 else { return p }
                var q = p
                q.x = clamp(p.x + dir * 0.06, arr[0].x + 0.02, arr[arr.count - 1].x - 0.02)
                return q
            }
        }
    }

    @ViewBuilder private func railButton(_ glyph: String, _ name: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(glyph).font(.system(size: 18))
                Text(name).font(.system(size: 12, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? DS.Color.accent.opacity(0.24).color : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? DS.Color.accent.opacity(0.6).color : Color.white.opacity(0.09))))
            .foregroundStyle(on ? .white : DS.Color.textPrimary.opacity(0.7).color)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("wall-editor-\(name.lowercased().filter { $0.isLetter })")
    }

    /// A button that TAPS or HOLDS (½ s): the design's Curved/Straight and Mirror.
    @ViewBuilder private func holdButton(glyph: String, label: String, hint: String, lit: Bool, id: String,
                                         onHold: @escaping () -> Void,
                                         onRelease: @escaping (_ held: Bool) -> Void) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 7) {
                Text(glyph).font(.system(size: 15)).foregroundStyle(sideTint)
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            Text(hint).font(.system(size: 9.5, weight: .semibold)).tracking(0.3)
                .foregroundStyle(DS.Color.textPrimary.opacity(0.42).color)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(lit ? Color(red: 0.5, green: 0.75, blue: 1) : Color.white.opacity(0.09))))
        .shadow(color: lit ? DS.Color.accent.opacity(0.55).color : .clear, radius: lit ? 9 : 0)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if pressBegan == nil {
                    pressBegan = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if pressBegan != nil { onHold() } }
                }
            }
            .onEnded { _ in
                let held = pressBegan.map { Date().timeIntervalSince($0) >= 0.5 } ?? false
                pressBegan = nil
                onRelease(held)
            })
        .accessibilityIdentifier(id)
    }
}
