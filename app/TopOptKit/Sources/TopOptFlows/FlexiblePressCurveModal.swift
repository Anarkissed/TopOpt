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
// ★ U21 B (his notes of 2026-10-21, Img16 finally, 27.png): the window fills 80 % of the screen (FlexibleCurveWindowLayout; the
// 3D camera fits by aspect), and a legend column beside the charts carries [Mirror] (Left → Right / Right → Left) per curve and
// [Copy] between the two (FlexibleCurveMirror) — draft only, as every drag; a corner has none.

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
    /// ★ U21 B: bumped by each [Mirror] / [Copy] — the tables clear their selected point (their selection is private state).
    public var resets: Int = 0
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

/// ★ U21 B CURVE-WINDOW-80 (his notes of 2026-10-21, Img16 finally: "Please also expand the modal to fill 80% of the screen, going
/// overtop most assets. This is especially required for the 3D view."): the window is 0.8 × the screen, centred on it; the 2D
/// tables share its height (≥ 140 pt each), the 3D table fills the rest, and the 3D camera fits by aspect (a taller-than-wide table
/// widens its vertical lens so the square table fits its WIDTH, never clipped nor under the gizmo when turned).
enum FlexibleCurveWindowLayout {
    static let fraction: CGFloat = 0.8
    /// The legend column beside the charts (Mirror / Copy).
    static let column: CGFloat = 168
    static let minChart: CGFloat = 140
    static let min3D: CGFloat = 240
    /// The legend's buttons: 44 pt tall, 8 pt apart.
    static let button: CGFloat = 44, buttonGap: CGFloat = 8

    /// ★ RED CONTROL only: the window before U21 (620 pt wide at most, its height its content, charts 170 pt, 3D ≤ 460 pt).
    nonisolated(unsafe) static var controlOldWindowSize = false
    /// ★ RED CONTROL only: the 3D table's camera keeps its vertical lens in a taller-than-wide table (the square table clips).
    nonisolated(unsafe) static var controlNoAspectFit = false

    /// The window in the reader's own space: 0.8 × the screen (the reader's size + its safe-area insets), centred on the screen.
    static func card(size: CGSize, insets: EdgeInsets) -> CGRect {
        let sw = size.width + insets.leading + insets.trailing, sh = size.height + insets.top + insets.bottom
        let w = (fraction * sw).rounded(), h = (fraction * sh).rounded()
        return CGRect(x: sw / 2 - insets.leading - w / 2, y: sh / 2 - insets.top - h / 2, width: w, height: h)
    }

    /// The 3D table's camera for a table of `size`: in a taller-than-wide table the vertical lens widens by height ÷ width, so the
    /// table's horizontal lens is the camera's own (the fit is by the smaller side).
    static func fitted(_ c: OrbitCamera, size: CGSize) -> OrbitCamera {
        guard !controlNoAspectFit, size.width > 0, size.height > size.width else { return c }
        var out = c
        out.fovY = 2 * atan(tan(c.fovY / 2) * Float(size.height / size.width))
        return out
    }
}

/// ★ U2: the window over everything — the press's curves in 2D (stacked tables) or 3D (one table, the gizmo), [Cancel] / [OK].
/// ★ U21 B: 80 % of the screen; the Mirror / Copy legend column beside the charts (none for a corner).
struct FlexiblePressCurveModalView: View {
    @ObservedObject var model: FlexibleStageModel
    let draft: FlexiblePressCurveDraft
    /// The press's strip (nil: a face's curves).
    let strip: FlexibleStrip?
    @StateObject private var camera: OrbitCameraModel
    /// (tests only) the open window's 3D camera — the one its gizmo turns.
    @MainActor static weak var shownCamera: OrbitCameraModel?
    typealias Axis = FlexiblePressCurveBaselines.Axis
    typealias L = FlexibleCurveWindowLayout

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
                if L.controlOldWindowSize {   // (RED CONTROL: the window before U21)
                    card(width: Swift.min(geo.size.width - 2 * PageChrome.edge, 620), height: nil, old3D: Swift.min(460, Swift.max(300, geo.size.height - 360)))
                } else {
                    let r = L.card(size: geo.size, insets: geo.safeAreaInsets)
                    card(width: r.width, height: r.height, old3D: nil)
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
        .onAppear { Self.shownCamera = camera }
        .accessibilityIdentifier("flexible-curve-modal")
    }

