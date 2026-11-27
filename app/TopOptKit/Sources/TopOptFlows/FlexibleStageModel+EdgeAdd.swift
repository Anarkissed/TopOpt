// FlexibleStageModel+EdgeAdd — round 7 batch R7-E1b (his notes of 2026-10-19 on R7-E1, binding): "There is currently no way to add a
// corner/edge to any group without creating a new one. When in a group, I should be able to tap onto an edge/corner to select it. And
// there should be a Group selection just like the faces." — his answer: "Edges/corners can be added to an EXISTING edges group: in a
// group, tapping an edge/corner adds it; a group selection (chips with names) like the faces have."
//
// ★ THE OPEN EDGES GROUP's pick state (`edgeAdd`): the same candidates and greys as [+ New]'s pick card (loadEdgePick), read again
// whenever the open group or its presses change (`syncEdgeAdd`, the page's task). Only the pressable ones are drawn; a tap on one
// ADDS it to the open group (`addEdgeToGroup`) — ONE edit, one undo step (changeStrips with `into`), at the group's one force, 3 mm
// at core's halfway like a new pick. A tap on a spot that cannot be pressed says why in one line (`blockedLine`), with its fix.
// ★ THE CHIPS (`movePress`): a press moves to another edges group, taking that group's one force — one undo step.

import CoreGraphics
import Foundation
import TopOptKit

extension FlexibleStageModel {
    /// ★ RED CONTROLS only: an added edge makes a NEW group (the bug: no way to add to an existing one); a moved press keeps its own
    /// force (not the group's one force).
    @MainActor static var controlAddMakesNewGroup = false
    @MainActor static var controlMoveKeepsForce = false

    /// ★ RED CONTROL only: E1b's open group — every pressable edge and corner lit all the time (his "wayyy too busy").
    @MainActor static var controlAlwaysLit = false

    /// ★ R7-E3: the open edges group's pressable edges and corners are LIT only while its [+] is on (a tap on the part adds either way).
    public var edgeAddLit: Bool {
        guard let a = edgeAdd, let g = a.into else { return false }
        return Self.controlAlwaysLit || edgeAddingGroup == g
    }

    /// [+] on the open edges group's card: lit ⇄ not lit.
    public func toggleEdgeAdding() {
        guard let g = edgeAdd?.into else { edgeAddingGroup = nil; return }
        edgeAddingGroup = edgeAddingGroup == g ? nil : g
    }

    /// The open edges group's pick state, read again when the open group or its presses change (nil: no edges tab, or [+ New]'s card).
    public func syncEdgeAdd() {
        // ★ found by looking (his live pad, E1b_03): read while the part was still opening, the group said "The part is still opening."
        // and lit nothing — it is read once the part is open (the page asks again then)
        guard edgePick == nil, let g = FlexibleFlatPrismUI.openEdgesGroup(self), sceneState == .ready, openedKey == currentSceneKey else {
            if edgeAdd != nil { edgeAdd = nil }
            if edgeAddingGroup != nil, FlexibleFlatPrismUI.openEdgesGroup(self)?.id != edgeAddingGroup { edgeAddingGroup = nil }
            return
        }
        if let a = edgeAddingGroup, a != g.id { edgeAddingGroup = nil }   // ★ R7-E3: [+] belongs to the group it was pressed on
        var a = FlexibleEdgePick(groupID: g.id, colour: FlexibleSqueezeGroups.colourChoice(of: g, in: settings))
        a.into = g.id
        a.weightKg = g.presses.compactMap { settings.press($0)?.settings.weightKg }.first { $0 > 0 }
        edgeAdd = a
        track(Task { @MainActor [weak self] in await self?.loadEdgePick(\.edgeAdd) })
    }

    /// A tap on a spot that cannot be pressed: its one line why ("Edge 9 · In Group 2"), and its fix when there is one (the group it
    /// is in: [Open Group 2]). The line goes on the card and is returned for the toast.
    @discardableResult
    func blockedLine(_ n: Int, in kp: ReferenceWritableKeyPath<FlexibleStageModel, FlexibleEdgePick?>) -> String {
        guard let p = self[keyPath: kp], let c = p.candidate(n) else { return FlexibleRowCopy.edgePickMiss }
        let line = FlexibleRowCopy.fit(FlexibleRowCopy.candidateLabel(c) + " \u{00B7} " + (p.greyed[n] ?? FlexibleRowCopy.coreRefuses))
        let s = settings
        let held = c.members.compactMap { s.pressHolding($0) }.first
        self[keyPath: kp]?.line = line
        self[keyPath: kp]?.fixGroup = held.flatMap { FlexibleSqueezeGroups.group(ofPress: $0.id, in: s)?.id }
        return line
    }

