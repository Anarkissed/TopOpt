# 2026-08-08 — how wrong is the boundary cell

Task `how-wrong-is-the-boundary-cell`, branch `claude/boundary-cell-error-50f585`,
branched from `3828949` (`origin/main`, PR 314). Runs in parallel with
`semdot-does-it-come-out-smoother`, which owns the optimizer; this task owns
certification and quadrature and touches neither the MMA update, the sensitivity
path nor the design variable.

**No production file is changed at all.** The whole diff is one
`EXCLUDE_FROM_ALL` harness under `core/tests/harness/` and the CMake block that
declares it. CI: `core-linux` + `app-macos`. `materials.json` untouched; `app/`
untouched.

Evidence: `evidence/2026-08-08-how-wrong-is-the-boundary-cell/`

---

## 0 · Headline

**The margins on all four variants you have already exported are optimistic, and
one halving of the element size moves them 17 % to 41 %.** Certified 2169.6 on
your first rung; the identical design on a grid twice as fine says 1540.0; at
three times as fine, 1288.9. Same object, same load, same code.

**The premise is not what is wrong.** On three of your four rungs there is no
smeared boundary cell at all: of the 60,588 / 63,228 / 64,637 cells in the
interface band, **4, 1 and 2** hold a fractional density. The conditional Heaviside
projection fired on those rungs and binarised them. §2.

**★ AND CUT-CELL QUADRATURE WOULD NOT HAVE HELPED — measured, not argued.** A cut
scheme needs a geometric interface, and the only one this design carries is the
0.5 level set of its own density. That surface does cut 63–65 % of interface
cells, but its **median cut fraction is exactly 0.5000** — a half-voxel-shifted
staircase, not a smooth boundary — and the total material it would move is
**0.86–1.66 % of printed volume**. It would integrate the same staircase, keep the
same corners, and leave the measured error in place. §8(b).

**What is wrong is WHERE the stress is read.** `analyze_fixed_design` recovers each
voxel's stress at the **element centroid** (`core/src/simp/analyze.cpp:355`;
`hex8_stress`'s evaluation point defaults to the centroid,
`core/include/topopt/fea.hpp:132-134`). Your own `report.json` says all four rungs
sit **exactly on the min-feature floor** — thinnest member 3.411 mm, which is two
voxels — and the peak sits on one of those members. The certificate samples a
quarter of the way in from a free surface and reports it as the surface stress. §7.

**★ AND THERE IS NO "CORRECT MARGIN" TO CONVERGE TO.** Three resolutions on two
rungs: the peak grows like h^−q with **q = 0.4945 then 0.4391** (rung 0.68) and
**q = 0.2301 then 0.2524** (rung 0.26). q is not collapsing. A converging quantity's
would. 0.4555 is the 2-D re-entrant 90° corner exponent and 0.5 is a crack — the
staircase's inside corners are singular, so the peak von Mises is a
**mesh-dependent number, not an approximation to one**. §6. That is the single most
important input to the decision you are actually making, and §8 explains why.

**One control makes the diagnosis airtight.** Under the same refinement that moves
the peak 15–29 %, the **compliance moves 0.7–1.1 %** and the peak displacement
1.0–1.5 %, both in the textbook direction. A wrong load, a wrong clamp, a
mis-mapped design or an unconverged CG would each have moved the compliance too.
The solve is right about the structure to within one percent and wrong about one
point's stress by up to twenty-nine. §5.

**Nothing you printed is unsafe and no verdict moves.** The gate needs 1.5 after
your 35 % infill knockdown; you have 449. At 3× you would have 267. Every rung
stays ACCEPTED at every resolution measured. What this costs you is the number, not
the part — but on a job whose margin sat near 1.5, the same 41 % would decide the
verdict, in the wrong direction.

---

## 1 · What the certificate actually reads

The gate is one number wide. `compute_stress_margin`
(`core/include/topopt/report.hpp:47-51`):

```
in_plane   = yield_strength_mpa / max_von_mises_stress
interlayer = (z_knockdown * yield_strength_mpa) / max_interlayer_tension
worst_case = min(in_plane, interlayer)
```

PLA is `yield 55 MPa, z_knockdown 0.55` (`core/src/materials/materials.json`, not
edited). On all four of your rungs the interlayer term is about twice the in-plane
term, so **`margin_worst_case` IS `55 / peak_von_mises`, exactly**. Therefore a
relative error in the peak is minus the relative error in the margin;
`margin_effective = margin_worst_case × 0.2070627924` (your 35 % infill); and
`accepted = load_path_ok && margin_effective >= 1.5`.

`max_von_mises` is the max over printed voxels of a **per-voxel** von Mises. So
"how wrong is the boundary cell" is, precisely, "is the worst per-voxel von Mises
the worst stress in the object".

**And the worst per-voxel von Mises is a boundary cell on every rung.** Of the 200
highest-stressed voxels, 194 / 200 / 200 / 200 are boundary cells, and the boundary
peak is 1.30 / 1.29 / 1.35 / 1.34 times the interior peak. The question was aimed
at the right population, even though its premise turns out to be wrong.

---

## 2 · S1, first — the census that reframes the question