    private var isFace: Bool { strip == nil }
    private var pair: (top: Axis, bottom: Axis)? { FlexibleCurveMirror.copyPair(face: isFace, strip: strip) }

    private func card(width: CGFloat, height: CGFloat?, old3D: CGFloat?) -> some View {
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
            HStack(alignment: .top, spacing: DS.Space.l) {
                if draft.mode == .flat2D {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(strip.map { FlexiblePressCurveModal.tables2D($0, names: draft.press.map { model.stripFaceNames($0) } ?? []) }
                                ?? FlexiblePressCurveModal.faceTables2D()) { t in
                            FlexibleCurveTable2D(table: t, curves: draft.curves, resetToken: draft.resets,
                                                 chartHeight: old3D == nil ? nil : 170) { a, c in model.setDraftCurve(a, c) }
                        }
                    }
                    if let p = pair, !L.controlOldWindowSize { column2D(p) }
                } else {
                    FlexibleCurveTable3D(camera: camera, curves3D: strip.map { FlexiblePressCurveModal.curves3D($0, cut: draft.press.flatMap { model.flatCut($0) }) }
                                            ?? FlexiblePressCurveModal.faceCurves3D(), face: isFace,
                                         curves: draft.curves, height: old3D, resetToken: draft.resets,
                                         showsLegend: pair == nil || L.controlOldWindowSize) { a, c in model.setDraftCurve(a, c) }
                    if let p = pair, !L.controlOldWindowSize { column3D(p) }
                }
            }
            .frame(maxHeight: height == nil ? nil : .infinity, alignment: .top)
            Text(FlexiblePressCurveModal.hint).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
            HStack(spacing: DS.Space.m) {
                Spacer()
                Button { model.closeCurveModal(keep: false) } label: {
                    Text(FlexiblePressCurveModal.cancel).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Color.textPrimary.color).padding(.horizontal, 18).frame(minHeight: 44)
                        .background(Capsule().fill(DS.Color.fillSelected.color))
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveCancel": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .accessibilityIdentifier("flexible-curve-modal-cancel")
                Button { model.closeCurveModal(keep: true) } label: {
                    Text(FlexiblePressCurveModal.ok).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlexibleStageStyle.onAccent).padding(.horizontal, 26).frame(minHeight: 44)
                        .background(Capsule().fill(FlexibleStageStyle.accent))
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveOK": g.frame(in: .global)])
                }.allowsHitTesting(false))
                .accessibilityIdentifier("flexible-curve-modal-ok")
            }
        }
        .padding(DS.Space.l)
        .frame(width: width, height: height, alignment: .top)
        .background(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous).fill(DS.Color.chipSolid.color))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.dialog, style: .continuous).strokeBorder(DS.Color.strokeSheet.color, lineWidth: 1))
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveModal": g.frame(in: .global)])
        }.allowsHitTesting(false))
    }

    // MARK: the legend column (U21 B CURVE-MIRROR)

    /// A curve's short name for the spoken labels ("X", "Across").
    private func name(_ a: Axis) -> String {
        if isFace { return a == .along ? "X" : "Y" }
        switch a { case .across: return "across"; case .along: return "along"; case .corner: return "corner" }
    }

    /// 2D: [Mirror] beside each chart (its colour dot), [Copy] between the two.
    private func column2D(_ p: (top: Axis, bottom: Axis)) -> some View {
        VStack(alignment: .leading, spacing: L.buttonGap) {
            mirrorBlock(p.top, head: FlexibleRowCopy.curveMirror)
            Spacer(minLength: L.buttonGap)
            copyBlock(p)
            Spacer(minLength: L.buttonGap)
            mirrorBlock(p.bottom, head: FlexibleRowCopy.curveMirror)
        }
        .frame(width: L.column)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveLegend": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-legend")
    }

    /// 3D: each curve's block named by the curve (its colour dot, "head-on from Top / Front"), then [Copy].
    private func column3D(_ p: (top: Axis, bottom: Axis)) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            mirrorBlock(p.top, head: FlexiblePressCurveModal.legend(p.top, face: isFace))
            mirrorBlock(p.bottom, head: FlexiblePressCurveModal.legend(p.bottom, face: isFace))
            copyBlock(p)
            Spacer(minLength: 0)
        }
        .frame(width: L.column)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveLegend": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-legend")
    }

    private func mirrorBlock(_ a: Axis, head: String) -> some View {
        let c = draft.curves[a] ?? FlexiblePressCurveBaselines.ones
        return VStack(alignment: .leading, spacing: L.buttonGap) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(FlexiblePressCurveModal.tint(a)).frame(width: 8, height: 8)
                Text(head).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            actionButton(FlexibleRowCopy.curveMirrorLR, id: "mirror-\(a.rawValue)-lr",
                         spoken: FlexibleRowCopy.curveMirrorSpoken(name(a), leftToRight: true),
                         enabled: FlexibleCurveMirror.changes(c, .leftToRight)) { model.mirrorDraftCurve(a, .leftToRight) }
            actionButton(FlexibleRowCopy.curveMirrorRL, id: "mirror-\(a.rawValue)-rl",
                         spoken: FlexibleRowCopy.curveMirrorSpoken(name(a), leftToRight: false),
                         enabled: FlexibleCurveMirror.changes(c, .rightToLeft)) { model.mirrorDraftCurve(a, .rightToLeft) }
        }
    }

    private func copyBlock(_ p: (top: Axis, bottom: Axis)) -> some View {
        let same = (draft.curves[p.top] ?? FlexiblePressCurveBaselines.ones) == (draft.curves[p.bottom] ?? FlexiblePressCurveBaselines.ones)
        return VStack(alignment: .leading, spacing: L.buttonGap) {
            Text(FlexibleRowCopy.curveCopy).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.textSecondary.color)
            actionButton(isFace ? FlexibleRowCopy.curveCopyXY : FlexibleRowCopy.curveCopyAcrossAlong, id: "copy-down",
                         spoken: FlexibleRowCopy.curveCopySpoken(name(p.top), name(p.bottom)), enabled: !same) {
                model.copyDraftCurve(from: p.top, to: p.bottom)
            }
            actionButton(isFace ? FlexibleRowCopy.curveCopyYX : FlexibleRowCopy.curveCopyAlongAcross, id: "copy-up",
                         spoken: FlexibleRowCopy.curveCopySpoken(name(p.bottom), name(p.top)), enabled: !same) {
                model.copyDraftCurve(from: p.bottom, to: p.top)
            }
        }
    }

    private func actionButton(_ label: String, id: String, spoken: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: L.button)
                .background(Capsule().fill(DS.Color.fillSelected.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveAction-\(id)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("flexible-curve-\(id)")
    }
}

