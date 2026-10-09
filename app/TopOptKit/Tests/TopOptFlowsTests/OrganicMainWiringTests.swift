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

    /// Manual on the wire (ruling 5, 2026-10-03): one size = the one-size window, swept with
    /// cell_min_mm == cell_max_mm; a grade = swept with lo < hi. Never fit + cell_mm, which
    /// core's schema refuses.
    func testManualMapsOntoTheCellKeys() throws {
        var s = spec(structural: false)
        s.organicPickedSeparationMM = 4.5
        let g = try XCTUnwrap(s.gradingDictionary())
        XCTAssertEqual(g["cell_mode"] as? String, "swept")
        XCTAssertEqual(g["cell_min_mm"] as? Double, 4.5)
        XCTAssertEqual(g["cell_max_mm"] as? Double, 4.5)
        XCTAssertNil(g["cell_mm"]); XCTAssertNil(g["organic_separation_mm"])
        var t = spec(structural: false)
        t.organicPickedGradeMM = [3, 5]
        let h = try XCTUnwrap(t.gradingDictionary())
        // ★★★ "swept", NOT "auto" (corrected 2026-09-08). This test DID build a graded
        // organic job and asserted the mode the app was writing — so it pinned the
        // defect rather than catching it: core parses `cell_min_mm`/`cell_max_mm` only
        // under swept and REFUSES them under auto, and the whole lattice stage died on
        // that refusal the moment the Look slider landed on a real range. A dictionary
        // this app writes is not evidence of what core will accept; see
        // `testAGradedOrganicJobUsesTheSweptWindowCoreParses`, which reads core's own
        // rule.
        XCTAssertEqual(h["cell_mode"] as? String, "swept")
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
                // ★ margin 0: what core writes on an AESTHETIC recommendation — its probe
                // runs no certificate there (`want_cert`, run_job.cpp)
                "fit": ["found": true, "cell_mm": 3.0, "margin": 0, "traced_mm": 26100, "source": "look"],
                "auto": ["found": true, "cell_min_mm": 3.0, "cell_max_mm": 4.8, "margin": 0, "traced_mm": 24000, "source": "look_pair"],
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
        // ★ an aesthetic recommendation shows NO margin — nothing, never "0.00"
        let fit = try XCTUnwrap(r.fit), auto = try XCTUnwrap(r.auto)
        XCTAssertFalse(r.showsMargin)
        XCTAssertNil(r.tint, "★ no colour verdict under Aesthetic (ruling A)")
        XCTAssertEqual(r.pillText(fit), "Fit 3 mm"); XCTAssertEqual(r.pillText(auto), "Auto 3–4.8 mm")
        for t in [r.pillText(fit), r.pillText(auto), r.infoText(fit), r.infoText(auto)] {
            XCTAssertFalse(t.contains("0.00") || t.contains("margin") || t.contains("·"), t)
        }
    }

    /// ★ …and a STRUCTURAL one keeps its predicted margin (positive control for the above).
    func testAStructuralRecommendationShowsItsMargin() throws {
        let doc: [String: Any] = [
            "organic_probe_version": 1, "candidates": [],
            "recommendation": [
                "ran": true, "mode": "structural", "band_lo_mm": 1.71, "band_hi_mm": 6.0, "collapsed": false,
                "printability_floor_mm": 0.691, "resolution_floor_mm": 1.71,
                "member_ceiling_mm": 6.0, "extent_ceiling_mm": 12.0, "look_cell_mm": 3.0,
                "grade_ratio": 1.6, "look_cells_across": 8, "target_margin": 1.5,
                "fit": ["found": true, "cell_mm": 3.0, "margin": 1.84, "traced_mm": 26100, "source": "grid"],
                "auto": ["found": true, "cell_min_mm": 3.0, "cell_max_mm": 4.8, "margin": 1.6, "traced_mm": 24000, "source": "grid_pair"],
                "rejected": [],
            ],
        ]
        let r = try XCTUnwrap(OrganicForecast.parse(try JSONSerialization.data(withJSONObject: doc))?.recommendation)
        XCTAssertTrue(r.showsMargin)
        XCTAssertEqual(r.tint, .green, "a structural pick is rooted, certified and at the target margin")
        XCTAssertEqual(r.pillText(try XCTUnwrap(r.fit)), "Fit 3 mm · 1.84")
        XCTAssertEqual(r.pillText(try XCTUnwrap(r.auto)), "Auto 3–4.8 mm · 1.60")
        XCTAssertTrue(r.infoText(try XCTUnwrap(r.auto)).contains("Predicted margin 1.60."))
    }

    /// ★ The wizard's pills are built by those helpers — a value-type test alone would
    /// miss a call site that still formats the margin itself.
    func testTheWizardPillsUseTheRecommendationsText() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TopOptFlows/LatticeSetupWizard.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("organicPill(rec.pillText(a)"))
        XCTAssertTrue(src.contains("organicPill(rec.pillText(f)"))
        XCTAssertFalse(src.contains("Predicted margin %.2f"), "the wizard formats no margin of its own")
        // ★ ruling A: the Recommended pills take the recommendation's own tint (nil under
        // Aesthetic), the candidate pills are coloured only under Structural, and the (i)
        // is the mode's own meaning — no certificate caveat appended under Aesthetic
        XCTAssertFalse(src.contains("OrganicProbeTintModifier(tint: .green)"))
        XCTAssertEqual(src.components(separatedBy: "OrganicProbeTintModifier(tint: rec.tint)").count - 1, 2)
        XCTAssertFalse(src.contains("OrganicForecast.tint(c),"))
        XCTAssertEqual(src.components(separatedBy: "OrganicForecast.tint(c, structural: structural)").count - 1, 2)
        XCTAssertEqual(src.components(separatedBy: "OrganicForecast.meaning(structural: structural)").count - 1, 2)
        XCTAssertFalse(src.contains("+ \" \" + OrganicForecast.notCertified"))
        // ★ ruling V3 (2026-09-29): no bare "*" on a Structural pill that was never checked;
        // the headings claim "Likely to certify" only when a size was; an unchecked
        // Recommended pick is not offered under Structural; the Manual seed is selectable
        XCTAssertFalse(src.contains("%g–%g mm*"))
        XCTAssertTrue(src.contains("organicPill(m.label,"))
        XCTAssertEqual(src.components(separatedBy: "label: c.pillText(structural: structural)").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "c.hoverText(structural: structural, probedIntent: probe.probedIntent)").count - 1, 2)
        XCTAssertEqual(src.components(separatedBy: "organicProbePresent && structural && organicAnyChecked").count - 1, 2)
        XCTAssertTrue(src.contains("uncheckedSummary(\n            structural: structural, grades: model.simulateStresses, checkRefusal: organicProbeRefusal)"))
        XCTAssertTrue(src.contains("anyChecked(grades: model.simulateStresses)"), "the heading reads the list shown")
        XCTAssertEqual(src.components(separatedBy: "enabled: !structural || rec.showsMargin").count - 1, 2)
        XCTAssertTrue(src.contains("organicManualGrades.first(where: { $0.selectable })?.grade"))
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
            // ★ core #358: the flare is gone; `unsupported_spans` counts what could not be held
            // up (1728 on his stand). An OLD receipt's fillet keys ride along and must be ignored.
            "unsupported_spans": 1728,
            "overhang_fillet_on": false, "fillet_skipped_spans": 239, "filleted_spans": 12,
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
        XCTAssertEqual(r.unsupportedSpans, 1728)
        XCTAssertEqual(r.repairsLine, "1728 spans cross open air — printed as drawn, with nothing underneath · 118 ties landed",
                       "the fillet stage is gone (#358): its keys are not shown")
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
        // ★ core #358 removed the overhang fillet: the key is REFUSED, so the job never writes
        // it (`put` is schema-gated) and the wizard hides its toggle
        XCTAssertFalse(TopOptKit.gradingSchemaAccepts(key: "organic_overhang_fillet"))
        XCTAssertTrue(TopOptKit.gradingSchemaAccepts(key: "organic_transfer_ties"))
        XCTAssertTrue(TopOptKit.organicSyntheticStressWired, "per-region synthetic_stress/foci")
        XCTAssertTrue(TopOptKit.organicProbeWired, "organic_probe_cells_mm / grades")
        XCTAssertTrue(TopOptKit.organicStructuralCertificationWired, "beam_network certificate")
    }

    /// ★★★ A GRADED ORGANIC JOB MUST OPEN (his walk, 2026-09-08: the lattice stage died
    /// on `job.json: grading "cell_min_mm" / "cell_max_mm" are only allowed with
    /// "cell_mode": "swept"`).
    ///
    /// The Look slider writes a window, and the window was being sent under
    /// `cell_mode: "auto"` — which core refuses outright, and which would have dropped
    /// the window even if it had not. No test had ever built a graded organic job, so
    /// the whole stage was unreachable the moment the slider landed on a real range.
    func testAGradedOrganicJobUsesTheSweptWindowCoreParses() throws {
        var s = spec(structural: false)
        s.organicPickedSeparationMM = 0
        s.organicPickedGradeMM = [1.81, 3.62]
        let g = try XCTUnwrap(s.gradingDictionary())
        XCTAssertEqual(g["cell_mode"] as? String, "swept",
                       "★ core parses cell_min_mm/cell_max_mm ONLY under swept")
        XCTAssertEqual(g["cell_min_mm"] as? Double, 1.81)
        XCTAssertEqual(g["cell_max_mm"] as? Double, 3.62)
        XCTAssertNil(g["cell_mm"], "a target alongside a ladder is a conflict core refuses")
        // ★ A single size is the one-size window (ruling 5, 2026-10-03), never fit + cell_mm.
        var one = spec(structural: false)
        one.organicPickedSeparationMM = 3.5
        one.organicPickedGradeMM = []
        let f = try XCTUnwrap(one.gradingDictionary())
        XCTAssertEqual(f["cell_mode"] as? String, "swept")
        XCTAssertEqual(f["cell_min_mm"] as? Double, 3.5)
        XCTAssertEqual(f["cell_max_mm"] as? Double, 3.5)
        XCTAssertNil(f["cell_mm"])
        // ★ AND THE RULE ITSELF, READ FROM CORE rather than restated here: the refusal
        // this test exists for is a literal in job.cpp.
        let root: URL = {
            var u = URL(fileURLWithPath: #filePath); for _ in 0..<5 { u.deleteLastPathComponent() }
            return u
        }()
        let jobCpp = try String(contentsOf: root.appendingPathComponent("core/src/cli/job.cpp"),
                                encoding: .utf8)
        XCTAssertTrue(jobCpp.contains("are only allowed with "),
                      "★ core still refuses a window outside swept; if this line goes, "
                      + "re-read the rule before relaxing the app")
        XCTAssertTrue(jobCpp.contains("must be >= \\\"cell_min_mm\\\""),
                      "★ equal ends pass because core's rule is >=, read from job.cpp")
    }
}

