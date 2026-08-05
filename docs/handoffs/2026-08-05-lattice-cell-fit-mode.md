# lattice-cell-fit-mode

Branch `claude/lattice-cell-fit-mode-2c28f1`.
Evidence `evidence/2026-08-05-lattice-cell-fit-mode/`.

---

## 0. WHAT CHANGES FOR YOU

**Your 4 mm walls can now hold a lattice.** Set `"cell_mode": "fit"` in the
`grading` block and core derives the cell from each declared include region's own
extent instead of from a constant. On your seven 4 mm regions at your 0.42 mm bead
that is a **1.0950 mm cell at relative density 0.6000**, strut 0.4200 mm, 3.65 cells
across the wall — and it **emits**. Today `"auto"` plans a 4.6026 mm cell, which needs
23.0131 mm of material, and puts nothing in those regions at all.

**Your hand-set `cell_mm` now survives.** A graded job asking for a 1.2 mm cell used to
be silently raised to 4.6026 mm and land straight back in "0.87 cells across". It is now
raised only to 1.0950 mm — the cell below which *no* density in the band prints — and the
density is raised with the cell instead. That is why `cell_mm: 1.2` works on a graded run
now and did not before.

**`"auto"` is untouched.** Every saved job, every past run, every app screen that says
"auto" behaves exactly as it did. Making `auto` mean `fit` is a one-line decision you
take, not one this branch takes for you — `kProductionLatticeAutoIsFit` in
`core/src/simp/production.cpp`, default `false`. §3's flip table is the evidence for
taking it.

**Three things to know before you use it.**

1. A 4 mm wall latticed at 1.0950 mm is **BUILDABLE and OUT OF REGIME**. It prints and
   it percolates; the homogenized certificate over it is not trustworthy, because
   3.65 cells across is under the 5-cell accuracy floor. The receipt says so per region
   and per voxel. Nothing in this task relaxes that floor or hides it.
2. A fine cell is a **big file**. Your l-bracket reproduction emitted a 152 MB STL at
   1.0950 mm where a 4.6026 mm cell emits ~1 MB. §5 has the numbers. This is arithmetic,
   not a defect — an octet cell is ~24 struts and you asked for 4.2× more of them per
   axis — but it is the practical cost of the mode.
3. `fit` is **job-JSON only today**. The app's `LatticeCellSizeMode` (`LatticeSettings.swift`)
   has three cases and would need a fourth. Nothing app-side was changed.
4. ★ **Your job carries a design box, and no graded mode can run with one.**
   `run_job.cpp:5665` refuses a `"grading"` block alongside a `"design_box"` — a
   PRE-EXISTING guard (it is in the stack base verbatim, and it predates this task),
   because the cell plan is chosen before the added-material policy runs. So to use
   `fit` on the WallMount bracket you have to drop the box, exactly as you would for
   `auto` or `swept`. Your own `job_nobox.json` is that job. This is reported, not
   fixed: lifting it means making the grading law's candidate set added-material-aware,
   which is its own task.

**This task does NOT decide where lattice goes.** It only decides how big the cells are
where you have already asked for it. Working out that a lattice could also go somewhere
you did not declare is de-homogenization, and it is a separate, larger piece of work.

---

## 1. ★ READ THIS BEFORE MERGING: THE BRANCH IS STACKED ON PR #298

The brief for this task says `lattice_derive_cell_for_member`,
`lattice_percolation_cells_per_member_min` and "the existing three-case pre-flight"
are in core. **They are not on `main`.** They live on
`claude/lattice-cell-size-adaptation-7ec715` — **PR #298, open and mergeable** at the
time of writing. `main` at `40bf4f8` has none of them.

Rather than write a second copy of a measured derivation, this branch **merges PR #298**
and builds on it. Consequences, all of them yours to weigh:

* This PR's diff against `main` **includes PR #298's**. Merge #298 first and this
  becomes a clean delta; merge this alone and you take both.
* **Bar R1's baseline is PR #298's tip** (`935a77f`), not `origin/main` — that is the
  only control that isolates *this* task's movement. PR #298's own movement against
  `main` is measured in its own evidence (`m5_byte_identity.txt`) and is not re-litigated
  here.
