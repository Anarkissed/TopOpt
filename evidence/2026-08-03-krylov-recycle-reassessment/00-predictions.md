# Predictions, recorded BEFORE any measurement on this branch

Task `krylov-recycle-reassessment`. Written after reading `recycle.hpp` /
`recycle.cpp` / both call sites and handoffs 133, 248 (`2026-07-28-deflation-phase0`
/ `2026-07-29-geneo-arming`), 273 (`iteration-phase-timing`), 275
(`geneo-standing-probe`) and 278 (`geneo-disarm`) — and before running a single
measurement. Graded in the handoff, whether or not it flatters me.

## The structural claim I expect to be able to make (read from source, not measured yet)

`mf_mgpcg` constructs its `RecycleSession` with `allowed = rc_wrap_multigrid()`,
which production pins **false** (`production.cpp:544`). With `allowed == false`
the session returns from its constructor before `begin()` — no state touched, no
matvecs, no allocation. So:

> **The recycler's entire bill is confined to the plain-Jacobi fallback path.**
> On a solve that multigrid carries, recycling is not merely cheap — it is
> structurally absent, and the recycling-ON and recycling-OFF postures should be
> **bit-identical**, not merely close.

If that is right, the 30.3 % is not "30.3 % of a solve" in general; it is 30.3 %
of the *latched* solve, and the campaign's own direction (PR 273/278: fix the
multigrid, worth 0.45 s/solve) removes the cost without anyone touching
`recycle.cpp`. I predict AG1(b) confirms this as **bit-identity**, and I will
report it as a falsified prediction if any bit moves.

## Numbers predicted before measuring

| # | prediction |
|---|---|
| **AG1(a)** latched | Recycling ON cuts CG iterations **30–55 %** (handoff 133 measured 48.1 % at k=16 on the void-heavy ladder, and GenEO is no longer stealing the same modes). In **wall** it is much closer to a wash: I predict ON lands between **0.85x and 1.15x** of OFF, i.e. the honest verdict is "marginal", not "45 %". DOF-weighted work favours ON; wall may not. |
| **AG1(b)** healthy MG | **Bit-identical.** Zero recycle matvecs, `recycle_ms == 0`, identical CG counts, identical converged field to the last bit. |
| **AG1(c)** cert | The certification solve inherits a basis harvested from the *trajectory's* looser systems and from a *different tolerance*. I expect the basis to still help (the operator is the same design) but by **less than on the trajectory** — predicted **0–20 %** iteration cut, and a wall verdict inside noise. If the cert solve runs on the multigrid path it is bit-identical for the same reason as (b). |
| **AG2** phases | **`augment` — the per-iteration column work — is the largest phase on the latched path**, above `commit` and above the k setup matvecs. Arithmetic: augment streams ~2·k·n per CG iteration ⇒ ~16,000·n over a 500-iteration solve, against commit's ~2·(2k)²·n ≈ 2,048·n once, and setup's 16 matvecs. I predict augment ≥ 55 % of `recycle_ms`, commit 10–25 %, setup (matvecs + Cholesky) 15–30 %, observe < 5 %. **If commit dominates instead, the cheap lever is the cadence (AG4); if augment dominates, the cadence cannot help and only the dimension (AG3) or disarming can.** |
| **AG3** dimension | Unlike PR 275's W3 (GenEO's threshold, INERT), I expect the dimension to **actually trade**: iterations fall monotonically with k while per-iteration cost rises linearly in k, so wall should be **U-shaped** with a shallow optimum. I predict the wall optimum on today's posture sits **at or below k = 16** — most likely **k = 8** — because handoff 133 chose 16 in the GenEO-stacked posture where recycling only had to add value on top of a deflation that was already flattening the spectrum. |
| **AG4** cadence | `rc_cycle()` is **1** in production (never set away from its default), so **every** solve harvests, pays 16 setup matvecs and runs a Rayleigh-Ritz over 32 columns. Cadence 2 and 4 should cut the setup+commit part roughly in half and in quarter. But handoff 133 already measured a longer cycle and REJECTED it on iterations ("a 4-solve-old basis was worth almost nothing"). So I predict **cadence 2 is roughly neutral in wall and cadence 4+ loses**, i.e. the cheapest lever is probably not available. |
| **AG5** wrap-multigrid | Flipping it **true** on the healthy path should **regress** — handoff 133 §10's mechanism (the +1 spectral lift widens the spectrum when M is already strong) is a real argument, not a fitted one. Predicted: iterations flat-to-worse, wall **1.05–1.4x slower**, and a strictly positive `recycle_ms` where today there is exactly zero. |
| **AG6** recommendation | I expect to recommend **retune, not disarm**: keep recycling armed on the Jacobi fallback, lower `k`, and note that the whole line item disappears when multigrid is fixed. I will change this if AG1(a) shows ON losing in wall at every k. |
| **AG7** exactness | Worst relative displacement deviation ON vs OFF **≤ 1e-6** (both solves stop on the same relative-residual test at 1e-8; the additive correction is SPD so the fixed point is identical). Reruns **bit-identical**. |
| **AG8** | Stash-rebuild checksum identical; full ctest green. |

## What would change the recommendation

* If AG1(a) shows recycling ON **losing wall at k = 16 and at every smaller k**,
  the recommendation becomes **disarm** — flagged as a production-default change
  belonging to a follow-up, not to this task.
* If AG1(b) is **not** bit-identical, my structural reading of the `allowed`
  flag is wrong and every "it is free on the healthy path" statement must go.
* If `commit` rather than `augment` dominates AG2, the cadence becomes the
  cheap lever and AG4 turns from a formality into the recommendation.

## Host, recorded up front

Apple M2 Pro (10 cores), 16 GB, Apple clang `-O2`, Release, `TOPOPT_USE_OCCT=OFF`.
**The host is SHARED and heavily loaded for the duration of this task** — a
concurrent task owns the multigrid coarsening probe. Load average at the start of
measurement: **17.11** (1 min) on 10 cores. Every wall claim below therefore comes
from postures **interleaved inside one process in ABBA order** with medians
pooled; no wall number is ever taken from separately-run postures. Load is
re-recorded at the end of each bench.
