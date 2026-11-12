// FlexibleNewModel — "Upload new version" on a FLEXIBLE part (DATA-MODEL decision 12; UI-Notes' hand-off 2026-11-12 02:51Z, his
// fourth answer: "a Flexible part gets the button once #362 matches Flexible's per-face setup"). His picks of 2026-11-12:
//   1. a pressed face the new model SPLITS: every piece is pressed, with the same settings, in the same squeeze group;
//   2. an edge or corner press is RE-FOUND on the new model where the faces it joined still meet (when its scene opens:
//      `FlexibleStageModel.refindNewModelPresses`), else it is lost;
//   3. what finds no face is KEPT AND FLAGGED: the Squish page lists it with "Pick its face" and the run waits.
// Everything else carries over the same way (decision 12: faces matched by place, then shape — `FaceMatch`). A Flexible part's
// face-prisms ARE its lattice, so they are matched too (never sent back to Auto: that is Topology's answer 3, for the frozen
// Lattice page).
//
// Region ids (FlexibleRegions): a whole face is its FaceID (< 1 000 000); his Surface sector is 1 000 000 + its FaceRegion id
// (its faces are remapped by FaceRegionModel.remapFaces, the id stays; one whose faces are all gone finds none); a Flexible-only
// sector (≥ 2 000 000) is derived from the face-prisms and the strips every time, its number kept by role key (`sectors.ids`,
// whose keys name faces and are remapped here).
import Foundation

/// What the new model's faces could not take yet (FlexibleStageSettings.newModel).
public struct FlexibleNewModelState: Codable, Equatable, Hashable, Sendable {
    /// Pressed or resting faces that found no face: kept with their settings (their OLD region id, for the list's name) until he
    /// picks a face for each.
    public var lostFaces: [FlexibleFaceSettings]
    /// Presses (a tilted face, an edge, a corner) that found no face, kept the same way.
    public var lostPresses: [FlexiblePress]
    /// Edge and corner presses whose faces were matched, to re-find on the new model when its scene opens (their strips were
    /// drawn on the old model's shape).
    public var refind: [UUID]

    public init(lostFaces: [FlexibleFaceSettings] = [], lostPresses: [FlexiblePress] = [], refind: [UUID] = []) {
        self.lostFaces = lostFaces; self.lostPresses = lostPresses; self.refind = refind
    }

    /// Nothing waits for a face.
    public var isEmpty: Bool { lostFaces.isEmpty && lostPresses.isEmpty && refind.isEmpty }
    /// How many things wait for him to pick a face (the run waits while this is above 0).
    public var lostCount: Int { lostFaces.count + lostPresses.count }
}

public enum FlexibleNewModel {

    /// The new region ids an old one became: a whole face its matched faces; his Surface sector itself while it still holds a
    /// face (`faceRegions`, already remapped); a Flexible-only sector itself (re-derived on the new model).
    static func pieces(_ id: Int, _ match: FaceMatch, faceRegions: FaceRegionModel?) -> [Int] {
        if FlexibleRegions.isFlexible(id) { return [id] }
        if FlexibleRegions.isSector(id) {
            guard let r = faceRegions?.region(id - FlexibleRegions.sectorBase), !r.add.isEmpty else { return [] }
            return [id]
        }
        guard id >= 0 else { return [] }
        return match.faces(for: FaceID(id)).map { Int($0) }
    }

