// FlexibleStageModel+Presses — the model's side of the angled presses (task 2026-10-07, angled presses,
// batch AP1; FlexiblePress has the struct and its rules, spec §4).
//
// ★ HIS ACTIONS, each ONE undoable edit (the project's snapshot history, like every other edit):
//   * addPress — a new edge / corner / tilted press, at the weight the rule gives (never an invented
//     one: the members' main-page Load group, linked; else its squeeze group's one force; else the
//     pad's answer — nil when the pad must ask);
//   * tilt — a pressed face becomes a 1-region press, its settings moved intact (weight and link kept);
//   * straighten — back into `faces`, intact;
//   * removePress — the last one leaves `presses` nil; a member a main-page group presses or anchors is
//     remembered as deleted in the same edit (S6), so the next re-sync shows what the trash showed.
// ★ AP1 REVIEW: each action seals the edit before it first (as Reset all and every Surface action do), so
// it is its OWN undo step; a direction that cannot be stored is refused (FlexiblePress.isAimable); and
// after the page's undo / redo a press card open on a press the history took away closes
// (`historyRestored`, called by FlexibleStagePage.history).
// ★ WHAT IS SENT. ★ R7-E2: `sentPresses` — the edge and corner presses FlexiblePressSupport's gate lets in (AP9). The job's
// one-group rule, core's hold, the sims and the stress route read `sentSqueezeGroups`, so a press that is NOT sent never holds or
// breaks a face press's job.
// ★ THE PICKING, THE ARROW, THE CARD AND THE CLASH FIXES are AP2–AP4; this file is the saved state only.

