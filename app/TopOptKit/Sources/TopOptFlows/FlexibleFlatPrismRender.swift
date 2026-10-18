// FlexibleFlatPrismRender — the edge/corner FLAT PRISM on the Squish page (task 2026-09-29-flexible-screens, round 7 batch
// R7-E1). His words, 2026-10-18 (binding): "There should be a prism that the user can drag to show how far it can squish in … It
// should also be able to be angled up or down based on the user's choice." — "drag the prism's ARROW — a handle on the edge/corner
// prism's arrow tilts it toward one face or the other; it starts at halfway (core's halfway) and snaps back there; the angle shows
// on the handle (tap to type, keypad)." His rules: one visible line per setting (≤ 44); numbers are boxes (tap = keypad, drag =
// scrub); 44 pt targets; icons only for views.
//
// ★ WHAT HE SEES (the Squish page only — the main Lattice page shows the lattice only, his img2 rule):
//   * THE WEDGE (`items`): the flat prism, TRUE SIZE (× 1, whatever the page's k): the footprints on the member faces carried
//     along the arrow onto the plane — faint face-prism purple at rest, the contact look while a handle is dragged; every press
//     of the open group faint with the Prisms view.
//   * ITS TRACES on each face, dashed in the group colour (`FlexibleFlatPrismOverlay`), and THE ARROW from its tail outside the
//     part to its head on the flat face, through the edge's midpoint (a corner's vertex) — dashed (not sent yet), ▼ at the deep
//     end when twisted; the other presses of the group dimmed.
//   * THE DEPTH CHIP at the arrow's head: the face's own glass chip "↓ 3.0 mm" — drag it along the arrow (looking along it: a
//     scrub, down = deeper), detents every 0.5 mm; a tap opens the keypad.
//   * THE ANGLE KNOB at the arrow's tail (a 32 pt disc, a 44 pt target) and its two boxes "↕ 0.0°" "↔ 0.0°": a drag ACROSS the
//     edge tilts (up/down), ALONG it twists (left/right) — one 2-D drag, each angle snapping to exactly 0 within 3°; while held, a
//     guide arc per angle with ticks at 0 and at the limits and the faces named at the tilt arc's ends. A stop says why for 2 s.
//   * While a handle moves only the preview moves (FlexibleStageModel.flatPreview): nothing is written, no scene opens; the release
//     is ONE edit and one undo step (setFlatCut). The handles are disabled while that commit runs.
// ★ ONE STORE PER NUMBER: the chip, the card's boxes, the on-model boxes and the wedge read FlexibleFlatPrism.cut(of:) (or the
// drag's preview) — never a copy.

import CoreGraphics
import Foundation
import SwiftUI
import simd
import TopOptDesign
import TopOptKit

@MainActor
enum FlexibleFlatPrismRender {
    /// ★ RED CONTROL only (FlexibleFlatPrismTests): the wedge drawn × the page's k.
    static var controlTimesK = false
    private static var cache: (key: String, items: [ClearanceRenderItem])?

