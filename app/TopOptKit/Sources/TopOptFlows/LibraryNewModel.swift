// LibraryNewModel.swift — "Upload new version" on a Library part (his ask 2026-11-11 in UI-Notes' chat; DATA-MODEL.md
// decision 12, which REPLACES decision 5's "rev 2 = a new part").
//
// His four answers:
//  1. The uploaded file is the part's NEXT version: a draft "v8 · from v7" whose change line starts "New model". Older
//     versions keep their own model and results (each version's folder already holds its own copy of its model).
//  2. Everything carries over, its faces matched again by place and shape (`FaceMatch`). A group that finds no face STAYS
//     (its role, weight and Keep clear are kept) and blocks Optimize: "A group lost its faces · Pick its faces".
//  3. The per-face lattice choices start from Auto (the Lattice page is being rebuilt; its old code is frozen): the type
//     and every lattice setting that names no face carry over, and one line on the new version says so.
//  4. Topology parts first: a Flexible part gets the button once #362 matches Flexible's per-face setup.
//
// Every import has a face id per triangle — a STEP's B-rep faces, an STL's or 3MF's faces from the core's segmenter — so
// one matcher serves every format. App only: the job, the worker and the engine see an ordinary project folder.

import Foundation
import simd
import UniformTypeIdentifiers
import TopOptKit

// MARK: - what the draft remembers

/// What "Upload new version" left on a version: the model it brought, and what it could not carry.
public struct NewModelNote: Codable, Equatable, Sendable {
    /// The picked file's name, for the change line ("New model: Bracket rev2.step").
    public var fileName: String
    /// SHA-256 of the uploaded file's bytes: the part holds this model from now on, and a draft OF this version (the same
    /// model) never says "New model" again.
    public var modelHash: String
    /// The groups that found no face on the new model, until he picks theirs (empty once every one has faces again).
    public var lostGroups: [UUID]
    /// true when per-face lattice choices went back to Auto (his third answer); nil when there were none.
    public var latticeReset: Bool?

    public init(fileName: String, modelHash: String, lostGroups: [UUID] = [], latticeReset: Bool? = nil) {
        self.fileName = fileName
        self.modelHash = modelHash
        self.lostGroups = lostGroups
        self.latticeReset = latticeReset
    }
}

// MARK: - the face matcher: place first, then shape

/// Which faces of the new model each face of the old model became.
public struct FaceMatch: Equatable, Sendable {
    /// old face → the new faces it became (two or more when the new model split it). A face not here found none.
    public var map: [FaceID: [FaceID]]

    public init(map: [FaceID: [FaceID]]) { self.map = map }

    /// The new faces an old face became (empty: it found none).
    public func faces(for old: FaceID) -> [FaceID] { map[old] ?? [] }

    /// Match `old`'s faces to `new`'s.
    ///
    /// **Place.** Each triangle of one model asks which face of the other it lies on (within a hair's width, facing the
    /// same way). A new face is the old face that holds at least half of it; an old face is the new face that holds at
    /// least half of it. Both directions count, so a face the new model SPLIT goes to every piece, and two faces it MERGED
    /// both go to the merged one — unless one was a small patch of it (under a quarter): that one is lost, never stretched
    /// over the whole face. A face that only grew (a longer side) still lies mostly on its old place.
    ///
    /// **Shape.** An old face left over (it MOVED: a longer part's end, a hole drilled elsewhere) takes the nearest unclaimed
    /// new face of the same shape: the same area and the same extents (within 10 %), facing the same way when it is flat.
    /// A face whose place and shape both changed finds nothing, and its group asks for its faces again.
    public static func between(old: ImportedMesh, new: ImportedMesh) -> FaceMatch {
        let a = Faces(old), b = Faces(new)
        guard !a.tris.isEmpty, !b.tris.isEmpty else { return FaceMatch(map: [:]) }
        let lo = simd_min(a.lo, b.lo), hi = simd_max(a.hi, b.hi)
        let diag = simd_length(hi - lo)
        let tol = max(0.05, 0.002 * diag)

        var map: [FaceID: Set<FaceID>] = [:]
        // new → old: the old face holding most of each new face
        for (n, votes) in a.votes(from: b, tol: tol) {
            if let top = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value >= 0.5 * (b.area[n] ?? .infinity) {
                map[top.key, default: []].insert(n)
            }
        }
        // old → new: the new face holding most of each old face — unless the old face is a small piece of it (under a
        // quarter): a patch the new model folded into a bigger face is LOST, never stretched over the whole face (a load
        // on a small pad must not become a load on the whole top without him seeing it)
        for (o, votes) in b.votes(from: a, tol: tol) {
            if let top = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), top.value >= 0.5 * (a.area[o] ?? .infinity),
               (a.area[o] ?? 0) >= 0.25 * (b.area[top.key] ?? .infinity) {
                map[o, default: []].insert(top.key)
            }
        }

