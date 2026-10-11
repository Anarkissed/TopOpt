import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ DEFAULT GRADE'S BASE RULE — the reviewer's ruling (b), 2026-10-11 00:35, approved by the maintainer:
/// "do (b) now and (a) as its own round … it must be deterministic, and it must not itself have a cliff of the
/// kind you just found".
///
/// His 68BF7B74 face 23 middle facet (job region 4): P1's footprint moved its measured wall one voxel
/// (20.6245 → 18.9058 mm, a trimodal walk whose median sits in a valley), the Default Grade cell moved
/// 10.31 → 9.45, and 9.45's half (2.36 mm) is over the 2.25 mm floor but does not print open — so the halving
/// ladder ENDED AT PRINTS-OPEN on 4.73 mm: 342 cells and a see-through slit where 1,524 had been.
/// The rule: under Default Grade, a base whose ladder ends at prints-open gives way to the first larger
/// whole-number fit that prints open and whose ladder ends at the floor.
@MainActor
final class LatticeDefaultGradeBaseRuleTests: XCTestCase {
    private let floor = 2.25, bead = 0.45

    private func open(_ c: Double) -> Bool {
        LatticePreviewOccupancy.printsOpen(cellMM: c, lineWidthMM: bead, latticeID: "octet")
    }
    private func rule(_ w: Double, _ cell: Double) -> Double {
        LatticeRegionCells.cellWhoseHalvesEndAtTheFloor(depthMM: w, cellMM: cell, tileFloorMM: floor,
                                                        bakeFloorMM: floor, beadMM: bead, printsOpen: open)
    }
    /// The finest rung of a halving ladder, the bake's way (halve while the half is over the floor and open).
    private func finest(_ base: Double) -> Double {
        var r = base
        while r / 2 >= floor - 1e-9, r / 2 > bead, open(r / 2) { r /= 2 }
        return r
    }

