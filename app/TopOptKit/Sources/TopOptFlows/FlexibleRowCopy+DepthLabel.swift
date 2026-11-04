// FlexibleRowCopy+DepthLabel — the words of round 7 · U21 batch F "One depth number" (his notes of 2026-10-21, Img8/9/10).
// Every line ≤ 44 characters (FlexibleRowCopy.fit), plain words.

import Foundation

extension FlexibleRowCopy {
    /// ★ DEPTH-LABEL (his Img9: "If it can't go to a depth, ensure that the depth it reverts to is labelled correctly in both
    /// areas"): the number on the model (the chip, a Prisms tag) when core builds short: "0.6 of 7.0 mm".
    public static func reachedOf(_ reachedMM: Double, _ deepestMM: Double) -> String {
        String(format: "%.1f of %.1f mm", reachedMM, deepestMM)
    }
    /// The card's orange line, the same numbers: "Reaches 0.6 of 7.0 mm · 4549 columns short" (≤ 44; "· 4549 short" when the
    /// numbers are long).
    public static func reaches(_ reachedMM: Double, of deepestMM: Double, short: Int) -> String {
        let head = "Reaches " + reachedOf(reachedMM, deepestMM)
        let long = "\(head) \u{00B7} \(short) columns short"
        return long.count <= maxChars ? long : fit("\(head) \u{00B7} \(short) short")
    }
    /// The Auto pane's per-face line (one source with the card): "Core builds 0.6 of 7.0 mm here."
    public static func coreBuilds(_ reachedMM: Double, of deepestMM: Double) -> String {
        "Core builds " + reachedOf(reachedMM, deepestMM) + " here."
    }

    /// ★ DEPTH-LABEL: X-ray's legend row — before the 3D sim the prism is his DRAWING scaled ×k ("Prism = your drawing ×2"),
    /// with the 3D sim it is the bend at full load.
    public static func legendBendRow(short: Bool, drawing: Bool, k: Int) -> String {
        guard drawing, !controlBendRowAlwaysBend else { return legendBendRow(short: short) }
        return k > 1 ? fit("Prism = your drawing \u{00D7}\(k)") : "Prism = your drawing"
    }
    /// ★ RED CONTROL only (U21 batch F): X1's row — "bend at full load" over his drawing too.
    nonisolated(unsafe) static var controlBendRowAlwaysBend = false

    /// ★ AUTO-CURVE (his Img10: "Why can't 'auto' ever meet my curve? … What does it take to meet my curve?"): the worst face or
    /// press in core's failure list and its counts.
    public struct AutoBlocker: Equatable, Sendable {
        public let name: String
        public let tooFirm: Int, tooSoft: Int, beyondData: Int
        public init(name: String, tooFirm: Int, tooSoft: Int, beyondData: Int) {
            self.name = name; self.tooFirm = tooFirm; self.tooSoft = tooSoft; self.beyondData = beyondData
        }
    }
    /// What it takes, from the dominant count: too firm (even the softest lattice is too firm) → more weight or less depth; too
    /// soft → less weight or more depth; beyond the data → past the tested squish. The name is fitted, the what-to-do kept.
    public static func autoWhatItTakes(_ b: AutoBlocker) -> String {
        let tail: String, short: String
        if b.beyondData > max(b.tooFirm, b.tooSoft) {
            tail = " is past the tested squish"; short = " \u{00B7} past the tested squish"
        } else if b.tooSoft > b.tooFirm {
            tail = " needs less weight or more depth"; short = " \u{00B7} less weight or more depth"
        } else if b.tooFirm > 0 {
            tail = " needs more weight or less depth"; short = " \u{00B7} more weight or less depth"
        } else {
            tail = " can't be met"; short = " can't be met"
        }
        let head = "Auto: "
        if (head + b.name + tail).count <= maxChars { return head + b.name + tail }
        return head + fit(b.name, maxChars - head.count - short.count) + short
    }
}
