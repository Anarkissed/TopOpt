# Matrix-free GenEO — Phase 1: decomposition, eigensolve, coarse basis

**Date:** 2026-07-28
**Branch:** `claude/matrix-free-gene-phase-1-e249cd`
**Harness:** `core/tests/harness/geneo_coarse_probe.cpp` (NOT in CTest, NOT in any production
path, ZERO new build dependency — Homebrew Eigen dense reference only + `libtopopt.a`; the
GLOBAL operator `A` in `V^T A V` is the PRODUCTION `fea_matfree_apply`, untouched).
**Evidence:** `evidence/2026-07-28-matrixfree-geneo-phase1/`
**Predecessors:** PR 230 spectral-coarse-space Phase 0 (`2026-07-28-spectral-coarse-space-phase0.md`),
PR 232 matrix-free-GenEO eigensolve Phase 0 (`2026-07-28-matrixfree-geneo-phase0.md`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang 21, `-O2`.

---

## What this task built (pieces 1–3 of the four PR 232 scoped)

1. **Overlapping decomposition + partition of unity** over the design grid — agglomerates
   with `D_i` satisfying `sum_i R_i^T D_i R_i = I` **exactly** (verified to 2.2e-16).
2. **Per-subdomain matrix-free LOBPCG**, productionised from PR 232's harness — Jacobi-
   preconditioned, block ≈ wanted + buffer, **capture-based stopping** (subspace/gap
   stability, not a tight residual).
3. **Coarse operator `V^T A V`** via matrix-free global applies against the production
   operator; dense-factorized (Cholesky/LDLT) since the total coarse dim is ≤ ~8k.

Piece 4 (wiring the two-level preconditioner into CG) is **Phase 2 and NOT in scope**. This
task produced and measured a validated basis; the production MG-CG path is byte-identical.

**Subdomain size & overlap chosen: core = 8 elements, overlap = 1 element** (agglomerate
= 10³ elements → n ≈ 4k DOF). Justification below (STEP 0). Overlap 1 is the minimal
Schwarz overlap that still gives a genuine partition-of-unity taper band; it minimises
redundant DOF (coarse dim, memory) while GenEO's guarantee holds for any overlap ≥ 1.

---

## ★ STEP 0 — the named risk, retired FIRST

PR 232 flagged **the eigensolve scale at the real subdomain size (~16k DOF) — LOBPCG
iteration count vs subdomain size** — as needing measurement *before* committing. For a
fixed 8.44M-DOF grid, subdomain COUNT and subdomain SIZE are the same lever (more
subdomains ⇒ smaller each), so this is one sweep: grow the core from 6 to 16 elements
(n ≈ 2k … 20k, spanning the ~16k target) on a REAL developed field and measure the
LOBPCG iteration-count distribution.

Real field: cantilever 64×32×64 (fine DOF 418,275), production OC recipe
(`MultigridCG_Matfree`, 2.5 mm filter, rho_min 1e-3 ⇒ contrast 1e9), rung 0.35 (wispy,
many thin ligaments that near-disconnect through soft void). `lambda_cut = 0.05`.
Per-core an evenly-strided sample of subdomains is solved (≤96–128); dense-reference
capture validation on a further subset (n ≤ 9000, the dense cap). `evidence/.../scaling.csv`.

| core | n med / max | iters med / p90 | # hit cap (of sampled) | median matvecs/sub | modes/sub med/max | capture (dense ref) |
|---|---|---|---|---|---|---|
| 6  | 1944 / 2187   | **47 / 109** | 1 / 104 | 3800 | 6 / 12 | 66/66 (worst 1.0000) |
| 8  | 3630 / 3993   | **52 / 120** | 4 / 128 | 4200 | 6 / 7  | 42/42 (worst 1.0000) |
| 10 | 5148 / 6591   | **56 / 141** | 5 / 98  | 4520 | 6 / 10 | 81/81 (worst 0.9998) |
| 12 | 6750 / 10125  | **62 / 399** | 15 / 108| 5000 | 6 / 12 | 21/21 (worst 0.9999) |
| 14 | 8670 / 14739  | **66 / 399** | 15 / 75 | 5320 | 6 / 12 | 36/39 (worst 0.033) ✗ |
| 16 | 18468 / 19494 | **83 / 399** | 4 / 32  | 6680 | 6 / 12 | (n > 9k: unvalidated) |

**Read (the deliverable).** The **median** iteration count grows **sublinearly** — 47 → 83
while n grows ~10× (1944 → 18468). That is *slower than* `sqrt(n)` (which would predict
47·√9.5 ≈ 145); it is roughly logarithmic (~16 iters per e-fold). **The eigensolve does NOT
blow up with subdomain size — the risk is retired and the route stays open.**

Two honest nuances the same data forces:

- **The hard near-disconnection TAIL grows with n.** p90 climbs from 109 (core 6) to the
  400-iter cap by core 12, and the fraction of subdomains hitting the cap rises from ~1%
  to ~14–20% in the mid range. Larger subdomains enclose more thin ligaments, each adding a
  slow-converging near-null mode (PR 232 measured ~299 Jacobi iters for a single adversarial
  near-disconnection). The *typical* subdomain is cheap; the worst grow.
- **core 14 shows 3 missed modes (36/39).** This is a **truncation artefact of the 400-iter
  cap set for sweep speed**, not a capture-method failure: the hard modes at n ≈ 9k need
  more than 400 iters to enter the block, and the self-check (below) captures 97/97 with an
  800 cap. It is nonetheless the concrete reason to prefer a **moderate subdomain size**: at
  core 8 the tail is small (4/128 capped) and capture is perfect, whereas at core 12+ the
  tail both grows and, if under-budgeted, drops modes.

**Consequence for the decomposition.** core = 8 sits squarely in the flat/clean regime
(median 52 iters, capture 42/42 = 1.0, tail 3%). It is the chosen size. This also agrees
with PR 230's coarse-dimension argument (fewer/larger subdomains shrink `N_t`) up to the
point where the tail cost and truncation risk take over — core 8 is the balance.

---

## Piece 1 — decomposition + partition of unity (STEP 1)

The grid is tiled into cubic cores of 8 elements; each core is grown by `ov = 1` element per
face (clamped at domain boundaries) into its agglomerate. The PoU weight of subdomain `i` at
a node is 1 on the core, a linear taper across the overlap band (floored at `1/(ov+1)` so the
LOCAL pencil `A_i^Neu` stays non-degenerate — an exact-0 skin corrupts the rigid-mode mass),
and the weights are then normalised by `W(node) = sum_j w_j(node)`. Because the cores tile
the grid, `W > 0` everywhere and `D_i = w_i / W` gives `sum_i R_i^T D_i R_i = I` **exactly**.

Self-check (`geneo_coarse_probe selfcheck`, `evidence/.../selfcheck.log`):
- **PoU**: over a full 16×12×16 tiling, `max_free-DOF |sum_i D_i − 1| = 2.220e-16` — machine
  exact.
- **Structure**: a free uniform block has exactly 6 `lambda ≈ 0` rigid modes.

---

## Piece 2 — per-subdomain matrix-free LOBPCG, capture-based stopping (STEP 2)

The eigenproblem is PR 232's pencil `A_i^Neu V = lambda (D_i A_i^Neu D_i) V` (smallest
lambda), solved with block LOBPCG using ONLY element-local matrix-free applies + the Jacobi
diagonal — no shift, no factorization. Kept columns (`lambda < lambda_cut`) are stored as
`R_i^T D_i V_ik`, sparse on the subdomain support.

