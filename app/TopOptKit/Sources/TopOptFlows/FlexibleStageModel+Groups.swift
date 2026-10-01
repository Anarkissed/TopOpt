// FlexibleStageModel+Groups — the model's side of the squeeze groups (task
// 2026-09-29-flexible-screens, round 4 batch D2; FlexibleSqueezeGroups has the rule).
//
// ★ HIS ACTIONS: move a pressed face to another group, make a new group from it, remove a group
// (its faces join the first other group), and set a group's ONE force — which writes every
// main-page Load group among its hands back (one source of truth: the group) and every face of
// his own. Each is one undoable edit that re-runs the designs; none of them can block Exit.
// ★ WHAT THE PIPELINE READS: `pinches` (core's stack conflicts inside one group) and the
// two-segment designs of the pinched faces (`segments`, FlexiblePinch — run with the designs,
// FlexibleStageModel.scheduleDesigns), and `sims` (what the squish player can play).

import Foundation
import TopOptKit

extension FlexibleStageModel {

    /// Every squeeze group (pressed faces only), numbered 1…N.
    public var squeezeGroups: [FlexibleSqueezeGroup] { FlexibleSqueezeGroups.groups(settings) }

    /// The group a pressed face is in.
    public func squeezeGroup(of region: Int) -> FlexibleSqueezeGroup? {
        FlexibleSqueezeGroups.group(of: region, in: settings)
    }

    /// A group's ONE squeeze force (a range only for faces of their own weights from before groups).
    /// ★ D2 REVIEW: a main-page hand's weight is read from the project, live (one source of truth).
    public func groupForce(_ g: FlexibleSqueezeGroup) -> ClosedRange<Double>? {
        FlexibleSqueezeGroups.force(g, settings: settings, loads: mainPageLoads, liveKg: liveMainKg)
    }

    /// The main page's Load group's weight now (nil: not a Load group).
    var liveMainKg: (UUID) -> Double? { { [project] id in project.force.kind(for: id).weightKg } }

    /// ★ D2 REVIEW: the faces that move with `region` (its main-page Load group's faces).
    public func hand(of region: Int) -> [Int] {
        FlexibleSqueezeGroups.hand(of: region, settings: settings, loads: mainPageLoads)
    }

    /// The group's one line: "Group 1 · Face 3 + Face 5 · Squeeze 10 kg".
    public func groupLine(_ g: FlexibleSqueezeGroup) -> String {
        FlexibleRowCopy.groupLine(number: g.number, names: g.regions.map { displayName($0) }, force: groupForce(g))
    }

    /// Two faces of one group on one stack: a pinch (core's conflicts, filtered by group).
    public var pinches: [(a: Int, b: Int)] { FlexibleSqueezeGroups.pinches(conflicts, settings) }

    /// The faces `region` is pinched with.
    public func pinchPartners(_ region: Int) -> [Int] {
        FlexibleSqueezeGroups.partners(pinches)[region] ?? []
    }

    /// Separate groups whose faces press the same material (the firmer wins there): along one
    /// axis (core's conflicts across groups) or across axes (a face's column midpoints inside
    /// another group's face's stack — the handover region). Said in one line under the groups.
    public var groupsShareMaterial: Bool {
        let gs = squeezeGroups
        guard gs.count > 1 else { return false }
        if !FlexibleSqueezeGroups.acrossGroups(conflicts, settings).isEmpty { return true }
        let regions = self.regions
        for (i, a) in gs.enumerated() {
            for b in gs[(i + 1)...] {
                for ra in a.regions {
                    guard let sa = stack(ra) else { continue }
                    let partners = b.regions.compactMap { rb in stack(rb).map { (stack: $0, cuts: regions.cuts(of: rb)) } }
                    if FlexiblePinch.pinchedColumns(sa, partners: partners).contains(true) { return true }
                }
            }
        }
        return false
    }

