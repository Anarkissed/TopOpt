// FlexibleMainStage+Attach — the Attach tool, the stage's side (task 2026-09-29-flexible-screens, round 7 · U21 batch I, part
// I2). His answer of 2026-10-21 ~15:35: "when you select the lattice in the selections, it is an option/tool in the dragable
// modal, once clicked, it shows the lattice on its own, you select a wall, then it shows the model with the lattice as a ghost
// and you select the face it is meant to connect to. And you should be able to do this multiple times per lattice object."
//
//   * [🔗 Attach] on the card of ONE lattice face (role Lattice, unlocked, no legend drilled in) → step 1 (the lattice alone,
//     its walls lit) → step 2 (the model, the lattice a ghost, only the touching solid lit, every other face dimmed; X-ray stays
//     his) → the link (one sealed undo step) → back to step 1 with [Done];
//   * a stray tap never ends it (H22 / H23 route here first); Cancel / Done / ✕, another pick, an Undo that removes the lattice,
//     gravity setup, leaving the stage or a full-screen page end it — Play put back as it was;
//   * the one-tap suggestion ("Attach to the 4 walls around it") adds every missing side → wall link in ONE step.
// No new hook: every input already reaches the stage (H22, H23, H4, H3, H15', H25, H32). Links never reach a job or the
// lattice's key (FlexibleStageSettings.designInputs).

import CoreGraphics
import Foundation
import simd

extension FlexibleMainStage {

    /// Attach is on and changes the view (the red control `controlAttachKeepsTheView` leaves the view as it was).
    var attachView: Bool { attach.active && !FlexibleAttach.controlAttachKeepsTheView }
    var attachStep2: Bool { attach.wall != nil }

    // MARK: what the walls are read from

    /// The emission the walls come from (memoised; a link never re-emits it).
    func attachRegions(_ p: ProjectModel) -> [LatticeRegionSpec] {
        var lattice = p.lattice
        lattice.flexible?.links = nil
        let key = FlexibleIncludeMemoKey(lattice: lattice, selection: p.selection, force: p.force, faceRegions: p.faceRegions,
                                         mesh: p.viewerMesh.map { "\($0.signature.contentHash)|\($0.faceIDs.count)" } ?? "")
        if let m = attachRegionsMemo, m.key == key { return m.regions }
        let r = p.latticeJobRegions().regions
        attachRegionsMemo = (key, r)
        return r
    }

    func attachWalls(_ p: ProjectModel, key: String) -> FlexibleLatticeWalls.Result? {
        FlexibleLatticeWalls.walls(project: p, key: key, regions: attachRegions(p))
    }

    func links(_ p: ProjectModel) -> [FlexibleLatticeLink] { p.lattice.flexible?.links ?? [] }

    /// A link as Selections lists it: live, stale (its reason), or dormant (its group is gone, or its face left the group).
    func linkState(_ p: ProjectModel, _ l: FlexibleLatticeLink) -> FlexibleAttach.LinkState {
        guard let ref = FlexibleAttach.ref(l.lattice), let g = FlexibleAttach.group(of: ref),
              let grp = p.selection.groups.first(where: { $0.id == g }), p.latticeSelectableRefs(grp).contains(ref) else { return .dormant }
        let on = p.latticeSelectableRole(ref, in: g) == .include
        return FlexibleAttach.state(l, groupExists: true, latticeOn: on, walls: on ? attachWalls(p, key: l.lattice) : nil)
    }

    /// The live links of lattice `key`.
    func liveLinks(_ p: ProjectModel, key: String) -> [FlexibleLatticeLink] {
        links(p).filter { $0.lattice == key && linkState(p, $0) == .live }
    }

