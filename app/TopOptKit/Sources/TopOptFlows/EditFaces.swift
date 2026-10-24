// EditFaces.swift — B5 (his picks 2026-10-24, S3 amended): EDIT FACES, an edit MODE on every stage.
//
// Surface is no longer a stage. "Edit faces…" in a stage's ● menu and the greyed ✂ after its last page both open one
// screen — a slim "Editing faces · Done" header over today's Surface tools (select · similar · cut · union · pattern ·
// region, re-homed, not redesigned) plus Paint on an STL part. Done returns to the exact page it came from.
//
// And every edit made there changes what a face IS on every stage (his note of 2026-10-24): a tap anywhere selects the
// EDITED face — the cut half, the painted area, the combined face — never the original underneath. `EditedFaces` is
// that one resolver.
//
// ★ IDS ARE KEPT. Edited faces are FaceRegionModel's own regions (ids 100…, never renumbered) and the paint overlay's
// painted faces (`.faces` sidecar, `PaintModel.exportRemap`), so saved keys built on them — Flexible's 1M + rid — keep
// resolving. Nothing here is stored: no new sidecar.

import Foundation
import simd

// MARK: - the mode

/// ★ WHERE DONE GOES — the page Edit faces was opened from.
public enum EditFacesOrigin: Equatable, Sendable {
    /// Topology's Setup, Results or Smooth (Smooth names the variant it was smoothing).
    case topology(TopologyPage, smoothVariant: Int? = nil)
    /// The lattice stage's Regions or Cells.
    case lattice(LatticeStagePage)
    /// ★ THE RETURN-TARGET API for a page another owner draws (#362's Flexible pages, e.g. "flexible.squish"). Done hands
    /// this value back to the closure the owner gave `WorkspacePlaceholder.enterEditFaces(from:onReturn:)`, which puts
    /// its own page back.
    case host(String)

    /// The stage under the mode. nil for a host page: its owner decides.
    public var stage: WorkspaceStage? {
        switch self {
        case .topology: return .topology
        case .lattice: return .lattice
        case .host: return nil
        }
    }
}

/// ★ THE MODE FLAG. `isEditing` is the whole flag; `origin` is where Done returns. A value, so the rules are tests.
public struct EditFacesSession: Equatable, Sendable {
    public private(set) var origin: EditFacesOrigin?

    public init() {}

    public var isEditing: Bool { origin != nil }

    /// Open Edit faces from `origin`. Already editing ⇒ false, and the first way in is kept (Done still goes there).
    @discardableResult
    public mutating func enter(from origin: EditFacesOrigin) -> Bool {
        guard self.origin == nil else { return false }
        self.origin = origin
        return true
    }

    /// Done: leaves the mode and says where to go (nil when not editing).
    public mutating func done() -> EditFacesOrigin? {
        defer { origin = nil }
        return origin
    }
}

public enum EditFacesCopy {
    public static let header = "Editing faces"
    public static let done = "Done"
    public static let paint = "Paint"
    public static let paintSTL = "Drag across the mesh to paint a face. STL parts only."
    public static let paintSTEP = "Not for STEP: its CAD faces are already exact."
}

/// ★ PAINT LIVES IN EDIT FACES (his pick): shown only there, and only usable on a mesh (STL) part; on a STEP part it is
/// greyed with one line why. Outside Edit faces it is absent on every stage.
public enum EditFacesPaint {
    public enum Row: Equatable, Sendable {
        case hidden
        case enabled(String)
        case greyed(String)
    }

    public static func isStep(_ path: String?) -> Bool {
        guard let p = path?.lowercased() else { return false }
        return p.hasSuffix(".step") || p.hasSuffix(".stp")
    }

    public static func row(modelPath: String?, editingFaces: Bool) -> Row {
        guard editingFaces, modelPath != nil else { return .hidden }
        return isStep(modelPath) ? .greyed(EditFacesCopy.paintSTEP) : .enabled(EditFacesCopy.paintSTL)
    }
}

