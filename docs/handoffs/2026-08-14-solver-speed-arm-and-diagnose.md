# The two accelerators are armed and not running — why, and why the third one does not save it either

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
Re-arming is tested on his part rather than inferred, which is what §7 of
`2026-07-27-mg-stagnation-phase0` asked for and could not do. ★ And §2(d)'s
premise is corrected: PLSM's `rho_min = 1e-3` does **not** put the contrast at
1e3 — through `E = rho³E₀` it is **1e9**, the same as SIMP's. The cause is the
GEOMETRY, and PR 283 already measured it: the geometric coarse space captures
**1.6 %** of the exact solution's energy on this field. §2.

**Total CG iterations across the run, before and after everything armed.**
★ **The most promising candidate was a THIRD accelerator the brief does not name
— and it was measured here, on his job, and it does not work.** The algebraic
level-1 coarse space is built and DISARMED rather than idle, and it had been
measured on this class of field at **ladder CG 85,536 → 15,595 (5.5×)** with
GenEO's decline problem *dissolving* (1 build / 1 armed / 167 declines → 0/0/0).
Its stated blocking reason is a memory projection binding above ~5.5M DOF, and
his grid is 1.47M — so it **builds** here (5,199 aggregates, 112.4 MB, not
refused). **And the V-cycle still burns all 300 cycles**, latches at the same
place, and every CG count down all four rungs is identical to the control.
Geometric and algebraic coarse spaces have now both been observed to fail on his
part. §4(a) for the case, **§6c for the measurement**.

**Whether the exact volume fraction made the stagnation worse.**
★ **It cannot have, because it is not in production.** PR 327 changed **four
files, all under `core/tests/harness/`, and zero lines of `core/src` or
`core/include`**. The shipped PLSM path still computes `rho_e = H_eta(-phi)` at
`eta_voxels = 2` ([`plsm.cpp:354`](core/src/simp/plsm.cpp:354)); the exact
fraction is a probe flag (`levelset_probe --frac K`, default 0 = off) that no
production path calls. §3 measures the underlying physical question anyway, using
the production knob that does exist. §3.

---

*(Every section marked MEASURED carries numbers. §8 is the plain-language
section and is not optional reading.)*

---

## 1. §1 — WHY GENEO DECLINES. The gate is right; the basis is too big.

### 1a. MEASURED — his own decision log, in full

`evidence/2026-08-10-plsm-production/s1_production_run/run_info.json` is a real
4-rung 128³ run on his part. **Nothing in this task re-ran it. It was read.**

★ **It is not the same run §0 of the task quotes, and the difference is worth
stating before the table rather than after it.** The task's run reports
`geneo_armed_solves 6 / declined 242`; this one reports `12 / 156`. They are the
same job, the same part, the same production path (its own `run.log` writes to a
`plsm_prod/` directory, and this tree reproduces its first two solves to twelve
significant figures — compliance `0.005266659662` then `0.002829441384`, CG 927
then 970), the same shipped posture, and — the load-bearing part — **the same
`geneo_basis_dim = 1674` and the same computed threshold of 4,702.** They differ
in length. So every mechanism below is his, and the specific counts 6/242 are
his longer run's version of the same 12/156 arithmetic.

Its `geneo_decisions` (18 rows for 168 solves) reproduced verbatim by
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

### 2b. ★ §2(d) — THE CONTRAST PREMISE IS OFF BY SIX ORDERS OF MAGNITUDE

The task reasons that PLSM's `rho_min = 1e-3` clamp puts the contrast at ~1e3,
"far below the 1e9 that SIMP at penalty 3 produced", and concludes that multigrid
**should** work better on a PLSM field than it ever did on SIMP's. **That
arithmetic does not survive contact with the code, and the correction matters
because it removes a reason to expect a rescue that was never coming.**

The ersatz is a DENSITY. The operator sees a MODULUS, and the SIMP power law sits
between them:

```
  plsm.cpp:356    rho[v] = rho_min + (1 - rho_min) * H_eta(-phi)      rho in [1e-3, 1]
  simp.cpp:284    E      = pow(rho, params.penalty) * youngs_modulus  penalty = 3
  ------------------------------------------------------------------------------
  modulus range   [1e-9, 1] x E0        ->  contrast 1e9
```