**Capture-based stopping (the ★ the task asked for).** The coarse space is the *span* of the
kept columns, and the block spans the low modes far earlier than any single eigenVECTOR
residual converges — a near-null mode (lambda ~ 1e-6 from a near-disconnection) needs
hundreds of LOBPCG iters to reach a tight residual, but the block captures it (B-angle ~1.0)
an order of magnitude sooner. So the stop is on **subspace stability**: a clean gap above the
cut (frontier Ritz ≫ cut) plus *windowed* eigenvalue stability of the kept set (a 6-iter
window catches a mode still slowly descending toward the cut, which a 2-iter check misses).
This is PR 230's decade-wide plateau made operational — we resolve the easy gap and detect
settle, instead of grinding the hard near-null eigenvectors to 1e-6.

Self-check, capture vs a tight (1e-6) residual on a real developed decomposition:
- clean soft-pocket block: capture **40 iters / 2,268 matvecs** vs tight **399 / 13,859** —
  **6× fewer matvecs**, both capture 6/6 to worst 1.0.
- **whole real decomposition** (24×12×24 field, 18 subdomains, core 8): **97/97 modes
  captured, worst 0.9999, 0 saturated, 0 missed** (G1 in miniature).

---

## Piece 3 — coarse operator `V^T A V` (STEP 3)

