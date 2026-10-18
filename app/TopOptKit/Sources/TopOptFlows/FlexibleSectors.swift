// FlexibleSectors — the Flexible stage's OWN sectors (task 2026-09-29-flexible-screens, round 7 batch M2; the reviewer's
// ruling 3 on the 2026-10-14 outbox: "Lattice sections under a face-prism on the Squish page: FLEXIBLE-ONLY sectors carried
// in the job, NOT Surface-stage sectors (his Oct 10 reversal kept group types separate; nothing reaches other stages until
// he approves on Flexible). If I2 already writes Surface sectors, move them to Flexible-only and say what moved.").
//
// ★ WHAT THEY ARE. Three kinds, all Flexible-only:
//   * a lattice SECTION — the part of a face (or of his own Surface leaf sector) inside a face-prism, when the face is only
//     partly inside one (FlexibleLatticeSections; his img3 words);
//   * an edge/corner STRIP (I2's, round 6 item 2) — nested inside its section (D6);
//   * a strip's REST — what of the section (or the whole face) no strip takes.
// ★ WHERE THEY LIVE. Their NUMBER in `FlexibleStageSettings.sectors` (by a stable ROLE key, never geometry: "s:<root>:<prism
// key>#<facet>", "p:<press>:<member>", "rest:<parent>:<n>"); their GEOMETRY derived here every time, from the face-prisms
// (Selections' include specs), the strips and his Surface regions, on a SCRATCH copy of the regions — the Surface tool's
// own calls (union / splitManual / splitDetached / revertSplit), never assigned to the project. Declared only in the
// Flexible scene and run jobs: `loads.face_regions` id = `base` + number (core 099dcaed takes any unique non-negative id,
// cuts in any number, one entry per region; shared_footprint is checked among LOADED entries). The Surface stage,
// Topology, the lattice stage's job and the Stress solve never see one (`project.faceRegions` is untouched).
// ★ ONLY LEAVES ARE DECLARED (a section a strip cut is its strip and rests), and the unlatticed rest of a face is not.

import Foundation
import simd

/// One Flexible-only sector: a lattice SECTION (the part of a face, or of his own Surface sector, inside a face-prism), an
/// edge/corner STRIP, or a strip's REST.
public struct FlexibleSector: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case section, strip, rest }
    /// Its stable ROLE key (never geometry): "s:<root>:<prism key>#<k>", "p:<press>:<member>", "rest:<parent>:<n>".
    public let key: String
    public let number: Int
    public var wireID: Int { FlexibleSectors.base + number }
    /// The region the job declares (id = FlexibleRegions' sector offset away from the wire id).
    public let region: FaceRegion
    public let kind: Kind
    /// The section key, or the root token, it belongs to (a section: its own key).
    public let chain: String
    /// "f<face>" (a whole face) or "r<FaceRegion id>" (his Surface sector).
    public let rootToken: String
    /// The root as a Flexible region id: the face id, or his Surface sector's wire id.
    public let rootRegion: Int
    /// A strip piece's press and member index.
    public let press: UUID?
    public let member: Int?
    /// The section it lies in (a section: itself; a strip or rest on a whole root: nil).
    public let sectionKey: String?
}

/// Every Flexible-only sector of the part as it is now, and what each root is.
public struct FlexibleSectorSet: Equatable, Sendable {
    public var pieces: [FlexibleSector] = []
    /// Roots partly inside a face-prism (root region id → its section keys).
    public var partialRoots: [Int: [String]] = [:]
    /// Roots wholly inside a face-prism.
    public var wholeRoots: Set<Int> = []
    /// Roots a face-prism meets that cannot be cut into sections yet (D4) → the one line.
    public var notYet: [Int: String] = [:]
    /// Strip picks that cannot be cut → the one line.
    public var refused: [UUID: String] = [:]
    /// A kept strip that was clipped or has no lattice under it → the one line (said once on its card).
    public var notes: [UUID: String] = [:]
    /// Each strip press's regions (Flexible wire ids, member order).
    public var stripRegions: [UUID: [Int]] = [:]

