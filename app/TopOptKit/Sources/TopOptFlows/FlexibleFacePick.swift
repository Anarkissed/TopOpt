// FlexibleFacePick — THE PICK on the main Flexible page (task 2026-09-29-flexible-screens, round 7, batch R7-D2: his
// mockup pick 2, "B1. I definitely prefer B1. But with two small adjustments", 2026-10-14). PURE: what a tap on the part
// means, never what it writes.
//
// ★ HIS WORDS. img1 (2026-10-14): "When a new face is selected, the pop-up to ask whether it's a load, anchor, protected,
// etc. does not show up. It must always show up with a new face-selection." B1: a face never joins a group by itself —
// today #354's LatticeLibraryTap.route grew the active group with every free face tapped, and handleTopologyPiecePick
// could move a piece into it. Hook H22 now hands every edit-phase tap on the Flexible stage to this router instead.
//
// ★ THE RULES (the plan's step 1):
//   * a face a REGION covers resolves to its outermost piece (SurfaceTint.regionAt → FaceRegionModel.outermostUnion,
//     falling back to ProjectModel.surfaceCutTarget) — the piece is never moved or removed;
//   * an identity region nobody holds (the scaffolding I2's edge strips left — FlexibleEdgeStrips) is the face itself;
//   * an OWNED face or piece (a group holds it by EITHER membership — its faces, or its regions, or a region above it)
//     → `.face(group, ref)`; the stage then makes that group the active one (a pick, not a membership write);
//   * a FREE one → `.pending([it])`; another free face tapped while pending joins the set, the same one again leaves it;
//   * a tap NEVER writes a group; a miss → `.none` (a pending pick is dropped: no orphan "Pending" group is ever made);
//   * a pick whose group is gone (an Undo removed it) reads as `.none` (`validated`).
// The session also remembers the last group picked (the join button's target: "Add to Group C as lattice" is offered only
// when a group was picked earlier this session) and the last depth set (the next new lattice group starts there).

import Foundation
import simd
import TopOptKit

/// A face or piece no group holds (the new-face chip's subject).
public enum FlexibleFreeFace: Hashable, Sendable {
    case face(FaceID)
    case region(RegionID)

    /// The chip's key for its moved spot (kept per face for the session).
    public var key: String {
        switch self {
        case let .face(f): return "face:\(f)"
        case let .region(r): return "region:\(r)"
        }
    }
}

/// What the main page has picked.
public enum FlexibleFaceScope: Equatable, Sendable {
    case none
    /// Free faces waiting for the chip's answer (nothing is written yet).
    case pending([FlexibleFreeFace])
    /// One face (or piece) of a group.
    case face(group: UUID, ref: LatticeSelectableRef)
    /// A whole group (its line in the list, or the chip's "All").
    case group(UUID)

    public var groupID: UUID? {
        switch self {
        case let .face(g, _): return g
        case let .group(g): return g
        case .none, .pending: return nil
        }
    }

    public var isNone: Bool { self == .none }

    /// The chip's key: one face's spot is kept for that face, the group's for the group (the plan's "keyed by scope").
    public var chipKey: String? {
        switch self {
        case .none: return nil
        case let .pending(faces): return faces.first.map { "n:" + $0.key }
        case let .face(_, ref): return "f:" + ref.key
        case let .group(g): return "g:" + g.uuidString
        }
    }
}

/// The pick and what this session remembers beside it.
public struct FlexibleFacePickSession: Equatable, Sendable {
    public var scope: FlexibleFaceScope = .none
    /// The group picked earlier this session — the join button's target.
    public var lastGroup: UUID?
    /// The last depth set on this page (a new lattice group starts there).
    public var lastDepth: Double?
    public init(scope: FlexibleFaceScope = .none, lastGroup: UUID? = nil, lastDepth: Double? = nil) {
        self.scope = scope; self.lastGroup = lastGroup; self.lastDepth = lastDepth
    }
}

@MainActor
enum FlexibleFacePick {

    /// What a tap at `point` on `face` hits: the outermost piece of the region covering it (never moved), or the face.
    static func target(face: FaceID, point: SIMD3<Float>?, project p: ProjectModel, mesh: ViewerMesh) -> FlexibleFreeFace {
        let covering = p.faceRegions.regions.filter { FaceRegionGeometry.members(of: $0, in: mesh).contains(face) }
        guard !covering.isEmpty else { return .face(face) }
        let hit = point.flatMap {
            SurfaceTint.regionAt(point: SIMD3<Double>($0), face: face, mesh: mesh, regions: p.faceRegions)
        } ?? p.surfaceCutTarget(face: face)
        guard let h = hit else { return .face(face) }
        let piece = p.faceRegions.outermostUnion(containing: h)
        // ★ an identity region nobody holds — the scaffolding I2's edge strips left on the face (FlexibleEdgeStrips) —
        // is the face itself
        if let r = p.faceRegions.region(piece), r.isIdentity, !r.isCut, p.faceRegions.children(of: piece).isEmpty,
           !p.selection.groups.contains(where: { $0.regionIDs.contains(piece) }) {
            return .face(face)
        }
        return .region(piece)
    }