import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {

    /// Every press (none ⇒ []).
    public var presses: [FlexiblePress] { settings.presses ?? [] }

    public func press(_ id: UUID) -> FlexiblePress? { settings.press(id) }

    /// The presses IN THE JOB. ★ R7-E2 (AP9's second half): every edge or corner press FlexiblePressSupport's gate lets in —
    /// core's schema takes it, the bridge builds its stack, core's press API is 2, core stacked and designed it on the open scene,
    /// no region in two entries, no shared surface, no same-axis stack in its group (FlexibleStageModel+PressSend). A tilted
    /// single-face press (AP1, no flat prism) is never sent.
    public var sentPresses: Set<UUID> { Set(pressSupport.compactMap { $0.value.inJob ? $0.key : nil }) }

    /// The squeeze groups with something SENT (FlexibleSqueezeGroups.groups(_:sent:)).
    public var sentSqueezeGroups: [FlexibleSqueezeGroup] { FlexibleSqueezeGroups.groups(settings, sent: sentPresses) }

    /// The group a press is in.
    public func squeezeGroup(ofPress id: UUID) -> FlexibleSqueezeGroup? { FlexibleSqueezeGroups.group(ofPress: id, in: settings) }

    // MARK: the weight rule

    /// Where a new press over `regions` in squeeze group `group` (stored number; nil ⇒ 1) takes its
    /// force from: the members' main-page Load group (linked), else that group's ONE force, else ask.
    public func newPressWeight(regions: [Int], group: Int? = nil) -> FlexiblePress.Weight {
        let gid = group ?? FlexibleSqueezeGroups.first
        let force = squeezeGroups.first { $0.id == gid }.flatMap { groupForce($0) }
        return FlexiblePress.weight(regions: regions, loads: mainPageLoads, groupForce: force)
    }

    /// Must the pad ask "How much weight presses here?" before this press can be made?
    public func pressNeedsWeight(regions: [Int], group: Int? = nil) -> Bool {
        newPressWeight(regions: regions, group: group) == .ask
    }

    // MARK: his actions

    /// A new press over `regions` (2+ for an edge or a corner, 1 for a tilted sector) aimed along
    /// `direction`, in squeeze group `group` (stored number; nil ⇒ group 1; a number no group has makes a
    /// new tab). `kg` is the PAD's answer, used only when neither a Load group nor the squeeze group has
    /// a force. nil (nothing changes) when there is no weight to press with — the pad must ask — or when
    /// `regions` is empty, or when the direction cannot be stored (not finite, no length).
    @discardableResult
    public func addPress(regions: [Int], direction: SIMD3<Double>, snap: String?, group: Int? = nil,
                         kg: Double? = nil) -> UUID? {
        guard !regions.isEmpty, FlexiblePress.isAimable(direction) else { return nil }
        var f = FlexibleFaceSettings(faceRegionID: regions[0])
        switch newPressWeight(regions: regions, group: group) {
        case .linked(let g, let w): f.weightKg = w; f.weightFrom = g
        case .force(let w): f.weightKg = w
        case .ask:
            guard let w = kg, w > 0, w.isFinite else { return nil }
            f.weightKg = w
        }
        let gid = group ?? FlexibleSqueezeGroups.first
        f.squeezeGroup = gid == FlexibleSqueezeGroups.first ? nil : gid
        let p = FlexiblePress(regions: regions, direction: direction, snap: snap, settings: f)
        project.sealUndoStep()   // ★ AP1 review: the edit before it is its own step
        actionSerial += 1
        let loads = mainPageLoads
        edit { s in
            s.setPress(p)
            // a linked press sits in its hand's group (one force per hand), then 1…N
            FlexibleSqueezeGroups.uniteHands(&s, loads: loads)
        }
        return p.id
    }

    /// [Tilt]: the pressed face `region` becomes a press along `direction`, its settings moved INTACT
    /// (weight, link, curves, stamp, group), drawn in its own face's frame (`drawnIn`). nil: not a
    /// pressed face, already in a press, or a direction that cannot be stored.
    @discardableResult
    public func tilt(_ region: Int, direction: SIMD3<Double>, snap: String?) -> UUID? {
        var s = settings
        guard let id = s.tiltFace(region, direction: direction, snap: snap) else { return nil }
        project.sealUndoStep()   // ★ AP1 review: the edit before it is its own step
        actionSerial += 1
        edit { $0 = s }
        return id
    }

    /// [Press it straight]: a tilted press goes back into `faces`, intact, where it sat. false: not a
    /// 1-region press, or the face is pressed on its own already (a clash — its own fix, AP4).
    @discardableResult
    public func straighten(_ id: UUID) -> Bool {
        var s = settings
        guard let p = s.press(id), s.straightenPress(id) else { return false }
        project.sealUndoStep()   // ★ AP1 review: the edit before it is its own step
        actionSerial += 1
        edit { $0 = s }
        if selectedPress == id { selectedPress = nil }
        selectedRegion = p.regions.first
        return true
    }

    /// The trash on a press card. The last press leaves `presses` nil (the file as it was).
    /// ★ AP1 REVIEW (S6's rule, "a face he deleted stays deleted"): a member a main-page Load or Anchor
    /// group holds, and that is neither a face nor in another press, is remembered as deleted
    /// (`removedRegions`) IN THE SAME EDIT — else the next re-sync (a scene open, a write-back) re-pressed
    /// it at the group's weight with default curves, unseen, in another undo step. Pressing it again
    /// brings it back as a new face (`press`). A member no group holds leaves no trace.
    public func removePress(_ id: UUID) {
        guard let p = settings.press(id) else { return }
        // ★ ROUND 6 ITEM 2: an edge / corner pick's press gives its strips back to their faces (one undo step)
        if p.strip != nil { track(Task { @MainActor [weak self] in _ = await self?.removeStripPresses([id]) }); return }
        project.sealUndoStep()   // ★ AP1 review: the edit before it is its own step
        actionSerial += 1
        let loads = mainPageLoads
        edit { s in
            s.removePress(id)
            let still = s.pressRegions
            for r in p.regions where !loads.canRemove(r) && s.face(r) == nil && !still.contains(r) && !s.isRemoved(r) {
                s.removedRegions = (s.removedRegions ?? []) + [r]
            }
            FlexibleSqueezeGroups.normalise(&s)
        }
        if selectedPress == id { selectedPress = nil }
    }

    /// ★ AP1 REVIEW: after the page's undo / redo (FlexibleStagePage.history) — a press card open on a
    /// press the history took away closes.
    public func historyRestored() {
        relinkIfNeeded()   // ★ U21 · I3: an Undo / Redo of a link re-solves the sims with the links it brought back
        if let id = selectedPress, settings.press(id) == nil { selectedPress = nil }
        // ★ U21 (UNDO-GHOST): an undone delete opens its tab again with its face selected (FlexibleSettingsOpenGroup)
        let before = historyBefore
        if restoreRailAfterHistory() { return }
        syncRail()   // ★ ROUND 7 (S, 4f): the open tab stays on its members through an undo / redo too
        // ★ U21: a face this step took away (a redone take-out) is not left selected
        if !Self.controlUndoKeepsMovedTab, let r = selectedRegion, settings.face(r) == nil, before?.faces.contains(r) == true {
            selectedRegion = Self.appearSelection(self)
        }
    }

    // MARK: inputs between two of core's frames (FlexiblePressReframe)

    /// `f`'s curves and stamp re-expressed from core's frame `from` to core's frame `to`, through the
    /// open scene (core's stack, from_uv and to_uvt — never a Swift frame). Today both must be FACE
    /// frames (a face press moving to a complement sector); a press's own frame throws
    /// `FlexiblePressReframe.Waiting.pressFrame` until AP9. The caller applies the result and shows its
    /// `toast` ("Curves follow the face") when anything swapped.
    public func reframed(_ f: FlexibleFaceSettings, from: FlexibleFrameRef, to: FlexibleFrameRef) async throws -> FlexiblePressReframe.Result {
        try await frameWorker.withScene { scene in
            try FlexiblePressReframe.reframe(f, from: from, to: to, frames: FlexibleSceneFrames(scene))
        }
    }
}
