import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ TWO FINDINGS FROM HIS WALK (2026-09-06, the M2 stand at "2.00 mm to 4.00 mm"):
/// the strut bake traced the OCTET window (4–8 mm) while the job carried the typed
/// grade, and the bake's own completion re-armed a second 12-minute bake.
final class OrganicPreviewBakeInputsTests: XCTestCase {

    private func organic() -> LatticeSettings {
        var s = LatticeSettings(enabled: true)
        s.algorithm = "organic"
        s.simulateStresses = true
        s.cellMinMM = 4; s.cellMaxMM = 8; s.cellMM = 8
        return s
    }

    /// The window the preview traces = the numbers the job writes, case by case.
    func testThePreviewWindowIsTheJobsCellKeys() throws {
        var grade = organic()
        grade.organicPickedGradeMM = [2, 4]
        XCTAssertEqual(grade.organicPreviewSeparationWindowMM.lo, 2)
        XCTAssertEqual(grade.organicPreviewSeparationWindowMM.hi, 4)
        var spec = LatticeSpec(topologyID: "octet", cellMM: 8, strutRadiusMM: 0.6,
                               generateRelativeDensity: 0.2, minRelativeDensity: 0.05,
                               maxRelativeDensity: 0.9, graded: true)
        spec.algorithm = "organic"
        spec.organicPickedGradeMM = [2, 4]
        let g = try XCTUnwrap(spec.gradingDictionary())
        XCTAssertEqual(g["cell_min_mm"] as? Double, grade.organicPreviewSeparationWindowMM.lo)
        XCTAssertEqual(g["cell_max_mm"] as? Double, grade.organicPreviewSeparationWindowMM.hi)

        var single = organic()
        single.organicPickedSeparationMM = 3.5
        XCTAssertEqual(single.organicPreviewSeparationWindowMM.lo, 3.5)
        XCTAssertEqual(single.organicPreviewSeparationWindowMM.hi, 3.5)
        spec.organicPickedGradeMM = []; spec.organicPickedSeparationMM = 3.5
        XCTAssertEqual(try XCTUnwrap(spec.gradingDictionary())["cell_mm"] as? Double, 3.5)

        let none = organic()   // nothing picked: the window, as before
        XCTAssertEqual(none.organicPreviewSeparationWindowMM.lo, 4)
        XCTAssertEqual(none.organicPreviewSeparationWindowMM.hi, 8)
        var inverted = organic()
        inverted.organicPickedGradeMM = [4, 2]   // not a grade the job would write
        XCTAssertEqual(inverted.organicPreviewSeparationWindowMM.lo, 4)
        XCTAssertEqual(inverted.organicPreviewSeparationWindowMM.hi, 8)
    }

    /// Nothing picked ⇒ the window is a stand-in and the bake must ask core's band.
    func testNothingPickedIsFlaggedAsTheStandIn() {
        XCTAssertTrue(organic().organicPreviewWindowIsFallback)
        var g = organic(); g.organicPickedGradeMM = [2, 4]
        XCTAssertFalse(g.organicPreviewWindowIsFallback)
        var s = organic(); s.organicPickedSeparationMM = 3
        XCTAssertFalse(s.organicPreviewWindowIsFallback)
        var bad = organic(); bad.organicPickedGradeMM = [4, 2]
        XCTAssertTrue(bad.organicPreviewWindowIsFallback, "an inverted grade is not a pick")
    }

    /// A field a bake WRITES is not a field a bake READS.
    func testAMeasurementTheBakeWroteDoesNotChangeItsInputs() throws {
        let a = organic()
        var b = a
        b.selectableWallStressFraction = ["f:x:2": 0.9, "f:x:15": 0.83]
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.previewBakeInputs, b.previewBakeInputs, "the wall shares are its own write")
        var c = a
        c.organicForecast = OrganicForecast.parse(try JSONSerialization.data(withJSONObject: [
            "organic_probe_version": 1,
            "candidates": [["cell_min_mm": 4.5, "cell_max_mm": 4.5, "regions": [],
                            "approved_structural": true, "approved_aesthetic": true]]]))
        XCTAssertNotNil(c.organicForecast)
        XCTAssertEqual(a.previewBakeInputs, c.previewBakeInputs, "the probe's answer is not a picture")
        var d = a
        d.cellMinMM = 3
        XCTAssertNotEqual(a.previewBakeInputs, d.previewBakeInputs, "a real input still rebakes")
        var e = a
        e.organicPickedGradeMM = [2, 4]
        XCTAssertNotEqual(a.previewBakeInputs, e.previewBakeInputs)
    }

    /// The call sites, since a value-type test cannot see them.
    func testTheWorkspaceReadsBothAtTheRightPlaces() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift")
        let ws = try String(contentsOf: url, encoding: .utf8)
        guard let r = ws.range(of: ".onChange(of: project.lattice)") else { return XCTFail("trigger moved") }
        let trigger = String(ws[r.lowerBound...].prefix(2600))
        XCTAssertTrue(trigger.contains("project.lattice.previewBakeInputs"), "★ the rebake compares what a bake reads")
        XCTAssertTrue(trigger.contains("latticeInputsLastBaked = inputs"), "★ …and remembers what it baked from")
        XCTAssertTrue(trigger.contains("buildStrutScene()"), "★ …and still bakes on a real change")
        guard let o = ws.range(of: "let organicForBake: LatticeOrganicInput? = {") else { return XCTFail("bake input moved") }
        let bake = String(ws[o.lowerBound...].prefix(1400))
        XCTAssertTrue(bake.contains("lat.organicPreviewSeparationWindowMM"), "★ the trace reads the job's numbers")
        XCTAssertFalse(bake.contains("lat.cellMinMM > 0 ? lat.cellMinMM"), "★ the octet window is gone from the trace")
    }
}
