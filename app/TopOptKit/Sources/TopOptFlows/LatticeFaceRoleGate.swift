// LatticeFaceRoleGate.swift — ★ WHICH FACES MAY CARRY A LATTICE ROLE
// (task 2026-08-12-lattice-page-redesign §1a / §1d).
//
// THE MAINTAINER'S RULE, VERBATIM: "a face cannot be selected without saying
// either 'don't let TO touch this' or 'don't let anyone touch this'." So the
// lattice flow does not introduce a new way to pick faces — it rides the four
// roles the setup page already has:
//
//     PROTECT     TO may not touch it            → may be latticed  ★ PRIMARY
//     ANCHOR      the part is clamped here       → may be latticed
//     LOAD        the force arrives here         → may be latticed
//     KEEP CLEAR  nothing may touch it           → BLOCKS both (§1d)
//     (nothing)   undeclared                     → BLOCKS both (§1a)
//
// PROTECT + LATTICE IS THE PRIMARY WORKFLOW (§1c), not an edge case: the face is
// held against TO to the dragged depth and THAT held material is what the
// lattice lightens. It is the barrier model in one gesture.
//
// KEEP CLEAR BLOCKS BOTH because it is the one role that means "no material" —
// core's own precedence has clearance beating include and exclude alike, so a
// lattice role on a keep-clear face would be a declaration the run discards. It
// is refused here instead of being silently dropped later.
//
// Pure derivation, no view: the gate is the same function the chips, the
// spawn-on-lattice path and the tests all read.

import Foundation

public enum LatticeFaceRoleGate {

    /// Why a group may not carry a lattice role. `nil` ⇒ it may.
    public enum Block: Equatable, Sendable {
        /// The group has declared nothing yet.
        case undeclared
        /// The group is "Keep clear" — nothing may occupy this space.
        case keepClear

        /// The chip's disabled reason. ★ Five words at most (R3).
        public var reason: String {
            switch self {
            case .undeclared: return "Give this face a role first"
            case .keepClear:  return "Keep clear blocks lattice"
            }
        }
    }

    /// Whether `group` may be set to "Lattice here" / "No lattice here", and why
    /// not when it may not.
    ///
    /// `keepClearOn` is the group's EFFECTIVE keep-clear (including the anchored-
    /// bore auto), which only the caller can resolve — `ForceModel.keepClearIsOn`
    /// takes the auto default the workspace computes.
    public static func block(kind: GroupKind, protected: Bool,
                             keepClearOn: Bool) -> Block? {
        if keepClearOn { return .keepClear }
        if kind.isAnchor || kind.isLoad { return nil }
        if protected { return nil }
        return .undeclared
    }

    public static func allowed(kind: GroupKind, protected: Bool,
                               keepClearOn: Bool) -> Bool {
        block(kind: kind, protected: protected, keepClearOn: keepClearOn) == nil
    }

    /// A lattice role that a role change has invalidated must be DROPPED, not
    /// left to be silently discarded by the run. Returns the roles map with every
    /// now-ineligible group removed. Applied whenever a group's role or its
    /// keep-clear attribute changes.
    public static func pruned(roles: [UUID: LatticeGroupRole],
                              eligible: (UUID) -> Bool) -> [UUID: LatticeGroupRole] {
        roles.filter { eligible($0.key) }
    }
}
