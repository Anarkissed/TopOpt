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
}

/// A voxel-grid summary (ROADMAP M1.5).
public struct VoxelSummary {
    public let nx: Int
    public let ny: Int
    public let nz: Int
    public let spacing: Double
    public let solidVoxels: Int
}

/// One evaluated volume-fraction rung of a minimize_plastic run.
public struct OptimizeVariant {
    public let requestedVolumeFraction: Double
    public let achievedVolumeFraction: Double
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

    public init(requestedVolumeFraction: Double, achievedVolumeFraction: Double,
                massGrams: Double, supportVolumeVoxels: Int, meshTriangleCount: Int,
                worstCaseMargin: Double, accepted: Bool, v3Passes: Bool,
                minFeatureViolations: Int = 0, minFeatureWarning: String = "",
                orientation: SIMD3<Double> = .zero, maxStressMPa: Double = 0,
                maxInterlayerTensionMPa: Double = 0, inPlaneMargin: Double = 0,
                interlayerMargin: Double = 0, meshVertices: [Float] = [],
                meshIndices: [Int32] = [], vonMisesField: [Float] = []) {
        self.requestedVolumeFraction = requestedVolumeFraction
        self.achievedVolumeFraction = achievedVolumeFraction
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

    public init(variants: [OptimizeVariant], stoppedOnMargin: Bool,
                cancelled: Bool, acceptedCount: Int, voxelVolumeMM3: Double = 0,
                gridNx: Int = 0, gridNy: Int = 0, gridNz: Int = 0,
                gridOrigin: SIMD3<Double> = .zero, spacing: Double = 0) {
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

    /// Import an STL or STEP file (dispatched by extension) into a mesh.
    public static func importMesh(path: String,
                                  linearDeflectionMM: Double = 0) throws -> ImportedMesh {
        let lower = path.lowercased()
        var err = topoptbridge.BridgeError()
        let raw: topoptbridge.ImportedMesh
        if lower.hasSuffix(".step") || lower.hasSuffix(".stp") {
            raw = topoptbridge.import_step(std.string(path), linearDeflectionMM, &err)
        } else {
            raw = topoptbridge.import_stl(std.string(path), &err)
        }
        try throwIfFailed(err)
        return convert(raw)
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
    public static func minimizePlasticLoadCase(
        stepPath: String, material: String, materialsPath: String, rulesPath: String,
        resolution: Int, anchorFaceIDs: [Int], loadGroups: [LoadGroupSpec],
        minimizePlastic: Bool, buildDirection: SIMD3<Double> = SIMD3(0, 0, 1),
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
        lc.minimize_plastic = minimizePlastic
        lc.build_dir_x = buildDirection.x
        lc.build_dir_y = buildDirection.y
        lc.build_dir_z = buildDirection.z

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

    /// Map the bridge's OptimizeResult to the Swift outcome (shared by both run
    /// entry points — mirrors the C++ `to_optimize_result` helper).
    private static func convertOutcome(_ raw: topoptbridge.OptimizeResult) -> OptimizeOutcome {
        var variants: [OptimizeVariant] = []
        for v in raw.variants {
            variants.append(OptimizeVariant(
                requestedVolumeFraction: v.requested_volume_fraction,
                achievedVolumeFraction: v.achieved_volume_fraction,
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
                vonMisesField: Array(v.von_mises_field)))
        }
        return OptimizeOutcome(variants: variants,
                               stoppedOnMargin: raw.stopped_on_margin,
                               cancelled: raw.cancelled,
                               acceptedCount: Int(raw.accepted_count),
                               voxelVolumeMM3: raw.voxel_volume_mm3,
                               gridNx: Int(raw.grid_nx), gridNy: Int(raw.grid_ny),
                               gridNz: Int(raw.grid_nz),
                               gridOrigin: SIMD3<Double>(raw.grid_origin_x, raw.grid_origin_y, raw.grid_origin_z),
                               spacing: raw.spacing)
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
                     watertight: raw.watertight)
    }

    private static func throwIfFailed(_ err: topoptbridge.BridgeError) throws {
        if !err.ok { throw TopOptError(message: String(err.message)) }
    }
}
