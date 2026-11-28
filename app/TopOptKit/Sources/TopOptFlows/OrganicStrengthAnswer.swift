// OrganicStrengthAnswer.swift — ★ A1 (the Organic strength check, spec build-c2.md "SPEC FOR 362, CORRECTED" and the C7-C12
// additions). At print-accurate / export the Organic file job writes a top-level `strength_answer` into lattice_file.json:
// {by, accepted, verdict: pass | fail | not_proven | not_checked, reason, pass_line, pass_allowance}, with the details in
// `strength.break` and the C9 `posts_step` block. THAT is the file's answer; the old rod-check numbers (struts.*, weakest[],
// strength.accepted / strength.verdict) are no longer shown as the answer for such a file.
//
// Every key is read as optional (a number that is not finite arrives as JSON null), and every unknown word decodes and shows a
// generic line. No new notice, pop-up or alert: these words go into the lines Results already has.

import Foundation
import simd

public struct OrganicStrengthAnswer: Equatable, Sendable {
    /// "break" (the break check); a file with `by` "rod" is not decoded here.
    public var by: String
    public var accepted: Bool
    /// "pass", "fail", "not_proven", "not_checked" (any other word is kept as sent).
    public var verdict: String
    /// The not-checked reason (too_big, did_not_settle, no_load, load_on_empty_space, stopped, error, bearing_anchors), or "".
    public var reason: String
    public var passLine: Double?
    public var passAllowance: Double?
    /// `strength.break.not_proven_because`.
    public var notProvenBecause: [String]
    /// The first break of the printed shape: its multiple of the load and where (mm, the part's frame); nil when core sent null.
    public var firstBreakMultiple: Double?
    public var firstBreakAt: SIMD3<Double>?
    /// Thin regions that carry the load (`load_path.regions_by_load`), largest first.
    public var thinRegions: [ThinRegion]
    /// A named post's place (`load_path.posts[]` with `blocks`), mm.
    public var postPlaces: [SIMD3<Double>]
    /// C9: the posts the step strengthened (nil: no step ran), and core's words for each post still short (for the (i)).
    public var postsStrengthened: Int?
    public var stillShort: [String]

    public struct ThinRegion: Equatable, Sendable {
        public var kind: String
        public var at: SIMD3<Double>?
    }

    public enum Kind: Equatable, Sendable { case pass, fail, notProven, notChecked, other }
    public var kind: Kind {
        switch verdict {
        case "pass": return .pass
        case "fail": return .fail
        case "not_proven": return .notProven
        case "not_checked": return .notChecked
        default: return .other
        }
    }

