// FlexiblePlanCut — B9 (#362) slice 3, + Cut on the Print plan (app-map §3.7 "1 · Pieces", design-system §4.31; round 3 P7 /
// P8 "Plane first"; U18: every Tilt has a Rotate; U19: a cut that is placed or drawn shows the plane card first, the camera
// faces the plane (draw) or sees it edge-on (place), and comes back after ✓ or ✕).
//   * + Cut ⌄ offers SIX ways. A plane, Draw on a plane and Keyed step cut open with "start from which plane?" (Top · Front ·
//     Side · A face). The plane is drawn on the part (a thin slab, FlexibleMainStage.volumes), and the view turns to it —
//     edge-on to place it, straight at it to draw on it — and back to his own view after ✓ or ✕.
//   * The bar (one place: the top of the free model area, clear of the panel and the view corner): ✕ · the plane chip ⌄ ·
//     Move (mm) · Tilt ↺ n° ↻ · Rotate ↺ n° ↻ · Key (keyed) · ✓.
// ★ FRONT END FIRST (his 11-03 answer): cutting the body by a plane, a drawn curve, a shape, an offset or an edge loop is
// engine work (E5 item 62); so is A face (its plane from the tapped face) and the Pencil / Spline stroke capture, which come
// with the next slice. ✓ keeps the cut in the plan (a row under Pieces, Join removes it) and says in one plain line that
// its pieces come with the engine update — it never draws pieces the engine has not cut.

import SwiftUI
import simd
import TopOptDesign

/// The cut being placed: its way, its step (the plane card, then the bar) and its plane.
public struct FlexiblePlanCutDraft: Equatable, Sendable {
    /// The plane card, then (A face) waiting for his tap on a flat face, then the bar.
    public enum Step: Equatable, Sendable { case pick, face, place }
    /// ★ slice 4: how he draws on the plane — ✎ freehand, 〰 through tapped points.
    public enum Tool: String, Equatable, Sendable { case pencil, spline }
    public var cut: FlexiblePlanCut
    public var step: Step
    public var tool: Tool?
    /// The stroke as drawn, in the page's points (freehand samples, or the spline's tapped points).
    public var stroke: [CGPoint] = []
    /// A tap in A face mode that missed a flat face (the bar says so).
    public var faceMiss = false
    public init(way: FlexibleCutWay) {
        cut = FlexiblePlanCut(way: way)
        step = way.planeFirst ? .pick : .place
    }
    /// What turns the camera (the plane and the step) — never the stroke.
    var turnKey: String {
        "\(step) \(cut.way) \(cut.base) \(cut.offsetMM) \(cut.tiltDeg) \(cut.rotateDeg) \(cut.faceNormal ?? [])"
    }
    /// The stroke is enough to cut with: a freehand line or two tapped points.
    var strokeReady: Bool { tool != nil && stroke.count >= 2 }
}

enum FlexiblePlanCutCopy {
    static let ask = "start from which plane?"
    static let move = "Move"
    static let tilt = "Tilt"
    static let rotate = "Rotate"
    static let key = "Key"
    static let pencil = "Pencil: draw freehand"
    static let spline = "Spline: tap points"
    static let tapFace = "tap a flat face of the part"
    static let notFlat = "That face isn\u{2019}t flat: tap a flat one."
    static let pickTool = "Pick \u{270E} or \u{3030}, then draw on the plane."
    static let drawPencil = "Draw across the part on the plane."
    static let drawSpline = "Tap points on the plane; tap a point again to remove it."
    static let noView = "Couldn\u{2019}t read the plane from this view: draw again."
    static func pickOnPart(_ w: FlexibleCutWay) -> String {
        switch w {
        case .shape: return "Box, cylinder or ball: placing it comes with the engine update."
        case .offset: return "Tap a face to offset from: comes with the engine update."
        case .edges: return "Tap an edge loop: comes with the engine update."
        default: return ""
        }
    }
    static func kept(_ w: FlexibleCutWay) -> String { "\(w.title) is kept. Its pieces come with the engine update." }
    static func row(_ c: FlexiblePlanCut) -> String {
        c.way.planeFirst ? "\(c.way.title) \u{00B7} \(c.base.chip.lowercased())" : c.way.title
    }
    static let rowSub = "pieces come with the engine update"
}

