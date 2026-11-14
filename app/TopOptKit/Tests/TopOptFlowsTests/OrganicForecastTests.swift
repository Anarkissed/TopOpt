import XCTest
import TopOptKit
@testable import TopOptFlows

/// ★ THE ORGANIC CELL-SIZE PROBE (final contract 2026-09-05): `organic_probe.json`
/// written inside a lattice-variant run; the UI is gated on the file.
final class OrganicForecastTests: XCTestCase {

    /// The contract's document, in shape.
    private static let probe: [String: Any] = [
        "organic_probe_version": 1, "algorithm": "organic", "growth": true,
        "transfer_ties": true,
        "rooted_gate": 0.95, "curves_per_family_gate": 2, "cells_across_advisory": 4.0,
        "candidates": [
            ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "trace_seconds": 31.2, "curves": 412,
             "components": 79, "traced_length_mm": 26100, "rooted_length_fraction": 0.97,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 2.7,
                 "curves_per_family": [14, 9, 6], "components": 40,
                 "traced_length_mm": 26100, "rooted_length_fraction": 0.97,
                 "approved_structural": true, "approved_aesthetic": true,
                 "refusals": "", "advice": "2.7 cells across; the lattice behaves as one material past ~4"]],
             "predicted": ["ran": true, "verdict": "certified", "margin": 1.84,
                           "p99_mpa": 12.1, "max_mpa": 19.3, "allowable_mpa": 31.0,
                           "segments": 26773, "seconds": 41.0, "refusal": ""],
             "approved_structural": true, "approved_aesthetic": true],
            ["cell_min_mm": 6.5, "cell_max_mm": 6.5, "trace_seconds": 18.0, "curves": 120,
             "components": 30, "traced_length_mm": 9000, "rooted_length_fraction": 0.96,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 1.8,
                 "curves_per_family": [6, 3, 2], "components": 30,
                 "traced_length_mm": 9000, "rooted_length_fraction": 0.96,
                 "approved_structural": false, "approved_aesthetic": true,
                 "refusals": "predicted refused: p99 34.0 MPa > allowable 31.0", "advice": ""]],
             "predicted": ["ran": true, "verdict": "refused", "margin": 0.91,
                           "p99_mpa": 34.0, "max_mpa": 40.2, "allowable_mpa": 31.0,
                           "segments": 8000, "seconds": 20.0,
                           "refusal": "p99 34.0 MPa exceeds the allowable 31.0 MPa"],
             "approved_structural": false, "approved_aesthetic": true],
            ["cell_min_mm": 3.0, "cell_max_mm": 5.0, "trace_seconds": 44.0, "curves": 600,
             "components": 120, "traced_length_mm": 30000, "rooted_length_fraction": 0.91,
             "candidate_voxels": 12480,
             "regions": [
                ["face_id": 2, "region_id": 1, "depth_mm": 12, "cells_across": 3.1,
                 "curves_per_family": [20, 12, 8], "components": 120,
                 "traced_length_mm": 30000, "rooted_length_fraction": 0.91,
                 "approved_structural": false, "approved_aesthetic": false,
                 "refusals": "rooted_length_fraction 0.91 < 0.95", "advice": ""]],
             "predicted": ["ran": false, "reason": "segment cap hit"],
             "approved_structural": false, "approved_aesthetic": false],
        ],
    ]

    private func data(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o) }

    func testTheFileParsesPerTheContract() throws {
        let p = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        XCTAssertEqual(p.probeVersion, 1)
        XCTAssertTrue(p.growth); XCTAssertTrue(p.transferTies)
        XCTAssertEqual(p.rootedGate, 0.95); XCTAssertEqual(p.curvesPerFamilyGate, 2)
        XCTAssertEqual(p.cellsAcrossAdvisory, 4.0)
        XCTAssertEqual(p.candidates.count, 3)
        XCTAssertEqual(p.sizes.map(\.cellMinMM), [4.5, 6.5])
        XCTAssertEqual(p.grades.map(\.gradeMM), [[3.0, 5.0]])
        let good = p.sizes[0]
        XCTAssertEqual(good.label, "4.5 mm")
        XCTAssertEqual(good.curves, 412); XCTAssertEqual(good.components, 79)
        XCTAssertEqual(good.regions[0].faceID, 2)
        XCTAssertEqual(good.regions[0].curvesPerFamily, [14, 9, 6])
        XCTAssertEqual(good.regions[0].advice.prefix(3), "2.7")
        XCTAssertEqual(good.predicted?.certified, true)
        XCTAssertEqual(good.marginText, "1.84")
        XCTAssertTrue(good.hoverText.contains("margin 1.84"), good.hoverText)
        let refused = p.sizes[1]
        XCTAssertEqual(refused.refusals, ["predicted refused: p99 34.0 MPa > allowable 31.0"], "verbatim")
        XCTAssertTrue(refused.hoverText.contains("p99 34.0 MPa exceeds"), refused.hoverText)
        let grade = p.grades[0]
        XCTAssertEqual(grade.label, "3–5 mm")
        XCTAssertNil(grade.marginText, "the prediction did not run")
        XCTAssertTrue(grade.hoverText.contains("segment cap hit"), grade.hoverText)
    }

    /// Absent, malformed, or a version this build does not understand ⇒ nil —
    /// "fall back to today's octet forecast; no organic approvals shown".
    func testUnknownVersionOrGarbageMeansNoApprovals() throws {
        var v2 = Self.probe; v2["organic_probe_version"] = 2
        XCTAssertNil(OrganicForecast.parse(try data(v2)))
        var none = Self.probe; none.removeValue(forKey: "organic_probe_version")
        XCTAssertNil(OrganicForecast.parse(try data(none)))
        XCTAssertNil(OrganicForecast.parse(Data("not json".utf8)))
        XCTAssertNil(OrganicForecast.parse(try data(["organic_probe_version": 1])), "no candidates")
    }

    /// green = approved_structural; amber = aesthetic only; grey = refused.
    /// Structural selects only green; Aesthetic selects all.
    func testTheMenusLaw() throws {
        let p = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        let green = p.sizes[0], amber = p.sizes[1], grey = p.grades[0]
        XCTAssertEqual(OrganicForecast.tint(green), .green)
        XCTAssertEqual(OrganicForecast.tint(amber), .amber)
        XCTAssertEqual(OrganicForecast.tint(grey), .grey)
        XCTAssertTrue(OrganicForecast.selectable(green, structural: true))
        XCTAssertFalse(OrganicForecast.selectable(amber, structural: true))
        XCTAssertFalse(OrganicForecast.selectable(grey, structural: true))
        for c in p.candidates { XCTAssertTrue(OrganicForecast.selectable(c, structural: false)) }
        // ★ the colours are Structural's alone (ruling A, 2026-09-29)
        XCTAssertEqual(OrganicForecast.tint(green, structural: true), .green)
        XCTAssertEqual(OrganicForecast.tint(amber, structural: true), .amber)
        XCTAssertNil(OrganicForecast.tint(grey, structural: true),
                     "★ ruling 3: its prediction did not run (segment cap hit) — no computed verdict, no colour")
        for c in p.candidates { XCTAssertNil(OrganicForecast.tint(c, structural: false)) }
    }

    /// ★ NO COLOUR VERDICT UNDER AESTHETIC (maintainer, 2026-09-29: "no green, no
    /// amber"). A candidate exactly as core writes it under aesthetic intent: no
    /// certificate ran, so approved_structural is false by construction.
    func testAnAestheticProbeShowsNoColour() throws {
        var doc = Self.probe
        doc["candidates"] = [[
            "cell_min_mm": 4.5, "cell_max_mm": 4.5, "trace_seconds": 31.2, "curves": 412,
            "components": 79, "traced_length_mm": 26100, "rooted_length_fraction": 0.97,
            "candidate_voxels": 12480, "regions": [],
            "predicted": ["ran": false, "reason": "aesthetic intent: nothing reads a certificate"],
            "approved_structural": false, "approved_aesthetic": true]]
        let c = try XCTUnwrap(OrganicForecast.parse(try data(doc))?.candidates.first)
        XCTAssertEqual(OrganicForecast.tint(c), .amber,
                       "control: the one-argument law paints it amber — 'did not pass the stress bar', never computed")
        XCTAssertNil(OrganicForecast.tint(c, structural: false), "★ no dot at all")
        XCTAssertNil(OrganicForecast.tint(c, structural: true),
                     "★ ruling 3: a stored aesthetic probe viewed under Structural — still nothing ran, still no dot")
        XCTAssertNil(c.marginText, "and no margin")
    }

    /// ★ NO PREDICTION THAT RAN, NO COLOUR (maintainer, 2026-09-29, ruling 3: "No
    /// computed verdict means no colour: not amber, not grey"). Each case shows the
    /// one-argument law's colour as the control, then nothing under Structural; a
    /// prediction that DID run keeps its colour.
    func testNoPredictionThatRanMeansNoColour() throws {
        func candidate(_ predicted: [String: Any]?, structural s: Bool, aesthetic a: Bool) throws -> OrganicForecast.Candidate {
            var c: [String: Any] = ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "regions": [],
                                    "approved_structural": s, "approved_aesthetic": a]
            if let predicted { c["predicted"] = predicted }
            var doc = Self.probe; doc["candidates"] = [c]
            return try XCTUnwrap(OrganicForecast.parse(try data(doc))?.candidates.first)
        }
        // nothing ran
        let noSegments = try candidate(["ran": false, "reason": "no segments"], structural: false, aesthetic: true)
        XCTAssertEqual(OrganicForecast.tint(noSegments), .amber, "control")
        XCTAssertNil(OrganicForecast.tint(noSegments, structural: true))
        let capped = try candidate(["ran": false, "reason": "612000 segments exceed the probe's 600000 cap"],
                                   structural: false, aesthetic: false)
        XCTAssertEqual(OrganicForecast.tint(capped), .grey, "control")
        XCTAssertNil(OrganicForecast.tint(capped, structural: true))
        XCTAssertNil(capped.marginText)
        XCTAssertTrue(capped.hoverText.contains("prediction did not run: 612000 segments exceed"), capped.hoverText)
        let absent = try candidate(nil, structural: false, aesthetic: true)
        XCTAssertNil(absent.predicted)
        XCTAssertEqual(OrganicForecast.tint(absent), .amber, "control")
        XCTAssertNil(OrganicForecast.tint(absent, structural: true))
        // it ran: the colour is a computed verdict and stays
        let refused = try candidate(["ran": true, "verdict": "refused", "margin": 0.91], structural: false, aesthetic: true)
        XCTAssertEqual(OrganicForecast.tint(refused, structural: true), .amber)
        let unrooted = try candidate(["ran": true, "verdict": "certified", "margin": 1.3], structural: false, aesthetic: false)
        XCTAssertEqual(OrganicForecast.tint(unrooted, structural: true), .grey, "certified, then refused for rooting")
        let green = try candidate(["ran": true, "verdict": "certified", "margin": 1.84], structural: true, aesthetic: true)
        XCTAssertEqual(OrganicForecast.tint(green, structural: true), .green)
        XCTAssertNil(OrganicForecast.tint(green, structural: false))
    }

    /// ★★ RULING V3 (2026-09-29): under Structural an unchecked candidate stays
    /// unselectable, but reads "Not checked" and core's reason — never the bare "*".
    func testAnUncheckedCandidateReadsNotCheckedNeverAStar() throws {
        func cand(_ predicted: [String: Any]?, structural s: Bool = false, aesthetic a: Bool = true,
                  mode: String? = nil) throws -> (OrganicForecast.Candidate, OrganicForecast) {
            var c: [String: Any] = ["cell_min_mm": 3.0, "cell_max_mm": 5.0, "regions": [],
                                    "approved_structural": s, "approved_aesthetic": a]
            if let predicted { c["predicted"] = predicted }
            var doc: [String: Any] = ["organic_probe_version": 1, "candidates": [c]]
            if let mode { doc["recommendation"] = ["ran": true, "mode": mode, "band_lo_mm": 3.0, "band_hi_mm": 6.0] }
            let f = try XCTUnwrap(OrganicForecast.parse(try data(doc)))
            return (try XCTUnwrap(f.candidates.first), f)
        }
        for predicted in [["ran": false, "reason": "no segments"],
                          ["ran": false, "reason": "aesthetic intent: nothing reads a certificate"],
                          ["ran": false, "reason": "612000 segments exceed the probe's 600000 cap"], nil] as [[String: Any]?] {
            let (c, f) = try cand(predicted)
            // CONTROL: the old pill — the bare star
            XCTAssertEqual(c.label + (c.approvedStructural ? "" : "*"), "3–5 mm*")
            XCTAssertEqual(c.pillText(structural: true), "3–5 mm · Not checked")
            XCTAssertFalse(c.pillText(structural: true).contains("*"))
            XCTAssertFalse(OrganicForecast.selectable(c, structural: true), "★ still unselectable under Structural")
            XCTAssertNil(OrganicForecast.tint(c, structural: true))
            let hover = c.hoverText(structural: true, probedIntent: f.probedIntent)
            XCTAssertTrue(hover.contains("Not checked: "), hover)
            if let r = predicted?["reason"] as? String { XCTAssertTrue(hover.contains(r), "core's reason, verbatim: \(hover)") }
            // under Aesthetic nothing changes
            XCTAssertEqual(c.pillText(structural: false), c.label + (c.approvedAesthetic ? "" : "*"))
        }
        // positive controls: a prediction that RAN keeps its words exactly
        let (refused, _) = try cand(["ran": true, "verdict": "refused", "margin": 0.91])
        XCTAssertEqual(refused.pillText(structural: true), "3–5 mm* · 0.91")
        let (certified, _) = try cand(["ran": true, "verdict": "certified", "margin": 1.84], structural: true)
        XCTAssertEqual(certified.pillText(structural: true), "3–5 mm · 1.84")
        XCTAssertTrue(OrganicForecast.selectable(certified, structural: true))
        // an approved-but-unchecked candidate is never offered under Structural
        let (odd, _) = try cand(["ran": false, "reason": "no segments"], structural: true)
        XCTAssertTrue(odd.approvedStructural, "control: approved…")
        XCTAssertFalse(OrganicForecast.selectable(odd, structural: true), "★ …but not checked, so not offered")
    }

    /// Core writes "N segments exceed the probe's 600000 cap" for a certificate it SKIPPED
    /// (an Aesthetic probe; sent to #358). Within the cap the line contradicts itself, so
    /// the true cause is said; above the cap, or on a Structural probe, it is verbatim.
    func testTheSelfContradictingCapLineIsNotShownAsTheReason() throws {
        func candidate(_ reason: String) throws -> OrganicForecast.Candidate {
            let doc: [String: Any] = ["organic_probe_version": 1, "candidates": [[
                "cell_min_mm": 4.5, "cell_max_mm": 4.5, "regions": [],
                "predicted": ["ran": false, "reason": reason],
                "approved_structural": false, "approved_aesthetic": true]]]
            return try XCTUnwrap(OrganicForecast.parse(try data(doc))?.candidates.first)
        }
        let within = try candidate("51080 segments exceed the probe's 600000 cap")
        XCTAssertTrue(within.hoverText.contains("51080 segments exceed"), "control: the old hover showed core's false line")
        let why = try XCTUnwrap(within.notCheckedReason(probedIntent: nil))
        XCTAssertTrue(why.contains("Aesthetic"), why); XCTAssertFalse(why.contains("exceed"), why)
        XCTAssertEqual(within.notCheckedReason(probedIntent: "structural"), "51080 segments exceed the probe's 600000 cap",
                       "on a Structural probe the line is core's, verbatim")
        let over = try candidate("612000 segments exceed the probe's 600000 cap")
        XCTAssertEqual(over.notCheckedReason(probedIntent: nil), "612000 segments exceed the probe's 600000 cap")
    }

    /// ★ NONE CHECKED: one line saying so and what would get them checked; nil when any
    /// was checked, under Aesthetic, or with no candidates.
    func testNoneCheckedSaysSoAndWhatWouldCheckThem() throws {
        func probe(_ reasons: [String?], mode: String? = nil) throws -> OrganicForecast {
            let cands: [[String: Any]] = reasons.enumerated().map { i, r in
                var c: [String: Any] = ["cell_min_mm": 3.5 + Double(i), "cell_max_mm": 3.5 + Double(i), "regions": [],
                                        "approved_structural": false, "approved_aesthetic": true]
                if let r { c["predicted"] = ["ran": false, "reason": r] }
                return c
            }
            var doc: [String: Any] = ["organic_probe_version": 1, "candidates": cands]
            if let mode { doc["recommendation"] = ["ran": true, "mode": mode, "band_lo_mm": 3.0, "band_hi_mm": 6.0] }
            return try XCTUnwrap(OrganicForecast.parse(try data(doc)))
        }
        let aes = try probe(["51080 segments exceed the probe's 600000 cap", "aesthetic intent: nothing reads a certificate"],
                            mode: "aesthetic")
        let s = try XCTUnwrap(aes.uncheckedSummary(structural: true, grades: false))
        XCTAssertTrue(s.line.hasPrefix("No size was checked for strength."), s.line)
        XCTAssertTrue(s.line.contains("Check sizes") && s.line.contains("Structural"), s.line)
        XCTAssertTrue(s.info.contains("3.5 mm:") && s.info.contains("4.5 mm:"), s.info)
        XCTAssertFalse(s.info.contains("exceed"), "the false cap line is not the reason")
        XCTAssertTrue(try probe(["612000 segments exceed the probe's 600000 cap"], mode: "structural")
            .uncheckedSummary(structural: true, grades: false)?.line.contains("larger size") == true)
        XCTAssertTrue(try probe(["no segments"], mode: "structural").uncheckedSummary(structural: true, grades: false)?
            .line.contains("mark a wall") == true)
        XCTAssertTrue(try probe([nil]).uncheckedSummary(structural: true, grades: false)?.line.contains("update it") == true)
        XCTAssertEqual(try probe(["no segments"]).uncheckedSummary(structural: true, grades: false, checkRefusal: "No worker is connected.")?
            .line, "No size was checked for strength. No worker is connected.", "never points at a button that is not there")
        // nil when there is nothing to say
        XCTAssertNil(aes.uncheckedSummary(structural: false, grades: false), "Aesthetic runs no strength check — not a gap")
        XCTAssertNil(try probe([]).uncheckedSummary(structural: true, grades: false))
        var mixedDoc: [String: Any] = ["organic_probe_version": 1, "candidates": [
            ["cell_min_mm": 4.5, "cell_max_mm": 4.5, "regions": [], "approved_structural": true, "approved_aesthetic": true,
             "predicted": ["ran": true, "verdict": "certified", "margin": 1.8]],
            ["cell_min_mm": 5.5, "cell_max_mm": 5.5, "regions": [], "approved_structural": false, "approved_aesthetic": true,
             "predicted": ["ran": false, "reason": "no segments"]]]]
        mixedDoc["x"] = 0
        XCTAssertNil(try XCTUnwrap(OrganicForecast.parse(try data(mixedDoc))).uncheckedSummary(structural: true, grades: false),
                     "one was checked")
        // ★ the LIST SHOWN decides: a checked 6.5 mm SIZE does not stand for grades none of
        // which was checked (the simulation on shows grades only)
        let split = try XCTUnwrap(OrganicForecast.parse(try data(["organic_probe_version": 1, "candidates": [
            ["cell_min_mm": 6.5, "cell_max_mm": 6.5, "regions": [], "approved_structural": true, "approved_aesthetic": true,
             "predicted": ["ran": true, "verdict": "certified", "margin": 2.1]],
            ["cell_min_mm": 3.0, "cell_max_mm": 5.0, "regions": [], "approved_structural": false, "approved_aesthetic": true,
             "predicted": ["ran": false, "reason": "612000 segments exceed the probe's 600000 cap"]]]] as [String: Any])))
        XCTAssertTrue(split.anyChecked, "control: across both lists, one was checked")
        XCTAssertFalse(split.anyChecked(grades: true), "★ but not one GRADE was")
        XCTAssertNotNil(split.uncheckedSummary(structural: true, grades: true), "★ so the grade list says so")
        XCTAssertNil(split.uncheckedSummary(structural: true, grades: false), "the size list had one checked")
    }

    /// ★ GREEN, AND THE STRUCTURAL RECOMMENDED PICK, NEED A CERTIFICATE THAT RAN — core's
    /// source, pinned: `cert_ok` is set only inside the branch that writes `ran: true`, and
    /// the structural recommender rejects an uncertified row. So the ran-guard above can
    /// never take a green dot away, and `Recommendation.tint`'s green always stands on a
    /// prediction that ran.
    func testGreenAndTheStructuralPickNeedACertificateThatRan() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        func flat(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                .split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
        }
        let run = try flat("core/src/cli/run_job.cpp")
        XCTAssertTrue(run.contains("bool cert_ok = false;"))
        XCTAssertEqual(run.components(separatedBy: "cert_ok = ").count - 1, 2, "declared once, set once")
        // #358 (154ce24f, synced 2026-09-30) made the skip ONE tested decision,
        // `organic_probe_certificate_skip`: None only with a structural question, a network, and
        // no more segments than the cap — the old branch's own condition, reason by reason.
        let hpp = try flat("core/include/topopt/organic_lattice.hpp")
        XCTAssertTrue(hpp.contains("if (!want_cert) return OrganicProbeSkip::AestheticIntent; "
                                   + "if (segments == 0) return OrganicProbeSkip::NoSegments; "
                                   + "if (segments > cap) return OrganicProbeSkip::SegmentCap; "
                                   + "return OrganicProbeSkip::None;"))
        XCTAssertTrue(run.contains("constexpr std::size_t kProbeSegmentCap = 600000;"))
        let branch = try XCTUnwrap(run.range(of: "if (skip == OrganicProbeSkip::None) {"))
        let certify = try XCTUnwrap(run.range(of: "certify_organic_structural("))
        let set = try XCTUnwrap(run.range(of: "cert_ok = pc.margin >= 1.0;"))
        let ranTrue = try XCTUnwrap(run.range(of: #"\"predicted\": {\"ran\": true,"#))
        XCTAssertTrue(branch.upperBound <= certify.lowerBound && certify.upperBound <= set.lowerBound
                      && set.upperBound <= ranTrue.lowerBound,
                      "cert_ok is set only inside the branch that runs the certificate, from its margin")
        XCTAssertTrue(run.contains("const bool approved_structural = ok_s && cert_ok;"))
        XCTAssertTrue(run.contains("row.certified = cert_ok;"))
        let lat = try flat("core/src/mesh/organic_lattice.cpp")
        XCTAssertTrue(lat.contains("else if (!r.certified) why = \"refused by the certificate\";"))
    }

    /// The copy: "likely to certify", ~20 % conservative, predicted margin, never the
    /// certificate, never one piece; cells_across is advice, not a gate.
    func testTheCopyKeepsTheContractsPromises() {
        let all = [OrganicForecast.structuralMeaning, OrganicForecast.aestheticMeaning,
                   OrganicForecast.notCertified, OrganicForecast.checkSizesHelp]
        for t in all {
            XCTAssertFalse(t.lowercased().contains("contiguous"), t)
            XCTAssertFalse(t.lowercased().contains("single piece"), t)
            XCTAssertFalse(t.lowercased().contains("cells across"), "advisory only, never in the approval copy: \(t)")
        }
        XCTAssertTrue(OrganicForecast.structuralMeaning.hasPrefix("Likely to certify"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("20 % conservative"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("margin shown is predicted"))
        XCTAssertTrue(OrganicForecast.structuralMeaning.contains("certificate is the verdict"))
        // ★ ruling A (2026-09-29): Aesthetic's (i) makes no certificate or stress claim
        XCTAssertEqual(OrganicForecast.aestheticMeaning, "Sizes chosen for the look. Aesthetic runs no strength check.")
        let aes = OrganicForecast.meaning(structural: false)
        for w in ["ertif", "stress bar", "Green", "Amber", "Grey", "margin", "prediction"] {
            XCTAssertFalse(aes.contains(w), "\(w) in: \(aes)")
        }
        XCTAssertTrue(OrganicForecast.meaning(structural: true).hasPrefix(OrganicForecast.structuralMeaning))
        XCTAssertTrue(OrganicForecast.meaning(structural: true).hasSuffix(OrganicForecast.notCertified))
    }

    func testTheAnswerPersistsOnTheSettings() throws {
        var l = LatticeSettings()
        XCTAssertNil(l.organicForecast)
        l.organicForecast = try XCTUnwrap(OrganicForecast.parse(try data(Self.probe)))
        let back = try JSONDecoder().decode(LatticeSettings.self, from: try JSONEncoder().encode(l))
        XCTAssertEqual(back.organicForecast, l.organicForecast)
        let plain = try JSONEncoder().encode(LatticeSettings())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(obj["organicForecast"], "an untouched file carries no key")
    }

    /// The probe job: the re-lattice job plus the two lattice keys, organic only.
    func testTheProbeJobCarriesTheKeysAndRefusesNonOrganic() throws {
        let organic: [String: Any] = [
            "grading": ["algorithm": "organic", "intent": "aesthetic"],
            "lattice": ["topology": "octet", "regions": []],
        ]
        let out = try RelatticeRun.probeJob(try data(organic), cellsMM: [4.5, 0, 3.5],
                                            gradesMM: [[3, 5], [5, 3], [4]])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        let lat = try XCTUnwrap(obj["lattice"] as? [String: Any])
        XCTAssertEqual(lat["organic_probe_cells_mm"] as? [Double], [4.5, 3.5], "non-positive dropped")
        XCTAssertEqual(lat["organic_probe_grades_mm"] as? [[Double]], [[3, 5]], "lo < hi only")
        XCTAssertNil(lat["forecast_only"], "the probe is NOT a forecast")
        XCTAssertEqual(lat["topology"] as? String, "octet", "the rest of the job untouched")
        let octet: [String: Any] = ["grading": ["algorithm": "doubled"], "lattice": ["topology": "octet"]]
        XCTAssertThrowsError(try RelatticeRun.probeJob(try data(octet), cellsMM: [4], gradesMM: []))
        XCTAssertThrowsError(try RelatticeRun.probeJob(try data(organic), cellsMM: [], gradesMM: []),
                             "no candidates")
        XCTAssertEqual(LatticeSettings.organicProbeCellsMM, [3.5, 4.5, 5.5, 6.5])
        XCTAssertEqual(LatticeSettings.organicProbeGradesMM, [[3, 5], [4.5, 5.5]])
    }

    /// The forecast document no longer carries an organic block (old contract).
    func testTheForecastParserIgnoresAnOrganicBlock() throws {
        let f = try XCTUnwrap(LatticeForecast.parse(try data([
            "region_voxels": 10, "would_lattice_voxels": 8, "would_stay_solid_voxels": 2,
            "organic": Self.probe,
        ])))
        XCTAssertEqual(f.wouldLatticeVoxels, 8)
    }
}
