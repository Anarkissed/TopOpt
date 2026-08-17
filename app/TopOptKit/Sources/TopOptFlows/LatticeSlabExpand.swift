// LatticeSlabExpand.swift — ★ GROW THE SLAB PAST THE FACE IT CAME FROM
// (maintainer, 2026-08-17).
//
// ★ HIS WORDS: "the primitives are the same shape as the face that they are
// derived from. I'd like a way to expand them with a handle to be able to get
// the outside walls that might be otherwise impossible to get latticed (i.e. the
// chamfer)."
//
// ★ AND HIS AXES, VERBATIM: "I would just create an expand handle for all the
// other axis *except* the depth that was set (so x and y). It needs to expand
// outward." So this is ONE number — an outward margin added to BOTH in-plane
// half-extents — and it never touches the depth, which has its own control, its
// own handle, its own detents and its own tie to the protection.
//
// ★ WHY ONE NUMBER AND NOT TWO. A slab's in-plane axes are the face's own fitted
// u/v, which have no stable meaning to a user looking at a chamfer: "u" is
// whichever way the fit happened to land. A single outward margin is the thing
// he can actually aim — "reach 3 mm further in every direction" — and it is
// rotation-independent, so it survives the face being re-fitted.
//
// ★★ WHAT THIS DOES NOT DO, STATED RATHER THAN DISCOVERED LATER. The expand
// grows the LATTICE REGION, which is a geometric slab core evaluates pointwise.
// It does NOT grow the PROTECTION: core's `face_protections` are keyed by FACE
// ID and masked by `mask_step_face`, which walks that face's own footprint —
// there is no margin on that call. So material outside the face's outline is
// latticed-if-present but NOT held against the optimizer, and TO may carve it
// away before the lattice pass sees it. The honest remedy is the one the app
// already has: protect the chamfer's own face too. `LatticeSlabExpandTests`
// pins this as a known boundary rather than leaving it to be found on a run.

import Foundation

public enum LatticeSlabExpand {

    /// No expand at all — the slab is exactly its face.
    public static let minMM = 0.0
    /// A ceiling, so a runaway drag cannot swallow the part. Deliberately the
    /// same bound the depth uses: an in-plane reach and a depth are the same kind
    /// of quantity to a user, and two different ceilings would be a surprise.
    public static let maxMM = LatticeSlabDepth.maxMM

    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return minMM }
        return Swift.min(maxMM, Swift.max(minMM, v))
    }

    /// The half-extents a slab presents after expanding, in mm. Pure so the
    /// growth is testable without a view — and so "in plane only" is a property
    /// of a function rather than of a comment.
    public static func expanded(halfUMM: Double, halfWMM: Double,
                                by expandMM: Double)
        -> (halfUMM: Double, halfWMM: Double) {
        let e = clamp(expandMM)
        return (halfUMM + e, halfWMM + e)
    }
}
