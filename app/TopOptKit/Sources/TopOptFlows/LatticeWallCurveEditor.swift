import SwiftUI
import simd
import TopOptDesign

// ★★★ THE CURVE EDITOR — ORGANIC ONLY (his 2026-09-21 22:40: "Organic lattice can be
// done with curves, this was discussed and approved. Revert this back to the curves only
// for organic lattices"). The design's editor as first built: PEN taps add points on the
// half tapped, MOVE drags them, MAGNET snaps to the 5 mm grid, tangent handles with 45°
// detents, Curved/Straight (tap: the point, hold: the line), Mirror, Shift, Flatten,
// Delete, Reset, undo/redo at the top of the rail; the START line lives in the outer half
// (≤ 50 %) and the END line in the inner half (≥ 50 %). Cell-based lattices use
// `LatticeWallProfileEditor` (steps). Both share the cards, the 3D render and the rail.

public struct LatticeWallCurveEditor: View {
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
    private struct SelPt: Equatable { var face: String; var side: LatticeWallCurves.Side; var idx: Int }
    private enum DragKind: Equatable { case thick(LatticeWallCurves.Side), point(LatticeWallCurves.Side, Int), wing(LatticeWallCurves.Side, Int, Double), none }
    private struct Drag: Equatable { var face: String; var kind: DragKind; var moved: Bool }