// MARK: - the plane's geometry (model space)

enum FlexiblePlaneFrame {
    /// The base's frame: its normal and two in-plane axes (model space; Top is the build plate's plane, +Z up). A face: its
    /// own normal (slice 4), the in-plane axes from the model axis least along it.
    static func base(_ c: FlexiblePlanCut) -> (n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
        switch c.base {
        case .top: return (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .front: return (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .side: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .face:
            guard let fn = c.faceNormal, fn.count == 3 else { return (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)) }
            let n = simd_normalize(SIMD3<Float>(Float(fn[0]), Float(fn[1]), Float(fn[2])))
            let axes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
            let a = axes.min { abs(simd_dot($0, n)) < abs(simd_dot($1, n)) }!
            let u = simd_normalize(a - n * simd_dot(a, n))
            return (n, u, simd_cross(n, u))
        }
    }

    /// ★ slice 4: the tapped face's plane (model space) — a point on it and its outward normal, from its triangles (area
    /// weighted) — or nil when the face is not flat (a triangle more than 5° off) or has no triangles.
    static func facePlane(_ face: Int32, mesh: ViewerMesh) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        var nSum = SIMD3<Float>(repeating: 0), cSum = SIMD3<Float>(repeating: 0), area: Float = 0
        var normals: [SIMD3<Float>] = []
        func p(_ i: UInt32) -> SIMD3<Float> { SIMD3(mesh.positions[3 * Int(i)], mesh.positions[3 * Int(i) + 1], mesh.positions[3 * Int(i) + 2]) }
        for t in 0..<min(mesh.faceIDs.count, mesh.indices.count / 3) where mesh.faceIDs[t] == face {
            let a = p(mesh.indices[3 * t]), b = p(mesh.indices[3 * t + 1]), c = p(mesh.indices[3 * t + 2])
            let cr = simd_cross(b - a, c - a), l = simd_length(cr)
            guard l > 1e-9 else { continue }
            nSum += cr; cSum += (a + b + c) / 3 * (l / 2); area += l / 2
            normals.append(cr / l)
        }
        guard area > 0, simd_length(nSum) > 1e-9 else { return nil }
        let n = simd_normalize(nSum)
        guard normals.allSatisfy({ simd_dot($0, n) >= cos(5 * Float.pi / 180) }) else { return nil }
        return (cSum / area, n)
    }

    /// ★ slice 4: where a point on the screen lands on the plane, in the plane's own (u, v) mm about its centre — the ray through
    /// the point (the view's clip-from-model inverted) met with the plane. nil when the ray runs along the plane.
    static func onPlane(_ pt: CGPoint, view: LatticeBandChipFrame, cut: FlexiblePlanCut, bounds: MeshBounds) -> SIMD2<Float>? {
        guard view.viewportSize.width > 0, view.viewportSize.height > 0 else { return nil }
        let inv = view.clipFromModel.inverse
        let x = Float(pt.x / view.viewportSize.width) * 2 - 1, y = 1 - Float(pt.y / view.viewportSize.height) * 2
        func un(_ z: Float) -> SIMD3<Float> { let h = inv * SIMD4<Float>(x, y, z, 1); return SIMD3(h.x, h.y, h.z) / h.w }
        let o = un(-1), d = simd_normalize(un(1) - o)
        let f = frame(cut, bounds: bounds)
        let den = simd_dot(d, f.n)
        guard abs(den) > 1e-4 else { return nil }
        let hit = o + d * (simd_dot(f.c - o, f.n) / den)
        return SIMD2(simd_dot(hit - f.c, f.u), simd_dot(hit - f.c, f.v))
    }

