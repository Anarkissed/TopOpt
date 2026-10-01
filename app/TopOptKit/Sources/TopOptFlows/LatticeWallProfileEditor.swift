import SwiftUI
import simd
import TopOptDesign

// ★★★ THE WALL EDITOR IN THE VIEWER — his design `Lattice Wall Thickness.dc.html` and his
// notes (2026-09-21, 01:36, 02:12), rebuilt on his three decisions of the evening:
//
//   D1  the drawing is CELL-BASED, not curve-based: the box is divided into columns one
//       cell wide along the wall and rows at the depths the wall's cells can be packed to;
//       the user PAINTS the depth per column and the preview draws exactly those steps,
//       in 2D here and in 3D on the card.
//   D2' (his 22:40) the START line is back: "the user may want the lattice to start further
//       inside" — the start in the outer half, the end in the inner, as the curves have it.
//   D3  it is called depth, not density.
//
// The editor still spans the stage from the far left above the minimised settings, one
// squircle card per wall with a BIG box (OUTER SURFACE above, INNER SURFACE below), the
// cards scroll with a bar and arrows past two walls, the rail floats to the right with
// air around it, Cancel / Save at the very bottom, "Show in 3D" renders THAT wall.
//
//   thickness stage  one bar to drag — how deep the lattice may go on each wall
//   grade stage      paint: drag across the box and every column under the finger takes
//                    the depth under it (snapped to the wall's steps); the rail undoes /
//                    redoes, fills, flattens, mirrors, shifts and resets.