`density_min = 1e-3` ([`simp.hpp:40`](core/include/topopt/simp.hpp:40)) and
`penalty = 3.0` ([`production.cpp:39`](core/src/simp/production.cpp:39)) are the
production values on **both** paths. So the level set did not lower the contrast
the V-cycle has to cope with **at all** — it is the same 1e9 it always was, and
comparing a density ratio on one side against a modulus ratio on the other is
what makes it look otherwise. **§2(d)'s "multigrid should work better on a PLSM
field" is not supported.**

### 2c. …and contrast is still not the cause. The evidence is measured, not inferred.

Two prior measurements settle it without needing the arithmetic above to come out
any particular way:

- **Contrast alone is nearly free.** Handoff 125 reproduced a 1e-9-contrast field
  in a clean box and multigrid converged in **13 cycles**. A clearance hole in a
  cubic box did not stagnate it either (≤ 45 cycles at 128³).
- **Stagnation reproduces on the UNIFORM field.** `2026-07-27-mg-stagnation-phase0`
  ran his extents (`192×112×128`, occ 0.40) on the *iteration-0 uniform* field and
  got **300 cycles then 3,602 Jacobi iterations** — stagnation before any design
  exists to have contrast.

What both point at is the one thing identical at every iteration of his run: **the
fixed geometry.** 110,904 allowable voxels inside a 468,224-voxel box — a thin
stand occupying **23.7 %** of the index space — with a 5,165-voxel load pad and a
10,554-voxel protection collar frozen solid inside it. Handoff 125 named that
interaction precisely ("a thin structure filling a small fraction of a large empty
design-box expanse"), and phase 0 named its timing: *"present and unchanging from
iteration 0"*.

### 2d. ★ AND THE MECHANISM IS ALREADY MEASURED — the coarse space sees 1.6 % of the answer

The sharpest number in this whole diagnosis is not new; it is sitting in
production.cpp's own tripwire, from PR 283:

> *"On the maintainer's dilute field the GEOMETRIC level-1 space captures
> **1.5954 %** of the exact solution's energy (**99.2959 %** on a healthy
> control), and every space below level 1 is a subspace of it — so PR 280's 25
> failed configurations were all working inside a space that sees 1.6 % of the
> answer. **The algebraic level 1 captures 56.3293 %** at a SMALLER coarse
> dimension."*
> — [`production.cpp:300-306`](core/src/simp/production.cpp:300)

That is the V-cycle's failure stated as a quantity: halving the grid on this
geometry throws away 98.4 % of the energy, so the correction it computes is
almost orthogonal to the error it is meant to remove, and no amount of smoothing,
depth or cycle shape recovers it (`2026-08-02-multigrid-component-sweep`: **25
configurations, 0 convergences**). **It also names the remedy**, which is exactly
what §4(a) asks to arm.

### 2e. §2(a) — "if it latched early that is a bug." It latched early. It is not a bug.

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

*(One precision, because §2b turns on it: those phase-0 fixtures are SIMP OC
fields, and his rung-0 field is not a grey haze at all — the level set seeds from
a holes pattern and the ersatz is a smoothed Heaviside, so iteration 1 is already
near-binary. The direction of the evidence is unaffected — early is still easier
than late, by his own 3.7× — but "haze" should not be read as "low contrast" on
the PLSM path. There is no low-contrast moment in a PLSM run.)*

**So the latch fires at the one moment multigrid had its best chance, and it is
right to stay off afterwards.** A re-arm's upside set is not small — it is empty,
*if* the July forecast holds on his part.

### 2f. WHAT WAS ACTUALLY MISSING, AND WHAT THIS TASK BUILT

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

### 2g. §2(c) — the odd 31 axis and the pad are NOT implicated

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
   productionising PR 327 is a live proposal. The knob that exists is
   `plsm.eta_voxels`: narrowing the smoothed band from 2 voxels toward the exact
   fraction's one-cell layer is the same sharpening, applied through a production
   setting, on the production path, with `eta_voxels = 4` as the positive control
   that keeps the comparison from passing vacuously.

   ★ **Both were started and both were stopped, and §3's answer does not depend
   on them.** They were given up so the machine could finish the `rearm` arm,
   which answers a question with no other route. `evidence/…/probes/NOTE_eta.md`
   carries the two commands and how to read them. What is worth saying is that
   §6c makes them *more* interesting rather than moot: the V-cycle now fails on
   this geometry with a geometric coarse space **and** with an algebraic one, so
   if it is also insensitive to an 8× sweep of the ersatz band, then the ersatz
   is conclusively not a variable in the stagnation and productionising PR 327
   carries no solver risk at all.