    /// What the squish player can play: each group (largest face first), and all at once.
    public var sims: [FlexibleSim] {
        FlexibleSqueezeGroups.sims(squeezeGroups, key: { [weak self] r in self?.key(r) },
                                   area: { [stacks] k in stacks[k]?.areaMM2 ?? 0 },
                                   name: { [weak self] r in self?.displayName(r) ?? "Face \(r)" })
    }

    /// ★ THE PINCHES' TWO-SEGMENT DESIGNS (run with the designs, off the main thread): every
    /// face of a pinch (two faces of one group on one stack) gets its pinched columns designed
    /// over their half (FlexiblePinch.design, core's table); a face with no pinched column, or
    /// refused by core, keeps core's own design (no entry).
    /// ★ D2 REVIEW: ONE FACE'S THROW NO LONGER DROPS EVERY PINCH (the rule designEach set for the
    /// designs): each face has its own catch; a face that threw keeps core's one profile (the
    /// lattice builds from `FlexiblePinch.core`) and its words are kept against its key — its
    /// card says "one profile for now".
    nonisolated static func pinchSegments(settings: FlexibleStageSettings, conflicts: [FlexConflictInfo],
                                          designs: [FlexFaceKey: FlexFaceDesignInfo], stacks: [FlexFaceKey: FlexStackInfo],
                                          cuts: [Int: [RegionCut]], law: FlexiblePinch.Law)
        -> (segments: [FlexFaceKey: FlexiblePinch.Segments], errors: [FlexFaceKey: String]) {
        let partners = FlexibleSqueezeGroups.partners(FlexibleSqueezeGroups.pinches(conflicts, settings))
        guard !partners.isEmpty else { return ([:], [:]) }
        func key(_ r: Int) -> FlexFaceKey? { settings.face(r).map { FlexFaceKey(region: r, rotation: $0.rotationDeg) } }
        var out: [FlexFaceKey: FlexiblePinch.Segments] = [:], errors: [FlexFaceKey: String] = [:]
        for (region, others) in partners.sorted(by: { $0.key < $1.key }) {
            guard let k = key(region), let st = stacks[k], let d = designs[k], d.refusal == nil else { continue }
            let with = others.compactMap { o -> (stack: FlexStackInfo, cuts: [RegionCut])? in
                guard let ko = key(o), let so = stacks[ko] else { return nil }
                return (so, cuts[o] ?? [])
            }
            let pinched = FlexiblePinch.pinchedColumns(st, partners: with)
            guard pinched.contains(true) else { continue }
            do { out[k] = try FlexiblePinch.design(d, stack: st, pinched: pinched, law: law) }
            catch { errors[k] = "\(error)" }
        }
        return (out, errors)
    }

    /// ★ D2 REVIEW: separate groups, estimated with the designs (FlexibleGroupEstimate): which
    /// group will squish less than it was designed for once the lattice carries every group.
    nonisolated static func groupEstimate(settings: FlexibleStageSettings, designs: [FlexFaceKey: FlexFaceDesignInfo],
                                          segments: [FlexFaceKey: FlexiblePinch.Segments], stacks: [FlexFaceKey: FlexStackInfo],
                                          cuts: [Int: [RegionCut]], law: FlexiblePinch.Law) throws -> [FlexibleGroupEstimate.Miss] {
        let gs = FlexibleSqueezeGroups.groups(settings)
        guard gs.count > 1 else { return [] }
        let groups = gs.map { g in
            FlexibleGroupEstimate.Group(id: g.id, number: g.number, faces: g.regions.compactMap { r -> FlexibleGroupEstimate.Face? in
                guard let f = settings.face(r) else { return nil }
                let k = FlexFaceKey(region: r, rotation: f.rotationDeg)
                guard let st = stacks[k], let d = designs[k], d.refusal == nil else { return nil }
                return FlexibleGroupEstimate.Face(region: r, stack: st, cuts: cuts[r] ?? [],
                                                  segments: segments[k] ?? FlexiblePinch.core(d, stack: st),
                                                  pressureMPa: d.columns.map(\.pressureMPa))
            })
        }
        return try FlexibleGroupEstimate.estimate(groups, strainUnder: law.strainUnder)
    }