        // shape: the faces that moved
        var claimed = Set(map.values.flatMap { $0 })
        let left = a.area.keys.filter { (map[$0] ?? []).isEmpty }.sorted { (a.area[$0] ?? 0, $1) > (a.area[$1] ?? 0, $0) }
        for o in left {
            var best: (n: FaceID, d: Double)?
            for n in b.area.keys where !claimed.contains(n) && a.sameShape(o, as: n, in: b, tol: tol) {
                let d = simd_length(a.centroid(o) - b.centroid(n))
                if d <= 0.5 * diag, best == nil || d < best!.d || (d == best!.d && n < best!.n) { best = (n, d) }
            }
            if let n = best?.n { map[o] = [n]; claimed.insert(n) }
        }
        return FaceMatch(map: map.mapValues { $0.sorted() })
    }

    /// One model's triangles and faces, with a grid for "which triangle is near this point".
    private struct Faces {
        struct Tri { var a, b, c, n: SIMD3<Double>; var area: Double; var face: FaceID }
        var tris: [Tri] = []
        var area: [FaceID: Double] = [:]
        var weighted: [FaceID: SIMD3<Double>] = [:]       // area × centroid
        var normal: [FaceID: SIMD3<Double>] = [:]         // area × normal
        var boxLo: [FaceID: SIMD3<Double>] = [:], boxHi: [FaceID: SIMD3<Double>] = [:]
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)

        init(_ m: ImportedMesh) {
            let v = m.vertices, idx = m.indices
            func p(_ i: Int32) -> SIMD3<Double> { let k = Int(i) * 3; return SIMD3(Double(v[k]), Double(v[k + 1]), Double(v[k + 2])) }
            let count = min(idx.count / 3, m.faceIDs.isEmpty ? idx.count / 3 : m.faceIDs.count)
            tris.reserveCapacity(count)
            for t in 0..<count {
                let i0 = idx[3 * t], i1 = idx[3 * t + 1], i2 = idx[3 * t + 2]
                guard max(i0, i1, i2) < Int32(v.count / 3), min(i0, i1, i2) >= 0 else { continue }
                let x = p(i0), y = p(i1), z = p(i2)
                let c = simd_cross(y - x, z - x), len = simd_length(c)
                guard len > 0 else { continue }
                let face = m.faceIDs.isEmpty ? 0 : m.faceIDs[t]
                let tri = Tri(a: x, b: y, c: z, n: c / len, area: len / 2, face: face)
                tris.append(tri)
                area[face, default: 0] += tri.area
                weighted[face, default: .zero] += tri.area * (x + y + z) / 3
                normal[face, default: .zero] += tri.area * tri.n
                let tlo = simd_min(x, simd_min(y, z)), thi = simd_max(x, simd_max(y, z))
                boxLo[face] = simd_min(boxLo[face] ?? tlo, tlo); boxHi[face] = simd_max(boxHi[face] ?? thi, thi)
                lo = simd_min(lo, tlo); hi = simd_max(hi, thi)
            }
        }

        func centroid(_ f: FaceID) -> SIMD3<Double> { (weighted[f] ?? .zero) / max(area[f] ?? 1, 1e-12) }

        /// Same area and extents within 10 % (or a hair), and the same way when both are flat-ish.
        func sameShape(_ f: FaceID, as g: FaceID, in other: Faces, tol: Double) -> Bool {
            guard let a1 = area[f], let a2 = other.area[g], abs(a1 - a2) <= 0.1 * max(a1, a2) else { return false }
            let e1 = ((boxHi[f] ?? .zero) - (boxLo[f] ?? .zero)), e2 = ((other.boxHi[g] ?? .zero) - (other.boxLo[g] ?? .zero))
            let s1 = [e1.x, e1.y, e1.z].sorted(), s2 = [e2.x, e2.y, e2.z].sorted()
            for k in 0..<3 where abs(s1[k] - s2[k]) > max(0.1 * max(s1[k], s2[k]), 2 * tol) { return false }
            let n1 = (normal[f] ?? .zero) / a1, n2 = (other.normal[g] ?? .zero) / a2
            if simd_length(n1) > 0.5, simd_length(n2) > 0.5 { return simd_dot(simd_normalize(n1), simd_normalize(n2)) >= cos(5 * Double.pi / 180) }
            return true
        }

        /// For every face of `other`: how much of its area lies on each of this model's faces.
        func votes(from other: Faces, tol: Double) -> [FaceID: [FaceID: Double]] {
            let grid = Grid(tris, lo: lo, hi: hi, tol: tol)
            let facing = cos(20 * Double.pi / 180)
            var out: [FaceID: [FaceID: Double]] = [:]
            for t in other.tris {
                let q = (t.a + t.b + t.c) / 3
                var best: (face: FaceID, d: Double)?
                for i in grid.near(q) {
                    let s = tris[i]
                    guard simd_dot(s.n, t.n) >= facing else { continue }
                    let d = simd_length(q - Self.closest(q, s.a, s.b, s.c))
                    if d <= tol, best == nil || d < best!.d { best = (s.face, d) }
                }
                if let f = best?.face { out[t.face, default: [:]][f, default: 0] += t.area }
            }
            return out
        }

        /// The closest point to `p` on triangle abc (Ericson, Real-Time Collision Detection 5.1.5).
        static func closest(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> SIMD3<Double> {
            let ab = b - a, ac = c - a, ap = p - a
            let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
            if d1 <= 0, d2 <= 0 { return a }
            let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
            if d3 >= 0, d4 <= d3 { return b }
            let vc = d1 * d4 - d3 * d2
            if vc <= 0, d1 >= 0, d3 <= 0 { return a + d1 / (d1 - d3) * ab }
            let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
            if d6 >= 0, d5 <= d6 { return c }
            let vb = d5 * d2 - d1 * d6
            if vb <= 0, d2 >= 0, d6 <= 0 { return a + d2 / (d2 - d6) * ac }
            let va = d3 * d6 - d5 * d4
            if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (d4 - d3) / ((d4 - d3) + (d5 - d6)) * (c - b) }
            let denom = 1 / (va + vb + vc)
            return a + ab * (vb * denom) + ac * (vc * denom)
        }
    }

    /// A uniform grid of triangle boxes (each grown by the tolerance), keyed by cell.
    private struct Grid {
        let lo: SIMD3<Double>, h: Double
        var cells: [SIMD3<Int>: [Int]] = [:]

        init(_ tris: [Faces.Tri], lo: SIMD3<Double>, hi: SIMD3<Double>, tol: Double) {
            self.lo = lo
            self.h = max(simd_length(hi - lo) / 48, 2 * tol, 1e-6)
            for (i, t) in tris.enumerated() {
                let a = cell(simd_min(t.a, simd_min(t.b, t.c)) - tol), b = cell(simd_max(t.a, simd_max(t.b, t.c)) + tol)
                for x in a.x...b.x { for y in a.y...b.y { for z in a.z...b.z { cells[SIMD3(x, y, z), default: []].append(i) } } }
            }
        }
        func cell(_ p: SIMD3<Double>) -> SIMD3<Int> {
            let q = (p - lo) / h
            return SIMD3(Int(q.x.rounded(.down)), Int(q.y.rounded(.down)), Int(q.z.rounded(.down)))
        }
        func near(_ p: SIMD3<Double>) -> [Int] { cells[cell(p)] ?? [] }
    }
}