---

## 4. §4 — WHAT WAS ARMED, AND WHAT WAS NOT

### 4a. `mg_algebraic_level1` — the remedy §2 points at, and why it is genuinely live here

★ **This is the finding the task's framing does not have a slot for, so state it
first: there is a THIRD accelerator, it is built, it is DISARMED rather than
idle, and it has already been measured at 5.5× on exactly R1's figure of merit in
exactly this regime.** From `docs/handoffs/2026-08-03-algebraic-level1-coarsening.md`:

| | disarmed | armed |
| --- | ---: | ---: |
| dilute stagnating field, one solve | 300 cycles → give up → **3,636 Jacobi iterations** | **CARRIES in 96 PCG iterations** (39× less DOF-weighted work) |
| a full 4-rung ladder, TOTAL CG | **85,536** | **15,595** — *5.5×* |
| stagnating solves on that ladder | 3, then `kMgLatchThreshold` fires | **0, latch quiet** |
| GenEO builds / armed / declines | 1 / 1 / 167 | **0 / 0 / 0** |
| verdict flips | — | **zero, all four rungs** |

The last two rows are the ones to read twice. **GenEO's decline problem does not
get solved there — it gets dissolved**, because the solves stop being hard enough
to need rescuing. And §2d's energy number is why: the geometric level-1 space
captures **1.5954 %** of the exact solution's energy on this class of field, the
algebraic one **56.3293 %** at a *smaller* coarse dimension.

★ **The scale gap, named before anyone quotes those numbers at his job.** The
39× was measured on a **150,075-DOF** dilute field and the 5.5× on a ladder whose
whole wall was **77.4 s**. His grid is **1,473,696 DOF** and his ladder is 90
minutes. Neither figure transfers for free, and closing that gap is precisely
what this task's `alg1` probe is for.

It is armed by a public `fea.hpp` setter — `fea_set_mg_algebraic_level1` — with
**no production writer at all**, the same shape `warm_start_coarse` was in before
it was measured.

It ships disarmed for three measured reasons
([`production.cpp:317-335`](core/src/simp/production.cpp:317)), and **one of them
is the reason to expect it to matter here rather than not**:

> *"THE MEMORY PROJECTION EXCEEDS THE CAP AT THE MAINTAINER'S SCALE … ~355
> bytes/DOF, projecting to ~3.3 GB at 8.44M DOF — above `kAlgMaxCoarseBytes`
> (2048 MB), which the path enforces by DECLINING … **So on the real job an armed
> default would silently be the geometric path anyway, above roughly 5.5M DOF.**"*

**His job is not above 5.5M DOF. It is at 1,473,696** (`solved_grid_dofs`, his own
`run_info.json`) — the 128³ *resolution* names a 468,224-voxel box of which only
110,904 voxels may hold material. At 355 bytes/DOF that projects to **~520 MB**,
a quarter of the cap.

★ **THE VERDICT IS IN §6c AND IT IS A NO-GO — read this section as the case for
running the experiment, not as its result.** The algebraic level does build here,
and it does not help. Everything below is what was believed before the run.

**So the prediction, stated before the measurement:** the algebraic level should
be BUILT and not refused on this job, `mg_algebraic_level1_refused` should read
false, and `mg_algebraic_added_mb` should land in the low hundreds. §6 reports
what actually happened, including if it refused.

The other two disarming reasons are untouched by this and stay true: it is a
**loss on healthy fields** (18 V-cycles → 39 on a well-connected block), so
anything armed must be a SWITCH and not a replacement; and the switching rule was
never established. **Nothing here proposes arming it by default.** The question is
narrower and answerable: on the one geometry where the geometric space sees 1.6 %
of the answer, does the algebraic space make the V-cycle contract at all?

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
resolution continuation**, which the brief puts out of scope. That is not an argument
against it; it is an argument that it belongs on the brief's own
"not in this task" list, and §7 puts it there.

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

**It stops scaling at 6, and past 6 it goes backwards.** The shipped
`matfree_threads = 6` is that measurement, and his run reports exactly it.

