// FlexibleStageModel+Presses — the model's side of the angled presses (task 2026-10-07, angled presses,
// batch AP1; FlexiblePress has the struct and its rules, spec §4).
//
// ★ HIS ACTIONS, each ONE undoable edit (the project's snapshot history, like every other edit):
//   * addPress — a new edge / corner / tilted press, at the weight the rule gives (never an invented
//     one: the members' main-page Load group, linked; else its squeeze group's one force; else the
//     pad's answer — nil when the pad must ask);
//   * tilt — a pressed face becomes a 1-region press, its settings moved intact (weight and link kept);
//   * straighten — back into `faces`, intact;
//   * removePress — the last one leaves `presses` nil.
// ★ WHAT IS SENT. Nothing yet: `sentPresses` is empty until the bridge builds press stacks (AP9, through
// FlexiblePressSupport.inJob in AP6). The job's one-group rule, core's hold, the sims and the stress
// route read `sentSqueezeGroups`, so a press alone in a group never holds or breaks a face press's job.
// ★ THE PICKING, THE ARROW, THE CARD AND THE CLASH FIXES are AP2–AP4; this file is the saved state only.

import Foundation
import simd
import TopOptKit

extension FlexibleStageModel {

    /// Every press (none ⇒ []).
    public var presses: [FlexiblePress] { settings.presses ?? [] }

    public func press(_ id: UUID) -> FlexiblePress? { settings.press(id) }

    /// The presses IN THE JOB. ★ Empty until AP9: core's schema accepts press_direction only after the
    /// #361 sync (S1), and the bridge does not build a press's stack before the seam (AP9) — so no press
    /// is ever sent, simulated or built into the lattice before then.
    public var sentPresses: Set<UUID> { [] }

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
    /// `regions` is empty.
    @discardableResult
    public func addPress(regions: [Int], direction: SIMD3<Double>, snap: String?, group: Int? = nil,
                         kg: Double? = nil) -> UUID? {
        guard !regions.isEmpty else { return nil }
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
    /// pressed face, or already in a press.
    @discardableResult
    public func tilt(_ region: Int, direction: SIMD3<Double>, snap: String?) -> UUID? {
        var s = settings
        guard let id = s.tiltFace(region, direction: direction, snap: snap) else { return nil }
        actionSerial += 1
        edit { $0 = s }
        return id
    }

    /// [Press it straight]: a tilted press goes back into `faces`, intact. false: not a 1-region press,
    /// or the face is pressed on its own already (a clash — its own fix, AP4).
    @discardableResult
    public func straighten(_ id: UUID) -> Bool {
        var s = settings
        guard let p = s.press(id), s.straightenPress(id) else { return false }
        actionSerial += 1
        edit { $0 = s }
        if selectedPress == id { selectedPress = nil }
        selectedRegion = p.regions.first
        return true
    }

    /// The trash on a press card. The last press leaves `presses` nil (the file as it was).
    public func removePress(_ id: UUID) {
        guard settings.press(id) != nil else { return }
        actionSerial += 1
        edit { s in
            s.removePress(id)
            FlexibleSqueezeGroups.normalise(&s)
        }
        if selectedPress == id { selectedPress = nil }
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
