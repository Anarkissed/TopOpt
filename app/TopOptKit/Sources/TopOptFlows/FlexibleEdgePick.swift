// FlexibleEdgePick — round 6 item 2's PICK MODE (task 2026-10-08, his img2 words: "when creating a new group, there
// should be the option to selecting 'edges/corners' in which case, different edges/corners are highlighted with
// different colours and listed. You then select from a list and/or tap on the edges/corners to add to the group. After
// that, the stamp and all that is the same." — and his answer: a group is EITHER faces OR edges/corners, never mixed).
//
// ★ THE STATE (one stored `edgePick` on the stage model while [+ New] → [Edges/corners] is open; nothing is stored in
// the project until [Done]): the new group's number and its free colour, every edge and corner of the part
// (FlexibleEdgeCandidates — core's adjacency, the 15° rule, numbered by position), each one's colour on the model,
// what is picked (in pick order), what cannot be picked and the one line why, each pick's AREA (FlexibleEdgeStrips),
// the group's one squeeze force, and the last tap (a repeat tap cycles).
// ★ THE RULES (pure, here): COLOURS — the eight group colours minus the new group's own, assigned greedily so that
// TOUCHING candidates (sharing a corner point) never wear the same one; every candidate also carries its number, as in
// the list. THE TAP — in screen space: the nearest CORNER within 22 pt, else the nearest EDGE within 22 pt, else
// nothing ("Tap an edge or a corner"); a REPEAT tap within 22 pt of the last one CYCLES through every candidate there
// (corners first, nearest first), so an end-on edge under its two corners (his img3 camera) can still be picked on
// the model. The list always holds every candidate. Back-facing candidates are drawn faint, untagged, and stay listed.

import CoreGraphics
import Foundation
import simd

/// Pick mode's state (FlexibleStageModel.edgePick).
public struct FlexibleEdgePick: Equatable {
    /// This pick session (a load that finishes after he left pick mode, or started another, is dropped).
    public let token = UUID()
    /// The new group's stored id (after every group's) and its colour (the first no group wears).
    public var groupID: Int
    public var colour: FlexibleGroupColour
    /// Every edge and corner (FlexibleEdgeCandidates), numbered.
    public var candidates: [FlexibleEdgeCandidates.Candidate] = []
    /// Each candidate's colour on the model (touching ones never share; never the group's own).
    public var colours: [Int: FlexibleGroupColour] = [:]
    /// What cannot be picked, and the one line why (≤ 44): AP2's (a face taken out, two parts of one face, core's
    /// adjacency, a wrapping face), "In Group N", core's verdict on the press, the area's.
    public var greyed: [Int: String] = [:]
    /// Each pickable candidate's area (its default width), by number.
    public var strips: [Int: FlexibleStrip] = [:]
    /// Each candidate's members' core inward normals (is it facing the camera?), by number.
    public var loads: [Int: [SIMD3<Double>]] = [:]
    /// Picked, in pick order.
    public var picks: [Int] = []
    /// The group's one squeeze force (kg); nil until he types it (a press never invents a weight).
    public var weightKg: Double?
    /// The list is being read from core.
    public var loading = true
    /// Core's verdict on each candidate's press is being asked.
    public var checking = false
    /// [Done] is cutting the strips.
    public var working = false
    /// One line: why the list could not be read, or why [Done] did nothing.
    public var line: String?
    /// The last tap on the model (a repeat tap cycles).
    public var cycle: FlexibleEdgePickRules.Cycle?
    /// ★ R7-E1b (his 2026-10-19 answer: "Edges/corners can be added to an EXISTING edges group"): the open edges group a tap ADDS
    /// to (its stored id) — nil for [+ New]'s pick card.
    public var into: Int?
    /// ★ R7-E1b: the group the last tapped spot is already in (its fix: [Open Group N]).
    public var fixGroup: Int?

    public init(groupID: Int, colour: FlexibleGroupColour) { self.groupID = groupID; self.colour = colour }

    public func candidate(_ n: Int) -> FlexibleEdgeCandidates.Candidate? { candidates.first { $0.number == n } }
    public func pickable(_ n: Int) -> Bool { greyed[n] == nil && strips[n] != nil }
    /// ★ R7-E1b (his answer: "NO LIST … only the pressable edges/corners light up on the part"): what the part draws — the pressable
    /// ones and the picked ones; never one that cannot be pressed (the RED CONTROL: every candidate, as the list had it).
    @MainActor public var drawn: [FlexibleEdgeCandidates.Candidate] {
        FlexibleEdgePickRules.controlDrawAll ? candidates : candidates.filter { pickable($0.number) || picks.contains($0.number) }
    }
    public var edgesPicked: Int { picks.filter { candidate($0)?.kind != .corner }.count }
    public var cornersPicked: Int { picks.filter { candidate($0)?.kind == .corner }.count }
}

