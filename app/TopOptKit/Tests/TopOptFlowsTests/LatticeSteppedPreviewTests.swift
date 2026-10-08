// LatticeSteppedPreviewTests — ★★★ THE PREVIEW CAN NOW DRAW A NON-DYADIC CELL.
//
// ★ THE STANDING NO-GO SAID IT COULD NOT, and the no-go was about the ENCODING, not
// about stepped. The cell texture carried a BASE CELL plus an integer DYADIC LEVEL, the
// shader recovered the covering cell as `S0 · 2^L`, and stepped's cells are arbitrary
// reals — so no (base, level) pair expressed them and the conclusion drawn was "a
// second renderer". It is not: it is one more texture channel carrying the SIZE, and a
// frame built with the power-of-two assumption removed.
//
// These bars are on the two halves of that claim: the field really does carry cells the
// old encoding could not express, and the doubled path is untouched.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeSteppedPreviewTests: XCTestCase {

    /// A slab with two side-by-side declared faces, so two regions can state two cells.
    private func twoRegionScene() throws -> (LatticeSDFScene, [LatticeRegionSpec]) {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var specs: [LatticeRegionSpec] = []
        for (f, depth) in [(FaceID(15), 11.0), (FaceID(2), 13.0)] {
            guard let r = LatticeRegionEmission.planeFor(face: f, in: mesh),
                  let s = LatticeRegionEmission.spec(for: r, role: .include,
                                                     depthMM: depth, faceID: Int(f))
            else { continue }
            specs.append(s)
        }
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    maxDim: 128, regions: specs,
                                    whenEmpty: .latticeNothing)
        return (scene, specs)
    }

    /// ★★★ THE HEADLINE: two regions, two cells, NEITHER a dyadic multiple of the other.
    func testTwoRegionsCarryTwoNonDyadicCells() throws {
        let (scene, specs) = try twoRegionScene()
        try XCTSkipIf(specs.count < 2, "his two faces did not resolve")

        // Deliberately awkward reals — the exact case the old encoding could not hold.
        let want: [Double] = [5.3125, 6.875]
        let field = try XCTUnwrap(
            LatticePreviewOccupancy.steppedCellField(
                occupancy: scene.occupancy, demand: scene.demand,
                regions: specs, cellMM: want, baseCellMM: want.min()!),
            "the stepped field did not build")

        let painted = Set(field.steppedCellMM.filter { $0 > 0 }.map { Double($0) })
        print("── stepped: cells painted onto the base grid: \(painted.sorted())")
        XCTAssertEqual(painted.count, 2, "★ two regions must paint two distinct cells")
        for w in want {
            XCTAssertTrue(painted.contains { abs($0 - w) < 1e-3 },
                          "★ \(w) mm did not reach the field — got \(painted.sorted())")
        }

        // ★ THE POSITIVE CONTROL FOR THE WHOLE TASK. Assert these really are outside
        // what the old encoding could say: no integer level L makes base·2^L land on
        // the second cell.
        let base = want.min()!
        let dyadic = (0..<8).map { base * pow(2.0, Double($0)) }
        XCTAssertFalse(dyadic.contains { abs($0 - want[1]) < 1e-3 },
                       "★ the control cell IS dyadic — this test would have passed "
                     + "under the old encoding and proves nothing")

        // And the level channel stays flat: stepped is not a ladder wearing a hat.
        XCTAssertTrue(field.level.allSatisfy { $0 == 0 })
        XCTAssertEqual(field.baseCellMM, base, accuracy: 1e-12,
                       "★ the base cell must be the FINEST region cell — the march's "
                     + "step bound reads it as the finest thing that can be adjacent")
    }

    /// ★ HALF-REPRESENTABLE, EXACTLY. The texture is `rgba16Float`; a size the app and
    /// the shader disagreed about in the last bit would drift the tiling across the part.
    func testTheCellsSurviveTheTextureFormatBitForBit() throws {
        let (scene, specs) = try twoRegionScene()
        try XCTSkipIf(specs.count < 2, "his two faces did not resolve")
        // A size with no exact half: 5.31 needs more mantissa than half carries.
        let want: [Double] = [5.31, 6.87]
        let field = try XCTUnwrap(LatticePreviewOccupancy.steppedCellField(
            occupancy: scene.occupancy, demand: scene.demand,
            regions: specs, cellMM: want, baseCellMM: want.min()!))
        for v in Set(field.steppedCellMM.filter { $0 > 0 }) {
            XCTAssertEqual(Float(Float16(v)), v,
                           "★ \(v) is not exactly representable as a half — it will "
                         + "arrive in the shader as a different cell")
        }
    }

    /// ★★ AND THE LADDER IS UNTOUCHED. Every non-stepped path must produce a field with
    /// an EMPTY stepped channel, which is what makes the shader's `b > 0` branch inert.
    func testTheDoubledPathCarriesNoSteppedCells() throws {
        let (scene, specs) = try twoRegionScene()
        try XCTSkipIf(specs.isEmpty, "his faces did not resolve")
        let grid = LatticePreviewOccupancy.cellField(
            occupancy: scene.occupancy, demand: scene.demand, cellMM: 8)
        let uniform = LatticePreviewOccupancy.uniformCellField(grid, cellMM: 8)
        XCTAssertTrue(uniform.steppedCellMM.isEmpty,
                      "★ the uniform path grew a stepped channel — doubled would change")
    }

    /// ★ NOTHING STATED ⇒ NIL, so the caller keeps the ladder rather than drawing an
    /// empty part. "The user chose stepped but no region derived a cell" is a real
    /// state (a member too thin for any printable cell) and must not blank the preview.
    func testNoStatedCellLeavesTheLadderAlone() throws {
        let (scene, specs) = try twoRegionScene()
        try XCTSkipIf(specs.isEmpty, "his faces did not resolve")
        XCTAssertNil(LatticePreviewOccupancy.steppedCellField(
            occupancy: scene.occupancy, demand: scene.demand,
            regions: specs, cellMM: [Double](repeating: 0, count: specs.count),
            baseCellMM: 5))
    }
}