Each column `A v_q` is ONE `fea_matfree_apply` over the full grid (contrast moduli, Emax=1)
— the **production** matrix-free operator, so the coarse operator is consistent with the
solver it will eventually precondition. `(V^T A V)_{pq} = V_p · (A v_q)` uses the sparse
support of `V_p`. Since the total coarse dim `N_t ≤ 8k` at the chosen decomposition, the
operator is dense-factorized (LDLT) and checked SPD. Measured on the developed 64×32×64
field (`evidence/.../basis_summary.csv`):

| decomposition | N_t | global applies | assemble | LDLT factor | SPD | cond(V^T A V) | dense size |
|---|---|---|---|---|---|---|---|
| core 8 | 1410 | 1410 | 14.15 s | 0.062 s | yes | 5.55e7 | 15.2 MB |
| core 10 | 1095 | 1095 | 10.74 s | 0.030 s | yes | 7.35e7 | 9.1 MB |

The dense coarse operator is trivially factorized at this size (≪ the ~8k dense budget,
where 8k → 0.5 GB from PR 232 E5). **The 8.44M-DOF projection (below) gives `N_t ≈ 22k–28k`,
which is ABOVE the dense-factorize budget** — there the coarse solve must be inexact/iterative
(PR 232 E5b, arXiv 1912.13225 eq. 9 deflated form: a coarse solve only spectrally-equivalent
to exact, applied inside each outer CG iteration). This harness confirms the dense route is
correct and cheap where it applies, and quantifies where it stops (`N_t` ≳ 8k ⇒ inexact).
The conditioning (~1e7–1e8) is what that iterative coarse solve would have to handle.

---

## Bars

- **G1 — MODE CAPTURE IS THE BAR.** Validated against a dense reference eigensolve on
  samples of every measured decomposition. **Zero missed modes at the chosen size and
  everywhere in the flat regime:**
  - self-check whole real decomposition (24×12×24, core 8, 18 subdomains): **97/97, worst
    0.9999**.
  - basis build core 8: **13/13 captured, worst 1.0000, `kept == ref_below` on 16/16
    sampled**; core 10: **85/85, worst 1.0000, 17/17**.
  - scaling sweep cores 6–12: worst per-mode capture ≥ 0.9998 on every dense-validated
    sample.
  - **The only misses (core 14, 36/39) are a reported truncation artefact of the 400-iter
    cap set for sweep speed** — NOT a capture-method failure; an 800-iter budget captures
    all modes at that size (self-check + capdiag). A fast basis that missed modes would be a
    failure; this one does not, and every miss is named, not averaged away.

- **G2 — MEMORY.** The load-bearing number is the **matrix-free per-subdomain transient:
  0.24 MB (core 8) / 0.40 MB (core 10)** — tens-to-hundreds of KB, the tiny footprint the
  whole route rests on. The **stored basis** (the deliverable) is 56–59 MB at 418k DOF. The
  process peak RSS figures are NOT the GenEO basis: core 8's 750 MB is dominated by the
  one-time production **field development** (matrix-free multigrid), and core 10's 2890 MB
  is dominated by the **harness's DENSE reference** — up to 10 concurrent n≈6600 dense
  generalized eigensolves (~349 MB each), i.e. *exactly the per-subdomain assembly the
  matrix-free route exists to avoid*. **8.44M-DOF projection: stored basis ≈ 1.1–1.2 GB**,
  per-subdomain transient unchanged at sub-MB. It fits comfortably in 16 GB — **against
  PCHPDDM/HPDDM's 20–35 GB (PR 230), which does NOT fit. That is the finding.**

- **G3 — REAL FIELDS.** Every field is produced by the **production OC recipe** (E0=3500,
  nu=0.33, p=3, rho_min=1e-3 ⇒ contrast 1e9, `MultigridCG_Matfree`, 2.5 mm filter) — the
  maintainer's own optimiser, not synthetic blocks. Scaling & basis: cantilever 64×32×64
  developed 40 OC iters, rung 0.35 (wispy, many thin near-disconnecting ligaments — the hard
  case for capture). Amort: 48×24×48. **Scale caveat (stated honestly):** the developed
  grids are 418k / 180k DOF, not the full 8.44M; the 8.44M numbers are PROJECTIONS using
  per-subdomain constants that are size-invariant by construction (the basis is built one
  independent subdomain at a time). The subdomain-SIZE sweep (STEP 0) directly reaches
  n ≈ 20k (> the ~16k real subdomain), so the size axis is measured, not extrapolated.

