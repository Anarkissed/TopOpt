// FlexiblePressCurveModal — an edge's or corner's curves edited in a WINDOW OVER EVERYTHING (task 2026-09-29-flexible-screens,
// round 7 step U2). His notes of 2026-10-20, item 5 (img_1020_9): "Get rid of the down and 45 degree buttons. There should only be
// 2D or 3D view. In 2D view, it shows a modal over everything that shows the two curves in two different tables, one on top of the
// other. In 3D view, it shows both curves in the modal on the same table in 3D, intersecting as they do in the model, but without
// the model. No need to angle it as it is in the main squish model. Keep the position gizmo so that the front shows one view
// head-on, and the top shows the other view head-on. Then press OK to close the modal or cancel to revert to what it was
// beforehand." FRONT-END only (his order: send to core comes after U2; FlexibleBackend.sendsPresses stays off).
//
// ★ A DRAFT, NOT THE PRESS: opening copies the press's stored multipliers (FlexiblePressCurveBaselines — ones = the flat prism);
// every drag in the window changes the draft only. [OK] writes every changed curve in ONE edit and seals it as ONE undo step;
// [Cancel] drops the draft, so the press is exactly what it was before the window opened (nothing was written).
// ★ 2D: one table per curve, stacked (an edge: across, then along; a corner: its one curve). The table's bottom line is the flat
// face (the deepest squish), the dashed top line the part's surface (no squish), as the curves read on the part.
// ★ 3D: both curves on ONE table, crossing at their middles as on the part, the flat face as the table (the plane x = 0). Both
// rise along +X — the one direction square to the gizmo's Front AND Top — so [Front] shows the across curve head-on and [Top] the
// along curve (a corner: its curve on two of its sides, one head-on from each). Each span is drawn the same length (the true
// 13 mm across beside a 100 mm along was too small to drag); the heights are the same scale for both.

import SwiftUI
import simd
import TopOptDesign
import TopOptKit

/// ★ U2: the open window's draft (FlexibleStageModel.curveDraft).
public struct FlexiblePressCurveDraft: Equatable {
    public enum Mode: String, CaseIterable, Hashable, Sendable { case flat2D = "2d", table3D = "3d" }
    /// The press (nil: a face's curves — `face`).
    public let press: UUID?
    /// ★ X20b (his answer of 2026-10-20 ~19:10: "FACE presses use the SAME 2D/3D curve window"): the face whose curves are open
    /// (its X curve under `.along`, its Y curve under `.across` — the press's own storage keys: curveX / curveY).
    public var face: Int? = nil
    public var mode: Mode
    /// The press's curves when the window opened ([Cancel] returns to these — nothing was written).
    public let before: [FlexiblePressCurveBaselines.Axis: FlexCurve]
    public var curves: [FlexiblePressCurveBaselines.Axis: FlexCurve]
}

public enum FlexiblePressCurveModal {
    typealias Axis = FlexiblePressCurveBaselines.Axis

    /// ★ RED CONTROL only: every drag in the window writes the press at once (R7-E4's editing on the part) — [Cancel] keeps it.
    nonisolated(unsafe) static var controlLiveEdits = false
    /// ★ RED CONTROL only: 2D draws both curves on one table.
    nonisolated(unsafe) static var controlOneTable = false
    /// ★ RED CONTROL only: 3D keeps the model's own angle (the curves as they lie on the part).
    nonisolated(unsafe) static var controlModelAngle = false
    /// ★ RED CONTROL only: the Shape row's [↓] / [45°] (R7-E4) instead of [2D] / [3D].
    nonisolated(unsafe) static var controlOldViewButtons = false

    // MARK: 2D

    struct Table: Identifiable, Equatable {
        let id: String
        let axes: [Axis]
        let title: String
        /// The words under the table's two ends (t = 0, t = 1).
        let ends: (String, String)
        static func == (a: Table, b: Table) -> Bool { a.id == b.id && a.axes == b.axes && a.title == b.title }
    }

