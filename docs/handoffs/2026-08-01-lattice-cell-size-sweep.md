# Cell size as AUTO / FIXED / SWEPT

**Date:** 2026-08-01
**Scope:** `core/` + `app/`. The gate is untouched. No fixture, materials.json,
ARCHITECTURE.md or DECISIONS.md change.
**Builds on:** PR 198 (offline homogenization library), PR 235 / handoff
2026-07-28-graded-cell-size-phase0 (the C1 scale-invariance and C4 dyadic
measurements this feature rests on), PR 254-263 (the lattice page, the grading law,
the strut-strength out-of-regime reporting pattern).
**Harness:** `core/tests/harness/cell_sweep_probe.cpp` (standalone, not in CTest).
**Evidence:** `evidence/2026-08-01-lattice-cell-size-sweep/`.

---

## TL;DR

1. **The three design questions are answered, and the answers were measured, not
   assumed.** The tensor is cell-size invariant (0.000e+00, against a stated 1e-9
   tolerance). The cells-per-member floor is enforced **per cell** by making it an
   upper bound on that cell's size. Cells of different size meet **dyadically, on an
   aligned octree** — and that is the only rule of the three candidates that works.

2. **★ The transition rule is DYADIC OCTREE, and it needs NO new generator
   architecture.** Restrict cells to `S0 · 2^L` on aligned `2^L` blocks and every node
   of a coarse cell lands on a base-grid node position, so the levels meet at SHARED
   nodes with zero bridge struts. Generation is then just **one ordinary pass per
   level** over the existing generator. Measured on a real 4 → 8 mm part: **ZERO
   floating strut ends** out of 44,256 endpoints checked, with 15,520 of those
   endpoints landing on shared coarse-node positions (so the check is not vacuous).

3. **The feature is real but it does NOT rescue the Phase-0 BLOCKED-STOP, and this
   handoff does not pretend otherwise.** PR 235 asked "can the cell GROW so a
   low-density strut stays printable in a thin member?" — the answer was and remains
   no. This feature asks a different question — "can the cell FOLLOW DEMAND per
   region?" — and there the answer is yes, with the payoff in **thick** regions. In a
   thin member the two bounds still cross, and the law leaves that material **SOLID**
   and counts it.

4. **A fixed-cell job is byte-identical.** `CellSizeMode::Fixed` is the default, takes
   the pre-sweep code path unchanged, and leaves the posture's per-voxel cell field
   empty. Stash-rebuild checksums in `r1_byte_identity.txt`.

---

## The three design questions

### Q1 — Does a varying cell size break the homogenized tensor? **No. Measured.**

**Tolerance, stated before measuring:** relative deviation ≤ **1e-9** on each of
C11, C12, C44 at a fixed relative density across cell sizes.

Two independent measurements, both at 0.000e+00:

**(a) The physics** (`c1_scale_invariance.csv`, `r2_cell_invariance.txt`) — periodic
homogenization of the resolved octet cell at 4 / 8 / 16 / 32 mm, at fixed `r/L`, over
six (target rho, voxels-per-cell) combinations:

| target rho | vpc | cell range | strut d range | C11 | C12 | C44 | max rel dev |
|---:|---:|:--|:--|---:|---:|---:|---:|
| 0.20 | 16 | 4 → 32 mm | 0.75 → 6.00 mm | 111.809 | 52.329 | 45.514 | **0.000e+00** |
| 0.20 | 24 | 4 → 32 mm | 0.83 → 6.67 mm | 239.499 | 104.020 | 91.156 | **0.000e+00** |
| 0.20 | 32 | 4 → 32 mm | 0.80 → 6.40 mm | 208.232 | 92.156 | 80.865 | **0.000e+00** |
| 0.40 | 16 | 4 → 32 mm | 1.25 → 10.00 mm | 747.394 | 263.063 | 234.583 | **0.000e+00** |
| 0.40 | 24 | 4 → 32 mm | 1.19 → 9.52 mm | 597.888 | 223.469 | 198.175 | **0.000e+00** |
| 0.40 | 32 | 4 → 32 mm | 1.14 → 9.11 mm | 635.971 | 232.498 | 208.696 | **0.000e+00** |