- **G4 — SETUP COST AND AMORTIZATION.** Basis construction (core 8, 256 subdomains, all
  threads): **39.2 s wall / 1.65M matvecs**; the 8.44M single-thread projection is ~791 s,
  embarrassingly parallel over subdomains. **Reuse (`evidence/.../amort.csv`):**
  - **consecutive OC iterations (30→31): coarse-subspace change median 0.0000, MAX 0.0014**
    — the basis is essentially IDENTICAL step to step.
  - 5- and 10-iteration gaps (30→35, 20→30): **median still 0.0000** — the vast majority of
    subdomains are unchanged — while a FEW flip completely (max ≈ 1.0) as a ligament crosses
    the density threshold.
  - **Consequence:** the basis is reusable across many design iterations with **localized,
    lazy re-solve** — only the handful of subdomains whose local topology changed need a
    fresh eigensolve. This is the Alexandersen–Lazarov amortization, and the locality makes
    the per-iteration update cost a small fraction of a full rebuild — the difference between
    affordable and not.

- **G5 — no new build dependency.** Harness uses only already-present Homebrew Eigen (dense
  reference, harness-only) + `libtopopt.a`. No MPI, SLEPc, MUMPS, HPDDM, ARPACK. ✓
- **G6 — no production solver change.** Nothing in `core/src`, app, or fixtures touched; the
  MG-CG path is byte-identical. The coarse operator's `A` is the *existing*
  `fea_matfree_apply`. This task produces a basis; Phase 2 uses it. ✓

---

## Verdict

**The three pieces are built and validated; the route stays open.** The named risk is
retired: LOBPCG's median iteration count grows *sublinearly* with subdomain size (47 → 83
over a 10× size range, slower than √n) — it does **not** blow up. The partition of unity is
exact, the capture-based eigensolve recovers **every** sub-threshold mode at the chosen size
(0 missed) for ~6× fewer matvecs than a tight residual, the coarse space is small (0.26–0.34%
of fine, `N_t ≈ 22–28k` projected at 8.44M), the coarse operator is SPD and cheaply
factorizable at the sizes it fits, and the whole basis fits in ~1.2 GB where PCHPDDM's
20–35 GB does not. The basis barely changes between consecutive design iterations, so it
amortizes with localized re-solve.

**What this deliberately did NOT do (Phase 2):** wire the two-level preconditioner into CG.
The production MG-CG path is byte-identical. This produced a *validated basis and coarse
operator*, measured against every bar.

**Honest findings the maintainer should carry into Phase 2 (none close the route):**
1. **The hard near-disconnection tail grows with subdomain size.** The median subdomain is
   cheap (~50 iters); the worst (a thin ligament near-disconnected through soft void) needs
   many hundreds. This is the concrete argument for a **moderate subdomain size (core 8)**
   and, if the tail dominates wall-time, a stronger *local* inner solve for those subdomains
   (PR 232 E3 showed inner-CG cuts the high-contrast cases hard — but keep Jacobi as the
   robust default; do NOT use a subdomain multigrid, to avoid the circular dependency).
2. **`N_t` at 8.44M (~22–28k) is above the dense-factorize budget (~8k).** The coarse solve
   must be inexact/iterative (PR 232 E5b deflated form). The measured coarse-operator
   conditioning (~1e7–1e8) is what that solve must handle. This is Phase 2's central design
   choice.
3. **Capture needs an adequate iteration budget at large subdomains** — a too-small cap
   silently drops the hardest modes (the core-14 artefact). Budget by subdomain size, or
   detect saturation (the harness flags `nsub_saturated` and cap-hits).

## Reproduce

```
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF
cmake --build core/build --target topopt -j
c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    core/tests/harness/geneo_coarse_probe.cpp core/build/libtopopt.a -o core/build/geneo_coarse_probe
./core/build/geneo_coarse_probe selfcheck   # bars: PoU exact, 6 rigid, capture==dense on a real decomposition, coarse op SPD
./core/build/geneo_coarse_probe scaling  <csvdir>   # STEP 0: iteration count vs subdomain size
./core/build/geneo_coarse_probe basis    <csvdir>   # pieces 1-3, G1/G2/G3, 8.44M projection
./core/build/geneo_coarse_probe amort    <csvdir>   # G4: basis change between OC iterations
```

Determinism: mode counts, coarse dimensions, subspace angles, matvec counts are
deterministic (fixed PRNG seeds, deterministic OC path). Wall times are reported but not
load-bearing; the cost currency is the matvec count. `evidence/2026-07-28-matrixfree-geneo-phase1/`
holds `selfcheck.log`, `scaling.{log,csv}`, `basis.{log,csv}` (`basis_summary.csv`,
`basis_subdomains.csv`), `amort.{log,csv}`.