    /// The Flexible setup on the new model (`match`: old face → new faces; `faceRegions`: his Surface regions, remapped).
    public static func carry(_ s: FlexibleStageSettings, match: FaceMatch, faceRegions: FaceRegionModel?) -> FlexibleStageSettings {
        var o = s
        var state = s.newModel ?? FlexibleNewModelState()
        var taken = Set<Int>()
        func pieces(_ id: Int) -> [Int] { Self.pieces(id, match, faceRegions: faceRegions) }

        // the faces, in their order (the run job's face order): a split face → every piece, the same settings; a piece an
        // earlier face already took (two faces the new model MERGED) is not taken twice; none → kept, waiting for a face
        var faces: [FlexibleFaceSettings] = []
        for f in s.faces {
            let free = pieces(f.faceRegionID).filter { !taken.contains($0) }
            if free.isEmpty { state.lostFaces.append(f); continue }
            for id in free {
                var g = f
                g.faceRegionID = id
                faces.append(g)
                taken.insert(id)
            }
        }
        o.faces = faces

        // the presses: a tilted face's like a face (one press per piece, the first keeps its id); an edge or corner's members
        // matched and the press re-found when the scene opens; a member that found no face → the press waits for a face
        var presses: [FlexiblePress] = []
        for p in s.presses ?? [] {
            if var st = p.strip {
                var ok = true
                for i in st.members.indices {
                    let face = pieces(st.members[i].face)
                    guard let first = face.first else { ok = false; break }
                    st.members[i].face = first
                    if st.members[i].root >= 0 {
                        let root = pieces(st.members[i].root)
                        st.members[i].root = root.first ?? -1
                    }
                }
                guard ok else { state.lostPresses.append(p); continue }
                var q = p
                q.strip = st
                q.drawnIn = remapped(p.drawnIn, pieces)
                presses.append(q)
                if !state.refind.contains(p.id) { state.refind.append(p.id) }
                continue
            }
            let free = (p.regions.first.map(pieces) ?? []).filter { !taken.contains($0) }
            if free.isEmpty { state.lostPresses.append(p); continue }
            for (k, id) in free.enumerated() {
                var q = p
                if k > 0 { q.id = UUID() }
                q.regions = [id] + p.regions.dropFirst().flatMap(pieces)
                q.settings.faceRegionID = id
                q.drawnIn = remapped(p.drawnIn, pieces)
                presses.append(q)
                taken.insert(id)
            }
        }
        o.presses = presses.isEmpty ? nil : presses   // `setPresses`' rule: nil, never []

        if let removed = s.removedRegions {
            var seen = Set<Int>()
            let r = removed.flatMap(pieces).filter { seen.insert($0).inserted }
            o.removedRegions = r.isEmpty ? nil : r
        }
        o.checkStamps = s.checkStamps.compactMap { c in
            guard let id = pieces(c.faceRegionID).first else { return nil }
            var d = c
            d.faceRegionID = id
            return d
        }
        o.links = s.links.flatMap { links in
            let kept = links.compactMap { l -> FlexibleLatticeLink? in
                guard let lat = remapKey(l.lattice, match), let wall = remapKey(l.wall, match), let target = remapKey(l.target, match)
                else { return nil }
                return FlexibleLatticeLink(id: l.id, lattice: lat, wall: wall, target: target)
            }
            return kept.isEmpty ? nil : kept
        }
        if let store = s.sectors {
            var ids: [String: Int] = [:]
            for (key, n) in store.ids {
                guard let k = remapKey(key, match) else { continue }
                if ids[k] == nil { ids[k] = n }
            }
            o.sectors = FlexibleSectorStore(version: store.version, ids: ids)
        }
        o.newModel = state.isEmpty ? nil : state
        return o
    }

