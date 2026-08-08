# closing-flow-and-the-field — adding material does not remove your staircase either, and the density field has nothing left to give. Two NO-GOs, both measured, nothing built.

**Slug:** `closing-flow-and-the-field` · **Branch:** `claude/closing-flow-measurement-d609fa`
**Evidence:** `evidence/2026-08-08-closing-flow-and-the-field/`
**Changes:** test harnesses only. **No production file changed** — see R1.
**CI:** core-linux + app-macos. `materials.json` untouched. `app/` untouched.
**Required reading it builds on:** PR 299 (Taubin NO-GO), 303 (SDF), 306 (the sphere
bake-off), 307 (CAD projection + the classifier), 314 (MCF NO-GO on his part —
**not yet merged**, see R1).

---

# 0. WHAT CHANGES FOR YOU

Nothing ships. Two questions were asked and both came back NO, and the second one
closes a door that has been standing open since PR 299.

## ★ ADDING MATERIAL DOES NOT REMOVE YOUR STAIRCASE. And this time the reason is a property of your part, not of the operator.

The three failed attempts so far — Taubin, SDF/RBF, mean-curvature flow — are all
**filters**. The maintainer's proposal was an operator that **adds mass**, which is
morphological closing, and the literature agrees it is the right family: Sellán,
Kesten, Ang Yan Sheng & Jacobson (SIGGRAPH Asia 2020) name classic mean curvature
as the wrong tool by name.

**It does not help, and here is the number that says it cannot.** A closing at
radius r fills every concavity a ball of radius r cannot roll into, and leaves
everything else exactly where it was. So the question is not "how well does it
work" but "what can it even touch". On your rung-068 optimizer-cut surface:

| ball radius | how much of your cut surface it reaches |
|---|---|
| 0.25 mm (0.15 voxel) | **0.00%** |
| 0.50 mm (0.29 voxel) | 0.01% |
| 1.00 mm (0.59 voxel) | 0.28% |
| **1.71 mm (one whole voxel)** | **3.17%** |
| 3.41 mm (two voxels) | 11.04% |
| 6.82 mm (four voxels) | 14.34% — and it has stopped climbing |

**34.55% of that surface is CONVEX** — it has no concavity at all, so no closing at
any radius will ever touch it. Of the rest, the median concavity is so shallow that
only a ball of **radius 454.9 mm** would reach its floor; your part's solved grid is
218 mm on its longest axis.

**Your staircase is not made of crevices.** It is a terrace — wide flats joined by
wide risers, 0.34 mm deep on a 1.71 mm voxel. That is a very *obtuse* concavity,
and an obtuse concavity is exactly what a closing is built to leave alone. Same on
all four rungs (§S1.1).

Everything downstream agrees. On the surface where "how much staircase was removed"
has a truthful answer, **on all four rungs**:

| | closing, stable form | closing, aggressive form | Taubin 20 / 160 |
|---|---|---|---|
| rung 068 | **0.0%** at every radius | −0.3% / −4.4% / −8.8% / **−11.7%** | +2.5% / **+8.0%** |
| rung 026 | **0.0%** at every radius | −0.3% / −3.9% / −5.9% / **−7.9%** | +1.9% / **+6.2%** |

The stable form removes nothing because it can reach nothing; the aggressive form is
worse than doing nothing, and gets worse the harder you push it.

## ★ AND YOUR DENSITY FIELD DOES NOT HOLD THE DETAIL THE MESH LOST.

This was the bigger of the two questions and it now has a clean answer, on three
independent readings:

1. **The field is binary where it matters.** Of the boundary voxels — the only ones
   that place a surface — **96.6%** sit at one end of the density band or the other.
   Strictly in between: **3.41%** (rung 068), 3.97 / 4.73 / 4.77% on the others.
2. **Marching cubes already has nothing to interpolate.** On the design lattice,
   **91.05% of the surface crossings** place their point within 1% of the edge
   midpoint — a midpoint is a staircase. The whole sub-voxel placement the field
   still supports is **rms 0.1037 mm**, against a staircase of **0.3424 mm**.
3. **★ Your exported surface is ALREADY exactly on the field's 0.5 level set.**
   Residual **rms 0.000000 mm**. That is the size of the opportunity, and it is zero.
   A vertex-position optimisation against the field — the Wedekind analogue the
   brief asked for — accordingly recovers **0.2%**, then **−0.0%**, then **−0.1%**.
   (§S2.4 says why that zero is an identity rather than a lucky reading, and why it
   still answers the question.)

**So the information is genuinely gone, and resolution really is the only lever.**
The brief said that answer was worth the day on its own. It is now measured rather
than suspected, and it retires the whole "recover it from the field" idea.

## Two smaller things, both of which cost someone an hour if not written down

* **The brief's premise about the projection is wrong in the file.** It says
  `conditional_projection_fired: [false, true, true, true]`. `run_info.json` for
  this run says **`[true, true, true, true]`** — all four rungs projected, with
  measured Mnd 0.194–0.343 against a 0.07 threshold. §S2.0.
* **The control caught a real defect in my own code before it could reach a table.**
  §S1.0. It is worth reading because the defect was *copying a constant out of the
  reference implementation*, which is the exact failure the shared-instrument-header
  rule exists to prevent.

**Nothing was built.** `git diff main -- core/src core/include app/TopOptKit/Sources`
is empty, and the command is shown in R1.

---

# 1. S1 — THE CLOSING FLOW. **NO-GO.**

