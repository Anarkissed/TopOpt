# lattice-cell-fit-mode

Branch `claude/lattice-cell-fit-mode-2c28f1`.
Evidence `evidence/2026-08-05-lattice-cell-fit-mode/`.

---

## BUILD RITUAL — MERGE ORDER FIRST

1. **PR #298 (`claude/lattice-cell-size-adaptation-7ec715`) MERGES FIRST.** This branch
   is stacked on it and already contains its commits. The three core functions this
   branch depends on are `lattice_derive_cell_for_member`,
   `lattice_min_density_for_strut` and `lattice_percolation_cells_per_member_min` — if
   #298 is reworked, those are what must survive.
2. **Then this branch.** It changes `core/` only.
3. Then, as always:
   ```
   ./build_core.sh
   cmake --build core/build --target topopt-cli      # ★ the TARGET is topopt_cli
   ```
   restart the worker, rebuild the app. CI: `core-linux` + `app-macos`.
4. **PR #301 (`claude/lattice-retention-app-control`) must merge before any of this is
   reachable from the iPad.** `fit` is job-JSON only today: `LatticeCellSizeMode`
   (`LatticeSettings.swift`) has three cases where it needs four, and nothing app-side
   was changed here. #301 is also the branch that fixes the cell-size control's lower
   bound, and this branch's derivation agrees with its number exactly (§5.8).

★ The CMake target is `topopt_cli` (underscore); the binary is `topopt-cli` (hyphen).
`--target topopt-cli` finds an existing file, declares it up to date, and builds
nothing. Every script in the evidence directory asserts the two binaries differ before
comparing anything.

---

## 0. WHAT CHANGES FOR YOU

**Your 4 mm walls can now hold a lattice.** Set `"cell_mode": "fit"` in the `grading`
block and core derives the cell from each declared include region's own extent instead
of from a constant.

★ **EVERY NUMBER BELOW DEPENDS ON ONE INPUT: the stated extrusion width.** Your app
sends `PrintParams.wallLineWidthOuterMM` — your **outer bead, 0.42 mm** — as
`min_extrudable_width_mm`, at all four call sites. It is not a nozzle bore
(`PrintParams.swift:44-46` says so explicitly), and your inner bead
(`wall_line_width_mm`) is 0.45 and is **not** what this key receives. Both are given
below because a 7 % move in that input moves every result by 7 %.

**Your 4 mm wall, both widths:**

| stated width | derived cell | rho | strut | cells across | regime |
|---|---|---|---|---|---|
| **0.42 mm** — your outer bead, what the app sends today | 1.0950 mm | 0.6000 | 0.4200 mm | 3.65 | out of regime |
| 0.45 mm — your inner bead, for comparison | 1.1732 mm | 0.6000 | 0.4500 mm | 3.41 | out of regime |

Today `"auto"` plans **4.6026 mm** at your outer bead — a cell needing 23.0131 mm of
member — and puts nothing in those regions at all.

**What has actually been shown, and what has not.** `fit` derives correctly on your
geometry, and through the analyze path **at your own resolution 128** it lattices
**4,414 voxels** inside your seven declared regions where `auto` lattices none — every
candidate in every region, none skipped. It has **not** been shown to complete a run on
your part: the three-rung optimize did not finish (§5.2). A derivation has been produced
and 4,414 voxels through one path; a part has not.

**Your hand-set `cell_mm` now survives.** A graded job asking for 1.2 mm used to be
silently raised to 4.6026 mm and land straight back in "0.87 cells across". It is now
raised only to the cell below which *no* density in the band prints (1.0950 mm at your
outer bead), and the density is raised with the cell instead.

**`"auto"` is untouched.** Every saved job, every past run, every app screen that says
"auto" behaves exactly as it did. Making `auto` mean `fit` is one line —
`kProductionLatticeAutoIsFit` in `core/src/simp/production.cpp`, default `false` — and
§4's flip table is the evidence for taking it.

**Five things to know before you use it.**

1. A 4 mm wall latticed this fine is **BUILDABLE and OUT OF REGIME**. It prints and it
   percolates; the homogenized certificate over it is not trustworthy, because 3.65
   cells across is under the 5-cell accuracy floor. The receipt says so per region and
   per voxel. Nothing here relaxes that floor or hides it.
2. **The isolated-fragment bar is NOT met.** One loose strut, not zero (§5.3). It is
   named, located and attributed; it is not fixed here.
3. A fine cell is a **big file** — 152 MB for the heaviest rung of the seven-region
   reproduction (§5.5).
