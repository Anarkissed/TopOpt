# Handoff — 2026-09-28-lattice-types-core: eight lattice types, round 1 (TRACK core)

## Where this stands, in plain language

**Types live so far: NONE. Types parked: none. K0 (the inventory) is done, the
per-type plumbing is in, and FCC is next.**

This is the first commit of the round and it deliberately contains no code. The spec
requires the octet-only inventory to be written *before* any code
(`docs/design/lattice-types/02-core-spec.md` §1), and writing it first changed what I
think the round is. The short version:

- The **certification half is already done.** `LatticeTopology` carries all ten ids,
  and `lattice_cubic_tensor`, `lattice_rho_min/max`, `lattice_resolved_rows` and
  `lattice_topology_certifiable` are already per-type with the six strut types' rows
  landed. Nothing in this round has to make a strut type *certifiable*.
- What is octet-only is the **generator** (one enum value, one `throw`) and the
  **practical numbers**.
- The round is dominated by **one substitution**: `octet_strut_diameter_mm(rho, cell)`
  is called from **44 places**, none of them topology-aware. Ten of those are inside
  `lattice_cell_printability_floor_mm` and `lattice_min_density_for_strut` — two
  functions that already **take a topology argument and ignore it**. Twenty are inside
  `run_job.cpp`'s anonymous namespaces, where no unit test can reach them.
- So the first real work is not FCC's geometry. It is giving those two functions a
  per-type table, because most of the other sites then follow, and R9 (octet
  byte-identical) is an exact test of whether the plumbing change was safe.

## What I did

1. **Branch.** Committed the tail of the #354 follow-ups as its own commit
   (`478ad2c7`, docs only — the convex-edge open item the reviewer asked to record),
   then `git fetch origin && git merge --no-ff origin/main -m "Sync: merge main"`
   (`266e1bd3`). No conflicts, as the reviewer's trial merge predicted. The merge
   brought #359 (Flexible pack), #360 (this pack,
   `core/src/materials/lattice_print_tests.json`, the DECISIONS entry) and five papers.
2. **Blocked checks, all clear.** The `2026-09-28: LATTICE TYPES ROUND 1` entry is at
   `docs/DECISIONS.md:203` with all nine items. The pack is complete (7 files + data).
   `core/src/materials/lattice_print_tests.json` exists (1310 bytes) and is identical
   to the pack's seed copy; I have not touched it.
3. **Read** ARCHITECTURE.md, the DECISIONS entry, AGENT_PROMPTS §1, and the pack
   (README, 00-decisions, 01-types, 02-core-spec, 05-roadmap; skimmed 03-app-spec).
4. **K0 — the inventory**, in
   `docs/handoffs/evidence/2026-09-28-lattice-types-core/k0_inventory.md`. 366
   mentions across 34 files, every behavioural site classified (a)/(b)/(c), line
   numbers re-grepped at the merged head rather than taken from the spec (the spec's
   were at `daa764c4` and several had drifted).

## Test evidence (raw, pasted, unedited)

Core suite minus `cli_demo`, own build directory, on the plumbing tree (`4764ca7e`):

```
100% tests passed out of 131

Total Test time (real) = 2043.89 sec
```

Integrity of that run, checked rather than assumed: `cli_demo` appears 0 times in
`LastTest.log` (correctly excluded), `strut_diameter_per_type` ran once, 131 tests
registered, and no source file is newer than the build's `libtopopt.a`. The total is
**132 with `cli_demo`**, one more than before because of the new test.

The box was also running the app's xctest suite and the Flexible agent's ctest
throughout, so **no timing from any run here is a performance measurement.**

### R9 — octet byte-identity, end to end

Reference CLI built at `4a1ccc45` (pre-plumbing) in its own worktree. **Both binaries
copied to a read-only directory before any run**, after an earlier pass was invalidated
by rebuilding the binary mid-comparison (see Warnings). Final-tree proof: the string
`"no measured density law for"` is present in the new binary and absent in the
reference, so this evidence describes the committed code including the density routing.

```
VERDICT: stl_mismatches=0 receipt_mismatches=0
```

| job | grading path | exported STL (sha256, first 16) |
|---|---|---|
| octet_uniform | `cell_mm` + `strut_radius_mm`, no grading block | `0c93e608b8b1c314` |
| cube_doubled | doubled, swept | `ce143be9baead19f` |
| cube_stepped | stepped, swept | `e86741223834d819` |
| organic_stand | organic aesthetic, M2 stand, res 128 | `d6ec8f7517031dd5` |

