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
    public func groupForce(_ g: FlexibleSqueezeGroup) -> ClosedRange<Double>? {
        FlexibleSqueezeGroups.force(g, settings: settings, loads: mainPageLoads)
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
    nonisolated static func pinchSegments(settings: FlexibleStageSettings, conflicts: [FlexConflictInfo],
                                          designs: [FlexFaceKey: FlexFaceDesignInfo], stacks: [FlexFaceKey: FlexStackInfo],
                                          cuts: [Int: [RegionCut]], law: FlexiblePinch.Law) throws -> [FlexFaceKey: FlexiblePinch.Segments] {
        let partners = FlexibleSqueezeGroups.partners(FlexibleSqueezeGroups.pinches(conflicts, settings))
        guard !partners.isEmpty else { return [:] }
        func key(_ r: Int) -> FlexFaceKey? { settings.face(r).map { FlexFaceKey(region: r, rotation: $0.rotationDeg) } }
        var out: [FlexFaceKey: FlexiblePinch.Segments] = [:]
        for (region, others) in partners.sorted(by: { $0.key < $1.key }) {
            guard let k = key(region), let st = stacks[k], let d = designs[k], d.refusal == nil else { continue }
            let with = others.compactMap { o -> (stack: FlexStackInfo, cuts: [RegionCut])? in
                guard let ko = key(o), let so = stacks[ko] else { return nil }
                return (so, cuts[o] ?? [])
            }
            let pinched = FlexiblePinch.pinchedColumns(st, partners: with)
            guard pinched.contains(true) else { continue }
            out[k] = try FlexiblePinch.design(d, stack: st, pinched: pinched, law: law)
        }
        return out
    }

    // MARK: his actions

    /// Move a pressed face into the group stored as `groupID`. ★ ONE FORCE PER GROUP: a face of
    /// his own takes the group's force (a face a main-page Load group presses keeps that group's
    /// weight — the main page is its one truth; the group line then says the range).
    public func moveToGroup(_ region: Int, _ groupID: Int) {
        guard squeezeGroup(of: region)?.id != groupID else { return }
        let force = squeezeGroups.first { $0.id == groupID }.flatMap { groupForce($0) }
        actionSerial += 1
        edit { s in
            FlexibleSqueezeGroups.move(region, to: groupID, in: &s)
            if let f = force, f.upperBound - f.lowerBound < 0.05, f.upperBound > 0,
               var face = s.face(region), face.weightFrom == nil {
                face.weightKg = f.upperBound
                s.setFace(face)
            }
        }
    }

    /// A new group made from `region` (nil: not pressed, or already alone in its group).
    @discardableResult
    public func newGroup(with region: Int) -> Int? {
        var s = settings
        guard let n = FlexibleSqueezeGroups.newGroup(with: region, in: &s) else { return nil }
        actionSerial += 1
        edit { $0 = s }
        return n
    }

    /// Remove a group: its faces join the first other group (never the only group).
    public func removeGroup(_ groupID: Int) {
        guard squeezeGroups.count > 1 else { return }
        actionSerial += 1
        edit { FlexibleSqueezeGroups.remove(group: groupID, in: &$0) }
    }

    /// ★ ONE FORCE PER GROUP (his answer 1): every hand of the group presses with `kg` — a
    /// main-page Load group takes `kg` as its weight (written back; its faces re-sync by area),
    /// and each face of his own takes `kg`. Sealed as one undo step.
    public func setGroupForce(_ groupID: Int, kg: Double) {
        guard kg > 0, kg.isFinite, let g = squeezeGroups.first(where: { $0.id == groupID }) else { return }
        actionSerial += 1
        let hands = FlexibleSqueezeGroups.hands(g, settings: settings, loads: mainPageLoads)
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
