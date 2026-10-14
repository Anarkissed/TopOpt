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
}
#endif
