# semdot-does-it-come-out-smoother — SEMDOT built as a second mode, and measured on his own part

**Slug:** `semdot-does-it-come-out-smoother` · **Branch:** `claude/semdot-optimizer-smoothness-9b8184`
**Evidence:** `evidence/2026-08-08-semdot-does-it-come-out-smoother/`
**Changes:** `core/` only. Two build outputs on merge. CI: core-linux + app-macos. `materials.json` untouched.
**Required reading it builds on:** PR 299 (Taubin NO-GO + the metric), 303 (SDF), 306 (the bake-off + the instruments), 307 (the CAD/cut classifier), 314 (MCF NO-GO), 315 (the field is binary).

---

# 0. THE ANSWER: NO. **YOUR PART DOES NOT COME OUT SMOOTHER — IT COMES OUT ROUGHER.**

**SEMDOT is a FIFTH NO-GO, and this one is different in kind from the other four,
because THE MECHANISM WORKED and the surface got worse anyway.**

On your own part, resolution 128, all four rungs, your captured job document run
both ways on the same machine with the same binary:

| rung | stair-step amplitude (the CAD surface, PR 299's metric) | roughness of the surface the optimizer CUT |
|---|---|---|
| 0.68 | 0.4293 → **0.4731 mm — 10.2% WORSE** | 7.55° → **20.01° — 165% WORSE** |
| 0.52 | 0.4507 → **0.5151 mm — 14.3% WORSE** | 9.63° → **16.37° — 70% WORSE** |
| 0.38 | 0.4394 → **0.4829 mm — 9.9% WORSE** | 10.46° → **15.76° — 51% WORSE** |
| 0.26 | 0.4375 → **0.4877 mm — 11.5% WORSE** | 10.27° → **16.38° — 60% WORSE** |

**The BLOCKED-STOP in the brief fires. Nothing is built on it** — the mode ships
OFF, no default moves, no second certificate, the app is untouched.

## ★ AND THE BRIEF'S CENTRAL PREMISE IS REFUTED, WHICH IS THE FINDING WORTH KEEPING

The brief said: *the design variable is a per-voxel density on a fixed grid, so the
boundary cannot be finer than the grid.* **SEMDOT made it finer than the grid, and
that was not enough.**

PR 315 measured the entire sub-voxel opportunity the field could support at
**0.1037 mm**, with marching-cubes crossings landing at the edge midpoint 91% of
the time — and a midpoint every time *is* a staircase. SEMDOT put **0.32–0.39 mm**
of sub-voxel placement into the field and cut the midpoint share to **40–54%**. On
the three rungs where the shipped β-projection had driven your field essentially
binary (99.96–99.99% of crossings at the midpoint, offset 0.002–0.006 mm), SEMDOT
put in **more than a hundred times** as much sub-voxel content.

**Then the surface got rougher.**

## ★ WHY, in one sentence, and it is the thing to carry forward

**Sub-voxel content is necessary but not sufficient — it has to be spatially
COHERENT, and a per-voxel threshold cannot make it so.** SEMDOT's crossing offsets
are spread nearly uniformly across the whole lattice edge (rms 0.223 against a
maximum of 0.5), so neighbouring vertices get unrelated sub-voxel positions. That
is not a finer surface, it is a **jittered** one. A staircase is at least a
*coherent* error — every vertex on a terrace is wrong the same way — which is
exactly why it reads as a low amplitude and a low dihedral. Trading it for an
incoherent error moves the surface around more *and* roughens it.

The root cause is structural, not a tuning miss: the level-set value is GLOBAL
while the field's gradient across the boundary is not, so two adjacent boundary
voxels crossing the same threshold land at different fractions of their edges, and
nothing in the method couples them. **Any successor needs a term that couples
neighbouring boundary crossings. A per-voxel threshold, however fine, cannot
supply one.** That, with PR 315's "the staircase is a low-curvature, wide-terrace
feature", now closes both halves of the space that has been tried.

## What it would have cost, had it worked

* **Strength: real, and it grows down the ladder.** All four rungs still pass, but
  the worst-case margin goes 3254 → 3180 (−2%) at 0.68 and **3014 → 303 (−90%)**
  at 0.26. Stiffness is fine (compliance +0.4% to +9.6%); the part is more
  STRESSED, not softer. **Part of that is a handicap I declared up front** — the
  certificate solves at penalty 3 while SEMDOT steers at penalty 1, so a
  half-filled voxel is certified eleven times softer than the optimizer treated
  it. The cost is real; the −90% figure is not trustworthy, and §S2.4 says what
  would have to be measured before anyone acts on it.
* **Printability: 8 to 11 times more min-feature violations** (407 → 3,166 at 0.68;
  726 → 7,791 at 0.26). The fractional boundary layer reads as thin material.
* **Weight: slightly lighter** (0.2–6.0% less enclosed volume) and the volume
  target is hit *exactly*, to six decimals, on every rung.
* **Time: cheaper, but not for the reason the paper claims.** 150 iterations
  against 447, 21 min against 83. **On the one rung where the comparison is clean
  — 0.68, the only rung SIMP's β-polish did not run on — SEMDOT took 33% MORE
  iterations (36 against 27).** The rest of the saving is the polish phase not
  running, which SEMDOT subsumes rather than outruns.

## And your lattice: it would not have worked either

**SEMDOT and your multiscale lattice want the same per-voxel number to mean
opposite things** (§S3, read-only, nothing changed). Multiscale exists so an
*interior* voxel can stay grey, because grey there is a real printable lattice
cell; SEMDOT exists to remove grey everywhere except the boundary. Two lines read
it the wrong way — `run_job.cpp:2703` and `run_job.cpp:534`, the second of which
would inflate your exported part by nearly a whole voxel. "Smooth **and** latticed"
is two per-voxel numbers, not one. Everything else in the lattice law reads the
design field only as an in/out mask and would have been fine.

---

# 1. S1 — SEMDOT, BUILT AS A SECOND MODE

## S1(a) — what the method is here, in one paragraph

The stiffness of a voxel stops being a penalized function of its own density. The
filtered, pinned density field is interpolated to **grid points** — a regular
n×n×n sub-lattice inside every voxel, trilinear from the field's nodal averages —
a single global **level-set value** is chosen so the rung's volume budget is met,
and a voxel's **elemental volume fraction** V is the fraction of its own grid
points at or above that level. Interior voxels come out at 1, exterior at 0, and a
voxel the boundary passes through carries the real fraction of itself that is
inside. The material law over V is **linear, E = V·E₀** — no penalization, because
the thresholding is what keeps the design from going grey.

`core/include/topopt/semdot.hpp` states the method, the tie rule and the one
parameter; `core/src/simp/semdot.cpp` is the map.

## S1(b) — the parameter count, and the one number that exists

**There is exactly one number, and it is a DISCRETIZATION, not a control.**
`semdot_grid_points` (n per axis per voxel, default **4**) sets how finely a
boundary voxel's fill can be resolved. It does not steer the optimizer toward one
answer or another; its whole effect is to quantize V at 1/n³, which quantizes the
exported surface's position at ~1/n³ of a voxel — **0.027 mm on his 1.705 mm
voxel, five times below the 0.1037 mm of sub-voxel placement PR 315 measured the
field as able to support at all.** No smoothing width, no continuation schedule,
no stabilization weight, no second threshold.

**And β is REMOVED, not added to.** SEMDOT refuses to run beside a Heaviside
projection (`core/src/simp/simp.cpp:172`, `validate_semdot_options`), because the
level set *is* the sharpening mechanism and β-continuation is exactly the control
parameter the method claims not to need. On the SIMP arm of this job the
conditional projection gate fired on three of the four rungs (0.52 / 0.38 / 0.26,
`conditional_projection_fired` `[false, true, true, true]`); under SEMDOT it is
disarmed at `core/src/simp/minimize_plastic.cpp:936-950` so the ladder walks the
same rungs and simply never enters the polish phase. That one un-fired rung, 0.68,
is what makes §S2.4's iteration comparison readable at all.

## S1(c) — THE SEAMS, with file and line

| seam | file:line | what changed |
|---|---|---|
| the field map | `core/src/simp/semdot.cpp` (new, 260 lines) | the whole method |
| its contract | `core/include/topopt/semdot.hpp` (new) | method, tie rule, the one parameter |
| the switch | `core/include/topopt/simp.hpp:1431-1466` | `SimpOptions::semdot`, `semdot_grid_points` |
| validation + refusals | `core/src/simp/simp.cpp:168-193` | `validate_semdot_options` |
| the linear law | `core/src/simp/simp.cpp:195-203` | `semdot_law` — p forced to 1, identity when off |
| **the trajectory field** | `core/src/simp/simp.cpp:3271-3286` | the map, AFTER `apply_mask_pins`, charged to `project` |
| **the trajectory law** | `core/src/simp/simp.cpp:3293-3294` | `semdot_law(penalty_for_iteration(...))` |
| **`achieved_vf`** | `core/src/simp/simp.cpp:3403-3426` | the post-step printed shape is the SEMDOT field; the achieved fraction is its Active-set sum, not `active_volfrac` of a pinned field |
| **the shipped field** | `core/src/simp/simp.cpp:3612-3632` | `result.physical_density` IS the SEMDOT field — so design.bin, `analyze_fixed_design`, the export and the lattice all see the object the optimizer solved |
| the final solve | `core/src/simp/simp.cpp:3654-3663` | same linear law as the trajectory |
| the result record | `core/include/topopt/simp.hpp:1509-1527` | level set, tie fraction, boundary-layer count |
| **the ladder** | `core/src/simp/minimize_plastic.cpp:936-950` | conditional MMA projection disarmed under SEMDOT |
| the unconstrained overload | `core/src/simp/simp.cpp:2052-2061` | REFUSED — out of scope must mean refused |
| the job schema | `core/src/cli/job.cpp:389-395, 788-808`; `core/include/topopt/job.hpp:686-694` | the optional `"semdot"` block |
| the driver | `core/src/cli/run_job.cpp:6042-6055` | maps the block onto `options.simp`, last, so nothing it subsumes can be re-armed behind it |
| run_info echo | `core/include/topopt/observability.hpp:522-544`; `core/src/simp/observability.cpp:786-812`; `core/src/cli/run_job.cpp:247-252, 7955-7969` | armed mode + per-rung level set and boundary-layer count |

### The two seams deliberately NOT touched, and why

**`analyze_fixed_design` is UNCHANGED, and the brief's premise correction holds.**
`core/include/topopt/analyze.hpp:306` takes `const std::vector<double>& density`
and runs a penalized elastic solve; fractional material is its native input.
Confirmed in passing, as asked, and not investigated further. **The certificate is
not the obstacle.** What the certificate does do is run at the run's `params.penalty`
(3), while SEMDOT's own physics is linear — so a SEMDOT boundary voxel at V = 0.5
contributes 0.125·E₀ to the certificate and 0.5·E₀ to the optimizer. That biases
the certified margin **against** SEMDOT, which is the safe direction and the right
one for a comparison: if SEMDOT wins on margin it wins under a handicap. It is
recorded here rather than fixed because fixing it changes the certificate, and
this task was told not to build a second one.

**The frozen/protect masks and the clearance keep-outs are untouched.** The map
runs *after* `apply_mask_pins` and copies every non-Active voxel through
byte-for-byte (`test_semdot` asserts this with `memcmp`). His job freezes 10,554
voxels behind the protected face; every one of them comes out of the map exactly
as it went in.

## S1(d) — two defects the tests found before the runs did

**R2 was paid twice, and both were real.**

1. **The nodal background rule would have eroded the outer layer of every design.**
   The first implementation used marching cubes' own rule — an out-of-grid
   neighbour reads 0.0, divisor held at 8. That is right for MC and wrong for a
   nodal *average*: on a uniform field at fraction v it drives every domain-face
   node to v/2 and every corner to v/8, the level set lands at the top of the
   field's range, and **the entire outer layer of the design comes back at V = 0**.
   The uniform field is exactly what iteration 1 of the first rung starts from, so
   every run would have handed its first FEA an eroded part. `test_semdot`'s
   "a UNIFORM field must map to itself" check caught it. The rule is now "average
   the voxels that exist", which costs nothing at the *part* boundary — the voxels
   outside the part are in-grid, tagged Empty and carry a real 0.0.

2. **An exact `v == phi` tie test shatters a uniform field into binary noise.**
   A grid-point sample is a mean of up to eight densities blended trilinearly, so
   samples that are mathematically equal differ by a few ulps at 3/5/6/7 incident
   voxels. With an exact test that ulp noise sorts into a spurious "above" group,
   the tie fraction clamps, and a uniform field comes back **binary, in a pattern
   chosen by rounding error**. The band is now 8 ulps — a floating-point noise
   floor, not a tunable: 1e-15 is twelve orders below the 1/n³ quantum V is
   resolved to.

`core/tests/unit/test_semdot.cpp` (5,225 checks, registered as ctest `semdot`)
pins volume exactness to the grid-point quantum, the uniform passthrough, the
sub-voxel content, byte-identical pins, bit-identical re-derivation, and every
refusal.

---

# 2. S2 — THE MEASUREMENT ON HIS PART. **NO-GO.**

His captured job document, resolution 128, all four rungs, both ways, sequentially
on the same machine with the same binary (sha256 in `s2_binary_of_record.txt`).
SIMP 88 min, SEMDOT 32 min. Every number below is in
`s2_semdot_vs_simp.csv` / `s2_cost_and_verdict.csv`.

## S2.0 — the instruments reproduce PR 315 before they are used to judge anything

Rung 0.68 under SIMP, on the DESIGN lattice, against PR 315's readings of the
multiscale design:

| | this run (SIMP) | PR 315 |
|---|---|---|
| boundary voxels binary at a band end | **88.69%** | 96.6% |
| MC crossings within 1% of the edge midpoint | **85.28%** | 91.05% |
| crossing offset, rms \|frac−0.5\| | **0.1297 mm** | 0.1037 mm |
| CAD / ambiguous / optimizer-CUT split | **79.1 / 2.5 / 18.4%** | PR 307: 81.8 / — / 15.7% |

Same regime on every row. The instruments are measuring what they measured before.

## ★ S2.1 — THE MECHANISM WORKED. THE PREMISE OF THE WHOLE TASK IS REFUTED.

The brief's central claim was that **the boundary cannot be finer than the grid**,
so the fix has to be in the optimizer. SEMDOT made the boundary finer than the
grid, by a wide margin, on every rung:

| | SIMP 0.68 / 0.52 / 0.38 / 0.26 | SEMDOT 0.68 / 0.52 / 0.38 / 0.26 |
|---|---|---|
| boundary voxels binary at a band end | 88.69 / 99.99 / 99.998 / 99.998 % | **77.79 / 73.44 / 71.90 / 69.15 %** |
| crossings within 1% of the midpoint | 85.28 / 99.96 / 99.99 / 99.99 % | **53.56 / 49.24 / 45.20 / 40.43 %** |
| crossing offset rms (mm) | 0.130 / 0.002 / 0.006 / 0.003 | **0.389 / 0.325 / 0.351 / 0.380** |

PR 315 measured the entire sub-voxel opportunity the SIMP field could support at
**0.1037 mm**. SEMDOT put **0.32–0.39 mm** of sub-voxel placement into the field —
three times the whole opportunity, and more than a HUNDRED times what was left on
the three rungs where SIMP's β-projection had driven the field essentially binary
(crossings at the midpoint 99.96–99.99% of the time, offset 0.002–0.006 mm).

**And the surface came out worse anyway.**

## ★ S2.2 — THE ANSWER. Worse on every rung, on both populations.

**Stair-step amplitude — PR 299's metric, the OBLIQUE CAD surface, the only place
on his part where "how much staircase is there" has a truthful answer:**

| rung | SIMP | SEMDOT | |
|---|---|---|---|
| 0.68 | 0.4293 mm | **0.4731 mm** | **10.2% WORSE** |
| 0.52 | 0.4507 mm | **0.5151 mm** | **14.3% WORSE** |
| 0.38 | 0.4394 mm | **0.4829 mm** | **9.9% WORSE** |
| 0.26 | 0.4375 mm | **0.4877 mm** | **11.5% WORSE** |

**Roughness on the OPTIMIZER-CUT population — PR 307's classifier, rms dihedral by
the same `dihedral_rms_deg` on a submesh of cut-attributed triangles (S2(d)):**

| rung | SIMP | SEMDOT | |
|---|---|---|---|
| 0.68 | 7.55° | **20.01°** | **165.0% WORSE** |
| 0.52 | 9.63° | **16.37°** | **69.9% WORSE** |
| 0.38 | 10.46° | **15.76°** | **50.7% WORSE** |
| 0.26 | 10.27° | **16.38°** | **59.6% WORSE** |

On the CAD population the same instrument reads 7.58 / 7.90 / 8.06 / 8.30° against
**7.72 / 8.24 / 8.87 / 9.87°** — worse there too, by less.

**THE BLOCKED-STOP IN THE BRIEF FIRES. I built nothing on it** — no default change,
no second certificate, no app work, nothing downstream.

## ★ S2.3 — WHY, and this is the part worth keeping

**Sub-voxel content is necessary but not sufficient. It has to be SPATIALLY
COHERENT, and SEMDOT's is not.**

An rms \|frac−0.5\| of **0.2228** (rung 0.26) against a theoretical maximum of 0.5
means the crossings are spread almost uniformly across the whole lattice edge:
adjacent edges get essentially unrelated sub-voxel offsets. That is not a finer
surface, it is a **jittered** one. Marching cubes then places each vertex at a
different fraction than its neighbour, and the 165% jump in cut-surface dihedral
is that jitter, measured.

**The staircase is at least a COHERENT error** — every vertex on a terrace is
wrong in the same direction by the same amount, which is why it reads as a low
rms and a low dihedral. Replacing it with an incoherent one moves the surface
around more (higher amplitude) *and* makes it rougher.

**The root cause, with a line:** the level-set value is GLOBAL (`semdot.cpp`, the
K-th largest grid-point sample) while the field's local gradient across the
boundary is not. Two adjacent boundary voxels with different local gradients
crossing the same φ land at different fractions of their edges. Nothing in the
method couples them.

**This unifies with the other four NO-GOs rather than adding a fifth unrelated
one.** PR 315's summary was "the staircase is a low-curvature, wide-terrace
feature and every operator tried keys on curvature or on frequency". The operator
that does *not* key on either — this one, which works on the field — fails for the
dual reason: **it has no notion of the surface's spatial coherence at all.** Any
successor needs a term that couples neighbouring boundary crossings; a per-voxel
threshold, however fine, cannot supply one.

## S2.4 — WHAT IT COSTS: strength, weight, iterations and wall

**STRENGTH — the real cost, and it grows down the ladder.** All eight variants were
accepted (`margin_stop` 1.5), but:

| rung | SIMP margin | SEMDOT margin | SIMP max vM | SEMDOT max vM |
|---|---|---|---|---|
| 0.68 | 3254.4 | **3180.1** (−2%) | 0.0169 MPa | 0.0173 MPa |
| 0.52 | 3389.4 | **2164.8** (−36%) | 0.0162 MPa | 0.0254 MPa |
| 0.38 | 3290.9 | **1008.5** (−69%) | 0.0167 MPa | 0.0545 MPa |
| 0.26 | 3014.1 | **303.2** (−90%) | 0.0182 MPa | 0.1814 MPa |

**COMPLIANCE is nearly unchanged** — 0.00240038 / 0.00251706 / 0.00283886 /
0.00347194 against **0.00240946 / 0.00252112 / 0.00292106 / 0.00380689**, i.e.
+0.4% / +0.2% / +2.9% / +9.6%. **So the part is not less stiff; it is more
STRESSED**, in the fractional boundary layer.

★ **AND PART OF THAT IS THE HANDICAP I DECLARED IN §S1(c), NOT THE METHOD.** The
certificate solves at penalty 3 while SEMDOT steered at penalty 1, so a boundary
voxel at V = 0.3 is certified at 0.027·E₀ instead of 0.3·E₀ — eleven times softer
— and a soft voxel under load reads a high stress. SEMDOT leaves 17,284–31,680
fractional voxels where SIMP leaves almost none, so this term grows exactly the
way the table does. **I did not chase it**: the brief said not to build a second
certificate, and re-certifying under the optimizer's own law is exactly that. What
can be said without building anything is that the margin cost is REAL but its
SIZE is not trustworthy, and no decision should be taken on the −90% figure until
someone certifies a SEMDOT design under the law it was optimized with.

**WEIGHT.** `achieved_vf` is exact to six decimals on all four SEMDOT rungs (the
level set enforces the volume directly) against SIMP's ±5e-5. The EXPORTED mesh
volume is **0.2% / 6.0% / 0.9% / 1.8% LIGHTER** under SEMDOT — the 0.5 iso of a
fractional field encloses less than the 0.5 iso of a binary one.

**PRINTABILITY — the worst single column.** Min-feature violations (voxel):
407 / 591 / 635 / 726 under SIMP against **3,166 / 5,271 / 6,004 / 7,791** under
SEMDOT — **8 to 11 times more**. The fractional boundary layer is, by
construction, a layer of not-quite-solid material, and the min-feature gate reads
it as thin. The minimum cross-section holds at 3.4106 mm² in all eight rows.

**ITERATIONS AND WALL, SEPARATELY (R6):**

| | SIMP | SEMDOT | ratio |
|---|---|---|---|
| iterations, all | 447 (168 grayscale + 279 β-polish) | **150** (150 + 0) | 0.336x |
| iterations, grayscale phase only | 168 | **150** | 0.893x |
| wall | 4988.4 s | **1269.3 s** | 0.254x |
| CG iterations | 419,205 | **129,975** | 0.310x |

★ **THE PAPER'S "FEWER ITERATIONS" CLAIM DOES NOT SURVIVE THE ONE CLEAN
COMPARISON.** SIMP's conditional β-projection fired on rungs 0.52 / 0.38 / 0.26
and NOT on 0.68, so **rung 0.68 is the only rung with no polish-phase confound —
and there SEMDOT took 36 iterations against SIMP's 27, i.e. 33% MORE.** The 0.336x
headline is mostly "the polish phase did not run", which is a consequence of
SEMDOT subsuming β, not of faster convergence. The map itself is cheap and is not
the story either way: 66 ms of a ~10 s iteration, 0.7%.

**THE HOST WAS NOT IDLE.** Two other worktrees ran solver jobs throughout;
`host_contention.txt` samples it every 60 s. Iteration and CG counts cannot be
moved by that and are the primary cost reading; the wall ratio is reported second
and should not be quoted to better than "about 4x".

## S2.5 — R5: NO VERDICT MOVED ON THE SIMP PATH

The SIMP arm accepted all four rungs at margins 3254 / 3389 / 3291 / 3014 with
`semdot=false` echoed in `run_info.json`, `rung_infeasible` and
`rung_non_convergent` all-false. Rung 0.68's margin of 3254 sits against the
3.26e+03 his recorded multiscale run reported for the same rung.

---

# 3. S3 — READ, DO NOT TEST: CAN THE LATTICE LAW EAT THIS?

Full reading with every line number in
`evidence/2026-08-08-semdot-does-it-come-out-smoother/s3_lattice_law_reading.txt`.
The short form:

**(a) `grade_lattice` — WORKS UNCHANGED.** Every one of its eight reads of
`density` is the mask `density[e] > iso` (`core/src/simp/grading.cpp:188, 194,
209, 238, 373, 406, 525, 626`). The magnitude is never used. The number the
homogenized tensor and the strut radii are built from comes from `rho_of` at
`grading.cpp:290-303`, and in the classic law that is derived from the **von Mises
demand field**, not from the design density at all. The **cells-per-member floor**
compares a member width against a cell size — no density. The **sub-floor
retention predicate** qualifies on `stress_fraction` (`grading.cpp:261`),
accumulated from `demand[e]` over voxels selected by the same mask.
`lattice_boundary_for` / `set_voxel_base` (`run_job.cpp:898`,
`lattice_boundary.hpp:95`) is "the union of the solid voxel cubes (density >=
iso)" — a mask again.

