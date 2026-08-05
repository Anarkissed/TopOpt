// SmoothBrushKit.swift — the Swift surface the smoothing page calls (handoff
// 2026-08-02-smoothing-page).
//
// Three seams, all over the SAME core:
//
//   * `smoothFreezeMask`      — WHAT MAY NOT BE TOUCHED, answered by core's own
//     `compute_freeze_mask` on the resolved clearance predicates. The page asks
//     BEFORE the user paints, so the brush can refuse a frozen vertex at the
//     geometry level instead of moving it and putting it back.
//   * `certifyMeshLoadCase`   — ONE `analyze_fixed_design` certification of a
//     given mesh under a declared load case. This is what fills the BEFORE column
//     (bar AE2): the unsmoothed variant is MEASURED, never remembered.
//   * `smoothBrushAndRecertifyLoadCase` — smooth under per-vertex weights, then
//     certify the result through the SAME `certifyMeshLoadCase` path, so the two
//     columns of the receipt are produced by one engine.
//
// The load case these run under comes from the variant's RETAINED JOB DOCUMENT
// (see `SmoothRecertLoadCase`), never from the project's current editable state.
// PR 261's lesson: a selector resolved against the wrong geometry does not fail
// loudly, it silently tags nothing.

import Foundation
import simd
import TopOptBridge

extension TopOptKit {

    /// One certification reading over one mesh — the raw numbers, plus the two
    /// volume fractions hazard H3 requires (the certified object is the mesh's
    /// RE-VOXELIZATION, not the mesh).
    public struct MeshCertification: Equatable, Sendable {
        public let accepted: Bool
        public let nonConvergent: Bool
        public let marginWorstCase: Double
        public let marginInPlane: Double
        public let marginInterlayer: Double
        public let marginEffective: Double
        public let marginRequired: Double
        public let maxStressMPa: Double
        public let minFeatureViolations: Int
        public let voxelMassGrams: Double
        public let meshMassGrams: Double
        public let spacingMM: Double
        public let meshVolumeFraction: Double
        public let voxelVolumeFraction: Double
        public let meshPath: String

        public init(accepted: Bool, nonConvergent: Bool, marginWorstCase: Double,
                    marginInPlane: Double, marginInterlayer: Double,
                    marginEffective: Double, marginRequired: Double,
                    maxStressMPa: Double, minFeatureViolations: Int,
                    voxelMassGrams: Double, meshMassGrams: Double,
                    spacingMM: Double, meshVolumeFraction: Double,
                    voxelVolumeFraction: Double, meshPath: String) {
            self.accepted = accepted
            self.nonConvergent = nonConvergent
            self.marginWorstCase = marginWorstCase
            self.marginInPlane = marginInPlane
            self.marginInterlayer = marginInterlayer
            self.marginEffective = marginEffective
            self.marginRequired = marginRequired
            self.maxStressMPa = maxStressMPa
            self.minFeatureViolations = minFeatureViolations
            self.voxelMassGrams = voxelMassGrams
            self.meshMassGrams = meshMassGrams
            self.spacingMM = spacingMM
            self.meshVolumeFraction = meshVolumeFraction
            self.voxelVolumeFraction = voxelVolumeFraction
            self.meshPath = meshPath
        }
    }

    /// The smoothing half of a brushed re-certification: what the constrained
    /// smoother actually did, including the brush populations.
    public struct BrushSmoothStats: Equatable, Sendable {
        public let pairsRequested: Int
        public let pairsApplied: Int
        public let totalVertices: Int
        public let frozenVertices: Int
        public let brushedVertices: Int
        public let unbrushedVertices: Int
        public let maxVertexWeight: Double
        public let volumeDriftFraction: Double
        public let volumeDriftBound: Double
        public let minFeatureLimited: Bool
        public let smoothedMeshPath: String
    }

    /// A brushed re-certification: the smoothed geometry's own numbers plus the
    /// smoothing receipt.
    public struct BrushRecertifyResult: Equatable, Sendable {
        public let certification: MeshCertification
        public let smoothing: BrushSmoothStats
    }

    /// The per-vertex freeze mask core will apply to `meshPath` — one entry per
    /// mesh vertex — plus the tolerance it used.
    public struct FreezeMaskResult: Equatable, Sendable {
        public let frozen: [Bool]
        public let toleranceMM: Double
        public var frozenCount: Int { frozen.reduce(0) { $0 + ($1 ? 1 : 0) } }
    }

    // MARK: - the bridge load case, built once

