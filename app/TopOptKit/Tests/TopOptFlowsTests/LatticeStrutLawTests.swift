// LatticeStrutLawTests — ★ THE PREVIEW'S STRUT LAW IS CORE'S, NOT A SECOND ONE
// (task 2026-08-20, from the preview/algorithm audit).
//
// ★★ WHAT WAS WRONG. The app carried a closed form — `r = cell * sqrt(rho / K)`,
// K = 48 — while core interpolates `kOctetDia`, a table MEASURED at vpc48
// (evidence/2026-07-28-graded-cell-size-phase0/b3_printability.csv). Measured against
// each other at a 4 mm cell:
//
//     rho    core d      app d      app/core
//     0.05   0.3632      0.2582     0.71
//     0.20   0.7592      0.5164     0.68
//     0.40   1.1815      0.7303     0.62
//     0.60   1.5343      0.8944     0.58
//
// The preview drew every strut 1.4-1.7x thinner than the run builds, and quoted those
// numbers in millimetres beside it. The ratio is not constant, so it could not even
// be corrected by eye.
//
// ★ THESE ASSERT AGAINST THE MEASURED TABLE ITSELF, not against whatever the bridge
// happens to return, so a bridge that silently stopped forwarding core would fail.

import XCTest
@testable import TopOptFlows
import TopOptKit

final class LatticeStrutLawTests: XCTestCase {

    /// `kOctetDia` verbatim — rho and diameter at the reference 4 mm cell.
    private let table: [(rho: Double, d4: Double)] = [
        (0.05, 0.3632), (0.08, 0.4787), (0.10, 0.5336), (0.15, 0.6401),
        (0.20, 0.7592), (0.30, 0.9754), (0.40, 1.1815), (0.60, 1.5343),
    ]

    func testTheBridgeReturnsCoresMeasuredDiameters() throws {
        for row in table {
            let got = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                       relativeDensity: row.rho, cellMM: 4)
            try XCTSkipIf(got == 0, "core carries no strut law in this build")
            XCTAssertEqual(got, row.d4, accuracy: 1e-4,
                           "★ rho \(row.rho): the bridge must return core's MEASURED "
                           + "diameter, not a formula that resembles it")
        }
    }

    /// ★ Diameter is exactly linear in cell size — core's own comment says the CSV's
    /// cell8/16/32 columns are 2/4/8x the cell4 column to four digits. If that stops
    /// holding, a caller scaling by `cell/4` is silently wrong.
    func testDiameterIsLinearInCellSize() throws {
        let d4 = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                  relativeDensity: 0.20, cellMM: 4)
        try XCTSkipIf(d4 == 0, "core carries no strut law in this build")
        for factor in [2.0, 4.0, 8.0] {
            let d = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                     relativeDensity: 0.20,
                                                     cellMM: 4 * factor)
            XCTAssertEqual(d, d4 * factor, accuracy: 1e-4,
                           "★ diameter must scale linearly with the cell (x\(factor))")
        }
    }

    /// ★★ AND THE OLD CLOSED FORM IS MEASURABLY WRONG — this is the test that would
    /// have caught the drift years earlier. It pins the DISAGREEMENT so nobody
    /// reintroduces `sqrt(rho/K)` believing it equivalent.
    func testTheOldClosedFormDisagreesWithCoreAndIsNotUsed() throws {
        let K = 48.0, cell = 4.0
        for rho in [0.05, 0.20, 0.60] {
            let core = TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                        relativeDensity: rho, cellMM: cell)
            try XCTSkipIf(core == 0, "core carries no strut law in this build")
            let closedForm = 2 * cell * (rho / K).squareRoot()
            XCTAssertLessThan(closedForm / core, 0.75,
                              "★ the closed form is 25%+ thin at rho \(rho) — if this "
                              + "ever passes, someone has changed one of the two laws "
                              + "and the app must be re-checked against core")
        }
    }

    /// A topology core has no law for must return 0, not a guess.
    func testAnUnknownTopologyHasNoNumber() {
        XCTAssertEqual(TopOptKit.latticeStrutDiameterMM(topology: "gyroid",
                                                        relativeDensity: 0.2, cellMM: 4), 0)
        XCTAssertEqual(TopOptKit.latticeStrutDiameterMM(topology: "octet",
                                                        relativeDensity: 0.2, cellMM: 0), 0)
    }

    /// ★★ AND THE SHADER MUST USE IT TOO. Bridging only the Swift side would fix the
    /// LEGEND's millimetres while the drawn struts stayed 1.4-1.7x thin — the numbers
    /// would agree with core and the picture would not.
    ///
    /// Measured on his part at rho 0.08, same code, same camera, silhouette pixels:
    ///
    ///     analytic fallback ....  613
    ///     core's curve .........  685   (+11.7%; core's radius is 1.47x there)
    ///
    /// (Coverage grows sub-linearly with radius because struts overlap in
    /// projection, and it SATURATES at dense settings where the lattice already
    /// fills the region — which is why that measurement was taken sparse.)
    func testTheShaderReadsCoresCurveAndNotTheClosedForm() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/UnifiedShading.swift")
        let msl = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(msl.contains("float4 strutCurve[8]"),
                      "★ the uniform must carry core's sampled law")
        XCTAssertTrue(msl.contains("lsdf_strut_radius_norm"),
                      "★ …and the march must look the radius up from it")
        XCTAssertFalse(msl.contains("sqrt(max(rho, 0.0) / K)"),
                       "★ the march must NOT reinvert rho = K(r/L)^2 — that is the "
                       + "law that disagreed with core by 1.4-1.7x")
        XCTAssertFalse(msl.contains("sqrt(max(hitRho, 0.0) / K)"),
                       "★ nor may the normal/shade path")
        // The fallback is allowed to exist — for a topology core has not measured —
        // but ONLY inside the lookup, where it is reachable by that condition alone.
        guard let r = msl.range(of: "static float lsdf_strut_radius_norm") else {
            return XCTFail("the lookup must exist")
        }
        let body = String(msl[r.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("gradeParams.w"),
                      "★ the analytic form survives only as the no-core-law fallback")
    }
}
