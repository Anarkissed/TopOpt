# ACTIVE DOMAIN — re-examining the arming against PR 209's evidence

## TL;DR (measured, not asserted)

PR 209 raised two results against the Active Domain (AD) arming (PR 187). I reproduced
both independently before judging anything. The findings **cut in a more nuanced
direction than the alarm OR the original arming**:

1. **Result 1 (stagnation, +26% CG) REPRODUCES to the digit** — but it is **one sample
   of a high-variance coin-flip**, not a systematic regression. On the same class of
   stagnating job at a different size (L, uncapped) AD is **−9%** (a win). AD's effect on
   stagnating jobs is uncontrolled trajectory noise ranging **−25% … +26%**, because the
   escape latch turns AD off after ~2 restricted iterations — so its dilution win never
   operates there, leaving only which-iteration-stagnates chaos.
2. **Result 2 (AD-on "does not converge" at L) DOES NOT REPRODUCE** under faithful,
   **uncapped** conditions. AD-on L converges (tight and draft). My first "throw" was a
   **CG-cap artifact** (AD-off threw at the same cap). No correctness/robustness regression.

**What this means for the arming.** AD was armed on the theory its fixture win (1.79×)
would cut the maintainer's stagnating 128³ Jacobi grind. **That premise is measured
false**: in the stagnation regime AD targets, its effect is a coin-flip, not a reliable
win. What remains is a **non-bit-identical approximation** that reliably helps only in the
strictly-healthy, no-latch regime (−17% … −25%) — a regime that is (a) redundant with the
also-armed draft quality and (b) the opposite of the target job — and that costs a real
fidelity miss on the gate (rung-1 margin `dM/M = 1.097e-3`, over the 0.1% bar).

**Recommendation: DISARM AD** (revert `kProductionActiveDomainBand` to `0`). Basis below.
Disarming is gate-safe (identical verdicts) and byte-identical to the pre-187 reference
that reproduces 185/197 to the digit. **This PR does not change the armed default (R4).**
The maintainer decides; the table is supplied.

---

## R1 — REPRODUCE BOTH RESULTS FIRST

### Result 1 — REPRODUCES EXACTLY

`draft_arming_gate stag 12`, big stagnation fixture (48×32×48, 73 728 elements, 48.8×
dilution), recycling armed in every posture (`repro_stag12.log`):

| posture | CG | Jacobi | latch |
|---|---|---|---|
| rec (no AD) | **15349** | 2/12 | — |
| rec+AD | **19329** (**+25.9%**) | 2/12 | escape @iter3, **1008 escapes** → full domain |
| rec+AD+draft | **947** | 0/12 | escape @iter3, 1008 escapes |

Matches PR 209's A5 table (15349 → 19329, latch@3/1008, 947) to the digit. **Reproduced.**

### Result 2 — DOES NOT REPRODUCE (faithful, uncapped)

The claim: at L 32×16×32 the armed posture fails to converge (matfree multigrid stalls
into Jacobi-CG and `fea_solve_mgcg_matfree` throws). What actually happens
(`repro_L_convergence_faithful.log`, single production ladder per posture, tight 1e-8,
**uncapped**):

| posture | result | trajectory CG | wall |
|---|---|---|---|
| AD-off tight | **CONVERGED** | 246667 | 413 s |
| AD-on tight | **CONVERGED** | 223863 (0.91×) | 383 s |

**AD-on L converges — it does not throw**, and is actually *cheaper* than AD-off here.

**The confound, named.** My first reproduction used a CG cap of 2000 and AD-on threw
(`repro_L_ADon_cap2000.log`) — but **AD-off threw at the same cap too**
(`repro_L_ADoff_cap2000.log`). The L grid's stagnating tight solves need ~250k trajectory
CG; a per-solve cap of 2000 forces the **full-domain** solve to miss tolerance regardless
of AD, so both postures throw. The cap, not AD, produced the throw. There is no cap at
which AD-on throws and AD-off converges on this fixture.

