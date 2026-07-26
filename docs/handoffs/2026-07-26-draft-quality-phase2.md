# Draft Quality Phase 2 — a design-space escalation trigger (BUILT; does NOT separate)

**Date:** 2026-07-26
**Area:** core optimizer posture — the escalation gate in `minimize_plastic.cpp`
(`MinimizePlasticOptions::draft_use_design_trigger` + the two-reseed probe),
observability, and the topopt-cli `draft` job block. **NOT `/app/`.**
**Status:** the design-space trigger is BUILT, plumbed, byte-identical OFF, and costs
~1% of the rung. **Its pre-stated acceptance bar D1 FAILS: the probe does NOT separate
Phase-1's two counterexamples.** Per the task's explicit instruction, no threshold was
fitted to force separation — the non-separation is reported with its mechanism and the
work STOPS at that gate. The provisional 0.02 compliance gap is RETIRED (it fires as a
false positive and catches nothing). **Evidence:** `evidence/2026-07-26-draft-quality-phase2/`.

## TL;DR

Phase 1 shipped a compliance-gap escalation trigger and measured it not to separate.
This task built Phase 1's own recommended replacement — a DESIGN-SPACE probe at the
rung plateau — and put it to the pre-stated bar D1: it must fire on the genuinely
diverged rung (flip 0.15, gap ≈ 0) and not on the converged one (gap 0.031, flip 0).

