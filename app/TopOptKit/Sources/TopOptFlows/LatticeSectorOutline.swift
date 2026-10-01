// LatticeSectorOutline.swift — ★ A SPLIT PIECE IS LATTICED, ON ITS OWN SIDE OF THE CUT
// (task 2026-09-29-flexible-screens, round 3 batch E; his item 4, 2026-09-29: "For some reason a
// protected face is considered frozen - however, that is how we make a lattice and protected from
// TO. Please fix this so a protected face isn't frozen.").
//
// ★ THE CAUSE WAS THE SPLIT, NOT PROTECTION. 'top A' on his pad is a CUT piece of face 1 (region
// 103, x ≥ 50), and his 'Top' group is not even protected. `ProjectModel.latticeRegionMembers`
// answered nil for any region with cuts (and for any union of pieces), so the emission dropped it:
// the Selections row said "Frozen, not latticed" under "Out of regime", the Lattice button said
// "nothing set to lattice", and the Flexible job — with no include region — latticed the whole part.
// The note beside that rule ("a region is a voxel set the run has no predicate for") was out of date
// for a piece of a plane: a half-space cuts a planar face along a straight line.
//
// ★ THE FIX, IN GEOMETRY CORE ALREADY TAKES. A piece is `members ∩ (∩ half-spaces)`. On a planar
// face (or each planar FACET of a curved one, `LatticeFaceFacets`) every half-space is a half-PLANE
// in the face's own (u, v) frame, so each member's outline loops are clipped to it here and the piece
// is emitted as ordinary face prisms under its OWN key — its role, depth, expand and density. Core's
// `region_contains`, the #354 previews and the Flexible job all read `outline_uv` even-odd, so the
// run, the picture and C1 follow with no core change. A union of pieces emits each of its pieces.
//
// ★ BYTE-IDENTICAL WITHOUT CUTS. A face no cut touches takes exactly the shapes it always took
// (`pieces` hands back `resolve ?? facets` untouched), and the T-junction pass reads pieces only.
//
// ★ THE CUT EDGE. A new edge reads the piece's OWN face across it, so `finishSeams` pairs it with
// the sibling piece when that sibling is latticed — a seam: no rim, no wall between two latticed
// halves — and leaves it a rim (the lattice ends under a solid wall) when it is not. Where a piece
// was cut again, the long cut edge of its neighbour is first split at the T, because the seam test
// matches edges end to end.
//
// ★ THE EXPAND crosses a cut edge like any other face edge ("expand grows it in EVERY direction",
// his 2026-09-23 ruling) unless that edge is a seam.

import Foundation
import simd

public enum LatticeSectorOutline {

    public typealias Loop = [SIMD2<Double>]
    public typealias ResolvedFace = LatticeRegionEmission.ResolvedFace

    /// A vertex this close (mm) to a cut is ON it.
    static let snapMM = 1e-7
    /// How far (mm) past the cut a side test looks — beyond the snap band.
    static let probeMM = 1e-5
    /// A loop smaller than this (mm²) is a sliver of arithmetic, not surface.
    static let minAreaMM2 = 1e-9

    // MARK: - the words (his rule: never "Frozen", never "Out of regime")

    /// ★ THE ROW CHIP AND THE DRAWER HEADLINE for a region whose lattice choice reaches no run (a
    /// piece with no surface on this model, a stale region). ★ BATCH E REVIEW: two words, either way
    /// — the chip sits in a 9 pt capsule beside Lattice / Solid / Off / depth, where "Frozen, not
    /// latticed" wrapped to two lines (img 4) and "Protected, not latticed" would too; the group's
    /// shield already says Protected. (`protected` is kept so the hooks read the same.)
    public static func notLatticedWords(protected: Bool) -> String {
        "Not latticed"
    }