The brief's premise is that a boundary cell's material is smeared uniformly across
the cell, so the cell knows how much it holds and nothing about where. That is only
true of a cell holding a FRACTION of a cell of material. Measured on the design's
own lattice (`field_census.py` → `S1_field_census.txt`; BOUNDARY = printed with at
least one face-neighbour not printed, off-grid reading void, which is marching
cubes' own rule):

| rung | printed cells | boundary | % of printed | interface band | **grey in (0.05, 0.95)** |
|---|---|---|---|---|---|
| 0.68 | 88,425 | 31,707 | 35.86 % | 54,068 | **6,182 (11.43 %)** |
| 0.52 | 76,974 | 34,328 | 44.60 % | 60,588 | **4 (0.007 %)** |
| 0.38 | 67,078 | 34,881 | 52.00 % | 63,228 | **1 (0.002 %)** |
| 0.26 | 58,595 | 34,969 | 59.68 % | 64,637 | **2 (0.003 %)** |

**Three of your four rungs have no smeared boundary at all.** Their boundary is a
staircase of completely full and completely empty cells. `run_info.json` says why:

```json
"conditional_projection_fired":    [false, true, true, true],
"conditional_projection_rung_mnd": [0.0635, 0.1002, 0.1081, 0.1079],
"conditional_mma_projection_mnd_threshold": 0.07
```

The projection fired on rungs 2–4 and binarised them; rung 1 (Mnd 0.0635) fell
below the threshold and kept its grey band, which is why it is the only rung with
anything to smear.

**A correction of record, because a successor will otherwise trip on it.** The
stored note from task `closing-flow-and-the-field` states that this run's
`run_info` reads `[true, true, true, true]` with mnd `[0.194, 0.291, 0.343,
0.314]`. Job `ca62f91cba4b422d` reads what is quoted above, and the density field
corroborates it independently. That note is about a different run. Six worker jobs
carry fingerprint `d9fe8f768331`; **this is the only one with a complete four-rung
`design.bin`** — two of the others have no `out/` payload and three carry a single
variant.

---

## 3 · S1 — the instrument, and what it holds fixed

`core/tests/harness/boundary_cell_probe.cpp`, `EXCLUDE_FROM_ALL`, not a ctest.

The physics is `analyze_fixed_design` — the same call the ladder's per-rung
certification (`minimize_plastic.cpp:1806`) and the re-lattice path
(`run_job.cpp:5486`) both make. The load case is `production_loadcase_from_job` →
`build_production_loadcase`, the ONE core builder. Nothing here re-derives physics.

**Two ways to refine a certificate, two different questions, never mixed.**

* **`replicate` — THE REFERENCE.** Only the element size changes. The fine grid is
  the exact N× subdivision of the run's own grid, tags replicated child for child,
  so the Fixture region, the Load region and the part occupancy are the SAME
  SOLIDS rather than re-derived from the CAD. The BCs are then rebuilt by the
  production rule (all 8 corner nodes of every Fixture voxel,
  `core/src/cli/loadcase.cpp:249-263`) and the traction by the production call
  (`traction_loads` over the Load region's exposed faces, `loadcase.cpp:236`), so
  the clamped volume and the loaded surface are geometrically identical to the
  run's, refined. Any difference is discretization error of the solve and nothing
  else. It requires exactly one live load group, because
  `build_production_loadcase` builds each group's traction against an anchors-only
  base grid; with one group that base grid carries the same tags as the final
  grid, so the subdivision is exact. With more it is not, and the probe refuses
  rather than approximating.
* **`retag`** — `build_production_loadcase` run at the finer resolution outright,
  so the CAD is re-voxelized and the anchor/load faces re-tagged there too. A real
  and different question, reported separately in §9 and never averaged in.

**The design is carried across by piecewise-constant replication and nothing
else** — coarse voxel (i,j,k) → the N³ fine voxels under it. That reproduces the
object exactly: same material, same total volume, same boundary surface, same
fraction in every grey cell. Trilinear or tricubic resampling would MANUFACTURE a
ramp through binary corners (`mesh.hpp` says so of `resample_field`; PR 314
measured it), and the reference would then be a different object rather than a
better-resolved one.

**The solver posture is pinned**, exactly as `ScopedLadderSolverIsolation`
(`run_job.cpp:2553`) pins it around every re-certification: Krylov recycling and
GenEO off. Two reasons, both necessary. Comparability — a carried recycle subspace
is state, not an argument (PR 313 §1). And arithmetic — GenEO's basis at 128 is
1,674 columns over 1.47 M DOF; at 2× that is 1,674 columns over 11.5 M DOF, which
fits on no machine this runs on. One solve per process, so the recycle space starts
empty regardless.

**Four preconditions are asserted, not assumed**, and all four hold on every row:

| what | why it would invalidate the comparison | measured |
|---|---|---|
| the declared resultant survives refinement | the two sides would carry different loads | −33.3617019653 N at **every** resolution |
| no printed cell lost to a `ceil()` gap | the comparison would be on part of the design | 0 everywhere |
| no voxel needs the tag repair in `replicate` | the object would differ from the run's | 0 everywhere (the repair fires only in `retag`, 6,788 cells on rung 1) |
| the load path stays connected | `accepted` would move for a non-stress reason | connected on every `replicate` row |

### The positive control

At refine 1 the subdivision is the identity, so a `replicate` run still executes
the whole reference construction — tag copy, BC rebuild, traction rebuild — and
must land on the margin the run RECORDED. It does:

| rung | recorded margin | reproduced | rel delta | band |
|---|---|---|---|---|
| 0.68 | 2169.617170604274 | 2169.6171633115155 | 3.36e-09 | 1e-06 ✓ |
| 0.52 | 2259.9528152616044 | 2259.9528131892675 | 9.17e-10 | 1e-06 ✓ |
| 0.38 | 2193.8768329099 | 2193.876834561551 | 7.53e-10 | 1e-06 ✓ |
| 0.26 | 2008.2783386128367 | 2008.2783368635692 | 8.71e-10 | 1e-06 ✓ |

and `replicate`@1 is **identical on every gate quantity** to `retag`@1, which is
the shipped setup. (An earlier version of this probe skipped the replicate path at
refine 1. That left the reference's own construction untested at the only
resolution where the right answer is already known; the guard is gone and the
comment says why.)

---

## 4 · S1(b) — what the gate reads, coarse against the reference

Full table: `evidence/.../S1_tables.txt`. Mode `replicate`.
128 → 1,473,696 DOF @ 1.705279 mm · 256 → 11,511,801 DOF @ 0.852640 mm ·
384 → 38,542,350 DOF @ 0.568426 mm.

| rung | | certified (128) | 2× | 3× | error of the certificate vs 2× |
|---|---|---|---|---|---|
| **0.68** | peak von Mises | 0.02535009445 | 0.035713383 | 0.0426728134 | **−29.02 %** |
| | margin worst_case | 2169.6172 | 1540.0389 | 1288.8768 | **+40.88 %** |
| | margin effective | 449.2470 | 318.8848 | 266.8697 | +40.88 % |
| | ACCEPT verdict | true | true | true | unchanged |
| | printed mass (g) | 543.7300261724452 | 543.7300261724452 | — | 0 (same object) |
| | compliance (N·mm) | 0.005400527627 | 0.005438604233 | — | −0.70 % |
| **0.52** | peak von Mises | 0.02433679132 | 0.0338217603 | — | **−28.04 %** |
| | margin worst_case | 2259.9528 | 1626.1720 | — | **+38.97 %** |
| | ACCEPT verdict | true | true | — | unchanged |
| | compliance (N·mm) | 0.005663192112 | 0.005708166735 | — | −0.79 % |
| **0.38** | peak von Mises | 0.02506977563 | 0.02943254701 | — | **−14.82 %** |
| | margin worst_case | 2193.8768 | 1868.6796 | — | **+17.40 %** |
| | ACCEPT verdict | true | true | — | unchanged |
| | compliance (N·mm) | 0.00638547484 | 0.006443254905 | — | −0.90 % |
| **0.26** | peak von Mises | 0.02738664208 | 0.03212295433 | 0.03558420241 | **−14.74 %** |
| | margin worst_case | 2008.2783 | 1712.1713 | 1545.6297 | **+17.29 %** |
| | ACCEPT verdict | true | true | true | unchanged |
| | compliance (N·mm) | 0.007810319124 | 0.007895511185 | — | −1.09 % |

Every one of those stress/margin errors is between **2.2 × 10⁷** and
**6.0 × 10⁷** times the noise floor established in §5.

**The coarse solve can also name the wrong place.** On rung 0.52 the governing cell
at 128 is (17,14,61); at 256 the worst cell lies under coarse cell (126,6,16) — a
different feature entirely, the one that governs rung 0.68.

| rung | peak cell @128 | peak cell @256 (coarse-equivalent) | |
|---|---|---|---|
| 0.68 | (126, 6, 16) | (126, 6, 16) | same |
| 0.52 | (17, 14, 61) | **(126, 6, 16)** | **a different feature governs** |
| 0.38 | (17, 16, 61) | (17, 16, 60) | adjacent cell |
| 0.26 | (17, 17, 60) | (17, 17, 60) | same |

---

## 5 · S1(c) and S1(d) — the split, the noise, and the control

### The split a whole-part number would have hidden

The fine field is reduced onto the COARSE lattice by max over each coarse cell's
children and then classified by the COARSE design's own boundary mask, so both
sides speak about the same population.

| rung | refinement | BOUNDARY peak, error of the certificate | INTERIOR peak, error | ratio |
|---|---|---|---|---|
| 0.68 | 2× | **−29.02 %** | −3.60 % | **8.1×** |
| 0.68 | 3× | **−40.59 %** | −17.23 % | 2.4× |
| 0.52 | 2× | **−28.04 %** | −4.65 % | **6.0×** |
| 0.38 | 2× | −14.82 % | −14.66 % | 1.0× |
| 0.26 | 2× | −14.74 % | −9.37 % | 1.6× |
| 0.26 | 3× | −23.04 % | −16.32 % | 1.4× |

**Reported honestly rather than averaged, because it does not say one thing.** On
the two DENSER rungs at 2× the error is overwhelmingly a boundary effect — six to
eight times the interior's, the brief's expectation confirmed. On the two SPARSEST
it is not: boundary cells are already 52.0 % and 59.7 % of the printed set, so
almost nothing is more than one cell from a surface. And by 3× the interior is
climbing too (−17 % on rung 0.68), because a singular field radiates: a coarse cell
can be interior by the six-neighbour test and still sit one cell from a corner. The
premise "a cell fully inside the material is exact either way" holds on the denser
rungs at one doubling and degrades from there.

### ★ R2 — the reference's own noise, before any difference is quoted

Repeat solves of the fine reference, fresh process, identical arguments, on two
rungs (0.68 and 0.26):

**Bit-identical on every quantity** — peak von Mises, both margins, mass,
compliance, peak displacement, both boundary/interior peaks. Relative spread
**0.000e+00**, and the operator-apply counts match exactly (11,101 twice; 12,953
twice). That is not luck: the matrix-free apply fixes its summation order with an
8-colour partition precisely so the result cannot depend on thread scheduling
(`core/src/fea/matfree.cpp:134-139`).

So the floor is the larger of that (zero) and PR 313's measured warm-versus-cold
Krylov path difference on this same machinery, **8.4e-11 … 6.8e-09**:

```
FLOOR = 6.8e-09 relative
differences quoted above = 0.147 … 0.409  =  2.2e7x to 6.0e7x the floor
```

Wall clock is the one thing that is *not* reproducible: the same solve took 470.8 /
494.6 / 424.7 s across three runs, a ±8 % spread. R4's ratios are 9–45×, so this
does not touch them, but no wall number here should be read to better than ±10 %.

### ★★ The control that rules out every other explanation

| rung | peak von Mises | compliance | peak displacement |
|---|---|---|---|
| 0.68 | **+40.9 %** | +0.71 % | +0.96 % |
| 0.52 | **+38.9 %** | +0.79 % | +1.13 % |
| 0.38 | **+17.4 %** | +0.90 % | +1.10 % |
| 0.26 | **+17.4 %** | +1.09 % | +1.47 % |

Compliance and displacement both rise, which is the textbook direction for a
displacement-based FEM (a finer mesh is softer, converging from below), and both
are settled to about one percent. **The coarse solve is right about the structure
to within 1 % and wrong about one point's stress by up to 29 %.** A wrong load, a
wrong clamp, a mis-mapped design, a non-converged CG or a changed geometry would
every one of them have moved the compliance as well. What is wrong is the stress
RECOVERY at a point, not the solve.

---

## 6 · ★ The third point — the peak does not converge

Two resolutions can say "the coarse answer is X % off the finer one". They cannot
say whether the finer one is itself converged, and that is the difference between
"your margin is overstated by X %" and "this quantity has no value to be right
about". So a third refinement, 3× (resolution 384, 12,642,048 voxels,
38,542,350 DOF), on two rungs.

**4× was refused, with numbers rather than a shrug.** Peak RSS measured: 0.385 GB
at 1×, 2.42 GB at 2×, 3.60 GB at 3×. A 4× run is 29.97 M voxels and ~91 M DOF —
roughly 19 GB by the same scaling, on a 16 GB machine, at an estimated 4–5 hours
per rung. 3× is the affordable third point and it delivers what 4× was for.

| rung 0.68 | h (mm) | peak, centroid | peak, free surface |
|---|---|---|---|
| 128 | 1.705279 | 0.02535009445 | 0.03325949272 |
| 256 | 0.852640 | 0.035713383 | 0.04520530648 |
| 384 | 0.568426 | 0.0426728134 | 0.05355546359 |

| rung 0.26 | h (mm) | peak, centroid | peak, free surface |
|---|---|---|---|
| 128 | 1.705279 | 0.02738664208 | 0.03277851384 |
| 256 | 0.852640 | 0.03212295433 | 0.039444575 |
| 384 | 0.568426 | 0.03558420241 | 0.04437125528 |

Written as `peak ~ h^−q`, one q per refinement step:

| rung | 128 → 256 | 256 → 384 | surface read, same two steps |
|---|---|---|---|
| 0.68 | **q = 0.4945** | **q = 0.4391** | 0.4427 → 0.4180 |
| 0.26 | **q = 0.2301** | **q = 0.2524** | 0.2671 → 0.2903 |

**q is not collapsing. A convergent quantity's would.** For reference: the stress
exponent at a 2-D re-entrant 90° corner is 0.4555, and at a crack, 0.5. Rung 0.68
sits on the first; rung 0.26's weaker 0.24 is a shallower effective corner. Both
are non-vanishing over a 3× range of element size.

**So the peak von Mises this certificate reads has no continuum limit on these
geometries.** Richardson extrapolation is unavailable; there is no "true margin" to
quote. What can be quoted, and is, is how far the number moves per refinement.

Three consequences, all of which matter to the decision in §8:

1. **"The certificate is 41 % too high" must be read precisely.** It is 41 % higher
   than the value at half the element size. It is not 41 % away from a right
   answer, because there isn't one.
2. **No amount of solver work fixes this.** Certifying at a finer resolution buys a
   different number, not a better one, and pays 45× the wall clock for it.
3. **Only the GEOMETRY or the STRESS MEASURE can fix it.** Remove the re-entrant
   corners (a genuinely smooth boundary) and the quantity may become well posed;
   or stop taking a point maximum (a p-norm, or a stress averaged over a physical
   length such as the layer height) and it is well posed on any geometry.

The physics footnote, stated so nobody over-reads the result: real PLA does not
carry infinite stress at a corner — it yields locally and redistributes. The
divergence is a property of the linear-elastic model the certificate uses, not of
the part. That does not make the number harmless; it makes it arbitrary, because
its value is set by the mesh rather than by the material.

---

## 7 · Root cause, with file and line

1. **The certificate reads the stress at the CELL CENTRE.**
   `core/src/simp/analyze.cpp:355`:

   ```cpp
   const Hex8Stress st = hex8_stress(params.youngs_modulus, params.poisson,
                                     grid.spacing, ue);
   ```

   `hex8_stress`'s `(xi, eta, zeta)` default to `(0, 0, 0)` —
   `core/include/topopt/fea.hpp:132-134`, "Defaults to the element centroid". That
   is the right place to sample an element's MEAN stress (it is the superconvergent
   point of a trilinear hex) and the wrong place to sample the stress at a free
   surface.

