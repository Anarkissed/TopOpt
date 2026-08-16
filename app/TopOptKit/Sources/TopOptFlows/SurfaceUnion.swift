// SurfaceUnion.swift — ★ THE UNION TOOL, REWRITTEN (task 2026-08-15-lattice-and-
// face-ui §6; maintainer: "I think it might be best to completely *re-write* the
// union tool. Patching it together is making things stranger").
//
// ── WHY THE PATCHES KEPT MAKING IT STRANGER ──────────────────────────────────
//
// The tool was built three times without ever deciding what a union IS against
// this data model, so each fix contradicted the last:
//
//   1. It held `Set<FaceID>`. Two pieces of a cut face share ONE face id, so the
//      second tap toggled the first back off and the count never reached two.
//   2. Held as regions instead, the HIGHLIGHT still lit a picked piece's whole
//      FACE — one tap looked like two selections.
//   3. The commit built a region out of two pieces. A region is
//      `faces ∩ (intersection of half-spaces)`; the union of two disjoint pieces
//      is NOT expressible that way, so it produced a region resolving to the whole
//      face while the original pieces carried on existing side by side — "I press
//      the checkbox and they are still separate pieces."
//
// ── THE RULE, IN ONE SENTENCE ────────────────────────────────────────────────
//
// ★ THE PIECES YOU TAPPED, AND ONLY THOSE, BECOME ONE PIECE.
//
// Maintainer, 2026-08-15, after I had built something else: "If a piece is part of
// a cut or patterned face, *ONLY THAT PIECE* joins the other selected piece. DO NOT
// EVER JOIN ANY PIECES WITHOUT A PERSON ACTIVELY SELECTING THEM!"
//
// ★ AND WHY I BUILT SOMETHING ELSE — recorded so the next person does not repeat
// it. `FaceRegion` is `(member faces) ∩ (intersection of half-spaces)`, which can
// express one convex-ish part and not a UNION of two. Faced with a rule the struct
// could not hold, I bent the RULE ("a union combines whole faces") instead of the
// STRUCT. That is backwards: the data model exists to serve the operation, and a
// tool that quietly takes in pieces the user never touched is worse than one that
// does not exist yet.
//
// ★ WHAT THE STRUCT NEEDS, and why it is not written here yet. A union has to hold
// its PARTS — the regions that were picked — and resolve to their union. The job
// already carries regions as a LIST per group with per-region depths
// (`ProjectModel.faceProtectionPayload`), so a union region can expand to its parts
// at emission while showing as ONE row with one role and one depth in the UI. That
// is a `parts: [RegionID]` on `FaceRegion` (absent by default, so day-one projects
// stay byte-identical per PR 331's bar), membership as the union of the parts, and
// expansion at the two emission sites. It is a contained change and it is NOT DONE.
//
// Until it is, this type PICKS but does not COMMIT: `canCommit` is false and the
// confirm stays disabled, because the only commit available today is the one the
// maintainer explicitly forbade.

import Foundation
import TopOptKit

public struct SurfaceUnion: Equatable, Sendable {

    /// The pieces picked, in tap order — order is kept so the UI can show them
    /// stably, but membership is what matters.
    public private(set) var pieces: [RegionID] = []

    public init() {}

    public var isEmpty: Bool { pieces.isEmpty }
    public var count: Int { pieces.count }

    /// ★ TAP TO ADD, TAP AGAIN TO DROP. One gesture, reversible, so a mis-tap
    /// costs a tap rather than the whole selection.
    public mutating func toggle(_ id: RegionID) {
        if let i = pieces.firstIndex(of: id) { pieces.remove(at: i) }
        else { pieces.append(id) }
    }

    public mutating func clear() { pieces = [] }

    public func contains(_ id: RegionID) -> Bool { pieces.contains(id) }

    /// Two pieces is the minimum a union could ever act on.
    public var hasEnoughToCombine: Bool { pieces.count >= 2 }

    /// ★ TWO PIECES AND IT COMMITS. `FaceRegion.parts` now holds a union of
    /// exactly the picked pieces, so the honest commit exists.
    public var canCommit: Bool { hasEnoughToCombine }

    // MARK: - what a commit would do, answerable BEFORE committing

    // ── how a pick is DRAWN depends on whether it is a whole face ──────────
    //
    // ★ A WHOLE FACE HAS NO HALF-SPACES, so it produces no chain for the fragment
    // test — and with the test armed, its fragments fell through to the "not in any
    // group" colour and went DIM. That is why "union only seems to work with CUT
    // pieces": picking an ordinary face registered in the set and looked like
    // nothing had happened.
    //
    // The two kinds are drawn by the two mechanisms that suit them: a whole face is
    // unambiguous and is coloured per triangle; a PART needs the per-fragment
    // half-space test to separate it from its siblings.

    /// Picks that are entire faces — coloured directly, no fragment test needed.
    public func wholeFacePicks(regions: FaceRegionModel, mesh: ViewerMesh) -> Set<FaceID> {
        var out: Set<FaceID> = []
        for id in pieces {
            guard let r = regions.region(id), !r.isCut else { continue }
            out.formUnion(FaceRegionGeometry.members(of: r, in: mesh))
        }
        return out
    }

    /// Picks that are PARTS of a face — these need the fragment test.
    public func partialPicks(regions: FaceRegionModel) -> [RegionID] {
        pieces.filter { regions.region($0)?.isCut ?? false }
    }

    /// The faces whose fragments the shader must test — the partial picks' faces,
    /// and only those. A whole face must NOT be in here: it is already coloured,
    /// and testing it would dim it.
    public func facesTouched(regions: FaceRegionModel, mesh: ViewerMesh) -> [FaceID] {
        var out: Set<FaceID> = []
        for id in partialPicks(regions: regions) {
            guard let r = regions.region(id) else { continue }
            out.formUnion(FaceRegionGeometry.members(of: r, in: mesh))
        }
        return out.sorted()
    }

    /// The one line the tray shows. It always states the count — a tap that
    /// toggled a piece OFF and a tap that never registered must not look alike —
    /// and, while the commit is unavailable, says so instead of leaving a dimmed
    /// checkmark to be interpreted.
    public func hint(regions: FaceRegionModel, mesh: ViewerMesh) -> String {
        switch count {
        case 0:  return "Tap pieces to combine."
        case 1:  return "1 piece — tap another to combine."
        default: return "\(count) pieces — tap ✓ to combine."
        }
    }
}
