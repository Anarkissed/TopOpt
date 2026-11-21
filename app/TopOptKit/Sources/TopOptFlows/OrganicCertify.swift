// OrganicCertify — ★ ORGANIC CUT 2, his certify wizard (his design 11-19, memory organic-cut2-certify-wizard): when an Organic
// part does not certify, the Results screen walks him through it, ONE pop-up per issue:
//   * each pop-up's line goes straight to the affected area and stays on it however he turns the part; the area is coloured
//     and OUTLINED ("If the outline is in view, it is visible, if it is covered it is behind something or around the other
//     side"); a hidden area: the line simply points behind;
//   * buttons Next (needs a part change), Skip, Solve (straight to what fixes it);
//   * ORDER: "In app changes like lattice settings should be done first, then infill, then model change recommendations";
//   * GROUPING: "Group spots that have the same issue. It's One pop-up per solution/issue";
//   * INFILL is changed ONLY here, by Solve: the lowest passing infill, said with the print settings, made as a new version
//     (the version that ran keeps its own), and the card says so;
//   * RE-CHECK: "It should ask the user. And should be in the space of where 'Lattice' is after all the issues have gone
//     through."
// This file is the wizard's MODEL: the issues, in his order, from the strength check's block (core's run_job.cpp, OS15: the
// weak spots with `id`, `issue`, `advice`; `fields.bin` block 3 holds each voxel's spot id for the colour and the outline)
// and the strengthening's summary. The views draw it.
import Foundation
import simd

public enum OrganicCertify {
    /// His order: lattice settings, then infill, then the model.
    public enum Stage: Int, Comparable, Sendable {
        case lattice = 0, infill = 1, model = 2
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// What Solve does (nil: no in-app fix — Next, a change to the part).
    public enum Solve: Equatable, Sendable {
        /// Protect the loaded face (a load on open lattice).
        case protectLoadedFace
        /// The Organic strut thickness (the struts still short after strengthening).
        case strutThickness
        /// A deeper protected skin or a keep-clear area here (a weak spot beside the lattice).
        case keepLatticeAway
        /// The lowest infill that passes, made as a new version.
        case infill(percent: Int)
    }

    /// One pop-up: one issue, its spots grouped.
    public struct Issue: Equatable, Sendable, Identifiable {
        public var id: String
        public var stage: Stage
        public var title: String
        public var text: String
        /// The weak spots it covers (their ids in fields.bin's block 3: coloured and outlined together).
        public var spotIDs: [Int]
        /// Where its line goes (model mm): the worst spot's worst point, or the weakest strut's; nil: the card stands alone.
        public var at: SIMD3<Double>?
        public var solve: Solve?
        /// The worst margin among its spots (to order within a stage).
        public var worst: Double
    }

    /// One weak spot of the solid, as the check lists it.
    public struct Spot: Equatable, Sendable {
        public var id: Int
        public var issue: String
        public var advice: String
        public var worstAt: SIMD3<Double>
        public var effectiveMargin: Double
        public var passesAtInfill: Int?
    }