New harness: `core/tests/harness/closing_flow_probe.cpp`.

```
./core/build/closing_flow_probe <design.bin> <part.step> <evidence_dir>
```

Run on your `design.bin` and `M2_verticalStand.step` from
`evidence/2026-08-03-multiscale-lattice-to`, res 128, voxel 1.705279 mm, export
factor 2 → tessellation cell 0.852640 mm, C1 half-cell 0.426320 mm.

**PR 307's classifier, not a second one** — `attribute_to_cad_faces` with
`cad_project_options_for_grid(1.705279)`, exactly as PR 307 and PR 314 call it.
**PR 314's metric, not a second one** — `stairstep_metric.hpp` and
`surface_instruments.hpp` are *included*, not retyped, so these rows land in
PR 314's table (R2).

## S1.0 — THE SIGN CONTROL FIRED, AND WHAT IT CAUGHT

The whole operator turns on one predicate, `κ_min < −1/r`. Get the sign or the
scale of κ_min wrong and it selects **ridges** instead of **valleys**, and every
table below is confidently backwards. So the probe reads a known answer off a known
shape first and **exits 3** rather than continuing.

It fired on the first run: a sphere of radius 5 mm read κ = +0.0987/+0.1499 where
+0.2 was required. Two defects, and the second is the interesting one:

1. **The coefficient was half.** The Python reimplementation writes the per-edge
   mean-curvature contribution as `0.5*0.5*0.5*(pi-A)*l` = ⅛ to each endpoint. That
   constant was copied. **It is wrong in this mass convention:** summing the
   per-vertex form over all vertices counts each edge twice, so
   `Σ_v H_int(v) = ½ Σ_e |e| β_e`, which is Cohen-Steiner & Morvan's estimate of
   `∫H dA` and must come to 4πR on a sphere. With ⅛ it comes to 2πR. The
   reference's ⅛ pairs with a different mass matrix downstream. **Copying a
   constant across conventions is the "agrees in spirit" failure the shared-header
   rule exists to stop, and it happened here anyway.**
2. **The control itself was read wrong** — as a min and a max over vertices, on an
   octahedron-subdivision sphere whose triangles are strongly non-uniform. That
   reads the worst-shaped corner of the tessellation, not the operator. The
   assertion moved onto the two quantities the continuous identities pin exactly:
   the area-weighted means, Cohen-Steiner & Morvan for `∫H dA = 4πR` and
   Gauss-Bonnet for `∫K dA = 4π`.

After both fixes, on both radii: κ_mean within **0.2%** of 1/R, Gaussian curvature
within **0.2%** of 1/R², area within 0.3%.

**And there is a negative control, because two convex bodies selecting nothing
would pass an operator that selects nothing EVER.** A concave 90° seam must be
selected, and is (13 of 13 seam vertices). Both directions, every run.
Full text: `evidence/.../s1_sign_control_caught_it.txt`.

## ★ S1.1 — WHAT SHAPE IS THE STAIRCASE, AS A CLOSING SEES IT?

**This is the deciding reading, and it does not depend on a single discretization
choice in my file.**

A closing at radius r moves exactly the vertices whose local concavity is tighter
than the ball — whose **crevice radius** `−1/κ_min` is below r. Measured on the
optimizer-cut population, before any operator runs:

| rung | cut vertices | CONVEX (no crevice at all) | reached at r = ½ voxel | at 1 voxel | at 2 voxels | at 4 voxels |
|---|---|---|---|---|---|---|
| 0.68 | 25,175 | **8,698 (34.55%)** | 70 (0.28%) | 798 (**3.17%**) | 2,780 (11.04%) | 3,611 (14.34%) |
| 0.52 | 36,384 | **12,410 (34.11%)** | 120 (0.33%) | 1,345 (**3.70%**) | 4,700 (12.92%) | 5,998 (16.49%) |
| 0.38 | 61,097 | **18,101 (29.63%)** | 236 (0.39%) | 2,356 (**3.86%**) | 8,629 (14.12%) | 11,339 (18.56%) |
| 0.26 | 67,594 | **20,190 (29.87%)** | 308 (0.46%) | 2,890 (**4.28%**) | 10,717 (15.85%) | 13,719 (20.30%) |

Crevice-radius quantiles over the *concave* remainder:

| rung | p01 | p10 | **median** |
|---|---|---|---|
| 0.68 | 1.0477 | 2.5572 | **454.88 mm** |
| 0.52 | 1.0660 | 2.5572 | **159.09 mm** |
| 0.38 | 1.0549 | 2.4761 | **72.74 mm** |
| 0.26 | 1.0462 | 2.2986 | **79.47 mm** |

**No rung has a p01 below 1.04 mm.** Even the tightest one per cent of the concave
cut surface needs a ball larger than half a voxel, and half a voxel is already the
whole trust region C1 allows.

**Read that against the staircase itself.** PR 299 measured its amplitude at rms
0.3424 mm on a 1.705 mm voxel — a terrace that is shallow and wide. Shallow-and-wide
is an *obtuse* concavity and an obtuse concavity has a *large* crevice radius, which
is precisely what a closing must not touch. Doubling the ball from one voxel to four
buys 3.17% → 14.34% and then stops climbing, so there is no radius that reaches the
staircase and stays smaller than the design's own features.

