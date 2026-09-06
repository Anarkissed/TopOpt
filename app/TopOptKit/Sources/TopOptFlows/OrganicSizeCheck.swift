import Foundation

/// ★ THE ORGANIC SIZE CHECK (his items 2 and 4, 2026-09-05): a typed cell size or
/// grade is checked against our definition of a lattice AFTER the number is
/// complete, never per keystroke. What the app can judge locally: the printable
/// floor at this bead, and whether one cell fits the thinnest declared wall. What
/// only the probe can judge (rooting, families, the stress bar): read from the
/// probe when it has that exact candidate; otherwise "likely" stays a guess and
/// the copy says so. `cells_across` is ADVICE, never a gate (core's brief).
public enum OrganicSizeCheck {

    public struct Wall: Equatable, Sendable {
        public let key: String
        public let depthMM: Double
        public init(key: String, depthMM: Double) { self.key = key; self.depthMM = depthMM }
    }

    public struct Verdict: Equatable, Sendable {
        /// Aesthetic: may it be used at all (the printable floor, one cell fits)?
        public let allowed: Bool
        /// Structural: is it LIKELY to certify? nil when nothing can say (no probe).
        public let likely: Bool?
        /// Why, in short lines — shown under the field (Aesthetic) or in the alert
        /// (Structural). Empty when nothing is wrong.
        public let reasons: [String]
        /// Advice that never gates (cells across).
        public let advice: [String]
        public var text: String { reasons.joined(separator: "\n") }
    }

    /// Cells across below which the certificate's own material assumption is
    /// doubtful — ADVICE only (measured: 1.7–3.4 cells across certified).
    public static let cellsAcrossAdvisory = 4.0

    public static func evaluate(cellMinMM: Double, cellMaxMM: Double,
                                walls: [Wall], printabilityFloorMM: Double,
                                probe: OrganicForecast?) -> Verdict {
        var reasons: [String] = []
        var advice: [String] = []
        let lo = Swift.min(cellMinMM, cellMaxMM), hi = Swift.max(cellMinMM, cellMaxMM)
        guard lo > 0 else {
            return Verdict(allowed: false, likely: false, reasons: ["Enter a size greater than 0 mm."], advice: [])
        }
        if printabilityFloorMM > 0, lo < printabilityFloorMM - 1e-9 {
            reasons.append(String(format: "%g mm is smaller than the smallest cell this nozzle can print (%.2f mm).",
                                  lo, printabilityFloorMM))
        }
        if let thinnest = walls.min(by: { $0.depthMM < $1.depthMM }), thinnest.depthMM > 0,
           hi > thinnest.depthMM + 1e-9 {
            reasons.append(String(format: "%g mm is larger than the thinnest wall (%.1f mm), so not even one cell fits.",
                                  hi, thinnest.depthMM))
        }
        for w in walls where w.depthMM > 0 {
            let across = w.depthMM / hi
            if across < cellsAcrossAdvisory {
                advice.append(String(format: "%.1f cells across the %.1f mm wall. Four or more behave as one material.",
                                     across, w.depthMM))
            }
        }
        // The probe's own verdict for this exact candidate, when it has one.
        var likely: Bool? = nil
        if let probe {
            if let c = probe.candidates.first(where: {
                abs($0.cellMinMM - lo) < 1e-6 && abs($0.cellMaxMM - hi) < 1e-6 }) {
                likely = c.approvedStructural
                if !c.approvedAesthetic { reasons.append(contentsOf: c.refusals) }
                else if !c.approvedStructural { reasons.append(contentsOf: c.refusals) }
                if let p = c.predicted, p.ran {
                    advice.append(String(format: "Predicted margin %.2f.", p.margin))
                }
            }
        }
        let allowed = reasons.isEmpty || (likely != nil && probeAllowsAesthetic(probe, lo, hi))
        return Verdict(allowed: allowed && !hardRefused(reasons), likely: reasons.isEmpty ? likely : (likely ?? false),
                       reasons: reasons, advice: advice)
    }

    private static func probeAllowsAesthetic(_ probe: OrganicForecast?, _ lo: Double, _ hi: Double) -> Bool {
        probe?.candidates.first(where: { abs($0.cellMinMM - lo) < 1e-6 && abs($0.cellMaxMM - hi) < 1e-6 })?
            .approvedAesthetic ?? true
    }

    /// The two local rules are hard refusals everywhere: below the printable cell,
    /// or bigger than the thinnest wall.
    private static func hardRefused(_ reasons: [String]) -> Bool {
        reasons.contains { $0.contains("smallest cell") || $0.contains("thinnest wall") }
    }

    /// The Structural pop-up's words (his item 2: "it will confirm when the actual
    /// lattice is calculated but that it may not fit", said better).
    public static func structuralNotice(label: String, verdict: Verdict) -> String {
        var text = "\(label) is not expected to pass certification."
        if !verdict.reasons.isEmpty { text += "\n" + verdict.text }
        return text + "\nThe final check happens when the lattice is built. You can keep this size; "
            + "the run's certificate decides."
    }
}
