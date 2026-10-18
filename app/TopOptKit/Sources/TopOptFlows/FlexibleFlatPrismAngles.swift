// FlexibleFlatPrismAngles — R7-E1 STUB (the tests' red run): the flat prism's two angles. Signatures only.
import Foundation
import simd
import TopOptKit

public enum FlexibleFlatPrismAngles {
    public static let snapDeg = 3.0
    public struct Frame: Equatable, Sendable {
        public let d0: SIMD3<Double>
        public let tilt: SIMD3<Double>
        public let twist: SIMD3<Double>
        public let corner: Bool
        public let tiltMember: Int
        public let twistMember: Int?
        public let namedEnd: String
    }
    public static func frame(_ s: FlexibleStrip, d0: SIMD3<Double>, up: SIMD3<Double>) -> Frame? { nil }
    public static func compose(_ f: Frame, theta: Double, phi: Double) -> SIMD3<Double> { f.d0 }
    public static func decompose(_ f: Frame, _ d: SIMD3<Double>) -> (theta: Double, phi: Double) { (0, 0) }
    public static func snapped(_ deg: Double) -> Double { deg }
    public enum Stop: Equatable, Sendable { case edgeOn(Int), cross(Int), rest(Int), farEnd, lattice(Double), shallow }
    public struct Limits {
        public var loads: [SIMD3<Double>]
        public var keepsRest: (SIMD3<Double>, Double) -> Int?
        public var latticeCapMM: Double?
        public init(loads: [SIMD3<Double>], keepsRest: @escaping (SIMD3<Double>, Double) -> Int? = { _, _ in nil },
                    latticeCapMM: Double? = nil) {
            self.loads = loads; self.keepsRest = keepsRest; self.latticeCapMM = latticeCapMM
        }
    }
    public static func check(_ s: FlexibleStrip, d: SIMD3<Double>, h: Double, limits: Limits) -> Stop? { nil }
    public static func clamp(_ s: FlexibleStrip, frame f: Frame, h: Double, from: (theta: Double, phi: Double),
                             to: (theta: Double, phi: Double), limits: Limits) -> (theta: Double, phi: Double, stop: Stop?) {
        (to.theta, to.phi, nil)
    }
    public static func limit(_ s: FlexibleStrip, frame f: Frame, h: Double, at: (theta: Double, phi: Double), tilt: Bool, sign: Double,
                             limits: Limits) -> (deg: Double, stop: Stop?) { (0, nil) }
    public static func depthRange(_ s: FlexibleStrip, d: SIMD3<Double>, limits: Limits, probeMM: Double = 1000)
        -> (min: Double, max: Double, minStop: Stop, maxStop: Stop?) { (0.5, 1000, .shallow, nil) }
    public static func line(_ stop: Stop, strip s: FlexibleStrip, name: (Int) -> String) -> String { "" }
    public static func heldLine(_ value: Double, unit: String, stop: Stop, strip s: FlexibleStrip, name: (Int) -> String) -> String { "" }
}
