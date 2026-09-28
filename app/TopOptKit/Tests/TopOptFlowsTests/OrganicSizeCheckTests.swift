import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ His eight organic-pane items (2026-09-05): the typed size check (2, 4), the
/// sim-off rules (1, 3, 6, 7) and the density label (5).
final class OrganicSizeCheckTests: XCTestCase {

    private let walls = [OrganicSizeCheck.Wall(key: "f:a", depthMM: 12),
                         OrganicSizeCheck.Wall(key: "f:b", depthMM: 11)]

    func testBelowThePrintableCellIsRefusedEverywhere() {
        let v = OrganicSizeCheck.evaluate(cellMinMM: 1.5, cellMaxMM: 3, walls: walls,
                                          printabilityFloorMM: 2.2, probe: nil)
        XCTAssertFalse(v.allowed)
        XCTAssertEqual(v.likely, false)
        XCTAssertTrue(v.reasons.contains { $0.contains("smallest cell this nozzle can print") }, v.text)
    }

    func testBiggerThanTheThinnestWallIsRefused() {
        let v = OrganicSizeCheck.evaluate(cellMinMM: 12, cellMaxMM: 12, walls: walls,
                                          printabilityFloorMM: 2.2, probe: nil)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.reasons.contains { $0.contains("thinnest wall") && $0.contains("11.0") }, v.text)
    }

    /// A fine size with no probe: allowed, "likely" unknown, cells across is ADVICE.
    func testAFineSizeWithoutAProbeIsAllowedAndOnlyAdvised() {
        let v = OrganicSizeCheck.evaluate(cellMinMM: 4.5, cellMaxMM: 4.5, walls: walls,
                                          printabilityFloorMM: 2.2, probe: nil)
        XCTAssertTrue(v.allowed)
        XCTAssertNil(v.likely, "nothing can say without the probe")
        XCTAssertTrue(v.reasons.isEmpty)
        XCTAssertEqual(v.advice.count, 2, "2.7 and 2.4 cells across — advice, never a gate")
        XCTAssertTrue(v.advice[0].contains("cells across"))
    }

    func testTheProbesVerdictIsUsedWhenItHasTheCandidate() throws {
        let doc: [String: Any] = [
            "organic_probe_version": 1, "candidates": [
                ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "regions": [
                    ["approved_structural": false, "approved_aesthetic": true,
                     "refusals": "predicted refused: p99 34.0 MPa > allowable 31.0"]],
                 "predicted": ["ran": true, "verdict": "refused", "margin": 0.91],
                 "approved_structural": false, "approved_aesthetic": true],
                ["cell_min_mm": 3, "cell_max_mm": 5, "regions": [
                    ["approved_structural": false, "approved_aesthetic": false,
                     "refusals": "rooted_length_fraction 0.91 < 0.95"]],
                 "approved_structural": false, "approved_aesthetic": false]]]
        let probe = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(withJSONObject: doc)))
        let amber = OrganicSizeCheck.evaluate(cellMinMM: 4.5, cellMaxMM: 4.5, walls: walls,
                                              printabilityFloorMM: 2.2, probe: probe)
        XCTAssertTrue(amber.allowed, "aesthetic may use it")
        XCTAssertEqual(amber.likely, false, "structural is not expected to certify")
        XCTAssertEqual(amber.reasons, ["predicted refused: p99 34.0 MPa > allowable 31.0"], "verbatim")
        XCTAssertTrue(amber.advice.contains { $0.contains("margin 0.91") })
        let grey = OrganicSizeCheck.evaluate(cellMinMM: 3, cellMaxMM: 5, walls: walls,
                                             printabilityFloorMM: 2.2, probe: probe)
        XCTAssertFalse(grey.allowed, "refused for aesthetic too")
        XCTAssertEqual(grey.likely, false)
        // A size the probe never traced: back to the local rules only.
        let unknown = OrganicSizeCheck.evaluate(cellMinMM: 5.5, cellMaxMM: 5.5, walls: walls,
                                                printabilityFloorMM: 2.2, probe: probe)
        XCTAssertTrue(unknown.allowed); XCTAssertNil(unknown.likely)
    }

    func testTheStructuralNoticeSaysCoreSettlesItAndTheRunIsTheVerdict() {
        let v = OrganicSizeCheck.evaluate(cellMinMM: 12, cellMaxMM: 12, walls: walls,
                                          printabilityFloorMM: 2.2, probe: nil)
        let text = OrganicSizeCheck.structuralNotice(label: "12 mm", verdict: v)
        XCTAssertTrue(text.hasPrefix("12 mm is not expected to pass certification."), text)
        XCTAssertTrue(text.contains("thinnest wall"))
        XCTAssertTrue(text.contains("The final check happens when the lattice is built"))
        XCTAssertTrue(text.contains("the run's certificate decides"))
        XCTAssertFalse(text.contains(" here"), "no placeless 'here' (his review, 2026-09-05)")
    }

    // MARK: the sim-off rules on the wizard model (items 1, 3, 6)

    private func organicModel(sim: Bool) -> LatticeWizardModel {
        var s = LatticeSettings(enabled: true)
        s.simulateStresses = sim
        s.algorithm = "organic"
        var m = LatticeWizardModel(settings: s)
        m.selectOrganic()
        return m
    }

    func testWithoutASimulationAutoIsNotOfferedFitIsForcedAndShapeFitOnlyStaysOn() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        var m = organicModel(sim: false)
        XCTAssertEqual(m.organicCellModes, [.fit], "Auto is a stress grading")
        XCTAssertEqual(m.cellSizeMode, .fit)
        XCTAssertTrue(m.organicShapeFitOnly)
        m.setCellSizeMode(.auto)
        XCTAssertEqual(m.cellSizeMode, .fit, "Auto cannot be reached without a simulation")
        XCTAssertTrue(m.organicShapeFitOnly)
        // Turning the simulation off from Auto lands on Fit with the switch on.
        var on = organicModel(sim: true)
        on.setCellSizeMode(.auto)
        XCTAssertEqual(on.organicCellModes, [.auto, .fit], "with a simulation: Auto, and Manual — never Fit as a pill")
        on.setSimulateStresses(false)
        XCTAssertEqual(on.cellSizeMode, .fit)
        XCTAssertTrue(on.organicShapeFitOnly)
    }

    /// ★ "Shape fit only" and the cell-size mode have NOTHING in common (his
    /// correction, 2026-09-05): flipping one never moves the other.
    func testShapeFitOnlyAndCellSizeModeAreIndependent() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic on this core") }
        var m = organicModel(sim: true)
        m.setCellSizeMode(.auto)
        m.organicShapeFitOnly = true
        XCTAssertEqual(m.cellSizeMode, .auto, "switching shape fit on did not move the mode")
        m.organicShapeFitOnly = false
        m.setCellSizeMode(.fit)
        XCTAssertFalse(m.organicShapeFitOnly, "choosing Fit did not flip the switch")
        m.setCellSizeMode(.auto)
        XCTAssertFalse(m.organicShapeFitOnly, "choosing Auto did not flip the switch")
        // Without a simulation the switch is locked ON (item 6) — still not by the mode.
        var off = organicModel(sim: false)
        XCTAssertTrue(off.organicShapeFitOnly)
        off.setCellSizeMode(.fit)
        XCTAssertTrue(off.organicShapeFitOnly)
    }
}
