// TopOptKit — the idiomatic Swift wrapper over the C++ TopOptBridge facade
// (ROADMAP M7.1). It converts the bridge's std::string/std::vector/POD results
// into Swift value types and closures, and turns BridgeError into thrown Swift
// errors. This is the surface the iPad app (M7.3+) and the headless macOS tests
// call; the app itself stays a thin SwiftUI shell over this.
import Foundation
import TopOptBridge

/// An error surfaced from the core through the bridge. `message` is the core
/// diagnostic (MaterialError / StlError / StepError / std::exception what()),
/// suitable for a user-facing toast (ROADMAP M7.3).
public struct TopOptError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

/// A material record from materials.json (ARCHITECTURE §6).
public struct Material: Equatable, Sendable {
    public let name: String
    public let youngsModulusMPa: Double
    public let yieldStrengthMPa: Double
    public let densityGCm3: Double
    public let zKnockdown: Double
    public let poisson: Double
    public let family: String
}

/// The EXACT B-rep surface geometry of one STEP face (keep-clear v2), the same
/// `topopt::StepFaceInfo` numbers the core clearance rasterizer freezes. The app
/// renders clearance volumes and derives "Auto · N mm" labels from THIS — never
/// an app-side tessellation fit, which would draw a different object than the run
/// actually keeps clear. All lengths mm, in the model/voxel frame.
public struct StepFaceGeometry: Equatable, Sendable, Codable {
    /// The face's surface class (mirrors `topopt::StepSurfaceKind`).
    public enum Kind: Int, Equatable, Sendable, Codable {
        case plane = 0
        case cylinder = 1
        case other = 2
    }
    public let kind: Kind
    /// Cylinder radius (mm); meaningful iff `kind == .cylinder`.
    public let cylinderRadiusMM: Double
    /// A point on the cylinder axis, and the UNIT axis direction (both zero unless
    /// `kind == .cylinder`). A swept-cylinder bolt clearance runs along this axis.
    public let axisPoint: SIMD3<Double>
    public let axisDir: SIMD3<Double>
    /// The OUTWARD unit plane normal and a point on the plane (both zero unless
    /// `kind == .plane`). A bounded-slab face clearance extrudes along the normal.
    public let planeNormal: SIMD3<Double>
    public let planeOrigin: SIMD3<Double>
    public init(kind: Kind, cylinderRadiusMM: Double = 0,
                axisPoint: SIMD3<Double> = .zero, axisDir: SIMD3<Double> = .zero,
                planeNormal: SIMD3<Double> = .zero, planeOrigin: SIMD3<Double> = .zero) {
        self.kind = kind
        self.cylinderRadiusMM = cylinderRadiusMM
        self.axisPoint = axisPoint
        self.axisDir = axisDir
        self.planeNormal = planeNormal
        self.planeOrigin = planeOrigin
    }
    /// A bore face the app can build a swept-cylinder clearance from.
    public var isCylinder: Bool { kind == .cylinder && cylinderRadiusMM > 0 }
    /// A planar face the app can build a bounded slab from.
    public var isPlane: Bool { kind == .plane }
}

/// An imported triangle mesh, laid out for a Metal vertex/index buffer
/// (ROADMAP M7.4). `vertices` is flattened xyz; `indices` is flattened triangle
/// corners; `faceIDs` is the per-triangle B-rep face id for STEP (empty for STL).
public struct ImportedMesh {
    public let vertices: [Float]
    public let indices: [Int32]
    public let faceIDs: [Int32]
    public let vertexCount: Int
    public let triangleCount: Int
    public let faceCount: Int
    public let watertight: Bool
    /// Per-B-rep-face exact surface geometry, indexed by face id (size
    /// `faceCount`; empty for STL). Keep-clear v2: lets the app draw clearance
    /// volumes from the same axis/radius/normal the core uses.
    public let faceGeometry: [StepFaceGeometry]
    /// Handoff 134: true when the faces were MANUFACTURED by the core's dihedral
    /// segmenter from a mesh (STL/3MF) rather than read from a B-rep. Display
    /// only — no behaviour branches on it, because a pseudo-face and a B-rep
    /// face are the same contract everywhere downstream.
    public let pseudoFaces: Bool
    public init(vertices: [Float], indices: [Int32], faceIDs: [Int32],
                vertexCount: Int, triangleCount: Int, faceCount: Int,
                watertight: Bool, faceGeometry: [StepFaceGeometry] = [],
                pseudoFaces: Bool = false) {
        self.vertices = vertices
        self.indices = indices
        self.faceIDs = faceIDs
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.faceCount = faceCount
        self.watertight = watertight
        self.faceGeometry = faceGeometry
        self.pseudoFaces = pseudoFaces
    }
}

/// Why a mesh import was refused, and what the importer repaired on the way
/// (handoff 134). The app renders this as a plain-language sheet — a refusal is
/// never a crash and never a silent half-import.
public struct PartDiagnostics: Equatable, Sendable {

    /// A structural problem that makes a mesh unusable that the importer could
    /// not safely repair. Small holes ARE capped and duplicate facets ARE
    /// removed (Phase 2); what remains here is a defect with no single safe fix —
    /// self-intersection resolution and shell thickening are still not attempted.
    public enum Defect: Int, Equatable, Sendable, CaseIterable {
        case emptyMesh = 0
        case nonManifoldEdges = 1
        case openBoundary = 2
        case nonOrientable = 3
        case zeroThickness = 4
    }

    /// False for a STEP part: the B-rep path is not mesh-inspected.
    public let checked: Bool
    public let acceptable: Bool
    public let defects: [Defect]
    /// The core's own one-line description per defect, parallel to `defects`.
    public let defectText: [String]

    public let boundaryEdges: Int
    public let nonManifoldEdges: Int
    public let degenerateTriangles: Int
    /// Repairs applied automatically (reported, not hidden). The Phase-2 repairs
    /// (duplicate-facet removal and small-hole capping) change the user's
    /// geometry just as much as a weld, so they are carried through here too —
    /// a mesh accepted only because a hole was filled must still say so.
    public let weldedVertices: Int
    public let flippedTriangles: Int
    public let removedDuplicateTriangles: Int
    public let filledHoles: Int
    public let filledHoleTriangles: Int

    /// Measured in FILE units — an STL carries no unit, so the size hint on the
    /// unit prompt is built from this.
    public let volume: Double
    public let bboxMin: SIMD3<Double>
    public let bboxMax: SIMD3<Double>

    public init(checked: Bool, acceptable: Bool, defects: [Defect],
                defectText: [String], boundaryEdges: Int, nonManifoldEdges: Int,
                degenerateTriangles: Int, weldedVertices: Int,
                flippedTriangles: Int, removedDuplicateTriangles: Int = 0,
                filledHoles: Int = 0, filledHoleTriangles: Int = 0,
                volume: Double,
                bboxMin: SIMD3<Double>, bboxMax: SIMD3<Double>) {
        self.checked = checked
        self.acceptable = acceptable
        self.defects = defects
        self.defectText = defectText
        self.boundaryEdges = boundaryEdges
        self.nonManifoldEdges = nonManifoldEdges
        self.degenerateTriangles = degenerateTriangles
        self.weldedVertices = weldedVertices
        self.flippedTriangles = flippedTriangles
        self.removedDuplicateTriangles = removedDuplicateTriangles
        self.filledHoles = filledHoles
        self.filledHoleTriangles = filledHoleTriangles
        self.volume = volume
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
    }

    /// Longest bounding-box edge in file units — the number the unit prompt's
    /// sanity hint is phrased around.
    public var largestDimension: Double {
        max(bboxMax.x - bboxMin.x, max(bboxMax.y - bboxMin.y, bboxMax.z - bboxMin.z))
    }

    /// True iff the importer changed the geometry to make it usable. Includes
    /// the Phase-2 repairs: a mesh imported only because a duplicate facet was
    /// dropped or a small hole was capped was still changed, and saying so is
    /// the whole point of the repair note.
    public var didRepair: Bool {
        weldedVertices > 0 || flippedTriangles > 0 || degenerateTriangles > 0
            || removedDuplicateTriangles > 0 || filledHoles > 0
    }
}

/// A voxel-grid summary (ROADMAP M1.5).
public struct VoxelSummary {
    public let nx: Int
    public let ny: Int
    public let nz: Int
    public let spacing: Double
    public let solidVoxels: Int
}

/// One isosurface frame of a variant's optimization history (playback): flattened
/// xyz vertices + triangle-corner indices (local to the frame).
public struct KeyframeMesh: Equatable, Sendable {
    public let vertices: [Float]
    public let indices: [Int32]
    public init(vertices: [Float], indices: [Int32]) {
        self.vertices = vertices
        self.indices = indices
    }
}


/// The core's STRUCTURED explanation of one variant's gate verdict — report.json's
/// `"diagnosis"` object (handoff 2026-08-02-gate-diagnosis-recommendations).
///
/// *** IT EXPLAINS A VERDICT; IT NEVER CARRIES ONE. *** `OptimizeVariant.accepted`
/// and `worstCaseMargin` are the gate's, and this was written from them.
///
/// WHY IT EXISTS. A real run (fingerprint 9f6738726016, WallMount bracket) told the
/// user "the strongest variant's worst-case stress margin was 0.00× — try a stronger
/// material, a coarser resolution, or a lighter load." The 0.00 was a max over an
/// EMPTY array; the part's own worst case was 2.78× — nearly 2× the 1.5 requirement —
/// and what rejected it was the f^1.5 infill knockdown at 35% infill (2.78 × 0.35^1.5
/// = 0.58). The material was fine and the resolution was irrelevant.
public struct GateDiagnosis: Equatable, Sendable {
    /// Which term BINDS. Exactly one, decided by the core from the gate's own
    /// arithmetic. `.knockdown` is the motivating case: the part clears the
    /// requirement and the sparse-infill knockdown takes it under.
    public enum Term: String, Sendable {
        case none, loadPath = "load_path", inPlane = "in_plane"
        case interlayer, knockdown, minFeature = "min_feature"
    }

    /// One change the core PRICED THROUGH THE REAL GATE and confirmed passes.
    /// A candidate that did not pass was dropped, never emitted — so anything
    /// here is a measurement, not a suggestion.
    public struct Recommendation: Equatable, Sendable {
        public let lever: String          // "infill", "material", "build_orientation", ...
        public let parameter: String      // "infill_percent"
        public let currentValue: Double
        public let proposedValue: Double
        public let proposedLabel: String  // "67%", "PA12", "(0.000, 0.000, 1.000)"
        /// The gate's OWN number under this proposal, against the SAME requirement
        /// the verdict used. `marginAtProposal >= marginRequired` on every emitted row.
        public let marginAtProposal: Double
        public let marginRequired: Double
        /// True on every gate-priced row. The one lever that sets it false is
        /// `resolution`, whose quantity is the §7 V3 min-feature count rather than
        /// the stress margin; it states its own criterion in `note`.
        public let verifiedThroughGate: Bool
        /// This number divides by the material's z_knockdown, which is a seeded,
        /// human-tuned constant with no measured source. When true, `provenance`
        /// must be shown WITH the number.
        public let inheritsUnsourcedZKnockdown: Bool
        public let provenance: String
        public let note: String