    /// ★ BATCH E REVIEW: a card's held voxels scaled to the piece's share of its face (nil ⇒ the face's).
    public static func heldVoxels(_ voxels: Int, share: Double?) -> Int {
        guard let share, share.isFinite else { return voxels }
        return Int((Double(voxels) * Swift.max(0, Swift.min(1, share))).rounded())
    }

    // MARK: - one face, clipped to one piece

    /// The shapes face `f` contributes to a piece bounded by each of `cutSets` (one set per leaf of a
    /// union; `[[]]` — or any empty set — means the whole face).
    public struct Pieces {
        public var shapes: [ResolvedFace]
        /// The shapes were clipped to a piece (not the face as it always was).
        public var clipped: Bool
        /// The face has a shape and the piece holds none of it: not a SKIPPED face.
        public var clippedAway: Bool
    }

    public static func pieces(_ f: FaceID, cutSets: [[RegionCut]],
                              resolve: (FaceID) -> ResolvedFace?,
                              facets: (FaceID) -> [ResolvedFace]) -> Pieces {
        // ★ no cut ⇒ exactly the shapes the emission always took for this face
        if cutSets.isEmpty || cutSets.contains(where: { $0.isEmpty }) {
            if let r = resolve(f) { return Pieces(shapes: [r], clipped: false, clippedAway: false) }
            return Pieces(shapes: facets(f), clipped: false, clippedAway: false)
        }
        let whole = resolve(f)
        var planar = false
        if let w = whole, case .plane = w { planar = true }
        // a cylinder (or a face with no single surface) is cut through its planar facets
        let base: [ResolvedFace] = planar ? [whole!] : facets(f)
        var out: [ResolvedFace] = []
        for cuts in cutSets {
            var kept: [ResolvedFace] = []
            var untouched = true
            for b in base {
                let (r, changed) = clipReport(b, to: cuts, ownFace: f)
                if changed { untouched = false }
                if let r { kept.append(r) }
            }
            // ★ a whole CYLINDER inside the piece stays the bolt it always was
            if !planar, untouched, kept.count == base.count, let w = whole { out.append(w); continue }
            out += kept
        }
        // a face whose shapes have no outline to clip is SKIPPED (as unclipped), not clipped away
        let clippable = base.contains { if case let .plane(_, _, _, _, l, _) = $0 { return !l.isEmpty }; return false }
        return Pieces(shapes: out, clipped: true, clippedAway: out.isEmpty && clippable)
    }

    /// `face` clipped to every half-space of `cuts` (a point p is kept where
    /// `dot(p − point, normal) ≥ 0`); nil when nothing remains or the face is not a plane. Surviving
    /// edges keep the face across them; a new cut edge reads `ownFace`.
    public static func clip(_ face: ResolvedFace, to cuts: [RegionCut], ownFace: FaceID) -> ResolvedFace? {
        clipReport(face, to: cuts, ownFace: ownFace).face
    }

    static func clipReport(_ face: ResolvedFace, to cuts: [RegionCut],
                           ownFace: FaceID) -> (face: ResolvedFace?, changed: Bool) {
        guard case let .plane(center, normal, _, _, loops, neighbours) = face, !loops.isEmpty else { return (nil, true) }
        // the face's own frame — the one `LatticeFaceOutline` projected its loops into
        let (bu, bv) = LatticeRegionMask.basis(ManualPrimitive.unit(normal))
        var ls = loops
        var nb: [[FaceID?]] = loops.indices.map { l in
            loops[l].indices.map { i in l < neighbours.count && i < neighbours[l].count ? neighbours[l][i] : nil }
        }
        var changed = false
        for c in cuts {
            let n = ManualPrimitive.unit(c.normal)
            guard simd_length(n) > 0.5 else { continue }
            // dot(center + u·bu + v·bv − point, n) = u·(bu·n) + v·(bv·n) + (center − point)·n
            let a = SIMD2(simd_dot(bu, n), simd_dot(bv, n))
            guard let r = halfPlane(ls, nb, a: a, c: simd_dot(center - c.point, n), own: ownFace) else { continue }
            ls = r.loops; nb = r.neighbours; changed = true
            if ls.isEmpty { return (nil, true) }
        }
        guard changed else { return (face, false) }
        var hu = 0.0, hw = 0.0
        for l in ls { for q in l { hu = Swift.max(hu, abs(q.x)); hw = Swift.max(hw, abs(q.y)) } }
        return (.plane(center: center, normal: normal, halfUMM: hu, halfWMM: hw,
                       outlineLoops: ls, neighbours: nb), true)
    }

