// FlexibleFaceStamp — a face's Shape = Stamp: its ONE stamp, edited inline on the Face tab and
// moved by one handle on the part (task 2026-09-29-flexible-screens, round 4 batch D1).
//
// ★ HIS NOTES (img 1, img 4) AND ANSWER 3. "If it's an either/or then the Stamp section should
// only be visible when it is selected. And the curves should disappear right away." "There is
// a way to add multiple stamps on the same side … unless it can actually create a lattice
// that can squish a face in multiple ways, then there is no point to keep it." So:
//   * Shape [Curves | Stamp] on the face row is live. Stamp shows THIS face's single stamp in
//     place of the curves (the curve editors go at once — FlexibleStageOverlays.curveAxes);
//     Curves hides it (the stamp stays stored for a switch back, and is never sent);
//   * one stamp per face: which one (the library, or an imported SVG / image), its size, a
//     quarter turn, soft or rigid — one line each; its weight IS the face's weight (the
//     weight row above it, which a main-page group may own);
//   * the Stamps tab and the check stamps are gone (the tap-to-read legend gives dent values);
//   * the stamp's handle and outline are drawn ONLY for the selected Stamp face, and NEVER
//     under the panel or the legend (img 6's black circles were round 3's check-stamp handles
//     seen through the panel) — the depth chip's keep-out rule, and the outline clipped out.
// ★ WHAT CORE DOES WITH IT: flat curves + `design_stamp` (FlexibleJob) — core designs the face
// so the stamp sinks the deepest squish where it sits and uses weight ÷ footprint elsewhere
// (core brief #10: "sinks that far ANYWHERE" is core work). The map the page draws is the
// stamp sinking where it sits ("What you drew"), and the depth prism stands on its footprint.

import SwiftUI
import UniformTypeIdentifiers
import simd
import TopOptDesign
import TopOptKit

// MARK: - the model

extension FlexibleStageModel {

    /// A face's short name, as the panel and the face list say it ("Top A", "Face 3") — the
    /// readiness line's own `displayName` (one rule, not a copy of it).
    public func faceName(_ r: Int) -> String { displayName(r) }

    /// Shape [Curves | Stamp]: an either/or. Stamp lands ONE stamp on the face (the library's
    /// first that fits it, at its centre) unless the face kept one from before.
    /// ★ VERIFICATION OF D1: a tap on the chip ALREADY chosen changes nothing (a face that never
    /// chose reads Curves) — writing "curves" over nil changed the settings' hash, so the main
    /// page's lattice went stale and the designs re-ran for a tap that changed nothing.
    /// ★ AND A STAMP NEEDS ITS FACE: before the face's stack has landed there is no size to fit
    /// or centre to sit on (it put an 80 × 95 mm palm on the pad's corner, mostly off the face) —
    /// the shape is Stamp at once and the stamp is seeded when the stack arrives
    /// (`seedStampIfNeeded`, from the stack's landing).
    public func setShape(_ r: Int, _ shape: String) {
        guard let current = settings.face(r) else { return }
        guard (shape == "stamp") != current.isStampShape else { curvePoint = nil; return }
        let seed = shape == "stamp" ? defaultStamp(r) : nil
        edit { s in
            guard var f = s.face(r) else { return }
            if shape == "stamp" {
                if f.designStamp == nil { f.designStamp = seed }
                f.shape = "stamp"
            } else {
                // "curves", never nil: nil + a stored stamp reads as round 3's design stamp
                // (FlexibleSettingsMigration) and would come back as Stamp
                f.shape = "curves"
            }
            s.setFace(f)
        }
        curvePoint = nil
        save()
    }

    /// The stamp a face gets when Stamp is chosen: the palm, a thumb or a fingertip — the first
    /// that fits the face, square or turned a quarter — at the face centre. nil until the face's
    /// stack has landed (its size and centre are the stack's).
    func defaultStamp(_ r: Int) -> FlexibleStampPlacement? {
        guard let lib = library, let f = settings.face(r), let st = stack(r) else { return nil }
        let u = st.uExtentMM, v = st.vExtentMM
        guard u > 0, v > 0 else { return nil }
        let order = ["palm", "thumb", "fingertip"].compactMap { lib.shape($0) }
            + lib.stamps.filter { $0.shape != "whole_face" }
        for s in order {
            guard let turn = Self.stampTurnThatFits(s.naturalSizeMM, uExtentMM: u, vExtentMM: v) else { continue }
            var p = FlexibleStamps.place(s, uExtentMM: u, vExtentMM: v, weightKg: f.weightKg)
            p.rotationDeg = turn
            return p
        }
        return lib.stamps.first.map { FlexibleStamps.place($0, uExtentMM: u, vExtentMM: v, weightKg: f.weightKg) }
    }