**Why AD-on converges — the escape latch saves it.** On every stagnating fixture measured
(L, big-stag, ARM12, the gate fixture) AD's escape latch fires ~iter 3 and reverts to the
full domain. So AD-on runs restricted for only ~2 iterations, then *is* AD-off; the final
full-domain tight certification (`simp.cpp:1917`, the only uncaught-throw site) certifies
the same class of design AD-off does. For AD-on to throw, the latch would have to stay
quiet while AD ran restricted the whole way into a severed/non-coarsenable domain — which
does not happen here. Per R1, this is the best outcome and it retires the result-2 alarm.

**Corroboration via the EXACT PR 209 harness.** `draft_quality_phase2_scale` (the harness
whose A6 reported the throw), `TOPOPT_SCALE_AD=on`, L, **uncapped**, run to completion
(`repro_L_ADon_scaleharness_uncapped.log`): **tight CG 223863 (CONVERGED), draft CG 140162,
WIN 1.60×, exit 0 — no throw.** The tight CG (223863) matches the faithful single-ladder
probe to the digit. So the result-2 non-convergence does not reproduce in the very harness
that reported it, on this build (main incl. #206/#207/#208/#210).

---

## Mechanism, named with numbers

### Result 1: it is TRAJECTORY DIVERGENCE, not restriction overhead

Per-iteration probe on the big-stag fixture (`mechanism_stag_per_iter.log`,
`mechanism_result1_analysis.txt`). Both postures run 12 capped iters; recycling armed:

| | rec (no AD) | rec+AD |
|---|---|---|
| deep Jacobi-stagnation events | iters {3,5} = 5803 + 8004 = **13807** | iters {3,6} = 6299 + 11987 = **18286** |
| AD restriction overhead | — | iter 2 only (active_frac 0.31): **+146 CG** |
| everything else | cheap multigrid (~50–240 CG/iter) | cheap multigrid |
| total | 15349 | 19329 |

- The **restriction overhead is negligible** (+146 CG). The +3980 is downstream.
- The **escape latch works as designed**: the band fights the optimizer's descent for 2
  steps, 1008 elements escape, the latch reverts at iter 3. From iter 3 on **both postures
  solve the identical full-domain operator**.
- The +3980 is **trajectory divergence**. The 2 pre-latch restricted steps seed a
  different design; on a job whose cost is dominated by a *few unpredictable* deep
  Jacobi-stagnation solves (5k–12k CG each), a different design path lands a different set
  of those events. Here it landed a deeper one (11987 vs 8004).
- **The sign is not controlled.** Same mechanism, L tight: AD-on is −9% (223863 vs
  246667). Big-stag: +26%. It is a coin-flip, paid on top of AD's setup + O(N) escape scan.

### Result 2: the latch reverts AD before the final cert can diverge (above).

---

## R2 — FOUR POSTURES × MULTIPLE GRIDS × BOTH REGIMES

`none` = recycling OFF, AD OFF, draft OFF. `rec` = +recycling. `rec+AD` = the arming.
`rec+AD+draft` = full shipped production. **AD effect** is measured vs `rec` (recycling is
armed in production). All CG deterministic (P-core pin, matfree threads 6). Sources:
`fourposture_healthy_arm{8,12,16}.log`, `stag.csv`, `repro_L_*`, `four_posture_table.txt`.

| fixture / grid | Jacobi (regime) | none | rec | rec+AD | rec+AD+draft | **AD vs rec** |
|---|---|---|---|---|---|---|
| ARM8 16×6×16 | 0/60 **healthy** | 4878 | 4878 | 4062 | 3232 | **0.833× helps** |
| ARM16 32×12×32 | 0/73 **healthy** | 3494 | 3494 | 2619 | 1697 | **0.750× helps** |
| gate 24576 (46.5×) | 0/98 healthy+latch | — | 2384 | 2618 | — | **1.098× hurts** |
| ARM12 24×8×24 | 2–3/59 mild stag | 17605 | 17661 | 18921 | 11574 | **1.071× hurts** |
| big-stag 48×32×48 | 2/12 deep stag | — | 15349 | 19329 | 947 | **1.259× hurts** |
| L 32×16×32 tight | deep stag (~250k CG) | — | 246667 | 223863 | — | **0.908× helps** |
| L 32×16×32 +draft | 192–284 Jacobi | — | 161365¹ | — | 140162 | **0.869× helps** |

¹ `rec+draft` (AD off) baseline for the draft row.

**The pattern.** AD's sign is set by the *specific* stagnation event structure, **not by
grid size** (ARM16 large-but-healthy helps; ARM12 small-but-stagnating hurts). Across the
measurements AD helps 5, hurts 3, range −25% … +26%, mean ≈ −5% but with the variance
swamping the mean. **In the healthy no-latch regime it is a reliable −17% … −25%; the
moment the escape latch fires (gate, ARM12, big-stag) it is neutral-to-negative.** The
128³ design-box job stagnates ~100% of iterations → it is the latch-fires / coin-flip end,
where AD does not reliably help.

---

## Question (d) — does AD's benefit survive once draft is armed?

`ad_redundant_under_draft_probe` on big-stag, recycling on all four
(`question_d_ad_redundant.log`):

| posture | CG | Jacobi |
|---|---|---|
| rec | 15349 | 2/12 |
| rec+AD | 19329 | 2/12 |
| rec+draft | **1210** | 0/12 |
| rec+AD+draft | **947** | 0/12 |

- **Draft alone does 92% of the win** (15349 → 1210, 0.079×). It lifts the early
  ultra-dilute solves off the Jacobi stagnation latch — the exact grind AD's dilution win
  was meant to cut.
- **Under draft, AD gives a small additional win** (947 vs 1210, 0.783×) — but note draft
  moved every solve to multigrid (0/12 Jacobi), so AD is back in its *healthy* regime,
  where it works. Its marginal contribution (263 CG) is 1.7% of the original problem.
- So AD is **not strictly redundant** under draft, but its value is small and lives in the
  healthy regime draft itself creates. At L, draft removed less stagnation (still 192–284
  Jacobi solves) and AD still helped modestly (0.869×). **Draft, not AD, is the load-
  bearing stagnation feature.**

---

## R3 — GATE TABLE, ARMED (AUTO) vs DISARMED (band 0)

Full production ladder, AD-arming gate fixture (24 576 elements, 46.5×, healthy), each
posture twice (`gate_table_adg_arm.log`, `gate/gate.csv`, `gate_table_interpretation.txt`).
"OFF" (band 0) is the recommended disarmed posture; "ON" (AUTO) is what ships today.

| rung | vf | verdict OFF→ON | margin OFF → ON | dM/M | mean\|Δρ\| | max\|Δρ\| | latch (ON) |
|---|---|---|---|---|---|---|---|
| 0 | 0.68 | ACCEPT → ACCEPT | 1.75947 → 1.75938 | 5.54e-5 | 3.94e-6 | 1.19e-3 | — (f_bar 0.417) |
| 1 | 0.52 | REJECT → REJECT | 0.842343 → 0.841419 | **1.097e-3** | 6.82e-6 | 1.40e-3 | **LATCHED@3, 50 esc** |

```
twice-run bit-identical:  OFF YES   ON YES
gate verdicts identical:  YES (rung 0 ACCEPT, rung 1 REJECT; ladder stops at rung 1, both)
terminal recommendation:  IDENTICAL — "fdm walls=4 top=5 bottom=4 infill=45% gyroid"
CG iterations:            OFF 2384 -> ON 2618  (1.098x — the armed posture is +9.8% MORE here)
WORST margin rel delta:   1.097e-3  (bar 1e-3 = 0.1%)  -> the ARMED posture MISSES the bar (rung 1)
```

**Reading.** (1) **Disarming is gate-safe**: identical verdicts, identical terminal
recommendation; OFF is byte-identical to the pre-187 reference (band 0 derives no mask).
(2) **The armed posture is already the worse one here**: +9.8% CG and a 0.1%-margin-bar
miss on rung 1, because that rung's trajectory is mildly divergent — the escape latch fires
(50 esc@3) and AD pays the divergence cost without the sustained-restriction benefit. This
is result 1's mechanism in miniature, on the gate fixture itself. (Verdicts/margins match
PR 187's A3 to the digit — `1.75947 / 0.842343`; absolute CG differs, `2384/2618` vs the
handoff's `3454/3885`, because #206/#207 merged after; the ratio and the rung-1
latch/margin-miss are unchanged.)