* If #298 is rejected or reworked, this branch carries code you did not accept. Say so
  and it comes out — the three functions it uses are `lattice_derive_cell_for_member`,
  `lattice_min_density_for_strut` and `lattice_percolation_cells_per_member_min`.

---

## 2. THE DEFECT, ROOT-CAUSED

### 2.1 A conservative lower bound was promoted into a selection rule

`lattice_cell_printability_floor_mm(topo, w)` is
`w / phi(lattice_rho_min)` — the smallest cell at which the band's **lightest** strut
still prints. It is a valid *bound*: nothing may be finer *if* the lattice is that light.

`core/src/simp/grading.cpp:120` (at the stack base) read it as an *answer*:

```cpp
const double uniform_cell = params.cell_mode == CellSizeMode::Auto
                                ? floor_mm
                                : std::max(params.target_cell_size_mm, floor_mm);
```

`Auto` **selects** the bound; `Fixed` **raises a user's target to** it. Because the bound
is taken at the extreme of the density band, using it to choose picks the **largest**
cell in the name of printability: 4.6026 mm at a 0.42 mm bead, which needs
5 × 4.6026 = 23.0131 mm of member to clear the cells-per-member floor.

Three faults compound, exactly as the brief states:

1. **It fixes the density and solves for the cell.** The real problem is a joint solve
   over `(cell, rho)`: printability needs `S·phi(rho) >= w` and homogenization needs
   `W/S >= N*`, so the admissible window is `w/phi(rho) <= S <= W/N*` and the widest
   window is at the band's **top**. `lattice_derive_cell_for_member` (PR #298) already
   solves it correctly and takes exactly the input the selection lacked.
2. **Nothing carried the requirement to the chooser.** `lattice_derive_cell_for_member`
   was wired only to *messages*. There was no path from a declared region to the cell law.
3. **Fixed mode's `max(target, floor)` evaluated the floor at `rho_min`**, so it
   overrode a correct hand-set cell upward, guarding against a density nobody selected.

### 2.2 Where each defect is, with file and line (bar R8)

| # | Defect | Site (pre-change) |
|---|---|---|
| D1 | `Auto` selects a bound evaluated at `rho_min` | `core/src/simp/grading.cpp:112-123` (`floor_mm` → `uniform_cell`) |
| D2 | `Fixed` raises a hand-set target to that same bound | same expression, `std::max(target, floor_mm)` |
| D3 | No plumbing from a declared region to the cell law | `lattice_derive_cell_for_member` called only at `run_job.cpp:2311`, `:2313`, `:5615` — all message text (line numbers at the stack base) |
| D4 | The pre-flight's own case-B advice named a remedy the code then overrode | `run_job.cpp:5687` ("★ ON THIS GRADED RUN, SETTING `cell_mm` WILL NOT DO IT") |

D4 is worth pausing on: PR #298 had already **found** D2 and, unable to fix it inside its
own scope, wrote a message telling the user the obvious remedy would not work. That
message is now false and has been replaced with the remedy that does work.

---

## 3. WHAT WAS BUILT

### S1 — `"cell_mode": "fit"`

**The law, in one line:**

```
cell(region) = max(region extent / N*, w / phi(rho_max))
rho(voxel)   = max(demand density, the lightest band density printing at that cell)
```

