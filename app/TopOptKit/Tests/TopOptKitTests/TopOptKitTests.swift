// Headless macOS unit tests for the TopOptKit Swift/C++ bridge (ROADMAP M7.1).
// These are the M7 verification standard for /app/ core-bridge code: `xcodebuild
// test` on this package, run on the maintainer's Mac (raw output in the handoff)
// — /app/ is not covered by Linux CI. They exercise the wrapper end to end
// against the committed core fixtures, so they would fail if the bridge returned
// stubbed data or the wiring to the core were broken.
import XCTest
import simd
@testable import TopOptKit

final class TopOptKitTests: XCTestCase {

    // Repo paths resolved from this source file: .../app/TopOptKit/Tests/
    // TopOptKitTests/TopOptKitTests.swift -> up 5 -> repo root.
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()
    private static func core(_ rel: String) -> String {
        repoRoot.appendingPathComponent("core/\(rel)").path
    }
    private static var materialsPath: String { core("src/materials/materials.json") }
    private static var rulesPath: String { core("src/settings/rules.json") }
    private static var cubeSTL: String { core("tests/fixtures/stl/cube_10mm.stl") }
    private static var brokenSTL: String { core("tests/fixtures/stl/broken_open_cube.stl") }
    private static var lbracketSTEP: String { core("tests/fixtures/demo/l-bracket.step") }

    // MARK: liveness

    func testCoreVersionNonEmpty() {
        XCTAssertFalse(TopOptKit.coreVersion.isEmpty)
    }

    // MARK: materials

    func testLoadMaterials() throws {
        let mats = try TopOptKit.loadMaterials(path: Self.materialsPath)
        XCTAssertEqual(mats.count, 12)
        let pla = try XCTUnwrap(mats.first { $0.name == "PLA" })
        XCTAssertEqual(pla.youngsModulusMPa, 3500)
        XCTAssertEqual(pla.family, "fdm")
        XCTAssertTrue(mats.contains { $0.name == "Resin_Standard" && $0.family == "resin" })
        // Deterministic (name-sorted) order from the core.
        XCTAssertEqual(mats.map(\.name), mats.map(\.name).sorted())
    }

    func testLoadMaterialsMissingFileThrows() {
        XCTAssertThrowsError(try TopOptKit.loadMaterials(path: "/no/such/materials.json"))
    }

    // MARK: import

    func testImportCubeSTL() throws {
        let mesh = try TopOptKit.importMesh(path: Self.cubeSTL)
        XCTAssertEqual(mesh.triangleCount, 12)   // a box is 12 triangles
        XCTAssertEqual(mesh.vertexCount, 8)      // welded to 8 corners
        XCTAssertEqual(mesh.indices.count, mesh.triangleCount * 3)
        XCTAssertEqual(mesh.vertices.count, mesh.vertexCount * 3)
        XCTAssertTrue(mesh.watertight)
        XCTAssertTrue(mesh.faceIDs.isEmpty)      // STL has no B-rep faces
    }

    func testImportBrokenSTLReportsNotWatertight() throws {
        // read path does not enforce watertightness; the flag exposes it so the
        // app can warn (M7.3). Geometry still parses.
        let mesh = try TopOptKit.importMesh(path: Self.brokenSTL)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        XCTAssertFalse(mesh.watertight)
    }

    func testImportMissingFileThrows() {
        XCTAssertThrowsError(try TopOptKit.importMesh(path: "/no/such/part.stl")) { err in
            XCTAssertFalse("\(err)".isEmpty)  // carries a core diagnostic
        }
    }

    func testImportStepFaces() throws {
        let mesh = try TopOptKit.importMesh(path: Self.lbracketSTEP)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        XCTAssertGreaterThan(mesh.faceCount, 0)
        // One face id per triangle for STEP.
        XCTAssertEqual(mesh.faceIDs.count, mesh.triangleCount)
        XCTAssertTrue(mesh.faceIDs.allSatisfy { $0 >= 0 && Int($0) < mesh.faceCount })
    }

    // MARK: voxelize

    func testVoxelizeCube() throws {
        let s = try TopOptKit.voxelize(meshPath: Self.cubeSTL, resolution: 8)
        XCTAssertEqual(max(s.nx, max(s.ny, s.nz)), 8)  // longest axis == resolution
        XCTAssertGreaterThan(s.solidVoxels, 0)
        XCTAssertGreaterThan(s.spacing, 0)
    }

    func testVoxelizeBadResolutionThrows() {
        XCTAssertThrowsError(try TopOptKit.voxelize(meshPath: Self.cubeSTL, resolution: 0))
    }

