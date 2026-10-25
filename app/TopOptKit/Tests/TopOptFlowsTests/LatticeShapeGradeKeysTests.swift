import XCTest
@testable import TopOptFlows
import TopOptKit

/// ★ THE SHAPE GRADE ON THE WIRE (core reply 5, 2026-09-20): `grading.shape_grade`
/// defaults to false in core and false means NO outline beam, so a job that wants the
/// beam must say so; the band rides with it for the bleed rule and is refused alone.
final class LatticeShapeGradeKeysTests: XCTestCase {
    private func spec(_ algorithm: String, on: Bool, band: Double) -> LatticeSpec {
        var s = LatticeSpec(topologyID: "octet", cellMM: 12, strutRadiusMM: 0.4,
                            generateRelativeDensity: 0.2, minRelativeDensity: 0.1,
                            maxRelativeDensity: 0.9, graded: true)
        s.algorithm = algorithm; s.shapeGrade = on; s.shapeGradeBandMM = band
        return s
    }

    func testTheKeysTravelWithStepppedAndDoubledOnlyWhenTheGradeIsOn() throws {
        let accepts = TopOptKit.gradingSchemaAccepts(key: "shape_grade")
        let acceptsBand = TopOptKit.gradingSchemaAccepts(key: "shape_grade_band_mm")
        for alg in ["stepped", "doubled"] {
            let g = try XCTUnwrap(spec(alg, on: true, band: 25).gradingDictionary())
            XCTAssertEqual(g["shape_grade"] as? Bool, accepts ? true : nil, "\(alg): written iff core accepts it (\(accepts))")
            XCTAssertEqual(g["shape_grade_band_mm"] as? Double, (accepts && acceptsBand) ? 25 : nil, alg)
            // off = core's default, never restated
            let off = try XCTUnwrap(spec(alg, on: false, band: 25).gradingDictionary())
            XCTAssertNil(off["shape_grade"], alg); XCTAssertNil(off["shape_grade_band_mm"], "\(alg): the band is refused without shape_grade")
            // a zero band is not a key
            let zero = try XCTUnwrap(spec(alg, on: true, band: 0).gradingDictionary())
            XCTAssertNil(zero["shape_grade_band_mm"], alg)
        }
        // never beside organic
        let o = spec("organic", on: true, band: 25).gradingDictionary() ?? [:]
        XCTAssertNil(o["shape_grade"]); XCTAssertNil(o["shape_grade_band_mm"])
        print("shape_grade accepted=\(accepts) band accepted=\(acceptsBand)")
    }

    /// ★ THE DENSITY CAP (core reply 6, 2026-09-20): `max_relative_density` = the aesthetic
    /// ceiling whenever Allow quilt is off, under either intent; never for organic, never
    /// when the topology has no ceiling, never on a core without the key.
    func testTheDensityCapTravelsUnlessAllowQuiltLiftsIt() throws {
        let accepts = TopOptKit.gradingSchemaAccepts(key: "max_relative_density")
        var s = LatticeSettings(enabled: true); s.topologyID = "octet"; s.cellMM = 6
        s.allowQuilt = false
        let capped = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        let ceiling = LatticeType.octet.aestheticDensityCeiling(cellMM: 6)
        XCTAssertEqual(capped.densityCapRho, ceiling, accuracy: 1e-12)
        XCTAssertGreaterThan(ceiling, 0.2); XCTAssertLessThan(ceiling, 0.23, "the diameter table's preimage of 0.20")
        let g = try XCTUnwrap(capped.gradingDictionary())
        XCTAssertEqual(g["max_relative_density"] as? Double, accepts ? ceiling : nil,
                       "written iff core accepts the key (\(accepts) on this core)")
        s.allowQuilt = true
        let lifted = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        XCTAssertEqual(lifted.densityCapRho, 0)
        XCTAssertNil(try XCTUnwrap(lifted.gradingDictionary())["max_relative_density"], "Allow quilt lifts the cap")
        var o = spec("organic", on: false, band: 0); o.densityCapRho = ceiling
        XCTAssertNil(o.gradingDictionary()?["max_relative_density"], "never beside organic")
        print("max_relative_density accepted=\(accepts)")
    }

    /// The settings feed the spec: the grade mode's `fitsShape` and the wizard's band.
    func testTheSettingsFeedTheSpec() throws {
        var s = LatticeSettings(enabled: true)
        s.gradingMode = .full; s.shapeFitBandMM = 7
        let a = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        XCTAssertTrue(a.shapeGrade); XCTAssertEqual(a.shapeGradeBandMM, 7)
        s.gradingMode = .stressOnly
        let b = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45))
        XCTAssertFalse(b.shapeGrade)
    }
}
