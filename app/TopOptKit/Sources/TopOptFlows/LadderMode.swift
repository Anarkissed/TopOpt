// LadderMode — THE two modes "Minimize plastic" chooses between, each nameable in
// ONE LINE (task 2026-08-03-growth-ladder, bar G7).
//
// WHAT WAS WRONG. "Minimize plastic" read as an objective toggle with an obvious
// on-state and an unexamined off-state. Unticking it silently changed three things
// at once:
//   * the SEARCH — from a four-rung reduction ladder to a single conservative
//     variant at 0.9 of the part, with no search and no recommendation at all;
//   * the ANCHOR PAD — a structural safety feature (added after a real failure)
//     was quietly not built;
//   * and it said none of that anywhere. The chip said "Minimize plastic". The
//     Optimize sub-label, with the box off, said nothing about the mode at all.
//
// WHAT IS TRUE NOW. Off is a GROWTH LADDER: the user is saying "you may add more
// plastic to reach the strength I asked for — as little as possible". Both modes
// search, both recommend, the pad is built in both, and this file is the ONE place
// either mode is described, so the chip, the import sheet, the Optimize sub-label
// and the results screen cannot phrase the same mode four different ways.
//
// Pure value type — no core dependency, no view dependency — so the copy is
// headlessly assertable.

import Foundation

/// Which ladder a run walks. `reduction` is "Minimize plastic" ON (the default).
public enum LadderMode: String, Equatable, Sendable, CaseIterable {
    /// Rungs BELOW the part's volume: remove as much plastic as possible while
    /// holding the required margin. Recommends the LIGHTEST variant that passes.
    case reduction
    /// Rungs ABOVE the part's volume: add as little plastic as possible to reach
    /// the required margin. Recommends the SMALLEST ADDITION that passes.
    case growth

    /// Which mode a "minimize plastic" setting means. The ONE mapping; nothing
    /// else in the app may re-derive it from the boolean.
    public static func of(minimizePlastic: Bool) -> LadderMode {
        minimizePlastic ? .reduction : .growth
    }

    /// The mode's short name, for a chip or a badge.
    public var title: String {
        switch self {
        case .reduction: return "Minimize plastic"
        case .growth:    return "Add to strengthen"
        }
    }

    /// *** THE ONE LINE. *** What this mode optimizes for, in a sentence, in the
    /// user's terms. This is the bar: each mode must be nameable in one line.
    public var oneLine: String {
        switch self {
        case .reduction:
            return "Remove as much plastic as possible while still meeting your safety margin."
        case .growth:
            return "Add as little plastic as possible to meet your safety margin."
        }
    }

    /// The same fact compressed for the Optimize button's sub-label, where it sits
    /// beside the load-case summary ("minimize plastic · 2 anchors · 1 load").
    public var summaryToken: String {
        switch self {
        case .reduction: return "minimize plastic"
        case .growth:    return "add to strengthen"
        }
    }

    /// What the RESULTS screen says above the variant tabs, naming both the mode
    /// and what its recommendation means — because the two ladders' tabs look alike
    /// and the recommendation means the opposite thing in each.
    public var resultsLine: String {
        switch self {
        case .reduction:
            return "Minimize plastic — recommending the LIGHTEST variant that meets your margin."
        case .growth:
            return "Add to strengthen — recommending the SMALLEST addition that meets your margin."
        }
    }

    /// What the tab headline's sign means in this mode: material saved, or added.
    public var headlineNoun: String {
        switch self {
        case .reduction: return "saved"
        case .growth:    return "added"
        }
    }
}