    /// ★ X20b: a face's 2D tables, top to bottom: its X curve, then its Y curve (each its own table).
    static func faceTables2D() -> [Table] {
        if controlOneTable { return [Table(id: "both", axes: [.along, .across], title: "X and Y", ends: ("", ""))] }
        return [Table(id: "x", axes: [.along], title: FlexibleRowCopy.faceCurveX, ends: ("Corner", "X end")),
                Table(id: "y", axes: [.across], title: FlexibleRowCopy.faceCurveY, ends: ("Corner", "Y end"))]
    }

    /// ★ The 2D tables, top to bottom: an edge's across then along (each its own table); a corner's one curve.
    static func tables2D(_ st: FlexibleStrip, names: [String]) -> [Table] {
        if st.kind == .corner {
            return [Table(id: "corner", axes: [.corner], title: FlexibleRowCopy.cornerOneCurve, ends: ("Rim", "Corner tip"))]
        }
        let a = names.first ?? "first face", b = names.count > 1 ? names[1] : "second face"
        let across = FlexibleRowCopy.fit("Across the edge \u{00B7} \(a) \u{2192} \(b)")
        if controlOneTable { return [Table(id: "both", axes: [.across, .along], title: "Across and along", ends: ("", ""))] }
        return [Table(id: "across", axes: [.across], title: across, ends: (a, b)),
                Table(id: "along", axes: [.along], title: "Along the edge", ends: ("One end", "Other end"))]
    }