    /// The plane after Move (along the base normal), Tilt (how far it leans, from the base normal toward the Rotate direction)
    /// and Rotate (which way it leans, about the base normal): its centre, normal and in-plane axes.
    static func frame(_ c: FlexiblePlanCut, bounds: MeshBounds) -> (c: SIMD3<Float>, n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
        let b = base(c)
        let t = Float(c.tiltDeg * .pi / 180), r = Float(c.rotateDeg * .pi / 180)
        let d = b.u * cos(r) + b.v * sin(r)
        let n = simd_normalize(b.n * cos(t) + d * sin(t))
        var u = b.u - n * simd_dot(b.u, n)
        if simd_length(u) < 1e-4 { u = b.v - n * simd_dot(b.v, n) }
        u = simd_normalize(u)
        let v = simd_cross(n, u)
        var origin = (bounds.min + bounds.max) * 0.5
        if c.base == .face, let fp = c.facePoint, fp.count == 3 { origin = SIMD3(Float(fp[0]), Float(fp[1]), Float(fp[2])) }
        return (origin + b.n * Float(c.offsetMM), n, u, v)
    }

    /// The slab drawn for the plane: as wide as the part's largest extent, 0.4 mm thick, in the cut colour.
    static func item(_ c: FlexiblePlanCut, bounds: MeshBounds) -> ClearanceRenderItem {
        let f = frame(c, bounds: bounds)
        let half = simd_reduce_max(bounds.max - bounds.min) * 0.6
        return ClearanceRenderItem(volume: ClearanceVolume(faceID: -1, kind: .face,
                                                           shape: .slab(center: f.c - f.n * 0.2, normal: f.n, uAxis: f.u, vAxis: f.v,
                                                                        halfU: half, halfV: half, depthMM: 0.4)),
                                   selected: true, tint: SIMD3(0.39, 0.82, 1), faceAlpha: 0.22, edgeAlpha: 0.95)
    }

    /// Where the camera looks FROM (world space, unit) to see the plane: straight at it to draw, edge-on to place it.
    /// `settle` turns model space into the world the part is drawn in; `azimuth` is his current view's (an edge-on view keeps
    /// his side of the part when it can).
    static func eyeDirection(_ c: FlexiblePlanCut, drawn: Bool, settle: simd_quatf, azimuth: Float) -> SIMD3<Float> {
        let n = simd_normalize(settle.act(base(c).n))
        if drawn { return n.y < -0.2 ? -n : n }   // from the side above the plane where it can
        let up = SIMD3<Float>(0, 1, 0)
        var side = simd_cross(up, n)
        if simd_length(side) < 1e-3 { side = SIMD3(sin(azimuth), 0, cos(azimuth)) }   // a level plane: level view, his side
        side = simd_normalize(side)
        if simd_dot(side, SIMD3(sin(azimuth), 0, cos(azimuth))) < 0 { side = -side }
        return simd_normalize(side + up * 0.1)   // a touch above, so the part's depth reads
    }

    /// The (azimuth, elevation) whose `OrbitCamera.direction` is `d`.
    static func orientation(_ d: SIMD3<Float>) -> (azimuth: Float, elevation: Float) {
        (atan2(d.x, d.z), asin(max(-1, min(1, d.y))))
    }
}

// MARK: - the edits

extension FlexibleMainStage {
    /// + Cut ⌄ › a way: its plane card (plane first) or its bar.
    func startCut(_ way: FlexibleCutWay) {
        planNote = nil
        planCut = FlexiblePlanCutDraft(way: way)
    }

    /// ✓ — the cut is kept in the plan; its pieces come with the engine's cut (one plain line says so). A drawing is kept as
    /// its stroke on the plane (u, v mm), read through the view it was drawn in.
    func commitCut(project: ProjectModel? = nil) {
        guard var d = planCut, d.step == .place, d.cut.way.planeFirst else { return }
        if d.cut.way.drawn {
            guard d.strokeReady, let view = viewFrame, let b = (project ?? model?.project)?.viewerMesh?.bounds else { return }
            let uv = d.stroke.compactMap { FlexiblePlaneFrame.onPlane($0, view: view, cut: d.cut, bounds: b) }
            guard uv.count >= 2 else { planCut?.faceMiss = false; planNote = FlexiblePlanCutCopy.noView; return }
            d.cut.curveUV = uv.map { [Double($0.x), Double($0.y)] }
            d.cut.curveTool = d.tool?.rawValue
        }
        let cut = d.cut
        editPlans { p in p.plan.cuts = (p.plan.cuts ?? []) + [cut]; p.plan.built = false }
        planCut = nil
        planNote = FlexiblePlanCutCopy.kept(cut.way)
    }