    /// 0 when a stamp of `size` fits the face (within 90 % of each side) as it is, 90 when it
    /// fits only turned a quarter (a long stamp along a long face), nil when it fits neither way.
    nonisolated static func stampTurnThatFits(_ size: (width: Double, length: Double), uExtentMM u: Double,
                                              vExtentMM v: Double) -> Double? {
        if size.width <= 0.9 * u && size.length <= 0.9 * v { return 0 }
        if size.length <= 0.9 * u && size.width <= 0.9 * v { return 90 }
        return nil
    }

    /// A Stamp face with no stamp yet (Stamp chosen before its stack landed): seeded now, at
    /// the face centre. Called as a stack lands.
    func seedStampIfNeeded(_ r: Int) {
        guard let f = settings.face(r), f.isStampShape, f.designStamp == nil, let seed = defaultStamp(r) else { return }
        edit({ s in
            guard var g = s.face(r) else { return }
            g.designStamp = seed
            s.setFace(g)
        }, recompute: false)   // the stack's landing recomputes (and lays the stamp's grid)
    }

    /// Replace the face's stamp (a library shape, or an imported mask), keeping where it sits.
    /// Refused until the face's stack has landed (no size to fit, no centre to sit on).
    public func setStamp(_ r: Int, source: FlexibleStampSource, shape: FlexibleStampShape?) {
        guard let st = stack(r) else { return }
        let u = st.uExtentMM, v = st.vExtentMM
        edit { s in
            guard var f = s.face(r) else { return }
            var p: FlexibleStampPlacement
            if let shape {
                p = FlexibleStamps.place(shape, uExtentMM: u, vExtentMM: v, weightKg: f.weightKg)
            } else {
                let side = max(1, min(u, v) * 0.4)
                var aspect = 1.0
                if case .imported(_, _, _, let a) = source { aspect = a }
                p = FlexibleStampPlacement(source: source, widthMM: side * min(1, aspect), lengthMM: side / max(1, aspect),
                                           centreU: u / 2, centreV: v / 2, weightKg: f.weightKg, rigid: false)
            }
            if let old = f.designStamp, shape?.shape != "whole_face" {
                p.centreU = old.centreU; p.centreV = old.centreV; p.rotationDeg = old.rotationDeg
            }
            f.designStamp = p
            f.shape = "stamp"
            s.setFace(f)
        }
        save()
    }

    /// Change the face's stamp (size, turn, soft / rigid, where it sits).
    public func updateStamp(_ r: Int, save saving: Bool = true, _ change: (inout FlexibleStampPlacement) -> Void) {
        edit { s in
            guard var f = s.face(r), var p = f.designStamp else { return }
            change(&p)
            f.designStamp = p
            s.setFace(f)
        }
        if saving { save() }
    }

    /// Where the Stamp face's stamp presses, per column 0…1 — nil for a Curves face or before
    /// the grid is laid. ★ SMOOTHED (verification of D1): the stamp's sharp cover, a 0/1 step
    /// one column wide, was drawn as a ROW OF TEETH — each dent corner is the mean of the four
    /// columns round it, so along the staircase of the stamp's edge the corners alternated ¼ / ¾
    /// of a 12 mm (× 4) cliff. The cover is blurred on the column grid
    /// (`FlexibleStampFootprint.smoothed`), so the pit's wall slopes and the corners at one
    /// distance from the stamp's edge sink alike.
    public func stampFootprint(_ r: Int) -> [Double]? {
        guard let raw = stampCoverage(r), let st = stack(r) else { return nil }
        return FlexibleStampFootprint.smoothed(raw, stack: st)
    }