    /// A table's flat drawing: t across the table, the curve's height up (the flat face at the bottom, the surface on top).
    static let flatMargin = CGSize(width: 40, height: 22)
    static func flatProjection(size: CGSize) -> CameraProjection {
        let W = Float(Swift.max(size.width, 1)), H = Float(Swift.max(size.height, 1))
        let mx = Float(flatMargin.width), my = Float(flatMargin.height)
        let sx = 2 * (W - 2 * mx) / W, tx = 2 * mx / W - 1, sy = 2 * (H - 2 * my) / H, ty = 2 * my / H - 1
        let m = simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(tx, ty, 0, 1)))
        return CameraProjection(viewProjection: m, viewportSize: size)
    }
    static let flatBaseline = FlexibleCurveBaseline(points: (0...32).map { SIMD3(Double($0) / 32, 0, 0) },
                                                    up: SIMD3(0, 1, 0), amplitudeMM: 1)

    // MARK: 3D

    struct Curve3D: Identifiable, Equatable {
        let id: String
        let axis: Axis
        let baseline: FlexibleCurveBaseline
    }
    /// Each span's drawn length and the curves' common height on the 3D table.
    static let span = 1.0, rise = 0.45

    /// ★ The 3D table's curves (table space): the flat face is the plane x = 0, every curve rises along +X. An edge: ACROSS runs
    /// down Y (head-on from Front), ALONG runs along Z (head-on from Top), crossing at their middles. A corner: its one curve on two
    /// sides meeting at the corner tip (the origin) — one down Y, one along Z.
    /// ★ X20b: a face's 3D table — its Y curve down Y (head-on from Front), its X curve along Z (head-on from Top), crossing at
    /// their middles, as an edge's.
    static func faceCurves3D() -> [Curve3D] {
        let up = SIMD3<Double>(1, 0, 0), h = span / 2
        func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> FlexibleCurveBaseline {
            FlexibleCurveBaseline(points: (0...32).map { simd_mix(a, b, SIMD3(repeating: Double($0) / 32)) }, up: up, amplitudeMM: rise)
        }
        return [Curve3D(id: "y", axis: .across, baseline: line(SIMD3(0, h, 0), SIMD3(0, -h, 0))),
                Curve3D(id: "x", axis: .along, baseline: line(SIMD3(0, 0, -h), SIMD3(0, 0, h)))]
    }

    static func curves3D(_ st: FlexibleStrip, cut: FlexibleFlatPrism.Cut?) -> [Curve3D] {
        let up = SIMD3<Double>(1, 0, 0)
        func line(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> FlexibleCurveBaseline {
            FlexibleCurveBaseline(points: (0...32).map { simd_mix(a, b, SIMD3(repeating: Double($0) / 32)) }, up: up, amplitudeMM: rise)
        }
        if controlModelAngle, let c = cut { return modelAngle(st, c) }   // (RED CONTROL: the part's own angle)
        let h = span / 2
        if st.kind == .corner {
            return [Curve3D(id: "corner-a", axis: .corner, baseline: line(SIMD3(0, span, 0), .zero)),
                    Curve3D(id: "corner-b", axis: .corner, baseline: line(SIMD3(0, 0, -span), .zero))]
        }
        return [Curve3D(id: "across", axis: .across, baseline: line(SIMD3(0, h, 0), SIMD3(0, -h, 0))),
                Curve3D(id: "along", axis: .along, baseline: line(SIMD3(0, 0, -h), SIMD3(0, 0, h)))]
    }

    /// (RED CONTROL) the curves as they lie on the part, moved to the origin and scaled to the table.
    private static func modelAngle(_ st: FlexibleStrip, _ c: FlexibleFlatPrism.Cut) -> [Curve3D] {
        let bs: [(String, Axis, FlexibleCurveBaseline)] = st.kind == .corner
            ? st.members.indices.prefix(2).compactMap { k in FlexiblePressCurveBaselines.cornerSide(st, member: k, c).map { ("corner-\(k)", .corner, $0) } }
            : [("across", .across, FlexiblePressCurveBaselines.across(st, c)), ("along", .along, FlexiblePressCurveBaselines.along(st, c))]
                .compactMap { i, a, b in b.map { (i, a, $0) } }
        let pts = bs.flatMap { $0.2.points }
        guard let first = pts.first else { return [] }
        let lo = pts.reduce(first) { simd_min($0, $1) }, hi = pts.reduce(first) { simd_max($0, $1) }
        let mid = (lo + hi) / 2, k = span / Swift.max(simd_length(hi - lo), 1e-9)
        return bs.map { i, a, b in
            Curve3D(id: i, axis: a, baseline: FlexibleCurveBaseline(points: b.points.map { ($0 - mid) * k }, up: b.up, amplitudeMM: rise))
        }
    }

    /// The 3D table's camera on opening (and Home): the default three-quarter view, on the table's middle.
    static func homeCamera(corner: Bool) -> OrbitCamera {
        let centre: SIMD3<Float> = corner ? SIMD3(Float(rise) / 2, Float(span) / 2, -Float(span) / 2) : SIMD3(Float(rise) / 2, 0, 0)
        // found by looking (U2_03/04): at the stage's 45° lens the edge-on curve spread 19 pt across the head-on one's middle and
        // the table read as a wedge — a long lens (17°), nearly flat, keeps Front / Top true head-on views
        return OrbitCamera(target: centre, distance: 6.4, fovY: 0.3, minDistance: 3, maxDistance: 20)
    }

    /// ★ Whether a curve is edited in this view: not when it is seen edge-on (its span under 40 pt) — found by looking: in
    /// [Front] the along curve's handles sat on the across curve's middle point and took its touches. It is drawn faint instead.
    static func editable(_ c: Curve3D, _ pr: CameraProjection) -> Bool {
        guard let a = pr.project(SIMD3<Float>(c.baseline.at(0))), let b = pr.project(SIMD3<Float>(c.baseline.at(1))) else { return false }
        return hypot(a.x - b.x, a.y - b.y) >= 40
    }

    /// Each curve's colour (an edge's along curve in cyan, so the two read apart on the 3D table and match the 2D tables).
    static func tint(_ a: Axis) -> Color { a == .along ? DS.Color.accentCyan.color : FlexibleStageStyle.onPart }

    // MARK: copy (one line each, ≤ 44)

    static func title(_ strip: String) -> String { FlexibleRowCopy.fit(strip + " \u{00B7} curves") }
    static func legend(_ a: Axis, face: Bool = false) -> String {
        if face { return a == .along ? "X \u{00B7} head-on from Top" : "Y \u{00B7} head-on from Front" }
        switch a {
        case .across: return "Across \u{00B7} head-on from Front"
        case .along: return "Along \u{00B7} head-on from Top"
        case .corner: return "Corner curve \u{00B7} Front and Top"
        }
    }
    static let hint = "Drag a point \u{00B7} tap the line to add one"
    static let cancel = "Cancel", ok = "OK"
}