2. **The peak sits on a member two elements thick, and your own run already said
   so.** `report.json`, all four rungs: `binding_term: "min_feature"`,
   `binding_value: 2`, `required_value: 2`, `ratio: 1`, and the resolution
   recommendation names "THIS design's measured thinnest member (3.411 mm)" —
   exactly 2 × the 1.705 mm voxel. `min_feature_violations` is 407 / 598 / 619 /
   740.

3. **The stress falls steeply into that member.** Walking inward from the peak
   voxel through your own `fields.bin` (`s1c_peak_profile.py`):

   | rung | outward face | member depth | von Mises, first two cells inward | drop in ONE cell |
   |---|---|---|---|---|
   | 0.68 | +x | 14 voxels | 0.02535 → 0.02030 | −19.9 % |
   | 0.68 | +y | 7 voxels | 0.02535 → 0.01406 | −44.5 % |
   | 0.52 | −x | **2 voxels** | 0.02434 → 0.01782 | −26.8 % |
   | 0.38 | −x | **2 voxels** | 0.02507 → 0.01857 | −25.9 % |
   | 0.26 | −x | **2 voxels** | 0.02739 → 0.01953 | −28.7 % |

4. **So two innocent facts compose into a systematic optimism.** The optimizer works
   at its own resolution floor — the min-feature filter radius pins at 1.5 voxels
   once the part exceeds about 107 mm, and yours is 218 mm — and the certificate
   then reads the surface stress of those floor-thickness members from their cell
   centres. Neither piece is a defect alone.

