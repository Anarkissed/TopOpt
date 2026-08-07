# Cell mode `fit`, the swept floor, and a refusal you can actually read

Task `cell-mode-fit-and-swept-floor`, branch `claude/cell-mode-fit-swept-floor-fc4f63`,
branched from `d9fe8f7` (`origin/main`).
Evidence: `evidence/2026-08-07-cell-mode-fit-and-swept-floor/`.

Supersedes S3(a) of `app-core-option-controls` (the `fit` control).

---

## 0 · What changes for you

**Your nine-region refusal is now four lines and a table, and the line telling you what
to type is the second one.** It was nine near-identical five-line paragraphs with the
remedy at the bottom. Measured on your exact case: **5,692 → 2,689 characters (−52.7 %)**
and **115 → 53 wrapped lines at 60 columns (−53.9 %)**. The instruction you needed —
`SET cell size between 1.1732 mm and 2.8284 mm` — moved from wrapped line ~100 to
wrapped line 2.

**You can now pick automatic per-region cell sizing from the iPad.** The lattice page's
Cell size control has a fourth option, **Per region**. Core has had it since PR 302 and
the app had no way to ask for it. On your nine-region job it lattices six regions
out-of-regime and certifies three, instead of refusing.

**A swept cell window now means what you typed.** Declaring `cell_min_mm: 1.173` used to
be silently raised to 4.9314 mm and then refused for being too coarse — your declared
number changed *not one character* of the refusal. It now plans at 2.3460 mm and runs.
On *your* part it runs and still emits no lattice, and the pre-flight says so before the
solve rather than after (§3A) — **Per region is the mode that actually lattices your
bolt regions.**

**Turn retention OFF when you use Per region**, and the app now enforces that: the two
mechanisms decide the same material two different ways and core refuses a job that asks
for both. The control greys itself and says which to use when.

One thing was **built and deliberately left disarmed**, and it is your call: the same
swept-floor correction also applies to the multiscale length-scale derivation, where it
*moves the design*. §S1.4 has the measurement.

---

## 1 · S1 — swept was still broken the way fixed was

### 1.1 Establish before fixing (bar S1a / S1b)

**(a) Which function produced `planned cell 4.931378498 mm`?**

`core/src/cli/run_job.cpp`, the pre-flight block, **origin/main line 6059**:

```cpp
else if (pf_mode == CellSizeMode::Swept)
  cell_mm = std::max(job.grading.cell_min_mm, floor_mm);
```

`floor_mm` is `lattice_cell_printability_floor_mm(octet, 0.45)` = 4.931378498 mm — the
printability floor evaluated at `rho_min`. Your job was `cell_mode: "auto"`, which takes
the same number one line above; the swept arm reports the identical value for a
different reason, which is what this bar is about.

It was **not** `multiscale_floor_cell_mm` (origin/main `run_job.cpp:761-785`). That is a
**second copy** of the same switch, with the same swept arm on line 773, read only when
`lattice.multiscale` is armed. Both copies were wrong; only the pre-flight one is on
your path.

**(b) Does `plan_cell_sizes` apply the same floor, a different one, or none?**

**None.** `core/src/simp/cell_plan.cpp`:

```cpp
P.base_cell_mm = params.min_cell_size_mm;   // verbatim — no max(), no floor
```

and `run_job.cpp` passes the job's number straight through
(`gp.min_cell_size_mm = job.grading.cell_min_mm`). The planner's only printability rule
is **per base cell** — `need[c]`, the smallest dyadic level whose strut at that cell's
own density still prints — and a base cell whose `need` exceeds its `cap` is dropped to
solid.

**So the pre-flight and the planner already disagreed, by a factor of 4.2 on your
numbers: forecast 4.9314 mm, plan 1.173 mm.** That is the defect. The one-line change
was not the fix.

### 1.2 The fix (bar S1c)

One rule, in the planner's own file, read by both sides —
`core/include/topopt/cell_plan.hpp` / `core/src/simp/cell_plan.cpp`:

