# Strut line width — S2: the strut gets its own field, and the dropped width comes back

Branch `claude/strut-line-width-field-7140fd`.
Evidence: `evidence/2026-08-06-strut-line-width-field/`.
Merge-base: `56058c202db59656aa31c3da150d20f6ee776e35` (PR #304). PRs #301, #302 and
#303 are all in it.

**Build ritual on merge.** This touches `core/` AND `app/`:
`./app/scripts/build_core.sh`, `cmake --build core/build --target topopt_cli`,
restart the worker, rebuild the app. CI: `core-linux` + `app-macos`.
`materials.json` is untouched.

---

## 0. What changes for the maintainer

### 0.1 Two separate things, and they are not the same thing

This branch does two jobs that involve adjacent numbers and different keys. Keeping
them apart is the point of this section.

**★ A DEFECT IS FIXED (S0).** Your outer wall line width, 0.42 mm, was being parsed
out of the job, validated, and then dropped one line before it reached the solver.
S1 found it; this fixes it. It rides `loads.wall_line_width_outer_mm`.

**★ A DECISION IS APPLIED (S2).** The lattice strut printability floor now has its
own setting instead of borrowing the outer wall bead. On your machine it resolves to
0.45 mm where it used to be 0.42 mm. That is a deliberate change to what your device
sends, not a bug being corrected, and §4 measures it as one. It rides
`lattice.min_extrudable_width_mm` — a different key, which the drop never touched.

### 0.2 The dropped width, and what it cost

The missing line is restored at
[core/src/cli/run_job.cpp:3410](core/src/cli/run_job.cpp:3410).

| quantity | before this branch | after | delta |
|---|---|---|---|
| recorded outer wall line width, on a 0.42 / 0.45 job | 0.45 mm | **0.42 mm** | −0.03 mm |
| wall-ring thickness `t` = outer + (loops−1)·inner, 5 loops | 2.25 mm | **2.22 mm** | −0.03 mm, −1.33 % |

**Nothing else moves, and nothing you were told this week was wrong because of it.**
`t` is read by exactly one piece of arithmetic, `width_aware_knockdown()`, and only
inside a `width_aware` branch whose shipped posture is OFF
(`kProductionWidthAwareKnockdown = false`,
[core/src/simp/production.cpp:183](core/src/simp/production.cpp:183)). So no margin,
verdict, mass or recommendation moved. What was wrong was the **record**: every
`run_info.json` from a LAN/CLI run said 0.45 mm, and 0.45 mm was never a setting you
chose. The day the width-aware gate is armed, that same drop would have sized your
wall ring 0.03 mm thicker than reality — crediting the part with wall rescue it does
not have.

Device runs were never affected: the bridge writes the field straight onto the load
case and never goes through this helper.

### 0.3 What a brand-new project will use for a strut, and why it is a rule

A lattice strut is a **lone unsupported extrusion**, not a wall loop. Nobody — not
this project, not the slicer's documentation — has established which bead a slicer
actually deposits for one. So the new field does not ship your number; it ships a
**rule**: the strut width defaults to `max(outer bead, inner bead)`, the **wider**
of the two.

* On your 0.42 / 0.45 profile that is **0.45 mm**, which is the number you chose.
* On a 0.6 / 0.55 machine it is **0.6 mm**, not 0.45 mm.
* Change either bead and the default follows it.

The rule is `PrintParams.defaultStrutLineWidthMM(outer:inner:)`
([app/TopOptKit/Sources/TopOptFlows/PrintParams.swift:121](app/TopOptKit/Sources/TopOptFlows/PrintParams.swift:121)),
and 0.45 is not written anywhere as a strut width. Wider is the conservative
direction: a too-wide assumption costs grams; a too-narrow one authorises a strut the
printer cannot lay down, and then the certificate describes a member that does not
exist in the print.

You no longer have to falsify the outer wall bead to state a strut width — which is
what you would have had to do before, and which would have corrupted the wall ring
in §0.2 at the same time.

### 0.4 Your 4 mm wall's derived cell

See §4.3 for the full per-region table at resolution 128. The headline: your 4 mm
wall's derived cell goes from **1.094962 mm at a 0.42 mm strut width** to
**1.173173 mm at a 0.45 mm strut width** — 7.14 % coarser — with the strut itself
going 0.4200 mm → 0.4500 mm and the cells-per-member count 3.65 → 3.41.
**The verdict does not move.** A 4 mm wall is out of regime at both widths (the
accuracy floor needs 5 cells per member) and is latticed at both.

---

## 1. S0 — the drop, the fix, and the defect class

### 1.1 The defect, root-caused

`production_loadcase_from_job` — the ONE job.json → `ProductionLoadCase` mapping,
used by the optimize path, the analyze path and `lattice_variant_job` — copied
`wall_loops` and `wall_line_width_mm` and not `wall_line_width_outer_mm`.

* **Added:** PR #227, commit `84a1350`, 2026-07-28 20:52.
* **Dropped:** PR #228's merge-conflict resolution, commit `fc6e95f`, 71 minutes
  later, which hoisted the block into the helper and re-typed **five of its six**
  trailing assignments.

### 1.2 (c) The failing test, first

`core/tests/unit/test_job_loadcase_copy.cpp` (new), registered as ctest
`job_loadcase_copy`. It drives a `JobDescription` through the real helper and asserts
what comes out the far side. Against the **unfixed** copy
(`evidence/.../S0_failing_test_before_fix.txt`):

```
job -> load case copy (task 2026-08-06-strut-line-width-field, S0)
FAIL: wall_line_width_outer_mm (OUTER) carried  <-- the PR #228 drop
      job said 0.420000, load case got -1.000000 (the mirror-inner sentinel: the value was DROPPED)
  wall ring t = 2.2500 mm  (loops 5, outer 0.4500 mm, inner 0.4500 mm)
FAIL: wall ring t = 2.22 mm at outer 0.42 mm / inner 0.45 mm, 5 loops
2 check(s) failed
```

After restoring the assignment, the same binary (`S0_test_after_fix.txt`):

```
  wall ring t = 2.2200 mm  (loops 5, outer 0.4200 mm, inner 0.4500 mm)
all job/load-case copy checks passed
```

The test also carries the **positive control** the drop needed: a job that OMITS the
outer width must still arrive at the sentinel (`< 0`), because "mirror the inner
width" is the documented design and restoring the assignment must not turn an absence
into a zero. Same field, two different answers on two jobs that differ only in
whether they stated the key — so §1.2's assertion is reading a copied value and not a
coincidence of defaults.

### 1.3 (b) Why no test caught it, and what now does

Neither existing test crossed the boundary the merge broke:

* [core/tests/unit/test_job.cpp:434](core/tests/unit/test_job.cpp:434) asserts the
  **parser** — one step short. Still green after the drop; the parser was never broken.
* [core/tests/validation/test_production_parity.cpp:280](core/tests/validation/test_production_parity.cpp:280)
  asserts `knockdown_spec_for()` by setting `MinimizePlasticOptions::
  wall_line_width_outer_mm` **directly on the struct** — one step past. That is the
  "tests on the value type miss the call site" shape this repo has shipped defects on
  before.

**Adding the missing line is the patch, not the fix.** The defect class is a
hand-retyped copy block, and a test that enumerates fields by hand is only marginally
better than the copy that enumerates them by hand. So:

**★ The copy is now EXHAUSTIVE BY CONSTRUCTION.** The helper no longer writes
`job.loads.<field>`. It decomposes `JobLoadCase` by **structured binding**
([run_job.cpp:3325](core/src/cli/run_job.cpp:3325)), which C++ requires to name
**every** direct non-static data member — no more, no fewer — and then copies from
the bound names. Adding a field to `JobLoadCase` and not handling it **stops the
build**. Measured, not asserted: a probe field added to `JobLoadCase` and left
uncopied produces (`S0_ledger_tripwire.txt`)

```
core/src/cli/run_job.cpp:3325:15: error: type 'const JobLoadCase' decomposes into 14 elements,
                                        but only 13 names were provided
```

That is the mechanism S0(b) asked for: it fails when a field is **ADDED**, which no
enumerated test can do. The round-trip test locks the **values**; the compiler locks
the **coverage**. One member is named and deliberately not carried — `present`, which
answers "was a loads block given at all", the caller's question — and the ledger says
so on the line below it, with a test (`§4` of the test file) asserting the copy does
not start depending on it.

The helper is now declared in `core/include/topopt/job.hpp` rather than living in
`run_job.cpp`'s anonymous namespace. That is what made a test at this seam possible at
all — and the fact that it wasn't testable is a large part of why the drop survived
eight days.

### 1.4 (d) The blast radius, stated honestly

* `t` **before** the fix, on a 0.42 / 0.45 five-loop job: **2.25 mm** (outer read as
  0.45 mm — the inner width, mirrored).
* `t` **after**: **2.22 mm** (outer 0.42 mm, inner 0.45 mm).
* **Nothing else moves today.** `t` reaches only `width_aware_knockdown()` under
  `if (knockdown.width_aware)`; the production constant is `false`, and the
  gate-diagnosis wall-loops lever explicitly declines to recommend walls in the
  width-blind posture. Measured, not argued: §4.1 case C runs the split-bead job on
  the base and branch binaries and names every `run_info` key that moved.

---

## 2. S2 — the strut's own width

### 2.1 The field

`PrintParams.strutLineWidthMM`
([PrintParams.swift:92](app/TopOptKit/Sources/TopOptFlows/PrintParams.swift:92)),
beside the two wall beads, with the doc comment §0.3 summarises: what a strut is,
that nobody has established which bead a slicer deposits for one, and why wider is
the direction to be wrong in.

**(b) The default is a rule, not a literal.** The initialiser takes
`strutLineWidthMM: Double? = nil` and resolves `nil` through
`defaultStrutLineWidthMM(outer:inner:)` = `max(outer, inner)`. `fdmDefault` does not
state a strut width at all — it derives 0.45 mm from its own 0.42 / 0.45 beads. There
is no `0.45` literal anywhere in the strut path; `StrutLineWidthTests.
testStrutWidthFollowsTheMachineNotAConstant` drives four different bead pairs through
it, three of which do not resolve to 0.45.

**(c) Migration.** `PrintParams` already used the `decodeIfPresent(...) ?? default`
pattern; the strut width follows it, with one refinement: it defaults against the
project's **own decoded beads**, not against `fdmDefault`'s.

| a project saved… | resolves its strut width to |
|---|---|
| after this change, having stated one | exactly what it stated (lossless round trip) |
| before this change, beads 0.42 / 0.45 (the shipped profile) | **0.45 mm** — was 0.42 mm |
| before this change, beads 0.62 / 0.58 (a 0.6 nozzle) | **0.62 mm** — not 0.45 mm |
| before line widths existed at all | 0.45 mm, from the defaulted beads |

Four decode tests cover those four rows. **The second row is a real change to an
existing project's result**, and it is the deliberate change this task exists to
make — §4 measures it. It is not a silent migration: it is the same rule a new
project gets, applied once, and thereafter the stored value wins.

**Editing.** The field is stored and round-trips, but has **no row in the Print
Parameters sheet yet**. It does not need one to deliver the decision — the rule
produces 0.45 mm on the shipped profile without anyone touching a wall bead. Adding a
row later needs no second migration. Stated here because "there is a field" and
"there is a control" are different claims.

### 2.2 (d) The call-site audit — every one, and why

**★ The brief listed six sites. Five of them are lattice sites; the sixth is not.**

| site | what it feeds | changed? |
|---|---|---|
| [AppModel.swift:274](app/TopOptKit/Sources/TopOptFlows/AppModel.swift:274) | `lattice.runSpec(lineWidthMM:)` → the JOB and the BRIDGE | **→ strut width** |
| [LatticePage.swift:144](app/TopOptKit/Sources/TopOptFlows/LatticePage.swift:144) | `LatticeBounds.compute` — the page's bounds + refusal text | **→ strut width** |
| [LatticePage.swift:186](app/TopOptKit/Sources/TopOptFlows/LatticePage.swift:186) | `LatticeOptimizeSurface.compute` — the panel summary row | **→ strut width** |
| [WorkspacePlaceholder.swift:2022](app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift:2022) | the re-lattice job's spec | **→ strut width** |
| [WorkspacePlaceholder.swift:2112](app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift:2112) | the re-lattice receipt echo | **→ strut width** |
| [AppModel.swift:293](app/TopOptKit/Sources/TopOptFlows/AppModel.swift:293) | `RunRequest.wallLineWidthOuterMM` → `loads.wall_line_width_outer_mm` (LAN) and `BridgeLoadCase.wall_line_width_outer_mm` (device) | **NO — this is a WALL-LOOP site** |

The brief's list of six included `AppModel.swift:293`, which is the RunRequest's outer
**wall** bead. Following it: `RunModel.swift:1034` → `TopOptKit.swift:1584` →
`BridgeLoadCase.wall_line_width_outer_mm` on device, and `RemoteRunner.swift:803` →
`loads.wall_line_width_outer_mm` in the job. That is the exact field S0 spent a fix
restoring; redirecting it would corrupt the wall ring §0.2 is about. **It was left
alone deliberately**, and the guard test asserts five strut sites, not six.

Deliberately **not** redirected, all wall-loop consumers:

| site | why it keeps the wall bead |
|---|---|
| `PrintParamsSheet.swift:172, :209, :326` | the sheet's outer-wall field, its read-only label and its stepper — this IS the wall bead's editor |
| `RunModel.swift:88, :145, :168, :1034` | `RunRequest`'s wall field and its hand-off to the device bridge |
| `RemoteRunner.swift:803` | the LAN job's `wall_line_width_outer_mm` |
| `TopOptKit.swift:1519, :1584` / `Smoothing.swift:105, :123` | the bridge's `BridgeLoadCase.wall_line_width_outer_mm` mapping |

Copy that named the wrong setting was corrected with the sites, because a refusal that
tells the user to edit a **wall** setting to move a **lattice** floor is the same
conflation in prose:

* `LatticePageModel.swift:273` — "auto density needs your **outer line width**…" →
  "needs a **strut line width** … set your wall line widths in print settings".
* `LatticePage.swift:1225` — "set an outer line width to read it" → "set your wall
  line widths to read it"; "prints at your line width" → "prints at your **strut**
  line width".
* `LatticeSettings.swift:822` — the `lineWidthMM` parameter doc now says STRUT and
  names the field.

### 2.3 (R2) The missed-call-site failure, reproduced

A value test can only assert about sites that exist; the risk is a site added later,
or one of the five missed now. So the guard is a source walk over
`Sources/TopOptFlows` (`StrutLineWidthTests.testNoLatticeLineWidthSiteReadsAWallBead`)
that fails on any `lineWidthMM:` argument whose value is a `printParams` property
other than `strutLineWidthMM`, plus a count. Its twin
(`testWallLoopConsumersStillCarryTheWallBead`) fails if the strut width appears in
`PrintParamsSheet` / `RunModel` / `RemoteRunner`.

Both were reproduced failing (`S2_missed_call_site_tripwire.txt`), in both directions:

```
=== PROBE 1 — one lattice site reverted to the WALL bead ===
    error: … XCTAssertEqual failed: ("4") is not equal to ("5") - the five audited lattice sites …
    error: … XCTAssertTrue failed - lattice lineWidthMM site(s) reading a WALL bead:

=== PROBE 2 — the strut width wired into a WALL-LOOP consumer ===
    error: … XCTAssertFalse failed - PrintParamsSheet.swift is a WALL-LOOP consumer
                                     and must not read the strut width
```

The script restores both files and re-runs the guards green.

---

## 3. S3 — the two consumers still agree

`core/tests/tools/probe_fit_flips.cpp`, built and run with the new field in force
(`S3_probe_fit_flips.txt`):

```
PR #301 cross-check @ 0.45 mm: their control floor 1.17317343413935 mm,
                               this derivation 1.17317343413935 mm,
                               delta 0.000e+00 mm — AGREE
```

PR #301's cell-size control is bounded below by core's densest-end printability
floor, recorded as **1.173173434139347 mm at a 0.45 mm stated strut width**. PR
#302's `fit` derivation computes the same number from
`w / phi(rho_max)`. They agree to the last digit. **No divergence; no blocked-stop.**

The probe also reproduces PR #302's own row for his geometry exactly — at a **0.45 mm**
stated width a 4 mm extent derives cell **1.1732 mm**, strut **0.4500 mm**, **3.41**
cells per member — and prints the whole FIT table at both 0.42 mm and 0.45 mm so no
figure appears without the width it was computed at.

---

## 4. S4 — the change, measured as a change

### 4.1 (a) R1 — byte-identical where the strut width is UNCHANGED

`S4a_byte_identity.sh`, base worktree at `56058c2` built fresh, branch built fresh,
**both binaries asserted to differ before a single artefact is compared**
(`b416d25f…` vs `dcc8a912…`).

| case | what it is | result |
|---|---|---|
| **A** | equal beads (outer 0.45 mm = inner 0.45 mm), no lattice — the S0 no-op | **byte-identical**: report.json, fields.bin, design.bin, all four variant STLs, run_info.json (minus named clocks), iterations.csv |
| **B** | a graded lattice at a fixed 0.45 mm stated strut width, base vs branch | **byte-identical**, including `variant_060_lattice.stl` and its receipt — so the code motion that took `production_loadcase_from_job` out of the anonymous namespace changed nothing |
| **C** | ★ control: split beads (outer 0.42 mm, inner 0.45 mm) | **MOVED**, as it must |
| **D** | ★ control: the same graded job at a 0.42 mm vs a 0.45 mm stated strut width | **MOVED**, as it must |

Case C is the S0 fix, and it names its own blast radius. **Exactly two keys moved,
and nothing else in the run did:**

```
  keys that moved (base -> branch), clocks excluded:
    wall_line_width_outer_mm: 0.45  ->  0.42
    wall_thickness_mm: 2.25  ->  2.22
```

report.json, fields.bin, design.bin, every variant mesh and iterations.csv are all
byte-identical across the fix. That is S0(d) discharged by measurement rather than by
argument: **the corrected width changed the record and nothing else.**

**And the other case moves.** A project on the shipped 0.42 / 0.45 profile does not
fall under case A or B — its strut width goes 0.42 → 0.45 mm, every derived cell
moves, and §4.2 enumerates exactly what that does.

### 4.2 (b) The full flip table for the case that moves

`S4b_flip_table.sh`, l-bracket at resolution 40, three-rung ladder, graded `fit`, on
**two region sizes** — because the width acts through two different terms and quoting
only one would misdescribe the change.

**The negative control first.** A width perturbation of 1e-9 mm (0.42 vs
0.42 + 1e-9) produces, at every rung on both fixtures: **0 voxel-class flips,
max |Δρ| = 0.000e+00, identical design fingerprints.** So the floor holds and a
non-zero count below would be signal.

**★ THE DESIGN DOES NOT MOVE AT ALL.** 0.42 mm → 0.45 mm, all three rungs, both
fixtures: **0 voxel-class flips, max |Δρ| = 0.000e+00, design fingerprint SAME**, and
every rung's verdict, worst-case margin, effective margin and printed fraction
identical to ten significant figures:

| rung | verdict @ 0.42 mm | worst-case margin @ 0.42 mm | verdict @ 0.45 mm | worst-case margin @ 0.45 mm | moved? |
|---|---|---|---|---|---|
| 0.8000 | ACCEPTED | 3557.917204 | ACCEPTED | 3557.917204 | no |
| 0.7000 | ACCEPTED | 3545.384123 | ACCEPTED | 3545.384123 | no |
| 0.5998 | ACCEPTED | 3517.250009 | ACCEPTED | 3517.250009 | no |

That is not luck and it is not a vacuous bar (case D above proves the width reaches
the run). On a graded two-step run the cell law runs **after** the solve, so the
optimizer's trajectory cannot depend on the strut width. PR #302's `r6_cost.sh`
established this for the cell *mode*; it holds for the *width* too.

**What does move — enumerated, each figure beside its width:**

| | THIN 4 mm region | THICK 12 mm region |
|---|---|---|
| which floor binds | the FINEST PRINTABLE CELL | the ACCURACY floor (extent / N*) |
| derived cell @ 0.42 mm | **1.094962 mm** | **2.4000 mm** |
| derived cell @ 0.45 mm | **1.173173 mm** (+7.14 %) | **2.4000 mm** (unchanged) |
| region density @ 0.42 mm | 0.6000 | 0.1751469353 |
| region density @ 0.45 mm | 0.6000 | **0.1961376994** (+11.98 %) |
| strut | 0.4200 → **0.4500 mm** | 0.4200 → **0.4500 mm** |
| cells per member | 3.653095 → **3.409556** | 5.00 → 5.00 |
| latticed voxels | 171 → 171 | 635 → 635 |
| voxels whose density was raised to print | 12 → 12 | 0 → 0 |
| emitted `variant_0NN_lattice.stl` | **DIFFERS at all three rungs** | **IDENTICAL at all three rungs** |
| emitted `variant_0NN.stl` (the design) | IDENTICAL | IDENTICAL |

**Every one of those is explained by the width change:**

1. *Thin region, cell moves.* `cell = max(extent / N*, w / φ(ρ_max))`. At a 4 mm
   extent the second term binds, and it is **linear in the width**:
   1.173173 / 1.094962 = 1.0714 = 0.45 / 0.42 exactly. The emitted lattice is built
   on that cell, so its STL must differ — and does.
2. *Thick region, cell does not move.* At a 12 mm extent `extent / N*` = 2.4 mm binds
   at both widths, so the cell is width-independent there. The width lands instead on
   the density that prints at that cell, ρ = 0.1751 → 0.1961 — again linear:
   0.1961377 / 0.1751469 = 1.11985, and the octet strut law is not linear in ρ, so
   this ratio is not 0.45/0.42; the STRUT is, 0.42 → 0.45 exactly.
3. *Thick region, STL identical despite the density moving.* The region row's density
   is the **floor** the region would be raised to, not what was emitted.
   `density_raised_for_print_voxels` is **0** at both widths and `rho_used` is
   `[0.5646652974, 0.89988]` at both — every voxel's own solved density already
   printed, so the floor never fired and the geometry is the same object. The receipt
   moved; the part did not.
4. *Thin region, `density_raised` = 12 at both widths.* Twelve voxels fell under the
   floor at both widths, so the COUNT does not move — but they were raised to a
   different value on a different cell, which is (with 1) why the mesh differs.
5. *Latticed / candidate counts unchanged.* Which voxels are latticed is decided by
   the region declaration and the demand field, neither of which the width touches.

**No flip is unexplained, so there is no blocked-stop here.**

### 4.3 (c) His own part, resolution 128, both widths side by side

`S4c_his_part.sh` — WallMount_ShelfBracket.stl, his loads block verbatim, seven
include regions each 4 mm across, through the **analyze** path (the optimize ladder
on this job still cannot be bounded: `simp.max_iterations` is parsed and dropped on
the loadcase path, root-caused in PR #302's `q3c_max_iterations_ignored.md` and
unchanged here). The 0.42 mm column reproduces PR #302's committed table exactly.

| region | extent | cell @ 0.42 mm | cell @ 0.45 mm | ρ | strut @ 0.42 / 0.45 | cells/member @ 0.42 / 0.45 | candidates | latticed |
|---|---|---|---|---|---|---|---|---|
| 0 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 238 | 238 |
| 1 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 396 | 396 |
| 2 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 384 | 384 |
| 3 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 576 | 576 |
| 4 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 672 | 672 |
| 5 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 828 | 828 |
| 6 | 4.0000 mm | 1.0950 mm | **1.1732 mm** | 0.6000 | 0.4200 / **0.4500** mm | 3.65 / **3.41** | 1320 | 1320 |

Totals at BOTH widths: region_voxels 46291, latticed 4414, solid_fallback 41877,
density_raised 4414, out_of_regime_voxels 0, distinct cells 1. Every candidate in
every region was latticed at both widths; the counts do not move.

**★ THE VERDICT DOES NOT MOVE**, and neither does anything that feeds it:

| | @ 0.42 mm | @ 0.45 mm |
|---|---|---|
| verdict | REJECTED | REJECTED |
| worst-case margin | 2.612793696 | 2.612793696 |
| effective margin | 0.5410123586 | 0.5410123586 |
| peak von Mises | 18.00739053 MPa | 18.00739053 MPa |
| voxel mass | 244.059339 g | 244.059339 g |

That is what §0.4 predicted: a 4 mm wall is **out of regime at both widths** — it
needs 5 cells per member for the accuracy floor and gets 3.65 at 0.42 mm, 3.41 at
0.45 mm — and it is **latticed at both**, so the width moves the cell without moving
which side of any gate the part is on. (The REJECTED verdict here is the analyze
gate's verdict on the SOLID part as drawn under his declared load — his own standing
result, identical at both widths. The strut width did not cause it and does not
change it.)

**His 4 mm wall's derived cell: 1.094962 mm at a 0.42 mm strut width →
1.173173 mm at a 0.45 mm strut width, 7.14 % coarser.**

---

## 5. Bars

| bar | status |
|---|---|
| **R1** byte-identical where nothing changed, by stash-rebuild checksum | **PASS** — §4.1, both binaries rebuilt and asserted different; two positive controls fired |
| **R2** failing test first, for S0 and for the missed-call-site risk in S2 | **PASS** — §1.2 (0.42 → −1.0, `t` 2.25 mm) and §2.3 (both directions) |
| **R3** no number quoted without its width | **PASS** — every cell / strut / cells-per-member figure in §0.4, §3, §4.2 and §4.3 carries its width; `probe_fit_flips` prints the whole table at both |
| **R4** never weaken or delete an assertion | **PASS** — `R4_assertion_sweep.txt`: the sweep over `core/tests` and `app/TopOptKit/Tests` returns nothing. Both test files are NEW (`test_job_loadcase_copy.cpp`, `StrutLineWidthTests.swift`); no existing test file is modified, so no line could be renamed or removed |
| **R5** root cause with file and line | **PASS** — §1.1 ([run_job.cpp:3410](core/src/cli/run_job.cpp:3410), commits `84a1350` / `fc6e95f`) |
| **R6** no unfilled placeholders | checked by grep before commit |
| **R7** separate commit for any review response | to be honoured if review follows |

### 5.1 Test suites

`R7_test_suites.txt`. Core: **107/107 ctest targets pass**, including the new
`job_loadcase_copy`. App: **1324 Swift tests, 18 skipped, 0 failures.**

★ **An earlier core run reported three failures — `cli_demo`, `design_stream`,
`lattice_variant`, all segfaulting inside `topopt-cli` — and they were an artefact
of the build directory, not of this change.** The S0(b) tripwire probe temporarily
added a field to `JobLoadCase`; that build failed part-way, and the header restore
landed in the same wall-clock second as `job.cpp.o`, so `make` left ONE translation
unit compiled against a `JobDescription` 8 bytes larger than `main.cpp` expected.
`load_job_file` then returned by value over `main`'s stack into `materials_path`, and
the crash surfaced in libc++ string code during materials loading — nowhere near the
change. The base-ref binary ran the identical job cleanly, which is what identified
it as local. `cmake --build core/build --clean-first` cleared it. Recorded because
the next person to build a compile-time tripwire will hit it.

### 5.2 Blocked-stops — none hit

* **The exhaustive-copy mechanism was achievable.** §1.3: a structured binding over
  `JobLoadCase`, which fails to compile when a field is added. A hand-enumerated test
  was not the only option and is not what shipped.
* **A project saved before this change migrates without a silent result change.** It
  changes — 0.42 → 0.45 mm on the shipped profile — and the change is stated, ruled,
  tested (§2.1) and measured (§4.2, §4.3). Silent is what it is not.
* **S3's two consumers agree**, delta 0.000e+00 mm (§3).
* **No verdict moves on his part from the width change alone** (§4.3).
* **Nothing hardcodes 0.45.** The rule is `max(outer, inner)`; four bead pairs are
  driven through it, three of which do not resolve to 0.45.

### 5.3 Two things this branch found and did not fix

1. **The brief's site list was one long.** `AppModel.swift:293` is a wall-loop site,
   not a lattice one (§2.2). Reported rather than acted on.
2. **`simp.max_iterations` is still ignored on the loadcase path.** It blocks the
   full optimize ladder on his own job, which is why §4.3 uses the analyze path.
   Root-caused in PR #302's evidence; unchanged here.

---

## 6. In plain language — what was done, and what happens next

**What was asked.** Two things, deliberately kept apart. First, fix the bug stage 1
found: the outer wall line width you set was being thrown away before it reached the
solver. Second, stop the lattice strut borrowing that same wall setting, and give it
a setting of its own.

**The bug is fixed, and here is what it cost you: nothing today, something later.**
The line that hands your 0.42 mm outer wall width to the solver was deleted during a
merge on 2026-07-28 and is now back. The only number it feeds is the thickness of the
solid wall ring the accept gate can credit a part with — 2.25 mm was being recorded
where 2.22 mm was true. That credit is switched off in the shipped build, so no
margin, verdict, weight or recommendation you have been given is wrong because of it,
and the measurement in §4.1 confirms that: on a job with your two widths, exactly two
numbers in the whole run change and every other file comes back byte for byte
identical. What was wrong was the record — your run reports said 0.45 mm, and that
was never a setting you chose. The day the width-aware gate is switched on, the same
bug would have credited your part with 0.03 mm of wall it does not have, so it is
worth having fixed now rather than then.

**A brand-new project will assume a 0.45 mm strut, and that is a rule, not your
number.** A lattice strut is a single unsupported thread of plastic thrown across
open space. A wall loop is a closed perimeter laid against its neighbours and against
the layer below. They are different printing problems, and nobody — not this project,
not the slicer's own documentation — has established which bead width a slicer
actually uses for a strut. So instead of writing 0.45 into the code, the new setting
takes **the wider of your two wall line widths**. On your machine (0.42 outer, 0.45
inner) that is 0.45 mm, which is the number you chose. On a 0.6 mm nozzle it would be
0.6 mm. Change a bead and it follows. Wider is the safe direction to be wrong in: too
wide only makes the lattice coarser and the part a few grams heavier, while too narrow
authorises a strut the printer cannot actually lay down, and then the certificate is
describing a member that does not exist in the print.

You will not find a box for it in the print-parameters sheet yet. You do not need
one — the rule gives you 0.45 mm without touching anything. What you no longer have
to do is the thing you would have had to do before, which was falsify your outer wall
setting to 0.45 in order to move the strut floor, corrupting the wall-ring number at
the same time.

**Your 4 mm wall's cell becomes 1.173173 mm.** It was 1.094962 mm at the old 0.42 mm
assumption — 7.14 % coarser now, with the strut going from 0.4200 mm to 0.4500 mm and
the wall spanning 3.41 cells instead of 3.65. Measured on your own bracket at
resolution 128, all seven regions (§4.3). **Your verdict does not move**: the wall is
out of regime at either width — the accuracy floor wants 5 cells across a member and
your wall gives less than 4 at both — and it is latticed at either width, so nothing
about which side of a gate you are on changes. Margin, peak stress and mass come back
identical to ten digits.

**One thing worth knowing about how little else moved.** The strut width does not
touch the optimizer at all. Across three ladder rungs and two region sizes the
optimized design came back with zero changed voxels and identical margins — because
the lattice is decided after the solve, not during it. What the width changes is the
lattice laid into the finished design: on a thin region the cell and the emitted mesh
both change; on a thick region the cell is set by the region's own size instead and
only the report moves.

**What happens next.** Nothing is required of you. On merge the maintainer rebuilds
the core and the app and restarts the worker; your next new project picks up the
0.45 mm strut assumption by itself, and any project you already saved picks it up the
first time it is opened. Two loose ends are recorded rather than fixed: the iteration
cap is still ignored on jobs with a declared load case, which is why the full
three-rung run on your own bracket still cannot be bounded on this machine; and the
lattice strut width has a rule but no on-screen control, which is a decision for
whoever adds the row.
