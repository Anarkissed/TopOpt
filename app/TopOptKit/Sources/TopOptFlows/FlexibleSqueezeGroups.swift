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
// Group colours are DS tokens — green, blue, orange, red — never purple.

import Foundation
import TopOptDesign
import TopOptKit

/// One squeeze group: the pressed faces squeezed at the same time.
public struct FlexibleSqueezeGroup: Equatable, Identifiable, Sendable {
    /// The stored number (`FlexibleFaceSettings.squeezeGroup`; nil ⇒ 1).
    public let id: Int
    /// As shown ("Group 2"): its rank among the groups that have a pressed face.
    public let number: Int
    /// Its pressed faces (regions), in the settings' order.
    public let regions: [Int]
}

/// One squeeze the player can play: a group, or every group at once (batch G's case picker
/// plugs in here — each case a named, selectable sim).
public struct FlexibleSim: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case group(Int)
        case allAtOnce
    }
    /// "group-1" … "group-N", "all".
    public let id: String
    public let kind: Kind
    /// "Group 1 · Top A + Top B" / "All at once".
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

    /// Every group that has a pressed face, by stored number, numbered 1…N as shown.
    public static func groups(_ s: FlexibleStageSettings) -> [FlexibleSqueezeGroup] {
        var members: [Int: [Int]] = [:]
        for f in s.loadedFaces { members[id(f), default: []].append(f.faceRegionID) }
        return members.keys.sorted().enumerated().map { i, g in
            FlexibleSqueezeGroup(id: g, number: i + 1, regions: members[g] ?? [])
        }
    }

    public static func group(of region: Int, in s: FlexibleStageSettings) -> FlexibleSqueezeGroup? {
        groups(s).first { $0.regions.contains(region) }
    }

    /// Renumber to 1…N in order (group 1 stored as nil); a resting face holds no group.
    public static func normalise(_ s: inout FlexibleStageSettings) {
        let order = groups(s).map(\.id)
        var rank: [Int: Int] = [:]
        for (i, g) in order.enumerated() { rank[g] = i + 1 }
        for i in s.faces.indices {
            guard s.faces[i].isLoaded else { s.faces[i].squeezeGroup = nil; continue }
            let n = rank[id(s.faces[i])] ?? first
            s.faces[i].squeezeGroup = n == first ? nil : n
        }
    }

    /// Move a pressed face into the group stored as `groupID`.
    public static func move(_ region: Int, to groupID: Int, in s: inout FlexibleStageSettings) {
        guard var f = s.face(region), f.isLoaded else { return }
        f.squeezeGroup = groupID
        s.setFace(f)
        normalise(&s)
    }

    /// A NEW group holding `region` alone, numbered after the last. nil (nothing changes) for a
    /// face that is not pressed or is already alone in its group.
    @discardableResult
    public static func newGroup(with region: Int, in s: inout FlexibleStageSettings) -> Int? {
        guard let f = s.face(region), f.isLoaded, let g = group(of: region, in: s), g.regions.count > 1 else { return nil }
        let next = (groups(s).map(\.id).max() ?? first) + 1
        move(region, to: next, in: &s)
        return group(of: region, in: s)?.number
    }

    /// Remove a group: its faces join the first OTHER group. No-op for the only group.
    public static func remove(group groupID: Int, in s: inout FlexibleStageSettings) {
        let gs = groups(s)
        guard gs.count > 1, gs.contains(where: { $0.id == groupID }),
              let target = gs.first(where: { $0.id != groupID }) else { return }
        for i in s.faces.indices where s.faces[i].isLoaded && id(s.faces[i]) == groupID {
            s.faces[i].squeezeGroup = target.id
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
    }

    /// The hands of a group: a face linked to a main-page Load group (weightFrom = that group,
    /// still pressed by it) is that group's hand; any other pressed face is its own.
    public static func hands(_ g: FlexibleSqueezeGroup, settings s: FlexibleStageSettings,
                             loads: FlexibleMainPageLoads) -> [Hand] {
        var out: [Hand] = []
        var byGroup: [UUID: Int] = [:]
        for r in g.regions {
            guard let f = s.face(r) else { continue }
            if let from = f.weightFrom, let e = loads.entry(r), e.groupID == from, e.role == .pressed {
                if let i = byGroup[from] {
                    out[i] = Hand(mainGroup: from, kg: out[i].kg, regions: out[i].regions + [r])
                } else {
                    byGroup[from] = out.count
                    out.append(Hand(mainGroup: from, kg: e.groupKg, regions: [r]))
                }
            } else {
                out.append(Hand(mainGroup: nil, kg: f.weightKg, regions: [r]))
            }
        }
        return out
    }

    /// The group's squeeze force: one number when every hand agrees (within 0.05 kg), else the
    /// range (a project from before groups, whose faces had their own weights). nil: no hand.
    public static func force(_ g: FlexibleSqueezeGroup, settings s: FlexibleStageSettings,
                             loads: FlexibleMainPageLoads) -> ClosedRange<Double>? {
        let kg = hands(g, settings: s, loads: loads).map(\.kg)
        guard let lo = kg.min(), let hi = kg.max() else { return nil }
        return hi - lo < 0.05 ? hi...hi : lo...hi
    }

    // MARK: the sims (the squish player's picker)

    /// One sim per group, LARGEST face first; with two or more groups, "All at once" too.
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
            out.append(FlexibleSim(id: FlexibleSim.allID, kind: .allAtOnce, title: FlexibleRowCopy.simAll,
                                   short: FlexibleRowCopy.simAllShort, keys: ordered(groups.flatMap(\.regions))))
        }
        return out
    }

    // MARK: colours

    /// A group's colour — DS tokens, NEVER purple: green (group 1, the pressed faces' own
    /// colour), blue, orange, red, then round again. FlexibleSqueezeGroupsTests pins it.
    public static let palette: [RGBA] = [DS.Color.accentGreen, DS.Color.accent, DS.Color.warning, DS.Color.danger]
    public static func colour(number: Int) -> RGBA { palette[(max(1, number) - 1) % palette.count] }
}
