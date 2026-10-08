// FlexibleSqueezeGroups — which pressed faces are squeezed TOGETHER (task
// 2026-09-29-flexible-screens, round 4 batch D2; his img 3: "When I attempted to squish the two
// sides simultaneously, it makes the lattice not generate. But when squeezing something with
// your hands, you would absolutely squeeze the two sides together. One side wouldn't rest."
// and img 4: "there needs to be a setting that says Groups faces together … The user should
// group all of them together, or group two sides together with another two sides as a
// different group").
//
// ★ THE RULE (his answer 1: "Squeeze 10 kg" applies to every face in the group, like two hands
// pressing equally; each face keeps its own curve):
//   * every pressed face starts in GROUP 1 (`FlexibleFaceSettings.squeezeGroup` nil); a face
//     can be moved to another group, a new group made from it, a group removed (its faces join
//     the first other group). Groups are numbered 1…N in order; a resting face is in none;
//   * faces of ONE group are squeezed AT THE SAME TIME — opposite faces included: two faces of
//     one group that press the same material along one axis (core's stack conflict) are a
//     PINCH, designed as two segments (FlexiblePinch), so a pinch always builds;
//   * each group has ONE squeeze force. A HAND is one face — or one main-page Load group,
//     whose force core spreads over its faces by area (one traction). The group's force is
//     every hand's force; setting it writes each main-page group back and each own face's
//     weight (FlexibleStageModel.setGroupForce) — one source of truth, the faces' weights;
//   * SEPARATE groups are separate squeezes (sims). The preview lattice is built for all of
//     them: where two groups need the same material the FIRMER wins (FlexibleGroupField), and
//     the page says so in one line. The squish player picks a group (or all at once).
// Group colours are DS tokens, never purple; ★ round 5 (S1): chosen per group; ★ C5: eight
// (green, pink, mint, blue, yellow, teal, olive, terracotta), then round again, numbered (FlexibleGroupColours).

import Foundation
import TopOptDesign
import TopOptKit

/// One squeeze group: the pressed faces squeezed at the same time.
public struct FlexibleSqueezeGroup: Equatable, Identifiable, Sendable {
    /// The stored number (`FlexibleFaceSettings.squeezeGroup`; nil ⇒ 1).
    public let id: Int
    /// As shown ("Group 2"): its rank among the groups that have a pressed face (or a press).
    public let number: Int
    /// Its pressed faces (regions), in the settings' order.
    public let regions: [Int]
    /// ★ ANGLED PRESSES (AP1): its presses (FlexiblePress ids), in the settings' order. A group may hold
    /// only presses and still be a tab; the job and core's hold count only groups with something SENT
    /// (`FlexibleSqueezeGroups.groups(_:sent:)`).
    public let presses: [UUID]

    public init(id: Int, number: Int, regions: [Int], presses: [UUID] = []) {
        self.id = id; self.number = number; self.regions = regions; self.presses = presses
    }
}

/// One squeeze the player can play: a group (its own 3D sim — batch G), or every group one after
/// another ("Play all").
/// ★ BATCH G (his words: "I'd like a way to play the different sims if there are multiple ways to
/// squeeze/squish a model"): D2's "All at once" is DROPPED — the groups are, by his own definition,
/// separate squeezes the firmer-wins lattice was designed for one at a time; a simultaneous press
/// is a load case he never asked for. "Play all" plays each group's sim in turn.
public struct FlexibleSim: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case group(Int)
        case playAll
    }
    /// "group-1" … "group-N", "all".
    public let id: String
    public let kind: Kind
    /// "Group 1 · Top A + Top B" / "Play all".
    public let title: String
    /// "Group 1" / "All".
    public let short: String
    /// The faces it squeezes, LARGEST first (the pass squishes the first four).
    public let keys: [FlexFaceKey]

    public static let allID = "all"
    public static func groupID(_ number: Int) -> String { "group-\(number)" }
}

public enum FlexibleSqueezeGroups {

    /// The group a face starts in.
    public static let first = 1

    public static func id(_ f: FlexibleFaceSettings) -> Int { f.squeezeGroup ?? first }
    public static func id(_ p: FlexiblePress) -> Int { p.squeezeGroup }

