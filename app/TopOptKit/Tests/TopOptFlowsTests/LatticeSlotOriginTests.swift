import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ REVIEWER, 2026-10-08 (approved by the maintainer): "Send slot_origin_mm from the anchor
/// search." Core measures every planned cell's alignment, depth, overlap and grouping from its
/// region's slot origin (stepped_plan.cpp:232-234, 461-463); without one it takes the region's
/// `origin`, which is not the grid the bake packed on. Core at 36f5fdde refused a slot origin
/// standing 1e-6 mm or more off the face plane, so a plan whose grid was off a tilted facet's plane
/// was withheld, and the preview said why. Since K2 (#358 25c6a551) it is a grid PHASE, and depth is
/// measured from the region's own plane: the app sends it (`TopOptKit.regionSlotOriginIsPhase`).
final class LatticeSlotOriginTests: XCTestCase {

    // MARK: the bake

    /// A 40 mm block at 1 mm voxels; A = its −y face (normal +y), B = its −x face (normal +x).
    private func block() -> (occ: LatticeVoxelGrid, demand: LatticeVoxelGrid, regions: [LatticeRegionSpec]) {
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
        let spacing = SIMD3<Float>(repeating: 1)
        return (LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing, values: vals),
                LatticeVoxelGrid(nx: n, ny: n, nz: n, origin: origin, spacing: spacing,
                                 values: [Float](repeating: 0.3, count: vals.count)),
                [face(origin: SIMD3(20, 0, 20), normal: SIMD3(0, 1, 0)),
                 face(origin: SIMD3(0, 20, 20), normal: SIMD3(1, 0, 0))])
    }

    /// Core's own test for a doubled cell (stepped_plan.cpp, `on_own_size_grid`): its offset from
    /// the slot origin is a whole number of its own size, per axis, within 1e-6.
    private static func onOwnSizeGrid(_ c: LatticeSteppedCell, from so: SIMD3<Double>) -> Bool {
        (0..<3).allSatisfy { a in
            let q = (c.originMM[a] - so[a]) / c.sizeMM
            return abs(q - (q + 0.5).rounded(.down)) <= 1e-6
        }
    }

    /// ★ Every baked cell carries its region's grid; one grid per region; that grid lies IN the
    /// face plane (so core takes it), and every cell is on its own size's grid from it — the
    /// test core's R6 applies to a doubled plan.
    func testEveryCellCarriesItsRegionsGridAndSitsOnIt() throws {
        let s = block()
        var st = LatticePreviewOccupancy.OctreeBakeStats()
        let f = try XCTUnwrap(LatticePreviewOccupancy.octreeCellField(
            occupancy: s.occ, demand: s.demand, regions: s.regions, cellMM: [6, 6], lineWidthMM: 0.45,
            realFloorMM: 1.5, shapeFitBandMM: 0, shapeFit: false, densityLo: 0.1, densityHi: 0.3,
            densityGamma: 1, latticeID: "octet", dyadicSteps: true, stats: &st), "no bake")
        XCTAssertFalse(f.steppedCells.isEmpty)
        var grids: [Int: Set<[Double]>] = [:]
        var offOwnGrid = 0, offRegionOriginGrid = 0
        for c in f.steppedCells {
            let so = try XCTUnwrap(c.slotOriginMM, "★ a baked cell states its grid")
            grids[c.region, default: []].insert([so.x, so.y, so.z])
            if !Self.onOwnSizeGrid(c, from: so) { offOwnGrid += 1 }
            // what core measures from WITHOUT the key: the region's own origin
            if !Self.onOwnSizeGrid(c, from: s.regions[c.region].origin) { offRegionOriginGrid += 1 }
        }
        XCTAssertEqual(grids.count, 2, "both faces planned")
        XCTAssertTrue(grids.values.allSatisfy { $0.count == 1 }, "★ one grid per region: \(grids)")
        XCTAssertEqual(offOwnGrid, 0, "★ every cell on its own size's grid from its slot origin")
        // ★ POSITIVE CONTROL: the faces' origins (20, ·, 20) are off the anchor's grid (−2), so
        // without the key core's R6 would measure from the wrong point and refuse every cell
        XCTAssertEqual(offRegionOriginGrid, f.steppedCells.count, "the fixture is not vacuous")
        for (r, g) in grids {
            let so = SIMD3<Double>(g.first![0], g.first![1], g.first![2])
            XCTAssertEqual(simd_dot(so - s.regions[r].origin, s.regions[r].normal), 0, "★ in the face plane")
        }
        let wire = LatticeSteppedCellWire.wire(f.steppedCells, regions: s.regions)
        guard case .success(let origins) = LatticeSteppedCellWire.slotOrigins(wire, regions: s.regions,
                                                                              slotOriginWired: true) else {
            return XCTFail("an axis-aligned plan is not withheld")
        }
        XCTAssertEqual(Set(origins.keys), [1, 2])
        print("SLOT-ORIGIN cells=\(f.steppedCells.count) anchor=\(st.anchorShiftMM) "
              + "offOwnGrid=\(offOwnGrid) offRegionOriginGrid=\(offRegionOriginGrid) origins=\(origins)")
    }

    // MARK: the check, against core's own parser

    private func tilted(_ origin: SIMD3<Double>, _ normal: SIMD3<Double>,
                        role: LatticeGroupRole = .include) -> LatticeRegionSpec {
        var r = LatticeRegionSpec(role: role, kind: .face)
        r.origin = origin; r.normal = normal; r.depthMM = 4; r.halfUMM = 5; r.halfWMM = 5
        return r
    }

    /// Core's verdict on one include face carrying `slot`: nil = accepted.
    private func coreVerdict(origin: SIMD3<Double>, normal: SIMD3<Double>, slot: SIMD3<Double>) -> String? {
        func j(_ v: SIMD3<Double>) -> String { "[\(v.x), \(v.y), \(v.z)]" }
        var text = String(decoding: TopOptKit.regionSlotOriginProbeJob(", \"slot_origin_mm\": \(j(slot))"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"origin\": [0, 0, 0], \"normal\": [0, 0, 1]",
                                         with: "\"origin\": \(j(origin)), \"normal\": \(j(normal))")
        return TopOptKit.jobSchemaError(Data(text.utf8))
    }

    /// ★★ PARITY WITH CORE'S PARSER: the app withholds exactly the slot origins core refuses —
    /// on the plane, a hair off either side of 1e-6, and a tilted facet's world-axis grid (the
    /// bake's: the anchor in-plane, the plane along the ladder axis).
    /// ★ K2 (#358 25c6a551, the reviewer 2026-10-09): core now takes the slot origin as a grid PHASE
    /// and measures depth from the region's own plane, so it refuses NONE of these, and the app
    /// withholds none. The old in-plane rule stays as the CONTROL, for an older core: under it the
    /// app withholds the tilted grid and the hair-off point, exactly as that core did.
    func testTheAppWithholdsExactlyWhatCoreRefuses() throws {
        XCTAssertTrue(TopOptKit.regionSlotOriginWired, "the linked core takes slot_origin_mm (36f5fdde+)")
        XCTAssertTrue(TopOptKit.regionSlotOriginIsPhase, "★ the linked core takes it as a phase (K2, 3952c411+)")
        let n18 = simd_normalize(SIMD3<Double>(0.95, 0, -0.31))      // his face 23's foot facet, 18°
        let o = SIMD3<Double>(10, 5, 7)
        var axisGrid = SIMD3<Double>(-2.25, -1.5, -2.75); axisGrid.x = o.x   // the bake's slot origin, axis x
        let cases: [(String, SIMD3<Double>, SIMD3<Double>, Bool)] = [
            // name, normal, slot, refused by the OLD in-plane rule
            ("in plane", SIMD3(0, 0, 1), SIMD3(1.5, -0.25, 0), false),
            ("2e-6 off", SIMD3(0, 0, 1), SIMD3(1.5, -0.25, 2e-6), true),
            ("5e-7 off", SIMD3(0, 0, 1), SIMD3(1.5, -0.25, 5e-7), false),
            ("short normal, 2e-6 off (unit test, as core)", SIMD3(0, 0, 0.001), SIMD3(3, 4, 2e-6), true),
            ("tilted 18°, the bake's grid", n18, axisGrid, true),
            ("tilted 18°, projected onto the plane", n18, axisGrid - simd_dot(axisGrid - o, n18) * n18, false),
        ]
        var rows: [String] = []
        for (name, normal, slot, oldRefuses) in cases {
            let origin = normal == n18 ? o : SIMD3<Double>(0, 0, 0)
            let core = coreVerdict(origin: origin, normal: normal, slot: slot)
            let cell = LatticeSteppedCellWire(regionID: 1, originMM: slot, sizeMM: 3, slotOriginMM: slot)
            func withholds(phase: Bool) -> Bool {
                if case .failure(let why) = LatticeSteppedCellWire.slotOrigins([cell], regions: [tilted(origin, normal)],
                                                                               slotOriginWired: true, slotOriginIsPhase: phase) {
                    if case .offPlane = why {} else { XCTFail("\(name): \(why)") }
                    return true
                }
                return false
            }
            let app = withholds(phase: TopOptKit.regionSlotOriginIsPhase)
            XCTAssertEqual(app, core != nil, "★ \(name): app \(app ? "withholds" : "sends"), core \(core ?? "accepts")")
            XCTAssertNil(core, "★ K2: core takes \(name) as a phase")
            // ★ CONTROL: the old rule still tells these apart, so the sweep is not vacuous
            XCTAssertEqual(withholds(phase: false), oldRefuses, "control, old core: \(name)")
            rows.append("\(name): core \(core == nil ? "accepts" : "refuses"), app \(app ? "withholds" : "sends"), "
                        + "old rule \(oldRefuses ? "withheld" : "sent")")
        }
        print("SLOT-ORIGIN parity\n  " + rows.joined(separator: "\n  "))
    }

    /// The other reasons a plan is withheld, each named.
    func testTheOtherWithheldReasons() {
        let a = tilted(SIMD3(0, 0, 0), SIMD3(0, 0, 1))
        let ex = tilted(SIMD3(0, 0, 0), SIMD3(0, 0, 1), role: .exclude)
        let g1 = SIMD3<Double>(1, 1, 0), g2 = SIMD3<Double>(2, 1, 0)
        func cell(_ id: Int, _ so: SIMD3<Double>?) -> LatticeSteppedCellWire {
            LatticeSteppedCellWire(regionID: id, originMM: SIMD3(1, 1, 0), sizeMM: 1, slotOriginMM: so)
        }
        func verdict(_ cells: [LatticeSteppedCellWire], _ regions: [LatticeRegionSpec],
                     wired: Bool = true) -> LatticeSteppedCellWire.PlanWithheld? {
            if case .failure(let w) = LatticeSteppedCellWire.slotOrigins(cells, regions: regions, slotOriginWired: wired) { return w }
            return nil
        }
        XCTAssertEqual(verdict([cell(1, g1), cell(1, g2)], [a]), .twoGrids(regionID: 1))
        XCTAssertEqual(verdict([cell(2, g1)], [ex, a]), .noSuchRegion(regionID: 2), "★ the exclude has no id")
        XCTAssertEqual(verdict([cell(1, g1)], [a], wired: false), .slotOriginNotWired)
        XCTAssertNil(verdict([cell(1, g1), cell(1, g1)], [ex, a]))
        XCTAssertNil(verdict([cell(1, nil)], [], wired: false), "a hand-built cell states no grid")
    }

    // MARK: the job

    private func spec(regions: [LatticeRegionSpec], cells: [LatticeSteppedCellWire]) -> LatticeSpec {
        var s = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.4,
                            generateRelativeDensity: 0.2, minRelativeDensity: 0.1, maxRelativeDensity: 0.9,
                            regions: regions)
        s.algorithm = "doubled"
        s.steppedCells = cells
        return s
    }

    private func latticeBlock(_ s: LatticeSpec, plans: Bool) throws -> [String: Any] {
        let original = try JSONSerialization.data(withJSONObject: ["model": "p.step"])
        let data = try RelatticeJobBuilder.build(original: original, designFingerprint: 1,
                                                 achievedVolumeFraction: 0.3, designFileName: "d.3mf",
                                                 lattice: s, steppedCellsWired: true, steppedPlans: plans)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(job["lattice"] as? [String: Any])
    }

    private func slotKeys(_ lat: [String: Any]) -> [[Double]?] {
        ((lat["regions"] as? [[String: Any]]) ?? []).map { ($0["geometry"] as? [String: Any])?["slot_origin_mm"] as? [Double] }
    }
    private func baseKeys(_ lat: [String: Any]) -> [Double?] {
        ((lat["regions"] as? [[String: Any]]) ?? []).map { ($0["geometry"] as? [String: Any])?["plan_base_cell_mm"] as? Double }
    }

    /// ★ The grid goes on the PLANNED include faces only, with the cells; never without the switch;
    /// and a plan with a tilted grid goes out as NO plan at all — never cells without their grid.
    func testTheJobCarriesTheGridOnPlannedIncludesOnly() throws {
        let ex = tilted(SIMD3(0, 0, 0), SIMD3(0, 0, 1), role: .exclude)
        let a = tilted(SIMD3(20, 0, 20), SIMD3(0, 1, 0))
        let b = tilted(SIMD3(0, 20, 20), SIMD3(1, 0, 0))
        let ga = SIMD3<Double>(-1.25, 0, -2), gb = SIMD3<Double>(0, -1.25, -2)
        // the cells sit on those grids INSIDE their regions' 10 mm boxes (a cell wholly outside its region's
        // polygon withholds the plan, `PlanWithheld.cellOutsideRegion`; they were at x 1.75…10.75, outside 15…25)
        let cells = [LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(16.75, 0, 16), sizeMM: 6, slotOriginMM: ga,
                                            planBaseCellMM: 12),
                     LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(16.75, 6, 16), sizeMM: 3, slotOriginMM: ga,
                                            planBaseCellMM: 12)]
        let on = try latticeBlock(spec(regions: [ex, a, b], cells: cells), plans: true)
        XCTAssertEqual((on["stepped_cells"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(slotKeys(on), [nil, [-1.25, 0, -2], nil], "★ only region 1 (job index 1) was planned")
        XCTAssertEqual(baseKeys(on), [nil, 12, nil], "★ K1: the planned region carries its ladder's base")

        let off = try latticeBlock(spec(regions: [ex, a, b], cells: cells), plans: false)
        XCTAssertNil(off["stepped_cells"]); XCTAssertEqual(slotKeys(off), [nil, nil, nil], "★ the switch is off")
        XCTAssertEqual(baseKeys(off), [nil, nil, nil])

        // ★ K2: a tilted facet's grid now goes, as a phase — on the linked core
        var bt = b; bt.normal = simd_normalize(SIMD3(0.95, 0, -0.31))
        let both = cells + [LatticeSteppedCellWire(regionID: 2, originMM: SIMD3(0, 16.75, 16), sizeMM: 6, slotOriginMM: gb,
                                                   planBaseCellMM: 6)]
        let tiltedJob = try latticeBlock(spec(regions: [ex, a, bt], cells: both), plans: true)
        XCTAssertEqual((tiltedJob["stepped_cells"] as? [[String: Any]])?.count, 3, "★ K2: sent whole")
        XCTAssertEqual(slotKeys(tiltedJob), [nil, [-1.25, 0, -2], [0, -1.25, -2]])
        XCTAssertEqual(baseKeys(tiltedJob), [nil, 12, 6], "★ each region its own ladder's base")
        // …and on an older core the in-plane rule withholds it whole, as before (the control)
        var withheldBlock: [String: Any] = ["regions": [ex, a, bt].map { $0.wireDictionary }]
        XCTAssertEqual(LatticeSteppedCellWire.writePlan(into: &withheldBlock, for: spec(regions: [ex, a, bt], cells: both),
                                                        wired: true, enabled: true, slotOriginIsPhase: false),
                       .offPlane(regionID: 2, offsetMM: simd_dot(gb - bt.origin, bt.normal)))
        XCTAssertNil(withheldBlock["stepped_cells"], "★ withheld whole")
        XCTAssertEqual(slotKeys(withheldBlock), [nil, nil, nil])
        XCTAssertEqual(baseKeys(withheldBlock), [nil, nil, nil])

        // ★ ONE WRITER: both job builders call it, neither writes the key by hand
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        for f in ["RemoteRunner.swift", "RelatticeRunner.swift"] {
            let src = try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/" + f), encoding: .utf8)
            XCTAssertTrue(src.contains("LatticeSteppedCellWire.writePlan(into: &block"), f)
            XCTAssertFalse(src.contains("block[\"stepped_cells\"] ="), f)
        }
    }

    // MARK: the preview

    /// ★ "Where core can't, it says so BEFORE a run": with the switch on and the plan withheld,
    /// the line says why; with the switch off the old line stands; nothing withheld, no line.
    func testThePreviewSaysWhyThePlanCannotGo() throws {
        let s = LatticePreviewSummaryValues(interiorVoxelCount: 1, previewLabel: "doubled · 6.00 mm",
                                            algorithmName: "doubled")
        let why = LatticeSteppedCellWire.PlanWithheld.offPlane(regionID: 3, offsetMM: 0.4)
        let withheld = try XCTUnwrap(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: s,
                                                               plansWired: true, plansEnabled: true, planWithheld: why))
        XCTAssertTrue(withheld.text.contains(LatticePreviewBanner.planWithheldSentence + why.reason), withheld.text)
        XCTAssertTrue(withheld.text.contains("region 3"))
        XCTAssertEqual(withheld.caption, LatticePreviewBanner.planNotSentCaption)
        let sent = try XCTUnwrap(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: s,
                                                           plansWired: true, plansEnabled: true))
        XCTAssertFalse(sent.text.contains(LatticePreviewBanner.planWithheldSentence))
        XCTAssertFalse(sent.text.contains(LatticePreviewBanner.planNotSentSentence))
        let switchOff = try XCTUnwrap(LatticePreviewBanner.make(previewOn: true, hasModel: true, scene: s,
                                                                plansWired: true, plansEnabled: false, planWithheld: why))
        XCTAssertTrue(switchOff.text.contains(LatticePreviewBanner.planNotSentSentence))
        XCTAssertFalse(switchOff.text.contains(LatticePreviewBanner.planWithheldSentence), "one line, not two")
    }
}
