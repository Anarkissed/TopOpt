// LatticeStageMode — ★★★ THE ONE QUESTION THE LATTICE STAGE ASKS BEFORE ANYTHING ELSE
// (maintainer, 2026-08-21: "create the two separate 'Modes' for the Lattice Stage …
// implement it with a Modal at the start, right when you switch over … This cannot be
// changed again afterwards").
//
// ★★ IT IS NOT A NEW CONCEPT — IT IS CORE'S `GradingIntent`, SURFACED. Core already
// carries the distinction and carries it better than a UI flag would:
//
//   STRUCTURAL   demand / the material ALLOWABLE.        "Is it strong enough."
//   AESTHETIC    demand / a high PERCENTILE of the field. "Where is it working hardest."
//
// Both are the same relative law; they differ in the denominator, and the denominator
// is the whole argument. Core's own note on why aesthetic does not divide by the peak:
// one re-entrant corner or point load runs several times the bulk field, so dividing by
// the MAXIMUM compressed everything else onto the floor. The 95th percentile is that
// law with the outlier removed, and everything above it is clamped AND COUNTED.
//
// ★ WHAT ACTUALLY CHANGES, AND IT IS NOT DECORATION:
//
//   1. THE DENOMINATOR (above) — so the same part grades differently.
//   2. THE CELLS-PER-MEMBER FLOOR. The fixed 5 is an ACCURACY threshold — where the
//      homogenised model's transverse-stiffness error crosses a 2.4 % band — not a
//      buildability one. A lattice graded for looks makes no strength claim, so core
//      computes the floor from its measured error curve and the material's own
//      utilisation, down to a HARD FLOOR OF 2. Two, not one: 2 is the lowest cell count
//      measured under the same bending case the accuracy floor uses (+8.5 %), while the
//      percolation floor of 1.0 was measured axially at rho ≈ 0.199 and its own
//      declaration warns it "must not be quoted unconditionally".
//   3. WHAT THE RECEIPT CLAIMS. This is the difference that matters and the one he
//      asked to have settled before any UI: an aesthetic lattice is NOT covered by the
//      strength certificate, and the part is stamped out of regime for the material
//      that sits below the accuracy floor. Aesthetic changes what the density MEANS,
//      never whether it is checked — the printability floor still binds, the band clamp
//      still runs and is still counted, and the certificate still runs over whatever is
//      emitted.
//
// ★ WHY IT CANNOT BE CHANGED AFTERWARDS. The two modes produce different receipts about
// the same object. Letting the choice move mid-session would leave a part whose lattice
// was graded under one claim and certified under the other, and nothing on screen would
// say which — the precise class of silent divergence this whole branch has been paying
// down. So it is asked ONCE, up front, in a modal that cannot be dismissed without an
// answer, and it is then a property of the stage.

import Foundation
import TopOptKit

/// Which question the lattice stage is answering. Chosen once, on entering the stage.
public enum LatticeStageMode: String, Codable, Hashable, Sendable, CaseIterable {
    case structural
    case aesthetic

    /// The title shown wherever the stage identifies itself — required to be visible at
    /// all times ("a title somewhere that says Structural or Aesthetic").
    public var title: String {
        switch self {
        case .structural: return "Structural"
        case .aesthetic:  return "Aesthetic"
        }
    }

    /// One line, for the chip beside the title.
    public var tagline: String {
        switch self {
        case .structural: return "Graded to carry the load"
        case .aesthetic:  return "Graded to follow the load"
        }
    }

    /// The modal's body. Says what CHANGES, not what it is called — every sentence is a
    /// consequence the user can act on. The words "advanced", "expert" and "unsafe" are
    /// deliberately absent, as they are in `LatticeRetentionControl`.
    public var explanation: String {
        switch self {
        case .structural:
            return "Sized against the material's allowable stress. Members too thin "
                 + "to certify are left solid, and the strength certificate covers the "
                 + "whole part."
        case .aesthetic:
            return "Follows the stress pattern for appearance. Always goes down to 2 "
                 + "cells across a member instead of 5, however hard the wall is "
                 + "working — so every wall you mark gets latticed."
        }
    }

    /// The single sentence that must appear on the aesthetic side, taken from core so
    /// the app never authors the claim. nil for structural, which claims nothing extra.
    public var receiptCaveat: String? {
        switch self {
        case .structural: return nil
        case .aesthetic:
            // ★ CORE'S SENTENCE, NOT OURS (`kAestheticDensityMeaning`). It was
            // paraphrased in Swift for one build; the paraphrase is exactly the drift
            // this file exists to prevent, so it now comes across the bridge. Core
            // leads with "This lattice follows the stress pattern for appearance",
            // which the card already says one line above, so only the clause the
            // heading does not carry is shown — split on core's own text, never
            // retyped.
            let whole = TopOptKit.latticeAestheticDensityMeaning
            guard let cut = whole.range(of: "Its density") else { return whole }
            return String(whole[cut.lowerBound...])
        }
    }

    /// Core's `GradingIntent`, as the bridge takes it: 0 structural, 1 aesthetic.
    public var coreIntent: Int32 { self == .aesthetic ? 1 : 0 }

    /// ★ THE FLOOR THIS MODE ASKS FOR, given what the material actually carries.
    ///
    /// STRUCTURAL always takes core's accuracy floor — the utilisation is irrelevant
    /// because the certificate has to hold.
    ///
    /// ★★★ AESTHETIC TAKES CORE'S HARD FLOOR, FLAT (maintainer, 2026-08-21: "wire the
    /// Aesthetic lattice to *always* lattice at 2 cells/member max … The rule is we
    /// lattice *WHEREVER* it is asked of us"). It used to ask for the ADAPTIVE floor,
    /// which is still an accuracy rule: 2 cells only below 11.8 % utilisation, 3 below
    /// 24.4 %, and the accuracy floor of 5 above that — so a wall doing real work went
    /// solid in the mode whose entire premise is that it makes no strength claim. It
    /// also returned the accuracy floor outright when no utilisation was measurable,
    /// which made the presence of a solve decide whether his wall latticed.
    ///
    /// The mirror of this change lives in `core/src/simp/grading.cpp`, so the picture
    /// and the run take the same number from the same function.
    ///
    /// - Parameter utilisation: read only on the structural path — kept in the
    ///   signature because callers cannot know which mode they hold.
    /// - Returns: 0 when core has no number for the topology, which the caller must
    ///   surface rather than replace with a guess.
    public func cellsPerMemberFloor(topology: String, utilisation: Double) -> Double {
        switch self {
        case .structural:
            return TopOptKit.latticeLimits(topology: topology).minCellsPerMember
        case .aesthetic:
            return TopOptKit.latticeAestheticCellsPerMemberHardFloor(topology: topology)
        }
    }
}
