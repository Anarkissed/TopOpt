# 093 — Savings % vs mass disagreement at 128³: diagnosis + fix spec

Status: **DIAGNOSED (read-only). No code changed.** This is the fix spec. The
`git diff` for this branch is this file only.

Territory read: `/core/` (`minimize_plastic.cpp`, `simp.cpp`, `voxelize.cpp`,
`step.cpp`) and `/app/` for how the number is displayed (`ResultsModel.swift`,
`bridge.cpp` — read only; a concurrent task owns `core/src/cli/`, `bridge.cpp`,
`RunModel.swift`, so nothing there was touched). Measurement harness is scratch,
not committed.

---

## TL;DR — the 178 g is NOT frozen material and NOT a mask class

The displayed % and the mass are computed from **two different measures of the
same field**:

- **Savings %** = `1 − achievedVolumeFraction` (`ResultsModel.swift:1480`).
  `achievedVolumeFraction` is the core's **continuous** active volume fraction
  `Σρ / n_active` (`simp.cpp:1299-1303,1431`), which the volume constraint drives
  to the **ladder target**. So the % shown is exactly `1 − vf_target` — a target,
  not a measurement.
- **Mass** = `density · (#{ρ > 0.5}) · voxel_volume` — a **thresholded voxel
  COUNT** of the printed shape (`minimize_plastic.cpp:474-516`).

These two agree only when the printed field is crisp 0/1. The production ladder
runs **MMA with no Heaviside projection** (`bridge.cpp:189-204`,
`simp.cpp:73-76` reject MMA+projection), so the physical density is a **grayscale
ramp ~1 filter-radius wide** (`bridge.cpp:206-214` says exactly this). Every voxel
in that ramp with `0.5 < ρ < 1` counts as a **whole** printed voxel in the mass
but contributes only `ρ` to the volume fraction. **The COUNT exceeds the
FRACTION by the gray content**, and that excess is what shows up as the "178 g
floor." It is real, printed plastic — the mass is right; the savings % is the one
telling the untruth.

The "floor" is resolution-dependent because the 128³ design is far lacier (finer
members permitted by the tighter min-feature filter → vastly more gray interface
per unit volume) than the chunky, near-crisp 64³ design.

**The 178 g is not a protected region and not a bug in what is frozen. It is a
reporting-basis mismatch — the same class of bug handoff 080 fixed, in the branch
080 did not cover (no design box).**

---

## STEP 1 — What is the 178 g?

### The arithmetic (irrefutable, straight off the device data)

The device masses fit `mass = 178 + vf·690` g to within 1 g. Restated against the
part (868 g) and the displayed fraction:

| rung | vf (=target) | displayed | mass (g) | printed/part = mass/868 | **gap = printed/part − vf** |
|-----:|-------------:|----------:|---------:|------------------------:|----------------------------:|
| 0 | 0.68 | −32% | 647 | 0.745 | **0.066** |
| 1 | 0.52 | −48% | 538 | 0.620 | **0.100** |
| 2 | 0.38 | −62% | 440 | 0.507 | **0.127** |
| 3 | 0.26 | −74% | 357 | 0.411 | **0.152** |

The gap is not constant — **`gap = 0.205 · (1 − vf)` to 3 decimals on every
rung.** That is the signature, and it is decisive:

- **It rules out a fixed frozen set.** A frozen mask of N voxels would add a
  *constant* `N/part` to `printed/part` at every rung. Instead the excess **grows
  as `(1 − vf)`** — biggest when the part is lightest and laciest. That is the
  fingerprint of gray content, not of pinned material.
- **The constant "178 g floor" is just the y-intercept.** `printed = vf·part +
  0.205·part·(1−vf) = 0.205·part + vf·0.795·part` → intercept `0.205·868 = 178`,
  slope `0.795·868 = 690`. Extrapolating the gray-excess line to vf=0 *looks* like
  a 178 g floor; nothing is actually frozen at 178 g.
- **It rules out non-convergence.** The displayed % is *exactly* `1 − vf_target`,
  so `Σρ/n_active = vf` exactly — the volume constraint **is** satisfied. The
  optimizer hit its target volume. The only way the COUNT can exceed that met
  volume is fractional (gray) densities above 0.5.