// MARK: - the model

extension FlexibleStageModel {
    /// ★ X20b (his answer of 2026-10-20 ~19:10: "FACE presses use the SAME 2D/3D curve window"): a face's [2D] / [3D] — the window
    /// opens on a draft of its X and Y curves.
    public func openFaceCurveModal(_ r: Int, _ mode: FlexiblePressCurveDraft.Mode) {
        guard let f = settings.face(r), !f.isStampShape else { return }
        let now: [FlexiblePressCurveBaselines.Axis: FlexCurve] = [.along: f.curveX, .across: f.curveY]
        curvePoint = nil
        curveDraft = FlexiblePressCurveDraft(press: nil, face: r, mode: mode, before: now, curves: now)
    }

    /// ★ U2: [2D] / [3D] — the window opens on a draft of the press's curves.
    public func openCurveModal(_ id: UUID, _ mode: FlexiblePressCurveDraft.Mode) {
        guard let p = settings.press(id), let st = p.strip, !p.settings.isStampShape else { return }
        var now: [FlexiblePressCurveBaselines.Axis: FlexCurve] = [:]
        for a in FlexiblePressCurveBaselines.axes(st) { now[a] = FlexiblePressCurveBaselines.multipliers(p, a) }
        curvePoint = nil
        curveDraft = FlexiblePressCurveDraft(press: id, mode: mode, before: now, curves: now)
    }

    /// ★ U2: [2D | 3D] inside the window (the draft is kept).
    public func setCurveModalMode(_ mode: FlexiblePressCurveDraft.Mode) { curveDraft?.mode = mode }

    /// ★ U2: one curve of the draft (clamped: never past the flat face). Nothing reaches the press until [OK].
    public func setDraftCurve(_ axis: FlexiblePressCurveBaselines.Axis, _ c: FlexCurve) {
        guard var d = curveDraft else { return }
        let m = FlexiblePressCurveBaselines.clamped(c)
        d.curves[axis] = m
        curveDraft = d
        if FlexiblePressCurveModal.controlLiveEdits {   // (RED CONTROL: written at once)
            if let id = d.press { setPressCurve(id, axis, m) } else if let r = d.face { setFaceCurve(r, axis, m) }
            save()
        }
    }

    /// ★ U2: [OK] (`keep`) writes every changed curve in ONE edit, sealed as ONE undo step; [Cancel] writes nothing.
    public func closeCurveModal(keep: Bool) {
        guard let d = curveDraft else { return }
        curveDraft = nil
        guard keep, d.curves != d.before else { return }
        project.sealUndoStep()   // what came before the window is its own step
        if let r = d.face {   // ★ X20b: a face's X and Y curves, one edit
            edit({ s in
                guard var f = s.face(r) else { return }
                if let c = d.curves[.along], c != d.before[.along] { f.curveX = c }
                if let c = d.curves[.across], c != d.before[.across] { f.curveY = c }
                s.setFace(f)
            }, recompute: false)
            curveChanged(region: r)
            save()
            return
        }
        guard let id = d.press else { return }
        edit({ s in
            guard var q = s.press(id), q.strip != nil else { return }
            for a in FlexiblePressCurveBaselines.Axis.allCases { if let c = d.curves[a], c != d.before[a] { FlexiblePressCurveBaselines.set(&q, a, c) } }
            s.setPress(q)
        }, recompute: false)
        save()
    }