    /// The links Selections lists under lattice `key` (live and stale — never dormant), with their state.
    func listedLinks(_ p: ProjectModel, key: String) -> [(link: FlexibleLatticeLink, state: FlexibleAttach.LinkState)] {
        let all = links(p).filter { $0.lattice == key }.map { ($0, linkState(p, $0)) }.filter { $0.1 != .dormant }
        // (the red control only: stale links pruned — never in the app: no automatic changes)
        if FlexibleAttach.controlPruneStale, all.contains(where: { $0.1 != .live }),
           let stale = Optional(Set(all.filter { $0.1 != .live }.map(\.0.id))) {
            for id in stale { FlexibleFaceCommits.removeLink(id: id, project: p) }
            return all.filter { $0.1 == .live }
        }
        return all
    }

    /// A wall's name for a link row — from the walls now, else the face's own outline (a side the expand ate keeps its name).
    func wallName(_ p: ProjectModel, lattice: String, wall: String) -> String {
        if let w = attachWalls(p, key: lattice)?.wall(wall) { return w.name }
        if wall == "floor" { return "Floor" }
        if let ref = FlexibleAttach.ref(lattice), case let .face(_, f) = ref, let mesh = p.viewerMesh,
           let r = FlexibleLatticeWalls.runs(face: Int(f), mesh: mesh).first(where: { $0.key == wall }) {
            return r.kind == .side ? "Side \(r.number)" : "Hole \(r.number)"
        }
        return wall.hasPrefix("hole") ? "Hole" : "Side"
    }

    // MARK: the card's rows

    /// What chip M shows under its face line.
    enum AttachRow: Equatable {
        case none
        /// "Curved lattice · Attach not yet".
        case curved
        /// [🔗 Attach] with its right-hand words, and the suggestion's sides (nil: no suggestion row).
        case button(right: String, suggestion: [String]?)

        var rows: Int {
            switch self {
            case .none: return 0
            case .curved: return 1
            case let .button(_, s): return s == nil ? 1 : 2
            }
        }
    }

    func attachRow(_ p: ProjectModel, group g: UUID, ref: LatticeSelectableRef) -> AttachRow {
        let everywhere = FlexibleAttach.controlAttachEverywhere
        guard everywhere || (p.latticeSelectableRole(ref, in: g) == .include && !FlexibleFaceCommits.isLocked(g, p) && !legendDrilled) else {
            return .none
        }
        let inc = attachRegions(p).filter { $0.role == .include }
        guard FlexibleLatticeWalls.attachable(inc, key: ref.key), let w = attachWalls(p, key: ref.key) else {
            if everywhere { return .button(right: FlexibleSelectionsCopy.notAttached, suggestion: nil) }
            return FlexibleLatticeWalls.specs(inc, key: ref.key).isEmpty ? .none : .curved
        }
        let live = liveLinks(p, key: ref.key)
        let right = w.nothingTouches ? FlexibleSelectionsCopy.nothingTouches
            : live.isEmpty ? FlexibleSelectionsCopy.notAttached : FlexibleSelectionsCopy.linkedCount(live.count)
        let suggestion = w.suggestion(linked: Set(live.filter { $0.target == "wall" }.map(\.wall)))
        // (the red control only: the suggestion applied on open — nothing may be set until he taps)
        if FlexibleFaceCommits.controlAutoApplySuggestion, let s = suggestion {
            FlexibleFaceCommits.addSuggested(lattice: ref.key, sides: s, project: p)
            return .button(right: FlexibleSelectionsCopy.linkedCount(live.count + s.count), suggestion: nil)
        }
        return .button(right: right, suggestion: suggestion)
    }

    // MARK: start / end

    /// [🔗 Attach]: the card turns into the step card in place; Play pauses at rest (remembered); the views row goes inert.
    func startAttach(_ p: ProjectModel, group g: UUID, ref: LatticeSelectableRef) {
        guard case .button = attachRow(p, group: g, ref: ref) else { return }
        faceUI.closeTransient()
        attachPlayWas = playOn
        if playOn { model?.views.remove(.play) }
        if let key = facePick.scope.chipKey, faceUI.spots[key] == nil, let o = faceUI.lastChipOrigin {
            faceUI.spots[key] = o
            attachSpotSet = key
        }
        attachTintsCache = nil
        faceUI.attachTagPick = [:]
        faceUI.attachTagFrozen = [:]
        attachProject = p
        attach = FlexibleAttach.start(lattice: ref.key, group: g, faceName: p.latticeSelectableName(ref))
    }

