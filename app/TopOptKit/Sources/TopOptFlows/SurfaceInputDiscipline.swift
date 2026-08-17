// SurfaceInputDiscipline.swift — ★ §2: WHICH CONTACT MAY DO WHAT.
//
// ★ HIS LONG-STANDING ASK, first raised in the Jul 31 round as TO-page item (5)
// and never built:
//
//   "an option to do movement with fingers only and actions with the pencil only,
//    or vice-versa."
//
// ── WHY A VALUE TYPE AND NOT A BOOLEAN READ AT EACH RECOGNIZER ───────────────
//
// `BrushGesture` is the precedent, and it exists because the same question —
// "may THIS contact do THIS?" — was answered in two recognizers from two
// different flags, and the pencil-only smoothing brush disarmed the pencil.
// (Task 2026-08-05, bar D1: "this handler used to read a flag the page computed
// from a FINGER-only property".) One value, asked by every recognizer, is how
// that class of defect stops being possible.
//
// ★ AND THE INTENT IS A THIRD AXIS, NAMED. Undo and redo are FINGER gestures —
// two-finger double tap undoes, three-finger double tap redoes — and they must
// keep working with pencil mode on (bar R3): undo is not an edit. Modelled as
// "fingers may not edit", undo is edit-shaped and dies. Modelled as three
// intents, `undoRedo` is a case somebody has to deliberately withhold, and this
// type never does.

import Foundation

/// WHICH KIND OF CONTACT. Distinct from `BrushInput` (which is the brush's own
/// vocabulary) so the two features cannot drift into each other by aliasing.
public enum SurfaceContact: Equatable, Sendable {
    case finger
    case pencil
}

/// WHAT THE CONTACT IS TRYING TO DO.
public enum SurfaceIntent: Equatable, Sendable {
    /// Change the model: tap a face, aim a tool, commit an action.
    case edit
    /// Move the camera: orbit, pan, zoom.
    case camera
    /// ★ NEITHER. Undo and redo are multi-finger double taps, and they are not
    /// edits — they take one back. Named so no discipline can withhold them by
    /// folding them into `edit`.
    case undoRedo
}

/// ★ §2 — THE PENCIL MODE. Off by default; both contacts do everything, exactly
/// as the stage behaves today.
public struct SurfaceInputDiscipline: Equatable, Sendable {

    /// The maintainer's toggle: editing to the pencil, camera to the fingers.
    public let pencilOnly: Bool

    /// ★ §2(c) — HAS THIS DEVICE EVER PRODUCED A PENCIL CONTACT?
    ///
    /// There is no public "is an Apple Pencil paired" API; the only honest signal
    /// is a `UITouch` whose `type` is `.pencil`, which the view already partitions
    /// its recognizers by. So the app learns this by being touched.
    public let pencilSeen: Bool

    public init(pencilOnly: Bool, pencilSeen: Bool) {
        self.pencilOnly = pencilOnly
        self.pencilSeen = pencilSeen
    }

    /// Both contacts do everything — every stage but the Surface one, and the
    /// Surface one until the button is pressed.
    public static let off = SurfaceInputDiscipline(pencilOnly: false,
                                                   pencilSeen: false)

    /// ★ §2(c) — THE BUTTON MUST NOT STRAND A FINGER-ONLY USER.
    ///
    /// Turning it on with no pencil ever seen would leave a stage that refuses to
    /// edit and offers no other way in — the one outcome §2(c) forbids. So the
    /// separation is only ENFORCED once a pencil has actually touched the glass.
    /// The toggle still latches (it is a preference, and it is the user's), and
    /// the tray says out loud that it is waiting — see `waitingForPencil`.
    public var enforced: Bool { pencilOnly && pencilSeen }

    /// On, but inert because nothing has ever written on this screen with a
    /// pencil. The tray's hint line reads this rather than leaving the button lit
    /// over a stage where nothing changed.
    public var waitingForPencil: Bool { pencilOnly && !pencilSeen }

    /// ★ THE ONE ROUTING DECISION. Every recognizer asks this.
    public func admits(_ contact: SurfaceContact, _ intent: SurfaceIntent) -> Bool {
        // ★ UNDO AND REDO ARE NEVER WITHHELD, from either contact, in any mode
        // (bar R3). They are how you get out of a mistake, and a mode that can
        // trap you in one is worse than no mode.
        if intent == .undoRedo { return true }
        guard enforced else { return true }
        switch (contact, intent) {
        case (.pencil, .edit):   return true
        case (.pencil, .camera): return false
        case (.finger, .edit):   return false
        case (.finger, .camera): return true
        case (_, .undoRedo):     return true      // unreachable; stated anyway
        }
    }
}
