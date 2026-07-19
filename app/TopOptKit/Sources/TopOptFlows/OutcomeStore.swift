// OutcomeStore.swift — persist optimize results across app launches (persist-c).
//
// A run's `OptimizeOutcome` (variant meshes, stress fields, AND the optimization-
// history keyframes for playback) is far too heavy for the JSON snapshot, so it is
// serialized separately: the big `[Float]`/`[Int32]` arrays are packed as raw
// little-endian `Data` blobs (near the minimal on-disk size, memcpy-fast) inside
// Codable DTOs, encoded as a BINARY property list (which stores `Data` natively —
// no base64 bloat). The DTOs are `Sendable` so the encode + file write run off the
// main thread. Decode failures degrade gracefully to "no results" (the card still
// reads Optimized; opening just shows the original until a re-run).

import Foundation
import simd
import TopOptKit

enum OutcomeCodec {
    // MARK: DTOs (Sendable so they can cross to a background queue)

    struct MeshDTO: Codable, Sendable { let v: Data; let i: Data }

    struct VariantDTO: Codable, Sendable {
        let requestedVolumeFraction, achievedVolumeFraction, massGrams: Double
        // Handoff 104: the printed/count basis by name. Optional so blobs written
        // before this field existed still decode (→ nil → OptimizeVariant defaults it
        // to achievedVolumeFraction, i.e. the same count basis → identical savings).
        let printedFraction: Double?
        let supportVolumeVoxels, meshTriangleCount: Int
        let worstCaseMargin: Double
        let accepted, v3Passes: Bool
        let minFeatureViolations: Int
        let minFeatureWarning: String
        let orientation: [Double]      // 3 components
        let maxStressMPa, maxInterlayerTensionMPa, inPlaneMargin, interlayerMargin: Double
        let meshVertices: Data
        let meshIndices: Data
        let vonMisesField: Data
        // M7.viz.3: the per-node FEA displacement field, persisted alongside the von
        // Mises field so a reopened project flexes without re-optimizing. Optional so
        // blobs written before this field existed still decode (→ empty → no flex
        // until a re-run), rather than failing the whole outcome.
        let displacementField: Data?
        let keyframes: [MeshDTO]
    }

    // Handoff 100's per-face "Keep clear" outcome, mirrored for persistence so a
    // reopened run keeps its honest clearance notes (ResultsModel.clearanceNotes).
    // `kind` is the raw value of `TopOptKit.ClearanceKind` (an Int enum).
    struct AppliedClearanceDTO: Codable, Sendable {
        let faceID: Int
        let kind: Int
        let voxelsFrozen: Int
        let inGrid: Bool
    }

    struct OutcomeDTO: Codable, Sendable {
        let variants: [VariantDTO]
        let stoppedOnMargin, cancelled: Bool
        let acceptedCount: Int
        let voxelVolumeMM3: Double
        let gridNx, gridNy, gridNz: Int
        let gridOrigin: [Double]       // 3 components
        let spacing: Double
        // LAN offload (097): the remote-compute flag MUST survive the persist/restore
        // round-trip, or a reopened remote result forgets it was computed on the Mac
        // and lies — the withheld mass renders as a plausible "0.0 g", the "computed on
        // Mac" note vanishes, and the stress/playback controls come back dead (the exact
        // 097 honesty gap this DTO once silently dropped). Optional so blobs written
        // before this field existed still decode (→ nil → false, correct: they predate
        // remote runs, and there is no honest value to recover for one anyway).
        let computedRemotely: Bool?
        // Optional so blobs written before this field existed still decode (→ nil →
        // no clearance notes), rather than failing the whole outcome. Empty when no
        // "Keep clear" clearance was declared.
        let appliedClearances: [AppliedClearanceDTO]?
    }

    // MARK: OptimizeOutcome → DTO (cheap: array→Data is a memcpy)

