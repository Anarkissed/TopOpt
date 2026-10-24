import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ THE "LATTICE DEPTH" SECTION IS REMOVED (his decision, 2026-10-11): "I want the entire section
/// removed." … "The lattice *always* goes the entire depth of the prism. The *GRADE* can only be modified
/// by that setting ... the actual lattice depth NEVER changes." A project saved with a wall setting must
/// still open, and its preview must fill the whole prism, 0 to depthMM.
@MainActor
final class LatticeWallDepthRemovedTests: XCTestCase {

    /// The old setting, written by hand the way a 2026-09-21 build saved it: the switch off, half the
    /// wall, one wall with its own range and a drawn profile.
    static let oldWallKey: [String: Any] = [
        "depthBySim": false, "density": "manualSingle", "pct": 50, "seedBoost": 2,
        "faces": ["f:g:4": ["startMM": 0, "endMM": 20, "profile": ["ends": [0.5, 0.25]]]],
    ]

    private func project() -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "wall", material: "ABS", process: .fdm,
                     importedFile: ImportedFile(name: "part.step", path: NSTemporaryDirectory() + "part.step",
                                                triangleCount: 12, faceCount: 6, watertight: true),
                     importedMesh: nil)
        p.lattice.enabled = true
        return p
    }

    /// The bottom face (z = 0) of the 40 mm box, looking up into the part, 20 mm deep.
    private func bottomWall() -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 20, 0); r.normal = SIMD3(0, 0, 1); r.depthMM = 20
        r.halfUMM = 15; r.halfWMM = 15
        r.outlineLoops = [[SIMD2(-15, -15), SIMD2(15, -15), SIMD2(15, 15), SIMD2(-15, 15)]]
        r.selectableKey = "f:g:4"; r.faceID = 4
        return r
    }

    func testAProjectSavedWithAWallSettingOpensAndItsPreviewFillsTheWholePrism() throws {
        let p = project()
        let untouched = try XCTUnwrap(p.snapshot(savedAt: Date(timeIntervalSince1970: 0)))
        let untouchedData = try JSONEncoder().encode(untouched)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: untouchedData) as? [String: Any])
        var lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
        XCTAssertNil(lat["wallThickness"], "an untouched project writes no wall key")
        lat["wallThickness"] = Self.oldWallKey
        obj["lattice"] = lat
        let saved = try JSONSerialization.data(withJSONObject: obj)

        // ★ it opens
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: saved)
        let lattice = try XCTUnwrap(back.lattice)
        // ★ and the old key is ignored: the lattice re-encodes exactly as the untouched one
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try e.encode(lattice), as: UTF8.self),
                       String(decoding: try e.encode(try XCTUnwrap(untouched.lattice)), as: UTF8.self),
                       "★ the old wall key is read and dropped")

        // ★ its preview: the regions the stage bakes, through the scene every reader reads
        _ = lattice
        let region = bottomWall()
        let scene = LatticeSDFScene(mesh: LatticeBandChipsTests.boxMesh(), field: nil, latticeID: "octet",
                                    regions: [region], whenEmpty: .latticeNothing)
        let r = try XCTUnwrap(scene.regions.first)
        let deep = SIMD3<Double>(20, 20, 0.9 * r.depthMM)
        XCTAssertTrue(LatticeRegionMask.contains(deep, region: r), "★ the lattice reaches 0.9 · depth (18 mm)")
        XCTAssertTrue(LatticeRegionMask.contains(SIMD3(20, 20, 0.6 * r.depthMM), region: r), "past the old 50 % slab")
        XCTAssertLessThan(LatticeRegionMask.signedDistance(deep, region: r), 0, "inside by the region distance too")
        // the occupancy the bake reads: latticed voxels in the prism's last tenth
        let g = scene.occupancy
        var deepVoxels = 0
        for k in 0..<g.nz { for j in 0..<g.ny { for i in 0..<g.nx where g.values[(k * g.ny + j) * g.nx + i] > 0.5 {
            let z = Double(g.origin.z + Float(k) * g.spacing.z)
            let x = Double(g.origin.x + Float(i) * g.spacing.x), y = Double(g.origin.y + Float(j) * g.spacing.y)
            if z > 0.9 * r.depthMM, z < r.depthMM, abs(x - 20) < 14, abs(y - 20) < 14 { deepVoxels += 1 }
        }}}
        print("WALL-REMOVED deep voxels (z in 18…20 mm): \(deepVoxels)")
        XCTAssertGreaterThan(deepVoxels, 0, "★ the occupancy is latticed through the whole depth")
    }
}