**★ AND THIS UNIFIES THE THREE PRIOR NO-GOs.** PR 299 found Taubin cannot reach the
terrace because it is *low-frequency*, inside the pass band. PR 314 found MCF makes
it worse because curvature flow rounds the *sharp* things, and the sharp things on
your part are the CAD edges, not the staircase. S1.1 finds a closing cannot reach it
because it is *not concave enough*. **Three operators, three different mechanisms,
one geometric fact: the staircase is a low-curvature, wide-terrace feature, and
every operator tried so far keys on curvature or on frequency.**

## S1.2 — FOUR ARMS, AND WHY THERE ARE FOUR

A NO-GO on a reimplementation that diverges where the reference does not would be a
statement about my file. So the operator is measured in four configurations:

| arm | what it is |
|---|---|
| `expl_C1on` | explicit step `dt·(−κ_min)` along the outward normal, `dt = 0.125·h̄²`, C1 at half a cell |
| `expl_C1off` | the same with C1 disarmed — what the operator does unrestrained |
| `expl_dt.025` | the same at a fifth of the time step, so a divergence cannot be blamed on step size |
| **`COUPLED`** | the active vertices as unknowns with everything else Dirichlet — **what the reference actually solves** |

**C1 here is C1 as this codebase defines it**, and that took a correction worth
recording. The first cut bounded only the *normal* component of a vertex's travel
from its original position. `surface_operator.hpp` defines C1 as **the axis-aligned
cube of half-width `trust_voxels · cell_mm` about the original position**, and the
two are not the same: a vertex whose normal has flipped (§S1.4) accumulates
*tangential* travel a normal-direction projection never sees, and can leave the cube
with every individual step passing the test. Both bounds are now applied, and the
cube's bite is reported separately (`C1 box clamps`) so the difference between them
is visible rather than assumed away.

**What is reproduced from the reference and what is not** is stated in the probe's
own header, not buried: κ_min from the discrete curvatures, the active-set
predicate `k < −bd` with `bd = 1/r`, the set recomputed every iteration, and
termination on an empty set are all reproduced. The **implicit solve** is
approximated by the `COUPLED` Jacobi sweep, and **remeshing is not done at all** —
because remeshing destroys the vertex correspondence that C4's bitwise identity,
the signed outward displacement and the per-vertex motion column are defined on.
Triangle quality is therefore **measured**, not assumed. Neither MATLAB, gptoolbox
nor a Python runtime was added to the build.

## S1.3 — THE TABLE, rung 068

**The two arms that bracket the answer are shown; `expl_C1off` and `expl_dt.025`
are cut from this block for width and are in `s1_closing_flow.csv` in full,
as are all four rungs.** 64 closing rows in total. Nothing is summarised away —
the two claims made below are checked against all 64, not against these ten.

```
operator             r_mm  iters  wall_s  cutmax  cutrms  cutmoved  cadmoved  dihed_b  dihed_a    vol%   mass_g   cad_rm%   inward
as exported          -     0    0.000  0.0000  0.0000         0         0     8.36     8.36   0.000    0.000     0.0%        0
Close_r0.50_expl_C1on 0.50   40   3.449  0.4263  0.0038         2         0     8.36     8.37   0.000    0.000     0.0%        0
Close_r1.00_expl_C1on 1.00   40   3.433  0.4708  0.0370       189         0     8.36     8.71   0.007    0.041     0.0%        0
Close_r1.71_expl_C1on 1.71   40   3.614  0.4836  0.1031      1491         0     8.36    10.62   0.064    0.354     0.0%        0
Close_r3.41_expl_C1on 3.41   40   3.598  0.6864  0.1475      4179         0     8.36    12.65   0.154    0.846     0.0%        2
Close_r0.50_COUPLED   0.50   40   3.978  0.0000  0.0000         0         0     8.36     8.36   0.000    0.000     0.0%        0
Close_r1.00_COUPLED   1.00   40   3.600  0.0179  0.0001         1         0     8.36     8.36   0.000    0.000     0.0%        0
Close_r1.71_COUPLED   1.71   40   3.984  0.4263  0.0033        25         0     8.36     8.37   0.000    0.001     0.0%        0
Close_r3.41_COUPLED   3.41   40   3.680  0.4263  0.0095       262         0     8.36     8.44   0.002    0.009     0.0%        0
Taubin_pairs_20       -      20   0.034  0.5093  0.1234     24218         0     8.36     8.30  -0.004   -0.021     0.0%        -
Taubin_pairs_160      -     160   0.126  0.7595  0.1866     25175         0     8.36     8.09  -0.032   -0.175     0.0%        -
```

**★ THOSE TWO TAUBIN ROWS ARE NOT MERELY COMPARABLE WITH PR 314's — THEY ARE ITS
ROWS.** `evidence/.../r2_reproduces_pr314_rows.txt`: all **8 shared rows** across all
four rungs, all **64 shared fields** (cut max, cut rms, cut moved, C4 violations,
dihedral before and after, volume before and after), **0 differing**. Same design,
same extraction, same classifier call, same included metric headers. That is what
R2's "so the rows are comparable" is worth when it is checked instead of asserted.

**And C1's box does real work.** At r = 3.41 it fires **5,393 times** on rung 068
and pulls the maximum cut motion from **4.3688 mm** (normal-bound only, the first
cut of this probe) down to **0.6864 mm**. Across every C1-respecting row on every
rung the largest cut motion is **0.738408 mm**, which is *exactly* C1's cube
diagonal `0.426320 · √3 = 0.738408 mm`. The bound is tight and it is the bound
`surface_operator.hpp` specifies.