    /// ★ THE WEDGES the Squish page draws: the working press's (the open edges tab's selected press) — faint at rest, the contact
    /// look while a handle is dragged; with the Prisms view, every press of the open edges group, faint. True size.
    static func items(model m: FlexibleStageModel, k: Double) -> [ClearanceRenderItem] {
        guard let mesh = m.project.viewerMesh else { return [] }
        let working = FlexibleFlatPrismUI.workingPress(m)
        var ids: [UUID] = working.map { [$0] } ?? []
        if m.views.contains(.prisms), let g = FlexibleFlatPrismUI.openEdgesGroup(m) {
            for id in g.presses where !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { return [] }
        let dragging = m.flatPreview != nil
        var key = "\(mesh.signature.contentHash)|\(k)|\(controlTimesK)|\(dragging)|\(working?.uuidString ?? "-")"
        for id in ids {
            if let c = m.flatCut(id) { key += "|\(id.uuidString)\(FlexiblePressAim.bits(c.direction))\(c.depthMM.bitPattern)" }
            if let p = m.press(id) { key += "\(p.regions)" }
        }
        if let c = cache, c.key == key { return c.items }
        var out: [ClearanceRenderItem] = []
        for id in ids {
            guard let p = m.press(id), let st = p.strip, var c = m.flatCut(id) else { continue }
            if controlTimesK { c.depthMM *= k }
            let cuts = FlexibleFlatPrism.memberCuts(st, c)
            var polys: [[SIMD3<Double>]] = []
            for (i, mb) in st.members.enumerated() {
                polys += FlexibleFlatPrism.footprint(FlexibleEdgeStrips.triangles(face: mb.face, mesh: mesh), cuts[i])
            }
            guard let sh = FlexibleFlatPrism.wedge(polys, c) else { continue }
            let v = ClearanceVolume.shell(faceID: -1, shell: sh)
            if id == working, dragging {
                out.append(ClearanceRenderItem(volume: v, selected: true, tint: FlexibleStageStyle.facePrismTint))
            } else {
                let bright = id == working && m.views.contains(.prisms)
                out.append(ClearanceRenderItem(volume: v, selected: id == working, tint: FlexibleStageStyle.facePrismTint,
                                               faceAlpha: bright ? FlexibleDepthPrism.viewSelectedFaceAlpha : FlexibleDepthPrism.restFaceAlpha,
                                               edgeAlpha: bright ? FlexibleDepthPrism.viewSelectedEdgeAlpha : FlexibleDepthPrism.restEdgeAlpha))
            }
        }
        cache = (key, out)
        return out
    }
}

/// The flat prism's on-model pieces, as values (the overlay, the card, the evidence and the tests read the same).
@MainActor
enum FlexibleFlatPrismUI {
    /// What the chip and the boxes show.
    struct Shown: Equatable {
        let depthMM: Double
        let chipText: String
        let tilt: Double
        let twist: Double
    }

    /// The open tab's edges group (nil: a faces tab, [Model], [New], or the views hide every overlay).
    static func openEdgesGroup(_ m: FlexibleStageModel) -> FlexibleSqueezeGroup? {
        guard case .group(let gid) = m.rail, let g = m.railGroup(gid), g.kind == .edges else { return nil }
        if FlexibleStagePage.overlaysHidden(views: m.views, edgePick: m.edgePick != nil) { return nil }
        return g
    }

    /// ★ The press he works on: the open edges tab's selected press (its first when none).
    static func workingPress(_ m: FlexibleStageModel) -> UUID? {
        guard let g = openEdgesGroup(m) else { return nil }
        if let id = m.selectedPress, g.presses.contains(id), m.press(id)?.strip != nil { return id }
        return g.presses.first { m.press($0)?.strip != nil }
    }

    /// The halfway frame of a press (its angles' axes); nil without a halfway or core's build direction.
    static func frame(_ m: FlexibleStageModel, _ id: UUID) -> FlexibleFlatPrismAngles.Frame? {
        guard let p = m.press(id), let st = p.strip, let d0 = FlexibleFlatPrism.halfway(of: p) else { return nil }
        return FlexibleFlatPrismAngles.frame(st, d0: d0, up: m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1))
    }

    /// ★ ONE STORE PER NUMBER: the depth and the two angles as every box shows them (the preview while dragged).
    static func shown(model m: FlexibleStageModel, press id: UUID) -> Shown? {
        guard let c = m.flatCut(id) else { return nil }
        let a: (theta: Double, phi: Double) = frame(m, id).map { FlexibleFlatPrismAngles.decompose($0, c.direction) } ?? (theta: 0, phi: 0)
        return Shown(depthMM: c.depthMM, chipText: "\u{2193} " + String(format: "%.1f mm", c.depthMM), tilt: a.theta, twist: a.phi)
    }

    /// The face name of member k ("Face 3", his Surface sector's name).
    static func memberName(_ m: FlexibleStageModel, _ st: FlexibleStrip, _ k: Int) -> String {
        guard k >= 0, k < st.members.count else { return "a face" }
        let mb = st.members[k]
        if let r = m.project.faceRegions.region(mb.root), r.isCut { return FlexibleRowCopy.faceName(sector: r.name, face: mb.face) }
        return "Face \(mb.face)"
    }

    /// The arrow: through the edge's midpoint (a corner's vertex), its head H on the plane, its tail outside the part.
    struct Arrow: Equatable {
        let anchor: SIMD3<Double>
        let head: SIMD3<Double>
        let tail: SIMD3<Double>
        /// The deep end (an edge twisted off halfway); nil untwisted.
        let deepEnd: SIMD3<Double>?
        /// The edge's direction (an edge), for the knob's place when looking down the arrow.
        let along: SIMD3<Double>?
    }