`N*` cells across where the region can hold them (the minimum-mass certified lattice for
that member — the coarse end of `lattice_derive_cell_for_member`'s own window), and the
**finest printable cell** where it cannot, because that is the cell with the *most* cells
across and therefore the least inaccuracy accepted.

At a 0.42 mm bead (`r2_flip_probe.txt`):

| region extent | derived cell | rho | strut | cells/member | floor in force |
|---|---|---|---|---|---|
| 2.0000 | 1.0950 | 0.6000 | 0.4200 | 1.83 | percolation — **out of regime** |
| 4.0000 | 1.0950 | 0.6000 | 0.4200 | 3.65 | percolation — **out of regime** |
| 6.0000 | 1.2000 | 0.5239 | 0.4200 | 5.00 | accuracy |
| 8.0000 | 1.6000 | 0.3362 | 0.4200 | 5.00 | accuracy |
| 12.0000 | 2.4000 | 0.1751 | 0.4200 | 5.00 | accuracy |
| 24.0000 | 4.8000 | 0.0505 | 0.4380 | 5.00 | accuracy |
| 30.0000 | 6.0000 | 0.0505 | 0.5475 | 5.00 | accuracy |

Below **5.4748 mm** the accuracy floor is unreachable at any `(cell, rho)` and the
percolation floor takes over; below **1.0950 mm** of member nothing percolates and the
region is refused. Both numbers are `lattice_derive_cell_for_member`'s, read at run time.

**What it enforces, and what it deliberately does not.** It never emits a strut under the
stated bead (the density is raised with the cell) and never emits below the
**percolation** floor measured against the design's own local member width — such a voxel
stays solid. It **does** emit below the **accuracy** floor where the region cannot hold
it, counted in `fit_out_of_regime_voxels` and stamped per region in the receipt.

**Refusals reuse the existing three-case pre-flight** (`run_job.cpp:5615` at the stack base, `:5871` here), with two
scoped differences that follow from what `fit` does:

* **(A)** fires only when *no* declared region is feasible. Under one part-wide cell the
  thinnest region decides the run; under `fit` each region gets its own cell, so a job
  with one hopeless rib and six good bosses still honours the six.
* **(B)** *cannot* fire: the derived cell is at or below `extent / percolation floor` by
  construction, so a feasible region's planned cell percolates. That is the defect this
  mode removes.
* **(C)** is the reporting path, now naming each region's own derived cell.

**Schema.** `fit` requires at least one `"role": "include"` region (without a declaration
there is no requirement to fit, and the *design's* measured member width is not a
substitute — it is what the optimizer produced, not what you asked to lattice). It refuses
`cell_mm` (core derives it) and refuses `retain_subfloor_in_unloaded_regions` (two
mechanisms deciding the same voxel with two receipts).

### S2 — the printability floor is a bound again

`core/src/simp/grading.cpp` now raises a Fixed target only to

```
abs_floor_mm = min_extrudable_width / phi(rho_max)      // 1.0950 mm at a 0.42 bead
```

and raises the **density** to `lattice_min_density_for_strut(topo, cell, w)` before the
band clamp. `Auto` still selects `floor_mm` — unchanged, deliberately (S4).

**Why this cannot move a run whose cell was never overridden**, which is blocked-stop 4:
for any target at or above `floor_mm` the `max()` picks the target either way, *and* the
density raise is inert, because a cell at or above `floor_mm` already prints at `rho_min`
and the grade is clamped to `rho_min` from below. Asserted (`test_grading` S2c) and
measured (`r1_byte_identity.txt` case C, and the two CONTROL rows of
`r2_flip_probe.txt`).

### S3 — more than one cell in one run, and the seam

**FIRST, WHAT THE EMITTER CAN ALREADY DO — read from the code, with file and line.**

It **can** carry more than one cell size, but **only on an aligned dyadic octree**:

* `run_job.cpp:2925-2962` builds one `LatticeLevelSpec` per dyadic level, each with its
  own occupancy predicate and its own radius field.
* The occupancy predicate is
  `sp.latticed = [pl, LV](int ci,int cj,int ck){ const int bi = ci << LV; … return pl->level[pl->index(bi,bj,bk)] == LV; }`
  (`run_job.cpp:2935-2940`) — it indexes the **base** grid by `ci << LV`, so a level's
  cell size must be `base · 2^L` and its blocks must be aligned to that stride.
* `export_latticed_variant` takes the single-cell path unless
  `levels && levels->size() > 1 && base_cell_mm > 0.0` (`run_job.cpp:1005`), where it
  dispatches to `generate_lattice_multilevel`.
* Why dyadic is the whole transition rule is stated at `core/include/topopt/cell_plan.hpp:12-39`:
  the octet's nodes sit at multiples of `S_L/2`, so for `L >= 1` every coarse node is also
  a base-grid node and the levels meet at **shared nodes** with no bridge geometry.

So arbitrary per-region cells (1.0950 and 1.2000, say) **cannot** be carried as-is.
`fit` therefore lands them on **one** ladder: base `S0` = the finest cell any region
derived (never below `w/phi(rho_max)`), and each region takes the coarsest rung at or
below its own derived cell. Snapping **down** is safe twice over — the cell stays at or
above `S0`, so a printable density still exists, and a finer cell puts *more* cells across
the member, so the floor in force can only be cleared by more. `plan_cell_sizes_fit`
asserts exactly that (`cell <= what the region asked for`, aligned octree, 2:1 balance).

**THE SEAM, MEASURED — not solved.** No attempt was made at the transition problem.
See §5.3 for the numbers.

### S4 — `auto` stays `auto`, behind one constant

`kProductionLatticeAutoIsFit` (`core/src/simp/production.cpp`), read by
`production_lattice_auto_is_fit()`, applied in exactly one place —
`resolve_cell_mode()` in `run_job.cpp`, which every call site that turns the job's
`cell_mode` string into a `CellSizeMode` now goes through (the variant path, the forecast,
the analyze path, the pre-flight and `multiscale_floor_cell_mm`). Default **`false`**.

---

## 4. THE FLIP TABLE (bar R2)

Bar R2 inverts the usual rule for this task: the flips **are** the deliverable, so every
one is enumerated with the cell and density before and after, and why it moved. The
machine-generated half is `r2_flip_probe.txt`; the run-level half is `r3_before_after.txt`
and `r4_his_part.txt`.

### 4.1 What moves, and what provably does not

| Path | Before | After | Why |
|---|---|---|---|
| `auto`, any job | cell = `w/phi(rho_min)` | **identical** | S4: `auto` is not redefined while the constant is `false`. Measured: `r2_flip_probe.txt` CONTROL rows; `r3_before_after.txt` A vs B (same exit code, same stderr, on two different binaries) |
| `swept`, any job | dyadic plan | **identical** | S2 touches only the uniform Fixed cell; `swept`'s per-cell printability is already evaluated at each cell's own `rho`. Measured: `r1_byte_identity.txt` case B |
| `fixed`, target ≥ `w/phi(rho_min)` | target | **identical**, 0 densities raised | the `max()` picks the target either way and the raise is inert. Measured: `r1_byte_identity.txt` case C; `r2_flip_probe.txt` CONTROL row |
| `fixed`, `w/phi(rho_max)` ≤ target < `w/phi(rho_min)` | raised to `w/phi(rho_min)` | **target kept, density raised** | S2. This is a real flip on an existing path and it is intended |
| `fixed`, target < `w/phi(rho_max)` | raised to `w/phi(rho_min)` | raised to `w/phi(rho_max)` | still raised, to the floor that binds |
| `fit` | (mode did not exist) | per-region derived cell | S1 |

### 4.2 Every S2 flip measured, region by region

From `r2_flip_probe.txt` (bead, member, target → cell / latticed voxels / fallback /
achieved rho band / voxels whose density was raised):

| input | BEFORE | AFTER |
|---|---|---|
| bead 0.40, 15 mm member, target 2.0 | cell 4.3834, latticed 0, fallback 48000 | cell 2.0000, latticed 42760, fallback 5240, rho [0.2189, 0.8999], raised 42759 |
| bead 0.40, 4 mm member, target 2.0 | cell 4.3834, latticed 0 | cell 2.0000, latticed 0 — the cell moved, the outcome did not (4/2 = 2 cells, still under N*) |
| bead 0.40, 15 mm member, target 3.0 | cell 4.3834, latticed 0 | cell 3.0000, latticed 34624, fallback 13376, rho [0.0999, 0.8999], raised 34623 |
| bead 0.42, 4 mm member, target 1.2 | cell 4.6026, latticed 0 | cell 1.2000, latticed 0 — 3.33 cells, still under N* (this is why `fit`, not S2 alone, is what reaches his wall) |
| bead 0.42, 8 mm member, target 1.2 | cell 4.6026, latticed 0 | cell 1.2000, latticed 24432, fallback 1168, rho [0.5239, 0.8999], raised 24431 |
| bead 0.42, 30 mm member, target 1.2 | cell 4.6026, latticed 0 | cell 1.2000, latticed 94304, fallback 1696, rho [0.5239, 0.8999], raised 94303 |
| bead 0.42, 30 mm member, target 6.0 | cell 6.0000, latticed 0 | **identical** — the control |
| bead 0.42, any member, `auto` | cell 4.6026 | **identical** — the control |

Every row is explained by one sentence of the derivation: the cell is no longer raised, so
`width/cell` rises, so voxels that were under `N*` clear it; and the density is raised to
whatever prints at the finer cell, which is why the achieved `rho` band starts at 0.2189
(bead 0.40, cell 2.0) or 0.5239 (bead 0.42, cell 1.2) instead of at the band floor.

### 4.3 Three shipped fixtures were PINNED, and here is what that hides

`test_grading`'s `p.target_cell_size_mm` (2.0) and `wp.target_cell_size_mm` (2.0), and
`test_lattice_hookup`'s `job.grading.cell_mm` (3.0), all stated a target **below** the
`rho_min` floor at a 0.40 mm bead — so every bar built on them was measured at the
**raised** cell (4.3834 mm). Under S2 those targets survive, which would silently re-point
a dozen unrelated bars at a different cell (the sub-floor exposure fixture, for one, stops
being over the 3 % cap and its cap assertions start passing for the wrong reason).

Each was **pinned to the floor it used to be raised to, read from core** —
`lattice_cell_printability_floor_mm(topo, 0.4)` — so those bars keep measuring what they
were written to measure. That is a fixture pin, not a weakened assertion: the numbers in
their comments (1,704 of 30,600 voxels, 5.57 % exposure) were measured at that cell.

**A pin conceals, so the concealed thing is reported.** `probe_fit_flips` runs all three
at their *unpinned* values — the first three rows of §4.2 — so what the shipped fixture
value now does is on the record rather than hidden behind the pin.

### 4.4 Assertion sweep (bar R7)

```
git diff 935a77f HEAD -- core/tests app/TopOptKit/Tests \
  | grep -E '^-\s*(func test|TEST|EXPECT|CHECK|REQUIRE)'
```

yields exactly one line, and the full removed-line set is four lines. Every one accounted
for by hand:

| removed | accounted for by |
|---|---|
| `p.target_cell_size_mm = 2.0;` | replaced by the pinned `lattice_cell_printability_floor_mm(topo, 0.4)` — §4.3 |
| `wp.target_cell_size_mm = 2.0;` | same pin, same reason |
| `CHECK(gf.cell_size_floored, "target below floor was raised");` | **retargeted, not dropped**: `CHECK(U.cell_size_floored, "target below the binding floor was raised")` on a target that *is* below the floor now in force |
| `"raised cell equals the printability floor");` | retargeted to `CHECK(fabs(U.cell_size_mm - U.min_printable_cell_mm) < 1e-12, "raised cell equals the floor that binds")` |

Plus one in `test_lattice_hookup.cpp`: `CHECK(contains(rcpt, "\"cell_size_floored\": true"))`
became `… false` for the pinned target **and** the claim it made (a target under the
binding floor is raised, and says so) is asserted directly alongside it. Net: **42 added
`CHECK`s**, 0 claims lost.

---

## 5. THE MEASUREMENTS

### 5.1 R3 — the failing test first

`r3_before_after.txt`. Seven 4 mm include regions on the demo l-bracket, graded, at his
0.42 mm bead, run three ways with two different binaries (asserted to differ — the
`topopt_cli` / `topopt-cli` silent-no-op trap).

* **A, base binary, `auto`** — exit 1. Pre-flight refuses, naming
  `5.0 cells × 4.6026 mm = 23.013 mm` per region and `7 of 7 include regions are thinner`.
* **B, branch binary, `auto`** — exit 1, byte-for-byte the same stderr. **S4 holds.**
* **C, branch binary, `fit`** — exit 0. Cell **1.094961872 mm**, 2302 region voxels,
  **2302 latticed**, 0 solid fallback, 4 rungs, 4 lattice receipts.

**A precision about "today".** The brief says `auto` "plans a 4.6026 mm cell and emits
nothing". At the stack base it does not get that far — PR #298's pre-flight refuses first.
The pre-#298 behaviour was: plan 4.6026 mm, run the solve, emit nothing in the regions.
The unit test `FIT1` asserts that fact directly at the level of the law (`AUTO` on a 4 mm
wall: `cell_size_mm == 4.6026`, `latticed_voxels == 0`), which is the form of it that
survives both behaviours.

### 5.2 R4 — his own part: PARTIALLY MET, and here is exactly which part

`r4_his_part.txt`. WallMount_ShelfBracket.stl, his loads block verbatim (including
`"minimize_plastic": false` and his three bolt clearances), seven 4 mm include
regions, his 0.42 mm bead, resolution 64.

**Two things about his job had to change before any graded mode could run at all, and
both are pre-existing:**

* **His design box had to come out.** `run_job.cpp:5665` refuses `grading` alongside
  `design_box` — verbatim in the stack base. No graded cell mode, `fit` included, is
  reachable on his job as saved. His own `job_nobox.json` is the job that runs.
* **His ladder is three rungs, not four.** `"minimize_plastic": false` selects
  `production_growth_ladder()` = {1.55, 1.25, 1.10}. Four is the *reduction* ladder.

**MEASURED, on his part:**

| | |
|---|---|
| pre-flight under `auto` | REFUSES in 0.05 s — "5.0 cells × 4.6026 mm = 23.013 mm", 7 of 7 regions |
| pre-flight under `fit` | all seven regions: extent 4.000 mm → **cell 1.0950 mm at rho 0.6000, strut 0.4200 mm, 3.65 cells/member**, PERCOLATION floor in force, out of regime |
| the ANALYZE path end to end (`analyze_path_fit.txt`) | cell 1.094961872, region 5710 voxels, **456 latticed**, 5254 kept solid as `fit_no_derivation_voxels` (analyze grades the whole printed design, so everything outside the seven declared regions has no derived cell), 454 densities raised for printability |

**NOT MEASURED: the three-rung optimize end to end.** The `auto` side has nothing to
run — it refuses at the pre-flight, and that refusal *is* the auto result. The `fit`
side runs, but on the loadcase path the schema refuses both `ladder` and `margin_stop`
while `simp.max_iterations` does not bind the MMA plateau, so every rung runs to the
200-iteration cap; under this machine's load (other worktrees held it between 5 and 61
on 8 cores all session) rung 0 of 3 was still running past iteration 210 when the session ended (past the
200-iteration MMA plateau cap, so a rung here is not bounded by that number either). Re-run
`r4_his_part.sh core/build <out> 64` on an idle machine to finish it.

