// FlexibleGeometryOnlyLatticeTests — the SHAPE-ONLY lattice for a calibrate-first filament
// (task 2026-09-29-flexible-screens, round 3 batch B, item 9; maintainer: "Save & Exit builds
// a SHAPE-ONLY lattice that follows the curves … Exit always works").
//   * the mask is CORE'S: its voxel count equals FlexibleScene.Info.latticeVoxels (memory:
//     "core computed one wall two ways" — a second route to the mask would drift). RED
//     CONTROL: the app's own part occupancy on the same pad is a different count;
//   * the density band's ends are cells from core's planning relation (cellSizeMM): no cell
//     finer than 8 walls, none coarser than half the lattice depth; ρ(S) is monotone, the
//     firmest at S = 0. RED CONTROL: the inverted mapping fails the order;
//   * the field FOLLOWS THE DRAWING: under the soft middle of a centre-soft curve the density
//     is lower than under its firm edge. RED CONTROL: a drawing-blind (uniform) field is not.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

final class FlexibleGeometryOnlyLatticeTests: XCTestCase {

    /// C1's pad with TPU 95A and its top pressed with a centre-soft X curve.
    @MainActor
    private func pad() async throws -> (FlexibleStageModel, FlexFaceKey) {
        var s = FlexibleStageSettings(materialID: "tpu95a_generic")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3,
                                       curveX: FlexCurve(x: [0, 0.5, 1], y: [1, 0, 1]),
                                       curveY: FlexCurve(x: [0, 1], y: [0.5, 0.5])))
        let pm = try FlexibleHisProject.padProject(s)
        let m = try await FlexibleHisProject.openedModel(pm, test: self)
        let k = FlexFaceKey(region: top, rotation: 0)
        try await FlexibleHisProject.waitFor(30, "the drawn map") { m.liveS[k] != nil }
        await m.waitForIdle()
        return (m, k)
    }

    @MainActor
    func testTheMaskIsCoresOwn() async throws {
        let (m, _) = try await pad()
        let info = try XCTUnwrap(m.sceneInfo)
        let mask = try await m.workerForTests.withScene { try $0.latticeMask(build: m.build) }
        let n = FlexibleGeometryOnlyLattice.maskVoxels(mask)
        let occ = LatticePreviewOccupancy.occupancy(positions: m.project.viewerMesh!.positions, indices: m.project.viewerMesh!.indices,
                                                    bounds: m.project.viewerMesh!.bounds, maxDim: max(info.nx, info.ny, info.nz))
        let inside = occ.values.filter { $0 >= 0.5 }.count
        print("FLEX-SHAPE mask voxels \(n), core's latticeVoxels \(info.latticeVoxels) | app occupancy on its own grid \(inside) (control)")
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(n, info.latticeVoxels, "one route to the mask: core's")
        XCTAssertEqual(mask.nx, info.nx); XCTAssertEqual(mask.ny, info.ny); XCTAssertEqual(mask.nz, info.nz)
        // ★ RED CONTROL: a second route (the preview's own occupancy) counts something else
        XCTAssertNotEqual(inside, info.latticeVoxels, "control: the app's occupancy is not core's mask")
    }

    func testTheBandIsPrintableAndTheDensityMonotone() throws {
        let t = 0.42
        let band = try FlexibleGeometryOnlyLattice.band(topology: "gyroid", beadsPerWall: 1, beadWidthMM: t, latticeDepthMM: 18.4)
        let fine = try FlexibleCore.cellSizeMM(topology: "gyroid", density: band.upperBound, beadsPerWall: 1, beadWidthMM: t)
        let coarse = try FlexibleCore.cellSizeMM(topology: "gyroid", density: band.lowerBound, beadsPerWall: 1, beadWidthMM: t)
        print(String(format: "FLEX-SHAPE band ρ %.3f…%.3f ⇒ cells %.2f…%.2f mm (t %.2f, depth 18.4)", band.lowerBound, band.upperBound, fine, coarse, t))
        XCTAssertEqual(fine, FlexibleGeometryOnlyLattice.minCellWalls * t, accuracy: 1e-9, "the finest cell is 8 walls")
        XCTAssertEqual(coarse, 0.5 * 18.4, accuracy: 1e-9, "the coarsest is half the lattice depth")
        let deep = try FlexibleGeometryOnlyLattice.band(topology: "gyroid", beadsPerWall: 1, beadWidthMM: t, latticeDepthMM: 80)
        XCTAssertEqual(try FlexibleCore.cellSizeMM(topology: "gyroid", density: deep.lowerBound, beadsPerWall: 1, beadWidthMM: t),
                       FlexibleGeometryOnlyLattice.maxCellMM, accuracy: 1e-9, "capped at 12 mm")
        let ss = stride(from: 0.0, through: 1.0, by: 0.1).map { FlexibleGeometryOnlyLattice.density(s: $0, band: band) }
        XCTAssertEqual(ss.first!, band.upperBound, accuracy: 1e-12, "S = 0 (no squish) is the firmest")
        XCTAssertEqual(ss.last!, band.lowerBound, accuracy: 1e-12, "S = 1 (the deepest) is the softest")
        XCTAssertTrue(zip(ss, ss.dropFirst()).allSatisfy { $0 > $1 }, "softer where he drew softer")
        XCTAssertTrue(ss.allSatisfy { band.contains($0) })
        // ★ RED CONTROL: the inverted mapping (S = 1 firmest) fails the order
        let inv = stride(from: 0.0, through: 1.0, by: 0.1).map { band.lowerBound + $0 * (band.upperBound - band.lowerBound) }
        XCTAssertFalse(zip(inv, inv.dropFirst()).allSatisfy { $0 > $1 }, "control: an inverted map is caught")
    }

    @MainActor
    func testTheShapeOnlyFieldFollowsTheDrawing() async throws {
        let (m, k) = try await pad()
        let st = try XCTUnwrap(m.stacks[k]), s = try XCTUnwrap(m.liveS[k])
        let mask = try await m.workerForTests.withScene { try $0.latticeMask(build: m.build) }
        let band = try FlexibleGeometryOnlyLattice.band(topology: "gyroid", beadsPerWall: 1, beadWidthMM: m.build.beadWidthMM,
                                                        latticeDepthMM: 18)
        let f = FlexibleGeometryOnlyLattice.field(mask: mask, faces: [.init(stack: st, s: s)], band: band)
        XCTAssertEqual(FlexibleGeometryOnlyLattice.maskVoxels(f), FlexibleGeometryOnlyLattice.maskVoxels(mask), "the mask is untouched")
        // the densities under the softest and the firmest columns
        let soft = s.indices.max { s[$0] < s[$1] }!, firm = s.indices.min { s[$0] < s[$1] }!
        func rhoUnder(_ c: Int) -> Float? {
            let col = st.columns[c]
            let centre = st.centroid + st.xAxis * (col.uMM + st.uMin) + st.yAxis * (col.vMM + st.vMin)
            let p = centre + st.load * (0.5 * (col.entryT + col.exitT))
            let i = Int(((p.x - f.origin.x) / f.spacing).rounded(.down)), j = Int(((p.y - f.origin.y) / f.spacing).rounded(.down))
            let kk = Int(((p.z - f.origin.z) / f.spacing).rounded(.down))
            guard i >= 0, j >= 0, kk >= 0, i < f.nx, j < f.ny, kk < f.nz else { return nil }
            let v = f.density[f.index(i, j, kk)]
            return v > 0 ? v : nil
        }
        let rs = try XCTUnwrap(rhoUnder(soft)), rf = try XCTUnwrap(rhoUnder(firm))
        print(String(format: "FLEX-SHAPE S soft %.2f → ρ %.3f · S firm %.2f → ρ %.3f (band %.3f…%.3f)", s[soft], rs, s[firm], rf, band.lowerBound, band.upperBound))
        XCTAssertGreaterThan(s[soft] - s[firm], 0.3, "premise: the drawing is centre-soft")
        XCTAssertLessThan(rs, rf, "softer where he drew softer")
        // ★ RED CONTROL: a drawing-blind field (every S the same) cannot tell them apart
        let flat = FlexibleGeometryOnlyLattice.field(mask: mask, faces: [.init(stack: st, s: s.map { _ in 0.5 })], band: band)
        let i0 = f.density.indices.first { f.density[$0] > 0 }!
        XCTAssertEqual(Set(flat.density.filter { $0 > 0 }).count, 1, "control: a drawing-blind field is uniform")
        XCTAssertGreaterThan(Set(f.density.filter { $0 > 0 }).count, 1, "…and his is not (first ρ \(f.density[i0]))")
    }
}