```cpp
int    cell_plan_max_level(double min_cell_size_mm, double max_cell_size_mm);
double cell_plan_finest_printable_cell_mm(LatticeTopology, double min_cell_mm,
                                          double max_cell_mm, double min_width_mm);
```

`cell_plan_max_level` is the ladder arithmetic **extracted from `plan_cell_sizes`, not
rewritten** — the same 1e-9 guard, and `plan_cell_sizes` / `plan_cell_sizes_fit` now
call it, so there is one ladder rule and not three copies.
`cell_plan_finest_printable_cell_mm` returns the first rung `cell_min · 2^L` at or above
`w / phi(rho_max)`, evaluated at the band's most generous density — a true lower bound
on what the plan can grant. A window with no printable rung reports the frontier cell
itself, the same resolution `fit` applies when no region is feasible.

The two run_job copies became **one function with one argument**:
`planned_cell_mm(job, swept_light_floor)`. The pre-flight passes `false` (the
correction). `multiscale_floor_cell_mm` passes `true` — see §1.4.

**AUTO deliberately keeps the light floor**, with the comment saying so
(`run_job.cpp`): "auto" means *the lightest lattice core can print*, and the rho_min
floor is exactly the cell that claim implies. It is the mode's answer, not a bound on
someone else's number, so past auto runs stay reproducible.

### 1.3 The failing test first (bar S1d / R2)

`evidence/.../s1_disagreement.txt`, on the **unfixed** binary, your geometry:

```
base, cell_mode auto            : exit 1
base, cell_mode swept @1.173 mm : exit 1
sha256 of the auto  message: 447e45f73371085372203d90e76464dfd7280c867c41f4b71e437a3b5e311515
sha256 of the swept message: 447e45f73371085372203d90e76464dfd7280c867c41f4b71e437a3b5e311515
★ IDENTICAL. Declaring cell_min_mm 1.173 changed NOT ONE CHARACTER of the refusal.
```

The refusal it produced:

```
topopt-cli: the planned lattice cell is too COARSE for the regions you declared: ...
  planned cell 4.931378498 mm gives 0.5735570948 cells across that region; a
  connected network needs at least 1.
```

After the fix, the same two jobs:

```
branch, cell_mode auto            : exit 1   (still refuses — auto IS the light floor)
branch, cell_mode swept @1.173 mm : exit 0   (RUNS, planning at 2.346 mm)
★ they now DIFFER — the declared minimum reaches the forecast.
```

A permanent regression test lives in `core/tests/unit/test_grading.cpp` §5 (ten new
checks), including the measured statement that the planner's base cell **is** the
declared minimum and that it grants cells below the light floor.

### 1.4 ★ BUILT + DISARMED — the one place this reaches geometry

`multiscale_floor_cell_mm`'s return value becomes `options.min_feature_mm` (the density
filter's length scale) on a `lattice.multiscale` job, so changing it **changes the
design**. Measured, `evidence/.../r1_byte_identity.txt` case G — a swept multiscale job
declaring a 0.6 mm minimum at a 0.20 mm strut line width:

```
old rule : floor 5.0 cells x 2.1917 mm = 10.959 mm member => min_feature 5.479 mm
new rule : floor 5.0 cells x 0.6000 mm =  3.000 mm member => min_feature 2.500 mm
```

and **every artifact moved** — `design.bin`, both meshes, `report.json`, `fields.bin`.
That is a verdict moving on a job that runs today, which bar R3 makes a blocked-stop.
So the correction stops at the refusal path (which touches no geometry — cases A–F of
the same script) and this caller keeps the old answer, behind a named argument and a
comment that says it is the same defect. **Flipping `swept_light_floor` to `false` is
the whole change; what it needs is a gate table on multiscale swept jobs.** Your call.

### 1.5 Root cause, with file and line (bar R6)