/// ★★ MAINTAINER, 2026-10-03, RULING 5: "Organic single-size Fit: the app sends a one-size
/// window (cell_min_mm = cell_max_mm = the size), with no schema change. The app must never
/// write a job core refuses: add a test that core's parser accepts what the app writes."
/// Every organic cell shape the app can write, through the app's REAL builders (the stage's
/// `lattice_part` document, and the variant's run, forecast and Check-sizes documents), parsed
/// by core's own `parse_job`. Before this ruling the single size was `fit` + `cell_mm` and
/// core refused every one of those documents; nothing caught it, because the old tests read
/// the dictionary the app built and never handed it to core.
@MainActor
final class OrganicJobsCoreAcceptsTests: XCTestCase {

    private enum Pick: String, CaseIterable { case single, grade, auto, fitNoPick }

    private func project(_ pick: Pick) -> ProjectModel {
        let (p, _, _) = VariantFacePrismFixture.project(organic: true)
        switch pick {
        case .single:
            p.lattice.setSimulateStresses(false); p.lattice.cellSizeMode = .fit
            p.lattice.organicPickedSeparationMM = 4
        case .grade:
            p.lattice.setSimulateStresses(true); p.lattice.cellSizeMode = .fit
            p.lattice.organicPickedGradeMM = [3, 5]
        case .auto:
            p.lattice.setSimulateStresses(true); p.lattice.cellSizeMode = .auto
        case .fitNoPick:
            p.lattice.setSimulateStresses(false); p.lattice.cellSizeMode = .fit
        }
        return p
    }