    /// The stamp's sharp COVER of each column: its laid grid (half a pitch) averaged over the
    /// column's own cell, over the grid's peak — what the smoothing starts from (and the red
    /// control of the teeth).
    func stampCoverage(_ r: Int) -> [Double]? {
        guard let f = settings.face(r), let p = f.activeStamp, let g = stampGrids[p.id], let st = stack(r),
              g.cellMM > 0, let peak = g.valuesMPa.max(), peak > 0 else { return nil }
        let q = st.pitchMM / 4
        return st.columns.map { c in
            var sum = 0.0
            for (du, dv) in [(-q, -q), (q, -q), (-q, q), (q, q)] {
                let iu = Int(((c.uMM + du - g.originU) / g.cellMM).rounded(.down))
                let iv = Int(((c.vMM + dv - g.originV) / g.cellMM).rounded(.down))
                guard iu >= 0, iv >= 0, iu < g.nu, iv < g.nv else { continue }
                sum += g.valuesMPa[iv * g.nu + iu] / peak
            }
            return sum / 4
        }
    }

    /// A Stamp face's footprint for its depth prism (the smoothed one, whose ½ contour the prism
    /// stands on); nil for a Curves face (the prism stands on every column).
    public func prismFootprint(_ r: Int) -> [Double]? {
        guard settings.face(r)?.isStampShape == true else { return nil }
        return stampFootprint(r) ?? []
    }

    /// The columns a face's depth prism stands on: a Stamp face's footprint (at least half
    /// pressed); nil ⇒ every column (Curves).
    public func prismColumns(_ r: Int) -> Set<Int>? {
        guard settings.face(r)?.isStampShape == true else { return nil }
        guard let foot = stampFootprint(r) else { return [] }
        return Set(foot.indices.filter { foot[$0] >= 0.5 })
    }

    /// A stamp's name: the library's, or the imported file's.
    public func stampName(_ p: FlexibleStampPlacement) -> String {
        switch p.source {
        case .library(let id): return library?.shape(id)?.name ?? id
        case .imported(let n, _, _, _): return n
        }
    }
}

// MARK: - the rows (Shape = Stamp, on the Face tab, in place of the curves)

struct FlexibleFaceStampRows: View {
    @ObservedObject var model: FlexibleStageModel
    let region: Int
    @Binding var padTarget: String?
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let f = model.settings.face(region) {
                let p = f.activeStamp
                FlexRow(FlexibleRowCopy.stamp(name: p.map { model.stampName($0) } ?? "pick one"),
                        info: FlexibleRowCopy.Info.stamp, id: "flexible-row-stamp") {
                    // a stamp needs its face's stack (its size and centre): the menu waits for it
                    if model.stack(region) != nil {
                    Menu {
                        ForEach(model.library?.stamps ?? []) { s in
                            Button(s.name) { model.setStamp(region, source: .library(s.id), shape: s) }
                        }
                        Divider()
                        Button { importing = true } label: { Label(FlexibleRowCopy.stampImport, systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Color.textPrimary.color)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(DS.Color.fillSubtle.color))
                    }
                    .accessibilityIdentifier("flexible-stamp-menu")
                    }
                }
                if let p {
                    // ★ ROUND 5 (S3): every number in its own box — tap for the keypad, drag up / down
                    let faceMM = model.stack(region).map { max($0.uExtentMM, $0.vExtentMM) }
                    FlexRow(FlexibleRowCopy.stampSize(widthMM: p.widthMM, lengthMM: p.lengthMM),
                            info: FlexibleRowCopy.Info.stampSize, id: "flexible-row-stamp-size") {
                        FlexNumberBox(key: "stamp-size-\(region)", title: FlexibleRowCopy.stampWidthTitle,
                                      spec: FlexibleNumberSpecs.stampWidth(mm: p.widthMM, faceMM: faceMM),
                                      padTarget: $padTarget) { v in
                            model.updateStamp(region) { q in
                                let k = q.widthMM > 0 ? v / q.widthMM : 1
                                q.widthMM = v; q.lengthMM *= k
                            }
                        }
                    }
                    FlexRow(FlexibleRowCopy.stampTurnRow, info: FlexibleRowCopy.Info.stampTurn,
                            id: "flexible-row-stamp-turn") {
                        FlexNumberBox(key: "stamp-turn-\(region)", title: FlexibleRowCopy.stampTurnRow,
                                      spec: FlexibleNumberSpecs.stampTurn(deg: p.rotationDeg),
                                      padTarget: $padTarget) { v in
                            model.updateStamp(region) { $0.rotationDeg = v.truncatingRemainder(dividingBy: 360) }
                        }
                        .accessibilityIdentifier("flexible-stamp-turn")
                    }
                    FlexRow(FlexibleRowCopy.stampPress, info: FlexibleRowCopy.Info.stampPress, id: "flexible-row-stamp-press") {
                        FlexChips(options: FlexibleRowCopy.stampPressOptions, selection: p.rigid ? "rigid" : "soft",
                                  id: "flexible-stamp-press", equalWidths: false) { v in
                            model.updateStamp(region) { $0.rigid = v == "rigid" }
                        }
                        .fixedSize()
                    }
                    // ★ ONE LINE, NEVER BEHIND THE (i) (verification of D1): the main page's lattice is
                    // core's design of this face, and today core sinks the WHOLE face (flat curves ⇒
                    // the deepest everywhere, core brief #10) — the map here is the stamp he drew
                    Text(FlexibleRowCopy.stampMainPage)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.textSecondary.color)
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .accessibilityIdentifier("flexible-row-stamp-main-page")
                    let err = model.stampError(p.id)
                    if !err.isEmpty { FlexWarningLine(text: FlexibleRowCopy.fit(err), id: "flexible-row-stamp-error") }
                    if let d = model.design(region), d.designStampOffFace {
                        FlexWarningLine(text: FlexibleRowCopy.stampOffFace(d.designStampOffFaceN), id: "flexible-row-stamp-offface")
                    }
                }
                if let e = importError { FlexWarningLine(text: FlexibleRowCopy.fit(e), id: "flexible-row-stamp-import-error") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.svg, .png, .jpeg, .image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let name = url.deletingPathExtension().lastPathComponent
                let src: FlexibleStampSource = url.pathExtension.lowercased() == "svg"
                    ? try FlexibleStampImport.svg(text: String(decoding: data, as: UTF8.self), name: name)
                    : try FlexibleStampImport.image(data: data, name: name)
                importError = nil
                model.setStamp(region, source: src, shape: nil)
            } catch {
                importError = "\(error)"
            }
        }
    }
}

