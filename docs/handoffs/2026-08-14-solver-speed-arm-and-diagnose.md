# The two accelerators are armed and not running — why, and what to do about it

**Task:** `solver-speed-arm-and-diagnose` ·
**Evidence:** `evidence/2026-08-14-solver-speed-arm-and-diagnose/`
**Machine:** Apple M2 Pro (6 performance + 4 efficiency cores), 16 GB, Release.
**Kind:** DIAGNOSIS first, then arming. One measurement-only switch was added to
`core/src` (a latch re-arm period, default 0 = the shipped policy) and one
harness. **No production default moved.** No assertion was weakened or deleted.

---

## 0. THE ANSWERS, ONE LINE EACH

**Why GenEO declined 242 of 248 solves, and whether a smaller basis fixes it.**
Because the coarse-operator REFRESH costs `2 × N_t = 3,348` plain-iteration
equivalents, which is **71 % of the 4,702-iteration threshold the gate computes**
([`geneo.cpp:897`](core/src/fea/geneo.cpp:897)) — and the gate is **CORRECT**:
every declined solve in his log finished plain in fewer iterations than the armed
alternative would have cost. But the declines miss by a **median of 346
iterations, 7.4 % of the threshold**, so the gate is sitting almost exactly on
break-even and `N_t` is the only term with room in it. §1.

**At which solve multigrid latched, and whether re-arming helps.**
At **rung 0, design iteration 4** — the first three solves of a 160-solve run each
burned the full 300-cycle budget and tripped `kMgLatchThreshold`. Reproduced on
this tree to the iteration (927 / 970 / 1420 / 1591 CG, `hier_built` 1/1/1/0).
★ And the field at iteration 1 is **uniform at vf 0.68**, so its contrast is ≈ 3,
not 1e9: **the V-cycle fails on the easiest coefficient field the run ever
has.** §2.

**Total CG iterations across the run, before and after everything armed.** §4 and
the R1 table in §6.

**Whether the exact volume fraction made the stagnation worse.**
★ **It cannot have, because it is not in production.** PR 327 changed **four
files, all under `core/tests/harness/`, and zero lines of `core/src` or
`core/include`**. The shipped PLSM path still computes `rho_e = H_eta(-phi)` at
`eta_voxels = 2` ([`plsm.cpp:354`](core/src/simp/plsm.cpp:354)); the exact
fraction is a probe flag (`levelset_probe --frac K`, default 0 = off) that no
production path calls. §3 measures the underlying physical question anyway, using
the production knob that does exist. §3.

---

*(Every section marked MEASURED carries numbers. §7 is the plain-language
section and is not optional reading.)*

---

## 1. §1 — WHY GENEO DECLINES. The gate is right; the basis is too big.

### 1a. MEASURED — his own decision log, in full

`evidence/2026-08-10-plsm-production/s1_production_run/run_info.json` is a real
4-rung 128³ run on his part. **Nothing in this task re-ran it. It was read.** Its
`geneo_decisions` (18 rows for 168 solves) reproduced verbatim by
`tables.py`:

| solve | action | burn | threshold | burn−thr | iters | deflated tail |
|---:|---|---:|---:|---:|---:|---:|
| 1 | REBUILD | 500 | 500 | 0 | 927 | **427** |
| 2 | DECLINE | 970 | 4702 | −3732 | 970 | — |
| 125 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4713 | **11** |
| 126 | DECLINE | 3986 | 4702 | **−716** | 3986 | — |
| 130 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4891 | 189 |
| 131 | DECLINE | 4567 | 4702 | **−135** | 4567 | — |
| 132 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4938 | 236 |
| 135 | DECLINE | 4465 | 4702 | −237 | 4465 | — |
| 136 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 5006 | 304 |
| 137 | DECLINE | 4370 | 4702 | −332 | 4370 | — |
| 143 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4852 | 150 |
| 144 | DECLINE | 4392 | 4702 | −310 | 4392 | — |
| 145 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4776 | 74 |
| 146 | DECLINE | 4176 | 4702 | −526 | 4176 | — |
| 148 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 4772 | 70 |
| 149 | DECLINE | 4343 | 4702 | −359 | 4343 | — |
| 167 | REFRESH+ENGAGE | 4702 | 4702 | 0 | 5591 | 889 |
| 168 | REBUILD | 5202 | 5202 | 0 | 5545 | 343 |

