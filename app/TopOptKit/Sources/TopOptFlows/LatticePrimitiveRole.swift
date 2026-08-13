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

/// How much of a group is latticed — what the group row shows now that it no
/// longer decides (§3c).
public enum LatticeGroupCoverage: String, Equatable, Sendable {
    case all, some, none

    /// ★ One word (R7).
    public var label: String { rawValue.capitalized }
}

public enum LatticePrimitiveRoles {

    /// The role in force for one primitive: its own override when it has one,
    /// otherwise its group's declaration.
    public static func role(for ref: LatticePrimitiveRef,
                            groupRole: LatticeGroupRole?,
                            overrides: [String: LatticeGroupRole]) -> LatticeGroupRole? {
        overrides[ref.key] ?? groupRole
    }

    /// ALL / SOME / NONE of `refs` resolve to `.include`. An empty group is
    /// `.none` — there is nothing in it to lattice, and claiming `.all` of zero
    /// would put a green "All" on a group that emits nothing.
    public static func coverage(refs: [LatticePrimitiveRef],
                                groupRole: LatticeGroupRole?,
                                overrides: [String: LatticeGroupRole])
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

    /// Set every primitive of a group to one role — the group row's "set all"
    /// action. Writes an EXPLICIT override per primitive rather than only moving
    /// the group declaration, so a later per-primitive change is a change against
    /// a stated answer instead of against an invisible default.
    public static func setAll(_ role: LatticeGroupRole?, refs: [LatticePrimitiveRef],
                              in overrides: inout [String: LatticeGroupRole]) {
        for r in refs { overrides[r.key] = role }
    }

    /// Drop overrides whose primitive no longer exists. Keyed lookup already makes
    /// a stale entry inert; this keeps a long-lived project's snapshot from
    /// accumulating them.
    public static func pruned(_ overrides: [String: LatticeGroupRole],
                              live: Set<String>) -> [String: LatticeGroupRole] {
        overrides.filter { live.contains($0.key) }
    }
}