    // MARK: - one half-plane

    struct Clipped { var loops: [Loop]; var neighbours: [[FaceID?]] }

    /// The even-odd region of `loops` cut to `a·q + c ≥ 0`. nil ⇒ every vertex already lies on the
    /// kept side (nothing to do). The result's loops are SIMPLE: where a cut crosses a concave
    /// outline twice the pieces come back as separate loops, never joined by a zero-width bridge
    /// along the cut (a bridge would be an outline edge over air, and every rim reads edges).
    static func halfPlane(_ loops: [Loop], _ nbrs: [[FaceID?]], a: SIMD2<Double>, c: Double,
                          own: FaceID) -> Clipped? {
        let la = simd_length(a)
        if la < 1e-12 { return c >= -snapMM ? nil : Clipped(loops: [], neighbours: []) }   // parallel to the face
        let nh = a / la, off = c / la                          // signed distance in mm
        func s(_ q: SIMD2<Double>) -> Double { let v = simd_dot(nh, q) + off; return abs(v) < snapMM ? 0 : v }
        var anyIn = false, anyOut = false
        for l in loops where l.count >= 3 {
            for q in l { let v = s(q); if v > 0 { anyIn = true } else if v < 0 { anyOut = true } }
        }
        if !anyOut { return nil }
        if !anyIn { return Clipped(loops: [], neighbours: []) }
        return split(loops, nbrs, nh: nh, off: off, own: own, s: s)
            ?? sutherlandHodgman(loops, nbrs, own: own, s: s)
    }