★ **This task did NOT re-sweep it, and the reason is a property of the
measurement, not of the time available.** Thread count changes **only wall** —
`fea.hpp` guarantees the apply is bit-identical at any count, because it colours
the grid deterministically, so there is no deterministic quantity a thread sweep
can move. A wall sweep on a host at load 108–122 (§6a) measures which of five
other jobs happened to be running, not which thread count is best. Re-running it
needs a quiet machine and nothing else:

```bash
for T in 1 2 4 6 8 10; do
  ./build/solver_arm_sweep <job> <out>_$T --arm base --threads $T --iters 1
done   # compare wall_s only; total_cg is identical by construction
```

That `total_cg` must come out **identical across all six** is itself the check
that the sweep is measuring what it thinks it is.

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
| `job.hpp` / `run_job.cpp` — `RunObservability` gains **`mg_algebraic_level1`, `matfree_mixed_precision`, `mg_rearm_period`**, all defaulting to "leave the production rule alone" | ★ Also a trap, and it caught this task out first. `configure_production_options` **re-asserts** those globals at run start ([`production.cpp:714`](core/src/simp/production.cpp:714)) — deliberately, so a thread that ran a harness earlier cannot leak an armed solver into a production run. A harness that set them before `run_job` is therefore *silently overwritten* and measures the shipped posture while reporting an armed one. The first `alg1` arm of this task did exactly that; what caught it was `mg_algebraic_level1: false` sitting in the armed arm's own `run_info.json`. This is the same channel and the same reason `matfree_threads` already lives here. |
| `core/tests/unit/test_mg_tuning.cpp` — **the re-arm tripwire** | Asserts the shipped period is 0, that the setter round-trips, and that the run-start latch reset preserves the POSTURE while zeroing the COUNTERS. A future edit that arms a re-arm in production has to delete a check to do it. |
| `core/tests/harness/solver_arm_sweep.cpp` + one `EXCLUDE_FROM_ALL` CMake target | The measurement harness. Drives **`run_job` — the production driver, the same entry point `main.cpp` calls** — on his captured job, varying only switches production already has and does not write. `--arm base` applies nothing and is the control. Never built by CI. |

`materials.json`, `rules.json`, `ARCHITECTURE.md` and `DECISIONS.md` were not
touched. The gate is untouched. `geneo.cpp` was not edited at all — §1 is a
reading of it, not a change to it.

---

## 6. MEASURED — the arms, and the one that is BLOCKED

### 6a. ★ THE MACHINE. Read this before any number below.

The host was shared for the entire measurement window with **four other agents'
TopOpt jobs** out of other worktrees — a `levelset_probe` and three
`topopt-cli run` processes — at **load averages of 108–122 on a 10-core box**
(`evidence/…/host_load.txt`, sampled and appended throughout). A run asking for 6
threads held roughly one core.

Two consequences, applied rather than merely noted:

1. **No wall figure in this handoff is cited as evidence.** CG iteration counts,
   matvec counts and `N_t` are deterministic and contention-immune; wall is
   printed beside them and is indicative only. That is the discipline
   `2026-08-02-warm-start-coarse-experiment` §3 and `2026-07-29-geneo-arming`
   §Machine applied to the same condition, and §3 of the former demonstrated it
   directly: two runs of the identical posture, identical 394 iterations, **17.6 %
   apart in wall.**
2. **The arms are shorter than planned, identically across arms.** Every arm caps
   PLSM at the same small number of design iterations per rung instead of the
   shipped 60. That is a reduction in COVERAGE, not in the comparison. It also
   biases the table **against** GenEO: the solves are ~1,400 CG where his are
   ~4,400, so the threshold the gate must clear is unchanged while the plain
   solve it races got shorter. A GenEO win measured here would be conservative.

### 6b. ★ §1(b) — THE BASIS SWEEP DID NOT COMPLETE. BLOCKED, and reported as blocked.

The one measurement that decides whether the 21.7× is reachable is: **what is
`N_t` at a coarser subdomain tiling?** It costs one solve per point, because the
basis is built once and `N_t` is a property of that build.

| tiling | `N_t` | outcome |
| --- | ---: | --- |
| `core = 8` (SHIPPED) | **1674** | measured — his run, and reproduced by every arm here |
| `core = 4` | — | ABANDONED after 25 min; also the wrong direction (more subdomains ⇒ larger `N_t`) |
| `core = 16` | — | **ABANDONED after 35 min without finishing solve 1** |
| `core = 32` | — | not attempted |