/// ★ U2 2D: one flat table — its curve(s) with FlexibleCurveEditor unchanged (drag a point, tap the line to add one, × deletes).
/// ★ U21 B: the chart shares the window's height (≥ 140 pt); `resetToken` clears the selected point after a Mirror / Copy.
struct FlexibleCurveTable2D: View {
    let table: FlexiblePressCurveModal.Table
    let curves: [FlexiblePressCurveBaselines.Axis: FlexCurve]
    var resetToken: Int = 0
    /// nil: the chart fills its share of the window (U21 B); a number: that height (the red control's old window).
    var chartHeight: CGFloat? = nil
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
                .background(GeometryReader { c in
                    Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveChart-\(table.id)": c.frame(in: .global)])
                }.allowsHitTesting(false))
            }
            .frame(minHeight: chartHeight ?? FlexibleCurveWindowLayout.minChart, maxHeight: chartHeight ?? .infinity)
            HStack {
                Text(table.ends.0)
                Spacer()
                Text(table.ends.1)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Color.textTertiary.color)
            .padding(.horizontal, FlexiblePressCurveModal.flatMargin.width - 8)
        }
        .onChange(of: resetToken) { _ in selected = [:] }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveTable-\(table.id)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-table-\(table.id)")
    }
}

/// ★ U2 3D: both curves on ONE table, the flat face as the table, its own camera (drag the table or the gizmo to turn it; the
/// gizmo's Front and Top show each curve head-on). The model is not drawn.
/// ★ U21 B: the table fills the window's rest; its camera fits by aspect (FlexibleCurveWindowLayout.fitted); small L / R tags at
/// each curve's ends (Mirror's left and right); the legend moved into the column beside it (kept under it for a corner).
struct FlexibleCurveTable3D: View {
    @ObservedObject var camera: OrbitCameraModel
    let curves3D: [FlexiblePressCurveModal.Curve3D]
    /// ★ X20b: a face's X / Y (the legend's words).
    var face: Bool = false
    let curves: [FlexiblePressCurveBaselines.Axis: FlexCurve]
    /// nil: the table fills the window's rest (U21 B); a number: that height (the red control's old window).
    var height: CGFloat? = nil
    var resetToken: Int = 0
    /// The legend under the table (a corner, which has no column).
    var showsLegend: Bool = true
    let onChange: (FlexiblePressCurveBaselines.Axis, FlexCurve) -> Void
    @State private var selected: [String: Int] = [:]
    @State private var dragLast: CGPoint?