    static func arrow(_ st: FlexibleStrip, _ c: FlexibleFlatPrism.Cut, lengthMM: Double) -> Arrow {
        var anchor = st.members.first?.origin ?? c.apex
        var along: SIMD3<Double>? = nil
        var deep: SIMD3<Double>? = nil
        if let l = FlexibleFlatPrism.line(st) {
            anchor = l.origin + l.dir * ((l.s0 + l.s1) / 2)
            along = l.dir
            if Swift.abs(simd_dot(l.dir, c.direction)) > 1e-6 { deep = c.apex }
        }
        return Arrow(anchor: anchor, head: c.onPlane(anchor), tail: anchor - c.direction * lengthMM, deepEnd: deep, along: along)
    }

    /// The last arrow the overlay drew, in the page's points (the hosted tests read it).
    static var lastArrowEnds: (head: CGPoint, tail: CGPoint)?
    /// The last keypad a flat-prism box opened (the hosted tests read it).
    static var lastPad: String?

    /// ★ THE HANDLES' PLACES: the chip at the head; the knob at the tail — or, closer than 56 pt to the head on screen (looking
    /// down the arrow, D-AP-13), 56 pt from it along the edge's screen direction (vertical without one); its two boxes beside it,
    /// on the side away from the head. Each a 44 pt target at least.
    struct Layout: Equatable {
        let chip: CGPoint
        let knob: CGPoint
        let boxes: CGPoint
    }
    static let knobGap: CGFloat = 56
    static func layout(head: CGPoint, tail: CGPoint, edge: CGVector?) -> Layout {
        var knob = tail
        let dx = tail.x - head.x, dy = tail.y - head.y
        // clear of the chip (86 × 44 about the head) whatever way the knob sits from it: 56 pt at least
        func clear(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat { Swift.max(knobGap, abs(ux) * 72 + abs(uy) * 56) }
        let l0 = hypot(dx, dy)
        if l0 < clear(l0 > 1e-3 ? dx / l0 : 0, l0 > 1e-3 ? dy / l0 : 1) {
            var e = edge ?? CGVector(dx: 0, dy: 1)
            let len = hypot(e.dx, e.dy)
            e = len > 1e-3 ? CGVector(dx: e.dx / len, dy: e.dy / len) : CGVector(dx: 0, dy: 1)
            if l0 > 1e-3, e.dx * dx + e.dy * dy < 0 { e = CGVector(dx: -e.dx, dy: -e.dy) }   // on the tail's side
            let g = clear(e.dx, e.dy)
            knob = CGPoint(x: head.x + e.dx * g, y: head.y + e.dy * g)
        }
        // the boxes: beside the knob, across the head–knob line (their 100 × 92 card clear of the knob's 44 pt)
        var ax = knob.x - head.x, ay = knob.y - head.y
        let l = hypot(ax, ay)
        if l > 1e-3 { ax /= l; ay /= l } else { ax = 0; ay = 1 }
        let px = -ay, py = ax
        let boxes = CGPoint(x: knob.x + px * 92 + ax * 24, y: knob.y + py * 92 + ay * 24)
        return Layout(chip: head, knob: knob, boxes: boxes)
    }

    /// ★ THE CAMERA on [Done] and on selecting a press — D-AP-13 as ruled (the reviewer's 2026-10-10 ruling 4: "the view DOWN THE
    /// ARROW"): the gizmo view nearest down the arrow. (Asked of the reviewer at R7-E1's start: the view 25–50° off it, so the arrow
    /// and its handles do not collapse to one point; until a ruling, the knob is drawn ≥ 56 pt from the head — `layout`.)
    static func camera(press p: FlexiblePress, settle: simd_quatf) -> GizmoRegion? {
        FlexibleFixPopup.cameraRegion(load: p.direction, settle: settle)
    }
}

// MARK: - the overlay (traces, arrows) and the handles (chip, knob, boxes)

struct FlexibleFlatPrismOverlay: View {
    @ObservedObject var model: FlexibleStageModel
    let projection: CameraProjection?
    let keepOut: [CGRect]
    var clip: [CGRect]? = nil
    @Binding var padTarget: String?

    @State private var chipDrag: ChipDrag?
    @State private var knobDrag: KnobDrag?
    @State private var held: LatticeDepthDetent.Candidate?
    @State private var stop: (text: String, at: CGPoint, until: Date)?
    @GestureState private var dragging = false