The part of R4 that is arithmetic on his declared geometry — extent, derived cell,
derived density, strut diameter, cells per member, floor in force — is measured twice
and does not depend on the solve. The part that is per-rung emitted counts is not.

### 5.3 S3 — the seam, measured

`s3_seam.txt`. Two include slabs sharing the plane z = 12 on the demo l-bracket:
4 mm (derives 1.0950 mm) and 24 mm (derives 4.8000 mm). The ladder's base is the
finest derived cell and the coarse region snaps to the coarsest rung at or below its
own, so the plan is:

```
cell_base_mm  1.094961872   max_level 2      cells split by the 2:1 balance: 0
  level 0: cell 1.0950 mm, 1365 cells, 1365 voxels, min 2.74 cells/member, out_of_regime
  level 1: cell 2.1899 mm,    9 cells,   72 voxels, min 2.74 cells/member, out_of_regime
```

**The seam is continuous.** Across z = 12: **25,500 triangles straddle the plane**,
and there is material within 0.5 mm on both sides (4,720 below / 16,082 above). There
is no gap band, no bridging geometry was emitted, and none was needed — the levels are
dyadic and aligned, so the coarse cell's nodes are fine-grid node positions.
`cells_split_by_balance` is 0 because the two levels are already one apart.

**One isolated component, and it is NOT at the seam.** 16 triangles (one strut), bbox
`[-6.0, 1.0, 3.0]`–`[-4.5, 2.5, 6.0]`. The seam is at z = 12 and both declared regions
start at z = 8, so it sits ~6 mm below either of them — **outside every declared
include region**. That is the cell-overhang behaviour PR #298 diagnosed and did not
fix: the certification mask is include-scoped per VOXEL while cell activation is
whole-cell from any masked voxel, so an activated cell reaches past the region. A finer
cell just makes the overhang produce a smaller, lonelier piece of geometry.