**This is not a measurement of what a 16³ tiling costs.** It is that cost
convolved with a ~10× starvation factor, and the two cannot be separated after
the fact. What it does establish, and what the next attempt needs to know, is a
real hazard: **a coarser tiling makes the one-off LOBPCG build MORE expensive
even as it makes the per-solve refresh cheaper**, because the local eigenproblems
grow with the cube of the core size (8³ ≈ 1.7k local DOFs, 16³ ≈ 14k). The prior
sweep that found 8³ → 16³ took `N_t` 313 → 47 ran at `40×16×41`, where the whole
build was 12.4 s. It does not transfer to 128³ for free.

**The exact experiment, on a quiet machine, is one command:**

```bash
CORES="8 16 32" sh evidence/2026-08-14-solver-speed-arm-and-diagnose/run_nt_triage.sh
```

If `2·N_t + 500 + 2·tail` at 16³ or 32³ drops under the ~4,400 plain iterations
his solves cost, the gate starts engaging and §1's 21.7× is reachable. If it does
not, GenEO is finished as a rescue on this problem and §4(a)'s algebraic coarse
space is the answer instead. **Neither branch is established here, and this
handoff does not pretend otherwise.**

### 6c. ★ §4(a) MEASURED — the algebraic coarse space BUILDS at his scale, and the V-cycle still does not contract

This is the cleanest result in the task and it is a **NO-GO**.

| | control (`base`) | `alg1` |
| --- | --- | --- |
| `mg_algebraic_level1` | false | **true** — armed, and the artifact says so |
| `mg_algebraic_level1_refused` | — | **false** — NOT declined by the memory cap |
| aggregates / coarse dim / levels | — | **5,199 / 31,186 / 3** |
| `mg_algebraic_added_mb` | 0 | **112.38** — against a 2,048 MB cap |
| rung 0 iter 1: `cg_iters` | 927 | **927** |
| rung 0 iter 1: `hier_built` / `mg_cycles_attempted` | 1 / **300** | 1 / **300** |
| `cg_multigrid` (did the V-cycle ever carry?) | 0 | **0** |
| `mg_mode` | `stagnated-latched` | **`stagnated-latched`** |
| rungs 1-3 `cg_iters` | 1223 / 1343 / 1763 | **1223 / 1343 / 1763** |

**Read the first four rows and the last five together.** The half of §4(a)'s
prediction about *reachability* is confirmed and then some: the algebraic path is
armed, it builds a real three-level hierarchy with 5,199 aggregates, and it is
**not refused** — the memory objection that withholds it in production genuinely
does not bind at his scale, by a factor of eighteen rather than the four I
predicted. **The half about *acceleration* is refuted.** The V-cycle burns the
identical 300-cycle budget on the identical solve, the latch closes at the
identical place, and every CG count down all four rungs is identical to the
control.

**A correction to my own prediction, because the arithmetic was wrong even though
the conclusion was right.** §4(a) predicted "~520 MB" from 355 bytes/DOF x
1,473,696 DOF. The measurement is 112.38 MB. The error is the denominator:
`solved_grid_dofs` counts the **full padded nodal space**, while the algebraic
path — and the bytes/DOF table it was fitted on — count **KEPT** DOFs, and his
thin part keeps only about a quarter of them. Back the kept count out of the
measurement and it lands at ~346k DOF and **~67 fine DOFs per aggregate, inside
the 65-78 band** that fit held across a 108x DOF range. So the aggregation is
behaving *normally* here. It is not over-coarsening, it is not collapsing, and
there is no tuning story hiding in it. **It simply does not help on this
geometry.**

**What that closes.** Combined with §2, geometric and algebraic coarse spaces have
now both been observed to fail on his part, on his grid, through the production
driver. `2026-08-02-multigrid-component-sweep` had already closed the smoother,
the depth, the cycle shape and omega (25 configurations, 0 convergences). **There
is no remaining multigrid lever for this job that anyone has proposed and not
tested**, and mixed precision (§4d) stays a no-op because the V-cycle it
accelerates still never carries.

★ **And it moves the count that `2026-07-27-mg-stagnation-phase0` §6 asked for.**
That handoff's AMG reopen condition is "n >= 3 distinct real parts where geometric
MG is observed to attempt and stagnate with the latch disabled or re-armed". This
task contributes the first clean point for the maintainer's part — and it also
supplies something that handoff did not ask for and would have wanted: on that
same part, **the algebraic replacement it was holding AMG in reserve for was
tried, and it did not carry either.**