public enum FlexibleEdgePickRules {

    /// A tap reaches a candidate this close (points).
    public static let tapRadiusPt: CGFloat = 22
    /// A corner's tag is pushed this far out along its projected halfway; an edge's, this far.
    public static let cornerTagPushPt: CGFloat = 24
    public static let edgeTagPushPt: CGFloat = 16
    /// Strokes and dots (points).
    public static let edgeStrokePt: CGFloat = 6
    public static let pickedStrokePt: CGFloat = 10
    public static let cornerDotPt: CGFloat = 14
    public static let pickedDotPt: CGFloat = 20
    /// Every tag is a target of at least this (Apple's 44 pt).
    public static let tagTargetPt: CGFloat = 44
    /// A candidate facing away is drawn this faint, with no tag.
    public static let backFacingOpacity: Double = 0.4

    /// ★ RED CONTROLS (the after-s1 table): colours by number, round the palette (touching ones then share one); the
    /// edge-first tap rule; no cycling (an end-on edge under its corners cannot be picked on the model).
    @MainActor static var controlRoundRobin = false
    @MainActor static var controlEdgeFirst = false
    @MainActor static var controlNoCycle = false
    /// ★ R7-E1b RED CONTROL: the part draws every candidate (the greyed ones too).
    @MainActor static var controlDrawAll = false

    // MARK: colours

    /// The points a candidate holds: a corner's point; an edge's (and a fillet's) polylines' ends.
    static func ends(_ c: FlexibleEdgeCandidates.Candidate) -> [SIMD3<Double>] {
        c.kind == .corner ? [c.point] : c.polylines.flatMap { pl in [pl.first, pl.last].compactMap { $0 } }
    }

    /// ★ TOUCHING: two candidates sharing a point (an edge and the corner at its end; two edges meeting there).
    public static func touching(_ a: FlexibleEdgeCandidates.Candidate, _ b: FlexibleEdgeCandidates.Candidate) -> Bool {
        guard a.number != b.number else { return false }
        let eb = ends(b)
        return ends(a).contains { p in eb.contains { simd_distance(p, $0) <= FlexibleMeet.touchMM } }
    }

    /// ★ THE COLOURS: the eight group colours minus `own`, greedily by number, so TOUCHING candidates never share one
    /// (a candidate whose neighbours wear all seven takes the one they wear least — named in the tests' prints).
    @MainActor
    public static func colours(_ cs: [FlexibleEdgeCandidates.Candidate], excluding own: FlexibleGroupColour) -> [Int: FlexibleGroupColour] {
        let palette = FlexibleGroupColour.allCases.filter { $0 != own }
        var out: [Int: FlexibleGroupColour] = [:]
        let sorted = cs.sorted { $0.number < $1.number }
        if controlRoundRobin {
            for c in sorted { out[c.number] = palette[(c.number - 1) % palette.count] }
            return out
        }
        for c in sorted {
            var used: [FlexibleGroupColour: Int] = [:]
            for o in sorted where o.number != c.number { if let col = out[o.number], touching(c, o) { used[col, default: 0] += 1 } }
            out[c.number] = palette.first { used[$0] == nil } ?? palette.min { (used[$0] ?? 0) < (used[$1] ?? 0) }!
        }
        return out
    }

    // MARK: on screen

    /// A candidate on screen: its point (nil: behind the camera), its polylines, and whether it faces the camera.
    public struct Projected: Equatable, Sendable {
        public let number: Int
        public let kind: FlexibleEdgeCandidates.Kind
        public let point: CGPoint?
        public let lines: [[CGPoint]]
        public let front: Bool
        /// Where its tag sits: pushed out from the part along its projected halfway (nil: no tag — facing away).
        public let tag: CGPoint?
        public init(number: Int, kind: FlexibleEdgeCandidates.Kind, point: CGPoint?, lines: [[CGPoint]], front: Bool, tag: CGPoint?) {
            self.number = number; self.kind = kind; self.point = point; self.lines = lines; self.front = front; self.tag = tag
        }
    }

