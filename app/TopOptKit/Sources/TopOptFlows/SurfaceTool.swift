// SurfaceTool.swift — ★ THE SURFACE STAGE'S TOOLBOX (task
// 2026-08-15-lattice-and-face-ui §6/§7; maintainer 2026-08-14: "The different
// tools should be visible and clearly shown … think of it more like an icon tray
// - not a full text modal. Think Adobe Photoshop's tools").
//
// ── WHY A TYPE AND NOT FOUR BOOLEANS ─────────────────────────────────────────
//
// A tool is a MODE: exactly one is armed, and what a tap on the model means
// depends entirely on which. Modelled as a set of booleans, "no tool" and "two
// tools" are both representable and both meaningless — and the page has already
// paid for that shape once, in the role flags PR 331 replaced. One enum with one
// default cannot express either.
//
// ★ AND THE DEFAULT IS `select`, NOT `cut` (maintainer, explicitly: "The default
// tool that should be set is Select - cut should *not* be set as the default
// tool"). It is the only tool that changes nothing: arriving on a stage with a
// DESTRUCTIVE tool armed means the first exploratory tap already edited the model.
// Selecting is how you look; every other tool acts.

import Foundation

/// One tool. The order is the tray's order, top to bottom.
public enum SurfaceTool: Int, CaseIterable, Hashable, Sendable {
    case select
    /// ★ §6(c)/(d) — "the ones like this one". A SELECTION aid, so it sits beside
    /// `select` rather than among the tools that cut and combine.
    case similar
    case cut
    case union
    case pattern

    /// ★ THE DEFAULT. Named here rather than at the `@State` that holds it, so the
    /// rule is one fact with one test rather than a literal repeated per call site.
    public static let initial: SurfaceTool = .select

    /// SF Symbol for the tray.
    public var icon: String {
        switch self {
        case .select:  return "hand.tap"
        case .similar: return "sparkles"
        case .cut:     return "scissors"
        case .union:   return "square.on.square"
        case .pattern: return "square.grid.3x3"
        }
    }

    /// The tray's accessibility label, and the one-word name in the hint line.
    public var title: String {
        switch self {
        case .select:  return "Select"
        case .similar: return "Similar"
        case .cut:     return "Cut"
        case .union:   return "Union"
        case .pattern: return "Pattern"
        }
    }

    /// One line: what a tap does with this tool armed. Shown under the tray, so a
    /// tray of icons is never a guessing game.
    public var hint: String {
        switch self {
        case .select:  return "Tap a face to select it."
        case .similar: return "Tap a face to find the ones like it."
        case .cut:     return "Tap a face to cut it in two."
        case .union:   return "Tap faces to combine; tap again to drop."
        case .pattern: return "Tap a face to split it into a grid."
        }
    }

    /// ★ WHETHER THIS TOOL CHANGES THE MODEL. `select` does not, which is exactly
    /// why it is the default; the rest all commit through a confirm.
    public var edits: Bool { self != .select }
}
