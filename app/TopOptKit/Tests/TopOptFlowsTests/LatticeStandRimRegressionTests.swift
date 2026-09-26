import XCTest
import Metal
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ HIS 2026-09-26 IMAGES 2–5, PINNED ON HIS STAND (faces 15, 2, 23; 23 expanded 4.15 mm).
final class LatticeStandRimRegressionTests: XCTestCase {

    /// Wall B (behind face 2) at the channel floor's level, clear of every other face's
    /// band: x 50–170, y −48.9…−38.5 (a voxel short of the floor's edge at −36.8),
    /// z 15–28. The floor f20 is alongside and banded; wall B's inner face f1 is passed
    /// through (open), so the floor's band must stop at their shared edge.
    static func solidInWallBAtTheFloor(_ scene: LatticeSDFScene) -> Int {
        guard let f = scene.regionSDF, let pr = scene.prismSDF else { return -1 }
        let solid = scene.solidOccupancy
        var n = 0
        for k in 0..<f.nz { for j in 0..<f.ny { for i in 0..<f.nx {
            let p = f.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * f.spacing
            guard p.x > 50, p.x < 170, p.y > -48.9, p.y < -38.5, p.z > 15, p.z < 28 else { continue }
            let e = (k * f.ny + j) * f.nx + i
            if solid.values[e] > 0.5, pr.values[e] < 0, f.values[e] >= 0 {
                n += 1
                if ProcessInfo.processInfo.environment["LEDGE_DUMP"] == "1" {
                    print(String(format: "LEDGEVOX (%.1f,%.1f,%.1f) region %.2f skinIn %.2f outline %.2f partMat %.2f", p.x, p.y, p.z,
                                 f.values[e], scene.skinInSDF?.values[e] ?? .nan, scene.outlineSDF?.values[e] ?? .nan, scene.partMaterialSDF.values[e]))
                }
            }
        } } }
        return n
    }

    func testTheFloorsBandDoesNotWrapIntoTheWall() throws {
        let (_, scene) = try LatticeStandRenderProbe.stand()
        let now = Self.solidInWallBAtTheFloor(scene)
        // ★ POSITIVE CONTROL: a band that rounds every edge must put the ledge back, or this
        // test cannot see the defect it pins (the band redesign's switch; the legacy block's
        // was LATTICE_WRAPPED_BAND)
        setenv("LATTICE_BAND_NO_FOOTPRINT", "1", 1)
        defer { unsetenv("LATTICE_BAND_NO_FOOTPRINT") }
        let (_, wrapped) = try LatticeStandRenderProbe.stand()
        let before = Self.solidInWallBAtTheFloor(wrapped)
        print("LEDGE solid voxels in wall B at the floor: wrapped \(before) · clipped \(now)")
        XCTAssertGreaterThan(before, 20, "the control lost the ledge — the test no longer sees it")
        XCTAssertEqual(now, 0, "the channel floor's band still reaches into wall B's lattice")
    }

    /// The rim band is drawn by the march; how much of it is drawn must not depend on the
    /// march's cell (the step it takes from the air was 0.7 cell and leapt a 3.4 mm band:
    /// 19 % less rim at 8 mm than at 4 mm on this view, measured 2026-09-26).
    @MainActor
    func testTheRimIsDrawnTheSameAtEveryCell() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        setenv("STAND_ONE_SPAN", "1", 1)
        defer { unsetenv("STAND_ONE_SPAN") }
        let (mesh, scene) = try LatticeStandRenderProbe.stand()
        guard let renderer = MeshRenderer(device: device, sampleCount: 1) else { throw XCTSkip("renderer") }
        try XCTSkipUnless(renderer.latticePipelinesDidBuild)
        renderer.setMesh(mesh)
        renderer.setLatticeScene(scene, token: 1)
        renderer.setBodyAlpha(0)
        func blue(cellMM: Double, az: Float, el: Float) -> Int {
            renderer.latticeParams = LatticePreviewConfettiTests.hisParamsAtACellHisPartCanHold(cellMM: cellMM)
            renderer.camera.setOrientation(azimuth: az, elevation: el)
            guard let d = renderer.latticeMaskDump(size: 600) else { return -1 }
            var n = 0
            for i in 0..<d.mask.count where d.mask[i] {
                let r = Int(d.rgb[i * 3]), g = Int(d.rgb[i * 3 + 1]), b = Int(d.rgb[i * 3 + 2])
                if b > r + 60 && b > g + 30 { n += 1 }
            }
            return n
        }
        for (az, el) in [(Float(1.57), Float(0.6)), (0.6, 0.35)] {
            let fine = blue(cellMM: 4, az: az, el: el), coarse = blue(cellMM: 8, az: az, el: el)
            print("RIMCELL az \(az) el \(el): rim px at 4 mm \(fine) · at 8 mm \(coarse)")
            XCTAssertGreaterThan(fine, 1000)
            XCTAssertLessThan(abs(Double(fine - coarse)) / Double(fine), 0.03,
                              "the drawn rim changes with the march's cell — the march is stepping over it")
        }
    }
}
