// BrushGesture — who may paint with a drag, and where a drag goes (the Topology page's paint brush). It lived with the
// Smooth page's brush (SmoothBrush.swift), which B4 deletes with the page (plan.md §B4: "The Smooth page is deleted").

import Foundation

/// ONE DECISION, READ BY EVERY SITE THAT ROUTES A DRAG.
///
/// THE DEFECT THIS EXISTS TO MAKE UNWRITABLE. Round 2 armed the viewer's brush
/// gesture from one property; round 3 added `brushRequiresPencil` as a second,
/// correct admission mechanism at the recognizer — and left the first one
/// reading a finger-only value. Two mechanisms decided the same thing, the
/// stricter one won, and checking a box called "Pencil only" turned off painting
/// entirely, the pencil included. The maintainer lost a night to it.
///
/// So the question is asked ONCE here and the answer is passed down. The
/// workspace builds this value; the view's inputs carry its two fields; the
/// recognizers route through `route(_:touches:)`. There is no second place to
/// disagree with.
public struct BrushGesture: Equatable, Sendable {
    /// Does the brush claim a drag at all? Off ⇒ every contact is the camera's.
    public let armed: Bool
    /// Is the brush withholding the FINGER (the pencil is never withheld)?
    public let requiresPencil: Bool

    public init(armed: Bool, requiresPencil: Bool) {
        self.armed = armed
        self.requiresPencil = requiresPencil
    }

    /// The TO page's paint drawer — unchanged behaviour: armed by its own toggle,
    /// and it never withholds the finger.
    public static func workspacePaint(active: Bool) -> BrushGesture {
        BrushGesture(armed: active, requiresPencil: false)
    }

    /// The brush is off everywhere else.
    public static let off = BrushGesture(armed: false, requiresPencil: false)

    /// May a drag from `input` paint?
    public func admits(_ input: BrushInput) -> Bool {
        guard armed else { return false }
        switch input {
        case .pencil: return true
        case .finger: return !requiresPencil
        }
    }

    /// Where a drag goes.
    public enum Route: String, Equatable, Sendable {
        /// Into the brush.
        case paint
        /// To the camera's orbit.
        case orbit
        /// To the camera's pan (two fingers, brush not claiming the drag).
        case pan
    }

    /// Route a drag of `touches` contacts of kind `input`.
    ///
    /// The rules, unchanged from what the recognizers did before this value
    /// existed — one finger paints while the brush admits it, two fingers orbit
    /// so the camera stays drivable mid-stroke, and a contact the brush does not
    /// admit falls through to the ordinary camera gestures (two fingers pan, one
    /// orbits). What changed is that they are stated once.
    public func route(_ input: BrushInput, touches: Int) -> Route {
        if admits(input) {
            // A pencil is always exactly one contact; a finger drag with a second
            // finger down is the user reaching for the camera mid-stroke.
            if input == .pencil || touches <= 1 { return .paint }
            return .orbit
        }
        return touches >= 2 ? .pan : .orbit
    }

    /// Whether a drag from `input` is being REFUSED — the brush is armed and this
    /// contact still cannot paint. The page says so at the moment it happens
    /// rather than leaving grey buttons downstream to imply it.
    public func refuses(_ input: BrushInput) -> Bool {
        armed && !admits(input)
    }
}