Commit **`4032ce8`** (`lattice-cell-fit-mode: the cell is DERIVED from what it has to
fit into`, PR 302, 2026-08-05) — its S2 corrected the FIXED arm in **both** copies of
the switch and left the SWEPT arm untouched in both. In that commit's own diff of
`core/src/cli/run_job.cpp` the swept lines appear as **context, not additions**:

```
 245:     case CellSizeMode::Swept: return std::max(job.grading.cell_min_mm, floor_mm);
+246,+257: … abs_floor_mm … (the Fixed correction, one line below)
 431:       cell_mm = std::max(job.grading.cell_min_mm, floor_mm);
+442:     } else cell_mm = std::max(job.grading.cell_mm, abs_floor_mm);
```

The comment at origin/main `run_job.cpp:758` even claimed *"SWEPT's finest level is its
declared minimum, likewise raised"* — it was raised, to the wrong floor. **The
duplication is how it survived**, which is why the two copies are now one function.

### 1.6 One thing S1 relaxed that is worth knowing

The R3 table surfaced a case the old (wrong) refusal happened to catch: a swept window
whose **top** is below the printable frontier. No rung of the ladder can carry a strut,
so the run solves and emits nothing. The pre-flight now **says that sentence** —

```
★ AND SEPARATELY: your whole swept window (0.3 to 0.45 mm) is FINER than the smallest
cell that prints at a 0.2 mm strut line width, which is 0.5214104152 mm. No level of
the ladder can carry a strut, so this run will solve and then emit NO LATTICE AT ALL.
Raise "cell_max_mm" to at least that value.
```

— and does **not** refuse. Refusing would be a *new* refusal on jobs that run today (a
job whose regions cleared percolation against the light floor ran to completion,
emitting nothing), which R3 makes a blocked-stop. It is a one-line change behind its own
gate table if you want it.

---

## 2 · S2 — the app can select `fit`

### 2.1 What was added (bars S2a / S2b)

* `LatticeCellSizeMode.fit` (`app/.../LatticeSettings.swift`).
* The lattice page's Cell size segment is now **Auto / Fixed / Swept / Per region**.
* Its copy, in your words:
  > The cell size is derived per region from that region's own thickness, so a thin
  > wall gets a fine dense lattice and a thick member a coarse light one. No cell is
  > entered here.

  The words "advanced" and "expert" appear nowhere.
* When no include region is declared the control says so directly, because the mode
  derives *from* those regions and core refuses the job without one.
* The serializer emits `cell_mode: "fit"` and **no** `cell_mm` / `cell_min_mm` /
  `cell_max_mm` — core refuses a target cell alongside a derived one.

### 2.2 Two gates that are not decoration

**The linked core is asked whether it takes the VALUE.** `gradingSchemaAccepts(key:)`
cannot answer this: `cell_mode` has been an accepted *key* since the cell-size sweep,
while the value set grew afterwards. A core that predates `fit` fails the **whole job**
at validation with `grading "cell_mode" must be "fixed", "auto" or "swept"`. So
`grading_schema_accepts_cell_mode()` (bridge) hands core's own parser a document
carrying the mode, `LatticeCellModeCapability.fromCore` reads it, and a snapshot saved
with `fit` degrades to the fixed cell rather than dying at the worker.