        public init(lever: String, parameter: String, currentValue: Double,
                    proposedValue: Double, proposedLabel: String,
                    marginAtProposal: Double, marginRequired: Double,
                    verifiedThroughGate: Bool,
                    inheritsUnsourcedZKnockdown: Bool, provenance: String,
                    note: String) {
            self.lever = lever
            self.parameter = parameter
            self.currentValue = currentValue
            self.proposedValue = proposedValue
            self.proposedLabel = proposedLabel
            self.marginAtProposal = marginAtProposal
            self.marginRequired = marginRequired
            self.verifiedThroughGate = verifiedThroughGate
            self.inheritsUnsourcedZKnockdown = inheritsUnsourcedZKnockdown
            self.provenance = provenance
            self.note = note
        }
    }

    public let binding: Term
    public let bindingValue: Double
    public let requiredValue: Double
    public let ratio: Double
    /// The part's OWN worst-case margin, before the sparse-infill knockdown.
    public let marginWorstCaseRaw: Double
    public let marginInPlaneRaw: Double
    public let marginInterlayerRaw: Double
    /// What the gate actually compared. Differs from `marginWorstCaseRaw` by the
    /// knockdown — 4.8× on the motivating run — and only one of them explains a
    /// refusal, which is why both are always carried.
    public let marginEffective: Double
    public let knockdownFactor: Double
    public let infillPercent: Double
    public let minFeatureViolations: Int
    public let inheritsUnsourcedZKnockdown: Bool
    public let provenance: String
    /// No admissible print setting clears the gate. `noFixReason` then names the
    /// BINDING PHYSICAL QUANTITY instead of listing things to try.
    public let noSettingFixesThis: Bool
    public let noFixReason: String
    /// On an ACCEPTED part: the lowest infill that still passes ("passes at 35%;
    /// would still pass at 22%"). nil when it was not computed.
    public let headroomMinInfillPercent: Double?
    public let recommendations: [Recommendation]

    public init(binding: Term, bindingValue: Double, requiredValue: Double,
                ratio: Double, marginWorstCaseRaw: Double, marginInPlaneRaw: Double,
                marginInterlayerRaw: Double, marginEffective: Double,
                knockdownFactor: Double, infillPercent: Double,
                minFeatureViolations: Int, inheritsUnsourcedZKnockdown: Bool,
                provenance: String, noSettingFixesThis: Bool, noFixReason: String,
                headroomMinInfillPercent: Double?,
                recommendations: [Recommendation]) {
        self.binding = binding
        self.bindingValue = bindingValue
        self.requiredValue = requiredValue
        self.ratio = ratio
        self.marginWorstCaseRaw = marginWorstCaseRaw
        self.marginInPlaneRaw = marginInPlaneRaw
        self.marginInterlayerRaw = marginInterlayerRaw
        self.marginEffective = marginEffective
        self.knockdownFactor = knockdownFactor
        self.infillPercent = infillPercent
        self.minFeatureViolations = minFeatureViolations
        self.inheritsUnsourcedZKnockdown = inheritsUnsourcedZKnockdown
        self.provenance = provenance
        self.noSettingFixesThis = noSettingFixesThis
        self.noFixReason = noFixReason
        self.headroomMinInfillPercent = headroomMinInfillPercent
        self.recommendations = recommendations
    }

    /// THE ONE decoder, for both sources: a LAN run's report.json variant object and
    /// the on-device bridge's per-variant `diagnosis_json`. Both are the core's own
    /// emitter output, so one shape and one reader.
    public static func decode(_ o: [String: Any]) -> GateDiagnosis? {
        guard let term = o["binding_term"] as? String,
              let binding = Term(rawValue: term) else { return nil }
        func num(_ k: String) -> Double { (o[k] as? Double) ?? 0 }
        let recs: [Recommendation] = (o["recommendations"] as? [[String: Any]] ?? [])
            .map { r in
                Recommendation(
                    lever: r["lever"] as? String ?? "",
                    parameter: r["parameter"] as? String ?? "",
                    currentValue: r["current_value"] as? Double ?? 0,
                    proposedValue: r["proposed_value"] as? Double ?? 0,
                    proposedLabel: r["proposed_label"] as? String ?? "",
                    marginAtProposal: r["margin_effective_at_proposal"] as? Double ?? 0,
                    marginRequired: r["margin_required"] as? Double ?? 0,
                    verifiedThroughGate: r["verified_through_gate"] as? Bool ?? false,
                    inheritsUnsourcedZKnockdown:
                        r["inherits_unsourced_z_knockdown"] as? Bool ?? false,
                    provenance: r["provenance"] as? String ?? "",
                    note: r["note"] as? String ?? "")
            }
        return GateDiagnosis(
            binding: binding,
            bindingValue: num("binding_value"),
            requiredValue: num("required_value"),
            ratio: num("ratio"),
            marginWorstCaseRaw: num("margin_worst_case_raw"),
            marginInPlaneRaw: num("margin_in_plane_raw"),
            marginInterlayerRaw: num("margin_interlayer_raw"),
            marginEffective: num("margin_effective"),
            knockdownFactor: num("knockdown_factor"),
            infillPercent: num("infill_percent"),
            minFeatureViolations: o["min_feature_violations"] as? Int ?? 0,
            inheritsUnsourcedZKnockdown:
                o["inherits_unsourced_z_knockdown"] as? Bool ?? false,
            provenance: o["provenance"] as? String ?? "",
            noSettingFixesThis: o["no_setting_fixes_this"] as? Bool ?? false,
            noFixReason: o["no_fix_reason"] as? String ?? "",
            headroomMinInfillPercent: o["headroom_min_infill_percent"] as? Double,
            recommendations: recs)
    }

    /// Decode from the bridge's raw JSON string (empty / malformed -> nil).
    public static func decode(json: String) -> GateDiagnosis? {
        guard !json.isEmpty, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return decode(dict)
    }
}

/// WHERE ONE VARIANT'S PLASTIC IS, relative to the ORIGINAL imported part
/// (task 2026-08-03-growth-ladder) — the core's `AddedMaterialReport`, verbatim.
///
/// On a GROWTH run ("minimize plastic" unticked) this is the HEADLINE, not a
/// footnote: the user unticked the box to say "you may add plastic to reach the
/// strength I asked for", and the answer to that is how much was added and where.
/// `nil` on every REDUCTION run — nothing measured it, and a zeroed struct would
/// read as "nothing was added" rather than "this was never asked".
public struct AddedMaterial: Equatable, Sendable {
    /// Printed voxels of this variant, and the split by whether each lies inside
    /// the original part envelope or outside it. `insidePart + outsidePart ==
    /// printedVoxels`, always.
    public let printedVoxels: Int
    public let insidePart: Int
    public let outsidePart: Int
    /// The original part's own solid voxel count — the denominator every fraction
    /// here is taken against, carried so nothing has to reconstruct it.
    public let partSolidVoxels: Int
    /// `outsidePart / printedVoxels` — "what share of the object I am about to
    /// print is material that was not in my model".
    public let outsideFraction: Double
    /// Volumes on the voxel basis (mm³) and the NET change against the part
    /// (printed − part, so NEGATIVE if this variant prints LESS than the part —
    /// which is what a growth rung that could not reach its target looks like, and
    /// it must be visible rather than hidden).
    public let outsideVolumeMM3: Double
    public let netAddedVolumeMM3: Double
    /// The same two on the mass basis (grams), sharing the printed voxel count the
    /// reported mass uses, so "added" and "printed" can never disagree.
    public let outsideMassGrams: Double
    public let netAddedMassGrams: Double
    /// The rung asked for more material than the design box could hold, so it ran
    /// at "fill the box" rather than at the fraction its line requests. Not a
    /// strength verdict — but the achieved fraction must not be read as though the
    /// request had been honoured.
    public let targetSaturated: Bool

    public init(printedVoxels: Int, insidePart: Int, outsidePart: Int,
                partSolidVoxels: Int, outsideFraction: Double,
                outsideVolumeMM3: Double, netAddedVolumeMM3: Double,
                outsideMassGrams: Double, netAddedMassGrams: Double,
                targetSaturated: Bool = false) {
        self.printedVoxels = printedVoxels
        self.insidePart = insidePart
        self.outsidePart = outsidePart
        self.partSolidVoxels = partSolidVoxels
        self.outsideFraction = outsideFraction
        self.outsideVolumeMM3 = outsideVolumeMM3
        self.netAddedVolumeMM3 = netAddedVolumeMM3
        self.outsideMassGrams = outsideMassGrams
        self.netAddedMassGrams = netAddedMassGrams
        self.targetSaturated = targetSaturated
    }
}