At 64³ the same gap is ≈ 0 on both maintainer rungs (587 g @ 0.68, 448 g @ 0.52
⇒ intercept ≈ −4 g, slope ≈ 869 g = the part). The 64³ design is crisp enough
that COUNT ≈ FRACTION.

### (a) Voxel counts per mask class — the requested measurement

Built the library (Eigen absent, OCCT present) and measured the mask classes on
the reduction-ladder L-bracket (Fixture top face, Load foot end, 3-voxel
FrozenSolid anchor pad — assembled exactly as `bridge.cpp:806-814` +
`test_designbox_anchor_pad.cpp`), at a 64-equivalent grid and a 128-equivalent
grid of the **same physical part** (scratch harness `measure.cpp`):

| grid | solid voxels | **FrozenSolid** (pad ∪ Load ∪ Fixture) | Active | frozen % |
|------|-------------:|---------------------------------------:|-------:|---------:|
| 64-equiv (64×20×48) | 12 720 | 480 (Fixture 120, Load 120, pad 240) | 12 240 | **3.8 %** |
| 128-equiv (128×40×96) | 101 760 | 1 920 (Fixture 480, Load 480, pad 960) | 99 840 | **1.9 %** |

`FrozenVoid` and `Empty`-inside-part are 0 with no design box and no keep-outs.

**No mask class accounts for the 20 %.** `FrozenSolid` is ~2 % and it **halves**
(3.8 → 1.9 %) as resolution doubles — the exact opposite of the observed floor
(0 → 20 %). Everything else the ladder touches is `Active`. So the answer to "which
class is ~20 % at 128³ and ~0 % at 64³?" is: **none of them.** The 20 % lives
inside the `Active` region, as gray voxels the *count* over-reads.

### (b) The anchor pad — REFUTED, with numbers

`mask_step_face(..., FrozenSolid, kAnchorPadDepthVoxels=3, ...)`
(`step.cpp:270-318`, `bridge.cpp:153,806-814`) freezes a **fixed 3-voxel-deep**
slab behind each anchor/load face. Its voxel count scales as `3 · A/h²` (slab
area ÷ voxel face), while the part scales as `V/h³`, so the **pad fraction scales
∝ h — it HALVES at 128³.** The measurement confirms it (3.8 → 1.9 %). The pad (and
the 1-voxel Load/Fixture BC skin, same scaling) is therefore both too small (~2 %,
not 20 %) and moving the wrong way (shrinking, not growing). **The arithmetic said
the pad should not be it, and the measured voxel counts agree: it is not.**

### (c) The other candidates

- **1-voxel Load/Fixture BC skin (`effective_mask`, `simp.cpp:932-950`).** Same
  `A·h` slab scaling as the pad; measured as the Fixture+Load rows above (~1 % of
  solid). Not it.
- **`keep_largest_and_marked_components` / `load_fixture_islands`
  (`voxelize.cpp:494-498`).** Mesh cleanup for the *exported/displayed* surface.
  The mass counts `#{ρ>0.5}` on the solved grid (`minimize_plastic.cpp:474-481`)
  regardless of connectivity, so island retention never enters the mass. Not it.
- **Thin walls under-resolved at 64³, resolved at 128³ (voxelizer,
  `voxelize.cpp:204-330`).** Real, and it is *why* the 128³ topology is lacier —
  but a newly-resolved wall becomes `Active` (removable), not frozen; it changes
  `part_solid` (baseline), which is stable here (863 vs 868 g). It contributes to
  the floor only indirectly, by giving the optimizer finer features to fill with
  gray. Mechanism enabler, not a frozen class.