**Every closing row raises the roughness or leaves it alone. None lowers it — and
that is checked across all 64 rows on all four rungs, not read off this block.**
The most favourable dihedral change any closing achieves anywhere is **exactly
0.00°** (`Close_r0.50_COUPLED`, rung 068: 8.36204° → 8.36204°, unchanged to five
decimals). The worst is rung 026 at 9.00° → **47.34°** (`expl_C1off`, r = 3.41).
Taubin lowers it slightly on every rung (8.36 → 8.30 / 8.09 on 068), exactly as
PR 314 recorded.

**The `dt.025` arm settles the step-size question.** Cutting the time step to a
fifth changes the magnitudes and nothing else: rung 068 r = 1.71 goes 10.62° →
10.35° instead of 8.36°, and the active set still grows (798 → 1,297 rather than
798 → 1,435). **The divergence is the missing coupling, not the step size**, which
is why the coupled arm exists.

**And the active set never empties — 63 of the 64 closing rows hit the 40-iteration
cap with work still outstanding.** The single exception is `Close_r0.50_expl_C1off`
on rung 068, and it "converged" by spiking two vertices **5.05 mm** out into space,
which is the opposite of reassuring. The explicit arm's set *grows* — 798 → 3,688
at r = 1.71 with C1 off — which is a divergence, not a convergence: an explicit
per-vertex normal step lifts one vertex out of a crevice and manufactures a concave
collar around it. The `COUPLED` arm is stable and its set does not move at all:
**798 → 799**, **2,780 → 2,776** over 40 iterations. It is not failing to converge;
**there is nothing left in reach**, which is S1.1 restated from the other side.

## S1.4 — (c) THE OUTWARD PROPERTY. ASSERTED, NOT ASSUMED — AND IT FAILS.

Signed displacement along each vertex's **own outward normal as it stood before the
flow**. Any negative value means the obstacle is not holding.

| arm | inward vertices, rung 068 | worst inward |
|---|---|---|
| `COUPLED`, every radius | **0** | 0.000000 mm |
| `expl_C1on`, r ≤ 1.71 | **0** | 0.000000 mm |
| `expl_C1on`, r = 3.41 | **2** | −0.123511 mm |
| `expl_C1off`, r = 1.00 | **101** | **−4.873275 mm** |
| `expl_C1off`, r = 1.71 | **844** | **−5.311766 mm** |
| `expl_C1off`, r = 3.41 | **1,451** | **−7.618179 mm** |

Across all four rungs: **the `COUPLED` arm never produces a single inward vertex —
0 on all 32 of its rows.** `expl_C1on` produces them on exactly two rows, both at
r = 3.41, and C1's box keeps the damage inside the trust region (rung 068: 2
vertices, −0.1235 mm; rung 026: 1 vertex, −0.4263 mm — one trust radius exactly).
Unrestrained, `expl_C1off` reaches **5,492 inward vertices** on rung 026 and
**−7.618179 mm** on rung 068.

**The outward guarantee is a property of the CONTINUOUS flow, and it does not
survive this discretization.** The mechanism is exact: the step is always `+d` along
the *current* normal, and once the mesh folds — which it does, because nothing
remeshes — the current normal has flipped relative to the original, so "outward"
carries the vertex inward. C1 does not catch it either: C1 bounds how far a vertex
may travel *out*, and never fires on the way in.

**So the safety argument the brief asked me to test does collapse, in every arm that
moves a meaningful amount of material — and what saves the rest is C1, not the
operator.** The arm that keeps the property outright (`COUPLED`) keeps it by moving
almost nothing; the arm that moves and stays bounded stays bounded because a box
clamp caught it, having fired 5,393 times.

## S1.5 — (d) MINIMUM CROSS-SECTION OF EVERY TENDRIL

PR 306's slice-area instrument via the shared header — literally the same code —
**and a second reading on a grid one tessellation cell across**, because the design
grid's 1.705 mm voxel cannot see a sub-voxel change and read identically on every
row of PR 314's table. An instrument that cannot move is the instrument this project
warns about.

| arm, rung 068 | design grid (mm²) | export cell (mm²) |
|---|---|---|
| as exported | 104.6872 | 167.9357 |
| `COUPLED`, every radius | 104.6872 (unchanged) | 167.9357 (unchanged) |
| `expl_C1on`, every radius | 104.6872 (unchanged) | 167.9357 (unchanged) |
| **`expl_C1off`, r = 1.00** | **2.9080** | **0.7270** |
| `expl_C1off`, r = 1.71 | 40.7117 | 28.3528 |

**The brief asked me to prove the minimum cross-section is non-decreasing by
construction. The honest answer has two halves.**

**It holds — strictly — in every arm that respects C1**, across all four rungs:
no C1-respecting row on any rung reads below its baseline on either grid, and one
of them reads **above** it (rung 026, r = 3.41, `expl_C1on` and `expl_dt.025`:
133.7670 → **135.2210 mm²** on the export cell), which is the closing adding
material exactly as advertised. That is the property the brief expected, and it is
confirmed rather than assumed.

**It fails catastrophically without C1** — a **36× reduction** on the design grid
and **231×** on the export cell (167.9357 → **0.7270 mm²**), at r = 1.00 mm alone. Same cause as §S1.4: a folded
neighbourhood, a flipped normal, material removed from a strut by an operator that
is only supposed to add.

**So "non-decreasing" is not a property of the closing flow; it is a property of C1
holding the flow to half a cell.** The two stand or fall together, and both are
measured rather than argued.

