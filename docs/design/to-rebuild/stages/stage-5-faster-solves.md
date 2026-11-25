# Stage 5: faster solves (TOSolver)

Branch `claude/topopt-stage-5-faster-solves-8df866`, from 2b40bcf4. Status: step 1 (find the cause) done 2026-11-25; plan waits on the discussion with the maintainer. Nothing in the solver changed yet. Commits: f2b18bbd (bridge-way core test), 883e7e77 (the three solve functions moved to `core/src/simp/to_solve.cpp`, unchanged; 17 unit tests green before and after).

## 1. Why a solve takes about 1,500 iterations (step 1)

### What the existing logs already say (Release runs of 2026-11-20/21, ledger D and K)

| part | levels | lambda_max(D^-1 A) on the smoothed levels | shipped weight x lambda (must stay under 2) | shipped V-cycle | what runs instead | cycles per solve |
|---|---|---|---|---|---|---|
| Top Motor Mount, res 96 | 3 | 4.38 / 4.39 | 2.63 | diverges (rel res 12 to 28 after 300 cycles) on solves 1 to 3, then latched off | l1-Jacobi "safe retry", lambda(Dl1^-1 A) 0.58 / 0.93 | about 1,560 |
| Stand v4, res 96 | 4 | 7.38 / 8.96 / 9.87 | 4.4 to 5.9 | diverges (rel res 19 to 353) on solves 1 to 3, then latched off | l1-Jacobi, 0.98 / 0.81 / 0.79 | about 500 |

Reading: the shipped smoother (damped Jacobi, weight 0.6, one sweep each side) is UNSTABLE on these parts. Damped Jacobi only settles when weight x lambda_max < 2; here it is 2.6 to 5.9, so the highest-frequency error grows each sweep and the V-cycle is not a usable preconditioner. Every run therefore spends 3 x 300 wasted cycles, latches the shipped cycle off, and does every remaining solve on the l1-Jacobi retry. That one is stable but weak.

The August component sweep (handoff 2026-08-02) tried weights 0.5 and 0.6 only, both above 2 / lambda_max on these parts, so every arm it measured was unstable. That is why "nothing rescued it".

### Why the single-precision switch never ran (ledger K)

The FP32 V-cycle is used only on the shipped attempt (multigrid.cpp, `mf_mgpcg(..., mixed, ...)` at the shipped call); the safe retry hard-codes `mixed=false`. On his parts the shipped attempt runs only on solves 1 to 3, diverges, and is latched off, so every solve that produced a result was FP64. Bit-identical results follow. The 193 s extra in rung 0 (644 s against 451 s) is the doomed FP32 attempt plus its FP64 retry on those three solves, not machine load.

### The measurement (probe on dumped solves, 2026-11-25)

How: a local probe (never committed) dumps the exact inputs of chosen solves from Release `topopt-cli` runs of the two test-P jobs (Top Motor Mount, Stand v4) and of the demo fixture, then re-solves each dump with the solver's own reduced system, hierarchy and coarsest LDLT, swapping only the smoother or the coarse space. Iteration counts are PCG to the run's own tolerance (1e-4 relative). Times are the probe's single-thread ones on a shared machine: compare within a row only, never quote them as run times.

The shipped smoother, per level (stationary V-cycle, energy change of the error per cycle; above 1 = the error grows):

| solve | shipped weight 0.6 | l1 retry | stable Jacobi (4/(3 lambda)) |
|---|---|---|---|
| Top Motor Mount solve 1 / 40 | 2.03 / 1.85 (grows) | 0.84 / 0.84 | 0.75 / 0.75 |
| Stand v4 solve 1 / 40 | 4,726 / 34 (grows) | 0.85 / 0.85 | 0.83 / 0.80 |
| demo solve 9 / 10 | 1.02 / 7.5 (grows) | 0.81 / 0.80 | 0.74 / 0.76 |