    /// ★ slice 4: A face — a tap on the part while the bar waits for one: a flat face lays the plane on it (the bar follows);
    /// another face says so and keeps waiting. Consumed: nothing else on the page sees the tap.
    func planFaceTap(face: FaceID, mesh: ViewerMesh) {
        guard var d = planCut, d.step == .face else { return }
        guard let fp = FlexiblePlaneFrame.facePlane(Int32(face), mesh: mesh) else { d.faceMiss = true; planCut = d; return }
        d.cut.base = .face
        d.cut.facePoint = [Double(fp.point.x), Double(fp.point.y), Double(fp.point.z)]
        d.cut.faceNormal = [Double(fp.normal.x), Double(fp.normal.y), Double(fp.normal.z)]
        d.faceMiss = false
        d.step = .place
        planCut = d
    }

    /// ★ slice 4: the stroke as he draws — ✎ adds a sample (≥ 3 pt from the last; a fresh drag starts a fresh line), 〰 adds a
    /// point, or removes the one tapped again (within 22 pt).
    func drawOnPlane(_ pt: CGPoint, began: Bool, tap: Bool) {
        guard var d = planCut, d.step == .place, d.cut.way.drawn, let tool = d.tool else { return }
        switch tool {
        case .pencil:
            if began { d.stroke = [pt] }
            else if let last = d.stroke.last, hypot(pt.x - last.x, pt.y - last.y) >= 3 { d.stroke.append(pt) }
        case .spline:
            guard tap else { return }
            if let i = d.stroke.firstIndex(where: { hypot($0.x - pt.x, $0.y - pt.y) <= 22 }) { d.stroke.remove(at: i) }
            else { d.stroke.append(pt) }
        }
        planCut = d
    }

    /// Join on a cut's row: the cut goes (one undo step).
    func joinCut(_ i: Int) {
        editPlans { p in
            guard var cuts = p.plan.cuts, cuts.indices.contains(i) else { return }
            cuts.remove(at: i)
            p.plan.cuts = cuts.isEmpty ? nil : cuts
            p.plan.built = false
        }
        planNote = nil
    }

    /// The plane being placed, drawn on the part (only on the Print plan, while its bar is up).
    func planeItems(_ project: ProjectModel) -> [ClearanceRenderItem] {
        guard page == .plan, let d = planCut, d.step == .place, d.cut.way.planeFirst, let b = project.viewerMesh?.bounds, !b.isEmpty
        else { return [] }
        return [FlexiblePlaneFrame.item(d.cut, bounds: b)]
    }
}

// MARK: - the views

