import Foundation

/// ★ THE ORGANIC CELL-SIZE PROBE (final contract 2026-09-05; core built and
/// calibrated). It runs INSIDE a lattice-variant run, right after the base solve:
/// the job carries `lattice.organic_probe_cells_mm` / `organic_probe_grades_mm`
/// (organic only, refused otherwise) and core writes `<out>/organic_probe.json`
/// before emission — read it as soon as it appears, do not wait for the run.
///
/// MEANING (the copy): `approved_structural` = "likely to certify". The prediction
/// is calibrated on two parts and is ~20 % CONSERVATIVE on both — an approved size
/// is very likely to certify; an unapproved size may still. `cells_across` is
/// advisory text only; NEVER gate on it (measured: every candidate on a 12 mm wall
/// was 1.7–3.4 cells across and two certified). The probe is never the certificate:
/// the run's receipt (`grading.organic.structural_*`) is what "certified" means.
public struct OrganicForecast: Equatable, Sendable, Codable {

    /// The contract version this parser understands; any other ⇒ treated as absent.
    public static let supportedProbeVersion = 1

    public struct Region: Equatable, Sendable, Codable {
        public let faceID: Int
        public let regionID: Int
        public let depthMM: Double
        public let cellsAcross: Double
        public let curvesPerFamily: [Int]
        public let components: Int
        public let tracedLengthMM: Double
        public let rootedLengthFraction: Double
        public let approvedStructural: Bool
        public let approvedAesthetic: Bool
        /// Core's words, shown verbatim.
        public let refusals: String
        public let advice: String
    }

    /// The certification prediction for one candidate — or why it did not run.
    public struct Predicted: Equatable, Sendable, Codable {
        public let ran: Bool
        public let verdict: String          // "certified" | "refused" | ""
        public let margin: Double
        public let p99MPa: Double
        public let maxMPa: Double
        public let allowableMPa: Double
        public let segments: Int
        public let seconds: Double
        public let refusal: String          // when refused
        public let reason: String           // when !ran (segment cap hit)
        public var knockdownUsed: Double = 0
        public var knockdownSource: String = ""
        public var maxOverAllowable: Double = 0
        public var maxOverAllowableDistributed: Double = 0
        public var maxExceedsAllowable: Bool = false
        public var certified: Bool { ran && verdict == "certified" }
    }

