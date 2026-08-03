// FrozenRegionLatticeStatus.swift — task 2026-08-04-protect-freeze-vs-solidity,
// bar 6: THE LATTICE PAGE MUST SHOW WHICH FROZEN REGIONS ARE LATTICED AND WHICH
// ARE SOLID.
//
// WHY THIS EXISTS. "Protect" freezes a face's material: the optimizer may not
// reshape it. It says nothing about whether that material ends up SOLID or
// LATTICED — that is the Lattice page's include/exclude decision, exactly as it
// is for any other retained material. Before this task the app never said so
// anywhere, so a user who marked a wall Protect and then declared a lattice over
// it had no way to know which of the two he was going to get. On the
// maintainer's own part, 10,070 voxels of his declared lattice region were
// frozen by his own Protect collar, and nothing in the app mentioned it.
//
// THE RULE IS CORE'S RULE, NOT A SECOND ONE. lattice_certification_mask decides
// a voxel latticed iff it is printed AND outside every clearance keep-out AND
// outside every EXCLUDE region AND — when any include region exists — inside the
// include union. This derivation mirrors that precedence at GROUP granularity so
// the page can state it before the run:
//
//   * a protected group carrying role `exclude`  -> SOLID   (retained + solid)
//   * a protected group carrying role `include`  -> LATTICED (retained + latticed)
//   * a protected group carrying NO role, when some OTHER group declares an
//     include region                             -> SOLID
//     (an include region anywhere means "only the include union is latticed";
//      this group is outside it)
//   * a protected group carrying NO role, when NO include region exists anywhere
//     -> LATTICED (whole-part lattice — the page said "lattice everything")
//
// Group granularity is honest but COARSER than the run: a group's region and the
// protected collar are two different solids and they need not coincide voxel for
// voxel, so this states the INTENT the page expresses, and the run's own receipt
// states the measured split (run_info lattice_export.frozen_latticed /
// frozen_kept_solid). `caveat` carries that distinction rather than hiding it.
//
// Pure derivation over value types, no view or model dependency, so it is
// headlessly unit-tested (the lesson of "tests on value types miss call sites"
// is answered by LatticePage calling exactly this function — see `statusRows`).

import Foundation

public enum FrozenRegionLatticeStatus {

    public enum Outcome: String, Equatable, Sendable {
        case latticed
        case solid

        public var label: String { self == .latticed ? "Latticed" : "Solid" }
        public var symbol: String {
            self == .latticed ? "circle.grid.cross" : "square.fill"
        }
    }

    /// One protected group and what the current lattice declaration makes of it.
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let outcome: Outcome
        /// Why, in the user's words — short enough for a row subtitle.
        public let reason: String

        public init(id: UUID, name: String, outcome: Outcome, reason: String) {
            self.id = id
            self.name = name
            self.outcome = outcome
            self.reason = reason
        }
    }

    /// The rows for the page. `protectedGroups` are the groups carrying a Protect
    /// affix (ForceModel.protectedGroups); `roles` is LatticeSettings.groupRoles;
    /// `anyIncludeDeclared` must be true iff ANY include region will be emitted —
    /// including include regions from groups that are NOT protected and the legacy
    /// standalone include primitives, which is why the caller supplies it rather
    /// than this function inferring it from `roles` alone.
    public static func rows(protectedGroups: [SelectionGroup],
                            roles: [UUID: LatticeGroupRole],
                            anyIncludeDeclared: Bool) -> [Row] {
        protectedGroups.map { g in
            switch roles[g.id] {
            case .some(.exclude):
                return Row(id: g.id, name: g.name, outcome: .solid,
                           reason: "Protected, and marked “no lattice here”.")
            case .some(.include):
                return Row(id: g.id, name: g.name, outcome: .latticed,
                           reason: "Protected, and marked “lattice here” — the "
                                 + "shape is frozen, the inside is latticed.")
            case .none:
                if anyIncludeDeclared {
                    return Row(id: g.id, name: g.name, outcome: .solid,
                               reason: "Protected. Only the regions you marked "
                                     + "“lattice here” are latticed, and this is "
                                     + "not one of them.")
                }
                return Row(id: g.id, name: g.name, outcome: .latticed,
                           reason: "Protected. No region is marked “lattice "
                                 + "here”, so the whole part is latticed — "
                                 + "including this.")
            }
        }
    }

    /// The one-line summary above the rows. Empty when nothing is protected, so
    /// the section can hide itself entirely on a part with no Protect affix.
    public static func summary(_ rows: [Row]) -> String {
        if rows.isEmpty { return "" }
        let latticed = rows.filter { $0.outcome == .latticed }.count
        let solid = rows.count - latticed
        if latticed == 0 {
            return "\(solid) protected \(solid == 1 ? "region stays" : "regions stay") solid."
        }
        if solid == 0 {
            return "\(latticed) protected \(latticed == 1 ? "region is" : "regions are") latticed."
        }
        return "\(latticed) protected \(latticed == 1 ? "region" : "regions") "
             + "latticed, \(solid) solid."
    }

    /// The honest caveat: this is the INTENT the declaration expresses, at group
    /// granularity; the run reports the measured voxel split. Shown once under
    /// the rows, never per row.
    public static let caveat =
        "Protect freezes the shape — it does not decide solid vs latticed. "
      + "These are the regions as declared; the run reports the exact voxel split."
}