/// The plane card and the cut bar, at the top of the free model area; the camera turns with them (U19).
struct FlexiblePlanCutLayer: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    let camera: OrbitCameraModel?
    /// His own view before the camera turned (✓ and ✕ bring it back).
    @State private var saved: OrbitCamera?

    static let barHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geo in
            if main.page == .plan, let d = main.planCut {
                let left = PageChrome.edge + PageChrome.widePanelWidth + PageChrome.gap
                let right = geo.size.width - PageChrome.gizmoClearance
                ZStack {
                    // ★ slice 4: the drawing area — the free model area, under the bar (taps elsewhere stay the page's)
                    if d.step == .place, d.cut.way.drawn {
                        canvas(d, rect: CGRect(x: left, y: PageChrome.panelTop + 2 * Self.barHeight + PageChrome.gap,
                                               width: max(0, right - left),
                                               height: max(0, geo.size.height - PageChrome.panelTop - 2 * Self.barHeight - 160)))
                    }
                    Group {
                        if d.step == .pick { card(d) } else { bar(d) }
                    }
                    .frame(maxWidth: max(320, right - left))
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: (left + right) / 2, y: PageChrome.panelTop + Self.barHeight / 2 + (d.step == .pick ? 40 : 0))
                }
            }
        }
        .onChange(of: main.planCut?.turnKey) { _ in turn(main.planCut) }
        .onDisappear { restore() }
    }

    /// ★ slice 4: where he draws on the plane — ✎ a drag draws freehand, 〰 a tap adds a point (a tap on one removes it); the
    /// stroke drawn in the cut colour, the spline's points as dots.
    private func canvas(_ d: FlexiblePlanCutDraft, rect: CGRect) -> some View {
        let pts = d.stroke
        return ZStack(alignment: .topLeading) {
            // a plain Button under the drag (NumberField's pattern): it takes the touch where a bare shape would not on the Mac
            Button {} label: { Rectangle().fill(Color.white.opacity(0.001)).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        guard d.tool == .pencil else { return }
                        main.drawOnPlane(g.location, began: g.translation == .zero, tap: false)
                    }
                    .onEnded { g in
                        guard d.tool == .spline, hypot(g.translation.width, g.translation.height) < 8 else { return }
                        main.drawOnPlane(g.location, began: false, tap: true)
                    })
                .allowsHitTesting(d.tool != nil)
                .accessibilityHidden(true)
            Path { p in
                guard let f = pts.first else { return }
                p.move(to: f)
                if d.tool == .spline, pts.count > 2 {
                    // Catmull-Rom through the points (the spline he taps out)
                    for i in 0..<(pts.count - 1) {
                        let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
                        p.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                   control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
                    }
                } else {
                    for q in pts.dropFirst() { p.addLine(to: q) }
                }
            }
            .offset(x: -rect.minX, y: -rect.minY)
            .stroke(DS.Color.accentCyan.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
            if d.tool == .spline {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, q in
                    Circle().fill(DS.Color.accentCyan.color).frame(width: 12, height: 12)
                        .position(x: q.x - rect.minX, y: q.y - rect.minY).allowsHitTesting(false)
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .background(publish("planCutCanvas"))   // (before `position`: after it, the frame is the whole page)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: the plane card — "A plane · start from which plane?"

    private func card(_ d: FlexiblePlanCutDraft) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("\(d.cut.way.title) \u{00B7} \(FlexiblePlanCutCopy.ask)").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.textPrimary.color)
                Spacer(minLength: DS.Space.s)
                x("planCutCancel") { main.planCut = nil }
            }
            HStack(spacing: DS.Space.s) {
                ForEach(FlexiblePlaneBase.allCases, id: \.self) { b in
                    let off = false
                    Button {
                        var n = d
                        if b == .face { n.step = .face } else { n.cut.base = b; n.step = .place }
                        main.planCut = n
                    } label: {
                        VStack(spacing: 3) {
                            Text(b.title).font(.system(size: 14, weight: .semibold))
                            Text(b.sub).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(DS.Color.textTertiary.color)
                        }
                        .foregroundStyle(DS.Color.textPrimary.opacity(off ? 0.4 : 1).color)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DS.Color.fillSubtle.color))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(publish("planPlane-\(b.rawValue)"))
                    .accessibilityIdentifier("flexible-plan-plane-\(b.rawValue)")
                }
            }
        }
        .padding(DS.Space.ml)
        .background(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).fill(DS.Surface.panel.color)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.panelSmall).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.panel)
        .background(publish("planCutCard"))
    }

    // MARK: the bar — ✕ · plane ⌄ · Move · Tilt ↺ ↻ · Rotate ↺ ↻ · (Key) · ✓

    /// One row where it fits; narrower (13" landscape beside the 440 pt panel), Tilt and Rotate go to a second row — the bar
    /// wraps between its groups, never inside one (the mockup's rule).
    private func bar(_ d: FlexiblePlanCutDraft) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s) { lead(d); if placing(d) { angles(d) }; Spacer(minLength: 0); ok(d) }
                .padding(.horizontal, DS.Space.s).frame(minHeight: Self.barHeight)
                .background(Capsule().fill(DS.Surface.bar.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.s) { lead(d); Spacer(minLength: 0); ok(d) }.frame(minHeight: Self.barHeight)
                if placing(d) { HStack(spacing: DS.Space.s) { angles(d); Spacer(minLength: 0) }.frame(minHeight: Self.barHeight) }
            }
            .padding(.horizontal, DS.Space.s)
            .background(RoundedRectangle(cornerRadius: 22).fill(DS.Surface.bar.color)
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        }
        .dsShadow(DS.Shadow.panel)
        .background(publish("planCutBar"))
    }

    /// A plane being placed (not drawn on): it has Move, Tilt and Rotate.
    private func placing(_ d: FlexiblePlanCutDraft) -> Bool { d.step == .place && d.cut.way.planeFirst && !d.cut.way.drawn }

    /// ✕ · the plane chip ⌄ · Move (Key) — or the drawing tools, or a way's plain line.
    @ViewBuilder private func lead(_ d: FlexiblePlanCutDraft) -> some View {
        x("planCutCancel") { main.planCut = nil }
        if d.step == .face {
            // ★ slice 4: A face — the bar waits for his tap on a flat face
            Text("\(d.cut.way.title) \u{00B7} \(d.faceMiss ? FlexiblePlanCutCopy.notFlat : FlexiblePlanCutCopy.tapFace)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle((d.faceMiss ? DS.Color.warning : DS.Color.textPrimary).color)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .background(publish("planCutFaceLine"))
        } else if d.cut.way.planeFirst {
            Menu {
                ForEach(FlexiblePlaneBase.allCases, id: \.self) { b in
                    Button(b.chip) {
                        var n = d
                        if b == .face { n.step = .face } else { n.cut.base = b; n.cut.facePoint = nil; n.cut.faceNormal = nil }
                        n.stroke = []
                        main.planCut = n
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(d.cut.base.chip).font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(DS.Color.accent.color).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .menuIndicator(.hidden).menuStyle(.button).buttonStyle(.plain).fixedSize()
            .background(publish("planCutPlane"))
            .accessibilityIdentifier("flexible-plan-cut-plane")
            divider
            if d.cut.way.drawn {
                tool("pencil.tip", FlexiblePlanCutCopy.pencil, key: "planCutPencil", tool: .pencil, d)
                tool("scribble.variable", FlexiblePlanCutCopy.spline, key: "planCutSpline", tool: .spline, d)
                Text(d.tool == nil ? FlexiblePlanCutCopy.pickTool : d.tool == .pencil ? FlexiblePlanCutCopy.drawPencil : FlexiblePlanCutCopy.drawSpline)
                    .font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 2) {
                    label(FlexiblePlanCutCopy.move)
                    field("planCutMove", FlexiblePlanCutCopy.move, d.cut.offsetMM, unit: "mm", step: 1, range: -200...200) { v in
                        var n = d; n.cut.offsetMM = v; main.planCut = n
                    }
                }
                if d.cut.way == .keyed {
                    divider
                    HStack(spacing: 2) {
                        label(FlexiblePlanCutCopy.key)
                        field("planCutKey", FlexiblePlanCutCopy.key, d.cut.keyMM, unit: "mm", step: 0.5, range: 1...20) { v in
                            var n = d; n.cut.keyMM = v; main.planCut = n
                        }
                    }
                }
            }
        } else {
            Text("\(d.cut.way.title) \u{00B7} \(FlexiblePlanCutCopy.pickOnPart(d.cut.way))").font(.system(size: 12.5))
                .foregroundStyle(DS.Color.textSecondary.color).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tilt ↺ n° ↻ · Rotate ↺ n° ↻ (U18: one group of two, never apart).
    @ViewBuilder private func angles(_ d: FlexiblePlanCutDraft) -> some View {
        stepper(FlexiblePlanCutCopy.tilt, key: "planCutTilt", value: d.cut.tiltDeg, range: -75...75) { v in
            var n = d; n.cut.tiltDeg = v; main.planCut = n
        }
        divider
        stepper(FlexiblePlanCutCopy.rotate, key: "planCutRotate", value: d.cut.rotateDeg, range: -180...180) { v in
            var n = d; n.cut.rotateDeg = v; main.planCut = n
        }
    }

    private func ok(_ d: FlexiblePlanCutDraft) -> some View {
        let canCut = placing(d) || (d.step == .place && d.cut.way.drawn && d.strokeReady)
        return Button { main.commitCut(project: project) } label: {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.opacity(canCut ? 1 : 0.35).color)
                .frame(width: 44, height: 44)
                .background(Circle().fill((canCut ? DS.Color.accent : DS.Color.fillSubtle).color))
        }
        .buttonStyle(.plain).disabled(!canCut)
        .background(publish("planCutOK"))
        .accessibilityLabel("Cut")
        .accessibilityIdentifier("flexible-plan-cut-ok")
    }

    // MARK: parts

    private var divider: some View { Rectangle().fill(DS.Color.strokeStrong.color).frame(width: 1, height: 22) }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color).fixedSize()
    }

    private func field(_ key: String, _ title: String, _ value: Double, unit: String, step: Double, range: ClosedRange<Double>,
                       commit: @escaping (Double) -> Void) -> some View {
        NumberField(key: key, title: title, spec: FlexNumberSpec(value: value, unit: unit, step: step, range: range, decimals: step < 1 ? 1 : 0),
                    size: .bare, allowsNegative: range.lowerBound < 0, onCommit: commit)
    }

    /// Tilt or Rotate: ↺ 15° · its number · ↻ 15° (U18: a Tilt always has its Rotate beside it).
    private func stepper(_ t: String, key: String, value: Double, range: ClosedRange<Double>,
                         set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            label(t)
            round("arrow.counterclockwise", "\(t) \u{2212}15\u{00B0}", key: "\(key)Minus") { set(max(range.lowerBound, value - 15)) }
            field(key, t, value, unit: "\u{00B0}", step: 1, range: range, commit: set)
            round("arrow.clockwise", "\(t) +15\u{00B0}", key: "\(key)Plus") { set(min(range.upperBound, value + 15)) }
        }
    }

    private func round(_ icon: String, _ label: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(publish(key)).accessibilityLabel(label)
    }

    /// ✎ or 〰: lit while it draws; picking the other starts a fresh stroke.
    private func tool(_ icon: String, _ label: String, key: String, tool t: FlexiblePlanCutDraft.Tool, _ d: FlexiblePlanCutDraft) -> some View {
        let on = d.tool == t
        return Button {
            var n = d; if n.tool != t { n.stroke = [] }; n.tool = t; main.planCut = n
        } label: {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(on ? DS.Color.accent.color : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).background(publish(key)).accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func x(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 44, height: 44).background(Circle().fill(DS.Color.fillSubtle.color)).contentShape(Circle())
        }
        .buttonStyle(.plain).background(publish(key)).accessibilityLabel("Cancel the cut")
        .accessibilityIdentifier("flexible-plan-cut-cancel")
    }

    private func publish(_ key: String) -> some View {
        GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: [key: g.frame(in: .global)]) }
            .allowsHitTesting(false)
    }

    // MARK: the camera (U19): to the plane while it is placed or drawn, back to his own view after ✓ or ✕

    /// Test seam: the last view the layer asked for (nil: his own restored).
    @MainActor static var lastTurn: (azimuth: Float, elevation: Float)?

    private func turn(_ d: FlexiblePlanCutDraft?) {
        guard let camera else { return }
        guard let d, d.step == .place, d.cut.way.planeFirst else { restore(); return }
        if saved == nil { saved = camera.camera }
        let settle = project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let dir = FlexiblePlaneFrame.eyeDirection(d.cut, drawn: d.cut.way.drawn, settle: settle, azimuth: (saved ?? camera.camera).azimuth)
        let o = FlexiblePlaneFrame.orientation(dir)
        var c = camera.camera
        c.setOrientation(azimuth: o.azimuth, elevation: o.elevation)
        camera.adopt(c)
        Self.lastTurn = o
    }

    private func restore() {
        guard let camera, let s = saved else { return }
        camera.adopt(s)
        saved = nil
        Self.lastTurn = nil
    }
}