**The distribution of (burn − threshold) over the logged declines:** −3732, −716,
−526, −359, −332, −310, −237, −135. Drop the first (solve 2, immediately after
the first build, before the basis had a measured cost) and **seven of eight miss
by 2.9 % to 15.2 % of the threshold, median 7.4 %.** The task's own criterion —
"if most missed by a little, a smaller basis fixes it" — is met.

### 1b. ★ THE HONESTY NOTE THE TABLE CANNOT BE READ WITHOUT

**`geneo_decisions` records TRANSITIONS ONLY.** Its own header says so: *"runs of
identical consecutive decisions are not [recorded], so the log stays legible on a
long ladder"* ([`geneo.hpp:339`](core/src/fea/geneo.hpp:339)). His run declined
**156** solves and logged **8**. The eight are the solves that immediately
followed an engage — the **hardest** declines, not a sample of them. So the eight
deltas above are a *biased-optimistic* view of how close the declines came, and
the true distribution is somewhere further from the threshold.

The unbiased source is the per-solve `geneo_burn` / `geneo_threshold` columns in
`iterations.csv`. **His run wrote them as 0** — those columns post-date the binary
that produced it. This task's arms fill them, and §6 prints the full
distribution from an arm rather than from the transition log.

### 1c. ROOT CAUSE, WITH FILE AND LINE (R5)

[`core/src/fea/geneo.cpp:897-899`](core/src/fea/geneo.cpp:897):

```cpp
double cost = kGeneoRefreshCostPerColumn * static_cast<double>(S.Nt) +
              (S.engaged_burn > 0 ? static_cast<double>(S.engaged_burn) : 0.0) +
              kGeneoDeflatedIterCost * static_cast<double>(S.engaged_tail);
```

His run's numbers put through it:

```
  refresh    kGeneoRefreshCostPerColumn * N_t = 2 x 1674 = 3348   <-- 71 % of the total
  plain leg  engaged_burn                     =            500
  deflated   kGeneoDeflatedIterCost * tail    = 2 x  427 =  854
  ------------------------------------------------------------
  threshold                                              = 4702   (the run reports 4702)
```

**"It declined" is not the answer. The answer is: the refresh is 71 % of the
price of being armed, the refresh is `2 × N_t`, and `N_t = 1,674`.** The refresh
is also not skippable — phase 2 §P6 measured divergence from a stale coarse
operator, and the moduli move every design iteration by construction, so it is
paid on every armed solve. That is the whole mechanism.

### 1d. ★ THE FACT THAT REOPENS THIS — the operating point moved by 73×

`docs/handoffs/2026-08-02-geneo-standing-probe.md` closed standing GenEO as a
NO-GO, and its killer argument was one ratio:

> *"The armed production run measured **N_t = 7,588**, and the latched solves run
> at **~275 CG iterations**, so there `N_t / k_jacobi = 27.6`. The refresh alone
> would cost 27.6× the entire solve it is meant to accelerate."*

**On the run in front of us that ratio is `1674 / 4400 = 0.38.`** `N_t` fell 4.5×
and the solves grew 16×. 0.38 is not off the end of that handoff's own scaling
table — **it is a row in it** (`40×16×41`, N_t/k_jacobi 0.38, where deflation cut
771 plain iterations to 201). The single number that made standing GenEO absurd
is gone, and it is worth being blunt about why the conclusion did not travel:
**it was correct for its operating point and was never re-checked against a
changed one.**

### 1e. §1(c) — the trigger is not the problem