    /// ★ THE RECOMMENDATION (`organic_recommend` ≠ "off"): the band the WALLS, the
    /// shortest FACE, the BEAD and the VOXEL bound, and core's FIT and AUTO picks.
    public struct Recommendation: Equatable, Sendable, Codable {
        public struct Fit: Equatable, Sendable, Codable {
            public let found: Bool
            public let cellMM: Double
            public let margin: Double
            public let tracedMM: Double
            public let source: String
        }
        public struct Auto: Equatable, Sendable, Codable {
            public let found: Bool
            public let cellMinMM: Double
            public let cellMaxMM: Double
            public let margin: Double
            public let tracedMM: Double
            public let source: String
        }
        public struct Rejected: Equatable, Sendable, Codable {
            public let cellMinMM: Double
            public let cellMaxMM: Double
            public let source: String
            public let reason: String
        }
        public let ran: Bool
        public let mode: String
        public let bandLoMM: Double
        public let bandHiMM: Double
        public let collapsed: Bool
        public let printabilityFloorMM: Double
        public let resolutionFloorMM: Double
        public let memberCeilingMM: Double
        public let extentCeilingMM: Double
        public let lookCellMM: Double
        public let gradeRatio: Double
        public let lookCellsAcross: Double
        public let targetMargin: Double
        public let fit: Fit?
        public let auto: Auto?
        public let rejected: [Rejected]
        /// The smallest cell: the larger of the bead floor and the grid's voxel.
        public var floorMM: Double { Swift.max(printabilityFloorMM, resolutionFloorMM) }
        public var floorIsResolutionBound: Bool { resolutionFloorMM > printabilityFloorMM + 1e-9 }
        /// Which of the four bounds hold the band, for the "no cell fits" copy.
        public var boundsText: String {
            String(format: "bead floor %.2f mm · grid %.2f mm · wall ceiling %.1f mm · face ceiling %.1f mm",
                   printabilityFloorMM, resolutionFloorMM, memberCeilingMM, extentCeilingMM)
        }
        /// ★ A MARGIN EXISTS ONLY UNDER A STRUCTURAL RECOMMENDATION (maintainer,
        /// 2026-09-29). Core runs the probe's certificate only for structural intent or a
        /// structural recommendation (`want_cert`, run_job.cpp); on an aesthetic one it
        /// writes margin 0, and "· 0.00" read as a failing margin when nothing was
        /// certified. Show nothing, never 0.00.
        public var showsMargin: Bool { mode == "structural" }
        /// ★ AND A COLOUR ONLY THERE TOO (maintainer, 2026-09-29, ruling A). A structural
        /// pick is rooted, certified and at or over the target margin, so green is true;
        /// an aesthetic pick is only rooted — no strength check ran — so it gets no colour.
        public var tint: OrganicForecast.Tint? { showsMargin ? .green : nil }
        public func pillText(_ a: Auto) -> String {
            String(format: "Auto %g–%g mm", a.cellMinMM, a.cellMaxMM)
                + (showsMargin ? String(format: " · %.2f", a.margin) : "")
        }
        public func pillText(_ f: Fit) -> String {
            String(format: "Fit %g mm", f.cellMM) + (showsMargin ? String(format: " · %.2f", f.margin) : "")
        }
        public func infoText(_ a: Auto) -> String {
            String(format: "Core's graded pick across the band %.2f–%.2f mm (%@). ", bandLoMM, bandHiMM, a.source)
                + (showsMargin ? String(format: "Predicted margin %.2f. ", a.margin) + OrganicForecast.notCertified : "")
        }
        public func infoText(_ f: Fit) -> String {
            String(format: "Core's one-size pick across the band %.2f–%.2f mm (%@). ", bandLoMM, bandHiMM, f.source)
                + (showsMargin ? String(format: "Predicted margin %.2f. ", f.margin) + OrganicForecast.notCertified : "")
        }
    }

    public struct Candidate: Equatable, Sendable, Codable {
        public let cellMinMM: Double
        public let cellMaxMM: Double
        public let traceSeconds: Double
        public let curves: Int
        public let components: Int
        public let tracedLengthMM: Double
        public let rootedLengthFraction: Double
        public let candidateVoxels: Int
        public let regions: [Region]
        public let predicted: Predicted?
        public let approvedStructural: Bool
        public let approvedAesthetic: Bool