All four byte-identical. Receipts: 21 files, 2,106 leaves, 0 differing.

**The volatile set was PROVED, not asserted** — the reference binary was run twice per
job and only the leaves it disagreed with *itself* about were excluded. The complete
set is three field paths in six occurrences:

| field | files |
|---|---|
| `/created_wall_ms` | 4 |
| `/grading/organic/trace_seconds` | 1 |
| `/candidates[0]/trace_seconds` | 1 |

**Differs by design — identifies the binary** (listed separately, never folded into the
volatile set): `/cli_version` (`0.1.0` both), `/fingerprint` (`unknown` both),
`/build_time` (`''` both).

★ All three are EQUAL and two are EMPTY, so this category is correct and **inert**: the
comparison proves nothing about provenance. That absence is the dispatch-order defect
in Warnings below.

### Tests added

- `test_strut_diameter_per_type` (new, 158 checks): octet bit-identical through both
  directions of the law (180 (ρ, cell) pairs, 42 (cell, radius) pairs, refusals
  included); every other type refusing by name; the ceiling's own refusal type; all
  five readiness states including the one core's real sets cannot reach; the plain
  words pinned exactly; the id round trip.
- `test_job` 299 checks: the two kinds of topology refusal, and all four two-key cases
  plus the decision asserted on the pure function.

### Existing tests edited — argument-only, proved programmatically

| file | diff | check |
|---|---|---|
| `test_lattice_refusal.cpp` | −8 / +8 | every `+` equals its `−` with only `LatticeTopology::Octet, ` inserted |
| `test_stepped_plan.cpp` | −28 / +28 | same |

Same assertions, same cells, widths and tolerances; outcomes unchanged (9/9 and PASS).
Permission for each was given explicitly by the reviewer before the edit.

CI run: maintainer to fill
PR: #358 (`claude/raster-receipt-fields`)

## What I did NOT do

- **No type is live.** `lattice_gen_topology_names()` is unchanged and every new type
  refuses. FCC is next; nothing in K1 is measured yet.
- **Did not route `octet_aesthetic_density_ceiling`'s own body**, nor
  `strut_strength.cpp`'s `kOctetStrutLaw`. Both are octet's own implementations and
  stay; the per-type entry points in front of them refuse.
- **Did not answer any Q.** Q1 (sheet ceiling) and Q2 (octet's legs-only tensor, which
  is K5) are the maintainer's.
- **Did not build the Stepped beam-network certificate.** Sized above, on instruction.
- **Did not fix the fingerprint dispatch-order defect** — next commit, with a red-first
  CLI test.
- **Did not move the frame-basis check to parse time** (brief item j) — planned, own
  commit.

## Warnings for the next run

- **★ I invalidated my own evidence twice by rebuilding under a running measurement.**
  First the baseline suite (rebuilt `core/build` while its ctest ran); then the R9
  comparison (rebuilt `core/build/topopt-cli` between its 3rd and 4th job, so three
  jobs ran against the pre-routing binary and one against the post). "Suite runs get
  their own build directory" was not enough. **What works: copy the binaries under
  test to a directory and `chmod a-w` them before measuring anything.** A rebuild then
  has no path to the measurement.
- **Every `OK` a script prints must come from an exit code.** One of mine printed
  `BUILD OK` unconditionally and I read five PASSes off stale binaries before noticing.
- **`octet_strut_diameter_mm` could not be fixed by search-and-replace**, and two
  attempts bit me: two lines in `grading.cpp` were textually identical (so a text match
  was ambiguous), and a line-targeted wrap then clobbered an `if (` whose continuation
  I had not read. Both were caught by the compiler. Line-targeted edits with an
  assertion on the target line's content, and re-grep line numbers after every
  structural insert.
- **★ `lattice-variant` and `analyze` write a `run_info.json` with
  `fingerprint: "unknown"` and an empty `build_time`.** Not the worktree —
  `git -C core rev-parse` resolves fine here. It is dispatch order: `analyze` (:354),
  `preflight` (:359) and `lattice-variant` (:362) all return before `main.cpp:386`,
  where `obs.fingerprint` and `obs.build_time` are set, so `RunObservability`'s
  defaults survive (`fingerprint = "unknown"`, job.hpp:1178). Six `run_info` write
  sites across three runners; only `run_job`'s four reach :386. `preflight` writes no
  `run_info` and is unaffected. So every relattice receipt in production cannot answer
  "which core did that run use" — the exact question `main.cpp:371` says the file
  exists to answer. **Fix is the next commit.** The comment at `run_job.cpp:210`
  claiming "all four run_info write sites agree by construction" is now six sites.