Every one of the 24 rows carries `0.00e+00` in all four deviation columns. The strut
**diameter** spans 8× at a byte-identical tensor.

**(b) The SHIPPED lookup** (`r2_production_lookup.csv`) — the part a swept posture
actually depends on. `octet_relative_density(cell, r)` then
`lattice_cubic_tensor(topo, rho, Es)`, queried at fixed `r/L` across **2 / 4 / 8 / 16
/ 32 mm** (a 16× range) at four ratios. Worst relative deviation on rho and on all
three constants: **0.000e+00**.

**Why it is exact rather than approximate:** the library is keyed on RELATIVE
DENSITY, and relative density is a *ratio* of strut volume to cell volume — it cannot
see the cell size. At fixed `r/L` the voxel occupancy pattern is identical and hex8
homogenization is a uniform mesh scaling (`CH ~ h³/h³ = 1`).

**Consequence for the build:** a varying cell size perturbs the certification solve by
**exactly nothing**. `LatticePosture::cell_size_mm` was already documented as "not
used in the math", and that stays true. What a swept cell changes is only *which
voxels clear the cells-per-member regime* — which is why the whole feature reduces to
a geometry-and-reporting problem, not a certification-physics one.

### Q2 — How is the cells-per-member floor enforced per region rather than per part?

**By making it an upper bound on the cell, evaluated per cell against that cell's own
thinnest member.** For each base cell the plan computes:

- `cap` = the **largest** dyadic level whose cell still spans ≥ N\* cells of the
  thinnest member in that cell — the homogenization ceiling, `S ≤ W_min / N*`;
- `need` = the **smallest** dyadic level whose strut at the thinnest **rho** in that
  cell still prints at the stated minimum width — the printability floor.

The chosen level is `need`, and it is only taken when `need ≤ cap`. Both are computed
from the **conservative end** (min width, min rho) over the cell's voxels, so a
guarantee proved on them holds for every voxel inside.

Three things follow, all of them measured in `r3_r5_per_region.csv`:

- **A cell whose bounds CROSS is not latticed at all** — it stays SOLID and is counted
  in `cells_dropped_unprintable`. On the three-zone fixture: **1,600 cells dropped**.
  This is the per-cell form of the L4 fallback the scalar law already applied per part.
- **Cells raised for printability are counted** — `cells_raised_to_floor`: 96 of 864
  (11.1%) on the 4→8 sweep, 1,088 of 37,952 (2.9%) on a 2→8 sweep.
- **The 2:1 balance can only split**, never coarsen. Splitting shrinks a cell, which
  strictly *helps* the ceiling, so balancing can never push a cell out of the
  certifiable regime. It can break printability, and a cell that lands there is
  dropped to solid rather than printed under-width.

`grade_lattice` and `plan_cell_sizes` each **assert** these invariants over every
emitted voxel before returning, and throw `std::logic_error` rather than return a
poisoned posture.

### Q3 — How do cells of different size MEET? **Dyadic octree, at shared nodes.**

This is the hard part, so here is the actual argument.

The octet cell's 14 nodes are its 8 corners (integer multiples of the cell edge `S`)
and its 6 face centres (one coordinate at `S/2`). Restrict admissible cells to the
dyadic ladder `S_L = S0 · 2^L` and place every cell on an **aligned** `2^L` block of
the base grid, and every node of a level-`L` cell sits at a multiple of
`S_L/2 = S0 · 2^(L-1)`, which for `L ≥ 1` is a multiple of `S0` — **a node position of
the base grid**. Coarse nodes NEST in the fine grid. The two levels therefore meet at
shared nodes, and there is no bridging geometry to get wrong because none is needed.
PR 235's C4 measured exactly this on resolved geometry (zero bridge struts, zero extra
transition triangles) and named it as what slicers' adaptive-cubic infill already does
on real prints.

