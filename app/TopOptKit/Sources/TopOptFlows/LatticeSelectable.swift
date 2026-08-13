// LatticeSelectable.swift — ★ EACH SELECTABLE GETS ITS OWN LATTICE /
// NO-LATTICE CHOICE (task 2026-08-14-lattice-separation §3c, widened to REGIONS
// after PR 331 landed).
//
// ★ HIS WORDS: "Each primitive needs to have its own lattice/no lattice
// selection. Otherwise, what the fuck are they doing?"
//
// PR 328 put the choice on the GROUP (`LatticeSettings.groupRoles`, keyed by
// `SelectionGroup.id`), so a group holding a wall face, a boss face and a
// hand-placed slab had ONE answer for all three. The things inside it were
// listed, coloured and gizmo-draggable — and had no say in the one decision the
// page exists to take. They were decorative.
//
// ★ AND PR 331 MADE THE UNIT BIGGER THAN "PRIMITIVE". A face now has a second
// identity — a REGION — which may be a union of 24 blend faces or one sector of
// a 10×5 grid split, and a region sits in a selection group exactly as a face
// does (`SelectionGroup.regionIDs`). His complaint applies to a region
// identically, so the choice is PER SELECTABLE:
//
//     a B-rep FACE of the group          .face(group:face:)
//     a hand-placed MANUAL PRIMITIVE     .primitive(_:)
//     a REGION of the group (PR 331)     .region(group:region:)
//
//   `LatticeSettings.groupRoles`        the group's DECLARATION — still what
//                                       makes the group latticeable at all,
//                                       still what the role gate (§1a/§1d)
//                                       reads, still what turns the mode on.
//   `LatticeSettings.selectableRoles`   the per-selectable OVERRIDE. Absent ⇒
//                                       follows the group, so every existing
//                                       snapshot resolves to the roles it had.
//
// The group row shows ALL / SOME / NONE of its selectables latticed, computed
// from the resolved answers, rather than owning the decision.
//
// ★ THE SAME SHAPE CARRIES THE DEPTH (§3d). `selectableDepthMM` overrides
// `groupDepthMM`, and BOTH the protection spec and the region emission read it
// through `LatticeSlabDepth` — which is what keeps R4 true when two faces of one
// group are dragged to different depths, and what lets PR 331's per-sector
// protection depth (`face_protection_region_ids` +
// `face_protection_region_depths_mm`) be filled from the SAME store rather than
// from a parallel one.
//
// Pure value types over `String` keys so the whole resolution is headlessly
// testable AND `Codable` without a custom key coder.

import Foundation

/// One thing inside a selection group that can be latticed on its own.
public enum LatticeSelectableRef: Hashable, Sendable {
    /// A B-rep face of the group. Keyed by the GROUP as well, because the key
    /// must stay stable when a group is renamed or recoloured.
    case face(group: UUID, face: FaceID)
    /// A hand-placed manual primitive (`ManualPrimitive.id`).
    case primitive(UUID)
    /// ★ A REGION of the group (PR 331) — a union, or a sector of a split.
    case region(group: UUID, region: RegionID)

    /// The stable dictionary key. Prefixed by kind so a face id, a region id and
    /// a primitive UUID can never collide.
    public var key: String {
        switch self {
        case let .face(group, face): return "f:\(group.uuidString):\(face)"
        case let .primitive(id): return "p:\(id.uuidString)"
        case let .region(group, region): return "r:\(group.uuidString):\(region)"
        }
    }

    /// The region id this ref names, or nil. The protection emission needs it to
    /// fill PR 331's per-region depth arrays.
    public var regionID: RegionID? {
        if case let .region(_, r) = self { return r }
        return nil
    }

    /// ★ WHETHER THE LATTICE PASS CAN CONSUME THIS SELECTABLE'S CHOICE TODAY.
    ///
    /// FALSE for a region, and this is not a limitation of the app. PR 331 §6
    /// states it precisely: core's `lattice.regions` are pure GEOMETRY — a bolt
    /// cylinder or a bounded face slab — which become `ClearanceGeometry`
    /// predicates that the fit-cell field, the multiscale mask and the
    /// thinnest-extent law all evaluate POINTWISE (`run_job.cpp:621`, `:756`,
    /// `:856`). A region is a voxel SET, not a predicate, so a sector of a grid
    /// split cannot be a lattice region until core grows a mask-backed sibling.
    /// That is a CORE change and a separate task.
    ///
    /// The choice is still stored (it is the user's, and it must survive until
    /// core catches up) — and the row SAYS SO, because a control that silently
    /// does nothing is worse than one that states its limit.
    public var latticeReachesTheRun: Bool {
        if case .region = self { return false }
        return true
    }
}

/// ★ ONE DISCLOSURE MECHANISM IN THE SELECTIONS PANEL (bar R12).
///
/// PR 331 gave a grid split's parent a `collapsed` flag so fifty rows from one
/// operation fold into one (§5b). This task adds a DRAWER that opens beneath a
/// row to show its derived numbers (§4). Two expand/collapse states in one list
/// is exactly the "two UIs" the maintainer keeps rejecting, so there is ONE
/// concept — "this row is expanded" — and for a REGION it is stored in PR 331's
/// own field. Expanding a region therefore reveals its drawer AND its children
/// together, which is what §5(b) describes happening on a deliberate expand.
///
/// A group and a manual primitive have no `FaceRegion` to store it on, so those
/// live in the view's own set; the TYPE is still one, and the region case cannot
/// disagree with the Regions sheet because it is the same bit.
public struct LatticeRowDisclosure: Equatable, Sendable {
    /// Rows with no `FaceRegion` behind them (group rows, face rows, primitives).
    private var open: Set<String> = []