    /// ★ X20b: one curve of a face written at once (the window's red control only).
    func setFaceCurve(_ r: Int, _ axis: FlexiblePressCurveBaselines.Axis, _ c: FlexCurve) {
        edit({ s in
            guard var f = s.face(r) else { return }
            if axis == .across { f.curveY = c } else { f.curveX = c }
            s.setFace(f)
        }, recompute: false)
        curveChanged(region: r)
    }

    /// The press's faces by name, in its strip's order ("Face 1", "Face 4").
    func stripFaceNames(_ id: UUID) -> [String] {
        guard let st = settings.press(id)?.strip else { return [] }
        return st.members.map { m in
            if let r = project.faceRegions.region(m.root), r.isCut { return FlexibleRowCopy.faceName(sector: r.name, face: m.face) }
            return "Face \(m.face)"
        }
    }
}

// MARK: - the window

/// ★ U2: the window over everything — the press's curves in 2D (stacked tables) or 3D (one table, the gizmo), [Cancel] / [OK].
struct FlexiblePressCurveModalView: View {
    @ObservedObject var model: FlexibleStageModel
    let draft: FlexiblePressCurveDraft
    /// The press's strip (nil: a face's curves).
    let strip: FlexibleStrip?
    @StateObject private var camera: OrbitCameraModel
    /// (tests only) the open window's 3D camera — the one its gizmo turns.
    @MainActor static weak var shownCamera: OrbitCameraModel?

    init(model: FlexibleStageModel, draft: FlexiblePressCurveDraft, strip: FlexibleStrip?) {
        self.model = model
        self.draft = draft
        self.strip = strip
        _camera = StateObject(wrappedValue: OrbitCameraModel(camera: FlexiblePressCurveModal.homeCamera(corner: strip?.kind == .corner)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // over everything: the page beneath takes no touch
                Color.black.opacity(0.6).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}
                    .accessibilityHidden(true)
                card(width: Swift.min(geo.size.width - 2 * PageChrome.edge, 620), height: geo.size.height)
            }
        }
        .onAppear { Self.shownCamera = camera }
        .accessibilityIdentifier("flexible-curve-modal")
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text(FlexiblePressCurveModal.title(draft.press.map { model.stripTitle($0) } ?? draft.face.map { model.displayName($0) } ?? ""))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: DS.Space.s)
                FlexChips(options: [("2d", "2D"), ("3d", "3D")], selection: draft.mode.rawValue, id: "flexible-curve-modal-mode",
                          equalWidths: false) { v in model.setCurveModalMode(FlexiblePressCurveDraft.Mode(rawValue: v) ?? .flat2D) }
                    .fixedSize()
            }
            if draft.mode == .flat2D {
                ForEach(strip.map { FlexiblePressCurveModal.tables2D($0, names: draft.press.map { model.stripFaceNames($0) } ?? []) }
                        ?? FlexiblePressCurveModal.faceTables2D()) { t in
                    FlexibleCurveTable2D(table: t, curves: draft.curves) { a, c in model.setDraftCurve(a, c) }
                }
            } else {
                FlexibleCurveTable3D(camera: camera, curves3D: strip.map { FlexiblePressCurveModal.curves3D($0, cut: draft.press.flatMap { model.flatCut($0) }) }
                                        ?? FlexiblePressCurveModal.faceCurves3D(), face: strip == nil,
                                     curves: draft.curves, height: Swift.min(460, Swift.max(300, height - 360))) { a, c in model.setDraftCurve(a, c) }
            }
            Text(FlexiblePressCurveModal.hint).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: DS.Space.m) {
                Spacer()
                Button { model.closeCurveModal(keep: false) } label: {
                    Text(FlexiblePressCurveModal.cancel).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Capsule().fill(DS.Color.fillSelected.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-curve-modal-cancel")
                Button { model.closeCurveModal(keep: true) } label: {
                    Text(FlexiblePressCurveModal.ok).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 26).frame(minHeight: 44)
                        .background(Capsule().fill(FlexibleStageStyle.accent))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flexible-curve-modal-ok")
            }
        }
        .padding(DS.Space.l)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous).fill(DS.Color.chipSolid.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveModal": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }
}