## S1.6 — (e) THE MASS, IN GRAMS. PLA at 1.24 g/cm³.

Rung 068 as exported is **443,799 mm³ = 550.31 g**.

| arm | added, rung 068 | as % of the part |
|---|---|---|
| `COUPLED` r = 1.71 | **+0.001 g** | +0.000% |
| `COUPLED` r = 3.41 | +0.009 g | +0.002% |
| `expl_C1on` r = 1.71 | +0.354 g | +0.064% |
| `expl_C1on` r = 3.41 | +0.846 g | +0.154% |
| `expl_C1off` r = 1.71 | +23.882 g | +4.340% |
| `expl_C1off` r = 3.41 | **+47.862 g** | **+8.697%** |

**So the price is either nothing or ruinous, and never anything in between that buys
a smoother surface.** The rows that cost a milligram change the roughness by 0.01°;
the rows that cost 48 g make it 3× rougher (8.36° → 26.61°) and neck a strut. There
is no setting on this operator where you pay some grams and get some staircase back.

**And the worst row on any rung is worse than that.** Rung 026 at r = 3.41 with C1
off adds **+176.833 g to a 357.87 g part — +49.41% by volume — and takes the
roughness from 9.00° to 47.34°.** That is the operator, unrestrained, on the sparsest
rung: it does not fill a staircase, it inflates the part by half again and destroys
the surface.

## S1.7 — (f) COST PER STROKE, against the 63 ms the page now achieves

Release build, on the rung-068 mesh (141,894 vertices — the shipped
`variant_068.stl` carries 143,862; this is the same field re-extracted, PR 314's
own note).

```
operator                       iters   total_ms   ms/iteration   x the 63.3 ms budget
Closing r1.71 explicit           1      101.1          101.1                  1.6x
Closing r1.71 explicit           5      453.6           90.7                  7.2x
Closing r1.71 explicit          40     3494.0           87.3                 55.2x
Closing r1.71 COUPLED            1      118.7          118.7                  1.9x
Closing r1.71 COUPLED            5      464.5           92.9                  7.3x
Closing r1.71 COUPLED           40     3533.9           88.3                 55.8x
Taubin pairs 20 (the incumbent) 20       45.7            2.3                  0.7x
```

**A SINGLE iteration already exceeds the whole stroke budget** — 101 ms against
63.3 ms end-to-end, and against the 34.9 ms PR 314 measured for the smoothing
itself. **Taubin costs 2.3 ms per pass; the closing flow costs 87–119 ms per
iteration, 38–52× more**, because it re-derives the full discrete curvature tensor
(mean, Gaussian, both principals) over every vertex every time. And one iteration is
not an option: this is an obstacle problem, and §S1.3 shows the active set has not
settled after forty.

**So it does not fit, and not by a margin any tuning closes.** This column is
reported for completeness — the operator was already dead at §S1.1, and a fast
version of an operator that reaches 3% of the surface would still reach 3%.

## S1.8 — C4 HOLDS, BITWISE, ON BOTH DISCRETIZATIONS

`cadmoved` reads **0** on every row of every rung of every arm, compared with
`memcmp`, with 116,719 vertices frozen on rung 068 (CAD + ambiguous, folded in on
the safe side exactly as PR 314 folds them). The freeze is a **branch**, never
`p + 0·d` — `0.0 * x` flips the sign bit on a `-0.0` coordinate and would defeat
`memcmp`. R3 holds.

## S1.9 — THE VERDICT

**BLOCKED-STOP, as the brief defined it.** The closing flow does not clearly beat
Taubin on the cut population — it does not beat it at all, on any reading, at any
radius, in either discretization. **A fourth NO-GO, and the brief said that is a
good outcome.** Nothing was built, nothing was wired, no operator was swapped, and
the brush still drives the shipped smoother.

**What makes this NO-GO different from the previous three is that it comes with a
reason that generalises.** §S1.1's crevice-radius distribution is a property of the
geometry, measured before any operator runs, and it would rule out a *correct*
closing implementation — remeshing, implicit solve, gptoolbox and all — just as
firmly as it rules out mine.

---

# 2. S2 — THE FIELD THAT WAS THROWN AWAY. **ALSO NO, AND CLEANLY.**

New harness: `core/tests/harness/field_information_probe.cpp`.

## S2.0 — THE BRIEF'S PREMISE, CHECKED

The brief says `run_info` records `conditional_projection_fired: [false, true, true,
true]`, so rung 0.68 escaped the projection and the grayscale differs per rung. The
file says otherwise:

```
conditional_projection_fired             : [True, True, True, True]
conditional_projection_rung_mnd          : [0.194, 0.291, 0.343, 0.314]
conditional_mma_projection_mnd_threshold : 0.07
```

All four fired; the loosest rung's Mnd is nearly three times the gate. **It does not
change the answer** — the measurement was run per rung anyway rather than assuming
the premise either way — and the measured grayscale is close to identical across the
four. If rung 0.68 had escaped it would be the *grayest*; it is the **least** gray.
`evidence/.../s2_brief_premise_correction.txt`.

## S2.1 — (b) WHAT SURVIVES: THE FIELD IS BINARY WHERE IT MATTERS

A boundary voxel is one with a 6-neighbour on the other side of the iso value, with
out-of-grid reading background 0.0 — the same neighbourhood and the same zero pad
`marching_cubes` itself uses, so "boundary" means what the extractor means by it.

