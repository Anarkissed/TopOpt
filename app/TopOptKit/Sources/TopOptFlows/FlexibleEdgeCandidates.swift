// FlexibleEdgeCandidates — every edge and corner of the part, numbered (task 2026-10-07, angled presses, batch AP2;
// round 6 item 2's "Candidates", r6 spec §3: his "edges/corners" groups list them, colour them and let him tap them;
// the colouring and the picking are item 2's, built on this list).
//
// ★ WHAT IS AN EDGE, WHAT IS A CORNER (the 15° rule; r6 spec §3, FlexibleMainPageLoads.straightCos):
//   * a SEAM SEGMENT is CREASED when core's inward normals of the two triangles that meet there differ by at least
//     15° (core's face_frame of each triangle — FlexibleMeetFacts.triangleLoads); under 15° the seam is SMOOTH
//     (tangent: a fillet running into a flat, a pseudo-face boundary on a shallow bend) and is not offered;
//   * an EDGE is two pieces of DIFFERENT faces whose seam has more than 1e-3 mm of creased length. Two pieces of one
//     face (sectors, meeting along their cut) are never an edge;
//   * a BLEND (a filleted edge, "Top ⌒ Face 3 · fillet") is two FLATS (core's normal spread ≤ 1°) at least 15°
//     apart, joined through smooth seams by a chain of curved pieces: ONE candidate holding the flats and the WHOLE
//     chain (FlexibleMeet.blendChain), never the flat–fillet seams one by one;
//   * a CORNER is a point where three or more pieces meet AND, once pieces joined there by a smooth seam or a cut
//     are taken as one side, three or more sides remain (a box corner: yes; the end of his r5's cut on the top's
//     edge, where Top A and Top B are one face: no).
// ★ NOT OFFERED (listed, with one line why): a member that WRAPS — core's normal_spread_flag (> 30°, flat + fillet +
// flat in one STL pseudo-face: [Split on Surface] is item 2's fix) — or that core frames no direction for (normals
// cancel, as the rounded slab's whole side wall); two sectors of one face (core's press refuses them). In a blend,
// the curved chain is EXPECTED to spread (it is the fillet); only its two flats must not wrap.
// ★ STABLE NUMBERS: corners first, then edges and blends, each ordered by its point's position (−z, y, x) at the
// 1e-4 mm key, then by members — the same numbers on every open and in any triangle order.
// ★ ONE SOURCE: CORE. Every normal, spread and validity used is core's (FlexibleMeetFacts); the app finds where
// faces meet (FlexibleMeet) and compares core's numbers with the 15° threshold. No frame is computed here.

// ★★ AP2 TESTS-FIRST STUBS: the rules marked "RED STUB" are the spec's red variants (no 15° rule, every meeting
// point a corner, no blend, nothing refused, numbers in the order the seams are first met); the next commit
// replaces each with its rule.

import Foundation
import simd
import TopOptKit

/// Core's facts the candidates need, read once per scene open (FlexibleStageModel+Meet).
public struct FlexibleMeetFacts: Equatable, Sendable {
    /// Core's face_adjacency (element f: face f's neighbours).
    public var adjacency: [[Int]]
    /// Core's frame of every piece (rotation 0, no direction), by region id; a piece core refused has none.
    public var frames: [Int: FlexRegionFrame]
    /// Core's inward normal of every seam triangle, by VIEWER triangle index (checked to be core's triangle).
    public var triangleLoads: [Int: SIMD3<Double>]
    /// Why core's answers cannot be used against this viewer mesh (its triangles are not core's); nil = they can.
    public var mismatch: String?

    public init(adjacency: [[Int]] = [], frames: [Int: FlexRegionFrame] = [:], triangleLoads: [Int: SIMD3<Double>] = [:],
                mismatch: String? = nil) {
        self.adjacency = adjacency; self.frames = frames; self.triangleLoads = triangleLoads; self.mismatch = mismatch
    }

    /// The viewer triangles whose core normal the 15° rule needs: both sides of every whole-face seam segment.
    public static func seamTriangles(_ meet: FlexibleMeet) -> [Int] {
        var s = Set<Int>()
        for list in meet.faceSeams.values { for seg in list { s.insert(seg.triA); s.insert(seg.triB) } }
        return s.sorted()
    }
}

extension FlexibleMeet {
    /// ★ Does piece `r` WRAP — core's normal_spread_flag, or no frame from core at all (its normals cancel)?
    public func wraps(_ r: Int, facts: FlexibleMeetFacts) -> Bool {
        false   // ★ AP2 RED STUB: nothing wraps
    }

    /// The seam's segments CREASED under the 15° rule (core's normals of the two triangles; a cut line never is).
    public func creasedSegments(_ pair: Pair, facts: FlexibleMeetFacts,
                                creaseCos: Double = FlexibleMainPageLoads.straightCos) -> [Segment] {
        seams[pair]?.segments ?? []   // ★ AP2 RED STUB: no 15° rule — every seam is creased
    }