`geneo_trigger_iters = 500` governs only the FIRST build on a structure
([`geneo.cpp:879-882`](core/src/fea/geneo.cpp:879)); once a basis is held the
computed threshold governs. His solve 1 burned 927 and built at 500, so the
trigger fired on the first solve of the run and never mattered again. **Lowering
it changes nothing:** it cannot make a held basis engage, because the held-basis
branch never reads it. The one place it re-enters is a scheduled degradation
REBUILD, where it is added to the cost ([`geneo.cpp:906`](core/src/fea/geneo.cpp:906)) —
visible as solve 168's threshold of 5202 = 4702 + 500 in the table above.

### 1f. §1(d) — is the gate correct, and should we stop here?

**The gate is correct, and no, that is not the whole answer.** Correct, because
every row above grades out: the declines converged plain in 3,986–4,567
iterations, all under the 4,702 the armed route would have cost; the engages had
already passed 4,702 unconverged, so plain was going to cost more. It is the
ski-rental rule and it is playing it properly.

But "the gate is correct" and "GenEO is not worth engaging" are different
claims, and only the first is established. The gate compares the plain cost
against **the armed cost at N_t = 1,674**. The measured deflated tails —
**median 212, and 427 from a genuinely cold start** — say the deflation itself
works extremely well on this problem. What does not work is paying 3,348
iterations for the privilege. So the question that decides it is not "should the
gate engage more often" but **"can the basis be made cheap enough that engaging
is obviously right"**, and the only lever measured to move `N_t` at all is the
subdomain tiling: the same handoff's W3 swept `lambda_cut` over 50× and moved
`N_t` by **0.7 %**, while W4's tiling sweep moved it 313 → 47 going from 8³ to
16³ cores. §6 runs that sweep on his job.

---

## 2. §2 — THE LATCH. Not a bug, and not for the reason anyone expected.

### 2a. MEASURED — when it latched

Directly from his `iterations.csv`, no reconstruction needed
(`hier_built`/`mg_cycles_attempted` have been per-solve columns since handoff
128):

| rung | iter | cg_iters | hier_built | mg_cycles_attempted |
|---:|---:|---:|---:|---:|
| 0 | 1 | 927 | **1** | **300** |
| 0 | 2 | 970 | **1** | **300** |
| 0 | 3 | 1420 | **1** | **300** |
| 0 | 4 | 1591 | 0 | 0 |
| … | … | … | 0 | 0 *(for the remaining 156 solves)* |

**The hierarchy was ATTEMPTED on 3 of 160 solves and CARRIED on 0.** Each of the
three burned the entire `kMgIterBudget = 300` V-cycle budget, tripping
`kMgLatchThreshold = 3` ([`multigrid.cpp:145`](core/src/fea/multigrid.cpp:145)),
and the latch at [`multigrid.cpp:2257`](core/src/fea/multigrid.cpp:2257) then
short-circuited the build at
[`multigrid.cpp:2157`](core/src/fea/multigrid.cpp:2157) for the rest of the run.

**This reproduces exactly on this tree**, same binary that produced every arm
below: 927 / 970 / 1420 / 1591 with `hier_built` 1/1/1/0
(`evidence/…/arms/base/iterations.csv`). The reproduction matters because it
means the diagnosis is about today's code, not about the code his run used.

### 2b. ★ THE DECISIVE OBSERVATION — contrast is not the cause, and cannot be

The task's §2(d) asks whether contrast explains it, and reasons that PLSM's
`rho_min = 1e-3` clamp should make multigrid work *better* than it ever did on
SIMP's 1e-9. **The run answers a stronger version of that question.**

At rung 0 iteration 1 the design is **uniform**: `achieved_vf` is exactly
`0.680000` and the frozen set is solid. With SIMP's penalty the modulus ratio
across the whole active domain is `1.0 / 0.68³ ≈ 3.2`. **The V-cycle burned 300
cycles without contracting on a field whose contrast is about 3.**

