# The engagement gate on a REAL production ladder

`topopt-cli run ladder32.json` — the maintainer's own job shape, and the exact
fixture PR 273 used to attribute the missing 410 s: `l-bracket.step` at
resolution 32 inside a whole-domain design box (80 x 55 x 70 mm), production
ladder [0.68, 0.52, 0.38, 0.26], `simp.max_iterations` 16, full production
posture. Multigrid BUILDS and then stagnates, so most solves are the plain
Jacobi fallback — the state this task exists for.

`cli_ladder32_iterations.csv`, rung 0. The two columns this task adds,
`geneo_burn` and `geneo_threshold`, ARE the decision:

| it | cg_iters | mg | action | N_t | burn | threshold | what the gate did |
|---:|---:|---:|---:|---:|---:|---:|---|
|  1 |     88 | 1 | 0 |   0 |    0 |    0 | multigrid carried — GenEO cannot act |
|  2 |     47 | 1 | 0 |   0 |    0 |    0 | multigrid carried |
|  3 |  1,200 | 0 | 3 | 724 |  500 |    0 | no basis -> PR 248's 500 trigger -> BUILD |
|  4 |  2,805 | 0 | 5 | 724 | 2805 | 3348 | **DECLINED** — 2,805 < 3,348, finished plain |
|  5 |    289 | 1 | 0 |   0 |    0 |    0 | multigrid carried |
|  6 | 10,736 | 0 | 2 | 724 | 3348 | 3348 | **ENGAGED** — burn reached the threshold |
|  7 |  2,595 | 0 | 5 | 724 | 2595 | 3848 | **DECLINED** |
|  8 |  3,886 | 0 | 3 | 658 | 3848 | 3848 | degradation REBUILD, cleared both bars |
|  9 |  2,259 | 0 | 5 | 658 | 2259 | 5240 | **DECLINED** |
| 10 |  1,760 | 0 | 5 | 658 | 1760 | 5240 | **DECLINED** |
| 11 |  9,477 | 0 | 2 | 658 | 5240 | 5240 | **ENGAGED** |
| 12 |  5,782 | 0 | 3 | 723 | 5740 | 5740 | REBUILD |
| 13 |  7,557 | 0 | 2 | 723 | 7270 | 7270 | **ENGAGED** |
| 14 |  5,826 | 0 | 5 | 723 | 5826 | 7770 | **DECLINED** |

## The whole run: 64 iterations, 61 of them latched

| | |
| --- | ---: |
| iterations | 64 (rungs 0-1; the run then hit a PRE-EXISTING abort, below) |
| Jacobi-fallback rows (GenEO can act) | 61 |
| **DECLINED** (action 5) | **50** — median 2,839 CG, range 259-15,919 |
| ENGAGED (action 1/2) | 5 — median **10,736** CG, range 7,557-17,617 |
| BUILT / REBUILT (action 3) | 6 — median 7,343 CG |

**The gate declined 50 of 61 fallback solves and engaged on the hardest 5** — a
median of 2,839 CG on the ones it turned down against 10,736 on the ones it took.

Solver phase totals over those 61 fallback rows:

| phase | wall | share |
| --- | ---: | ---: |
| `cg_ms` | 2,511.1 s | 61.7 % |
| `geneo_setup_ms` | 513.3 s | 12.6 % |
| `geneo_apply_ms` | 158.3 s | 3.9 % |
| `recycle_ms` | 883.8 s | 21.7 % |
| **GenEO total** | **671.6 s** | **16.5 %** |

**PR 273 measured GenEO at 80.7 % of a latched iteration on this exact fixture
and job (coarse setup 54.7 % + correction 26.0 %). It is now 16.5 %** — and most
of what remains is the six basis BUILDS, which PR 248's trigger governs and this
task did not touch.

## Two caveats a reader must hold

**The run ABORTED, and not because of this change.** After rung 1 it died with
`recommend_settings: worst_case_stress_margin must be finite and >= 0` — an
ultra-dilute whole-domain design carries no stress, so its margin is +inf and the
whole CLI run dies instead of that rung being rejected. PR 273 hit exactly this
and verified it on a pre-instrumentation binary; it is item 5 on that handoff's
"what to do next" list and is still open.

**A consequence worth knowing:** `run_info.json`'s lifecycle counters and the
`geneo_decisions` event log are written by a finalize block that an aborting run
never reaches, so on THIS run they read zero. The per-iteration columns above are
written and flushed row by row, so they survive the abort intact. That is the
argument for having both surfaces rather than one. `cli_1rung_run_info.json` is
the same job cut to a single rung so it COMPLETES, and carries the populated
decision log.

**This is the discrimination the task asked for, solve by solve on a real job.**
The ~1,700-2,800-iteration solves pay GenEO NOTHING — no refresh, no coarse
correction, no 38 s rebuild. The ~9,500-10,700-iteration solves are still
rescued. Nothing about the decision is a heuristic guess: iteration 4's threshold
of 3,348 is exactly `2 x 724 + 500 + 2 x (1200 - 500)`, the measured all-in price
of the armed alternative from the solve that built the basis.

## The honest limitation this trace shows

The threshold RATCHETS: 3348 -> 3848 -> 5240 -> 5740 -> 7270 -> 7770. Each
degradation REBUILD re-measures the armed cost, and a rebuild that fires at a
high burn records that burn as the armed alternative's "plain leg" — but the
burn is a property of the GATE POLICY, not of the armed alternative. By
iteration 14 the gate declines a 5,826-iteration solve that GenEO might well
have won.

The direction is CONSERVATIVE (fewer engagements, never more), so it cannot
reintroduce the tax, and the rescue still fires three times here. The obvious
tightening is to price the plain leg at `min(engaged_burn, kGeneoTriggerIters)` —
the armed alternative's INTRINSIC plain leg is the trigger burn, not whatever
the gate made this solve burn. That is a one-line change and it is NOT made
here: it changes a solver default, and re-validating it needs the full AA1/AA2/AA3
battery, which is its own task. Named in the handoff as the first follow-up.