4. `fit` is **job-JSON only today** — see the build ritual, item 4.
5. ★ **Your design box has to come out.** `run_job.cpp:5665` refuses a `"grading"`
   block alongside a `"design_box"` — a pre-existing guard, verbatim in the stack base.
   No graded cell mode, `fit` included, is reachable on your job while it carries a
   box. Your own `job_nobox.json` is the job that runs.

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

### 2.3 ★ WHICH WIDTH THE DERIVATION IS FED, AND WHO ASSUMES WHAT (review Q1)

The whole law hangs off one input, so it was traced end to end before any number moved.
Full reading with every file and line in `q1_width_provenance.md`; the conclusions:

* **Core's meaning** (`grading.hpp:88-92`, `job.hpp:230`): "the STATED minimum
  extrudable strut width" — an extrusion width, never sourced by core, always an input.
* **The app supplies `PrintParams.wallLineWidthOuterMM`** at all four call sites
  (`LatticePage.swift:140,180`, `AppModel.swift:269`,
  `WorkspacePlaceholder.swift:1974`), and **PR #301 does not change that**.
* **`wallLineWidthOuterMM` is a deposited bead width, NOT a nozzle bore** —
  `PrintParams.swift:44-46` states it in those words. Shipped defaults, which are also
  his job's values: outer **0.42**, inner **0.45**.
* So the app sends **0.42**, and this branch's 0.42 derivations describe what his device
  sends today. The `0.45000000000000001` in PR #301's evidence is its **own test
  fixture** (`LatticeRetentionEvidenceGen.swift:28,36` sets `lineWidthMM: 0.45` and
  `wallLineWidthOuterMM: 0.45`), not his configuration.

**★ THE DEFECT THAT IS ACTUALLY THERE.** The codebase carries two bead widths and the
lattice path silently takes the **narrower**: the strut printability floor comes from
the OUTER wall bead (0.42) while the width-aware knockdown and core's historical
`wall_line_width_mm` use the INNER bead (0.45). **A lattice strut is not a wall loop**,
and nothing in the app, core, or any handoff states which bead a slicer deposits for a
lone unsupported extrusion. Taking the outer width is the less conservative choice: if a
strut is really laid at 0.45, every strut derived at 0.42 is thinner than one line of
his slicer's output. That is APP-side and it is a decision, not a patch — named,
quantified at both widths, and left to the maintainer. Whoever takes it must answer
*which bead does the slicer lay for a single extrusion?*, and the answer belongs in
`PrintParams.swift` beside the two fields.

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

At his 0.42 mm OUTER bead — the width the app sends (§2.3); the same table at
0.45 mm is in `r2_flip_probe.txt`:

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

### 5.2 R4 — his own part: what is established, and what is not

`r4_his_part.txt`, `q2_no_derivation.md`. WallMount_ShelfBracket.stl, his loads block
verbatim (`"minimize_plastic": false` ⇒ the GROWTH ladder {1.55, 1.25, 1.10}, his three
bolt clearances), seven 4 mm include regions, his 0.42 mm outer bead.

**Two things about his job had to change before any graded mode could run, both
pre-existing:** his design box (§0 item 5), and the ladder is three rungs, not four —
`"minimize_plastic": false` selects the growth ladder; four is the *reduction* ladder.

**MEASURED:**

| | |
|---|---|
| pre-flight, `auto` | REFUSES in 0.05 s — "5.0 cells × 4.6026 mm = 23.013 mm", 7 of 7 regions |
| pre-flight, `fit` | all seven: extent 4.000 mm → **cell 1.0950 mm at rho 0.6000, strut 0.4200 mm, 3.65 cells/member**, PERCOLATION floor in force, out of regime |
| ANALYZE path, end to end, **resolution 128 (his)** | **4,414 latticed**, and the per-region split below |

#### ★ WHERE THE SKIPPED VOXELS WERE, PER REGION (review Q2)

A bare `no_derivation` total against a small latticed count is the shape of number that
hid the overnight run's failure for a night, so the receipt now answers it directly.
Added: `GradingFitRegion::candidate_voxels` / `latticed_voxels`, and a run-level
`printed_outside_regions`, filled by `fill_fit_region_voxels` (`run_job.cpp:673`) using
the SAME membership test and precedence as `fit_cell_field`. Wired at all three fit call
sites (`:4524`, `:5260`, `:6745`).

**Resolution 128 — his:**