    private static func bridgeLoadCase(
        anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double>, infillPercent: Int
    ) -> topoptbridge.BridgeLoadCase {
        var lc = topoptbridge.BridgeLoadCase()
        for f in anchorFaceIDs { lc.anchor_face_ids.push_back(Int32(f)) }
        for g in loadGroups {
            for f in g.faceIDs { lc.load_face_ids.push_back(Int32(f)) }
            lc.load_group_sizes.push_back(Int32(g.faceIDs.count))
            lc.load_forces.push_back(g.force.x)
            lc.load_forces.push_back(g.force.y)
            lc.load_forces.push_back(g.force.z)
        }
        lc.minimize_plastic = false  // a fixed design, not a ladder
        lc.build_dir_x = buildDirection.x
        lc.build_dir_y = buildDirection.y
        lc.build_dir_z = buildDirection.z
        lc.infill_percent = Int32(infillPercent)
        return lc
    }

    private static func bridgeFreeze(_ freeze: [FreezeRegionSpec])
        -> topoptbridge.BridgeFreezeRegions {
        var fr = topoptbridge.BridgeFreezeRegions()
        for r in freeze {
            fr.kind.push_back(Int32(r.kind.rawValue))
            for v in [r.axisPoint.x, r.axisPoint.y, r.axisPoint.z] { fr.axis_point.push_back(v) }
            for v in [r.axisDir.x, r.axisDir.y, r.axisDir.z] { fr.axis_dir.push_back(v) }
            fr.radius_mm.push_back(r.radiusMM)
            fr.half_length_mm.push_back(r.halfLengthMM)
            for v in [r.origin.x, r.origin.y, r.origin.z] { fr.origin.push_back(v) }
            for v in [r.normal.x, r.normal.y, r.normal.z] { fr.normal.push_back(v) }
            fr.half_u_mm.push_back(r.halfUMM)
            fr.half_w_mm.push_back(r.halfWMM)
        }
        return fr
    }

    private static func certification(_ raw: topoptbridge.AnalyzeResult,
                                      meshPath: String) -> MeshCertification {
        // In-plane and interlayer margins are recovered from the two stresses the
        // certification reports against the material's own allowables, exactly as
        // the gate compares them — no second derivation of the margin law here.
        MeshCertification(
            accepted: raw.accepted,
            nonConvergent: raw.non_convergent,
            marginWorstCase: raw.margin_worst_case,
            marginInPlane: raw.margin_in_plane,
            marginInterlayer: raw.margin_interlayer,
            marginEffective: raw.margin_effective,
            marginRequired: raw.margin_required,
            maxStressMPa: raw.max_stress_mpa,
            minFeatureViolations: Int(raw.min_feature_violations),
            voxelMassGrams: raw.voxel_mass_grams,
            meshMassGrams: raw.mesh_mass_grams,
            spacingMM: raw.spacing,
            meshVolumeFraction: raw.mesh_volume_fraction,
            voxelVolumeFraction: raw.voxel_volume_fraction,
            meshPath: meshPath)
    }

    // MARK: - the three seams