| rung | boundary voxels | strictly inside the band | **as %** |
|---|---|---|---|
| 0.68 | 54,004 | 1,841 | **3.41%** |
| 0.52 | 58,321 | 2,317 | **3.97%** |
| 0.38 | 60,977 | 2,881 | **4.73%** |
| 0.26 | 61,855 | 2,953 | **4.77%** |

Band ends `[0.05047, 0.89988]`, the run's own, from `run_info.json`. Over the whole
grid it is starker still — **0.40%** strictly between on rung 068. The full
ten-bin histograms are in the evidence and they are U-shaped with almost nothing in
the middle: on rung 068's boundary set, 39.58% in `[0.0,0.1)` and 57.56% in
`[0.9,1.0)`, and **every one of the eight bins in between together holds 2.86%.**

## ★ S2.2 — THE DECIDING READING: WHERE MARCHING CUBES PUTS THE POINT

The histogram above is suggestive; this is the reading that settles it.
`mesh.cpp:549` places every surface vertex at `frac = (iso − va)/(vb − va)` along a
lattice edge. **A binary field gives `frac == 0.5` on every crossing — every vertex
at an edge midpoint, which IS a staircase.** So the spread of `frac` is exactly the
sub-voxel information the field still carries, in a unit that converts to
millimetres.

On the **design lattice**, rung 068 (37,342 crossings):

```
|frac-0.5| <= 0.01  (NO sub-voxel information at all): 33999  (91.05%)
|frac-0.5| >  0.10  (real sub-voxel placement)       :  1762   (4.72%)
rms |frac-0.5| = 0.06079  =>  0.1037 mm on a 1.7053 mm cell
```

against a staircase of **0.3424 mm**. Across the four rungs: 91.05 / 88.21 / 85.79 /
85.47% carry nothing, and the whole sub-voxel signal is rms 0.104–0.124 mm.

**One honest limit on the CAD/cut split of these crossings.** A lattice crossing is
not a mesh vertex, so PR 307's classifier cannot be called on it — the split in the
evidence uses the classifier's own tolerance against the CAD tessellation and *not*
its analytic-distance test, which PR 307 showed is needed for a proper attribution.
It is an approximation, it says so where it is defined, and **nothing decisive rests
on it**: the two readings above are whole-population, and §S2.4's split uses the
real classifier on real vertices. For the record the two populations agree anyway —
rms |frac−0.5| is 0.1289 mm CAD-side and 0.1449 mm cut-side on rung 068.

## S2.3 — ★ THE TRAP: THE RESAMPLE MANUFACTURES GRAYSCALE

The same statistic on the **shipped** lattice — after the tricubic resample to
factor 2 — looks completely different: rms 0.1326 mm, and 50.24% of crossings
"beyond 10%". **Read alone, that row says the opposite of the truth.**

It is interpolation, not information. `mesh.hpp`'s own note on `resample_field` says
so in as many words: it "adds NO design information — the surface is already in the
field". A tricubic through binary corner values produces a smooth ramp, and a smooth
ramp produces a spread of `frac`, and none of it came from the optimizer. **The
design lattice is the one that answers the brief's question; anyone re-reading this
should not quote the factor-2 row.**

## S2.4 — (d) THE VERTEX-POSITION OPTIMISATION, MEASURED ANYWAY

The brief branches — "if the field is near-binary, say so and stop". It is, and that
is §S2.5. But the fit was run regardless, because a measurement beats a decision not
to take one. It alternates an umbrella-Laplacian fairing step with a Newton
projection back onto the field's own 0.5 level set, under C1 (half a cell) and C4,
with a **positive control** that removes only the field term — so any difference
between the two is what the field contributed and nothing else.

Rung 068, C4 off so the "amplitude removed" column is defined:

```
operator                  iters   cad_rms_mm  removed%   resid_rms_mm
as exported                   -      0.3270      0.0%              -
Fit_field_i20                20      0.3263      0.2%        0.00037
Fit_field_i50                50      0.3270     -0.0%        0.00042
Fit_field_i200              200      0.3273     -0.1%        0.00043
Fair_only_i20   (control)    20      0.3216      1.7%        0.16159
Fair_only_i50   (control)    50      0.3313     -1.3%        0.18423
Fair_only_i200  (control)   200      0.3477     -6.3%        0.20877
Taubin_pairs_20              20      0.3187      2.5%              -
Taubin_pairs_160            160      0.3009      8.0%              -
```

**★ And the one number that explains the whole column: the level-set residual of the
shipped surface, before anything runs, is rms 0.000000 mm** (below the 1e-6 mm the
probe prints). Your exported mesh is *already* sitting exactly on the field's 0.5
level set, so there is nothing for a projection to pull it onto.

**That zero is an identity, not a lucky measurement, and it should be read as one.**
Marching cubes places each vertex by *linear* interpolation along a lattice edge
(`mesh.cpp:549`), and trilinear interpolation restricted to a lattice edge *is*
linear — so `φ(vertex) = 0.5` holds by construction, not by accident. **The
significance is not that the number is surprising; it is that it is the exact size
of the opportunity the brief was asking about, and it is zero.** A vertex-position
optimisation against a field can only recover what the extraction failed to use, and
this extraction used all of it. There is no residual to mine.

Which is why the field arm holds its residual at 4×10⁻⁴ mm and removes 0.2%, while
the control drifts to 0.16–0.21 mm off the field and only "wins" by *leaving* it —
which is the filter family again, and Taubin does that better (+8.0%).

