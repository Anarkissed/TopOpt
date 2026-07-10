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
}

/// The outcome of a minimize_plastic run (ROADMAP M5.3 / M7.7).
public struct OptimizeOutcome {
    public let variants: [OptimizeVariant]
    public let stoppedOnMargin: Bool
    public let cancelled: Bool
    public let acceptedCount: Int
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

    /// Run minimize_plastic (ROADMAP M5.3) with M7.0a progress + cancellation.
    /// The `progress` closure is invoked once per OC iteration of every rung; it
    /// returns `true` to continue or `false` to request cancellation.
    public static func minimizePlastic(
        stlPath: String, material: String, materialsPath: String, rulesPath: String,
        resolution: Int,
        progress: ((_ rung: Int, _ rungCount: Int, _ iteration: Int) -> Bool)? = nil
    ) throws -> OptimizeOutcome {
        let cancelFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        cancelFlag.initialize(to: false)
        defer { cancelFlag.deinitialize(count: 1); cancelFlag.deallocate() }

        var err = topoptbridge.BridgeError()
        var raw: topoptbridge.OptimizeResult
        if let progress {
            let box = ProgressBox(progress, cancelFlag)
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            let trampoline: topoptbridge.ProgressFn = { ctxPtr, rung, count, iter in
                guard let ctxPtr else { return }
                let b = Unmanaged<ProgressBox>.fromOpaque(ctxPtr).takeUnretainedValue()
                if !b.callback(Int(rung), Int(count), Int(iter)) {
                    b.cancelFlag.pointee = true
                }
            }
            raw = topoptbridge.run_minimize_plastic(
                std.string(stlPath), std.string(material), std.string(materialsPath),
                std.string(rulesPath), Int32(resolution), trampoline, ctx,
                cancelFlag, &err)
            withExtendedLifetime(box) {}
        } else {
            raw = topoptbridge.run_minimize_plastic(
                std.string(stlPath), std.string(material), std.string(materialsPath),
                std.string(rulesPath), Int32(resolution), nil, nil, cancelFlag, &err)
        }
        try throwIfFailed(err)

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
                v3Passes: v.v3_passes))
        }
        return OptimizeOutcome(variants: variants,
                               stoppedOnMargin: raw.stopped_on_margin,
                               cancelled: raw.cancelled,
                               acceptedCount: Int(raw.accepted_count))
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