    @State private var activeFace: String? = nil
    @State private var tool: Tool = .pen
    @State private var magnet = false
    @State private var side: LatticeWallCurves.Side = .start
    @State private var selPt: SelPt? = nil
    @State private var showWings = true
    @State private var drag: Drag? = nil
    @State private var holdAll = false
    @State private var holdMirror = false
    @State private var pressBegan: Date? = nil
    @State private var render3D: Set<String> = []
    @State private var info3D: String? = nil
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollContent: CGFloat = 1
    @State private var scrollViewport: CGFloat = 1
    @State private var undoStack: [LatticeWallThickness] = []
    @State private var redoStack: [LatticeWallThickness] = []

    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let red = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)
    private static let bx: CGFloat = 60, by: CGFloat = 30, padR: CGFloat = 78, padB: CGFloat = 30
    /// ★ the box is TALL whatever the wall's mm say (his 01:36)
    private static let boxHeight: CGFloat = 300
    /// the grid, in mm, both ways (his image 7)
    private static let gridMM: Double = 5
    private static let railWidth: CGFloat = 116

    public var body: some View {
        let grade = stage == .grade
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ZStack(alignment: .trailing) {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 18) {
                                ForEach(faces) { f in faceCard(f, grade: grade).id(f.id) }
                            }
                            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 24)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ScrollMetrics.self,
                                                       value: [ -g.frame(in: .named("wallScroll")).minY, g.size.height ])
                            })
                        }
                        .coordinateSpace(name: "wallScroll")
                        .background(GeometryReader { g in Color.clear.onAppear { scrollViewport = g.size.height }
                            .onChange(of: g.size.height) { scrollViewport = $0 } })
                        .onPreferenceChange(ScrollMetrics.self) { m in
                            if m.count == 2 { scrollOffset = m[0]; scrollContent = max(1, m[1]) }
                        }
                        if scrollContent > scrollViewport + 1 { scrollBar }
                    }
                    .overlay(alignment: .topTrailing) { if faces.count > 2 { arrows(proxy) } }
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
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
                }
                .padding(18)
            }
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(red: 9 / 255, green: 10 / 255, blue: 16 / 255).opacity(0.985))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.white.opacity(0.08))))
            // ★ the rail: to the right, nothing behind it, air between (his 02:12)
            if grade { rail.frame(width: Self.railWidth) }
        }
        .onAppear { if activeFace == nil { activeFace = faces.first?.id } }
    }

    private struct ScrollMetrics: PreferenceKey {
        static var defaultValue: [CGFloat] = []
        static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) { value = nextValue() }
    }

    private var scrollBar: some View {
        GeometryReader { g in
            let track = g.size.height
            let thumb = max(36, track * scrollViewport / scrollContent)
            let maxOff = max(1, scrollContent - scrollViewport)
            let y = (track - thumb) * min(1, max(0, scrollOffset / maxOff))
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(DS.Color.accent.opacity(0.75).color).frame(height: thumb).offset(y: y)
            }
            .frame(width: 8)
        }
        .frame(width: 8)
        .padding(.trailing, 8).padding(.vertical, 24)
        .accessibilityIdentifier("wall-editor-scrollbar")
    }

    private func arrows(_ proxy: ScrollViewProxy) -> some View {
        let ids = faces.map(\.id)
        let cur = ids.firstIndex(of: activeFace ?? "") ?? 0
        return VStack(spacing: 6) {
            Button {
                let i = max(0, cur - 1); activeFace = ids[i]
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(ids[i], anchor: .top) }
            } label: { Image(systemName: "chevron.up").font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40) }
                .buttonStyle(.plain).disabled(cur == 0).opacity(cur == 0 ? 0.35 : 1)
                .accessibilityIdentifier("wall-editor-up")
            Button {
                let i = min(ids.count - 1, cur + 1); activeFace = ids[i]
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(ids[i], anchor: .top) }
            } label: { Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40) }
                .buttonStyle(.plain).disabled(cur == ids.count - 1).opacity(cur == ids.count - 1 ? 0.35 : 1)
                .accessibilityIdentifier("wall-editor-down")
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 22 / 255, green: 24 / 255, blue: 34 / 255).opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09))))
        .foregroundStyle(DS.Color.textPrimary.color)
        .padding(.trailing, 24).padding(.top, 18)
    }

    // MARK: history

    /// Snapshot before a change that can be undone (a drag's first move, a tap, a rail op).
    private func remember() { undoStack.append(ask); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack.removeAll() }
    private func undo() { guard let p = undoStack.popLast() else { return }; redoStack.append(ask); ask = p; selPt = nil }
    private func redo() { guard let n = redoStack.popLast() else { return }; undoStack.append(ask); ask = n; selPt = nil }

    // MARK: per-face state

    private func faceAsk(_ id: String) -> LatticeFaceWallThickness { ask.faces[id] ?? LatticeFaceWallThickness() }
    private func setFace(_ id: String, _ mutate: (inout LatticeFaceWallThickness) -> Void) {
        var f = faceAsk(id); mutate(&f); ask.faces[id] = f
    }
    private func profile(_ f: LatticeWallEditorFace) -> LatticeWallCurves {
        let a = faceAsk(f.id)
        if let c = a.profile?.curves { return c }
        let t = max(f.thickMM, 1e-9)
        return .flat(start: a.startMM / t, end: (a.endMM ?? f.thickMM) / t)
    }
    private func setProfile(_ f: LatticeWallEditorFace, _ mutate: (inout LatticeWallCurves) -> Void) {
        var c = profile(f); mutate(&c); setFace(f.id) { $0.profile = LatticeWallProfile(curves: c) }
    }
    private func shares(_ f: LatticeWallEditorFace) -> (start: Double, end: Double) {
        let a = faceAsk(f.id), t = max(f.thickMM, 1e-9)
        return (min(max(0, a.startMM / t), 1), min(max(0, (a.endMM ?? f.thickMM) / t), 1))
    }
    /// ★ the mid-plane of the ALLOWED RANGE (review #45): the start line lives above it,
    /// the end line below — halves of the range, not of the wall
    private func midShare(_ f: LatticeWallEditorFace) -> Double { let s = shares(f); return 0.5 * (s.start + s.end) }
    /// The magnet: the nearest grid crossing, in the box's normalised units.
    private func snap(_ f: LatticeWallEditorFace, x: Double, y: Double) -> (Double, Double) {
        guard magnet else { return (x, y) }
        let gx = Self.gridMM / max(f.widthMM, 1e-9), gy = Self.gridMM / max(f.thickMM, 1e-9)
        return (min(1, max(0, (x / gx).rounded() * gx)), min(1, max(0, (y / gy).rounded() * gy)))
    }

    // MARK: one wall's card

    @ViewBuilder private func faceCard(_ f: LatticeWallEditorFace, grade: Bool) -> some View {
        let isActive = f.id == activeFace
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(f.tint).frame(width: 10, height: 10)
                Text(f.name).font(.system(size: 16, weight: .bold))
                Text(String(format: "%.0f × %.1f mm wall", f.widthMM, f.thickMM))
                    .font(.system(size: 13)).foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                if grade && isActive {
                    Text("● editing").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1))
                }
                Spacer(minLength: 0)
                Button { info3D = f.id } label: {
                    Image(systemName: "info.circle").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Color.textTertiary.color).frame(width: 30, height: 34)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { info3D == f.id }, set: { if !$0 { info3D = nil } })) {
                    Text("The 3D wall is the face's own prism — its outline, position and angle — and it updates automatically as you edit the lines.")
                        .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textPrimary.color)
                        .fixedSize(horizontal: false, vertical: true).padding(16).frame(maxWidth: 320)
                }
                .accessibilityIdentifier("wall-editor-3d-info-\(f.id)")
                Button {
                    if render3D.contains(f.id) { render3D.remove(f.id) } else { render3D.insert(f.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cube").font(.system(size: 12, weight: .semibold))
                        Text(render3D.contains(f.id) ? "Hide 3D" : "Show in 3D").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .background(Capsule().fill(render3D.contains(f.id) ? DS.Color.accent.opacity(0.22).color : Color.white.opacity(0.06))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1))))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wall-editor-3d-\(f.id)")
            }
            GeometryReader { g in
                let bw = max(80, g.size.width - Self.bx - Self.padR), bh = Self.boxHeight
                Canvas { ctx, _ in draw(f, in: &ctx, bw: bw, bh: bh, grade: grade, isActive: isActive) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in dragChanged(f, v, bw: bw, bh: bh, grade: grade) }
                        .onEnded { v in dragEnded(f, v, bw: bw, bh: bh, grade: grade) })
            }
            .frame(height: Self.by + Self.boxHeight + Self.padB)
            .accessibilityIdentifier("wall-editor-canvas-\(f.id)")
            if render3D.contains(f.id) {
                LatticeWallSlabRender(face: f, ask: faceAsk(f.id), pct: ask.pct)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08)))
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color(red: 20 / 255, green: 22 / 255, blue: 31 / 255).opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(grade && isActive ? Color(red: 0.5, green: 0.75, blue: 1).opacity(0.6) : Color.white.opacity(0.09), lineWidth: 1.2)))
        .foregroundStyle(DS.Color.textPrimary.color)
        .onTapGesture { if activeFace != f.id { activeFace = f.id } }
        .animation(.easeInOut(duration: 0.2), value: render3D)
        .accessibilityIdentifier("wall-editor-card-\(f.id)")
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
        ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(.white.opacity(0.05)))
        // ★ the 5 mm grid, dotted, both ways; every 25 mm a little stronger (his image 7)
        do {
            var g = ctx
            g.clip(to: Path(roundedRect: box, cornerRadius: 8))
            let stepX = CGFloat(Self.gridMM / max(f.widthMM, 1e-9)) * bw
            let stepY = CGFloat(Self.gridMM / max(f.thickMM, 1e-9)) * bh
            if stepX >= 4 {
                var i = 1; var x = box.minX + stepX
                while x < box.maxX - 0.5 {
                    var p = Path(); p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    g.stroke(p, with: .color(.white.opacity(i % 5 == 0 ? 0.22 : 0.10)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    i += 1; x += stepX
                }
            }
            if stepY >= 4 {
                var j = 1; var y = box.minY + stepY
                while y < box.maxY - 0.5 {
                    var p = Path(); p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                    g.stroke(p, with: .color(.white.opacity(j % 5 == 0 ? 0.22 : 0.10)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    j += 1; y += stepY
                }
            }
        }
        ctx.stroke(Path(roundedRect: box, cornerRadius: 8),
                   with: .color(grade && isActive ? Color(red: 0.5, green: 0.75, blue: 1).opacity(0.8) : .white.opacity(0.22)),
                   lineWidth: 1.5)
        let midY = box.minY + box.height * CGFloat(midShare(f))
        var mid = Path(); mid.move(to: CGPoint(x: box.minX, y: midY)); mid.addLine(to: CGPoint(x: box.maxX, y: midY))
        ctx.stroke(mid, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
        let labelFont = Font.system(size: 11, weight: .semibold)
        ctx.draw(Text("OUTER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.minY - 10), anchor: .leading)
        ctx.draw(Text("INNER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.maxY + 16), anchor: .leading)

        let prof = profile(f)
        let sh = shares(f)
        let startPts: [SIMD2<Double>] = grade
            ? LatticeWallCurves.polyline(prof.start, curved: prof.curveStart, side: .start)
            : [SIMD2(0, sh.start), SIMD2(1, sh.start)]
        let endPts: [SIMD2<Double>] = grade
            ? LatticeWallCurves.polyline(prof.end, curved: prof.curveEnd, side: .end)
            : [SIMD2(0, sh.end), SIMD2(1, sh.end)]
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
            for (y, col) in [(sh.start, Self.green), (sh.end, Self.red)] {
                let c = CGPoint(x: box.midX, y: Self.by + CGFloat(y) * bh)
                let circle = Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
                ctx.fill(circle, with: .color(col))
                ctx.stroke(circle, with: .color(Color(white: 0.02)), lineWidth: 3)
                ctx.draw(Text(String(format: "%.1f mm", y * f.thickMM)).font(readFont).foregroundColor(col),
                         at: CGPoint(x: readX, y: c.y), anchor: .leading)
            }
        } else {
            // the readouts, kept apart when the two lines meet
            let ys = Self.by + CGFloat(prof.start.first?.y ?? 0) * bh
            var ye = Self.by + CGFloat(prof.end.first?.y ?? 1) * bh
            if abs(ye - ys) < 16 { ye = ys + 16 }
            ctx.draw(Text("start").font(readFont).foregroundColor(Self.green), at: CGPoint(x: readX, y: ys), anchor: .leading)
            ctx.draw(Text("end").font(readFont).foregroundColor(Self.red), at: CGPoint(x: readX, y: ye), anchor: .leading)
            if showWings, let sp = selPt, sp.face == f.id {
                let pts = sp.side == .start ? prof.start : prof.end
                if sp.idx < pts.count, pts[sp.idx].smooth, (sp.side == .start ? prof.curveStart : prof.curveEnd) {
                    let p = pts[sp.idx], t = LatticeWallCurves.tangent(pts, sp.idx)
                    let c = CGPoint(x: Self.bx + CGFloat(p.x) * bw, y: Self.by + CGFloat(p.y) * bh)
                    let col = sp.side == .start ? Self.green : Self.red
                    for dir: CGFloat in [1, -1] where (dir == 1 && sp.idx < pts.count - 1) || (dir == -1 && sp.idx > 0) {
                        let e = CGPoint(x: c.x + CGFloat(t.x) * bw * dir, y: c.y + CGFloat(t.y) * bh * dir)
                        var l = Path(); l.move(to: c); l.addLine(to: e)
                        ctx.stroke(l, with: .color(col.opacity(0.55)), lineWidth: 1.2)
                        var d = Path(); d.move(to: CGPoint(x: e.x, y: e.y - 7)); d.addLine(to: CGPoint(x: e.x + 7, y: e.y))
                        d.addLine(to: CGPoint(x: e.x, y: e.y + 7)); d.addLine(to: CGPoint(x: e.x - 7, y: e.y)); d.closeSubpath()
                        ctx.fill(d, with: .color(Color(white: 0.02))); ctx.stroke(d, with: .color(col), lineWidth: 1.6)
                    }
                }
            }
            for s in [LatticeWallCurves.Side.start, .end] {
                let pts = s == .start ? prof.start : prof.end
                let col = s == .start ? Self.green : Self.red
                for (i, p) in pts.enumerated() {
                    let sel = selPt == SelPt(face: f.id, side: s, idx: i)
                    let c = CGPoint(x: Self.bx + CGFloat(p.x) * bw, y: Self.by + CGFloat(p.y) * bh)
                    let r: CGFloat = sel ? 11 : 8
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
            if inX, abs(p.y - ys) <= 24, abs(p.y - ys) <= abs(p.y - ye) { return .thick(.start) }
            if inX, abs(p.y - ye) <= 24 { return .thick(.end) }
            return .none
        }
        let prof = profile(f)
        if showWings, let sp = selPt, sp.face == f.id {
            let pts = sp.side == .start ? prof.start : prof.end
            if sp.idx < pts.count, pts[sp.idx].smooth {
                let q = pts[sp.idx], t = LatticeWallCurves.tangent(pts, sp.idx)
                let c = CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)
                for dir: CGFloat in [1, -1] where (dir == 1 && sp.idx < pts.count - 1) || (dir == -1 && sp.idx > 0) {
                    let e = CGPoint(x: c.x + CGFloat(t.x) * bw * dir, y: c.y + CGFloat(t.y) * bh * dir)
                    if hypot(p.x - e.x, p.y - e.y) <= 18 { return .wing(sp.side, sp.idx, Double(dir)) }
                }
            }
        }
        var best: (DragKind, CGFloat)? = nil
        for s in [LatticeWallCurves.Side.start, .end] {
            let pts = s == .start ? prof.start : prof.end
            for (i, q) in pts.enumerated() {
                let c = CGPoint(x: Self.bx + CGFloat(q.x) * bw, y: Self.by + CGFloat(q.y) * bh)
                let d = hypot(p.x - c.x, p.y - c.y)
                if d <= 24, best == nil || d < best!.1 { best = (.point(s, i), d) }
            }
        }
        return best?.0 ?? .none
    }

    private func dragChanged(_ f: LatticeWallEditorFace, _ g: DragGesture.Value, bw: CGFloat, bh: CGFloat, grade: Bool) {
        if drag == nil || drag?.face != f.id {
            let kind = hit(f, at: g.startLocation, bw: bw, bh: bh, grade: grade)
            drag = Drag(face: f.id, kind: kind, moved: false)
            activeFace = f.id
            if case let .point(s, i) = kind { side = s; selPt = SelPt(face: f.id, side: s, idx: i) }
            if case let .wing(s, _, _) = kind { side = s }
        }
        guard var d = drag else { return }
        if !d.moved, hypot(g.translation.width, g.translation.height) > 3 {
            d.moved = true; drag = d
            if d.kind != .none { remember() }
        }
        let n = norm(g.location, bw: bw, bh: bh)
        let nx = clamp(n.x, 0, 1), ny = clamp(n.y, 0, 1)
        switch d.kind {
        case let .thick(s):
            guard d.moved else { return }
            setFace(f.id) { a in
                let t = f.thickMM
                let cur = (a.startMM / t, (a.endMM ?? t) / t)
                let (_, sy) = snap(f, x: 0, y: ny)
                if s == .start { a.startMM = min(sy, cur.1 - 0.02) * t }
                else {
                    let e = max(sy, cur.0 + 0.02) * t
                    a.endMM = e >= t - 1e-9 ? nil : e
                }
            }
        case let .point(s, i):
            guard tool == .move || d.moved else { return }
            setProfile(f) { p in
                var arr = s == .start ? p.start : p.end
                guard i < arr.count else { return }
                var q = arr[i]
                let (sx, sy) = snap(f, x: nx, y: ny)
                let m = midShare(f)
                q.y = s == .start ? min(sy, m) : max(sy, m)
                if i != 0, i != arr.count - 1 { q.x = clamp(sx, arr[i - 1].x + 0.02, arr[i + 1].x - 0.02) }
                arr[i] = q
                if s == .start { p.start = arr } else { p.end = arr }
            }
        case let .wing(s, i, dir):
            setProfile(f) { p in
                var arr = s == .start ? p.start : p.end
                guard i < arr.count else { return }
                var q = arr[i]
                // in px so angles are true on screen; detents at every 45° (his image 7)
                var dx = (Double(g.location.x) - (Double(Self.bx) + q.x * Double(bw))) * dir
                var dy = (Double(g.location.y) - (Double(Self.by) + q.y * Double(bh))) * dir
                let len = hypot(dx, dy), ang = atan2(dy, dx), step = Double.pi / 4
                let snapped = (ang / step).rounded() * step
                if abs(ang - snapped) < 0.2 { dx = cos(snapped) * len; dy = sin(snapped) * len }
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
        if grade, tool == .pen, d.kind == .none, !d.moved {
            let n = norm(g.location, bw: bw, bh: bh)
            guard n.x > 0.02, n.x < 0.98, n.y > -0.1, n.y < 1.1 else { return }
            let m = midShare(f)
            let tapSide: LatticeWallCurves.Side = n.y < m ? .start : .end
            side = tapSide
            remember()
            setProfile(f) { p in
                var arr = tapSide == .start ? p.start : p.end
                let (sx, sy) = snap(f, x: n.x, y: n.y)
                var i = arr.firstIndex { $0.x > sx } ?? (arr.count - 1)
                if i < 0 { i = 0 }
                arr.insert(.init(x: sx, y: tapSide == .start ? clamp(sy, 0, m) : clamp(sy, m, 1)), at: i)
                if tapSide == .start { p.start = arr } else { p.end = arr }
                selPt = SelPt(face: f.id, side: tapSide, idx: i)
            }
        }
    }

    // MARK: the rail (grade stage)

    private var activeFaceModel: LatticeWallEditorFace? { faces.first { $0.id == activeFace } ?? faces.first }
    private var sideTint: Color { side == .start ? Self.green : Self.red }
    private var selectedPoint: LatticeWallCurvesPoint? {
        guard let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) else { return nil }
        let pts = sp.side == .start ? profile(f).start : profile(f).end
        return sp.idx < pts.count ? pts[sp.idx] : nil
    }
    private func sideOp(_ fn: ([LatticeWallCurvesPoint]) -> [LatticeWallCurvesPoint]) {
        guard let f = activeFaceModel else { return }
        remember()
        setProfile(f) { p in if side == .start { p.start = fn(p.start) } else { p.end = fn(p.end) } }
    }

    @ViewBuilder private var rail: some View {
        let selSmooth = selectedPoint?.smooth ?? true
        let selLeft = (selectedPoint?.x ?? 0) <= 0.5
        VStack(spacing: 6) {
            // ★ undo / redo at the top (his image 8)
            HStack(spacing: 6) {
                railButton("↶", "Undo", on: false, enabled: !undoStack.isEmpty) { undo() }
                railButton("↷", "Redo", on: false, enabled: !redoStack.isEmpty) { redo() }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                railButton("✎", "Pen", on: tool == .pen) { tool = .pen }
                railButton("✥", "Move", on: tool == .move) { tool = .move }
            }
            HStack(spacing: 6) {
                railButton("⌖", "Handles", on: showWings) { showWings.toggle() }
                // ★ the magnet: points tick into the grid's crossings (his image 8)
                railButton("🧲", "Magnet", on: magnet) { magnet.toggle() }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Circle().fill(sideTint).frame(width: 8, height: 8)
                Text((side == .start ? "Start" : "End") + " line").font(.system(size: 10.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(sideTint)
            }
            holdButton(glyph: selSmooth ? "∿" : "⟋", label: selSmooth ? "Curved" : "Straight",
                       hint: holdAll ? "all points" : (selPt == nil ? "hold: whole line" : "tap: this point"),
                       lit: holdAll, id: "wall-editor-curve",
                       onHold: { holdAll = true },
                       onRelease: { held in
                           if held {
                               let target = !selSmooth
                               sideOp { $0.map { var q = $0; q.smooth = target; return q } }
                               holdAll = false
                           } else if let sp = selPt, let f = faces.first(where: { $0.id == sp.face }) {
                               remember()
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
                                   let refl = src.filter { abs($0.x - 0.5) > 0.001 }.map { q -> LatticeWallCurvesPoint in
                                       var r = q; r.x = 1 - q.x; if let ty = q.ty { r.ty = -ty }; return r
                                   }
                                   return (src + refl).sorted { $0.x < $1.x }
                               }
                               holdMirror = false
                           } else if let f = activeFaceModel {
                               remember()
                               setProfile(f) { p in
                                   let from = side == .start ? p.start : p.end
                                   let other: LatticeWallCurves.Side = side == .start ? .end : .start
                                   let m = midShare(f)
                                   let mapped = from.map { q -> LatticeWallCurvesPoint in
                                       var r = q
                                       r.y = other == .start ? clamp(2 * m - q.y, 0, m) : clamp(2 * m - q.y, m, 1)
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
                    let m = activeFaceModel.map(midShare) ?? 0.5
                    y = side == .start ? min(y, m) : max(y, m)
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
                remember()
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
                remember()
                let sh = shares(f)
                setFace(f.id) { $0.profile = LatticeWallProfile(curves: .flat(start: sh.start, end: sh.end)) }
            } label: {
                Text("Reset face").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.09)))
                    .foregroundStyle(DS.Color.textPrimary.opacity(0.6).color)
            }.buttonStyle(.plain).accessibilityIdentifier("wall-editor-reset")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(red: 22 / 255, green: 24 / 255, blue: 34 / 255).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.white.opacity(0.09))))
        .foregroundStyle(DS.Color.textPrimary.color)
        .accessibilityIdentifier("wall-editor-rail")
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

    @ViewBuilder private func railButton(_ glyph: String, _ name: String, on: Bool = false, enabled: Bool = true,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(glyph).font(.system(size: 17))
                Text(name).font(.system(size: 11.5, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? DS.Color.accent.opacity(0.24).color : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? DS.Color.accent.opacity(0.6).color : Color.white.opacity(0.09))))
            .foregroundStyle(on ? .white : DS.Color.textPrimary.opacity(0.7).color)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
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

