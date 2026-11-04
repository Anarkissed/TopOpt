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
    public enum Step: Equatable, Sendable { case pick, place }
    public var cut: FlexiblePlanCut
    public var step: Step
    public init(way: FlexibleCutWay) {
        cut = FlexiblePlanCut(way: way)
        step = way.planeFirst ? .pick : .place
    }
}

enum FlexiblePlanCutCopy {
    static let ask = "start from which plane?"
    static let move = "Move"
    static let tilt = "Tilt"
    static let rotate = "Rotate"
    static let key = "Key"
    static let pencil = "Pencil: draw freehand"
    static let spline = "Spline: tap points"
    static let faceNext = "next update"
    static let drawNext = "Drawing on the plane comes with the next update."
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
    /// The base's frame: its normal and two in-plane axes (model space; Top is the build plate's plane, +Z up).
    static func base(_ b: FlexiblePlaneBase) -> (n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
        switch b {
        case .top, .face: return (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .front: return (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1))
        case .side: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        }
    }

    /// The plane after Move (along the base normal), Tilt (how far it leans, from the base normal toward the Rotate direction)
    /// and Rotate (which way it leans, about the base normal): its centre, normal and in-plane axes.
    static func frame(_ c: FlexiblePlanCut, bounds: MeshBounds) -> (c: SIMD3<Float>, n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>) {
        let b = base(c.base)
        let t = Float(c.tiltDeg * .pi / 180), r = Float(c.rotateDeg * .pi / 180)
        let d = b.u * cos(r) + b.v * sin(r)
        let n = simd_normalize(b.n * cos(t) + d * sin(t))
        var u = b.u - n * simd_dot(b.u, n)
        if simd_length(u) < 1e-4 { u = b.v - n * simd_dot(b.v, n) }
        u = simd_normalize(u)
        let v = simd_cross(n, u)
        let centre = (bounds.min + bounds.max) * 0.5 + b.n * Float(c.offsetMM)
        return (centre, n, u, v)
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
        let n = simd_normalize(settle.act(base(c.base).n))
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

    /// ✓ — the cut is kept in the plan; its pieces come with the engine's cut (one plain line says so).
    func commitCut() {
        guard let d = planCut, d.step == .place, !d.cut.way.drawn else { return }
        editPlans { p in p.plan.cuts = (p.plan.cuts ?? []) + [d.cut]; p.plan.built = false }
        planCut = nil
        planNote = FlexiblePlanCutCopy.kept(d.cut.way)
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
                Group {
                    if d.step == .pick { card(d) } else { bar(d) }
                }
                .frame(maxWidth: max(320, right - left))
                .fixedSize(horizontal: false, vertical: true)
                .position(x: (left + right) / 2, y: PageChrome.panelTop + Self.barHeight / 2 + (d.step == .pick ? 40 : 0))
            }
        }
        .onChange(of: main.planCut) { d in turn(d) }
        .onDisappear { restore() }
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
                    let off = b == .face
                    Button {
                        guard !off else { return }
                        var n = d; n.cut.base = b; n.step = .place
                        main.planCut = n
                    } label: {
                        VStack(spacing: 3) {
                            Text(b.title).font(.system(size: 14, weight: .semibold))
                            Text(off ? FlexiblePlanCutCopy.faceNext : b.sub).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
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
    private func placing(_ d: FlexiblePlanCutDraft) -> Bool { d.cut.way.planeFirst && !d.cut.way.drawn }

    /// ✕ · the plane chip ⌄ · Move (Key) — or the drawing tools, or a way's plain line.
    @ViewBuilder private func lead(_ d: FlexiblePlanCutDraft) -> some View {
        x("planCutCancel") { main.planCut = nil }
        if d.cut.way.planeFirst {
            Menu {
                ForEach(FlexiblePlaneBase.allCases.filter { $0 != .face }, id: \.self) { b in
                    Button(b.chip) { var n = d; n.cut.base = b; main.planCut = n }
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
                tool("pencil.tip", FlexiblePlanCutCopy.pencil, key: "planCutPencil")
                tool("scribble.variable", FlexiblePlanCutCopy.spline, key: "planCutSpline")
                Text(FlexiblePlanCutCopy.drawNext).font(.system(size: 12)).foregroundStyle(DS.Color.textSecondary.color)
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
        let canCut = placing(d)
        return Button { main.commitCut() } label: {
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

    private func tool(_ icon: String, _ label: String, key: String) -> some View {
        Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.opacity(0.4).color)
            .frame(width: 44, height: 44).background(publish(key)).accessibilityLabel(label)
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
