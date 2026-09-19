import XCTest
@testable import TopOptFlows

/// ★ THE GRADE'S STRENGTH (his 2026-09-18): a slider with 0 at the middle, an exponent
/// on the band fraction, saved with the project and carried to both bakes.
final class LatticeGradeStrengthTests: XCTestCase {
    func testTheGammaIsOneAtZeroAndSymmetric() {
        XCTAssertEqual(LatticeSettings.gradeGamma(strength: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeGamma(strength: 1), 0.25, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeGamma(strength: -1), 4, accuracy: 1e-12)
        XCTAssertEqual(LatticeSettings.gradeGamma(strength: 7), 0.25, accuracy: 1e-12, "clamped")
    }
    func testItPersistsAndReachesTheWizardAndTheProxyParams() throws {
        var s = LatticeSettings()
        XCTAssertEqual(s.shapeFitGradeStrength, 0)
        s.shapeFitGradeStrength = 0.6
        let back = try JSONDecoder().decode(LatticeSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.shapeFitGradeStrength, 0.6, accuracy: 1e-12)
        let m = LatticeWizardModel(settings: back)
        XCTAssertEqual(m.shapeFitGradeStrength, 0.6, accuracy: 1e-12)
        XCTAssertEqual(m.applied(to: LatticeSettings()).shapeFitGradeStrength, 0.6, accuracy: 1e-12)
    }
}