    static func v3(_ v: Any?) -> SIMD3<Double>? {
        guard let a = v as? [NSNumber], a.count == 3 else { return nil }
        return SIMD3(a[0].doubleValue, a[1].doubleValue, a[2].doubleValue)
    }
    static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    public static func spots(_ strength: [String: Any]) -> [Spot] {
        let solid = strength["solid_margin"] as? [String: Any] ?? [:]
        return (solid["spots"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = (s["id"] as? NSNumber)?.intValue, let at = v3(s["worst_at"]) else { return nil }
            return Spot(id: id, issue: s["issue"] as? String ?? s["kind"] as? String ?? "inside_the_solid",
                        advice: s["advice"] as? String ?? "", worstAt: at, effectiveMargin: num(s["effective_margin"]) ?? 0,
                        passesAtInfill: (s["passes_at_infill_percent"] as? NSNumber)?.intValue)
        }
    }

    /// The pop-ups for a result, in his order (lattice, infill, model; the worst first within each), one per issue. Empty: it
    /// certifies (or was not checked). `report` is lattice_file.json as the app holds it (core's `strength` block, and the
    /// app's `organic_strengthen`); `infillNow` the print settings' infill.
    public static func issues(report: [String: Any], infillNow: Int) -> [Issue] {
        guard let s = report["strength"] as? [String: Any] else { return [] }
        let verdict = s["verdict"] as? String ?? ((s["accepted"] as? Bool ?? true) ? "pass" : "fail")
        guard verdict != "pass" else { return [] }
        let reason = s["fail_reason"] as? String
        let safety = num(s["safety_margin"]) ?? 1.5
        var out: [Issue] = []

        // ── lattice settings ──
        if reason == "load_on_open_lattice" {
            out.append(Issue(id: "load_on_open_lattice", stage: .lattice, title: "The load lands on open lattice",
                             text: "Nothing carries it to the fixings. Protect the loaded face to keep it solid, then check again.",
                             spotIDs: [], at: nil, solve: .protectLoadedFace, worst: 0))
        }
        let struts = s["struts"] as? [String: Any] ?? [:]
        let under = (struts["under_safety"] as? NSNumber)?.intValue ?? 0
        if under > 0 {
            let weakest = (s["weakest"] as? [[String: Any]] ?? []).compactMap { w -> (SIMD3<Double>, Double)? in
                guard let at = v3(w["at"]) else { return nil }
                return (at, num(w["margin"]) ?? 0)
            }.min { $0.1 < $1.1 }
            let smallest = num(struts["smallest_margin"]) ?? weakest?.1 ?? 0
            let sum = report[LatticeFileButton.strengthenKey] as? [String: Any]
            let rounds = (sum?["rounds"] as? [Any])?.count
            let after = rounds.map { " after \($0 == 1 ? "1 round" : "\($0) rounds") of strengthening" } ?? ""
            out.append(Issue(id: "struts_short", stage: .lattice,
                             title: under == 1 ? "1 strut is still short" : "\(under) struts are still short",
                             text: String(format: "The weakest holds %.2f× your load%@; it needs %.1f×. Thicker struts fix it: "
                                          + "raise the strut thickness, or let strengthening go further past it.",
                                          smallest, after, safety),
                             spotIDs: [], at: weakest?.0, solve: .strutThickness, worst: smallest))
        }
        let spots = Self.spots(s)
        let byIssue = Dictionary(grouping: spots, by: \.issue)
        if let near = byIssue["beside_the_lattice"], let w = near.min(by: { $0.effectiveMargin < $1.effectiveMargin }) {
            out.append(Issue(id: "beside_the_lattice", stage: .lattice, title: plural(near.count, "weak area beside the lattice"),
                             text: w.advice, spotIDs: near.map(\.id), at: w.worstAt, solve: .keepLatticeAway, worst: w.effectiveMargin))
        }

        // ── infill: the ONLY place it changes (his words: "the 81% infill is one solution, but ... the other is to
        // strengthen up these pointed to areas") ──
        let solid = s["solid_margin"] as? [String: Any] ?? [:]
        if reason == "solid_margin", let pass = (solid["passes_at_infill_percent"] as? NSNumber)?.intValue, pass > infillNow,
           pass <= 100 {
            let worst = spots.min(by: { $0.effectiveMargin < $1.effectiveMargin })
            let text = (solid["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "The solid part does not certify at \(infillNow)% infill. \(pass)% infill is one solution; the other is to "
                   + "strengthen the areas pointed to."
            out.append(Issue(id: "infill", stage: .infill, title: "Print it at \(pass)% infill",
                             text: text, spotIDs: spots.map(\.id), at: worst?.worstAt, solve: .infill(percent: pass),
                             worst: worst?.effectiveMargin ?? (num(solid["effective"]) ?? 0)))
        }

        // ── the model ──
        for (key, title) in [("beside_a_fixing", "weak area beside a fixing"), ("beside_the_load", "weak area where the load presses"),
                             ("inside_the_solid", "weak area inside the solid")] {
            guard let group = byIssue[key], let w = group.min(by: { $0.effectiveMargin < $1.effectiveMargin }) else { continue }
            out.append(Issue(id: key, stage: .model, title: plural(group.count, title), text: w.advice, spotIDs: group.map(\.id),
                             at: w.worstAt, solve: nil, worst: w.effectiveMargin))
        }
        // ── a fail none of the above covers (nothing carries the load; the check's own words): one pop-up says why ──
        if out.isEmpty, verdict == "fail" {
            let f = LatticeFileStrength(block: s)
            out.append(Issue(id: "not_certified", stage: .model, title: "It does not certify",
                             text: f.noPathLine ?? (f.notCertified ? LatticeFileStrength.notCertifiedLine(f.notCertifiedReason) : f.line),
                             spotIDs: [], at: nil, solve: nil, worst: 0))
        }
        return out.enumerated().sorted { a, b in
            a.element.stage != b.element.stage ? a.element.stage < b.element.stage : a.offset < b.offset
        }.map(\.element)
    }

    static func plural(_ n: Int, _ what: String) -> String { n == 1 ? "1 \(what)" : "\(n) \(what.replacingOccurrences(of: "area", with: "areas"))" }

    /// The infill card's own lines (his: "with a notification and the print parameters shown"; the version made says so).
    /// `newVersion`/`ranVersion`: the versions' labels ("v4"), nil outside the Library.
    public static func infillLines(from: Int, to: Int, layerMM: Double, walls: Int, newVersion: String?, ranVersion: String?) -> [String] {
        var out = ["Infill \(from)% → \(to)%", String(format: "Layers %.2g mm · %d walls", layerMM, walls)]
        if let n = newVersion {
            out.append("Made as \(n)" + (ranVersion.map { " · \($0) keeps \(from)%" } ?? ""))
        }
        return out
    }

    /// His re-check question, asked where Lattice is once every pop-up has gone through.
    public static let recheckLine = "Check it again with the changes?"
    public static let recheckYes = "Check again"
    public static let recheckNo = "Not now"

    /// The pop-up's own label for its stage (his order, said on the card).
    public static func stageLabel(_ s: Stage) -> String {
        switch s {
        case .lattice: return "Lattice settings"
        case .infill: return "Infill"
        case .model: return "Change the part"
        }
    }

    /// ★ The wizard's walk through one result's pop-ups. The workspace keeps it: Solve leaves Results for the page that fixes
    /// it, and coming back the next pop-up is up. Once every pop-up has gone through, the re-check question takes the Lattice
    /// button's place until he answers it.
    public struct Walk: Equatable, Sendable {
        /// The version whose result it walks, and that result (its report's hash: a new run starts a new walk).
        public let version: UUID
        public let key: Int
        public let issues: [Issue]
        public let grid: OrganicSpotGrid?
        public var index = 0
        /// The issues he solved in the app (their ids).
        public var solved: [String] = []
        /// The infill Solve's lines once it is done (the card then says what changed, and Next goes on).
        public var infillLines: [String]? = nil
        public var answered = false

        public init(version: UUID, key: Int, issues: [Issue], grid: OrganicSpotGrid?) {
            self.version = version; self.key = key; self.issues = issues; self.grid = grid
        }

        public var current: Issue? { issues.indices.contains(index) ? issues[index] : nil }
        public var done: Bool { index >= issues.count }
        public var step: String { "\(Swift.min(index + 1, issues.count)) of \(issues.count)" }
        /// Whether the open pop-up was solved and now only says what changed (the infill's).
        public var currentSolved: Bool { current.map { solved.contains($0.id) } ?? false }
        /// The re-check question is up (where Lattice is) on this version.
        public func asksRecheck(on id: UUID) -> Bool { version == id && done && !answered }

        public mutating func skip() { index += 1 }
        public mutating func next() { index += 1 }
        public mutating func markSolved() {
            if let c = current, !solved.contains(c.id) { solved.append(c.id) }
        }
    }

    /// Whether a landed Lattice run opens on Results by itself: an Organic part that does not certify (its walk starts there).
    public static func opensResults(organic: Bool, reportJSON: Data?) -> Bool {
        organic && walk(version: UUID(), reportJSON: reportJSON, infillNow: 100) != nil
    }

    /// The walk for a result, or nil when it certifies (no pop-ups).
    public static func walk(version: UUID, reportJSON: Data?, infillNow: Int) -> Walk? {
        guard let d = reportJSON, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let list = issues(report: o, infillNow: infillNow)
        guard !list.isEmpty else { return nil }
        return Walk(version: version, key: d.hashValue, issues: list, grid: OrganicSpotGrid(json: o[OrganicSpotGrid.reportKey]))
    }
}