    // MARK: face tagging

    func testTagStepFace() throws {
        let mesh = try TopOptKit.importMesh(path: Self.lbracketSTEP)
        // Sum tagged voxels over all faces: at a usable resolution the boundary
        // slabs are non-empty, so at least one face tags voxels (exercises the
        // tag_step_face plumbing M7.5 drives).
        var total = 0
        for f in 0..<mesh.faceCount {
            total += try TopOptKit.tagStepFace(stepPath: Self.lbracketSTEP,
                                               faceID: f, asFixture: true, resolution: 24)
        }
        XCTAssertGreaterThan(total, 0)
    }

    func testTagStepFaceOutOfRangeThrows() {
        XCTAssertThrowsError(try TopOptKit.tagStepFace(stepPath: Self.lbracketSTEP,
                                                       faceID: 100000, asFixture: true,
                                                       resolution: 12))
    }

    func testMaskStepFace() throws {
        let mesh = try TopOptKit.importMesh(path: Self.lbracketSTEP)
        // At a usable resolution some face's boundary slab is non-empty, so a
        // depth-1 FrozenSolid mask over the faces marks voxels (exercises the
        // mask_step_face bridge M7.6-app freezes load/anchor shells through).
        var depth1 = 0
        for f in 0..<mesh.faceCount {
            depth1 += try TopOptKit.maskStepFace(stepPath: Self.lbracketSTEP,
                                                 faceID: f, mask: .frozenSolid,
                                                 depthVoxels: 1, resolution: 24)
        }
        XCTAssertGreaterThan(depth1, 0)

        // A single face masked to depth 2 covers at least as many voxels as
        // depth 1 (the deeper slab is a superset), and is > 0 for some face.
        var deeperFound = false
        for f in 0..<mesh.faceCount {
            let d1 = try TopOptKit.maskStepFace(stepPath: Self.lbracketSTEP,
                                                faceID: f, mask: .frozenVoid,
                                                depthVoxels: 1, resolution: 24)
            let d2 = try TopOptKit.maskStepFace(stepPath: Self.lbracketSTEP,
                                                faceID: f, mask: .frozenVoid,
                                                depthVoxels: 2, resolution: 24)
            XCTAssertGreaterThanOrEqual(d2, d1)
            if d2 > 0 { deeperFound = true }
        }
        XCTAssertTrue(deeperFound)
    }

    func testMaskStepFaceOutOfRangeThrows() {
        XCTAssertThrowsError(try TopOptKit.maskStepFace(stepPath: Self.lbracketSTEP,
                                                        faceID: 100000, mask: .frozenSolid,
                                                        depthVoxels: 1, resolution: 12))
    }

    func testMaskStepFaceBadDepthThrows() {
        XCTAssertThrowsError(try TopOptKit.maskStepFace(stepPath: Self.lbracketSTEP,
                                                        faceID: 0, mask: .frozenSolid,
                                                        depthVoxels: 0, resolution: 12))
    }

    // MARK: export

    func testExportSTLRoundTrip() throws {
        let mesh = try TopOptKit.importMesh(path: Self.cubeSTL)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("topoptkit_cube_\(UUID().uuidString).stl").path
        defer { try? FileManager.default.removeItem(atPath: out) }
        try TopOptKit.exportSTL(mesh: mesh, to: out)
        let reimported = try TopOptKit.importMesh(path: out)
        XCTAssertEqual(reimported.triangleCount, 12)
        XCTAssertTrue(reimported.watertight)
    }

    // MARK: minimize_plastic (M5.3) + progress/cancel (M7.0a)

    func testMinimizePlasticWithProgress() throws {
        var invocations = 0
        var lastIterByRung: [Int: Int] = [:]
        var monotone = true
        let outcome = try TopOptKit.minimizePlastic(
            stlPath: Self.cubeSTL, material: "PLA",
            materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: 6
        ) { rung, rungCount, iteration in
            invocations += 1
            XCTAssertEqual(rungCount, 3)                 // default ladder [0.7,0.5,0.3]
            if let prev = lastIterByRung[rung], iteration != prev + 1 { monotone = false }
            lastIterByRung[rung] = iteration
            return true                                   // never cancel
        }
        XCTAssertGreaterThan(invocations, 0)
        XCTAssertTrue(monotone, "iteration numbers must be 1..N within a rung")
        XCTAssertFalse(outcome.cancelled)
        XCTAssertFalse(outcome.variants.isEmpty)
        for v in outcome.variants {
            XCTAssertGreaterThan(v.massGrams, 0)
            XCTAssertGreaterThanOrEqual(v.supportVolumeVoxels, 0)
            XCTAssertGreaterThan(v.meshTriangleCount, 0)
        }
        // accepted_count matches the accepted-prefix flags.
        XCTAssertEqual(outcome.acceptedCount, outcome.variants.filter(\.accepted).count)
    }

