// GroupEyeHides.swift — Flexible (PR #362) round 9: THE EYE HIDES THE PRIMITIVES TOO.
//
// ★ HIS WORDS (2026-10-24): "When I click the eyeball the primitives of a group don't disappear.
// it's impossible to actually touch anything when it's as full as this one is."
//
// The eye already took a hidden group's face tints and lattice depth planes off the screen, but
// three things on the Topology stage never asked it: the keep-out / protect / load / anchor
// VOLUMES (`keepOutRenderItems`), the clearance drag KNOBS and their value CHIPS
// (`clearanceHandleItems`), and the active group's primitive MOVE KNOBS (`primitiveGizmoOverlay`).
// The knobs and chips are SwiftUI hit targets, so a hidden group still caught the taps meant for
// the model underneath. Each of those three now filters through here (hooks H49a–c).
//
// Hiding stays a PICTURE-only state (see `GroupViewState`): the group is still in the job.

import Foundation

extension GroupViewState {

    /// The items whose owning group is NOT hidden, in their original order.
    public func showing<T>(_ items: [T], group: (T) -> UUID) -> [T] {
        guard !hidden.isEmpty else { return items }
        return items.filter { !hidden.contains(group($0)) }
    }

    /// Whether the active group's primitive move knobs / transform gizmo draw at all. A hidden
    /// group draws none — they are hit targets that would sit over the model it was hidden to free.
    public func drawsPrimitiveKnobs(forActive group: UUID?) -> Bool {
        guard let group else { return false }
        return !isHidden(group)
    }
}