5. **And the peak cell is FULL on every rung** (`rho = 1`, `tag = Surface`, 26.5 mm
   and 15.5 voxels from the nearest clamped node on rung 1). It is not a smeared
   cell, not a load cell and not a boundary-condition artefact. This is why §8's
   answer is what it is: cut-cell quadrature changes nothing about a full cell.

---

## 8 · S2 — scope first, then the minimum that answers the comparison

### (a) What cut-cell would cost against the machinery that makes his solve affordable

The matrix-free operator's entire premise is that **every element is the same
cube** — `core/src/fea/matfree.cpp:10-12`:

> exploiting the regular grid where every element is the same unit cube:
> `K(E) = E * Ke`, so each element's contribution scales its reference block by the
> voxel modulus.

One element is one double and 24 ints (`fea_matfree.hpp:56-59`), and the operator's
only dense storage is a single 24×24 block — 576 doubles, **independent of grid
size** (`fea_matfree_operator_storage_doubles`, `matfree.cpp:1250-1252`).

**The lattice shows the shape of extension this architecture admits.** It got in
without breaking any of that because a latticed element is still *scalars against
fixed blocks* — `Ke(C11,C12,C44) = C11·K_A + C12·K_B + C44·K_C`, three fixed
reference blocks (`fea_matfree.hpp:61-68`). Storage stays O(1) in the grid.

