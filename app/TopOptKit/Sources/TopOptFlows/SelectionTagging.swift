// SelectionTagging.swift — map M7.5 selection groups onto the core's face tagging.
//
// A selection group is a set of B-rep face ids (SelectionModel); this turns each
// group into a real tagged voxel region via the bridge, so a later optimize run
// clamps/loads/freezes exactly the user's faces (ROADMAP M7.5: "a group becomes a
// real tagged voxel region"). No optimization run here (that is M7.7).
//
// Role → bridge mapping:
//   * .fixture → tag_step_face(asFixture: true)   — clamped mounting face
//   * .load    → tag_step_face(asFixture: false)  — loaded face
//   * .frozen  → mask_step_face(...)              — NOT EXPOSED BY THE BRIDGE.
//
// The core has `mask_step_face` (M3.7 passive keep-in/keep-out) but the bridge
// (TopOptBridge.hpp) only forwards `tag_step_face`, so Frozen groups cannot be
// applied yet. Per the M7.5 rules ("do not widen the bridge yourself; file
// Blocked") this reports `.frozenUnsupported` instead of silently dropping the
// group; the handoff's Blocked section requests the accessor.
//
// The bridge call is injected (defaulting to `TopOptKit.tagStepFace`) so the
// mapping is unit-tested headlessly with a spy — proving each group tags with the
// right face ids and Fixture/Load flags — the M7 /app/ verification standard.

import Foundation
import TopOptKit

/// A failure applying a selection group to the grid.
public enum SelectionTagError: Error, Equatable, CustomStringConvertible {
    /// A group is Frozen, but the bridge does not expose `mask_step_face` yet.
    case frozenUnsupported
    public var description: String {
        switch self {
        case .frozenUnsupported:
            return "Frozen (keep-in/keep-out) groups need the core's mask_step_face, "
                 + "which the bridge does not expose yet."
        }
    }
}

/// The per-face bridge call the tagger made (one per face id in a group), for
/// verification and reporting.
public struct FaceTagCall: Equatable, Sendable {
    public let faceID: FaceID
    public let asFixture: Bool
    /// Voxels the bridge reported tagging against this face.
    public let voxelsTagged: Int
}

/// The outcome of tagging one group.
public struct GroupTagResult: Equatable, Sendable {
    public let groupID: UUID
    public let role: GroupRole
    public let calls: [FaceTagCall]
    /// Total voxels tagged across the group's faces.
    public var voxelsTagged: Int { calls.reduce(0) { $0 + $1.voxelsTagged } }
}

/// Maps selection groups onto the core's `tag_step_face` bridge entry point.
public struct SelectionTagger {
    /// Injected bridge seam: `(stepPath, faceID, asFixture, resolution) -> voxels`.
    private let tagFace: (String, FaceID, Bool, Int) throws -> Int

    public init(tagFace: @escaping (String, FaceID, Bool, Int) throws -> Int = {
        try TopOptKit.tagStepFace(stepPath: $0, faceID: Int($1), asFixture: $2, resolution: $3)
    }) {
        self.tagFace = tagFace
    }

    /// Apply every group to the STEP part at `stepPath`, voxelized at `resolution`,
    /// tagging each group's faces per its role.
    ///
    /// Frozen groups are rejected UP FRONT (before any tagging) with
    /// `.frozenUnsupported`, so a run never half-applies. Fixture/Load groups tag
    /// each of their face ids via the bridge; a group with no faces makes no calls.
    ///
    /// - Returns: one `GroupTagResult` per group, in `groups` order.
    @discardableResult
    public func apply(groups: [SelectionGroup],
                      role: (SelectionGroup) -> GroupRole,
                      stepPath: String,
                      resolution: Int) throws -> [GroupTagResult] {
        // Validate first: no partial tagging if any group is Frozen.
        for g in groups where role(g) == .frozen {
            throw SelectionTagError.frozenUnsupported
        }
        var results: [GroupTagResult] = []
        for g in groups {
            let asFixture = role(g) == .fixture
            var calls: [FaceTagCall] = []
            for face in g.faces {
                let voxels = try tagFace(stepPath, face, asFixture, resolution)
                calls.append(FaceTagCall(faceID: face, asFixture: asFixture, voxelsTagged: voxels))
            }
            results.append(GroupTagResult(groupID: g.id, role: role(g), calls: calls))
        }
        return results
    }
}
