// FlexibleRegions — which face regions the Flexible job declares, what they are called,
// and which one a tap lands on (task 2026-09-29-flexible-screens, overnight round:
// split faces).
//
// ★ TWO KINDS OF REGION, ONE ID SPACE.
//   * every B-rep / pseudo face is declared as its own region, id = the face id, so a
//     whole face and core's sentences about it read "face 12";
//   * every SPLIT SECTOR the user made on the Surface stage (a FaceRegion with cuts) is
//     declared too, id = sectorBase + its FaceRegionModel id. FaceRegionModel ids start at
//     100 and a part can have hundreds of faces, so the offset keeps the two apart.
// Core frames a sector from its own clipped triangles and keeps only the columns whose
// entry point passes its cuts (face_frame_cut / build_stack), so a sector is a loaded face
// like any other; the app only has to declare it and pick it.
//
// ★ THE TAP. A point on a face that has sectors resolves to the sector whose cuts hold it
// — SurfaceTint.regionAt, the Surface stage's own rule — else to the whole face.

import Foundation
import simd

public struct FlexibleRegions {
    public static let sectorBase = 1_000_000

    /// The split sectors the job declares (cut regions with member faces), by FaceRegion id.
    public let sectors: [FaceRegion]
    public let model: FaceRegionModel
    /// ★ ROUND 7 (M2): the Flexible-only sectors (FlexibleSectors) — lattice sections, edge strips and their rests —
    /// declared after his Surface sectors; nil: none (a value built over the project's regions alone).
    public let flexible: FlexibleSectorSet?

    public init(model: FaceRegionModel, mesh: ViewerMesh?, flexible: FlexibleSectorSet? = nil) {
        self.model = model
        self.flexible = flexible
        var own: [FaceRegion]
        if let mesh {
            own = model.regions.filter {
                $0.isCut && !$0.isUnionOfParts && !FaceRegionGeometry.members(of: $0, in: mesh).isEmpty
            }
        } else {
            own = model.regions.filter { $0.isCut && !$0.isUnionOfParts }
        }
        own += (flexible?.pieces ?? []).map(\.region)
        sectors = own
    }

    public static func isSector(_ id: Int) -> Bool { id >= sectorBase }
    /// ★ M2: a Flexible-only sector (never one of his Surface sectors).
    public static func isFlexible(_ id: Int) -> Bool { FlexibleSectors.isFlexible(id) }
    public func flexiblePiece(_ id: Int) -> FlexibleSector? { flexible?.piece(id) }
    public static func wireID(_ r: FaceRegion) -> Int { sectorBase + r.id }

    public func sector(_ id: Int) -> FaceRegion? {
        guard Self.isSector(id) else { return nil }
        return sectors.first { $0.id == id - Self.sectorBase }
    }

    /// The faces a region covers (a whole face: itself).
    public func faces(of id: Int, mesh: ViewerMesh?) -> [Int] {
        if let r = sector(id) {
            return (mesh.map { FaceRegionGeometry.members(of: r, in: $0) } ?? r.add).map { Int($0) }
        }
        return [id]
    }

    public func cuts(of id: Int) -> [RegionCut] { sector(id)?.cuts ?? [] }

    /// "face 12", or "face 12 · A" for a sector (its Surface-stage name when it has one).
    public func name(_ id: Int, mesh: ViewerMesh?) -> String {
        guard Self.isSector(id) else { return "face \(id)" }
        guard let r = sector(id) else { return "sector \(id - Self.sectorBase)" }
        let faces = self.faces(of: id, mesh: mesh)
        let base = faces.count == 1 ? "face \(faces[0])" : "faces \(faces.map(String.init).joined(separator: "+"))"
        return "\(base) · \(r.name.isEmpty ? "part \(r.id)" : r.name)"
    }

    /// Core's sentences name regions by id ("face 1000103 …", "face region 1000103 …" — AP3 REVIEW: the press
    /// verdict's words); show the app's names.
    public func renamed(_ text: String, mesh: ViewerMesh?) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\bface(?:s| region)? (\\d+)") else { return text }
        let ns = text as NSString
        var out = text
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard let id = Int(ns.substring(with: m.range(at: 1))), Self.isSector(id) else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: name(id, mesh: mesh))
        }
        return out
    }

    /// The region a tap lands on: the sector holding the point, else the whole face.
    public func region(at point: SIMD3<Double>?, face: Int, mesh: ViewerMesh?) -> Int {
        guard let point, let mesh, sectors.contains(where: { FaceRegionGeometry.members(of: $0, in: mesh).contains(FaceID(face)) })
        else { return face }
        if let id = SurfaceTint.regionAt(point: point, face: FaceID(face), mesh: mesh, regions: model),
           let r = model.region(id), r.isCut, sectors.contains(where: { $0.id == r.id }) {
            return Self.wireID(r)
        }
        return face
    }

    /// ★ ROUND 7 (M2, his img3 words): the region a tap on the Squish page PRESSES — the lattice section (or strip / rest)
    /// holding the point; a whole face or Surface sector when it is wholly latticed (or not latticed at all: its card says
    /// so); nil on the solid part of a face only partly inside a face-prism. TESTS-FIRST STUB: today's `region(at:)`.
    public func pressable(at point: SIMD3<Double>?, face: Int, mesh: ViewerMesh?) -> Int? {
        region(at: point, face: face, mesh: mesh)
    }

    /// Does triangle `t` (face `fid`, centroid `c`) belong to region `id`?
    public func contains(_ id: Int, face fid: Int, centroid c: SIMD3<Double>, mesh: ViewerMesh?) -> Bool {
        guard let r = sector(id) else { return fid == id }
        return faces(of: id, mesh: mesh).contains(fid) && FaceRegionGeometry.inside(c, r.cuts)
    }

    /// The sectors' `loads.face_regions` entries (the Surface stage's wire, RemoteRunner's
    /// encoding, with the offset id and without `parent_id`: the parent is not declared).
    public var wire: [[String: Any]] {
        sectors.map { r in
            var e: [String: Any] = ["id": Self.wireID(r)]
            if !r.name.isEmpty { e["name"] = r.name }
            if !r.add.isEmpty { e["add"] = r.add.map { Int($0) } }
            if !r.remove.isEmpty { e["remove"] = r.remove.map { Int($0) } }
            if r.filterMatchedAtAuthor >= 0 { e["filter_matched_at_author"] = r.filterMatchedAtAuthor }
            if r.filter.any {
                var f: [String: Any] = [:]
                if r.filter.maxAreaMM2 > 0 { f["max_area_mm2"] = r.filter.maxAreaMM2 }
                if r.filter.minAreaMM2 > 0 { f["min_area_mm2"] = r.filter.minAreaMM2 }
                if r.filter.minLargerNeighbours > 0 {
                    f["min_larger_neighbours"] = r.filter.minLargerNeighbours
                    f["larger_ratio"] = r.filter.largerRatio
                }
                if !r.filter.kind.isEmpty { f["kind"] = r.filter.kind }
                if r.filter.cylinderRadiusMM > 0 {
                    f["cylinder_radius_mm"] = r.filter.cylinderRadiusMM
                    f["cylinder_radius_tol_mm"] = r.filter.cylinderRadiusTolMM
                }
                e["filter"] = f
            }
            e["cuts"] = r.cuts.map { c -> [String: Any] in
                ["point": [c.point.x, c.point.y, c.point.z], "normal": [c.normal.x, c.normal.y, c.normal.z],
                 "strict": c.strict]
            }
            return e
        }
    }

    /// A key that changes when the declared sectors change (the scene must reopen).
    public var key: String {
        let data = (try? JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