/// ★ U2 2D: one flat table — its curve(s) with FlexibleCurveEditor unchanged (drag a point, tap the line to add one, × deletes).
struct FlexibleCurveTable2D: View {
    let table: FlexiblePressCurveModal.Table
    let curves: [FlexiblePressCurveBaselines.Axis: FlexCurve]
    let onChange: (FlexiblePressCurveBaselines.Axis, FlexCurve) -> Void
    @State private var selected: [FlexiblePressCurveBaselines.Axis: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(table.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
            GeometryReader { g in
                let pr = FlexiblePressCurveModal.flatProjection(size: g.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSubtle.color)
                    ForEach(table.axes, id: \.self) { a in
                        FlexibleCurveEditor(projection: pr, baseline: FlexiblePressCurveModal.flatBaseline,
                                            curve: curves[a] ?? FlexiblePressCurveBaselines.ones, label: "",
                                            tint: FlexiblePressCurveModal.tint(a),
                                            selected: Binding(get: { selected[a] }, set: { selected[a] = $0 }),
                                            onChange: { onChange(a, $0) }, onCommit: {})
                    }
                }
                .coordinateSpace(name: FlexibleStageSpace.name)
            }
            .frame(height: 170)
            HStack {
                Text(table.ends.0)
                Spacer()
                Text(table.ends.1)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
            .padding(.horizontal, FlexiblePressCurveModal.flatMargin.width - 8)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveTable-\(table.id)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-table-\(table.id)")
    }
}

/// ★ U2 3D: both curves on ONE table, the flat face as the table, its own camera (drag the table or the gizmo to turn it; the
/// gizmo's Front and Top show each curve head-on). The model is not drawn.
struct FlexibleCurveTable3D: View {
    @ObservedObject var camera: OrbitCameraModel
    let curves3D: [FlexiblePressCurveModal.Curve3D]
    /// ★ X20b: a face's X / Y (the legend's words).
    var face: Bool = false
    let curves: [FlexiblePressCurveBaselines.Axis: FlexCurve]
    let height: CGFloat
    let onChange: (FlexiblePressCurveBaselines.Axis, FlexCurve) -> Void
    @State private var selected: [String: Int] = [:]
    @State private var dragLast: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { g in
                    let pr = CameraProjection(camera: camera.camera, viewportSize: g.size)
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Color.fillSubtle.color)
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    let last = dragLast ?? v.startLocation
                                    camera.orbit(dx: Float(v.location.x - last.x), dy: Float(v.location.y - last.y))
                                    dragLast = v.location
                                }
                                .onEnded { _ in dragLast = nil })
                        Canvas { ctx, _ in table(&ctx, pr) }.allowsHitTesting(false)
                        ForEach(curves3D.filter { FlexiblePressCurveModal.editable($0, pr) }) { c in
                            FlexibleCurveEditor(projection: pr, baseline: c.baseline,
                                                curve: curves[c.axis] ?? FlexiblePressCurveBaselines.ones, label: "",
                                                tint: FlexiblePressCurveModal.tint(c.axis),
                                                selected: Binding(get: { selected[c.id] }, set: { selected[c.id] = $0 }),
                                                onChange: { onChange(c.axis, $0) }, onCommit: {})
                        }
                    }
                    .coordinateSpace(name: FlexibleStageSpace.name)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                OrientationGizmoView(camera: camera, size: 124)
                    .padding(6)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveGizmo": g.frame(in: .global)])
                    }.allowsHitTesting(false))
                    .accessibilityIdentifier("flexible-curve-modal-gizmo")
            }
            .frame(height: height)
            HStack(spacing: DS.Space.m) {
                ForEach(Array(Set(curves3D.map(\.axis))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { a in
                    HStack(spacing: 6) {
                        Circle().fill(FlexiblePressCurveModal.tint(a)).frame(width: 8, height: 8)
                        Text(FlexiblePressCurveModal.legend(a, face: face)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Color.textSecondary.color).lineLimit(1)
                    }
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveTable3D": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-table-3d")
    }

    /// The table: the flat face (x = 0) as a grid square under the curves, and a short arrow for "softer" (+X).
    private func table(_ ctx: inout GraphicsContext, _ pr: CameraProjection) {
        let pts = curves3D.flatMap { $0.baseline.points }
        guard let f = pts.first else { return }
        let lo = pts.reduce(f) { simd_min($0, $1) }, hi = pts.reduce(f) { simd_max($0, $1) }
        let pad = 0.12
        let y0 = lo.y - pad, y1 = hi.y + pad, z0 = lo.z - pad, z1 = hi.z + pad
        func s(_ y: Double, _ z: Double, _ x: Double = 0) -> CGPoint? { pr.project(SIMD3<Float>(Float(x), Float(y), Float(z))) }
        var fill = Path()
        if let a = s(y0, z0), let b = s(y0, z1), let c = s(y1, z1), let d = s(y1, z0) { fill.addLines([a, b, c, d]); fill.closeSubpath() }
        ctx.fill(fill, with: .color(DS.Color.fillSubtle.color))
        var grid = Path()
        for i in 0...8 {
            let k = Double(i) / 8
            if let a = s(y0 + (y1 - y0) * k, z0), let b = s(y0 + (y1 - y0) * k, z1) { grid.move(to: a); grid.addLine(to: b) }
            if let a = s(y0, z0 + (z1 - z0) * k), let b = s(y1, z0 + (z1 - z0) * k) { grid.move(to: a); grid.addLine(to: b) }
        }
        ctx.stroke(grid, with: .color(DS.Color.strokeStrong.color), lineWidth: 1)
        ctx.stroke(fill, with: .color(DS.Color.textQuaternary.color), lineWidth: 1)
        // a curve seen edge-on: one faint line where it crosses (it is not edited in this view)
        for c in curves3D where !FlexiblePressCurveModal.editable(c, pr) {
            var l = Path()
            if let a = pr.project(SIMD3<Float>(c.baseline.at(0))), let b = pr.project(SIMD3<Float>(c.baseline.world(0.5, 1))) { l.move(to: a); l.addLine(to: b) }
            ctx.stroke(l, with: .color(FlexiblePressCurveModal.tint(c.axis).opacity(0.45)), lineWidth: 2)
        }
    }
}

/// ★ U2 / X20b: one [2D] or [3D] button of a Shape row — a press's or (his answer of 2026-10-20 ~19:10: "FACE presses use the SAME
/// 2D/3D curve window") a face's; 44 pt, its keep-out frame named by `id`.
struct FlexibleCurveModalButton: View {
    /// ★ X20b, RED CONTROL only: a face's Shape row without [2D] / [3D] (its curves edited on the part, before X20b).
    nonisolated(unsafe) static var controlNoFaceWindow = false
    let mode: FlexiblePressCurveDraft.Mode
    let id: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode == .flat2D ? "2D" : "3D").font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.Color.textPrimary.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DS.Color.fillSubtle.color))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: [(id == "flexible-press-curves" ? "pressCurves" : "faceCurves") + "-\(mode.rawValue)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel(label)
        .accessibilityIdentifier("\(id)-\(mode.rawValue)")
    }
}