    static func f(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)) }

    /// ★ Every candidate through the page's projection. FACING: a member whose core inward normal points away from the
    /// camera along the view ray (its outward side faces the camera). The tag is pushed out along the projected
    /// halfway of the members' outward normals (corners 24 pt, edges 16 pt).
    public static func project(_ cs: [FlexibleEdgeCandidates.Candidate], loads: [Int: [SIMD3<Double>]],
                               projection: CameraProjection) -> [Projected] {
        cs.map { c in
            let pt = projection.project(f(c.point))
            let lines = c.polylines.map { pl in pl.compactMap { projection.project(f($0)) } }.filter { $0.count >= 2 }
            var front = false
            var tag: CGPoint? = nil
            if let p = pt, let ray = projection.ray(throughViewPoint: p) {
                let d = SIMD3<Double>(Double(ray.dir.x), Double(ray.dir.y), Double(ray.dir.z))
                let ls = loads[c.number] ?? []
                front = ls.contains { simd_dot($0, d) > 1e-6 }
                if front {
                    var out = SIMD3<Double>.zero
                    for l in ls { out -= l }
                    let push = c.kind == .corner ? cornerTagPushPt : edgeTagPushPt
                    if let o = FlexiblePressAim.unit(out), let q = projection.project(f(c.point + o * 10)) {
                        let dx = q.x - p.x, dy = q.y - p.y, len = (dx * dx + dy * dy).squareRoot()
                        tag = len > 1e-6 ? CGPoint(x: p.x + dx / len * push, y: p.y + dy / len * push) : CGPoint(x: p.x, y: p.y - push)
                    } else {
                        tag = CGPoint(x: p.x, y: p.y - push)
                    }
                }
            }
            return Projected(number: c.number, kind: c.kind, point: pt, lines: lines, front: front, tag: tag)
        }
    }

    /// The last tap: where, the candidates there in cycling order, and which one the tap toggled.
    public struct Cycle: Equatable, Sendable {
        public let anchor: CGPoint
        public let order: [Int]
        public let index: Int
    }

    /// What a tap does: toggle one candidate (and, on a repeat tap, toggle the previous step's back first).
    public struct Hit: Equatable, Sendable {
        public let toggle: Int?
        public let untoggle: Int?
        public let cycle: Cycle?
        /// ★ R7-E1b: nothing pressable there, but this candidate (not drawn — it cannot be pressed): its one line why is said.
        public var blocked: Int? = nil
    }

    /// Screen distance from `p` to segment ab.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y, l2 = abx * abx + aby * aby
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / l2)) : 0
        let x = a.x + t * abx - p.x, y = a.y + t * aby - p.y
        return (x * x + y * y).squareRoot()
    }

    /// A candidate's screen distance from `p` (a corner's point; an edge's nearest polyline segment).
    static func distance(_ c: Projected, _ p: CGPoint) -> CGFloat? {
        if c.kind == .corner {
            guard let q = c.point else { return nil }
            return ((q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)).squareRoot()
        }
        var best: CGFloat? = nil
        for pl in c.lines { for i in 1..<pl.count { let d = distance(p, pl[i - 1], pl[i]); best = min(best ?? d, d) } }
        return best
    }

    /// ★ THE TAP (front-facing candidates only; the list reaches the rest): the nearest corner within 22 pt, else the
    /// nearest edge within 22 pt, else nothing. A REPEAT tap within 22 pt of the last one (two or more candidates there)
    /// toggles the last step's candidate back and the NEXT one on, round and round.
    /// ★ R7-E1b: `pressable` — the numbers drawn on the part; a tap reaches only those, and, when none is near, names the nearest one
    /// that cannot be pressed (`blocked`) so its one line why is said (nil: every candidate is reachable, as before).
    @MainActor
    public static func hit(_ ps: [Projected], at p: CGPoint, last: Cycle?, pressable: Set<Int>? = nil) -> Hit {
        if let ok = pressable {
            let h = hit(ps.filter { ok.contains($0.number) }, at: p, last: last)
            if h.toggle != nil { return h }
            let other = hit(ps.filter { !ok.contains($0.number) }, at: p, last: nil)
            return Hit(toggle: nil, untoggle: nil, cycle: nil, blocked: other.toggle)
        }
        let near = ps.filter(\.front).compactMap { c -> (c: Projected, d: CGFloat)? in
            guard let d = distance(c, p), d <= tapRadiusPt else { return nil }
            return (c, d)
        }
        let corners = near.filter { $0.c.kind == .corner }.sorted { ($0.d, $0.c.number) < ($1.d, $1.c.number) }
        let edges = near.filter { $0.c.kind != .corner }.sorted { ($0.d, $0.c.number) < ($1.d, $1.c.number) }
        let order = (controlEdgeFirst ? edges + corners : corners + edges).map(\.c.number)
        guard let first = order.first else { return Hit(toggle: nil, untoggle: nil, cycle: nil) }
        if !controlNoCycle, let l = last, order.count >= 2, Set(l.order) == Set(order),
           (l.anchor.x - p.x) * (l.anchor.x - p.x) + (l.anchor.y - p.y) * (l.anchor.y - p.y) <= tapRadiusPt * tapRadiusPt {
            let i = (l.index + 1) % l.order.count
            return Hit(toggle: l.order[i], untoggle: l.order[l.index], cycle: Cycle(anchor: l.anchor, order: l.order, index: i))
        }
        return Hit(toggle: first, untoggle: nil, cycle: Cycle(anchor: p, order: order, index: 0))
    }
}