PCG iterations, same solve, only the named part changed (geometric = today's halved grid; algebraic = the existing, disarmed `fea_set_mg_algebraic_level1` level 1; c4:k = 4th-kind Chebyshev of degree k):

| solve | today (l1 retry, geometric) | stable Jacobi, geometric | c4:4, geometric | stable Jacobi, algebraic | c4:2, algebraic | c4:4, algebraic |
|---|---|---|---|---|---|---|
| Top Motor Mount solve 1 | 1,560 | 1,225 | 728 | 98 | 73 | |
| Top Motor Mount solve 40 (cold / warm) | 1,584 / 1,495 | 1,227 / 1,131 | 727 / 678 | 107 / 72 | 75 / 51 | 58 |
| Stand v4 solve 1 | not in 2,000 | not in 2,000 | 928 | 481 | 267 | |
| Stand v4 solve 40 (cold / warm) | 554 / 497 | 464 / 419 | 213 / 228 | 181 / 195 | 139 / 110 | 84 |
| demo solve 9 | 250 | 211 | 127 | 69 | 47 | 36 |
| demo solve 10 | not in 2,000 (residual grows to 150x) | same | same | | 88 | |

What separates the two causes (Top Motor Mount solve 40, same code, same smoother):

| field | levels | stable Jacobi | c4:4 |
|---|---|---|---|
| the whole 96x81x50 box solid, geometric | 4 | 87 | 42 |
| the whole box solid, algebraic | 3 | 29 | 24 |
| the part's own domain, every element solid (no contrast at all) | 3 | 1,213 | 715 |
| the part's design as solved | 3 | 1,227 | 727 |

Reading:
1. The shipped smoother is unstable on every solve measured (above). That is the latch, the l1 retry and the dead single-precision path.
2. Stabilising or strengthening the smoother alone buys at most about 2x (1,584 to 727). The wall is the GEOMETRIC COARSE GRID on the part's SHAPE, not the 1e9 stiffness contrast: the same part made fully solid needs the same 1,213 iterations, while the plain box needs 87. Halving the grid cannot follow thin walls, holes and gaps of a part that fills 10 % of its box. PR 283 (2026-08) measured the same thing as energy: the geometric level 1 captured 1.6 % of the solution on a dilute field.
3. The existing algebraic level 1 (aggregates that follow the structure) removes that wall: 15 to 27x fewer iterations on Top Motor Mount and 3 to 7x on Stand v4. It is also better on the plain box once the smoother is stable (24 to 29 against 42 to 87): the August finding that it loses on healthy fields (18 V-cycles to 39 on a 32x16x32 block) came with the shipped smoother, whose weight is unstable on a solid block too (lambda 3.99 here); with a stable smoother it wins on this box.
4. Demo solve 10 is a different case: 8 LOADED pieces have no face path to any support (they hang on void at 1e-9; the connection rule keeps them because they carry load). The geometric solve cannot converge whatever the smoother; the algebraic one converges in 88. Whether the design step that cut them loose should be refused is the optimiser's question, not the solver's (named to TOReview).

## 2. Research (papers named in the brief, and newer work)

| paper | what it says | what it means here |
|---|---|---|
| Aage, Andreassen & Lazarov 2015 (SMO 51:565), code TopOpt_in_PETSc `LinearElasticity.cc` | FGMRES outer (rtol 1e-5); 4 levels, Galerkin coarse operators; on every level the smoother is 4 GMRES steps preconditioned by SOR; coarse level GMRES(30)+SOR | far stronger smoothing than ours (1 Jacobi sweep each side, at an unstable weight). Their method is the reference for "tens of iterations" |
| Amir, Aage & Lazarov 2014 (SMO 49:815) | MGCG for TO; the solve tolerance is relaxed during the optimisation with no loss in the result | not opened (paywalled). The trajectory solves already run at 1e-4 (dumps). Ask for the PDF only if stage 5 tunes the tolerance |
| Lottes 2023 (arXiv 2202.08830); Phillips & Fischer 2022 (arXiv 2210.03179) | 4th-kind Chebyshev smoother: quasi-optimal for the V-cycle bound; better than classical Chebyshev; one-sided V-cycles with doubled order cost the same | the modern smoother to test against damped Jacobi and classical Chebyshev |
| Alexandersen & Lazarov 2015 (CMAME 290:156, arXiv 1411.3923) | spectral coarse basis per agglomerate (K psi = lambda M psi, modes under a threshold, partition of unity); contrast tested 1e-3 to 1e-12; GMRES 4 to 10 iterations; basis rebuilt only when the count rises (7 times in 200 design steps) | the cure if the coarse space, not the smoother, is what fails on dilute designs (TOReview's demo case) |
| Wang, de Sturler & Paulino 2007 (IJNME 69:2441) | ill-conditioning = density ratio x constant-density problem; diagonal rescaling removes the first factor; Krylov recycling across the sequence | the Jacobi scaling is already in the smoother; recycling exists (`recycle.*`, measured 2026-08 in section H) |
| Spillane et al. 2014 (GenEO) | coefficient-independent coarse space from local eigenproblems | `geneo.*` is this, used only in the Jacobi-CG fallback today; settings never swept |
| Behrou et al. 2021 (CMAME 113799, arXiv 2012.02860) | elements with density at or below 0.001 to 0.1 removed from the solve, returned by projection; 3D iteration 91 s to 10.5 s | the "Active Domain" lever; also removes the 1e-9 contrast the coarse grid struggles with |
| Khodak et al. 2026 (PCGBandit, arXiv 2509.08765) | online bandit picks the preconditioner per solve from measured wall; up to 1.5x; break-even about 1,000 solves | a run here has about 200 solves; low priority against fixing the smoother |

## 3. Plan (after the discussion with the maintainer)

To write after step 1's numbers and his discussion.
