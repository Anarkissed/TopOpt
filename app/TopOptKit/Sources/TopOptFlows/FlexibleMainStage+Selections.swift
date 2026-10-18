// FlexibleMainStage+Selections — the main Flexible page's Selections, the stage's side (task 2026-09-29-flexible-screens,
// round 7, batch R7-D2: his mockup pick 2 — B1 with his three changes). Hooks H22 / H23 route the taps here; H25 mounts the
// list (FlexibleSelectionsList) and H32 the on-model layer (FlexibleOnModelLayer: the chip, its leader, the edge light, the
// numbered handles, the (i), the message). Pure decisions live in FlexibleFacePick and FlexibleFaceCommits.
//
//   * a tap (H22): every card folds (his rule: one card at a time — FlexibleChromeState), the router decides
//     (FlexibleFacePick.tap — it never writes a group), an owned face makes its group the active one, and the chip shows;
//   * a miss (H23): the chip closes, a pending pick is dropped, nothing is created;
//   * the list: a group line = GROUP scope, a face line or one of its boxes = that face;
//   * the chip's buttons and the list's boxes commit through FlexibleFaceCommits (each ONE undo step), then the face cards
//     refresh (H25 / H32 hand `cardsChanged`).
// The pick is coarse state (one publish per tap — the prisms follow it, H15'); the chip's drag, its spots, the keypad and
// the messages live in `faceUI` (FlexibleFaceChipState), which only the layer and the list observe.

import Foundation
import simd
import SwiftUI
import TopOptKit

extension FlexibleMainStage {

    // MARK: the taps (H22, H23)

    /// H22: a tap on the part in the edit phase with no page up. Consumed: #354's tap routers never run on this stage.
    public func tapFace(_ project: ProjectModel, face: FaceID, point: SIMD3<Float>?, mesh: ViewerMesh) {
        chrome.foldAll()
        faceUI.closeTransient()
        let s = FlexibleFacePick.tap(FlexibleFacePick.validated(facePick, project: project), face: face, point: point,
                                     project: project, mesh: mesh)
        if let g = s.scope.groupID, project.selection.activeGroupID != g {
            routerWritesSelection = true
            project.selection.setActive(g)
            routerWritesSelection = false
        }
        if s.scope.groupID != nil { sessionPicked = true }
        facePick = s
        if !s.scope.isNone { chrome.show(.faceChip) }
    }

    /// H23: a tap on empty canvas — the chip closes, a pending pick is dropped, nothing is created.
    public func missTap() {
        chrome.foldAll()
        faceUI.closeTransient()
        let s = FlexibleFacePick.miss(facePick)
        if s != facePick { facePick = s }
    }

    /// The list's group line (GROUP scope) — ★ LOOKED AT (img2's front camera, the Top picked: chip G read "All 1"): a group of
    /// ONE face picks that face.
    func pickGroup(_ gid: UUID, project: ProjectModel) {
        if let g = project.selection.groups.first(where: { $0.id == gid }), case let refs = project.latticeSelectableRefs(g), refs.count == 1 {
            pickFace(refs[0], group: gid, project: project)
            return
        }
        faceUI.closeTransient()
        chrome.foldAll()
        if project.selection.activeGroupID != gid {
            routerWritesSelection = true
            project.selection.setActive(gid)
            routerWritesSelection = false
        }
        var s = facePick
        s.scope = .group(gid)
        s.lastGroup = gid
        sessionPicked = true
        facePick = s
        chrome.show(.faceChip)
    }

    /// A face line of the list, or one of its boxes (that face, in its group).
    func pickFace(_ ref: LatticeSelectableRef, group gid: UUID, project: ProjectModel) {
        if case let .face(g, r) = facePick.scope, g == gid, r == ref { return }
        faceUI.closeTransient()
        chrome.foldAll()
        if project.selection.activeGroupID != gid {
            routerWritesSelection = true
            project.selection.setActive(gid)
            routerWritesSelection = false
        }
        var s = facePick
        s.scope = .face(group: gid, ref: ref)
        s.lastGroup = gid
        sessionPicked = true
        facePick = s
        chrome.show(.faceChip)
    }