/// One evaluated volume-fraction rung of a minimize_plastic run.
public struct OptimizeVariant {
    public let requestedVolumeFraction: Double
    /// The PRINTED/count-basis volume fraction (#{ρ>0.5}/part_solid); savings is its
    /// complement (1 - achievedVolumeFraction) and shares the reported mass's voxel
    /// count, so the two can never disagree (handoff 094/104). Kept as the app's
    /// savings basis under this name for continuity; `printedFraction` names it too.
    public let achievedVolumeFraction: Double
    /// Handoff 104 (additive): the printed/count basis by its canonical name — equal
    /// to `achievedVolumeFraction`. Distinct from the core report's optimizer-achieved
    /// (continuous) `volume_fraction`; surfaced so any UI showing both can label them
    /// "optimizer achieved" vs "printed" rather than two unlabeled percentages.
    public let printedFraction: Double
    public let massGrams: Double
    public let supportVolumeVoxels: Int
    public let meshTriangleCount: Int
    public let worstCaseMargin: Double
    public let accepted: Bool
    public let v3Passes: Bool
    /// M5.2b min-feature violation count (solid regions thinner than 2 voxels).
    /// REPORT-ONLY (DECISIONS 2026-07-06): advisory, never gates `accepted`.
    public let minFeatureViolations: Int
    /// The human-readable min-feature warning, or "" when there are none.
    public let minFeatureWarning: String
    /// M7.8 — the chosen build orientation (M4.4 winning unit build direction),
    /// for the results orientation sheet.
    public let orientation: SIMD3<Double>
    /// M7.8 — peak stresses for the chosen orientation (MPa). `maxStressMPa` (max
    /// von Mises) drives the stress legend's shared scale; `maxInterlayerTensionMPa`
    /// is the raw layer-plane tension behind the "Layer shear" readout.
    public let maxStressMPa: Double
    public let maxInterlayerTensionMPa: Double
    /// M7.8 — the two margin components (safety factors; larger is safer). The
    /// worst case is `worstCaseMargin`; `interlayerMargin` classifies layer shear.
    public let inPlaneMargin: Double
    public let interlayerMargin: Double
    /// M7.8 — the extracted+cleaned variant isosurface for display: flattened xyz
    /// vertices and flattened triangle-corner indices (empty for a cancelled rung).
    public let meshVertices: [Float]
    public let meshIndices: [Int32]
    /// M7.8 — per-voxel von Mises stress (MPa), grid-indexed against the outcome's
    /// grid metadata, for the stress overlay. Empty for a cancelled rung.
    public let vonMisesField: [Float]
    /// M7.disp — the per-node displacement field (mm), DOF-ordered: entries
    /// [3n, 3n+1, 3n+2] are (ux, uy, uz) of grid node n (corner (a,b,c) at index
    /// (c*(gridNy+1)+b)*(gridNx+1)+a; count 3*(gridNx+1)*(gridNy+1)*(gridNz+1)).
    /// The companion of `vonMisesField` that M7.viz.3's flex animation displaces
    /// mesh vertices by; zero on nodes attached only to non-printed voxels, empty
    /// for a cancelled rung.
    public let displacementField: [Float]
    /// M7.viz.5 (load→anchor flow) — the per-voxel Cauchy stress tensor, grid-indexed
    /// and flattened: voxel `idx` occupies entries `[6*idx .. 6*idx+5]` in Voigt order
    /// `[xx, yy, zz, xy, yz, zx]` with TRUE shear (τ, not doubled), MPa; size
    /// `6·voxelCount`. The tensor `vonMisesField` is derived from, exposed per voxel so
    /// the app can integrate load→anchor flux streamlines (`F = σ·d̂`). Zero on
    /// non-printed voxels (companion to `vonMisesField`); empty for a cancelled rung.
    public let stressTensorField: [Float]
    /// Optimization-history keyframes (playback): the isosurface from ~solid (first)
    /// to optimized (last). Empty when playback capture is off.
    public let keyframeMeshes: [KeyframeMesh]
    /// WHY this rung's verdict is what it is (handoff 2026-08-02-gate-diagnosis-
    /// recommendations). nil when the run did not arm the diagnosis. It EXPLAINS
    /// `accepted` / `worstCaseMargin` above and never contradicts them.
    public let diagnosis: GateDiagnosis?
    /// WHERE THIS VARIANT'S PLASTIC IS (task 2026-08-03-growth-ladder). nil on a
    /// REDUCTION run — the question was never asked — and the headline of a GROWTH
    /// one. See `AddedMaterial`.
    public let addedMaterial: AddedMaterial?

    public init(requestedVolumeFraction: Double, achievedVolumeFraction: Double,
                printedFraction: Double? = nil,
                massGrams: Double, supportVolumeVoxels: Int, meshTriangleCount: Int,
                worstCaseMargin: Double, accepted: Bool, v3Passes: Bool,
                minFeatureViolations: Int = 0, minFeatureWarning: String = "",
                orientation: SIMD3<Double> = .zero, maxStressMPa: Double = 0,
                maxInterlayerTensionMPa: Double = 0, inPlaneMargin: Double = 0,
                interlayerMargin: Double = 0, meshVertices: [Float] = [],
                meshIndices: [Int32] = [], vonMisesField: [Float] = [],
                displacementField: [Float] = [], stressTensorField: [Float] = [],
                keyframeMeshes: [KeyframeMesh] = [],
                diagnosis: GateDiagnosis? = nil,
                addedMaterial: AddedMaterial? = nil) {
        self.requestedVolumeFraction = requestedVolumeFraction
        self.achievedVolumeFraction = achievedVolumeFraction
        // printedFraction defaults to achievedVolumeFraction: on the app the two are
        // the same count basis (handoff 104), and this keeps every existing caller
        // (and persisted blobs decoded before this field existed) byte-identical.
        self.printedFraction = printedFraction ?? achievedVolumeFraction
        self.massGrams = massGrams
        self.supportVolumeVoxels = supportVolumeVoxels
        self.meshTriangleCount = meshTriangleCount
        self.worstCaseMargin = worstCaseMargin
        self.accepted = accepted
        self.v3Passes = v3Passes
        self.minFeatureViolations = minFeatureViolations
        self.minFeatureWarning = minFeatureWarning
        self.orientation = orientation
        self.maxStressMPa = maxStressMPa
        self.maxInterlayerTensionMPa = maxInterlayerTensionMPa
        self.inPlaneMargin = inPlaneMargin
        self.interlayerMargin = interlayerMargin
        self.meshVertices = meshVertices
        self.meshIndices = meshIndices
        self.vonMisesField = vonMisesField
        self.displacementField = displacementField
        self.stressTensorField = stressTensorField
        self.keyframeMeshes = keyframeMeshes
        self.diagnosis = diagnosis
        self.addedMaterial = addedMaterial
    }

    /// The same variant with DIFFERENT GEOMETRY — the smooth-then-lattice handoff
    /// (handoff 2026-08-02-smoothing-page, bar AE8). A kept smoothing replaces the
    /// mesh and NOTHING else: the rung, the field, the margins and the run's own
    /// record travel unchanged, because smoothing changed the surface and not which
    /// variant this is. The margins deliberately stay the RUN's — the smoothing
    /// page's own receipt carries the smoothed geometry's certification, and
    /// copying it in here would silently restate one solver's answer as another's.
    public func withGeometry(vertices: [Float], indices: [Int32]) -> OptimizeVariant {
        OptimizeVariant(
            requestedVolumeFraction: requestedVolumeFraction,
            achievedVolumeFraction: achievedVolumeFraction,
            printedFraction: printedFraction, massGrams: massGrams,
            supportVolumeVoxels: supportVolumeVoxels,
            meshTriangleCount: indices.count / 3,
            worstCaseMargin: worstCaseMargin, accepted: accepted,
            v3Passes: v3Passes, minFeatureViolations: minFeatureViolations,
            minFeatureWarning: minFeatureWarning, orientation: orientation,
            maxStressMPa: maxStressMPa,
            maxInterlayerTensionMPa: maxInterlayerTensionMPa,
            inPlaneMargin: inPlaneMargin, interlayerMargin: interlayerMargin,
            meshVertices: vertices, meshIndices: indices,
            vonMisesField: vonMisesField, displacementField: displacementField,
            stressTensorField: stressTensorField, keyframeMeshes: keyframeMeshes,
            diagnosis: diagnosis, addedMaterial: addedMaterial)
    }
}

/// How long a run actually took, in the run's OWN frame of reference — never the
/// viewer's (handoff 134, results-integrity item 1).
///
/// The incident: a 40m53s remote solve looked at the next morning reported "11
/// hours", because the only duration the app had was wall time measured against
/// `now()` (or against the moment the client re-attached). Both are properties of
/// WHEN SOMEONE LOOKED, not of the run. A duration that drifts with the observer is
/// a number describing a different object than the file — the same reject class as
/// a fabricated mass.
///
/// So the duration is CARRIED, not computed at display time:
///   * a remote run reads the worker's own record (`created_at` / `started_at` /
///     `finished_at` on `GET /jobs/{id}`), the same timestamps the Mac's menu shows;
///   * a local run stamps its own start/finish while it is genuinely running.
/// Nothing downstream may reconstruct it from `Date()`. `nil` (no timing at all)
/// is the honest fallback — the results screen then shows NO duration rather than
/// an observer-dependent one.
///
/// `queuedSeconds` is the wait BEFORE the solve began (a worker queue is real time
/// the user waited but not time the part was being solved). It is reported
/// separately — "waited 4m · solved 40m 53s" — so neither number absorbs the other.
public struct RunTiming: Equatable, Sendable {
    /// Seconds spent QUEUED before the solve started. 0 for a local run (nothing
    /// queues) and for a remote job promoted immediately.
    public let queuedSeconds: TimeInterval
    /// Seconds spent SOLVING: finish − start, measured where the solve happened.
    public let solveSeconds: TimeInterval

    public init(queuedSeconds: TimeInterval = 0, solveSeconds: TimeInterval) {
        // Clamp rather than trust: a worker clock adjustment (or a garbled field)
        // must not produce a negative "duration" the UI would render as nonsense.
        self.queuedSeconds = Swift.max(0, queuedSeconds)
        self.solveSeconds = Swift.max(0, solveSeconds)
    }

    /// Build from the worker's epoch timestamps. Returns nil unless BOTH ends of the
    /// solve are known — a job with no `finished_at` has no truthful duration yet,
    /// and inventing one from `now()` is the bug this type exists to prevent.
    public static func fromWorker(createdAt: Double?, startedAt: Double?,
                                  finishedAt: Double?) -> RunTiming? {
        guard let finished = finishedAt else { return nil }
        // A job that never recorded a promotion start (a pre-121 worker) still has an
        // honest total: created → finished, all of it attributed to the solve, with
        // no queue claim we can't support.
        guard let started = startedAt else {
            guard let created = createdAt else { return nil }
            return RunTiming(queuedSeconds: 0, solveSeconds: finished - created)
        }
        return RunTiming(queuedSeconds: createdAt.map { started - $0 } ?? 0,
                         solveSeconds: finished - started)
    }

    /// "40m 53s" / "1h 04m" / "38s" — the exact solve time, locale-independent so it
    /// is unit-testable and matches the worker's own reading of the same interval.
    public static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(Swift.max(0, seconds).rounded())
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// The results/summary line. "solved 40m 53s", or "waited 4m 12s · solved 40m 53s"
    /// when the run sat in the worker's queue first. The queue wait is shown ONLY when
    /// it is real (≥ 1s) — a zero wait is not worth a clause.
    public var summary: String {
        let solved = "solved \(RunTiming.clock(solveSeconds))"
        guard queuedSeconds >= 1 else { return solved }
        return "waited \(RunTiming.clock(queuedSeconds)) · \(solved)"
    }
}

/// The outcome of a minimize_plastic run (ROADMAP M5.3 / M7.7).
public struct OptimizeOutcome {
    public let variants: [OptimizeVariant]
    public let stoppedOnMargin: Bool
    public let cancelled: Bool
    public let acceptedCount: Int
    /// M7.8 — the run's voxel volume (mm³ == spacing³), for turning a variant's
    /// `supportVolumeVoxels` count into a cm³ support estimate.
    public let voxelVolumeMM3: Double
    /// M7.8 — the run's voxel grid (dims, min-corner origin, spacing), for sampling
    /// a variant's `vonMisesField` at a mesh vertex (index (k*ny+j)*nx+i).
    public let gridNx: Int
    public let gridNy: Int
    public let gridNz: Int
    public let gridOrigin: SIMD3<Double>
    public let spacing: Double
    /// LAN offload (handoff 097): true when this outcome was computed on a remote
    /// worker via `topopt-cli`, which serialises meshes + the scalar report but NOT
    /// the per-voxel von Mises / displacement / stress-tensor fields, the playback
    /// keyframes, or the mass. The results screen uses this to render those fields
    /// as explicitly UNAVAILABLE ("computed on Mac — n/a in this build") rather than
    /// as a plausible-but-wrong 0 g / blank overlay. Default false → local runs are
    /// byte-identical (a local outcome never sets this).
    public let computedRemotely: Bool