    /// The file's answer from lattice_file.json, or nil for a file with no `strength_answer` made by the break check.
    public static func decode(report r: [String: Any]) -> OrganicStrengthAnswer? {
        guard let a = r["strength_answer"] as? [String: Any], (a["by"] as? String ?? "break") == "break" else { return nil }
        func n(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil } }
        func p(_ v: Any?) -> SIMD3<Double>? {
            guard let x = v as? [Any], x.count == 3 else { return nil }
            let d = x.compactMap { n($0) }
            return d.count == 3 ? SIMD3(d[0], d[1], d[2]) : nil
        }
        let brk = (r["strength"] as? [String: Any])?["break"] as? [String: Any] ?? [:]
        let fb = brk["first_break"] as? [String: Any]
        let lp = brk["load_path"] as? [String: Any] ?? [:]
        let regions = (lp["regions_by_load"] as? [[String: Any]] ?? []).map { ThinRegion(kind: $0["kind"] as? String ?? "", at: p($0["at"])) }
        let posts = (lp["posts"] as? [[String: Any]] ?? []).filter { $0["blocks"] as? Bool == true }
        let step = r["posts_step"] as? [String: Any]
        let changed = step.map { s in
            (s["by_round"] as? [[String: Any]] ?? []).flatMap { $0["posts"] as? [[String: Any]] ?? [] }
                .filter { $0["changed"] as? Bool == true }.count
        }
        return OrganicStrengthAnswer(
            by: "break", accepted: a["accepted"] as? Bool ?? false, verdict: a["verdict"] as? String ?? "not_checked",
            reason: a["reason"] as? String ?? "", passLine: n(a["pass_line"]) ?? n(brk["pass_line"]),
            passAllowance: n(a["pass_allowance"]) ?? n(brk["pass_allowance"]),
            notProvenBecause: brk["not_proven_because"] as? [String] ?? [], firstBreakMultiple: n(fb?["multiple"]),
            firstBreakAt: p(fb?["at"]), thinRegions: regions, postPlaces: posts.compactMap { p($0["at"]) },
            postsStrengthened: changed, stillShort: (step?["still_short"] as? [[String: Any]] ?? []).compactMap { $0["why"] as? String })
    }

    // MARK: the words (each caption at most five words; positive words)

    /// The one headline.
    public var title: String {
        switch kind {
        case .pass: return "Strong enough"
        case .fail: return "Not strong enough"
        case .notProven: return "Strength not proven"
        case .notChecked, .other: return "Strength not checked"
        }
    }

    /// Why a check was not made, in a few words.
    public static func reasonWords(_ r: String) -> String {
        switch r {
        case "too_big": return "Part too big to check"
        case "did_not_settle": return "Check did not settle"
        case "no_load": return "No load to check"
        case "load_on_empty_space": return "Load sits on empty space"
        case "stopped": return "Check was stopped"
        case "error": return "Check hit an error"
        case "bearing_anchors": return "Bolted holds: strength not checked"
        default: return "Strength not checked"
        }
    }

    /// Why a verdict is not proven, in a few words.
    public static func provenWords(_ w: String) -> String {
        switch w {
        case "nothing_judged": return "Nothing thick enough to judge"
        case "thin_place_under_pass_line": return "A thin place reads low"
        case "post_section_under_pass_line": return "A post reads low"
        case "post_load_path_not_resolved": return "Post too thin to judge"
        case "unresolved_energy": return "Thin parts carry the load"
        case "unresolved_joint": return "Thin joint carries the load"
        case "close_to_pass_line": return "Close to the limit"
        default: return "Strength not proven"
        }
    }

    /// A thin region's words (C8 FINAL).
    public static func regionWords(_ kind: String) -> String { kind == "thin_member" ? "Thin strut carries the load" : "Thin joint carries the load" }

    /// The reason line: the not-checked reason, or the first not-proven word; "" when there is none to give.
    public var reasonLine: String {
        switch kind {
        case .notChecked, .other: return Self.reasonWords(reason)
        case .notProven: return Self.provenWords(notProvenBecause.first ?? "")
        default: return ""
        }
    }

    /// A number only where the verdict carries one: the first break's multiple, for a pass or a fail.
    public var number: Double? { kind == .pass || kind == .fail ? firstBreakMultiple : nil }

    /// "Holds 20.50x · needs 1.5x" for a pass or fail with a number; else the reason line, or "".
    public var checkLine: String {
        if let m = number {
            return (kind == .pass ? "Holds " : "Breaks at ") + StrengthWords.x(m) + (passLine.map { " \u{00B7} needs " + StrengthWords.need($0) } ?? "")
        }
        return reasonLine
    }

    /// Where it gives way first (pass or fail), or where the thin part sits (not proven).
    public var place: SIMD3<Double>? {
        switch kind {
        case .pass, .fail: return firstBreakAt
        case .notProven: return postPlaces.first ?? thinRegions.compactMap(\.at).first
        default: return nil
        }
    }

    /// The (i) behind a not-proven line: every word it gives, each once.
    public var info: String? {
        guard kind == .notProven else { return nil }
        var seen = Set<String>()
        let t = (notProvenBecause.map(Self.provenWords) + thinRegions.map { Self.regionWords($0.kind) }).filter { seen.insert($0).inserted }
        return t.isEmpty ? nil : t.joined(separator: ". ") + "."
    }
}
