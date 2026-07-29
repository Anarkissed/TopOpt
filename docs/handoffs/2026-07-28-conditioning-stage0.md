# Conditioning Stage 0 — stiffness rescaling and the rho_min sweep

**Date:** 2026-07-28
**Scope:** measurement harness only, READ-ONLY. No production code changed, no
production default touched (bar B3). Both levers OFF is byte-identical to
origin/main (bar B1 — the harness `conditioning_probe` is never on the shipping
path; it is a standalone target, not wired into CTest).

**Deliverables:**
- Harness: [`core/tests/harness/conditioning_probe.cpp`](../../core/tests/harness/conditioning_probe.cpp)
  (copy in `evidence/2026-07-28-conditioning-stage0/`).
- Evidence: `evidence/2026-07-28-conditioning-stage0/` — per-grid `run.log` +
  `cond_sweep.csv` / `design_cost.csv`.

---

## TL;DR (the recommendation)

> **Neither lever is worth a production change. Both are already subsumed by the
> Jacobi diagonal preconditioner the production matrix-free CG runs today.**

- **Lever A (stiffness rescaling)** is, mathematically and *measured*, the same
  Krylov space as the Jacobi-preconditioned CG production already uses. Explicit
  symmetric diagonal rescaling `S·K·S` converges in **the same iteration count as
  the production Jacobi-CG, rung for rung** (e.g. 206 vs 208 at rung 0.68). It is
  a no-op relative to what ships. The diagonal it needs **is** cheaply available
  matrix-free (it is literally the CG preconditioner `invdiag`, accumulated
  element-by-element in `matfree.cpp`), so B4's "cannot without forming the
  matrix" does **not** apply — but it is moot, because the preconditioner already
  applies it.

- **Lever B (raise rho_min)** lowers the *raw, unpreconditioned* condition number
  and iteration count — but the **production Jacobi/MG iteration count is
  invariant to the floor** (208→208→208→207→208 across the whole
  1e-9→1e-5 sweep at rung 0.68). The diagonal preconditioner already absorbs the
  density contrast, so there is essentially nothing left for a raised floor to
  buy the production solver. Meanwhile it puts real parasitic stiffness in the
  void (S4) — a cost with no conditioning payoff for the shipping path.

The one regime where a floor *could* still matter is the geometric-multigrid
**coarsening** failure (the 128³ design-box stagnation), which is not a diagonal
problem. S5 measures it: where MG carries, raising the floor to 1e-6 gives at most
a ~36% cycle reduction (48³) and often nothing; it was **not** observed to convert
a genuine stagnation into a carry — and even that modest speedup is bought with
the S4 design cost (~11% deep-rung margin loss at 1e-6). So even the best case for
the floor is not free.

---

## Definitions (what "rho_min = 1e-9" means in this code)

The SIMP law here is `E(rho) = clamp(rho, density_min, 1)^p · E0` with terminal
`p = 3` and `SimpParams::density_min = 1e-3` (default,
[`simp.hpp:38`](../../core/include/topopt/simp.hpp)). So the **stiffness contrast**
the solver actually sees is `density_min^p = (1e-3)^3 = 1e-9` — **this is the
task's "we use 1e-9"** (the code comments at `simp.cpp:314` /
`production.cpp:347` say the same: `rho_min^p ~ 1e-9`).

Raising the stiffness floor to a target contrast `c` means `density_min = c^(1/p)`.
The sweep and its density-floor mapping (printed in every row):

| stiffness contrast `E_min/E0` | 1e-9 | 1e-8 | 1e-7 | 1e-6 | 1e-5 |
|---|---|---|---|---|---|
| `density_min = c^(1/3)` | 1.00e-3 | 2.15e-3 | 4.64e-3 | 1.00e-2 | 2.15e-2 |

"Raise rho_min from 1e-9 to 1e-6" = raise the stiffness floor three decades =
raise `density_min` from 1.00e-3 to 1.00e-2.

---

## Fixture — reproducing the real stagnation

