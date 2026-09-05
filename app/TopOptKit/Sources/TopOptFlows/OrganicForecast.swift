import Foundation

/// ★ CELL-SIZE APPROVAL FOR ORGANIC (contract 2026-09-05, core half designed, not
/// built). `lattice_forecast.json` MAY gain an `"organic"` block: per candidate
/// cell size (or grade), per include region, what TRACING ALONE predicts — no
/// emission, no support pass, no FEA. The UI is coded against the contract and
/// gated on the block being present; absent ⇒ today's octet forecast alone, no
/// organic approvals, no guessing.
///
/// THE CRITERION, verbatim from the contract (this is the copy):
///   rooted_length_fraction ≥ 0.95   (length in components that touch part solid)
///   curves_per_family      ≥ 2
///   cells_across           ≥ 4      (structural only)
/// Structural: all three, every include region. Aesthetic: the first two, rooted
/// advisory. "Approved" NEVER means one contiguous piece (a grown lattice is many
/// rooted pillars by design) and NEVER means the stress bar — the probe predicts
/// TIES, not margin. Until core calibrates it, structural approval is "likely to
/// certify", never "certified".
public struct OrganicForecast: Equatable, Sendable, Codable {

    /// The contract version this parser understands. Any other ⇒ the block is
    /// treated as absent (version-gated, per the contract).
    public static let supportedProbeVersion = 1

    public struct Region: Equatable, Sendable, Codable {
        public let faceID: Int
        public let regionID: Int
        public let cellsAcross: Double
        public let curvesPerFamily: [Int]
        public let rootedLengthFraction: Double
        public let tracedLengthMM: Double
        public let deadFraction: Double
        public let approvedStructural: Bool
        public let approvedAesthetic: Bool
        /// Written to be read; shown verbatim.
        public let refusals: [String]
    }

    public struct Candidate: Equatable, Sendable, Codable {
        /// One of the two is set: a single separation, or a grade [min, max].
        public let cellMM: Double?
        public let gradeMM: [Double]?
        public let traceSeconds: Double
        public let regions: [Region]
        public let approvedStructural: Bool
        public let approvedAesthetic: Bool

        public var isGrade: Bool { gradeMM != nil }
        /// Every region's refusals, deduplicated, in region order.
        public var refusals: [String] {
            var seen = Set<String>(), out: [String] = []
            for r in regions { for s in r.refusals where seen.insert(s).inserted { out.append(s) } }
            return out
        }
        public var label: String {
            if let g = gradeMM, g.count == 2 { return String(format: "%g–%g mm", g[0], g[1]) }
            return String(format: "%g mm", cellMM ?? 0)
        }
    }

    public let probeVersion: Int
    public let algorithm: String
    public let growth: Bool
    public let candidates: [Candidate]

    public var sizes: [Candidate] { candidates.filter { $0.cellMM != nil && !$0.isGrade } }
    public var grades: [Candidate] { candidates.filter { $0.isGrade } }

    // MARK: - parse

    /// nil when the block is absent, malformed, or of a version this build does
    /// not understand — every one of those means "show the octet forecast alone".
    public static func parse(_ any: Any?) -> OrganicForecast? {
        guard let o = any as? [String: Any],
              let version = o["organic_probe_version"] as? Int,
              version == supportedProbeVersion,
              let raw = o["candidates"] as? [[String: Any]] else { return nil }
        let candidates: [Candidate] = raw.compactMap { c in
            let cell = c["cell_mm"] as? Double
            let grade = (c["grade_mm"] as? [Double]).flatMap { $0.count == 2 ? $0 : nil }
            guard cell != nil || grade != nil,
                  let structural = c["approved_structural"] as? Bool,
                  let aesthetic = c["approved_aesthetic"] as? Bool else { return nil }
            let regions: [Region] = (c["regions"] as? [[String: Any]] ?? []).compactMap { r in
                guard let rs = r["approved_structural"] as? Bool,
                      let ra = r["approved_aesthetic"] as? Bool else { return nil }
                return Region(faceID: r["face_id"] as? Int ?? -1,
                              regionID: r["region_id"] as? Int ?? -1,
                              cellsAcross: r["cells_across"] as? Double ?? 0,
                              curvesPerFamily: r["curves_per_family"] as? [Int] ?? [],
                              rootedLengthFraction: r["rooted_length_fraction"] as? Double ?? 0,
                              tracedLengthMM: r["traced_length_mm"] as? Double ?? 0,
                              deadFraction: r["dead_fraction"] as? Double ?? 0,
                              approvedStructural: rs, approvedAesthetic: ra,
                              refusals: r["refusals"] as? [String] ?? [])
            }
            return Candidate(cellMM: grade == nil ? cell : nil, gradeMM: grade,
                             traceSeconds: c["trace_seconds"] as? Double ?? 0,
                             regions: regions,
                             approvedStructural: structural, approvedAesthetic: aesthetic)
        }
        return OrganicForecast(probeVersion: version,
                               algorithm: o["algorithm"] as? String ?? "organic",
                               growth: o["growth"] as? Bool ?? false,
                               candidates: candidates)
    }

    // MARK: - the menu's law (pure, tested)

    /// Whether a candidate may be SELECTED: Structural offers only the
    /// structurally approved; Aesthetic offers every candidate.
    public static func selectable(_ c: Candidate, structural: Bool) -> Bool {
        structural ? c.approvedStructural : true
    }

    /// Whether a candidate wears the "not approved" badge for the stage.
    public static func badged(_ c: Candidate, structural: Bool) -> Bool {
        structural ? !c.approvedStructural : !c.approvedAesthetic
    }

    /// What "approved" means here — the contract's own words, never "certified".
    public static let structuralMeaning =
        "Likely to certify: at this size the lattice is predicted to tie to the part "
        + "(≥ 95 % of its length rooted, every family twice across, ≥ 4 cells across). "
        + "It will not be refused for disconnection. Stress margin needs the run."
    public static let aestheticMeaning =
        "Predicted to trace with every family twice across the member; rooting is "
        + "advisory under Aesthetic. Sizes marked * did not meet that bar."
    public static let notCertified =
        "A prediction from tracing alone — no emission, no support pass, no solve. "
        + "The certificate after the run is the verdict."
}
