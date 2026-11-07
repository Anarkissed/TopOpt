import XCTest
import TopOptKit
@testable import TopOptFlows
final class TmpFillProbe: XCTestCase {
    func testHowSolidCanAnOctetGet() {
        let lat = LatticeType.octet
        print("rho = 1.0 — the densest the law allows:")
        for cell in [5.0, 6.0, 8.0, 10.31, 13.0] {
            let d = 2 * lat.strutRadiusMM(relativeDensity: 1.0, cellMM: cell)
            print(String(format: "  cell %5.2f mm -> strut %5.2f mm = %.1f%% of the cell across",
                         cell, d, 100 * d / cell))
        }
    }
}