    /// Handoff 100 — what each declared "Keep clear" clearance actually did on the
    /// solved grid, so the results screen states it HONESTLY: which face, which
    /// kind, how many voxels it forbade, and whether the region reached the grid at
    /// all (`inGrid == false` → a silent no-op the UI SURFACES rather than hides).
    /// Empty when no clearance was declared.
    public let appliedClearances: [AppliedClearance]

    /// Handoff 124 — what each declared Face protection actually preserved on the
    /// solved grid, so the results screen states it HONESTLY: which face, how many
    /// voxels its skin was frozen to, the depth used, and whether the face's own
    /// solid was thinner than that depth (froze what exists, no silent over-claim).
    /// Empty when no protection was declared.
    public let appliedFaceProtections: [AppliedFaceProtection]

    /// Handoff 134 — how long the run took, measured WHERE IT RAN (see `RunTiming`).
    /// A remote outcome carries the worker's own created/started/finished record; a
    /// local one carries the app's own start→finish stamp. nil when no truthful
    /// timing is available (a legacy blob, a worker that didn't report one) — the
    /// results screen then shows no duration rather than one derived from `now()`.
    public let timing: RunTiming?

    /// Handoff 2026-07-29-lattice-mode-ui — the lattice the RUN carried (what was
    /// generated), so the results screen names it HONESTLY rather than showing the
    /// project's current (possibly since-edited) settings. nil for a non-lattice run.
    /// Carries the settings echo always, and the worker's generated facts when the
    /// run_info `lattice_export` record was available (remote runs). On-device runs
    /// don't generate lattices, so a local outcome leaves this nil.
    public let latticeReport: LatticeReport?

    /// The BUILD-ORIENTATION RECEIPT this run produced (handoff
    /// 2026-08-01-build-direction-separation) — the raw JSON of the core's ONE
    /// emitter, identical whether the run was on-device (bridge) or on a LAN
    /// worker (build_orientation.json). Decode with `OrientationRanking.decode`.
    ///
    /// A RECOMMENDATION. Every `variants[i].accepted` above is that rung's verdict
    /// for the orientation ACTUALLY USED, and nothing in this string may change it.
    /// nil unless the run armed the ranking.
    public let buildOrientationJSON: Data?

    /// WHICH MACHINE SOLVED THIS RUN (task 2026-08-03-variant-entry-gating-and-
    /// retention, bar AJ5) — the LAN worker's own name as the app selected it
    /// ("Mac mini"), or nil.
    ///
    /// nil is DELIBERATELY AMBIGUOUS-FREE only in combination with
    /// `computedRemotely`: nil + local ⇒ this device; nil + remote ⇒ a worker whose
    /// name was not recorded (a re-attached or legacy run). The app never guesses a
    /// name — the whole point of this field is that "re-run it on a Mac worker" must
    /// not be told to someone who did exactly that.
    public let solvedBy: String?

    /// WHICH LADDER THIS RUN WALKED (task 2026-08-03-growth-ladder).
    ///
    ///   false — REDUCTION: every rung ≤ 1.0 × the part. "Remove as much plastic
    ///           as possible while holding the required margin"; the
    ///           recommendation is the LIGHTEST variant that passes.
    ///   true  — GROWTH: every rung > 1.0 × the part. "Add as little plastic as
    ///           possible to reach the required margin"; the recommendation is the
    ///           SMALLEST ADDITION that passes.
    ///
    /// The two ladders optimize for OPPOSITE things and their variant tables look
    /// alike, so the results screen must NAME the mode. It comes from the core's
    /// own flag rather than being inferred from a fraction, so a run can never be
    /// presented as the mode it was not. Default false keeps every existing
    /// caller, and every persisted pre-growth outcome, reading as reduction — which
    /// is what they are.
    public let growthLadder: Bool

    public init(variants: [OptimizeVariant], stoppedOnMargin: Bool,
                cancelled: Bool, acceptedCount: Int, voxelVolumeMM3: Double = 0,
                gridNx: Int = 0, gridNy: Int = 0, gridNz: Int = 0,
                gridOrigin: SIMD3<Double> = .zero, spacing: Double = 0,
                computedRemotely: Bool = false,
                appliedClearances: [AppliedClearance] = [],
                appliedFaceProtections: [AppliedFaceProtection] = [],
                timing: RunTiming? = nil,
                latticeReport: LatticeReport? = nil,
                buildOrientationJSON: Data? = nil,
                solvedBy: String? = nil,
                growthLadder: Bool = false) {
        self.variants = variants
        self.stoppedOnMargin = stoppedOnMargin
        self.cancelled = cancelled
        self.acceptedCount = acceptedCount
        self.voxelVolumeMM3 = voxelVolumeMM3
        self.gridNx = gridNx
        self.gridNy = gridNy
        self.gridNz = gridNz
        self.gridOrigin = gridOrigin
        self.spacing = spacing
        self.computedRemotely = computedRemotely
        self.appliedClearances = appliedClearances
        self.appliedFaceProtections = appliedFaceProtections
        self.timing = timing
        self.latticeReport = latticeReport
        self.buildOrientationJSON = buildOrientationJSON
        self.solvedBy = solvedBy
        self.growthLadder = growthLadder
    }

    /// A copy carrying `solvedBy` — how the run flow stamps the machine it
    /// DISPATCHED to onto an outcome the bridge/worker built without one (neither
    /// knows where it ran). Never overwrites a name already present.
    public func withSolvedBy(_ name: String?) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: stoppedOnMargin,
                        cancelled: cancelled, acceptedCount: acceptedCount,
                        voxelVolumeMM3: voxelVolumeMM3,
                        gridNx: gridNx, gridNy: gridNy, gridNz: gridNz,
                        gridOrigin: gridOrigin, spacing: spacing,
                        computedRemotely: computedRemotely,
                        appliedClearances: appliedClearances,
                        appliedFaceProtections: appliedFaceProtections,
                        timing: timing, latticeReport: latticeReport,
                        buildOrientationJSON: buildOrientationJSON,
                        solvedBy: solvedBy ?? name,
                        growthLadder: growthLadder)
    }

    /// A copy carrying `timing` — how the run flow stamps a LOCAL run's measured
    /// duration onto an outcome the solver built without one. Never used to overwrite
    /// a timing the outcome already carries (a remote outcome's worker record wins;
    /// see `RunTiming`).
    public func withTiming(_ timing: RunTiming?) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: stoppedOnMargin,
                        cancelled: cancelled, acceptedCount: acceptedCount,
                        voxelVolumeMM3: voxelVolumeMM3,
                        gridNx: gridNx, gridNy: gridNy, gridNz: gridNz,
                        gridOrigin: gridOrigin, spacing: spacing,
                        computedRemotely: computedRemotely,
                        appliedClearances: appliedClearances,
                        appliedFaceProtections: appliedFaceProtections,
                        timing: timing ?? self.timing,
                        latticeReport: latticeReport,
                        buildOrientationJSON: buildOrientationJSON,
                        solvedBy: solvedBy,
                        growthLadder: growthLadder)
    }

    /// A copy carrying `latticeReport` — how the run flow stamps the run's lattice onto
    /// an outcome the solver/assembler built without one (the request is known at the
    /// run flow, not inside the bridge). Never overwrites a report already present.
    public func withLatticeReport(_ report: LatticeReport?) -> OptimizeOutcome {
        OptimizeOutcome(variants: variants, stoppedOnMargin: stoppedOnMargin,
                        cancelled: cancelled, acceptedCount: acceptedCount,
                        voxelVolumeMM3: voxelVolumeMM3,
                        gridNx: gridNx, gridNy: gridNy, gridNz: gridNz,
                        gridOrigin: gridOrigin, spacing: spacing,
                        computedRemotely: computedRemotely,
                        appliedClearances: appliedClearances,
                        appliedFaceProtections: appliedFaceProtections,
                        timing: timing,
                        latticeReport: self.latticeReport ?? report,
                        buildOrientationJSON: buildOrientationJSON,
                        solvedBy: solvedBy,
                        growthLadder: growthLadder)
    }
}

/// The lattice a RUN carried (handoff 2026-07-29-lattice-mode-ui): the settings echo
/// the app sent, plus the facts the worker's run_info `lattice_export` reported when a
/// lattice was actually generated. A plain data record for the results screen — no
/// core dependency, populated by the run flow from the request + run_info.
public struct LatticeReport: Equatable, Sendable {
    public let topologyID: String
    public let cellMM: Double
    /// The single density the uniform build filled at (the range's dense end).
    public let generateRelativeDensity: Double
    public let minRelativeDensity: Double
    public let maxRelativeDensity: Double
    /// True iff a sub-region primitive scoped the preview (vs the whole part).
    public let regionScoped: Bool
    /// How many include/exclude regions the JOB actually carried
    /// (`lattice.regions`). Distinct from `regionScoped`, which is also true for a
    /// legacy PREVIEW-only include primitive that never reaches the job — the two
    /// being conflated is what made the results screen say the build ignored the
    /// user's regions even when it had honoured them (task
    /// 2026-08-04-variant-volume-fraction-mismatch, bar B6).
    public let emittedRegions: Int
    /// Worker-generated facts from run_info `lattice_export`; nil when unavailable
    /// (a local run, or the run_info couldn't be read) — then only the settings echo
    /// shows, honestly labelled "requested".
    public let generated: Generated?
    /// Strut-strength REPORT (task 2026-07-31-lattice-strut-strength-report),
    /// parsed from run_info's certification `lattice` object when the worker
    /// evaluated PR 259's measured de-homogenization law. REPORT ONLY — these
    /// numbers never fed the accept verdict. In-plane and interlayer are kept
    /// SEPARATE deliberately (which one binds is the point, exactly like a solid
    /// part's margin.in_plane / margin.interlayer); the interlayer margin divides
    /// by the UNSOURCED z_knockdown echoed here. nil when the worker reported no
    /// strut numbers (older worker, non-octet lattice, or run_info unreadable).
    public let strut: StrutStrength?

    public struct StrutStrength: Equatable, Sendable {
        public let marginInPlane: Double
        public let marginInterlayer: Double
        /// The interlayer divisor, echoed because its provenance is UNSOURCED —
        /// the bound survives re-sourcing, this margin does not.
        public let zKnockdown: Double
        /// Thinnest latticed member's span in cells vs the homogenization floor;
        /// below the floor the numbers are indicative, not certified.
        public let minCellsPerMember: Double
        public let outOfRegime: Bool
        /// SUB-FLOOR RETENTION (handoff 2026-08-04-subfloor-lattice-unloaded-regions).
        /// How many voxels were DELIBERATELY kept as lattice below the floor because
        /// the region measured as carrying almost no load, and what that region's peak
        /// stress measured as a fraction of the part's peak. 0 / 0 means the run did
        /// not opt in — and then an `outOfRegime` flag means something else entirely
        /// (a member that came out thinner than the cell could hold), which is why the
        /// two are reported apart rather than collapsed into one reason.
        public let subfloorRetainedVoxels: Int
        public let subfloorRegionStressFraction: Double
        public init(marginInPlane: Double, marginInterlayer: Double,
                    zKnockdown: Double, minCellsPerMember: Double,
                    outOfRegime: Bool,
                    subfloorRetainedVoxels: Int = 0,
                    subfloorRegionStressFraction: Double = 0) {
            self.marginInPlane = marginInPlane
            self.marginInterlayer = marginInterlayer
            self.zKnockdown = zKnockdown
            self.minCellsPerMember = minCellsPerMember
            self.outOfRegime = outOfRegime
            self.subfloorRetainedVoxels = subfloorRetainedVoxels
            self.subfloorRegionStressFraction = subfloorRegionStressFraction
        }
    }