- **Seven struct members still default `LatticeTopology` to `Octet`** (`grading.hpp:172`,
  `cell_plan.hpp:187`, `lattice_material.hpp:92`, `analyze.hpp:52`/`:159`,
  `pipeline.hpp:499`/`:559`). Left alone on instruction: `assert()` compiles out in
  Release, and a consumer cannot tell "set to Octet" from "defaulted to Octet". Each
  type's K1e end-to-end test must instead prove every consumer used **that** type — a
  receipt field naming it, or a number that differs from octet's.
- **`lattice_relative_density` was renamed to `lattice_density_from_strut`** (`a974e539`)
  because the old name collided with `SimpParams::lattice_relative_density`, a field
  that predates it. The field is untouched; every remaining mention of the old name is
  a `SimpParams::` reference and is correct.

## Who stamps the build identity, and who does not (reviewer, 2026-10-02)

`set_build_identity()` is process-wide, so every entry point that can reach a receipt
either states it or documents that its receipts read `"unknown"`. The complete list of
in-process callers of the three receipt-writing entry points:

| caller | calls | states the identity? |
|---|---|---|
| `core/src/cli/main.cpp` (the CLI) | `run_job`, `analyze_job`, `lattice_variant_job` | **YES**, once, before any dispatch. All three receipt paths read it |
| **`app/.../TopOptBridge/bridge.cpp:1913`** (PR 354) | `lattice_variant_job` **in-process** | **NO** → its receipts stamp `"unknown"` |
| `core/tests/validation/test_lattice_variant.cpp` (16) | `lattice_variant_job` | NO → `"unknown"`; none assert on it |
| `test_loadcase_analyze.cpp` (8) | `analyze_job` | NO → `"unknown"`; none assert on it |
| `test_lattice_hookup.cpp` (5), `test_designbox_lattice_recert.cpp` (5), `test_cli.cpp` (4), `test_3mf_import.cpp` (3), `test_mesh_job.cpp` (2), `test_protect_freeze_vs_solidity.cpp`, `test_lattice_void_exterior.cpp`, `test_bake_build_orientation.cpp`, `tests/harness/solver_arm_sweep.cpp` | one of the three | NO → `"unknown"` |
| `core/tests/validation/test_run_info_fingerprint.cpp` | all three, via the CLI as a subprocess | the CLI states it; the test asserts the receipt matches the binary's `--version` |

★ **The app line is the one that matters.** `bridge.cpp:1913` runs
`lattice_variant_job` **inside the app process**, not through the CLI, so the app's own
relattice receipts will still say `"unknown"` after this fix. Core cannot fix that from
here: the identity has to be stated by whoever owns the binary. The app already has the
value — `CoreFingerprint.value`, generated by `build_core.sh`
(`ComputeLocation.swift:12,26,105`, used for its version-skew check) — so the app side
is one call before its first bridge run:

```cpp
topopt::set_build_identity(<CoreFingerprint.value>, <build time>);
```

Stating it twice with the same value is a no-op; a *different* value throws, naming
both, so the app cannot half-adopt this and end up with two identities in one process.
**Not a core change, and not urgent** — a `"unknown"` receipt is the honest "nobody told
me" rather than a wrong SHA. Listed here because the app agent should decide, not
discover.

The test harnesses are deliberately left alone: none of them reads the fingerprint, and
touching eleven test files to set a field they ignore would be churn.

## The weld piece: why the margin moved, and the question it leaves open

The reviewer ruled on 2026-10-07: ship the GLOBAL weld piece, do not ship per-strut. The
diagnosis behind that ruling, and the one question it does not answer, are here because
the answer is about the INSTRUMENT, not about a defect.

**What was measured.** Core already writes a per-member dump for the governing load case
(`TOPOPT_ORGANIC_STRESS_DUMP`: A, B, radius, stress, knockdown), so all of this came out
of the probe's own runs with NO core change. Frozen probe `216fcdb618ca0cb1608d`,
byte-identical to the binary behind `stepped_weld_piece_ab.txt`, so the A/B table and
these numbers are one measurement. The control: recomputing core's own convention
reproduces the printed p99, max and margin on all six runs exactly. Scripts and raw
output: `evidence/2026-09-28-lattice-types-core/stepped_weld_statistic.txt`,
`weld_statistic.py`, `weld_field_compare.py`.

