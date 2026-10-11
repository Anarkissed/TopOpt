import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★★ K4 READERS — the reviewer's ruling, 2026-10-11 03:28, item 3, approved by the maintainer: "do it now, gated on
/// 'this job carried a plan', with a forced-plan test. The two Results lines: the request's cell, and
/// strut_radius_min/max. The per-region law figures. Fixing them is a precondition of turning plans on in production."
/// On a plan run core's `cell_mm`, its strut aggregates and the per-region receipt describe the grading LAW, not the
/// file (#358 39db7c33); the plan as laid is run_info's `grading.plan_by_region`.
@MainActor
final class LatticePlanRunResultsTests: XCTestCase {

    /// A forced-plan job, through the relattice builder's seam (production sends none: plans are off).
    private func jobs() throws -> (plan: Data, noPlan: Data) {
        var face = LatticeRegionSpec(role: .include, kind: .face)
        face.normal = SIMD3(0, 0, 1); face.depthMM = 12; face.halfUMM = 20; face.halfWMM = 20
        var spec = LatticeSpec(topologyID: "octet", cellMM: 14.5, strutRadiusMM: 0.5,
                               generateRelativeDensity: 0.3, minRelativeDensity: 0.1, maxRelativeDensity: 0.5,
                               regions: [face])
        spec.algorithm = "doubled"
        spec.steppedCells = [LatticeSteppedCellWire(regionID: 1, originMM: .zero, sizeMM: 6, planBaseCellMM: 6)]
        let original = try JSONSerialization.data(withJSONObject: ["model": "p.step"])
        func build(_ plans: Bool) throws -> Data {
            try RelatticeJobBuilder.build(original: original, designFingerprint: 1, achievedVolumeFraction: 0.3,
                                          designFileName: "d.3mf", lattice: spec,
                                          steppedCellsWired: TopOptKit.steppedCellsWired, steppedPlans: plans)
        }
        return (try build(true), try build(false))
    }

    /// run_info as core writes it on a plan run (observability.cpp's K4 block, the ledger fixture's numbers).
    private let runInfo: [String: Any] = ["grading": ["plan_by_region": [
        ["region": 1, "base_cell_mm": 6, "cells": 32, "sizes": "6.000=32",
         "groups": [["size_mm": 6, "cells": 32, "struts_laid": 144, "nodes_laid": 13, "cells_with_no_strut": 24]]],
        ["region": 2, "base_cell_mm": 5.15612, "cells": 10, "sizes": "5.156=2 2.578=8",
         "groups": [["size_mm": 5.15612, "cells": 2, "struts_laid": 20, "nodes_laid": 4, "cells_with_no_strut": 0],
                    ["size_mm": 2.57806, "cells": 8, "struts_laid": 60, "nodes_laid": 9, "cells_with_no_strut": 1]]],
    ]]]

    private func report(_ plan: LatticeReport.PlanLaid?) -> LatticeReport {
        LatticeReport(topologyID: "octet", cellMM: 14.5, generateRelativeDensity: 0.3, minRelativeDensity: 0.1,
                      maxRelativeDensity: 0.5, regionScoped: true, emittedRegions: 2,
                      generated: .init(emitSTL: true, emit3MF: false, latticedCells: 42, regionVoxels: 999,
                                       triangles: 12345, strutRadiusMinMM: 0.31, strutRadiusMaxMM: 0.77),
                      planLaid: plan)
    }

    /// The gate: the job document carried `lattice.stepped_cells`.
    func testTheGateIsTheJobDocument() throws {
        let j = try jobs()
        XCTAssertTrue(LatticeReport.PlanLaid.jobCarriesPlan(j.plan), "★ the forced plan rides")
        XCTAssertFalse(LatticeReport.PlanLaid.jobCarriesPlan(j.noPlan), "control: production's job carries none")
        XCTAssertFalse(LatticeReport.PlanLaid.jobCarriesPlan(Data("{\"lattice\":{\"stepped_cells\":[]}}".utf8)))
    }