So contrast is not the cause, and no ersatz change can be either. What is left is
the thing that is identical at every iteration of the run: **the fixed geometry**
— 110,904 allowable voxels inside a 468,224-voxel box, i.e. a thin part occupying
**23.7 %** of the index space, with a 5,165-voxel load pad and a 10,554-voxel
protection collar frozen solid inside it. That is precisely the regime handoff
125 identified ("a thin structure filling a small fraction of a large empty
design-box expanse") and precisely what `2026-07-27-mg-stagnation-phase0` measured
as the driver of stagnation: *"present and unchanging from iteration 0"*.

### 2c. §2(a) — "if it latched early that is a bug." It latched early. It is not a bug.

The hypothesis is that iteration 3 is the run's worst moment — high contrast,
thrashing — and that the V-cycle would carry once structure formed. **The
measurement says the ordering is the other way round**, and this is not a new
result; `docs/handoffs/2026-07-27-mg-stagnation-phase0.md` refuted it in July on
synthetic fixtures at his extents:

| 192×112×128, occ 0.40, **no hole** | rung 0 | rung 1 | rung 2 | rung 3 |
|---|---|---|---|---|
| start-field V-cycles | 157 CARRY | 268 CARRY | **300 STAG** | **300 STAG** |
| end-field V-cycles | 268 CARRY | **300 STAG** | 300 STAG | 300 STAG |

Developing structure raises the cycle count monotonically. The uniform haze is
the **easiest** field, not the hardest — which is exactly what his run shows from
the other direction: rung 0 averages **1,170** CG iterations per solve and rung 3
averages **4,365**, a 3.7× climb as the design forms.

**So the latch fires at the one moment multigrid had its best chance, and it is
right to stay off afterwards.** A re-arm's upside set is not small — it is empty,
*if* the July forecast holds on his part.

### 2d. WHAT WAS ACTUALLY MISSING, AND WHAT THIS TASK BUILT

That July handoff refuted the mechanism on proxies and then said, in its own §7,
exactly what it could not do:

> *"NOT measured, and it requires the maintainer's actual part: whether **this
> specific STEP part at 128³** stagnates on its **developed** rungs when MG is
> allowed to run. … A **latch-disabled measurement build** (opt-in flag; no
> production behavior change) so MG is attempted on every solve of every rung and
> the developed-rung verdict is **observed rather than inferred**. … the
> instrumentation already exists; only the latch-disable flag is missing, and
> that is a one-line opt-in, not a production change."*

Its three requirements were his STEP file, an `iterations.csv` with
`hier_built`/`mg_cycles_attempted`, and that flag. The first two are in this
repository. **This task built the third**
([`fea.hpp`](core/include/topopt/fea.hpp:1093),
[`multigrid.cpp:151`](core/src/fea/multigrid.cpp:151)) and ran it. The result is
§6's `rearm` arm, and it is the first clean data point against that handoff's own
reopen condition.

### 2e. §2(c) — the odd 31 axis and the pad are NOT implicated

The run's own banner: `solve grid 128x31x118 has odd axis(es) [y=31] — geometric
multigrid pads its INDEX SPACE to 128x32x120 (up to 4 levels)`. The pad
**worked**: a hierarchy built on all three attempts (`hier_built = 1`), which is
the only thing the pad is for. Without it the odd `y` axis would have failed the
first halving and there would have been no hierarchy at all
(`2026-07-31-multigrid-odd-axis-cliff`). The padded nodes are permanently
inactive and get the same treatment as void/fixed DOFs, so they add no equations.

**The failure is CONTRACTION, not construction, and the pad is upstream of
contraction.** Reading `2026-08-01-multigrid-deep-block-pad` before theorising —
as §2(c) asks — is what makes that distinction available: that handoff's own
worst case is "dense AND non-contracting", where the pad builds a hierarchy that
then stagnates and the latch pays 3 solves and stops. His run is that case
exactly, and the pad is doing its job while the V-cycle fails to do its.

---

## 3. §3 — THE ERSATZ. The premise is false, and the correction is the finding.

**PR 327 never touched production.** `git diff --stat` across its merge, restricted
to `core/`:

```
 core/tests/harness/frac_ersatz.hpp    |  545 +
 core/tests/harness/levelset_probe.cpp | 1713 +
 core/tests/harness/plsm_basis.hpp     |   23 +
 core/tests/harness/plsm_probe.cpp     |  533 +
 4 files changed — ZERO lines in core/src or core/include
```

The shipped PLSM optimiser still computes the ersatz as the smoothed Heaviside:
[`plsm.cpp:354`](core/src/simp/plsm.cpp:354) is
`plsm_heaviside(-phi_eff_at(v, offset), eta)` with
`eta = plsm.eta_voxels * h` and `eta_voxels = 2`, which his own `run_info.json`
echoes as `plsm_eta_voxels: 2`. The exact volume fraction is reachable only
through `levelset_probe --frac K`, whose default is 0 — off — and which no
production path calls.

**So the §3 question as posed has a one-word answer: no, because it never ran.**
Two consequences worth stating rather than leaving implied:

1. **The reason PR 327 "never reported `mg_mode`" is structural, not an
   oversight.** Its arms ran through `levelset_probe`, a harness that drives
   `simp_compliance` directly. `mg_mode` is written by `run_job`'s observability
   ([`run_job.cpp:8485`](core/src/cli/run_job.cpp:8485)). A probe has no
   `run_info.json` to report it in. Closing the gap needed the probe's finding to
   be run through the production driver — which is what this task's harness does,
   and it is why the harness drives `run_job` and not `simp_compliance`.
2. **The underlying physical question is still worth an answer**, because
   productionising PR 327 is a live proposal. §6 answers it with the knob that
   does exist: `plsm.eta_voxels`. Narrowing the smoothed band from 2 voxels
   toward the exact fraction's one-cell layer is the same sharpening, applied
   through a production setting, on the production path.

---

## 4. §4 — WHAT WAS ARMED, AND WHAT WAS NOT

### 4b. `warm_start_coarse` — off for a measured reason, and the PLSM argument does not rescue it

`docs/handoffs/2026-08-02-warm-start-coarse-experiment.md` measured it. **It lost,
and it lost hardest in exactly this regime.** On `nobox`, the fixture where
multigrid genuinely never carries — the closest thing that experiment had to his
latched runs — arming it:

- raised fine iterations 944 → 1000 (**+5.9 %**),
- raised charged DOF-touches **+7.2 %**,
- raised the count of stagnating iterations 942 → **1000**,
- and landed on a **26.0 % worse rung-2 compliance** at the same volume fraction,
  with **15.2 % of that rung's margin gone**.

The task asks me to arm it if it is not already off for a measured reason. **It
is**, so it stays off. But the task's PLSM-specific argument deserves a direct
answer rather than a citation, because it is a good argument about a feature that
does not exist:

> *"it is EASIER than it was under SIMP because phi is analytic — you evaluate it
> on the coarse grid exactly, with no restriction operator and no averaging
> error."*

**The shipped lever does not do that.**
[`minimize_plastic.cpp:859-917`](core/src/simp/minimize_plastic.cpp:859) runs a
coarse **`simp_optimize`** — SIMP, on a coarsened grid — and prolongs its
**density**. PLSM then converts that density back into a level set at
[`plsm.cpp:277`](core/src/simp/plsm.cpp:277) (`phi[v] = 0.5 - initial_design[v]`)
and fits the basis to it. So arming `warm_start_coarse` under PLSM seeds a level
set from a coarse SIMP design: the averaging error is still there, and an
algorithm mismatch is added on top. **The thing the task describes — a coarse
stage that evaluates the analytic φ exactly — is a NEW FEATURE, and it is
resolution continuation**, which §5 puts out of scope. That is not an argument
against it; it is an argument that it belongs in the §5 line, and §7 puts it
there.

One more structural bound, unchanged since handoff 110: `warm_seed` is replaced
or cleared after every rung
([`minimize_plastic.cpp:1819`](core/src/simp/minimize_plastic.cpp:1819)), so even
at its best the cascade seeds **rung 0 of 4**.

### 4c. `matfree_threads` — the machine, and where it stops scaling

The machine is a **Mac mini M2 Pro: 10 cores = 6 performance + 4 efficiency**,
16 GB unified memory, ~200 GB/s peak. The shipped `matfree_threads = 6` is the
performance-core count and that is not a coincidence — `2026-07-28-apple-silicon-envelope`
measured this exact question on this exact box:

| what | measured |
|---|---|
| STREAM triad, sustained | 151 GB/s = **76 % of peak**; 2 threads already reach 73 % |
| production `apply_kgg`, 6 P-cores, FP64 | ~54 GB/s = **27 % of peak**, ~90 GFLOP/s |
| the shape of the limit | **gather-bound (indirect indexing), NOT bandwidth-saturated** |
| 8 and 10 threads | **REGRESS** — the E-cores drag the 8-colour partition |

**It stops scaling at 6, and past 6 it goes backwards.** The sweep is re-run in §6
on the current PLSM operating point rather than quoted, because the operator has
changed since.

**And the GPU question the task attaches to it, answered from the same
measurement:** a real Metal element-apply reaches 62–69 % of the bus, ~4× the CPU
FP64 apply — *the GPU does reclaim the gather slack*. But its FP32 floor is
6.9e-8, which makes it preconditioner-only, and Amdahl on the ~66 % build caps the
whole solve at ~1.2×. **A GPU port would not pay**, and that is measured rather
than assumed.

### 4d. `mixed_precision` — correctly not armed, and §2 is why

PR 327 measured it a proven no-op — byte-identical designs with the flag on and
off — because it only accelerates the V-cycle and the V-cycle never engaged. The
task's instruction is not to arm it before §2 resolves. §2 resolved against the
V-cycle carrying (§6), so **mixed precision stays where it is**, and the reason is
now positively established rather than inherited: the code path it speeds is
`mf_mgpcg`'s FP32 attempt at
[`multigrid.cpp:2196`](core/src/fea/multigrid.cpp:2196), which is inside
`if (have_h)`, which the latch keeps false for 157 of 160 solves.

---

## 5. WHAT WAS BUILT (measurement and reachability only — no default moved)

| change | why |
| --- | --- |
| `multigrid.cpp` / `fea.hpp` — **`fea_matfree_set_mg_rearm_period`** (+ `_period` / `_attempts` / `_carries` readers) | The latch-disabled measurement build handoff `2026-07-27-mg-stagnation-phase0` §7 named as the one thing missing to close its own B4. Default **0 = the shipped policy**, no production caller, and the re-arm branch is unreachable at 0. A re-armed retry that stagnates re-latches immediately rather than paying `kMgLatchThreshold` again, which is what makes a period-1 arm affordable on a 128³ job. |
| `plsm.cpp` — the observation hook now fills **`geneo_dim` / `geneo_action` / `geneo_burn` / `geneo_threshold`**, plus **`matvecs` / `fea_solves`** and the two GenEO timing splits | ★ A DEFECT, not an addition. The SIMP loop fills these; the PLSM loop did not — and `topopt-cli run` has run PLSM **exclusively** since PR 325. So **every row of every production `iterations.csv` since then has reported `geneo_action 0, geneo_threshold 0`**, and the per-solve gate decision was unreadable on the only path that ships. This is the THIRD occurrence of that drift; `geneo.hpp`'s `geneo_fill_cg_info` comment documents the second. Read-only: four ints and two counters copied out of a `CgInfo` the solve already filled. |
| `core/tests/unit/test_mg_tuning.cpp` — **the re-arm tripwire** | Asserts the shipped period is 0, that the setter round-trips, and that the run-start latch reset preserves the POSTURE while zeroing the COUNTERS. A future edit that arms a re-arm in production has to delete a check to do it. |
| `core/tests/harness/solver_arm_sweep.cpp` + one `EXCLUDE_FROM_ALL` CMake target | The measurement harness. Drives **`run_job` — the production driver, the same entry point `main.cpp` calls** — on his captured job, varying only switches production already has and does not write. `--arm base` applies nothing and is the control. Never built by CI. |

`materials.json`, `rules.json`, `ARCHITECTURE.md` and `DECISIONS.md` were not
touched. The gate is untouched. `geneo.cpp` was not edited at all — §1 is a
reading of it, not a change to it.