**Margins (1/ratio_p99), global -> per-strut:**

| plan | core's p99 | p99 by LENGTH | p99 by VOLUME | max |
|---|---|---|---|---|
| 500 | 179.0 -> 174.9 (-2.3%) | 177.6 -> 179.3 (+1.0%) | 191.6 -> 191.3 (-0.2%) | 33.9 -> 41.2 |
| 2000 | 165.7 -> 138.9 (-16.2%) | 165.9 -> 150.9 (-9.0%) | 207.1 -> 191.6 (-7.5%) | 32.1 -> 11.3 |
| 8000 | 149.8 -> 126.7 (-15.4%) | 150.4 -> 136.0 (-9.6%) | 193.8 -> 177.8 (-8.3%) | 9.2 -> 14.7 |

The hypothesis under test was that the shift is the STATISTIC: core takes one sample per
member regardless of length, so coarsening the thick struts' pieces tilts the population
toward thin, highly stressed ones. That is half right. Reweighting removes about half the
shift (16.2 -> 9.0 at plan 2000) and about nine points survive every reweighting. The MAX
moves in opposite directions by plan -- down at 500 and 8000, up 2.8x at 2000 -- so it is
one element in a million and settles nothing either way.

**What settles it is the stress FIELD.** A length-weighted mean is invariant to how
finely a strut is cut, so a difference in it is a difference in the field, not the
sampling. (The first version of that instrument FAILED ITS OWN CONTROL -- per-bin strut
length differed by 466%, because pieces are binned by midpoint and a thin bin gains or
loses a whole piece -- and those numbers were discarded. The kept version holds total
strut length identical to 7 figures and restricts bin comparisons to bins whose length
matches within 1%, reporting the covered fraction.) The whole-pocket length-weighted mean
stress rises **+7.25% (500), +18.89% (2000), +12.38% (8000)**; of the comparable bins only
18.5-30.5% agree within 5%, and individual bins move -56% to +230%. The load path
redistributes: the mechanics changed.

**The size of it.** Global cuts every strut at 0.354-0.377 mm, so a joint lands at most
0.19 mm from where the struts actually meet. Per-strut cuts the thickest strut
(r = 1.0973) at 2.1213 mm, so at most **1.06 mm -- 5.6x further**, about half the finest
cell. A thin strut arriving mid-span on a thick one has no node there and fuses to one up
to that far away. No join is LOST either way (floating_ends 0 under both rules, and the
reviewer's fusion proof holds: the reach `r_a + r_b` grows with `r_a` at the same rate the
piece does). But "no join lost" is not "the same joints".

**And why organic is sound as shipped.** Core's statistic is a length-weighted estimate
only to the extent the pieces are equal. Under the global rule the spread is
0.3536-0.3771 mm at plan 2000 -- 7%, and that spread IS the remainder pieces organic
leaves -- and core's per-element p99 lands within **0.12-0.78%** of the length-weighted
one on all three plans. Under per-strut, pieces span 0.354-2.12 mm (6x) and the two differ
by 2.5-8.6%. So organic's statistic does not depend on exact uniformity, and it is sound
BECAUSE the global rule keeps pieces near-uniform. That is a second reason to ship global,
independent of the margin.

**OPEN QUESTION (reviewer, 2026-10-07: parked, blocks nothing).** What is the correct
joint treatment for a mixed-radius lattice when a thin strut meets a thick one between
that strut's nodes? Every rule measured here fuses it to a NODE, so the joint lands at an
offset, and the only question the measurement settles is which rule makes that offset
smaller. Whether offsetting a joint at all is acceptable modelling practice -- as against
splitting the thick strut at the arrival point, or adding a rigid link -- is a research
question, not a defect. It does not block the Stepped certificate: global is the smaller
error of the two available, by 5.6x.

## Open items

- **A real part with a convex edge inside a lattice region** (carried from the #358
  follow-ups, reviewer 2026-09-30): the only term that can separate
  `lattice_certification_mask` from the posture on a real part is the shell base
  rejecting posture voxels at a convex edge. No fixture exercises it; to be built only
  if a probe/run mismatch appears.

---

## Reply to #354's core brief (`2026-09-28-core-brief-lattice-types-app-needs.md`)

Read at `origin/claude/topopt-holes-quilting-298212`. One line per item: **done**,
**planned (when)**, or **refused (why)**.