**Fit needs a declared region, and the app now knows it.** Core refuses
`cell_mode: "fit"` with no include region ("a job that declares none states no
requirement to fit"). This was **found by the test suite, not by reading**: the test
that hands the emitted bytes to `TopOptKit.jobSchemaError` failed, and the first version
of the bridge probe reported `fit` unsupported on a core that supports it perfectly
well, because the probe document had no region either. Both are fixed.

### 2.3 ★ The mutual exclusion (bar S2c)

`grade_lattice` throws on `fit` + `retain_subfloor_in_unloaded_regions`
(`core/src/simp/grading.cpp:66-70`), and the job schema refuses the pair as well
(`core/src/cli/job.cpp:1275-1280`). The app cannot author it, in two places:

* **Structurally, on the emitted bytes** — `resolvedSubfloor(capability:cellMode:)`
  drops retention and both dependents when the resolved mode is `fit`. It takes the
  mode the *spec* will carry, not the stored setting, so a swept snapshot that
  `runSpec` resolved down to fixed can still arm retention normally.
* **In the UI** — selecting Per region clears `retainSubfloorInUnloadedRegions`,
  `subfloorPerRegion` and `subfloorStressFraction`, exactly the pattern the retention
  switch already uses for its own dependents.

The copy says **which to use when**, because from where you sit they solve the same
problem:

> Cell size is set to Per region, which already fits a cell to each region and reports
> what it emitted below the floor. Use Per region when your regions differ in
> thickness; use this switch when one cell has to serve them all. Only one of the two
> can decide a given piece of material, so core refuses a run that asks for both.

### 2.4 Failing test first, through the REAL serializer (bar S2d / R2)

`evidence/.../r2_s2_app_failing_first.txt` — four tests written to compile against the
**unfixed** app, driving `RemoteRun.buildJobJSON()`, **5 failures**:

```
R2a: the app cannot represent core's fourth cell mode
R2b: XCTAssertEqual failed: ("nil") is not equal to ("Optional("fit")")
R2b: XCTAssertNil failed: "4"   — core REFUSES a target cell alongside fit
R2c: XCTAssertNil failed: "1"   — fit + retention WAS expressible
R2d: no API exists to ask core whether it takes cell_mode "fit"
```

The permanent suite is `app/TopOptKit/Tests/TopOptFlowsTests/LatticeCellFitModeTests.swift`
— **12 tests**, all through `RemoteRun.buildJobJSON()` and `RelatticeJobBuilder.build`,
three of them handing the result to core's own parser. Includes the positive control
that retention still ships on every *other* cell mode, so the exclusion is not "retention
never ships".

**App suite: 1,336 tests, 0 failures, 19 skipped.**

### 2.5 ★ The default is UNCHANGED — and the evidence for your decision (bar S2e)

`LatticeSettings.cellSizeMode` still defaults to `.fixed`; an untouched project emits no
`cell_mode` key at all, byte-identically to before (asserted by
`testDefaultCellModeIsUnchangedAndEmitsNoModeKey`).

What you would be deciding, with the numbers:

* **For:** on your nine-region job, `auto` refuses outright and `fit` runs, latticing
  six regions out-of-regime and certifying three (§3A). Every region gets the finest
  cell it can print instead of one number that fits none of them.
* **Against, and it is structural:** `fit` is **not expressible on a job with no
  declared include region** — core refuses it. Roughly every whole-part lattice job is
  in that state. Making it the default therefore needs a documented fallback (silently
  becoming `fixed` is exactly the "auto never silently means uniform" rule this project
  already refuses elsewhere).
* **Against, weaker:** `fit` reports material as OUT OF REGIME where `auto` would have
  left it solid. That is more honest, not less safe — but it changes what a receipt says
  on jobs you have already read.

Recommendation, not taken: leave `fixed` as the default and let Per region be a choice,
until a job with no regions has a stated answer.

---

## 3 · S3 — the refusal must be readable

### 3.1 The shape, now fixed for every case

```
HEADLINE   what happened, with the count and the planned cell
ACTION     the number to type — FIRST, before any explanation
TABLE      one row per declared region, and nothing else per region
Why:       the explanation, ONCE
```

One composer (`pf_compose`) and one table builder (`pf_table`) produce every message the
pre-flight can emit, so the ordering cannot drift between cases.

**Nothing this changes decides anything.** The three-case machine (A: nothing percolates
anywhere → refuse; B: the planned cell is too coarse → refuse; C: percolates but under
the accuracy floor → report) is untouched: the same jobs refuse, for the same reasons,
with the same arithmetic. Only the composition of the text changed. Proven by
`r1_byte_identity.txt` case D — geometry identical, text different — and by the R3 gate
table's five run-on-both-sides jobs at 0 voxel flips.

### 3.2 The measured improvement (bar S3d)

`evidence/.../s3_message_before_after.txt`, all four shapes, base = `origin/main`:

| case | chars before | chars after | Δ | wrapped@60 before | after |
|---|---|---|---|---|---|
| **his nine-region `auto` refusal** | **5,692** | **2,689** | **−52.7 %** | **115** | **53** |
| same job as `swept @1.173` | 5,692 | 2,264 | −60.2 % | 115 | 52 |
| the case-C forecast (fixed 1.5 mm) | 4,577 | 1,761 | −61.4 % | 93 | 42 |
| `fit`, nine regions | 2,178 | 1,941 | −10.3 % | 42 | 44 |

**The `fit` row is reported honestly and is the weakest of the four.** Its per-region
output was already one line each, so there was little duplication to remove; its wrapped
count rose by two because the aligned table is wider than the prose it replaced. What it
gained is the ordering — the action moved from nowhere to the second line — and columns
you can scan.

### 3.3 The audit (bar S3c)

Every multi-region refusal and forecast message reachable in the pipeline, and what
happened to each:

| message | file | verdict |
|---|---|---|
| per-region `FORECAST region_too_thin` paragraph (×N) | `run_job.cpp` pre-flight | **rewritten** → one table row |
| per-region `FIT region N:` paragraph (×N) | `run_job.cpp` pre-flight | **rewritten** → one table row |
| `FORECAST: N of M include regions are thinner than…` | `run_job.cpp` pre-flight | **rewritten** → the headline, action-first |
| `FIT: N of M include regions cannot reach…` | `run_job.cpp` pre-flight | **rewritten** → the headline, action-first |
| case A refusal (`no CONNECTED lattice at any cell size`) | `run_job.cpp` pre-flight | **rewritten** → headline / action / table / why |
| case B refusal (`the planned lattice cell is too COARSE`) | `run_job.cpp` pre-flight | **rewritten** → headline / action / table / why |
| case C note — thick enough, cell too coarse | `run_job.cpp` pre-flight | **rewritten** |
| case C note — under the accuracy floor (graded / uniform) | `run_job.cpp` pre-flight | **rewritten** |
| `vf=… NO LATTICE EMITTED — …` | `run_job.cpp` `emit_lattice` | **left alone** — one message per *variant*, not per region, and it already leads with what happened |
| `grading.subfloor.regions[]` per-region rows | `run_job.cpp` receipt writer | **left alone** — already a table (JSON), one object per region, with the shared explanation in a single `regions_note` |
| `[lattice] vf=… frozen material: printed=… latticed=…` | `run_job.cpp` | **left alone** — one aggregate line, no per-region repetition |

### 3.4 Three corrections that fell out of the rewrite

These are wording, not behaviour, but they were wrong:

1. **The old case-B remedy named a key core refuses.** It said *Set `"cell_mm"` in the
   GRADING block* on every graded path — and the schema refuses `cell_mm` alongside both
   `"auto"` and `"swept"`, which are the two modes the app can send. The action is now
   named per mode: lower `cell_min_mm` for swept, switch to `"fixed"` with `cell_mm` for
   auto.
2. **"THAT SWITCH IS NOT EXPOSED IN THE APP."** Sub-floor retention shipped to the app
   in task `2026-08-05-lattice-retention-app-control`. The message had been telling you
   to give up on a control that is on your own lattice page.
3. The same note claimed "from the iPad this region cannot be latticed at all today",
   which followed from (2) and is likewise gone.

### 3.5 Information preserved (bar S3e)

Every number the old form carried still appears. Region index, kind and thinnest extent
are table columns; cells-across is a column (it was `required_mm` arithmetic repeated
per region); the planned cell, `n_star`, the required member, the bead, the admissible
window, both floors and the derived density/strut/cells-per-member appear once each in
the headline, the action or the prose. Nothing was dropped to hit the character count.

---

## 3A · R4 — your nine-region job, end to end, at every setting

`evidence/.../r4_his_case.txt`, resolution **128** (yours), strut line width **0.45 mm**
(yours — `max(outer 0.42, inner 0.45)`, the rule task `2026-08-06-strut-line-width-field`
shipped). Three deviations from your captured job are stated in the script's header:
your `loads` block is replaced by `fixture_faces` + gravity + a one-rung ladder (the
loads path refuses `ladder`/`margin_stop` and runs to the MMA plateau — hours);
`skin` is `"none"`, not `"rim"` (a rim on a voxel-silhouette part emits zero triangles
and PR 302 made that an abort); and the `design_box` is dropped (`grading` +
`design_box` is refused outright, pre-existing).

| mode | exit | what happens |
|---|---|---|
| `auto` | **1** | refuses — the message in §6, planned cell 4.9314 mm |
| `swept` @ `cell_min 1.173` | **0** | **runs**, plans at 2.3460 mm — and emits **no lattice** |
| `fit` | **0** | **runs and lattices**: 286 cells, 318,128 triangles |

### `fit`, per region — the R4 table

| reg | thinnest | cell mm | density | strut mm | cells/member | candidates | latticed | |
|---|---|---|---|---|---|---|---|---|
| 0 | 2.828 | 1.1732 | 0.6000 | 0.4500 | 2.41 | 0 | 0 | OUT OF REGIME |
| 1 | 2.828 | 1.1732 | 0.6000 | 0.4500 | 2.41 | 0 | 0 | OUT OF REGIME |
| 2 | 2.828 | 1.1732 | 0.6000 | 0.4500 | 2.41 | 20 | 20 | OUT OF REGIME |
| 3 | 4.000 | 1.1732 | 0.6000 | 0.4500 | 3.41 | 36 | 36 | OUT OF REGIME |
| 4 | 4.000 | 1.1732 | 0.6000 | 0.4500 | 3.41 | 2 | 2 | OUT OF REGIME |
| 5 | 4.000 | 1.1732 | 0.6000 | 0.4500 | 3.41 | 0 | 0 | OUT OF REGIME |
| 6 | 6.000 | 1.2000 | 0.5806 | 0.4500 | 5.00 | 66 | 66 | certifiable |
| 7 | 6.000 | 1.2000 | 0.5806 | 0.4500 | 5.00 | 108 | 108 | certifiable |
| 8 | 6.000 | 1.2000 | 0.5806 | 0.4500 | 5.00 | 54 | 54 | certifiable |

`candidates == latticed` in **every** region — nothing you selected was silently
dropped. 26,170 printed voxels lie **outside** every declared region (the companion
body, kept solid). Certificate: `margin_worst_case = 90.019`, accepted,
`strut_out_of_regime = true`, `min_cells_per_member = 2.7618`.

### ★ Swept runs but does not lattice YOUR part — and the forecast said so first

The swept run reaches the solve and then reports
`NO LATTICE EMITTED … member_too_thin_for_cell=2, strut_unprintable_at_every_cell=284`.
Both of the plan's bounds cross on your geometry: at the 1.173 mm base the strut is
unprintable at the graded density, and every coarser rung puts fewer than five cells
across a 3.24 mm member. **The pre-flight predicted exactly this** before the solve —
*"9 of 9 … are under the accuracy floor at the planned 2.346 mm cell … SO THOSE REGIONS
WILL COME BACK SOLID"* — which is the pre-flight doing its job.

So the honest conclusion for your part is: **S1 makes swept mean what you typed, but
`fit` is the mode that actually lattices your bolt regions.** Swept is worth having
correct; it is not the answer here.

---

## 4 · Bars

| bar | result |
|---|---|
| **R1** byte-identical where nothing changed | **PASS**, 7 cases, `r1_byte_identity.txt`. A (no lattice), B (graded fixed), C (swept above the floor), F (uniform) and G (multiscale) byte-identical across every artifact; D (auto + regions) geometry identical and text deliberately different; E deliberately different (refused → runs). Both binaries asserted to differ first. **Bytes** are covered by R1/R3; **wording** by `s3_message_before_after.txt`. |
| **R2** failing test first | **DONE** for S1 (`s1_disagreement.txt` — byte-identical refusals on the unfixed binary) and S2 (`r2_s2_app_failing_first.txt` — 4 tests, 5 failures, compiled against unfixed app sources). |
| **R3** full gate table | **PASS**, `r3_gate_table.txt`. 7 swept jobs × 3 rungs. Five ran on both sides: identical verdicts and margins on every rung, **0 voxel flips of 27,691**, negative control at 1e-9 = **0**. Two previously refused and now run — `S_between_thin`, `S_underfrontier` — enumerated as the point of S1. No job that ran now refuses. |
| **R4** his own case, end to end | **DONE**, §3A and `r4_his_case.txt`. Nine regions at res 128, all three modes, per-region thinnest / cell / density / strut / cells-per-member / candidates / latticed, and the refusal quoted verbatim. |
| **R5** never weaken an assertion | **PASS**, `r5_assertion_census.txt`. 5,435 assertion messages on `origin/main`, 5,466 on the branch, **present-on-main-absent-on-branch: none**. |
| **R6** root cause with file and line | §1.5 — commit `4032ce8`, `run_job.cpp:773` and `:6059`. |
| **R7** no unfilled placeholders | none. |
| **R8** no scratch at the repository root | **clean** — `git diff --stat d9fe8f7 -- . ':(exclude)core' ':(exclude)app' ':(exclude)docs' ':(exclude)evidence'` is empty. All scratch lives in the session scratchpad. |
| **R9** separate commit for any review response | honoured on any follow-up. |

**Test suites.** Core `ctest`: **111/111 pass** (652 s). App `swift test`: **1,336 tests,
0 failures, 19 skipped** (285 s). `test_grading` grew by 10 checks (26,315 total);
`test_protect_freeze_vs_solidity`'s PF5 keeps its assertion message verbatim and now
pins the region's index, kind *and* extent on one line, which is stricter than the
prefix it replaced.

---

## 5 · Files

**Core**
* `core/include/topopt/cell_plan.hpp` — `cell_plan_max_level`,
  `cell_plan_finest_printable_cell_mm`.
* `core/src/simp/cell_plan.cpp` — the two functions; both planners now read the shared
  ladder rule.
* `core/src/cli/run_job.cpp` — `planned_cell_mm(job, swept_light_floor)` replaces the
  two copied switches; `multiscale_floor_cell_mm` is the disarmed caller; the pre-flight
  block is restructured into headline / action / table / why.
* `core/tests/unit/test_grading.cpp` — §5, ten S1 checks.
* `core/tests/validation/test_protect_freeze_vs_solidity.cpp` — PF5's marker moved onto
  the table row.

**App**
* `app/.../TopOptBridge/include/TopOptBridge.hpp`, `bridge.cpp` —
  `grading_schema_accepts_cell_mode`, and the probe document now carries an include
  region.
* `app/.../TopOptKit/TopOptKit.swift` — `gradingSchemaAcceptsCellMode`.
* `app/.../TopOptFlows/LatticeSettings.swift` — `.fit`, the serializer arm, the two
  fallbacks, the exclusion in `resolvedSubfloor`.
* `app/.../TopOptFlows/LatticeSubfloorRetention.swift` — `LatticeCellModeCapability`,
  the retention control's fit branch.
* `app/.../TopOptFlows/LatticePage.swift` — the four-way segment, the Per region body,
  the UI half of the exclusion.
* `app/.../Tests/TopOptFlowsTests/LatticeCellFitModeTests.swift` — 12 tests.

---

## 6 · In plain words

**You can now pick automatic per-region cell sizing from the app.** On the lattice
page, Cell size has a fourth option called **Per region**. Pick it and core works out a
cell size for each region you have selected, from how thick that region actually is — a
thin wall gets a fine, dense lattice and a thick member a coarse, light one. You do not
type a number. It needs at least one "lattice here" region, because that is what it
measures; with none selected the control tells you so.

**Turn "Keep the lattice where the part is too thin to certify it" OFF when you use Per
region — and the app now does that for you.** Both settings answer the same complaint
("my regions are too thin, lattice them anyway"), but they answer it in different ways
and each keeps its own books. If both were on, two mechanisms would be deciding the same
piece of material and you would get two receipts that disagree. Core refuses such a run
outright, so the app no longer lets you build one: selecting Per region switches
retention off, and the switch greys itself and says why. The rule of thumb is in the
message: **use Per region when your regions differ in thickness; use the retention
switch when one cell size has to serve all of them.**

**Your nine-region refusal now looks like this** — action second line, one row per
region, the explanation once at the bottom:

```
topopt-cli: 9 of 9 declared lattice include regions are too thin for the planned
4.931378498 mm cell — refusing before spending a solve.
SET cell size between 1.173173434 mm and 2.828427125 mm — set "cell_mode": "fixed"
with "cell_mm" in that range ("auto" takes core's own floor, which is how you got
here). Or set "cell_mode": "fit" and core derives it per region.

  region        thinnest   cells
  0 (bolt)       2.828    0.57  SOLID: under the floor
  1 (bolt)       2.828    0.57  SOLID: under the floor
  2 (bolt)       2.828    0.57  SOLID: under the floor
  3 (bolt)       4.000    0.81  SOLID: under the floor
  4 (bolt)       4.000    0.81  SOLID: under the floor
  5 (bolt)       4.000    0.81  SOLID: under the floor
  6 (bolt)       6.000    1.22  SOLID: under the floor
  7 (bolt)       6.000    1.22  SOLID: under the floor
  8 (bolt)       6.000    1.22  SOLID: under the floor
  ("cells" = the region's thinnest extent across the planned 4.9314 mm cell)

Why: a strut network only connects when at least 1 cell(s) lie across the member.
The planned 4.931378498 mm cell puts 0.5735570948 across your thinnest region
(2.828427125 mm), so this run would emit loose fragments rather than a lattice. At a
0.45 mm strut line width that region admits cells from 1.173173434 mm (printability)
up to 2.828427125 mm (percolation).
     …
```

(The remaining "Why" lines are the sub-floor explanation, once, and the note about
lattice outside your declared regions. Full text in
`evidence/.../s3_message_before_after.txt`.)

### What was done

1. Fixed the swept cell floor so a cell window you type is the window core plans with,
   and made the forecast and the planner read one rule instead of two that disagreed.
2. Added the Per region cell mode to the app, with the probe that stops it being sent to
   a core that would reject it, and made the fit/retention pair impossible to author.
3. Rewrote every multi-region refusal and forecast into action-first, one row per
   region, explanation once — and corrected three sentences in them that had become
   untrue.

### What is next, and what needs you

* **Decide whether Per region should be the default.** §2.5 has both sides. The blocker
  is that it cannot apply to a job with no selected regions, so a default needs a stated
  fallback.
* **Decide on the disarmed half of S1** (§1.4). The multiscale length-scale derivation
  still uses the old, too-coarse swept floor. Correcting it moves designs on jobs that
  run today — measured — so it is left off until you want the gate table run.
* **Two refusals were deliberately not added**, both because they would newly refuse
  jobs that run today: a swept window entirely below the printable frontier (§1.6), and
  `fit` on a job with no regions is refused by core but only *warned about* in the app.
  Both are one line each behind their own gate table.
* Nothing here changed what any run decides. If a design or a margin moves after this
  merges, that is a bug in this branch and the R1/R3 scripts reproduce the check.
