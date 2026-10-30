// ViewModeHold.swift — the 3 s hold on a view button (lattice only), and the tap its release
// also delivers.

import Foundation

/// ★ THE RELEASE THAT ENDS A HOLD IS ALSO DELIVERED AS A TAP, and that tap must not undo what
/// the hold just set. It was swallowed by a CLOCK — within 1.5 s of the hold firing — so a
/// finger kept down a little longer (the badge is still showing) let go into a tap that turned
/// lattice only straight back off (his 2026-10-01: "I am also not able to go to 'Lattice Only'
/// view"). Now it is swallowed by the PRESS: a tap that ends the very press the hold fired
/// during. Where no press was tracked, the old clock remains; and the press rule has its own
/// bound, so a press-tracking gesture that stopped reporting can never swallow taps for long.
enum ViewModeHold {
    /// The fallback when no press has been tracked (the pre-2026-10-01 rule).
    static let clockWindowS: TimeInterval = 1.5
    /// A finger cannot plausibly stay down this long after the hold fired.
    static let pressWindowS: TimeInterval = 10

    /// Whether the tap arriving `now` is the release of the press the hold fired during.
    static func swallowsTap(holdFiredAt: Date, pressBeganAt: Date?, now: Date) -> Bool {
        guard let began = pressBeganAt else {
            return now.timeIntervalSince(holdFiredAt) < clockWindowS
        }
        return holdFiredAt >= began && now.timeIntervalSince(holdFiredAt) < pressWindowS
    }
}