**A cut cell is not of that shape.** Its integration domain is a different
polyhedron per cell, so its 24×24 is its own dense matrix and no coefficient vector
against any fixed basis. From that one property:

| what breaks | why | file:line |
|---|---|---|
| operator storage goes O(1) → O(cut cells) | 576 doubles × 8 B = 4.6 kB **per cut cell** | `matfree.cpp:1250` |
| the apply kernel loses its L1-resident block | it is already memory-bound on x/y; each cut element must additionally stream 4.6 kB, every CG iteration, and there are thousands | `matfree.cpp:109-124`, `:130-132` |
| the Galerkin block cache is void for every cut cell | it works because `S = W^T Ke W` is "a purely GEOMETRIC quantity" cached **once per 8-colour parity class**; per-cell Ke destroys the parity key | `fea.hpp:826-840` |
| the coarse-grid operator is undefined | geometric multigrid halves every axis; a cut polyhedron has no coarse counterpart | `coarsen.hpp` |
| **GenEO survives** | it builds its coarse space from local eigenproblems, so it is element-agnostic — and it is not what makes this solve affordable anyway (`geneo_declined_solves: 455` of 457 on his run) | `fea.hpp:997-1045` |

**And the population is not a thin skin.** Boundary cells are **35.9 / 44.6 / 52.0 /
59.7 %** of the printed set across his four rungs. At the lightest rung nearly three
elements in five would be cut.

### (b) ★ The concern it is said to dissolve — corrected, not confirmed

The brief's claim: mapping a smooth design back onto a fixed grid "reintroduces
traditional density-based issues, such as zig-zag or blurred interfaces"; with
cut-cell quadrature nothing is mapped back, because the smooth design is integrated
ON the grid.

**That is a true statement about immersed FEA and it does not transfer to this
pipeline, for a reason that is measurable rather than arguable.** In level-set
topology optimisation the design variable IS a signed-distance function; in the
Finite Cell Method the domain IS a CAD solid. There the design exists independently
of the mesh, so integrating it on a fixed grid genuinely avoids committing it to
one.