---

## RECOMMENDATION — disarm AD, with the measured basis

**Primary: DISARM.** Set `kProductionActiveDomainBand = 0` (a one-line flip of the same
production dial 187 set; byte-identical off, THE ONE RULE preserved). **Not done in this
PR** (R4) — this is the measured recommendation the maintainer decides on.

The five measured reasons, in order of weight:

1. **The arming's core premise is false.** AD was armed to cut the stagnating 128³ job's
   Jacobi grind. In the stagnation regime its effect is an **uncontrolled coin-flip
   (−25% … +26%)** because the escape latch turns it off after ~2 iterations — the dilution
   win never operates there. It does **not** reliably help the target job.
2. **It is a non-bit-identical approximation with a real fidelity cost.** The gate shows a
   `dM/M = 1.097e-3` miss on the 0.1% margin bar (rung 1) — a cost paid for no reliable
   benefit. Disarming restores exact, bit-identical trajectories.
3. **Its only reliable win is redundant and off-target.** −17% … −25% appears only in the
   strictly-healthy, no-latch regime; that regime is (a) already cheap, (b) covered by the
   also-armed **draft** (question d), and (c) the opposite of the stagnating target job.
4. **Disarming is safe and simplifying.** Gate verdicts identical, byte-identical to the
   validated pre-187 reference (185/197 to the digit), removes the +26% tail and the
   trajectory-divergence noise, and drops the one production dial that is not bit-identical.