    /// His project's settings: the octet, a 0.45 mm bead, Aesthetic (2 cells per member), Allow quilt off.
    private func project(_ algorithm: String) -> ProjectModel {
        let p = ProjectModel(id: UUID(), name: "M2", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.printParams.strutLineWidthMM = bead
        p.lattice.topologyID = "octet"
        p.lattice.algorithm = algorithm
        p.lattice.stageMode = .aesthetic
        p.lattice.allowQuilt = false
        return p
    }
    private func face(depth: Double) -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: .include, kind: .face)
        r.origin = .zero; r.normal = SIMD3(0, 0, 1); r.depthMM = depth; r.halfUMM = 20; r.halfWMM = 20
        return r
    }

    /// ★ RED before (b), through the production derivation (`regionCells`, the per-region bake's cell): his
    /// middle facet's 18.9058 mm wall was 2 × 9.45, a ladder that ends at prints-open on 4.73. Now 3 × 6.30,
    /// whose ladder ends at the floor on 3.15.
    func testHisMiddleFacetTakesAFitWhoseHalvesEndAtTheFloor() {
        XCTAssertEqual(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: bead, allowQuilt: false) ?? 0, floor,
                       accuracy: 1e-9)
        let w = 18.905773997306824
        let p = project("doubled")
        let cell = LatticeRegionCells.regionCells(project: p, scene: nil, regions: [face(depth: w)],
                                                  widthPercentile: 0.5, quiltStep: true).first?.cellMM ?? 0
        XCTAssertEqual(cell, w / 3, accuracy: 1e-9, "★ three across: 6.30 mm, not 9.45")
        XCTAssertEqual(finest(cell), w / 6, accuracy: 1e-9, "★ its ladder ends at the floor on 3.15 mm")
        XCTAssertEqual(finest(w / 2), w / 4, accuracy: 1e-9, "the old base's ladder ended at prints-open on 4.73")
        // controls: Stepped's any-step menu has no such stop, and the walk before P1 (20.62 mm) already reached
        p.lattice.algorithm = "stepped"
        XCTAssertEqual(LatticeRegionCells.regionCells(project: p, scene: nil, regions: [face(depth: w)],
                                                      widthPercentile: 0.5, quiltStep: true).first?.cellMM ?? 0,
                       w / 2, accuracy: 1e-9, "★ Stepped keeps today's fit")
        p.lattice.algorithm = "doubled"
        let before = 20.624480724334717
        XCTAssertEqual(LatticeRegionCells.regionCells(project: p, scene: nil, regions: [face(depth: before)],
                                                      widthPercentile: 0.5, quiltStep: true).first?.cellMM ?? 0,
                       before / 2, accuracy: 1e-9, "control: 10.31's ladder ends at the floor on 2.58")
        // and only the bake's per-region cell (quiltStep) moves — not the other readers of the derivation
        XCTAssertEqual(LatticeRegionCells.regionCells(project: p, scene: nil, regions: [face(depth: w)],
                                                      widthPercentile: 0.5, quiltStep: false).first?.cellMM ?? 0,
                       w / 2, accuracy: 1e-9)
    }

    /// The rule on his walls, case by case.
    func testTheRuleOnHisWalls() {
        XCTAssertEqual(rule(18.905773997306824, 18.905773997306824 / 2), 18.905773997306824 / 3, accuracy: 1e-9,
                       "68BF7B74 r4: 9.45 → 6.30")
        XCTAssertEqual(rule(14, 14.0 / 3), 3.5, accuracy: 1e-9,
                       "3418E167 Default Grade r1: 4.67 (half 2.33 over the floor, not open) → 3.50, four across 14")
        // unchanged: their ladders end at the floor
        XCTAssertEqual(rule(20.624480724334717, 10.312240362167358), 10.312240362167358, "10.31 → 5.16 → 2.58")
        XCTAssertEqual(rule(12.030947089195251, 4.010315696398417), 4.010315696398417, "face 2's 4.01: half 2.005 under the floor")
        XCTAssertEqual(rule(12, 12), 12, "12 → 6 → 3, half 1.5 under the floor")
        XCTAssertEqual(rule(12.030947089195251, 6.015473544597626), 6.015473544597626, "6.02 → 3.01")
        XCTAssertEqual(rule(4, 4), 4, "102117B9 r129's 4.0: half 2.0 under the floor")
        // ★ never a quilt base: a one-cell 4.6 mm wall's only smaller fit (2.3 mm) does not print open, so it stays
        XCTAssertFalse(open(2.3))
        XCTAssertEqual(rule(4.6, 4.6), 4.6, "★ none reaches ⇒ the cell stands")
    }

    /// ★ NO CLIFF OF THE KIND FOUND. Sweeping the wall in 1 µm steps, the finest rung's largest jump between
    /// neighbouring walls is today 2× at every cells-across count (a base on either side of 4 × 2.3709 mm);
    /// under (b) it is 1.5× at n₀ = 2 and 3. The sweep is its own positive control: without the rule it finds
    /// the 2× (a sweep that measured nothing would report 1). Core's predicate is monotone in the cell, so the
    /// sweep reads its crossing, found once by bisecting `lattice_prints_open` itself.
    func testTheFinestRungNeverJumpsTwiceOverAtTwoOrThreeAcross() {
        guard let crossing = TopOptKit.printsOpenCrossingMM(topology: "octet", beadMM: bead) else {
            return XCTFail("core calls the octet live")
        }
        XCTAssertEqual(crossing, 2.370908, accuracy: 1e-6, "core's own 0.20 crossing at a 0.45 mm bead")
        let fast: (Double) -> Bool = { $0 >= crossing }
        func ruleFast(_ w: Double, _ c: Double) -> Double {
            LatticeRegionCells.cellWhoseHalvesEndAtTheFloor(depthMM: w, cellMM: c, tileFloorMM: floor, bakeFloorMM: floor,
                                                            beadMM: bead, printsOpen: fast)
        }
        func finestFast(_ base: Double) -> Double {
            var r = base
            while r / 2 >= floor - 1e-9, r / 2 > bead, fast(r / 2) { r /= 2 }
            return r
        }
        for n0 in [2.0, 3.0] {
            var worstToday = 1.0, worstRule = 1.0
            var prevToday: Double?, prevRule: Double?
            var w = floor * n0
            while w < 40 {
                let c = w / n0, b = ruleFast(w, c)
                let today = finestFast(c), withRule = finestFast(b)
                if let p = prevToday { worstToday = Swift.max(worstToday, Swift.max(p, today) / Swift.min(p, today)) }
                if let p = prevRule { worstRule = Swift.max(worstRule, Swift.max(p, withRule) / Swift.min(p, withRule)) }
                prevToday = today; prevRule = withRule
                if b != c, !fast(b) { XCTFail("★ never a quilt base (w \(w) → \(b))") }
                w += 0.001
            }
            print("BASE-RULE n0=\(Int(n0)): worst finest-rung jump today \(String(format: "%.3f", worstToday)), "
                  + "with (b) \(String(format: "%.3f", worstRule))")
            XCTAssertGreaterThan(worstToday, 1.9, "positive control: today's 2× is there to find (n0 \(n0))")
            XCTAssertLessThanOrEqual(worstRule, 1.5 + 1e-3, "★ at most 1.5× under (b) (n0 \(n0))")
        }
    }

    /// ★ THE CACHED THRESHOLD IS CORE'S ANSWER: core's predicate is a threshold in the cell, found once per
    /// bead by bisecting core itself; every cached answer equals a direct ask — at the two adjacent doubles
    /// either side of the crossing, and across 2.000–5.998 mm (where the old Swift law agreed too).
    func testTheCachedThresholdIsCoresAnswer() {
        guard let c = TopOptKit.printsOpenCrossingMM(topology: "octet", beadMM: bead) else { return XCTFail("octet") }
        for cell in [c, c.nextUp, c.nextDown, c.nextDown.nextDown, 2.0, 2.3706, 2.3712, 4.73, 6.3, 12] {
            XCTAssertEqual(TopOptKit.latticePrintsOpen(topology: "octet", cellMM: cell, beadMM: bead),
                           TopOptKit.askCorePrintsOpen(topology: "octet", cellMM: cell, beadMM: bead), "at \(cell)")
        }
        XCTAssertEqual(TopOptKit.askCorePrintsOpen(topology: "octet", cellMM: c, beadMM: bead), true, "the crossing opens")
        XCTAssertEqual(TopOptKit.askCorePrintsOpen(topology: "octet", cellMM: c.nextDown, beadMM: bead), false,
                       "the double below does not")
        let law = LatticeType.octet
        var t0 = Date(); var direct = 0, cached = 0, swift = 0
        for i in 0..<200 where TopOptKit.askCorePrintsOpen(topology: "octet", cellMM: 2 + Double(i) * 0.02, beadMM: bead) == true { direct += 1 }
        let tDirect = Date().timeIntervalSince(t0) / 200
        t0 = Date()
        for i in 0..<200 where TopOptKit.latticePrintsOpen(topology: "octet", cellMM: 2 + Double(i) * 0.02, beadMM: bead) == true { cached += 1 }
        let tCached = Date().timeIntervalSince(t0) / 200
        for i in 0..<200 where law.printabilityDensityFloor(lineWidthMM: bead, cellMM: 2 + Double(i) * 0.02)
            <= LatticePreviewOccupancy.finestRungMaxDensity + 1e-9 { swift += 1 }
        print("PRINTS-OPEN: crossing \(c) mm; an ask: direct \(String(format: "%.3f", tDirect * 1000)) ms, "
              + "cached \(String(format: "%.4f", tCached * 1000)) ms; open \(direct) / \(cached) / Swift law \(swift) of 200")
        XCTAssertEqual(direct, cached)
        XCTAssertEqual(direct, swift, "the Swift law it replaces agrees on 2.00–5.98 mm")
    }
}