    struct ChipDrag { let press: UUID; let startMM: Double; let perMM: CGVector?; let maxMM: Double; let minMM: Double; let maxStop: FlexibleFlatPrismAngles.Stop? }
    struct KnobDrag {
        let press: UUID
        let start: (theta: Double, phi: Double)
        let jac: (a: CGVector, b: CGVector)?   // screen points per degree of θ and of φ
        let arcs: (tilt: [CGPoint], twist: [CGPoint], ticks: [CGPoint], tags: [(String, CGPoint)])
    }

    /// Test diagnostics only: why the overlay drew nothing the last time.
    static var lastWhy = ""

    var body: some View {
        let _ = { Self.lastWhy = projection == nil ? "no projection" : FlexibleFlatPrismUI.openEdgesGroup(model) == nil ? "no edges tab" : "drawn" }()
        if let proj = projection, let g = FlexibleFlatPrismUI.openEdgesGroup(model), let mesh = model.project.viewerMesh {
            let working = FlexibleFlatPrismUI.workingPress(model)
            let colour = model.groupColour(g)
            let len = FlexiblePressAim.arrowLength(boundsDiagonalMM: Double(simd_length(mesh.bounds.max - mesh.bounds.min)))
            let arrows: [(UUID, FlexibleFlatPrismUI.Arrow, [[SIMD3<Double>]])] = g.presses.compactMap { id in
                guard let p = model.press(id), let st = p.strip, let c = model.flatCut(id) else { return nil }
                let cuts = FlexibleFlatPrism.memberCuts(st, c)
                var traces: [[SIMD3<Double>]] = []
                for (i, mb) in st.members.enumerated() {
                    traces += FlexibleFlatPrism.traces(FlexibleFlatPrism.footprint(FlexibleEdgeStrips.triangles(face: mb.face, mesh: mesh), cuts[i]), c)
                }
                return (id, FlexibleFlatPrismUI.arrow(st, c, lengthMM: len), traces)
            }
            ZStack {
                Canvas { ctx, size in
                    if let clip { FlexibleChromeClip.apply(&ctx, size: size, holes: clip) }
                    for (id, a, traces) in arrows {
                        let on = id == working
                        var tp = Path()
                        for t in traces where t.count == 2 {
                            if let p0 = proj.project(SIMD3<Float>(t[0])), let p1 = proj.project(SIMD3<Float>(t[1])) { tp.move(to: p0); tp.addLine(to: p1) }
                        }
                        ctx.stroke(tp, with: .color(colour.color.opacity(on ? 1 : 0.45)),
                                   style: StrokeStyle(lineWidth: on ? 3 : 2, lineCap: .round, dash: [7, 5]))
                        guard let h = proj.project(SIMD3<Float>(a.head)), let t = proj.project(SIMD3<Float>(a.tail)) else { continue }
                        var ap = Path()
                        ap.move(to: t); ap.addLine(to: h)
                        ctx.stroke(ap, with: .color(colour.color.opacity(on ? 1 : 0.45)),
                                   style: StrokeStyle(lineWidth: on ? 3.5 : 2.5, lineCap: .round, dash: [9, 6]))   // dashed: not sent yet
                        // the head
                        let ang = atan2(h.y - t.y, h.x - t.x)
                        var head = Path()
                        head.move(to: h)
                        head.addLine(to: CGPoint(x: h.x - 13 * cos(ang - 0.42), y: h.y - 13 * sin(ang - 0.42)))
                        head.addLine(to: CGPoint(x: h.x - 13 * cos(ang + 0.42), y: h.y - 13 * sin(ang + 0.42)))
                        head.closeSubpath()
                        ctx.fill(head, with: .color(colour.color.opacity(on ? 1 : 0.45)))
                        if let d = a.deepEnd, let q = proj.project(SIMD3<Float>(d)) {
                            ctx.draw(Text("\u{25BC}").font(.system(size: 13, weight: .bold)).foregroundColor(colour.color), at: CGPoint(x: q.x, y: q.y - 12))
                        }
                    }
                    // the knob's guide arcs while it is held
                    if let k = knobDrag {
                        for arc in [k.arcs.tilt, k.arcs.twist] where arc.count > 1 {
                            var p = Path(); p.addLines(arc)
                            ctx.stroke(p, with: .color(DS.Color.textPrimary.color.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 4]))
                        }
                        for t in k.arcs.ticks { ctx.fill(Path(ellipseIn: CGRect(x: t.x - 3.5, y: t.y - 3.5, width: 7, height: 7)), with: .color(DS.Color.textPrimary.color)) }
                        for (s, at) in k.arcs.tags {
                            ctx.draw(Text(s).font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Color.textPrimary.color), at: at)
                        }
                    }
                }
                .allowsHitTesting(false)
                // ★ a tap on an arrow selects its press (the others, dimmed)
                ForEach(arrows.filter { $0.0 != working }.map(\.0), id: \.self) { id in
                    if let a = arrows.first(where: { $0.0 == id })?.1, let h = proj.project(SIMD3<Float>(a.head)),
                       let t = proj.project(SIMD3<Float>(a.tail)) {
                        let mid = CGPoint(x: (h.x + t.x) / 2, y: (h.y + t.y) / 2)
                        if FlexibleDepthChipLayout.visible(mid, keepOut: keepOut, viewport: proj.viewportSize) {
                            Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
                                .onTapGesture { model.selectedPress = id }
                                .position(mid)
                                .accessibilityLabel("Select \(model.press(id)?.strip?.label ?? "the press")")
                        }
                    }
                }
                if let id = working, let a = arrows.first(where: { $0.0 == id })?.1 { handles(id, a, proj) }
                if let s = stop, Date() < s.until {
                    Text(s.text).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Color.textPrimary.color)
                        .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(DS.Surface.panel.color.opacity(0.92)))
                        .position(x: s.at.x, y: s.at.y - 40)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("flexible-flat-stop")
                }
            }
            .onChange(of: dragging) { d in if !d { finishDrags() } }
        }
    }

    // MARK: the handles

    @ViewBuilder private func handles(_ id: UUID, _ a: FlexibleFlatPrismUI.Arrow, _ proj: CameraProjection) -> some View {
        if let p = model.press(id), let st = p.strip, let h = proj.project(SIMD3<Float>(a.head)), let t = proj.project(SIMD3<Float>(a.tail)),
           let shown = FlexibleFlatPrismUI.shown(model: model, press: id) {
            let edge: CGVector? = a.along.flatMap { e in
                guard let p0 = proj.project(SIMD3<Float>(a.anchor)), let p1 = proj.project(SIMD3<Float>(a.anchor + e * 10)) else { return nil }
                return CGVector(dx: p1.x - p0.x, dy: p1.y - p0.y)
            }
            // ★ the handles keep off the chrome: a head under it (the mini in portrait, the panel over the arrow's head) nudges
            // the whole set the least way out (≤ 36 pt), so the chip still sits at the head
            let lay: FlexibleFlatPrismUI.Layout = {
                let base = FlexibleFlatPrismUI.layout(head: h, tail: t, edge: edge)
                if FlexibleDepthChipLayout.visible(base.chip, keepOut: keepOut, viewport: proj.viewportSize) || chipDrag != nil { return base }
                for r in [CGFloat(18), 27, 36] {
                    for k in 0..<8 {
                        let a = Double(k) * .pi / 4 - .pi / 2
                        let off = CGVector(dx: r * CGFloat(cos(a)), dy: r * CGFloat(sin(a)))
                        let c = CGPoint(x: h.x + off.dx, y: h.y + off.dy)
                        if FlexibleDepthChipLayout.visible(c, keepOut: keepOut, viewport: proj.viewportSize) {
                            return FlexibleFlatPrismUI.layout(head: c, tail: CGPoint(x: t.x + off.dx, y: t.y + off.dy), edge: edge)
                        }
                    }
                }
                return base
            }()
            let label = st.label
            let busy = model.flatCommitting == id
            let _ = { FlexibleFlatPrismUI.lastArrowEnds = (h, t) }()
            let showChip = FlexibleDepthChipLayout.shows(lay.chip, dragging: chipDrag != nil, keepOut: keepOut, viewport: proj.viewportSize)
            let showKnob = FlexibleDepthChipLayout.shows(lay.knob, dragging: knobDrag != nil, keepOut: keepOut, viewport: proj.viewportSize)
            let showBoxes = FlexibleDepthChipLayout.visible(lay.boxes, keepOut: keepOut, viewport: proj.viewportSize)
            Color.clear.frame(width: 1, height: 1)
                .background(mark("flatPrism-\(label)", CGRect(x: min(h.x, t.x), y: min(h.y, t.y), width: max(1, abs(h.x - t.x)), height: max(1, abs(h.y - t.y)))))
                .background(mark("flatArrow-\(label)", CGRect(x: min(h.x, t.x), y: min(h.y, t.y), width: max(1, abs(h.x - t.x)), height: max(1, abs(h.y - t.y)))))
                .allowsHitTesting(false)
            if showChip {
                // a TAP opens the keypad; a drag (past 4 pt) moves the plane along the arrow — the drag wins once it travels
                Button {
                    FlexibleFlatPrismUI.lastPad = "flat-depth-\(id.uuidString)"
                    padTarget = "flat-depth-\(id.uuidString)"
                } label: { chip(shown.chipText, active: chipDrag != nil) }
                    .buttonStyle(.plain)
                    .background(GeometryReader { g in Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["flatDepthChip-\(label)": g.frame(in: .global)]) }.allowsHitTesting(false))
                    .modifier(FlexPadCommit(key: "flat-depth-\(id.uuidString)", padTarget: $padTarget,
                                            config: .init(title: label + " \u{00B7} " + FlexibleRowCopy.flatDeepestRow, unit: "mm", allowsDecimal: true),
                                            seed: shown.depthMM) { v in commitTyped(id, depth: v) })
                    .highPriorityGesture(chipGesture(id, st, a, proj).updating($dragging) { _, s, _ in s = true })
                    .position(lay.chip)
                    .disabled(busy)
                    .accessibilityIdentifier("flexible-flat-depth-chip")
            }
            if showKnob {
                FlexibleHandleDisc(symbol: "arrow.up.and.down.and.arrow.left.and.right", active: knobDrag != nil)
                    .contentShape(Rectangle())
                    .background(GeometryReader { g in Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["flatKnob-\(label)": g.frame(in: .global)]) }.allowsHitTesting(false))
                    .gesture(knobGesture(id, st, a, proj).updating($dragging) { _, s, _ in s = true })
                    .position(lay.knob)
                    .disabled(busy)
                    .accessibilityLabel("Tilt and twist \(label)")
                    .accessibilityIdentifier("flexible-flat-knob")
            }
            if showBoxes {
                VStack(spacing: 4) {
                    angleBox(id, st, key: "flat-tilt-\(id.uuidString)", glyph: "\u{2195}", value: shown.tilt, tilt: true)
                        .background(GeometryReader { g in Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["flatTiltBox-\(label)": g.frame(in: .global)]) }.allowsHitTesting(false))
                    angleBox(id, st, key: "flat-twist-\(id.uuidString)", glyph: "\u{2194}", value: shown.twist, tilt: false)
                        .background(GeometryReader { g in Color.clear.preference(key: FlexibleViewMarksKey.self, value: ["flatTwistBox-\(label)": g.frame(in: .global)]) }.allowsHitTesting(false))
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.Surface.panel.color.opacity(0.82)))
                .position(lay.boxes)
                .disabled(busy)
            }
        }
    }

    private func mark(_ key: String, _ r: CGRect) -> some View {
        Color.clear.preference(key: FlexibleViewMarksKey.self, value: [key: r])
    }

    /// The face's own glass chip (FlexibleDepthChips') — over a dark capsule, so its number reads on the wedge's bright flat face.
    private func chip(_ text: String, active: Bool) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(Capsule().fill(DS.Surface.panel.color.opacity(0.6)))
            .liquidGlass(LiquidGlass.Tint.frost(FlexibleStageStyle.facePrismKnob, intensity: active ? 0.85 : 0.55), in: Capsule(), specular: active ? 1.3 : 1)
            .contentShape(Capsule())
    }

    private func angleBox(_ id: UUID, _ st: FlexibleStrip, key: String, glyph: String, value: Double, tilt: Bool) -> some View {
        HStack(spacing: 3) {
            Text(glyph).font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Color.textSecondary.color)
            FlexNumberBox(key: key, title: st.label + " \u{00B7} " + (tilt ? FlexibleRowCopy.flatTiltWord(corner: st.kind == .corner) : FlexibleRowCopy.flatTwistWord(corner: st.kind == .corner)),
                          spec: FlexNumberSpec(value: (value * 10).rounded() / 10, unit: "\u{00B0}", step: 1, range: -89...89, decimals: 1),
                          padTarget: $padTarget, allowsNegative: true, twin: key + "-card", hitHeight: 44) { v in
                FlexibleFlatPrismUI.lastPad = key
                commitTyped(id, angle: v, tilt: tilt)
            }
        }
    }

    // MARK: drags

    private func chipGesture(_ id: UUID, _ st: FlexibleStrip, _ a: FlexibleFlatPrismUI.Arrow, _ proj: CameraProjection) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                guard model.flatCommitting == nil, let c = model.flatCut(id) else { return }
                if chipDrag == nil {
                    ClearanceHaptics.grab()
                    held = nil
                    let p0 = proj.project(SIMD3<Float>(a.head)), p1 = proj.project(SIMD3<Float>(a.head + c.direction * 10))
                    var per: CGVector? = nil
                    if let p0, let p1 {
                        let v = CGVector(dx: (p1.x - p0.x) / 10, dy: (p1.y - p0.y) / 10)
                        let along = proj.ray(throughViewPoint: g.startLocation).map { Double(abs(simd_dot($0.dir, SIMD3<Float>(c.direction)))) } ?? 1
                        if !FlexibleDepthChipLayout.needsScrub(rayAlongLoad: along, projectedPointsPer10MM: hypot(v.dx, v.dy) * 10) { per = v }
                    }
                    let r = FlexibleFlatPrismAngles.depthRange(st, d: c.direction, limits: model.flatLimits(id, withLattice: true))
                    chipDrag = ChipDrag(press: id, startMM: c.depthMM, perMM: per, maxMM: r.max, minMM: r.min, maxStop: r.maxStop)
                }
                guard let d = chipDrag else { return }
                let raw: Double
                if let v = d.perMM {
                    raw = d.startMM + Double((g.translation.width * v.dx + g.translation.height * v.dy) / max(1e-6, v.dx * v.dx + v.dy * v.dy))
                } else {
                    raw = FlexibleDepthChipLayout.scrubMM(seedMM: d.startMM, translation: g.translation)
                }
                let r = FlexibleDepthPrism.resolve(rawMM: max(d.minMM, raw), latticeMM: d.maxMM, held: held)
                if r.didSnap { ClearanceHaptics.detent() }
                held = r.held
                if raw > d.maxMM + 0.25, let s = d.maxStop { say(FlexibleFlatPrismAngles.line(s, strip: st, name: { FlexibleFlatPrismUI.memberName(model, st, $0) }), at: g.location) }
                if raw < d.minMM - 0.25 { say(FlexibleFlatPrismAngles.line(d.minMM > FlexibleFlatPrism.minDepthMM ? .farEnd : .shallow, strip: st, name: { _ in "" }), at: g.location) }
                model.previewFlatCut(id, depthMM: max(d.minMM, r.mm), direction: nil)
            }
            .onEnded { _ in finishDrags() }
    }

    private func knobGesture(_ id: UUID, _ st: FlexibleStrip, _ a: FlexibleFlatPrismUI.Arrow, _ proj: CameraProjection) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(FlexibleStageSpace.name))
            .onChanged { g in
                guard model.flatCommitting == nil, let c = model.flatCut(id), let f = FlexibleFlatPrismUI.frame(model, id) else { return }
                let len = simd_length(a.anchor - a.tail)
                func tail(_ th: Double, _ ph: Double) -> CGPoint? {
                    proj.project(SIMD3<Float>(a.anchor - FlexibleFlatPrismAngles.compose(f, theta: th, phi: ph) * len))
                }
                if knobDrag == nil {
                    ClearanceHaptics.grab()
                    let s = FlexibleFlatPrismAngles.decompose(f, c.direction)
                    var jac: (CGVector, CGVector)? = nil
                    if let t0 = tail(s.theta, s.phi), let ta = tail(s.theta + 1, s.phi), let tb = tail(s.theta, s.phi + 1) {
                        let va = CGVector(dx: ta.x - t0.x, dy: ta.y - t0.y), vb = CGVector(dx: tb.x - t0.x, dy: tb.y - t0.y)
                        if abs(va.dx * vb.dy - va.dy * vb.dx) > 0.5 { jac = (va, vb) }
                    }
                    // the guide arcs: each angle across its range, the other held; ticks at 0 and at the limits
                    let lim = model.flatLimits(id, withLattice: false)
                    let tmin = FlexibleFlatPrismAngles.limit(st, frame: f, h: c.depthMM, at: s, tilt: true, sign: -1, limits: lim).deg
                    let tmax = FlexibleFlatPrismAngles.limit(st, frame: f, h: c.depthMM, at: s, tilt: true, sign: 1, limits: lim).deg
                    let pmin = FlexibleFlatPrismAngles.limit(st, frame: f, h: c.depthMM, at: s, tilt: false, sign: -1, limits: lim).deg
                    let pmax = FlexibleFlatPrismAngles.limit(st, frame: f, h: c.depthMM, at: s, tilt: false, sign: 1, limits: lim).deg
                    let ta = (0...24).compactMap { tail(tmin + (tmax - tmin) * Double($0) / 24, s.phi) }
                    let tb = (0...24).compactMap { tail(s.theta, pmin + (pmax - pmin) * Double($0) / 24) }
                    let ticks = [tail(0, s.phi), tail(tmin, s.phi), tail(tmax, s.phi), tail(s.theta, 0), tail(s.theta, pmin), tail(s.theta, pmax)].compactMap { $0 }
                    var tags: [(String, CGPoint)] = []
                    let named = f.corner ? FlexibleFlatPrismUI.memberName(model, st, f.tiltMember) : FlexibleFlatPrismUI.memberName(model, st, 0)
                    let other = f.corner ? "sides" : FlexibleFlatPrismUI.memberName(model, st, 1)
                    if let p = tail(tmax, s.phi) { tags.append((named, CGPoint(x: p.x, y: p.y - 14))) }
                    if let p = tail(tmin, s.phi) { tags.append((other, CGPoint(x: p.x, y: p.y - 14))) }
                    knobDrag = KnobDrag(press: id, start: s, jac: jac, arcs: (ta, tb, ticks, tags))
                }
                guard let k = knobDrag else { return }
                var dth: Double, dph: Double
                if let j = k.jac {
                    // solve translation = dθ·a + dφ·b
                    let det = Double(j.a.dx * j.b.dy - j.a.dy * j.b.dx)
                    dth = Double(g.translation.width * j.b.dy - g.translation.height * j.b.dx) / det
                    dph = Double(j.a.dx * g.translation.height - j.a.dy * g.translation.width) / det
                } else {
                    // looking down the arrow: the trackball (0.5° per point)
                    dph = Double(g.translation.width) * FlexiblePressAim.trackballDegPerPoint
                    dth = Double(-g.translation.height) * FlexiblePressAim.trackballDegPerPoint
                }
                let want = (FlexibleFlatPrismAngles.snapped(k.start.theta + dth), FlexibleFlatPrismAngles.snapped(k.start.phi + dph))
                let r = FlexibleFlatPrismAngles.clamp(st, frame: f, h: c.depthMM, from: k.start, to: want,
                                                      limits: model.flatLimits(id, withLattice: false))
                if let s = r.stop { say(FlexibleFlatPrismAngles.line(s, strip: st, name: { FlexibleFlatPrismUI.memberName(model, st, $0) }), at: g.location) }
                let prev = model.flatPreview.map { FlexibleFlatPrismAngles.decompose(f, $0.direction) }
                if (r.theta == 0 && (prev?.theta ?? 1) != 0) || (r.phi == 0 && (prev?.phi ?? 1) != 0) { ClearanceHaptics.detent() }
                model.previewFlatCut(id, depthMM: nil, direction: FlexibleFlatPrismAngles.compose(f, theta: r.theta, phi: r.phi))
            }
            .onEnded { _ in finishDrags() }
    }

    private func say(_ text: String, at p: CGPoint) {
        if stop?.text != text { ClearanceHaptics.detent() }
        stop = (text, p, Date().addingTimeInterval(2))
    }

    /// The release: ONE commit (setFlatCut), once — the gesture's end and its cancel both land here.
    private func finishDrags() {
        guard chipDrag != nil || knobDrag != nil else { return }
        let id = chipDrag?.press ?? knobDrag?.press
        chipDrag = nil
        knobDrag = nil
        held = nil
        ClearanceHaptics.release()
        guard let id, model.flatPreview?.press == id else { return }
        Task { @MainActor in
            if let why = await model.commitFlatPreview(id) { model.toast = why }
        }
    }

    private func commitTyped(_ id: UUID, depth: Double) {
        guard let p = model.press(id) else { return }
        Task { @MainActor in
            if let why = await model.setFlatCut(id, depthMM: depth, direction: model.flatCut(id)?.direction ?? p.direction, snap: p.snap) {
                model.toast = why
            }
        }
    }

    private func commitTyped(_ id: UUID, angle: Double, tilt: Bool) {
        Task { @MainActor in if let why = await model.setFlatAngle(id, degrees: angle, tilt: tilt) { model.toast = why } }
    }
}
