# Matrix-free GenEO — Phase 2: the two-level preconditioner, wired into CG

**Date:** 2026-07-29
**Branch:** `claude/geneo-two-level-preconditioner-eb39f0`
**Predecessor:** PR 236 matrix-free-GenEO Phase 1 (`2026-07-28-matrixfree-geneo-phase1.md`)
— decomposition + partition of unity, capture-LOBPCG basis, `V^T A V` coarse operator.
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang, `-O2`.
**Production change (all default-OFF, byte-identical):** a nullable external additive
preconditioner **hook** on the matrix-free Jacobi-CG (`mf_cg_solve`) —
`core/src/fea/{matfree.cpp,fea_matfree.hpp,multigrid.cpp}`,
`core/include/topopt/fea.hpp` (tripwire constant). The GenEO eigensolve /
decomposition machinery lives ENTIRELY in the harness
`core/tests/harness/geneo_twolevel_probe.cpp` (+ `_part2.inc`, `_part3.inc`), which
installs the hook — so the production library stays Eigen-free.
**Evidence:** `evidence/2026-07-29-matrixfree-geneo-phase2/`.

---

## Verdict: THE ROUTE PAYS.

On the real high-contrast design-box rung whose geometric multigrid stagnates, the
two-level preconditioner cut the cold linear solve from **5,412 Jacobi-CG iterations to
249 — a 21.7× reduction** — to the SAME field (within the basin noise floor), with the
basis fitting in tens of MB. And the reduction **grows with problem size** (a controlled
sweep: 1.9× → 2.5× → 3.0× → 3.6× as the grid grows and Jacobi degrades while the
two-level count stays flat), which is the GenEO promise — contrast/mode-count
independence — measured, not asserted. Projected to the maintainer's 128³ rung (Jacobi
≈ 41,063), the two-level count stays in the low hundreds ⇒ a ~100×-class win.

**One honest structural finding that shaped the build:** of the two terms in the task's
`M^-1 = R_0^T A_0^-1 R_0 + Σ_i R_i^T A_i^-1 R_i`, the **coarse (GenEO deflation) term
does all the work; the local additive-Schwarz term with inexact local solves does
essentially nothing** (measured below). The winning preconditioner is the **deflation
form** the base Jacobi already anchors:
`M^-1 = D^-1 + V (V^T A V)^-1 V^T` — precisely arXiv 1912.13225 eq. 9, and precisely the
structure the shipped Krylov-recycling machinery (handoff 133) uses. The local solves
being inexact is not what closes them — the coarse space simply subsumes them.

---

## What this task built (PR 236's piece 4)

The two-level preconditioner, wired into the PRODUCTION matrix-free Jacobi-CG
(`mf_cg_solve`, the exact solve the stagnating rung falls back to) via a default-null
hook. When installed, after the base Jacobi step the loop adds the GenEO coarse
correction `z += V (V^T A V)^-1 (V^T r)`, with:
- **V** = Phase-1's capture-LOBPCG coarse basis (columns `R_i^T D_i V_ik`), rebuilt for
  the current system and mapped into the reduced kept-DOF space.
- **A** = the PRODUCTION reduced operator `MatfreeReduced::apply_kgg` (same operator CG
  iterates), so `V^T A V` is consistent with the solve.
- **coarse solve** = dense Cholesky where `N_t` fits the budget (the measured regime);
  a capped inner-CG for `N_t` above it (production extents — implemented, see §P3).
- **local subdomain operators** = the same operator restricted to the overlapping
  agglomerate, Dirichlet-eliminated on the boundary (classical additive Schwarz
  `A_i = R_i A R_i^T`), solved INEXACTLY by Jacobi sweeps or a capped inner CG — never a
  factorization, never a subdomain multigrid. Built and measured; found not to help (§P7b).

Every added correction is SPD, so the compound preconditioner is SPD: it can change the
ITERATION COUNT but never the converged field or the stopping test.

