import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// R4 EVIDENCE GENERATOR — the retention path end to end, against WHICHEVER core
/// this build links (task 2026-08-05-lattice-retention-app-control).
///
/// It prints, rather than asserts, on purpose: its job is to produce the record
/// that says what the app would send to the worker on the maintainer's own
/// machine. The bars themselves live in LatticeRetentionControlTests. Its output is
/// `evidence/2026-08-05-lattice-retention-app-control/r4_core_with_all_four_keys.txt`.
///
/// It was run on two DIFFERENT cores while PR 298 was unmerged, which made the
/// capability gate's withholding visible rather than argued. That is no longer
/// reproducible — the per-region messages now read core's percolation floor, which
/// arrives with PR 298, so the package does not build against an older core. The
/// withholding behaviour is pinned by the injected-capability tests instead.
@MainActor
final class LatticeRetentionEvidenceGen: XCTestCase {
    func testWriteRetentionReachabilityEvidence() throws {
        let cap = LatticeRetentionCapability.fromCore
        print("R4 probe reliable = \(cap.probeReliable)")
        print("R4 core accepts: retention=\(cap.retention) stressFraction=\(cap.stressFraction) perRegion=\(cap.perRegion) regionCells=\(cap.regionCells)")
        print("R4 core default ceiling = \(LatticeRetentionCapability.coreStressFractionDefault)")

        func job(_ mutate: (inout LatticeSettings) -> Void) throws -> String {
            var s = LatticeSettings(enabled: true)
            s.densityMode = .auto
            s.minRelativeDensity = 0.2; s.maxRelativeDensity = 0.5
            mutate(&s)
            let spec = try XCTUnwrap(s.runSpec(lineWidthMM: 0.45, capability: cap))
            let cfg = RemoteRunnerConfig(host: "127.0.0.1", port: 8757, expectedFingerprint: "test")
            let req = RunRequest(modelPath: "/tmp/part.step", material: "PLA",
                                 materialsPath: "", rulesPath: "", resolution: 64,
                                 projectName: "r4", anchorFaceIDs: [3],
                                 loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [11], force: SIMD3(0,0,-250))],
                                 minimizePlastic: true, buildDirection: SIMD3(0,0,1),
                                 infillPercent: 40, wallLoops: 3,
                                 wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
                                 lattice: spec)
            let run = RemoteRun(config: cfg, request: req, progress: { _,_,_ in true }, onVariant: { _ in })
            let d = try run.buildJobJSON()
            let o = try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
            let g = o["grading"] as? [String: Any] ?? [:]
            return String(data: try JSONSerialization.data(withJSONObject: g, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!
        }

        print("R4 --- controls UNTOUCHED, grading block ---")
        print(try job { _ in })
        print("R4 --- retention ARMED, all four controls on ---")
        print(try job { s in
            s.retainSubfloorInUnloadedRegions = true
            s.subfloorPerRegion = true
            s.reportRegionCells = true
        })
        print("R4 --- retention ARMED with a MOVED ceiling ---")
        print(try job { s in
            s.retainSubfloorInUnloadedRegions = true
            s.subfloorStressFraction = 0.12
        })

        // The cell control's audited envelope, at his own line width.
        var cs = LatticeSettings(enabled: true)
        let b = LatticeBounds.compute(settings: cs,
                                      limits: TopOptKit.latticeLimits(topology: "octet"),
                                      generatable: true, memberMM: 0, lineWidthMM: 0.45)
        print("R4 cell control @0.45mm: light floor=\(b.cellFloorMM!) densest floor=\(b.cellFloorDensestMM!) range=\(LatticeCellEntry.range(b)) typed(1.2)=\(LatticeCellEntry.typed(1.2, b))")
        cs.cellMM = 1.2
        let b2 = LatticeBounds.compute(settings: cs,
                                       limits: TopOptKit.latticeLimits(topology: "octet"),
                                       generatable: true, memberMM: 0, lineWidthMM: 0.45)
        print("R4 reason at 1.2mm: \(b2.cellReason ?? "none")  runnable=\(b2.runnableAsCertified)")

        // ── S2 · what the control says, at each of its states ────────────────
        for (label, armed, below) in [("OFF, nothing below the floor", false, 0),
                                      ("OFF, 822 below the floor", false, 822),
                                      ("ON, 822 below the floor", true, 822)] {
            let c = LatticeRetentionControl.compute(
                armed: armed, graded: true, capability: cap,
                belowFloorVoxels: below, regionVoxels: 1257,
                ceilingFraction: nil,
                coreCeilingFraction: LatticeRetentionCapability.coreStressFractionDefault)
            print("R4 control [\(label)] enabled=\(c.enabled) ceiling=\(c.ceilingText)")
            print("     title: \(c.title)")
            print("      body: \(c.body)")
            print("  exposure: \(c.exposure ?? "—")")
        }

        // ── S4 · the per-region receipt, as it reaches the results screen ─────
        //
        // ★ THIS IS A CONSTRUCTED GRADED FIXTURE, NOT THE MAINTAINER'S RUN. His
        // overnight run was UNIFORM (a `lattice` block with rho_min == rho_max and
        // no `grading` block at all), and core's per-region report exists only on
        // the graded path — so this receipt would NOT have fired on it. The numbers
        // are modelled on his job (seven include regions, 4 mm members, a 0.45 mm
        // bead) to show what the rendering does; they are not measurements of his
        // run. See §5 of the handoff.
        //
        // ★ AND IT IS INTERNALLY COHERENT, which the first version was not. Every
        // region has the SAME 4.00 mm member, so nothing geometric can separate
        // them — `at_thinnest.feasible` is a pure function of (member width,
        // nozzle) and is FALSE for all seven. What separates them is the retention
        // predicate: regions 1-5 measure ABOVE the stress ceiling and did not
        // qualify; region 6 measures below it and was kept. The first fixture gave
        // all seven the same stress fraction and still had them diverge, which is a
        // state no run can reach — and it produced two rows that contradicted each
        // other (review P2).
        func region(_ id: Int, latticed: Int, verdict: String, stress: Double,
                    nozzle: Double = 0) -> [String: Any] {
            ["region_id": id, "candidate_voxels": 1257,
             "latticed_voxels": latticed, "solid_voxels": 1257 - latticed,
             "member_width_mm": ["min": 4.0, "max": 4.0],
             "stress_fraction": stress, "verdict": verdict,
             "exposure_fraction": verdict == "out_of_regime" ? 0.0289 : 0.0,
             "nozzle_needed_mm": nozzle,
             // FALSE for every region: a 4.00 mm member cannot be CERTIFIED at a
             // 0.45 mm bead (it would need 5.47 mm). That is the same for all seven.
             "at_thinnest_member": ["feasible": false,
                                    "min_printable_cell_mm": 1.1732,
                                    "min_member_width_mm": 5.4748],
             "at_thickest_member": ["feasible": false,
                                    "min_printable_cell_mm": 1.1732,
                                    "min_member_width_mm": 5.4748]]
        }
        func subRegion(_ id: Int, stress: Double, qualified: Bool,
                       retained: Int) -> [String: Any] {
            ["region_id": id, "candidate_voxels": 1257,
             "below_floor_voxels": 1257, "stress_fraction_measured": stress,
             "qualified": qualified, "retained_voxels": retained]
        }
        var rows: [[String: Any]] = (1...5).map {
            region($0, latticed: 0, verdict: "no_pair", stress: 0.44,
                   nozzle: 0.3073)
        }
        var subRows: [[String: Any]] = (1...5).map {
            subRegion($0, stress: 0.44, qualified: false, retained: 0)
        }
        rows.append(region(6, latticed: 1257, verdict: "out_of_regime",
                           stress: 0.04))
        subRows.append(subRegion(6, stress: 0.04, qualified: true, retained: 1257))
        rows.append(region(7, latticed: 900, verdict: "certified", stress: 0.11))
        subRows.append(subRegion(7, stress: 0.11, qualified: true, retained: 0))
        let receiptJSON = try JSONSerialization.data(withJSONObject: [
            "grading": [
                "regions": rows,
                "subfloor_retention": ["armed": true,
                                       "stress_fraction_ceiling": 0.2,
                                       "over_budget": false,
                                       "regions": subRows],
            ],
        ])
        let report = LatticeReport(
            topologyID: "octet", cellMM: 8, generateRelativeDensity: 0.5,
            minRelativeDensity: 0.2, maxRelativeDensity: 0.5,
            regionScoped: true, emittedRegions: 7,
            generated: LatticeReport.Generated(
                emitSTL: true, emit3MF: false, latticedCells: 1131,
                regionVoxels: 8799, triangles: 2_400_000,
                strutRadiusMinMM: 0.21, strutRadiusMaxMM: 0.88),
            strut: nil, regionCellsJSON: receiptJSON)
        print("R4 --- the results screen's lattice lines (CONSTRUCTED GRADED FIXTURE, not his uniform run) ---")
        for line in ResultsModel.latticeNotes(report) { print("     • \(line)") }
    }
}