    /// Back to the normal card, Play restored, nothing else said.
    func endAttach() {
        guard attach.active else { return }
        attach = .off
        attachTintsCache = nil
        if let k = attachSpotSet { faceUI.spots[k] = nil; attachSpotSet = nil }
        if attachPlayWas { attachPlayWas = false; if !playOn { togglePlay() } }
    }

    /// The lattice is no longer a single Lattice face-prism of the pick (an Undo, a delete, Solid / Off): Attach ends; the
    /// picked wall lost its solid (a box edit): back to step 1, said once.
    func revalidateAttach(_ p: ProjectModel) {
        guard attach.active else { return }
        guard case let .face(g, ref) = FlexibleFacePick.validated(facePick, project: p).scope, ref.key == attach.lattice,
              p.latticeSelectableRole(ref, in: g) == .include,
              FlexibleLatticeWalls.attachable(attachRegions(p).filter { $0.role == .include }, key: ref.key) else { endAttach(); return }
        let s = FlexibleAttach.revalidated(attach, walls: attachWalls(p, key: ref.key))
        if s != attach { attach = s }
    }

    // MARK: taps

    /// A chip or tag on the step card / the model (the sure way to pick, whatever the camera does).
    func attachChip(_ tap: FlexibleAttachTap, project p: ProjectModel) { attachApply(p, tap) }

    /// H22 during Attach: the tap's point hit-tested against the projected walls (step 1) or the lit solid (step 2).
    func attachTap(_ p: ProjectModel, face: FaceID, point: SIMD3<Float>?) {
        let walls = attachWalls(p, key: attach.lattice)
        var tap: FlexibleAttachTap = attachStep2 ? .face(Int(face)) : .miss
        if let pt = point, let f = viewFrame, let sp = f.project(pt) {
            let project: (SIMD3<Double>) -> CGPoint? = { f.project(SIMD3<Float>($0)) }
            let depth: (SIMD3<Double>) -> Double? = { q in
                let c = f.clipFromModel * SIMD4<Float>(SIMD3<Float>(q), 1)
                return c.w > 0 ? Double(c.w) : nil
            }
            switch attach.step {
            case .pickWall:
                if let k = FlexibleAttach.wallUnder(sp, walls: walls?.walls ?? [], project: project, depth: depth) { tap = .wall(k) }
            case let .pickTarget(k):
                if let w = walls?.wall(k), let t = w.target, !t.hasPrefix("skin"),
                   FlexibleAttach.wallUnder(sp, walls: [w], project: project, depth: depth) != nil { tap = .target(t) }
            case .off: break
            }
        }
        attachApply(p, tap, walls: walls)
    }

    /// H23 during Attach: the step line again — nothing thrown away.
    func attachMiss() {
        guard let p = attachProject ?? model?.project else { return }
        attachApply(p, .miss)
    }

    func attachApply(_ p: ProjectModel, _ tap: FlexibleAttachTap, walls given: FlexibleLatticeWalls.Result?? = nil) {
        guard attach.active else { return }
        let walls = given ?? attachWalls(p, key: attach.lattice)
        let linked = Set(liveLinks(p, key: attach.lattice).map { "\($0.wall)|\($0.target)" })
        var outside: Set<Int> = []
        if let k = attach.wall, let w = walls?.wall(k), let q = w.frame.first?.first, let mesh = p.viewerMesh,
           let f = FlexibleSolid.of(mesh).faceOnPlane(point: q, normal: w.m, tolMM: FlexibleLatticeWalls.touchMM) { outside = [f] }
        let (s, e) = FlexibleAttach.step(attach, tap, walls: walls, linked: linked, outsideFaces: outside)
        switch e {
        case .end: endAttach(); return
        case let .link(w, t): FlexibleFaceCommits.addLink(lattice: attach.lattice, wall: w, target: t, project: p)
        case .none: break
        }
        if s != attach { attach = s }
    }