// MARK: - the handle on the part

/// The selected Stamp face's stamp on the part: its outline and one draggable centre. ★ NEVER
/// UNDER THE PANEL OR THE LEGEND (img 6): the handle hides in a keep-out (the depth chip's
/// rule — mounted mid-drag), and the outline is clipped out of them.
struct FlexibleFaceStampHandle: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    /// The panel's and the legend's frames, in stage points.
    let keepOut: [CGRect]
    /// The page's exaggeration: where the depth chip sits (the handle keeps clear of it).
    var k: Double = 1
    /// The stamp's centre when the drag began (nil: not dragging).
    @State private var dragging: SIMD2<Double>?

    struct Placed { let region: Int; let stamp: FlexibleStampPlacement }

    /// ★ NEVER ON THE DEPTH CHIP (verification of D1): the chip sits on the prism's floor, right
    /// under the stamp's centre along the load, so seen from above (≳ 60°) the two 44 pt targets
    /// met and the handle — drawn later — took the chip's drag. The handle keeps `minGap` from the
    /// chip on screen, pushed straight away from it (up-left when they coincide), with a leader
    /// to the stamp's centre; its drag is relative, so where it sits does not move the stamp.
    static let minGap: CGFloat = 56
    static func handlePoint(centre c: CGPoint, chip: CGPoint?) -> CGPoint {
        guard let q = chip, q.x.isFinite, q.y.isFinite else { return c }
        let dx = c.x - q.x, dy = c.y - q.y, d = hypot(dx, dy)
        guard d < minGap else { return c }
        let dir = d > 1 ? CGVector(dx: dx / d, dy: dy / d) : CGVector(dx: -0.7071, dy: -0.7071)
        return CGPoint(x: q.x + dir.dx * minGap, y: q.y + dir.dy * minGap)
    }

    /// What is drawn: ONLY the selected face's stamp, and only while its shape is Stamp — one
    /// handle at most (round 3 drew every design and check stamp of every face).
    static func placements(_ s: FlexibleStageSettings, selected: Int?) -> [Placed] {
        guard let r = selected, let f = s.face(r), f.isLoaded, let p = f.activeStamp else { return [] }
        return [Placed(region: r, stamp: p)]
    }

    /// A face point at (u, v): the column plane through the corner, along core's X / Y.
    private func world(_ r: Int, _ u: Double, _ v: Double) -> SIMD3<Double>? {
        guard let k = model.key(r), let g = model.geometry[k], let st = model.stacks[k] else { return nil }
        return g.corner + st.xAxis * u + st.yAxis * v - st.load * 0.5
    }
    private func screen(_ w: SIMD3<Double>?) -> CGPoint? {
        w.flatMap { projection?.project(SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))) }
    }

    var body: some View {
        let placed = Self.placements(model.settings, selected: model.selectedRegion)
        let vp = projection?.viewportSize ?? .zero
        let chip = placed.isEmpty ? nil : FlexibleDepthChips.handle(model: model, k: k).flatMap { projection?.project($0.anchor) }
        ZStack {
            Canvas { ctx, size in
                var clip = Path(CGRect(origin: .zero, size: size))
                for r in keepOut { clip.addRect(r) }
                ctx.clip(to: clip, style: FillStyle(eoFill: true))
                for s in placed {
                    // the leader from a handle kept off the chip to the stamp's centre
                    if let c = screen(world(s.region, s.stamp.centreU, s.stamp.centreV)) {
                        let h = Self.handlePoint(centre: c, chip: chip)
                        if h != c {
                            var lead = Path(); lead.move(to: c); lead.addLine(to: h)
                            ctx.stroke(lead, with: .color(FlexibleStageStyle.onPart.opacity(0.7)), lineWidth: 1.5)
                        }
                    }
                    let th = s.stamp.rotationDeg * .pi / 180
                    var path = Path()
                    for i in 0...48 {
                        let a = Double(i) / 48 * 2 * .pi
                        let lx = cos(a) * s.stamp.widthMM / 2, ly = sin(a) * s.stamp.lengthMM / 2
                        let u = s.stamp.centreU + lx * cos(th) - ly * sin(th), v = s.stamp.centreV + lx * sin(th) + ly * cos(th)
                        guard let q = screen(world(s.region, u, v)) else { continue }
                        i == 0 ? path.move(to: q) : path.addLine(to: q)
                    }
                    ctx.stroke(path, with: .color(FlexibleStageStyle.onPart),
                               style: StrokeStyle(lineWidth: 2, dash: s.stamp.rigid ? [] : [6, 4]))
                }
            }
            .allowsHitTesting(false)
            ForEach(placed, id: \.stamp.id) { s in
                if let c = screen(world(s.region, s.stamp.centreU, s.stamp.centreV)),
                   case let q = Self.handlePoint(centre: c, chip: chip),
                   FlexibleDepthChipLayout.shows(q, dragging: dragging != nil, keepOut: keepOut, viewport: vp) {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.Color.chipSolid.color)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(FlexibleStageStyle.onPart))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .position(q)
                        .gesture(drag(s))
                        .accessibilityIdentifier("flexible-stamp-handle")
                }
            }
        }
    }

    /// Screen drag → (u, v) through the projected X / Y axes at the stamp's centre.
    private func drag(_ s: Placed) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                if dragging == nil { dragging = SIMD2(s.stamp.centreU, s.stamp.centreV) }
                guard let st = dragging, let o = screen(world(s.region, st.x, st.y)),
                      let ex = screen(world(s.region, st.x + 10, st.y)),
                      let ey = screen(world(s.region, st.x, st.y + 10)) else { return }
                let ax = CGVector(dx: ex.x - o.x, dy: ex.y - o.y), ay = CGVector(dx: ey.x - o.x, dy: ey.y - o.y)
                let det = ax.dx * ay.dy - ax.dy * ay.dx
                guard abs(det) > 1e-6 else { return }
                let d = CGVector(dx: g.translation.width, dy: g.translation.height)
                let a = (d.dx * ay.dy - d.dy * ay.dx) / det, b = (ax.dx * d.dy - ax.dy * d.dx) / det
                model.updateStamp(s.region, save: false) { p in
                    p.centreU = st.x + Double(a) * 10
                    p.centreV = st.y + Double(b) * 10
                }
            }
            .onEnded { _ in
                dragging = nil
                model.save()
            }
    }
}