    /// The miss of group `groupID` (nil: it squishes as designed, or one group).
    public func groupMiss(_ groupID: Int) -> FlexibleGroupEstimate.Miss? {
        squeezeGroups.count > 1 ? groupMisses.first { $0.groupID == groupID } : nil
    }

    /// The pinch partners among `keys` (both directions) — the squish slots keep them whole.
    func pinchedKeys(_ keys: [FlexFaceKey]) -> [FlexFaceKey: [FlexFaceKey]] {
        let byRegion = Dictionary(keys.map { ($0.region, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [FlexFaceKey: [FlexFaceKey]] = [:]
        for (r, others) in FlexibleSqueezeGroups.partners(pinches) {
            guard let k = byRegion[r] else { continue }
            out[k] = others.compactMap { byRegion[$0] }
        }
        return out
    }

    /// The squish order (largest first) with the four slots holding whole pinches.
    nonisolated static func squishOrder<K: Hashable>(_ faces: [(key: K, areaMM2: Double)], pinchedWith: [K: [K]]) -> [K] {
        FlexibleSqueezeGroups.squishSlots(squishOrder(faces), pinchedWith: pinchedWith).order
    }

    /// ★ D2 REVIEW: which columns of a pressed face a pinch halves (its two-segment design's,
    /// else computed from the stacks — a calibrate-first filament has no design); nil: none.
    /// The dent's exaggeration and the depth chip stop at the HALF there.
    public func pinchedColumns(_ region: Int) -> [Bool]? {
        guard let k = key(region) else { return nil }
        if let sg = segments[k] { return sg.pinched.contains(true) ? sg.pinched : nil }
        let others = pinchPartners(region)
        guard !others.isEmpty, let st = stacks[k] else { return nil }
        let with = others.compactMap { o in stack(o).map { (stack: $0, cuts: regions.cuts(of: o)) } }
        let p = FlexiblePinch.pinchedColumns(st, partners: with)
        return p.contains(true) ? p : nil
    }

    // MARK: his actions

    /// Move a pressed face into the group stored as `groupID`. ★ ONE FORCE PER GROUP: a face of
    /// his own takes the group's force (a face a main-page Load group presses keeps that group's
    /// weight — the main page is its one truth; the group line then says the range).
    /// ★ D2 REVIEW: a main-page Load group is ONE hand — its faces move TOGETHER (moving one of
    /// them alone let one group's force rewrite another's through the main page).
    public func moveToGroup(_ region: Int, _ groupID: Int) {
        guard squeezeGroup(of: region)?.id != groupID else { return }
        let force = squeezeGroups.first { $0.id == groupID }.flatMap { groupForce($0) }
        let hand = hand(of: region)
        actionSerial += 1
        edit { s in
            FlexibleSqueezeGroups.move(region, to: groupID, hand: hand, in: &s)
            Self.takeForce(force, regions: hand, in: &s)
        }
    }

    /// A face of his own that joins a group takes the group's ONE force (a face a main-page Load
    /// group presses keeps the main page's weight — the main page is its one truth).
    nonisolated static func takeForce(_ force: ClosedRange<Double>?, regions: [Int], in s: inout FlexibleStageSettings) {
        guard let f = force, f.upperBound - f.lowerBound < 0.05, f.upperBound > 0 else { return }
        for r in regions {
            guard var face = s.face(r), face.isLoaded, face.weightFrom == nil else { continue }
            face.weightKg = f.upperBound
            s.setFace(face)
        }
    }

    /// A new group made from `region` and its hand (nil: not pressed, or its hand is already
    /// the whole group).
    @discardableResult
    public func newGroup(with region: Int) -> Int? {
        var s = settings
        // ★ ROUND 5 (S1): the new group wears the first colour no group wears — STORED, so it keeps
        // it when an earlier group goes and it is renumbered
        let colour = FlexibleSqueezeGroups.freeColour(in: s, forNumber: squeezeGroups.count + 1)
        guard let n = FlexibleSqueezeGroups.newGroup(with: region, hand: hand(of: region), in: &s) else { return nil }
        if let g = FlexibleSqueezeGroups.groups(s).first(where: { $0.number == n }) {
            var map = s.groupColours ?? [:]
            map[String(g.id)] = colour.rawValue
            // ★ S VERIFICATION: normal form — its number's own colour needs no entry (`normalise`
            // carries what it is shown in through a renumber either way)
            s.groupColours = FlexibleSqueezeGroups.canonical(map, groups: FlexibleSqueezeGroups.groups(s))
        }
        actionSerial += 1
        edit { $0 = s }
        return n
    }

    /// Remove a group: its faces join the first other group (never the only group).
    /// ★ D2 REVIEW: like a move, they take THAT group's one force — the merged group had kept
    /// both forces ("Squeeze 6–10 kg"), and the next press asked for the pad.
    public func removeGroup(_ groupID: Int) {
        mergeGroup(groupID, into: nil)
    }

    /// ★ D2 REVIEW ("Join the groups"): every face of group `groupID` joins group `target` (nil:
    /// the first other group) at its force. One undoable edit.
    public func mergeGroup(_ groupID: Int, into target: Int?) {
        let gs = squeezeGroups
        guard gs.count > 1, let from = gs.first(where: { $0.id == groupID }),
              let into = gs.first(where: { $0.id != groupID && (target == nil || $0.id == target) }) else { return }
        let force = groupForce(into)
        actionSerial += 1
        edit { s in
            FlexibleSqueezeGroups.remove(group: groupID, into: into.id, in: &s)
            Self.takeForce(force, regions: from.regions, in: &s)
        }
    }

    /// ★ ONE FORCE PER GROUP (his answer 1): every hand of the group presses with `kg` — a
    /// main-page Load group takes `kg` as its weight (written back; its faces re-sync by area),
    /// and each face of his own takes `kg`. Sealed as one undo step.
    public func setGroupForce(_ groupID: Int, kg: Double) {
        guard kg > 0, kg.isFinite, let g = squeezeGroups.first(where: { $0.id == groupID }) else { return }
        actionSerial += 1
        let hands = FlexibleSqueezeGroups.hands(g, settings: settings, loads: mainPageLoads, liveKg: liveMainKg)
        var wroteMain = false
        for h in hands {
            guard let main = h.mainGroup else { continue }
            project.force.setWeight(main, kg: kg)
            wroteMain = true
        }
        let own = hands.filter { $0.mainGroup == nil }.flatMap(\.regions)
        for r in g.regions { relinkedWeights[r] = nil }
        edit { s in
            for r in own {
                guard var f = s.face(r) else { continue }
                f.weightKg = kg; f.weightFrom = nil
                s.setFace(f)
            }
        }
        if wroteMain { adoptMainPageLoads() } else { project.sealUndoStep() }
    }

    /// The force a newly pressed face joins group 1 with (no pad to ask): group 1's one force.
    var firstGroupForce: Double? {
        guard let g = squeezeGroups.first, let f = groupForce(g), f.upperBound - f.lowerBound < 0.05, f.upperBound > 0 else { return nil }
        return f.upperBound
    }

    /// [Press it] asks the pad only when there is no weight to press with: no main-page Load
    /// group presses the face and no group has a force yet.
    public func pressNeedsWeight(_ region: Int) -> Bool {
        mainPageLoads.entry(region)?.role != .pressed && firstGroupForce == nil
    }
}
