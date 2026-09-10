import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE UI WIRED TO CORE MAIN (PR 355 merged 2026-09-06): the brief's job keys,
/// the organic floor, the recommendation and the receipt.
final class OrganicMainWiringTests: XCTestCase {

    private func spec(structural: Bool, grown: Bool = false) -> LatticeSpec {
        var s = LatticeSpec(topologyID: "octet", cellMM: 6, strutRadiusMM: 0.6,
                            generateRelativeDensity: 0.2, minRelativeDensity: 0.05,
                            maxRelativeDensity: 0.9, graded: true)
        s.algorithm = "organic"
        s.stageMode = structural ? .structural : .aesthetic
        s.organicGrowth = grown; s.layerHeightMM = 0.2
        return s
    }

    /// The keys main accepts (job.cpp allow-list): the certificate is REQUIRED with a
    /// structural intent; ties/swirl ride the grown path; the rim only when changed.
    func testTheBriefsKeysAreWrittenWhenCoreAcceptsThem() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_structural_certification") else {
            throw XCTSkip("this core predates PR 355")
        }
        let g = try XCTUnwrap(spec(structural: true).gradingDictionary())
        XCTAssertEqual(g["intent"] as? String, "structural")
        XCTAssertEqual(g["organic_structural_certification"] as? String, "beam_network")
        XCTAssertNil(g["organic_transfer_ties"], "default true ⇒ absent")
        XCTAssertNil(g["organic_tie_swirl"], "default 1 ⇒ absent")
        XCTAssertNil(g["organic_solid_rim_mm"], "default −1 ⇒ absent")
        let a = try XCTUnwrap(spec(structural: false).gradingDictionary())
        XCTAssertNil(a["organic_structural_certification"], "aesthetic: no certificate")
        var s = spec(structural: false, grown: true)
        s.organicTransferTies = false; s.organicSolidRimMM = 0
        let t = try XCTUnwrap(s.gradingDictionary())
        XCTAssertEqual(t["organic_transfer_ties"] as? Bool, false)
        XCTAssertEqual(t["organic_solid_rim_mm"] as? Double, 0)
        var w = spec(structural: false, grown: true); w.organicTieSwirl = 0.3
        XCTAssertEqual(try XCTUnwrap(w.gradingDictionary())["organic_tie_swirl"] as? Double, 0.3)
        var traced = spec(structural: false, grown: false); traced.organicTransferTies = false
        XCTAssertNil(try XCTUnwrap(traced.gradingDictionary())["organic_transfer_ties"], "ties are the grown path's")
    }

    /// Manual on the wire: one size = cell_mode fit + cell_mm; a grade = cell_mode
    /// auto + cell_min/max — the same keys the recommendation's buttons write.
    func testManualMapsOntoTheCellKeys() throws {
        var s = spec(structural: false)
        s.organicPickedSeparationMM = 4.5
        let g = try XCTUnwrap(s.gradingDictionary())
        XCTAssertEqual(g["cell_mode"] as? String, "fit")
        XCTAssertEqual(g["cell_mm"] as? Double, 4.5)
        XCTAssertNil(g["cell_min_mm"]); XCTAssertNil(g["organic_separation_mm"])
        var t = spec(structural: false)
        t.organicPickedGradeMM = [3, 5]
        let h = try XCTUnwrap(t.gradingDictionary())
        XCTAssertEqual(h["cell_mode"] as? String, "auto")
        XCTAssertEqual(h["cell_min_mm"] as? Double, 3)
        XCTAssertEqual(h["cell_max_mm"] as? Double, 5)
        XCTAssertNil(h["cell_mm"]); XCTAssertNil(h["organic_window_mm"])
    }

    /// §0: the organic floor is max(1.535 × bead, one voxel), never the octet bound.
    func testTheOrganicFloor() {
        let f = OrganicSizeCheck.floor(beadMM: 0.45, voxelMM: 0.5)
        XCTAssertEqual(f.beadFloorMM, 0.691, accuracy: 0.001, "the STAND runs printed 'bead floor 0.691'")
        XCTAssertEqual(f.mm, 0.691, accuracy: 0.001)
        XCTAssertFalse(f.resolutionBound)
        let g = OrganicSizeCheck.floor(beadMM: 0.45, voxelMM: 1.71)
        XCTAssertEqual(g.mm, 1.71, accuracy: 1e-9, "at 128³ on the STAND the voxel binds")
        XCTAssertTrue(g.resolutionBound)
        XCTAssertLessThan(g.mm, 4.93, "seven times under the octet bound")
        let v = OrganicSizeCheck.evaluate(cellMinMM: 1.0, cellMaxMM: 1.0,
                                          walls: [.init(key: "f", depthMM: 12)], floor: g, probe: nil)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.reasons.contains { $0.contains("solve grid (1.71 mm)") }, v.text)
        let ok = OrganicSizeCheck.evaluate(cellMinMM: 1.71, cellMaxMM: 1.71,
                                           walls: [.init(key: "f", depthMM: 12)], floor: g, probe: nil)
        XCTAssertTrue(ok.allowed, "the probe measured the 1.71 mm cell rooting and certifying")
    }

    /// §3: the recommendation block parses, and its floor is the smallest cell.
    func testTheRecommendationParses() throws {
        let doc: [String: Any] = [
            "organic_probe_version": 1, "candidates": [],
            "recommendation": [
                "ran": true, "mode": "aesthetic", "band_lo_mm": 1.71, "band_hi_mm": 6.0, "collapsed": false,
                "printability_floor_mm": 0.691, "resolution_floor_mm": 1.71,
                "member_ceiling_mm": 6.0, "extent_ceiling_mm": 12.0, "look_cell_mm": 3.0,
                "grade_ratio": 1.6, "look_cells_across": 8, "target_margin": 1.5,
                "fit": ["found": true, "cell_mm": 3.0, "margin": 1.84, "traced_mm": 26100, "source": "look"],
                "auto": ["found": true, "cell_min_mm": 3.0, "cell_max_mm": 4.8, "margin": 1.6, "traced_mm": 24000, "source": "look_pair"],
                "rejected": [["cell_min_mm": 6.0, "cell_max_mm": 6.0, "source": "grid", "reason": "rooted 0.91 < 0.95"]],
            ],
        ]
        let p = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(withJSONObject: doc)))
        let r = try XCTUnwrap(p.recommendation)
        XCTAssertTrue(r.ran); XCTAssertEqual(r.mode, "aesthetic")
        XCTAssertEqual(r.floorMM, 1.71); XCTAssertTrue(r.floorIsResolutionBound)
        XCTAssertEqual(r.fit?.cellMM, 3.0); XCTAssertEqual(r.auto?.cellMaxMM, 4.8)
        XCTAssertEqual(r.rejected.first?.reason, "rooted 0.91 < 0.95")
        XCTAssertTrue(r.boundsText.contains("grid 1.71 mm"))
        let f = OrganicSizeCheck.floor(from: r)
        XCTAssertEqual(f.mm, 1.71); XCTAssertTrue(f.resolutionBound)
    }

    /// §2: the receipt's certificate, ties, fillet, floors, recommendation and
    /// per-face synthetic rows, in the brief's display rule.
    func testTheReceiptReadsMainsKeys() {
        let info: [String: Any] = ["grading": ["organic": [
            "structural_verdict": "refused", "structural_margin": 1.19, "structural_statistic": "p99",
            "structural_refusal": "the worst strut exceeds its allowable under distributed load",
            "structural_max_over_allowable_distributed": 1.31, "structural_max_exceeds_allowable": true,
            "structural_knockdown_used": 0.42, "structural_knockdown_source": "z_knockdown by orientation",
            "transfer_ties_on": true, "ties_landed": 118, "tie_swirl": 1.0,
            "overhang_fillet_on": false, "fillet_skipped_spans": 239,
            "solid_rim_mm": 3.0, "shape_fit_on": true,
            "spacing_print_floor_mm": 0.691, "spacing_resolution_floor_mm": 1.71,
            "support_grid_too_large": false, "tensor_note": "",
            "recommend": ["fit_found": true, "fit_mm": 4.5, "auto_found": true, "auto_lo_mm": 3.0, "auto_hi_mm": 5.0,
                          "band_lo_mm": 1.71, "band_hi_mm": 6.0, "collapsed": false],
            "synthetic_stress_regions": 1, "synthetic_stress_voxels": 12480, "synthetic_stress_fully": 12480,
            "synthetic_stress_by_region": [
                ["face_id": 2, "region_id": 1, "foci": 4, "voxels": 12480, "fully": 12480, "blended": 0],
                ["face_id": 15, "region_id": 2, "foci": 4, "voxels": 9000, "fully": 0, "blended": 0]],
        ]]]
        let r = OrganicRunReceipt(info: info)
        XCTAssertEqual(r.floorMM, 1.71)
        XCTAssertEqual(r.certificateLine, "Refused · margin 1.19 (p99) · the worst strut exceeds its allowable under distributed load · worst strut 1.31× allowable")
        XCTAssertEqual(r.repairsLine, "239 spans left over air · 118 ties landed")
        XCTAssertEqual(r.fittingSeparationsMM, [4.5], "the FIT pick is the approved separation")
        XCTAssertEqual(r.recommendAutoLoMM, 3.0); XCTAssertEqual(r.recommendAutoHiMM, 5.0)
        XCTAssertEqual(r.syntheticStressByFace[2]?.text, "synthetic field: 4 foci, 12480 of 12480 voxels")
        XCTAssertEqual(r.syntheticStressByFace[15]?.text, "carried load, untouched")
        let certified = OrganicRunReceipt(info: ["grading": ["organic": [
            "structural_verdict": "certified", "structural_margin": 2.31,
            "structural_max_over_allowable_distributed": 0.43]]])
        XCTAssertEqual(certified.certificateLine, "Certified · margin 2.31 (p99) · worst strut 0.43× allowable")
        XCTAssertNil(OrganicRunReceipt(info: ["grading": ["organic": ["structural_verdict": "not run"]]]).certificateLine)
    }

    /// The Check-sizes job carries the recommendation request beside the candidates.
    func testTheProbeJobCarriesTheRecommendRequest() throws {
        let job: [String: Any] = ["grading": ["algorithm": "organic", "intent": "aesthetic"],
                                  "lattice": ["topology": "octet"]]
        let data = try JSONSerialization.data(withJSONObject: job)
        let out = try RelatticeRun.probeJob(data, cellsMM: [3.5], gradesMM: [],
                                            recommend: .init(mode: "auto", lookCellsAcross: 8, margin: 1.5, steps: 5))
        let lat = try XCTUnwrap((try JSONSerialization.jsonObject(with: out) as? [String: Any])?["lattice"] as? [String: Any])
        XCTAssertEqual(lat["organic_recommend"] as? String, "auto")
        XCTAssertEqual(lat["organic_look_cells_across"] as? Int, 8)
        XCTAssertEqual(lat["organic_recommend_margin"] as? Double, 1.5)
        XCTAssertEqual(lat["organic_recommend_steps"] as? Int, 5)
        // A recommendation alone is a valid request (core generates the candidates).
        let alone = try RelatticeRun.probeJob(data, cellsMM: [], gradesMM: [], recommend: .init())
        XCTAssertNotNil(alone)
        XCTAssertThrowsError(try RelatticeRun.probeJob(data, cellsMM: [], gradesMM: [], recommend: nil))
    }

    /// The probes this app gates on now pass against main's schema.
    func testMainsSchemaAcceptsWhatTheUIGatesOn() throws {
        guard TopOptKit.gradingSchemaAccepts(key: "organic_structural_certification") else {
            throw XCTSkip("this core predates PR 355")
        }
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "organic_overhang_fillet"))
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "organic_transfer_ties"))
        XCTAssertTrue(TopOptKit.organicSyntheticStressWired, "per-region synthetic_stress/foci")
        XCTAssertTrue(TopOptKit.organicProbeWired, "organic_probe_cells_mm / grades")
        XCTAssertTrue(TopOptKit.organicStructuralCertificationWired, "beam_network certificate")
    }
}