    public struct Generated: Equatable, Sendable {
        public let emitSTL: Bool
        public let emit3MF: Bool
        public let latticedCells: Int
        public let regionVoxels: Int
        public let triangles: Int
        public let strutRadiusMinMM: Double
        public let strutRadiusMaxMM: Double
        public init(emitSTL: Bool, emit3MF: Bool, latticedCells: Int, regionVoxels: Int,
                    triangles: Int, strutRadiusMinMM: Double, strutRadiusMaxMM: Double) {
            self.emitSTL = emitSTL
            self.emit3MF = emit3MF
            self.latticedCells = latticedCells
            self.regionVoxels = regionVoxels
            self.triangles = triangles
            self.strutRadiusMinMM = strutRadiusMinMM
            self.strutRadiusMaxMM = strutRadiusMaxMM
        }
    }

    public init(topologyID: String, cellMM: Double, generateRelativeDensity: Double,
                minRelativeDensity: Double, maxRelativeDensity: Double,
                regionScoped: Bool, emittedRegions: Int = 0,
                generated: Generated? = nil,
                strut: StrutStrength? = nil) {
        self.topologyID = topologyID
        self.cellMM = cellMM
        self.generateRelativeDensity = generateRelativeDensity
        self.minRelativeDensity = minRelativeDensity
        self.maxRelativeDensity = maxRelativeDensity
        self.regionScoped = regionScoped
        self.emittedRegions = emittedRegions
        self.generated = generated
        self.strut = strut
    }
}

/// One clearance region's outcome (handoff 100): the face it came from, its kind,
/// how many voxels it forbade, and whether it reached the solved grid.
public struct AppliedClearance: Equatable, Sendable {
    public let faceID: Int
    public let kind: TopOptKit.ClearanceKind
    public let voxelsFrozen: Int
    public let inGrid: Bool
    public init(faceID: Int, kind: TopOptKit.ClearanceKind, voxelsFrozen: Int, inGrid: Bool) {
        self.faceID = faceID
        self.kind = kind
        self.voxelsFrozen = voxelsFrozen
        self.inGrid = inGrid
    }
}

/// One Face protection's outcome (handoff 124): the face whose skin was preserved,
/// how many part voxels were frozen FrozenSolid behind it, the depth (in voxels)
/// used, and whether the face's own solid was thinner than that depth (so it froze
/// what exists — the honest edge, no silent over-claim).
public struct AppliedFaceProtection: Equatable, Sendable {
    public let faceID: Int
    public let voxelsFrozen: Int
    public let depthVoxels: Int
    public let thinnerThanDepth: Bool
    public init(faceID: Int, voxelsFrozen: Int, depthVoxels: Int, thinnerThanDepth: Bool) {
        self.faceID = faceID
        self.voxelsFrozen = voxelsFrozen
        self.depthVoxels = depthVoxels
        self.thinnerThanDepth = thinnerThanDepth
    }
}

/// The M7.1 bridge smoke summary: material count + imported-mesh triangle count.
public struct SmokeResult {
    public let materialCount: Int
    public let triangleCount: Int
    public let watertight: Bool
}

/// Boxes the Swift progress closure so it can be reached from the C
/// `@convention(c)` trampoline via an opaque context pointer.
private final class ProgressBox {
    /// Returns `true` to keep running, `false` to request cancellation.
    let callback: (_ rung: Int, _ rungCount: Int, _ iteration: Int) -> Bool
    let cancelFlag: UnsafeMutablePointer<Bool>
    init(_ cb: @escaping (Int, Int, Int) -> Bool,
         _ cancelFlag: UnsafeMutablePointer<Bool>) {
        self.callback = cb
        self.cancelFlag = cancelFlag
    }
}

/// Boxes the Swift per-variant closure so the C `@convention(c)` variant
/// trampoline can reach it via an opaque context pointer (progressive results).
private final class VariantBox {
    /// Receives a one-variant partial outcome (the variant + the run's grid metadata).
    let callback: (OptimizeOutcome) -> Void
    init(_ cb: @escaping (OptimizeOutcome) -> Void) { self.callback = cb }
}

/// The TopOptKit API. Static functions form the M7.1 bridge surface: load
/// materials, import STEP/STL, voxelize, tag faces, run minimize_plastic (with
/// M7.0a progress + cancellation), and export.
public enum TopOptKit {

    /// The core library version (topopt::version()); a trivial liveness check.
    public static var coreVersion: String { String(topoptbridge.core_version()) }

    // MARK: lattice certification limits (handoff 2026-07-29-lattice-mode-ui)

    /// The certifiable bounds the lattice-mode controls clamp to, READ FROM CORE at
    /// runtime (topopt::lattice_rho_min/max via the bridge) — the app hardcodes none
    /// of these numbers, so the controls widen automatically the moment core's
    /// measurement widens. `certifiable == false` means the core does not carry a
    /// homogenized tensor for the topology (preview-only); `minCellsPerMember == 0`
    /// means core does not yet certify a cells-per-member ceiling, so the UI shows
    /// that readout as advisory rather than a hard clamp.
    public struct LatticeLimits: Equatable, Sendable {
        public let rhoMin: Double
        public let rhoMax: Double
        public let certifiable: Bool
        public let minCellsPerMember: Double
        public init(rhoMin: Double, rhoMax: Double, certifiable: Bool, minCellsPerMember: Double) {
            self.rhoMin = rhoMin
            self.rhoMax = rhoMax
            self.certifiable = certifiable
            self.minCellsPerMember = minCellsPerMember
        }
    }

    /// The core's certifiable limits for a lattice topology named as the job schema
    /// names it (`"octet"`). Forwards `topoptbridge::lattice_limits`; never throws.
    public static func latticeLimits(topology: String) -> LatticeLimits {
        let lim = topoptbridge.lattice_limits(std.string(topology))
        return LatticeLimits(rhoMin: lim.rho_min, rhoMax: lim.rho_max,
                             certifiable: lim.certifiable,
                             minCellsPerMember: lim.min_cells_per_member)
    }

    /// The CELL-SIZE bounds the Auto / Fixed / Swept control must respect, BOTH read
    /// from core (handoff 2026-08-01-lattice-cell-size-sweep, bar R6). The app
    /// hardcodes neither number, so a re-measurement in core moves the control with
    /// no app change.
    /// - `printabilityFloorMM` — the smallest cell at which this topology's thinnest
    ///   certifiable strut still prints at the stated extrusion width. It is the
    ///   control's LOWER bound and the cell core picks in AUTO mode.
    /// - `cellsPerMemberFloor` — N*, the scale-separation floor; on a member of width
    ///   W the ceiling is W / N*.
    /// - `valid == false` — core carries no tensor for the topology, or the width was
    ///   non-positive; the UI then says it has no core number rather than guessing.
    public struct LatticeCellBounds: Equatable, Sendable {
        public let printabilityFloorMM: Double
        public let cellsPerMemberFloor: Double
        public let valid: Bool
        public init(printabilityFloorMM: Double, cellsPerMemberFloor: Double, valid: Bool) {
            self.printabilityFloorMM = printabilityFloorMM
            self.cellsPerMemberFloor = cellsPerMemberFloor
            self.valid = valid
        }
    }

    /// Core's cell-size bounds for a topology named as the job schema names it
    /// (`"octet"`) at the user's own minimum extrudable width (mm). Forwards
    /// `topoptbridge::lattice_cell_bounds`; never throws.
    public static func latticeCellBounds(topology: String,
                                         minExtrudableWidthMM: Double) -> LatticeCellBounds {
        let b = topoptbridge.lattice_cell_bounds(std.string(topology), minExtrudableWidthMM)
        return LatticeCellBounds(printabilityFloorMM: b.printability_floor_mm,
                                 cellsPerMemberFloor: b.cells_per_member_floor,
                                 valid: b.valid)
    }

    /// The topology names the core can RUN and certify today (the seven cubic
    /// topologies). The UI reads this to mark which picker entries are certifiable
    /// rather than assuming.
    public static var latticeCertifiableTopologies: [String] {
        topoptbridge.lattice_certifiable_topologies().map { String($0) }
    }

    /// The topology names the core GEOMETRY GENERATOR can emit (`["octet"]` today).
    /// Certifiability and generatability are INDEPENDENT: core certifies seven
    /// topologies but can generate geometry for only this set. The picker reads
    /// BOTH sets and never infers one from the other (handoff
    /// 2026-07-30-lattice-page, bar B0).
    public static var latticeGeneratableTopologies: [String] {
        topoptbridge.lattice_generatable_topologies().map { String($0) }
    }

    /// Load and validate a materials.json file (ARCHITECTURE §6). Materials are
    /// returned in the core's deterministic name-sorted order.
    public static func loadMaterials(path: String) throws -> [Material] {
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.load_materials(std.string(path), &err)
        try throwIfFailed(err)
        return raw.map {
            Material(name: String($0.name),
                     youngsModulusMPa: $0.youngs_modulus_mpa,
                     yieldStrengthMPa: $0.yield_strength_mpa,
                     densityGCm3: $0.density_g_cm3,
                     zKnockdown: $0.z_knockdown,
                     poisson: $0.poisson,
                     family: String($0.family))
        }
    }

    /// Import a STEP, STL or 3MF file into a face-carrying mesh.
    ///
    /// Handoff 134: one call for every format. The core dispatches by extension
    /// — a STEP gets its real B-rep faces, a mesh gets pseudo-faces from the
    /// dihedral segmenter — and both arrive with `faceIDs`, `faceCount` and
    /// `faceGeometry` populated, which is what makes tap selection, keep-clear,
    /// protect and optimize work identically on an STL.
    ///
    /// Throws on an unreadable/unparseable file OR on a mesh-quality refusal;
    /// call `inspectPart` for the structured reason behind a refusal.
    public static func importMesh(path: String,
                                  linearDeflectionMM: Double = 0) throws -> ImportedMesh {
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.import_part(std.string(path), linearDeflectionMM, &err)
        try throwIfFailed(err)
        return convert(raw)
    }