extension WorkspaceStageVisibility {
    /// ★ THE EDIT FACES COLUMN — what the Surface stage drew (§6(a): "NO PRIMITIVES ARE VISIBLE IN THIS MODE"; the
    /// wireframe on; the face-editing affordances on), now over whichever stage it was opened from.
    public static let editingFaces = WorkspaceStageVisibility(designBox: false, groupPrimitives: false, keepOuts: false,
                                                              latticeDepthPlanes: false, latticeControls: false,
                                                              wireframe: true, surfaceEditing: true)

    /// The table with the mode applied: editing faces wins over the stage underneath.
    public static func of(_ stage: WorkspaceStage, editingFaces: Bool) -> WorkspaceStageVisibility {
        editingFaces ? .editingFaces : .of(stage)
    }
}

// MARK: - the post-edit hook

/// What an edit in Edit faces did. Passed to every `ProjectModel.onFaceEdit` hook INSIDE the edit's undo step.
public enum FaceEditKind: String, Equatable, Sendable {
    case cut, isolate, union, pattern, regionFace, undoSplit, dissolve, paint
}

public struct FaceEditEvent: Equatable, Sendable {
    public let kind: FaceEditKind
    /// Regions the edit made / removed (FaceRegionModel ids).
    public let made: [RegionID]
    public let removed: [RegionID]
    /// Painted faces the edit touched (paint only).
    public let paintedFaces: [FaceID]
}

// MARK: - edited faces

/// One face as every stage now sees it.
public struct EditedFace: Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        /// A CAD face nothing edited, or a painted area (its painted face id, ≥ the part's base face count).
        case face(FaceID)
        /// A FaceRegionModel region: a cut piece, an isolated face set, or a combined face (a union of parts).
        case region(RegionID)
    }
    public let id: ID
    /// ★ LINEAGE: the original CAD face(s) it came from (native ids, sorted).
    public let lineage: [FaceID]
    public let isPainted: Bool
}

public enum EditedFaces {

    /// Leaf regions: no live child, and not a part of a live union (the union is the face).
    static func leafRegions(_ regions: FaceRegionModel) -> [FaceRegion] {
        let parents = Set(regions.regions.map(\.parentID))
        let inUnion = Set(regions.regions.flatMap(\.parts))
        return regions.regions.filter { !parents.contains($0.id) && !inUnion.contains($0.id) }
    }

    /// The CAD faces a region stands for (a union through its parts).
    static func lineage(_ id: RegionID, mesh: ViewerMesh, regions: FaceRegionModel) -> [FaceID] {
        var out = Set<FaceID>()
        for leaf in regions.resolvedLeaves(id) {
            guard let r = regions.region(leaf) else { continue }
            out.formUnion(FaceRegionGeometry.members(of: r, in: mesh))
        }
        return out.sorted()
    }

    /// ★ EVERY EDITED FACE ON THE PART — the faces a tap selects on every stage, in order: faces (CAD and painted, by
    /// id), then regions (by id).
    public static func leaves(mesh: ViewerMesh, regions: FaceRegionModel, paint: PaintModel?) -> [EditedFace] {
        let regionLeaves = leafRegions(regions)
        var covered = Set<FaceID>()
        var regionFaces: [EditedFace] = []
        for r in regionLeaves {
            let lin = lineage(r.id, mesh: mesh, regions: regions)
            covered.formUnion(lin)
            regionFaces.append(EditedFace(id: .region(r.id), lineage: lin, isPainted: false))
        }
        let effective = paint.map { $0.effectiveFaceIDs(base: mesh.faceIDs) } ?? mesh.faceIDs
        var faces: [EditedFace] = []
        for f in Set(effective).sorted() {
            if let p = paint, p.isPainted(f) {
                let natives = Set(p.triangles(ofPaintedFace: f).compactMap { t -> FaceID? in
                    Int(t) < mesh.faceIDs.count ? mesh.faceIDs[Int(t)] : nil
                })
                faces.append(EditedFace(id: .face(f), lineage: natives.sorted(), isPainted: true))
            } else if !covered.contains(f) {
                faces.append(EditedFace(id: .face(f), lineage: [f], isPainted: false))
            }
        }
        return faces + regionFaces
    }

