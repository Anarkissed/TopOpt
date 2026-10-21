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
//     ("25.0 mm" — the list's number, one store), and in FACE scope the expand disc + with its box ("+0.0 mm") — ★ U21: each
//     a unit kept ≥ 24 pt from the other, each box on the side away from the other handle (FlexibleLatticeHandles.layout); a tap on a
//     box opens the numeric keypad, a vertical drag scrubs, the disc drags along the prism;
//   * under [Prisms], every other lattice face-prism's number, read-only — a tap on one picks that face;
//   * the (i)'s card (his change b — FlexibleFaceStatsPopover): below the chip when the chip's (i) opened it, beside the
//     list's (i) otherwise (★ the review of R7-D2: it sat on the chip); its numbers are the lattice drawn at that face;
//   * the one message (a Load's "Set its weight on the Squish page", a delete's [Undo]) — above the player when Play is on
//     (★ the review of R7-D2: it was drawn on the player's own band).
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
    /// ★ the review of R7-D2: the chip's drawn size, for the scope it was measured on — placement takes it when the chip grows
    /// past its kind's estimate (the role line, a confirm), so it never runs onto a keep-out, the face or the (i)'s card.
    @State private var chipMeasuredKey: String?
    @State private var chipMeasuredSize: CGSize = .zero
    /// ★ U21 HANDLE-GAP: each handle box's REAL width as drawn (the layout places the units with it; the estimate until then).
    @State private var handleBoxWidths: [String: CGFloat] = [:]

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
            let chipPlaced: Placed? = frame.flatMap { f in chrome.allowsFaceChip && !scope.isNone ? place(scope, frame: f, origin: origin, viewport: v) : nil }
            ZStack(alignment: .topLeading) {
                if let frame { edgeLights(scope, frame: frame, origin: origin, under: listUnder(origin: origin, viewport: v)) }
                if let frame, let placed = chipPlaced {
                    leaders(placed.targets, chip: placed.rect, under: listUnder(origin: origin, viewport: v))
                    handles(scope, frame: frame, origin: origin, viewport: v, under: listUnder(origin: origin, viewport: v))
                    FlexibleFaceChip(main: main, project: project, ui: ui, scope: scope, cardsChanged: cardsChanged)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: placed.rect.width)
                        .background(GeometryReader { c in
                            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["faceChip": c.frame(in: .global)])
                                .onAppear { noteChip(scope, c.size) }
                                .onChange(of: c.size) { noteChip(scope, $0) }
                        }.allowsHitTesting(false))
                        .offset(x: placed.rect.minX, y: placed.rect.minY)
                        .highPriorityGesture(chipDragGesture(scope, placed: placed.rect, viewport: v))
                        .opacity(chipGesture ? 0.92 : 1)
                        .onChange(of: chipGesture) { live in
                            if !live { finishChipDrag(scope, viewport: v, tiers: placed.tiers) }
                        }
                }
                if let frame, main.prismsOn, chrome.allowsFaceChip || chrome.open == nil { prismNumbers(scope, frame: frame, origin: origin, viewport: v) }
                if let info = ui.info {
                    let fromChip = info.key.hasPrefix("c-")
                    statsCard(info, origin: origin, viewport: v, chip: fromChip ? chipPlaced?.rect : nil,
                              // the (i)'s card is passing: it may sit over the face's own handles while open (11" portrait: kept
                              // off them, it went onto the corner pair), never over the page's panels
                              keepOut: (frame.map { keepOuts(scope, frame: $0, origin: origin, viewport: v, ownHandles: false) } ?? [])
                                + (fromChip ? [] : chipPlaced.map { [$0.rect] } ?? []))
                }
                if let t = ui.toast { toast(t, viewport: v, chip: chipPlaced?.rect) }
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
            // the lit faces' outline on screen (the projector's space is the page's, as `local` reads it) — the tests read it
            .background(Color.clear.preference(key: FlexibleKeepOutKey.self,
                                               value: Self.outlineBounds(segs, frame: frame).map { ["faceOutline": $0] } ?? [:])
                .allowsHitTesting(false))
        }
    }

    /// The lit faces' outline on screen (the projector's space), or nil when none of it projects.
    static func outlineBounds(_ segs: [(SIMD3<Float>, SIMD3<Float>)], frame: LatticeBandChipFrame) -> CGRect? {
        var r: CGRect?
        for s in segs {
            for q in [s.0, s.1] {
                guard let p = frame.project(q) else { continue }
                let pr = CGRect(x: p.x, y: p.y, width: 0, height: 0)
                r = r.map { $0.union(pr) } ?? pr
            }
        }
        return r
    }

    // MARK: the chip's spot

    private struct Placed { let rect: CGRect; let targets: [CGPoint]; let keepOut: [CGRect]; var tiers: [[CGRect]] = [] }

    private func place(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> Placed {
        let kind = FlexibleFaceChip.kind(scope, project: project, lastGroup: main.facePick.lastGroup)
        var size = FlexibleFaceChipLayout.size(kind)
        if let k = scope.chipKey, chipMeasuredKey == k, chipMeasuredSize.height > size.height { size.height = chipMeasuredSize.height }
        let pts = targets(scope).compactMap { local(frame.project($0), origin) }
        let keep = keepOuts(scope, frame: frame, origin: origin, viewport: v)
        // ★ R7-D3: where nothing is clear of the list's whole column (the mini in portrait), the list's whole reach decides — then
        // without the face's own handles (the chip may cover its own handles, never the page's chrome) — then the list as drawn
        // (the mini's tall new-face chip, 229 pt, fits neither above nor below the reach; its list does not grow under a new face)
        let tiers: [[CGRect]] = [keep] + (geometry.selectionsFrame == nil ? [] : [
            keepOuts(scope, frame: frame, origin: origin, viewport: v, listColumn: false, listReach: true),
            keepOuts(scope, frame: frame, origin: origin, viewport: v, listColumn: false, listReach: true, ownHandles: false),
            keepOuts(scope, frame: frame, origin: origin, viewport: v, listColumn: false, ownHandles: false),
        ])
        let anchor: CGPoint? = pts.isEmpty ? nil : CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                                                         y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        var r: CGRect
        if let key = scope.chipKey, let spot = ui.spots[key] {
            r = FlexibleFaceChipLayout.clamped(CGRect(origin: spot, size: size), viewport: v)
        } else {
            // ★ the review of R7-D2 (13"/11" portrait: chip M sat on Face 3's own lattice; img2's front camera: on the pad's
            // front): the automatic spot also keeps off the lit faces' outline on screen — a drag may put it anywhere
            let face = Self.outlineBounds(FlexibleFaceOutline.edges(faces: litFaces(scope), mesh: project.viewerMesh), frame: frame)
                .map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            r = FlexibleFaceChipLayout.auto(size: size, anchor: anchor, viewport: v, tiers: tiers,
                                            soft: FlexibleFaceChipLayout.faceKeepOut(face, viewport: v))
        }
        return Placed(rect: r, targets: pts, keepOut: keep, tiers: tiers)
    }

    private func noteChip(_ scope: FlexibleFaceScope, _ s: CGSize) {
        guard s.height > 0 else { return }
        if chipMeasuredKey != scope.chipKey { chipMeasuredKey = scope.chipKey }
        if abs(chipMeasuredSize.height - s.height) > 0.5 || abs(chipMeasuredSize.width - s.width) > 0.5 { chipMeasuredSize = s }
    }

    private func keepOuts(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize,
                          listColumn: Bool = true, listReach: Bool = false, ownHandles: Bool = true) -> [CGRect] {
        // ★ LOOKED AT (13" portrait: after a join the list grew under a chip placed against its old frame): while the list is
        // open the whole left panel column is kept clear (the mockup's own rule), the measured pill while it is minimised
        // ★ the review of R7-D2: [Prisms]' small numbers keep off the list as it is drawn (`listColumn: false` — the whole column
        // dropped Face 5's number at 11" portrait, though it sat above the list)
        let measured = geometry.selectionsFrame.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let open = measured.map { $0.height > FlexibleChromeLayout.selectionsPillHeight + 4 } ?? true
        // ★ R7-D3: the chip's second tier keeps out of the open list's whole reach (a measure lags a frame as the list grows)
        let sel: CGRect? = listColumn && open ? FlexibleFaceChipLayout.selectionsColumn(viewport: v)
            : (listReach && open ? measured.map { FlexibleFaceChipLayout.listReach(measured: $0, viewport: v) } : measured)
        let legend = main.legendCard(viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)?.frame
        let panel = FlexibleMainPlayerSlot.openPanel(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)
        let player = FlexibleMainPlayerSlot.frame(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)
        let own = ownHandles ? handleRects(scope, frame: frame, origin: origin, viewport: v) : []
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
    private func finishChipDrag(_ scope: FlexibleFaceScope, viewport v: CGSize, tiers: [[CGRect]]) {
        defer { dragAnchor = nil }
        guard dragAnchor != nil, let key = scope.chipKey, let spot = ui.spots[key] else { return }
        let size = FlexibleFaceChipLayout.size(FlexibleFaceChip.kind(scope, project: project, lastGroup: main.facePick.lastGroup))
        ui.spots[key] = FlexibleFaceChipLayout.released(CGRect(origin: spot, size: size), viewport: v, tiers: tiers).origin   // ★ R7-D3: the tiers
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

    /// ★ U21 HANDLE-GAP: a picked prism's handles — the depth disc on its floor, the TRUE projected expand knob (`rawKnob`,
    /// what the drag's direction reads) and the units as the layout placed them (the expand disc drawn at `layout.expand`).
    private struct HandleSpot {
        let plane: ProjectModel.LatticeDepthPlane; let floor: CGPoint; let deeper: CGPoint?; let rawKnob: CGPoint?; let out: CGPoint?
        let layout: FlexibleLatticeHandles.Layout
    }

    private func handleSpots(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> [HandleSpot] {
        let under = listUnder(origin: origin, viewport: v)
        return main.pickedPlanes(project).compactMap { plane in
            let geo = FlexibleLatticeHandles.geometry(plane, expandMM: project.latticeExpandMM(plane.ref))
            guard let f = local(frame.project(geo.floor), origin) else { return nil }
            var raw: CGPoint? = nil
            if case .face = scope, let k = geo.expandKnob, let kp = local(frame.project(k), origin) { raw = kp }
            let est = FlexibleLatticeHandles.boxWidthEstimate
            let layout = FlexibleLatticeHandles.layout(floor: f, rawKnob: raw,
                                                       depthBox: handleBoxWidths["handle-depth-\(plane.ref.key)"] ?? est,
                                                       expandBox: handleBoxWidths["handle-expand-\(plane.ref.key)"] ?? est,
                                                       viewport: v, keepOut: under.map { [$0] } ?? [])
            return HandleSpot(plane: plane, floor: f, deeper: local(frame.project(geo.deeper), origin), rawKnob: raw,
                              out: geo.expandOut.flatMap { local(frame.project($0), origin) }, layout: layout)
        }
    }

    /// The handles' touch units (disc + box, 44 pt tall) — what the chip keeps off and what `underList` tests: one set of rects.
    private func handleRects(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> [CGRect] {
        handleSpots(scope, frame: frame, origin: origin, viewport: v).flatMap { h -> [CGRect] in
            [h.layout.depth.rect] + (h.layout.expand.map { [$0.rect] } ?? [])
        }
    }

    @ViewBuilder private func handles(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize,
                                      under: CGRect?) -> some View {
        if let gid = scope.groupID, !FlexibleFaceCommits.isLocked(gid, project) {
            let group: Bool = { if case .group = scope { return true } else { return false } }()
            ForEach(handleSpots(scope, frame: frame, origin: origin, viewport: v), id: \.plane.id) { h in
                if !Self.underList(h.layout.depth.rect, under) { depthHandle(h, group: group ? gid : nil) }
                if let e = h.layout.expand, !Self.underList(e.rect, under) { expandHandle(h, unit: e) }
            }
        }
    }

    /// A handle's unit (its disc and its box, on whichever side) would sit on the open list.
    static func underList(_ unit: CGRect, _ under: CGRect?) -> Bool {
        guard let u = under else { return false }
        return unit.intersects(u)
    }

    /// The disc and its box in the unit's order (box on the left: [box][disc]), centred on the unit's rect, its real width
    /// measured for the next layout, its disc's and unit's frames published (the hosted tests click them).
    @ViewBuilder private func handleUnit<Disc: View, Box: View>(_ unit: FlexibleLatticeHandles.Unit, key: String,
                                                                 disc: Disc, box: Box) -> some View {
        let measuredDisc = disc.background(GeometryReader { g in
            Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["handleDisc-\(key)": g.frame(in: .global)])
        }.allowsHitTesting(false))
        HStack(spacing: FlexibleLatticeHandles.boxGap) {
            if unit.boxOnLeft { box; measuredDisc } else { measuredDisc; box }
        }
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear
                .preference(key: FlexibleKeepOutKey.self, value: ["handleUnit-\(key)": g.frame(in: .global)])
                .onAppear { noteHandleWidth(key, g.size.width) }
                .onChange(of: g.size.width) { noteHandleWidth(key, $0) }
        }.allowsHitTesting(false))
        .position(x: unit.rect.midX, y: unit.rect.midY)
    }

    private func noteHandleWidth(_ key: String, _ unitWidth: CGFloat) {
        let box = unitWidth - FlexibleLatticeHandles.hit - FlexibleLatticeHandles.boxGap
        guard box > 0, abs((handleBoxWidths[key] ?? 0) - box) > 0.5 else { return }
        handleBoxWidths[key] = box
    }

    private func depthHandle(_ h: HandleSpot, group: UUID?) -> some View {
        let ref = h.plane.ref, gid = h.plane.groupID
        let key = "handle-depth-\(ref.key)"
        let mm = project.latticeSlabDepthMM(ref, in: gid)
        let candidates = LatticeDepthDetent.candidates(topology: project.lattice.topologyID,
                                                       minExtrudableWidthMM: project.printParams.strutLineWidthMM)
        var spec = FlexibleSelectionsList.depthSpec
        spec.value = mm
        return handleUnit(h.layout.depth, key: key,
            disc: FlexibleHandleDisc(symbol: FlexibleLatticeHandles.depthSymbol, active: ui.dragging == key)
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
                .accessibilityIdentifier("flexible-handle-depth-\(ref.key)"),
            box: FlexNumberBox(key: key, title: "Depth", spec: spec, padTarget: $ui.padTarget, twin: "list-depth-\(ref.key)",
                          shownOverride: FlexibleLatticeHandles.boxNumber(mm, signed: false), hitHeight: FlexNumberBox.target) { v in
                var s = main.facePick
                FlexibleFaceCommits.setDepth(v, ref: group == nil ? ref : nil, group: gid, project: project, session: &s)
                main.facePick = s
                cardsChanged()
            })
    }

    private func expandHandle(_ h: HandleSpot, unit: FlexibleLatticeHandles.Unit) -> some View {
        let ref = h.plane.ref, gid = h.plane.groupID
        let key = "handle-expand-\(ref.key)"
        let mm = project.latticeExpandMM(ref)
        var spec = FlexibleSelectionsList.expandSpec
        spec.value = mm
        // ★ U21 EXPAND-DRAG-DIR: the drag reads the TRUE knob → out (the disc is drawn pushed out; RED: the drawn disc)
        let dragKnob = FlexibleLatticeHandles.controlOldDrag || FlexibleLatticeHandles.controlDrawnDiscWiring ? unit.disc : h.rawKnob
        let changed: @MainActor (CGSize) -> Void = { t in
            if ui.dragging == nil { main.beginHandleDrag(project, key: key); ui.seed = mm }
            project.writeLatticeExpandMM(ref, mm: FlexibleLatticeHandles.dragExpand(seed: ui.seed ?? mm, translation: t,
                                                                                    knob: dragKnob, outward: h.out))
        }
        let ended: @MainActor () -> Void = { main.endHandleDrag(project, cardsChanged: cardsChanged); ui.seed = nil }
        if FlexibleLatticeHandles.recordLiveDrags { FlexibleLatticeHandles.liveDrags[key] = .init(axis: .init(raw: h.rawKnob, out: h.out, drawn: unit.disc),
                                                      changed: changed, ended: ended) }
        return handleUnit(unit, key: key,
            disc: FlexibleHandleDisc(symbol: FlexibleLatticeHandles.expandSymbol, active: ui.dragging == key)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { d in changed(d.translation) }
                    .onEnded { _ in ended() })
                .accessibilityLabel("Expand handle")
                .accessibilityIdentifier("flexible-handle-expand-\(ref.key)"),
            box: FlexNumberBox(key: key, title: "Expand", spec: spec, padTarget: $ui.padTarget, allowsNegative: true,
                          twin: "list-expand-\(ref.key)", shownOverride: FlexibleLatticeHandles.boxNumber(mm, signed: true),
                          hitHeight: FlexNumberBox.target) { v in
                FlexibleFaceCommits.setExpand(v, ref: ref, group: gid, project: project)
                cardsChanged()
            })
    }

    // MARK: [Prisms]' numbers (read-only; a tap picks that face)

    @ViewBuilder private func prismNumbers(_ scope: FlexibleFaceScope, frame: LatticeBandChipFrame, origin: CGPoint, viewport v: CGSize) -> some View {
        let picked = main.pickedPlaneKeys(project) ?? []
        let tags = FlexiblePrismNumbers.place(
            project.latticeDepthPlanes().filter { $0.role == .include && !picked.contains($0.ref.key) && !project.groupView.isHidden($0.groupID) }
                .compactMap { p -> (ProjectModel.LatticeDepthPlane, [CGPoint])? in
                    // ★ the review of R7-D2: its floor point, else the face's centre, else halfway (Face 5's sat under the open list
                    // and was dropped silently)
                    let spots = [p.handle.anchor, p.handle.planeOrigin, (p.handle.anchor + p.handle.planeOrigin) / 2]
                        .compactMap { local(frame.project($0), origin) }
                    return spots.isEmpty ? nil : (p, spots)
                },
            viewport: v, keepOut: keepOuts(scope, frame: frame, origin: origin, viewport: v, listColumn: false))
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

    /// ★ the review of R7-D2: the numbers are the lattice drawn at that face (`main.faceStats` — the legend's lattice; #354's
    /// slab card, handed in as `cards` / `groupCards` by H32, is no longer read here); from the chip's (i) the card goes below
    /// the chip (`chip`), never on it.
    private func statsCard(_ info: FlexibleFaceChipState.Info, origin: CGPoint, viewport v: CGSize, chip: CGRect?, keepOut: [CGRect]) -> some View {
        let rows = main.faceStats(info.ref, group: info.group, project: project)
        let a = info.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        let size = CGSize(width: FlexibleFaceStatsCard.width, height: FlexibleFaceStatsPlacement.estimatedHeight(rows: rows != nil))
        let r = FlexibleFaceStatsPlacement.frame(anchor: a, chip: chip, size: size, viewport: v, keepOut: keepOut)
        return FlexibleFaceStatsCard(title: project.latticeSelectableName(info.ref) + " · lattice", rows: rows) { ui.info = nil }
            .fixedSize()
            .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["statsCard": g.frame(in: .global)]) }
                .allowsHitTesting(false))
            .offset(x: r.minX, y: r.minY)
    }

    // MARK: the message

    private func toast(_ t: FlexibleFaceChipState.Toast, viewport v: CGSize, chip: CGRect?) -> some View {
        let player = FlexibleMainPlayerSlot.frame(main: main, viewport: v, bottomClearance: bottomClearance, chipColumnWidth: 0)
        // ★ the review of R7-D2: above the player; and above the chip when the chip sits in its band (11" landscape)
        let width = min(v.width - 32, CGFloat(t.text.count) * 7.6 + (t.undo ? 70 : 0) + 2 * DS.Space.l)
        let spot = FlexibleSelectionsMessage.frame(size: CGSize(width: width, height: 44), viewport: v, player: player, avoid: chip.map { [$0] } ?? [])
        return HStack(spacing: DS.Space.m) {
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
        .background(GeometryReader { g in Color.clear.preference(key: FlexibleKeepOutKey.self, value: ["toast": g.frame(in: .global)]) }
            .allowsHitTesting(false))
        .position(x: spot.midX, y: spot.midY)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flexible-toast")
    }
}

