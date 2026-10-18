// FlexibleOnModelLayer — what the main Flexible page draws ON the part for Selections (task 2026-09-29-flexible-screens,
// round 7, batch R7-D2: his mockup pick 2, B1 "on the face"). Hook H32 mounts it on this stage only, inside the chrome that
// hides under a full-screen page.
//
//   * the picked face — and the pending ones — wear a 2 pt WHITE edge light (80 %); no face fill and no group colour on the
//     model (his fixed rule: no role colours on the main page's model);
//   * the face CHIP (FlexibleFaceChip), at its automatic spot or where he dragged it (his change a — kept per face for the
//     session; an orbit moves only the leader), with its LEADER from the chip's nearest edge to the face's centre (a 6 pt
//     dot), re-aimed every frame;
//   * the picked prism's NUMBERED handles (FlexibleLatticeHandles): the depth disc ⇕ at the prism's floor with its box
//     ("25.0 mm" — the list's number, one store), and in FACE scope the expand disc ↔ with its box ("+0.0 mm"); a tap on a
//     box opens the numeric keypad, a vertical drag scrubs, the disc drags along the prism;
//   * under [Prisms], every other lattice face-prism's number, read-only — a tap on one picks that face;
//   * the (i)'s card (his change b — FlexibleFaceStatsPopover), beside the (i) it opened from;
//   * the one message (a Load's "Set its weight on the Squish page", a delete's [Undo]).
// ONLY the chip, the discs, the boxes, the numbers and the message take a touch — the layer itself is hit-transparent, so
// orbit and pinch still reach the part (FlexibleRound7SelectionsHostedTests: a tap on an empty point reaches what is under).

import SwiftUI
import simd
import TopOptDesign

public struct FlexibleOnModelLayer: View {
    @ObservedObject var main: FlexibleMainStage
    @ObservedObject var project: ProjectModel
    @ObservedObject private var ui: FlexibleFaceChipState
    @ObservedObject private var chrome: FlexibleChromeState
    @ObservedObject private var geometry: FlexibleChromeGeometry
    let projection: CameraProjection?
    let settle: simd_quatf
    let bottomClearance: CGFloat
    let cards: [String: LatticeFaceCard]
    let groupCards: [UUID: LatticeFaceCard]
    let cardsChanged: () -> Void

    /// The chip's drag: live while a finger moves it (resets by itself when the gesture ends or is cancelled), and where it
    /// started. The spot itself is written to `ui.spots` every frame, so a cancelled drag still keeps where it got to.
    @GestureState private var chipGesture = false
    @State private var dragAnchor: CGPoint?

    public init(main: FlexibleMainStage, project: ProjectModel, projection: CameraProjection?, settle: simd_quatf,
                bottomClearance: CGFloat, cards: [String: LatticeFaceCard], groupCards: [UUID: LatticeFaceCard],
                cardsChanged: @escaping () -> Void) {
        self.main = main
        self.project = project
        self._ui = ObservedObject(wrappedValue: main.faceUI)
        self._chrome = ObservedObject(wrappedValue: main.chrome)
        self._geometry = ObservedObject(wrappedValue: main.chromeGeometry)
        self.projection = projection
        self.settle = settle
        self.bottomClearance = bottomClearance
        self.cards = cards
        self.groupCards = groupCards
        self.cardsChanged = cardsChanged
    }