    /// The projection the table draws and edits with (tests read the same).
    static func projection(_ c: OrbitCamera, _ size: CGSize) -> CameraProjection {
        CameraProjection(camera: FlexibleCurveWindowLayout.fitted(c, size: size), viewportSize: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                GeometryReader { g in
                    let pr = Self.projection(camera.camera, g.size)
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
            .frame(minHeight: height ?? FlexibleCurveWindowLayout.min3D, maxHeight: height ?? .infinity)
            .background(GeometryReader { g in
                Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveView3D": g.frame(in: .global)])
            }.allowsHitTesting(false))
            if showsLegend {
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
        }
        .onChange(of: resetToken) { _ in selected = [:] }
        .background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["curveTable3D": g.frame(in: .global)])
        }.allowsHitTesting(false))
        .accessibilityIdentifier("flexible-curve-table-3d")
    }

    /// The table's square in table space (the flat face x = 0, padded around the curves): its four corners.
    static func tableCorners(_ curves3D: [FlexiblePressCurveModal.Curve3D]) -> [SIMD3<Double>] {
        let pts = curves3D.flatMap { $0.baseline.points }
        guard let f = pts.first else { return [] }
        let lo = pts.reduce(f) { simd_min($0, $1) }, hi = pts.reduce(f) { simd_max($0, $1) }
        let pad = 0.12
        return [SIMD3(0, lo.y - pad, lo.z - pad), SIMD3(0, lo.y - pad, hi.z + pad), SIMD3(0, hi.y + pad, hi.z + pad), SIMD3(0, hi.y + pad, lo.z - pad)]
    }

    /// Where a curve's L / R tag sits: just past its end, out along the curve on screen (nil when seen edge-on).
    static func endTags(_ c: FlexiblePressCurveModal.Curve3D, _ pr: CameraProjection) -> (l: CGPoint, r: CGPoint)? {
        guard c.axis != .corner, FlexiblePressCurveModal.editable(c, pr),
              let a = pr.project(SIMD3<Float>(c.baseline.at(0))), let b = pr.project(SIMD3<Float>(c.baseline.at(1))) else { return nil }
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 1 else { return nil }
        let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d, k: CGFloat = 14
        return (CGPoint(x: a.x - ux * k, y: a.y - uy * k), CGPoint(x: b.x + ux * k, y: b.y + uy * k))
    }

    /// The table: the flat face (x = 0) as a grid square under the curves, and a short arrow for "softer" (+X).
    private func table(_ ctx: inout GraphicsContext, _ pr: CameraProjection) {
        let cs = Self.tableCorners(curves3D)
        guard cs.count == 4 else { return }
        let y0 = cs[0].y, y1 = cs[2].y, z0 = cs[0].z, z1 = cs[2].z
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
        // ★ U21 B: L / R at each curve's ends (what Mirror's left and right mean on this table)
        for c in curves3D {
            guard let t = Self.endTags(c, pr) else { continue }
            let tint = FlexiblePressCurveModal.tint(c.axis)
            ctx.draw(Text("L").font(.system(size: 11, weight: .bold)).foregroundColor(tint), at: t.l)
            ctx.draw(Text("R").font(.system(size: 11, weight: .bold)).foregroundColor(tint), at: t.r)
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