    /// The exact clip: keep the boundary on the kept side, then close it ALONG the cut wherever the
    /// region lies just past it, then chain the pieces into loops. nil when the pieces do not close
    /// (arithmetic at a near-tangent edge) — the caller falls back to Sutherland–Hodgman.
    static func split(_ loops: [Loop], _ nbrs: [[FaceID?]], nh: SIMD2<Double>, off: Double,
                      own: FaceID, s: (SIMD2<Double>) -> Double) -> Clipped? {
        struct Seg { var p: SIMD2<Double>; var q: SIMD2<Double>; var nb: FaceID? }
        let src = loops.filter { $0.count >= 3 }
        let along = SIMD2(-nh.y, nh.x)
        func inside(_ q: SIMD2<Double>) -> Bool { LatticeFaceOutline.contains(q, loops: src) }
        var segs: [Seg] = []
        var onCut: [(t: Double, p: SIMD2<Double>)] = []
        var keptOnCut: [(lo: Double, hi: Double)] = []
        for (l, loop) in loops.enumerated() where loop.count >= 3 {
            let m = loop.count
            for i in 0..<m {
                let p = loop[i], q = loop[(i + 1) % m]
                let sp = s(p), sq = s(q)
                let nb: FaceID? = l < nbrs.count && i < nbrs[l].count ? nbrs[l][i] : nil
                if sp == 0 { onCut.append((simd_dot(along, p), p)) }
                if sp == 0, sq == 0 {
                    // an edge lying ON the cut stays only where the region is on the kept side of it
                    let mid = 0.5 * (p + q)
                    if inside(mid + nh * probeMM) {
                        segs.append(Seg(p: p, q: q, nb: nb))
                        let t0 = simd_dot(along, p), t1 = simd_dot(along, q)
                        keptOnCut.append((Swift.min(t0, t1), Swift.max(t0, t1)))
                    }
                } else if sp >= 0, sq >= 0 {
                    segs.append(Seg(p: p, q: q, nb: nb))
                } else if (sp > 0 && sq < 0) || (sp < 0 && sq > 0) {
                    let x = p + (q - p) * (sp / (sp - sq))
                    onCut.append((simd_dot(along, x), x))
                    segs.append(sp > 0 ? Seg(p: p, q: x, nb: nb) : Seg(p: x, q: q, nb: nb))
                }
            }
        }
        // the new boundary: every stretch of the cut with the region just past it
        onCut.sort { $0.t < $1.t }
        var stops: [(t: Double, p: SIMD2<Double>)] = []
        for e in onCut where stops.last.map({ e.t - $0.t > 1e-9 }) ?? true { stops.append(e) }
        if stops.count >= 2 {
            for k in 0..<(stops.count - 1) {
                let a = stops[k], b = stops[k + 1]
                let tm = 0.5 * (a.t + b.t)
                if keptOnCut.contains(where: { tm > $0.lo && tm < $0.hi }) { continue }
                if inside(0.5 * (a.p + b.p) + nh * probeMM) { segs.append(Seg(p: a.p, q: b.p, nb: own)) }
            }
        }
        guard !segs.isEmpty else { return Clipped(loops: [], neighbours: []) }
        // chain: vertices by position (the cut points are shared values, so they meet exactly)
        struct Key: Hashable { let x: Int64, y: Int64 }
        func key(_ p: SIMD2<Double>) -> Key { Key(x: Int64((p.x * 1e8).rounded()), y: Int64((p.y * 1e8).rounded())) }
        var ends: [(Key, Key)] = []
        var adj: [Key: [Int]] = [:]
        var pos: [Key: SIMD2<Double>] = [:]
        for (i, sg) in segs.enumerated() {
            let ka = key(sg.p), kb = key(sg.q)
            ends.append((ka, kb))
            pos[ka] = pos[ka] ?? sg.p; pos[kb] = pos[kb] ?? sg.q
            if ka == kb { continue }                           // a point, not an edge
            adj[ka, default: []].append(i); adj[kb, default: []].append(i)
        }
        guard adj.values.allSatisfy({ $0.count % 2 == 0 }) else { return nil }
        func kept(_ q: SIMD2<Double>) -> Bool { s(q) > 0 && inside(q) }
        var used = [Bool](repeating: false, count: segs.count)
        for (i, e) in ends.enumerated() where e.0 == e.1 { used[i] = true }
        var outLoops: [Loop] = [], outNb: [[FaceID?]] = []
        for start in segs.indices where !used[start] {
            used[start] = true
            let first = ends[start].0
            var pts: Loop = [pos[first]!], nbs: [FaceID?] = [segs[start].nb]
            var prev = first, cur = ends[start].1
            var steps = 0
            while cur != first {
                steps += 1
                guard steps <= segs.count + 1 else { return nil }
                let cands = (adj[cur] ?? []).filter { !used[$0] }
                guard !cands.isEmpty else { return nil }
                var pick = cands[0]
                if cands.count > 1 {
                    // ★ at a pinch (two pieces touching at one point) stay on the SAME piece: turn
                    // towards the side the region lies on, so no loop crosses itself
                    let pc = pos[cur]!, pp = pos[prev]!
                    let din = pc - pp
                    let leftN = simd_normalize(SIMD2(-din.y, din.x))
                    let regionLeft = kept(0.5 * (pc + pp) + leftN * probeMM * 10)
                    func turn(_ j: Int) -> Double {
                        let other = ends[j].0 == cur ? ends[j].1 : ends[j].0
                        let dout = pos[other]! - pc
                        return atan2(din.x * dout.y - din.y * dout.x, simd_dot(din, dout))
                    }
                    pick = regionLeft ? cands.max { turn($0) < turn($1) }! : cands.min { turn($0) < turn($1) }!
                }
                used[pick] = true
                pts.append(pos[cur]!); nbs.append(segs[pick].nb)
                let next = ends[pick].0 == cur ? ends[pick].1 : ends[pick].0
                prev = cur; cur = next
            }
            if pts.count >= 3, abs(area(pts)) > minAreaMM2 { outLoops.append(pts); outNb.append(nbs) }
        }
        return Clipped(loops: outLoops, neighbours: outNb)
    }

