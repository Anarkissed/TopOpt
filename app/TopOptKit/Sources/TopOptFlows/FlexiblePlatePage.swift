// FlexiblePlatePage — STUB (tests first; the review of R7-D1).
import SwiftUI
import TopOptDesign

public enum FlexiblePlatePage {
    public struct Choice: Equatable, Sendable { public let label: String; public let dir: SIMD3<Float>; public let lit: Bool }
    public static let question = ""
    public static let assumeTitle = ""
    public static func choices(orientation: BuildOrientation, gravity: SIMD3<Float>?) -> [Choice] { [] }
    public static func stateLine(orientation: BuildOrientation, gravity: SIMD3<Float>?) -> String { "" }
    @MainActor public static func pick(_ dir: SIMD3<Float>, project: ProjectModel) {}
    @MainActor public static func assume(project: ProjectModel) {}
}
