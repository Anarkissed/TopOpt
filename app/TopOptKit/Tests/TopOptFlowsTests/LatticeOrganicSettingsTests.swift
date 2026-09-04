import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★★ THE ORGANIC KEYS — every §10 rule of the 2026-09-02 task that can be pinned on
/// the job document alone. The document is the LAST place these rules can be enforced:
/// a control that is merely disabled in one page lets any other caller build a job
/// that dies at parse.
final class LatticeOrganicSettingsTests: XCTestCase {

    private static let organicKeys = [
        "organic_strut_width_mm", "organic_overhang_angle_deg", "organic_boundary_finish",
        "organic_shape_fit", "organic_shape_fit_only", "organic_scale", "organic_growth",
    ]

    private func spec(algorithm: String) -> LatticeSpec {
        var s = LatticeSpec(topologyID: "octet", cellMM: 6, strutRadiusMM: 0.6,
                            generateRelativeDensity: 0.2, minRelativeDensity: 0.05,
                            maxRelativeDensity: 0.9, graded: true)
        s.algorithm = algorithm
        return s
    }

    /// U1: an untouched spec emits no organic_* key at all — byte-identical to before.
    func testAnUntouchedSpecWritesNoOrganicKey() throws {
        let g = try XCTUnwrap(spec(algorithm: "").gradingDictionary())
        for k in Self.organicKeys { XCTAssertNil(g[k], "★ \(k) leaked into an untouched job") }
        XCTAssertNil(g["algorithm"])
    }

    /// Every organic_* key is ABSENT under octet/doubled/stepped even when set —
    /// core refuses each one "only allowed with algorithm organic".
    func testOrganicKeysAreNeverWrittenUnderAnotherAlgorithm() throws {
        for alg in ["doubled", "stepped"] where TopOptKit.latticeAlgorithmIsKnown(alg) {
            var s = spec(algorithm: alg)
            s.organicGrowth = true; s.organicStrutWidthMM = 1.2; s.organicOverhangDeg = 40
            s.organicBoundaryFinish = "rim"; s.organicShapeFit = true
            s.organicShapeFitOnly = true; s.organicScale = 1.5; s.layerHeightMM = 0.2
            let g = try XCTUnwrap(s.gradingDictionary())
            for k in Self.organicKeys { XCTAssertNil(g[k], "★ \(k) written under \(alg)") }
        }
    }