    public var body: some View {
        GeometryReader { g in
            let origin = g.frame(in: .global).origin
            let v = g.size
            let scope = FlexibleFacePick.validated(main.facePick, project: project).scope
            let frame = viewFrame
            ZStack(alignment: .topLeading) {
                if let frame { edgeLights(scope, frame: frame, origin: origin, under: listUnder(origin: origin, viewport: v)) }
                if let frame, chrome.allowsFaceChip, !scope.isNone {
                    let placed = place(scope, frame: frame, origin: origin, viewport: v)
                    leaders(placed.targets, chip: placed.rect, under: listUnder(origin: origin, viewport: v))
                    handles(scope, frame: frame, origin: origin, under: listUnder(origin: origin, viewport: v))
                    FlexibleFaceChip(main: main, project: project, ui: ui, scope: scope, cardsChanged: cardsChanged)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: placed.rect.width)
                        .background(GeometryReader { c in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["faceChip": c.frame(in: .global)])
                        }.allowsHitTesting(false))
                        .offset(x: placed.rect.minX, y: placed.rect.minY)
                        .highPriorityGesture(chipDragGesture(scope, placed: placed.rect, viewport: v))
                        .opacity(chipGesture ? 0.92 : 1)
                        .onChange(of: chipGesture) { live in
                            if !live { finishChipDrag(scope, viewport: v, keepOut: placed.keepOut) }
                        }
                }
                if let frame, main.prismsOn, chrome.allowsFaceChip || chrome.open == nil { prismNumbers(scope, frame: frame, origin: origin, viewport: v) }
                if let info = ui.info { statsCard(info, origin: origin, viewport: v) }
                if let t = ui.toast { toast(t, viewport: v) }
            }
            .frame(width: v.width, height: v.height, alignment: .topLeading)
        }
        .onChange(of: chrome.open) { open in
            // a card opened over the chip (one card at a time): the (i) and the asks go with it
            if open != nil, open != .faceChip, open != .keypad { ui.closeTransient() }
        }
        .onChange(of: ui.padTarget) { t in
            if t != nil { chrome.show(.keypad) } else { chrome.close(.keypad); if !main.facePick.scope.isNone { chrome.show(.faceChip) } }
        }
    }

    // MARK: the view's projector

    private var viewFrame: LatticeBandChipFrame? {
        guard let projection, let c = (main.mesh(project, on: .lattice) ?? project.viewerMesh)?.bounds.center else { return nil }
        return LatticeBandChipFrame(projection: projection, modelCentre: c, modelRotation: settle)
    }

    private func local(_ p: CGPoint?, _ origin: CGPoint) -> CGPoint? { p.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) } }

    // MARK: the faces' model points

    /// The faces the scope lights (their B-rep face ids).
    private func litFaces(_ scope: FlexibleFaceScope) -> [FaceID] {
        func faces(_ t: FlexibleFreeFace) -> [FaceID] {
            switch t {
            case let .face(f): return [f]
            case let .region(r): return project.surfaceResolvedFaces(r).sorted()
            }
        }
        switch scope {
        case .none: return []
        case let .pending(ts): return ts.flatMap(faces)
        case let .face(_, ref):
            switch ref {
            case let .face(_, f): return [f]
            case let .region(_, r): return project.surfaceResolvedFaces(r).sorted()
            case .primitive: return []
            }
        case let .group(g):
            guard let grp = project.selection.groups.first(where: { $0.id == g }) else { return [] }
            return grp.faces + grp.regionIDs.flatMap { project.surfaceResolvedFaces($0).sorted() }
        }
    }

    /// Where each lit thing's leader ends: a plane's face centre (#354's own), else the face's centroid.
    private func targets(_ scope: FlexibleFaceScope) -> [SIMD3<Float>] {
        let planes = main.pickedPlanes(project)
        switch scope {
        case let .face(_, ref):
            if let p = planes.first(where: { $0.ref == ref }) { return [p.handle.planeOrigin] }
        case .group:
            let fromPlanes = planes.map(\.handle.planeOrigin)
            var covered = Set<FaceID>()
            for p in planes {
                switch p.ref {
                case let .face(_, f): covered.insert(f)
                case let .region(_, r): covered.formUnion(project.surfaceResolvedFaces(r))
                case .primitive: break
                }
            }
            let rest = litFaces(scope).filter { !covered.contains($0) }.compactMap { project.viewerMesh?.faceCentroid($0) }
            if !fromPlanes.isEmpty || !rest.isEmpty { return fromPlanes + rest }
        default: break
        }
        return litFaces(scope).compactMap { project.viewerMesh?.faceCentroid($0) }
    }

    // MARK: the open list's frame (what the part's drawings stay out of)

    /// ★ LOOKED AT (13" portrait: Face 2's edge light and its leader ran across the open list; a handle sat on its boxes): the
    /// open Selections list's frame, local — the edge light and the leaders are clipped out of it, a handle under it is not
    /// drawn (its face's boxes are right there in the list). nil while the list is minimised or not measured.
    private func listUnder(origin: CGPoint, viewport v: CGSize) -> CGRect? {
        guard let m = geometry.selectionsFrame, m.height > FlexibleChromeLayout.selectionsPillHeight + 4 else { return nil }
        return m.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    /// `ctx` clipped to everything but `under`.
    private static func clipOut(_ ctx: inout GraphicsContext, _ under: CGRect?, _ size: CGSize) {
        guard let u = under else { return }
        var p = Path(CGRect(origin: .zero, size: size))
        p.addRect(u)
        ctx.clip(to: p, style: FillStyle(eoFill: true))
    }

    // MARK: the edge light

    @ViewBuilder private func edgeLights(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, under: CGRect?) -> some View {
        let segs = FlexibleFaceOutline.edges(faces: litFaces(scope), mesh: project.viewerMesh)
        if !segs.isEmpty {
            Canvas { ctx, size in
                Self.clipOut(&ctx, under, size)
                var path = Path()
                for s in segs {
                    guard let a = local(frame.project(s.0), origin), let b = local(frame.project(s.1), origin) else { continue }
                    path.move(to: a); path.addLine(to: b)
                }
                ctx.stroke(path, with: .color(Color.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: the chip's spot

    private struct Placed { let rect: CGRect; let targets: [CGPoint]; let keepOut: [CGRect] }

    private func place(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> Placed {
        let kind = FlexibleFaceChip.kind(scope, project: project, lastGroup: main.facePick.lastGroup)
        let size = FlexibleFaceChipLayout.size(kind)
        let pts = targets(scope).compactMap { local(frame.project($0), origin) }
        let keep = keepOuts(scope, frame: frame, origin: origin, viewport: v)
        let anchor: CGPoint? = pts.isEmpty ? nil : CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                                                         y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        var r: CGRect
        if let key = scope.chipKey, let spot = ui.spots[key] {
            r = FlexibleFaceChipLayout.clamped(CGRect(origin: spot, size: size), viewport: v)
        } else {
            r = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, keepOut: keep)
        }
        return Placed(rect: r, targets: pts, keepOut: keep)
    }

    private func keepOuts(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> [CGRect] {
        // ★ LOOKED AT (13" portrait: after a join the list grew under a chip placed against its old frame): while the list is
        // open the whole left panel column is kept clear (the mockup's own rule), the measured pill while it is minimised
        let measured = geometry.selectionsFrame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let sel: CGRect? = (measured.map { $0.height > FlexibleChromeLayout.selectionsPillHeight + 4 } ?? true)
            ? FlexibleFaceChipLayout.selectionsColumn(viewport: v) : measured
        let legend = main.legendCard(viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)?.frame
        let panel = FlexibleMainPlayerSlot.openPanel(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)
        let player = FlexibleMainPlayerSlot.frame(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)
        let own = handleRects(scope, frame: frame, origin: origin)
        return FlexibleFaceChipLayout.keepOuts(viewport: v, selections: sel, legend: legend, panel: panel, player: player, own: own)
    }

    private func chipDragGesture(_ scope: FlexibleFaceScope, placed: CGRect, viewport v: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($chipGesture) { _, live, _ in live = true }
            .onChanged { d in
                guard let key = scope.chipKey else { return }
                if dragAnchor == nil { dragAnchor = placed.origin; ui.info = nil }
                ui.spots[key] = FlexibleFaceChipLayout.dragged(anchor: dragAnchor ?? placed.origin, translation: d.translation,
                                                               size: placed.size, viewport: v).origin
            }
    }

    /// The drag is over (ended or cancelled): let go over a keep-out, the chip slides to the nearest clear spot.
    private func finishChipDrag(_ scope: FlexibleFaceScope, viewport v: CGSize, keepOut: [CGRect]) {
        defer { dragAnchor = nil }
        guard dragAnchor != nil, let key = scope.chipKey, let spot = ui.spots[key] else { return }
        let size = FlexibleFaceChipLayout.size(FlexibleFaceChip.kind(scope, project: project, lastGroup: main.facePick.lastGroup))
        ui.spots[key] = FlexibleFaceChipLayout.released(CGRect(origin: spot, size: size), viewport: v, keepOut: keepOut).origin
    }

    // MARK: the leader

    private func leaders(_ pts: [CGPoint], chip: CGRect, under: CGRect?) -> some View {
        Canvas { ctx, size in
            Self.clipOut(&ctx, under, size)
            for p in pts {
                let s = FlexibleFaceChipLayout.leaderStart(chip: chip, target: p)
                var path = Path()
                path.move(to: s); path.addLine(to: p)
                ctx.stroke(path, with: .color(Color.white.opacity(0.8)), lineWidth: 1)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(Color.white.opacity(0.8)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: the handles

    private struct HandleSpot { let plane: ProjectModel.LatticeDepthPlane; let floor: CGPoint; let deeper: CGPoint?; let knob: CGPoint?; let out: CGPoint? }

    private func handleSpots(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint) -> [HandleSpot] {
        main.pickedPlanes(project).compactMap { plane in
            let geo = FlexibleLatticeHandles.geometry(plane, expandMM: project.latticeExpandMM(plane.ref))
            guard let f = local(frame.project(geo.floor), origin) else { return nil }
            var knob: CGPoint? = nil
            if case .face = scope, let k = geo.expandKnob, let kp = local(frame.project(k), origin) {
                knob = LatticeSlabExpand.separated(knob: kp, from: f)
            }
            return HandleSpot(plane: plane, floor: f, deeper: local(frame.project(geo.deeper), origin), knob: knob,
                              out: geo.expandOut.flatMap { local(frame.project($0), origin) })
        }
    }

    private func handleRects(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint) -> [CGRect] {
        handleSpots(scope, frame: frame, origin: origin).flatMap { h -> [CGRect] in
            var r = [CGRect(x: h.floor.x - 22, y: h.floor.y - 22, width: 44 + 8 + 96, height: 44)]
            if let k = h.knob { r.append(CGRect(x: k.x - 22, y: k.y - 22, width: 44 + 8 + 96, height: 44)) }
            return r
        }
    }

    @ViewBuilder private func handles(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, under: CGRect?) -> some View {
        if let gid = scope.groupID, !FlexibleFaceCommits.isLocked(gid, project) {
            let group: Bool = { if case .group = scope { return true } else { return false } }()
            ForEach(handleSpots(scope, frame: frame, origin: origin), id: \.plane.id) { h in
                if !Self.underList(h.floor, under) { depthHandle(h, group: group ? gid : nil) }
                if let k = h.knob, !Self.underList(k, under) { expandHandle(h, at: k) }
            }
        }
    }

    /// A handle (its disc and its box to the right) would sit on the open list.
    static func underList(_ p: CGPoint, _ under: CGRect?) -> Bool {
        guard let u = under else { return false }
        let r = CGRect(x: p.x - FlexibleLatticeHandles.hit / 2, y: p.y - FlexibleLatticeHandles.hit / 2,
                       width: FlexibleLatticeHandles.hit + DS.Space.s + 92, height: FlexibleLatticeHandles.hit)
        return r.intersects(u)
    }

    private func depthHandle(_ h: HandleSpot, group: UUID?) -> some View {
        let ref = h.plane.ref, gid = h.plane.groupID
        let key = "handle-depth-\(ref.key)"
        let mm = project.latticeSlabDepthMM(ref, in: gid)
        let candidates = LatticeDepthDetent.candidates(topology: project.lattice.topologyID,
                                                       minExtrudableWidthMM: project.printParams.strutLineWidthMM)
        var spec = FlexibleSelectionsList.depthSpec
        spec.value = mm
        return HStack(spacing: DS.Space.s) {
            FlexibleHandleDisc(symbol: "arrow.up.and.down", active: ui.dragging == key)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { d in
                        if ui.dragging == nil { main.beginHandleDrag(project, key: key); ui.seed = mm }
                        let r = FlexibleLatticeHandles.dragDepth(seed: ui.seed ?? mm, translation: d.translation, floor: h.floor,
                                                                 deeper: h.deeper, candidates: candidates, held: ui.held)
                        ui.held = r.held
                        var s = main.facePick
                        FlexibleFaceCommits.writeDepth(r.mm, ref: group == nil ? ref : nil, group: gid, project: project, session: &s)
                        main.facePick = s
                    }
                    .onEnded { _ in main.endHandleDrag(project, cardsChanged: cardsChanged); ui.seed = nil })
                .accessibilityLabel("Depth handle")
                .accessibilityIdentifier("flexible-handle-depth-\(ref.key)")
            FlexNumberBox(key: key, title: "Depth", spec: spec, padTarget: $ui.padTarget, twin: "list-depth-\(ref.key)",
                          shownOverride: FlexibleLatticeHandles.boxNumber(mm, signed: false)) { v in
                var s = main.facePick
                FlexibleFaceCommits.setDepth(v, ref: group == nil ? ref : nil, group: gid, project: project, session: &s)
                main.facePick = s
                cardsChanged()
            }
        }
        .fixedSize()
        .position(x: h.floor.x + (FlexibleLatticeHandles.hit + DS.Space.s + 92) / 2 - FlexibleLatticeHandles.hit / 2, y: h.floor.y)
    }

    private func expandHandle(_ h: HandleSpot, at k: CGPoint) -> some View {
        let ref = h.plane.ref, gid = h.plane.groupID
        let key = "handle-expand-\(ref.key)"
        let mm = project.latticeExpandMM(ref)
        var spec = FlexibleSelectionsList.expandSpec
        spec.value = mm
        return HStack(spacing: DS.Space.s) {
            FlexibleHandleDisc(symbol: "arrow.left.and.right", active: ui.dragging == key)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { d in
                        if ui.dragging == nil { main.beginHandleDrag(project, key: key); ui.seed = mm }
                        project.writeLatticeExpandMM(ref, mm: FlexibleLatticeHandles.dragExpand(seed: ui.seed ?? mm, translation: d.translation,
                                                                                                knob: k, outward: h.out))
                    }
                    .onEnded { _ in main.endHandleDrag(project, cardsChanged: cardsChanged); ui.seed = nil })
                .accessibilityLabel("Expand handle")
                .accessibilityIdentifier("flexible-handle-expand-\(ref.key)")
            FlexNumberBox(key: key, title: "Expand", spec: spec, padTarget: $ui.padTarget, allowsNegative: true,
                          twin: "list-expand-\(ref.key)", shownOverride: FlexibleLatticeHandles.boxNumber(mm, signed: true)) { v in
                FlexibleFaceCommits.setExpand(v, ref: ref, group: gid, project: project)
                cardsChanged()
            }
        }
        .fixedSize()
        .position(x: k.x + (FlexibleLatticeHandles.hit + DS.Space.s + 92) / 2 - FlexibleLatticeHandles.hit / 2, y: k.y)
    }

    // MARK: [Prisms]' numbers (read-only; a tap picks that face)

    @ViewBuilder private func prismNumbers(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> some View {
        let picked = main.pickedPlaneKeys(project) ?? []
        let tags = FlexiblePrismNumbers.place(
            project.latticeDepthPlanes().filter { $0.role == .include && !picked.contains($0.ref.key) && !project.groupView.isHidden($0.groupID) }
                .compactMap { p -> (ProjectModel.LatticeDepthPlane, CGPoint)? in local(frame.project(p.handle.anchor), origin).map { (p, $0) } },
            viewport: v, keepOut: keepOuts(scope, frame: frame, origin: origin, viewport: v))
        ForEach(tags, id: \.0.id) { t in
            Button { main.pickFace(t.0.ref, group: t.0.groupID, project: project) } label: {
                Text(FlexibleLatticeHandles.depthText(project.latticeSlabDepthMM(t.0.ref, in: t.0.groupID)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(DS.Color.textSecondary.color)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(Capsule().fill(DS.Surface.valuePill.color))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(t.1)
            .accessibilityIdentifier("flexible-prism-number-\(t.0.ref.key)")
        }
    }

    // MARK: the (i)'s card

    private func statsCard(_ info: FlexibleFaceChipState.Info, origin: CGPoint, viewport v: CGSize) -> some View {
        let depth = project.latticeSlabDepthMM(info.ref, in: info.group)
        let card = FlexibleFaceStats.card(info.ref, group: info.group, cards: cards, groupCards: groupCards)
        let rows = FlexibleFaceStats.rows(card: card, depthMM: depth, held: project.force.isProtected(info.group),
                                          reaches: project.latticeReachesTheRun(info.ref))
        let a = info.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        let w = FlexibleFaceStatsCard.width, h: CGFloat = rows == nil ? 96 : 210
        var x = a.maxX + 8
        if x + w > v.width - 8 { x = a.minX - 8 - w }
        x = min(max(8, x), v.width - 8 - w)
        let y = min(max(8, a.midY - h / 2), v.height - 8 - h)
        return FlexibleFaceStatsCard(title: project.latticeSelectableName(info.ref) + " · lattice", rows: rows) { ui.info = nil }
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["statsCard": g.frame(in: .global)]) }
                .allowsHitTesting(false))
            .offset(x: x, y: y)
    }

    // MARK: the message

    private func toast(_ t: FlexibleFaceChipState.Toast, viewport v: CGSize) -> some View {
        HStack(spacing: DS.Space.m) {
            Text(t.text).font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.Color.textPrimary.color).lineLimit(1)
            if t.undo {
                Button { main.undoDelete(project: project, cardsChanged: cardsChanged) } label: {
                    Text(FlexibleSelectionsCopy.undo).font(.system(size: 13.5, weight: .bold)).foregroundStyle(DS.Color.accent.color)
                        .padding(.horizontal, DS.Space.s).frame(height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["toastUndo": g.frame(in: .global)]) }
                    .allowsHitTesting(false))
                .accessibilityIdentifier("flexible-toast-undo")
            }
        }
        .padding(.horizontal, DS.Space.l).frame(height: 44)
        .background(Capsule().fill(DS.Surface.toast.color).overlay(Capsule().strokeBorder(DS.Color.strokePanel.color, lineWidth: 1)))
        .dsShadow(DS.Shadow.toast)
        .fixedSize()
        .position(x: (PageChrome.edge + PageChrome.panelWidth + v.width) / 2,
                  y: v.height - FlexibleChromeLayout.barClearance - PageChrome.gap - 22)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-toast")
    }
}

/// The edge light's segments: each face's boundary (edges used by one of its triangles only), in model space.
enum FlexibleFaceOutline {
    static func edges(faces: [FaceID], mesh: ViewerMesh?) -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let m = mesh, !faces.isEmpty, !m.faceIDs.isEmpty else { return [] }
        let want = Set(faces)
        struct K: Hashable { let x: Int32, y: Int32, z: Int32 }
        func key(_ p: SIMD3<Float>) -> K { K(x: Int32((p.x * 1000).rounded()), y: Int32((p.y * 1000).rounded()), z: Int32((p.z * 1000).rounded())) }
        func pos(_ i: Int) -> SIMD3<Float> { SIMD3(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]) }
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        for f in want {
            var count: [[K]: (Int, SIMD3<Float>, SIMD3<Float>)] = [:]
            var t = 0
            while t + 2 < m.indices.count {
                let tri = t / 3
                if tri < m.faceIDs.count, m.faceIDs[tri] == f {
                    let v = (0..<3).map { pos(Int(m.indices[t + $0])) }
                    for (a, b) in [(v[0], v[1]), (v[1], v[2]), (v[2], v[0])] {
                        let ka = key(a), kb = key(b)
                        let k = (ka.x, ka.y, ka.z) < (kb.x, kb.y, kb.z) ? [ka, kb] : [kb, ka]
                        let c = count[k]?.0 ?? 0
                        count[k] = (c + 1, a, b)
                    }
                }
                t += 3
            }
            for (_, e) in count where e.0 == 1 { out.append((e.1, e.2)) }
        }
        return out
    }
}

/// [Prisms]' read-only numbers: each at its floor, greedily kept off the keep-outs and off each other.
enum FlexiblePrismNumbers {
    static func place(_ cands: [(ProjectModel.LatticeDepthPlane, CGPoint)], viewport v: CGSize, keepOut: [CGRect]) -> [(ProjectModel.LatticeDepthPlane, CGPoint)] {
        var taken: [CGRect] = []
        var out: [(ProjectModel.LatticeDepthPlane, CGPoint)] = []
        for (p, at) in cands {
            let r = CGRect(x: at.x - 34, y: at.y - 13, width: 68, height: 26)
            guard r.minX >= 8, r.minY >= 8, r.maxX <= v.width - 8, r.maxY <= v.height - 8 else { continue }
            if keepOut.contains(where: { $0.intersects(r) }) || taken.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) { continue }
            taken.append(r)
            out.append((p, at))
        }
        return out
    }
}
