import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ ROUND 5's APP-SIDE PLAN FIXES (the reviewer, 2026-10-08: "Your app-side fixes (the fifths
/// packer, the owner-0 case, the depth tolerance to core's 1e-6): yes, in your order"). Each is
/// checked against core's own rule, in core's own arithmetic (stepped_plan.cpp).
final class LatticeCorePlanRulesTests: XCTestCase {

    /// A block 40 mm on a side at 1 mm voxels, its −y face latticed `depth` mm deep.
    private func wall(depth: Double) -> (occ: LatticeVoxelGrid, demand: LatticeVoxelGrid, regions: [LatticeRegionSpec]) {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var solid = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { solid[(k * n + j) * n + i] = 1 }
        }}}
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = SIMD3(20, 0, 20); r.normal = SIMD3(0, 1, 0)
        r.halfUMM = 19; r.halfWMM = 19; r.depthMM = depth
        r.outlineLoops = [[SIMD2(-18, -18), SIMD2(18, -18), SIMD2(18, 18), SIMD2(-18, 18)]]
        let spacing = SIMD3<Float>(repeating: 1)
        let whole = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: solid)
        // the scene's occupancy is the prism-clipped part, as `LatticeRegionMask.clipped` makes it
        let occ = LatticeRegionMask.clipped(whole, to: [r], whenEmpty: .latticeNothing)
        return (occ, LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                      values: [Float](repeating: 0.3, count: solid.count)), [r])
    }
    private func bake(_ w: (occ: LatticeVoxelGrid, demand: LatticeVoxelGrid, regions: [LatticeRegionSpec]),
                      cell: Double, dyadic: Bool) throws -> LatticeCellField {
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        return try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: w.occ, demand: w.demand, regions: w.regions, cellMM: [cell], lineWidthMM: 0.45,
            realFloorMM: 1.5, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: dyadic, stats: &st), "no bake")
    }

    // MARK: the fifths

    /// ★ The any-step menu holds only the families `packSlot`'s base/12 grid lands on — halves,
    /// thirds, quarters, sixths. Fifths (k·base/5) are not on it. Literals, so the rule can't drift.
    func testTheAnyStepMenuHoldsOnlyFamiliesThePackerLandsOn() {
        let menu = LatticePreviewOccupancy.steppedSizeMenu(base: 12, floorMM: 1.5, lineWidthMM: 0.45,
                                                          latticeID: "octet", printsOpenBound: false)
        XCTAssertEqual(menu, [12, 10, 9, 8, 6, 4, 3, 2], "★ no 9.6, 7.2, 4.8 or 2.4")
        for fifth in [9.6, 7.2, 4.8, 2.4] {
            XCTAssertFalse(menu.contains { abs($0 - fifth) < 1e-9 }, "\(fifth) is a fifth")
        }
        XCTAssertEqual(LatticePreviewOccupancy.steppedPackGrid, 12)
        for n in 2...LatticePreviewOccupancy.steppedMenuMaxDivisor where LatticePreviewOccupancy.steppedPackGrid % n == 0 {
            XCTAssertNotEqual(n, 5)
        }
    }

    /// ★ Core's alignment test (stepped_plan.cpp:254-281), every cell of an any-step bake: its offset
    /// from the slot origin is a whole number of its own size, or of a family tile base/n (n ≤ 6)
    /// that divides its size.
    func testEveryPackedCellSitsOnItsFamilyGrid() throws {
        let f = try bake(wall(depth: 12), cell: 12, dyadic: false)
        XCTAssertFalse(f.steppedCells.isEmpty)
        let base = f.steppedCells.map(\.sizeMM).max()!
        var sizes = Set<Double>(), bad: [String] = []
        for c in f.steppedCells {
            sizes.insert(c.sizeMM)
            let so = try XCTUnwrap(c.slotOriginMM)
            func whole(_ x: Double) -> Bool { abs(x - (x + 0.5).rounded(.down)) <= 1e-6 }
            for a in 0..<3 {
                let off = c.originMM[a] - so[a]
                let ok = whole(off / c.sizeMM) || (2...6).contains { n in
                    let t = base / Double(n)
                    return whole(c.sizeMM / t) && whole(off / t)
                }
                if !ok { bad.append(String(format: "%.3f mm at axis %d offset %.4f", c.sizeMM, a, off)) }
            }
        }
        XCTAssertEqual(bad, [], "★ every cell on its family's grid")
        XCTAssertGreaterThan(sizes.count, 1, "positive control: the packer stepped down somewhere")
        print("PLAN-RULES any-step sizes \(sizes.sorted(by: >)) cells \(f.steppedCells.count)")
    }

    // MARK: the depth

    /// ★★ Core's depth rule (stepped_plan.cpp:283-324): projected on the unit normal from the face
    /// plane, the cube's centre lies in [0, depth] and its far side not past the depth, within 1e-6
    /// mm. A wall 11.5 mm deep: the voxel test alone lets a far face reach 12 (RED control).
    func testEveryCellPassesCoresDepthRule() throws {
        let w = wall(depth: 11.5)
        func violations(_ f: LatticeCellField) -> [String] {
            let r = w.regions[0]
            let n = LatticeRegionMask.unit(r.normal)
            return f.steppedCells.compactMap { c in
                let s0 = simd_dot(c.originMM - r.origin, n)
                let sHi = s0 + c.sizeMM * (Swift.max(0, n.x) + Swift.max(0, n.y) + Swift.max(0, n.z))
                let sMid = s0 + 0.5 * c.sizeMM * (n.x + n.y + n.z)
                guard sMid < -1e-6 || sMid > r.depthMM + 1e-6 || sHi > r.depthMM + 1e-6 else { return nil }
                return String(format: "%.2f mm from %.3f to %.3f (centre %.3f)", c.sizeMM, s0, sHi, sMid)
            }
        }
        for dyadic in [true, false] {
            let f = try bake(w, cell: 4, dyadic: dyadic)
            XCTAssertEqual(violations(f), [], "★ core's depth rule (dyadic \(dyadic))")
            XCTAssertFalse(f.steppedCells.isEmpty)
            let saved = LatticePreviewOccupancy.coreDepthRuleEnabled
            LatticePreviewOccupancy.coreDepthRuleEnabled = false
            defer { LatticePreviewOccupancy.coreDepthRuleEnabled = saved }
            let old = try bake(w, cell: 4, dyadic: dyadic)
            let v = violations(old)
            XCTAssertGreaterThan(v.count, 0, "RED control: the voxel test alone passes the depth (dyadic \(dyadic))")
            print("PLAN-RULES depth 11.5 dyadic \(dyadic): \(f.steppedCells.count) cells, \(violations(f).count) past the depth | "
                  + "voxel test alone: \(old.steppedCells.count) cells, \(v.count) past it, e.g. \(v.prefix(2))")
        }
    }
}