    /// Which vertices of `meshPath` the smoother will hold bit-identical, for the
    /// load case's anchors + load faces plus every supplied bore/pad primitive.
    /// Blocking; callers wrap it in a detached task.
    public static func smoothFreezeMask(
        modelPath: String, meshPath: String, resolution: Int,
        anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
        infillPercent: Int = -1, freeze: [FreezeRegionSpec] = []
    ) throws -> FreezeMaskResult {
        let lc = bridgeLoadCase(anchorFaceIDs: anchorFaceIDs, loadGroups: loadGroups,
                                buildDirection: buildDirection,
                                infillPercent: infillPercent)
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.smooth_freeze_mask(
            std.string(modelPath), std.string(meshPath), Int32(resolution), lc,
            bridgeFreeze(freeze), &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        return FreezeMaskResult(frozen: raw.frozen.map { $0 != 0 },
                                toleranceMM: raw.freeze_tol_mm)
    }

    /// Certify `meshPath` AS IT IS under the declared load case — no smoothing.
    /// This fills the receipt's BEFORE column (bar AE2). A non-convergent solve
    /// returns `nonConvergent == true` rather than throwing, so the page can
    /// report the H1 state instead of crashing.
    public static func certifyMeshLoadCase(
        modelPath: String, meshPath: String, material: String,
        materialsPath: String, rulesPath: String, resolution: Int,
        anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double> = SIMD3(0, 0, 1), infillPercent: Int = -1
    ) throws -> MeshCertification {
        let lc = bridgeLoadCase(anchorFaceIDs: anchorFaceIDs, loadGroups: loadGroups,
                                buildDirection: buildDirection,
                                infillPercent: infillPercent)
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.analyze_loadcase(
            std.string(modelPath), std.string(meshPath), std.string(material),
            std.string(materialsPath), std.string(rulesPath), Int32(resolution),
            lc, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        return certification(raw, meshPath: meshPath)
    }

    /// THE LIVE BRUSH PREVIEW (task 2026-08-04-variant-volume-fraction-mismatch,
    /// failure C): the deformation the brush ASKS FOR, with no certification.
    ///
    /// The page's Original/Smoothed toggle was inert until a re-certification had
    /// run — it offered a comparison it could not make, and the maintainer read
    /// the resulting "no difference" as a broken brush. This is the same
    /// smoother, cheap enough to run on every settled stroke.
    ///
    /// `frozen` is the mask `smoothFreezeMask` already returned; those vertices go
    /// in at weight 0, which the smoother copies VERBATIM on the identical code
    /// path it uses for a frozen vertex. It does NOT enforce the min-feature
    /// constraint, so the certified pass may smooth LESS — the page says so.
    public struct BrushPreview: Equatable, Sendable {
        public let meshVertices: [Float]
        public let meshIndices: [Int32]
        public let totalVertices: Int
        public let movedVertices: Int
        public let maxDisplacementMM: Double
        public let seconds: Double
    }

    public static func smoothBrushPreview(inputMeshPath: String,
                                          strength: Double,
                                          weights: [Double],
                                          frozen: [Bool] = []) throws -> BrushPreview {
        var brush = topoptbridge.BridgeVertexWeights()
        for (i, w) in weights.enumerated() {
            brush.weight.push_back(i < frozen.count && frozen[i] ? 0 : w)
        }
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.smooth_brush_preview(
            std.string(inputMeshPath), strength, brush, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }
        return BrushPreview(
            meshVertices: Array(raw.vertices), meshIndices: Array(raw.indices),
            totalVertices: Int(raw.total_vertices),
            movedVertices: Int(raw.moved_vertices),
            maxDisplacementMM: raw.max_displacement_mm,
            seconds: raw.seconds)
    }

    /// Smooth `inputMeshPath` with PER-VERTEX weights, write the result to
    /// `smoothedOutPath`, and certify THAT — the receipt's AFTER column.
    ///
    /// `weights` is one entry per mesh vertex in [0,1]; each vertex melts by
    /// `strength * weights[v]`. Empty ⇒ the uniform PR 200 behaviour, byte for
    /// byte. A frozen vertex is bit-identical whatever its weight says.
    public static func smoothBrushAndRecertifyLoadCase(
        modelPath: String, inputMeshPath: String, smoothedOutPath: String,
        material: String, materialsPath: String, rulesPath: String,
        resolution: Int, strength: Double, weights: [Double],
        enforceMinFeature: Bool = true, anchorFaceIDs: [Int],
        loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double> = SIMD3(0, 0, 1), infillPercent: Int = -1,
        freeze: [FreezeRegionSpec] = []
    ) throws -> BrushRecertifyResult {
        let lc = bridgeLoadCase(anchorFaceIDs: anchorFaceIDs, loadGroups: loadGroups,
                                buildDirection: buildDirection,
                                infillPercent: infillPercent)
        var brush = topoptbridge.BridgeVertexWeights()
        for w in weights { brush.weight.push_back(w) }

        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.smooth_brush_and_recertify_loadcase(
            std.string(modelPath), std.string(inputMeshPath),
            std.string(smoothedOutPath), std.string(material),
            std.string(materialsPath), std.string(rulesPath), Int32(resolution),
            strength, enforceMinFeature, lc, bridgeFreeze(freeze), brush, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }

        return BrushRecertifyResult(
            certification: certification(raw, meshPath: String(raw.smoothed_mesh_path)),
            smoothing: BrushSmoothStats(
                pairsRequested: Int(raw.smooth_pairs_requested),
                pairsApplied: Int(raw.smooth_pairs_applied),
                totalVertices: Int(raw.total_vertices),
                frozenVertices: Int(raw.frozen_vertices),
                brushedVertices: Int(raw.brushed_vertices),
                unbrushedVertices: Int(raw.unbrushed_vertices),
                maxVertexWeight: raw.max_vertex_weight,
                volumeDriftFraction: raw.volume_drift_fraction,
                volumeDriftBound: raw.volume_drift_bound,
                minFeatureLimited: raw.min_feature_limited,
                smoothedMeshPath: String(raw.smoothed_mesh_path)))
    }
}