/// ★ REVIEW OF R7-D2: where the one message goes — its band above the bar, centred between the left panel and the right
/// edge; with Play on, ABOVE the player (its note row included), a gap between (R7-D2 drew it on the player's own band:
/// neither could be read, and the delete's [Undo] sat on the player's track).
enum FlexibleSelectionsMessage {
    /// `avoid`: what else may sit in its band (the chip) — the message goes above it (its true width decides).
    static func frame(size: CGSize, viewport v: CGSize, player: CGRect?, avoid: [CGRect] = []) -> CGRect {
        let x = (PageChrome.edge + PageChrome.panelWidth + v.width) / 2 - size.width / 2
        var r = CGRect(x: x, y: v.height - FlexibleChromeLayout.barClearance - PageChrome.gap - 22 - size.height / 2,
                       width: size.width, height: size.height)
        if let p = player, p.width > 0, r.insetBy(dx: 0, dy: -PageChrome.gap / 2).intersects(CGRect(x: r.minX, y: p.minY, width: r.width, height: p.height)) {
            r.origin.y = p.minY - PageChrome.gap - size.height
        }
        for _ in 0..<2 {
            guard let k = avoid.first(where: { $0.width > 0 && $0.intersects(r.insetBy(dx: 0, dy: -PageChrome.gap / 2)) }) else { break }
            r.origin.y = k.minY - PageChrome.gap - size.height
        }
        if r.minY < PageChrome.gap { r.origin.y = PageChrome.gap }
        return r
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

/// [Prisms]' read-only numbers: each at the first of its spots (its floor, the face's centre, halfway) that is clear,
/// greedily kept off the keep-outs and off each other.
enum FlexiblePrismNumbers {
    static func place(_ cands: [(ProjectModel.LatticeDepthPlane, [CGPoint])], viewport v: CGSize, keepOut: [CGRect]) -> [(ProjectModel.LatticeDepthPlane, CGPoint)] {
        var taken: [CGRect] = []
        var out: [(ProjectModel.LatticeDepthPlane, CGPoint)] = []
        for (p, spots) in cands {
            // ★ the review of R7-D2: the first of its spots that is on screen and clear (one spot only dropped it silently)
            for at in spots {
                let r = CGRect(x: at.x - 34, y: at.y - 13, width: 68, height: 26)
                guard r.minX >= 8, r.minY >= 8, r.maxX <= v.width - 8, r.maxY <= v.height - 8 else { continue }
                if keepOut.contains(where: { $0.intersects(r) }) || taken.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) { continue }
                taken.append(r)
                out.append((p, at))
                break
            }
        }
        return out
    }
}