**This is also the difference from Wedekind et al. and it is worth naming.** Their
data term is the ORIGINAL PROJECTIONS — measurements the reconstruction has not yet
committed to a surface, so the mesh genuinely can disagree with them and be pulled
back. The analogue here would have to be something the extraction did not already
consume. `design.bin` is not that. It is the very field the 0.5 level set was taken
from.

## S2.5 — (c) THE ANSWER

**The field is near-binary and the information is genuinely gone.** Three
independent readings agree: 96.6% of boundary voxels are at a band end; 91% of
surface crossings carry no sub-voxel placement; the surface is already on the level
set to the last bit. The Wedekind analogue does not transfer, and it does not
transfer for a reason that is specific and checkable rather than vague — CT
reconstruction has projections that were never binarized, whereas SIMP's
penalisation plus a conditional Heaviside projection that **fired on all four rungs**
drove this field to 0/1 on purpose.

**Resolution is the lever.** PR 299 measured one doubling removing **49%** of the
stair-step amplitude; PR 314 measured a finer extraction of the same field moving the
surface by ~1/40th of it. S2 closes the last route that was not resolution.

---

# THE BARS

**R1 — NO PRODUCTION FILE CHANGED.** `evidence/.../r1_no_production_change.txt`.

```bash
git diff main -- core/src core/include app/TopOptKit/Sources
```

**Empty**, staged and unstaged alike. `git diff --stat main` touches seven paths and
every one is a test harness, the build rule for one, or this handoff:
`core/CMakeLists.txt` (three additive `EXCLUDE_FROM_ALL` blocks), the two new
probes, two files carried from PR 314, PR 314's instrument move, and the handoff.
**All three new CMake targets are `EXCLUDE_FROM_ALL`**, so CI configures them and
never compiles them — the line numbers are in the evidence. `git diff --stat main --
app` is likewise empty.

**Why two harness files come from an unmerged branch, stated rather than buried.**
PR 314 (`claude/smoothing-page-reset-63aa19`) is **not in main** — checked with
`git merge-base --is-ancestor`, exit 1. R2 requires this task to be scored by PR
314's metric *unchanged*, and that metric lives in `surface_instruments.hpp` on that
branch. Re-typing it would put a silent discrepancy exactly where the comparison
lives. Both files are taken **verbatim**: `git diff` against PR 314's own copies is
empty. `cut_population_probe.cpp` comes with them so the maintainer can re-run PR
314's rows next to these on one tree.