    /// ★ On a plan run the three readers say the PLAN; on any other run they are exactly as before.
    func testAPlanRunReadsThePlanNotTheLaw() {
        let plan = LatticeReport.PlanLaid(runInfo: runInfo)
        XCTAssertEqual(plan.cells, 42); XCTAssertEqual(plan.strutsLaid, 224); XCTAssertEqual(plan.cellsWithNoStrut, 25)
        let notes = ResultsModel.latticeNotes(report(plan))
        let all = notes.joined(separator: "\n")
        print("PLAN-RUN NOTES:\n" + all)
        XCTAssertFalse(all.contains("14.5 mm cell"), "★ not the law's cell")
        XCTAssertTrue(all.contains("your plan of 42 cells over 2 regions"))
        XCTAssertFalse(all.contains("strut radius"), "★ not the run's strut aggregate")
        XCTAssertTrue(all.contains("the plan laid 224 struts and 26 nodes, and 25 of its 42 cells got no strut."))
        XCTAssertTrue(all.contains("Region 1: 32 cells on a 6 mm base (32 × 6 mm), 144 struts laid, 24 cells with no strut."))
        XCTAssertTrue(all.contains("Region 2: 10 cells on a 5.156 mm base (2 × 5.16 mm, 8 × 2.58 mm), 80 struts laid, 1 cell with no strut."))
        // a plan run on a core before K4: said, never the law's figures in their place
        let bare = ResultsModel.latticeNotes(report(LatticeReport.PlanLaid(runInfo: [:]))).joined(separator: "\n")
        XCTAssertTrue(bare.contains("did not report the plan as laid"))
        XCTAssertFalse(bare.contains("14.5 mm cell")); XCTAssertFalse(bare.contains("strut radius"))
        // CONTROL: no plan ⇒ byte-for-byte the old lines
        let old = ResultsModel.latticeNotes(report(nil)).joined(separator: "\n")
        XCTAssertTrue(old.contains("14.5 mm cell"))
        XCTAssertTrue(old.contains("strut radius 0.31–0.77 mm."))
        XCTAssertFalse(old.contains("your plan"))
    }

    /// The store keeps it: a reopened plan run reads the plan; a run without one is written exactly as before.
    func testAReopenedPlanRunStillReadsThePlan() throws {
        let plan = LatticeReport.PlanLaid(runInfo: runInfo)
        func roundTrip(_ r: LatticeReport) throws -> (OptimizeOutcome, Data) {
            let bytes = try OutcomeCodec.encode(OutcomeCodec.dto(from: OptimizeOutcome(
                variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0, latticeReport: r)))
            return (try OutcomeCodec.decode(bytes), bytes)
        }
        let (back, _) = try roundTrip(report(plan))
        XCTAssertEqual(back.latticeReport?.planLaid, plan)
        XCTAssertEqual(ResultsModel.latticeNotes(back.latticeReport), ResultsModel.latticeNotes(report(plan)))
        let (_, plainBytes) = try roundTrip(report(nil))
        XCTAssertFalse(String(decoding: plainBytes, as: UTF8.self).contains("planByRegionJSON"), "no key without a plan")
    }

    /// Both runners read it only where the job they SENT carried a plan (source pins).
    func testBothRunnersGateOnTheJobTheySent() throws {
        var u = URL(fileURLWithPath: #filePath); for _ in 0..<3 { u.deleteLastPathComponent() }
        func src(_ f: String) throws -> String {
            try String(contentsOf: u.appendingPathComponent("Sources/TopOptFlows/\(f)"), encoding: .utf8)
        }
        XCTAssertTrue(try src("RemoteRunner.swift").contains("let carriedPlan = submittedJobJSON.map(LatticeReport.PlanLaid.jobCarriesPlan) ?? false"))
        XCTAssertTrue(try src("RelatticeRunner.swift").contains("if LatticeReport.PlanLaid.jobCarriesPlan(jobToSubmit) {"))
        XCTAssertTrue(try src("WorkspacePlaceholder.swift").contains("planLaid: result.planLaid))"))
    }
}