    /// The pick as the project stands now (a group an Undo removed reads as none) — re-checked on every project change.
    func revalidatePick(_ project: ProjectModel) {
        let v = FlexibleFacePick.validated(facePick, project: project)
        if v != facePick { facePick = v }
        if facePick.scope.isNone { chrome.close(.faceChip) }
    }

    /// An outside write of the active group (anything but the router — a test, another stage's restore) is a GROUP pick, as
    /// R7-V defined a pick ("the active Selections group changing"). An Undo / Redo's re-write never is (`restoreWritePending`).
    func noteActiveGroupFromOutside(_ g: UUID?) {
        guard !routerWritesSelection, let g, !frozen else { return }
        // ★ R7-D2 follow-up: not while another stage shows (a group picked on Topology is Topology's — the chip must not pop
        // open when he comes back); a stage never told where it is (a test's bare model) counts as showing
        if let shown = seenOwned, !shown { return }
        var s = facePick
        s.scope = .group(g)
        s.lastGroup = g
        facePick = s
    }

    // MARK: chip N

    /// The five buttons (Lattice HELD — FlexibleFaceCommits.latticeOnlyRoleLanded).
    func commitNew(_ kind: FlexibleNewFaceKind, project: ProjectModel, cardsChanged: () -> Void) {
        guard case let .pending(faces) = facePick.scope else { return }
        var s = facePick
        guard let gid = FlexibleFaceCommits.newGroup(kind, faces: faces, project: project, session: &s) else { return }
        routerWritesSelection = true
        project.selection.setActive(gid)
        routerWritesSelection = false
        // the chip stays: on the new group's face (the first), its spot carried over (his img4 lesson: never shift)
        let refs = FlexibleFaceCommits.refs(faces, in: gid)
        let oldKey = facePick.scope.chipKey
        s.scope = refs.count == 1 ? .face(group: gid, ref: refs[0]) : .group(gid)
        if let o = oldKey, let n = s.scope.chipKey, let spot = faceUI.spots[o] { faceUI.spots[n] = spot }
        sessionPicked = true
        facePick = s
        if kind == .load {
            // ★ the review of R7-D2: its weight is the force's default until he sets it on the Squish page — the chip and the list
            // say "weight: Squish page" meanwhile (not "2.5 kg")
            if let kg = project.force.kind(for: gid).weightKg { faceUI.unweighed[gid] = kg }
            faceUI.say(FlexibleSelectionsCopy.loadToast(faces.map { FlexibleFacePick.name($0, project: project) }.joined(separator: " + ")))
        }
        cardsChanged()
    }

    /// (c) "Add to Group C as lattice".
    func commitJoin(project: ProjectModel, cardsChanged: () -> Void) {
        guard case let .pending(faces) = facePick.scope, let gid = facePick.lastGroup else { return }
        var s = facePick
        guard FlexibleFaceCommits.join(gid, faces: faces, project: project, session: &s) else { return }
        let refs = FlexibleFaceCommits.refs(faces, in: gid)
        let oldKey = facePick.scope.chipKey
        s.scope = refs.count == 1 ? .face(group: gid, ref: refs[0]) : .group(gid)
        if let o = oldKey, let n = s.scope.chipKey, let spot = faceUI.spots[o] { faceUI.spots[n] = spot }
        routerWritesSelection = true
        project.selection.setActive(gid)
        routerWritesSelection = false
        sessionPicked = true
        facePick = s
        cardsChanged()
    }

    // MARK: the trash (his answers: a confirm, then Undo)

    func askDelete(_ gid: UUID, inChip: Bool = false) {
        faceUI.closeTransient()
        faceUI.deleteAskInChip = inChip
        faceUI.deleteAsk = gid
    }

