// PrintOrientationJobsTests — ★ notes27 P7 (builder H; his print orientation 11-23, SPEC 2d "What Check strength re-runs"): the
// jobs "Check strength" sends — a topology result's analyze job with core's orientation_recheck on its own run job, a lattice's
// print file standing on the checked up (print_frame) — and what their answers say (the re-check spliced into the kept result,
// a lattice report's own numbers for the benefits modal).
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class PrintOrientationJobsTests: XCTestCase {
    // MARK: fixtures (shaped like his stand's v8 print file: core P4's block)

    static func ranking(change: Bool) -> [String: Any] {
        func cand(_ up: [Double], _ rests: String, asPlaced: Bool, offered: Bool, guessed: Double, support: Double, height: Double,
                  layers: Int, bed: Double, stands: Bool = true) -> [String: Any] {
            var c: [String: Any] = ["up": up, "rests_on": rests, "as_placed": asPlaced, "offered": offered, "dropped": NSNull(),
                                    "passes": guessed >= 1.5, "stands": stands, "support_mm3": support, "part_support_mm3": support,
                                    "height_mm": height, "layers": layers, "bed_contact_mm2": bed,
                                    "strength": ["guessed": guessed, "solid": 2.66, "solid_interlayer": 7.53, "struts": guessed,
                                                 "struts_under": 3, "struts_estimate": true]]
            if rests == "edge" {
                c["held_by_supports"] = true; c["edge_mm"] = 27.6
                c["stand_supports"] = ["band_mm": [48, 2], "area_mm2": 1380.0, "volume_mm3": 15925.2]
            }
            return c
        }
        return ["estimate": true, "required_margin": 1.5, "as_placed": 0, "recommended": change ? 1 : 0, "change": change,
                "headline": change ? "new_orientation_may_be_stronger" : "best_orientation", "none_passes": false,
                "why": change ? ["Stronger across the layers"] : [], "hull": true,
                "candidates": [cand([0, 0, 1], "face", asPlaced: true, offered: true, guessed: 1.34, support: 2000.4, height: 70,
                                    layers: 350, bed: 3119.8),
                               cand([0.7071067812, 0, 0.7071067812], "edge", asPlaced: false, offered: true, guessed: 1.40,
                                    support: 18668.8, height: 110.4, layers: 553, bed: 0)]]
    }

    static func outcome(_ report: [String: Any]) throws -> OptimizeOutcome {
        OptimizeOutcome(variants: [], stoppedOnMargin: false, cancelled: false, acceptedCount: 0,
                        reportJSON: try JSONSerialization.data(withJSONObject: report))
    }

    // MARK: P7: the jobs

    func testTheTopologyRecheckJobIsItsOwnRunJobAsAnAnalyze() throws {
        let run: [String: Any] = ["mode": "minimize_plastic", "model": "model.step", "material": "PA12", "resolution": 64,
                                  "loads": ["build_dir": [0, 0, 1]], "bake_build_orientation": "off"]
        let job = try PrintCheckJobs.recheckJob(runJob: try JSONSerialization.data(withJSONObject: run), up: SIMD3(0, 1, 0))
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: job) as? [String: Any])
        XCTAssertEqual(o["mode"] as? String, "analyze", "★ core's re-check is an analyze job")
        let rc = try XCTUnwrap(o["orientation_recheck"] as? [String: Any])
        XCTAssertEqual(rc["mesh"] as? String, "recheck.stl", "the mesh the worker saves beside it")
        XCTAssertEqual(rc["build_dir"] as? [Double], [0, 1, 0])
        XCTAssertEqual(o["material"] as? String, "PA12", "its own loads, material, margin: the run's")
        XCTAssertEqual((o["loads"] as? [String: Any])?["build_dir"] as? [Int], [0, 0, 1], "the service gravity untouched")
    }

    func testTheLatticeJobsStandOnTheCheckedUp() throws {
        let p = ProjectModel(id: UUID(), name: "Stand", material: "PLA", process: .fdm,
                             importedFile: ImportedFile(name: "stand.step", path: "/nonexistent/stand.step", triangleCount: 12,
                                                        faceCount: 6, watertight: true),
                             importedMesh: nil)
        let up = SIMD3<Double>(0.7071067812, 0, 0.7071067812)
        let field = LatticeDemandField(vonMises: [Float](repeating: 10, count: 8), nx: 2, ny: 2, nz: 2, origin: .zero, spacingMM: 1,
                                       provenance: .solidSim(date: Date(timeIntervalSince1970: 0), resolution: 2))
        let stress = LatticeLayoutPreview.Stress(key: 1, field: field, referenceMPa: 10)
        let made = LatticeFileJob.forPart(p, stress: stress, strengthJob: Data("{}".utf8), printUp: up)
        guard case .success(let job) = made else {
            if case .failure(let why) = made { XCTFail("the cell lattice's job: \(why.line)") }
            return
        }
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: job.json) as? [String: Any])
        XCTAssertEqual((o["print_frame"] as? [String: Any])?["up"] as? [Double], [up.x, up.y, up.z], "★ the print file stands that way")
        XCTAssertEqual(o["strength_job"] as? String, "strength_job.json", "the strength check rides with it (core turns it at its door)")
        guard case .success(let plain) = LatticeFileJob.forPart(p, stress: stress, strengthJob: nil) else {
            return XCTFail("as placed")
        }
        XCTAssertNil((try JSONSerialization.jsonObject(with: plain.json) as? [String: Any])?["print_frame"],
                     "RED CONTROL: as placed, no frame")
    }

    // MARK: what the re-check and the print file say

    func testTheRecheckIsReadAndSplicedIntoTheResult() throws {
        let standing: [String: Any] = ["height_mm": 60.0, "layers": 300, "layer_mm": 0.2, "bed_contact_mm2": 7200.0,
                                       "painted": ["triangles": 12, "area_mm2": 400.0, "est_volume_mm3": 5200.0],
                                       "slicer_supports": "painted", "file": "oriented.3mf",
                                       "print_frame": ["up": [0, 1, 0], "rotation_row_major": [1, 0, 0, 0, 0, 1, 0, -1, 0],
                                                       "translation_mm": [0, 0, 30]]]
        var base = standing
        base["height_mm"] = 70.0; base["layers"] = 350; base["bed_contact_mm2"] = 3120.0; base["slicer_supports"] = "off"
        base["painted"] = ["triangles": 0, "area_mm2": 0.0, "est_volume_mm3": 0.0] as [String: Any]
        let block: [String: Any] = ["build_dir": [0, 1, 0], "margin": 2.9, "interlayer_margin": 4.1, "margin_required": 1.5,
                                    "accepted": true, "overhang_area_mm2": 400.0, "support_volume_mm3": 5200.0,
                                    "standing": standing, "reason": "Strong enough printed this way",
                                    "baseline": ["build_dir": [0, 0, 1], "overhang_area_mm2": 0.0, "standing": base]]
        let rc = try XCTUnwrap(PrintRecheck.decode(analysis: ["orientation_recheck": block]))
        XCTAssertEqual(rc.margin, 2.9); XCTAssertEqual(rc.layerMargin, 4.1)
        XCTAssertEqual(rc.standing?.layers, 300); XCTAssertEqual(rc.baseline?.bedMM2, 3120)
        XCTAssertEqual(rc.standing?.frame?.up, SIMD3(0, 1, 0))
        let kept = PrintCheckJobs.withReport(try Self.outcome(["ok": true, "scenarios": []]), adding: ["orientation_recheck": block])
        let facts = PrintReportFacts.of(report: kept.reportJSON)
        XCTAssertEqual(facts.recheck?.margin, 2.9, "★ the kept result carries the measured re-check")
        XCTAssertEqual(facts.slicerSupports, "painted", "its supports word, from the file standing that way")
        XCTAssertEqual(facts.frame?.up, SIMD3(0, 1, 0), "★ Results draws it standing that way")
        let after = PrintBenefitRow.measured(standing: rc.standing, strength: rc.margin, layers: rc.layerMargin, tookS: 58)
        XCTAssertEqual(after.supportMM3, 5200); XCTAssertEqual(after.heightMM, 60); XCTAssertEqual(after.bedMM2, 7200)
    }

    func testALatticeReportsOwnNumbersForTheModal() throws {
        var r = IPadNotes1121Tests.report()
        r["print_orientation"] = Self.ranking(change: false)
        r["painted"] = ["places": 3, "places_painted": 1, "places_unpainted": 2, "triangles": 27, "area_mm2": 34.9,
                        "est_volume_mm3": 2139.8, "support_type": "tree(manual)", "at": [[-0.9, 18.9, 64.5]]] as [String: Any]
        let m = PrintBenefitRow.measured(latticeReport: r)
        XCTAssertEqual(m.supportMM3 ?? 0, 2139.8, accuracy: 1e-9)
        XCTAssertEqual(m.paintedPlaces, 1)
        XCTAssertEqual(m.heightMM, 70); XCTAssertEqual(m.layers, 350); XCTAssertEqual(m.bedMM2 ?? 0, 3119.8, accuracy: 1e-9)
        XCTAssertEqual(m.layerStrength, 4.5, "the solid's layer margin")
        XCTAssertEqual(m.strength ?? 0, 1.6, accuracy: 1e-9, "the governing answer: the weakest strut")
        XCTAssertEqual(m.tookS ?? 0, 600.5 + 620, accuracy: 1e-6, "the file and the strengthening")
    }

}