    /// A seam with more than 1e-3 mm creased.
    public func creased(_ pair: Pair, facts: FlexibleMeetFacts, creaseCos: Double = FlexibleMainPageLoads.straightCos) -> Bool {
        creasedSegments(pair, facts: facts, creaseCos: creaseCos).reduce(0) { $0 + $1.length } > Self.touchMM
    }

    /// Core says piece `r` is FLAT (its normals spread ≤ `FlexibleEdgeCandidates.flatSpreadDeg`).
    public func flat(_ r: Int, facts: FlexibleMeetFacts) -> Bool {
        guard let f = facts.frames[r], f.valid else { return false }
        return f.normalSpreadDeg <= FlexibleEdgeCandidates.flatSpreadDeg
    }

    /// Core says piece `r` is CURVED (framed, its normals spread more than a flat's).
    public func curved(_ r: Int, facts: FlexibleMeetFacts) -> Bool {
        guard let f = facts.frames[r], f.valid else { return false }
        return f.normalSpreadDeg > FlexibleEdgeCandidates.flatSpreadDeg
    }

    /// The whole chain of curved pieces between flats `a` and `b`, through smooth seams (core's 15° verdict).
    public func blendChain(_ a: Int, _ b: Int, facts: FlexibleMeetFacts,
                           creaseCos: Double = FlexibleMainPageLoads.straightCos) -> [Int]? {
        nil   // ★ AP2 RED STUB: no chain
    }

    /// Do two pieces lie on one face (sectors)?
    public func shareFace(_ x: Int, _ y: Int) -> Bool {
        guard let px = piece(x), let py = piece(y) else { return false }
        return !Set(px.faces).isDisjoint(with: py.faces)
    }
}

public struct FlexibleEdgeCandidates {
    public enum Kind: String, Sendable { case corner, edge, blend }

    public struct Candidate: Equatable, Identifiable, Sendable {
        /// ★ Stable, from 1: corners, then edges and blends, by position (−z, y, x).
        public let number: Int
        public var id: Int { number }
        public let kind: Kind
        /// Regions (ascending; a blend: its first flat, the chain, its other flat).
        public let members: [Int]
        /// On the faces: the corner; the middle of the longest creased polyline; a blend's chain under the halfway.
        public let point: SIMD3<Double>
        /// What the page draws: the creased polylines (an edge), the chain's seams (a blend), none (a corner).
        public let polylines: [[SIMD3<Double>]]
        public let offered: Bool
        /// Why not offered (one line); nil when offered.
        public let why: String?
    }

    /// A flat (core's normal spread) at most this many degrees.
    public static let flatSpreadDeg = 1.0

    public let candidates: [Candidate]
    /// Core's facts could not be used (FlexibleMeetFacts.mismatch): no candidate is listed until they can.
    public let unread: String?
    let creasedPairs: Set<FlexibleMeet.Pair>

    public var corners: [Candidate] { candidates.filter { $0.kind == .corner } }
    /// Edges and blends.
    public var edges: [Candidate] { candidates.filter { $0.kind != .corner } }
    /// Is this seam creased (≥ 15°) — an edge?
    public func creased(_ pair: FlexibleMeet.Pair) -> Bool { creasedPairs.contains(pair) }

    /// ★ The list. `creaseCos` is the 15° rule (FlexibleMainPageLoads.straightCos); `name` names a region in the
    /// one-line reasons ("face 0", the page's own names when the model passes them).
    public static func make(meet: FlexibleMeet, facts: FlexibleMeetFacts,
                            creaseCos: Double = FlexibleMainPageLoads.straightCos,
                            name: (Int) -> String = { "face \($0)" }) -> FlexibleEdgeCandidates {
        // ★ AP2 RED STUB: every seam an edge (no 15° rule), every meeting point a corner, no blend, nothing refused,
        // numbered in the order the seams are first met in the triangle list
        _ = (facts, creaseCos, name)
        var out: [Candidate] = []
        for c in meet.corners {
            out.append(Candidate(number: out.count + 1, kind: .corner, members: c.regions, point: c.point, polylines: [], offered: true, why: nil))
        }
        let firstMet = meet.seams.values.sorted { ($0.segments.map { Swift.min($0.triA, $0.triB) }.min() ?? 0) < ($1.segments.map { Swift.min($0.triA, $0.triB) }.min() ?? 0) }
        for sm in firstMet {
            guard let mid = FlexibleMeet.midpoint(sm.polylines) else { continue }
            out.append(Candidate(number: out.count + 1, kind: .edge, members: [sm.pair.a, sm.pair.b], point: mid, polylines: sm.polylines,
                                 offered: true, why: nil))
        }
        return FlexibleEdgeCandidates(candidates: out, unread: nil, creasedPairs: Set(meet.seams.keys))
    }
}
