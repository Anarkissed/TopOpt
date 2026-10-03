import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ MAINTAINER, 2026-10-02 — RULING 5 (R12, one definition): the octet aesthetic density ceiling
/// is CORE'S (`octet_aesthetic_density_ceiling()`, bridged now; `lattice_aesthetic_density_ceiling`
/// at the next sync, identical by core's own == test). The app's 24-step bisection of the same
/// diameter table stays only as a test oracle, pinned to core within its own tolerance.
final class LatticeAestheticCeilingFromCoreTests: XCTestCase {

    private let oracleTolerance = 1.0 / Double(1 << 25)   // half the 2^-24 interval

    private var core: Double {
        get throws { try XCTUnwrap(TopOptKit.latticeAestheticDensityCeiling(topology: "octet"), "core has an octet ceiling") }
    }

    /// Core's number: the preimage of strut/cell 0.20 (core's own comment: 0.218871). None for a
    /// type core has not measured.
    func testCoreHasTheOctetCeilingAndNoOther() throws {
        XCTAssertEqual(try core, 0.218871, accuracy: 1e-6)
        for id in ["sc", "bcc", "fcc", "kelvin", "rhombic", "gyroid", "nonsense"] {
            XCTAssertNil(TopOptKit.latticeAestheticDensityCeiling(topology: id), id)
        }
    }

    /// The app reads core's number, exactly, at every cell (core's table is linear in the cell).
    func testTheAppReadsCoresNumberExactly() throws {
        let c = try core
        for cell in [1.6, 2.2, 4.0, 8.0, 12.0] {
            XCTAssertEqual(LatticeType.octet.aestheticDensityCeiling(cellMM: cell), c,
                           "★ cell \(cell): the app's ceiling IS core's — one definition")
        }
        XCTAssertEqual(LatticeType.sc.aestheticDensityCeiling(cellMM: 4), 1, "no ceiling: nothing capped")
    }

    /// The former bisection, kept as an oracle: within its own tolerance of core's value — and
    /// visibly NOT equal (2.9e-8 away), so a regression to it is caught by the exact tests.
    func testTheBisectionOracleAgreesWithinItsTolerance() throws {
        let c = try core
        for cell in [1.6, 4.0, 8.0, 12.0] {
            let o = LatticeType.octet.aestheticDensityCeilingOracle(cellMM: cell)
            XCTAssertLessThanOrEqual(abs(o - c), oracleTolerance, "cell \(cell): oracle \(o) vs core \(c)")
        }
        XCTAssertNotEqual(LatticeType.octet.aestheticDensityCeilingOracle(cellMM: 8), c,
                          "the oracle is a bisection, not core's number — the exact tests can tell them apart")
    }

    /// A graded octet job carries core's number, bit for bit.
    func testAGradedOctetJobCarriesCoresCeiling() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "max_relative_density") else { throw XCTSkip("core takes no cap") }
        var lat = LatticeSettings(enabled: true)
        lat.densityMode = .sim
        lat.cellMM = 8
        let spec = try XCTUnwrap(lat.runSpec(limits: TopOptKit.latticeLimits(topology: "octet"),
                                             generatable: true, lineWidthMM: 0.45))
        let g = try XCTUnwrap(spec.gradingDictionary())
        XCTAssertEqual(try XCTUnwrap(g["max_relative_density"] as? Double), try core,
                       "★ the job's max_relative_density is core's ceiling")
    }
}