    /// Inspect a part file without throwing on a mesh-quality refusal: the
    /// structured verdict behind the refusal sheet (handoff 134). Still throws
    /// if the file cannot be read or parsed at all — there is nothing to
    /// inspect in that case.
    public static func inspectPart(path: String) throws -> PartDiagnostics {
        var err = topoptbridge.BridgeError()
        let raw = topoptbridge.inspect_part(std.string(path), &err)
        try throwIfFailed(err)
        return PartDiagnostics(
            checked: raw.checked,
            acceptable: raw.acceptable,
            defects: raw.defects.compactMap { PartDiagnostics.Defect(rawValue: Int($0)) },
            defectText: raw.defect_text.map { String($0) },
            boundaryEdges: Int(raw.boundary_edges),
            nonManifoldEdges: Int(raw.non_manifold_edges),
            degenerateTriangles: Int(raw.degenerate_triangles),
            weldedVertices: Int(raw.welded_vertices),
            flippedTriangles: Int(raw.flipped_triangles),
            removedDuplicateTriangles: Int(raw.removed_duplicate_triangles),
            filledHoles: Int(raw.filled_holes),
            filledHoleTriangles: Int(raw.filled_hole_triangles),
            volume: raw.volume,
            bboxMin: SIMD3<Double>(raw.bbox_min.0, raw.bbox_min.1, raw.bbox_min.2),
            bboxMax: SIMD3<Double>(raw.bbox_max.0, raw.bbox_max.1, raw.bbox_max.2))
    }

    /// Apply a unit choice by writing a rescaled binary-STL working copy
    /// (handoff 134). STL carries no unit, so the app asks once and bakes the
    /// answer into the app-owned copy; every later stateless core call then
    /// re-reads a file that is already in millimetres, so no unit has to be
    /// threaded through the bridge, the job schema or persistence.
    public static func rescalePart(from inPath: String, to outPath: String,
                                   scale: Double) throws {
        var err = topoptbridge.BridgeError()
        topoptbridge.rescale_part(std.string(inPath), std.string(outPath), scale, &err)
        try throwIfFailed(err)
    }

    /// Export a mesh to an STL file (ROADMAP M6.1 secondary format; 3MF is M7.9).
    public static func exportSTL(mesh: ImportedMesh, to path: String) throws {
        var raw = topoptbridge.ImportedMesh()
        for v in mesh.vertices { raw.vertices.push_back(v) }
        for i in mesh.indices { raw.indices.push_back(i) }
        raw.vertex_count = Int32(mesh.vertexCount)
        raw.triangle_count = Int32(mesh.triangleCount)
        var err = topoptbridge.BridgeError()
        topoptbridge.export_stl(std.string(path), raw, &err)
        try throwIfFailed(err)
    }

    /// Voxelize the mesh at `path` (STL or STEP) at the given resolution.
    public static func voxelize(meshPath: String, resolution: Int) throws -> VoxelSummary {
        var err = topoptbridge.BridgeError()
        let s = topoptbridge.voxelize_mesh(std.string(meshPath), Int32(resolution), &err)
        try throwIfFailed(err)
        return VoxelSummary(nx: Int(s.nx), ny: Int(s.ny), nz: Int(s.nz),
                            spacing: s.spacing, solidVoxels: Int(s.solid_voxels))
    }

    /// Tag the voxels against B-rep face `faceID` of a STEP part as Fixture (or
    /// Load), returning the number tagged (ROADMAP M1.6 / M7.5).
    public static func tagStepFace(stepPath: String, faceID: Int,
                                   asFixture: Bool, resolution: Int) throws -> Int {
        var err = topoptbridge.BridgeError()
        let n = topoptbridge.tag_step_face(std.string(stepPath), Int32(faceID),
                                           asFixture, Int32(resolution), &err)
        try throwIfFailed(err)
        return Int(n)
    }

    /// Passive-region design mask value (ROADMAP M3.7), matching
    /// topopt::MaskValue: keep a region always full (`frozenSolid`) or always
    /// empty (`frozenVoid`), or leave it a free design variable (`active`).
    public enum MaskValue: Int32 {
        case active = 0
        case frozenSolid = 1
        case frozenVoid = 2
    }

    /// Mask the voxels within `depthVoxels` layers of B-rep face `faceID` of a
    /// STEP part as a passive region, returning the number masked (ROADMAP M3.7
    /// / M7.6-core D7). This freezes a load/anchor face as an N-voxel passive
    /// shell so the optimizer cannot remove the surface the boundary conditions
    /// sit on.
    public static func maskStepFace(stepPath: String, faceID: Int,
                                    mask: MaskValue, depthVoxels: Int,
                                    resolution: Int) throws -> Int {
        var err = topoptbridge.BridgeError()
        let n = topoptbridge.mask_step_face(std.string(stepPath), Int32(faceID),
                                            mask.rawValue, Int32(depthVoxels),
                                            Int32(resolution), &err)
        try throwIfFailed(err)
        return Int(n)
    }

    /// Persist the face-overrides sidecar next to `modelPath` (handoff
    /// 2026-07-24). `dihedralDeg <= 0` and `coneDeg < 0` mean "leave the core
    /// default"; `paintFaces` is one triangle-index set per painted pseudo-face.
    /// An all-default/empty call DELETES the sidecar (a cleared paint state must
    /// not leave a stale file a re-import would resurrect). After this, every
    /// import of `modelPath` — the viewer, live tagging, the run — reproduces the
    /// tuned threshold and the painted faces.
    public static func writeFaceOverrides(modelPath: String,
                                          dihedralDeg: Double = 0,
                                          coneDeg: Double = -1,
                                          paintFaces: [[Int32]] = []) throws {
        var input = topoptbridge.FaceOverridesInput()
        input.dihedral_deg = dihedralDeg
        input.cone_deg = coneDeg
        for face in paintFaces {
            input.paint_sizes.push_back(Int32(face.count))
            for t in face { input.paint_indices.push_back(t) }
        }
        var err = topoptbridge.BridgeError()
        topoptbridge.write_face_overrides(std.string(modelPath), input, &err)
        try throwIfFailed(err)
    }

    // Non-capturing C trampolines reaching the boxed Swift closures via ctx.
    private static let progressTrampoline: topoptbridge.ProgressFn = { ctxPtr, rung, count, iter in
        guard let ctxPtr else { return }
        let b = Unmanaged<ProgressBox>.fromOpaque(ctxPtr).takeUnretainedValue()
        if !b.callback(Int(rung), Int(count), Int(iter)) { b.cancelFlag.pointee = true }
    }
    private static let variantTrampoline: topoptbridge.VariantFn = { ctxPtr, partialPtr in
        guard let ctxPtr, let partialPtr else { return }
        let b = Unmanaged<VariantBox>.fromOpaque(ctxPtr).takeUnretainedValue()
        b.callback(TopOptKit.convertOutcome(partialPtr.pointee))
    }

    /// Run a bridge optimize with optional progress + per-variant streaming,
    /// keeping the closure boxes alive across the (synchronous) call. `body`
    /// receives the C fn-ptrs + ctx to forward to the bridge.
    private static func withRunCallbacks<T>(
        progress: ((Int, Int, Int) -> Bool)?, onVariant: ((OptimizeOutcome) -> Void)?,
        cancelFlag: UnsafeMutablePointer<Bool>,
        _ body: (topoptbridge.ProgressFn?, UnsafeMutableRawPointer?,
                 topoptbridge.VariantFn?, UnsafeMutableRawPointer?) -> T
    ) -> T {
        let pBox = progress.map { ProgressBox($0, cancelFlag) }
        let vBox = onVariant.map { VariantBox($0) }
        let r = body(pBox == nil ? nil : progressTrampoline,
                     pBox.map { Unmanaged.passUnretained($0).toOpaque() },
                     vBox == nil ? nil : variantTrampoline,
                     vBox.map { Unmanaged.passUnretained($0).toOpaque() })
        withExtendedLifetime(pBox) {}
        withExtendedLifetime(vBox) {}
        return r
    }

    /// Run minimize_plastic (ROADMAP M5.3) with M7.0a progress + cancellation, and
    /// optional progressive-results streaming: `onVariant` fires once per accepted
    /// variant as it completes, with a one-variant partial outcome (variant + grid).
    /// `progress` returns `true` to continue or `false` to request cancellation.
    public static func minimizePlastic(
        stlPath: String, material: String, materialsPath: String, rulesPath: String,
        resolution: Int,
        progress: ((_ rung: Int, _ rungCount: Int, _ iteration: Int) -> Bool)? = nil,
        onVariant: ((OptimizeOutcome) -> Void)? = nil
    ) throws -> OptimizeOutcome {
        let cancelFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        cancelFlag.initialize(to: false)
        defer { cancelFlag.deinitialize(count: 1); cancelFlag.deallocate() }

        var err = topoptbridge.BridgeError()
        let raw = withRunCallbacks(progress: progress, onVariant: onVariant,
                                   cancelFlag: cancelFlag) { pFn, pCtx, vFn, vCtx in
            topoptbridge.run_minimize_plastic(
                std.string(stlPath), std.string(material), std.string(materialsPath),
                std.string(rulesPath), Int32(resolution), pFn, pCtx, cancelFlag,
                vFn, vCtx, &err)
        }
        try throwIfFailed(err)
        return convertOutcome(raw)
    }

    /// A user load group for `minimizePlasticLoadCase`: the B-rep faces it covers
    /// and the total force (newtons) applied over them (the M7.6 UI's direction ×
    /// weight). The force is spread as a distributed traction over the faces.
    public struct LoadGroupSpec: Equatable, Sendable {
        public let faceIDs: [Int]
        public let force: SIMD3<Double>
        public init(faceIDs: [Int], force: SIMD3<Double>) {
            self.faceIDs = faceIDs
            self.force = force
        }
    }

    /// Run minimize_plastic under the user's DECLARED load case (ARCHITECTURE §1
    /// mode (a)) — the app's tagged anchors/loads — instead of self-weight, so the
    /// reported margins/stresses reflect the forces the user set. `minimizePlastic`
    /// on → the material-reduction ladder; off → one conservative variant.
    /// STEP-only (needs OCCT face selection). Same M7.0a progress/cancel contract.
    /// - Parameter infillPercent: the M7.params user infill-density override (0–100),
    ///   or < 0 for "no override". Threaded to the core through
    ///   `BridgeLoadCase.infill_percent` for the M7.infill-margin ladder knockdown.
    /// Which keep-out volume a "Keep clear" clearance builds (handoff 100).
    public enum ClearanceKind: Int, Equatable, Sendable, Codable {
        case bolt = 0  // swept cylinder about a bore's axis
        case face = 1  // bounded slab in front of a planar face
    }