    /// The textbook clip, per loop — always closed, even where a concave outline leaves a bridge of
    /// no width along the cut. Only reached when `split`'s pieces do not close.
    static func sutherlandHodgman(_ loops: [Loop], _ nbrs: [[FaceID?]], own: FaceID,
                                  s: (SIMD2<Double>) -> Double) -> Clipped {
        var outLoops: [Loop] = [], outNb: [[FaceID?]] = []
        for (l, loop) in loops.enumerated() where loop.count >= 3 {
            let m = loop.count
            // each output vertex with the face across the edge ARRIVING at it
            var vs: Loop = [], arrive: [FaceID?] = []
            for i in 0..<m {
                let p = loop[i], q = loop[(i + 1) % m]
                let sp = s(p), sq = s(q)
                let nb: FaceID? = l < nbrs.count && i < nbrs[l].count ? nbrs[l][i] : nil
                if sp >= 0, sq >= 0 {
                    vs.append(q); arrive.append(nb)
                } else if sp >= 0, sq < 0 {
                    if sp > 0 { vs.append(p + (q - p) * (sp / (sp - sq))); arrive.append(nb) }
                } else if sp < 0, sq >= 0 {
                    let x = sq > 0 ? p + (q - p) * (sp / (sp - sq)) : q
                    vs.append(x); arrive.append(own)              // along the cut, from the last exit
                    if sq > 0 { vs.append(q); arrive.append(nb) }
                }
            }
            guard vs.count >= 3, abs(area(vs)) > minAreaMM2 else { continue }
            // edge i runs vs[i] → vs[i+1]; its face is the one arriving at vs[i+1]
            outLoops.append(vs)
            outNb.append(vs.indices.map { arrive[($0 + 1) % vs.count] })
        }
        return Clipped(loops: outLoops, neighbours: outNb)
    }

    static func area(_ loop: Loop) -> Double {
        var a = 0.0
        for i in loop.indices { let p = loop[i], q = loop[(i + 1) % loop.count]; a += p.x * q.y - q.x * p.y }
        return 0.5 * a
    }

    /// The even-odd area of a set of loops (mm²), measured on a fine grid-free basis: Σ ±|loop| by
    /// nesting depth. For the tests and the receipts.
    public static func evenOddArea(_ loops: [Loop]) -> Double {
        var total = 0.0
        for (i, l) in loops.enumerated() where l.count >= 3 {
            // a loop nested inside an odd number of others is a hole
            let probe = l[0]
            var depth = 0
            for (j, o) in loops.enumerated() where j != i && o.count >= 3 {
                if LatticeFaceOutline.contains(probe, loops: [o]) { depth += 1 }
            }
            total += (depth % 2 == 0 ? 1 : -1) * abs(area(l))
        }
        return total
    }

    // MARK: - a piece meets its neighbours at a T

