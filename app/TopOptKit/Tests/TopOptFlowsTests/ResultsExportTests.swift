// Headless tests for the results-screen EXPORT surface on ResultsModel: the
// export filename, the enabled/disabled gate, the STL bytes, and the honest
// mesh-vs-voxel mass comparison (Open #6 — the mass gap). The share-sheet
// presentation itself is device QA (the M7 /app/ standard); everything asserted
// here is pure model logic. Material density is injected so the test does not
// depend on a bundled materials.json.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class ResultsExportTests: XCTestCase {

    // An axis-aligned box mesh [0,s]³ (mm): watertight, volume s³ mm³.
    private func cubeMesh(_ s: Float) -> (verts: [Float], idx: [Int32]) {
        let v: [Float] = [
            0, 0, 0,  s, 0, 0,  s, s, 0,  0, s, 0,
            0, 0, s,  s, 0, s,  s, s, s,  0, s, s,
        ]
        let i: [Int32] = [
            0, 2, 1, 0, 3, 2,  4, 5, 6, 4, 6, 7,
            0, 1, 5, 0, 5, 4,  2, 3, 7, 2, 7, 6,
            0, 4, 7, 0, 7, 3,  1, 2, 6, 1, 6, 5,
        ]
        return (v, i)
    }

    private func meshedVariant(vf: Double, mass: Double, side: Float = 20,
                               verts: [Float]? = nil, idx: [Int32]? = nil) -> OptimizeVariant {
        let (cv, ci) = cubeMesh(side)
        return OptimizeVariant(
            requestedVolumeFraction: vf, achievedVolumeFraction: vf, massGrams: mass,
            supportVolumeVoxels: 0, meshTriangleCount: (idx ?? ci).count / 3,
            worstCaseMargin: 2, accepted: true, v3Passes: true,
            orientation: SIMD3(0, 0, 1), maxStressMPa: 10,
            meshVertices: verts ?? cv, meshIndices: idx ?? ci)
    }

    private func outcome(_ vs: [OptimizeVariant], remote: Bool = false) -> OptimizeOutcome {
        OptimizeOutcome(variants: vs, stoppedOnMargin: false, cancelled: false,
                        acceptedCount: vs.filter(\.accepted).count, voxelVolumeMM3: 1,
                        gridNx: 1, gridNy: 1, gridNz: 1, spacing: 1, computedRemotely: remote)
    }

    private func model(_ vs: [OptimizeVariant], project: String = "Bracket",
                       material: String = "PLA", density: Double? = 1.24,
                       remote: Bool = false) -> ResultsModel {
        ResultsModel(projectName: project, outcome: outcome(vs, remote: remote),
                     materialName: material, materialDensityGCm3: density)
    }

    // MARK: - Filename

    func testExportFilenameFormat() {
        let m = model([meshedVariant(vf: 0.7, mass: 10)])   // 30% savings
        XCTAssertEqual(m.exportFilename, "Bracket-PLA-30pct.stl")
    }

    func testExportFilenameSanitizesNames() {
        let m = model([meshedVariant(vf: 0.5, mass: 10)], project: "My Bracket! v2", material: "PLA")
        // Spaces/punctuation collapse to underscores; savings 50%.
        XCTAssertEqual(m.exportFilename, "My_Bracket_v2-PLA-50pct.stl")
    }

    func testFileTokenFallsBackWhenEmpty() {
        XCTAssertEqual(ResultsModel.fileToken("", fallback: "part"), "part")
        XCTAssertEqual(ResultsModel.fileToken("!!!", fallback: "material"), "material")
    }

    // MARK: - Enabled / disabled gate

    func testCanExportWithMesh() {
        XCTAssertTrue(model([meshedVariant(vf: 0.7, mass: 10)]).canExport)
    }

    func testCannotExportWithoutMesh() {
        let empty = OptimizeVariant(
            requestedVolumeFraction: 0.7, achievedVolumeFraction: 0.7, massGrams: 10,
            supportVolumeVoxels: 0, meshTriangleCount: 0, worstCaseMargin: 2,
            accepted: true, v3Passes: true)   // no mesh buffers
        let m = model([empty])
        XCTAssertFalse(m.canExport)
        XCTAssertNotNil(m.exportDisabledReason)
    }

    // MARK: - STL bytes

    func testExportSTLDataIsValidBinarySTL() {
        let m = model([meshedVariant(vf: 0.7, mass: 10)])
        guard let data = m.exportSTLData() else { return XCTFail("expected STL bytes") }
        XCTAssertEqual(data.count, 80 + 4 + 12 * 50, "cube = 12 triangles")
        let (rv, ri) = MeshExport.parseBinarySTL(data)
        XCTAssertEqual(ri.count / 3, 12)
        XCTAssertEqual(rv.count / 3, 36)
        // The header names the project + material.
        let header = String(decoding: data.prefix(80).prefix { $0 != 0 }, as: UTF8.self)
        XCTAssertTrue(header.contains("Bracket"))
        XCTAssertTrue(header.contains("PLA"))
    }

    func testRemoteVariantExportsIdentically() {
        // A remote variant's mesh is a local buffer too (097): export works the same.
        let m = model([meshedVariant(vf: 0.7, mass: 10)], remote: true)
        XCTAssertTrue(m.canExport)
        XCTAssertNotNil(m.exportSTLData())
    }

    // MARK: - Mass comparison (Open #6)

    func testMassComparisonShowsBothWhenDiverging() {
        // 20 mm cube → 8 cm³ → mesh mass = 8 × 1.24 = 9.92 g. Voxel estimate set ~4%
        // heavier (10.32 g) — the lacy-part gap this feature exists for.
        let m = model([meshedVariant(vf: 0.7, mass: 10.32)])
        guard let c = m.selectedMassComparison else { return XCTFail("expected a comparison") }
        XCTAssertEqual(c.meshGrams, 9.92, accuracy: 1e-3)
        XCTAssertEqual(c.voxelGrams ?? 0, 10.32, accuracy: 1e-3)
        XCTAssertTrue(c.divergesBeyond1Percent)
        XCTAssertFalse(c.meshIsEstimate, "a watertight cube is exact, not an estimate")
        XCTAssertTrue(c.summary.contains("Mesh:"))
        XCTAssertTrue(c.summary.contains("voxel estimate:"))
    }

    func testMassComparisonSingleNumberWhenAgreeing() {
        // Voxel mass equal to the mesh mass (within 1%) → only the mesh number shows.
        let m = model([meshedVariant(vf: 0.7, mass: 9.92)])
        guard let c = m.selectedMassComparison else { return XCTFail("expected a comparison") }
        XCTAssertFalse(c.divergesBeyond1Percent)
        XCTAssertFalse(c.summary.contains("voxel estimate:"))
        XCTAssertTrue(c.summary.contains("Mesh:"))
    }

    func testMassComparisonNilWithoutDensity() {
        let m = model([meshedVariant(vf: 0.7, mass: 10)], density: 0)
        XCTAssertNil(m.selectedMassComparison, "no density → no fabricated mesh mass")
    }

    func testNonWatertightMeshMassIsEstimate() {
        // Drop the +X face → open surface → the mesh mass is labeled an estimate.
        let (v, i) = cubeMesh(20)
        let openIdx = Array(i.prefix(i.count - 6))
        let variant = meshedVariant(vf: 0.7, mass: 10.32, verts: v, idx: openIdx)
        let m = model([variant])
        guard let c = m.selectedMassComparison else { return XCTFail("expected a comparison") }
        XCTAssertTrue(c.meshIsEstimate)
        XCTAssertTrue(c.meshLabel.contains("(est.)"))
    }

    func testRemoteVariantMassComparisonHasNoVoxelEstimate() {
        // A remote run doesn't carry the Mac-computed voxel mass (097): the comparison
        // shows the mesh mass alone, never a stale/absent voxel number.
        let m = model([meshedVariant(vf: 0.7, mass: 10.32)], remote: true)
        guard let c = m.selectedMassComparison else { return XCTFail("expected a comparison") }
        XCTAssertNil(c.voxelGrams)
        XCTAssertFalse(c.summary.contains("voxel estimate:"))
    }
}
