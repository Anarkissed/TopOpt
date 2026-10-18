// FlexibleFacePick — STUB (round 7, batch R7-D2: tests first). The real router replaces it in the code commit.
import Foundation
import simd
import TopOptKit

public enum FlexibleFreeFace: Hashable, Sendable {
    case face(FaceID)
    case region(RegionID)
    public var key: String { "" }
}

public enum FlexibleFaceScope: Equatable, Sendable {
    case none
    case pending([FlexibleFreeFace])
    case face(group: UUID, ref: LatticeSelectableRef)
    case group(UUID)
    public var groupID: UUID? { nil }
    public var isNone: Bool { self == .none }
    public var chipKey: String? { nil }
}

public struct FlexibleFacePickSession: Equatable, Sendable {
    public var scope: FlexibleFaceScope = .none
    public var lastGroup: UUID?
    public var lastDepth: Double?
    public init(scope: FlexibleFaceScope = .none, lastGroup: UUID? = nil, lastDepth: Double? = nil) {
        self.scope = scope; self.lastGroup = lastGroup; self.lastDepth = lastDepth
    }
}

enum FlexibleFacePick {
    static func target(face: FaceID, point: SIMD3<Float>?, project p: ProjectModel, mesh: ViewerMesh) -> FlexibleFreeFace { .region(-1) }
    static func owner(of t: FlexibleFreeFace, face: FaceID?, project p: ProjectModel) -> (group: UUID, ref: LatticeSelectableRef)? { nil }
    static func tap(_ s: FlexibleFacePickSession, face: FaceID, point: SIMD3<Float>?, project p: ProjectModel,
                    mesh: ViewerMesh) -> FlexibleFacePickSession { s }
    static func miss(_ s: FlexibleFacePickSession) -> FlexibleFacePickSession { s }
    static func validated(_ s: FlexibleFacePickSession, project p: ProjectModel) -> FlexibleFacePickSession { s }
    static func name(_ t: FlexibleFreeFace, project p: ProjectModel) -> String { "" }
    static func pendingTitle(_ faces: [FlexibleFreeFace], project p: ProjectModel) -> String { "" }
}
