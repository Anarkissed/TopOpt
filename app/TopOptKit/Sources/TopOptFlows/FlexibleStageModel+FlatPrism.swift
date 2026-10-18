// FlexibleStageModel+FlatPrism — R7-E1 STUB (the tests' red run): the flat prism's engine. Signatures only.
import Foundation
import simd
import TopOptKit

/// What a drag shows before the release commits it (never in the settings, never in history).
public struct FlexibleFlatPreview: Equatable, Sendable {
    public let press: UUID
    public var depthMM: Double
    public var direction: SIMD3<Double>
}

/// A release the lattice (or a limit) stopped: its one line and the fix's number ([Set N mm]).
public struct FlexibleFlatStop: Equatable, Sendable {
    public let press: UUID
    public let line: String
    public let setMM: Double?
}

extension FlexibleStageModel {
    @MainActor static var controlRefuseFlatCut: String?
    @MainActor static var controlLiveFlatWrites = false

    public func setFlatCut(_ id: UUID, depthMM: Double, direction: SIMD3<Double>, snap: String?) async -> String? { "R7-E1 stub" }
    public func previewFlatCut(_ id: UUID, depthMM: Double?, direction: SIMD3<Double>?) {}
    public func commitFlatPreview(_ id: UUID) async -> String? { "R7-E1 stub" }
    public func flatCut(_ id: UUID) -> FlexibleFlatPrism.Cut? { nil }
    public func pressKey(_ id: UUID) -> Int? { nil }
    public func pressStack(_ id: UUID) -> FlexStackInfo? { nil }
    public func flatLatticeCap(_ id: UUID) -> Double? { nil }
}