| # | Ask | Status |
|---|---|---|
| **(a)** | Per-type offer status + one plain reason when not offered | **DONE** (`4764ca7e`). `lattice_type_readiness(id, generatable, certifiable)` → `Live` / `NotGeneratable` / `NotCertifiable` / `NotEither` / `UnknownId`, each with a detailed name **and** `lattice_type_readiness_plain()` for the picker: "Strength-checked, but not buildable yet", "Buildable, but not strength-checked yet", "Not buildable or strength-checked yet", "Not a lattice type", "Ready to use". Written once in core, exact strings pinned by test. **Stop wording your own reason** — these are the words. |
| **(b)** | One complete id list incl. sheets; one name table; a round-trip test | **PART DONE, PART K2.** `lattice_topology_from_id()` is the tested inverse of `lattice_topology_name` over all ten ids, so a spelling drift cannot silently grey a type — that is your round-trip test, and it refuses near-misses (`"Octet"`, `"octet "`). The two tables are still separate (`lattice_gen_topology_name` / `lattice_topology_name`); unifying them and adding `gyroid`/`schwarz_d` to the enum is **K2**. Until then the complete display list is the enum's ten plus those two ids, which is exactly the key set of `lattice_print_tests.json`. |
| **(c)** | The parser accepts each type as it goes live | **DONE as a mechanism** (`4764ca7e`). Both gates now ask `lattice_type_readiness`, so a type is accepted the moment it joins **both** sets — no parser edit per go-live, which removes the step that could be forgotten. Your whole-job parse gate with an octet control (U1) will therefore flip by itself. |
| **(d)** | Print status through the bridge, not a file path; and how "absent" reads | **PLANNED, K4** (next after FCC). Loader + a bridge function giving `print_tested`, `date`, `note` per id. **Absent reads as not print-tested** — confirmed as the rule, and the accepted-id set is derived from the enum plus the two sheet ids, so a maintainer row for `fccz` or `reentrant` is accepted rather than refused (the narrow hand-list was corrected on 2026-09-30). |
| **(e)** | "No ceiling", stated, with a reason | **PART DONE.** `lattice_aesthetic_density_ceiling(topo)` throws `LatticeAestheticCeilingNotMeasured`, deliberately a **different** exception from the diameter law's, so you can tell "no ceiling yet" from "no table yet". The facts struct is **K3**; the sheets' "band maximum until Q1" is the maintainer's (Q1) and I have not decided it. |
| **(f)** | Sheet per-region cell + anchor key names and convention | **PLANNED, K2**, published with it. Not designed yet; I will not invent key names ahead of the generator that reads them. |
| **(g)** | Can a worker run `lattice-sample`? A capability signal | **PLANNED, K4.** The subcommand does not exist yet. When it lands it will be listed by `topopt-cli --version` output so you can detect it without a trial run. |
| **(h)** | Per-type "measured" flag for strut strength | **PLANNED, K1f per type.** Today `strut_strength.hpp` already refuses non-octet rather than borrowing (R10), so the honest receipt line exists — but as a throw, not a flag. The flag goes in the facts struct (K3) so your receipt reads core's words, not a Swift id check. |
| **(i)** | Does a Stepped job naming the beam network get that certificate? | **ANSWERED: NO, it does not.** See the sizing section below. Confirmed in the code: the call at `run_job.cpp:7603` sits inside `if (job.grading.algorithm == "organic" && job.grading.intent == "structural")`, so a Stepped job that names `structural_certification: beam_network` passes `refuse_stepped_structural` and then is certified by the **tensor**, which core's own comment says over-claims at every any-step seam. It is unreachable today only because no app sends `stepped_cells`. Sized below; the maintainer sequences the fix. **Your preview floor should follow item (c) of the sizing, not the schema.** |
| **(j)** | Check the stated frame against the plane basis at parse time | **PLANNED, small, not yet done.** `plane_basis()` is pure and already in `clearance.hpp`, so the agreement check can move to parse time beside the in-plane test added in `12ff5880`. It is a behaviour change — a job refused earlier than before — so it gets its own commit, its own red-first test, and a meaning-changes row. Note your test pins only `+z`: the parse-time check will cover every axis. |

---

## Sizing: the beam-network certificate is never run for Stepped (reviewer, 2026-10-01)

**Sized, not built.** The maintainer sequences this against FCC.

### The gap, confirmed in the code

