# 102 — cli_demo achieved-volume-fraction drift: the plateau hypothesis is dead; the cause is handoff 094's reporting basis (BLOCKED — maintainer's invariant call)

**Status:** Diagnosis complete. No code change made — tree is clean.
**Verdict:** The task's lead hypothesis (086 MMA plateau firing early, enabled on the CLI
by PR 119) is **killed by evidence**. The real cause is **handoff 094** (`bec806e`,
"Fix savings % basis"), which redefined the *reported* achieved volume fraction on the
no-box path from the optimizer's continuous fraction to a thresholded voxel count — a
number that, on the grayscale MMA field, is genuinely 0.03–0.09 below the request. PR 119
is a red herring. Resolving the resulting invariant conflict is the maintainer's call
(it pits the cli_demo "achieved vf ≈ request" invariant against 094's "savings% == mass
basis" invariant, and any fix reaches the report schema / app savings display — outside
this task's stated scope of "core only, plateau logic + tests").

Handoff-number note: main tops out at 100 (clearance regions, merged via PR #123). The
remote-run-liveness-watchdog task is queued (worktree present), taking 101; this is 102.

---

## TL;DR

- **cli_demo fails 3 checks** — line 252, "achieved volume fraction within 0.01 of its
  request", one per rung {0.7, 0.5, 0.3}. Reproduced locally (STL path; the failure is
  independent of lib3mf, confirming THE FACTS).
- **The plateau never fires.** The demo job pins `simp.max_iterations = 30`; every rung
  runs to that cap. Per-iteration trace: `stop=0` on every iteration of every rung.
  Forcing `mma_plateau_window = 0` produces **byte-identical** volume fractions. The
  detector is inert here — it cannot be the cause.
- **The optimizer is feasible.** Its continuous achieved fraction Σρ/n_active lands on the
  target to ~3e-4: **0.6997 / 0.4997 / 0.2997** for requests 0.70 / 0.50 / 0.30.
- **The reported number is a different quantity.** Since 094, the no-box path *overwrites*
  `variant.optimization.volume_fraction` with `printed_voxels / part_solid` =
  `#{ρ>0.5} / part_solid` (the same count the reported mass uses). On the gray MMA field
  that count is **0.673 / 0.424 / 0.207** — off by **0.027 / 0.076 / 0.093**. The 0.30
  rung's 0.093 error is not "small".
- **Code-bisect isolates 094, not 119.** At `bec806e`'s parent `9613759` the vf checks
  PASS; at `bec806e` itself they FAIL with the identical line-252 signature as today's
  main. PR 119's config deltas (min-feature, solver flip) do not move the vf at all.

---

## The one-flag bisect (transcripts)

Method: instrumented `simp_optimize` (masked overload) to print per iteration
`{compliance, achieved vf, target, |vf−t|, change, stop}`, and `minimize_plastic` to print
`{continuous vf, printed_voxels, part_solid, count/part, reported vf}` per rung, both gated
by `TOPOPT_PLATEAU_TRACE`. Added env flags in `run_job.cpp` (self-weight branch) to flip one
production knob at a time. All instrumentation has been **reverted** — the tree is clean.

Demo self-weight run, resolution 48, ladder {0.7, 0.5, 0.3}, `max_iterations = 30`:

```
BASELINE (production, as-is)
  rung 0  req 0.7000  continuous 0.69970  printed 11514  part_solid 17112  reported 0.67286
  rung 1  req 0.5000  continuous 0.49973  printed  7258  part_solid 17112  reported 0.42415
  rung 2  req 0.3000  continuous 0.29966  printed  3534  part_solid 17112  reported 0.20652

mma_plateau_window = 0   → IDENTICAL to baseline (0.67286 / 0.42415 / 0.20652)
min_feature_mm     = 0   → IDENTICAL to baseline
solver = JacobiCG        → IDENTICAL to baseline
```

- **`plateau_window = 0` changes nothing** → the plateau detector is not on the code path
  that produces the failing number. Hypothesis killed.
- **`min_feature_mm = 0` changes nothing** → PR 119's filter change is inert here.
  `physical_filter_radius(2.5 mm, spacing≈1.75 mm)` floors to 1.5 voxels — the same radius
  the `min_feature_mm = 0` default (`simp.filter_radius = 1.5`) already uses. (Consistent
  with the min-feature-floor note in memory.)
- **`solver = JacobiCG` changes nothing** → MultigridCG_Matfree solves the identical system;
  the design (hence the vf) is solver-invariant, as designed.

Per-iteration trace confirms the plateau state directly (rung 0, target 0.70, tail):

```
[trace] it=28 c=2.831818e-05 vf=0.69870 target=0.70000 |vf-t|=0.00130 change=0.19980 stop=0
[trace] it=29 c=2.830582e-05 vf=0.69926 target=0.70000 |vf-t|=0.00074 change=0.19980 stop=0
[trace] it=30 c=2.828550e-05 vf=0.69970 target=0.70000 |vf-t|=0.00030 change=0.19980 stop=0   ← cap
```

`stop=1` never appears in any rung. `change` sits at the 0.2 move limit throughout — the run
ends on the 30-iteration cap, not on plateau and not on `change_tol`.

---

## The git code-bisect (which merge turned it red)

The maintainer is bisecting CI's Actions history; here is the corresponding **code** bisect.
094 and 119 are **parallel branches**, both later merged to main (neither is an ancestor of
the other), so the clean before/after is 094's own parent→commit pair. Built `test_cli` at
each with the identical toolchain (AppleClang, Release, brew OCCT+Eigen; no lib3mf, so the
STL path runs and the run-2 CLI-binary checks are the only unrelated failures):

| commit | what it is | line-252 vf checks |
|---|---|---|
| `9613759` | 094's parent (Merge #116, savings-floor **diagnosis** only) | **PASS** |
| `bec806e` | **094** "Fix savings % basis" (no-box reporting overwrite) | **FAIL ×3** |
| `f57f73d` | today's main (worktree base) | **FAIL ×3** (identical) |

`bec806e` touched `core/src/simp/minimize_plastic.cpp` and its own unit test
`test_minimize_plastic.cpp` — but **not** `test_cli.cpp` and **not**
`tests/fixtures/demo/expected_values.json`. The cli_demo invariant was never reconciled with
the new basis. PR 119 (`9f9e0d3`) never contained 094 and its config deltas are inert here
(above), so it cannot be the merge that turned CI red.

---

## Root cause, precisely

`minimize_plastic.cpp` (~line 569, current main):

```cpp
if (report_part_relative && part_solid > 0.0)
  variant.optimization.volume_fraction =
      static_cast<double>(printed_voxels) / part_solid;   // #{ρ>0.5} / part_solid
```

with `report_part_relative = !expanded || part_relative` → **true on the no-box demo**
(handoff 094 extended the box-only 080 overwrite to the no-box path). 094's own comment names
the tension exactly:

> "on the grayscale MMA field the two [continuous fraction vs `#{ρ>0.5}`] disagree and grow
> apart with finer features … Reporting `printed_voxels / part_solid` makes the % and the
> mass two views of one voxel count, so they can no longer disagree."

So the reported "achieved volume fraction" is deliberately the **mass basis** (thresholded
count), chosen so the app's savings% and mass cannot contradict each other. The optimizer's
**volume constraint** still targets and hits the *continuous* fraction (Σρ/n_active ≈ target).
The two bases diverge because the production updater is **MMA, which has no Heaviside
projection** (`projection_supported(MMA) == false`), so the field stays gray — a large
sub-threshold fringe carries real mass in Σρ but contributes 0 to `#{ρ>0.5}`. The drift grows
as the target shrinks (0.027 → 0.076 → 0.093), consistent with the void fringe being a larger
share of a smaller printed set.

There is no bug in the optimizer, the plateau logic, the solver, or PR 119. The failing test
compares the request against a quantity that 094 redefined to mean something else.

---

## Why this is BLOCKED (task option 3), not fixed here

Every available resolution changes an invariant or reaches outside "core only, plateau logic
+ tests" — it is the maintainer's call which invariant wins:

1. **Un-overwrite `variant.optimization.volume_fraction` (revert 094 for the report field),
   keep the count basis in a separate savings/mass field.** Honest for *this* test (the
   optimizer really did achieve ~0.70) but **re-opens the 093/094 defect**: the app's
   savings% and mass would once again disagree on gray fields. Touches the report schema the
   app/bridge consume → explicitly out of scope ("no bridge, no app").
2. **Crisp the MMA design (Heaviside projection on MMA).** Would make `#{ρ>0.5} ≈ Σρ` and the
   report honest under 094's basis. This is the deferred "Option A" in `simp.hpp`
   (`projection_supported`) — a substantial numerical feature, far beyond plateau logic.
3. **Change the test to compare the continuous achieved fraction** (or set an expected count
   basis in `expected_values.json`). That is *changing the invariant* — the maintainer's
   call, per the task.
4. **Widen the 0.01 tolerance / opt the demo out of production config.** Forbidden by the
   task (rule 2), and rightly so: it would hide the very behavior the integration test exists
   to watch.

The plateau **feasibility gate** the task specified for the "confirmed" path is **not
applicable** — the detector never fires on this job, so a gate on it would change nothing
here and would be a production behavior change justified by a hypothesis the evidence killed.
I did **not** implement it. (It remains a reasonable *latent* correctness property in its own
right — "converged" should imply "feasible" — but it belongs to its own task with its own
before/after evidence on a job where plateau actually fires, and it is unrelated to this red.)

**Recommended maintainer decision:** option 1 or 3. Option 1 restores the honest optimizer
achieved-fraction to the report while preserving 094's savings/mass consistency in a distinct
field — but it edits the report contract, which this task fenced off. If the intended meaning
of the cli_demo invariant is "the optimizer hit its volume target" (its pre-094 meaning),
option 3 (compare the continuous fraction, which passes at 0.6997/0.4997/0.2997) is the
minimal honest change. Either way, `expected_values.json` and `test_cli.cpp` should be
updated in the same change that resolves the basis, so the integration test and the reported
number can never silently disagree again.

---

## Honest correction for the record

The two prior handoffs that touched this were **right that the failure is pre-existing** (it
predates PR 123 — confirmed here on clean main and pinned to `bec806e` by code-bisect) and
**wrong to attribute it to lib3mf absence**: the 3 vf failures reproduce with lib3mf present
in CI and locally on the lib3mf-absent STL path alike, because the failing quantity is a
voxel-count ratio computed long before any mesh is written — export format is irrelevant.

This handoff's own framing also needs correcting for the next reader: **the MMA-plateau /
PR-119 hypothesis is likewise wrong.** It was a well-formed guess (086 did make plateau the
MMA terminator, and 119 did route the CLI through `configure_production_options`), but the
demo pins `max_iterations = 30`, the plateau needs its progress gate to open and ≥11 samples,
and it simply never fires; and 119's config deltas are inert on this job. Do not re-open the
plateau line of investigation for this red. The cause is the 094 reporting basis, full stop.

---

## Evidence index / how to reproduce

- Build (no lib3mf needed to see the 3 vf failures):
  `cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$(brew --prefix opencascade);$(brew --prefix eigen)"`
  then `cmake --build core/build --target test_cli topopt_cli -j8 && core/build/test_cli`.
- Failing checks: `FAIL (line 252): achieved volume fraction within 0.01 of its request` ×3.
- **CI is the arbiter of cli_demo** (per this incident): the pristine 3MF job runs there with
  lib3mf; locally the STL-patched copy runs and adds one extra check (84 vs 83), but the 3 vf
  failures are identical. Confirm any fix against CI, not only a local run.
- Trace to re-derive the numbers: re-add the two `TOPOPT_PLATEAU_TRACE`-gated `fprintf`s in
  the masked `simp_optimize` loop and after the `report_part_relative` overwrite in
  `minimize_plastic.cpp`; run `TOPOPT_PLATEAU_TRACE=1 core/build/test_cli`.
- Gates to keep green when the maintainer lands the real fix: `production_parity`,
  `clearance_parity`, `load_retention_connectivity`, `ladder_rung_count`,
  `savings_part_relative` (this last one pins 094's basis — coordinate the two), and Gate-V2
  (OC path, untouched by anything here).