    public init() {}

    public func isExpanded(_ key: String) -> Bool { open.contains(key) }

    /// Whether `ref` is expanded. A region reads PR 331's flag; everything else
    /// reads the local set.
    public func isExpanded(_ ref: LatticeSelectableRef,
                           regions: FaceRegionModel) -> Bool {
        if let rid = ref.regionID {
            return !(regions.region(rid)?.collapsed ?? true)
        }
        return open.contains(ref.key)
    }

    public mutating func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }

    /// Toggle `ref`. A region WRITES PR 331's flag, so the Selections panel and
    /// the Regions sheet fold and unfold together.
    public mutating func toggle(_ ref: LatticeSelectableRef,
                                regions: inout FaceRegionModel) {
        if let rid = ref.regionID {
            regions.setCollapsed(rid, !(regions.region(rid)?.collapsed ?? true))
            return
        }
        toggle(ref.key)
    }

    /// Close everything this type owns. PR 331's flags are NOT touched — they are
    /// the Regions sheet's state as much as this panel's.
    public mutating func closeAll() { open.removeAll() }
}

/// How much of a group is latticed — what the group row shows now that it no
/// longer decides (§3c).
public enum LatticeGroupCoverage: String, Equatable, Sendable {
    case all, some, none

    /// ★ One word (R7).
    public var label: String { rawValue.capitalized }
}

/// ★ ONE SELECTABLE'S OWN ANSWER, and it has THREE states, not two.
///
/// `LatticeGroupRole` has exactly two cases — `include` (material stays,
/// latticed) and `exclude` (material stays, solid) — and both are REGIONS core
/// emits. A per-selectable override needs a third answer the two-case enum
/// cannot express: **not a region at all**.
///
/// WITHOUT IT, "complete control with where the lattice goes" is not reachable.
/// A group with three faces and no declaration would gain one the moment the user
/// latticed ONE of them, and the other two — having no override — would follow it
/// and be latticed as well. Setting one face would silently set three. So the
/// tap that declares one selectable writes `off` on its siblings, and the group's
/// declaration becomes a fallback nothing is relying on.
///
/// `off` NEVER reaches the wire: the emission skips it, exactly as it skips a
/// selectable in an undeclared group.
public enum LatticeSelectableRole: String, Codable, Equatable, Sendable {
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

public enum LatticeSelectableRoles {

    /// The role in force for one selectable: its own override when it has one
    /// (`off` ⇒ not a region), otherwise its group's declaration.
    public static func role(for ref: LatticeSelectableRef,
                            groupRole: LatticeGroupRole?,
                            overrides: [String: LatticeSelectableRole]) -> LatticeGroupRole? {
        if let own = overrides[ref.key] { return own.regionRole }
        return groupRole
    }

    /// ALL / SOME / NONE of `refs` resolve to `.include`. An empty group is
    /// `.none` — there is nothing in it to lattice, and claiming `.all` of zero
    /// would put a green "All" on a group that emits nothing.
    public static func coverage(refs: [LatticeSelectableRef],
                                groupRole: LatticeGroupRole?,
                                overrides: [String: LatticeSelectableRole])
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

    /// ★ DECLARE ONE SELECTABLE, AND PIN ITS SIBLINGS TO WHAT THEY ALREADY WERE.
    ///
    /// This is the function that makes a per-selectable tap mean only itself. It
    /// writes `ref`'s answer, and — for every other selectable of the same group
    /// that has no answer yet — writes the one it currently RESOLVES to, so
    /// changing the group's declaration underneath them can no longer move them.
    /// A selectable that resolved to nothing is pinned `off`.
    public static func declare(_ role: LatticeSelectableRole,
                               for ref: LatticeSelectableRef,
                               siblings: [LatticeSelectableRef],
                               groupRole: LatticeGroupRole?,
                               in overrides: inout [String: LatticeSelectableRole]) {
        for s in siblings where s != ref && overrides[s.key] == nil {
            if let r = groupRole {
                overrides[s.key] = LatticeSelectableRole(r)
            } else {
                overrides[s.key] = .off
            }
        }
        overrides[ref.key] = role
    }

    /// Set every selectable of a group to one answer — the group row's "set all".
    public static func setAll(_ role: LatticeSelectableRole,
                              refs: [LatticeSelectableRef],
                              in overrides: inout [String: LatticeSelectableRole]) {
        for r in refs { overrides[r.key] = role }
    }

    /// Drop overrides whose selectable no longer exists. Keyed lookup already
    /// makes a stale entry inert; this keeps a long-lived project's snapshot from
    /// accumulating them.
    public static func pruned(_ overrides: [String: LatticeSelectableRole],
                              live: Set<String>) -> [String: LatticeSelectableRole] {
        overrides.filter { live.contains($0.key) }
    }
}
