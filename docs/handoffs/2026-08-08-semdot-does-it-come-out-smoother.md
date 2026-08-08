# semdot-does-it-come-out-smoother — SEMDOT built as a second mode, and measured on his own part

**Slug:** `semdot-does-it-come-out-smoother` · **Branch:** `claude/semdot-optimizer-smoothness-9b8184`
**Evidence:** `evidence/2026-08-08-semdot-does-it-come-out-smoother/`
**Changes:** `core/` only. Two build outputs on merge. CI: core-linux + app-macos. `materials.json` untouched.
**Required reading it builds on:** PR 299 (Taubin NO-GO + the metric), 303 (SDF), 306 (the bake-off + the instruments), 307 (the CAD/cut classifier), 314 (MCF NO-GO), 315 (the field is binary).

---

<!-- SECTION 0 IS WRITTEN LAST, FROM THE MEASUREMENT. -->

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
parameter the method claims not to need. On his job the conditional projection
gate fired on all four rungs under SIMP; under SEMDOT it is disarmed at
`core/src/simp/minimize_plastic.cpp:936-950` so the ladder walks the same rungs
and simply never enters the polish phase.

## S1(c) — THE SEAMS, with file and line

| seam | file:line | what changed |
|---|---|---|
| the field map | `core/src/simp/semdot.cpp` (new, 260 lines) | the whole method |
| its contract | `core/include/topopt/semdot.hpp` (new) | method, tie rule, the one parameter |
| the switch | `core/include/topopt/simp.hpp:1431-1466` | `SimpOptions::semdot`, `semdot_grid_points` |
| validation + refusals | `core/src/simp/simp.cpp:168-193` | `validate_semdot_options` |
| the linear law | `core/src/simp/simp.cpp:195-203` | `semdot_law` — p forced to 1, identity when off |
| **the trajectory field** | `core/src/simp/simp.cpp:3276-3291` | the map, AFTER `apply_mask_pins`, charged to `project` |
| **the trajectory law** | `core/src/simp/simp.cpp:3298-3299` | `semdot_law(penalty_for_iteration(...))` |
| **`achieved_vf`** | `core/src/simp/simp.cpp:3410-3431` | the post-step printed shape is the SEMDOT field; the achieved fraction is its Active-set sum, not `active_volfrac` of a pinned field |
| **the shipped field** | `core/src/simp/simp.cpp:3617-3637` | `result.physical_density` IS the SEMDOT field — so design.bin, `analyze_fixed_design`, the export and the lattice all see the object the optimizer solved |
| the final solve | `core/src/simp/simp.cpp:3660-3668` | same linear law as the trajectory |
| the result record | `core/include/topopt/simp.hpp:1509-1527` | level set, tie fraction, boundary-layer count |
| **the ladder** | `core/src/simp/minimize_plastic.cpp:936-950` | conditional MMA projection disarmed under SEMDOT |
| the unconstrained overload | `core/src/simp/simp.cpp:2052-2060` | REFUSED — out of scope must mean refused |
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

# 2. S2 — THE MEASUREMENT ON HIS PART

<!-- FILLED FROM THE RUNS. -->

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

<!-- FILLED WHEN THE RUNS AND THE BUILDS ARE IN. -->

---

# FILES

<!-- FILLED LAST. -->

---

# IN PLAIN LANGUAGE

<!-- FILLED LAST. -->