        public var isGrade: Bool { cellMaxMM > cellMinMM + 1e-9 }
        public var gradeMM: [Double] { [cellMinMM, cellMaxMM] }
        public var label: String {
            isGrade ? String(format: "%g–%g mm", cellMinMM, cellMaxMM)
                    : String(format: "%g mm", cellMinMM)
        }
        /// Every region's refusals, deduplicated, in region order.
        public var refusals: [String] {
            var seen = Set<String>(), out: [String] = []
            for r in regions {
                let t = r.refusals.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, seen.insert(t).inserted { out.append(t) }
            }
            return out
        }
        /// What hover / long-press shows: the refusals and the predicted margin.
        public var hoverText: String {
            var lines = refusals
            if let p = predicted {
                if p.ran {
                    lines.append(String(format: "predicted %@ · margin %.2f (p99 %.1f / %.1f MPa)",
                                        p.verdict, p.margin, p.p99MPa, p.allowableMPa))
                    if !p.refusal.isEmpty { lines.append(p.refusal) }
                } else {
                    lines.append("prediction did not run: " + p.reason)
                }
            }
            return lines.joined(separator: "\n")
        }
        /// The predicted margin, shown next to the size when the prediction ran.
        public var marginText: String? {
            guard let p = predicted, p.ran else { return nil }
            return String(format: "%.2f", p.margin)
        }
        /// ★ ruling V3 (2026-09-29): the stress bar was COMPUTED for this candidate.
        public var checked: Bool { predicted?.ran == true }
        /// Why its prediction did not run — core's reason VERBATIM, with one exception:
        /// core writes "N segments exceed the probe's 600000 cap" for a certificate it
        /// SKIPPED (an Aesthetic probe: run_job.cpp's `else if (!psegs.empty())` has no
        /// `want_cert` guard — sent to #358), so where N is within the cap that line
        /// contradicts itself and the true cause is said instead. nil when it ran.
        public func notCheckedReason(probedIntent: String?) -> String? {
            guard !checked else { return nil }
            guard let p = predicted else { return OrganicForecast.noPredictionReason }
            let r = p.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cap = OrganicForecast.segmentCap(in: r), cap.segments <= cap.cap,
               probedIntent != "structural" {
                return OrganicForecast.aestheticNotCheckedReason
            }
            return r.isEmpty ? "no reason given" : r
        }
        /// ★ THE PILL (ruling V3, 2026-09-29): under Structural a candidate whose stress
        /// bar was never computed reads "Not checked" — never the bare "*", which read as
        /// a failed check. Every other pill is exactly as before.
        public func pillText(structural: Bool) -> String {
            if structural && !checked { return label + " · " + OrganicSizeCheck.notCheckedTitle }
            let ok = structural ? approvedStructural : approvedAesthetic
            return label + (ok ? "" : "*") + (marginText.map { " · \($0)" } ?? "")
        }
        /// Hover / long-press: under Structural and not checked, "Not checked: <why>" after
        /// the refusals; otherwise exactly `hoverText`.
        public func hoverText(structural: Bool, probedIntent: String?) -> String {
            guard structural, let why = notCheckedReason(probedIntent: probedIntent) else { return hoverText }
            return (refusals + [OrganicSizeCheck.notCheckedTitle + ": " + why]).joined(separator: "\n")
        }
    }

    /// Structural only: green = likely to certify · amber = ties to the part, the
    /// prediction did not pass · grey = refused. Aesthetic shows no colour at all — its
    /// probe runs no certificate (`want_cert`, run_job.cpp), so no verdict exists to colour
    /// — and neither does a candidate whose prediction did not run (nil `predicted` or
    /// `ran == false`; ruling 3, 2026-09-29).
    public enum Tint: String, Equatable, Sendable {
        case green, amber, grey
    }

    public let probeVersion: Int
    public let algorithm: String
    public let growth: Bool
    public let transferTies: Bool
    public let rootedGate: Double
    public let curvesPerFamilyGate: Int
    public let cellsAcrossAdvisory: Double
    public let candidates: [Candidate]
    public var recommendation: Recommendation? = nil