public struct LatticeWallEditorFace: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let tint: Color
    public let widthMM: Double
    public let heightMM: Double
    public let thickMM: Double
    /// The face prism itself, for the true-shape render.
    public let region: LatticeRegionSpec?
    /// The depths this wall can be packed to (ascending, 0 first); empty ⇒ continuous (organic).
    public let depthStepsMM: [Double]
    /// The width of one drawn column along the wall (the wall's base cell; 5 mm for organic).
    public let columnMM: Double
    public init(id: String, name: String, tint: Color, widthMM: Double, heightMM: Double, thickMM: Double,
                region: LatticeRegionSpec? = nil, depthStepsMM: [Double] = [], columnMM: Double = 5) {
        self.id = id; self.name = name; self.tint = tint
        self.widthMM = widthMM; self.heightMM = heightMM; self.thickMM = thickMM; self.region = region
        self.depthStepsMM = depthStepsMM; self.columnMM = max(0.5, columnMM)
    }
    /// How many columns the box is divided into.
    /// ★ one column per base cell; the cap only guards a degenerate pitch (review #44: 96
    /// made a 2 mm cell on a 300 mm wall a 3-cell column)
    public var columns: Int { max(1, min(400, Int((widthMM / columnMM).rounded()))) }
    /// A depth in mm snapped to this wall's steps (or to 0.5 mm when continuous), never above
    /// the wall. The END rounds DOWN and never to nothing (a positive ask is never left solid);
    /// the START rounds to the NEAREST step, zero included, so the line can sit at the surface
    /// (his 2026-09-22: "won't let me go down to 0 in the green section").
    public func snap(_ mm: Double, nearest: Bool = false) -> Double {
        let v = min(thickMM, max(0, mm))
        if depthStepsMM.isEmpty { return (v * 2).rounded() / 2 }
        if nearest {
            return depthStepsMM.min { abs($0 - v) < abs($1 - v) } ?? v
        }
        return min(thickMM, LatticeWallDepthSteps.snap(v, steps: depthStepsMM))
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

    private struct Drag: Equatable { var face: String; var moved: Bool; var lastColumn: Int? }

    @State private var activeFace: String? = nil
    @State private var drag: Drag? = nil
    @State private var hover: (face: String, column: Int, mm: Double)? = nil
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
                        Text(grade ? "Save depth" : "Save depth").font(.system(size: 16, weight: .bold))
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

    private func remember() { undoStack.append(ask); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack.removeAll() }
    private func undo() { guard let p = undoStack.popLast() else { return }; redoStack.append(ask); ask = p }
    private func redo() { guard let n = redoStack.popLast() else { return }; undoStack.append(ask); ask = n }

    // MARK: per-face state

    private func faceAsk(_ id: String) -> LatticeFaceWallThickness { ask.faces[id] ?? LatticeFaceWallThickness() }
    private func setFace(_ id: String, _ mutate: (inout LatticeFaceWallThickness) -> Void) {
        var f = faceAsk(id); mutate(&f); ask.faces[id] = f
    }
    /// The allowed range on this wall, in mm from the surface.
    private func allowedMM(_ f: LatticeWallEditorFace) -> (start: Double, end: Double) {
        let a = faceAsk(f.id)
        let e = min(f.thickMM, a.endMM ?? f.thickMM)
        return (min(max(0, a.startMM), max(0, e - 0.1)), e)
    }
    /// The drawn steps on this wall, on its column count (the allowed range, flat, when none).
    private func profile(_ f: LatticeWallEditorFace) -> LatticeWallProfile {
        let a = faceAsk(f.id), t = max(f.thickMM, 1e-9)
        if let p = a.profile, !p.isCurves { return p.resampled(columns: f.columns) }
        let r = allowedMM(f)
        return .flat(start: r.start / t, end: r.end / t, columns: f.columns)
    }
    private func setProfile(_ f: LatticeWallEditorFace, _ mutate: (inout LatticeWallProfile) -> Void) {
        var p = profile(f); mutate(&p); setFace(f.id) { $0.profile = p }
    }
    /// The depth (mm) a touch at normalised y means on this wall, for the line of that half:
    /// the start stays in the outer half (≤ 50 %), the end in the inner (≥ 50 %); both snapped
    /// to the wall's steps and held inside the allowed range.
    private func depthAt(_ f: LatticeWallEditorFace, y: Double, side: LatticeWallProfile.Side) -> Double {
        let r = allowedMM(f), t = f.thickMM
        // ★ the halves are halves of the ALLOWED RANGE (review #45): with a range of
        // 8–12 on a 12 mm wall the start's "≤ 50 %" (6 mm) clamped to 8 and never moved
        let mid = 0.5 * (r.start + r.end)
        let raw = min(1, max(0, y)) * t
        let v = side == .start ? min(mid, max(r.start, raw)) : max(mid, min(r.end, raw))
        return f.snap(v, nearest: side == .start)
    }
    /// The mid-plane of the allowed range, as a share of the wall (the editor's y).
    private func midShare(_ f: LatticeWallEditorFace) -> Double {
        let r = allowedMM(f); return 0.5 * (r.start + r.end) / max(f.thickMM, 1e-9)
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
                if grade {
                    Text(f.depthStepsMM.isEmpty ? "continuous" : String(format: "%.1f mm cells", f.columnMM))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.opacity(0.45).color)
                }
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
                    Text("The 3D wall is the face's own prism — its outline, position and angle — and it updates automatically as you paint the depth. It shows the steps exactly as they will be laid.")
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
                        .onEnded { _ in drag = nil; hover = nil })
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

    private func draw(_ f: LatticeWallEditorFace, in ctx: inout GraphicsContext, bw: CGFloat, bh: CGFloat,
                      grade: Bool, isActive: Bool) {
        let box = CGRect(x: Self.bx, y: Self.by, width: bw, height: bh)
        let t = max(f.thickMM, 1e-9)
        ctx.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(.white.opacity(0.05)))
        // ★ the grid IS the cells (D1): columns one cell wide, rows at the packable depths
        do {
            var g = ctx
            g.clip(to: Path(roundedRect: box, cornerRadius: 8))
            let cols = f.columns
            let stepX = bw / CGFloat(cols)
            if stepX >= 3 {
                for i in 1..<max(1, cols) {
                    let x = box.minX + CGFloat(i) * stepX
                    var p = Path(); p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    g.stroke(p, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }
            }
            let rows: [Double] = f.depthStepsMM.isEmpty
                ? Swift.stride(from: 5.0, to: f.thickMM, by: 5.0).map { $0 }
                : f.depthStepsMM.filter { $0 > 0 && $0 < f.thickMM - 1e-6 }
            for mm in rows {
                let y = box.minY + CGFloat(mm / t) * bh
                var p = Path(); p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                g.stroke(p, with: .color(.white.opacity(f.depthStepsMM.isEmpty ? 0.10 : 0.18)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                if !f.depthStepsMM.isEmpty {
                    g.draw(Text(String(format: "%.1f", mm)).font(.system(size: 9)).foregroundColor(.white.opacity(0.3)),
                           at: CGPoint(x: box.minX - 6, y: y), anchor: .trailing)
                }
            }
        }
        ctx.stroke(Path(roundedRect: box, cornerRadius: 8),
                   with: .color(grade && isActive ? Color(red: 0.5, green: 0.75, blue: 1).opacity(0.8) : .white.opacity(0.22)),
                   lineWidth: 1.5)
        let labelFont = Font.system(size: 11, weight: .semibold)
        ctx.draw(Text("OUTER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.minY - 10), anchor: .leading)
        ctx.draw(Text("INNER SURFACE").font(labelFont).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: box.minX, y: box.maxY + 16), anchor: .leading)

        // the mid-plane: the start line lives above it, the end line below (his 50 % rule)
        let midY = box.minY + box.height * CGFloat(midShare(f))
        var midp = Path(); midp.move(to: CGPoint(x: box.minX, y: midY)); midp.addLine(to: CGPoint(x: box.maxX, y: midY))
        ctx.stroke(midp, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
        // the steps: the band between each column's start and end
        let allowed = allowedMM(f)
        let prof = profile(f)
        let starts: [Double] = grade ? prof.starts.map { min(allowed.end, max(allowed.start, $0 * t)) } : [allowed.start]
        let ends: [Double] = grade ? prof.ends.map { min(allowed.end, max(allowed.start, $0 * t)) } : [allowed.end]
        let cols = ends.count
        func stepPath(_ v: [Double]) -> Path {
            var p = Path()
            for (i, mm) in v.enumerated() {
                let x0 = box.minX + bw * CGFloat(i) / CGFloat(cols), x1 = box.minX + bw * CGFloat(i + 1) / CGFloat(cols)
                let y = box.minY + CGFloat(mm / t) * bh
                if i == 0 { p.move(to: CGPoint(x: x0, y: y)) } else { p.addLine(to: CGPoint(x: x0, y: y)) }
                p.addLine(to: CGPoint(x: x1, y: y))
            }
            return p
        }
        var region = stepPath(starts)
        for i in stride(from: cols - 1, through: 0, by: -1) {
            let x0 = box.minX + bw * CGFloat(i) / CGFloat(cols), x1 = box.minX + bw * CGFloat(i + 1) / CGFloat(cols)
            let y = box.minY + CGFloat(ends[i] / t) * bh
            region.addLine(to: CGPoint(x: x1, y: y)); region.addLine(to: CGPoint(x: x0, y: y))
        }
        region.closeSubpath()
        if grade {
            ctx.fill(region, with: .linearGradient(Gradient(colors: [Self.green.opacity(0.45), Self.red.opacity(0.45)]),
                                                   startPoint: CGPoint(x: box.midX, y: box.minY),
                                                   endPoint: CGPoint(x: box.midX, y: box.maxY)))
        } else {
            ctx.fill(region, with: .color(Color(red: 79 / 255, green: 168 / 255, blue: 1).opacity(0.16)))
        }
        ctx.stroke(stepPath(starts), with: .color(Self.green), style: StrokeStyle(lineWidth: grade ? 3 : 2.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(stepPath(ends), with: .color(Self.red), style: StrokeStyle(lineWidth: grade ? 3 : 2.5, lineCap: .round, lineJoin: .round))

        let readX = box.maxX + 14
        let readFont = Font.system(size: 12.5, weight: .bold)
        if !grade {
            for (mm, col) in [(allowed.start, Self.green), (allowed.end, Self.red)] {
                let c = CGPoint(x: box.midX, y: Self.by + CGFloat(mm / t) * bh)
                let circle = Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
                ctx.fill(circle, with: .color(col))
                ctx.stroke(circle, with: .color(Color(white: 0.02)), lineWidth: 3)
                ctx.draw(Text(String(format: "%.1f mm", mm)).font(readFont).foregroundColor(col),
                         at: CGPoint(x: readX, y: c.y), anchor: .leading)
            }
        } else {
            let ys = Self.by + CGFloat((starts.first ?? 0) / t) * bh
            var ye = Self.by + CGFloat((ends.first ?? t) / t) * bh
            if abs(ye - ys) < 16 { ye = ys + 16 }
            ctx.draw(Text("start").font(readFont).foregroundColor(Self.green), at: CGPoint(x: readX, y: ys), anchor: .leading)
            ctx.draw(Text("end").font(readFont).foregroundColor(Self.red), at: CGPoint(x: readX, y: ye), anchor: .leading)
            if let h = hover, h.face == f.id, h.column < cols {
                let x = box.minX + bw * (CGFloat(h.column) + 0.5) / CGFloat(cols)
                let y = box.minY + CGFloat(h.mm / t) * bh
                let c = Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14))
                ctx.fill(c, with: .color(.white)); ctx.stroke(c, with: .color(h.mm / t <= midShare(f) ? Self.green : Self.red), lineWidth: 2.5)
                ctx.draw(Text(String(format: "%.1f mm", h.mm)).font(readFont).foregroundColor(.white),
                         at: CGPoint(x: x, y: max(box.minY + 10, y - 18)), anchor: .center)
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

    private func dragChanged(_ f: LatticeWallEditorFace, _ g: DragGesture.Value, bw: CGFloat, bh: CGFloat, grade: Bool) {
        if drag == nil || drag?.face != f.id {
            drag = Drag(face: f.id, moved: false, lastColumn: nil)
            activeFace = f.id
            remember()
        }
        guard var d = drag else { return }
        d.moved = true
        let n = norm(g.location, bw: bw, bh: bh)
        let ny = min(1, max(0, n.y))
        if !grade {
            // two bars — the nearer one to where the drag began follows (snapped to the steps)
            let r = allowedMM(f), t = f.thickMM
            let s0 = norm(g.startLocation, bw: bw, bh: bh).y
            let nearStart = abs(s0 - r.start / t) <= abs(s0 - r.end / t)
            let mm = f.snap(ny * t, nearest: nearStart)
            setFace(f.id) { a in
                if nearStart { a.startMM = min(mm, r.end - 0.1) }
                else { let e = max(mm, r.start + 0.1); a.endMM = e >= t - 1e-9 ? nil : e }
            }
            drag = d
            return
        }
        // paint: the column under the finger takes the depth under it, on the line of the
        // half touched (start above the mid-plane, end below) — and every column between
        // the last one and this, so a fast stroke leaves no gap
        let cols = f.columns
        let col = min(cols - 1, max(0, Int((n.x * Double(cols)).rounded(.down))))
        let side: LatticeWallProfile.Side = ny < midShare(f) ? .start : .end
        let mm = depthAt(f, y: ny, side: side)
        let from = d.lastColumn ?? col
        setProfile(f) { p in
            for c in min(from, col)...max(from, col) where c < p.ends.count {
                if side == .start { p.starts[c] = mm / max(f.thickMM, 1e-9) } else { p.ends[c] = mm / max(f.thickMM, 1e-9) }
            }
        }
        hover = (f.id, col, mm)
        d.lastColumn = col
        drag = d
    }

    // MARK: the rail (grade stage)

    private var activeFaceModel: LatticeWallEditorFace? { faces.first { $0.id == activeFace } ?? faces.first }
    private func op(_ fn: (LatticeWallEditorFace, inout LatticeWallProfile) -> Void) {
        guard let f = activeFaceModel else { return }
        remember()
        setProfile(f) { fn(f, &$0) }
    }

    @ViewBuilder private var rail: some View {
        VStack(spacing: 6) {
            // ★ undo / redo at the top (his image 8)
            HStack(spacing: 6) {
                railButton("↶", "Undo", enabled: !undoStack.isEmpty) { undo() }
                railButton("↷", "Redo", enabled: !redoStack.isEmpty) { redo() }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 6) {
                Circle().fill(Self.red).frame(width: 8, height: 8)
                Text("Depth steps").font(.system(size: 10.5, weight: .bold)).tracking(0.6).foregroundStyle(Self.red)
            }
            Text("Drag across the box: above the dotted line shapes the start, below it the end. Each column takes the depth under your finger.")
                .font(.system(size: 10.5)).foregroundStyle(DS.Color.textPrimary.opacity(0.5).color)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            railButton("▮", "Fill") { op { f, p in
                let r = allowedMM(f), t = max(f.thickMM, 1e-9)
                p.starts = p.starts.map { _ in r.start / t }; p.ends = p.ends.map { _ in r.end / t }
            } }
            railButton("—", "Flatten") { op { f, p in
                func mid(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
                let sm = f.snap(mid(p.starts) * f.thickMM) / max(f.thickMM, 1e-9)
                let em = f.snap(mid(p.ends) * f.thickMM) / max(f.thickMM, 1e-9)
                p.starts = p.starts.map { _ in sm }; p.ends = p.ends.map { _ in em }
            } }
            railButton("⇋", "Mirror") { op { _, p in p.starts.reverse(); p.ends.reverse() } }
            HStack(spacing: 6) {
                railButton("←", "Shift") { op { _, p in
                    guard p.ends.count > 1 else { return }
                    p.ends.append(p.ends.removeFirst()); p.starts.append(p.starts.removeFirst())
                } }
                railButton("→", "Shift ") { op { _, p in
                    guard p.ends.count > 1 else { return }
                    p.ends.insert(p.ends.removeLast(), at: 0); p.starts.insert(p.starts.removeLast(), at: 0)
                } }
            }
            Divider().overlay(Color.white.opacity(0.08))
            Button {
                guard let f = activeFaceModel else { return }
                remember()
                setFace(f.id) { $0.profile = nil }
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

    @ViewBuilder private func railButton(_ glyph: String, _ name: String, on: Bool = false, enabled: Bool = true,
                                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(glyph).font(.system(size: 17))
                Text(name.trimmingCharacters(in: .whitespaces)).font(.system(size: 11.5, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? DS.Color.accent.opacity(0.24).color : Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(on ? DS.Color.accent.opacity(0.6).color : Color.white.opacity(0.09))))
            .foregroundStyle(on ? .white : DS.Color.textPrimary.opacity(0.7).color)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityIdentifier("wall-editor-\(name.lowercased().filter { $0.isLetter })\(name.hasSuffix(" ") ? "-right" : "")")
    }
}

/// ★ The wall in 3D inside its card — the steps the drawing makes, in the face's own
/// prism (outline, position, angle), framed like a freshly opened viewer; rebuilt on
/// every edit. Nothing where no depth is drawn.
struct LatticeWallSlabRender: View {
    let face: LatticeWallEditorFace
    let ask: LatticeFaceWallThickness
    let pct: Double
    @StateObject private var camera = OrbitCameraModel()
    @State private var framed = false

    private var mesh: ViewerMesh {
        if let r = face.region {
            return LatticeWallSlabMesh.build(region: r, ask: ask, pct: pct,
                                             depthSteps: face.depthStepsMM.isEmpty ? nil : face.depthStepsMM)
        }
        return LatticeWallSlabMesh.build(widthMM: face.widthMM, heightMM: face.heightMM, thickMM: face.thickMM,
                                         ask: ask, pct: pct)
    }
    private var lines: [Float] {
        if let r = face.region { return LatticeWallSlabMesh.prismLines(region: r) }
        return LatticeWallSlabMesh.boxLines(widthMM: face.widthMM, heightMM: face.heightMM, thickMM: face.thickMM)
    }

    var body: some View {
        let m = mesh
        ZStack {
            MetalMeshView(mesh: m.isEmpty ? nil : m, camera: camera, extraLines: lines)
            if m.isEmpty {
                Text("No slab — the start and end lines meet.")
                    .dsStyle(DS.TypeScale.footnote).foregroundStyle(DS.Color.textTertiary.color)
            }
        }
        .onAppear {
            guard !framed else { return }
            framed = true
            if let r = face.region {
                let l = LatticeWallSlabMesh.prismLines(region: r)
                var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                var i = 0
                while i + 2 < l.count { let p = SIMD3(l[i], l[i + 1], l[i + 2]); lo = simd_min(lo, p); hi = simd_max(hi, p); i += 3 }
                if lo.x <= hi.x { camera.reframe(MeshBounds(min: lo, max: hi, isEmpty: false)) }
            } else if !m.isEmpty {
                camera.reframe(m.bounds)
            }
        }
        .background(Color(red: 8 / 255, green: 9 / 255, blue: 14 / 255))
        .accessibilityIdentifier("wall-editor-3d-render-\(face.id)")
    }
}
