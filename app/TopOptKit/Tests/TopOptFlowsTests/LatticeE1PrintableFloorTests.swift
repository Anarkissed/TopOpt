import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ E1 (#358 26a37f64; the reviewer's ruling, 2026-10-08): "when #358 pushes
/// lattice_min_printable_cell_mm, merge it, delete the bridge's own composition, call core's
/// function, and pin the literals 2.25 / 1.173." Core's ONE answer to "the smallest cell that
/// prints", at the cap the job writes; and the per-region derivation at that same cap.
final class LatticeE1PrintableFloorTests: XCTestCase {

    private var octetCap: Double {
        LatticeSettings.jobDensityCap(topologyID: "octet", allowQuilt: false)
    }

    /// The literals, at a 0.45 mm bead: 2.25 mm at the job's octet cap, 1.173173434 mm uncapped
    /// (Allow quilt on). Literals, so a drift in either is seen.
    func testCoresFloorAtTheCapAndUncapped() throws {
        XCTAssertGreaterThan(octetCap, 0.2); XCTAssertLessThan(octetCap, 0.25)
        let capped = try XCTUnwrap(TopOptKit.latticeMinPrintableCellMM(topology: "octet", minExtrudableWidthMM: 0.45,
                                                                        maxRelativeDensity: octetCap))
        XCTAssertEqual(capped, 2.25, accuracy: 1e-9, "★ the floor grade_lattice applies")
        let open = try XCTUnwrap(TopOptKit.latticeMinPrintableCellMM(topology: "octet", minExtrudableWidthMM: 0.45,
                                                                      maxRelativeDensity: 0))
        XCTAssertEqual(open, 1.173173434, accuracy: 1e-9, "★ uncapped: Allow quilt on")
        // the tile floor reads the same function at the same cap
        XCTAssertEqual(try XCTUnwrap(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: 0.45, allowQuilt: false)),
                       capped, accuracy: 0)
        XCTAssertEqual(try XCTUnwrap(LatticeSettings.tileFloorMM(topologyID: "octet", beadMM: 0.45, allowQuilt: true)),
                       open, accuracy: 0)
    }

    /// Core refuses a cap the band cannot meet, by name; the guard hands Swift no number and core's
    /// reason — never a floor derived from a density core never measured.
    func testACapBelowTheBandIsRefusedInCoresWords() {
        let v = TopOptKit.latticeMinPrintableCellMM(topology: "octet", minExtrudableWidthMM: 0.45, maxRelativeDensity: 0.001)
        XCTAssertTrue(v == nil || v == 0, "no number for a cap below the band: \(String(describing: v))")
        XCTAssertNotNil(TopOptKit.lastCoreRefusal, "★ core's reason rides the guard")
    }

    /// The bridge composes nothing: its function IS core's call through the guard.
    func testTheBridgeCallsCoresFunction() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        let b = try String(contentsOf: u.appendingPathComponent("Sources/TopOptBridge/bridge.cpp"), encoding: .utf8)
        let start = try XCTUnwrap(b.range(of: "double lattice_min_printable_cell_mm(const std::string& topology,"))
        let body = String(b[start.lowerBound...].prefix(1400))
        XCTAssertTrue(body.contains("return topopt::lattice_min_printable_cell_mm(live_topology(topology)"))
        XCTAssertFalse(body.contains("lattice_strut_diameter_mm(topo, rho_hi, 1.0)"), "★ the bridge's own composition is gone")
        XCTAssertFalse(body.contains("std::min(band_top, max_relative_density)"))
    }

    /// The per-region derivation at the job's cap: a 9 mm member at N* = 5 derives 1.8 mm uncapped,
    /// and the run's floor 2.25 at the cap — the D2 disagreement #358 named, now one number.
    func testTheRegionDerivationTakesTheJobsCap() {
        let open = TopOptKit.latticeRegionDerivation(topology: "octet", memberWidthMM: 9, minExtrudableWidthMM: 0.45,
                                                     cellsPerMemberFloor: 5)
        let capped = TopOptKit.latticeRegionDerivation(topology: "octet", memberWidthMM: 9, minExtrudableWidthMM: 0.45,
                                                       cellsPerMemberFloor: 5, maxRelativeDensity: octetCap)
        XCTAssertTrue(open.valid && capped.valid)
        XCTAssertEqual(open.cellMM, 1.8, accuracy: 1e-9, "control: uncapped, 9 / 5")
        XCTAssertEqual(capped.cellMM, 2.25, accuracy: 1e-9, "★ at the job's cap, the run's floor")
        XCTAssertLessThanOrEqual(capped.derivedRelativeDensity, octetCap + 1e-12, "★ never a density the job forbids")
    }

    /// One source for the cap: the aesthetic ceiling unless Allow quilt lifts it; none for organic.
    func testTheJobsCapIsOneSource() throws {
        XCTAssertEqual(LatticeSettings.jobDensityCap(topologyID: "octet", allowQuilt: true), 0)
        XCTAssertEqual(LatticeSettings.jobDensityCap(topologyID: "octet", allowQuilt: false, algorithm: "organic"), 0)
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/" + f), encoding: .utf8)
        }
        XCTAssertTrue(try src("WorkspacePlaceholder.swift").contains("maxRelativeDensity: capCopy)"), "the drawer's card")
        XCTAssertTrue(try src("LatticeRegionCells.swift").contains("maxRelativeDensity: LatticeSettings.jobDensityCap("),
                      "the bake's region cells")
    }
}