    /// ★ Split every edge where a piece's edge starts or stops along it, so `finishSeams` — which
    /// decides an edge WHOLE (end to end, or by its midpoint) — decides each stretch on its own:
    ///   * a piece cut again: the long cut edge of its sibling is split at the T, so the half and
    ///     the two quarters cut from it pair as seams;
    ///   * ★ (batch E review) a face whose edge only HALF borders a latticed piece (face 2's top edge
    ///     under top A, x 50…100, and under unlatticed top B, x 0…50): split at x = 50, the stretch
    ///     under top A is a seam and the one under top B stays a RIM. Unsplit, the edge's midpoint
    ///     lay on top A's edge and the whole edge lost its rim.
    /// A pair is split only when one of the two is a piece: with no piece the prisms are untouched.
    static func meetAtTJunctions(_ out: inout [LatticeRegionSpec], pieces: Set<Int>) {
        guard !pieces.isEmpty else { return }
        func world(_ r: LatticeRegionSpec) -> ((SIMD2<Double>) -> SIMD3<Double>)? {
            let n = LatticeRegionMask.unit(r.normal)
            guard simd_length(n) > 0.5 else { return nil }
            let (bu, bv) = LatticeRegionMask.basis(n)
            return { r.origin + bu * $0.x + bv * $0.y }
        }
        var verts: [(region: Int, p: SIMD3<Double>)] = []
        for (i, r) in out.enumerated() where r.kind == .face && r.role == .include {
            guard let w = world(r) else { continue }
            for loop in r.outlineLoops { for q in loop { verts.append((i, w(q))) } }
        }
        let tolMM = 1e-4
        for ri in out.indices where out[ri].kind == .face && out[ri].role == .include {
            guard let w = world(out[ri]) else { continue }
            // a piece meets every latticed prism; any other prism meets the pieces only
            let others = verts.filter { $0.region != ri && (pieces.contains(ri) || pieces.contains($0.region)) }
            guard !others.isEmpty else { continue }
            var loops = out[ri].outlineLoops, seams = out[ri].outlineSeams, faces = out[ri].outlineSeamFaces
            var changed = false
            for l in loops.indices {
                let loop = loops[l]
                let hasF = l < faces.count && faces[l].count == loop.count
                let hasS = l < seams.count && seams[l].count == loop.count
                var nl: Loop = [], ns: [Bool] = [], nf: [Int?] = []
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    let fi: Int? = hasF ? faces[l][i] : nil
                    let si = hasS ? seams[l][i] : false
                    nl.append(a); ns.append(si); nf.append(fi)
                    let A = w(a), d = w(b) - A
                    let len = simd_length(d)
                    guard len > 2 * tolMM else { continue }
                    var ts: [Double] = []
                    for o in others {
                        let t = simd_dot(o.p - A, d) / (len * len)
                        guard t * len > tolMM, (1 - t) * len > tolMM,
                              simd_length(o.p - (A + d * t)) < tolMM else { continue }
                        ts.append(t)
                    }
                    var last = -1.0
                    for t in ts.sorted() where t - last > tolMM / len {
                        last = t
                        nl.append(a + (b - a) * t); ns.append(si); nf.append(fi)
                        changed = true
                    }
                }
                loops[l] = nl
                if hasS { seams[l] = ns }
                if hasF { faces[l] = nf }
            }
            if changed {
                out[ri].outlineLoops = loops
                out[ri].outlineSeams = seams
                out[ri].outlineSeamFaces = faces
            }
        }
    }
}

// MARK: - the project's side: which pieces, which cuts, and the one surface told once

extension ProjectModel {

    /// ★ BATCH E: the members of a split piece — or of a union of pieces — that the lattice
    /// reaches: every member face with surface on the piece's side of its cuts. nil when none has
    /// (the region is then named, never dropped silently — ruling (g)).
    func latticeSectorMembers(_ rid: RegionID) -> [FaceID]? {
        guard let mesh = viewerMesh else { return nil }
        var out = Set<FaceID>()
        for leaf in faceRegions.resolvedLeaves(rid) {
            guard let r = faceRegions.region(leaf) else { continue }
            for f in FaceRegionGeometry.members(of: r, in: mesh) where !out.contains(f) {
                if r.cuts.isEmpty || latticeSectorHasSurface(f, cuts: r.cuts, in: mesh) { out.insert(f) }
            }
        }
        return out.isEmpty ? nil : out.sorted()
    }