    /// A "Keep clear" clearance region for `minimizePlasticLoadCase`: a B-rep face
    /// id + kind + the editable clearance distances (mm). The app ships ONLY these;
    /// the bridge/core re-read the exact bore axis/radius or plane normal from the
    /// STEP. A distance left at 0 means "use the core's geometry-derived suggestion"
    /// (for a bolt that is the bore radius / diameter). Empty list → byte-identical.
    public struct ClearanceSpec: Equatable, Sendable {
        public let faceID: Int
        public let kind: ClearanceKind
        public let concentricMarginMM: Double
        public let axialClearanceMM: Double
        public let slabDepthMM: Double
        /// MANUAL (user-placed) primitive geometry (handoff group-editing). `nil`
        /// for an auto face (geometry re-read from the STEP via `faceID`);
        /// populated for a hand-placed primitive that has no B-rep face, so its
        /// axis/radius/normal/extent must travel to the core. When set, `faceID`
        /// is a sentinel (`-1`) and the same distance fields above still apply.
        public let manual: ManualGeometry?
        public init(faceID: Int, kind: ClearanceKind, concentricMarginMM: Double = 0,
                    axialClearanceMM: Double = 0, slabDepthMM: Double = 0,
                    manual: ManualGeometry? = nil) {
            self.faceID = faceID
            self.kind = kind
            self.concentricMarginMM = concentricMarginMM
            self.axialClearanceMM = axialClearanceMM
            self.slabDepthMM = slabDepthMM
            self.manual = manual
        }

        /// A hand-placed swept-cylinder (bolt) keep-out, geometry supplied inline.
        public static func manualBolt(
            axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>, radiusMM: Double,
            halfLengthMM: Double, concentricMarginMM: Double = 0,
            axialClearanceMM: Double = 0
        ) -> ClearanceSpec {
            ClearanceSpec(faceID: -1, kind: .bolt,
                          concentricMarginMM: concentricMarginMM,
                          axialClearanceMM: axialClearanceMM,
                          manual: ManualGeometry(axisPoint: axisPoint, axisDir: axisDir,
                                                 radiusMM: radiusMM, halfLengthMM: halfLengthMM))
        }

        /// A hand-placed bounded-slab (face) keep-out, geometry supplied inline.
        public static func manualFace(
            origin: SIMD3<Double>, normal: SIMD3<Double>, halfUMM: Double,
            halfWMM: Double, slabDepthMM: Double = 0
        ) -> ClearanceSpec {
            ClearanceSpec(faceID: -1, kind: .face, slabDepthMM: slabDepthMM,
                          manual: ManualGeometry(origin: origin, normal: normal,
                                                 halfUMM: halfUMM, halfWMM: halfWMM))
        }
    }

    /// Manual (user-placed) primitive geometry — the values the user supplies
    /// because a hand-placed keep-out has no B-rep face to derive them from
    /// (handoff group-editing). The kind-appropriate half is read: bolt reads
    /// axisPoint/axisDir/radiusMM/halfLengthMM; face reads origin/normal/halfU/halfW.
    /// Same model/voxel frame + mm units as the geometry the core re-reads from the
    /// STEP, so a manual and an auto primitive of identical geometry produce an
    /// identical mask (BAR B2).
    public struct ManualGeometry: Equatable, Sendable {
        public var axisPoint: SIMD3<Double> = .zero
        public var axisDir: SIMD3<Double> = .zero
        public var radiusMM: Double = 0
        public var halfLengthMM: Double = 0
        public var origin: SIMD3<Double> = .zero
        public var normal: SIMD3<Double> = .zero
        public var halfUMM: Double = 0
        public var halfWMM: Double = 0
        public init(axisPoint: SIMD3<Double> = .zero, axisDir: SIMD3<Double> = .zero,
                    radiusMM: Double = 0, halfLengthMM: Double = 0,
                    origin: SIMD3<Double> = .zero, normal: SIMD3<Double> = .zero,
                    halfUMM: Double = 0, halfWMM: Double = 0) {
            self.axisPoint = axisPoint
            self.axisDir = axisDir
            self.radiusMM = radiusMM
            self.halfLengthMM = halfLengthMM
            self.origin = origin
            self.normal = normal
            self.halfUMM = halfUMM
            self.halfWMM = halfWMM
        }
    }

    /// A design box / keep-out box for `minimizePlasticLoadCase`: an axis-aligned
    /// volume in MODEL space (mm) — the same frame as the mesh and the load faces.
    /// `min` must be <= `max` componentwise (the caller enforces this).
    public struct DesignBoxSpec: Equatable, Sendable {
        public let min: SIMD3<Double>
        public let max: SIMD3<Double>
        public init(min: SIMD3<Double>, max: SIMD3<Double>) {
            self.min = min
            self.max = max
        }
    }

    /// The wall-loop count the on-device bridge load case carries to core for the
    /// width-aware knockdown, given the project's Print-Parameters wall-loop override.
    /// Isolated as ONE mapping (the identity `Int32(wallLoops)`) so the CLI/bridge
    /// parity test can assert the on-device serializer and the LAN `buildJobJSON` emit
    /// the SAME value for one project without importing the C++ POD. `minimizePlasticLoadCase`
    /// sets `BridgeLoadCase.wall_loops` from THIS, so the asserted value and the value
    /// the bridge actually sends can never drift — this is the bridge/CLI-divergence
    /// class knockdown_spec_for already fixed once (handoff 2026-07-27-post-merge-build-fix).
    public static func bridgeWallLoops(forOverride wallLoops: Int) -> Int32 {
        Int32(wallLoops)
    }

    /// The INNER / OUTER wall LINE WIDTHS (mm) the on-device bridge load case carries to
    /// core for the width-aware knockdown's wall-ring term t = outer + (loops-1)·inner
    /// (handoff line-width-plumbing). These are BEAD widths, not the nozzle diameter. A
    /// value <= 0 is the "unset" sentinel the bridge/CLI both leave at the core default
    /// (inner → 0.45 mm, outer → mirror inner). Isolated as ONE mapping each (a Double
    /// identity) so the CLI/bridge parity test can assert `buildJobJSON`'s `loads.*` and
    /// this serializer's `BridgeLoadCase.*` are the SAME value for one project —
    /// `minimizePlasticLoadCase` sets the POD from THESE, so the asserted value and the
    /// value the bridge sends can never drift (the divergence class the wall-loops parity
    /// test guards).
    public static func bridgeWallLineWidthMM(forOverride widthMM: Double) -> Double {
        widthMM
    }
    public static func bridgeWallLineWidthOuterMM(forOverride widthMM: Double) -> Double {
        widthMM
    }

    public static func minimizePlasticLoadCase(
        stepPath: String, material: String, materialsPath: String, rulesPath: String,
        resolution: Int, anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        minimizePlastic: Bool, buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
        plateDirection: SIMD3<Double> = SIMD3(0, 0, 0),
        wantsOrientationRanking: Bool = false,
        infillPercent: Int = -1, wallLoops: Int = 0,
        wallLineWidthInnerMM: Double = -1, wallLineWidthOuterMM: Double = -1,
        designBox: DesignBoxSpec? = nil, keepOutBoxes: [DesignBoxSpec] = [],
        clearances: [ClearanceSpec] = [],
        faceProtections: [Int] = [], faceProtectionDepthMM: Double = -1,
        progress: ((_ rung: Int, _ rungCount: Int, _ iteration: Int) -> Bool)? = nil,
        onVariant: ((OptimizeOutcome) -> Void)? = nil
    ) throws -> OptimizeOutcome {
        var lc = topoptbridge.BridgeLoadCase()
        for f in anchorFaceIDs { lc.anchor_face_ids.push_back(Int32(f)) }
        for g in loadGroups {
            for f in g.faceIDs { lc.load_face_ids.push_back(Int32(f)) }
            lc.load_group_sizes.push_back(Int32(g.faceIDs.count))
            lc.load_forces.push_back(g.force.x)
            lc.load_forces.push_back(g.force.y)
            lc.load_forces.push_back(g.force.z)
        }
        // Handoff 100 — flatten the "Keep clear" clearances into the POD load case.
        // Handoff group-editing — a MANUAL primitive additionally ships its inline
        // geometry (stride-3 point arrays); an auto primitive leaves the manual
        // flag 0 and the geometry slots default (ignored core-side). All-auto =>
        // byte-identical POD to before (BAR B4).
        for c in clearances {
            lc.clearance_face_ids.push_back(Int32(c.faceID))
            lc.clearance_kinds.push_back(Int32(c.kind.rawValue))
            lc.clearance_margin_mm.push_back(c.concentricMarginMM)
            lc.clearance_axial_mm.push_back(c.axialClearanceMM)
            lc.clearance_slab_mm.push_back(c.slabDepthMM)
            let m = c.manual
            lc.clearance_manual.push_back(m == nil ? 0 : 1)
            let g = m ?? ManualGeometry()
            for v in [g.axisPoint.x, g.axisPoint.y, g.axisPoint.z] { lc.clearance_axis_point_xyz.push_back(v) }
            for v in [g.axisDir.x, g.axisDir.y, g.axisDir.z] { lc.clearance_axis_dir_xyz.push_back(v) }
            lc.clearance_radius_mm.push_back(g.radiusMM)
            lc.clearance_half_len_mm.push_back(g.halfLengthMM)
            for v in [g.origin.x, g.origin.y, g.origin.z] { lc.clearance_origin_xyz.push_back(v) }
            for v in [g.normal.x, g.normal.y, g.normal.z] { lc.clearance_normal_xyz.push_back(v) }
            lc.clearance_half_u_mm.push_back(g.halfUMM)
            lc.clearance_half_w_mm.push_back(g.halfWMM)
        }
        // Handoff 124 — flatten the Face protections (preserve-skin) into the POD
        // load case: the raw face ids + the ONE global depth (mm). A depth <= 0
        // means "use the core default". Empty list → byte-identical.
        for f in faceProtections { lc.face_protection_face_ids.push_back(Int32(f)) }
        lc.face_protection_depth_mm = faceProtectionDepthMM
        lc.minimize_plastic = minimizePlastic
        lc.build_dir_x = buildDirection.x
        lc.build_dir_y = buildDirection.y
        lc.build_dir_z = buildDirection.z
        // The build-plate normal as its OWN input (handoff 2026-08-01-build-
        // direction-separation). ZERO => nothing declared => the core's documented
        // gravity fallback => byte-identical to before this field existed.
        lc.plate_dir_x = plateDirection.x
        lc.plate_dir_y = plateDirection.y
        lc.plate_dir_z = plateDirection.z
        lc.build_orientation_report = wantsOrientationRanking
        lc.infill_percent = Int32(infillPercent)
        // Width-aware knockdown wall metadata (handoff 2026-07-27-wall-loops-plumbing +
        // line-width-plumbing). The user's wall-loop count and inner/outer line widths,
        // via the SAME mappings the CLI/bridge parity test asserts against. Consumed only
        // when the width-aware gate is armed, so this is byte-identical to the pre-plumbing
        // run today. A negative width is the "unset" sentinel the bridge leaves at the core
        // default (inner 0.45 mm, outer mirrors inner).
        lc.wall_loops = bridgeWallLoops(forOverride: wallLoops)
        lc.wall_line_width_mm = bridgeWallLineWidthMM(forOverride: wallLineWidthInnerMM)
        lc.wall_line_width_outer_mm =
            bridgeWallLineWidthOuterMM(forOverride: wallLineWidthOuterMM)

        // M7.dom-app: the optional design-domain expansion. Unset → has_design_box
        // stays false and the run is byte-identical to a no-box run (default off).
        if let box = designBox {
            lc.has_design_box = true
            lc.design_box_min_x = box.min.x
            lc.design_box_min_y = box.min.y
            lc.design_box_min_z = box.min.z
            lc.design_box_max_x = box.max.x
            lc.design_box_max_y = box.max.y
            lc.design_box_max_z = box.max.z
            for ko in keepOutBoxes {
                lc.keep_out_min.push_back(ko.min.x)
                lc.keep_out_min.push_back(ko.min.y)
                lc.keep_out_min.push_back(ko.min.z)
                lc.keep_out_max.push_back(ko.max.x)
                lc.keep_out_max.push_back(ko.max.y)
                lc.keep_out_max.push_back(ko.max.z)
            }
        }

        let cancelFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        cancelFlag.initialize(to: false)
        defer { cancelFlag.deinitialize(count: 1); cancelFlag.deallocate() }

        var err = topoptbridge.BridgeError()
        let raw = withRunCallbacks(progress: progress, onVariant: onVariant,
                                   cancelFlag: cancelFlag) { pFn, pCtx, vFn, vCtx in
            topoptbridge.run_minimize_plastic_loadcase(
                std.string(stepPath), std.string(material), std.string(materialsPath),
                std.string(rulesPath), Int32(resolution), lc, pFn, pCtx, cancelFlag,
                vFn, vCtx, &err)
        }
        try throwIfFailed(err)
        return convertOutcome(raw)
    }

