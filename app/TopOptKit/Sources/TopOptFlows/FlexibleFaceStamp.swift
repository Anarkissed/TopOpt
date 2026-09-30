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

    /// A face's short name, as the panel and the face list say it ("Top A", "Face 3").
    public func faceName(_ r: Int) -> String {
        let sector = regions.sector(r)
        return FlexibleRowCopy.faceName(sector: sector?.name,
                                        face: sector == nil ? r : regions.faces(of: r, mesh: project.viewerMesh).first ?? r)
    }

    /// Shape [Curves | Stamp]: an either/or. Stamp lands ONE stamp on the face (the library's
    /// first that fits it, at its centre) unless the face kept one from before.
    public func setShape(_ r: Int, _ shape: String) {
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
    /// that fits the face — at the face centre.
    func defaultStamp(_ r: Int) -> FlexibleStampPlacement? {
        guard let lib = library, let f = settings.face(r) else { return nil }
        let u = stack(r)?.uExtentMM ?? 0, v = stack(r)?.vExtentMM ?? 0
        let fits: (FlexibleStampShape) -> Bool = { s in
            let n = s.naturalSizeMM
            return u <= 0 || (n.width <= 0.9 * u && n.length <= 0.9 * v)
        }
        let pick = ["palm", "thumb", "fingertip"].compactMap { lib.shape($0) }.first(where: fits)
            ?? lib.stamps.first { $0.shape != "whole_face" && fits($0) } ?? lib.stamps.first
        return pick.map { FlexibleStamps.place($0, uExtentMM: u, vExtentMM: v, weightKg: f.weightKg) }
    }

    /// Replace the face's stamp (a library shape, or an imported mask), keeping where it sits.
    public func setStamp(_ r: Int, source: FlexibleStampSource, shape: FlexibleStampShape?) {
        let u = stack(r)?.uExtentMM ?? 0, v = stack(r)?.vExtentMM ?? 0
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

    /// Where the Stamp face's stamp presses, per column 0…1 (its laid grid at each column
    /// centre, over the grid's peak) — nil for a Curves face or before the grid is laid.
    public func stampFootprint(_ r: Int) -> [Double]? {
        guard let f = settings.face(r), let p = f.activeStamp, let g = stampGrids[p.id], let st = stack(r),
              g.cellMM > 0, let peak = g.valuesMPa.max(), peak > 0 else { return nil }
        return st.columns.map { c in
            let iu = Int(((c.uMM - g.originU) / g.cellMM).rounded(.down))
            let iv = Int(((c.vMM - g.originV) / g.cellMM).rounded(.down))
            guard iu >= 0, iv >= 0, iu < g.nu, iv < g.nv else { return 0 }
            return g.valuesMPa[iv * g.nu + iu] / peak
        }
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
                if let p {
                    FlexRow(FlexibleRowCopy.stampSize(widthMM: p.widthMM, lengthMM: p.lengthMM),
                            info: FlexibleRowCopy.Info.stampSize, id: "flexible-row-stamp-size") {
                        FlexEditPill(key: "stamp-size-\(region)", title: FlexibleRowCopy.stampWidthTitle, unit: "mm",
                                     value: p.widthMM, padTarget: $padTarget) { v in
                            model.updateStamp(region) { q in
                                let k = q.widthMM > 0 ? v / q.widthMM : 1
                                q.widthMM = v; q.lengthMM *= k
                            }
                        }
                    }
                    FlexRow(FlexibleRowCopy.stampTurn(p.rotationDeg), info: FlexibleRowCopy.Info.stampTurn,
                            id: "flexible-row-stamp-turn") {
                        Button {
                            model.updateStamp(region) { $0.rotationDeg = ($0.rotationDeg + 90).truncatingRemainder(dividingBy: 360) }
                        } label: {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.Color.textPrimary.color)
                                .frame(width: 44, height: 32)
                                .background(Capsule().fill(DS.Surface.valuePill.color))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("flexible-stamp-turn")
                    }
                    FlexRow(FlexibleRowCopy.stampPress, info: FlexibleRowCopy.Info.stampPress, id: "flexible-row-stamp-press") {
                        FlexChips(options: FlexibleRowCopy.stampPressOptions, selection: p.rigid ? "rigid" : "soft",
                                  id: "flexible-stamp-press", equalWidths: false) { v in
                            model.updateStamp(region) { $0.rigid = v == "rigid" }
                        }
                        .fixedSize()
                    }
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
    /// The stamp's centre when the drag began (nil: not dragging).
    @State private var dragging: SIMD2<Double>?

    struct Placed { let region: Int; let stamp: FlexibleStampPlacement }

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
        ZStack {
            Canvas { ctx, size in
                var clip = Path(CGRect(origin: .zero, size: size))
                for r in keepOut { clip.addRect(r) }
                ctx.clip(to: clip, style: FillStyle(eoFill: true))
                for s in placed {
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
                if let q = screen(world(s.region, s.stamp.centreU, s.stamp.centreV)),
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