**So bar R5 is NOT met on this fixture: the isolated count is 1, not 0.** It is named,
located, and attributed to a pre-existing mechanism rather than to the seam or to
`fit`. Fixing it means making cell activation region-aware, which moves the emitted
mask on every existing graded path.

One more thing the number is not: the **8,928 connected components** are not 8,928
fragments. The generator emits each strut as its own capsule mesh and never welds
them, so two interpenetrating struts are two components by shared-vertex
connectivity. That is exactly why the isolated test is proximity-based at the job's own
line width, and why a component count on its own says nothing.

### 5.4 R5 — percolation

`r5_percolation.py`, run inside `s3_seam.sh` and `r6_cost.sh`. The threshold is the
run's own `wall_line_width_mm` read from `run_info.json` (0.45 mm on these runs) —
never a literal, and never a strut radius. Result on the seam fixture: 8,928
components, **1 isolated** — §5.3.

### 5.5 R6 — iterations and wall

`r6_cost.txt`. Two fixtures, both with the control that makes the wall number mean
"generation": on a graded two-step run the cell law runs AFTER the solve, so the
solver iteration count must be identical between two runs that differ only in the cell.

**Fixture 1 — one 12 mm include region, l-bracket res 40, one rung.** Iterations
identical (40 vs 40). `auto` plans 4.6026 mm, puts 2.61 cells across a 12 mm region,
falls every candidate back to solid and **emits no lattice at all**; `fit` derives
2.4000 mm and lattices **635 of 635** candidate voxels (168,124 triangles, 8.4 MB,
0.096 s of generation). There is no generation cost to compare against on the `auto`
side, and that *is* the comparison.