    /// Every group that has a pressed face — ★ AP1: or a press — by stored number, numbered 1…N as
    /// shown. With no presses this is exactly the faces' groups it always was.
    public static func groups(_ s: FlexibleStageSettings) -> [FlexibleSqueezeGroup] {
        var members: [Int: [Int]] = [:]
        var pressed: [Int: [UUID]] = [:]
        for f in s.loadedFaces { members[id(f), default: []].append(f.faceRegionID) }
        for p in s.presses ?? [] { pressed[id(p), default: []].append(p.id) }
        return Set(members.keys).union(pressed.keys).sorted().enumerated().map { i, g in
            FlexibleSqueezeGroup(id: g, number: i + 1, regions: members[g] ?? [], presses: pressed[g] ?? [])
        }
    }

    /// ★ AP1: the groups with something SENT to core — a pressed face, or a press in `sent` (the presses
    /// in the job; none until the bridge builds press stacks, AP9). Numbers are the tabs' (`groups`), so
    /// "Send Group 3 only" names the tab he sees. The job's one-group rule and core's hold count these:
    /// a press that is not sent never makes the job throw `.squeezeGroups`.
    public static func groups(_ s: FlexibleStageSettings, sent: Set<UUID>) -> [FlexibleSqueezeGroup] {
        // ★ AP1 TESTS FIRST — RED STUB (the spec's red variant; the next commit replaces it): every group counts, sent or not
        groups(s)
    }

    public static func group(of region: Int, in s: FlexibleStageSettings) -> FlexibleSqueezeGroup? {
        groups(s).first { $0.regions.contains(region) }
    }

    /// ★ AP1: the group a press is in.
    public static func group(ofPress press: UUID, in s: FlexibleStageSettings) -> FlexibleSqueezeGroup? {
        groups(s).first { $0.presses.contains(press) }
    }

    /// Renumber to 1…N in order (group 1 stored as nil); a resting face holds no group.
    /// ★ AP1: presses are renumbered with the faces (a press is always pressed).
    public static func normalise(_ s: inout FlexibleStageSettings) {
        let order = groups(s).map(\.id)
        var rank: [Int: Int] = [:]
        for (i, g) in order.enumerated() { rank[g] = i + 1 }
        for i in s.faces.indices {
            guard s.faces[i].isLoaded else { s.faces[i].squeezeGroup = nil; continue }
            let n = rank[id(s.faces[i])] ?? first
            s.faces[i].squeezeGroup = n == first ? nil : n
        }
        if var ps = s.presses {
            for i in ps.indices {
                let n = rank[id(ps[i])] ?? first
                ps[i].settings.squeezeGroup = n == first ? nil : n
            }
            s.presses = ps
        }
        // ★ ROUND 5 (S1): each group's colour goes with it to its new number — ★ S VERIFICATION: the
        // colour it was SHOWN in (a pick or its old number's default), kept in normal form
        s.groupColours = canonical(remapColours(shownColours(s, ids: order), rank: rank), groups: groups(s))
    }

    /// Move a pressed face into the group stored as `groupID`. ★ D2 REVIEW: `hand` — the faces
    /// that move WITH it (its main-page Load group's faces: one hand is never split across two
    /// squeeze groups, or one group's force would rewrite another's through the main page).
    public static func move(_ region: Int, to groupID: Int, hand: [Int]? = nil, in s: inout FlexibleStageSettings) {
        guard s.face(region)?.isLoaded == true else { return }
        for r in Set((hand ?? []) + [region]) {
            guard var g = s.face(r), g.isLoaded else { continue }
            g.squeezeGroup = groupID
            s.setFace(g)
        }
        normalise(&s)
    }

    /// A NEW group holding `region` (and its `hand`), numbered after the last. nil (nothing
    /// changes) for a face that is not pressed or whose hand is already its group.
    @discardableResult
    public static func newGroup(with region: Int, hand: [Int]? = nil, in s: inout FlexibleStageSettings) -> Int? {
        guard let f = s.face(region), f.isLoaded, let g = group(of: region, in: s) else { return nil }
        let moving = Set((hand ?? []) + [region])
        // ★ AP1: a group that keeps a press is not emptied by the move
        guard g.regions.contains(where: { !moving.contains($0) }) || !g.presses.isEmpty else { return nil }
        let next = (groups(s).map(\.id).max() ?? first) + 1
        move(region, to: next, hand: hand, in: &s)
        return group(of: region, in: s)?.number
    }

