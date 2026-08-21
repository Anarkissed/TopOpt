# What his adaptive-layer 3MF says, and what we should export

Source: `AdaptiveLayers_gradedLattice.3mf` (13 MB, Bambu/Orca project), the graded
coupon with variable layer height set by hand in the slicer. Profile read from
`Metadata/layer_heights_profile.txt`, settings from `Metadata/project_settings.config`.
Raw profile kept as `coupon/his_adaptive_layer_profile.txt`.

## The measured profile

One object, 409 control points, z 0 .. 41.55 mm — which matches the coupon's own
41.58 mm height, so this is our geometry.

| | |
|---|---|
| base setting `layer_height` | 0.12 mm |
| `max_layer_height` | 0.28 mm |
| profile min / max | **0.080** / 0.280 mm |
| mean / median | 0.1024 / 0.1014 mm |
| control points at or below 0.085 mm | **37.7 %** |

★ **ABOVE THE BASE SLAB (z > 2 mm) THE PROFILE IS ESSENTIALLY FLAT:**

    mean 0.1000 mm,  sd 0.0191,  p05 0.080,  p95 0.139

and the per-band means are 0.100, 0.100, 0.101, 0.100, 0.100, 0.100, 0.100, 0.097
across z 5-45 mm. The 0.28 max and the 0.12-0.24 values all sit in the first 2 mm —
they are the SLAB, not the lattice.

## ★ THE FINDING THAT SIMPLIFIES THE FEATURE

Adaptive layer height on a lattice **converges to a near-constant fine value**. It does
not produce an interesting z-gradient, because a lattice's overhang character is
statistically uniform in z — every layer looks much like the last. sd 0.019 mm about a
0.100 mm mean.

**So a SINGLE recommended layer height captures almost all of the benefit**, and the
full per-z profile is optional polish. That turns "emit an adaptive profile" from a
vendor-coupled chore into a one-number recommendation we can compute and state.

## We can DERIVE the number, not guess it

From the print-result note: `tan(th_max) = c · W / h`, so

    h_max = c · W / tan(th_steepest)

and the law already knows `th_steepest` — it emitted every strut. At the coupon's
W = 0.42 mm, the steepest STACKING strut (below the single-layer bridge boundary)
implies h in the 0.08-0.12 band, which is exactly where the slicer's own adaptive
algorithm landed. Independent agreement between our geometry and his slicer.

## What to export, and the honest split

1. **A NOTE, portable, any slicer.** Recommended layer height (one number, derived),
   recommended orientation, and the reason. Costs nothing and couples to nothing.
2. **The ORIENTATION, applied by us.** Already reachable: `build_orientation.hpp` +
   `bake_build_orientation` exist and the bake path ships. A lattice's printability
   depends on the build axis through the same `th` — so the orientation we recommend
   and the orientation we bake must be the same one, or the note is wrong.
3. **The per-z PROFILE, vendor-specific.** `Metadata/layer_heights_profile.txt` is
   Bambu/Orca, NOT standard 3MF. Writing it couples our export to one slicer family.
   Given the profile is flat (above), the value is low and the coupling is real — so
   this is the piece to defer, not the piece to lead with.

★ **THE BLOCKER IS PLUMBING, NOT ALGORITHM.** `app/.../PrintParams.swift:16` records
that `layerHeightMM` is *"CAPTURED BUT NOT WIRED"* — the user already sets it, it is
persisted on the project, and it never reaches core. Core has no layer-height parameter
at all. Until that exists, the law cannot compute `h_max` because it does not know `h`,
and cannot check its own output against the printer it is being sent to.

## One more thing the settings file shows

`detect_overhang_wall 1` with the overhang speed ladder active — 50 / 30 / 10 % of
normal speed on progressively worse overhangs, and `filament_bridge_speed 25`. The
slicer was already slowing hard on exactly the segments in question. That is part of
why the coupon printed, and it belongs in the recommended-settings note too: a lattice
wants overhang slowdown ON.
