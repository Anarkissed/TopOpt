# G2 — Setup cost per subdomain + amortization (analysis)

The harness measures coarse-space SIZE with a dense eigenvalues-only solve (O(n_s^3)); that
is a sizing instrument, not the production eigensolver. The REAL method uses shift-invert
Lanczos on the sparse local Neumann matrix, so the setup cost is estimated analytically from
the two measured quantities: n_s (local free DOF per subdomain) and N_i (modes kept).

## Per-subdomain eigensolve cost (shift-invert Lanczos, the SLEPc/ARPACK default)
The dominant cost is ONE sparse-direct factorization of the shifted local Neumann matrix
K^w - sigma·diag(K^w), reused for every Lanczos apply:
- 3D FEM nested-dissection Cholesky on n_s DOF: **flops ~ O(n_s^2)**, **fill ~ O(n_s^{4/3})**.
- Lanczos then does ~O(N_i) back-solves against the factor (each O(fill)); with N_i in the
  low tens this is a modest multiple of the factorization, not a new order.
So per-subdomain setup ≈ c·n_s^2 flops + (N_i · fill) back-solve flops, memory ≈ the factor
fill O(n_s^{4/3}).

Concrete bracket at the two decompositions the G3 survey used (8.44M DOF total):
- **512 subdomains, n_s ≈ 16k:** factor ≈ 1-3M nnz (~10-25 MB) each; factorization ~ seconds
  each on one core; ×512 ⇒ setup wall-time on ~6 cores in the **minutes-to-low-tens-of-minutes**
  band, factor memory ~5-13 GB aggregate (survey number).
- **64 subdomains, n_s ≈ 125k:** factor ≈ 10-30M nnz (~0.1-0.25 GB) each; factorization ~tens of
  seconds each; ×64 on 6 cores ⇒ similar minutes band, factor memory ~7-16 GB aggregate.
Either way the ONE-TIME setup is comparable to a handful of production MG-CG solves — NOT free,
but not the bottleneck IF it amortizes.

## Amortization across design iterations — the decisive lever
A&L §5.1-5.2 (Fig 8): over **200 design iterations the spectral basis was rebuilt only 7 times**
(1 initial + 4 forced by p-continuation + 2 heuristic), because Mnd (design change) is tiny in
the early and late stages and the basis is contrast-robust for a fixed threshold. With a
GMRES-iteration-triggered heuristic + seeded initial guess they beat the direct solver end-to-end.

Applied here: production runs the 4-rung ladder; within a rung the OC/MMA design moves little
between iterations (my memory notes: "the design barely changes between solves", warm-start
inherits with -48%/-39% iters). So the setup cost is paid ~O(rungs + p-steps + a few heuristic
rebuilds) times per RUN, i.e. **a single-digit multiple**, not once per state solve. If a rung
runs ~30-50 state solves and the basis is rebuilt ~2-3× per rung, the amortized setup is
**~5-10% overhead per state solve** — the same regime that let A&L come out ahead of a direct
solver at Mx=64 (2D, 26M DOF).

CAVEAT specific to us (see G1): A&L amortized over **3 unique agglomerates** (2D single periodic
microstructure). Our 3D general field has **every subdomain unique**, so the setup is
n_subdomains full eigensolves, not 3 — the per-rebuild cost is O(n_subdomains) larger. Amortization
across iterations still holds; amortization across subdomains (periodicity) does NOT. This is why
the coarse-space SIZE and the number of subdomains, not the rebuild frequency, dominate our cost.

## R-GenEO — the published way to cut the setup (note for Phase 1)
Spillane's Reduced-GenEO poses the generalized eigenproblem only in a RING near the subdomain
boundary (the overlap), not the whole subdomain interior. The local eigen-matrix shrinks to the
ring DOF (a 2D-like O(n_s^{2/3}) set instead of the 3D n_s), so both the factorization and the
Lanczos apply get an order cheaper, at the cost of a weaker (but still contrast-robust in
practice) coarse space. If Phase 1 proceeds, R-GenEO is the first setup-cost lever to pull; it
also shrinks the coarse space itself (fewer interior modes), interacting with G1.

## Bottom line
Setup is a one-time, embarrassingly-parallel, amortizable cost of a few production-solve
equivalents per run — affordable IN ISOLATION. The affordability verdict therefore rests entirely
on the coarse-space SIZE (G1): the coarse operator is rebuilt/solved every Krylov iteration, and
its dimension N_t sets both the per-iteration cost and the memory, neither of which amortizes.