    public init() {}
    public static let empty = FlexibleSectorSet()
    public var isEmpty: Bool { pieces.isEmpty }
    public func piece(_ wireID: Int) -> FlexibleSector? { pieces.first { $0.wireID == wireID } }
    public func piece(key: String) -> FlexibleSector? { pieces.first { $0.key == key } }
}

public enum FlexibleSectors {
    /// Flexible-only sector wire ids start here (his Surface sectors are FlexibleRegions.sectorBase + id, below it).
    public static let base = 2_000_000
    public static func isFlexible(_ id: Int) -> Bool { id >= base }

    /// ★ RED CONTROL (FlexibleSectorStoreTests): I2's route — the strips are ALSO written into `project.faceRegions` (the
    /// Surface stage's regions), so Topology, the Lattice stage and the Stress solve see them.
    @MainActor static var controlSurfaceRoute = false
    /// ★ RED CONTROL (numbers): a new key takes the smallest free number (a number of a key gone this session recycled).
    nonisolated(unsafe) static var controlRecycle = false

    /// The id offset between a Flexible sector's wire id and its synthesized FaceRegion's id (FlexibleRegions.wireID).
    static var regionOffset: Int { base - FlexibleRegions.sectorBase }

    /// A ROOT: a whole face, or his own Surface leaf sector (FlexibleMeet's partition over the project's regions).
    struct Root {
        let token: String          // "f<face>" / "r<FaceRegion id>"
        let region: Int            // the face id, or the sector's wire id
        let sectorID: RegionID?    // his sector's FaceRegion id
        let faces: [Int]
        let name: String
        let polys: [[SIMD3<Double>]]
        let area: Double
        let lo: SIMD3<Double>, hi: SIMD3<Double>
    }