    /// A Flexible part's lattice (its face-prisms: the Flexible lattice itself) on the new model: every key that names a face
    /// takes its new faces (a split face: each piece the same value); everything else is kept as it was.
    public static func carryLattice(_ l: LatticeSettings, match: FaceMatch) -> LatticeSettings {
        var o = l
        func remapDict<V>(_ d: [String: V]) -> [String: V] {
            var out: [String: V] = [:]
            for (k, v) in d.sorted(by: { $0.key < $1.key }) {
                for nk in remapKeyAll(k, match) where out[nk] == nil { out[nk] = v }
            }
            return out
        }
        o.selectableRoles = remapDict(l.selectableRoles)
        o.selectableDepthMM = remapDict(l.selectableDepthMM)
        o.selectableDensity = remapDict(l.selectableDensity)
        o.selectableExpandMM = remapDict(l.selectableExpandMM)
        o.selectableCellMM = remapDict(l.selectableCellMM)
        o.bandTreatments = remapDict(l.bandTreatments)
        var seen = Set<Int>()
        o.paintedIncludeFaces = l.paintedIncludeFaces.flatMap { match.faces(for: FaceID($0)).map { Int($0) } }
            .filter { seen.insert($0).inserted }
        if var list = l.latticeList {
            let groups = list.groups.map { g -> SelectionGroup in
                var s = Set<FaceID>()
                let faces = g.faces.flatMap { match.faces(for: $0) }.filter { s.insert($0).inserted }
                return SelectionGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, faces: faces, regionIDs: g.regionIDs)
            }
            list.restore(groups: groups, active: list.activeGroupID)
            o.latticeList = list
        }
        return o
    }

    // MARK: keys that name faces

    /// The face numbers a key names, by their forms: a selectable face "f:<group>:<face>", a band member "face:<face>", a root
    /// token or a wall's / skin's face "f<face>" (after ':' or at the start, ended by ':', '.', '#' or the end).
    private static let selectable = try! NSRegularExpression(pattern: #"(f:[0-9A-Fa-f-]{36}:)(\d+)"#)
    private static let bandFace = try! NSRegularExpression(pattern: #"(^|:)(face:)(\d+)$"#)
    private static let token = try! NSRegularExpression(pattern: #"(^|:)(f)(\d+)(?=$|[:.#])"#)

    /// `key` on the new model, its every face its FIRST new face; nil when a face it names found none. A key naming no face
    /// is itself.
    static func remapKey(_ key: String, _ match: FaceMatch) -> String? {
        remapKeyAll(key, match, firstOnly: true).first
    }

    /// Every form of `key` on the new model: a key naming ONE face, one per new piece (a split face's settings go to each piece);
    /// a key naming several, each face its first piece. Empty when a face it names found none.
    static func remapKeyAll(_ key: String, _ match: FaceMatch, firstOnly: Bool = false) -> [String] {
        var faces: [(range: NSRange, face: Int)] = []
        let ns = key as NSString
        let all = NSRange(location: 0, length: ns.length)
        for m in selectable.matches(in: key, range: all) { faces.append((m.range(at: 2), Int(ns.substring(with: m.range(at: 2))) ?? -1)) }
        for m in bandFace.matches(in: key, range: all) { faces.append((m.range(at: 3), Int(ns.substring(with: m.range(at: 3))) ?? -1)) }
        for m in token.matches(in: key, range: all) where !faces.contains(where: { NSIntersectionRange($0.range, m.range(at: 3)).length > 0 }) {
            faces.append((m.range(at: 3), Int(ns.substring(with: m.range(at: 3))) ?? -1))
        }
        guard !faces.isEmpty else { return [key] }
        let mapped = faces.map { f -> [Int] in
            guard f.face >= 0, !FlexibleRegions.isSector(f.face) else { return f.face >= 0 ? [f.face] : [] }
            return match.faces(for: FaceID(f.face)).map { Int($0) }
        }
        guard mapped.allSatisfy({ !$0.isEmpty }) else { return [] }
        func build(_ choice: [Int]) -> String {
            var out = key as NSString
            for (f, n) in zip(faces, choice).sorted(by: { $0.0.range.location > $1.0.range.location }) {
                out = out.replacingCharacters(in: f.range, with: String(n)) as NSString
            }
            return out as String
        }
        if firstOnly || faces.count > 1 { return [build(mapped.map { $0[0] })] }
        return mapped[0].map { build([$0]) }
    }

    private static func remapped(_ ref: FlexibleFrameRef?, _ pieces: (Int) -> [Int]) -> FlexibleFrameRef? {
        guard let ref else { return nil }
        if case let .face(r) = ref { return pieces(r).first.map { .face($0) } }
        return ref
    }
}
