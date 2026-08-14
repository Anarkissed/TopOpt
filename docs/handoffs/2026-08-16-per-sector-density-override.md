# 2026-08-16 — per-sector density override: dialling one sector, not the run

Evidence: `evidence/2026-08-16-per-sector-density-override/`
Branch base: **PR 331's head** (`726160c`), stacked on PR 332 (lattice-regions).

> **"Dial a sector to 25% and its neighbour to 40% AT THE SAME DEPTH."**
> — the one thing my own §0 said was still missing, twice.

---

## §0 — THE ANSWERS

*(Filled in as each is MEASURED. Anything not measured is marked NOT MEASURED and
says why — the standing rule on this branch.)*

**Does a stated density reach the grading law? ★ MEASURED — THE FULL A/B, BOTH
ARMS COMPLETE.** Face 15 split 1×2, **both sectors at 7.5 mm — the same depth**.
Two jobs identical but for two `relative_density` keys, full production ladder:

| | sector 200 | sector 201 |
|---|---|---|
| CONTROL — nothing stated | 0.1386 | 0.1386 — **identical** |
| OVERRIDE — 0.25 / 0.60 | **0.2500** | **0.6000** — **different** |
| strut, control | 0.4200 mm | 0.4200 mm |
| strut, override | 0.5916 mm | 1.0466 mm |

Same cell (2.728446884 mm), same 5.00 cells per member, both in regime, and all
**eight** variants across the two ladders ACCEPTED. The two sectors come out
identical without the override and different with it. That is the task's own
test, and it passes.

★ **One variable moved, and only one.** `design.bin`, `fields.bin`,
`loadcase.json` and **all four variant STLs are byte-identical between the arms**;
only the lattice STLs differ. The override does not touch the optimizer — it acts
exactly where it should, at the grading step that fills an already-decided
design. A user dialling a sector's density gets a different **lattice**, never a
different **part**.

★★ **THE BEHAVIOUR A USER MUST KNOW: a stated density REPLACES the grading, it
does not cap or scale it.** The control's density spans 0.1386 … 0.8999 — the
whole certifiable band — because the law ramps density with stress. The
override's spans exactly 0.2500 … 0.6000: the two stated numbers and nothing
between them. Each region becomes **uniform** at its stated value. That is what
"dial this sector to 25 %" has to mean to be worth having, but it is a real
trade: the user gives up per-voxel stress grading inside that region in exchange
for saying what the region weighs.

Corroborating: `density_raised_for_print_voxels` is **16792 in the control and 0
in the override**. In the control the stress-graded density fell below printable
in 16,792 voxels and was raised to the 0.42 mm floor (hence its 0.4200 mm minimum
strut). With 0.25 and 0.60 stated, nothing needed raising.

**Mass:** the override is heavier at every rung (+29.2 g, +6.6 % at rung 068).
That is the honest direction — both stated values exceed the 0.1386 the
derivation picks. **The feature does not save mass; it puts the mass where the
user wants it.** `r_4b_override_vs_control.txt`.

At the unit level `grade_lattice` honours a stated density verbatim where one is
given and derives exactly as before where none is, in the SAME field:
`core/tests/unit/test_grading.cpp`, 26,321 checks, 0 failures — and **each new
check was verified by sabotaging the mechanism it watches**
(`r8_assertion_census.txt`).

**Does it work for MORE than two sectors? ★ MEASURED — a four-sector ramp.**
Face 15 grid-split 4×1 by core's own `grid_split_cells`, **all four sectors at
depth 7.5 mm**, densities ramped 0.20 → 0.60:

| sector | stated | derived | in force | strut | cells/member | latticed |
|---|---|---|---|---|---|---|
| 0 | 0.2000 | 0.1386 | 0.2000 | 0.5179 mm | 5.00 | 6214 |
| 1 | 0.3333 | 0.1386 | 0.3333 | 0.7122 mm | 5.00 | 7792 |
| 2 | 0.4667 | 0.1386 | 0.4667 | 0.8861 mm | 5.00 | 5173 |
| 3 | 0.6000 | 0.1386 | 0.6000 | 1.0466 mm | 5.00 | 6335 |