---

## The bars

### P1 — OFF IS BYTE-IDENTICAL. ✓
The feature is the nullable hook `mf_set_precond_hook` (internal `fea_matfree.hpp`);
nothing in the production build installs it, documented by the public tripwire
`kMatfreeExternalPrecondDefaultOff` + `static_assert` in `fea.hpp`. With no hook the
`mf_cg_solve` branch is never entered.
- **Cross-build FNV** over densities/compliance/margins/accepts of a full 2-rung ladder
  (`geneo_byteid_xbuild.cpp`, public API only): phase-2 build (hook present, off) =
  `5bff3f90b90babeb`; a `git stash` **pre-change** rebuild of the four production files =
  `5bff3f90b90babeb`. **Identical.** (`byteid_before.txt` / `byteid_after.txt`.)
- In-process (`byteid` mode): the ladder run twice is bit-identical and
  `mf_precond_hook_installed()` is 0 before and after. (`byteid.log`.)

### P2 — ★ THE NUMBER THAT MATTERS. ✓
Real field developed through the **production ladder** (`minimize_plastic`, min-feature
filter + projection ⇒ the thin near-disconnecting members a bare OC does not make),
grid 40×32×40, `ng = 156,198`, vf 0.26, coarse-only deflation, core 8:

| optimizer iter | Jacobi-CG | two-level | ratio |
|---|---|---|---|
| 0 (cold, converged design) | **5,412** | **249** | **21.7×** |
| 1 | 738 | 117 | 6.3× |
| 2 | 564 | 129 | 4.4× |

(`p2.log`, `p2_iters.csv`.) Iter 0 — the fully-developed rung solved cold — is the
representative stagnating solve (thousands of Jacobi iterations, the maintainer's
disease). Build (one-time, amortizable): 17.5 s; two-level solve wall 3.3 s vs Jacobi
23.6 s. `N_t = 595`, `cond(V^T A V) = 6.8e9`, `nsub = 100`, tail (subdomains carrying a
near-null mode) = 98/100 — the developed field is riddled with near-disconnections,
which is exactly why Jacobi stalls and the coarse space wins.

**Scaling toward 128³ (controlled synthetic, `hard_scaling.csv`).** A checkerboard
high-contrast composite (contrast 1e9), coarse-only, whose near-null-mode count grows
with the grid:

| n | ng | Jacobi-CG | two-level | ratio |
|---|---|---|---|---|
| 24 | 45,000 | 489 | 257 | 1.9× |
| 32 | 104,544 | 628 | 249 | 2.5× |
| 40 | 201,720 | 771 | 261 | 3.0× |
| 48 | 345,744 | 916 | 253 | 3.6× |

The two-level count is **flat (~255)** while Jacobi grows monotonically — the ratio grows
with size. This is the contrast/mode-count independence that makes the 128³ projection
(Jacobi ≈ 41k ⇒ two-level ≈ low hundreds, ~100×) credible rather than an extrapolation of
a single point.

### P3 — MEMORY IN BUDGET. ✓
At `ng = 156,198` the stored coarse basis is **22.9 MB**; the dense `V^T A V` at
`N_t=595` is 2.8 MB. Process peak RSS for the whole solve including the basis was
**≈340–409 MB** across runs (matrix-free Jacobi-CG baseline ≈120 MB). The resident subdomain operators
(18.5 MB) are only needed for the local term, which is **off** (§P7b), so the shipped
coarse-only footprint is ≈ basis + coarse-op. **8.44M-DOF projection** (per-subdomain
constants are size-invariant, Phase-1 §G3): basis ≈ 1.2 GB — matching Phase 1 — well
inside 16 GB, against PCHPDDM/HPDDM's 20–35 GB which does not fit. **Coarse-solve
caveat:** at 8.44M, `N_t ≈ 22–28k` exceeds the dense budget, so the coarse solve must be
inexact/iterative; the measured `cond(V^T A V) ≈ 6.8e9` is what that inner solve must
handle (higher than Phase 1's 1e7–1e8 estimate — a real cost to watch, but it is a small
dense/iterative problem, not the fine system).