5. **The alarm that prompted this review is also overstated — reported honestly.** Result
   1's +26% is one coin-flip sample (L shows −9%); result 2's throw is a cap artifact that
   does not reproduce. So this is a **"does not earn its non-bit-identical status"** disarm,
   **not** a "it regresses/breaks" disarm. It is a low-stakes decision either way.

**Alternatives considered.**
- **Keep armed.** Defensible on the mean (~−5% CG) and the modest draft-regime wins (L
  0.87×, big-stag 0.78×); it breaks nothing. But it keeps a non-bit-identical approximation
  with a margin-bar miss and a +26% tail for an unreliable benefit that draft largely
  duplicates. Weak justification.
- **Arm conditionally / below a grid ceiling.** Not supported: **size is not the axis**
  (ARM16 large+healthy helps, ARM12 small+stagnating hurts), and stagnation is not knowable
  pre-run. The escape latch is the runtime detector, but it fires *after* AD has already
  paid the trajectory-divergence cost, so it cannot be repurposed as a pre-run arming gate.
  No measured threshold cleanly separates help from hurt.

**If kept armed anyway** (maintainer's call), the one concrete robustness hardening this
review surfaces is unrelated to AD's benefit: the final-cert solve (`simp.cpp:1917`) is the
sole uncaught-throw site; wrapping it in the same AD-off fallback discipline the trajectory
solves already use would convert any future certification stall into a full-domain retry
rather than an aborted job. (Not needed for the disarm recommendation; noted for
completeness. Out of scope to implement here.)

---

## Provenance / scope

- **Machine:** Apple M2 Pro (6P+4E), macOS, Release (`-O3 -DNDEBUG`), matrix-free threads
  6 (the 132 P-core pin). Every CG count, escape count, latch iteration, resolved band and
  verdict is **deterministic**; wall-clock times are thermally exposed and several jobs
  shared the host, so wall times are indicative only — the CG counts and convergence
  outcomes are the durable signals.
- **Build:** this branch's core (main incl. #206/#207/#208/#210) built with
  `cmake -S core -B build -DCMAKE_BUILD_TYPE=Release`. All harnesses compiled `-O2` against
  `build/libtopopt.a`.
- **No forbidden files touched:** no `fixtures/`, benchmarks, `materials.json`,
  `ARCHITECTURE.md`, `DECISIONS.md`, ROADMAP checkboxes, or `/app/`. No production source
  or default changed (R4). New files are four standalone diagnostic **harnesses** under
  `core/tests/harness/` (not CTest targets), siblings of the existing `active_domain_*` /
  `draft_*` harnesses.
- **The 128³ job itself is still not run** (a single ladder there exceeds a 6-P-core Mac's
  practical wall time — 168 §1a's ~11 h). The stagnation-class fixtures here are the honest
  proxy; the coin-flip finding is what transfers, and it is a property of the mechanism (the
  latch turning AD off), not of a particular grid.

## Evidence — `evidence/2026-07-27-ad-arming-review/`

| file | what |
|---|---|
| `repro_stag12.log`, `stag.csv` | **Result 1** reproduced (rec 15349 → rec+AD 19329) |
| `mechanism_stag_per_iter.log`, `mechanism_result1_analysis.txt` | the per-iteration mechanism (trajectory divergence, +146 overhead) |
| `repro_L_convergence_faithful.log`, `result2_refutation.txt` | **Result 2** refuted (AD-on L converges uncapped) |
| `repro_L_ADon_cap2000.log`, `repro_L_ADoff_cap2000.log` | the CG-cap confound (both throw at cap 2000) |
| `repro_L_draft_stack.log` | shipped stack rec+AD+draft converges at L (0.87×) |
| `repro_L_ADon_scaleharness_uncapped.log` | corroboration via the exact PR 209 scale harness |
| `fourposture_healthy_arm{8,12,16}.log`, `four_posture_table.txt` | **R2** four-posture table across grids/regimes |
| `question_d_ad_redundant.log` | **question (d)** — draft does 92% of the win; AD marginal under draft |
| `gate_table_adg_arm.log`, `gate/gate.csv`, `gate_table_interpretation.txt` | **R3** gate table, ARMED vs DISARMED |

### Recipe

```bash
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="/opt/homebrew/opt/eigen;/opt/homebrew/opt/opencascade"
cmake --build build -j10
HRN="c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH=\"$PWD/core/src/settings/rules.json\""
EV=$PWD/evidence/2026-07-27-ad-arming-review

# Result 1 + question (d) + mechanism (big-stag; minutes each)
$HRN core/tests/harness/draft_arming_gate.cpp          build/libtopopt.a -o /tmp/dag
$HRN core/tests/harness/ad_stag_mechanism_probe.cpp    build/libtopopt.a -o /tmp/adm
$HRN core/tests/harness/ad_redundant_under_draft_probe.cpp build/libtopopt.a -o /tmp/adr
TOPOPT_DA_DIR=$EV /tmp/dag stag 12          # result 1
/tmp/adm 12                                 # mechanism
/tmp/adr 12                                 # question (d)

# Result 2 (faithful, uncapped — ~15 min) + shipped-stack + four-posture + gate
$HRN core/tests/harness/ad_L_convergence_probe.cpp     build/libtopopt.a -o /tmp/adl
$HRN core/tests/harness/ad_L_draft_probe.cpp           build/libtopopt.a -o /tmp/adld
/tmp/adl                                    # AD-off vs AD-on L, tight, uncapped -> BOTH converge
/tmp/adld                                   # rec+draft vs rec+AD+draft at L    -> BOTH converge
for A in 8 12 16; do TOPOPT_DA_DIR=$EV TOPOPT_DA_ARM=$A /tmp/dag interaction 200; done
$HRN core/tests/harness/active_domain_gate.cpp         build/libtopopt.a -o /tmp/adg_bin
mkdir -p $EV/gate && TOPOPT_AD_DIR=$EV /tmp/adg_bin arm   # gate table
```