    /// The half-space sets face `f` is clipped to under region `rid`: one per leaf of a union that
    /// holds `f`; `[[]]` — the whole face — for a region with no cut (so the emission is unchanged).
    func latticeRegionCutSets(_ rid: RegionID, face f: FaceID) -> [[RegionCut]] {
        guard let r = faceRegions.region(rid), !r.cuts.isEmpty || r.isUnionOfParts,
              let mesh = viewerMesh else { return [[]] }
        var sets: [[RegionCut]] = []
        for leaf in faceRegions.resolvedLeaves(rid) {
            guard let p = faceRegions.region(leaf), FaceRegionGeometry.members(of: p, in: mesh).contains(f)
            else { continue }
            if p.cuts.isEmpty { return [[]] }                   // a whole-face leaf covers the face
            sets.append(p.cuts)
        }
        return sets.isEmpty ? [[]] : sets
    }

    /// ★ ONE SURFACE, TOLD ONCE: the members the emission takes for region `rid` in group `gid` —
    /// nil when an ANCESTOR in the same group (the union a piece was combined into, the face it was
    /// cut from) already emits that surface with the same role. That is ruling (g)'s own test in
    /// `latticeDroppedRegionName`, so a piece told by its ancestor is never named as left out, and a
    /// piece with a role of its own is emitted. With no ancestor (every unsplit project) this IS
    /// `latticeRegionMembers`.
    func latticeEmittedRegionMembers(_ gid: UUID, _ rid: RegionID) -> [FaceID]? {
        guard let members = latticeRegionMembers(rid) else { return nil }
        guard let r = faceRegions.region(rid), faceRegions.region(r.parentID) != nil,
              let g = selection.groups.first(where: { $0.id == gid }) else { return members }
        let groupRole = latticeEligibleRoles()[gid]
        func role(_ id: RegionID) -> LatticeGroupRole? {
            LatticeSelectableRoles.role(for: .region(group: gid, region: id), groupRole: groupRole,
                                        overrides: lattice.selectableRoles)
        }
        let own = role(rid)
        var seen: Set<RegionID> = [rid]
        var up = r.parentID
        while let a = faceRegions.region(up), !seen.contains(a.id) {
            seen.insert(a.id)
            if g.regionIDs.contains(a.id), latticeRegionMembers(a.id) != nil, role(a.id) == own { return nil }
            up = a.parentID
        }
        return members
    }

    /// Whether face `f` keeps any surface inside `cuts` — memoised per mesh, because the Selections
    /// rows ask it on every pass and resolving a face outline walks the mesh.
    func latticeSectorHasSurface(_ f: FaceID, cuts: [RegionCut], in mesh: ViewerMesh) -> Bool {
        let key = "\(mesh.signature.contentHash)|\(mesh.signature.topologyHash)|\(f)|"
            + cuts.map { "\($0.point.x),\($0.point.y),\($0.point.z),\($0.normal.x),\($0.normal.y),\($0.normal.z),\($0.strict)" }
                .joined(separator: ";")
        if let hit = LatticeSectorSurfaceMemo.byKey[key] { return hit }
        let p = LatticeSectorOutline.pieces(f, cutSets: [cuts],
                                            resolve: { LatticeRegionEmission.planeFor(face: $0, in: mesh) },
                                            facets: { LatticeFaceFacets.facets(face: $0, in: mesh) })
        let has = !p.shapes.isEmpty
        if LatticeSectorSurfaceMemo.byKey.count > 4096 { LatticeSectorSurfaceMemo.byKey = [:] }
        LatticeSectorSurfaceMemo.byKey[key] = has
        return has
    }
}

extension ProjectModel {

