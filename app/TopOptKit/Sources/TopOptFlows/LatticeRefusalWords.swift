// LatticeRefusalWords.swift — his iPad notes 11-22 (the sample that "couldn't be built" with no reason): "An error should
// always tell what's wrong and how to fix it. Always."
//
// The engine's refusal already carries a plain sentence (LatticeReview's E1: "Cell size: the small end must be at least
// 3.2 mm, the smallest cell a 1.35 mm strut can print.") and the numbers it allows. This shows that sentence whole and, where
// the sentence names only one way out, adds the other one.

import Foundation
import TopOptKit

public enum LatticeRefusalWords {
    /// What is wrong and how to fix it, from one refusal (`text`: the sentence with its areas named, when the page renamed them).
    public static func line(_ r: LatticeLayoutSession.Refusal, text: String? = nil) -> String {
        let what = (text ?? r.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let more = fix(r) else { return what }
        return (what.hasSuffix(".") ? what : what + ".") + " " + more
    }

    /// Several refusals: the first whole, then how many more.
    public static func lines(_ rs: [LatticeLayoutSession.Refusal]) -> String? {
        guard let first = rs.first else { return nil }
        return line(first) + (rs.count > 1 ? " (and \(rs.count - 1) more)" : "")
    }

    /// The second way out, where the sentence gives one: a cell too small for its struts is fixed either way.
    static func fix(_ r: LatticeLayoutSession.Refusal) -> String? {
        switch r.code {
        case "under_smallest_cell", "under_gap_cell":
            // up to the hundredth, as the engine's own sentence rounds it ("at least 2.08 mm", never "2.0722")
            return r.allowedMin.map { "Raise it to \(StrengthCheckDocs.number(Self.upToHundredth($0))) mm, or make the struts thinner." }
        default:
            return nil   // the sentence says what to set ("must be from 0 to 1", "needs Ties switched on")
        }
    }

    /// A smallest allowed number, rounded up to the hundredth (a number rounded down would still be refused).
    static func upToHundredth(_ v: Double) -> Double { (v * 100 - 1e-9).rounded(.up) / 100 }
}

/// A lay the engine refused, carried to the sample's pop-up whole.
struct LatticeRefused: Error {
    let refusals: [LatticeLayoutSession.Refusal]
}
