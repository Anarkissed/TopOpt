// IPadNotes1121Tests — ★ his 11-21 on the Lattice button (his 2040 stand, Organic, Structural): "When I pressed Lattice it
// attempted to optimize and lattice. And failed." It did not optimize (the card borrowed Optimize's words) and it did not fail
// (the result landed unseen behind the Lattice stage). His picks: "Change the words, have it spit out an actual result in the
// app - because NOTHING happens in app" · "It should also show all the information associated to the final result".
import XCTest
import TopOptKit
@testable import TopOptFlows

final class IPadNotes1121Tests: XCTestCase {

    // MARK: the run card's words

    func testALatticeRunIsNeverCalledOptimizing() {
        XCTAssertEqual(RunCardWords.title(LatticeFileButton.jobMode), "Latticing", "★ the print file's run")
        XCTAssertEqual(RunCardWords.title("lattice_part"), "Latticing", "the old engine's Lattice run too")
        XCTAssertEqual(RunCardWords.title("minimize_plastic"), "Optimizing", "RED CONTROL: Optimize keeps its word")
        XCTAssertEqual(RunCardWords.title(nil), "Optimizing")
    }

    func testThePrintFilesStepsAreNamed() {
        let mode = LatticeFileButton.jobMode
        XCTAssertEqual(RunCardWords.step(mode, RunProgress(rung: 0, rungCount: 2, iteration: 0)), "Strengthening the struts · 1 of 2",
                       "★ Organic on Structural: the struts strengthened first")
        XCTAssertEqual(RunCardWords.step(mode, RunProgress(rung: 1, rungCount: 2, iteration: 0)), "Making the print file · 2 of 2")
        XCTAssertEqual(RunCardWords.step(mode, RunProgress(rung: 0, rungCount: 1, iteration: 0)), "Making the print file")
        XCTAssertNil(RunCardWords.step("minimize_plastic", RunProgress(rung: 0, rungCount: 2, iteration: 3)),
                     "RED CONTROL: an optimize run keeps 'Result 1 of 2 · iteration 3'")
    }

    // MARK: the result opens

    private func outcome(accepted: Bool, report: Data? = nil) -> OptimizeOutcome {
        let v = OptimizeVariant(requestedVolumeFraction: 0.6, achievedVolumeFraction: 0.6, massGrams: 60, supportVolumeVoxels: 0,
                                meshTriangleCount: 12, worstCaseMargin: 3, accepted: accepted, v3Passes: accepted,
                                meshVertices: [0, 0, 0], meshIndices: [0])
        return OptimizeOutcome(variants: [v], stoppedOnMargin: false, cancelled: false, acceptedCount: accepted ? 1 : 0,
                               computedRemotely: true, reportJSON: report)
    }

    func testALatticeRunThatLandsOpensItsResult() {
        XCTAssertTrue(LatticeFileButton.opensResults(succeeded: true, byLattice: true, outcome: outcome(accepted: true)),
                      "★ a passing print file opens on Results (before: only one that did not certify)")
        XCTAssertFalse(LatticeFileButton.opensResults(succeeded: true, byLattice: false, outcome: outcome(accepted: true)),
                       "RED CONTROL: Optimize's run puts its dot and message on Topology, as before")
        XCTAssertFalse(LatticeFileButton.opensResults(succeeded: false, byLattice: true, outcome: outcome(accepted: true)))
        XCTAssertFalse(LatticeFileButton.opensResults(succeeded: true, byLattice: true, outcome: outcome(accepted: false)))
        XCTAssertFalse(LatticeFileButton.opensResults(succeeded: true, byLattice: true, outcome: nil))
    }

    // MARK: all its information

    /// A Lattice run's report in the shape his stand's came back in (made-up numbers).
    static func report(strengthened: Bool = true, clean: Bool = true) -> [String: Any] {
        var r: [String: Any] = [
            "ok": true, "code": "ok", "file": "lattice.3mf", "file_bytes": 25_400_000, "file_format": "3mf",
            "slicer_supports": "off", "ms": ["total": 600_500.0],
            "layout": ["bars": 120_000, "strands": 17_000],
            "mesh": ["triangles": 2_500_000, "bridges": 11_000, "posts": 30, "posts_mm": 55.0, "mm3": 120_000.0, "part_mm3": 100_000.0],
            "print_check": ["clean": clean, "layers": 300, "midair_starts": clean ? 0 : 3, "longest_bridge_reach_mm": 6.0,
                            "first_layer_mm2": 3000.0, "thin_islands": 300],
            "strength": ["accepted": true, "verdict": "pass", "margin_worst_case": 3.0, "safety_margin": 1.5, "mass_grams": 60.0,
                         "struts": ["judged": 14_000, "smallest_margin": 1.6],
                         "weakest": [["margin": 1.6, "by": "tension", "width_mm": 2.3, "length_mm": 5.8, "at": [1.0, 2.0, 3.0]]],
                         "solid_margin": ["in_plane": 3.0, "interlayer": 4.5, "passes_at_infill_percent": 45],
                         "frame": ["load_share": 0.7]],
        ]
        if strengthened {
            r[LatticeFileButton.strengthenKey] = [
                "code": "done", "passing": true, "rounds_fixed": 5, "seconds": 620.0,
                "rounds": [["added": ["struts_widened": 40, "struts_braced": 2]], ["added": ["struts_widened": 10, "struts_braced": 0]],
                           ["struts": ["judged": 14_000]]],
            ] as [String: Any]
        }
        return r
    }