---

### 6d. R1 — the arms table, with the honest work unit beside the iteration count

Every arm is his job through `run_job`, capped at **2 PLSM design iterations per
rung** (4 rungs, 8 design solves) — identically, `base` included.

| arm | TOTAL CG | vs base | matvecs | vs base | wall s *(indicative)* | `mg_mode` | MG carried | GenEO armed / declined | `N_t` |
|---|---:|---:|---:|---:|---:|---|---:|---:|---:|
| `base` | **14,465** | 1.000x | **18,674** | 1.000x | 683.0 | `stagnated-latched` | 0 | 1 / 15 | 1674 |

★ **`matvecs` sits beside `total_cg` and is not decoration.** 18,674 against
14,465 is a **4,209-apply gap the CG counter cannot see**, and almost all of it is
GenEO's one basis build. An arm that engaged GenEO would report FEWER CG
iterations while doing MORE work; reporting the iteration count alone would let
that read as a win. This is the column `plsm.cpp` was not filling (§5), which is
why no previous production run has it.

★ **And `rearm_attempts = 0 / rearm_carries = 0` on `base` is the control that
matters for §5's new switch**: with the period at its shipped 0, the re-arm block
is unreachable and its counters never move. The measurement surface is inert
until it is asked for.

**R3 — the certified margin, every rung, and no verdict moved:**

| rung | 0.68 | 0.52 | 0.38 | 0.26 |
|---|---:|---:|---:|---:|
| `base` margin | 2372.887 | 793.601 | 355.270 | 232.153 |
| verdict | ACCEPT | ACCEPT | ACCEPT | ACCEPT |

★ **What R3 asked for and what this is, stated plainly.** R3 asks for the margin
as a CURVE with its settling iteration. **That is not what is above, and the
2-iteration cap is why**: a two-point curve has no settling iteration, and a
per-iteration margin curve was unaffordable for a reason that is measured rather
than asserted — PR 326 timed certifying an *unconverged* design at **26x the cost**
of certifying a converged one, so a margin curve down a 4-rung ladder would cost
more than every arm in this table combined and would put the instrument inside
the timing the table reports. What is here instead is the margin **at every rung
of every arm**, which is the number the accept gate actually reads, plus the
per-iteration compliance curve in `tables.py` (free — it is already in
`iterations.csv`). **The settling behaviour R3 wants is a property of a
60-iteration run and it is not measured here.** PR 326 and PR 327 measured it
directly (margin still climbing at 60; one arm peaking at 80 then falling 19.4 %
by 120) and those remain the references.

---

## 7. NOT IN THIS TASK — and the one line worth carrying forward

**Resolution continuation is the strongest remaining lever, and the exact volume
fraction has just made it well-posed for the first time.** `eta` is measured IN
VOXELS ([`plsm.cpp:198`](core/src/simp/plsm.cpp:198), `eta = plsm.eta_voxels * h`),
so a coarse stage and a fine stage would smear the boundary over **different
physical distances** and optimise **different shapes** — the continuation would
not be a continuation. A volume fraction has no scale parameter, so the same φ at
64³ and at 128³ is the same shape twice. It was flagged in July as "the genuinely
untried lever"; PR 327 is what turns it from ill-posed into merely unbuilt.

It is a feature, not a flag, so it is not in this task. But §4(b) is worth
re-reading beside it: the reason `warm_start_coarse` cannot deliver what the task
hoped is precisely that it prolongs a coarse **density** from a coarse **SIMP**
solve. A coarse **PLSM** stage that evaluates the analytic φ on the coarse grid
and hands the fine stage its **coefficients** is the thing that was actually being
described — and it is resolution continuation, wearing a different name.

`rho_min` was not touched. ★ But the brief's reason for excluding it does not
hold and §2b is where that is worked out: PLSM's 1e-3 density clamp becomes a
**1e-9 modulus floor** through `E = rho³E₀`, so the contrast is not SIMP's old
problem that PLSM left behind — it is the same 1e9 on both paths. Excluding
`rho_min` from this task is still right (it is a physics knob, not a solver
flag, and §2c shows contrast is not what stagnates the V-cycle anyway), but it
should be excluded for that reason and not for the stated one.

Active Domain remains disarmed.

---

## 8. PLAIN LANGUAGE — what is actually going on

