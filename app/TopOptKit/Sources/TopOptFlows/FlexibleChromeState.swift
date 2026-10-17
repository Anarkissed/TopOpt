// FlexibleChromeState — ONE CARD AT A TIME on the main Flexible page (task 2026-09-29-flexible-screens, round 7, the
// redesign's step 0; shared by batch R7-D1 — the Setup tray, the Lattice card and the blocker callout — and R7-D2 — the
// face chip and a keypad).
//
// His rules (2026-09-29 and the redesign's picks of 2026-10-14): "one legend card per page", "blockers pop at once", and
// the mockup's corner pair, whose tray, card and callout never stack. So every card on the main page asks this object
// before it shows, and a model tap, a stage change, the Squish page opening or gravity setup fold them all.
//
// The API is the plan's exact text (redesign_plan.json, R7-D1 step 0), so D2 builds on the same object.

import Combine
import Foundation

public final class FlexibleChromeState: ObservableObject {
    public enum Card: Equatable, Sendable { case setup, latticeCard, callout, faceChip, keypad }

    /// The one card open on the main page (nil: none).
    @Published public private(set) var open: Card?

    public init() {}

    /// Opens `c` and closes whichever card was open.
    public func show(_ c: Card) {
        if open != c { open = c }
    }

    /// Opens `c`, or closes it when it is the open one.
    public func toggle(_ c: Card) {
        open = open == c ? nil : c
    }

    /// Closes `c` if it is the open one (another open card stays).
    public func close(_ c: Card) {
        if open == c { open = nil }
    }

    /// Every card folds: a model tap, a stage change, the Squish page opening, gravity setup.
    public func foldAll() {
        if open != nil { open = nil }
    }

    /// D2's face chip may show: nothing else is open (the chip itself, or the keypad it opened).
    public var allowsFaceChip: Bool { open == nil || open == .faceChip || open == .keypad }
}
