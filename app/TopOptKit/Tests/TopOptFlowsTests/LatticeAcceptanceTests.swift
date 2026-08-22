// LatticeAcceptanceTests — ★★★ THE TWO THINGS HE ASKED TO WAKE UP TO.
//
// (maintainer, 2026-08-22: "Do not stop until you have confirmed the density and
// thickness of the struts are controlled and thin just by selecting 'Auto' everything
// with minimize_plastic=on AS WELL AS until you have the entire selection area - the
// prism of the wall faces - COMPLETELY latticed.")
//
// Both are measured on HIS mesh and HIS two declared faces, on the paths production
// uses, and both print the number rather than only asserting a bound.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeAcceptanceTests: XCTestCase {

    private func hisRegions(_ mesh: ViewerMesh) -> [LatticeRegionSpec] {
        [(FaceID(15), 11.0), (FaceID(2), 13.0)].compactMap { f, d in
            LatticeRegionEmission.planeFor(face: f, in: mesh).flatMap {
                LatticeRegionEmission.spec(for: $0, role: .include, depthMM: d,
                                           faceID: Int(f))
            }
        }
    }

    /// A uniform, LIGHT field — 4 MPa against a 50 MPa allowable. Uniform is the point:
    /// relative grading makes every voxel read ~1.0 (each IS the percentile of itself),
    /// so this is the case where an unanchored map hands out the fattest struts it can.
    private func lightField(_ mesh: ViewerMesh) -> StressField {
        let e = mesh.bounds.max - mesh.bounds.min
        let n = 16
        return StressField(nx: n, ny: n, nz: n, origin: SIMD3<Float>(mesh.bounds.min),
                           spacing: max(e.x, max(e.y, e.z)) / Float(n),
                           values: [Float](repeating: 4, count: n * n * n))
    }

    /// The fraction of DECLARED voxels whose covering cell is active. A voxel whose cell
    /// was refused is drawn as solid plastic — that is the grey he is pointing at.
    private func coverage(_ scene: LatticeSDFScene, cellMM: Double) -> (Int, Int) {
        let occ = scene.occupancy
        let f = LatticePreviewOccupancy.cellField(
            occupancy: occ, demand: scene.demand, cellMM: cellMM,
            memberThickness: scene.memberThicknessMM,
            minCellsPerMember: scene.minCellsPerMember,
            cellsPerMemberFloor: scene.cellsPerMemberFloorPerVoxel)
        var declared = 0, covered = 0
        for k in 0..<occ.nz { for j in 0..<occ.ny { for i in 0..<occ.nx {
            let n = (k * occ.ny + j) * occ.nx + i
            guard occ.values[n] > 0.5 else { continue }
            declared += 1
            let p = occ.origin + SIMD3<Float>(Float(i), Float(j), Float(k)) * occ.spacing
            let c = (p - f.origin) / f.spacing
            let ci = Int(c.x.rounded()), cj = Int(c.y.rounded()), ck = Int(c.z.rounded())
            guard ci >= 0, cj >= 0, ck >= 0, ci < f.nx, cj < f.ny, ck < f.nz else { continue }
            if f.values[(ck * f.ny + cj) * f.nx + ci] >= 0 { covered += 1 }
        } } }
        return (covered, declared)
    }

    /// ★★★ (1) THE PRISM IS COMPLETELY LATTICED.
    func testTheDeclaredPrismIsCompletelyLatticed() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = hisRegions(mesh)
        try XCTSkipIf(regions.isEmpty, "his faces did not resolve")

        var rows: [String] = []
        var worst = 1.0
        // Both resolutions, because the preview used to behave differently at Fast and
        // say nothing about it.
        for maxDim in [64, 128] {
            let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                        stageMode: .aesthetic, allowableMPa: 50,
                                        minimizePlastic: true,
                                        boundaryFinishWritten: true,
                                        maxDim: maxDim, regions: regions,
                                        whenEmpty: .latticeNothing)
            try XCTSkipIf(scene.memberThicknessMM.isEmpty,
                          "core gave no thickness at \(maxDim) — the cubic-voxel fix regressed")
            // Auto's own cell: the coarsest each member can hold under the floor.
            for cell in [4.0, 5.5, 8.0] {
                let (c, d) = coverage(scene, cellMM: cell)
                let frac = d > 0 ? Double(c) / Double(d) : 0
                rows.append(String(format: "  %3d³  cell %4.1f mm   %6d / %6d = %5.1f%%",
                                   maxDim, cell, c, d, 100 * frac))
                if cell <= 5.5 { worst = Swift.min(worst, frac) }
            }
        }
        print("\n── coverage of the DECLARED prism (aesthetic, finish, floor 1) ──\n"
              + rows.joined(separator: "\n") + "\n")
        XCTAssertGreaterThan(worst, 0.98,
            "★ the declared prism must be COMPLETELY latticed at a cell its members can "
          + "hold — every refused voxel is solid plastic where he asked for lattice")
    }

    /// ★★★ (2) AUTO + MINIMIZE PLASTIC GIVES THIN STRUTS.
    func testAutoWithMinimizePlasticGivesThinStruts() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        let regions = hisRegions(mesh)
        try XCTSkipIf(regions.isEmpty, "his faces did not resolve")
        let field = lightField(mesh)

        func scene(_ minimize: Bool) -> LatticeSDFScene {
            LatticeSDFScene(mesh: mesh, field: field, latticeID: "octet",
                            stageMode: .aesthetic, allowableMPa: 50,
                            minimizePlastic: minimize, boundaryFinishWritten: true,
                            maxDim: 64, regions: regions, whenEmpty: .latticeNothing)
        }
        let off = scene(false), on = scene(true)
        let dOff = try XCTUnwrap(off.demand), dOn = try XCTUnwrap(on.demand)

        // The band the preview grades between, and the strut each end produces at the
        // cell Auto would pick. rho = lo + (hi - lo) * demand^gamma with gamma 1.
        let lo = 0.05, hi = 0.90, cell = 5.5
        func strut(_ demand: Float) -> Double {
            let rho = lo + (hi - lo) * Double(max(0, min(1, demand)))
            return TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                    relativeDensity: rho, cellMM: cell)
        }
        let maxOff = dOff.values.max() ?? 0, maxOn = dOn.values.max() ?? 0
        print(String(format: """

        ── Auto + minimize plastic, 4 MPa against a 50 MPa allowable ──
        demand  OFF max %.3f   ON max %.3f
        strut   OFF %.2f mm    ON %.2f mm   (at a %.1f mm cell)

        """, maxOff, maxOn, strut(maxOff), strut(maxOn), cell))

        XCTAssertEqual(Double(maxOff), 1.0, accuracy: 1e-3,
                       "positive control: unanchored, a uniform field reads its own "
                     + "percentile everywhere and takes the top of the band")
        XCTAssertLessThan(Double(maxOn), 0.15,
                          "★ minimize plastic must cap the demand at the TRUE "
                        + "utilisation — 4 / 50 = 0.08, not 1.0")
        XCTAssertLessThan(strut(maxOn), 0.4 * strut(maxOff),
                          "★ and the strut it produces must be far thinner")
    }
}
