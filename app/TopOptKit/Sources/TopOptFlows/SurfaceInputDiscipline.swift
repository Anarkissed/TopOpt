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

    /// HAS THIS DEVICE EVER PRODUCED A PENCIL CONTACT?
    ///
    /// There is no public "is an Apple Pencil paired" API; the only honest signal
    /// is a `UITouch` whose `type` is `.pencil`, which the view already partitions
    /// its recognizers by. So the app learns this by being touched.
    ///
    /// ★ IT NO LONGER DECIDES ANYTHING. It used to gate `enforced`; now it picks
    /// which of the tray's two hint lines is shown — see `pencilAbsent`. Kept
    /// because "a pencil has never touched this screen" is the one case where the
    /// user needs to be told where the escape is, and that is worth a line of its
    /// own rather than a generic one.
    public let pencilSeen: Bool

    public init(pencilOnly: Bool, pencilSeen: Bool) {
        self.pencilOnly = pencilOnly
        self.pencilSeen = pencilSeen
    }

    /// Both contacts do everything — every stage but the Surface one, and the
    /// Surface one until the button is pressed.
    public static let off = SurfaceInputDiscipline(pencilOnly: false,
                                                   pencilSeen: false)

    /// ★★ LATCHED MEANS ENFORCED. No pencil-seen precondition.
    ///
    /// ── AND THE GATE THAT USED TO BE HERE ────────────────────────────────────
    ///
    /// This read `pencilOnly && pencilSeen`: the separation waited until a `.pencil`
    /// touch had actually arrived, so that latching it on a device with no pencil
    /// could not leave a stage that refuses to edit with the only input the user
    /// has. ★ THAT REASONING WAS SOUND AND IS NOT OVERRULED — it is SUPERSEDED,
    /// because the stranding it guarded against cannot happen: the TOGGLE ITSELF is
    /// not routed through this discipline, so a finger can always untick it, and it
    /// is always on screen. It is its own escape hatch. (Maintainer: "the checkbox
    /// can be UNCHECKED with a finger or a pencil." Gated by
    /// `SurfacePencilToggleExemptionTests`, which fail if anyone ever routes it
    /// through.)
    ///
    /// ★ AND THE WAIT WAS NOT MERELY REDUNDANT, IT WAS THE DEFECT. Pencil mode
    /// exists for Jul 31 item (4) — "Moving the camera while modifying a primitive
    /// is very difficult; touches suddenly change the primitive's location/size/
    /// angle." Waiting for a pencil leaves a window at the START OF EVERY SESSION
    /// in which a stray finger can still move the thing you are working on: exactly
    /// the case the mode was built to eliminate, still live in the first seconds,
    /// every time.
    public var enforced: Bool { pencilOnly }

    /// On, and no pencil has ever touched this screen. The tray's hint line reads
    /// this to pick the more helpful of its two lines.
    public var pencilAbsent: Bool { pencilOnly && !pencilSeen }

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