    // M7.8: the results-screen fields flow from the real bridge (VariantReport +
    // grid), not stubbed. Would fail if the bridge left them default-constructed.
    func testMinimizePlasticResultsFields() throws {
        let outcome = try TopOptKit.minimizePlastic(
            stlPath: Self.cubeSTL, material: "PLA",
            materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: 6)
        XCTAssertGreaterThan(outcome.voxelVolumeMM3, 0, "grid.voxel_volume() must flow")
        // Grid metadata + variant geometry/field flow (for the M7.8 viewer overlay).
        XCTAssertGreaterThan(outcome.gridNx, 0)
        XCTAssertGreaterThan(outcome.gridNy, 0)
        XCTAssertGreaterThan(outcome.gridNz, 0)
        XCTAssertGreaterThan(outcome.spacing, 0)
        let voxelCount = outcome.gridNx * outcome.gridNy * outcome.gridNz
        XCTAssertFalse(outcome.variants.isEmpty)
        for v in outcome.variants where v.accepted {
            XCTAssertFalse(v.meshVertices.isEmpty, "variant isosurface must flow")
            XCTAssertEqual(v.meshVertices.count % 3, 0)
            XCTAssertEqual(v.meshIndices.count % 3, 0)
            XCTAssertEqual(v.meshIndices.count, v.meshTriangleCount * 3)
            XCTAssertEqual(v.vonMisesField.count, voxelCount, "von Mises field is grid-indexed")
        }
        for v in outcome.variants {
            // Orientation is the M4.4 winning unit build direction — nonzero + finite.
            let len = simd_length(v.orientation)
            XCTAssertGreaterThan(len, 0.5, "orientation must be a real (unit) direction")
            XCTAssertTrue(v.orientation.x.isFinite && v.orientation.y.isFinite && v.orientation.z.isFinite)
            // Peak stresses are nonnegative + finite (self-weighted cube → loaded).
            XCTAssertGreaterThanOrEqual(v.maxStressMPa, 0)
            XCTAssertTrue(v.maxStressMPa.isFinite && v.maxInterlayerTensionMPa.isFinite)
            // Margins are positive + finite, and worst_case == min(in_plane, interlayer)
            // (the locked definition) — proves all three carry the same real numbers.
            XCTAssertGreaterThan(v.inPlaneMargin, 0)
            XCTAssertGreaterThan(v.interlayerMargin, 0)
            XCTAssertEqual(v.worstCaseMargin, min(v.inPlaneMargin, v.interlayerMargin), accuracy: 1e-6)
        }
    }

    func testMinimizePlasticCancel() throws {
        var invocations = 0
        let outcome = try TopOptKit.minimizePlastic(
            stlPath: Self.cubeSTL, material: "PLA",
            materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: 6
        ) { _, _, iteration in
            invocations += 1
            return iteration < 2   // request cancel once we reach iteration 2
        }
        XCTAssertTrue(outcome.cancelled)
        // Cancelled during rung 0: no full 3-rung ladder ran.
        XCTAssertLessThan(invocations, 60)
    }

    func testMinimizePlasticUnknownMaterialThrows() {
        XCTAssertThrowsError(try TopOptKit.minimizePlastic(
            stlPath: Self.cubeSTL, material: "NOPE",
            materialsPath: Self.materialsPath, rulesPath: Self.rulesPath,
            resolution: 6))
    }

    // MARK: smoke (the M7.1 deliverable summary)

    func testBridgeSmoke() throws {
        let smoke = try TopOptKit.smoke(materialsPath: Self.materialsPath, meshPath: Self.cubeSTL)
        XCTAssertEqual(smoke.materialCount, 12)
        XCTAssertEqual(smoke.triangleCount, 12)
        XCTAssertTrue(smoke.watertight)
        // Smoke summary agrees with the individual wrapper calls.
        let mats = try TopOptKit.loadMaterials(path: Self.materialsPath)
        let mesh = try TopOptKit.importMesh(path: Self.cubeSTL)
        XCTAssertEqual(smoke.materialCount, mats.count)
        XCTAssertEqual(smoke.triangleCount, mesh.triangleCount)
    }
}