**The two alternatives were considered and REJECTED, on measurements that already
existed:**

- **Conformal warp** (smoothly stretch the cell). PR 235's C5: an ~8% per-cell stretch
  drives `Ez/Ex` to 1.15, and 100% drives it to 4.1. The cell stops being cubic, and
  the certification library carries exactly one *cubic* tensor per topology.
  Certification-fatal — it would need a per-cell orthotropic tensor that does not
  exist.
- **Banded regions** with a gap or a hand-stitched interface. Needs bridge geometry no
  measured tensor covers, and any missed bridge is a floating strut end — the REJECT
  condition this task named.

**Why no floating ends, structurally:** within a level, the generator's existing
ownership rules already guarantee a node ball at every strut endpoint of an active
cell (the `node_owner` lex-smallest-active-sharer fallback). Across a seam, a coarse
cell simply sees no active neighbour on the fine side *of its own grid*, so
`owns_leg` makes it emit its own boundary legs, and the fine cells emit theirs. Both
sides' solids interpenetrate at the shared node — the same union discipline the whole
triangle soup already rests on.

**And it is measured, not asserted** — see R4 below.

**The cost, stated:** coincident node balls at a seam are emitted once per level. There
is no cross-level dedup, because a global dedup set would destroy the generator's
streaming / flat-RSS property. They are counted in `nodes` and reported, never
silently removed.

---

## The bars

### R1 — a fixed cell is byte-identical ✅

`CellSizeMode::Fixed` is the **default** value of the new field, so every existing
caller keeps its exact behaviour with no edit. The Fixed/Auto branch of
`grade_lattice` is the pre-sweep loop verbatim, `plan_cell_sizes` refuses to run in
any mode but Swept, `LatticePosture::cell_size_field` stays **empty**, and
`export_latticed_variant` takes the single-cell path (the level vector is empty).
The job schema treats an absent `cell_mode` as `"fixed"` and still requires `cell_mm`,
so a pre-sweep job.json parses to exactly the same `JobGrading`.

**Measured** (`r1_byte_identity.txt`): the same fixed-cell job (60 mm cylinder, res 32,
octet, `cell_mm` 3.0 raised to the 4.383 mm printability floor, 18,624 voxels latticed)
run on a stash-rebuilt PRE-feature core and on the feature core. All five outputs —
`variant_100.stl`, `variant_100_lattice.stl`, `report.json`, `fields.bin`,
`variant_100_lattice.report.json` — are **byte-identical** (SHA-256 match on every one).

### R2 — cell-invariance of the tensor, measured ✅

Tolerance stated first (1e-9); measured **0.000e+00** on both the physics and the
shipped lookup. Full table in Q1 above.

### R3 — struts stay printable everywhere, per cell ✅

Enforced per cell, never averaged over the part, and asserted before return.
From `r3_r5_per_region.csv` on the three-zone plate:

| sweep | min extrudable | min strut emitted | max strut | cells raised to floor | cells dropped (bounds crossed) |
|:--|---:|---:|---:|---:|---:|
| 4 → 8 mm | 0.80 mm | **1.1396 mm** | 1.5343 mm | 96 / 864 (11.1%) | 1,600 |
| 4 → 16 mm | 0.80 mm | **0.8500 mm** | 1.6347 mm | 64 / 5,696 (1.1%) | 0 |
| 2 → 8 mm | 0.60 mm | **0.6442 mm** | 1.6347 mm | 1,088 / 37,952 (2.9%) | 0 |

Every case clears its stated minimum, and the `any_strut_below_min` tripwire never
fires.

### R4 — the transition is sound and measured ✅