    /// The stage's `lattice_part` document, built the way the app builds it.
    private func stageDocument(_ p: ProjectModel) throws -> Data {
        let spec = try XCTUnwrap(p.latticeRunSpec(emission: p.latticeJobRegions()), "no run spec")
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "", rulesPath: "",
            resolution: 64, projectName: "organic", anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [4], force: SIMD3(0, 0, -250))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            lattice: spec, jobMode: "lattice_part")
        return try RemoteRun.buildJobJSON(request)
    }

    private func grading(_ doc: Data) throws -> [String: Any] {
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: doc) as? [String: Any])
        return try XCTUnwrap(job["grading"] as? [String: Any], "an organic job carries a grading block")
    }

    func testCoresParserAcceptsEveryOrganicCellShapeTheAppWrites() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        for pick in Pick.allCases {
            let p = project(pick)
            let stage = try stageDocument(p)
            var docs = [("stage", stage)]
            docs += try VariantFacePrismFixture.variantDocuments(p)
            for (name, doc) in docs {
                XCTAssertNil(TopOptKit.jobSchemaError(doc),
                             "★ \(pick.rawValue) \(name): core refuses — \(TopOptKit.jobSchemaError(doc) ?? "")")
            }
            let g = try grading(stage)
            switch pick {
            case .single:
                XCTAssertEqual(g["cell_mode"] as? String, "swept")
                XCTAssertEqual(g["cell_min_mm"] as? Double, 4)
                XCTAssertEqual(g["cell_max_mm"] as? Double, 4)
                XCTAssertNil(g["cell_mm"], "★ never fit + cell_mm")
            case .grade:
                XCTAssertEqual(g["cell_mode"] as? String, "swept")
                XCTAssertEqual(g["cell_min_mm"] as? Double, 3)
                XCTAssertEqual(g["cell_max_mm"] as? Double, 5)
            case .auto:
                XCTAssertNil(g["cell_min_mm"]); XCTAssertNil(g["cell_mm"])
            case .fitNoPick:
                XCTAssertEqual(g["cell_mode"] as? String, "fit")
                XCTAssertNil(g["cell_mm"]); XCTAssertNil(g["cell_min_mm"])
            }
            // the preview traces the window the job states — one mapping, both sides
            if pick == .single || pick == .grade {
                let w = p.lattice.organicPreviewSeparationWindowMM
                XCTAssertEqual(g["cell_min_mm"] as? Double, w.lo, pick.rawValue)
                XCTAssertEqual(g["cell_max_mm"] as? Double, w.hi, pick.rawValue)
            }
        }
    }

    /// The test cannot be green by accident: the old single-size shape spliced back in is
    /// refused by core (the parser does reach the grading block), and an inverted window is
    /// refused too (equal ends pass because core's rule is `>=`, not because nothing checks).
    func testTheControlsAreRefused() throws {
        guard TopOptKit.latticeAlgorithmIsKnown("organic") else { throw XCTSkip("no organic in core") }
        let stage = try stageDocument(project(.single))
        var job = try XCTUnwrap(JSONSerialization.jsonObject(with: stage) as? [String: Any])
        var g = try XCTUnwrap(job["grading"] as? [String: Any])
        g["cell_mode"] = "fit"; g["cell_mm"] = 4.0
        g.removeValue(forKey: "cell_min_mm"); g.removeValue(forKey: "cell_max_mm")
        job["grading"] = g
        let old = try JSONSerialization.data(withJSONObject: job)
        XCTAssertTrue(TopOptKit.jobSchemaError(old)?.contains("\"cell_mm\" is not allowed") ?? false,
                      "★ control: the pre-ruling shape is refused — \(TopOptKit.jobSchemaError(old) ?? "nil")")
        g["cell_mode"] = "swept"; g.removeValue(forKey: "cell_mm")
        g["cell_min_mm"] = 4.0; g["cell_max_mm"] = 3.5
        job["grading"] = g
        let inverted = try JSONSerialization.data(withJSONObject: job)
        XCTAssertTrue(TopOptKit.jobSchemaError(inverted)?.contains("must be >=") ?? false,
                      "★ control: an inverted window is refused — \(TopOptKit.jobSchemaError(inverted) ?? "nil")")
    }
}
