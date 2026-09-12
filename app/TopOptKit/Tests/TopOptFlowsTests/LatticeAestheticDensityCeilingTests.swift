import XCTest
@testable import TopOptFlows
import TopOptKit

/// ★★★ THE AESTHETIC CEILING (his ruling, 2026-09-12): every automatic density lands at
/// or below the strut-to-cell ratio where an octet still reads as a lattice; only a
/// stated, manual density may go past it.
final class LatticeAestheticDensityCeilingTests: XCTestCase {

    func testOctetCeilingIsAboutAFifthOfTheCellAtEveryCellSize() {
        let octet = LatticeType.named("octet")
        var rhos: [Double] = []
        for cell in [1.3, 4.0, 6.0, 10.31, 12.03] {
            let rho = octet.aestheticDensityCeiling(cellMM: cell)
            rhos.append(rho)
            // the strut that density draws is the ratio, at this cell
            let d = 2 * octet.strutRadiusMM(relativeDensity: rho, cellMM: cell)
            XCTAssertEqual(d / cell, LatticeType.aestheticStrutRatioCeiling, accuracy: 0.01,
                           "cell \(cell): strut/cell at the ceiling density is \(d / cell)")
        }
        // core's law is linear in the cell, so the ceiling density is the same everywhere
        XCTAssertLessThan(rhos.max()! - rhos.min()!, 0.01, "ceiling drifts with cell size: \(rhos)")
        // and it is a LATTICE density, well under the 0.53 where octet struts touch
        XCTAssertGreaterThan(rhos[1], 0.12); XCTAssertLessThan(rhos[1], 0.32)
    }

    func testTheDemandCapLandsExactlyOnTheCeiling() {
        for gamma in [0.5, 1.0, 2.0] {
            let lo = 0.05, hi = 0.90, ceiling = 0.22
            let cap = LatticeSDFScene.aestheticDemandCap(rhoMin: lo, rhoMax: hi, gamma: gamma,
                                                         ceilingRho: ceiling)
            let drawn = lo + (hi - lo) * pow(cap, gamma)     // the shader's own law
            XCTAssertEqual(drawn, ceiling, accuracy: 1e-9, "gamma \(gamma)")
            XCTAssertGreaterThan(cap, 0); XCTAssertLessThan(cap, 1)
        }
        // nothing to cap when the band already ends under the ceiling
        XCTAssertEqual(LatticeSDFScene.aestheticDemandCap(rhoMin: 0.05, rhoMax: 0.20, gamma: 1,
                                                          ceilingRho: 0.22), 1)
        // a floor above the ceiling caps everything to the floor
        XCTAssertEqual(LatticeSDFScene.aestheticDemandCap(rhoMin: 0.30, rhoMax: 0.90, gamma: 1,
                                                          ceilingRho: 0.22), 0)
    }
}

extension LatticeAestheticDensityCeilingTests {
    func testOnlyOctetHasTheCeiling() {
        XCTAssertTrue(LatticeType.named("octet").hasAestheticCeiling)
        for id in ["sc", "bcc", "bccz", "fcc", "fccz", "diamond"] {
            XCTAssertFalse(LatticeType.named(id).hasAestheticCeiling, id)
            XCTAssertEqual(LatticeType.named(id).aestheticDensityCeiling(cellMM: 6), 1, id)
        }
    }

    func testAllowQuiltDefaultsOffAndRoundTrips() throws {
        var s = LatticeSettings(enabled: true)
        XCTAssertFalse(s.allowQuilt)
        // an older project without the key decodes to OFF
        var noKey = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        noKey.removeValue(forKey: "allowQuilt")
        let decoded = try JSONDecoder().decode(LatticeSettings.self,
                                               from: JSONSerialization.data(withJSONObject: noKey))
        XCTAssertFalse(decoded.allowQuilt)
        s.allowQuilt = true
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.allowQuilt)
    }

    func testManualThicknessIsHeldUnderTheCeilingUnlessQuiltIsAllowed() {
        var s = LatticeSettings(enabled: true)
        s.topologyID = "octet"; s.cellMM = 12; s.simulateStresses = false
        s.manualStrutThicknessMM = 4.6                     // his 63 % strut on a 12 mm cell
        let limits = TopOptKit.latticeLimits(topology: "octet")
        let held = s.manualThicknessDensity(limits: limits)!
        XCTAssertLessThanOrEqual(held, LatticeType.named("octet").aestheticDensityCeiling(cellMM: 12) + 1e-9)
        s.allowQuilt = true
        let free = s.manualThicknessDensity(limits: limits)!
        XCTAssertGreaterThan(free, held)
    }
}
