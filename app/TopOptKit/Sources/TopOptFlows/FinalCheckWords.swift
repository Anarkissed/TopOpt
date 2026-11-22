import Foundation
import TopOptKit

/// ★ Reviewer ruling R-07 (11-22): a version that streamed (was on screen) and that the final check on its print file then
/// refused is never dropped in silence. While other versions stand, one plain line on the results names it and why; when
/// no version is left, the pop-up names the real cause from the run (each refused file, and the last design's own
/// numbers), never the generic "not strong enough". Words only: what core accepts does not change.
public enum FinalCheckWords {
    /// The versions the finishing turned from accepted to refused (report rows: `finish.verdict_changed`), in report order.
    public static func refused(_ b: RunReportBlocks) -> [RunReportBlocks.Row] {
        b.rows.filter { !$0.accepted && $0.finish?.verdictChanged == true }
    }

    /// Core's reason in plain words, first letter capital: "After finishing, it prints in 2 pieces" → "It prints in 2
    /// pieces"; "(2 bad edge(s))" → "(2 bad edges)".
    public static func reason(_ core: String) -> String {
        var s = core.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["After finishing, ", "With the slim finish, "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if let r = s.range(of: #"\d+ bad edge\(s\)"#, options: .regularExpression) {
            let n = Int(s[r].prefix { $0.isNumber }) ?? 0
            s.replaceSubrange(r, with: "\(n) bad edge" + (n == 1 ? "" : "s"))
        }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// What each accepted version was called on the results ("b"), by the volume fraction core asked for: the letter of
    /// its line in the Versions panel.
    public static func letters(tabs: [ResultVariantVM], blocks: RunReportBlocks?,
                               vf: (ResultVariantVM) -> Double?) -> [Double: String] {
        var out: [Double: String] = [:]
        for r in ResultsVersions.rows(tabs: tabs, blocks: blocks, requestedVF: vf) {
            guard let i = r.tabIndex, let t = tabs.first(where: { $0.index == i }), let v = vf(t) else { continue }
            out[v] = r.title.components(separatedBy: " · ").first ?? r.title
        }
        return out
    }

    /// The same, from an outcome as it streamed (the run screen's, before the final one replaces it).
    @MainActor public static func letters(of o: OptimizeOutcome) -> [Double: String] {
        let acc = o.variants.filter(\.accepted)
        let tabs = ResultsModel.buildTabs(acc, voxelVolumeMM3: o.voxelVolumeMM3, remote: o.computedRemotely)
        return letters(tabs: tabs, blocks: o.reportJSON.flatMap(RunReportBlocks.decode(reportJSON:))) { t in
            t.latticeAlternative == nil && acc.indices.contains(t.variantIndex) ? acc[t.variantIndex].requestedVolumeFraction : nil
        }
    }

    static func name(_ vf: Double, _ letters: [Double: String]) -> String {
        letters.first { abs($0.key - vf) < 1e-6 }.map { "Version " + $0.value } ?? "A version"
    }

    static func because(_ r: RunReportBlocks.Row) -> String {
        let core = r.finish.map { $0.verdictReason.isEmpty ? r.rejectionReason : $0.verdictReason } ?? r.rejectionReason
        let s = reason(core)
        return s.isEmpty ? "" : s.prefix(1).lowercased() + s.dropFirst()
    }

    /// The results' line, one per refused version: "Version b removed" · "Its file failed the final check: it prints in 2
    /// pieces". Empty when nothing was refused.
    public static func checks(_ b: RunReportBlocks?, letters: [Double: String]) -> [ResultsCheck] {
        guard let b else { return [] }
        return refused(b).map { r in
            let why = because(r)
            return ResultsCheck(kind: .warn, title: name(r.volumeFraction, letters) + " removed",
                                detail: "Its file failed the final check" + (why.isEmpty ? "" : ": " + why), tab: .printing)
        }
    }

    /// The pop-up's lines when no version is left: "Version a: it prints in 2 pieces".
    public static func lines(_ b: RunReportBlocks, letters: [Double: String]) -> [String] {
        refused(b).map { r in
            let why = because(r)
            return name(r.volumeFraction, letters) + ": " + (why.isEmpty ? "its file failed the final check" : why)
        }
    }
}
