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
//   * .frozen  → mask_step_face(.frozenSolid, N)  — passive keep-in shell
//
// The bridge now forwards `mask_step_face` (TopOptKit.maskStepFace, added for the
// M7.6 passive shell / handoff 100 clearance work), so a Frozen group is applied
// as an N-voxel FrozenSolid keep-in shell instead of the old `.frozenUnsupported`
// error — that throw is gone (handoff 100). (Keep-OUT clearance — the "Keep clear"
// FrozenVoid regions — is derived shape-aware core-side from the load case, not
// through this per-face tagger; see ProjectModel.clearanceSpecs.)
//
// Both bridge calls are injected (defaulting to the real TopOptKit) so the mapping
// is unit-tested headlessly with spies — proving each group tags/masks with the
// right face ids — the M7 /app/ verification standard.

import Foundation
import TopOptKit

/// The per-face bridge call the tagger made (one per face id in a group), for
/// verification and reporting.
public struct FaceTagCall: Equatable, Sendable {
    public let faceID: FaceID
    /// The role applied to this face (fixture/load → tag, frozen → mask).
    public let role: GroupRole
    public let asFixture: Bool
    /// Voxels the bridge reported tagging (fixture/load) or masking (frozen).
    public let voxelsTagged: Int
    public init(faceID: FaceID, role: GroupRole, asFixture: Bool, voxelsTagged: Int) {
        self.faceID = faceID
        self.role = role
        self.asFixture = asFixture
        self.voxelsTagged = voxelsTagged
    }
}

/// The outcome of tagging one group.
public struct GroupTagResult: Equatable, Sendable {
    public let groupID: UUID
    public let role: GroupRole
    public let calls: [FaceTagCall]
    /// Total voxels tagged across the group's faces.
    public var voxelsTagged: Int { calls.reduce(0) { $0 + $1.voxelsTagged } }
}

/// The FrozenSolid keep-in shell depth (voxels) a `.frozen` group masks. Matches
/// the LoadCaseTagger passive-shell default.
public let kSelectionFrozenShellDepthVoxels = 2

/// Maps selection groups onto the core's `tag_step_face` / `mask_step_face` bridge
/// entry points.
public struct SelectionTagger {
    /// Injected bridge seams. `tagFace`: `(stepPath, faceID, asFixture, resolution)
    /// -> voxels`; `maskFace`: `(stepPath, faceID, depthVoxels, resolution) -> voxels`.
    private let tagFace: (String, FaceID, Bool, Int) throws -> Int
    private let maskFace: (String, FaceID, Int, Int) throws -> Int

    public init(
        tagFace: @escaping (String, FaceID, Bool, Int) throws -> Int = {
            try TopOptKit.tagStepFace(stepPath: $0, faceID: Int($1), asFixture: $2, resolution: $3)
        },
        maskFace: @escaping (String, FaceID, Int, Int) throws -> Int = {
            try TopOptKit.maskStepFace(stepPath: $0, faceID: Int($1), mask: .frozenSolid,
                                       depthVoxels: $2, resolution: $3)
        }
    ) {
        self.tagFace = tagFace
        self.maskFace = maskFace
    }

    /// Apply every group to the STEP part at `stepPath`, voxelized at `resolution`,
    /// per its role: Fixture/Load faces are tagged (tag_step_face), Frozen faces are
    /// masked as an N-voxel FrozenSolid keep-in shell (mask_step_face). A group with
    /// no faces makes no calls.
    ///
    /// - Returns: one `GroupTagResult` per group, in `groups` order.
    @discardableResult
    public func apply(groups: [SelectionGroup],
                      role: (SelectionGroup) -> GroupRole,
                      stepPath: String,
                      resolution: Int) throws -> [GroupTagResult] {
        var results: [GroupTagResult] = []
        for g in groups {
            let r = role(g)
            let asFixture = r == .fixture
            var calls: [FaceTagCall] = []
            for face in g.faces {
                let voxels: Int
                if r == .frozen {
                    voxels = try maskFace(stepPath, face, kSelectionFrozenShellDepthVoxels, resolution)
                } else {
                    voxels = try tagFace(stepPath, face, asFixture, resolution)
                }
                calls.append(FaceTagCall(faceID: face, role: r, asFixture: asFixture,
                                         voxelsTagged: voxels))
            }
            results.append(GroupTagResult(groupID: g.id, role: r, calls: calls))
        }
        return results
    }
}