```
region_voxels 46291   latticed 4414   solid_fallback 41877
no_derivation 41877   printed_outside_regions 41877
IDENTITY no_derivation == printed_outside_regions: True
density_raised 4414   out_of_regime_voxels 0   distinct_cells 1

  region | extent | cell mm  | candidates | latticed | region out of regime
       0 |   4 mm | 1.094962 |        238 |      238 | True
       1 |   4 mm | 1.094962 |        396 |      396 | True
       2 |   4 mm | 1.094962 |        384 |      384 | True
       3 |   4 mm | 1.094962 |        576 |      576 | True
       4 |   4 mm | 1.094962 |        672 |      672 | True
       5 |   4 mm | 1.094962 |        828 |      828 | True
       6 |   4 mm | 1.094962 |       1320 |     1320 | True
  sum 4414  +  outside 41877  =  46291
```

(At resolution 64 the same identity holds: 456 latticed, 5,254 outside, 5,710 total.)

**Every skipped voxel was OUTSIDE every region he declared**, at both resolutions, and
the decomposition is exact and total. **Inside the declared regions nothing failed**:
candidates == latticed in all seven.

**Why the candidate set was the whole part, and why that is NOT §B2.** `run_job.cpp:4497`
passes `nullptr` for the region mask on the **analyze** path — deliberate and
pre-existing: `analyze_job` grades the whole printed design. `fit` then declines to
invent a cell for undeclared material, counts it, and keeps it solid. The control that
proves it is the call site and not the law: on the OPTIMIZE path the candidate set IS
include-scoped, and on the same geometry it reports `region_voxels 2302, latticed 2302,
solid_fallback 0, no_derivation 0`.

**★ §B2 IS still live — at EMISSION, not at candidacy.** Whole-cell activation from any
masked voxel overhangs the region boundary; that is what put one clipped strut outside
every region in the seam fixture and it is why R5 is not met (§5.4). Two different
mechanisms; they must not be conflated.

**★ TWO NUMBERS THAT LOOK CONTRADICTORY AND ARE NOT.** `out_of_regime_voxels` is 0 while
every REGION is stamped out of regime. The region flag is judged on the region's
DECLARED extent (4 mm) — what the cell was derived from, the conservative reading — and
the voxel count on the DESIGN's own measured local member width. A 4 mm include slab cut
into a thicker wall sits on material wider than 4 mm. That gap between declared extent
and measured width is the coherence gap PR #298 filed (§item-7b); reported, not closed.

**NOT ESTABLISHED: the three-rung optimize.** Re-run at **resolution 128** as the review
asked, on a machine at load ~8 rather than the previous ~40. The `auto` side has nothing
to run — it refuses at the pre-flight in 0.05 s, and that refusal *is* the auto result.
The `fit` side runs but **cannot be bounded**: `simp.max_iterations` is accepted and
**silently ignored** on the loadcase path (`run_job.cpp:5560-5561` sit inside the `else`
at `:5516`), root-caused with file and line in `q3c_max_iterations_ignored.md` and
summarised in §6. So the per-rung emitted-cell counts, verdicts, margins and mass under
`fit` are not established on his ladder, and §0 does not claim a part has been produced.

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

### 5.4 R5 — ★ NOT MET. One isolated fragment, not zero.

`r5_percolation.py`, run inside `s3_seam.sh` and `r6_cost.sh`. The threshold is the
run's own `wall_line_width_mm` read from `run_info.json` (0.45 mm) — never a literal,
never a strut radius.

**Result: 8,928 components, 1 isolated.** The bar demands zero. It is **NOT MET** and it
is recorded as an open, not as a pass.

* **The fragment**: 16 triangles — one strut — bbox `[-6.0, 1.0, 3.0]`–`[-4.5, 2.5, 6.0]`,
  about 6 mm below either declared region and outside both.
* **The cause**: §B2's whole-cell activation. The certification mask is include-scoped
  per VOXEL while cell activation is whole-cell from any masked voxel, so an activated
  cell reaches past the region and its clipped strut has nothing to weld to. A finer
  cell makes the leftover piece smaller and lonelier; it does not create it.
* **NOT fixed here, deliberately.** The fix moves the emitted mask on every graded path
  there has ever been, so it needs its own before/after gate table.
* **THE SUCCESSOR TASK**: make cell activation REGION-AWARE — an octree cell must be
  activated only where the certification mask would actually keep it, so the emitted set
  and the certified set agree at the region boundary. Its bar is that no strut is
  emitted outside the include union, with the isolated count measured at the job's own
  line width on a part that previously produced one.

