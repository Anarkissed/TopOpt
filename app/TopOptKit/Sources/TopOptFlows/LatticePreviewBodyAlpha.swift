// LatticePreviewBodyAlpha — when the part's shell may be hidden, as a pure value.
//
// ★★ WHY THIS IS A TYPE AND NOT A LINE IN A VIEW (task 2026-08-21). It was a private
// computed property on `WorkspacePlaceholder`, and it blanked the maintainer's whole
// part: his new `M2 verticalStand THICK` opened to a contact shadow on the stage floor
// and nothing drawn at all. No test could reach the rule to say it was wrong, which is
// the same reason `LatticeCellEntry` and `LatticeRetentionControl` were lifted out of
// views before it.
//
// ★ THE RULE. Hiding the shell is a concession to exactly ONE picture — the raymarched
// lattice layer standing alone, with no declared region to cut the shell against, where
// an opaque body would hide the preview completely (the lattice settings-page sample).
// Both halves of that sentence are conditions:
//
//   * the lattice layer must actually BE DRAWN, and
//   * there must be no declared include region to cut the shell to.
//
// The first was missing. The value was handed to the mesh view on every stage, so any
// project with no lattice include region — which is every project before the user
// declares one — drew no body. Measured on his own file: bodyAlpha 1 gives 9,590 lit
// pixels at 256², bodyAlpha 0 gives 0. The contact shadow survives either way, because
// the shadow pass does not read this value. That is precisely "a shadow and no body".
//
// ★ WHY IT SURFACED WHEN IT DID. The 0 had been computed for a long time but was
// silently dropped: until PR 341's confetti fix (dc0cb620) the coordinator only
// delivered a body alpha inside its load-flow block, and no other stage has a load flow.
// Making that delivery unconditional was correct, and it exposed a caller that was not.

import Foundation

public enum LatticePreviewBodyAlpha {

    /// The body opacity the workspace hands the mesh view.
    ///
    /// - Parameters:
    ///   - latticeLayerDrawn: whether the raymarched lattice layer is being drawn THIS
    ///     frame. Must be the same expression that gates the layer itself — a second
    ///     rule here is a rule that can drift from the one it is meant to match.
    ///   - hasIncludeRegion: whether the project declares any lattice INCLUDE region.
    ///     With one, the shell is cut to it and the two surfaces are complementary, so
    ///     the body stays opaque; with none, the lattice fills the interior and the
    ///     shell would hide it.
    /// - Returns: 1 (opaque) or 0 (not drawn at all).
    public static func value(latticeLayerDrawn: Bool, hasIncludeRegion: Bool) -> Float {
        guard latticeLayerDrawn else { return 1 }
        return hasIncludeRegion ? 1 : 0
    }
}
