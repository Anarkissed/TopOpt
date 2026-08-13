// LatticePrimitiveRole.swift — ★ EACH PRIMITIVE GETS ITS OWN LATTICE /
// NO-LATTICE SELECTION (task 2026-08-14-lattice-separation §3c).
//
// ★ HIS WORDS: "Otherwise, what the fuck are they doing?"
//
// He is right, and the complaint is precise. PR 328 put the choice on the GROUP
// (`LatticeSettings.groupRoles`, keyed by `SelectionGroup.id`), so a group holding
// a wall face, a boss face and a hand-placed slab had ONE answer for all three.
// The primitives inside it were listed, coloured and gizmo-draggable — and had no
// say in the one decision the page exists to take. They were decorative.
//
// SO THE ROLE MOVES DOWN ONE LEVEL, AND THE GROUP BECOMES A SUMMARY.
//
//   `LatticeSettings.groupRoles`      the group's DECLARATION — still what makes
//                                     the group latticeable at all, still what
//                                     the role gate (§1a/§1d) reads, still what
//                                     turns lattice mode on.
//   `LatticeSettings.primitiveRoles`  the per-primitive OVERRIDE. Absent ⇒ the
//                                     primitive follows its group, so every
//                                     existing snapshot resolves to exactly the
//                                     roles it had.
//
// The group row then shows ALL / SOME / NONE of its primitives latticed, computed
// from the resolved answers, rather than owning the decision.
//
// ★ THE SAME SHAPE CARRIES THE DEPTH. §3d asks for a draggable depth plane per
// FACE OR PRIMITIVE, and the wire has been per-face since PR 328 §0a
// (`face_protection_depths_mm` is parallel to the face ids, and a face-kind
// region carries its own `face_id` + `depth_mm`). So `primitiveDepthMM` overrides
// `groupDepthMM` the same way, and BOTH the protection spec and the region
// emission read it through `LatticeSlabDepth` — which is what keeps R4 true when
// two faces of one group are dragged to different depths.
//
// Pure value types over `String` keys so the whole resolution is headlessly
// testable AND `Codable` without a custom key coder: a `[UUID: …]` dictionary
// already survives `LatticeSettings`'s encoder, and a compound key does not.

import Foundation

/// One thing inside a selection group that can be latticed on its own.
///
/// A group's B-rep FACES and its hand-placed manual PRIMITIVES are both regions
/// on the wire — a face becomes a slab or a bolt from its own geometry, a manual
/// primitive is already one — so they are the same kind of thing here.
public enum LatticePrimitiveRef: Hashable, Sendable {
    /// A B-rep face of the group. Keyed by the GROUP as well, because the same
    /// face id can only ever be in one group but the key must stay stable when a
    /// group is renamed or recoloured.
    case face(group: UUID, face: FaceID)
    /// A hand-placed manual primitive (`ManualPrimitive.id`).
    case primitive(UUID)

    /// The stable dictionary key. Prefixed by kind so a face id can never collide
    /// with a primitive UUID.
    public var key: String {
        switch self {
        case let .face(group, face): return "f:\(group.uuidString):\(face)"
        case let .primitive(id): return "p:\(id.uuidString)"
        }
    }
}

/// ★ ONE PRIMITIVE'S OWN ANSWER, and it has THREE states, not two.
///
/// `LatticeGroupRole` has exactly two cases — `include` (material stays,
/// latticed) and `exclude` (material stays, solid) — and both are REGIONS core
/// emits. A per-primitive override needs a third answer that the two-case enum
/// cannot express: **not a region at all**.
///
/// WITHOUT IT, "complete control with where the lattice goes" is not reachable.
/// A group with three faces and no declaration would gain one the moment the user
/// latticed ONE of them, and the other two — having no override — would follow it
/// and be latticed as well. Setting one face would silently set three. So the
/// tap that declares one primitive writes `off` on its siblings, and the group's
/// declaration becomes a fallback nothing is relying on.
///
/// `off` NEVER reaches the wire: the emission skips it, exactly as it skips a
/// primitive in an undeclared group.
public enum LatticePrimitiveRole: String, Codable, Equatable, Sendable {
    case include, exclude
    /// Declared NOT to be a region. Distinct from "no answer yet", which is the
    /// absence of a key.
    case off

    /// The wire role, or nil for `off`.
    public var regionRole: LatticeGroupRole? {
        switch self {
        case .include: return .include
        case .exclude: return .exclude
        case .off: return nil
        }
    }

    public init(_ role: LatticeGroupRole) {
        self = role == .include ? .include : .exclude
    }
}

/// How much of a group is latticed — what the group row shows now that it no
/// longer decides (§3c).
public enum LatticeGroupCoverage: String, Equatable, Sendable {
    case all, some, none

    /// ★ One word (R7).
    public var label: String { rawValue.capitalized }
}

public enum LatticePrimitiveRoles {

    /// The role in force for one primitive: its own override when it has one
    /// (`off` ⇒ not a region), otherwise its group's declaration.
    public static func role(for ref: LatticePrimitiveRef,
                            groupRole: LatticeGroupRole?,
                            overrides: [String: LatticePrimitiveRole]) -> LatticeGroupRole? {
        if let own = overrides[ref.key] { return own.regionRole }
        return groupRole
    }

    /// ALL / SOME / NONE of `refs` resolve to `.include`. An empty group is
    /// `.none` — there is nothing in it to lattice, and claiming `.all` of zero
    /// would put a green "All" on a group that emits nothing.
    public static func coverage(refs: [LatticePrimitiveRef],
                                groupRole: LatticeGroupRole?,
                                overrides: [String: LatticePrimitiveRole])
        -> LatticeGroupCoverage {
        guard !refs.isEmpty else { return .none }
        var included = 0
        for r in refs where role(for: r, groupRole: groupRole,
                                 overrides: overrides) == .include {
            included += 1
        }
        if included == 0 { return .none }
        return included == refs.count ? .all : .some
    }

    /// ★ DECLARE ONE PRIMITIVE, AND PIN ITS SIBLINGS TO WHAT THEY ALREADY WERE.
    ///
    /// This is the function that makes a per-primitive tap mean only itself. It
    /// writes `ref`'s answer, and — for every other primitive of the same group
    /// that has no answer yet — writes the one it currently RESOLVES to, so
    /// changing the group's declaration underneath them can no longer move them.
    /// A primitive that resolved to nothing is pinned `off`.
    public static func declare(_ role: LatticePrimitiveRole,
                               for ref: LatticePrimitiveRef,
                               siblings: [LatticePrimitiveRef],
                               groupRole: LatticeGroupRole?,
                               in overrides: inout [String: LatticePrimitiveRole]) {
        for s in siblings where s != ref && overrides[s.key] == nil {
            if let r = groupRole {
                overrides[s.key] = LatticePrimitiveRole(r)
            } else {
                overrides[s.key] = .off
            }
        }
        overrides[ref.key] = role
    }

    /// Set every primitive of a group to one answer — the group row's "set all".
    public static func setAll(_ role: LatticePrimitiveRole,
                              refs: [LatticePrimitiveRef],
                              in overrides: inout [String: LatticePrimitiveRole]) {
        for r in refs { overrides[r.key] = role }
    }

    /// Drop overrides whose primitive no longer exists. Keyed lookup already makes
    /// a stale entry inert; this keeps a long-lived project's snapshot from
    /// accumulating them.
    public static func pruned(_ overrides: [String: LatticePrimitiveRole],
                              live: Set<String>) -> [String: LatticePrimitiveRole] {
        overrides.filter { live.contains($0.key) }
    }
}
