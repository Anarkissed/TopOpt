// FlexibleFlatPrism — R7-E1 STUB (the tests' red run): the edge/corner flat prism's geometry. Signatures only.
import Foundation
import simd
import TopOptKit

public enum FlexibleFlatPrism {
    public struct Cut: Equatable, Hashable, Sendable {
        public var apex: SIMD3<Double>
        public var direction: SIMD3<Double>
        public var depthMM: Double
        public init(apex: SIMD3<Double>, direction: SIMD3<Double>, depthMM: Double) {
            self.apex = apex; self.direction = direction; self.depthMM = depthMM
        }
        public func height(_ p: SIMD3<Double>) -> Double { 0 }
        public func onPlane(_ p: SIMD3<Double>) -> SIMD3<Double> { p }
    }
    public static let minDepthMM = 0.5
    public static let defaultDepthMM = 3.0
    public static let restMarginMM = 0.5
    nonisolated(unsafe) static var controlNoConvexity = false
    nonisolated(unsafe) static var controlThreeDCut = false
    public static func planeNormal(_ m: FlexibleStrip.Member) -> SIMD3<Double>? { nil }
    public static func inwardNormal(_ m: FlexibleStrip.Member, toward d: SIMD3<Double>) -> SIMD3<Double>? { nil }
    public static func edges(_ m: FlexibleStrip.Member) -> [SIMD3<Double>] { [] }
    public static func cornerEdges(_ s: FlexibleStrip) -> [SIMD3<Double>] { [] }
    public static func line(_ s: FlexibleStrip) -> (origin: SIMD3<Double>, dir: SIMD3<Double>, s0: Double, s1: Double)? { nil }
    public static func length(_ s: FlexibleStrip) -> Double { 0 }
    public static func apex(_ s: FlexibleStrip, direction d: SIMD3<Double>) -> SIMD3<Double> { .zero }
    public static func cut(_ s: FlexibleStrip, direction: SIMD3<Double>, depthMM: Double) -> Cut {
        Cut(apex: .zero, direction: direction, depthMM: depthMM)
    }
    public static func halfway(of p: FlexiblePress) -> SIMD3<Double>? { nil }
    public static func isLegacy(_ p: FlexiblePress) -> Bool { true }
    public static func legacyDepth(_ s: FlexibleStrip, d0: SIMD3<Double>) -> Double? { nil }
    public static func depth(of p: FlexiblePress) -> Double? { nil }
    public static func cut(of p: FlexiblePress) -> Cut? { nil }
    public static func planCut(of p: FlexiblePress) -> Cut? { nil }
    public static func memberCuts(_ s: FlexibleStrip, _ c: Cut) -> [[RegionCut]] { s.members.map { _ in [] } }
    public static func pieceCuts(_ s: FlexibleStrip, cut: Cut?) -> [[RegionCut]] {
        s.members.map { FlexibleEdgeStrips.legacyHalfSpaces($0, width: s.widthMM ?? 0) }
    }
    public static func inFace(_ m: FlexibleStrip.Member, _ d: SIMD3<Double>) -> SIMD3<Double>? { nil }
    public static func reach(_ s: FlexibleStrip, member k: Int, _ c: Cut, along: Double? = nil) -> Double? { nil }
    public static func footprint(_ tris: [[SIMD3<Double>]], _ cuts: [RegionCut]) -> [[SIMD3<Double>]] { [] }
    public static func traces(_ polys: [[SIMD3<Double>]], _ c: Cut, tolerance: Double = 1e-6) -> [[SIMD3<Double>]] { [] }
    public static func wedge(_ polys: [[SIMD3<Double>]], _ c: Cut) -> FaceOffsetShell? { nil }
    public static func convexityLine(_ s: FlexibleStrip, d0: SIMD3<Double>) -> String? { nil }
    public static func keepsRest(_ tris: [[SIMD3<Double>]], member m: FlexibleStrip.Member, _ c: Cut) -> Bool { true }
    public static func latticeCap(_ st: FlexStackInfo, apexT: Double) -> Double? { nil }
}