**This pipeline's design is not a geometric object.** It is a SIMP density field
that lives on the very grid in question (`design_store.hpp` — "the physical density
field, grid-indexed"), and its values are a stiffness weight, not an occupancy:
`E(rho) = E0·rho^p` with `p = 3`, printed set thresholded at `rho > 0.5`. The only
interface available to cut along is the 0.5 level set of that same field.

So the question becomes empirical: what does that level set actually look like?
Measured (`s2_cut_population.py` → `S2_cut_population.txt`, 8³ sub-samples of the
trilinear interpolant per cell):

| rung | interface band | cells genuinely CUT by the 0.5 level set | median cut fraction | volume a cut scheme would move |
|---|---|---|---|---|
| 0.68 | 54,068 | 34,950 (**64.6 %**) | **0.5000** | −7,288 mm³ (**−1.66 %** of printed) |
| 0.52 | 60,588 | 38,605 (**63.7 %**) | **0.5000** | −5,490 mm³ (**−1.44 %**) |
| 0.38 | 63,228 | 40,077 (**63.4 %**) | **0.5000** | −3,760 mm³ (**−1.13 %**) |
| 0.26 | 64,637 | 40,998 (**63.4 %**) | **0.5000** | −2,498 mm³ (**−0.86 %**) |

**A median cut fraction of exactly 0.5000 is a staircase.** Trilinear interpolation
between binary voxel centres puts the crossing at the edge midpoint, which is what
PR 314 measured independently (91 % of design-lattice crossings within 1 % of the
midpoint). So a cut-cell scheme fed this design would not integrate a smooth
boundary — **it would integrate the same staircase, shifted half a voxel, and
reallocate about 1 % of the volume doing it.** It would keep every re-entrant
corner, and §6's divergence with it.

**So: correction, not confirmation.** The concern is real; cut-cell dissolves it for
a design that IS a geometry; this design is not one. Making it one is the
optimizer's business — the parallel task's, not this one's. **Which is the answer to
"can we implement certification at the same time": you can, but on today's design
representation it would buy you a 1 % volume reallocation and none of the measured
error, at the cost of the matrix-free operator.** The order that pays is: get the
smooth boundary out of the optimizer first, then the quadrature has something to
integrate and the peak has a chance of being well posed.

**One consequence nobody has priced, flagged because it is not in the brief's scope
list.** Today a printed voxel contributes its whole volume to mass and to the
achieved volume fraction. A cut cell would contribute a fraction. On these rungs
that is a 0.86–1.66 % shift in reported mass and in the volume fraction — and both
are currently compared EXACTLY: the achieved-fraction check at
`run_job.cpp:5397-5407` uses a 1e-9 relative tolerance, and the mass appears in
every receipt. A cut-cell certification lands squarely on those.

### (c) The minimum that answers the comparison

Since the measured error is a **quadrature-POINT** error and not a
quadrature-DOMAIN one, the minimum instrument is not a cut cell. It is: **read the
same solve at the free surface instead of the cell centre.**

`hex8_stress` already takes the evaluation point (`fea.hpp:126-134`), and natural
coordinates map straight onto the grid axes — node 0 of `fea_element_nodes` is
(i,j,k) at (xi,eta,zeta) = (−1,−1,−1), `core/src/fea/hex_element.cpp:14-16`. So for
every printed boundary cell the probe gathers the element's 24 nodal displacements
from `FixedDesignAnalysis::displacement_field` and evaluates the stress at the
centre of each face that looks into void. **No solver, no new element, no
production change.**

### (d) The three columns, and what each costs

Peak von Mises, and the margin the gate would report from it:

| rung | ① certified: centroid @128 | ② the same solve, SURFACE @128 | ③ reference: centroid @256 | ① vs ③ | ② vs ③ | error removed by ② |
|---|---|---|---|---|---|---|
| 0.68 | 0.02535009445 → 2169.62 | 0.03325949272 → 1653.66 | 0.035713383 → 1540.04 | −29.02 % | **−6.87 %** | **76 %** |
| 0.52 | 0.02433679132 → 2259.95 | 0.03153290194 → 1744.21 | 0.0338217603 → 1626.17 | −28.04 % | **−6.77 %** | **76 %** |
| 0.38 | 0.02506977563 → 2193.88 | 0.03006495074 → 1829.37 | 0.02943254701 → 1868.68 | −14.82 % | **+2.15 %** | **86 %** |
| 0.26 | 0.02738664208 → 2008.28 | 0.03277851384 → 1677.93 | 0.03212295433 → 1712.17 | −14.74 % | **+2.04 %** | **86 %** |

**Wall cost per solve** (R4, and the ±8 % caveat from §5 applies):

| | DOF | operator applies | wall | vs 128 |
|---|---|---|---|---|
| ① centroid @128 | 1,473,696 | 6,355–7,322 | 46.8–50.7 s | 1× |
| ② surface @128 | same solve | **+0** | **+0.0 s** (a re-read of `displacement_field` over 31,707–34,969 cells) | **1×** |
| ③ centroid @256 | 11,511,801 | 11,101–12,953 | 470.8–597.3 s | 9.3–12.5× |
| centroid @384 | 38,542,350 | 16,193–18,953 | 2,145–2,268 s | 44.7–44.8× |

**So column ② buys 76–86 % of the accuracy of column ③ for none of its cost.** Two
honesty notes on it, both of which a production fix must address:

* the centroid is the superconvergent point of a trilinear hex and a face is not,
  so a shipped version should extrapolate from the 2×2×2 Gauss points (standard
  practice) rather than sample the face directly. The face value here is the FE
  solution's own strain at that point, which is enough to price the idea and not
  enough to ship it;
* **it does not converge either.** The surface read's own q is 0.4427 → 0.4180 and
  0.2671 → 0.2903 (§6). It is a better estimate at any given h; it is not a
  well-posed limit. Nothing sampled at a point can be, on this geometry.

---

## 9 · The other question: the whole job re-discretized at 2×

`replicate` answers "was the coarse SOLVE right about this object". `retag` answers
"what would this JOB say if it were RUN at 256", which moves the load case as well
as the mesh. Reported because a reader will ask, and because one of its results
would be alarming if left unexplained.

**It flips the verdict on all four rungs, and the reason is not stress.**

```
retag, rung 0.68, 256:
  tag repair : 6788 fine voxels forced solid (design occupied, the 2x CAD
               voxelization dropped them)
  load path  : connected=FALSE   Load voxels 20606 (3446 NOT printed)
                                 Fixture voxels 13392 (0 NOT printed)
  ACCEPTED   : false  (load_path_ok=FALSE, margin_effective >= margin_stop 1.5)
```

`accepted = load_path_ok && (margin_effective >= margin_stop)`, and the belt is
false BY CONSTRUCTION when a Load-tagged voxel is not itself printed — `voxel.hpp`
says so in as many words: "A Load voxel that is not itself printed is unreachable
by construction, hence false: the load face has been carved away." At 256 the CAD
re-tagging puts the load on a skin half as thick, and **3,446 of the 20,606
Load-tagged voxels land on material the 128 design had already carved.** The verdict
moved for a tagging reason, in the mode that exists to price tagging. That is why
the reference does not re-tag, and why the probe prints those counts beside the
bool: a moved verdict must be attributable, not merely observed.

**And re-tagging is not uniformly milder, which is worth knowing before anyone
proposes "just certify at a finer resolution".**

| rung | certified | `retag` @256 | `replicate` @256 (reference) |
|---|---|---|---|
| 0.68 | 0.02535009445 | 0.03128073352 (−18.96 %) | 0.035713383 (−29.02 %) |
| 0.52 | 0.02433679132 | 0.02942717265 (−17.30 %) | 0.0338217603 (−28.04 %) |
| 0.38 | 0.02506977563 | 0.03037113681 (−17.46 %) | 0.02943254701 (−14.82 %) |
| 0.26 | 0.02738664208 | 0.03321974491 (−17.56 %) | 0.03212295433 (−14.74 %) |

On the denser rungs re-voxelizing the CAD smooths away staircase corners the 128
grid manufactured, and the peak comes out below the reference; on the sparser rungs
it goes the other way. Both are true answers to different questions.

---

## 10 · S3 — the caveat this task carries

**(a) S1's result is a LOWER BOUND on the difference.** These designs are
staircases: the boundary lies on cell faces, so the outermost element is a full
element of material and the gap between "this element's mean stress" and "the
stress at the real surface" is as small as it can be. On a genuinely sub-voxel
boundary that outermost element would be part material and part void, its mean
diluted further, and the same reading would sit further from the surface value, not
closer.

**(b) The result is CONCLUSIVE, not provisional.** The difference is 15–29 % on the
peak and 17–41 % on the margin against a noise floor of 6.8e-09 — seven orders of
magnitude clear, on all four rungs, with the compliance control (§5) excluding every
competing explanation and a third resolution (§6) excluding "the reference is just
as wrong". It does not need re-measuring on a SEMDOT design to be believed.

**One thing about it does turn on the parallel task, and it should be said rather
than implied: the CURE does.** §6's divergence is a property of the staircase's
re-entrant corners. A SEMDOT design with a genuinely smooth sub-voxel boundary would
not have them, and the peak may become a convergent quantity again — at which point
a finer certification solve, or a better stress recovery, is a fix rather than a
moving target. On a staircase it is not. So: **the error is conclusive; the remedy
is what `semdot-does-it-come-out-smoother` may change.** And §8(b) is the
counterpart: the boundary algorithm needs the optimizer to produce a smooth design
before the quadrature has anything smooth to integrate.

**(c) The one-line handoff the successor needs.**

> The certified peak von Mises is recovered at the element CENTROID
> (`analyze.cpp:355`) on members that are two voxels thick, so it under-reads the
> surface stress by 15–29 % and overstates the margin by 17–41 % on the
> maintainer's run; refining does NOT converge it (q = 0.49 → 0.44 over 128/256/384,
> the re-entrant-corner exponent), so there is no true value to extrapolate to —
> reading the same solve at the element face recovers 76–86 % of it for free, but
> the fix for the rest is the boundary geometry or the stress measure, never the
> mesh and never the quadrature domain.