### P4 — THE ANSWER IS THE SAME ANSWER. ✓
**Solve level (`control.log`), grid 40×32×40, `ng=156,198`, negative control FIRST:**
- **basin floor** — Jacobi 1e-9 vs 1e-8: `max|du|/max|u| = 4.9e-12` [5,723 vs 5,412 it].
- **two-level** 1e-8 vs Jacobi 1e-8: `max|du|/max|u| = 1.4e-8` [249 vs 5,412 it].
Both agree to the CG tolerance (~1e-8): the two-level field IS the Jacobi field, reached in
21.7× fewer iterations. Compliance (`f^T u`), stresses and margins are continuous
functions of `u`, so the same `u` to 1e-8 ⇒ the same certified compliance/margin/accept ⇒
identical gate verdicts; the preconditioner never enters the accept decision (it changes
only iteration count).

**Design level, through the REAL ladder (`p4.log`).** `p4design` runs the full
`minimize_plastic` ladder three ways — stock, two-level-armed (provider hook rebuilding
the basis once per solve), and a 1e-9 negative control — and reports the fraction of
solid voxels flipping printed-classification, with grid dims + solid count, plus per-rung
compliance/margin/accept. At the tractable 32×24×32 grid: **0/22,528 voxels flip
(0.000e+00), compliance identical (9.648445e+07), margin identical (1.1600), gate 0/0** —
exactly the negative-control floor (also 0).
**Honest caveat, and why the headline forces Jacobi-CG directly:** at every tractable
extent the production **multigrid CARRIES** (≈93 V-cycles < the 300-cycle budget), so the
ladder never falls to Jacobi-CG and the hook (which lives on the Jacobi-CG fallback)
**never fires** — `p4design` reports **0 basis builds**. The MG→Jacobi stagnation the hook
targets appears only at ~128³-class extents (the align-8 coarsening limit,
`multigrid.cpp`), the multi-hour regime this route exists to remove. So the design-level
run confirms the two-level is correctly **inert where MG carries** (corroborating P1/P7),
while the *headline* two-level-vs-Jacobi win is measured by driving the Jacobi-CG solve
DIRECTLY — the exact solver the 128³ rung falls into — where the same-answer property is
proven at the solve level above.

### P5 — THE GATE NEVER SOFTENS. ✓
The hook changes only the preconditioner, never a tolerance. The certification/accept
solve still asserts the exact tolerance against the named constant — unchanged and
untouched — at `core/src/simp/minimize_plastic.cpp:1108`:
`assert(opt.cg_tolerance == kCertTol && ...)`, `kCertTol = options.simp.cg_tolerance =
1e-8`. No assertion was weakened or deleted.

### P6 — AMORTIZATION, MEASURED. ✓
See `amort.log`. Reuse policy: build the basis once at design state 0 and REUSE its expensive
LOBPCG basis for the next consecutive OC states — refreshing ONLY the cheap coarse
operator `V^T A_s V` (`N_t` matvecs + a small dense factor) — vs REBUILDING the whole
basis each state. Grid 32×24×32, `ng=75,066`, `N_t=253`:

| state | Jacobi | rebuilt (full LOBPCG) | reused (basis + refresh) | rebuild s | refresh s |
|---|---|---|---|---|---|
| 0 | 1,685 | 344 | 344 | 7.3 | 0.39 |
| 1 | 477 | 222 | 251 | 7.6 | 0.39 |
| 2 | 445 | 195 | 243 | 7.0 | 0.39 |
| 3 | 286 | 169 | 229 | 6.5 | 0.40 |
| 4 | 319 | 161 | 225 | 4.1 | 0.40 |