    /// The group holding `t` by either membership, and the ref its rows use. A piece held through a region above it is
    /// held by that region's group (the ref names the held region). A raw face held directly wins over a region nobody
    /// holds.
    static func owner(of t: FlexibleFreeFace, face: FaceID?, project p: ProjectModel) -> (group: UUID, ref: LatticeSelectableRef)? {
        switch t {
        case let .face(f):
            if let g = p.selection.groups.first(where: { $0.faces.contains(f) }) { return (g.id, .face(group: g.id, face: f)) }
            // a face a group's region covers (a union of whole faces)
            for g in p.selection.groups where p.latticeRegionCoveredFaces(g).contains(f) {
                if let rid = g.regionIDs.first(where: { p.surfaceResolvedFaces($0).contains(f) }) {
                    return (g.id, .region(group: g.id, region: rid))
                }
            }
            return nil
        case let .region(rid):
            var cur: RegionID? = rid
            var seen: Set<RegionID> = []
            while let c = cur, !seen.contains(c) {
                seen.insert(c)
                if let g = p.selection.groups.first(where: { $0.regionIDs.contains(c) }) {
                    return (g.id, .region(group: g.id, region: c))
                }
                cur = p.faceRegions.region(c)?.parentID
                if let next = cur, p.faceRegions.region(next) == nil { cur = nil }
            }
            if let f = face, let g = p.selection.groups.first(where: { $0.faces.contains(f) }) {
                return (g.id, .face(group: g.id, face: f))
            }
            return nil
        }
    }

    /// A tap: an owned face picks itself in its group; a free one joins (or leaves) the pending set. Writes nothing.
    static func tap(_ s: FlexibleFacePickSession, face: FaceID, point: SIMD3<Float>?, project p: ProjectModel,
                    mesh: ViewerMesh) -> FlexibleFacePickSession {
        let t = target(face: face, point: point, project: p, mesh: mesh)
        var out = s
        if let o = owner(of: t, face: face, project: p) {
            out.scope = .face(group: o.group, ref: o.ref)
            out.lastGroup = o.group
            return out
        }
        if case var .pending(faces) = s.scope {
            if let i = faces.firstIndex(of: t) {
                faces.remove(at: i)
                out.scope = faces.isEmpty ? .none : .pending(faces)
            } else {
                faces.append(t)
                out.scope = .pending(faces)
            }
            return out
        }
        out.scope = .pending([t])
        return out
    }

    /// A tap on empty canvas: the chip closes; a pending set is dropped; nothing is created.
    static func miss(_ s: FlexibleFacePickSession) -> FlexibleFacePickSession {
        var out = s
        out.scope = .none
        return out
    }

    /// The pick as the project stands: a group that is gone (an Undo, a delete) reads as `.none`, and is no longer the
    /// join's target; a face that left its group too.
    static func validated(_ s: FlexibleFacePickSession, project p: ProjectModel) -> FlexibleFacePickSession {
        var out = s
        if let g = s.lastGroup, !p.selection.groups.contains(where: { $0.id == g }) { out.lastGroup = nil }
        switch s.scope {
        case .none:
            break
        case let .pending(faces):
            // a free face that a group now holds (an Undo brought its group back) is no longer pending
            let still = faces.filter { owner(of: $0, face: nil, project: p) == nil }
            out.scope = still.isEmpty ? .none : (still == faces ? s.scope : .pending(still))
        case let .face(g, ref):
            guard let grp = p.selection.groups.first(where: { $0.id == g }) else { out.scope = .none; break }
            switch ref {
            case let .face(_, f): if !grp.faces.contains(f) { out.scope = .none }
            case let .region(_, r): if !grp.regionIDs.contains(r) { out.scope = .none }
            case .primitive: break
            }
        case let .group(g):
            if !p.selection.groups.contains(where: { $0.id == g }) { out.scope = .none }
        }
        return out
    }

    /// A free face's short name ("Face 3", or the piece's row name).
    static func name(_ t: FlexibleFreeFace, project p: ProjectModel) -> String {
        switch t {
        case let .face(f): return "Face \(p.runFaceID(f))"
        case let .region(r): return p.latticeRegionName(r)
        }
    }

    /// The chip's title for a pending set: "Face 3 · new", "Face 3 + Face 5 · new".
    static func pendingTitle(_ faces: [FlexibleFreeFace], project p: ProjectModel) -> String {
        faces.map { name($0, project: p) }.joined(separator: " + ") + " · new"
    }
}