**(b) `local_member_thickness_mm` — WORKS UNCHANGED; its READING moves.**
`core/src/voxel/voxelize.cpp:559-566` binarizes at `iso` before it measures
anything, so the quantity is identical under either field. What changes is which
voxels are in the set: a boundary voxel SIMP left at 1.0 may come back from SEMDOT
at 0.45 and drop out, so a member width can move by up to one voxel per side — in
the same direction and by the same amount as the exported surface. That is a
change in the object, not in the instrument, and it keeps the width the lattice is
sized against equal to the width the file carries. Arithmetically it can only
matter for a member already within ~7% of the cells-per-member floor (one voxel at
1.705 mm is 0.37 cells at his 4.60 mm cell, against a floor of 5).

**(c) The printed-set threshold — the MECHANISM covers it; the MULTISCALE VALUE
does not.** `printed_iso` (`analyze.hpp:316-328`) already means "a voxel carries
material when density > this", it defaults to 0.5, and 0.5 is exactly right for a
SEMDOT field. But `run_job.cpp:533-535` returns `0.5 * lattice_rho_min(octet)` ≈
**0.025** on a multiscale run, whose stated justification — "a voxel at density
0.30 is a real 30%-dense lattice cell and not a half-empty solid voxel" —
**inverts** under SEMDOT, where a 0.30 voxel *is* a 30%-full solid voxel. Reading a
SEMDOT field at 0.025 would call a voxel 2.5% inside the part "printed" and balloon
the exported surface by close to a whole voxel.