    public var sizes: [Candidate] { candidates.filter { !$0.isGrade } }
    /// ★ ruling V1 (2026-09-29): how many face walls the job this answer came from left out
    /// (a variant's job carries placed shapes only). Stamped by the app, not core; nil on
    /// an answer stored before it.
    public var faceWallsLeftOut: Int? = nil
    /// The intent the probe ran under: the wizard asks with `organic_recommend: "auto"`,
    /// which core resolves to the job's `grading.intent` (run_job.cpp) and writes as the
    /// recommendation's mode. nil when the file has no recommendation.
    public var probedIntent: String? {
        recommendation.flatMap { $0.ran && !$0.mode.isEmpty ? $0.mode : nil }
    }
    /// Any candidate whose stress bar was computed.
    public var anyChecked: Bool { candidates.contains(where: \.checked) }
    /// …in the list the wizard SHOWS: grades with the simulation on, sizes with it off.
    /// A checked size must not claim "Likely to certify" above grade pills none of which
    /// was checked.
    public func anyChecked(grades: Bool) -> Bool { (grades ? self.grades : sizes).contains(where: \.checked) }
    static let aestheticNotCheckedReason = "checked with the stage on Aesthetic, which runs no strength check"
    static let noPredictionReason = "this check made no strength prediction"
    /// "N segments exceed the probe's CAP cap" → (N, CAP).
    static func segmentCap(in r: String) -> (segments: Int, cap: Int)? {
        let parts = r.components(separatedBy: " segments exceed the probe's ")
        guard parts.count == 2, let n = Int(parts[0]), parts[1].hasSuffix(" cap"),
              let c = Int(parts[1].dropLast(4)) else { return nil }
        return (n, c)
    }
    /// ★ NONE CHECKED (ruling V3, 2026-09-29): under Structural, when not one candidate's
    /// stress bar was computed, one line says so and what would get them checked; each
    /// size's reason sits behind the (i). nil when any was checked, under Aesthetic, or
    /// with no candidates. `checkRefusal` is why Check sizes cannot act here — then that
    /// is said instead of pointing at a button that is not there.
    public struct UncheckedSummary: Equatable, Sendable {
        public let line: String
        public let info: String
    }
    public func uncheckedSummary(structural: Bool, grades: Bool, checkRefusal: String? = nil) -> UncheckedSummary? {
        // the list on screen only (grades with the simulation on, sizes with it off)
        let shown = grades ? self.grades : sizes
        guard structural, !shown.isEmpty, !shown.contains(where: \.checked) else { return nil }
        let why = shown.map { ($0.label, $0.notCheckedReason(probedIntent: probedIntent) ?? "") }
        let action: String
        if let refusal = checkRefusal, !refusal.isEmpty {
            action = refusal
        } else if probedIntent == "aesthetic"
                    || why.allSatisfy({ $0.1 == Self.aestheticNotCheckedReason || $0.1.hasPrefix("aesthetic intent") }) {
            action = "Tap Check sizes here, on Structural, to check them."
        } else if shown.allSatisfy({ c in
            OrganicForecast.segmentCap(in: c.predicted?.reason ?? "").map { $0.segments > $0.cap } ?? false }) {
            action = "Larger sizes have fewer struts: enter a larger size, then tap Check sizes."
        } else if why.allSatisfy({ $0.1 == "no segments" }) {
            action = "Nothing was traced at these sizes: mark a wall to lattice, then tap Check sizes."
        } else if why.allSatisfy({ $0.1 == Self.noPredictionReason }) {
            action = "This worker makes no strength prediction: update it, then tap Check sizes."
        } else {
            action = "Tap Check sizes to check them again."
        }
        return UncheckedSummary(
            line: "No size was checked for strength. " + action,
            info: "Why each size was not checked:\n" + why.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
    }
    public var grades: [Candidate] { candidates.filter { $0.isGrade } }

    // MARK: - parse

    /// The root of `organic_probe.json`. nil when absent, malformed, or of a
    /// version this build does not understand — each means "show the octet
    /// forecast alone, no organic approvals".
    public static func parse(_ data: Data) -> OrganicForecast? {
        parse((try? JSONSerialization.jsonObject(with: data)) as Any?)
    }

    public static func parse(_ any: Any?) -> OrganicForecast? {
        guard let o = any as? [String: Any],
              let version = o["organic_probe_version"] as? Int,
              version == supportedProbeVersion,
              let raw = o["candidates"] as? [[String: Any]] else { return nil }
        func d(_ x: Any?) -> Double { (x as? Double) ?? (x as? Int).map(Double.init) ?? 0 }
        func i(_ x: Any?) -> Int { (x as? Int) ?? (x as? Double).map(Int.init) ?? 0 }
        let candidates: [Candidate] = raw.compactMap { c in
            guard let lo = c["cell_min_mm"] ?? c["cell_mm"],
                  let structural = c["approved_structural"] as? Bool,
                  let aesthetic = c["approved_aesthetic"] as? Bool else { return nil }
            let cellMin = d(lo), cellMax = d(c["cell_max_mm"] ?? lo)
            guard cellMin > 0, cellMax >= cellMin else { return nil }
            let regions: [Region] = (c["regions"] as? [[String: Any]] ?? []).compactMap { r in
                guard let rs = r["approved_structural"] as? Bool,
                      let ra = r["approved_aesthetic"] as? Bool else { return nil }
                return Region(faceID: i(r["face_id"]), regionID: i(r["region_id"]),
                              depthMM: d(r["depth_mm"]), cellsAcross: d(r["cells_across"]),
                              curvesPerFamily: (r["curves_per_family"] as? [Any] ?? []).map(i),
                              components: i(r["components"]),
                              tracedLengthMM: d(r["traced_length_mm"]),
                              rootedLengthFraction: d(r["rooted_length_fraction"]),
                              approvedStructural: rs, approvedAesthetic: ra,
                              refusals: r["refusals"] as? String
                                  ?? (r["refusals"] as? [String])?.joined(separator: "; ") ?? "",
                              advice: r["advice"] as? String ?? "")
            }
            let predicted: Predicted? = (c["predicted"] as? [String: Any]).map { p in
                var pr = Predicted(ran: p["ran"] as? Bool ?? false,
                          verdict: p["verdict"] as? String ?? "",
                          margin: d(p["margin"]), p99MPa: d(p["p99_mpa"]), maxMPa: d(p["max_mpa"]),
                          allowableMPa: d(p["allowable_mpa"]), segments: i(p["segments"]),
                          seconds: d(p["seconds"]), refusal: p["refusal"] as? String ?? "",
                          reason: p["reason"] as? String ?? "")
                pr.knockdownUsed = d(p["knockdown_used"])
                pr.knockdownSource = p["knockdown_source"] as? String ?? ""
                pr.maxOverAllowable = d(p["max_over_allowable"])
                pr.maxOverAllowableDistributed = d(p["max_over_allowable_distributed"])
                pr.maxExceedsAllowable = p["max_exceeds_allowable"] as? Bool ?? false
                return pr
            }
            return Candidate(cellMinMM: cellMin, cellMaxMM: cellMax,
                             traceSeconds: d(c["trace_seconds"]), curves: i(c["curves"]),
                             components: i(c["components"]), tracedLengthMM: d(c["traced_length_mm"]),
                             rootedLengthFraction: d(c["rooted_length_fraction"]),
                             candidateVoxels: i(c["candidate_voxels"]), regions: regions,
                             predicted: predicted,
                             approvedStructural: structural, approvedAesthetic: aesthetic)
        }
        var out = OrganicForecast(probeVersion: version,
                                  algorithm: o["algorithm"] as? String ?? "organic",
                                  growth: o["growth"] as? Bool ?? false,
                                  transferTies: o["transfer_ties"] as? Bool ?? false,
                                  rootedGate: d(o["rooted_gate"]),
                                  curvesPerFamilyGate: i(o["curves_per_family_gate"]),
                                  cellsAcrossAdvisory: d(o["cells_across_advisory"]),
                                  candidates: candidates)
        if let r = o["recommendation"] as? [String: Any] {
            let fit: Recommendation.Fit? = (r["fit"] as? [String: Any]).map { f in
                Recommendation.Fit(found: f["found"] as? Bool ?? false, cellMM: d(f["cell_mm"]),
                                   margin: d(f["margin"]), tracedMM: d(f["traced_mm"]),
                                   source: f["source"] as? String ?? "")
            }
            let auto: Recommendation.Auto? = (r["auto"] as? [String: Any]).map { a in
                Recommendation.Auto(found: a["found"] as? Bool ?? false,
                                    cellMinMM: d(a["cell_min_mm"]), cellMaxMM: d(a["cell_max_mm"]),
                                    margin: d(a["margin"]), tracedMM: d(a["traced_mm"]),
                                    source: a["source"] as? String ?? "")
            }
            let rejected: [Recommendation.Rejected] = (r["rejected"] as? [[String: Any]] ?? []).map { x in
                Recommendation.Rejected(cellMinMM: d(x["cell_min_mm"]), cellMaxMM: d(x["cell_max_mm"]),
                                        source: x["source"] as? String ?? "",
                                        reason: x["reason"] as? String ?? "")
            }
            out.recommendation = Recommendation(
                ran: r["ran"] as? Bool ?? false, mode: r["mode"] as? String ?? "",
                bandLoMM: d(r["band_lo_mm"]), bandHiMM: d(r["band_hi_mm"]),
                collapsed: r["collapsed"] as? Bool ?? false,
                printabilityFloorMM: d(r["printability_floor_mm"]),
                resolutionFloorMM: d(r["resolution_floor_mm"]),
                memberCeilingMM: d(r["member_ceiling_mm"]), extentCeilingMM: d(r["extent_ceiling_mm"]),
                lookCellMM: d(r["look_cell_mm"]), gradeRatio: d(r["grade_ratio"]),
                lookCellsAcross: d(r["look_cells_across"]), targetMargin: d(r["target_margin"]),
                fit: fit, auto: auto, rejected: rejected)
        }
        return out
    }

    // MARK: - the menu's law (pure, tested)

    /// The colour a verdict maps to — not the display law (pills read
    /// `tint(_:structural:)`); kept as the tests' control.
    public static func tint(_ c: Candidate) -> Tint {
        c.approvedStructural ? .green : (c.approvedAesthetic ? .amber : .grey)
    }
    /// ★ NO COLOUR VERDICT UNDER AESTHETIC (maintainer, 2026-09-29, ruling A: "no green,
    /// no amber"), AND NONE WHERE THE PREDICTION DID NOT RUN (ruling 3: "No computed
    /// verdict means no colour: not amber, not grey"). Core writes `ran: false` for no
    /// segments, for aesthetic intent and at the 600000-segment cap (run_job.cpp), and
    /// `approved_structural` is then false because nothing ran (`cert_ok` is set only
    /// where the certificate ran) — amber or grey there read that false as a failure.
    /// Green cannot lose its dot: it needs `cert_ok`. The refusal a grey dot showed is
    /// still on the pill (its "*", or "Not checked" — ruling V3 — and the hover text).
    public static func tint(_ c: Candidate, structural: Bool) -> Tint? {
        guard structural, c.predicted?.ran == true else { return nil }
        return tint(c)
    }

    /// Structural offers only green — a CHECKED, approved candidate (every Structural
    /// option confirmed sound, 2026-09-03); Aesthetic offers every candidate.
    public static func selectable(_ c: Candidate, structural: Bool) -> Bool {
        structural ? (c.approvedStructural && c.checked) : true
    }

    /// What "approved" means here — never "certified".
    public static let structuralMeaning =
        "Likely to certify: a size predicted to tie to the part (≥ 95 % of its length "
        + "rooted, every family twice across) whose predicted certification passed. The "
        + "prediction runs about 20 % conservative — an approved size is very likely to "
        + "certify; an unapproved one may still. It will not be refused for disconnection. "
        + "The margin shown is predicted; the run's certificate is the verdict."
    public static let aestheticMeaning =
        "Sizes chosen for the look. Aesthetic runs no strength check."
    public static let notCertified =
        "This is a prediction made during the run, not the certificate. Only the run's "
        + "certificate says a size certified."
    /// The (i) beside the probe's sizes: the structural legend with its "not the
    /// certificate" caveat; under Aesthetic only the plain statement — no certificate
    /// claim of any kind, since none was computed.
    public static func meaning(structural: Bool) -> String {
        structural ? structuralMeaning + " " + notCertified : aestheticMeaning
    }
    public static let checkSizesTitle = "Check sizes"
    public static let checkSizesHelp =
        "Starts the run with the candidate sizes, reads the size check as soon as it is "
        + "written (about a minute for the solve plus 30 seconds per size), then stops the run."
}