    /// Remove a group: its faces join `target` (★ D2 REVIEW: "Join the groups" names it), else
    /// the first OTHER group. No-op for the only group.
    public static func remove(group groupID: Int, into target: Int? = nil, in s: inout FlexibleStageSettings) {
        let gs = groups(s)
        guard gs.count > 1, gs.contains(where: { $0.id == groupID }),
              let into = gs.first(where: { $0.id != groupID && (target == nil || $0.id == target) }) else { return }
        for i in s.faces.indices where s.faces[i].isLoaded && id(s.faces[i]) == groupID {
            s.faces[i].squeezeGroup = into.id
        }
        // ★ AP1: its presses join the same group
        if var ps = s.presses {
            for i in ps.indices where id(ps[i]) == groupID { ps[i].settings.squeezeGroup = into.id }
            s.presses = ps
        }
        normalise(&s)
    }

    /// ★ D2 REVIEW: the faces of `region`'s HAND — every pressed face linked to the same
    /// main-page Load group (the main page presses them with one weight, split by area); a face
    /// of his own is its own hand.
    public static func hand(of region: Int, settings s: FlexibleStageSettings, loads: FlexibleMainPageLoads) -> [Int] {
        guard let f = s.face(region), let from = f.weightFrom, let e = loads.entry(region), e.groupID == from,
              e.role == .pressed else { return [region] }
        return s.loadedFaces.filter { g in
            g.weightFrom == from && loads.entry(g.faceRegionID).map { $0.groupID == from && $0.role == .pressed } == true
        }.map(\.faceRegionID)
    }

    /// ★ D2 REVIEW: a hand split across squeeze groups (a main-page edit added a face to a Load
    /// group whose faces sit in two groups, or a project from before this rule) is united in the
    /// group of its first face — one force per hand.
    public static func uniteHands(_ s: inout FlexibleStageSettings, loads: FlexibleMainPageLoads) {
        var seen = Set<Int>()
        for f in s.loadedFaces where !seen.contains(f.faceRegionID) {
            let h = hand(of: f.faceRegionID, settings: s, loads: loads)
            h.forEach { seen.insert($0) }
            guard h.count > 1 else { continue }
            let gid = id(f)
            for r in h where r != f.faceRegionID {
                guard var g = s.face(r), id(g) != gid else { continue }
                g.squeezeGroup = gid == first ? nil : gid
                s.setFace(g)
            }
        }
        // ★ AP1: a press LINKED to a main-page Load group is part of that group's hand — it sits in the
        // group of the hand's first pressed face (one force per hand; a press alone in its hand stays put)
        if var ps = s.presses {
            for i in ps.indices {
                guard let from = ps[i].settings.weightFrom,
                      let f = s.loadedFaces.first(where: { g in
                          g.weightFrom == from && loads.entry(g.faceRegionID).map { $0.groupID == from && $0.role == .pressed } == true
                      }) else { continue }
                let gid = id(f)
                ps[i].settings.squeezeGroup = gid == first ? nil : gid
            }
            if ps != s.presses { s.presses = ps }
        }
        normalise(&s)
    }

    // MARK: pinches and shared material

    /// A PINCH: two pressed faces of ONE group that press the same material along one axis
    /// (core's stack conflict) — squeezed from both ends at once. Each pair once, in core's order.
    public static func pinches(_ conflicts: [FlexConflictInfo], _ s: FlexibleStageSettings) -> [(a: Int, b: Int)] {
        pairs(conflicts, s, sameGroup: true)
    }

    /// Two faces of DIFFERENT groups that press the same material along one axis: separate
    /// squeezes over one stack — the firmer wins there (never a blocker).
    public static func acrossGroups(_ conflicts: [FlexConflictInfo], _ s: FlexibleStageSettings) -> [(a: Int, b: Int)] {
        pairs(conflicts, s, sameGroup: false)
    }