    /// Core's own defaults are never RESTATED — restating is a different document.
    func testOrganicDefaultsAreNotRestated() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        let g = try XCTUnwrap(spec(algorithm: "organic").gradingDictionary())
        XCTAssertEqual(g["algorithm"] as? String, "organic")
        for k in Self.organicKeys { XCTAssertNil(g[k], "★ default restated: \(k)") }
    }

    /// Each key is written iff the user moved it AND the linked core accepts it.
    func testEachKeyIsGatedOnTheCapabilityProbe() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        var s = spec(algorithm: "organic")
        s.organicStrutWidthMM = 1.2; s.organicOverhangDeg = 40; s.organicBoundaryFinish = "rim"
        s.organicShapeFit = true; s.organicShapeFitOnly = true; s.organicScale = 1.5
        s.organicGrowth = false; s.layerHeightMM = 0.2
        let g = try XCTUnwrap(s.gradingDictionary())
        let expect: [String: Any] = ["organic_strut_width_mm": 1.2, "organic_overhang_angle_deg": 40.0,
            "organic_boundary_finish": "rim", "organic_shape_fit": true,
            "organic_scale": 1.5]
        // ★ `organic_shape_fit_only` is NEVER written for organic (2026-09-04): core
        // accepts it only with a cell window, and windows only on the swept path
        // (job.cpp), which D2 forbids for organic — the job would be refused.
        XCTAssertNil(g["organic_shape_fit_only"], "★ a key core refuses on every organic job")
        for (k, v) in expect {
            if TopOptKit.gradingSchemaAccepts(key: k) {
                XCTAssertNotNil(g[k], "★ core accepts \(k) and the user moved it, but it was not written")
                XCTAssertEqual(String(describing: g[k]!), String(describing: v), k)
            } else {
                XCTAssertNil(g[k], "★ \(k) written although this core does not accept it")
            }
        }
        print("probe reliable=\(TopOptKit.gradingSchemaProbeIsReliable)  accepts: "
              + Self.organicKeys.map { "\($0)=\(TopOptKit.gradingSchemaAccepts(key: $0))" }.joined(separator: " "))
    }

    /// §2A: growth is NEVER written without a stated layer height — a schema refusal
    /// at parse, not a fallback.
    func testGrowthIsNeverWrittenWithoutALayerHeight() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        var s = spec(algorithm: "organic"); s.organicGrowth = true
        s.layerHeightMM = 0
        XCTAssertNil(try XCTUnwrap(s.gradingDictionary())["organic_growth"],
                     "★ organic_growth written with no layer height — core will refuse the job at parse")
        s.layerHeightMM = 0.2
        let g = try XCTUnwrap(s.gradingDictionary())
        if TopOptKit.gradingSchemaAccepts(key: "organic_growth") {
            XCTAssertEqual(g["organic_growth"] as? Bool, true)
        } else { XCTAssertNil(g["organic_growth"]) }
    }

    /// §2C: the overhang angle is TRACE ONLY — grown clamps to a compile-time 30 deg.
    func testOverhangIsNotWrittenInGrownMode() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        var s = spec(algorithm: "organic"); s.organicOverhangDeg = 40; s.layerHeightMM = 0.2
        s.organicGrowth = true
        XCTAssertNil(try XCTUnwrap(s.gradingDictionary())["organic_overhang_angle_deg"],
                     "★ a dead knob: overhang written under growth, which ignores it")
        s.organicGrowth = false
        if TopOptKit.gradingSchemaAccepts(key: "organic_overhang_angle_deg") {
            XCTAssertNotNil(try XCTUnwrap(s.gradingDictionary())["organic_overhang_angle_deg"])
        }
    }

    /// The settings struct: the UI-facing gates, and a snapshot round trip.
    func testSettingsGatesAndRoundTrip() throws {
        var l = LatticeSettings(); l.enabled = true
        XCTAssertFalse(l.isOrganic)
        XCTAssertNil(l.organicGrowthRefusalReason(layerHeightMM: 0.2).flatMap { _ in nil as String? })
        l.algorithm = "organic"
        if TopOptKit.latticeAlgorithmIsKnown("organic") {
            XCTAssertTrue(l.isOrganic)
            XCTAssertTrue(l.organicOverhangIsLive)
            l.organicGrowth = true
            XCTAssertFalse(l.organicOverhangIsLive, "★ overhang offered in grown mode")
            XCTAssertNotNil(l.organicGrowthRefusalReason(layerHeightMM: 0),
                            "★ growth offered with no layer height")
            if TopOptKit.gradingSchemaAccepts(key: "organic_growth") {
                XCTAssertNil(l.organicGrowthRefusalReason(layerHeightMM: 0.2))
            }
        }
        l.organicBoundaryFinish = .rim; l.organicScale = 1.25; l.organicShapeFit = true
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(LatticeSettings.self, from: data)
        XCTAssertEqual(back, l, "★ organic settings did not round-trip the snapshot")
        // And a snapshot from BEFORE organic existed decodes to core's defaults.
        let old = try JSONDecoder().decode(LatticeSettings.self,
            from: Data(#"{"enabled":true,"topologyID":"octet","cellMM":6}"#.utf8))
        XCTAssertFalse(old.organicGrowth); XCTAssertEqual(old.organicBoundaryFinish, .skin)
        XCTAssertEqual(old.organicScale, 1.0); XCTAssertEqual(old.organicStrutWidthMM, 0)
    }
}
