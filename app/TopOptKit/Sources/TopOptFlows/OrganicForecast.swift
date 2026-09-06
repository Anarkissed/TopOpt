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
        public var certified: Bool { ran && verdict == "certified" }
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
    }

    /// green = likely to certify · amber = ties (aesthetic) only · grey = refused
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

    public var sizes: [Candidate] { candidates.filter { !$0.isGrade } }
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
                Predicted(ran: p["ran"] as? Bool ?? false,
                          verdict: p["verdict"] as? String ?? "",
                          margin: d(p["margin"]), p99MPa: d(p["p99_mpa"]), maxMPa: d(p["max_mpa"]),
                          allowableMPa: d(p["allowable_mpa"]), segments: i(p["segments"]),
                          seconds: d(p["seconds"]), refusal: p["refusal"] as? String ?? "",
                          reason: p["reason"] as? String ?? "")
            }
            return Candidate(cellMinMM: cellMin, cellMaxMM: cellMax,
                             traceSeconds: d(c["trace_seconds"]), curves: i(c["curves"]),
                             components: i(c["components"]), tracedLengthMM: d(c["traced_length_mm"]),
                             rootedLengthFraction: d(c["rooted_length_fraction"]),
                             candidateVoxels: i(c["candidate_voxels"]), regions: regions,
                             predicted: predicted,
                             approvedStructural: structural, approvedAesthetic: aesthetic)
        }
        return OrganicForecast(probeVersion: version,
                               algorithm: o["algorithm"] as? String ?? "organic",
                               growth: o["growth"] as? Bool ?? false,
                               transferTies: o["transfer_ties"] as? Bool ?? false,
                               rootedGate: d(o["rooted_gate"]),
                               curvesPerFamilyGate: i(o["curves_per_family_gate"]),
                               cellsAcrossAdvisory: d(o["cells_across_advisory"]),
                               candidates: candidates)
    }

    // MARK: - the menu's law (pure, tested)

    public static func tint(_ c: Candidate) -> Tint {
        c.approvedStructural ? .green : (c.approvedAesthetic ? .amber : .grey)
    }

    /// Structural offers only green; Aesthetic offers every candidate.
    public static func selectable(_ c: Candidate, structural: Bool) -> Bool {
        structural ? c.approvedStructural : true
    }

    /// What "approved" means here — never "certified".
    public static let structuralMeaning =
        "Likely to certify: a size predicted to tie to the part (≥ 95 % of its length "
        + "rooted, every family twice across) whose predicted certification passed. The "
        + "prediction runs about 20 % conservative — an approved size is very likely to "
        + "certify; an unapproved one may still. It will not be refused for disconnection. "
        + "The margin shown is predicted; the run's certificate is the verdict."
    public static let aestheticMeaning =
        "Green: likely to certify. Amber: predicted to tie to the part but not to pass the "
        + "stress bar. Grey: refused. Every size may be chosen under Aesthetic."
    public static let notCertified =
        "This is a prediction made during the run, not the certificate. Only the run's "
        + "certificate says a size certified."
    public static let checkSizesTitle = "Check sizes"
    public static let checkSizesHelp =
        "Starts the run with the candidate sizes, reads the size check as soon as it is "
        + "written (about a minute for the solve plus 30 seconds per size), then stops the run."
}
