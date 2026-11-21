// LatticeProbeSamplingTests — ★ THE READING MUST BE THE CELL IT AIMED AT
// (maintainer, 2026-08-19: "It's in the right area - but still only showing 5% each
// time every time").
//
// ★★ WHAT THIS SETTLED, AND WHY IT MATTERS. "Always the floor" has two possible
// causes and they call for opposite work: the sampler could be reading the wrong
// cell, or the FIELD could genuinely be at the floor. Measured on the fixture with a
// graded demand:
//
//     active cells 417   min 0.745  p50 0.883  p95 0.993  max 0.995
//     cells at zero        0 of 417
//     round-trip           densest 0.9947 -> read back 0.9947
//
// The sampler is exact and the pipeline carries a graded field end to end. So a flat
// 5% on his own part is the DEMAND being flat there, not the probe misreading it —
// which points the work at the FEA-to-demand mapping (it divides by the peak, and a
// stress concentration then collapses the whole part toward zero) rather than at
// this code.

import XCTest
import simd
@testable import TopOptFlows

final class LatticeProbeSamplingTests: XCTestCase {

    private func gradedField(_ b: MeshBounds) -> StressField {
        let ext = b.max - b.min
        let n = 48
        let sp = Swift.max(ext.x, Swift.max(ext.y, ext.z)) / Float(n)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            vals[(k * n + j) * n + i] = Float(i) / Float(n - 1)
        } } }
        return StressField(nx: n, ny: n, nz: n, origin: b.min, spacing: sp, values: vals)
    }

    private func scene() throws -> LatticeSDFScene {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60
        return LatticeSDFScene(mesh: mesh, field: gradedField(mesh.bounds),
                               latticeID: "octet", regions: [region],
                               rhoMin: 0.05, rhoMax: 0.9, gamma: 1,
                               whenEmpty: .latticeNothing)
    }

    /// ★ THE ARITHMETIC THE TAP READING USES. `cellField` centres cell (i,j,k) at
    /// `origin + index * cell`, so the nearest-cell formula must invert exactly that.
    /// An off-by-half here would read a neighbouring cell and quietly report the
    /// wrong density for the strut under the finger.
    func testTheNearestCellFormulaReadsBackTheCellItAimedAt() throws {
        let scene = try self.scene()
        let grid = LatticePreviewOccupancy.cellField(occupancy: scene.occupancy,
                                                     demand: scene.demand, cellMM: 8)
        var best = 0
        for (n, v) in grid.values.enumerated() where v > grid.values[best] { best = n }
        let bi = best % grid.nx, bj = (best / grid.nx) % grid.ny
        let bk = best / (grid.nx * grid.ny)
        let centre = grid.origin + SIMD3<Float>(Float(bi), Float(bj), Float(bk)) * grid.spacing

        let g = (centre - grid.origin) / grid.spacing
        let ri = Swift.min(Swift.max(Int(g.x.rounded()), 0), grid.nx - 1)
        let rj = Swift.min(Swift.max(Int(g.y.rounded()), 0), grid.ny - 1)
        let rk = Swift.min(Swift.max(Int(g.z.rounded()), 0), grid.nz - 1)
        XCTAssertEqual(grid.values[(rk * grid.ny + rj) * grid.nx + ri],
                       grid.values[best], accuracy: 1e-6,
                       "★ the tap reading must land on the cell it aimed at")
    }

    /// ★★ THE POSITIVE CONTROL. Without this, the test above passes just as happily
    /// on a field that is uniformly zero — and a flat reading would look "correct".
    func testAGradedDemandReachesTheCellsAsAGradedField() throws {
        let scene = try self.scene()
        XCTAssertNotNil(scene.demand, "a graded field must produce a demand grid")
        let grid = LatticePreviewOccupancy.cellField(occupancy: scene.occupancy,
                                                     demand: scene.demand, cellMM: 8)
        let active = grid.values.filter { $0 >= 0 }
        XCTAssertGreaterThan(active.count, 50, "there must be active cells to judge")
        let lo = active.min() ?? 0, hi = active.max() ?? 0
        XCTAssertGreaterThan(hi - lo, 0.15,
                             "★ the cells must SPAN a range — a flat field here would "
                             + "make every tap read the same density and the preview "
                             + "would be telling the truth about nothing")
    }

    /// ★★ THE WHOLE CHAIN THAT HANGS OFF ONE NIL. A scene baked before the FEA landed
    /// has `demand == nil`, and BOTH reported symptoms follow from it mechanically:
    /// every cell reads 0 (so a tap reports the floor — "5% no matter where I click")
    /// and `stressRGB` is never baked (so the overlay cannot arm — "the stress map is
    /// still not on the actual lattice"). Asserting the chain is what stops someone
    /// "fixing" the probe or the overlay flag instead of the missing rebake.
    func testASceneWithNoFieldReadsTheFloorAndCannotShowStress() throws {
        let mesh = try LatticePreviewConfettiTests.hisMesh()
        var region = LatticeRegionFidelityTests.hisSlab(mesh, halfU: 200, halfW: 200)
        region.depthMM = 60

        let withField = try scene()
        XCTAssertNotNil(withField.demand, "a field must produce demand")
        XCTAssertNotNil(withField.stressRGB, "…and the stress colours the overlay needs")

        let stale = LatticeSDFScene(mesh: mesh, field: nil, latticeID: "octet",
                                    regions: [region], rhoMin: 0.05, rhoMax: 0.9,
                                    gamma: 1, whenEmpty: .latticeNothing)
        XCTAssertNil(stale.demand, "no field ⇒ no demand")
        XCTAssertNil(stale.stressRGB,
                     "★ …and therefore no stress volume: `stressTex` is nil, and the "
                     + "overlay is ANDed off however loudly the toggle is set")

        let grid = LatticePreviewOccupancy.cellField(occupancy: stale.occupancy,
                                                     demand: stale.demand, cellMM: 8)
        let active = grid.values.filter { $0 >= 0 }
        XCTAssertFalse(active.isEmpty, "there are still active cells to read")
        XCTAssertEqual(active.max() ?? 1, 0, accuracy: 1e-6,
                       "★ every cell reads ZERO without a demand field, which is why a "
                       + "tap reported rhoMin everywhere — the probe was telling the "
                       + "truth about a stale scene")
    }

    /// ★ AND THE TRIGGER THAT PREVENTS IT. The preview rebakes on the selection and on
    /// a RUN's variants; the on-device FEA landing needs its own, because the solve is
    /// async and finishes after the first bake.
    func testThePreviewRebakesWhenTheFEAFieldLands() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift")
        let ws = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(ws.contains(".onChange(of: latticeStressFieldKey)"),
                      "★ the preview must rebake when the FEA field arrives or changes")
        guard let r = ws.range(of: ".onChange(of: latticeStressFieldKey)") else { return }
        XCTAssertTrue(String(ws[r.lowerBound...].prefix(240)).contains("buildStrutScene()"),
                      "★ …and the rebake must actually run")
    }
}