    func testTheResultSaysWhatTheMacMade() throws {
        let f = try XCTUnwrap(LatticeFileFacts.decode(Self.report()))
        let checks = f.checks
        XCTAssertEqual(checks.map(\.title), ["Strengthened · 5 rounds", "Print file ready", "Prints layer by layer"])
        // ★ RE-PINNED (notes25 C3 (4): only numbers true for the final lattice — the per-round "thickened" sum counted a strut once
        // per round; the file's line carries no strut count)
        XCTAssertEqual(checks[0].more, "2 braced", "the braces (no widest strut in this report)")
        XCTAssertEqual(checks[1].detail, "3MF · 25.4 MB")
        XCTAssertEqual(checks[1].more, "Turn supports off in your slicer")
        // ★ RE-PINNED (notes25 C3 (6): the strength rows are the governing answer's — LatticeStrengthAnswer; the facts keep the
        // strengthening)
        XCTAssertEqual(f.rows(.strength).map(\.label), ["Strengthened"])
        XCTAssertEqual(f.rows(.strength).first?.value, "5 rounds · 2 braced")
        let a = try XCTUnwrap(LatticeStrengthAnswer.decode(report: Self.report()))
        let strength = a.rows(loadKg: 0, unit: .kg, infillPercent: 100, plastic: nil)
        XCTAssertEqual(strength.first { $0.label == "Gives first at" }?.value, "A strut · in tension · 2.30 mm thick, 5.8 mm long")
        XCTAssertEqual(strength.first { $0.label == "Holds" }?.value, "1.60× your load", "the smaller of the strut's 1.6 and the solid's 3")
        let printing = f.rows(.printing).map(\.label)
        XCTAssertEqual(printing.first, "Print file")
        XCTAssertTrue(printing.contains("Bridges") && printing.contains("Layers") && printing.contains("Longest bridge"))
        XCTAssertEqual(f.rows(.run).map(\.value), ["120,000", "10 min 20 s", "10 min 1 s"],
                       "★ RE-PINNED (notes25 C3 (7)): the file's bars, then the strengthening, then the file")
    }

    func testAFileWithoutStrengtheningOrWithLayerTroubleSaysSo() throws {
        let f = try XCTUnwrap(LatticeFileFacts.decode(Self.report(strengthened: false, clean: false)))
        XCTAssertEqual(f.checks.map(\.title), ["Print file ready", "Check the layers"])
        XCTAssertEqual(f.checks.last?.detail, "3 places start in mid-air")
        XCTAssertEqual(f.checks.last?.kind, .warn)
    }

    func testOnlyALatticeRunsReportCarriesIt() {
        XCTAssertNil(LatticeFileFacts.decode(["variants": [[String: Any]](), "safety_margin": 1.5]),
                     "RED CONTROL: an optimize run's report has no print file")
        XCTAssertNotNil(RunReportBlocks.decode(report: Self.report()).printFile, "★ Results reads it with the run's other blocks")
    }

    @MainActor func testResultsCarriesIt() throws {
        let o = outcome(accepted: true, report: try JSONSerialization.data(withJSONObject: Self.report()))
        let m = ResultsModel(projectName: "Stand", outcome: o)
        let b = try XCTUnwrap(m.reportBlocks)
        let titles = ResultsChecks.checks(tab: m.selected, margin: 3, required: 1.5, safetyMargin: 1.5, scenarios: [], thinJoints: 0,
                                          bridged: false, struts: b.latticeFile, printFile: b.printFile).map(\.title)
        XCTAssertTrue(titles.contains("Strengthened · 5 rounds") && titles.contains("Print file ready"), "\(titles)")
        let plain = ResultsChecks.checks(tab: m.selected, margin: 3, required: 1.5, safetyMargin: 1.5, scenarios: [], thinJoints: 0,
                                         bridged: false).map(\.title)
        XCTAssertFalse(plain.contains("Print file ready"), "RED CONTROL: no print file, no line")
        let rows = ResultsVersions.rows(tabs: m.tabs, blocks: m.reportBlocks, requestedVF: { m.requestedVolumeFraction(of: $0) })
        let printing = m.detailRows(.printing, version: rows.first).map(\.label)
        XCTAssertTrue(printing.contains("Print file") && printing.contains("Bridges"), "★ Details › Printing: \(printing)")
        XCTAssertTrue(m.detailRows(.run, version: rows.first).contains { $0.label == "Strengthening" }, "★ Details › Run")
    }

    // MARK: the plastic share

    func testAnOrganicFilesShareIsItsMassNotItsOverlappingBodies() throws {
        let d = try JSONSerialization.data(withJSONObject: Self.report())
        let r = try XCTUnwrap(LatticeFileReport.parse(d))
        XCTAssertEqual(LatticeFileButton.plasticShare(r, organic: false, densityGCm3: 1.0), 1.2, accuracy: 1e-9,
                       "RED CONTROL: the mesh's own volume (overlaps counted twice) reads 120 %")
        XCTAssertEqual(LatticeFileButton.plasticShare(r, organic: true, densityGCm3: 1.0), 0.6, accuracy: 1e-9,
                       "★ his stand: the strength check's 60 g of a 100 cm³ part at 1 g/cm³ is 60 %")
    }
}