    /// [Delete] — the group goes here and in Topology; the message offers [Undo].
    func confirmDelete(project: ProjectModel, cardsChanged: () -> Void) {
        guard let gid = faceUI.deleteAsk else { return }
        faceUI.deleteAsk = nil
        guard let taken = FlexibleFaceCommits.delete(gid, project: project) else { return }
        faceUI.deleted = taken
        revalidatePick(project)
        faceUI.say(FlexibleSelectionsCopy.deleted(taken.group.name), undo: true)
        model?.refreshMainPageLoads()
        cardsChanged()
    }

    /// The message's [Undo]: the group, its faces, its role and its depths come back exactly (FlexibleFaceCommits.restore).
    func undoDelete(project: ProjectModel, cardsChanged: () -> Void) {
        faceUI.toast = nil
        guard let taken = faceUI.deleted else { return }
        faceUI.deleted = nil
        FlexibleFaceCommits.restore(taken, project: project)
        revalidatePick(project)
        model?.refreshMainPageLoads()
        cardsChanged()
    }

    // MARK: the (i)'s numbers

    /// ★ REVIEW OF R7-D2: the (i)'s numbers for a face — the Flexible lattice DRAWN inside its own prism (its include
    /// region(s), by the emission's selectable key), at the depth its box shows; the legend's lattice, never #354's slab card.
    /// nil before a lattice is drawn ("No numbers yet for this face").
    func faceStats(_ ref: LatticeSelectableRef, group gid: UUID, project: ProjectModel) -> FlexibleFaceStats.Rows? {
        guard let m = model, m.project === project, let g = m.lattice else { return nil }
        let depth = project.latticeSlabDepthMM(ref, in: gid)
        let key = "\(g.generation)|\(ref.key)|\(depth)"
        if let hit = faceStatsMemo[key] { return hit }
        let rows = FlexibleFaceStats.rows(lattice: g.inputs, regions: m.includeSpecs.filter { $0.selectableKey == ref.key }, depthMM: depth)
        if faceStatsMemo.count > 64 { faceStatsMemo.removeAll() }
        faceStatsMemo[key] = rows
        return rows
    }

    // MARK: the prisms the pick draws (H15' — `volumes`)

    /// The face-prisms of the pick: FACE scope that face's, GROUP scope every face of the group; nothing before a pick.
    func pickedPlaneKeys(_ project: ProjectModel) -> Set<String>? {
        // (R7-V's red control: the active group's prism on open)
        if controlPrismOnOpen, facePick.scope.isNone, let g = project.selection.activeGroup {
            return Set(project.latticeSelectableRefs(g).map(\.key))
        }
        guard sessionPicked else { return nil }   // a pick of this session (R7-V's rule — a test may reset it)
        switch FlexibleFacePick.validated(facePick, project: project).scope {
        case .none, .pending: return nil
        case let .face(_, ref): return [ref.key]
        case let .group(g):
            guard let grp = project.selection.groups.first(where: { $0.id == g }) else { return nil }
            return Set(project.latticeSelectableRefs(grp).map(\.key))
        }
    }

    /// #354's depth planes of the pick (the handles' geometry), cached on the face-prisms' own inputs.
    func pickedPlanes(_ project: ProjectModel) -> [ProjectModel.LatticeDepthPlane] {
        guard let keys = pickedPlaneKeys(project) else { return [] }
        let inputs = FacePrismInputs(group: facePick.scope.groupID, all: false, lattice: project.lattice, selection: project.selection,
                                     force: project.force, regions: project.faceRegions, groupView: project.groupView,
                                     mesh: project.viewerMesh?.triangleCount ?? 0)
        let all: [ProjectModel.LatticeDepthPlane]
        if let c = planesCache, c.inputs == inputs { all = c.planes } else {
            all = project.latticeDepthPlanes()
            planesCache = (inputs, all)
        }
        return all.filter { keys.contains($0.ref.key) && !project.groupView.isHidden($0.groupID) }
    }
}
