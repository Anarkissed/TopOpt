// TopOptKit — constrained smoothing with re-certification (handoff
// 2026-07-28-constrained-smooth-ui). The Swift surface the results screen calls to
// smooth the selected variant's mesh and RE-CERTIFY it under the run's declared
// load case, so the numbers shown beside the smoothed geometry always describe the
// smoothed part — never the pre-smoothing one (the honesty rule).
//
// This is the SMOOTH half of the feature; the receipt engine (analyze_fixed_design)
// and the load-case builder (build_production_loadcase) are shared with the optimizer
// and the CLI, so a re-certification is measured on exactly the physics the run used.
import Foundation
import TopOptBridge

extension TopOptKit {

    /// A region to hold BIT-IDENTICAL through smoothing (a keep-clear bore or a
    /// protected/mating face). The anchor and load faces of the run's load case are
    /// frozen automatically; these are the ADDITIONAL app-placed regions (PR 190's
    /// ManualClearanceGeometry) — pass the run's clearances/protections so bolt
    /// circles and mating faces stay put. All lengths mm, in the model/voxel frame.
    public struct FreezeRegionSpec: Equatable, Sendable {
        public enum Kind: Int, Equatable, Sendable { case bolt = 0; case face = 1 }
        public let kind: Kind
        // Bolt (swept cylinder): axis point + unit dir, bore radius, half axial extent.
        public let axisPoint: SIMD3<Double>
        public let axisDir: SIMD3<Double>
        public let radiusMM: Double
        public let halfLengthMM: Double
        // Face (bounded slab): a point on the plane + outward normal, half extents.
        public let origin: SIMD3<Double>
        public let normal: SIMD3<Double>
        public let halfUMM: Double
        public let halfWMM: Double

        public static func bolt(axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>,
                                radiusMM: Double, halfLengthMM: Double) -> FreezeRegionSpec {
            FreezeRegionSpec(kind: .bolt, axisPoint: axisPoint, axisDir: axisDir,
                             radiusMM: radiusMM, halfLengthMM: halfLengthMM,
                             origin: .zero, normal: .zero, halfUMM: 0, halfWMM: 0)
        }
        public static func face(origin: SIMD3<Double>, normal: SIMD3<Double>,
                                halfUMM: Double, halfWMM: Double) -> FreezeRegionSpec {
            FreezeRegionSpec(kind: .face, axisPoint: .zero, axisDir: .zero,
                             radiusMM: 0, halfLengthMM: 0, origin: origin,
                             normal: normal, halfUMM: halfUMM, halfWMM: halfWMM)
        }
        public init(kind: Kind, axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>,
                    radiusMM: Double, halfLengthMM: Double, origin: SIMD3<Double>,
                    normal: SIMD3<Double>, halfUMM: Double, halfWMM: Double) {
            self.kind = kind; self.axisPoint = axisPoint; self.axisDir = axisDir
            self.radiusMM = radiusMM; self.halfLengthMM = halfLengthMM
            self.origin = origin; self.normal = normal
            self.halfUMM = halfUMM; self.halfWMM = halfWMM
        }
    }

    /// The re-certification receipt of a smoothed part. EVERY number here describes
    /// the SMOOTHED geometry (the pre-smoothing numbers are never returned — the
    /// honesty rule). `nonConvergent` is the S7 boundary: the certification solve
    /// could not resolve the (sparse, re-voxelized) field, so no number is
    /// trustworthy and the UI must say "couldn't re-certify — try a lower strength",
    /// NOT show a fabricated margin. It is distinct from an honest `accepted == false`
    /// (the part genuinely got weaker and failed the gate).
    public struct SmoothRecertifyResult: Equatable, Sendable {
        public let smoothedMeshPath: String
        // Re-analysed certification (the NEW numbers).
        public let accepted: Bool
        public let nonConvergent: Bool
        public let marginWorstCase: Double
        public let marginEffective: Double
        public let marginRequired: Double
        public let maxStressMPa: Double
        public let maxInterlayerTensionMPa: Double
        public let voxelMassGrams: Double
        public let meshMassGrams: Double
        public let minFeatureViolations: Int
        public let spacingMM: Double   // for the ~½-voxel quantization footnote
        // The smoothing receipt.
        public let strength: Double
        public let pairsRequested: Int
        public let pairsApplied: Int
        public let frozenVertices: Int
        public let totalVertices: Int
        public let volumeBeforeMM3: Double
        public let volumeAfterMM3: Double
        public let volumeDriftFraction: Double
        public let volumeDriftBound: Double
        public let minFeatureLimited: Bool
    }

    /// Smooth `inputMeshPath` (the selected variant's exported mesh) at `strength`
    /// ∈ (0,1], then re-certify the result under the run's DECLARED load case, and
    /// return the smoothed part's own numbers. Writes the smoothed mesh to
    /// `smoothedOutPath` (what Export then exports). The anchor and load faces are
    /// frozen automatically; `freeze` adds keep-clear bores / mating faces. Throws
    /// `TopOptError` on a hard failure (bad material / model / unwritable output); a
    /// certification that cannot converge returns a result with `nonConvergent == true`
    /// (accepted forced false) rather than throwing, so the UI can offer "try lower".
    public static func smoothAndRecertifyLoadCase(
        modelPath: String, inputMeshPath: String, smoothedOutPath: String,
        material: String, materialsPath: String, rulesPath: String, resolution: Int,
        strength: Double, enforceMinFeature: Bool = true,
        anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double> = SIMD3(0, 0, 1), infillPercent: Int = -1,
        wallLoops: Int = 0, wallLineWidthInnerMM: Double = -1,
        wallLineWidthOuterMM: Double = -1, freeze: [FreezeRegionSpec] = []
    ) throws -> SmoothRecertifyResult {
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
        lc.wall_loops = Int32(wallLoops)
        lc.wall_line_width_mm = wallLineWidthInnerMM
        lc.wall_line_width_outer_mm = wallLineWidthOuterMM

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

        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.smooth_and_recertify_loadcase(
            std.string(modelPath), std.string(inputMeshPath),
            std.string(smoothedOutPath), std.string(material),
            std.string(materialsPath), std.string(rulesPath), Int32(resolution),
            strength, enforceMinFeature, lc, fr, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }

        return SmoothRecertifyResult(
            smoothedMeshPath: String(raw.smoothed_mesh_path),
            accepted: raw.accepted,
            nonConvergent: raw.non_convergent,
            marginWorstCase: raw.margin_worst_case,
            marginEffective: raw.margin_effective,
            marginRequired: raw.margin_required,
            maxStressMPa: raw.max_stress_mpa,
            maxInterlayerTensionMPa: raw.max_interlayer_tension_mpa,
            voxelMassGrams: raw.voxel_mass_grams,
            meshMassGrams: raw.mesh_mass_grams,
            minFeatureViolations: Int(raw.min_feature_violations),
            spacingMM: raw.spacing,
            strength: raw.smooth_strength,
            pairsRequested: Int(raw.smooth_pairs_requested),
            pairsApplied: Int(raw.smooth_pairs_applied),
            frozenVertices: Int(raw.frozen_vertices),
            totalVertices: Int(raw.total_vertices),
            volumeBeforeMM3: raw.volume_before_mm3,
            volumeAfterMM3: raw.volume_after_mm3,
            volumeDriftFraction: raw.volume_drift_fraction,
            volumeDriftBound: raw.volume_drift_bound,
            minFeatureLimited: raw.min_feature_limited)
    }
}