**★ THE RAW COMPONENT COUNT IS NOT A FRAGMENT COUNT.** The generator emits each strut as
its own unwelded capsule mesh, so two struts that interpenetrate are two components by
shared-vertex connectivity. 8,928 is an artefact of that, not 8,928 loose pieces — which
is exactly why the isolated test must stay **proximity-based at the job's own line
width**. Anyone who replaces it with a component count will report a catastrophe that
is not there, or miss the one piece that is.

**★ AND THE SEAM WAS NEVER EXERCISED ON HIS GEOMETRY.** `fit.distinct_cells` came out
**1** on his part — all seven of his regions are 4 mm, so all seven derive the same
1.0950 mm cell and the run is single-cell. The multi-cell seam is measured only on the
constructed two-region fixture (§5.3). Nothing about the seam has been observed on the
part he actually prints.

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
| Q1 width provenance | **ANSWERED** (§2.3, `q1_width_provenance.md`) — and it cross-checks with PR #301 to 0.000e+00 (§5.8) |
| R2 enumerate every flip | **MET** — §4, machine-generated in `r2_flip_probe.txt`, including the three fixtures this task pinned, run at their unpinned values |
| R3 failing test first | **MET** — `r3_before_after.txt` end to end plus `FIT1`/`FIT2`/`S2a-c` in `test_grading.cpp` |
| R4 his part end to end | **PARTIALLY MET** — §5.2. The derivation and the analyze path are measured at his resolution and per region; the three-rung optimize could not be bounded (§6, `simp.max_iterations` ignored on the loadcase path) |
| R5 the lattice must percolate | ★ **NOT MET** — 1 isolated component, not 0 (§5.4). One strut outside every declared region, from pre-existing whole-cell activation (§B2), not from the seam and not from `fit`. Successor task named. |
| R6 iterations and wall, both | **MET** — §5.5, with the iterations-identical control |
| R7 never weaken an assertion | **MET** — §4.4, four removed lines all accounted for, 42 added |
| R8 root cause with file and line | **MET** — §2.2 |
| R9 no unfilled placeholders | **MET** |

### 5.8 CROSS-CHECK AGAINST PR #301 (review Q1(d))

PR #301's cell-size control is bounded below by core's densest-end printability floor,
recorded in its evidence as **1.173173434139347 mm** at a 0.45 mm stated width. This
branch's derivation at the same width:

```
PR #301 cross-check @ 0.45 mm: their control floor 1.17317343413935 mm,
this derivation 1.17317343413935 mm, delta 0.000e+00 mm — AGREE
```

Identical to the last printed digit. Both are
`w / octet_strut_diameter_mm(lattice_rho_max, 1.0)` read from core, not transcribed, and
the check is compiled into `probe_fit_flips.cpp` so it re-runs with the numbers rather
than being asserted once in prose.

---

## 6. WHAT WAS NOT DONE, AND WHY

* **The transition between cell sizes is not solved.** Measured only (§5.3), per the
  brief.
* **`fit` is not exposed in the app.** Core-only task.
* **De-homogenization** — deciding *where* lattice could go — is untouched.
* ★ **`simp.max_iterations` IS ACCEPTED AND SILENTLY IGNORED ON THE LOADCASE PATH.**
  A named defect found while trying to bound the R4 run, root-caused in
  `q3c_max_iterations_ignored.md`. `run_job.cpp:5560-5561` applies the job's cap, and
  those lines sit inside the `else` at `:5516` — the self-weight branch. A job with a
  `loads` block takes its options from `build_production_loadcase` and the key is
  parsed, stored and dropped. The schema accepts it unconditionally
  (`job.cpp:715-721`) while *explicitly refusing* `ladder` and `margin_stop` on the same
  path (`job.cpp:465-470`), so a user reading that refusal list reasonably concludes the
  unlisted keys are honoured. This is the same shape as the open item he already
  carries: a control that exists, is accepted, and cannot act. Not fixed here — moving
  an iteration cap changes the DESIGN on every loadcase run that states the key, which
  needs its own gate table. A fix must either honour it there or refuse it there;
  accepting and ignoring is the worst of the three.
  (Even where it IS read it is not a single ceiling: with a projection schedule
  `build_stage_plan` (`simp.cpp:967-974`) takes each stage's cap from `ps.iterations`
  and never consults `max_iterations` — `heaviside_continuation_schedule()` is
  6 × 50 = 300 iterations — and under conditional MMA projection a gray rung is
  continued *within the same rung*, each phase backstopped separately.)
