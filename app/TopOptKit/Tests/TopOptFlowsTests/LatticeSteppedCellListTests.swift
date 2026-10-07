import XCTest
import simd
@testable import TopOptFlows
import TopOptKit

/// ★★ THE CELL LIST GOES TO CORE (maintainer, 2026-09-18: "Send the cell list to
/// core"). The bake records every placed cell; the wire form numbers regions the way
/// core does; the job carries `lattice.stepped_cells` for a Stepped run and nothing
/// else — and only on a core whose schema takes it.
final class LatticeSteppedCellListTests: XCTestCase {

    private func region(role: LatticeGroupRole) -> LatticeRegionSpec {
        var s = LatticeRegionSpec(role: role, kind: .face)
        s.normal = SIMD3(0, 1, 0); s.depthMM = 12; s.halfUMM = 20; s.halfWMM = 20
        return s
    }

    /// Region INDEX (every role, emission order) → region ID (1-based, includes only).
    func testTheWireNumbersIncludeRegionsInJobOrderAndDropsTheRest() {
        let regions = [region(role: .exclude), region(role: .include), region(role: .include)]
        let cells = [LatticeSteppedCell(region: 1, originMM: SIMD3(1, 2, 3), sizeMM: 9),
                     LatticeSteppedCell(region: 0, originMM: SIMD3(0, 0, 0), sizeMM: 3),
                     LatticeSteppedCell(region: 2, originMM: SIMD3(4, 5, 6), sizeMM: 3)]
        let wire = LatticeSteppedCellWire.wire(cells, regions: regions)
        XCTAssertEqual(wire.map { $0.regionID }, [1, 2], "the exclude region's cell is dropped; includes count from 1")
        XCTAssertEqual(wire[0].sizeMM, 9)
        let d = wire[0].wireDictionary
        XCTAssertEqual(d["region_id"] as? Int, 1)
        XCTAssertEqual(d["origin_mm"] as? [Double], [1, 2, 3])
        XCTAssertEqual(d["size_mm"] as? Double, 9)
    }

    /// The key is written for a Stepped spec with a plan on a wired core, and for
    /// NOTHING else — core refuses it under any other algorithm, and an unknown key
    /// kills the job at parse on an older core.
    func testTheBlockCarriesTheKeyOnlyForAWiredSteppedRun() throws {
        var spec = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.4,
                               generateRelativeDensity: 0.2, minRelativeDensity: 0.1,
                               maxRelativeDensity: 0.9)
        spec.algorithm = "doubled"
        spec.steppedCells = [LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(0, 0, 0), sizeMM: 9)]
        // ★ ruling 4 (2026-10-02): only Default Grade, only when the plan switch is on
        XCTAssertEqual(LatticeSteppedCellWire.blockValue(for: spec, wired: true, enabled: true)?.count, 1)
        XCTAssertNil(LatticeSteppedCellWire.blockValue(for: spec, wired: true), "★ the switch is OFF in production")
        XCTAssertNil(LatticeSteppedCellWire.blockValue(for: spec, wired: false, enabled: true), "an older core: no key")
        var stepped = spec; stepped.algorithm = "stepped"
        XCTAssertNil(LatticeSteppedCellWire.blockValue(for: stepped, wired: true, enabled: true),
                     "★ Stepped (any-step) plans stay off in both intents")
        var organic = spec; organic.algorithm = "organic"
        XCTAssertNil(LatticeSteppedCellWire.blockValue(for: organic, wired: true, enabled: true), "never under organic")
        // ruling C: the density rides with the cell, only when the bake graded it
        let dense = LatticeSteppedCellWire(regionID: 1, originMM: SIMD3(0, 0, 0), sizeMM: 9, rho: 0.31)
        XCTAssertEqual(dense.wireDictionary["rho"] as? Double, 0.31)
        XCTAssertNil(spec.steppedCells[0].wireDictionary["rho"], "no rho ⇒ no key")
        var empty = spec; empty.steppedCells = []
        XCTAssertNil(LatticeSteppedCellWire.blockValue(for: empty, wired: true, enabled: true), "no plan ⇒ no key")

        // Through the real builder, wired forced on: the key lands under `lattice`.
        let original = try JSONSerialization.data(withJSONObject: ["model": "p.step"])
        let data = try RelatticeJobBuilder.build(original: original, designFingerprint: 1,
                                                 achievedVolumeFraction: 0.3, designFileName: "d.3mf",
                                                 lattice: spec, steppedCellsWired: true, steppedPlans: true)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lat = try XCTUnwrap(job["lattice"] as? [String: Any])
        let cells = try XCTUnwrap(lat["stepped_cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0]["region_id"] as? Int, 1)
        // ★ THE FLOOR'S KEY IS `stepped_min_tile_mm` (core reply 2, 2026-09-18): never
        // `cell_min_mm` (the swept window) nor `min_cell_mm` (never a key). Pinned on
        // the source, since the schema probe cannot tell a wrong name from an old core.
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSettings.swift"), encoding: .utf8)
        // ★★ Q3(i) (reviewer, 2026-10-05): core's floor at the job's own cap, not four beads
        XCTAssertTrue(src.contains("grading[\"stepped_min_tile_mm\"] = floor"))
        XCTAssertTrue(src.contains("let floor = TopOptKit.latticeMinPrintableCellMM(topology: topologyID, minExtrudableWidthMM: w,"))
        XCTAssertFalse(src.contains("printableFloorBeads"), "★ the four-bead rule is retired")
        XCTAssertFalse(src.contains("grading[\"min_cell_mm\"]"), "★ min_cell_mm was never a key")
        // Documented, not asserted: true only on a core carrying the any-step schema.
        print("steppedCellsWired = \(TopOptKit.steppedCellsWired); "
              + "steppedStructuralCertificationWired = \(TopOptKit.steppedStructuralCertificationWired)")
    }

    /// Structural: the menu reaches the printability floor alone — sixths of a 12 at
    /// 2.0 mm, and with them 10 — where the aesthetic quilt bound stops at fifths.
    func testTheStructuralMenuIsBoundedByTheFloorAlone() {
        let aesthetic = LatticePreviewOccupancy.steppedSizeMenu(base: 12, floorMM: 1.8, lineWidthMM: 0.45, latticeID: "octet")
        let structural = LatticePreviewOccupancy.steppedSizeMenu(base: 12, floorMM: 1.8, lineWidthMM: 0.45, latticeID: "octet",
                                                                 printsOpenBound: false)
        XCTAssertFalse(aesthetic.contains { abs($0 - 2) < 1e-9 }, "aesthetic: 2.0 is a quilt: \(aesthetic)")
        XCTAssertFalse(aesthetic.contains { abs($0 - 10) < 1e-9 })
        XCTAssertTrue(structural.contains { abs($0 - 2) < 1e-9 }, "structural: the floor alone: \(structural)")
        XCTAssertTrue(structural.contains { abs($0 - 10) < 1e-9 })
        let floored = LatticePreviewOccupancy.steppedSizeMenu(base: 12, floorMM: 2.5, lineWidthMM: 0.45, latticeID: "octet",
                                                              printsOpenBound: false)
        XCTAssertFalse(floored.contains { abs($0 - 2) < 1e-9 }, "…and the floor still binds: \(floored)")
    }
}
