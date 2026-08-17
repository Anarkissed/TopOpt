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
import CoreGraphics
import simd

public enum LatticeSlabExpand {

    /// ★ IT SHRINKS TOO (maintainer, 2026-08-17: "Can we make the expansion
    /// *also* take a negative value? I'd like to see us also be able to make it
    /// smaller in the x/y axis as well").
    ///
    /// So the floor is the ceiling's mirror rather than zero. ZERO keeps its
    /// meaning — "exactly the face" — and stays the value that clears the key,
    /// so every project written before this reads back identically.
    public static let minMM = -LatticeSlabDepth.maxMM
    /// A ceiling, so a runaway drag cannot swallow the part. Deliberately the
    /// same bound the depth uses: an in-plane reach and a depth are the same kind
    /// of quantity to a user, and two different ceilings would be a surprise.
    public static let maxMM = LatticeSlabDepth.maxMM

    /// ★ A SHRUNK SLAB STILL HAS TO BE A SLAB. A margin more negative than the
    /// face's own half-extent would invert it — a negative width is not a
    /// smaller region, it is a region that has stopped being one. The floor is
    /// applied per half-extent in `expanded`, not here, because only there is
    /// the face's own size known.
    public static let minHalfExtentMM = 0.05

    public static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(maxMM, Swift.max(minMM, v))
    }

    /// The half-extents a slab presents after expanding, in mm. Pure so the
    /// growth is testable without a view — and so "in plane only" is a property
    /// of a function rather than of a comment.
    ///
    /// ★ A NEGATIVE MARGIN SHRINKS BOTH AXES and is floored per-axis, so a
    /// shrink past the face's own size collapses that axis to a sliver rather
    /// than turning it inside out. The two axes floor INDEPENDENTLY: a long thin
    /// face should keep its length when its width has already bottomed out.
    public static func expanded(halfUMM: Double, halfWMM: Double,
                                by expandMM: Double)
        -> (halfUMM: Double, halfWMM: Double) {
        let e = clamp(expandMM)
        return (Swift.max(minHalfExtentMM, halfUMM + e),
                Swift.max(minHalfExtentMM, halfWMM + e))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: ★ WHERE THE GRAB KNOB SITS

    /// ★★ THE HANDLE HAD NOWHERE TO BE (maintainer, 2026-08-17, reporting it a
    /// SECOND time: "Expand still does not work - still does not have a
    /// handle").
    ///
    /// ★ THE DEFECT, and it is a reading error, not a layout one. The first cut
    /// built the knob's offset direction from `ClearanceHandle.axisDir` — but
    /// that type states outright that "only the fields the role needs are
    /// populated; the rest stay zero", and a `.slabDepth` handle populates
    /// `planeOrigin`/`planeNormal`. **`axisDir` is ZERO on every lattice depth
    /// plane.** `simd_normalize(.zero)` is NaN, a NaN anchor projects to
    /// nothing, and the knob was never placed — while the visibility rule I
    /// spent the previous cut on was correct the whole time.
    ///
    /// So the offset is derived HERE, from the normal that is actually
    /// populated, and it REFUSES rather than producing NaN. A caller that hands
    /// in a degenerate normal gets `nil` and draws no knob, which is a visible
    /// absence instead of an invisible NaN.
    ///
    /// - Parameters:
    ///   - anchor: the depth knob's own anchor — the knob rides out from it.
    ///   - normal: the slab's face normal (`ClearanceHandle.planeNormal`).
    ///   - baseMM: the resting offset, so the two knobs never overlap at 0.
    ///   - expandMM: the current expand; the knob is literally on the edge it moves.
    public static func knobAnchor(anchor: SIMD3<Float>, normal: SIMD3<Float>,
                                  baseMM: Float, expandMM: Double)
        -> SIMD3<Float>? {
        let len = simd_length(normal)
        guard len > 1e-6, normal.x.isFinite, normal.y.isFinite, normal.z.isFinite
        else { return nil }
        let n = normal / len
        // Any unit vector perpendicular to the slab normal — the same basis rule
        // `LatticeRegionMask` uses, so the knob points along an axis that grows.
        // The seed is chosen away from `n` so the cross product is never short.
        let seed: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let cross = simd_cross(n, seed)
        let cl = simd_length(cross)
        guard cl > 1e-6 else { return nil }
        let u = cross / cl
        // ★ A SHRINK STILL PUSHES THE KNOB OUT. The offset is `base + |expand|`,
        // not `base + expand`: a negative margin must not walk the knob back
        // through the depth knob and out the other side. Direction of travel is
        // the same either way; what it MEANS is read off the number.
        let out = anchor + u * (baseMM + abs(Float(clamp(expandMM))))
        guard out.x.isFinite, out.y.isFinite, out.z.isFinite else { return nil }
        return out
    }

    /// ★★ THE TWO KNOBS MUST NOT TOUCH (maintainer, 2026-08-17: "The 'expand'
    /// handle needs to be at least 1 cm away from the depth handle - preferably
    /// more. Currently it is touching").
    ///
    /// ★ AND THE SEPARATION HAS TO BE IN *SCREEN* SPACE, which is the reason
    /// the millimetre offset alone was never going to hold. `knobAnchor` puts
    /// the knob a fixed number of MILLIMETRES out along the face; how far apart
    /// that lands ON SCREEN depends entirely on the zoom. Framed to the whole
    /// part, 8 mm is a few points and the two 44 pt targets overlap — which is
    /// exactly what he saw. Raising the millimetres would fix one zoom level
    /// and break another.
    ///
    /// So the millimetre offset stays (it is what makes the knob ride out with
    /// the value), and this is a floor applied AFTER projection: if the two
    /// projected points are closer than `minimumPT`, the expand knob is pushed
    /// out along the line between them until they are exactly that far apart.
    /// A degenerate coincidence falls back to due right, so there is no case
    /// where the knob has no direction to go.
    public static let knobSeparationPT: Double = 72     // ★ ~1 cm on screen, and then some

    public static func separated(knob: CGPoint, from depth: CGPoint,
                                 minimumPT: Double = knobSeparationPT) -> CGPoint {
        let dx = Double(knob.x - depth.x), dy = Double(knob.y - depth.y)
        let d = (dx * dx + dy * dy).squareRoot()
        guard d.isFinite, minimumPT > 0 else { return knob }
        if d >= minimumPT { return knob }
        // Coincident (or as good as): pick a direction rather than divide by ~0.
        let (ux, uy) = d > 1e-6 ? (dx / d, dy / d) : (1.0, 0.0)
        return CGPoint(x: depth.x + CGFloat(ux * minimumPT),
                       y: depth.y + CGFloat(uy * minimumPT))
    }
}