- `refuse_stepped_structural` (`run_job.cpp:5163`) **requires**
  `structural_certification: "beam_network"` for any-step Stepped under a non-aesthetic
  intent, and its own comment explains why: cells of different families share no nodes,
  "a 9's face centre lands mid-strut on an 8's", so "the homogenised cubic tensor
  assumes shared nodes… it would over-claim at every seam".
- The certificate it names is **never run for Stepped**. The only run-path call,
  `run_job.cpp:7603`, is inside `if (algorithm == "organic" && intent ==
  "structural")`. So the job is forced to name an instrument core then does not use,
  and the tensor certificate runs instead — the exact over-claim the refusal exists to
  prevent.
- **Unreachable today**: no app sends `stepped_cells` (the app's `steppedCellsWired`
  probe is broken, and fixing it moves octet job bytes, so it waits on the maintainer).
  Every stepped job in the repo's evidence — including `STAND/SG2.json` — uses the
  legacy one-cell-per-region path, where `stepped_cells` is empty and the refusal
  returns early. **It becomes reachable the moment the app sends a plan.**

### (a) How big is running the existing certificate for any-step Stepped under Structural?

**The code is small. The solve is the unknown, and it is the real risk.**

Small, because three of the four inputs are already algorithm-agnostic:
- `hexm` (`run_job.cpp:7583`) is "solid voxels that are not lattice" — built from
  `physical_density > printed_iso && !mask`, nothing organic about it;
- `ocs` is one load case from `lattice_cert_context` plus the job's BCs;
- the weld precondition and `subdivide_beam_segments` already exist and were written
  **for octet struts** — the comment at `:7525` says so explicitly.

What is missing is **one emitter**: a `std::vector<BeamSegment>` for the placed stepped
cells. `octet_unit_struts()` (`lattice.cpp:25`) already returns the canonical cell, and
each `SteppedCell` carries `origin_mm`, `size_mm` and (ruling C) optionally `rho`. So it
is a loop — transform the unit struts per cell, radius from `lattice_strut_diameter_mm(topo,
rho, size)`. Order 30 lines plus a test.

★ **The cost I cannot bound without a real plan, and will not pretend to.** No job in
the repo places a plan, so there is nothing to measure. An ESTIMATE, labelled as one:
the stand's lattice filled ~61,880 voxels at ~1.7 mm. At an 8 mm base cell that is
roughly 600 cells; a plan using the halving ladder down to 2 mm could place several
thousand. At 24 struts per cell, and with the weld's subdivision cutting each strut to
twice the thinnest radius (sub-millimetre), that is **order 10⁵–10⁶ beam segments**
against the ~24,000 the organic stand certifies today — one to two orders of magnitude
more. The certificate's cost is in the coupled solve, so this may simply not fit.

**Recommendation:** before writing the emitter, measure the solve on a synthetic plan
of a known size and find where it stops being tractable. If it does not fit, the honest
options are a coarser weld piece (which weakens the fusion argument and must be
measured, not assumed) or refusing any-step Stepped under Structural outright until
there is a method. I would not ship the emitter without that number.

### (b) Under AESTHETIC, which certificate is honest for any-step Stepped?

**Neither of the two we have, and the current behaviour is the over-claim.**

`refuse_stepped_structural` returns early on `intent == "aesthetic"`, so an aesthetic
any-step plan is certified by the **tensor** — and the seam argument does not care about
intent. The nodes still do not line up; the tensor still assumes they do. M6 says
aesthetic certifies, so "skip the certificate" is not available.

So the honest answer is **the beam network, for the same reason as Structural** — which
makes (a)'s cost question the gate for both intents, not just one. The alternative,
if the solve will not fit, is to refuse any-step Stepped under aesthetic too and say
why; that is a product decision about whether the feature exists at all, and it is the
maintainer's.

What I would **not** do is leave aesthetic on the tensor quietly because its refusal
path happens to return early. That is the current state and it is the thing worth
fixing first, because it is live the moment a plan arrives.

### (c) Can core publish which algorithms it certifies by beam network?

**Yes, and it is the smallest item here.** The fact is a compile-time property of one
`if` at `run_job.cpp:7603`, so it can be stated as data instead of inferred:

```cpp
// which algorithms the RUN certifies with the beam network, as opposed to the
// homogenised tensor
std::vector<std::string> lattice_beam_network_certified_algorithms();
```

Today it returns `{"organic"}`. It belongs beside `lattice_gen_topology_names()`, is
trivially testable, and — the point — the app's preview floor then follows **what core
actually runs** rather than "the schema accepted the key". It should land with the fix
rather than before it, so it never advertises a certificate that is not wired.

