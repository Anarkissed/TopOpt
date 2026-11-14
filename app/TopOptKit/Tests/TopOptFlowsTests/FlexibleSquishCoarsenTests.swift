// FlexibleSquishCoarsenTests — ONE coarsening rule for the squish sim's grid, written twice (the
// bridge's flexible_squish_coarsen and FlexibleFE.coarsen, which sizes the main page's overlay
// before any sim ran), held together here (task 2026-09-29-flexible-screens, round 5 batch G, §1.1).
// RED CONTROL: a twin whose threshold is one voxel off disagrees on a 120 001-voxel box.
import XCTest
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleSquishCoarsenTests: XCTestCase {

    static let boxes: [(Int, Int, Int, Int)] = [
        (64, 64, 13, 1),      // his pad at Fast
        (128, 128, 26, 2),    // his pad at Fine
        (100, 100, 20, 2),    // C1's pad at resolution 100
        (200, 200, 40, 4),
        (120_000, 1, 1, 1), (120_001, 1, 1, 2), (960_000, 1, 1, 2), (960_001, 1, 1, 4),
    ]

    func testTheSwiftTwinIsTheBridgesRule() {
        for (x, y, z, c) in Self.boxes {
            XCTAssertEqual(FlexibleCore.squishCoarsen(nx: x, ny: y, nz: z), c, "bridge \(x)×\(y)×\(z)")
            XCTAssertEqual(FlexibleFE.coarsen(nx: x, ny: y, nz: z), c, "Swift \(x)×\(y)×\(z)")
        }
        // ★ RED CONTROL: a twin one voxel off
        func offByOne(_ x: Int, _ y: Int, _ z: Int) -> Int { x * y * z <= 120_001 ? 1 : (x * y * z <= 960_000 ? 2 : 4) }
        XCTAssertNotEqual(offByOne(120_001, 1, 1), FlexibleCore.squishCoarsen(nx: 120_001, ny: 1, nz: 1), "control: the twin must match to the voxel")
    }

    /// The solution's node counts are ceil(n / c) + 1 on C1's pad (100 × 100 × 20 ⇒ c = 2 ⇒ 51 × 51 × 11).
    func testTheSolutionGridFollowsTheRule() throws {
        let pad = try FlexibleSquishFETestsBridge.pad()
        let s = try pad.scene.squishSolve(FlexibleSquishFETestsBridge.request(pad))
        XCTAssertTrue(s.ok, s.failure)
        let c = FlexibleFE.coarsen(nx: pad.info.nx, ny: pad.info.ny, nz: pad.info.nz)
        XCTAssertEqual(s.coarsen, c)
        XCTAssertEqual([s.nx, s.ny, s.nz], [pad.info.nx, pad.info.ny, pad.info.nz].map { ($0 + c - 1) / c + 1 })
        XCTAssertEqual(s.spacing, pad.info.spacing * Double(c), accuracy: 1e-12)
        XCTAssertEqual(FlexibleFE.spacing(sceneNX: pad.info.nx, ny: pad.info.ny, nz: pad.info.nz, spacing: pad.info.spacing), s.spacing,
                       accuracy: 1e-12, "the main page's overlay edge IS the sim's spacing")
        print("FLEX-G COARSEN C1 pad \(pad.info.nx)×\(pad.info.ny)×\(pad.info.nz) → ×\(c) → nodes \(s.nx)×\(s.ny)×\(s.nz), \(s.spacing) mm")
    }
}

/// C1's pad scene for the TopOptFlows tests (the TopOptKit suite's helper is in another module).
@MainActor
enum FlexibleSquishFETestsBridge {
    struct Pad { let scene: FlexibleScene; let info: FlexibleScene.Info; let mask: FlexDensityField }
    static func pad() throws -> Pad {
        let dir = FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-28-flexible-squish-maths/a_pad_centre_soft")
        let scene = try FlexibleScene(jobJSON: try String(contentsOf: dir.appendingPathComponent("job.json"), encoding: .utf8), jobDir: dir.path)
        return Pad(scene: scene, info: try scene.info(),
                   mask: try scene.latticeMask(build: FlexBuildParams(topology: "gyroid", beadsPerWall: 1, beadWidthMM: 0.42)))
    }
    /// The top (101) at 294.3 N, the bottom (100) resting, ρ 0.2 everywhere latticed.
    static func request(_ p: Pad) throws -> FlexSquishRequestInfo {
        let st = try p.scene.stack(face: 101, rotation: 0)
        let n = p.info.nx * p.info.ny * p.info.nz
        return FlexSquishRequestInfo(
            pressed: [FlexSquishPressInfo(face: 101, rotation: 0, columnPressureMPa: [Double](repeating: 294.3 / st.footprintAreaMM2, count: st.columns.count))],
            restingIDs: [100], rho: (0..<n).map { p.mask.density[$0] < 0 ? -1 : 0.2 },
            strainOp: [Float](repeating: 0, count: n), skinFrac: [Float](repeating: 0, count: n),
            law: FlexSquishLawInfo(materialsPath: FlexibleHisProject.materialsPath, materialID: "varioshore_tpu", topology: "gyroid",
                                   tempC: 220, shapeOnly: false))
    }
}