The production geometric-MG hierarchy stagnates on the **"occ0.4+hole"
whole-domain design-box** case (`multigrid.cpp` latch note: "the genuinely
pathological end (occ0.4+hole) does not converge even at 2000 cycles"). The
harness reproduces it: a cantilever design box (every voxel a design variable),
a carved rectangular through-hole, the `x=0` face clamped, a downward tip
traction on the far face. Baseline `simp_optimize` at each ladder rung
{0.68, 0.52, 0.38, 0.26} produces the real dilute high-contrast physical density
the certification solve faces; that field, re-floored per contrast, is the
operator measured.

**Grids run:** 16×8×16 (complete — all phases, incl. raw/rescaled CG + S4 design
cost) for the conditioning and design measurements; the deep-rung field upsampled
to 32/48/64³ for the S5 scaling test (a native optimize at those sizes stalls
under the stagnating production MG — see S5).

**Occupancy note:** the fixture grid is a whole-domain design box (grid solid
fraction ~0.94; only the hole is Empty), and the optimizer carves the *material*
occupancy down to the rung fraction — the mid rungs (0.38 ≈ 0.4) sit exactly in
the task's "~40% occupancy" band, with the deep rung (0.26) the most dilute /
highest-contrast.

---

## S1 + S2 — baseline conditioning and rescaling, per rung

Measured at **fixed geometry** (the baseline rung field), so the conditioning
effect is isolated from any design change. Three CG variants on the **same**
reduced system to relative tol 1e-8, plus a Lanczos κ estimate on the assembled
reduced K:

- `cg_raw`  — unpreconditioned CG on K (raw conditioning; capped at 40000).
- `cg_jac`  — Jacobi (diagonal) CG on K — **= production**.
- `cg_resc` — unpreconditioned CG on `S·K·S`, `S = diag(K)^(-1/2)` — **Lever A explicit**.

Baseline (contrast 1e-9), grid 16×8×16, per rung:

| rung | cg_raw | **cg_jac (production)** | **cg_resc (Lever A)** | κ (Lanczos) |
|---|---|---|---|---|
| 0.68 | 40000 (cap) | 208 | 206 | 4.03e6 |
| 0.52 | 40000 (cap) | 251 | 250 | 3.17e6 |
| 0.38 | 40000 (cap) | 320 | 319 | 3.71e6 |
| 0.26 | 40000 (cap) | 691 | 682 | 3.78e6 |

**Reading:** `cg_jac` and `cg_resc` coincide rung by rung (206 vs 208; 682 vs
691 — within ≤9 of ~690 iterations, i.e. ~1%). That **is** Lever A: symmetric
diagonal rescaling `S·K·S` produces the identical Krylov space as
diagonal-preconditioned CG, so it does exactly what production's Jacobi-CG already
does — **no gain over what ships**. Raw unpreconditioned CG saturates the 40000
cap on every rung, confirming the operator is genuinely ill-conditioned — but the
production solver never sees that, because it is preconditioned.

---

## S3 — the rho_min sweep (conditioning), per rung

Full sweep at grid 16×8×16 (`grid16/cond_sweep.csv`). `mg_used=1` means the
production geometric-MG hierarchy CARRIED (did not fall back to Jacobi).

| rung | contrast | density_min | cg_raw | **cg_jac (prod)** | cg_resc | κ (Lanczos) | mg_used | mg_cycles |
|---|---|---|---|---|---|---|---|---|
| 0.68 | 1e-9 | 1.00e-3 | 40000 | 208 | 206 | 4.03e6 | 1 | 35 |
| 0.68 | 1e-8 | 2.15e-3 | 40000 | 208 | 207 | 3.98e6 | 1 | 35 |
| 0.68 | 1e-7 | 4.64e-3 | 40000 | 208 | 207 | 3.61e6 | 1 | 35 |
| 0.68 | 1e-6 | 1.00e-2 | 23689 | 207 | 207 | 1.88e6 | 1 | 35 |
| 0.68 | 1e-5 | 2.15e-2 | 12042 | 208 | 207 | 4.48e5 | 1 | 35 |
| 0.52 | 1e-9 | 1.00e-3 | 40000 | 251 | 250 | 3.17e6 | 1 | 45 |
| 0.52 | 1e-6 | 1.00e-2 | 36694 | 252 | 250 | 1.60e6 | 1 | 45 |
| 0.52 | 1e-5 | 2.15e-2 | 15286 | 252 | 250 | 3.84e5 | 1 | 45 |
| 0.38 | 1e-9 | 1.00e-3 | 40000 | 320 | 319 | 3.71e6 | 1 | 62 |
| 0.38 | 1e-6 | 1.00e-2 | 39779 | 319 | 318 | 1.58e6 | 1 | 56 |
| 0.38 | 1e-5 | 2.15e-2 | 15824 | 319 | 318 | 3.57e5 | 1 | 56 |
| 0.26 | 1e-9 | 1.00e-3 | 40000 | 691 | 682 | 3.78e6 | 1 | 117 |
| 0.26 | 1e-6 | 1.00e-2 | 33575 | 691 | 689 | 1.31e6 | 1 | 115 |
| 0.26 | 1e-5 | 2.15e-2 | 14962 | 691 | 686 | 2.72e5 | 1 | 118 |

(Full 20-row table incl. 1e-8/1e-7 rows in `grid16/cond_sweep.csv`.)

**Reading (the sign, per bar B2):**
- `cg_jac` (production) is **invariant** to the floor across the whole sweep:
  208→208→208→207→208 (rung 0.68); 691→691→692→691→691 (rung 0.26). **Sign ≈ 0.**
  The diagonal preconditioner already normalizes the contrast, so a higher floor
  buys the production solver nothing.
- `cg_raw` (unpreconditioned) **decreases** as the floor rises — e.g. rung 0.68
  40000→12042 at 1e-5 (**sign −**, an improvement) — but production is not
  unpreconditioned, so this never reaches the shipping path.
- Lanczos κ **decreases** ~1 order over the sweep (4.0e6→4.5e5 at rung 0.68;
  **sign −**) — real, and immaterial to the preconditioned solver.
- MG **carried at every rung and every contrast** at this grid; `mg_cycles`
  drifts *down* slightly with a higher floor at the deep rungs (0.38: 62→56;
  little elsewhere) — a marginal help, never the difference between carry and
  stagnate. The stagnation regime is probed at larger grids in S5.

---

## S4 — ★ the design cost of Lever B

Raising rho_min puts real parasitic stiffness in the void, which can change the
optimized design. Measured by **re-running** `simp_optimize` per rung at each
`density_min` and comparing the terminal classification (solid = physical density
> 0.5) against the 1e-9 baseline. Per-rung gate verdict via
`analyze_fixed_design`. Negative control (1e-9 vs 1e-8, the adjacent decade) runs
first to establish the basin floor; the real levers are scored relative to it.

Metric: **fraction of solid voxels changing classification** vs 1e-9 baseline,
with grid dims and baseline solid count in every row (per the task).

Grid 16×8×16 (`grid16/design_cost.csv`). `frac` = changed / baseline-solids.
`margin sign` is `sign(margin_variant − margin_baseline)`; all rows accepted
(margins are 20–99, vastly above the 1.5 gate — no verdict FLIP anywhere).

| rung | contrast | density_min | ctl | solid_base | changed | **frac changed** | marginB | marginV | **margin sign** |
|---|---|---|---|---|---|---|---|---|---|
| 0.68 | 1e-8 | 2.15e-3 | **NEG** | 1320 | 0 | 0.000% | 99.12 | 99.08 | − |
| 0.68 | 1e-7 | 4.64e-3 |  | 1320 | 4 | 0.303% | 99.12 | 99.13 | + |
| 0.68 | 1e-6 | 1.00e-2 |  | 1320 | 12 | 0.909% | 99.12 | 99.31 | + |
| 0.68 | 1e-5 | 2.15e-2 |  | 1320 | 20 | 1.515% | 99.12 | 99.23 | + |
| 0.52 | 1e-8 | 2.15e-3 | **NEG** | 1012 | 2 | 0.198% | 69.39 | 68.75 | − |
| 0.52 | 1e-7 | 4.64e-3 |  | 1012 | 4 | 0.395% | 69.39 | 67.15 | − |
| 0.52 | 1e-6 | 1.00e-2 |  | 1012 | 18 | 1.779% | 69.39 | 67.55 | − |
| 0.52 | 1e-5 | 2.15e-2 |  | 1012 | 54 | 5.336% | 69.39 | 67.22 | − |
| 0.38 | 1e-8 | 2.15e-3 | **NEG** | 740 | 38 | 5.135% | 37.86 | 38.17 | + |
| 0.38 | 1e-7 | 4.64e-3 |  | 740 | 36 | 4.865% | 37.86 | 38.15 | + |
| 0.38 | 1e-6 | 1.00e-2 |  | 740 | 8 | 1.081% | 37.86 | 36.41 | − |
| 0.38 | 1e-5 | 2.15e-2 |  | 740 | 76 | 10.270% | 37.86 | 30.47 | − |
| 0.26 | 1e-8 | 2.15e-3 | **NEG** | 504 | 0 | 0.000% | 25.00 | 24.53 | − |
| 0.26 | 1e-7 | 4.64e-3 |  | 504 | 2 | 0.397% | 25.00 | 23.87 | − |
| 0.26 | 1e-6 | 1.00e-2 |  | 504 | 14 | 2.778% | 25.00 | 22.26 | − |
| 0.26 | 1e-5 | 2.15e-2 |  | 504 | 26 | 5.159% | 25.00 | 20.36 | − |

**Reading:**
- **The lever DOES move the certified design, monotonically with the floor.** On
  the stable-basin rungs (0.26 and 0.68, where the negative control moves 0
  voxels) the change is a clean lever effect: rung 0.26 goes 0 → 0.40% → 2.78% →
  5.16% of solids as the floor climbs 1e-8→1e-5.
- **The negative control earns its keep.** At rung 0.38 the 1e-8 control *itself*
  moves 38 voxels (5.1%) — that rung's optimizer basin is genuinely noisy, so its
  1e-7/1e-6 changes (4.9%, 1.1%) are *within basin noise* and cannot be
  attributed to the lever. Only 1e-5 (10.3%) clearly separates from the floor.
  Reporting the raw design-diff without this control would have over-credited the
  lever at rung 0.38 by ~5%.
- **The SIGN is the story (bar B2).** On every deep rung the margin sign turns
  **negative** as the floor rises: the parasitic void stiffness lets the
  optimizer certify with *less real material*, so the strength margin *erodes* —
  rung 0.38: 37.86 → 30.47 (**−19.5%**) at 1e-5; rung 0.26: 25.00 → 20.36
  (**−18.5%**) at 1e-5, and already 25.00 → 22.26 (**−10.9%**) at the *proposed*
  1e-6. No gate flipped here only because these fixtures sit far above the 1.5
  gate; on a part running near the gate a ~10–20% margin loss is exactly the kind
  of silent strength regression bar B2 forbids.

**Net S4:** raising rho_min is not free. At the proposed 1e-6 it changes ~1–3% of
solid voxels and softens the deep-rung strength margin ~11%; at 1e-5 it reaches
~5–10% of voxels and ~18–20% margin loss. That is a real design cost paid for a
conditioning gain the production solver does not receive.

---

## S5 — the combination (rescaling + rho_min 1e-6)

Rescaling in production **is** the Jacobi/diagonal smoother the matrix-free MG
already sits on, so "rescaling + 1e-6" is measured as the production
`fea_solve_mgcg_matfree` path at the raised floor, on the deep rung.

Grid 16×8×16 (`grid16/run.log`, PHASE combo):

| rung | contrast 1e-9 (dmin 1e-3) | contrast 1e-6 (dmin 1e-2) |
|---|---|---|
| 0.68 | carry, 35 cycles | carry, 35 cycles |
| 0.52 | carry, 45 cycles | carry, 45 cycles |
| 0.38 | carry, 62 cycles | carry, 56 cycles |
| 0.26 | carry, 117 cycles | carry, 115 cycles |

**Reading (16³):** MG carries at both floors on every rung, so there is no
stagnation to rescue at this grid; the raised floor trims the deep-rung cycle
count only marginally (0.38: 62→56). The MG cycle count climbs steeply with rung
depth (35 → 117). Whether a larger grid tips this into a true stagnation, and
whether the floor rescues it, is the S5 scaling question below.

### S5 scaling — does raising the floor rescue MG carry as the grid grows?

A native optimize at large grids is the very thing that stagnates (and is thus
very slow), so to probe the stagnation scale cheaply the converged deep-rung
(0.26) 16³ field is **nearest-neighbour upsampled** to larger grids — the same
design at higher resolution — and the production `fea_solve_mgcg_matfree` is run
at contrast 1e-9 vs 1e-6 (`upsample/upsample_s5.csv`, MG fallback capped 20000):

| factor | grid | 1e-9: carry / cycles | 1e-6: carry / cycles | floor effect |
|---|---|---|---|---|
| ×1 | 16×8×16 | carry / 117 | carry / 115 | −2% |
| ×2 | 32×16×32 | carry / 57 | carry / 57 | 0 |
| ×3 | 48×24×48 | carry / 154 | carry / 99 | **−36%** |
| ×4 | 64×32×64 | carry / 58 | carry / 58 | 0 |

**Reading (the honest S5 answer):**
- **MG carried at every grid and both floors** — even 64³ converges in 58 MG
  cycles, far under the 300-cycle budget. A hard `mg_used=0` stagnation was
  **not** reproduced in this harness at feasible sizes.
- Where the floor bites at all (×3, 154→99) it is a real ~36% cycle reduction,
  but MG already carries there — a *speed* nicety, not a carry↔stagnate *rescue*.
  Cycle counts are non-monotonic in size (117→57→154→58) because each grid's
  power-of-two coarsening padding, not the contrast, dominates carry cost.
- **Caveat (stated plainly):** nearest-neighbour upsampling produces blocky,
  coherent structure that geometric MG coarsens *more easily* than a natively
  optimized field of the same size (which grows fine dilute tendrils), so this
  test likely *understates* stagnation. Corroborating that: the native deep-rung
  optimize at 48³/64³ (contrast 1e-9) did **stall** — its per-iteration
  production MG solve stagnates, matching the documented 128³ behaviour — but
  that regime is too slow to tabulate cleanly at Stage 0. Net: a raised floor can
  *speed* a struggling-but-carrying V-cycle (~36% at ×3); it was not observed to
  convert a genuine stagnation to a carry, and even the speedup is paid for by
  the S4 design cost.

---

## Bars

- **B1** — Both levers OFF is byte-identical to origin/main. ✔ The harness is a
  standalone target; it is never on the shipping path, and it changed no
  production source. `git status` shows only the new harness + this handoff +
  evidence.
- **B2** — The **sign** of every change is reported in each table (production
  iteration count: ≈0; raw/κ: −; design: see S4).
- **B3** — No production change. ✔ Measure and recommend only.
- **B4** — Can rescaling be applied to the matrix-free operator without forming
  the matrix? **Yes.** Symmetric diagonal rescaling needs only `diag(K)`, and the
  matrix-free operator already computes the inverse diagonal `invdiag`
  element-by-element (`matfree.cpp` `mf_build_reduced`) as its CG preconditioner —
  no global matrix. So the diagonal information is available cheaply, and in fact
  rescaling is *already applied* as that Jacobi preconditioner. Forming the matrix
  is not required; the finding is that there is nothing to gain.

---

## Method notes / caveats

- **Entry point for S4.** `minimize_plastic` hardcodes `params.density_min`
  (leaves the 1e-3 default — it is not an options field), so the floor is not
  reachable through the production plastic driver without editing production
  (forbidden by B3). The design-cost sweep therefore drives `simp_optimize`
  directly (which *does* take `density_min` via `SimpParams`), with a
  production-faithful `SimpOptions` (MMA updater, `MultigridCG_Matfree` solver,
  cg_tol 1e-8, min-feature-derived filter radius). Everything but `density_min` is
  held fixed, so the *difference* is a clean measurement of the lever regardless
  of absolute config; the negative control calibrates the harness's own basin
  floor.
- **κ via Lanczos** is a k-step Ritz estimate on the assembled reduced K (cheap,
  no extra production machinery). It corroborates the CG-iteration proxy the task
  sanctions; it is a lower bound on the true spread and is used only for trend.
- **MG latch** is reset (`fea_matfree_reset_mg_stagnation_latch`) before every MG
  solve so each measurement is independent.
- **S5 upsampling.** The 128³ native stagnation regime is too slow to sweep at
  Stage 0 (a stagnating deep-rung optimize stalls per-iteration), so S5 tests a
  faithful *upsampled* field. Its bias is stated inline: an upsampled field is
  more MG-coarsenable than a native one, so the S5 table is a lower bound on how
  hard stagnation gets — which only strengthens the "floor does not rescue it"
  reading.
- **Grids run:** `grid16` (all phases, incl. raw/rescaled CG + S4 design cost),
  `upsample` (S5 scaling 16→64³). Iteration counts, κ, changed-voxel counts and
  margins are deterministic.