    /// ★ THE EDITED FACE UNDER A TAP on `face` at `point`: the deepest region holding the point (a cut half wins only on
    /// its own side), resolved up to the combined face it is part of; else the face itself. `fallback` answers when the
    /// point is unknown (the caller's deepest-region rule).
    public static func leaf(face: FaceID, point: SIMD3<Double>?, mesh: ViewerMesh, regions: FaceRegionModel,
                            fallback: RegionID? = nil) -> EditedFace.ID {
        let covering = regions.regions.contains { FaceRegionGeometry.members(of: $0, in: mesh).contains(face) }
        guard covering else { return .face(face) }
        let hit = point.flatMap { SurfaceTint.regionAt(point: $0, face: face, mesh: mesh, regions: regions) } ?? fallback
        guard let piece = hit else { return .face(face) }
        return .region(regions.outermostUnion(containing: piece))
    }

    /// The triangles that make up an edited face.
    static func triangles(of id: EditedFace.ID, mesh: ViewerMesh, regions: FaceRegionModel,
                          paint: PaintModel?) -> [Int] {
        let triCount = mesh.indices.count / 3
        switch id {
        case .face(let f):
            let effective = paint.map { $0.effectiveFaceIDs(base: mesh.faceIDs) } ?? mesh.faceIDs
            return (0..<min(triCount, effective.count)).filter { effective[$0] == f }
        case .region(let rid):
            var out = Set<Int>()
            for leaf in regions.resolvedLeaves(rid) {
                guard let r = regions.region(leaf) else { continue }
                let members = Set(FaceRegionGeometry.members(of: r, in: mesh))
                for t in 0..<min(triCount, mesh.faceIDs.count) where members.contains(mesh.faceIDs[t]) {
                    var c = SIMD3<Double>(0, 0, 0)
                    for k in 0..<3 { c += SIMD3<Double>(FaceRegionGeometry.position(UInt32(mesh.indices[t * 3 + k]), mesh)) }
                    if FaceRegionGeometry.inside(c / 3, r.cuts) { out.insert(t) }
                }
            }
            return out.sorted()
        }
    }

    /// ★ ONE OUTLINE PER EDITED FACE: the boundary of its own triangles, as a flat line list (x, y, z per vertex, two
    /// vertices per segment — `SurfaceWireframe`'s format). Triangle-granular: a cut's edge follows the triangles whose
    /// centres fall on the piece's side.
    public static func outline(_ id: EditedFace.ID, mesh: ViewerMesh, regions: FaceRegionModel,
                               paint: PaintModel?) -> [Float] {
        func key(_ i: UInt32) -> SIMD3<Int64> {
            let b = Int(i) * 3
            return SIMD3<Int64>(Int64((mesh.positions[b] * 10_000).rounded()),
                                Int64((mesh.positions[b + 1] * 10_000).rounded()),
                                Int64((mesh.positions[b + 2] * 10_000).rounded()))
        }
        struct Edge: Hashable { let lo: SIMD3<Int64>; let hi: SIMD3<Int64> }
        var uses: [Edge: (n: Int, a: UInt32, b: UInt32)] = [:]
        var order: [Edge] = []
        for t in triangles(of: id, mesh: mesh, regions: regions, paint: paint) {
            let v = (UInt32(mesh.indices[t * 3]), UInt32(mesh.indices[t * 3 + 1]), UInt32(mesh.indices[t * 3 + 2]))
            for (x, y) in [(v.0, v.1), (v.1, v.2), (v.2, v.0)] {
                let kx = key(x), ky = key(y)
                let e = (kx.x, kx.y, kx.z) <= (ky.x, ky.y, ky.z) ? Edge(lo: kx, hi: ky) : Edge(lo: ky, hi: kx)
                if let u = uses[e] { uses[e] = (u.n + 1, u.a, u.b) } else { uses[e] = (1, x, y); order.append(e) }
            }
        }
        var out: [Float] = []
        for e in order {
            guard let u = uses[e], u.n == 1 else { continue }
            for i in [u.a, u.b] {
                let b = Int(i) * 3
                out += [mesh.positions[b], mesh.positions[b + 1], mesh.positions[b + 2]]
            }
        }
        return out
    }
}
