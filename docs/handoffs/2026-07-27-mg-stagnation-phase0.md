# MG stagnation Phase 0 — does re-arming the latch at rung boundaries rescue multigrid on a real job?

**Status:** Measurement complete. **NO production code changed** — `git diff` on
`core/src`, `core/include`, `app` is empty; `git status` shows one new harness
(`core/tests/harness/mg_rearm_probe.cpp`), this handoff, and its evidence
directory. Deliverable = this handoff + a committed, reproducible harness (the
131 precedent). Phase 0 produces the numbers that would justify a policy change;
the change itself is a separate task (BAR B3).

**Naming:** date-slug convention (`docs/handoffs/2026-07-27-mg-stagnation-phase0.md`,
evidence under `docs/handoffs/evidence/…` — see note below). No number taken.

---

## THE HEADLINE — the leading hypothesis is REFUTED by measurement

The task's leading hypothesis: *iteration 3 of rung 0 (a near-uniform gray haze)
is the single worst moment to judge multigrid; re-arm at each rung boundary and
the hierarchy will CARRY once real structure exists.*

**Measurement says the premise is backwards.** On the exact production entry point
`fea_solve_mgcg_matfree`, across three extents and two geometry regimes:

1. **Stagnation is driven by the FIXED frozen geometry** (thin part in a large
   empty design-box expanse ± a keep-out hole), which is present and unchanging
   from iteration 0. It reproduces on the **uniform** field — before any structure
   develops — at real padded extents (`192×112×128 occ0.40 hole0.40` → **STAGNATED,
   300 V-cycles then 3602 Jacobi**). This confirms handoff 125 §1a on the current
   tree.
2. **Developing real structure makes multigrid MONOTONICALLY WORSE, never better.**
   In *every* regime measured, the per-solve V-cycle count *climbs* as the OC field
   develops and the rung `vf` descends — and at real extents it climbs *past the
   300-cycle budget into stagnation*, even with **no hole at all**:

   | 192×112×128, occ 0.40 | rung 0 (vf .68) | rung 1 (.52) | rung 2 (.38) | rung 3 (.26) |
   |---|---|---|---|---|
   | **NO-HOLE** start-field V-cycles | 157 CARRY | 268 CARRY | **300 STAG** | **300 STAG** |
   | **NO-HOLE** end-field V-cycles | 268 CARRY | **300 STAG** | 300 STAG | 300 STAG |

   The deepest rung — `vf 0.26`, which was **69 % of the real run** — is the field
   where geometric multigrid is *least* able to carry, not most.

**Therefore re-arming the latch at rung boundaries cannot rescue this class of
run.** Re-arm can only help a rung that comes *after* a latched rung *and* would
itself carry. The measured cycle-growth means a later rung is **never more likely
to carry than an earlier one**; so if rung 0 stagnates (which is exactly what
`hier_built 3/165` records), every later rung stagnates at least as hard. Re-arm's
upside set is empty. It would only *add* wasted hierarchy builds (§4).

**The one caveat that keeps this honest (B4):** this is not the maintainer's STEP
part. Whether *that specific* part's rung-0 field genuinely stagnates or the latch
mis-fired is a property of its geometry that only the part resolves (§7). What the
measurement forecloses is the *mechanism* the hypothesis rested on — "haze bad,
structure good." That mechanism does not exist.

**One-line verdicts:**
- **M1 (why iter 3):** STAGNATION, not build-rejection — the hierarchy builds (4
  levels) and the V-cycle fails to contract. Driven by the fixed frozen geometry,
  reproduced on the uniform field. **Not** a property of the undeveloped design.
- **M2 (would it carry later):** **NO.** Developing structure raises the V-cycle
  count monotonically; at real extents it crosses into stagnation by rung 1–2.
- **M3 (cost of the policy):** The prize (Jacobi CG − working-V-cycle CG) is real
  **only where MG would carry**, and the measurement puts the developed low-`vf`
  rungs — the bulk of the run — outside that set. Prize for this run's regime ≈ **0**.