- **The min-feature filter (`min_feature_mm = 2.5` → `physical_filter_radius`,
  `bridge.cpp:203`).** **This is the mechanism.** rmin = 1.5 vox **floored** =
  4.69 mm at 64³ vs 1.6 vox = 2.5 mm at 128³. The tighter 128³ filter permits
  ~2.5 mm ≈ 1.6-voxel members. A member only ~1.6 voxels wide, filtered by a
  1.6-voxel kernel, **never reaches ρ = 1 at its core** — the whole member is gray
  yet entirely above 0.5, so it is counted 100 % into the mass while contributing
  only ~0.6–0.7 to the volume fraction. The 64³ design, chunky under the 4.69 mm
  floored filter, has member cores that hit ρ = 1 → crisp → COUNT ≈ FRACTION. This
  is exactly the resolution split the data shows, in the right direction. (This is
  the same grayscale ramp `bridge.cpp:206-214` and handoff 086 both describe.)

### (d) Legitimate region, or bug?

**Neither "legitimate protected region" nor "wrong thing frozen."** The 178 g is
**real printed plastic** — the mass is correct. The **bug is the savings %**: it
reports `1 − vf_target` (a continuous-fraction target the constraint always hits),
which is blind to the gray plastic the print actually lays down. The user reads
"−74 %" and gets a part that is 357/868 = **41 % of the original mass = −59 %
real**. The number is honest arithmetic on the wrong quantity.

---

## STEP 2 — What should the % mean?

### (a) What is displayed today

`ResultsModel.swift:1480`: `savings = 1 − v.achievedVolumeFraction`, rendered as
`"−pct%"` (`:1489`). `achievedVolumeFraction` is set from the core's
`optimization.volume_fraction` (`bridge.cpp:257`), which on the **no-box path is
`active_volfrac = Σρ/n_active`** (`simp.cpp:1431`) — the continuous fraction that
converges to the ladder target.

Handoff 080's fix — overwrite `optimization.volume_fraction` to
`printed_voxels / part_solid` — **fires only when `part_relative` is true**, and
`part_relative = expanded && !freeze_imported_part` (`minimize_plastic.cpp:303,
536-538`). With **no design box `expanded == false`**, so the overwrite is
skipped and the no-box path still ships the target-tracking `active_volfrac`.
**This is precisely the branch 080 did not cover, and it is the bug.**

### (b) What it should be

The honest number is the one the maintainer means — *printed mass vs original
part mass*:

```
honest_savings = 1 − printed_mass / part_mass
              = 1 − printed_voxels / part_solid      (same voxel count as the mass)
```

Because it is built from the **same `#{ρ>0.5}` count the mass already uses**, the
% and the mass become two views of one number and can no longer disagree. This is
identically 080's `printed_voxels / part_solid`, just applied to the no-box branch
too. **The core owns it** — `minimize_plastic` is the only side that has both
`printed_voxels` and `part_solid` (`grid.solid_count()`); the app's
`1 − achievedVolumeFraction` is then correct *given* a part-relative fraction (it
is already exactly right on the box path since 080).

Honest numbers for the device rungs: −25 %, −38 %, −49 %, −59 % (vs the shown
−32 %, −48 %, −62 %, −74 %).

---

## STEP 3 — Recommendation (ranked)

**The one rule for the implementer:** Gate-V2 must stay green and the 080 box path
must not regress (`designbox_reduction` stays green). The change is confined to the
no-box branch; the box branch already does this.

### Rank 1 (recommended) — extend 080's part-relative fraction to the no-box path

In `minimize_plastic.cpp`, make `optimization.volume_fraction` report
`printed_voxels / part_solid` on the **no-box path as well**, so the app's existing
`1 − achievedVolumeFraction` becomes `1 − printed/part` everywhere.

- Today `part_relative` is `expanded && !freeze_imported_part`
  (`minimize_plastic.cpp:303`). With no box, `part_solid = grid.solid_count()`
  (`:304`) already equals the whole part, and `printed_voxels` (`:474-481`)
  already counts the printed shape on that same grid. So the existing overwrite
  block (`:536-538`) is correct as-is for the no-box case — it only needs to be
  **reached** when `!expanded`.
- Concretely: introduce `report_part_relative = !expanded || (expanded &&
  !freeze_imported_part)` for the **reporting overwrite only** (`:536-538`). Do
  **not** change the *budget* rescale (`:376-381`), which must stay box-only — on
  the no-box path the rung target is already `vf` of the whole part, so rescaling
  there would change what the optimizer solves and move Gate-V2. Only the reported
  fraction changes; the solve is byte-identical.