    /// Rebuild the per-variant playback keyframe meshes from the bridge's flattened
    /// scalar vectors (one KeyframeMesh per captured frame, in order).
    private static func reconstructKeyframes(_ v: topoptbridge.OptimizeVariant) -> [KeyframeMesh] {
        let kv = Array(v.keyframe_vertices)
        let kvc = Array(v.keyframe_vertex_counts)
        let ki = Array(v.keyframe_indices)
        let kic = Array(v.keyframe_index_counts)
        var out: [KeyframeMesh] = []
        out.reserveCapacity(kvc.count)
        var vOff = 0, iOff = 0
        for f in 0..<kvc.count {
            let vc = Int(kvc[f])
            let ic = f < kic.count ? Int(kic[f]) : 0
            let vLo = vOff * 3, vHi = (vOff + vc) * 3
            let verts = (vLo <= vHi && vHi <= kv.count) ? Array(kv[vLo..<vHi]) : []
            let inds = (iOff <= iOff + ic && iOff + ic <= ki.count) ? Array(ki[iOff..<(iOff + ic)]) : []
            out.append(KeyframeMesh(vertices: verts, indices: inds))
            vOff += vc; iOff += ic
        }
        return out
    }

    /// Map the bridge's OptimizeResult to the Swift outcome (shared by both run
    /// entry points — mirrors the C++ `to_optimize_result` helper).
    private static func convertOutcome(_ raw: topoptbridge.OptimizeResult) -> OptimizeOutcome {
        var variants: [OptimizeVariant] = []
        for v in raw.variants {
            variants.append(OptimizeVariant(
                requestedVolumeFraction: v.requested_volume_fraction,
                achievedVolumeFraction: v.achieved_volume_fraction,
                printedFraction: v.printed_fraction,
                massGrams: v.mass_grams,
                supportVolumeVoxels: Int(v.support_volume_voxels),
                meshTriangleCount: Int(v.mesh_triangle_count),
                worstCaseMargin: v.worst_case_margin,
                accepted: v.accepted,
                v3Passes: v.v3_passes,
                minFeatureViolations: Int(v.min_feature_violations),
                minFeatureWarning: String(v.min_feature_warning),
                orientation: SIMD3<Double>(v.orientation_x, v.orientation_y, v.orientation_z),
                maxStressMPa: v.max_stress_mpa,
                maxInterlayerTensionMPa: v.max_interlayer_tension_mpa,
                inPlaneMargin: v.in_plane_margin,
                interlayerMargin: v.interlayer_margin,
                meshVertices: Array(v.mesh_vertices),
                meshIndices: Array(v.mesh_indices),
                vonMisesField: Array(v.von_mises_field),
                displacementField: Array(v.displacement_field),
                stressTensorField: Array(v.stress_tensor_field),
                keyframeMeshes: reconstructKeyframes(v),
                // WHY this rung gated as it did — the core's own diagnosis object
                // (handoff 2026-08-02-gate-diagnosis-recommendations). nil when the
                // run did not arm it, which is every pre-diagnosis run.
                diagnosis: GateDiagnosis.decode(json: String(v.diagnosis_json)),
                // WHERE THIS RUNG'S PLASTIC IS (task 2026-08-03-growth-ladder).
                // nil on a reduction run — the core never measured it, and a
                // zeroed struct would read as "nothing was added" rather than
                // "this was never asked".
                addedMaterial: v.added_material_evaluated
                    ? AddedMaterial(
                        printedVoxels: Int(v.added_printed_voxels),
                        insidePart: Int(v.added_inside_part),
                        outsidePart: Int(v.added_outside_part),
                        partSolidVoxels: Int(v.added_part_solid_voxels),
                        outsideFraction: v.added_outside_fraction,
                        outsideVolumeMM3: v.added_outside_volume_mm3,
                        netAddedVolumeMM3: v.added_net_volume_mm3,
                        outsideMassGrams: v.added_outside_mass_grams,
                        netAddedMassGrams: v.added_net_mass_grams,
                        targetSaturated: v.growth_target_saturated)
                    : nil))
        }
        // Handoff 100 — the clearance diagnostics (parallel arrays), for honest results.
        let cFaces = Array(raw.clearance_face_ids)
        let cKinds = Array(raw.clearance_kinds)
        let cFrozen = Array(raw.clearance_voxels_frozen)
        let cInGrid = Array(raw.clearance_in_grid)
        var applied: [AppliedClearance] = []
        for i in 0..<cFaces.count {
            applied.append(AppliedClearance(
                faceID: Int(cFaces[i]),
                kind: (i < cKinds.count && cKinds[i] == 1) ? .face : .bolt,
                voxelsFrozen: i < cFrozen.count ? Int(cFrozen[i]) : 0,
                inGrid: i < cInGrid.count ? cInGrid[i] != 0 : false))
        }
        // Handoff 124 — the Face-protection diagnostics (parallel arrays), for honest results.
        let pFaces = Array(raw.protection_face_ids)
        let pFrozen = Array(raw.protection_voxels_frozen)
        let pDepth = Array(raw.protection_depth_voxels)
        let pThin = Array(raw.protection_thinner)
        var protections: [AppliedFaceProtection] = []
        for i in 0..<pFaces.count {
            protections.append(AppliedFaceProtection(
                faceID: Int(pFaces[i]),
                voxelsFrozen: i < pFrozen.count ? Int(pFrozen[i]) : 0,
                depthVoxels: i < pDepth.count ? Int(pDepth[i]) : 0,
                thinnerThanDepth: i < pThin.count ? pThin[i] != 0 : false))
        }
        return OptimizeOutcome(variants: variants,
                               stoppedOnMargin: raw.stopped_on_margin,
                               cancelled: raw.cancelled,
                               acceptedCount: Int(raw.accepted_count),
                               voxelVolumeMM3: raw.voxel_volume_mm3,
                               gridNx: Int(raw.grid_nx), gridNy: Int(raw.grid_ny),
                               gridNz: Int(raw.grid_nz),
                               gridOrigin: SIMD3<Double>(raw.grid_origin_x, raw.grid_origin_y, raw.grid_origin_z),
                               spacing: raw.spacing,
                               appliedClearances: applied,
                               appliedFaceProtections: protections,
                               // The build-orientation receipt the core emitted for
                               // the recommended rung (handoff 2026-08-01-build-
                               // direction-separation). Empty string => the ranking
                               // was not armed => nil, and nothing changes.
                               buildOrientationJSON: {
                                   let s = String(raw.build_orientation_json)
                                   return s.isEmpty ? nil : Data(s.utf8)
                               }(),
                               // WHICH LADDER RAN (task 2026-08-03-growth-ladder) —
                               // the core's own flag, so the results screen names
                               // the mode instead of inferring it.
                               growthLadder: raw.growth_ladder)
    }

    /// The M7.1 smoke summary shared by the app's smoke screen and the tests.
    public static func smoke(materialsPath: String, meshPath: String) throws -> SmokeResult {
        let r = topoptbridge.bridge_smoke(std.string(materialsPath), std.string(meshPath))
        if !r.ok { throw TopOptError(message: String(r.message)) }
        return SmokeResult(materialCount: Int(r.material_count),
                           triangleCount: Int(r.triangle_count),
                           watertight: r.watertight)
    }

    // MARK: - internals

    private static func convert(_ raw: topoptbridge.ImportedMesh) -> ImportedMesh {
        ImportedMesh(vertices: Array(raw.vertices),
                     indices: Array(raw.indices),
                     faceIDs: Array(raw.face_ids),
                     vertexCount: Int(raw.vertex_count),
                     triangleCount: Int(raw.triangle_count),
                     faceCount: Int(raw.face_count),
                     watertight: raw.watertight,
                     faceGeometry: convertFaceGeometry(raw),
                     pseudoFaces: raw.pseudo_faces)
    }

    /// Rebuild the per-face geometry (keep-clear v2) from the bridge's flat arrays
    /// (kinds size faceCount, vec3 fields 3×faceCount). Empty for STL. Defensive on
    /// length so a short/absent array degrades to `.other` rather than crashing.
    private static func convertFaceGeometry(_ raw: topoptbridge.ImportedMesh) -> [StepFaceGeometry] {
        let count = Int(raw.face_count)
        guard count > 0, raw.face_kinds.count == count else { return [] }
        let kinds = Array(raw.face_kinds)
        let radius = Array(raw.face_cyl_radius)
        let axisPt = Array(raw.face_axis_point)
        let axisDr = Array(raw.face_axis_dir)
        let planeN = Array(raw.face_plane_normal)
        let planeO = Array(raw.face_plane_origin)
        func vec3(_ a: [Double], _ f: Int) -> SIMD3<Double> {
            let b = f * 3
            guard b + 2 < a.count else { return .zero }
            return SIMD3<Double>(a[b], a[b + 1], a[b + 2])
        }
        var out: [StepFaceGeometry] = []
        out.reserveCapacity(count)
        for f in 0..<count {
            let kind = StepFaceGeometry.Kind(rawValue: Int(kinds[f])) ?? .other
            out.append(StepFaceGeometry(
                kind: kind,
                cylinderRadiusMM: f < radius.count ? radius[f] : 0,
                axisPoint: vec3(axisPt, f), axisDir: vec3(axisDr, f),
                planeNormal: vec3(planeN, f), planeOrigin: vec3(planeO, f)))
        }
        return out
    }

    private static func throwIfFailed(_ err: topoptbridge.BridgeError) throws {
        if !err.ok { throw TopOptError(message: String(err.message)) }
    }
}
