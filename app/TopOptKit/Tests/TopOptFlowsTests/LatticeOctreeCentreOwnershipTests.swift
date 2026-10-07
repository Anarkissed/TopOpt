import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-03, R7: "one owner per cell, decided by its CENTRE, never by
/// declaration order (order-dependent ownership would change the lattice when he reorders
/// walls): the region whose prism contains the cell's centre owns it; a centre inside two
/// prisms goes to the region whose face plane is nearer …; an exact tie goes to the lower
/// region id; cells stay whole."
///
/// Two faces of one block whose prisms meet at the corner, with base cells that do not nest
/// (6 and 4 mm), so their cells overlap there — the stand's facets-into-walls case in miniature.
final class LatticeOctreeCentreOwnershipTests: XCTestCase {

    private struct Scene {
        let occ: LatticeVoxelGrid
        let demand: LatticeVoxelGrid
        let regions: [LatticeRegionSpec]
        let cells: [Double]
    }

    /// A 40 mm block at 1 mm voxels; A = its −y face (normal +y into the part), B = its −x face.
    private func corner() -> Scene {
        let n = 44, origin = SIMD3<Float>(-2, -2, -2)
        var vals = [Float](repeating: 0, count: n * n * n)
        for k in 0..<n { for j in 0..<n { for i in 0..<n {
            let p = SIMD3<Float>(Float(i), Float(j), Float(k)) + origin + 0.5
            if p.x > 0, p.x < 40, p.y > 0, p.y < 40, p.z > 0, p.z < 40 { vals[(k * n + j) * n + i] = 1 }
        }}}
        func face(origin o: SIMD3<Double>, normal: SIMD3<Double>) -> LatticeRegionSpec {
            var r = LatticeRegionSpec(role: .include, kind: .face)
            r.origin = o; r.normal = normal
            r.halfUMM = 19; r.halfWMM = 19; r.depthMM = 12
            let h = 18.0
            r.outlineLoops = [[SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]]
            return r
        }
        let a = face(origin: SIMD3(20, 0, 20), normal: SIMD3(0, 1, 0))
        let b = face(origin: SIMD3(0, 20, 20), normal: SIMD3(1, 0, 0))
        let spacing = SIMD3<Float>(repeating: 1)
        let occ = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vals)
        let demand = LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                      values: [Float](repeating: 0.3, count: vals.count))
        return Scene(occ: occ, demand: demand, regions: [a, b], cells: [6, 4])
    }

    private func bake(_ s: Scene, order: [Int], dyadic: Bool = true,
                      ownership: Bool = true) throws -> (LatticeCellField, LatticePreviewOccupancy.OctreeBakeStats) {
        let saved = LatticePreviewOccupancy.centreOwnershipEnabled
        LatticePreviewOccupancy.centreOwnershipEnabled = ownership
        defer { LatticePreviewOccupancy.centreOwnershipEnabled = saved }
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: order.map { s.regions[$0] },
            cellMM: order.map { s.cells[$0] }, lineWidthMM: 0.45, realFloorMM: 1.5,
            shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3, densityGamma: 1,
            latticeID: "octet", dyadicSteps: dyadic, stats: &st), "no bake")
        return (f, st)
    }

    /// Cells as order-free geometry (the region named by its face normal, not its index).
    private func cellSet(_ f: LatticeCellField, _ s: Scene, order: [Int]) -> Set<String> {
        Set(f.steppedCells.map { c in
            let r = s.regions[order[c.region]]
            return String(format: "%.0f,%.0f,%.0f|%.4f,%.4f,%.4f|%.4f",
                          r.normal.x, r.normal.y, r.normal.z, c.originMM.x, c.originMM.y, c.originMM.z, c.sizeMM)
        })
    }

    private func texelArrays(_ f: LatticeCellField) -> [UInt32] {
        f.field.values.map(\.bitPattern) + f.level.map(\.bitPattern) + f.steppedCellMM.map(\.bitPattern)
            + f.steppedPhase.map(\.bitPattern)
            + f.steppedOrigin.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
    }

    /// Positive-volume overlaps between cells of different regions.
    private func crossOverlaps(_ cells: [LatticeSteppedCell]) -> Int {
        var n = 0
        for i in cells.indices { for j in cells.indices where j > i && cells[i].region != cells[j].region {
            let a = cells[i], b = cells[j]
            var o = true
            for ax in 0..<3 where Swift.min(a.originMM[ax] + a.sizeMM, b.originMM[ax] + b.sizeMM)
                - Swift.max(a.originMM[ax], b.originMM[ax]) <= 1e-6 { o = false }
            if o { n += 1 }
        }}
        return n
    }

    /// ★ The rule acts where the prisms meet, and NOTHING depends on the order the walls arrive in;
    /// with the rule off, the same reorder changes the lattice (the control that the check can see).
    func testOwnershipIsByTheCentreNotTheOrder() throws {
        let s = corner()
        for dyadic in [true, false] {
            let (ab, st) = try bake(s, order: [0, 1], dyadic: dyadic)
            let (ba, _) = try bake(s, order: [1, 0], dyadic: dyadic)
            XCTAssertEqual(ab.field.origin, ba.field.origin, "the same texel grid either way (dyadic \(dyadic))")
            XCTAssertGreaterThan(st.contestedCells, 0, "positive control: the prisms do meet")
            // ★ and the rule acts there — since the step-down (2026-10-07) a yielded cell steps down
            // or is dropped at its finest rung over the rounds, so nothing yields in the painting pass
            XCTAssertGreaterThan(st.cellsSteppedDown + st.cellsDroppedAtFinest, 0, "★ and the rule acts there")
            XCTAssertEqual(cellSet(ab, s, order: [0, 1]), cellSet(ba, s, order: [1, 0]),
                           "★ the plan does not depend on declaration order (dyadic \(dyadic))")
            XCTAssertEqual(texelArrays(ab), texelArrays(ba), "★ nor does the picture (dyadic \(dyadic))")
            // control: declaration order, as before 2026-10-03
            let (offAB, _) = try bake(s, order: [0, 1], dyadic: dyadic, ownership: false)
            let (offBA, _) = try bake(s, order: [1, 0], dyadic: dyadic, ownership: false)
            if offAB.field.origin == offBA.field.origin {
                XCTAssertNotEqual(texelArrays(offAB), texelArrays(offBA),
                                  "control: first-region-wins IS order dependent here (dyadic \(dyadic))")
            }
            print("R7-SYNTH dyadic \(dyadic): contested \(st.contestedCells) yielded \(st.cellsYielded) "
                  + "straddler pairs \(st.straddlerPairs) texels reassigned \(st.texelsReassigned) "
                  + "emptied \(st.cellsEmptied) | cross overlaps on \(crossOverlaps(ab.steppedCells)) "
                  + "off \(crossOverlaps(offAB.steppedCells))")
        }
    }

    /// ★ No kept cell sits where a contesting region owns its centre: for every cell that overlaps
    /// another region's cell, its own region ranks first at its centre among the two.
    func testEveryContestedCellIsOwnedByItsCentre() throws {
        let s = corner()
        let (f, _) = try bake(s, order: [0, 1])
        let cells = f.steppedCells
        func rank(_ r: Int, _ p: SIMD3<Double>) -> (Int, Double) {
            let reg = s.regions[r]
            return (LatticeRegionMask.contains(p, region: reg) ? 0 : 1,
                    abs(simd_dot(p - reg.origin, LatticeRegionMask.unit(reg.normal))))
        }
        var checked = 0
        for a in cells { for b in cells where b.region != a.region {
            var o = true
            for ax in 0..<3 where Swift.min(a.originMM[ax] + a.sizeMM, b.originMM[ax] + b.sizeMM)
                - Swift.max(a.originMM[ax], b.originMM[ax]) <= 1e-6 { o = false }
            guard o else { continue }
            let c = a.originMM + SIMD3<Double>(repeating: 0.5 * a.sizeMM)
            let mine = rank(a.region, c), theirs = rank(b.region, c)
            if theirs.0 == 0 {
                XCTAssertTrue(mine.0 == 0 && (mine.1 < theirs.1 - 1e-9 || (abs(mine.1 - theirs.1) <= 1e-9 && a.region < b.region)),
                              "★ a kept cell whose centre region \(b.region) owns")
            }
            checked += 1
        }}
        XCTAssertGreaterThan(checked, 0, "positive control: there are contested cells left to check")
    }

    /// ★★ THE STEP-DOWN (reviewer, 2026-10-07, ruling 6): "A yielded cell steps down a rung on its
    /// own region's grid. Each child is judged by its own centre; iterate. Stop at the region's
    /// finest rung." The air R7 left where a yielded cell's own share of the seam was shrinks; no
    /// kept cell's centre is another region's (the test above runs with it on); the new cells are
    /// all smaller than their region's base, inside the space its yielded cells had.
    func testAYieldedCellStepsDownOnItsOwnGrid() throws {
        let s = corner()
        let saved = LatticePreviewOccupancy.stepDownEnabled
        defer { LatticePreviewOccupancy.stepDownEnabled = saved }
        for dyadic in [true, false] {
            let (off, _) = try bake(s, order: [0, 1], dyadic: dyadic, ownership: false)
            LatticePreviewOccupancy.stepDownEnabled = false
            let (noStep, stNo) = try bake(s, order: [0, 1], dyadic: dyadic)
            LatticePreviewOccupancy.stepDownEnabled = true
            let (step, st) = try bake(s, order: [0, 1], dyadic: dyadic)
            XCTAssertEqual(off.field.origin, step.field.origin)
            func air(_ f: LatticeCellField) -> Int {
                zip(off.steppedCellMM, f.steppedCellMM).filter { $0.0 > 0 && $0.1 <= 0 }.count
            }
            XCTAssertGreaterThan(stNo.cellsYielded, 0, "positive control: R7 alone yields cells here")
            XCTAssertGreaterThan(st.cellsSteppedDown, 0, "★ yielded cells step down (dyadic \(dyadic))")
            XCTAssertGreaterThanOrEqual(st.stepDownRounds, 1)
            XCTAssertEqual(st.cellsYielded, 0, "the rounds converge: nothing yields in the painting pass")
            XCTAssertLessThan(air(step), air(noStep), "★ the yielded cells' own share is filled (dyadic \(dyadic))")
            let before = Set(noStep.steppedCells.map { "\($0.region)|\($0.originMM)|\($0.sizeMM)" })
            for c in step.steppedCells where !before.contains("\(c.region)|\(c.originMM)|\(c.sizeMM)") {
                XCTAssertLessThan(c.sizeMM, s.cells[c.region] - 1e-9, "a new cell is a smaller rung of its own region")
            }
            print("R7-STEPDOWN-SYNTH dyadic \(dyadic): rounds \(st.stepDownRounds) stepped \(st.cellsSteppedDown) "
                  + "dropped at finest \(st.cellsDroppedAtFinest) | air texels: R7 alone \(air(noStep)) → with the step-down \(air(step)) "
                  + "| cells \(noStep.steppedCells.count) → \(step.steppedCells.count)")
        }
    }

    /// ★ Where no two regions' cells meet, nothing changes: the bake is bit-identical with the rule
    /// on and off.
    func testNothingChangesWhereRegionsDoNotMeet() throws {
        var s = corner()
        // move B to the opposite (+y) face, so the two prisms are 16 mm apart
        var b = s.regions[1]
        b.origin = SIMD3(20, 40, 20); b.normal = SIMD3(0, -1, 0)
        s = Scene(occ: s.occ, demand: s.demand, regions: [s.regions[0], b], cells: s.cells)
        for dyadic in [true, false] {
            let (on, st) = try bake(s, order: [0, 1], dyadic: dyadic)
            let (off, _) = try bake(s, order: [0, 1], dyadic: dyadic, ownership: false)
            XCTAssertEqual(st.contestedCells, 0)
            XCTAssertEqual(texelArrays(on), texelArrays(off), "★ bit-identical (dyadic \(dyadic))")
            XCTAssertEqual(on.steppedCells, off.steppedCells)
        }
    }
}
