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
        // ★ CHANGED (ruling 3, 2026-09-29): this candidate carries no prediction, so the
        // stress bar was never computed — not checked, not "false".
        XCTAssertNil(grey.likely, "★ ruling 3: no prediction ran — not checked")
        XCTAssertEqual(grey.notChecked, "")
        XCTAssertNil(amber.notChecked, "its prediction ran")
        // A size the probe never traced: back to the local rules only.
        let unknown = OrganicSizeCheck.evaluate(cellMinMM: 5.5, cellMaxMM: 5.5, walls: walls,
                                                printabilityFloorMM: 2.2, probe: probe)
        XCTAssertTrue(unknown.allowed); XCTAssertNil(unknown.likely)
    }

    /// A candidate exactly as core writes one (run_job.cpp): `approved_structural` is
    /// `ok_s && cert_ok`, and `cert_ok` is set only where the certificate ran.
    private func coreProbe(_ predicted: [String: Any]?, rooted: Bool = true, structural: Bool = false,
                           cell: [Double] = [4.5, 4.5]) throws -> OrganicForecast {
        var c: [String: Any] = [
            "cell_min_mm": cell[0], "cell_max_mm": cell[1],
            "regions": [["approved_structural": structural, "approved_aesthetic": rooted,
                         "refusals": rooted ? "" : "rooted 0.910000 < 0.95"]],
            "approved_structural": structural, "approved_aesthetic": rooted]
        if let predicted { c["predicted"] = predicted }
        return try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(
            withJSONObject: ["organic_probe_version": 1, "candidates": [c]] as [String: Any])))
    }

    /// ★★ RULING 3 (2026-09-29): "When a candidate's prediction never ran,
    /// OrganicSizeCheck says 'Not checked', never 'may not certify'." Every way core
    /// writes a prediction that did not run, and none at all.
    func testACandidateWhosePredictionNeverRanIsNotChecked() throws {
        let reasons: [String?] = ["no segments", "aesthetic intent: nothing reads a certificate",
                                  "612000 segments exceed the probe's 600000 cap", nil]
        for reason in reasons {
            let probe = try coreProbe(reason.map { ["ran": false, "reason": $0] })
            let c = try XCTUnwrap(probe.candidates.first)
            // CONTROL — what the old law said about this very candidate
            XCTAssertFalse(c.approvedStructural, "core writes false: nothing ran")
            let old = OrganicSizeCheck.Verdict(allowed: true, likely: c.approvedStructural, reasons: [], advice: [])
            XCTAssertEqual(OrganicSizeCheck.structuralTitle(label: "4.5 mm", verdict: old), "4.5 mm may not certify")
            // the ruling
            let v = OrganicSizeCheck.evaluate(cellMinMM: 4.5, cellMaxMM: 4.5, walls: walls,
                                              printabilityFloorMM: 2.2, probe: probe)
            XCTAssertNil(v.likely, "\(reason ?? "no prediction")")
            XCTAssertEqual(v.notChecked, reason ?? "", "core's reason, verbatim")
            XCTAssertTrue(v.allowed); XCTAssertTrue(v.reasons.isEmpty)
            XCTAssertFalse(v.advice.contains { $0.contains("margin") }, "no margin was predicted")
            let title = OrganicSizeCheck.structuralTitle(label: "4.5 mm", verdict: v)
            let notice = OrganicSizeCheck.structuralNotice(label: "4.5 mm", verdict: v)
            XCTAssertEqual(title, "4.5 mm: Not checked")
            XCTAssertTrue(notice.hasPrefix("Not checked"), notice)
            if let reason { XCTAssertTrue(notice.contains(reason), notice) }
            XCTAssertTrue(notice.contains("the run's certificate decides"))
            for t in [title, notice] {
                XCTAssertFalse(t.contains("may not certify") || t.contains("not expected to pass"), t)
            }
        }
    }

    /// A rooting refusal on a candidate whose prediction did not run is still "Not
    /// checked" for the stress bar — the refusal is listed, the certificate is not claimed.
    func testARootingRefusalWithoutAPredictionStaysNotChecked() throws {
        let probe = try coreProbe(["ran": false, "reason": "no segments"], rooted: false, cell: [3, 5])
        let v = OrganicSizeCheck.evaluate(cellMinMM: 3, cellMaxMM: 5, walls: walls,
                                          printabilityFloorMM: 2.2, probe: probe)
        XCTAssertFalse(v.allowed)
        XCTAssertEqual(v.reasons, ["rooted 0.910000 < 0.95"], "verbatim")
        XCTAssertNil(v.likely, "★ not coerced to false by the refusal")
        XCTAssertEqual(OrganicSizeCheck.structuralTitle(label: "3–5 mm", verdict: v), "3–5 mm: Not checked")
        let notice = OrganicSizeCheck.structuralNotice(label: "3–5 mm", verdict: v)
        XCTAssertTrue(notice.contains("rooted 0.910000 < 0.95"))
        XCTAssertFalse(notice.contains("not expected to pass"), notice)
    }

    /// Positive control: a prediction that RAN keeps its verdict and its words.
    func testAPredictionThatRanKeepsItsVerdict() throws {
        let refused = OrganicSizeCheck.evaluate(
            cellMinMM: 4.5, cellMaxMM: 4.5, walls: walls, printabilityFloorMM: 2.2,
            probe: try coreProbe(["ran": true, "verdict": "refused", "margin": 0.91]))
        XCTAssertEqual(refused.likely, false); XCTAssertNil(refused.notChecked)
        XCTAssertEqual(OrganicSizeCheck.structuralTitle(label: "4.5 mm", verdict: refused), "4.5 mm may not certify")
        XCTAssertTrue(OrganicSizeCheck.structuralNotice(label: "4.5 mm", verdict: refused)
            .hasPrefix("4.5 mm is not expected to pass certification."))
        let certified = OrganicSizeCheck.evaluate(
            cellMinMM: 4.5, cellMaxMM: 4.5, walls: walls, printabilityFloorMM: 2.2,
            probe: try coreProbe(["ran": true, "verdict": "certified", "margin": 1.84], structural: true))
        XCTAssertEqual(certified.likely, true); XCTAssertNil(certified.notChecked)
    }

    /// ★ The wizard's Structural pop-up takes its words from the size check (a value-type
    /// test alone would miss a call site that still writes its own title).
    func testTheWizardsStructuralNoticeReadsTheSizeCheck() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let wz = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift"),
                            encoding: .utf8)
        XCTAssertFalse(wz.contains("may not certify"), "the wizard writes no certification title of its own")
        XCTAssertTrue(wz.contains("} else if v.likely == false || !v.reasons.isEmpty || v.notChecked != nil {"))
        XCTAssertTrue(wz.contains("title: OrganicSizeCheck.structuralTitle(label: label, verdict: v),"))
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
