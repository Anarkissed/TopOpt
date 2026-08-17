// SurfaceSimilar.swift — ★ SELECT-SIMILAR IS A MULTI-SELECT OF *RULES*.
//
// Maintainer, 2026-08-16:
//
//   "I think Select-similar should *also* have multi-select. It should be able to
//    select multiple similar groups of faces (and another tap de-selects it)"
//
//   "What exactly does the checkbox of the 'select-similar' do? In my mind it
//    shouldn't be there. The select-similar should only be to add a tool's action
//    to all the similar faces or to cut them out as a group/individual faces."
//
// ── WHAT THE TOOL IS, AFTER THIS ─────────────────────────────────────────────
//
// ★ IT SELECTS. It does not commit anything of its own. Tap a face and every face
// like it joins the selection; tap another and its kind joins too; tap a selected
// one and its kind leaves. Then either
//
//   * ✂ cuts the selection out into its own pieces, or
//   * you pick another tool, and that tool acts on everything selected.
//
// The ✓ used to make a filter-defined UNION region of every match — one row, one
// role, one depth. That is a real thing the Regions sheet can still do, but as the
// FIRST answer to "these faces are alike" it is the wrong one: it welds them
// together, and the maintainer's actual want is the opposite, to get at them
// individually. Removed rather than kept as a second confusing verb.
//
// ── WHY A LIST OF FILTERS AND NOT A SET OF FACES ─────────────────────────────
//
// ★ THE FILTER IS THE MEMBERSHIP. PR 331 measured what storing the matches costs:
// a union becomes "a stale id list wearing a filter's clothes", and a simulated CAD
// edit grew a 24-face union to 32. The same holds for a multi-select — so this
// holds the RULES, and the faces are re-derived every time they are asked for.
//
// Pure value type; no mesh, no view. `matches(in:)` is the only thing that needs
// geometry and it takes it as an argument.

import Foundation
import TopOptKit

public struct SurfaceSimilar: Equatable, Sendable {

    /// One tap's worth: the face that was tapped and the rule derived from it.
    public struct Pick: Equatable, Sendable {
        public let seed: FaceID
        public let filter: RegionFilter
        public init(seed: FaceID, filter: RegionFilter) {
            self.seed = seed
            self.filter = filter
        }
    }

    public private(set) var picks: [Pick] = []

    public init() {}

    public var isEmpty: Bool { picks.isEmpty }
    public var count: Int { picks.count }
    public var seeds: [FaceID] { picks.map(\.seed) }

    /// ★ TAP TO ADD A KIND, TAP AGAIN TO DROP IT.
    ///
    /// `matched` is what the tapped face's rule already resolves to — the caller
    /// has the mesh, so it does the matching. A tap on a face ALREADY covered by
    /// one of the picks removes THAT pick, whichever one it is: a second tap has to
    /// undo the first even when the face tapped the second time is not the one that
    /// was tapped the first time. Keying on the seed alone would leave every other
    /// face of a kind unable to switch its own kind off.
    public mutating func toggle(seed: FaceID, filter: RegionFilter,
                                covering: (Pick) -> Set<FaceID>) {
        if let i = picks.firstIndex(where: { covering($0).contains(seed) }) {
            picks.remove(at: i)
        } else {
            picks.append(Pick(seed: seed, filter: filter))
        }
    }

    public mutating func clear() { picks = [] }

    /// Every face any pick matches, re-derived. Never cached — see the header.
    public func matches(in mesh: ViewerMesh) -> Set<FaceID> {
        var out: Set<FaceID> = []
        for p in picks { out.formUnion(FaceRegionGeometry.match(p.filter, in: mesh)) }
        return out
    }

    /// The one line the tray shows. It names the number of KINDS as well as the
    /// number of faces once there is more than one kind, because "12 like this" on
    /// a two-tap selection reads as one rule that has run away.
    public func hint(in mesh: ViewerMesh) -> String {
        let n = matches(in: mesh).count
        switch (picks.count, n) {
        case (0, _):  return "Tap a face to select the ones like it."
        case (1, 1):  return "Only this one is like it — ✂ isolates it."
        case (1, _):  return "\(n) like this — ✂ isolates, or pick a tool."
        default:      return "\(n) faces, \(picks.count) kinds — ✂ isolates, "
                           + "or pick a tool."
        }
    }
}