**(d) THE VERDICT: works unchanged for the CLASSIC lattice law; BREAKS for the
MULTISCALE one**, at two lines with one cause — `run_job.cpp:2703`
(`gp.prescribed_relative_density = &dens`) and `run_job.cpp:534` (the iso).

**And the reason generalises, which is what step 3 of his plan needs to know.**
*SEMDOT and MULTISCALE are opposite by construction.* Multiscale exists so an
**interior** voxel can stay grey, because grey there means a real printable lattice
cell. SEMDOT exists so grey survives **only at the geometric boundary**, because
that is what puts the surface between voxel centres. They cannot both own the same
per-voxel number. "Smooth **and** latticed" is not one field: it is an *occupancy*
(SEMDOT's volume fraction, which places the boundary) and a *relative density*
(which the lattice is built from), carried separately. Every consumer above except
those two lines already reads only the occupancy, so the separation is smaller than
it sounds — but it is a real design decision and it belongs to step 3.
**Nothing was changed.**

---

# THE BARS

**R1 — BYTE-IDENTICAL WHEN OFF, by stash-rebuild checksum. PASSES, and the report
says what it means rather than stopping at "differences".**
`r1_byte_identity.sh` builds `main` (3828949) in a **detached worktree** — not a
stash; `git stash push -- <paths>` matching nothing pops someone else's stash —
runs the same lattice+grading job with no `semdot` key through both binaries, and
classifies:

* **DESIGN ARTIFACTS — 8 of 8 BYTE-IDENTICAL**, no exceptions and no
  normalization: `design.bin`, `fields.bin`, `report.json`, `loadcase.json` and
  all four meshes.
* **RECEIPTS** — `build_orientation.json` identical once the wall clock is out;
  `iterations.csv` 60 rows with **all 19 non-timing columns identical**;
  `run_info.json` differs by the wall clock plus exactly **five ADDED keys**
  (`semdot`, `semdot_grid_points`, and the three empty per-rung vectors), named
  individually so nothing hides behind a whitelist.

★ The bare checksum diff this started as reported "DIFFERENCES FOUND" on three
files and left the reader to work out that all three carry a wall clock
(`created_wall_ms`, `preflight_ms`, `gen_seconds`, `sweep_seconds`, every `*_ms`
column). `r1_classify.py` holds the two classes to different, stated standards
instead — byte identity for the object, clock-stripped identity plus named
differences for the receipt — and exits non-zero if either fails.

**R1, SECOND BUILD OUTPUT. PASSES.** `app/scripts/build_core.sh` exit 0 (all three
slices; xcframework fingerprint `117ec7e8abd5`) and `swift test --package-path
app/TopOptKit` exit 0 — `r1_app_build.txt`. The app is untouched by this task; it
links core, so it is built and tested, not merely assumed.

**THE SUITE, AT CI'S DENOMINATOR: 116/116, 1736 s** (`ctest_116.txt`), including
`semdot` (#54) and — the point of insisting on 116 — `export_3mf` (#99) and
`threemf_import` (#116). ★ A DEFAULT LOCAL CONFIGURE OF THIS WORKTREE REGISTERS
**114**: lib3mf is not a Homebrew formula, so both 3MF tests silently do not
register and a local "114/114" is true and meaningless. Passing `-Dlib3mf_DIR=` over
the existing cache does nothing (`find_package` short-circuits on the cached
result); passing **`-DCMAKE_PREFIX_PATH=`** including the repo's `.vcpkg/installed/
arm64-osx-dynamic` DOES re-search and lifts 114 → 116 without a fresh configure.

**R2 — FAILING TEST FIRST. Paid twice, and both were real** (§S1(d)): the nodal
background rule that erodes a uniform field's outer layer, and the exact tie test
that shatters a uniform field into binary noise. `test_semdot` (ctest `semdot`,
5,225 checks) failed on both before either was fixed.

**R3 — SAME INSTRUMENTS AS PR 314/315, INCLUDED NOT RETYPED.**
`semdot_surface_probe.cpp` `#include`s `stairstep_metric.hpp` (PR 299's
`deviation_from_cad`, the oblique mask rule, `dihedral_rms_deg`,
`min_feature_now`) and `surface_instruments.hpp` (PR 306's `min_cross_section`)
and defines none of their symbols. PR 307's `attribute_to_cad_faces` does the
CAD/cut split. The cut-restricted roughness is the SAME `dihedral_rms_deg` run on
a submesh — the population is restricted, the instrument is not rewritten, exactly
as `deviation_from_cad`'s own `only` argument restricts the other one.
§S2.0 shows the instruments reproducing PR 315's readings before they are used to
judge anything.

**R4 — EVERY NUMBER ON HIS PART, ALL FOUR RUNGS.** No sphere, no dumbbell, no
L-bracket in any reported row. (The L-bracket appears only in R1's byte-identity
fixture and in the refactor-neutrality check, neither of which is a measurement of
the method.)

**R5 — NO VERDICT MOVED ON THE SIMP PATH.** §S2.5: four rungs, four accepted,
`semdot=false` on the receipt, no infeasible or non-convergent rung. R1 proves the
stronger statement on a second job.

**R6 — ITERATIONS AND WALL, ALWAYS BOTH, SEPARATELY.** §S2.4, with the grayscale /
β-polish split as well, because SIMP's polish phase has no SEMDOT counterpart and
lumping them would credit SEMDOT with work that did not run. The host was not idle
(`host_contention.txt`, sampled every 60 s); iteration and CG counts cannot be
moved by that and are reported as the primary cost.

**R7 — ASSERTION-MESSAGE CENSUS, not a name grep.** `r7_assertion_census.py`,
comment-stripped and **multi-line aware** — this codebase's assertion messages
routinely start on the line after the `assert(`, and a line-oriented grep reported
this branch's own new refusals as "nothing added", which is how a census lies.
Base 552 distinct messages / 596 occurrences, branch 563 / 607: **0 deleted, 0
weakened, 11 added.**

**R8 — ROOT CAUSE WITH FILE AND LINE.** §S1(c) is the seam table; §S2.3 and §S3
name their lines. No unfilled placeholders. No scratch at the repository root.

**R9 — separate commit for any review response.** Nothing to respond to yet.

### One provenance note, paid rather than waved at

Three cleanups (two `std::move`s and one dead 3.7 MB-per-iteration copy of the
SEMDOT field) were made AFTER the S2 binary was pinned, so the committed source
does not byte-match the binary that produced the S2 numbers. Rather than assert
they are neutral, the smoke job was re-run through the rebuilt binary and its
`design.bin` compared with the pre-refactor one: **identical**,
`90de90bcc3b67afd20c949253e2cffde40c7b8638b001aa7057a403ddba39eb4`
(`r1_refactor_neutrality.txt`).

---

# FILES

**New**

| file | what |
|---|---|
| `core/include/topopt/semdot.hpp` | the method, the tie rule, the one parameter |
| `core/src/simp/semdot.cpp` | the smooth-edged volume-fraction map |
| `core/tests/unit/test_semdot.cpp` | ctest `semdot`, 5,225 checks |
| `core/tests/harness/semdot_surface_probe.cpp` | S2's geometry table |
| `evidence/2026-08-08-semdot-does-it-come-out-smoother/` | everything measured |

**Changed** — `core/include/topopt/{simp,job,observability}.hpp`,
`core/src/simp/{simp,minimize_plastic,observability}.cpp`,
`core/src/cli/{job,run_job}.cpp`, `core/CMakeLists.txt`. Seam table in §S1(c);
1,638 insertions and 8 deletions against `main` across 13 files — and every one of
those 8 deletions is a line replaced in place (`git diff main -U0 | grep '^-'`).

---

# IN PLAIN LANGUAGE

**Your part does not come out smoother. It comes out rougher, on every one of your
four rungs, and this is the fifth method to fail.** I built it, measured it on your
own job, and built nothing on top of it.

**But this one failed differently, and that is worth your time.** The last four
attempts all failed the same way — they tried to sand the staircase off a finished
surface and couldn't reach it. The reason we thought that kept happening was that
your design is a stack of full-or-empty cubes, so the surface can never sit
anywhere except on a cube edge. **This method fixed that.** It let each cube on the
edge of the part say *how much* of itself is inside, and it worked: where your
current runs put the surface exactly on a cube edge 91–100% of the time, this put
it somewhere in between 46–60% of the time. There was three times more
in-between-ness in the file than the old approach could ever have had.

**And the surface still got worse.** About 10–14% worse on the flat and angled
faces that came from your CAD, and 51–165% rougher on the surface the optimizer
carved itself.

**Here is why, and it's the thing to remember.** Putting the surface *between*
cubes isn't enough — neighbouring bits of surface have to agree with each other
about where "between" is, and here they don't. Each cube picks its own offset
independently, so the surface ends up **jittery** rather than fine. A staircase is
at least a *tidy* error: every point on a step is wrong by the same amount in the
same direction, which is exactly why it measures as low and smooth-ish. Swapping it
for an untidy error of similar size makes things worse on both counts. Anything
tried next has to make neighbouring points agree; a rule applied one cube at a
time — however finely — cannot do that.

**What it would have cost, if it had worked.** Your parts all still passed the
strength check, but the safety margin on the lightest rung fell from 3014 to 303 —
and I want to be straight that **a chunk of that number is my measurement, not the
method**: the strength check treats a half-full cube as eleven times weaker than
the optimizer did, and this method makes a lot of half-full cubes. The cost is
real; the size of it isn't trustworthy, and I've written down what would have to
be measured before anyone acts on that figure. The part is *not* less stiff — it
bends the same amount. It's slightly lighter, it hits your volume target exactly,
and it produced **8 to 11 times more "this bit may be too thin to print"
warnings**, which is the worst single column in the table.

**On time: it looks three times faster, and that's mostly an illusion.** 150
passes instead of 447. But 279 of your 447 were a polishing stage this method
doesn't have — it removes the need for it rather than doing it quicker. On the one
rung where the comparison is clean, it took **33% more** passes, not fewer. So the
paper's "converges in fewer iterations" claim does not reproduce on your part.

**And you would not have been able to lattice it.** Your lattice runs in a mode
where a cube reading 0.30 means "a real 30%-dense lattice cell". Under this method
0.30 means "a cube 30% full of solid plastic". Two places in the code read it the
wrong way, one of which would have puffed your exported part up by nearly a whole
cube's width. That isn't a bug in either feature — they're deliberate opposites,
one wants the inside of the part grey and the other exists to remove grey. **If a
smoothing method ever does work, "smooth and latticed" will need two numbers per
cube, not one.** I only read the code for this; I changed nothing.

**What I would do next.** Nothing on this method. The door that is still open is
the one PR 299 measured and nobody has walked through: **resolution.** Doubling it
removed 49% of the staircase — five times the best any smoother managed, with the
surface moving *toward* your CAD rather than away from it. Every attempt since has
been a way of avoiding paying for that, and five of them have now failed. It is a
measurement, not a project, and it is where the staircase actually lives.
