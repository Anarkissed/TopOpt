// LoadcaseAnalyze.swift — the Swift wrapper over the bridge's analyze_loadcase
// seam (declared for the constrained-smooth work, Swift caller deferred until
// now). The lattice page's RUN SIM calls this: ONE linear FEA solve of the SOLID
// part under the user's DECLARED anchors + loads (the same
// build_production_loadcase the optimizer and the CLI use), returning the
// per-voxel von Mises field the auto-density preview grades from.
//
// This is deliberately the ON-DEVICE path: the LAN worker only routes `run`
// (minimize_plastic) jobs, so a worker-dispatched analyze does not exist yet —
// the gap is reported in handoff 2026-07-30-lattice-page.

import Foundation
import simd
import TopOptBridge

extension TopOptKit {

    /// One solid-part load-case analysis: the field + the headline numbers the
    /// sim banner shows. `nonConvergent == true` means the solve never finished
    /// and every number is meaningless (the banner must say so, never show a
    /// fabricated field) — the same honesty boundary the re-certify path draws.
    public struct SimAnalysisResult: Equatable, Sendable {
        public let accepted: Bool
        public let nonConvergent: Bool
        public let maxStressMPa: Double
        public let marginWorstCase: Double
        public let marginRequired: Double
        /// Max displacement magnitude (mm), derived from the DOF-ordered field.
        public let maxDisplacementMM: Double
        // The per-voxel von Mises field (MPa, 0 off the solid set) + its grid,
        // the exact metadata the SDF preview's demand field needs.
        public let vonMisesField: [Float]
        public let gridNX: Int, gridNY: Int, gridNZ: Int
        public let gridOrigin: SIMD3<Double>
        public let spacingMM: Double

        public init(accepted: Bool, nonConvergent: Bool, maxStressMPa: Double,
                    marginWorstCase: Double, marginRequired: Double,
                    maxDisplacementMM: Double, vonMisesField: [Float],
                    gridNX: Int, gridNY: Int, gridNZ: Int,
                    gridOrigin: SIMD3<Double>, spacingMM: Double) {
            self.accepted = accepted
            self.nonConvergent = nonConvergent
            self.maxStressMPa = maxStressMPa
            self.marginWorstCase = marginWorstCase
            self.marginRequired = marginRequired
            self.maxDisplacementMM = maxDisplacementMM
            self.vonMisesField = vonMisesField
            self.gridNX = gridNX
            self.gridNY = gridNY
            self.gridNZ = gridNZ
            self.gridOrigin = gridOrigin
            self.spacingMM = spacingMM
        }
    }

    /// Analyze the SOLID part (no mesh — the model's own voxelization) under the
    /// declared load case at `resolution`. Blocking; callers wrap it in a
    /// detached task (the SmoothingModel.live pattern). Throws on a hard failure;
    /// a non-convergent solve returns `nonConvergent == true` rather than throwing.
    public static func analyzeSolidLoadCase(
        modelPath: String, material: String, materialsPath: String,
        rulesPath: String, resolution: Int,
        anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        buildDirection: SIMD3<Double> = SIMD3(0, 0, 1)
    ) throws -> SimAnalysisResult {
        var lc = topoptbridge.BridgeLoadCase()
        for f in anchorFaceIDs { lc.anchor_face_ids.push_back(Int32(f)) }
        for g in loadGroups {
            for f in g.faceIDs { lc.load_face_ids.push_back(Int32(f)) }
            lc.load_group_sizes.push_back(Int32(g.faceIDs.count))
            lc.load_forces.push_back(g.force.x)
            lc.load_forces.push_back(g.force.y)
            lc.load_forces.push_back(g.force.z)
        }
        lc.minimize_plastic = false  // one analysis solve, not a ladder
        lc.build_dir_x = buildDirection.x
        lc.build_dir_y = buildDirection.y
        lc.build_dir_z = buildDirection.z

        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.analyze_loadcase(
            std.string(modelPath), std.string(""), std.string(material),
            std.string(materialsPath), std.string(rulesPath), Int32(resolution),
            lc, &err)
        if !err.ok { throw TopOptError(message: String(err.message)) }

        // Max displacement magnitude from the DOF-ordered (3*node) field.
        var maxDisp = 0.0
        let d = raw.displacement_field
        var i = 0
        while i + 2 < d.count {
            let m = Double(d[i]) * Double(d[i]) + Double(d[i + 1]) * Double(d[i + 1])
                  + Double(d[i + 2]) * Double(d[i + 2])
            if m > maxDisp { maxDisp = m }
            i += 3
        }

        return SimAnalysisResult(
            accepted: raw.accepted,
            nonConvergent: raw.non_convergent,
            maxStressMPa: raw.max_stress_mpa,
            marginWorstCase: raw.margin_worst_case,
            marginRequired: raw.margin_required,
            maxDisplacementMM: maxDisp.squareRoot(),
            vonMisesField: Array(raw.von_mises_field),
            gridNX: Int(raw.grid_nx), gridNY: Int(raw.grid_ny), gridNZ: Int(raw.grid_nz),
            gridOrigin: SIMD3(raw.grid_origin_x, raw.grid_origin_y, raw.grid_origin_z),
            spacingMM: raw.spacing)
    }
}