---

## 11 · Bars

| bar | status |
|---|---|
| **R1** byte-identical when off | ✅ `evidence/.../R1_byte_identity.txt`. S1 and S2 change NO production file: `git diff main -- core/src core/include app/TopOptKit/Sources` is empty, printed in the evidence. `topopt-cli` rebuilt from ONE folder at the branch and at the merge base hashes identically, with a **negative control** arm (one production string changed) proving the comparison can see a change, and an A/A2 arm proving the build is reproducible in that folder. |
| **R2** no difference quoted without the reference's noise beside it | ✅ §5. Repeat fine solves on two rungs are **bit-identical**; floor taken as PR 313's 6.8e-09; every difference is annotated with its multiple of that floor in `S1_tables.txt`. |
| **R3** every number on his part, all four rungs | ✅ every table is worker job `ca62f91cba4b422d`, all four rungs. Nothing is measured on a sphere or a fixture. The 3× third point is two rungs and says so. |
| **R4** iterations and wall, always both, separately | ✅ §8(d). `analyze_fixed_design` does not return `CgInfo`, so work is reported as OPERATOR APPLIES and the applies-per-CG-iteration ratio is **measured, not assumed**, by calling `simp_compliance` directly on identical arguments — 5150 iterations / 6355 applies = 1.234 at 128, and 9896 / 11101 = 1.122 at 256. Wall is reported separately with a measured ±8 % run-to-run spread. |
| **R5** no verdict moves on the shipped path | ✅ nothing ships. The reference keeps every rung ACCEPTED at every resolution; the verdicts that move are in `retag` mode and §9 attributes them to the load-path belt, with counts, rather than to stress. |
| **R6** never weaken or delete an assertion | ✅ `evidence/.../R6_assertion_census.txt` — message census over both test trees, the deleted-test sweep over this branch's own diff, and the ctest registration list. CHECK sites 3950 → 3950; no core assertion message removed; no app test function removed; every XCTAssert kind non-decreasing; no test file deleted or shrunk; `add_test` count unchanged. |
| **R7** root cause with file and line; no placeholders; no scratch at the repo root | ✅ §7. `git status` clean at the repository root; every temporary artifact went to the session scratchpad. |
| **R8** separate commit for any review response | pending review |