    static func dto(from o: OptimizeOutcome) -> OutcomeDTO {
        OutcomeDTO(
            variants: o.variants.map { v in
                VariantDTO(
                    requestedVolumeFraction: v.requestedVolumeFraction,
                    achievedVolumeFraction: v.achievedVolumeFraction,
                    massGrams: v.massGrams,
                    printedFraction: v.printedFraction,
                    supportVolumeVoxels: v.supportVolumeVoxels,
                    meshTriangleCount: v.meshTriangleCount,
                    worstCaseMargin: v.worstCaseMargin,
                    accepted: v.accepted, v3Passes: v.v3Passes,
                    minFeatureViolations: v.minFeatureViolations,
                    minFeatureWarning: v.minFeatureWarning,
                    orientation: [v.orientation.x, v.orientation.y, v.orientation.z],
                    maxStressMPa: v.maxStressMPa,
                    maxInterlayerTensionMPa: v.maxInterlayerTensionMPa,
                    inPlaneMargin: v.inPlaneMargin, interlayerMargin: v.interlayerMargin,
                    meshVertices: pack(v.meshVertices),
                    meshIndices: pack(v.meshIndices),
                    vonMisesField: pack(v.vonMisesField),
                    displacementField: pack(v.displacementField),
                    keyframes: v.keyframeMeshes.map { MeshDTO(v: pack($0.vertices), i: pack($0.indices)) })
            },
            stoppedOnMargin: o.stoppedOnMargin, cancelled: o.cancelled,
            acceptedCount: o.acceptedCount, voxelVolumeMM3: o.voxelVolumeMM3,
            gridNx: o.gridNx, gridNy: o.gridNy, gridNz: o.gridNz,
            gridOrigin: [o.gridOrigin.x, o.gridOrigin.y, o.gridOrigin.z],
            spacing: o.spacing,
            computedRemotely: o.computedRemotely,
            appliedClearances: o.appliedClearances.map {
                AppliedClearanceDTO(faceID: $0.faceID, kind: $0.kind.rawValue,
                                    voxelsFrozen: $0.voxelsFrozen, inGrid: $0.inGrid) })
    }

    // MARK: DTO → OptimizeOutcome

    static func outcome(from d: OutcomeDTO) -> OptimizeOutcome {
        OptimizeOutcome(
            variants: d.variants.map { v in
                OptimizeVariant(
                    requestedVolumeFraction: v.requestedVolumeFraction,
                    achievedVolumeFraction: v.achievedVolumeFraction,
                    printedFraction: v.printedFraction,
                    massGrams: v.massGrams,
                    supportVolumeVoxels: v.supportVolumeVoxels,
                    meshTriangleCount: v.meshTriangleCount,
                    worstCaseMargin: v.worstCaseMargin,
                    accepted: v.accepted, v3Passes: v.v3Passes,
                    minFeatureViolations: v.minFeatureViolations,
                    minFeatureWarning: v.minFeatureWarning,
                    orientation: vec(v.orientation),
                    maxStressMPa: v.maxStressMPa,
                    maxInterlayerTensionMPa: v.maxInterlayerTensionMPa,
                    inPlaneMargin: v.inPlaneMargin, interlayerMargin: v.interlayerMargin,
                    meshVertices: unpackFloats(v.meshVertices),
                    meshIndices: unpackInts(v.meshIndices),
                    vonMisesField: unpackFloats(v.vonMisesField),
                    displacementField: unpackFloats(v.displacementField ?? Data()),
                    keyframeMeshes: v.keyframes.map {
                        KeyframeMesh(vertices: unpackFloats($0.v), indices: unpackInts($0.i)) })
            },
            stoppedOnMargin: d.stoppedOnMargin, cancelled: d.cancelled,
            acceptedCount: d.acceptedCount, voxelVolumeMM3: d.voxelVolumeMM3,
            gridNx: d.gridNx, gridNy: d.gridNy, gridNz: d.gridNz,
            gridOrigin: vec(d.gridOrigin), spacing: d.spacing,
            computedRemotely: d.computedRemotely ?? false,
            appliedClearances: (d.appliedClearances ?? []).map {
                AppliedClearance(faceID: $0.faceID,
                                 kind: TopOptKit.ClearanceKind(rawValue: $0.kind) ?? .face,
                                 voxelsFrozen: $0.voxelsFrozen, inGrid: $0.inGrid) })
    }

    // MARK: Encode / decode (binary plist)

    static func encode(_ dto: OutcomeDTO) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(dto)
    }

    static func decode(_ data: Data) throws -> OptimizeOutcome {
        outcome(from: try PropertyListDecoder().decode(OutcomeDTO.self, from: data))
    }

    // MARK: Array ↔ Data (raw little-endian; ARM64 + x86 are both LE)

    private static func pack<T>(_ a: [T]) -> Data { a.withUnsafeBytes { Data($0) } }

    private static func unpackFloats(_ d: Data) -> [Float] {
        guard !d.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: d.count / MemoryLayout<Float>.stride)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0) }   // alignment-safe
        return out
    }

    private static func unpackInts(_ d: Data) -> [Int32] {
        guard !d.isEmpty else { return [] }
        var out = [Int32](repeating: 0, count: d.count / MemoryLayout<Int32>.stride)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return out
    }

    private static func vec(_ a: [Double]) -> SIMD3<Double> {
        a.count == 3 ? SIMD3(a[0], a[1], a[2]) : .zero
    }
}