    private static func pairs(_ conflicts: [FlexConflictInfo], _ s: FlexibleStageSettings, sameGroup: Bool) -> [(a: Int, b: Int)] {
        var gid: [Int: Int] = [:]
        for f in s.loadedFaces where gid[f.faceRegionID] == nil { gid[f.faceRegionID] = id(f) }
        var seen = Set<String>()
        var out: [(a: Int, b: Int)] = []
        for c in conflicts {
            guard let ga = gid[c.faceA], let gb = gid[c.faceB], (ga == gb) == sameGroup else { continue }
            guard seen.insert("\(min(c.faceA, c.faceB))|\(max(c.faceA, c.faceB))").inserted else { continue }
            out.append((c.faceA, c.faceB))
        }
        return out
    }

    /// The faces each face is pinched with (both directions).
    public static func partners(_ pinches: [(a: Int, b: Int)]) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for p in pinches {
            if !(out[p.a]?.contains(p.b) ?? false) { out[p.a, default: []].append(p.b) }
            if !(out[p.b]?.contains(p.a) ?? false) { out[p.b, default: []].append(p.a) }
        }
        return out
    }

    // MARK: the ONE squeeze force

    /// One hand: a face of his own, or a main-page Load group (its faces share its force by area).
    public struct Hand: Equatable, Sendable {
        /// The main-page group, nil for a face of his own.
        public let mainGroup: UUID?
        /// The force (kg) this hand presses with — the main-page group's whole weight, or the face's.
        public let kg: Double
        /// The group's faces this hand presses.
        public let regions: [Int]
        /// ★ AP1: the group's presses this hand presses (a press of his own is its own hand).
        public let presses: [UUID]

        public init(mainGroup: UUID?, kg: Double, regions: [Int], presses: [UUID] = []) {
            self.mainGroup = mainGroup; self.kg = kg; self.regions = regions; self.presses = presses
        }
    }

    /// The hands of a group: a face linked to a main-page Load group (weightFrom = that group,
    /// still pressed by it) is that group's hand; any other pressed face is its own.
    /// ★ D2 REVIEW: `liveKg` reads a main-page group's weight from the PROJECT (the one source of
    /// truth) — the cached entry went stale when the Settings page's undo restored the project.
    public static func hands(_ g: FlexibleSqueezeGroup, settings s: FlexibleStageSettings,
                             loads: FlexibleMainPageLoads, liveKg: ((UUID) -> Double?)? = nil) -> [Hand] {
        var out: [Hand] = []
        var byGroup: [UUID: Int] = [:]
        for r in g.regions {
            guard let f = s.face(r) else { continue }
            if let from = f.weightFrom, let e = loads.entry(r), e.groupID == from, e.role == .pressed {
                if let i = byGroup[from] {
                    out[i] = Hand(mainGroup: from, kg: out[i].kg, regions: out[i].regions + [r])
                } else {
                    byGroup[from] = out.count
                    out.append(Hand(mainGroup: from, kg: liveKg?(from) ?? e.groupKg, regions: [r]))
                }
            } else {
                out.append(Hand(mainGroup: nil, kg: f.weightKg, regions: [r]))
            }
        }
        // ★ AP1: a press LINKED to a main-page Load group that still holds a member is that group's hand
        // (its force goes through the press's members by area); any other press is its own hand
        // ★ AP1 TESTS FIRST — RED STUB (the spec's red variant; the next commit replaces it): presses are no hand
        for pid in g.presses where false {
            guard let p = s.press(pid) else { continue }
            if let from = p.settings.weightFrom,
               let e = p.regions.lazy.compactMap({ loads.entry($0) }).first(where: { $0.groupID == from && $0.role != .rests }) {
                if let i = byGroup[from] {
                    out[i] = Hand(mainGroup: from, kg: out[i].kg, regions: out[i].regions, presses: out[i].presses + [pid])
                } else {
                    byGroup[from] = out.count
                    out.append(Hand(mainGroup: from, kg: liveKg?(from) ?? e.groupKg, regions: [], presses: [pid]))
                }
            } else {
                out.append(Hand(mainGroup: nil, kg: p.settings.weightKg, regions: [], presses: [pid]))
            }
        }
        return out
    }

    /// The group's squeeze force: one number when every hand agrees (within 0.05 kg), else the
    /// range (a project from before groups, whose faces had their own weights). nil: no hand.
    public static func force(_ g: FlexibleSqueezeGroup, settings s: FlexibleStageSettings,
                             loads: FlexibleMainPageLoads, liveKg: ((UUID) -> Double?)? = nil) -> ClosedRange<Double>? {
        let kg = hands(g, settings: s, loads: loads, liveKg: liveKg).map(\.kg)
        guard let lo = kg.min(), let hi = kg.max() else { return nil }
        return hi - lo < 0.05 ? hi...hi : lo...hi
    }

    // MARK: the sims (the squish player's picker)

    /// One sim per group, LARGEST face first; with two or more groups, "Play all" too (the groups in
    /// turn — batch G).
    /// `area(region)` orders the faces (the pass squishes the first four); `name` names them.
    public static func sims(_ groups: [FlexibleSqueezeGroup], key: (Int) -> FlexFaceKey?,
                            area: (FlexFaceKey) -> Double, name: (Int) -> String) -> [FlexibleSim] {
        func ordered(_ regions: [Int]) -> [FlexFaceKey] {
            let keys = regions.compactMap(key)
            return FlexibleStageModel.squishOrder(keys.map { (key: $0, areaMM2: area($0)) })
        }
        var out = groups.map { g in
            FlexibleSim(id: FlexibleSim.groupID(g.number), kind: .group(g.number),
                        title: FlexibleRowCopy.simTitle(number: g.number, names: g.regions.map(name)),
                        short: FlexibleRowCopy.groupName(g.number), keys: ordered(g.regions))
        }
        if groups.count > 1 {
            out.append(FlexibleSim(id: FlexibleSim.allID, kind: .playAll, title: FlexibleRowCopy.simAll,
                                   short: FlexibleRowCopy.simAllShort, keys: ordered(groups.flatMap(\.regions))))
        }
        return out
    }

    // MARK: ★ D2 REVIEW: the pass's four squish slots never split a pinch

    /// `ordered` (largest first) reordered so the first `slots` hold WHOLE pinches: faces joined
    /// by a pinch (`pinchedWith`, both directions) fill the slots together or not at all — with
    /// five pressed faces the pass had squished face 3 while its partner, face 5, stood still.
    /// A pinch larger than the slots takes its largest faces. `shown`: how many faces squish.
    public static func squishSlots<K: Hashable>(_ ordered: [K], pinchedWith: [K: [K]],
                                                slots: Int = FlexibleSquishField.maxFaces) -> (order: [K], shown: Int) {
        guard ordered.count > slots, !pinchedWith.isEmpty else { return (ordered, min(slots, ordered.count)) }
        let present = Set(ordered)
        var unitOf: [K: Int] = [:], units: [[K]] = []
        for k in ordered where unitOf[k] == nil {
            var comp: [K] = [], stack = [k]
            unitOf[k] = units.count
            while let x = stack.popLast() {
                comp.append(x)
                for y in pinchedWith[x] ?? [] where present.contains(y) && unitOf[y] == nil {
                    unitOf[y] = units.count
                    stack.append(y)
                }
            }
            units.append(comp)
        }
        var chosen = Set<K>(), used = Set<Int>()
        for k in ordered {
            guard let u = unitOf[k], !used.contains(u) else { continue }
            if chosen.count + units[u].count <= slots { units[u].forEach { chosen.insert($0) }; used.insert(u) }
        }
        guard !chosen.isEmpty else { return (ordered, slots) }
        return (ordered.filter { chosen.contains($0) } + ordered.filter { !chosen.contains($0) }, chosen.count)
    }

    // MARK: colours

    /// A group's DEFAULT colour — DS tokens, NEVER purple: green (group 1, the pressed faces' own
    /// colour), then the palette in order, then round again. FlexibleSqueezeGroupsTests pins it.
    /// ★ ROUND 5 (S1): he picks each group's colour in its folder tab (FlexibleGroupColours —
    /// `FlexibleStageModel.groupColour`). ★ C5: eight DS tokens (DS.Color.squeezeGroupPalette).
    public static let palette: [RGBA] = FlexibleGroupColour.allCases.map(\.rgba)
    public static func colour(number: Int) -> RGBA { palette[(max(1, number) - 1) % palette.count] }
}