* **The two bead widths are not reconciled.** §2.3: the lattice path takes the OUTER
  bead while the knockdown takes the INNER one, and nothing states which a slicer lays
  for a lone strut. App-side, and a decision.
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
choosing the cell size with a rule that never asked what the cell had to fit into: it
took the smallest cell that would still print *if* the lattice were as light as the
material library allows, and because that "if" is the extreme case, the answer came out
large — 4.6 mm. A 4.6 mm cell needs about 23 mm of material to sit in. Your walls are
4 mm. So everything you declared was rejected, and the number you were shown, "23 mm",
looked like a property of your part when it was really a property of an assumption
nobody had made.

The fix is to ask the question the other way round. Given a 4 mm wall, what cell *and*
what lattice density fit together? A denser lattice has fatter struts, so it can be
printed at a smaller cell. Solving for both at once gets you a cell of about 1.1 mm at
60 % density in that wall, with struts exactly one extrusion line wide — and that does
fit, and it does print. That is what the new `"fit"` mode does, once per region you
declared, using the region's own size.

**Which width your numbers depend on.** Everything above is computed from one input: the
extrusion line width the app sends. It sends your **outer bead, 0.42 mm** — the width of
the single outer wall loop, which is a slicer setting, not your nozzle's bore. Your
*inner* bead is 0.45 mm, and the cell would come out about 7 % bigger (1.17 mm, struts
0.45 mm) if that were the number used. Both are printed side by side everywhere in this
handoff, because a result this sensitive to one input should never be quoted without
naming it. And there is a real open question underneath: a lattice strut is not a wall
loop, and nobody has established which of the two widths your slicer actually lays down
for a single strut floating in space. If it lays 0.45, then struts designed at 0.42 are
thinner than one line of your own output. That is worth settling before you print one.

**What has been shown, and what has not.** The mode derives correctly on your part, and
through one path — the analyze path, at your own resolution — it puts lattice in all
seven of your regions: 4,414 voxels, every candidate in every region, none skipped. That
is the first time this project has produced lattice in those walls. What has **not** been shown is a finished run on
your part: the three-rung optimize did not complete, because a key that should have
bounded it (`simp.max_iterations`) turns out to be accepted and then ignored on the path
your job takes. So a derivation exists and 4,414 voxels exist; a part does not.

**And one bar is not met.** The rule that says no piece of the lattice may come out
loose is not satisfied: one strut, sixteen triangles, ends up detached — about 6 mm
outside any region you declared. It comes from an old behaviour, not from this work: a
lattice cell is switched on as a whole whenever any part of it is inside your region, so
a cell sitting on the boundary reaches past it, and the piece that reaches past gets
trimmed off with nothing to weld to. Fixing that moves the geometry on every graded run
ever made, so it belongs to its own task, and that task is named in §5.4. Two smaller
cautions with it: the "8,928 components" figure in the evidence is not 8,928 loose
pieces — the generator writes every strut as its own unwelded shape, so overlapping
struts still count separately; and your part never exercised the seam between two
different cell sizes at all, because all seven of your regions are the same 4 mm and
therefore get the same cell.

Separately, one thing that used to be broken is now simply fixed: if you set the cell
size by hand on a graded run, it is no longer overridden behind your back. Setting
`cell_mm` to 1.2 does what it says.

Nothing here changes what `"auto"` means. Your old jobs re-run identically. If you want
`auto` to start doing this, that is one constant in one file, and the flip table in §4 is
what you should read before flipping it.

### The bars this did not clear, in one place

**R5 wanted zero loose fragments and got one** — named, located, attributed, successor
task written (§5.4).

**R4 wanted your part through every rung and got most of the way** — everything about
your regions that is arithmetic is measured on your part at your own resolution, and the
per-region split now shows all seven regions fully latticed with nothing skipped inside
them. The per-rung emitted counts are missing because the run could not be bounded.

### What next

1. **Settle the bead width.** Which line does your slicer lay for a lone strut, 0.42 or
   0.45? Everything in §0 moves ~7 % with the answer, and one direction designs struts
   thinner than your own output.
2. **Decide on the alias.** Read §4, then flip `kProductionLatticeAutoIsFit` or leave it.
3. **Decide whether a 4 mm wall should be latticed at all.** `fit` will do it and stamp
   it out of regime. Whether an out-of-regime lattice belongs in a part you ship is your
   call, not the pipeline's.
4. **The loose-strut task** (§5.4) and **the ignored-iteration-cap defect** (§6) are both
   written up ready to pick up.
5. **The file size wants an answer.** The natural one is a coarser cell where the region
   allows it — which `fit` already does for anything ≥ 6 mm — plus mesh decimation on
   export. Nothing here does the second.
6. **`fit` in the app** is a fourth enum case plus a picker label, on top of PR #301.
