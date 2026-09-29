// FlexibleLatticeFieldTests — the Flexible lattice's reference geometry on C1's pad
// (task 2026-09-29-flexible-screens, overnight round). The app is the source of truth for
// this geometry until core's C2 exists, so these pin what "the lattice" means.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleLatticeFieldTests: XCTestCase {

    static var padDir: URL {
        URL(fileURLWithPath: FlexibleStageTests.padSTL).deletingLastPathComponent()
    }
    static func padJob() throws -> String {
        try String(contentsOf: padDir.appendingPathComponent("job.json"), encoding: .utf8)
    }

    /// The pad designed on its top face (C1's evidence job, face region 101), the field
    /// assembled by core, the inputs built by the app.
    static func padInputs(topology: String = "gyroid", skinOff: Bool = false) throws -> FlexibleLatticeInputs {
        let scene = try FlexibleScene(jobJSON: try Self.padJob(), jobDir: Self.padDir.path)
        let build = FlexBuildParams(topology: topology, beadsPerWall: 1, beadWidthMM: 0.42)
        let map = FlexMap(mode: "both", x: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]),
                          y: FlexCurve(x: [0, 0.5, 1], y: [0.3, 1, 0.3]), centreEdge: .flat, deepestMM: 2)
        let d = try scene.design(materialsPath: FlexibleStageTests.materialsPath, materialID: "varioshore_tpu",
                                 tempC: 220, face: 101, rotation: 0, map: map, weightN: 294.3, stamp: nil, build: build)
        XCTAssertNil(d.refusal)
        let field = try scene.densityField(faces: [101], rotations: [0], build: build)
        let m = try TopOptKit.importMesh(path: FlexibleStageTests.padSTL)
        let part = ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs, pseudoFaces: true)
        // the job's face 1 (region 101 adds face 1) is the top
        return try FlexibleLatticeBuilder.inputs(field: field, part: part, topology: topology, beadsPerWall: 1,
                                                 beadWidthMM: 0.42, buildDir: SIMD3(0, 0, 1),
                                                 skinOffFaces: skinOff ? [(face: 1, cuts: [])] : [])
    }

    func testTheCoreFieldBecomesFilledGrids() throws {
        let f = try Self.padInputs()
        XCTAssertEqual(f.wallMM, 0.42, accuracy: 1e-6)
        XCTAssertTrue(f.rho.values.allSatisfy { $0 > 0 }, "every voxel has a density to sample (gaps filled)")
        XCTAssertGreaterThan(f.mask.values.reduce(0, +), Float(f.mask.values.count) * 0.5, "the pad is latticed")
        // core's corner origin became a voxel-centre origin
        XCTAssertEqual(f.rho.c0.x, Float(f.rho.spacing) * 0.5, accuracy: 1e-4)
        // the part's signed distance: negative in the middle, positive outside
        XCTAssertLessThan(f.partSDF.sample(SIMD3(50, 50, 10)), -3, "negative inside (clamped past the band)")
        XCTAssertGreaterThan(f.partSDF.sample(SIMD3(50, 50, 30)), 0)
    }

    func testWallsExistInsideAndTheSkinIsSolid() throws {
        let f = try Self.padInputs()
        // somewhere deep inside, the walls are hit and so is the space between them
        var inside = 0, outside = 0
        for i in 0..<400 {
            let p = SIMD3<Float>(20 + Float(i % 20) * 3.1, 20 + Float(i / 20) * 3.1, 10)
            if FlexibleLatticeField.lattice(at: p, f) < 0 { inside += 1 } else { outside += 1 }
        }
        XCTAssertGreaterThan(inside, 20, "walls cross the mid-plane")
        XCTAssertGreaterThan(outside, 200, "and most of it is open (ρ ≈ 0.14–0.36)")
        // within the 0.8 mm skin under the top face: no lattice, but solid in the export
        let skinP = SIMD3<Float>(50, 50, 19.7)
        XCTAssertGreaterThan(FlexibleLatticeField.lattice(at: skinP, f), 0)
        XCTAssertLessThan(FlexibleLatticeField.solid(at: skinP, f), 0)
        // outside the part: nothing
        XCTAssertGreaterThan(FlexibleLatticeField.solid(at: SIMD3(50, 50, 25), f), 0)
    }

    func testSkinOffLetsTheLatticeReachTheFace() throws {
        let on = try Self.padInputs(), off = try Self.padInputs(skinOff: true)
        // just under the top face: skin on = solid there; skin off = walls AND gaps
        var gapsOn = 0, gapsOff = 0
        for i in 0..<400 {
            let p = SIMD3<Float>(20 + Float(i % 20) * 3.1, 20 + Float(i / 20) * 3.1, 19.75)
            if FlexibleLatticeField.solid(at: p, on) > 0 { gapsOn += 1 }
            if FlexibleLatticeField.solid(at: p, off) > 0 { gapsOff += 1 }
        }
        XCTAssertEqual(gapsOn, 0, "a skinned face is solid under its surface")
        XCTAssertGreaterThan(gapsOff, 100, "with its skin off the lattice runs to the face")
    }

    func testHoneycombIsAPrismAlongTheBuildAxis() throws {
        let f = try Self.padInputs(topology: "honeycomb")
        XCTAssertEqual(f.topology, .honeycomb)
        // the honeycomb wall is the same at every height (a prism along +Z)
        for i in 0..<50 {
            let x = 30 + Float(i) * 0.7, y = 40 + Float(i % 7) * 1.3
            XCTAssertEqual(FlexibleLatticeField.wall(SIMD3(x, y, 6), f), FlexibleLatticeField.wall(SIMD3(x, y, 14), f), accuracy: 1e-4)
        }
        XCTAssertEqual(f.honeycombCellMM, 2 * 0.42 / (f.rho.values.reduce(0, +) / Float(f.rho.values.count)), accuracy: 0.8)
    }
}