**R2 — SAME METRIC AS PR 314, AND PROVEN SO ROW BY ROW.**
`evidence/.../r2_reproduces_pr314_rows.txt`. `dihedral_rms_deg`,
`deviation_from_cad` and `min_slice_section_of` are **included from the shared
headers**, not reimplemented — and the proof is not that claim, it is that this
probe's Taubin rows **reproduce PR 314's committed CSV exactly**: 8 shared rows
across all four rungs, **64 shared fields compared, 0 differing** (wall time
excluded, as a machine reading rather than a metric).
**Two extensions, both reported alongside the original rather than replacing it:**
the minimum cross-section is also read on a grid one tessellation cell across
(§S1.5, because the design-grid instrument cannot see a sub-voxel change and read
identically on every row of PR 314's table), and §S1.1's crevice-radius distribution
is new — it is a property of the input, not a score, and PR 314's columns are all
still there.

**R3 — C4 STILL HOLDS, BITWISE.** `cadmoved` is 0 on every row of every rung of
every arm, `memcmp`-compared, in both S1 discretizations and in S2's fit. The freeze
is a branch, never a scaled write. §S1.8.

**R4 — EVERY NUMBER ON HIS PART.** Every table above is his `design.bin` +
`M2_verticalStand.step` at res 128. The **only** synthetic geometry in this task is
§S1.0's sign control — two analytic spheres and one analytic wedge — which exists
precisely because PR 306's sphere result did not survive contact with his geometry:
it is used to check that the operator computes what it claims, and **never** to
conclude anything about the operator's usefulness.

**R5 — NO UNFILLED PLACEHOLDERS, NO SCRATCH AT THE ROOT, ASSERTION CENSUS.**
`evidence/.../r5_instrument_move_and_census.txt`. Every number in this handoff comes
from a committed run. `git status` at the repository root shows no stray files. The
one pre-existing file this branch changes, `operator_bakeoff_probe.cpp` (−247
lines), is PR 314's instrument **MOVE**, re-verified here rather than quoted:
**all 232 removed non-blank lines are present verbatim in `surface_instruments.hpp`
by exact whole-line match (0 missing)**, and the rebuilt probe reproduces PR 306's
committed `bakeoff_probe.txt` with **every geometry figure identical** — the only
differing lines are wall-time columns. **No assertion was removed or weakened**; the
two new harnesses add them, including S1.0's hard exit-3 gate with two positive
controls and one negative control.

**R6 — SEPARATE COMMIT FOR ANY REVIEW RESPONSE.** Acknowledged; none yet.

**SUITES.** `evidence/.../ctest.txt`. **core: `ctest` 114/114 — CI's FULL
denominator**, configured with OpenCASCADE + Eigen + lib3mf via
`./app/scripts/build_cli_macos.sh`, so no test is silently unregistered. **app: not
run, and deliberately** — `git diff --stat main -- app` is empty, so `app-macos`
builds the same tree as `main` and a local `swift test` would be measuring main.

---

# FILES

| file | what |
|---|---|
| `core/tests/harness/closing_flow_probe.cpp` | S1 — the closing flow, four arms, the sign control, the crevice-radius distribution |
| `core/tests/harness/field_information_probe.cpp` | S2 — the field's grayscale, the crossing statistic, the vertex-position fit |
| `core/tests/harness/surface_instruments.hpp` | PR 306's instruments via PR 314, carried verbatim (R2) |
| `core/tests/harness/cut_population_probe.cpp` | PR 314's probe, carried verbatim so its rows re-run on this tree |
| `core/tests/harness/operator_bakeoff_probe.cpp` | PR 314's instrument move (R5) |
| `core/CMakeLists.txt` | three additive `EXCLUDE_FROM_ALL` blocks |

Reproduce:

```bash
./app/scripts/build_cli_macos.sh
cmake --build core/build -j8 --target closing_flow_probe field_information_probe
D=evidence/2026-08-03-multiscale-lattice-to
E=evidence/2026-08-08-closing-flow-and-the-field
./core/build/closing_flow_probe      $D/m2_multiscale_final/design.bin $D/M2_verticalStand.step $E
./core/build/field_information_probe $D/m2_multiscale_final/design.bin $D/M2_verticalStand.step $E
```

---

# IN PLAIN LANGUAGE

**Does adding material remove your staircase, and what would it weigh?**

**No, and the reason is the shape of the staircase itself.** The idea was a good one
and the research backs it: instead of smearing the surface around, *fill in* the
dents — the way you would skim filler over a rough wall. The tool for that is called
a closing, and it works by rolling an imaginary ball over the outside of your part
and filling in everything the ball is too fat to reach into.

So I measured the one thing that decides it: **how much of your part's surface is
even dented enough for a ball to miss.** With a ball the size of one voxel — one of
the little cubes your part was designed on — it reaches **3% of the cut surface**.
With a ball twice that size, 11%, and going to four times only gets to 14% before it
stops improving. And **a third of that surface bulges outward rather than dipping
inward**, so no ball of any size will ever touch it. The middling dent on the rest is
so shallow that only a ball **455 mm in radius** would reach its bottom; your whole
part is 218 mm long.

Put simply: your staircase is not a set of narrow cracks. It is a set of **wide,
shallow steps** — like a gentle flight of stairs rather than a row of grooves — and
a ball rolls straight across a gentle flight of stairs without ever dropping in. The
filler never touches the thing you wanted filled.

**What it would weigh, since you asked and the answer is worth seeing.** At the
settings where it stays safe it adds **one to nine milligrams** to a 550 g part, and
changes the roughness by about a hundredth of a degree — you would not be able to
measure the difference. At the settings where it actually moves material, on your
fullest rung it adds **48 grams, nearly 9% of the part**, makes the surface **three
times rougher**, and thins one strut from 105 mm² to 3 mm². On your sparsest rung
the same setting adds **177 grams to a 358 g part — half the part again — and takes
the roughness from 9° to 47°.** **There is no setting in between where you pay some
weight and get some smoothness back.**

I also checked the promise that this method only ever pushes outward, and it does not
hold once you actually implement it — at the aggressive settings it pulls **up to
5,492 points inward, one of them by 7.6 mm**. That is what necked the strut. So the
safety argument that made this attractive does not survive contact with a real mesh,
which is worth knowing before anyone tries it again.

**And does the density field still hold the detail the mesh lost?**

**No, and this one is a proper closed door rather than a shrug.** The thought was
that the design your computer solved is stored as *shades of grey* — how full each
little cube is — and that the smooth shape might still be hiding in those shades even
though the surface we draw from them looks like stairs. Medical scanners do exactly
this trick to clean up their images.

**Your field is not grey. It is black and white.** Of the cubes that actually sit on
the surface — the only ones that decide where the surface goes — **96.6% are either
completely full or completely empty**. Fewer than four in a hundred hold anything in
between. That is not an accident: the optimizer is deliberately pushed toward a clean
yes-or-no answer, and on this run that push was applied to **all four** of your
variants.

And the clinching measurement: when the software draws your surface it already reads
those shades to decide exactly where between two cubes each point should sit. I
measured where it put every one of them, and **91% landed dead in the middle** —
which is another way of saying it had no information to go on and split the
difference. Dead-in-the-middle every time *is* a staircase.

Then I built the thing the idea called for anyway — a routine that nudges every point
on your surface to fit the stored field as well as possible — and it removed **0.2%**
of the stair-stepping, then nothing, then slightly less than nothing. **The reason is
the tidiest number in this whole report: your exported surface is already sitting
exactly on the field, to the last decimal place we can print.** There is nothing to
pull it onto. It is already there.

**So what does that leave?**

The same thing the last two rounds pointed at, now with the final alternative ruled
out: **solve your part on a finer grid.** One doubling of the resolution removed
**49%** of the stair-stepping — five times the best any smoother has ever managed on
your part, with no drift, no melting, and the surface moving *toward* your CAD rather
than away from it. Four different smoothing ideas have now been measured on your own
geometry and all four have failed, each for its own reason but all tracing back to
one fact: the stairs are baked into the grid your design was solved on, and no amount
of work on the surface afterwards will put back what the grid never recorded.

**One thing from the previous round is still the thing I would build**, and nothing
here changed it: the smoother you already have has no limit on how far it may move a
point and no volume term, and at its strongest setting it shifts your surface past
the safety line the whole argument rests on. Putting those limits around it is a
small job and does not depend on any of the four failed ideas.