    /// The roots of the part: his Surface LEAF sectors, then every face no leaf covers (FlexibleMeet's rule).
    static func roots(mesh: ViewerMesh, faceRegions: FaceRegionModel) -> [Root] {
        let own = FlexibleRegions(model: faceRegions, mesh: mesh)
        let parents = Set(own.sectors.map(\.parentID))
        let n = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        var trisOf: [Int: [[SIMD3<Double>]]] = [:]
        for t in 0..<n {
            trisOf[Int(mesh.faceIDs[t]), default: []].append((0..<3).map { FlexibleMeet.position(mesh, mesh.indices[3 * t + $0]) })
        }
        func make(_ token: String, _ region: Int, _ sid: RegionID?, _ faces: [Int], _ name: String, _ cuts: [RegionCut]) -> Root? {
            let polys = faces.flatMap { trisOf[$0] ?? [] }.map { cuts.isEmpty ? $0 : FlexibleMeet.clipPolygon($0, cuts) }.filter { $0.count >= 3 }
            guard !polys.isEmpty else { return nil }
            var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
            for p in polys.joined() { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            return Root(token: token, region: region, sectorID: sid, faces: faces, name: name, polys: polys,
                        area: polys.reduce(0) { $0 + FlexibleMeet.area($1) }, lo: lo, hi: hi)
        }
        var out: [Root] = []
        var covered = Set<Int>()
        for sec in own.sectors.sorted(by: { $0.id < $1.id }) where !parents.contains(sec.id) {
            let faces = FaceRegionGeometry.members(of: sec, in: mesh).map { Int($0) }.filter { trisOf[$0] != nil }
            guard !faces.isEmpty else { continue }
            covered.formUnion(faces)
            let name = FlexibleRowCopy.faceName(sector: sec.name, face: faces[0])
            if let r = make("r\(sec.id)", FlexibleRegions.wireID(sec), sec.id, faces, name, sec.cuts) { out.append(r) }
        }
        for f in trisOf.keys.sorted() where !covered.contains(f) {
            if let r = make("f\(f)", f, nil, [f], "Face \(f)", []) { out.append(r) }
        }
        return out
    }

    /// The root token a key grows from ("s:<token>:…", "rest:<parent>:<n>" — a parent being a section key or a token).
    public static func rootToken(ofKey key: String) -> String? {
        if key.hasPrefix("s:") { return key.dropFirst(2).split(separator: ":", maxSplits: 1).first.map(String.init) }
        if key.hasPrefix("rest:") {
            let body = String(key.dropFirst(5))
            guard let i = body.lastIndex(of: ":") else { return nil }
            let parent = String(body[..<i])
            return parent.hasPrefix("s:") ? rootToken(ofKey: parent) : parent
        }
        return nil
    }

    /// The root region of a token now: a face id, or his sector's wire id (its face when the sector is gone).
    static func rootRegion(token: String, faceRegions: FaceRegionModel, mesh: ViewerMesh?) -> Int? {
        if token.hasPrefix("f") { return Int(token.dropFirst()) }
        guard token.hasPrefix("r"), let id = Int(token.dropFirst()) else { return nil }
        if let r = faceRegions.region(id) { return FlexibleRegions.wireID(r) }
        return nil
    }

    /// ★ THE PART'S FLEXIBLE SECTORS, derived (pure; the stage model memoises it).
    /// `includes`: Selections' include specs (the face-prisms). `strips`: every edge/corner press's area, in pick order of
    /// storage. `newPicks`: picks being made now — refused where they cannot be cut (D6); a kept strip is clipped and noted.
    /// ★ R7-E1: `cuts` — each press's flat prism (FlexibleFlatPrism.planCut); a strip with none keeps M2's half-spaces.
    static func resolve(mesh: ViewerMesh, faceRegions: FaceRegionModel, includes: [LatticeRegionSpec],
                        strips: [(id: UUID, strip: FlexibleStrip)], cuts: [UUID: FlexibleFlatPrism.Cut] = [:],
                        newPicks: Set<UUID> = [], numbers: FlexibleSectorNumbers) -> FlexibleSectorSet {
        var out = FlexibleSectorSet()
        var scratch = faceRegions
        let roots = Self.roots(mesh: mesh, faceRegions: faceRegions)
        let prisms = FlexibleLatticeSections.controlWholeFace ? [] : FlexibleLatticeSections.prisms(includes)
        let anyPrism = !prisms.isEmpty   // (the whole-face red control: today's — no lattice rule on strips)
        // triangles of a face, once
        var faceTris: [Int: [[SIMD3<Double>]]] = [:]
        func tris(_ f: Int) -> [[SIMD3<Double>]] {
            if let t = faceTris[f] { return t }
            let t = FlexibleEdgeStrips.triangles(face: f, mesh: mesh)
            faceTris[f] = t
            return t
        }
        func area(_ f: Int, _ cuts: [RegionCut]) -> Double { FlexibleEdgeStrips.area(tris(f), cuts) }
        // ── the sections
        struct Section { let key: String; let id: RegionID; let root: Root }
        var sectionsOf: [Int: [Section]] = [:]
        var scratchRoot: [Int: RegionID] = [:]   // root region → its scratch region (a face's identity, made here)
        func scratchID(_ r: Root) -> RegionID {
            if let id = scratchRoot[r.region] { return id }
            let id: RegionID
            if let sid = r.sectorID { id = sid }
            else if let i = FlexibleEdgeStrips.identity(of: r.faces[0], in: scratch) { id = i }
            else { id = scratch.union(faces: [FaceID(r.faces[0])], named: r.name) }
            scratchRoot[r.region] = id
            return id
        }
        for r in roots where !prisms.isEmpty {
            let eps = Swift.max(1e-6, 1e-7 * r.area)
            var whole = false, notYet = false
            var partial: [FlexibleLatticeSections.Prism] = []
            for pr in prisms {
                switch FlexibleLatticeSections.meeting(pr, polys: r.polys, area: r.area, eps: eps, lo: r.lo, hi: r.hi) {
                case .whole: whole = true
                case .notYet: notYet = true
                case .partial: partial.append(pr)
                case .none: break
                }
            }
            if whole { out.wholeRoots.insert(r.region); continue }
            if notYet { out.notYet[r.region] = FlexibleRowCopy.curvedNotYet; continue }
            guard !partial.isEmpty else { continue }
            var free: [RegionID] = [scratchID(r)]
            var made: [Section] = []
            let face = r.faces[0]
            for pr in partial {
                func a(_ id: RegionID) -> Double { area(face, (scratch.region(id)?.cuts ?? []) + pr.relaxed) }
                let hits = free.map { (id: $0, a: a($0)) }.filter { $0.a > eps }
                guard let cur = hits.max(by: { ($0.a, -$0.id) < ($1.a, -$1.id) })?.id else { continue }
                free.removeAll { $0 == cur }
                let have = scratch.region(cur)?.cuts ?? []
                let planes = pr.cuts.filter { area(face, have + [FlexibleLatticeSections.beyond($0)]) > eps }
                let c = FlexibleLatticeSections.carve(&scratch, piece: cur, planes: planes, tris: tris(face), mesh: mesh, eps: eps)
                free += c.beyond
                let inside = c.inside.sorted { centroidKey(scratch, $0, tris(face)).lexicographicallyPrecedes(centroidKey(scratch, $1, tris(face))) }
                for (j, id) in inside.enumerated() {
                    made.append(Section(key: "s:\(r.token):\(pr.key)" + (inside.count > 1 ? ".\(j)" : ""), id: id, root: r))
                }
            }
            guard !made.isEmpty else { continue }
            // ★ face-prisms that TOGETHER cover the whole root (his split top's two halves, each through the pad): the root is
            // wholly latticed — the face itself, its id and bytes unchanged (D1); only a solid rest makes sections
            let remainder = free.reduce(0.0) { $0 + area(face, scratch.region($1)?.cuts ?? []) }
            if remainder <= Swift.max(eps, 1e-4 * r.area), !FlexibleLatticeSections.controlAlwaysCut {
                out.wholeRoots.insert(r.region)
                continue
            }
            // names by position: "Face 1 · lattice A", "… B"
            let ordered = made.sorted { centroidKey(scratch, $0.id, tris(face)).lexicographicallyPrecedes(centroidKey(scratch, $1.id, tris(face))) }
            for (i, sec) in ordered.enumerated() {
                scratch.rename(sec.id, to: FlexibleRowCopy.sectionName(root: r.name, index: i, of: ordered.count))
            }
            sectionsOf[r.region] = ordered
            out.partialRoots[r.region] = ordered.map(\.key)
        }
        // ── the strips: each member's chain — the section holding most of its area, else its whole root
        var entries: [FlexibleEdgeStrips.Entry] = []
        var chainOf: [Int: String] = [:]          // plan root (scratch id) → the chain's key (a section key or a root token)
        var sectionOfChain: [String: String] = [:]   // chain → its section key (nil for a whole root)
        var rootOfChain: [String: Root] = [:]
        for (id, strip) in strips {
            var st = strip
            var refusal: String?
            for (k, mb) in strip.members.enumerated() {
                let h = FlexibleFlatPrism.pieceCuts(strip, cut: cuts[id])[k]   // ★ R7-E1: the flat prism's in-face cut
                let fe = Swift.max(1e-6, 1e-7 * area(mb.face, []))
                var cands: [(chain: String, scratch: RegionID?, root: Root, section: String?, a: Double)] = []
                for r in roots where r.faces.contains(mb.face) {
                    if let secs = sectionsOf[r.region] {
                        for sec in secs { cands.append((sec.key, sec.id, r, sec.key, area(mb.face, (scratch.region(sec.id)?.cuts ?? []) + h))) }
                    } else {
                        let rc = r.sectorID.flatMap { faceRegions.region($0)?.cuts } ?? []
                        cands.append((r.token, nil, r, nil, area(mb.face, rc + h)))
                    }
                }
                let sorted = cands.sorted { $0.a > $1.a }
                guard let best = sorted.first, best.a > fe else {
                    refusal = FlexibleRowCopy.fit("\(strip.label) · nothing to press on Face \(mb.face)")
                    break
                }
                let isNew = newPicks.contains(id)
                if sorted.count > 1, sorted[1].a > Swift.max(fe, 1e-3 * best.a) {
                    if isNew { refusal = FlexibleRowCopy.latticeInTwoPlaces(strip.label); break }
                    out.notes[id] = FlexibleRowCopy.latticeInTwoPlaces(strip.label)
                }
                let latticed = best.section != nil || out.wholeRoots.contains(best.root.region) || out.notYet[best.root.region] != nil
                if anyPrism, !latticed {
                    if isNew { refusal = FlexibleRowCopy.noLatticeAt(strip.label); break }
                    out.notes[id] = FlexibleRowCopy.noLatticeAt(strip.label)
                }
                // the plan's root: the section; his Surface sector; the face's identity (made by the plan when none)
                let planRoot: Int
                if let sid = best.scratch { planRoot = sid }
                else if let sid = best.root.sectorID { planRoot = sid }
                else { planRoot = scratchRoot[best.root.region] ?? FlexibleEdgeStrips.identity(of: mb.face, in: scratch) ?? -1 }
                st.members[k].root = planRoot
                if planRoot >= 0 { chainOf[planRoot] = best.chain }
                sectionOfChain[best.chain] = best.section
                rootOfChain[best.chain] = best.root
            }
            if let refusal { out.refused[id] = refusal; continue }
            entries.append(.init(id: id, strip: st, regions: nil, cut: cuts[id]))
        }
        var plan = FlexibleEdgeStrips.Plan(faceRegions: scratch)
        if !entries.isEmpty {
            let replay = Set(entries.flatMap { $0.strip.members.map(\.root) }.filter { $0 >= 0 })
            plan = FlexibleEdgeStrips.plan(entries, replay: replay, faceRegions: scratch,
                                           mesh: mesh, keep: Set(faceRegions.regions.map(\.id)))
            scratch = plan.faceRegions
            // a root the plan made (a face's identity): its chain is the face's root token
            for e in entries {
                guard let filled = plan.strips[e.id] else { continue }
                for (k, mb) in filled.members.enumerated() where chainOf[mb.root] == nil {
                    if let r = roots.first(where: { $0.sectorID == nil && $0.faces == [e.strip.members[k].face] }) {
                        chainOf[mb.root] = r.token
                        sectionOfChain[r.token] = nil
                        rootOfChain[r.token] = r
                    }
                }
            }
            for (id, why) in plan.refused {
                if newPicks.contains(id) { out.refused[id] = why } else { out.notes[id] = why }
            }
        }
        // ── the leaves, keyed by role
        struct Leaf { let key: String; let id: RegionID; let kind: FlexibleSector.Kind; let chain: String; let section: String?
                      let root: Root; let press: UUID?; let member: Int? }
        var leaves: [Leaf] = []
        // the plan roots a strip really cut (a chain whose every pick was refused keeps its piece whole)
        let cut = Set(plan.restIDs.filter { $0.value != [$0.key] }.keys)
        for r in roots {
            if let secs = sectionsOf[r.region] {
                for sec in secs where !cut.contains(sec.id) {
                    leaves.append(Leaf(key: sec.key, id: sec.id, kind: .section, chain: sec.key, section: sec.key, root: r, press: nil, member: nil))
                }
            }
        }
        for (proot, rests) in plan.restIDs.sorted(by: { $0.key < $1.key }) where cut.contains(proot) {
            guard let chain = chainOf[proot], let r = rootOfChain[chain] else { continue }
            let face = r.faces[0]
            let ordered = rests.sorted { centroidKey(scratch, $0, tris(face)).lexicographicallyPrecedes(centroidKey(scratch, $1, tris(face))) }
            for (i, id) in ordered.enumerated() {
                leaves.append(Leaf(key: "rest:\(chain):\(i + 1)", id: id, kind: .rest, chain: chain, section: sectionOfChain[chain] ?? nil,
                                   root: r, press: nil, member: nil))
            }
        }
        for e in entries {
            guard let pieces = plan.pieceIDs[e.id], let filled = plan.strips[e.id] else { continue }
            for (k, id) in pieces.sorted(by: { $0.key < $1.key }) {
                let proot = filled.members[k].root
                guard let chain = chainOf[proot], let r = rootOfChain[chain] else { continue }
                leaves.append(Leaf(key: "p:\(e.id.uuidString):\(k)", id: id, kind: .strip, chain: chain,
                                   section: sectionOfChain[chain] ?? nil, root: r, press: e.id, member: k))
            }
        }
        // ── numbers: every key in sorted order (deterministic for a fresh session)
        let keys = leaves.map(\.key).sorted()
        if controlRecycle { numbers.forget(except: Set(keys)) }
        var number: [String: Int] = [:]
        for k in keys { number[k] = numbers.number(k) }
        for l in leaves.sorted(by: { number[$0.key]! < number[$1.key]! }) {
            guard let src = scratch.region(l.id), let n = number[l.key] else { continue }
            let region = FaceRegion(id: regionOffset + n, name: src.name, filter: src.filter,
                                    filterMatchedAtAuthor: src.filterMatchedAtAuthor, add: src.add, remove: src.remove,
                                    cuts: src.cuts, parentID: l.root.sectorID ?? -1, collapsed: true)
            out.pieces.append(FlexibleSector(key: l.key, number: n, region: region, kind: l.kind, chain: l.chain,
                                             rootToken: l.root.token, rootRegion: l.root.region, press: l.press,
                                             member: l.member, sectionKey: l.section))
        }
        for e in entries {
            let mine = out.pieces.filter { $0.press == e.id }.sorted { ($0.member ?? 0) < ($1.member ?? 0) }
            if !mine.isEmpty { out.stripRegions[e.id] = mine.map(\.wireID) }
        }
        return out
    }

    /// A region's centroid on `tris` as a position key (the order of rests and sections: by position).
    static func centroidKey(_ m: FaceRegionModel, _ id: RegionID, _ tris: [[SIMD3<Double>]]) -> [Int64] {
        let cuts = m.region(id)?.cuts ?? []
        var acc = SIMD3<Double>.zero, a = 0.0
        for t in tris {
            let p = cuts.isEmpty ? t : FlexibleMeet.clipPolygon(t, cuts)
            guard p.count >= 3 else { continue }
            for i in 1..<(p.count - 1) {
                let w = simd_length(simd_cross(p[i] - p[0], p[i + 1] - p[0])) / 2
                acc += (p[0] + p[i] + p[i + 1]) / 3 * w
                a += w
            }
        }
        return FlexibleMeet.qkey(a > 0 ? acc / a : .zero)
    }
}

/// ★ THE NUMBERS (M2): a key keeps its number for the session (undo and redo never renumber it); a new key takes one more
/// than every number seen (the store's and this session's), so a number is NEVER reused. Seeded from the store.
public final class FlexibleSectorNumbers {
    public private(set) var byKey: [String: Int] = [:]
    public init(seed: [String: Int] = [:]) { byKey = seed }

    /// Merge a store's numbers (a key already numbered keeps its session number).
    public func seed(_ ids: [String: Int]) { for (k, n) in ids where byKey[k] == nil { byKey[k] = n } }

    /// The number of `key`, made when new.
    public func number(_ key: String) -> Int {
        if let n = byKey[key] { return n }
        let n: Int
        if FlexibleSectors.controlRecycle {
            let used = Set(byKey.values)
            var k = 1
            while used.contains(k) { k += 1 }
            n = k
        } else {
            n = (byKey.values.max() ?? 0) + 1
        }
        byKey[key] = n
        return n
    }

    /// The key a number was given to, or nil.
    public func key(of number: Int) -> String? { byKey.first { $0.value == number }?.key }

    /// ★ CONTROL ONLY: forget keys not in `live` (what a recycling counter would do).
    func forget(except live: Set<String>) { byKey = byKey.filter { live.contains($0.key) } }
}