**Suites.** core `ctest` **115/115**, configured `-DTOPOPT_REQUIRE_DEPS=ON` with
OCCT, Eigen and lib3mf so the denominator is CI's (`ctest -N` = 115; CI's 114 plus
the one PR 313 added). No app change, so `swift test` is not in this task's path.

---

## 12 · Files

**New**

| file | what |
|---|---|
| `core/tests/harness/boundary_cell_probe.cpp` | the probe (`EXCLUDE_FROM_ALL`, not a ctest) |
| `evidence/2026-08-08-how-wrong-is-the-boundary-cell/` | scripts, raw output, tables, bars — see its `README.md` |

**Changed**

`core/CMakeLists.txt` — the `EXCLUDE_FROM_ALL` block declaring the harness, inside
the existing OCCT-gated section. Nothing else.

---

## 13 · Open

1. **Nothing here is shipped, deliberately.** S1 measures and S2 scopes; the
   surface-read column is an instrument, not a feature. The production change it
   argues for — Gauss-point extrapolation to the free surface — is not written.
2. **The stress measure is the real decision.** §6 says a point maximum on a
   staircase has no limit. A p-norm, or a stress averaged over a physical length
   (the layer height is the natural one), would be well posed on any geometry and
   would change every margin in the product. That is a bigger call than this task
   and it should be made deliberately, not inherited.
3. **The mass / volume-fraction consequence of cut cells** (§8(b) last paragraph)
   is unpriced beyond the 0.86–1.66 % figure, and it lands on an exact 1e-9
   comparison at `run_job.cpp:5397-5407`.
4. **The 3× point exists on two rungs, not four.** 0.52 and 0.38 have one
   refinement each, so their q is not quoted. Two more 3× runs at ~36 minutes each
   would close that.

---

## In plain language

**Are the safety margins on the parts you have already exported right?**

No. They are too optimistic — the parts are carrying more stress than the
certificate says.

**By how much, and in which direction?**

Solve the identical design with elements half the size and the margin on your first
variant drops from 2170 to 1540 — the certificate was 41 % high. Halve them again
and it drops to 1289. Across the four variants one halving costs between 17 % and
41 %, always in the direction that flatters the part.

Here is why, and it is simpler than the theory we set out to test. The program works
out the stress at the **middle** of each little cube. That is the right place for the
average stress inside that cube, but what the safety check needs is the stress at
the **surface**, which is where things break. Your part's thin walls are only two
cubes thick — your own report already says so, flagging a thinnest member of
3.411 mm, exactly two cubes — so the program measures a quarter of the way in from
the surface and calls it the surface. Read the very same calculation at the face of
the cube instead of its middle and the number jumps 20–31 %, recovering three
quarters of the gap for no extra computing at all.

**Does it make anything you printed unsafe? No.** The gate asks for 1.5 and you have
449; even at the finest resolution I ran you would have 267. Every variant stays
accepted at every resolution. Your part is enormously over-strength for this load,
and 41 % off an enormous number is still an enormous number. It would matter on a
job whose margin came out near 1.5 — there the same error decides accept or reject.

**The honest limit: I cannot tell you the right number, because there may not be
one.** Your designs come out of the optimizer as staircases, and at the inside
corner of every step the mathematics of an ideal elastic solid says the stress is
infinite. I measured how fast the number climbs as the cubes shrink, across three
resolutions, and it is not slowing down — it climbs at exactly the rate theory
predicts for a sharp corner. Real plastic does not do this; it yields a little and
shares the load around. But the calculation does not know that, so the finer you
chop, the bigger a number it reports, with no end. **The margin on your report is
therefore not a wrong number so much as an arbitrary one: its value is set by how
finely the part was chopped rather than by the plastic.**

**And on the boundary algorithm you are considering:** on these designs it would not
have helped. I measured what it would actually have had to work with. The only
surface it could cut along runs exactly through the midpoints of the cubes — it is
the same staircase shifted half a cube — and adopting it would move about one
percent of the material and keep every sharp corner. To get the benefit, the
optimizer has to produce a genuinely smooth boundary first; then the quadrature has
something real to integrate, and the stress number has a chance of settling down.
The two changes are worth making together, in that order, and neither alone gets you
a trustworthy margin.