**Fixture 2 — the same job at two hand-set cells (R1's cases C and D, res 24).** Both
emit, so the cost ratio is measurable with the design held fixed:

| | cell | latticed voxels | iterations | generation wall | triangles | bytes |
|---|---|---|---|---|---|---|
| C | 2.5000 mm | 550 | 24 | 0.142 s | 437,212 | 21,860,684 |
| D | 1.0000 mm | 1168 | 24 | 0.389 s | 1,675,088 | 83,754,484 |
| ratio | 2.50× finer | 2.12× | **identical** | **2.73×** | **3.83×** | **3.83×** |

Not the cube of the cell ratio, because the latticed VOLUME grows too: a finer cell
clears the cells-per-member floor in more members.

**At the finest printable cell the absolute size is large**: 1,416,356 triangles /
70.8 MB on the seam fixture, and **152.3 MB** for the heaviest rung of the
seven-4-mm-region job at res 48. Arithmetic, not a defect — but it is what asking for a
cell that fits a 4 mm wall costs.

★ **The absolute seconds are not a clean benchmark.** This machine ran at a load average
above 40 on 8 cores throughout (other worktrees), so only the RATIOS — measured minutes
apart under the same conditions — and the load-independent iteration counts should be
read as measurements.

---

## 5.7 WHAT THE BARS ACTUALLY CAME TO

| bar | verdict |
|---|---|
| R1 byte-identical when off | **MET**, measured against the stack base, with positive controls — and it caught a real defect first (§5.6) |
| R2 enumerate every flip | **MET** — §4, machine-generated in `r2_flip_probe.txt`, including the three fixtures this task pinned, run at their unpinned values |
| R3 failing test first | **MET** — `r3_before_after.txt` end to end plus `FIT1`/`FIT2`/`S2a-c` in `test_grading.cpp` |
| R4 his part end to end | **PARTIALLY MET** — §5.2. The derivation on his geometry and the analyze path are measured; the three-rung optimize did not finish on this machine |
| R5 the lattice must percolate | **NOT MET, and named**: 1 isolated component, not 0 — §5.3. It is one strut outside every declared region, from pre-existing cell overhang, not from the seam and not from `fit` |
| R6 iterations and wall, both | **MET** — §5.5, with the iterations-identical control |
| R7 never weaken an assertion | **MET** — §4.4, four removed lines all accounted for, 42 added |
| R8 root cause with file and line | **MET** — §2.2 |
| R9 no unfilled placeholders | **MET** |

---

## 6. WHAT WAS NOT DONE, AND WHY

* **The transition between cell sizes is not solved.** Measured only (§5.3), per the
  brief.
* **`fit` is not exposed in the app.** Core-only task.
* **De-homogenization** — deciding *where* lattice could go — is untouched.
* **The grading + design-box refusal is not lifted.** It is pre-existing
  (`run_job.cpp:5665`, verbatim in the stack base) and it is what makes `fit`
  unreachable on his job as saved. Naming it is this task's contribution; fixing it is
  a separate piece of work with its own certified-object bar.
* **The region-extent vs measured-width gap is not closed.** The cell is derived from
  the region's DECLARED extent (conservative) while the regime flag per voxel is
  measured on the DESIGN's own local member width. On a 4 mm include slab cut into a
  thicker wall those disagree, and both numbers appear in the receipt — the per-region
  `out_of_regime` flag and `fit.out_of_regime_voxels`. PR #298 filed the same gap
  (§item-7b); closing it moves the latticed mask on existing paths.

---

## 7. IN PLAIN LANGUAGE

You have seven 4 mm-deep regions where you want lattice, and until now the pipeline put
nothing in them. The reason was not your part and not the optimizer. The pipeline was
choosing the cell size with a rule that never asked what the cell had to fit into: it took
the smallest cell that would still print *if* the lattice were as light as the material
library allows, and because that "if" is the extreme case, the answer came out large —
4.6 mm. A 4.6 mm cell needs about 23 mm of material to sit in. Your walls are 4 mm. So
everything you declared was rejected, and the number you were shown, "23 mm", looked like
a property of your part when it was really a property of an assumption nobody had made.

The fix is to ask the question the other way round. Given a 4 mm wall, what cell *and*
what lattice density fit together? A denser lattice has fatter struts, so it can be
printed at a smaller cell. Solving for both at once gets you a 1.1 mm cell at 60 % density
in that wall, with struts exactly one bead wide — and that does fit, and it does print.
That is what the new `"fit"` mode does, once per region you declared, using the region's
own size.

Two honest caveats. First, a 4 mm wall still cannot be *certified* — 3.65 lattice cells
across a member is under the 5 the homogenized model needs, so the strength number over
that material is out of regime, and the receipt says so for every region and every voxel.
It is buildable, not blessed. Second, small cells mean a lot of struts: one of these runs
produced a 152 MB mesh file. Both are stated in the receipt rather than left for you to
discover.

Separately, one thing that used to be broken is now simply fixed: if you set the cell size
by hand on a graded run, it is no longer overridden behind your back. Setting `cell_mm` to
1.2 does what it says.

Nothing here changes what `"auto"` means. Your old jobs re-run identically. If you want
`auto` to start doing this, that is one constant in one file, and the flip table in §4 is
what you should read before flipping it.

### The two bars this did not clear, in one place

**R5 wanted zero loose fragments and got one.** It is a single 16-triangle strut about
6 mm outside every region you declared, and it comes from a mechanism that predates
this work: an activated lattice cell reaches past the region boundary, because the
certification mask is scoped per voxel while cell activation is whole-cell. A finer
cell just makes the leftover piece smaller and lonelier. Named, located, and not fixed
here — fixing it moves the emitted mask on every graded run there has ever been.

**R4 wanted your part through every rung and got most of the way.** Everything about
your regions that is arithmetic — the extent, the cell, the density, the strut, the
cells per member, which floor is in force — is measured on your part, twice. What is
missing is the per-rung emitted counts, because the run was still on rung 1 of 3 when
the session ended, still on the first of three rungs; the machine was shared with
several other jobs all night. One command re-runs it.

### What next

1. **Decide on the alias.** Read §4, then flip `kProductionLatticeAutoIsFit` or leave it.
2. **Decide whether a 4 mm wall should be latticed at all.** `fit` will do it and stamp it
   out of regime. Whether an out-of-regime lattice is acceptable in a part you ship is your
   call, not the pipeline's.
3. **The file size wants an answer.** The natural one is a coarser cell where the region
   allows it — which `fit` already does for anything ≥ 6 mm — plus mesh decimation on
   export. Nothing here does the second.
4. **`fit` in the app** is a fourth enum case plus a picker label.
5. **The seam** is measured, not solved. §5.3 says exactly what it does today.
