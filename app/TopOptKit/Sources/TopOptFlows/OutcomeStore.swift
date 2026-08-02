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
        // M7.viz.5 / handoff 122: the per-voxel Cauchy stress TENSOR, persisted so a
        // reopened run keeps the load→anchor flow overlay (previously DROPPED on the
        // round-trip — the exact 108/134 class of honesty bug, fixed here preemptively).
        // Optional so blobs written before this field existed still decode (→ empty →
        // the anchor-flow sub-mode stays gated until a re-run), never failing the outcome.
        let stressTensorField: Data?
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

    // Handoff 124's per-face Face-protection outcome, mirrored for persistence so a
    // reopened run keeps its honest protection notes (ResultsModel.faceProtectionNotes)
    // — the same honesty-round-trip discipline as AppliedClearanceDTO, so a restored
    // outcome never silently drops what was preserved.
    struct AppliedFaceProtectionDTO: Codable, Sendable {
        let faceID: Int
        let voxelsFrozen: Int
        let depthVoxels: Int
        let thinnerThanDepth: Bool
    }

    // Handoff 2026-07-29-lattice-mode-ui — the lattice a run carried, mirrored for
    // persistence so a reopened lattice run keeps its honest lattice notes
    // (ResultsModel.latticeNotes), the same honesty-round-trip discipline as the
    // clearance/protection DTOs. `generated*` fields are present only when the worker
    // reported a lattice_export; all optional so pre-lattice blobs decode (→ nil).
    struct LatticeReportDTO: Codable, Sendable {
        let topologyID: String
        let cellMM: Double
        let generateRelativeDensity: Double
        let minRelativeDensity: Double
        let maxRelativeDensity: Double
        let regionScoped: Bool
        let genEmitSTL: Bool?
        let genEmit3MF: Bool?
        let genLatticedCells: Int?
        let genRegionVoxels: Int?
        let genTriangles: Int?
        let genStrutRadiusMinMM: Double?
        let genStrutRadiusMaxMM: Double?
        // Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report) —
        // mirrored so a reopened lattice run keeps BOTH margins and the
        // out-of-regime caveat (the OutcomeStore honesty rule: the DTO mirrors
        // every displayed fact, or a reopened result silently lies). All optional
        // so pre-report blobs decode (→ nil → no strut lines). Infinite margins
        // (an unloaded failure mode) are stored as nil and restored as +inf.
        let strutMarginInPlane: Double?
        let strutMarginInterlayer: Double?
        let strutZKnockdown: Double?
        let strutMinCellsPerMember: Double?
        let strutOutOfRegime: Bool?
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
        // Handoff 124 — same optional discipline: nil on pre-124 blobs (→ no
        // protection notes), empty when no Face protection was declared.
        let appliedFaceProtections: [AppliedFaceProtectionDTO]?
        // Handoff 134 — the run's DURATION (queue wait + solve seconds). It must
        // survive the round-trip for the same reason `computedRemotely` must: a
        // reopened result that lost it would have to re-derive a duration at display
        // time, and the only clock available then is `now()` — which is exactly the
        // observer-dependent "11 hours" this handoff removed. Optional so pre-134
        // blobs still decode (→ nil → no duration shown, honest for a result that
        // never recorded one).
        let queuedSeconds: Double?
        let solveSeconds: Double?
        // Handoff 2026-07-29-lattice-mode-ui — nil on pre-lattice blobs (→ no lattice
        // notes), present when the run carried a lattice.
        let latticeReport: LatticeReportDTO?
        // Task 2026-08-03-variant-entry-gating-and-retention (AJ5) — WHICH MACHINE
        // solved the run. Persisted for the same reason `computedRemotely` is: a
        // reopened result that forgot where it ran would put the app right back in
        // the position this task exists to fix — telling a user to "re-run it on a
        // Mac worker" when they may have done exactly that. nil on pre-AJ5 blobs and
        // on local runs; combined with `computedRemotely` by `SolvingMachine`, which
        // is the ONLY thing allowed to interpret the pair.
        let solvedBy: String?
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
                    stressTensorField: pack(v.stressTensorField),
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
                                    voxelsFrozen: $0.voxelsFrozen, inGrid: $0.inGrid) },
            appliedFaceProtections: o.appliedFaceProtections.map {
                AppliedFaceProtectionDTO(faceID: $0.faceID, voxelsFrozen: $0.voxelsFrozen,
                                         depthVoxels: $0.depthVoxels,
                                         thinnerThanDepth: $0.thinnerThanDepth) },
            queuedSeconds: o.timing?.queuedSeconds,
            solveSeconds: o.timing?.solveSeconds,
            latticeReport: o.latticeReport.map { r in
                LatticeReportDTO(
                    topologyID: r.topologyID, cellMM: r.cellMM,
                    generateRelativeDensity: r.generateRelativeDensity,
                    minRelativeDensity: r.minRelativeDensity,
                    maxRelativeDensity: r.maxRelativeDensity,
                    regionScoped: r.regionScoped,
                    genEmitSTL: r.generated?.emitSTL, genEmit3MF: r.generated?.emit3MF,
                    genLatticedCells: r.generated?.latticedCells,
                    genRegionVoxels: r.generated?.regionVoxels,
                    genTriangles: r.generated?.triangles,
                    genStrutRadiusMinMM: r.generated?.strutRadiusMinMM,
                    genStrutRadiusMaxMM: r.generated?.strutRadiusMaxMM,
                    strutMarginInPlane: r.strut.flatMap {
                        $0.marginInPlane.isFinite ? $0.marginInPlane : nil },
                    strutMarginInterlayer: r.strut.flatMap {
                        $0.marginInterlayer.isFinite ? $0.marginInterlayer : nil },
                    strutZKnockdown: r.strut?.zKnockdown,
                    strutMinCellsPerMember: r.strut.flatMap {
                        $0.minCellsPerMember.isFinite ? $0.minCellsPerMember : nil },
                    strutOutOfRegime: r.strut?.outOfRegime) },
            solvedBy: o.solvedBy)
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
                    stressTensorField: unpackFloats(v.stressTensorField ?? Data()),
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
                                 voxelsFrozen: $0.voxelsFrozen, inGrid: $0.inGrid) },
            appliedFaceProtections: (d.appliedFaceProtections ?? []).map {
                AppliedFaceProtection(faceID: $0.faceID, voxelsFrozen: $0.voxelsFrozen,
                                      depthVoxels: $0.depthVoxels,
                                      thinnerThanDepth: $0.thinnerThanDepth) },
            // A duration exists only when the SOLVE time was recorded; a blob with
            // just a queue wait (impossible today, but decode defensively) is not a
            // duration and stays nil rather than reporting "solved 0s".
            timing: d.solveSeconds.map {
                RunTiming(queuedSeconds: d.queuedSeconds ?? 0, solveSeconds: $0) },
            latticeReport: d.latticeReport.map { r in
                LatticeReport(
                    topologyID: r.topologyID, cellMM: r.cellMM,
                    generateRelativeDensity: r.generateRelativeDensity,
                    minRelativeDensity: r.minRelativeDensity,
                    maxRelativeDensity: r.maxRelativeDensity,
                    regionScoped: r.regionScoped,
                    generated: r.genTriangles.map { tris in
                        LatticeReport.Generated(
                            emitSTL: r.genEmitSTL ?? true, emit3MF: r.genEmit3MF ?? false,
                            latticedCells: r.genLatticedCells ?? 0,
                            regionVoxels: r.genRegionVoxels ?? 0,
                            triangles: tris,
                            strutRadiusMinMM: r.genStrutRadiusMinMM ?? 0,
                            strutRadiusMaxMM: r.genStrutRadiusMaxMM ?? 0) },
                    // A strut report exists iff the z_knockdown echo was stored
                    // (it is always finite when the worker reported one); the
                    // margins themselves may be +inf and round-trip via nil.
                    strut: r.strutZKnockdown.map { zk in
                        LatticeReport.StrutStrength(
                            marginInPlane: r.strutMarginInPlane ?? .infinity,
                            marginInterlayer: r.strutMarginInterlayer ?? .infinity,
                            zKnockdown: zk,
                            minCellsPerMember: r.strutMinCellsPerMember ?? .infinity,
                            outOfRegime: r.strutOutOfRegime ?? false) }) },
            solvedBy: d.solvedBy)
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