- Result: savings and mass agree at every resolution by construction; 64³ is
  visually unchanged (it was already ≈ crisp, so `printed/part ≈ vf`); 128³ now
  shows the honest −25/−38/−49/−59 % instead of the target.

### Rank 2 — compute savings in the app from mass and a reported part mass

Have the core additionally report `part_mass_grams` (or `part_solid`) up through
the bridge, and let the app show `1 − massGrams / partMassGrams`. Same honest
result, but it moves the definition into the app and duplicates state the core
already owns; prefer Rank 1 so there is a single source of truth.

### Rank 3 (do not ship alone) — crisp the field so COUNT ≈ FRACTION

Enable MMA + Heaviside projection (the deferred "Option A", `bridge.cpp:190-197`)
so the printed field is ~0/1 and the two measures reconverge without redefining
the %. This is a real optimizer change (currently rejected, `simp.cpp:73-76`),
risks Gate-V2, and still leaves the *definition* wrong (target-based). It is a
legitimate quality improvement but not the fix for this bug.

### Regression test (both paths)

For a part with a **known gray/lacy printed field** at fine resolution, assert the
displayed % equals `1 − printed_mass / part_mass` on **both** the box and no-box
paths:

```
displayed_fraction == printed_voxels / part_solid        (no-box path)   // NEW: currently target
displayed_fraction == printed_voxels / part_solid        (box path)      // 080, must stay green
```

Add it beside `test_designbox_reduction.cpp` (e.g. `savings_part_relative`): run
the ladder with `min_feature_mm = 2.5` on a grid fine enough that
`#{ρ>0.5}` measurably exceeds `Σρ` (i.e. `achieved_active_volfrac < printed/part`),
and CHECK that `1 − reported_fraction == 1 − printed/part` — a value that would
FAIL today on the no-box branch (it reports `1 − active_volfrac`). Keep
`designbox_reduction` and Gate-V2 in the same run to prove no regression.

---

## Interaction with 086-surface-resample (the mesh-vs-voxel mass gap)

**Independent root, do not couple the fixes — but keep the basis consistent.**

- 086 found the **voxel-count mass** disagrees with the **exported mesh volume** by
  ~4.2 % on a lacy part (582.99 g voxel vs 559.39 g 2×-mesh). Both that gap and
  this bug come from the *same* grayscale field, but they are different comparisons:
  086 is *voxel-count vs mesh volume*; this is *voxel-count savings-basis vs
  voxel-count mass* — a **savings-vs-mass** mismatch, not a mass-vs-mesh one.
- The Rank 1 fix uses the **voxel count for both numerator and denominator**
  (`printed_voxels / part_solid`), so any thresholding over-count cancels in the
  ratio. The fix therefore does **not** need 086 and is unaffected by it.
- The one coupling to respect: **the % and the mass must share a basis.** Today
  both are voxel-count based, so Rank 1 keeps them aligned. **If** the maintainer
  later adopts 086's suggestion to make the displayed *mass* mesh-volume based,
  then the savings denominator/numerator must move to mesh volume too, or this
  disagreement reopens in a new form. Fix this one now on the voxel-count basis;
  revisit together only if mass ever switches to mesh volume.

---

## Evidence / reproduction

- Arithmetic: the per-rung table above is computed directly from the device masses;
  `gap = 0.205·(1−vf)` holds to 3 decimals on all four rungs.
- Mask-class counts: scratch `measure.cpp` linked against `libtopopt.a` (built
  without Eigen; voxelizer + mask logic are Eigen-free). Reproduces the L-bracket
  of `test_designbox_anchor_pad.cpp` at two resolutions and counts
  FrozenSolid/Active. Not committed.
- Code trace: `ResultsModel.swift:1480` (savings basis), `bridge.cpp:257` (fraction
  source), `simp.cpp:1299-1303,1431` (`active_volfrac`), `minimize_plastic.cpp:474-
  516` (voxel-count mass), `:303,536-538` (080 part-relative, box-gated),
  `bridge.cpp:189-204` (MMA → no projection → gray field), `simp.cpp:73-76` (MMA +
  projection rejected).

No ROADMAP box checked. No code changed.