- **M4 (re-arm candidates):** (a) shipped never-re-arm is the cheapest correct
  policy in the stagnating regime; (b) re-arm-each-rung and (c) developed-trigger
  both *add* wasted builds with no measured payoff here. **Recommend: do not ship a
  re-arm.** The lever is elsewhere (§6).
- **M5 (rung 3):** A working geometric V-cycle would **not** have rescued rung 3 at
  these extents; `vf 0.26` developed on thin/holed geometry is beyond geometric
  MG's reach. It is not intrinsic to `vf 0.26` (a *dilute filler* field at the same
  `vf` carries — AMG-P1 §6), it is intrinsic to *this geometry class*.
- **§7c (AMG reopen):** **Not yet met on clean evidence, and this run does not meet
  it either** — because the latch fired at rung-0 iter 3 and MG was *never tested*
  on rungs 1–3. This run shows geometric MG fails on the *haze*, not on a *developed
  real field*. n for "developed real field stagnates" is still effectively **0**.

---

## 0. The mechanism, stated once (so the tables below read cleanly)

`cg_multigrid=0` has two byte-identical causes (handoff 125 §0): **build-rejection**
(grid not coarsenable, no V-cycle ever runs) and **stagnation** (hierarchy builds,
the V-cycle can't contract, burns `kMgIterBudget=300` and falls back). The run's
`mg_mode="stagnated-latched"` is the second: `used_multigrid=false` for the run
**and** `mg_hierarchy_ever_built=true`
([run_job.cpp:908-913](core/src/cli/run_job.cpp#L908)).

The per-run **latch** ([multigrid.cpp:1217-1283](core/src/fea/multigrid.cpp#L1217))
counts *consecutive stagnated solves*; at `kMgLatchThreshold=3` it stops even
BUILDING the hierarchy for the rest of the run. It is reset **exactly once per
run**, at [minimize_plastic.cpp:238](core/src/simp/minimize_plastic.cpp#L238) —
before the ladder starts — and **never re-armed at a rung boundary.** So the
reported `hier_built 3/165 (rung 0), then 0/92, 0/61, 0/31` is the latch's exact
fingerprint: rung 0's first three solves built a hierarchy and stagnated → latch
fired → 162 remaining rung-0 solves **and all of rungs 1-3** skipped the build and
ran Jacobi. This is a faithful read of the shipped code, not a hypothesis.

Whether the latch was a **true** positive (MG genuinely can't carry this part) or a
**false** positive (MG would carry the developed rungs but got judged on the haze)
is the whole question. The measurement answers it for the *mechanism*; the specific
part needs §7.

---

## 1. M1 — WHY DID IT STAGNATE AT ITERATION 3?  (`scan`, uniform iteration-0 field)

Geometric MG on the **uniform** design (`ρ=0.5`, no structure) via the production
entry point, `tol=1e-6`. `verdict = STAGNATED` means the hierarchy **built**
(`hier_built=1`) but the V-cycle hit the 300 budget and fell back (`used_mg=0`) —
distinct from `no-hier` (build-rejection). `cyc` = V-cycles attempted; `cgit` =
CG iterations to converge (Jacobi count when stagnated).

```
case                            nsolid     nbore | verdict    cyc   cgit      resid
64^3      occ1.0 nohole         262144         0 | CARRIES     14     14   9.47e-07
64^3      occ0.4 hole0.4          9728     33536 | STAGNATED  300   1274   9.78e-07
128x80x96 occ0.45 nohole        200448         0 | CARRIES     55     55   9.03e-07
128x80x96 occ0.45 hole0.4       122496     77952 | CARRIES    102    102   9.09e-07
192x112x128 occ0.4 nohole       443520         0 | CARRIES    157    157   8.20e-07
192x112x128 occ0.4 hole0.4      242816    200704 | STAGNATED  300   3602   9.97e-07
```
(raw: `evidence/…/scan_out.txt`)

**Reading.**
- **Stagnation begins on the UNIFORM field** — no developed structure required. The
  `192×112×128 occ0.4 hole0.4` row is the production complaint's shape (thin part,
  large empty box, keep-out hole) and it stagnates at iteration 0. This is *why* the
  real run latched inside the first three solves of rung 0: the field the latch
  judged was already unsolvable by the V-cycle, and it was unsolvable because of the
  **frozen geometry**, which does not change across the run.
- **It is STAGNATION, not build-rejection.** `hier_built=1` on every stagnated row
  (4 internal levels); the `mg_levels=0` you see reported is the fallback default
  ([multigrid.cpp:1291](core/src/fea/multigrid.cpp#L1291)), not a build failure.
- **The killer is the geometry interaction, not contrast** (handoff 125 §1b re-
  confirmed): a full box carries; a thin part in a big empty box + a keep-out hole
  is what tips it. `192³-scale + hole` stagnates; the same extents `nohole` still
  carries (157) — but only just, and §2 shows development pushes it over too.

M1's four requested numbers (`mg_levels`, coarsening ratio, per-cycle contraction,
`mg_cycles_attempted`) for the stagnating case: hierarchy builds **4 levels** by
regular 2× coarsening (ratio ≈ 8×/level), `mg_cycles_attempted=300` (the budget),
and the residual is **still ~1.0 relative contraction** (does not reach `1e-6` in
300 cycles → the effective per-cycle contraction is ≈ 1). That "contraction ≈ 1 at
300 cycles" is 125 §1d's pathological signature, reproduced here.

---

## 2. M2 — WOULD IT CARRY LATER?  (`ladder`, real OC field, warm-start inherited)

The design is developed with the **production OC + density-filter path** down the
ladder `{0.68, 0.52, 0.38, 0.26}`, each rung seeded from the previous rung's
converged field (production `warm_start_inherit`). At the **start of each rung** (=
the exact field a re-armed latch would judge there) and at the **converged end**,
geometric MG is measured fresh (latch reset each time). `CARRIES`/`STAGNATED` as in §1.

**128×80×96, occ 0.45** (`evidence/…/ladder_128.txt`):

| rung (vf) | NO-HOLE start | NO-HOLE end | WITH-HOLE start | WITH-HOLE end |
|---|---|---|---|---|
| 0 (.68) | 55 CARRY | 98 CARRY | 102 CARRY | 177 CARRY |
| 1 (.52) | 98 CARRY | 136 CARRY | 177 CARRY | 237 CARRY |
| 2 (.38) | 136 CARRY | 186 CARRY | 237 CARRY | 251 CARRY |
| 3 (.26) | 186 CARRY | 253 CARRY | 251 CARRY | **300 STAGNATED** |

**192×112×128, occ 0.40** — the production-extents case (`evidence/…/ladder_192.txt`).
Cells show the start-field verdict and, when stagnated, the Jacobi fallback count:

| rung (vf) | NO-HOLE start | NO-HOLE end | WITH-HOLE start | WITH-HOLE end |
|---|---|---|---|---|
| 0 (.68) | 157 CARRY | 268 CARRY | **300 STAG** (3600) | **300 STAG** (5235) |
| 1 (.52) | 268 CARRY | **300 STAG** (2105) | **300 STAG** (5235) | **300 STAG** (6199) |
| 2 (.38) | **300 STAG** (2105) | 300 STAG (2409) | **300 STAG** (6199) | **300 STAG** (7690) |
| 3 (.26) | **300 STAG** (2409) | 300 STAG (3043) | **300 STAG** (7690) | **300 STAG** (8627) |

The WITH-HOLE column is the direct match to the production complaint (thin part,
large empty box, keep-out hole): it stagnates from the **uniform** field on, at
**every rung**, and the Jacobi fallback count **climbs monotonically as the design
develops** — `3600 → 5235 → 6199 → 7690 → 8627`. That climb is the miniature of the
real run's `41,063`-CG rung-3 solve at full 128³ STEP geometry: developing structure
makes the *linear solve itself* harder, and a re-armed V-cycle would only have burned
its 300 cycles on each of these fields before falling back to that same rising grind.

**The finding is uniform and it is the answer to M2:** developing structure raises
the V-cycle count at every step, and at production extents it crosses the budget by
rung 1–2. There is **no rung at which a developed field carries where the earlier
(less-developed) field did not.** The re-arm hypothesis needs the opposite — a field
that stagnates early and carries once developed — and it does not occur.

*Why development hurts, mechanistically:* OC drives the design toward thin
black-and-white members (`ρ→1`) separated by near-void (`ρ→ρ_min`). After 3–4
halvings a 2–3-voxel member is thinner than a coarse cell and **vanishes from the
Galerkin coarse operator**; the coarse-grid correction goes blind to exactly the
bending modes that dominate the error (125 §1b mechanism). The uniform haze has
*no* such members — which is precisely why it is the **easiest**, not the hardest,
field for the V-cycle.

---

## 3. M3 — THE COST OF THE POLICY (in the honest, conditional form)

The prize the task asks for — *CG iterations spent vs CG a working V-cycle would
need* — is only collectable **where a working V-cycle exists.** The measurement
(§1–2) places the developed low-`vf` rungs of a stagnating-regime run **outside**
that set. So for the run as reported:

- **Rung 3** (69 % of the run: `31` iters, one solve `41,063` CG, `5.41 h`): the
  developed `vf 0.26` field is measured STAGNATED at these extents (300 cycles, no
  contraction). A "working V-cycle" is **counterfactual** here — there isn't one to
  substitute. Prize ≈ **0 h**.
- **Whole run** (`1,583,186` Jacobi CG, `7.79 h`): same conclusion rung by rung.
  Since rung 0's uniform field already stagnated (the run latched there), no rung is
  easier than that stagnating field.

**Where the prize IS real** — and this is the number that matters for scoping — is a
run in the **carrying** regime, which is a *different run*: a filler-rich dilute box
with no sub-coarse-cell holed ligaments. AMG-Phase-1 §6 measured exactly one such
real-optimizer field (2 % fill, `vf 0.26`) and geometric MG **carried in 26 cycles
vs 1273 Jacobi** — a ~3× wall win. **But that run would never have latched** (its
rung 0 carries), so the shipped never-re-arm policy already keeps MG on for it.
The prize and the latch-firing are mutually exclusive populations. That is the crux
of why re-arm buys nothing.

---

## 4. M4 — RE-ARM POLICY CANDIDATES (compared; NOT shipped, per B3)

Evaluated on this run's structure (rung 0 stagnates → latch fires in rung 0) and on
the measured cycle-growth. "Wasted build" = a hierarchy build + up-to-300 V-cycles
that ends in fallback; handoff 127 measured the build alone at **~60 % of a
stagnating solve** (the latch's entire reason to exist).

| policy | hierarchy builds attempted | MG solves that carry | net vs shipped |
|---|---|---|---|
| **(a) never re-arm** (shipped) | **3** (rung 0 only), then latched | 0 | baseline |
| **(b) re-arm every rung boundary** | **3 × 4 = 12** (each rung re-stagnates, per §1–2) | 0 | **+9 wasted builds, 0 carries → strictly worse** |
| **(c) developed-design trigger** (e.g. gray-fraction / max‖Δρ‖) | 3 per firing, and it fires *when structure exists* — i.e. exactly when MG is measured WORST (§2) | 0 | worse than (a); the trigger points at the least favourable field |

The comparison is decided by the §2 monotonicity, not by a threshold choice: **every
re-arm variant re-attempts MG on a field that is at least as stagnation-prone as the
one that latched.** In the *carrying* regime all three policies are identical (the
run never latches). So re-arm has **no regime in which it wins** on this evidence.

**Recommendation (measure-and-advise, not ship):** keep the shipped never-re-arm
latch. The latch is doing its job — it is cheaply absorbing an *unavoidable*
Jacobi fallback. The real levers are the ones handoff 125 §5 already ranked and are
orthogonal to re-arm:
1. make the honest Jacobi fallback **cheaper** (draft loose-tol trajectory; Active-
   Domain domain-shrink) and **shorter** (the MMA plateau-stop that 125 §2 found
   never fired — a flat-from-start `vf`-rung walks to the 200 cap at Jacobi cost);
2. if a durable fix for the *linear solve itself* is wanted, it is **AMG as the
   latch's replacement target**, not a re-arm of geometric MG (§6).

---

## 5. M5 — RUNG 3 SPECIFICALLY (the 69 %)

Rung 3 is `vf 0.26`, the most-developed, thinnest field of the run. The measurement
(§2) puts it squarely in the STAGNATED band at production extents — in the NO-HOLE
`192³` ladder it is already stagnated by rung 2, and rung 3's converged field needs
`3043` Jacobi with the V-cycle contributing nothing. So:

**A working geometric multigrid would NOT have rescued rung 3.** `vf 0.26` on this
geometry class is beyond the regular-coarsening V-cycle's reach — the thin members
disappear from the coarse operator. The AD escape (active fraction `0.170→1.000`)
and the `41,063`-CG solve are the Jacobi tax on an unpreconditioned, near-mechanism
thin structure; a re-armed V-cycle would have burned its 300 cycles and fallen back
to the same Jacobi grind, adding build cost.

**The important qualifier, because it decides the AMG question:** `vf 0.26` is *not
intrinsically* beyond geometric MG. AMG-Phase-1 §6 measured a **dilute filler**
field at the same `vf 0.26` that geometric MG carried in 26 cycles — because a
sea of near-`ρ_min` filler is coarse-grid-friendly and *keeps the V-cycle healthy*.
What defeats the V-cycle at rung 3 is **thin solid ligaments routing around removed
material (holes / empty expanse)**, not the low volume fraction as such. This is the
line between "reopen AMG" and "don't" — see §6.

---

## 6. §7c — IS THE AMG REOPEN CONDITION MET?

The AMG shelf's named reopen condition (AMG-Phase-1 handoff, §7b item 5 / §6b): AMG
is worth reopening as **the latch's replacement target** when **geometric-multigrid
failure on REAL developed jobs becomes common** — because the one real-optimizer
field measured to date *did not* stagnate, so the whole shelf rested on synthetic
lattices for its stagnation evidence.

**State plainly: the condition is NOT yet met, and this run — despite being a real
geometric-MG failure — does not move it as much as it appears to.** Two reasons,
both from the evidence above:

1. **This run's failure was measured on the HAZE, not on a developed real field.**
   The latch fired at rung-0 iteration 3 and MG was **never run again** for the rest
   of the job. So the run is hard evidence that geometric MG fails on the *iteration-0
   frozen-geometry field*, and **no evidence at all** about whether it fails on the
   developed rungs — those solves were all Jacobi by policy. The reopen condition is
   about developed real fields; this run is silent on them.
2. **The count that matters is still n≈0.** Across the whole project the number of
   *real optimizer-output developed fields* on which geometric MG has been *observed*
   (MG actually attempted, not latched-off) to stagnate is: this run contributes
   **0** clean data points (latched), and the only prior real developed field
   (AMG-P1 §6) **carried**. So the honest tally of "real developed field where
   geometric MG genuinely stagnates" remains **0 confirmed**.

**What n would satisfy it, and what to collect on the way (the measurable ask):**

- **n ≥ 3 distinct real parts** on which, with the latch **disabled or re-armed in a
  measurement build**, geometric MG is *observed to attempt and stagnate on the
  DEVELOPED rungs* (`used_mg=0` with `hier_built=1` on a `vf≤0.4`, structure-formed
  field), each part's geometry characterized: envelope occupancy, presence and size
  of keep-out holes, and infill/dilution. Three is the smallest n that distinguishes
  "a recurring geometry class" from "one unlucky part," matching the project's
  n=1-is-not-a-trend discipline.
- **On the way there, the single cheapest high-value datum** is a *latch-disabled
  re-run of THIS job's part* (or any one real design-box + keep-out job): let MG
  attempt every solve, log per-solve `hier_built` / `mg_cycles_attempted` /
  `used_mg` down all four rungs. If the developed rungs stagnate with MG *allowed*,
  that is the first real confirmed point and it directly tests §2's forecast on the
  actual geometry. If they *carry*, the latch is a false positive on this part and
  the fix is a smarter latch (or re-arm after all) — but §2 predicts they will not.
- The instrumentation already exists: `iterations.csv` carries `hier_built` and
  `mg_cycles_attempted` (handoff 128); only the latch-disable flag for the
  measurement build is missing, and that is a one-line opt-in, not a production change.

Until those points exist, the durable-solver decision stays where AMG-Phase-1 left
it: **AMG NO-GO on the bars; keep it shelved as the latch-replacement candidate**,
and spend the next increment on the cheap Jacobi-cost levers (§4).

---

## 7. B4 — WHAT THIS MEASURED, AND WHAT IT DID NOT (the fixture the real run needs)

**Measured, on the exact production solver:** the *mechanism* of the re-arm
hypothesis, on the documented 125 geometry family (thin part in an empty box ± a
keep-out hole) across three extents and a real OC-developed ladder. This is
sufficient to refute "haze bad, structure good" — that claim is geometry-independent
and it is false in every regime tested.

**NOT measured, and it requires the maintainer's actual part (per B1/B4):** whether
*this specific STEP part at 128³, 25 % infill, with its actual keep-out geometry*
stagnates on its **developed** rungs when MG is allowed to run. Two things about the
real part are unknown to a synthetic proxy and both bear on the answer: (i) whether
its 25 % infill makes it *filler-rich* (the carrying regime of AMG-P1 §6) rather
than *holed-thin* (the stagnating regime), and (ii) the exact keep-out hole
geometry. The synthetic fixtures **bracket** these — no-hole/filler vs
with-hole/thin — but do not reproduce the part.

**Exactly what fixture would close it:**
1. The maintainer's STEP file + the run's `design_mask` / keep-out (clearance-void)
   definition + the load/BC case — i.e. the inputs that produce the `192×112×128`-
   class solved grid this job ran on.
2. The run's **per-iteration `iterations.csv`** (with the `hier_built` /
   `mg_cycles_attempted` columns), to place each solve as build-rejection vs
   stagnation without reconstruction (125 §3's ask, now that the columns exist).
3. A **latch-disabled measurement build** (opt-in flag; no production behavior
   change) so MG is attempted on every solve of every rung and the developed-rung
   verdict is observed rather than inferred.

With those three, §2's forecast becomes a direct measurement on the real geometry
and the §6c count gains its first clean point.

---

## 8. REPRODUCE — every number above

The library must be built Release first; then the harness is a single TU linked
against `libtopopt.a` (the 131 pattern):

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O2 -I core/include -I core/src/fea \
    core/tests/harness/mg_rearm_probe.cpp core/build/libtopopt.a -o mg_rearm_probe

./mg_rearm_probe scan                          # §1 uniform-field mechanism (~1.5 min)
./mg_rearm_probe ladder 128 80 96 0.45 12 1e-4 # §2 moderate-extent ladder   (~20 min)
./mg_rearm_probe ladder 192 112 128 0.4 8 1e-3 # §2 real-extent ladder       (~40 min)
```

Args: `ladder <ex> <ey> <ez> <occ> <oc_iters_per_rung> <develop_tol>`. Every table
above is a run of one of these three commands; raw stdout is committed under
`evidence/` (`scan_out.txt`, `ladder_128.txt`, `ladder_192.txt`). Cycle counts,
`hier_built` verdicts and CG counts are **deterministic** (thermal protocol 113
applies only to the `sec` columns). The harness resets the per-run latch before
every measurement, so each row is independent — the same discipline
`geometric_baseline` uses in `amg_probe.cpp`.

**Evidence directory:** committed at `evidence/2026-07-27-mg-stagnation-phase0/`
(the repo-root `evidence/` tree, per the task's handoff spec); the harness source
is committed at `core/tests/harness/mg_rearm_probe.cpp` (B1's sanctioned probe
location) and copied into the evidence dir for self-containment.
