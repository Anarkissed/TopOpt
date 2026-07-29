# Matrix-free GenEO — Phase 0: can the local eigenproblem be solved WITHOUT shift-and-invert?

**Date:** 2026-07-28
**Branch:** `claude/geneo-matrix-free-eigen-e630d1`
**Harness:** `core/tests/harness/geneo_matfree_probe.cpp` (NOT in CTest, NOT in any production
path, ZERO new build dependency — Homebrew Eigen dense + `libtopopt.a`).
**Evidence:** `evidence/2026-07-28-matrixfree-geneo-phase0/`
**Predecessor:** PR 230 spectral-coarse-space Phase 0 (`docs/handoffs/2026-07-28-spectral-coarse-space-phase0.md`)

---

## The one question, and the answer

PR 230 established that the GenEO coarse space is small in our regime and that the ONLY
architecture-preserving path is a bespoke matrix-free-fine / small-local two-level Schwarz.
The single unproven step was the eigensolve: GenEO needs the sub-threshold modes of a local
generalized eigenproblem, which are the HARD end for a Krylov eigensolver — the standard
route is shift-and-invert, a factorization we cannot afford at 8M DOF. LOBPCG needs only
`A·x`, `B·x` and a preconditioner, all of which we have matrix-free. **Does it recover ALL
sub-threshold modes at 1e9 contrast without shift-and-invert?**

**Answer: YES.** On a real OC-developed field at 1e9 (and 1e12) contrast, matrix-free block
LOBPCG recovers **every** sub-threshold mode — the 6 rigid-body modes AND the high-contrast
surcharge modes — to full subspace accuracy, using only element-local matrix-free applies
plus the existing Jacobi diagonal (or an inexact inner CG). No shift, no factorization of the
pencil, no assembled subdomain matrix. The route is **OPEN** for this hardware.

The task's premise that "smallest eigenvalues force shift-and-invert" is true for a generic
symmetric pencil, but does NOT bind here because of a structural fact this harness verifies:
the wanted modes are B-non-degenerate (see the crux below), so LOBPCG-smallest is well posed
on them without a shift.

---

## The crux that makes it work (grounded, then measured)

The pencil is exactly the task's (== arXiv **1912.13225** Def 3.1):

    (D_i A_i D_i) V = tau A_i^Neu V ,   coarse space keeps tau > threshold,