**Result: the design-space probe rejects the converged false-positive (an improvement
over the gap) but ALSO reads 0 on the genuine divergence — it does not fire on the
first case, so it does not separate.** The reason is structural and is proven, not
asserted: the diverged plateau is a locally STABLE tight optimum (a different basin
than the tight run's), so a probe seeded *from that plateau* cannot see the divergence
at any budget. The divergence lives upstream in the trajectory PATH — escaping it
needs a full tight re-run from the rung's entry seed, which is escalation itself, not a
cheap probe. And that divergence is benign anyway: it is a valid alternate optimum that
never reaches the always-exactly-certified shipped design.

Per D1 ("If it does not separate either, report that and STOP; do not fit a
threshold"), the work stops at the gate. What ships: the instrument, DISARMED by
default and honestly documented; the retirement of the 0.02 gap; exact certification
(Phase-1 part c) reaffirmed as the real and sufficient safety.

## The bars, scored

| Bar | Requirement | Result | |
|-----|-------------|--------|-|
| **D1** | Probe fires on the diverged counterexample, not the converged one | Converged CE-2 (loose 3e-1 r2): gap **0.03103** (gap FIRES, false +) / probe **0.00000** (correct). Diverged CE-1 (loose 5e-1 r1): truth flip **0.1500** / probe **0.00000** (MISS). **Fires on neither → does NOT separate.** | **FAIL → STOP** |
| **D2** | Negative control FIRST (tight vs tighter); diffs relative to floor | Floor (loose barely above cert) = **0.0000** both postures, both grids. Every probe number below is absolute-above-a-0-floor. | **PASS** |
| **D3** | Probe cost < 5% of the rung; state the number | Two-reseed probe = **0.94%** of the ladder (AD-on) / **0.96%** (AD-off); per-rung 0.71–2.59%. | **PASS** |
| **D4** | Win survives scale; ≥3 sizes; trend stated | AD-off (converges, reproduces 185 to the digit): 16³ **2.07×**, 24³ **3.62×**, 32³ **1.53×**. Non-monotonic (tracks stagnation fraction); endpoints FALL 2.07→1.53. Probe ~1% at every size. 128³ is a bracketed prediction, not measurable in practical wall time. | **PASS (trend down at endpoints, stated)** |
| **D5** | draft OFF byte-identical; re-proven | B1 FNV over densities+compliance+margins+accepts+iters (box + no-box), draft OFF: branch **8d4b9afed2181d10** == stashed-pre-phase2 **8d4b9afed2181d10** (stash-rebuild proof). test_job 106/106, test_observability 35/35. | **PASS** |
| **D6** | Gate never softens; asserted, not commented | The probe's tight endpoint and the escalation re-run both `assert(cg_tolerance == kCertTol)`; asserts live (no `-DNDEBUG`), never tripped (the diag's escalate-all path fired the re-run through the assert). | **PASS** |
| **D7** | Grid dims + solid count in every design-diff row | Every harness row carries `NxNyNz (solid)`. | **PASS** |
| **BLOCKED-STOP** | Probe must not disturb the trajectory it measures | The probe reseeds from the plateau and DISCARDS both results (never fed back). Read-only; not hit. | n/a |

## What was built

### The two-reseed design-space probe (the instrument)

When `draft_use_design_trigger` is armed, after a rung's loose plateau the driver takes
a probe from the rung's converged loose design `ρ_plateau`
(`variant.optimization.physical_density`). It runs TWO memoryless one-step **OC**
reseeds from the SAME plateau:

- `ρ_loose` — one OC step whose FEA is solved at the trajectory's LOOSE tolerance,
- `ρ_tight` — one OC step whose FEA is solved at the exact cert tolerance (asserted).

The signal is the fraction of `ρ_plateau`'s solid voxels whose printed↔void
classification DIFFERS between `ρ_loose` and `ρ_tight`. Both reseeds share the same
warm-start inverse-filter and volume bisection, so that displacement — and the
OC-vs-MMA fixed-point mismatch — is COMMON to both and cancels in the diff. Only the
difference the FEA tolerance makes to the step direction survives. Escalate when the
flip exceeds `draft_escalation_design_flip` (default 0 = the measured floor).

Two dead ends found and recorded on the way to this construction:
- A naive "plateau vs one tight step" comparison carried the reseed/updater
  displacement as a **0.36 spurious floor** — it could not separate anything.
- An MMA probe was worse (fresh moving asymptotes make a large cold-restart move even
  at the optimum). OC is memoryless, which is why the two-reseed diff has a 0 floor.

The probe result is DISCARDED — never assigned back into `variant` — so it is read-only
with respect to the trajectory it measures. The BLOCKED-STOP condition does not arise.

### The exact-solve gate (D6, structural)

The probe's tight endpoint is `cg_tolerance == kCertTol`, asserted; the escalation
re-run leaves `cg_tolerance` untouched and asserts it. The gate never softens: every
accept/reject the driver makes rests on an exact solve, and the probe's loose companion
step is a *measurement*, never a certificate.

### Plumbing / observability

- `MinimizePlasticResult`: per-rung `draft_rung_probe_flip`, `draft_rung_probe_cg`
  (cost, D3), and the diagnostic `draft_rung_probe_tightmove` (plateau vs tight-step).
- `run_info.json` echoes `draft_use_design_trigger`, `draft_escalation_design_flip`,
  and the per-rung probe vectors (finalize-only, like `draft_rung_c_gap`).
- topopt-cli `draft` block: optional `use_design_trigger`, `escalation_design_flip`,
  `probe_iters`; parsed strictly. Absent → OFF → byte-identical.

## D1 — the non-separation, and its mechanism (the derail, handled)

### Reproduction posture

`configure_production_options` arms Active Domain (AUTO) since handoff 187 — a
deliberately non-bit-identical approximation — so Phase-1's pre-187 numbers do not
bit-reproduce under the production posture. The harness runs BOTH: AD-off
(`active_domain_band = 0`, Phase-1's exact solve) and AD-on (production). **AD-off
reproduces Phase-1's tight baseline to the digit: total_cg 95303.** Both Phase-1
counterexamples reproduce under AD-off, warm-start ON:

| loose | rung | gap | probe | truth (flip vs tight[i]) | probe fires? | gap fires (.02)? |
|---|---|---|---|---|---|---|
| 3e-1 | r2 | **0.03103** | 0.00000 | 0.0000 (0/12) | no | **YES (false +)** |
| 5e-1 | r1 | 0.00001 | **0.00000** | **0.1500 (3/20)** | **no (MISS)** | no |

grid 16×8×16, 1536 solid. The gap wanders 0.003–0.031 with no relation to the (mostly
zero) design divergence — exactly Phase 1's finding. The probe correctly refuses CE-2
(the gap's false positive) but also reads 0 on CE-1's genuine 0.15 divergence.

### Why the probe reads 0 on a genuine divergence (proven, not asserted)

`draft_quality_phase2_diag.cpp`, grid S, AD-off, warm ON, loose 5e-1:

1. **The diverged plateau is tight-STATIONARY.** Sweeping the probe budget
   1→4→16→64: `probe_flip` (loose-step vs tight-step) is **0.00000 at every budget**,
   and the diagnostic `tightmove` (plateau vs tight-step) decays 0.235→0.059→0→0 as OC
   re-converges TO the plateau. draft[1] is not an under-probed design; it is a genuine
   local tight optimum.
2. **The 0.15 lives in the PATH, not the plateau.** A full tight re-run from rung 1's
   ENTRY seed (escalate-every-rung): `flip(escalated[1] vs tight[1]) = 0.0000` (it
   lands at the tight design) while `flip(escalated[1] vs draft[1]) = 0.1765` (it moves
   the design away from draft[1]). The loose FEA steered the EARLY, moving iterations
   into a different basin; by the plateau the design has settled and a from-the-plateau
   probe — loose or tight — stays put.

So the only design-space signal that catches CE-1 is a full tight re-solve from the
entry seed, i.e. escalation itself (~100% of the rung) — not a cheap plateau probe. The
plateau probe is *structurally blind* to basin/path divergence. That is the D1 STOP.

### Why CE-1 was benign anyway

The terminal (shipped) rung's cross-run flip is **0.0000** across the whole sweep — the
mid-ladder basin excursion washes out, exactly as Phase 1 found, and the certified
compliance/margin are always solved tight (Phase-1 part c / B2). CE-1 is a valid
alternate optimum on a flat objective, not a solve error. There is nothing a trigger
needs to catch that exact certification does not already guarantee.

### Production posture (AD-on)

Under the armed active domain, NO rung diverges in classification across the whole
1e-3…5e-1 sweep (max truth flip 0.03 = 1 voxel, probe 0 throughout). The production
posture is robust; the probe correctly never fires.

## Retiring the 0.02 gap

The compliance gap is retired as a divergence detector: it FIRES on CE-2 (0.031 > 0.02)
where there is no divergence, and MISSES CE-1. It detects FEA-residual-induced
compliance error, which is uncorrelated with design divergence. Recommended default:
escalation DISARMED (`draft_use_design_trigger = false`, and do not rely on the gap);
the design-space instrument ships available but disarmed, sound for the one thing it
does — flag a genuinely NON-stationary loose plateau, a regime these grids do not
exhibit. Exact certification remains the safety.

## D4 — the win across scale

The win (summed trajectory CG, tight vs draft-1e-3, no escalation) is stagnation-
fraction dependent, and the trend is NOT a clean function of grid size — it depends on
how much a given grid stagnates under tight. Every row carries grid dims + solid count
(D7); the probe-cost column re-confirms D3 at scale.

**Production posture (AD-on, post-187):**

| grid (solved) | tight CG | draft CG | win | probe/ladder |
|---|---|---|---|---|
| S 16×8×16 (1536) | 74 791 | 39 231 | **1.91×** | 2.53% |
| M 24×8×24 (4608) | 187 696 | 45 707 | **4.11×** | 0.74% |
| L 32×16×32 | — | — | *(no tight baseline)* | — |

On these programmatic whole-domain-box grids the AD-on win GROWS from S to M (1.91→4.11)
because M stagnates far harder under tight (187 696 vs 74 791 CG) while draft stays
cheap. **AD-on has no L point**: on the 32×16×32 restricted domain the tight multigrid
stalls into Jacobi-CG and does NOT reach 1e-8 — the matfree solver throws rather than
return a bogus certificate. That is a real property of AD-on-at-scale on this grid
class, and it is exactly why the win-vs-scale trend is measured in the AD-off posture.

**Phase-1 posture (AD-off, the one that reliably converges and matches Phase 1):**

| grid (solved) | tight CG | draft CG | win | probe/ladder |
|---|---|---|---|---|
| S 16×8×16 (1536) | 95 303 | 45 982 | **2.07×** | 1.08% |
| M 24×8×24 (4608) | 143 837 | 39 728 | **3.62×** | 0.72% |
| L 32×16×32 (12288) | 246 667 | 161 365 | **1.53×** | 1.09% |

AD-off S and L reproduce Phase 1 **to the digit** (S: 95 303 / 45 982 / 2.07×; L:
246 667 / 161 365 / 1.53×), validating the harness. **Reading:** the trend is
NON-MONOTONIC — 2.07× (S) → 3.62× (M) → 1.53× (L) — because the win tracks each grid's
STAGNATION FRACTION, not its size: the thin 24×8×24 grid stagnates hardest under tight,
so it wins most. But across the size ENDPOINTS the win FALLS (S→L: 2.07→1.53), exactly
the downward direction Phase 1 flagged, and probe cost stays ~1% at every size (D3/D7
reconfirmed at scale, 0 probe flips throughout — the production design is robust).

**Bottom line on D4:** the win survives to 32³ (1.53×) but erodes at the size
endpoints and is dominated by a part's stagnation fraction, not its resolution. The
maintainer's real job is 128³, where the uncapped stagnating tight baseline exceeds a
6-P-core Mac's practical wall time (the L row already took minutes; AD-on 32³ does not
even converge) — so the 128³ win is a PREDICTION these grids bracket (1.5–4×), not a
measurement. Since the trigger does not ship as a safety (D1), this win is the sole
reason to arm draft, and whether it clears the bar at 128³ stays a per-part maintainer
call. This reconfirms Phase 1's headline honestly — the win
is real but scale-sensitive, and the direction depends on the stagnation fraction of
the specific part, which these grids bracket but the maintainer's 128³ real part
decides. Since the trigger does not ship as a safety (D1), the win alone governs whether
DRAFT is worth arming, and that remains a scale-and-part-dependent maintainer call.

## Files

Core: `pipeline.hpp` (options + result vectors), `minimize_plastic.cpp` (the two-reseed
probe + design-trigger decision, exact-solve asserts), `observability.hpp`/`.cpp`
(echo + serialize), `run_job.cpp` (build/finalize + job→options), `job.hpp`/`job.cpp`
(draft block parse). Harnesses (core/tests/harness/, not in CTest):
`draft_quality_phase2_probe.cpp`, `draft_quality_phase2_diag.cpp`,
`draft_quality_phase2_scale.cpp`, `run_d5_identity.sh`. Reproduction: the evidence
`BUILD.md`.

## What a Phase 3 would need (if pursued)

The only reliable divergence detector is escalation itself (a tight re-run from the
entry seed). If the win ever justified a safety belt, the honest options are: (a) always
escalate the gray mid-rungs (correctness over win, the conservative posture Phase 1
already documented), or (b) a MID-trajectory tight probe taken BEFORE the basins settle
— but that disturbs the trajectory it measures (the BLOCKED-STOP hazard) or doubles it.
Neither is a cheap plateau probe. The stronger conclusion from this work: on these
grids the divergence is benign and exact certification suffices, so no escalation
trigger is warranted at all.