A real demand-driven 4 → 8 mm transition (the three-zone plate; the seam sits where
the demand drop makes the fine cell's struts unprintable). Emitted: 22,128 struts,
4,200 nodes, 792,096 triangles across two levels.

**(a) Connectivity — PR 250's bar:**

| metric | value |
|:--|---:|
| strut endpoints checked | 44,256 |
| **FLOATING ends** | **0** |
| endpoints on shared (coarse-node) positions | 15,520 |

Coverage is judged on the emitted prism's **inscribed** radius (`r·cos(π/8)`), not the
circumscribed cylinder — so "covered" means covered by the real emitted solid, never
by an idealisation.

**(b) Local density error at the seam.** The emitted solid is voxelized at 0.25 mm
(the real interpenetrating union, overlaps counted **once**), sampled in slabs one
*coarsest* cell wide, restricted to voxels the posture actually lattices, and
bracketed by the prism's in/circum radius:

| | seam vs its own level's bulk |
|:--|---:|
| 4 mm level | **1.50%** |
| 8 mm level | **6.45%** |

**A pre-existing offset, surfaced not hidden.** The absolute emitted-vs-claimed
numbers carry a systematic offset (−9.8% at the 4 mm level, **+69.4%** at the 8 mm
level). That is **not** a seam effect and **not** caused by sweeping: it is the
labelling gap `lattice.hpp` already documents — the shipped "octet" density/tensor
rows were measured on **legs-only** geometry (fc↔corner), while the production
generator meshes the **full** octet, legs plus the 12 octahedral braces. Verified
analytically alongside the harness: the full octet is exactly **2.00×** the strut
volume per cell at every density tested. It is present identically at a fixed cell
size. The seam verdict above deliberately compares each seam slab against the bulk of
its **own cell size**, which cancels everything that is a property of the cell size
rather than of the transition.

**This is worth a follow-up task** — a +69% gap between what the receipt claims and
what the file contains is a real reporting defect, just not this task's.

### R5 — cells-per-member reported per region ✅

A **region is one cell size**. `run_info.grading.cell_levels[]` carries one entry per
dyadic level with its cell size, cell/voxel counts, thinnest member, that member's
span in cells, its strut-diameter range, and an `out_of_regime` flag — flagged exactly
the way PR 263 flags `lattice_strut_out_of_regime`. The flag is a **tripwire measured
after the fact**, independent of the law that built the plan, so a true value is a bug
report rather than a mode.

| level | cell | cells | voxels | min member | min cells/member | min strut | regime |
|---:|---:|---:|---:|---:|---:|---:|:--|
| 0 | 4.00 mm | 768 | 49,152 | 24.00 mm | 6.00 | 1.5343 mm | in regime |
| 1 | 8.00 mm | 96 | 49,152 | 40.00 mm | 5.00 | 1.1396 mm | in regime |

The 8 mm level lands at **exactly 5.00** cells per member — the floor, hit precisely,
which is the ceiling doing its job rather than a coincidence.

`analyze_fixed_design`'s own regime guard now evaluates per voxel at that voxel's own
cell when the posture carries a `cell_size_field`, and is the unchanged scalar test
when it does not.

### The swept path in PRODUCTION, end to end (`r4_swept_e2e.txt`)

`topopt-cli run` on a 60 mm cylinder (res 32, octet, sweep 4 → 16 mm, min extrudable
0.4 mm) exercises the whole chain — grade → plan → multilevel export → certify:

| | |
|:--|---:|
| candidate base cells | 2,775 |
| latticed | **1,440 cells / 13,504 voxels** |
| dropped, bounds crossed (`need > cap`) | **300** |
| rejected by the ceiling even at the base cell (`cap < 0`) | 1,035 |
| min / max strut | 0.6256 / 1.5343 mm (stated min 0.4) |
| out of regime | none |

**Read this honestly: the sweep RESOLVES TO ONE LEVEL on this part.** No cell needed
coarsening, and the 300 that did — their struts are unprintable at 4 mm — could not
have it, because a coarser cell would breach the cells-per-member ceiling. They stayed
SOLID. That is the Phase-0 conflict reappearing in production, reported rather than
hidden. The multi-level case with a real 4 → 8 mm seam is the harness fixture (R4), a
part deliberately shaped to hold both.

**A second honest number from the same run:** the thickest per-cell member anywhere on
this cylinder is **22.50 mm**, so a 5 mm base cell (needing 25 mm at N\* = 5) is refused
*everywhere* — an earlier 5 → 20 mm attempt latticed nothing at all and said so. The
per-cell `width_min` is the MIN over the cell's voxels, so it is strictly more
conservative than the per-voxel test the uniform law applies; a part can therefore
lattice under Fixed and refuse under Swept at the same nominal cell. That is the
intended direction (a whole cell must be certifiable, not just its best voxel), but it
is a real behavioural difference and callers should know it.

### R6 — the app exposes Auto / Fixed / Swept, reading limits from core ✅

New bridge surface, both numbers forwarded from core and neither invented app-side:

```cpp
struct LatticeCellBounds { double printability_floor_mm; double cells_per_member_floor; bool valid; };
LatticeCellBounds lattice_cell_bounds(const std::string& topology, double min_extrudable_width_mm);
```

It forwards core's **one** printability-floor law, `lattice_cell_printability_floor_mm`
— newly extracted in `lattice.hpp` so the grading law, the dyadic plan and the bridge
all call the same function instead of three copies of `min_width / phi(rho_lo)`.

App side: a segmented Auto / Fixed / Swept control on the cell-size card, numeric entry
through the existing `NumberPad` popover (distinct keys for the swept min and max), and
the cell slider's **lower** bound now read from core's floor instead of the app-side
`2...20` literal it used before. Measured live through the bridge: the octet floor is
**4.60 mm** at a 0.42 mm line width, with N\* = 5.0.

Two things the app work settled that are worth carrying:

- **The three job shapes are mutually EXCLUSIVE**, and the schema enforces it:
  `fixed` → `cell_mm`; `auto` → `cell_mode` only (core chooses, so a stated target is
  refused); `swept` → `cell_mode` + `cell_min_mm` + `cell_max_mm` (a target cell
  alongside a ladder is a conflict, not a hint). Emitting `cell_mm` in auto mode would
  fail schema validation — the app emits exactly the right key set per mode.
- **Auto and Swept are gated on the graded path**, because the keys live inside the
  `grading` block and a uniform-density run carries none. Rather than let a uniform run
  silently drop the user's choice, the two segments are greyed with the reason stated,
  and both the summary text and `runSpec` report the fixed cell in that case.

App suite: **1015 tests, 13 skipped, 0 failures.** (A fresh worktree has no vendored
core — `app/scripts/build_core.sh` must run first, and its default build is lib3mf-free,
which fails three pre-existing 3MF tests until `LIB3MF_PREFIX` points at a vcpkg tree.
See [[app-worktrees-need-build-core]].)

### R7 — determinism + ctest ✅

The plan is pure integer/arithmetic sweeps in fixed cell order with no RNG, threads or
atomics; the multilevel generator emits levels in ascending order regardless of the
order the caller supplies them. `test_grading` asserts a byte-identical swept plan
across two runs. Full results in `ctest.txt`.

---

## What changed

**Core**
- `include/topopt/cell_plan.hpp`, `src/simp/cell_plan.cpp` — **new**: `CellSizeMode`,
  `CellSizePlan`, `plan_cell_sizes` (the dyadic octree + 2:1 balance + per-level
  report), `cell_size_field`.
- `include/topopt/lattice.hpp`, `src/fea/lattice.cpp` —
  `lattice_cell_printability_floor_mm`, the one floor law all three readers now share.
- `include/topopt/grading.hpp`, `src/simp/grading.cpp` — `cell_mode` +
  `min/max_cell_size_mm` on the params; `cell_plan` on the report; the Auto and Swept
  branches. The Fixed branch is the old loop verbatim.
- `include/topopt/analyze.hpp` — optional `LatticePosture::cell_size_field`;
  `src/simp/analyze.cpp`'s regime guard becomes per voxel when it is present.
- `include/topopt/lattice_gen.hpp`, `src/mesh/lattice_gen.cpp` —
  `LatticeLevelSpec` + `generate_lattice_multilevel` (one pass per level; the existing
  `generate_lattice` is untouched).
- `include/topopt/job.hpp`, `src/cli/job.cpp` — `grading.cell_mode` /
  `cell_min_mm` / `cell_max_mm`, with conflicting combinations REFUSED rather than
  silently ignored (`cell_mm` alongside `swept` or `auto` is an error).
- `src/cli/run_job.cpp` — mode wiring on both graded call sites, per-level specs for
  the swept export, and one shared `fill_grading_cell_plan` so the analyze and run
  receipts cannot drift.
- `include/topopt/observability.hpp`, `src/simp/observability.cpp` — the cell-mode +
  per-level block in `run_info.grading`.
- `tests/unit/test_grading.cpp` — the three modes, the dyadic-ladder invariant, the
  per-cell regime and printability invariants, swept determinism, and the mode-name
  round-trip.
- `tests/harness/cell_sweep_probe.cpp` — **new**, the R2/R3/R4/R5 harness.

**App** — bridge `lattice_cell_bounds`; Swift `LatticeCellSizeMode`, the settings
fields and their Codable wiring, the segmented control, and the `grading` job keys.

---

## Carried caveats

- **The legs-only labelling gap (R4b) is pre-existing and now quantified at 2.00×.**
  It should be closed as its own task; nothing here depends on it, but the receipt's
  claimed density understates the emitted solid by that factor.
- **The certification mask uses the coarsest cell** for the cell-overlap proof on a
  swept run. Coarser is the conservative direction for that test, and the result is
  intersected with the law's own mask with the difference counted
  (`mask_voxels_dropped_by_cell_overlap`), so nothing is hidden — but a per-level mask
  would be tighter.
- **PR 235's C4 measured the interface stress riser at 1.68×** the lattice's own
  internal concentration for a single factor-2 jump. The 2:1 balance bounds every
  transition to that single jump; it does not remove it.
- **Octet's ±10% resolution caveat still applies** to every absolute magnitude here.
- The reported scalar `cell_size_mm` on a swept run is the **coarsest** level used —
  the conservative choice for a part-scale cells-per-member question. The honest
  per-region numbers are in `cell_levels[]`.

---

## Reproduce

```bash
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON && cmake --build build -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/cell_sweep_probe.cpp build/libtopopt.a -o build/cell_sweep_probe
TOPOPT_LATTICE_CSV_DIR=<dir> ./build/cell_sweep_probe            # R2/R3/R4/R5
TOPOPT_CSW_ONLY=r4 ./build/cell_sweep_probe                      # just the transition
```

The Q1(a) physics rows come from the Phase-0 harness, re-run for this task:

```bash
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/graded_cell_size_probe.cpp build/libtopopt.a -o build/gcs_probe
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_GCS_ONLY=c1 \
  TOPOPT_GCS_C1_LS="4,8,16,32" TOPOPT_GCS_C1_VFS="0.20,0.40" \
  TOPOPT_GCS_C1_VPCS="16,24,32" ./build/gcs_probe
```

---

## In plain language

The maintainer asked for the lattice's **cell size** to stop being one number for the
whole part, and instead be pickable three ways: let the software choose it (**auto**),
type one in (**fixed**), or give a range like 4–8 mm and let it **vary across the
part** the way the strut thickness already does.

**The three things worth knowing.**

*First: making the cells different sizes costs nothing in the strength maths.* The
lattice's stiffness is looked up from how **full** a cell is — the fraction of it that
is solid strut. A fraction is a ratio, so it does not care whether the cell is 4 mm or
32 mm across. We measured this two different ways and got a difference of exactly
**zero** — not "small", zero. So varying the cell size cannot make the strength
certificate wrong. That was the thing most worth checking before building anything.

*Second: the hard part was how two different-sized cells join up.* If a 4 mm cell sits
next to an 8 mm cell, their struts generally do not line up, and a strut whose end
joins nothing is a strut that holds nothing — the software would be printing a
disconnected mess and certifying it as solid structure. The fix is to only allow cell
sizes that **double**: 4, 8, 16, and to line them up on a grid. Do that and the big
cell's corners land exactly on points the small cells already use, so the two sizes
join at shared corners with no special connector geometry at all. We then checked the
real output rather than trusting the argument: of **44,256 strut ends** on a test part
with a genuine 4→8 mm join, **none** were left floating. The two rejected alternatives
were gently stretching the cells (which measurably ruins the strength maths) and
leaving a gap between zones (which is the disconnected-mess case).

*Third — and this is the honest part — this does not fix the problem the earlier study
got stuck on.* Back in July a study found that to keep struts printable in a very
sparse lattice you need a **big** cell, but to trust the strength maths in a **thin**
rib you need a **small** cell, and in a thin rib you cannot have both. That is still
true. What this feature adds is the ability to make that choice **locally instead of
for the whole part**: a thick boss can now take a big cell with fat, easily-printed
struts, while a thin rib next to it takes a small one. Where the two requirements
genuinely conflict, the software does the safe thing — it leaves that bit of the part
**solid metal/plastic** rather than filling it with struts it cannot stand behind —
and it tells you how much it did that (on the test part, 1,600 cells).

**What actually happened when we ran it on a real part.** We put a 60 mm cylinder
through the whole pipeline. It filled about 13,500 voxels with lattice and left 300
patches solid — those are the spots where the struts would have come out too thin to
print at the small cell size, but where making the cell bigger would have meant too few
cells across the part to trust the strength maths. Rather than guess, it left those bits
solid and said so. On this particular part the "range" collapsed to a single size,
because nowhere actually needed the bigger cell. That is the feature behaving correctly,
not failing — but it's a fair warning that a range is an *option* the part may not use.

**One consequence worth flagging if you switch a job from Fixed to Swept.** Swept is
deliberately stricter. Fixed asks "is this individual point thick enough?", while Swept
asks "is this *whole cell* thick enough?" — because the whole cell either gets built or
doesn't. So a part that fills fine on Fixed at, say, 5 mm can legitimately refuse to
fill on Swept at the same 5 mm. On our test cylinder the thickest cell-sized chunk
measured 22.5 mm, just under the 25 mm a 5 mm cell needs, so it refused everywhere and
reported that. If a swept run comes back emptier than you expected, that's the reason,
and the receipt now tells you which of the two limits did it.

**One thing we found that is not about this feature.** While measuring, we found the
software's strength paperwork describes a *simpler* lattice than the one it actually
prints — the real printed lattice has extra internal braces the paperwork does not
count, so it contains almost exactly **twice** the strut material the report claims.
That is a pre-existing bug, not something introduced here, and it makes the part
*stronger* than advertised rather than weaker — but the numbers on the report are
wrong and that should be fixed as its own job.

**What you'll see in the app.** The cell-size control now has three buttons — Auto,
Fixed, Swept. Auto shows you the size the software picked and why. Fixed is what you
had before. Swept gives you two boxes, a smallest and a largest, and you type them on
the same keypad as every other number. The limits on all of them come from the
engineering core, not from numbers typed into the interface, so if the underlying
measurements are ever revised the controls follow automatically.
