// LoadCaseTagger.swift — turn the M7.6 force/gravity load case into the core's
// face tagging + passive-shell masking via the bridge (MOD-F1 D7).
//
// The M7.6 workspace declares each selection group an Anchor or a Load (ForceModel)
// over a set of B-rep faces (SelectionModel). This maps that load case onto the
// M7.6-core bridge signatures:
//
//   * every anchor/load face is TAGGED   — tag_step_face(asFixture:)   (anchor →
//     Fixture, load → Load), so the solver clamps/loads exactly those voxels; and
//   * every anchor/load face is MASKED    — mask_step_face(.frozenSolid, depth N)
//     — a passive N-voxel shell so the optimizer cannot remove the surface the
//     boundary conditions sit on (D7 / MOD acceptance: "All load and anchor faces
//     are marked passive as an N-voxel shell").
//
// This does NOT run the solver (M7.7) and does NOT apply the traction itself — the
// core's traction path (topopt::traction_loads, added in M7.6-core) is not on the
// Swift bridge, so the load's force vector (ForceModel.loadForceVectorNewtons) is
// carried forward for M7.7's run wiring. Pending groups (no Anchor/Load decision)
// are rejected UP FRONT so a run never half-applies.
//
// The two bridge calls are injected (defaulting to the real TopOptKit) so the
// mapping is unit-tested headlessly with spies — the M7 /app/ verification standard.

import Foundation
import TopOptKit

/// A failure applying the load case.
public enum LoadCaseError: Error, Equatable, CustomStringConvertible {
    /// A selected group still has no Anchor/Load role.
    case pendingGroup(UUID)
    public var description: String {
        switch self {
        case .pendingGroup:
            return "Every selection must be marked Anchor or Load before optimizing."
        }
    }
}

/// The bridge work done for one face: the tag flag used and the voxels the bridge
/// reported tagging + masking.
public struct FaceBridgeCall: Equatable, Sendable {
    public let faceID: FaceID
    public let asFixture: Bool
    public let voxelsTagged: Int
    public let voxelsMasked: Int
}

/// The outcome of applying one group.
public struct GroupApplyResult: Equatable, Sendable {
    public let groupID: UUID
    public let kind: GroupKind
    public let calls: [FaceBridgeCall]
    public var voxelsTagged: Int { calls.reduce(0) { $0 + $1.voxelsTagged } }
    public var voxelsMasked: Int { calls.reduce(0) { $0 + $1.voxelsMasked } }
}

/// Maps the force/gravity load case onto `tag_step_face` + `mask_step_face`.
public struct LoadCaseTagger {
    /// Depth of the passive shell frozen around each BC face, in voxels (D7 "N-voxel
    /// shell"). Must be ≥ 1.
    public let shellDepthVoxels: Int

    /// Injected bridge seams (default to the real TopOptKit).
    private let tagFace: (String, FaceID, Bool, Int) throws -> Int
    private let maskFace: (String, FaceID, Int, Int) throws -> Int

    public init(
        shellDepthVoxels: Int = 2,
        tagFace: @escaping (String, FaceID, Bool, Int) throws -> Int = {
            try TopOptKit.tagStepFace(stepPath: $0, faceID: Int($1), asFixture: $2, resolution: $3)
        },
        maskFace: @escaping (String, FaceID, Int, Int) throws -> Int = {
            try TopOptKit.maskStepFace(stepPath: $0, faceID: Int($1), mask: .frozenSolid,
                                       depthVoxels: $2, resolution: $3)
        }
    ) {
        self.shellDepthVoxels = Swift.max(1, shellDepthVoxels)
        self.tagFace = tagFace
        self.maskFace = maskFace
    }

    /// Apply the load case: tag + mask every anchor/load face of every group.
    ///
    /// Validates first — if any group is still `.pending`, throws
    /// `.pendingGroup` before any bridge call, so a run never half-applies. Anchors
    /// tag as Fixture, loads as Load; both freeze as a `frozenSolid` passive shell.
    ///
    /// - Returns: one `GroupApplyResult` per group, in `groups` order.
    @discardableResult
    public func apply(force: ForceModel,
                      groups: [SelectionGroup],
                      stepPath: String,
                      resolution: Int) throws -> [GroupApplyResult] {
        for g in groups where force.kind(for: g.id).isPending {
            throw LoadCaseError.pendingGroup(g.id)
        }
        var results: [GroupApplyResult] = []
        for g in groups {
            let kind = force.kind(for: g.id)
            let asFixture = kind.isAnchor          // anchor → Fixture, load → Load
            var calls: [FaceBridgeCall] = []
            for face in g.faces {
                let tagged = try tagFace(stepPath, face, asFixture, resolution)
                let masked = try maskFace(stepPath, face, shellDepthVoxels, resolution)
                calls.append(FaceBridgeCall(faceID: face, asFixture: asFixture,
                                            voxelsTagged: tagged, voxelsMasked: masked))
            }
            results.append(GroupApplyResult(groupID: g.id, kind: kind, calls: calls))
        }
        return results
    }
}
