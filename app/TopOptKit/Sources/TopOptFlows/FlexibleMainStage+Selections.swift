// FlexibleMainStage+Selections — STUB (round 7, batch R7-D2: tests first).
import Foundation
import simd
import SwiftUI
import TopOptKit

extension FlexibleMainStage {
    public func tapFace(_ project: ProjectModel, face: FaceID, point: SIMD3<Float>?, mesh: ViewerMesh) {}
    public func missTap() {}
    func pickGroup(_ gid: UUID, project: ProjectModel) {}
    func pickFace(_ ref: LatticeSelectableRef, group gid: UUID, project: ProjectModel) {}
    func pickedPlaneKeys(_ project: ProjectModel) -> Set<String>? { nil }
    func pickedPlanes(_ project: ProjectModel) -> [ProjectModel.LatticeDepthPlane] { [] }
    static func prismAlphas(bright: Bool, faint: Bool, overLattice: Bool) -> (face: Float?, edge: Float?) { (nil, nil) }
}