    /// A Selections link row tapped while the step card is up: its wall flashes (it never edits).
    func flashWall(_ key: String) {
        guard attach.active else { return }
        var s = attach
        s.flash = key
        attach = s
    }

    /// ★ HIS ONE-TAP SUGGESTION: the missing side → wall links in ONE step, "Linked 4 walls" for 3 s. Never on its own.
    func applySuggestion(_ p: ProjectModel, group g: UUID, ref: LatticeSelectableRef) {
        guard case let .button(_, sides?) = attachRow(p, group: g, ref: ref) else { return }
        let n = FlexibleFaceCommits.addSuggested(lattice: ref.key, sides: sides, project: p)
        if n > 0 { faceUI.say(FlexibleSelectionsCopy.linkedWalls(n), seconds: 3) }
    }

    // MARK: the picture

    /// The lattice pass's ghost during Attach: step 2 — the lattice as a ghost over the opaque model; step 1 — only when the
    /// lattice holds OTHER face-prisms too (the pass cannot draw one region alone without a rebuild: the others would read as
    /// part of it, so all of it is ghosted and the overlay lights this one's walls — said in the handoff).
    func attachGhosts(_ m: FlexibleStageModel) -> Bool {
        if attachStep2 { return !FlexibleAttach.controlNoGhostInStepTwo }
        return Set(m.includeSpecs.compactMap(\.selectableKey)).count > 1
    }

    /// Step 2's tints: every model face that is not a target dimmed grey; a skin target's face in the accent (his pick: "the
    /// app lights those; others greyed"). The wall / under targets are drawn by the overlay on top.
    static let attachDim = SIMD4<Float>(0.30, 0.31, 0.34, 1)
    static let attachLit = SIMD4<Float>(0.04, 0.52, 1.0, 1)

    func attachTints(_ p: ProjectModel, base: [Float]?) -> [Float]? {
        guard attachView, let o = overlay else { return nil }
        let n = o.mesh.flat.vertexCount
        guard n > 0 else { return nil }
        // step 1 — the lattice ON ITS OWN: no surface flagged opaque (the pressed face's heat lid, the closed body) and no ghost,
        // so at body alpha 0 nothing of the part draws (found looking: the lid's heat hid the lattice)
        if attach.step == .pickWall {
            let key = "1|\(n)|\(composedKey ?? "")"
            if let c = attachTintsCache, c.key == key { return c.tints }
            var out = base.flatMap { $0.count == n * 8 ? $0 : nil } ?? [Float](repeating: 0, count: n * 8)
            for v in 0..<n { out[v * 8 + 5] = 0; out[v * 8 + 6] = 0 }
            attachTintsCache = (key, out)
            return out
        }
        guard attachStep2, !FlexibleAttach.controlNoGhostInStepTwo else { return nil }
        var skin: Int?
        if let k = attach.wall, let t = attachWalls(p, key: attach.lattice)?.wall(k)?.target, t.hasPrefix("skin:f") { skin = Int(t.dropFirst(6)) }
        let key = "\(attach.lattice)|\(attach.wall ?? "")|\(skin ?? -1)|\(n)|\(composedKey ?? "")"
        if let c = attachTintsCache, c.key == key { return c.tints }
        var out = base.flatMap { $0.count == n * 8 ? $0 : nil } ?? [Float](repeating: 0, count: n * 8)
        let partVerts = min(o.partFlatVertices, n)
        for v in 0..<n {
            let t = v / 3
            let f = v < partVerts && t < o.keptFace.count ? o.keptFace[t] : -1
            let c = (skin != nil && f == skin!) ? Self.attachLit : Self.attachDim
            out[v * 8] = c.x; out[v * 8 + 1] = c.y; out[v * 8 + 2] = c.z; out[v * 8 + 3] = c.w
        }
        attachTintsCache = (key, out)
        return out
    }
}