equivalently the SMALLEST eigenvalues of the reciprocal `A_i^Neu V = lambda (D_i A_i D_i) V`
(HPDDM/SLEPc's shift-invert target). The harness uses the standard partition-of-unity Neumann
variant `A_i := A_i^Neu`, so both operators are element-local matrix-free applies over the
agglomerate:

    A^Neu·x       = sum_{e in agg} E_e (Ke·x_e)          (Ke = one shared 24x24 hex8_stiffness)
    (D A^Neu D)·x = D∘( A^Neu·(D∘x) )                    (D = partition-of-unity diagonal)

**Key structure (verified by the dense reference):** `A^Neu` has an EXACT 6-dim rigid-body
kernel even under soft-void SIMP — a rigid motion is zero-strain in every element for ANY
positive modulus field, so `A^Neu·(rigid) = 0` exactly, independent of contrast. Hence the 6
rigid modes are `lambda = 0` eigenpairs with **finite mass** (`D A^Neu D·rigid ≠ 0`). The
wanted subspace is therefore B-non-degenerate, LOBPCG-smallest is well posed on it, and the
rigid modes are captured naturally — no separate nullspace treatment is forced. The
contrast-induced surcharge modes sit just above at small `lambda > 0`. This is the whole
reason a matrix-free route exists; without it the shared kernel would force a shift.

Self-check confirms the structure before any scoring: uniform block → exactly 6 `lambda≈0`
with a clean gap; the analytic rigid modes span the reference `lambda≈0` space to
`worst_capture = 1.000000`; σ-insensitivity of the reference holds across three decades.

---

## E1 — reference vs matrix-free LOBPCG on a REAL subdomain (B1, B2, B3)

Real field: cantilever 32×16×32, production OC recipe (`MultigridCG_Matfree`, 2.5 mm filter,
rho_min 1e-3), rung 0.30. A dense eigenvalues-only scan picked the core-6 agglomerate with the
largest high-contrast surcharge: `core=[18,24)×[0,6)×[0,6)`, n=1728, solid_frac 0.27, **13
modes below 5e-2 (7 beyond the 6 rigid)** — a genuine near-disconnection, not a chunky block.

Reference spectrum (kappa=1e9): 6 rigid (~1e-13…1e-10), then a real contrast band
`2.23e-3, 3.96e-3, 8.37e-3, 1.81e-2, 2.02e-2, 2.53e-2, 4.11e-2, 6.50e-2`, then the elastic
bulk from 0.108. Scoring cut (largest gap) = 1.23e-2 → **9 wanted modes**.

| LOBPCG | block m | iters | captured | worst capture | eig rel-err |
|---|---|---|---|---|---|
| Jacobi    | 17 | 122 | **9/9** | 1.0000 | 6.8e-14 |
| inner-CG20| 17 | **17** | **9/9** | 0.9999 | 8.8e-11 |

Both recover the whole wanted subspace to 3+ digits. Ground truth was established and shown
correct FIRST (B2); scoring is per-mode B-inner-product capture, not an average (B3).

## E1b — adversarial 12-mode B3 stress (real density + inserted soft-void channel)

To make "miss a mode" possible and detectable, a 1-voxel soft-void plane was forced through
the picked block's mid-x, near-disconnecting it into two halves coupled only through 1e-9
material — manufacturing **12 sub-threshold modes** (6 global rigid + 6 relative-body, the
latter at `1.3e-8…2.3e-7`, a clean contrast-driven cluster) before the bulk. Feature density
is real; the channel amplifies a real near-disconnection.

| LOBPCG | iters | captured | worst | verdict |
|---|---|---|---|---|
| Jacobi     | 299 | **12/12** | 1.0000 | ALL MODES |
| inner-CG20 | **17**  | **12/12** | 1.0000 | ALL MODES |

**No silent miss.** The many-mode case — exactly where "18 of 20" would be a failure — is
recovered whole.

## E2 — convergence vs contrast (channel geometry; surcharge is contrast-sensitive)

The 6 relative-body modes track `contrast^-1` (wanted cut 1.65e-1 @1e3 → 1.71e-3 @1e6 →
2.26e-5 @1e9/1e12), i.e. genuinely high-contrast near-null modes.

| kappa | Jacobi iters / captured | inner-CG20 iters / captured |
|---|---|---|
| 1e3  | 124 / **12/12** | 32 / 12/12 |
| 1e6  | 187 / **12/12** | 399 (not conv) / 12/12 (worst 0.9998) |
| 1e9  | 299 / **12/12** | 17 / 12/12 |
| 1e12 | 299 / **12/12** | 17 / 12/12 |

**Graceful, no cliff.** Jacobi captures every mode at every contrast; its iteration count
grows ~2.4× from 1e3 to 1e9 then plateaus (the wanted count is fixed and the modes stay
gap-separated). inner-CG is excellent at high contrast (17 iters) but inefficient at the
intermediate 1e6 (168k Neumann applies — it does not hit the residual tol though it still
captures all modes). **Jacobi is the robust choice.**

## E3 — which preconditioner (channel @1e9), and the circular-dependency check

| precond | iters | captured | worst | neu applies / outer iter |
|---|---|---|---|---|
| none       | 499 (capped) | **11/12** MISS | 0.9989 | 60 |
| Jacobi     | 299 | 12/12 | 1.0000 | 35 |
| inner-CG5  | 61  | 12/12 | 1.0000 | 136 |
| inner-CG20 | 17  | 12/12 | 1.0000 | 439 |
| inner-CG50 | 8   | 12/12 | 1.0000 | 1043 |

- Preconditioning is necessary: **unpreconditioned LOBPCG missed a mode** within the budget.
- Jacobi (the production diagonal) suffices — captures all modes.
- A stronger local inverse (inner CG on A^Neu with the analytic rigid nullspace projected out)
  cuts outer iterations hard and is NET CHEAPER at 1e9 (fewer outer iters ⇒ fewer total
  applies: 10.3k Jacobi → 7.5k inner-CG20).
- **Circular-dependency check (the named risk):** the inner Neumann solve did NOT stagnate at
  1e9 — its cost per outer iter grows with inner depth but it converges. The geometric-MG
  stagnation that hits the GLOBAL solver at 1e9 on thin ligaments
  (`multigrid-cg0-has-two-modes`) does not carry over, because the LOCAL Neumann solve is
  small and rigid-deflated. Caveat: the harness used inner Jacobi-CG as the "existing solver"
  stand-in, not the production V-cycle; a true subdomain multigrid would need its own
  hierarchy — but Jacobi alone already suffices, so the circular dependency is avoidable by
  construction (use Jacobi, or inner-CG, not a subdomain MG).

## E4 — memory and cost per subdomain, extrapolated

| | per subdomain (n=1728) | @ 8.44M DOF (~4884 subdomains) |
|---|---|---|
| matrix-free LOBPCG footprint | **2.09 MB** | 2.09 MB one-at-a-time (embarrassingly parallel) / 9.95 GB all-resident |
| dense assembled + factorized | 91 MB (44× more) | 435 GB resident |

The matrix-free path stores only element topology + moduli + O(n·m) LOBPCG vectors + the 576
shared Ke doubles. The eigensolve currency is the matvec count (17–299 outer iters × block
applies); wall time is not load-bearing. The assembled column reproduces PR 230's 20–35 GB
blocker at real scale (435 GB here is the dense harness-scale ceiling; the real per-subdomain
factorization is the 20–35 GB figure). Matrix-free removes it.

**Scale caveat:** harness subdomains are n≈1728; a real GenEO subdomain is ~16k DOF (PR 230).
LOBPCG iteration counts will rise with n (smallest-eigenvalue convergence scales with the
conditioning and the gap), but the property that matters — contrast-robust capture of ALL
sub-threshold modes without a shift — is what was demonstrated, and it is contrast-driven, not
size-driven.

---

## E5 — the other two pieces (assessed, not built)

Full reasoning: `evidence/2026-07-28-matrixfree-geneo-phase0/formulation_and_e5_notes.md`.

**(a) Coarse operator V^T A V.** Correct in structure — each column `A v_i` is one matrix-free
global apply, and `V^T(AV)` is `N_t × N_t` dense. But "small enough to factorize densely"
holds only at the LOW end of PR 230's projected coarse dimension: 8k → 0.5 GB dense (fine);
33k → 8.5 GB (edge); **66k → 35 GB dense — does NOT fit.** A dense coarse factorization is
affordable only if the decomposition keeps `N_t` near 8k (fewer, larger subdomains — which
PR 230 showed also shrinks `N_t`). Correction to the task's claim: true at the low end, breaks
at the high end.

**(b) Inexact coarse/local solves (arXiv 1912.13225).** The modification (eq. 9) is a
DEFLATED/balanced two-level preconditioner
`M^-1 = Z Ẽ^-1 Z^T + (I − P̃0)(Σ_i R_i^T A_i^-1 R_i)(I − P̃0^T)`, `P̃0 = Z Ẽ^-1 Z^T A` —
NOT the naive additive form; the projector is the point. Robustness (Lemma 3.3) needs only
`ε_a = max(|1−λ_min(E Ẽ^-1)|, |1−λ_max(E Ẽ^-1)|)` bounded, i.e. the inexact coarse solve need
only be SPECTRALLY EQUIVALENT to the exact one, not accurate to tight tolerance. **It applies
to us** and is exactly the lever that rescues the 66k high-end case in (a): solve the coarse
operator iteratively and use eq. 9. Price: the deflation projector applies a coarse solve
inside every outer CG iteration, so the coarse cost is per-iteration, not one-off.

---

## Verdict and what a full matrix-free GenEO would take

**The route is OPEN.** Matrix-free LOBPCG solves the GenEO local eigenproblem at 1e9 contrast
without shift-and-invert, recovering all sub-threshold modes with the Jacobi diagonal we
already have. Combined with PR 230 (small coarse space) and the matrix-free operator/MG stack
that already exists, a bespoke matrix-free GenEO is feasible on this 16 GB machine.

Scope of a full build (each piece is the size of one prior handoff; NONE is in scope here):

1. **Overlapping decomposition + partition of unity** over the design grid (agglomerates,
   `D_i` with `Σ R_i^T D_i R_i = I`). Cheap, geometric, embarrassingly parallel.
2. **Per-subdomain matrix-free LOBPCG** (this harness, productionised): Jacobi-preconditioned,
   block ≈ wanted + buffer, capture-based stopping (not tight residual — the threshold has a
   decade-wide plateau, PR 230). Store the kept `R_i^T D_i V_ik` as coarse columns.
3. **Coarse operator `V^T A V`** via matrix-free applies; dense-factorize if `N_t ≲ 8k`,
   else the eq. 9 inexact/iterative coarse solve (E5).
4. **Two-level preconditioner** wrapping the existing matrix-free MG-CG as the smoother / local
   solve, coarse correction from step 3, deflated form eq. 9 if the coarse solve is inexact.

Remaining risks to retire before committing:
- **Scale of the eigensolve at n≈16k** subdomains (iteration count vs n) — measure before
  committing block sizes.
- **Setup vs amortization at real scale** — PR 230 argues the eigensolves amortize across
  design iterations; confirm on a real multi-iteration run.
- **The intermediate-contrast inner-CG inefficiency** (E2 @1e6) — prefer Jacobi, or cap inner
  iterations; do not use a subdomain multigrid preconditioner (avoids the circular dependency
  entirely).
- **Coarse-solve-per-iteration cost** of the deflated eq. 9 form when `N_t` forces inexactness.

What would have CLOSED the route (and did not): LOBPCG failing to find all sub-threshold modes
at 1e9 with the available preconditioners. It found them all, including the adversarial
12-mode case, at 1e9 and 1e12, with the Jacobi diagonal alone.

---

## Bars
- **B1 real field, real contrast:** real OC-developed field; the tested subdomain has a real
  near-disconnection (surcharge 7 modes beyond rigid); contrast swept to 1e12. ✓
- **B2 ground truth first:** dense reference established and self-checked (6 rigid, σ-stable,
  analytic-rigid capture 1.0) before LOBPCG scored against it. ✓
- **B3 missed modes reported, not averaged:** per-mode B-capture; the only misses observed are
  named (unpreconditioned E3: 11/12). Every preconditioned case captured all modes. ✓
- **B4 no new build dependency:** dense reference uses only already-present Eigen, harness-only;
  no SLEPc/HPDDM/ARPACK/Spectra. ✓
- **B5 no production change:** harness only; nothing in `core/src`, app, fixtures touched. ✓