// MARK: - the draft

public enum NewModelVersion {

    /// The one line on a version whose per-face lattice choices went back to Auto (his third answer).
    public static let latticeLine = "Lattice faces back to Auto"

    /// His fourth answer: Topology parts first — a Flexible part waits for #362's matching of its per-face setup.
    public static func offered(_ newest: ProjectSnapshot?) -> Bool { newest.map { $0.lattice?.flexible == nil } ?? false }

    /// The picker's types: New part's own (STEP, STL, 3MF).
    public static let allowedTypes: [UTType] = {
        let t = ["stl", "3mf", "step", "stp"].compactMap { UTType(filenameExtension: $0) }
        return t.isEmpty ? [.data] : t
    }()

    /// Copy a picked file to an app-owned path of its own (the picked URL is valid only inside its security scope), as New
    /// part does, so the core can read it again later.
    public static func copyPicked(_ url: URL) throws -> URL {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dst)
        return dst
    }

    /// The toast once the new version is in.
    public static func doneLine(version: String, lost: Int) -> String {
        lost == 0 ? "\(version) · New model · every group found its faces"
            : "\(version) · New model · \(lost) group\(lost == 1 ? " lost its" : "s lost their") faces"
    }

    /// The draft the upload makes from `parent`: every setting on the new model, its faces matched (`match`).
    public static func draft(from parent: ProjectSnapshot, id: UUID, savedAt: Date, modelFileName: String,
                             originalFileName: String, modelHash: String, match: FaceMatch) -> ProjectSnapshot {
        var d = parent
        d.id = id
        d.savedAt = savedAt
        d.optimized = nil
        d.modelFileName = modelFileName
        d.originalFileName = originalFileName
        let to: (FaceID) -> [FaceID] = { match.faces(for: $0) }

        // the groups: each on its new faces; one that found none STAYS (its role, weight and Keep clear with it)
        var lost: [UUID] = []
        let groups = parent.selection.groups.map { g -> SelectionGroup in
            var seen = Set<FaceID>()
            let faces = g.faces.flatMap(to).filter { seen.insert($0).inserted }
            if !g.faces.isEmpty, faces.isEmpty, g.regionIDs.isEmpty { lost.append(g.id) }
            return SelectionGroup(id: g.id, name: g.name, colorIndex: g.colorIndex, faces: faces, regionIDs: g.regionIDs)
        }
        d.selection.restore(groups: groups, active: parent.selection.activeGroupID)
        d.force.remapFaces(to)
        if var r = d.faceRegions { r.remapFaces(to); d.faceRegions = r }

        var reset: Bool?
        if var l = d.lattice, let flex = l.flexible {
            // ★ #362 (his picks 2026-11-12): a FLEXIBLE part's per-face setup is matched — its face-prisms ARE its lattice
            // (never back to Auto), its pressed faces, presses and the rest on their new faces (FlexibleNewModel)
            l = FlexibleNewModel.carryLattice(l, match: match)
            l.flexible = FlexibleNewModel.carry(flex, match: match, faceRegions: d.faceRegions)
            d.lattice = l
        } else if let l = d.lattice {
            let fresh = latticeFacesFromAuto(l)
            if fresh != l { reset = true }
            d.lattice = fresh == LatticeSettings() ? nil : fresh
        }
        d.newModel = NewModelNote(fileName: originalFileName, modelHash: modelHash, lostGroups: lost, latticeReset: reset)
        return d
    }

    /// His third answer: every lattice choice that names a face (or a face group of the Lattice stage's own list) goes back
    /// to Auto; the type and every setting that names no face stay. A zone is a shape, not a face: it stays.
    static func latticeFacesFromAuto(_ l: LatticeSettings) -> LatticeSettings {
        var o = l
        let zones = l.zoneGroups
        let kept = l.latticeList?.groups.filter { zones.contains($0.id) } ?? []
        o.latticeList = kept.isEmpty ? nil : .latticeList(adopting: kept)
        o.groupRoles = l.groupRoles.filter { zones.contains($0.key) }
        o.areaGrading = l.areaGrading.filter { zones.contains($0.key) }
        o.groupDensities = l.groupDensities.filter { zones.contains($0.key) }
        o.groupDepthMM = l.groupDepthMM.filter { zones.contains($0.key) }
        o.skinGroups = l.skinGroups.intersection(zones)
        o.paintedIncludeFaces = []
        o.selectableRoles = [:]
        o.selectableDepthMM = [:]
        o.selectableDensity = [:]
        o.selectableExpandMM = [:]
        o.selectableCellMM = [:]
        o.bandTreatments = [:]
        return o
    }
}