    /// [Open Group N] — the blocked spot's fix: that group's tab.
    public func openFixGroup(_ kp: ReferenceWritableKeyPath<FlexibleStageModel, FlexibleEdgePick?>) {
        guard let g = self[keyPath: kp]?.fixGroup else { return }
        if kp == \FlexibleStageModel.edgePick { edgePick = nil }
        rail = .group(g)
    }

    /// ★ A TAP ON THE PART while an edges group is open: the nearest pressable corner, then edge, is ADDED to the group; a spot that
    /// cannot be pressed says why. nil when nothing was near (the tap goes on to the face under it).
    public func edgeAddTap(at point: CGPoint, projection: CameraProjection) -> String?? {
        guard let p = edgeAdd, !p.loading, !p.working else { return nil }
        let shown = FlexibleEdgePickRules.project(p.candidates, loads: p.loads, projection: projection)
        let hit = FlexibleEdgePickRules.hit(shown, at: point, last: nil, pressable: Set(p.drawn.map(\.number)))
        if let b = hit.blocked { return .some(blockedLine(b, in: \.edgeAdd)) }
        guard let n = hit.toggle else { return nil }
        track(Task { @MainActor [weak self] in
            guard let self else { return }
            if let why = await self.addEdgeToGroup(n) { self.toast = why }
        })
        return .some(nil)
    }

    /// ★ ADD candidate `n` to the open edges group: its flat prism cut (3 mm at core's halfway, held so each face keeps some of itself;
    /// a lattice stop shallower starts it there), one press in THAT group at the group's one force — ONE edit, one undo step. nil when
    /// added; else the one line why nothing was stored.
    @discardableResult
    public func addEdgeToGroup(_ n: Int) async -> String? {
        guard var a = edgeAdd, let gid = a.into, !a.working, a.pickable(n), var st = a.strips[n] else { return nil }
        guard let kg = a.weightKg, kg > 0 else { return FlexibleRowCopy.edgePickWeightAsk }
        st.order = ((settings.presses ?? []).compactMap(\.strip).map(\.order).max() ?? 0) + 1
        let id = UUID()
        var cuts: [UUID: FlatCutChange] = [:]
        if let d0 = st.halfway, let mesh = project.viewerMesh {
            let others = Self.otherCuts(settings.presses ?? [], except: id)
            let range = FlexibleFlatPrismAngles.depthRange(st, d: d0, limits: .init(loads: [], keepsRest: Self.keepsRest(st, mesh: mesh, others: others)))
            cuts[id] = FlatCutChange(depthMM: Swift.min(FlexibleFlatPrism.defaultDepthMM, range.max), direction: d0, snap: FlexiblePress.Snap.halfway.raw)
        }
        a.working = true
        a.line = nil
        edgeAdd = a
        lastFlatStop = nil
        let ch = { StripChange(add: [(id, st)], cut: cuts, into: gid) }
        var why = await changeStrips(ch(), kg: kg)
        // a pick the lattice stops shallower than its start STARTS at the stop (core's N), as [Done] does
        if why != nil, let stop = lastFlatStop, stop.press == id, let mm = stop.setMM, var c = cuts[id],
           mm >= FlexibleFlatPrism.minDepthMM, mm < c.depthMM - 1e-9 {
            c.depthMM = mm
            cuts[id] = c
            why = await changeStrips(ch(), kg: kg)
        }
        edgeAdd?.working = false
        if let why { edgeAdd?.line = why; return why }
        selectedPress = id
        flatCameraRequest = id
        let label = a.candidate(n).map(FlexibleRowCopy.candidateLabel) ?? ""
        toast = FlexibleRowCopy.edgeAdded(label, to: FlexibleSqueezeGroups.group(ofPress: id, in: settings).map(groupName) ?? "")
        syncEdgeAdd()
        return nil
    }

    /// ★ THE CHIPS: press `id` moves to the edges group stored as `groupID`, taking that group's one force — one undo step; its tab
    /// opens on it.
    public func movePress(_ id: UUID, to groupID: Int) {
        guard let p = settings.press(id), FlexibleSqueezeGroups.group(ofPress: id, in: settings)?.id != groupID,
              let target = squeezeGroups.first(where: { $0.id == groupID && $0.kind == .edges }) else { return }
        let kg = target.presses.compactMap { settings.press($0)?.settings.weightKg }.first { $0 > 0 }
        project.sealUndoStep()
        actionSerial += 1
        edit { s in
            var q = p
            q.settings.squeezeGroup = groupID
            if let kg, q.settings.weightFrom == nil, !Self.controlMoveKeepsForce { q.settings.weightKg = kg }
            s.setPress(q)
            FlexibleSqueezeGroups.normalise(&s)
        }
        project.sealUndoStep()
        if let g = FlexibleSqueezeGroups.group(ofPress: id, in: settings) { rail = .group(g.id) }
        selectedPress = id
    }
}
