// FlexibleLatticePassTests + Printed — round 7 batch X1: the PRINTED VIEW's term in BOTH twins (the MSL `flx_field` under
// `shape2.w`, the Swift `FlexibleLatticeField.lattice(at:printed:)`), sampled at the same points, within `parityMM` (5e-3 mm).
// Written BEFORE the stage's code (round7/batch_x1/r7x1_red_run.txt); the RED controls run inside: the GPU field WITHOUT the
// gate against the printed reference must miss (the term is seen), and the printed GPU field against the unprinted
// reference must miss (the gate is seen).
#if canImport(Metal) && canImport(MetalKit)
import XCTest
import Metal
import simd
@testable import TopOptFlows

extension FlexibleLatticePassTests {

    func testThePrintedTermMatchesTheSwiftTwin() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        let pts = Fx.probePoints(3000, seed: 0x5EED_0F_71)
        var token = 100
        for topo in [FlexibleLatticeInputs.Topology.gyroid, .honeycomb] {
            token += 1
            pass.upload(Fx.layer(Fx.regionAndSkinBox(topo), token: token))
            let f = try XCTUnwrap(pass.referenceInputs)
            pass.printed = false
            let plain = try XCTUnwrap(pass.probe(pts))
            pass.printed = true
            let gpu = try XCTUnwrap(pass.probe(pts))
            pass.printed = false
            var worst: Float = 0, bySolid = 0, byWalls = 0, skinSolid = 0, pocketSolid = 0
            for (i, p) in pts.enumerated() {
                let ref = FlexibleLatticeField.lattice(at: p, f, printed: true)
                worst = max(worst, abs(gpu[i] - ref))
                let t = FlexibleLatticeField.terms(at: p, f)
                if t.printed < t.walls - 1e-3 { bySolid += 1 } else { byWalls += 1 }
                if t.printed < 0 {
                    if FlexibleLatticeField.dRegion(p, f) < 0 { skinSolid += 1 } else { pocketSolid += 1 }
                }
            }
            // ★ RED CONTROLS: the gate off on the GPU against the printed reference; the gate on against the plain one
            let missTerm = pts.indices.map { abs(plain[$0] - FlexibleLatticeField.lattice(at: pts[$0], f, printed: true)) }.max() ?? 0
            let missGate = pts.indices.map { abs(gpu[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            // the plain field is untouched by the change (the X-ray and the Squish page)
            let plainWorst = pts.indices.map { abs(plain[$0] - FlexibleLatticeField.lattice(at: pts[$0], f)) }.max() ?? 0
            print("FLEX-PRINTED \(topo): max |gpu − swift| \(worst) mm over \(pts.count) points; the printed solid decides at \(bySolid) (inside it: skin \(skinSolid), pocket \(pocketSolid)), the walls at \(byWalls); unprinted parity \(plainWorst) mm; controls: gate off \(missTerm) mm, unprinted reference \(missGate) mm")
            XCTAssertLessThanOrEqual(worst, Self.parityMM, "★ \(topo): the printed term drifted between the twins")
            XCTAssertLessThanOrEqual(plainWorst, Self.parityMM, "the unprinted field is unchanged")
            XCTAssertGreaterThanOrEqual(skinSolid, 5, "the probe reaches the finish's skin inside the region")
            XCTAssertGreaterThanOrEqual(pocketSolid, 5, "…and the part outside the region (the pocket's wall and floor)")
            XCTAssertGreaterThan(missTerm, 0.1, "★ RED CONTROL: without the gate the printed solid is missing")
            XCTAssertGreaterThan(missGate, 0.1, "★ RED CONTROL: the gate changes the field")
        }
        // the frame's uniform carries the gate (the echo reads shape2 by name)
        pass.printed = true
        let u = try XCTUnwrap(pass.frameUniforms(squish: 0))
        XCTAssertEqual(u.shape2.w, 1, "shape2.w = 1: the printed view")
        pass.printed = false
        XCTAssertEqual(try XCTUnwrap(pass.frameUniforms(squish: 0)).shape2.w, 0, "shape2.w = 0 otherwise (X-ray, the Squish page)")
    }

    /// ★ X1 VERIFY — THE HEAT ON THE WALLS in both twins (the MSL `flx_wall_heat`, the Swift `FlexibleWallHeat.value`): two
    /// pressed faces at right angles over the region-and-skin box (the top pressed down, the x = 0 side pressed in), each with
    /// its own heat table (some cells with no column), sampled at the same rest points. RED controls inside: the tables in the
    /// wrong face slots miss; with no table the frame stays on the density ramp.
    func testTheWallHeatMatchesTheSwiftTwin() throws {
        let pass = try FlexibleLatticePass(device: try Fx.device())
        var topCells: [SIMD4<Float>] = []
        for k in 0..<400 { topCells.append(SIMD4(2, 0, 20, k % 11 == 0 ? 0 : 1)) }
        let top = FlexibleSquishFace(centroid: SIMD3(20, 20, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0), load: SIMD3(0, 0, -1),
                                     uMin: -20, vMin: -20, pitchMM: 2, nu: 20, nv: 20, cells: topCells)
        let side = FlexibleSquishFace(centroid: SIMD3(0, 20, 10), xAxis: SIMD3(0, 1, 0), yAxis: SIMD3(0, 0, 1), load: SIMD3(1, 0, 0),
                                      uMin: -20, vMin: -10, pitchMM: 2, nu: 20, nv: 10,
                                      cells: [SIMD4<Float>](repeating: SIMD4(3, 0, 30, 1), count: 200))
        pass.upload(Fx.layer(Fx.regionAndSkinBox(.gyroid), faces: [top, side], token: 300))
        let heat = FlexibleWallHeat(cells: [(0..<400).map { Float($0 % 37) * 0.2 }, (0..<200).map { Float($0 % 13) * 0.5 }], topMM: 8)
        XCTAssertEqual(pass.wallColourMode().z, 0, "no table: the density ramp")
        pass.applyHeat(heat)
        let mode = pass.wallColourMode()
        XCTAssertEqual(mode.z, 2, "★ a table: the walls take the heat")
        XCTAssertEqual(mode.w, 1 / 8, accuracy: 1e-6, "★ …on the legend's scale (1 / its top)")
        let pts = Fx.probePoints(3000, seed: 0x4EA7_0F_71)
        let gpu = try XCTUnwrap(pass.probeHeat(pts), "★ the GPU's flx_wall_heat")
        var worst: Float = 0, both = 0, none = 0, hot = 0
        for (i, p) in pts.enumerated() {
            let ref = try XCTUnwrap(FlexibleWallHeat.value(at: p, faces: pass.faces, cells: heat.cells))
            worst = max(worst, abs(gpu[i] - ref))
            let inTop = FlexibleWallHeat.value(at: p, faces: [top], cells: [heat.cells[0]]) ?? 0
            let inSide = FlexibleWallHeat.value(at: p, faces: [top, side], cells: [[Float](repeating: 0, count: 400), heat.cells[1]]) ?? 0
            if inTop > 0, inSide > 0 { both += 1 }
            if ref == 0 { none += 1 } else { hot += 1 }
        }
        // ★ RED CONTROL: the tables in the wrong slots (the side's on the top) miss
        let swapped = pts.indices.map { i -> Float in
            let s = FlexibleWallHeat.value(at: pts[i], faces: [side, top], cells: heat.cells) ?? 0
            return abs(gpu[i] - s)
        }.max() ?? 0
        print("FLEX-WALL-HEAT max |gpu − swift| \(worst) mm over \(pts.count) points (both faces \(both), none \(none), hot \(hot)); control (swapped slots) \(swapped) mm")
        XCTAssertLessThanOrEqual(worst, 1e-4, "★ the wall heat drifted between the twins")
        XCTAssertGreaterThan(both, 50, "the probe reaches walls under both faces (the larger wins)")
        XCTAssertGreaterThan(none, 50, "…and walls under no column (0 mm)")
        XCTAssertGreaterThan(swapped, 0.5, "★ RED CONTROL: the wrong slots miss")
        pass.applyHeat(nil)
        XCTAssertEqual(pass.wallColourMode().z, 0, "the table gone: the density ramp again")
    }
}
#endif