Four distinct densities and four distinct struts (a 2.02× spread) at ONE cell and
ONE depth, all in regime, all four rungs accepted, `clamped_lo = clamped_hi = 0`
and `density_raised_for_print_voxels = 0` on every rung — **not one of the four
was moved by so much as a rounding**. The differing per-sector voxel counts show
the split is real geometry, not four names for one set.

★ This is also the first run where the receipt's **stated AND derived** columns
are both populated *with a density stated* — the reader can see what the user
asked for and what the derivation would have chosen, and the app reads the valid
range straight off it. `r_4d_ramp.txt`.

**Does the core suite pass? ★ 122 of 122 ON THE REBASED TREE** — the merge
target, not the branch base (2573 s, zero failures, zero timeouts). The
DENOMINATOR MOVED: 121 registered before the rebase, 122 after, because main's
merges (#330-#333) added a test. lib3mf is still absent from this worktree
(`ctest -N` reports 0 of `export_3mf` / `threemf_import`), so this is **122 of
CI's 124**. `r_core_ctest.txt`.

**Does the app suite pass? 1484 passed on the rebased tree, 0 signal deaths.**
Three failures, all `AppModelTests` 3MF import — the documented worktree lib3mf
gap, whose own refusal text names the cause ("3MF import requires lib3mf, which
is not available in this build").

★ **It had to be re-run, and the first attempt was worthless.** I ran the app
suite straight after the rebase without rebuilding the vendored core. On this
repo that does not fail to link — it hangs or double-frees, and the log ended
truncated mid-line at the same test that crashed the last time a stale vendor was
in play. `app/scripts/build_core.sh` after ANY rebase onto core changes, then
re-run. The 126-pass figure from before that rebuild is discarded, not reported.

**Does a density core cannot print refuse, with the number, before the run?
MEASURED — and the refusal was moved to where it is worth having.** A density of
0.06 on a 2.7284 mm cell gives a 0.274 mm strut against a 0.42 mm profile width
and is refused in **15 seconds** — the time to import and voxelize — naming the
strut, the width, the cell, the lightest density that prints (0.1386), the band
ceiling, and the two remedies. **NOT clamped.** `r4_refusals.txt`.

**Where the refusal used to be: after the solve.** Both region refusals lived
only inside the grading step, which runs *per variant, after `minimize_plastic`*.
The first run of the failing fixture spent two minutes solving before I killed
it; on his part that is over an hour before the user is told a number they typed
cannot print. Both now also run immediately after the regions resolve against the
part grid, before a single solve iteration. **The copies inside grading stay** —
this is a duplicate guard, not a move, because the grading step is reachable by
other callers and a refusal must not depend on which entry point ran.

**Does every per-voxel density consumer see it? MEASURED — a complete census, and
it found one defect.** Nine consumers enumerated from the unfiltered
`relative_density` grep over `core/src` + `core/include`. Every one reads the
posture field the law writes, per voxel; none re-derives a density.
`r2_density_consumer_census.txt`.

★ **The per-region receipt was flattening stated vs derived** — it reported only
the density in force, so a reader could not tell a stated 0.25 from a derived
0.25. **This is the same defect shape as PR 332's dropped region kind**: a
per-region receipt that is the only witness to a distinction, dropping it. Fixed:
`stated_relative_density` (0 = none stated) and `derived_relative_density` now
ride beside it, and `derived` is also the floor of the valid range the app
offers, so the app reads the range off the receipt instead of re-deriving it.

**Can the device dial it? BUILT and unit-tested (11 tests).** A "Sector density"
section on the **lattice page** — one row per include role group, Auto by
default, showing core's own cell / strut / cells-per-member and the valid range.
**NOT yet exercised on device.**

★ **What it says, for his own numbers, is written down** (`r3_app_surface.txt`),
and the app / the run / the CLI refusal quote the SAME values:

| | app | the run | the CLI refusal |
|---|---|---|---|
| cell at extent 13.6422 mm | 2.73 mm | 2.728446884 | 2.728446884 |
| strut at stated 0.25 | 0.59 mm | 0.5915954957 | — |
| strut at stated 0.60 | 1.05 mm | 1.046564014 | — |
| strut at stated 0.06 | 0.27 mm | (refused) | 0.2740042783 |
| lightest that prints | 14 % | — | 0.1385609912 |

The Auto row reads 14 %, which gives a 0.42 mm strut — *exactly* the profile's
extrusion width. That is what "the lightest density that prints here" means, and
why the valid range starts there.

★ **And it BLOCKS the run, it does not merely annotate it.** A dialled density
core would refuse disables the Optimize button with the REGION'S NAME and core's
number ("Sector A: 0.27 mm strut, under the profile's width"), extra regions
counted rather than dropped. That is the page's own design-box precedent, whose
comment says the point exactly: don't let the user configure a whole page and
discover the refusal at the end. Core's refusal is now fast — it lands before the
solve — but *fast* is not *here*.

★ **Nothing in the app derives any of those numbers.** One new bridge call,
`lattice_region_derivation`, evaluates them with the same core functions
`fill_fit_region_cell` calls, in the same order. The app carrying its own copy of
the octet strut law is exactly what put its number 1.4× off core's once
(`app-octet-strut-law-differs-from-core`), and a control whose readout disagrees
with the run is worse than no readout. A test asserts the bridge's cell equals
`max(extent/N*, printability_floor_densest_mm)` read from the *other* core-backed
reading the page already trusts.

**Is layer 1 untouched? MEASURED — byte-identical, twice over.** `loadcase.json`
from the override run and from a no-override run **on the pre-task binary** share
one md5 (`c4b48e99a06f612ec99cc289f4076fda`); it carries the resolved regions with
their areas to 9 significant figures (17099.62205 mm² each), the anchors, the load
nodes and the protections.

**And R3 proper — the CAD-PROJECTED mesh:** the §4(b) arms export **byte-identical
variant STLs on all four rungs**. `r3_cad_unchanged.txt`.

★ **I got R3's control backwards first, and the correction matters.** I built it
as "project_cad_faces on vs off" by adding `"project_cad_faces": true` to one arm
and leaving the key absent in the other; the runs came out identical and I
concluded projection was a no-op making R3 vacuous. **Wrong — the flag is ARMED
BY DEFAULT** (core's own `test_default_arming.cpp`: an absent key must mean
armed), so I had compared a configuration with itself. Verified directly: the
explicit-true run is byte-identical to a key-absent run.

The consequence is the opposite of my first reading: **both §4(b) arms had
projection armed and running**, so their identical meshes ARE R3's answer. It is
non-vacuous two ways over: `cad_probe` shows the operation is large on this part
(78 B-rep faces, not fitted; 29,679 of 41,070 vertices attributed; **20,084
displaced, up to 1.70 mm**), and an explicit `project_cad_faces: false` arm
exports a **different** mesh on every rung. Three-way:

```
projection OFF vs armed                    ->  DIFFERS    (projection is live)
override vs control, both armed            ->  IDENTICAL  (R3's answer)
override vs control, upstream artifacts    ->  IDENTICAL
```

Turning projection off changes every exported mesh; changing a region's density
changes none of them. **R3 MET.**

**Is a job with no override byte-identical? ★ MEASURED — YES, all four rungs.**
The same no-override job on his part, run in parallel on the pre-task binary
(`ace0d900`) and on this one, both Release, both finished rc=0. 26 files each,
**20 byte-identical** — including `design.bin`, `fields.bin`, `loadcase.json`,
every variant STL, every `alpha.f64`, every lattice STL, and **every lattice
report JSON**.

The six that differ, exhaustively:

| file(s) | difference |
|---|---|
| 4 × `variant_*_alpha.meta` | 2 lines each, **zero of them non-path** — the file embeds its output directory and I named the two directories differently. My experiment, not the code |
| `iterations.csv` | 241 rows, header identical, **41 of 44 columns never differ**; the three that do are `wall_ms`, `geneo_setup_ms`, `geneo_apply_ms` |
| `run_info.json` | 4 keys, in two groups — below |

`run_info.json`, group (a) — **five clocks, one in disguise**: `created_wall_ms`,
`preflight_ms`, `lattice_export.gen_seconds`, `lattice_export.void_escape
.wall_seconds`, and `lattice_export.gen_fraction`. ★ That last one is generation
seconds over total seconds — *a clock wearing a fraction's clothes*. It is on the
strip list by name because it slipped through on an earlier task, and it showed
up here behaving exactly as that note predicted.

`run_info.json`, group (b) — **the two receipt fields this task adds, ADDED and
never changed**. A structural walk of both documents reports no changed VALUE
anywhere in the grading block, only four additions:

```
ONLY-IN-NEW  grading.fit.regions[0].stated_relative_density  = 0
ONLY-IN-NEW  grading.fit.regions[0].derived_relative_density = 0.1385609912
ONLY-IN-NEW  grading.fit.regions[1].stated_relative_density  = 0
ONLY-IN-NEW  grading.fit.regions[1].derived_relative_density = 0.1385609912
```

★ **This is also the end-to-end proof of those fields**, which I had flagged as
unit-tested only — and on the hardest case, a run with *nothing* stated: `stated`
reads 0 ("nothing was stated") and `derived` reads the derivation's own number.
That `0.1385609912` is the same value the CLI refusal quotes as the lightest
printable density and the same the app shows as its 14 % valid-range floor. **One
number, three surfaces.** `r1_inertness.txt`.

**What does it cost? MEASURED DIRECTLY on a Release build**, never differenced
from a wall clock (`r7_cost.txt`):

| piece | cost | how often |
|---|---|---|
| the per-voxel stated-density field | **+0.004 ms** marginal over the membership sweep that already runs | once per run |
| the law's extra branch | **0.59 ms** over the whole grid (an upper bound — only latticed voxels evaluate it) | once per graded variant |
| the pre-solve refusal | **23.6 ms** | once per run |

24 ms per run against a solve of minutes per rung — and that 23.6 ms is what buys
a refusal in 15 seconds instead of after `minimize_plastic`.

---

## §1 — WHAT WAS BUILT

### The mechanism: one optional field, one predicate branch

`GradingLawParams::region_relative_density` — a `const std::vector<double>*`,
sentinel `> 0`. `grade_lattice`'s `rho_of` gains ONE branch, **after**
`prescribed_relative_density`:

```cpp
if (params.region_relative_density != nullptr &&
    (*params.region_relative_density)[e] > 0.0)
  return (*params.region_relative_density)[e];
```

Order matters and is asserted: multiscale's `prescribed` still wins outright, so
this cannot move a multiscale run.

The per-voxel field is built by `region_density_field`, **by the same membership
test** `fit_cell_field` uses — so a voxel gets the cell and the density of the
SAME region and the two cannot disagree about which region owns it.

### The refusals

| what | where | when |
|---|---|---|
| density outside the certifiable band | job schema (`job.cpp`) | at parse, before any work |
| density too light to print at this region's cell | `refuse_unprintable_stated_density` | after the regions resolve, **before the solve** |
| region too thin to lattice at any cell | `refuse_infeasible_region_lattice` | same |
| density on a non-include region | job schema | at parse |

★ The unset-extrusion-width branch inside `refuse_unprintable_stated_density` is
**unreachable from the CLI** — the schema already refuses both
`lattice.min_extrudable_width_mm` and `grading.min_extrudable_width_mm` at 0 when
their block is present. Verified by running two jobs that try. It stays as a
guard for direct callers and is **not claimed anywhere as a demonstrated
refusal**.

### The app

`LatticeSettings.groupDensities: [UUID: Double]`, keyed by the same
`SelectionGroup.id` as `groupRoles`. Absent means Auto. `LatticeSectorDensity`
carries the control's model; `LatticeRegionEmission.density(for:role:densities:)`
is the ONE gate that keeps a density off an exclude region.

★ **The two hand-copied region encoders are now one.** `RemoteRunner` (optimize)
and `RelatticeRunner` (re-lattice) each carried their own `lattice.regions`
dictionary, and they **had already diverged**: the re-lattice copy dropped
`face_id`. Adding a third field to both by hand is precisely the one-sided edit
`RelatticeRunner`'s own header says it collapsed the grading dictionary to
prevent — in the very next block. Both now call
`LatticeRegionSpec.wireDictionary`. The `face_id` divergence closes as a side
effect and is **provably inert**: the re-lattice path's regions come from
`variantRegions`, which emits only from manual primitives and never sets
`faceID`, so the key was nil there and stays absent.

---

## §2 — TWO TRAPS WORTH THE NEXT PERSON'S TIME

**A stale vendored core does not fail to link — it double-frees.** After adding
fields to `JobLatticeRegion` on this branch, `swift test` died with SIGABRT at
the same test twice. It was not the known wandering GPU flake: the crash log
showed `___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED` in
`topopt::JobLatticeRegion::~JobLatticeRegion` — the app's vendored static core
was built against the OLD struct layout while the bridge compiled against the
new header. `app/scripts/build_core.sh` is the fix. Same family as
`rebasing-onto-a-core-change-needs-build-core-again`, with a different symptom:
**a layout change crashes in a destructor, a stale symbol hangs a test, and
neither one fails to build.**

**A SABOTAGE MUST SURVIVE ITS OWN SCRIPT CRASHING.** To prove the new checks
discriminate (bar R8) I flipped the law's sentinel from `> 0` to `>= 0`, ran the
suite, and restored the file at the end of the same Python script. The script
raised an `IndexError` on an unrelated line **before** the restore — so the
sabotage stayed in `grading.cpp`. In the same command I printed a `grep -c error`
of the build (`0`) and read *that* as the pass, while three lines lower the test
itself was printing `26321 checks, 2 failures`.

The full core suite caught it: **1 failed of 121, and it was `grading`**, failing
on precisely the two checks that sabotage targets. By then the broken source had
been compiled into `topopt-cli`, and an R1 arm had run 44 s against it.

★ Nothing measured is contaminated, and the reason is checkable rather than
asserted: the §4(b) run exec'd at 16:21:26, before the sabotage existed, and a
running process keeps its loaded image — **decisively, the sabotage forces every
region voxel to density 0.0, and that run's receipt reports 0.25 / 0.60, which the
broken code cannot produce.** The R1 arm was killed and restarted.

**How to apply:** restore in a `try/finally`, or verify the revert by re-reading
the TEST's own last line rather than a grep count from the build. And the runs
now execute a **pinned copy** of the binary, so no later rebuild can swap it
mid-flight — the neighbouring rule to *rebuilding under a running ctest voids
it*.

---

## §3 — WHAT IS NOT DONE

*(Kept honest and current; see §0 for what each depends on.)*

- **The app section has never run on a device or simulator.** `r3_app_surface.txt`
  is the model's own output through the real bridge, and is labelled as such.
- **The 3MF pair** (`export_3mf`, `threemf_import`) does not register in this
  worktree, so this branch's core evidence is **122 of CI's 124** on the rebased
  tree (121 of 123 before the rebase — main's merges added a test, so the
  denominator moved and is re-stated rather than reused).

Everything else in §0 is measured.