There are two accelerators in the solver. Both are switched on. Neither is doing
anything, and they are idle for two completely different reasons.

**The first one, GenEO, is behaving correctly and that is the problem.** It works
by building a small "summary" of the structure and using it to skip most of the
work in each solve. The summary genuinely works: once it is switched in, a solve
that would have taken four or five thousand steps finishes in about two hundred.

But the summary has to be **rebuilt against the current shape every single time**,
because the optimiser changes the shape on every iteration — and rebuilding it
costs about three and a half thousand steps' worth of work. So the solver faces a
bet on every solve: pay 3,348 up front for a chance to save several thousand, or
just grind it out. It has a rule for making that bet, the rule is a good one, and
on this job it comes out to "grind it out" **97.6 % of the time — by an average
margin of 7 %.** It is losing a coin flip it is calling correctly.

The fix is not to change the rule. It is to make the summary smaller, because the
rebuild cost is directly proportional to its size — and the one setting that
changes its size is how the part is chopped up into pieces. Bigger pieces, fewer
summary entries, cheaper rebuild.

**That experiment did not run, and that is the one thing this task owes and did
not deliver.** The machine it had to run on was shared with four other jobs all
day, and building the summary at a coarser chop takes long enough that no single
attempt finished. It is one command on a quiet machine, it takes minutes, and
until someone runs it the honest position is that we know exactly why GenEO
declines and do not yet know whether the obvious fix works.

**The second one, multigrid, failed for a reason nobody expected, and it failed
early.** Multigrid solves a problem by repeatedly stepping back to a blurrier
version of it. It gets three chances at the start of a run; if it fails all three
it is switched off for good. On his job it failed all three and was off for the
remaining 157 solves.

The obvious suspicion is that it was judged at a bad moment — right at the start,
before the design has taken shape. **The measurement says the opposite.** Earlier
work reproduced the same failure on a completely uniform field, and separately
showed that extreme stiffness contrast on its own is nearly free. So neither the
design nor its contrast is the culprit.

*(A correction to the brief while we are here: it argues the new optimiser made
the material contrast a thousand times gentler. It did not. The number it quotes
is a density; the solver sees a stiffness, and stiffness goes as density cubed.
The contrast is a billion to one, exactly as before.)*

The cause is **the shape of the part**: a thin stand occupying under a quarter of
the box it sits in. Blur that and the thin bits disappear, and a blurry version
with no structure in it cannot help solve the sharp one. That is measurable and
was measured: the blurred version captures **1.6 %** of the answer's energy, where
a well-behaved part gives **99.3 %**. And it only gets worse as the optimiser
removes material — his own run shows solves getting **3.7× more expensive** from
the first rung to the last. **The moment it was judged was the moment it had its
best chance.** Switching it off was right.

**And there is a third accelerator that nobody asked about. It looked like the
answer. It is not.** Instead of blurring the grid, it groups voxels by how they
are actually connected. Someone built it in August, measured it on this kind of
problem, and found it cut the total work across a whole run by **five and a half
times** while leaving every engineering verdict unchanged — and it made the first
accelerator's whole dilemma vanish, because the solves stopped being hard enough
to need rescuing. It was left switched off partly because its memory use was
projected to blow the budget on a big enough job, **and his job is eighteen times
under that budget**, so there was every reason to expect it to work.

**It was switched on and run on his job, and it did not help at all.** It built
what it was supposed to build. Then the solver burned through its entire budget
exactly as before, gave up at exactly the same place, and every single count down
all four rungs came out identical to leaving it off. The numbers it was measured
at came from a problem twenty times smaller; they do not carry.

That is the most useful thing in this handoff, because it closes a door rather
than opening one. Blurring the grid does not work here. Grouping by connectivity
does not work here either. Every knob on the blurring itself — how much smoothing,
how many levels, what shape of cycle — was swept last week: twenty-five
combinations, none of them converged. **There is nothing left in that direction
that anyone has suggested and not tried**, and that is worth knowing before
another week goes into it.

**And one thing that turns out to be a non-question.** The task asks whether last
week's change to how the boundary is represented made the solver's job harder.
It did not, and it could not have: **that change was never merged into the part of
the code that ships.** It lives entirely in a test harness, behind a flag that is
off by default. The production optimiser still uses the older, blurrier
representation. That is not a criticism of the change — it is a good change — but
a claim about its effect on production runs would have been a claim about code
that has never run in one.