The **refresh is ~18× cheaper than a rebuild** (0.39 s vs ~7 s), and the reused-basis
iteration count (225–251) stays close to a full rebuild (161–222) and far below Jacobi
(319–477). So the eigensolve (the setup cost) amortizes across design iterations: reuse
the LOBPCG basis, refresh only the small coarse operator to keep it consistent with the
current `A`. **Refreshing the coarse operator is not optional** — an early bug that
reused the *stale* coarse operator (`V₀^T A₀ V₀` against `A₁`) diverged to the iteration
cap, because a coarse operator from the old system is not a deflation for the new one.
This is the Alexandersen–Lazarov amortization that made their 26M-DOF single-thread result
affordable, with the honest correction on what exactly is reused.

### P7 — WHERE IT DOES NOT HELP, SAY SO. ✓
`healthy.log`: on a well-connected near-solid block where geometric multigrid CARRIES
(MG-CG 18 cycles, 0.23 s), Jacobi-CG needs 327 and the two-level 152 (+2.52 s build) —
the two-level Jacobi-regime route is far more expensive than the V-cycle there. **This is
expected and it is why the hook lives on the Jacobi-CG fallback ONLY** (`mf_cg_solve`),
not on `mf_mgpcg`: a healthy multigrid rung never invokes it. The preconditioner is thus
armed conditionally on stagnation FOR FREE, by placement — exactly the posture the task
argued for.

### P7b — the local Schwarz term is measured USELESS (the honest structural finding).
Ablation on a single near-disconnection (`ablation.log`, Jacobi 338):
- coarse + local: 192 (1.8×)
- **coarse-only: 174 (1.9×)** ← best
- local-only: 330 (1.0×) ← the inexact local Schwarz term does essentially nothing.
The base Jacobi handles the local high-frequency error; the GenEO coarse space handles
the global near-null modes; the overlapping local solves are redundant with both and,
being inexact, only add per-iteration cost. Removing the base Jacobi to give the local
solves primacy (a "pure" additive Schwarz) makes a WEAK preconditioner that runs to the
iteration cap. So the shipped form is the deflation `D^-1 + coarse` — the local term is
retained in the harness (behind `TL_LOCALTERM`) only to keep the ablation reproducible.
**This is NOT the BLOCKED-STOP condition:** the route does not need the exact
factorizations we cannot afford — the coarse space, built matrix-free, delivers the
contrast independence with no local factorization at all.

### P8 — DETERMINISM. ✓
`det.log`: two builds+solves of the same system give identical CG iteration counts (249)
and identical FNV over the solution (`a5df20221d00b8bc`). Fixed PRNG seeds, fixed
traversal/accumulation order, deterministic operator.

---

## Honest limitations
1. **Scale is projected, not run at 128³.** The headline is measured at 40×32×40
   (Jacobi 5,412) and the mode-count independence at a controlled sweep to 345k DOF; the
   128³/41k figure is the maintainer's, and the 100×-class projection rests on the *flat*
   two-level curve, not on a single-point extrapolation. Developing a real 128³ field
   through the ladder is the multi-hour cost this whole route exists to remove.
2. **Coarse-solve conditioning at production extents** (`cond ≈ 6.8e9`, `N_t ≈ 22–28k`)
   is the open cost: an inner-CG coarse solve is implemented (`coarse_inner_cg`) but not
   stress-tested at that conditioning; a larger dense budget or a preconditioned coarse
   solve may be needed. This is the same "inexact coarse solve" Phase 1 flagged as
   Phase-2's central design choice; it is answered structurally (dense where it fits,
   iterative above) but its cost at 8.44M is estimated, not measured.
3. **The local Schwarz term did not earn its place** — reported, not hidden (§P7b).

## Reproduce
`evidence/2026-07-29-matrixfree-geneo-phase2/reproduce.sh`. Determinism: CG iteration
counts, coarse dimensions and mode counts are deterministic; wall times are reported but
not load-bearing (the currency is the CG iteration count).