    /// ★ BATCH E: the surface a split piece covers — its member faces' triangles CLIPPED to the
    /// piece's half-spaces, welded — so the Selections row's 3D depth primitive (`FaceOffsetShell`)
    /// sits over the piece and not over the whole face it was cut from. nil for a region with no cut
    /// (or a union of pieces, which draws no primitive today): that path is unchanged.
    func latticeSectorMesh(_ rid: RegionID) -> ViewerMesh? {
        guard let r = faceRegions.region(rid), !r.cuts.isEmpty, !r.isUnionOfParts, let mesh = viewerMesh
        else { return nil }
        let members = Set(FaceRegionGeometry.members(of: r, in: mesh).map { Int32($0) })
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        struct Key: Hashable { let x: Int64, y: Int64, z: Int64 }
        var weld: [Key: Int32] = [:]
        func vid(_ p: SIMD3<Double>) -> Int32 {
            let k = Key(x: Int64((p.x * 1e5).rounded()), y: Int64((p.y * 1e5).rounded()), z: Int64((p.z * 1e5).rounded()))
            if let i = weld[k] { return i }
            let i = Int32(v.count / 3)
            v += [Float(p.x), Float(p.y), Float(p.z)]
            weld[k] = i
            return i
        }
        func at(_ i: UInt32) -> SIMD3<Double> {
            let b = Int(i) * 3
            return SIMD3(Double(mesh.positions[b]), Double(mesh.positions[b + 1]), Double(mesh.positions[b + 2]))
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            defer { t += 3 }
            guard tri < mesh.faceIDs.count, members.contains(mesh.faceIDs[tri]) else { continue }
            let poly = SurfacePatternAxis.clipPolygon([at(mesh.indices[t]), at(mesh.indices[t + 1]), at(mesh.indices[t + 2])],
                                                      to: r.cuts)
            guard poly.count >= 3 else { continue }
            let ids = poly.map(vid)
            for k in 1..<(ids.count - 1) where ids[0] != ids[k] && ids[k] != ids[k + 1] && ids[0] != ids[k + 1] {
                idx += [ids[0], ids[k], ids[k + 1]]
                fid.append(mesh.faceIDs[tri])
            }
        }
        guard !idx.isEmpty else { return nil }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid, faceGeometry: mesh.faceGeometry)
    }
}

extension ProjectModel {

    /// ★ BATCH E REVIEW: the share of its card's face a CUT piece covers, by key. The drawer's card is
    /// built on a region's first member face (`latticeCardFace`, #354's rule) — for a piece that read
    /// the WHOLE face's grams (top A "Hands over 218.5 g" for a slab of half the top). Area of the
    /// face clipped to the piece over the face's own area, both in the face's own frame (each planar
    /// facet of a curved face). Only pieces are listed: every other card is its face, unchanged.
    public func latticeCardHeldShares() -> [String: Double] {
        guard let mesh = viewerMesh else { return [:] }
        var out: [String: Double] = [:]
        func area(_ shapes: [LatticeRegionEmission.ResolvedFace]) -> Double? {
            var total = 0.0
            for sh in shapes {
                guard case let .plane(_, _, _, _, loops, _) = sh, !loops.isEmpty else { return nil }
                total += LatticeSectorOutline.evenOddArea(loops)
            }
            return total
        }
        for g in selection.groups where lattice.groupRoles[g.id] != nil {
            for ref in latticeSelectableRefs(g) {
                guard case let .region(_, rid) = ref, let r = faceRegions.region(rid), !r.cuts.isEmpty,
                      let f = latticeCardFace(ref, in: g) else { continue }
                let resolved = LatticeRegionEmission.planeFor(face: f, in: mesh)
                let facets = LatticeFaceFacets.facets(face: f, in: mesh)
                var planar = false
                if let w = resolved, case .plane = w { planar = true }
                guard let whole = area(planar ? [resolved!] : facets), whole > 1e-9 else { continue }
                let piece = LatticeSectorOutline.pieces(f, cutSets: latticeRegionCutSets(rid, face: f),
                                                        resolve: { _ in resolved }, facets: { _ in facets })
                guard let kept = area(piece.shapes) else { continue }   // a cylinder kept whole: the face's
                out[ref.key] = Swift.max(0, Swift.min(1, kept / whole))
            }
        }
        return out
    }
}

enum LatticeSectorSurfaceMemo {
    @MainActor static var byKey: [String: Bool] = [:]
}
