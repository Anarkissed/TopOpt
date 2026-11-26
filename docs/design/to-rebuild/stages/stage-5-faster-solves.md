# Stage 5: faster solves (TOSolver)

Branch `claude/topopt-stage-5-faster-solves-8df866`, from 2b40bcf4. CURRENT STATE (2026-11-25 ~20:50 EST; the 95 % pause was lifted by the maintainer himself: "Keep going. Do not stop"):
- NO PUSH until the maintainer rules (TOReview 01:45Z): TOReview's commit 0ee02fda put 29 copyrighted PDFs under docs/design/to-rebuild/papers/; this branch carries them through merge e1df43e2 and was pushed at cddaad04. Do not push, do not merge TOReview's branch again, do not delete or rewrite; add files by name only.
- In the tree, uncommitted: E-01 phase 1 + S-05 + B-06 (applied by agent-scratch/tosolver/apply_patches.sh with5), with their four new tests. Committed only after the build-and-test hold (measureE) is green.
- Prepared in scratch: E-01 phase 2 (agent-scratch/tosolver/phase2/: simp.hpp, production.cpp, minimize_plastic.cpp, to_run.inc, to_solve.cpp; settings value only, byte-identical by construction; the per-run state wiring is phase 2b, for a ruling). Then the same-bytes check on the stand at res 64 against TOReview's tip build.
- Queue (agent-scratch/tosolver/requeue.sh, behind #362's release 21): measureE (build + new, quick and long tests), measureB (replays, 7 settings, all reference dumps; summarise with py/replay_table.py), mem.sh (algebraic memory at res 128/192), measureC (items 4 and 5 timings), measureD (the switch sweep).
- Side hustle: plan draft in section 4, awaiting the switch sweep and memory numbers, then the maintainer's approval.

Status: step 1 (find the cause) done 2026-11-25; plan waits on the discussion with the maintainer. Nothing in the solver changed yet. Commits: f2b18bbd (bridge-way core test), 883e7e77 (the three solve functions moved to `core/src/simp/to_solve.cpp`, unchanged; 17 unit tests green before and after).

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
| Amir, Aage & Lazarov 2014 (SMO 49:815) | MGCG for TO; the solve tolerance is relaxed during the optimisation with no loss in the result | a free copy exists (structopt.net.technion.ac.il/files/2015/11/SMOMGCG.pdf); to read before any tolerance change. The trajectory solves already run at 1e-4 (dumps) |
| Lottes 2023 (arXiv 2202.08830); Phillips & Fischer 2022 (arXiv 2210.03179) | 4th-kind Chebyshev smoother: quasi-optimal for the V-cycle bound; better than classical Chebyshev; one-sided V-cycles with doubled order cost the same | the modern smoother to test against damped Jacobi and classical Chebyshev |
| Alexandersen & Lazarov 2015 (CMAME 290:156, arXiv 1411.3923) | spectral coarse basis per agglomerate (K psi = lambda M psi, modes under a threshold, partition of unity); contrast tested 1e-3 to 1e-12; GMRES 4 to 10 iterations; basis rebuilt only when the count rises (7 times in 200 design steps) | the cure if the coarse space, not the smoother, is what fails on dilute designs (TOReview's demo case) |
| Wang, de Sturler & Paulino 2007 (IJNME 69:2441) | ill-conditioning = density ratio x constant-density problem; diagonal rescaling removes the first factor; Krylov recycling across the sequence | the Jacobi scaling is already in the smoother; recycling exists (`recycle.*`, measured 2026-08 in section H) |
| Spillane et al. 2014 (GenEO) | coefficient-independent coarse space from local eigenproblems | `geneo.*` is this, used only in the Jacobi-CG fallback today; settings never swept |
| Behrou et al. 2021 (CMAME 113799, arXiv 2012.02860) | elements with density at or below 0.001 to 0.1 removed from the solve, returned by projection; 3D iteration 91 s to 10.5 s | the "Active Domain" lever; also removes the 1e-9 contrast the coarse grid struggles with |
| Wang, Aage, Wu, Sigmund & Westermann 2025 (SMO 68:174, TOP3D-XL; read in full) | matrix-free GMG, trilinear, Galerkin, damped Jacobi weight 0.65 at nu 0.3 (lambda about 3: just under the bound 2/0.65 = 3.08), Emin 1e-6, CG tol 1e-3 (no visible change against 1e-12); 10-25 iterations per solve on bulky TO domains, 25-200 on porous infill | the same Jacobi recipe as ours, stable only because nu = 0.3; at our nu = 0.39 it diverges, which is cause 1. Their domains are bulky; none is thin-walled like Top Motor Mount (cause 2). Their 1e-3 tolerance is a lever to discuss, not taken |
| Khodak et al. 2026 (PCGBandit, arXiv 2509.08765) | online bandit picks the preconditioner per solve from measured wall; up to 1.5x; break-even about 1,000 solves | a run here has about 200 solves; low priority against fixing the smoother |

## 3. Plan (agreed with the maintainer 2026-11-25)

### In plain English (for Nadim)

The computer spends about three quarters of every run doing one kind of sum, over and over. That is the "solve". The brief asks me to make that sum faster without changing any answer. Six jobs, in this order:

1. **Fix the step that has been overcorrecting.** Today it makes the error bigger, so the solver gives up and uses a slow backup. I'll try two fixes, a simple one and a modern one, at three settings each, on every reference part, and keep whichever is fastest.
2. **One settings card instead of eleven hidden switches.** Today the solver's settings are scattered, and one solve can quietly affect the next. They become one card handed to each solve, so the same job always gives the same answer.
3. **Use every core of the Mac** for the step after each solve, which today runs on one core.
4. **Single precision: keep or delete.** This is a faster, less exact way of doing part of the sum. It never actually ran (it was always switched back off). Once step 1 is fixed it can run, so I measure it once. If it isn't clearly faster, it is deleted.
5. **Two ways of feeding the part to the sum:** read it from a stored list (today), or work it out on the fly. Measure both and keep the faster.
6. **Before-and-after table** on all your reference parts: run time (and how much of it is the solve), the design, the margin, the mass. Same answers, less time, or it doesn't ship.

What you will notice: shorter runs. Nothing on screen changes. Until the table passes, the new behaviour sits behind one switch and today's behaviour stays the default. Once it passes, the switch and the old path are deleted (the rebuild's rule: keep only what works).

When I stop: a change that makes any reference part slower, changes a pass/fail, or changes the design beyond rounding is not adopted. It is reported with its numbers, not forced through.

The side hustle (a better rough map) is separate and comes to you as its own write-up (section 4).

### Technical plan

Switch: `TOPOPT_SOLVER` (read once per solve in multigrid.cpp; unset = today's solver, byte-identical). Values select the settings measured below; the winner becomes the default and the switch and the old path are deleted at close-out.

1. **Smoother (B-05).** New `MgSmoother::Chebyshev4` (4th kind, Lottes 2023 / Phillips & Fischer 2022, degree k, upper bound rho = s x lambda_max(D^-1 A) per level), and damped Jacobi with a per-level weight f / lambda_max. lambda_max is computed per solve by the existing deterministic power iteration (`power_lambda_dinv_a`), so no state crosses solves. Settings: Jacobi 0.6 (today), f = 1.0 / 1.333 / 1.6; Chebyshev k = 2 / 3 / 4. Both smoothers are polynomials in D^-1 A, so pre = post keeps the V-cycle SPD. Measured by replaying dumped solves (first, middle and last solve of rung 0) of every reference part through the production solve (`fea_solve_mgcg_matfree`, production posture, cold and warm): iterations, solve wall (Release, production threads), and whether the latch or the l1 retry engaged. Then a full Release run per reference part, today against the winner.
2. **E-01: one settings value.** A `SolverSettings` value (smoother, weights, sweeps, mixed, threads, recycling, GenEO, parity pad, safe retry, re-arm period, cubic) in fea.hpp, passed to new overloads of the solve entry points. Per-run state (latches, recycle basis, GenEO basis) moves into an explicit run-state object the caller owns, so a solve's result depends only on its inputs, its settings and the state it is handed (test K). The bridge's four entry points keep their signatures as wrappers. Caller edits outside my files (production.cpp, to_run.inc, run_job.cpp, bridge) go to TOReview as exact lines.
   Design (2026-11-25, from reading every setter and caller):
   - What crosses solves today. Settings: threads (`g_mf_threads`, a PROCESS-wide atomic), Galerkin block cache, mixed precision, cubic lattice, recycling (enable, dim, cycle, wrap-multigrid: process-wide atomics), algebraic level 1, parity pad, safe retry, re-arm period (thread-locals), the solve deadline, and the harness tuning (`g_mg_tuning`). Run state: the stagnation latch and the safe-retry latch, counters and log windows (thread-local, reset by `fea_matfree_reset_mg_stagnation_latch` at run start in minimize_plastic.cpp), the Krylov recycle basis (thread-local), the GenEO basis and its lifecycle (`g_geneo`: a PLAIN GLOBAL, neither thread-local nor atomic, so two jobs solving at once in the app share and race on it).
   - Callers that set them (none of them my files): production.cpp (configure_production_options), to_run.inc (observability overrides), run_job.cpp (a scoped recycling/GenEO off), minimize_plastic.cpp (run-start resets), simp.cpp (deadline), the bridge (flexible_squish_fe.cpp posture, flexible_bridge.cpp, bridge.cpp recycle reset).
   - The value: `struct SolverSettings` in fea.hpp, one field per setting above plus the stage-5 smoother (kind, degree, F, safety, iterations); `SolverSettings::production()` holds what configure_production_options sets today, the default constructor what the library does today.
   - The run state: `class SolverRunState` (opaque, fea.hpp), owning the latches, counters, logs, the recycle basis and the GenEO basis. The caller makes one per run and passes it in; a certification or analysis solve gets a FRESH one, so its bytes cannot depend on which solves ran before it (test K), and two jobs in one process share nothing.
   - Entry points: new overloads `fea_solve_mgcg_matfree(..., const SolverSettings&, SolverRunState*)` (and the CG twin). The existing entry points, the bridge's four included, keep their signatures and meaning: they read a thread-local default SolverSettings (which the old setters now write) and a thread-local default run state (which the old resets clear). Then the callers move one by one to passing the value, and the setters are deleted when the last caller has moved.
   - Order: (1) SolverSettings + SolverRunState and the new overloads in my files, old entry points as wrappers, byte-identical (test: every existing test plus test K on two interleaved jobs); (2) the exact caller edits to TOReview for production.cpp, minimize_plastic.cpp, to_run.inc, run_job.cpp, simp.cpp; the bridge changes named to #362 through TOReview; (3) setters removed.
   Phase 1 status (2026-11-25): built in scratch and tested (SolverSettings and SolverRunState, the two new entry points, the old ones byte-identical; test_to_solver_settings 5/5, test_to_solver_run_state 4/4: two interleaved runs each get their own bytes, a fresh state cannot depend on earlier solves, the default state is untouched; the quick existing tests green with it linked in). Goes into the tree after the queued measurement build.
   Phase 2, the callers (only two call the solver: core/src/simp/to_solve.cpp, mine, and the Flexible bridge):
   - simp.hpp (not mine): SimpParams gains `const SolverSettings* solver_settings = nullptr; SolverRunState* solver_run = nullptr;`. to_solve.cpp (mine) passes them to the new entry points when set, else calls the old ones (byte-identical).
   - production.cpp (not mine): configure_production_options fills a SolverSettings with today's production values instead of calling the setters; minimize_plastic.cpp (not mine) owns one SolverRunState per run (replacing the three run-start resets) and hands a FRESH one to every certification / final compliance / analysis solve.
   - to_run.inc and run_job.cpp (not mine): the observability overrides and the scoped recycling/GenEO-off write into that SolverSettings instead of the globals.
   - The Flexible bridge (#362): Posture becomes a SolverSettings value (threads 1, pad auto, algebraic off, GenEO off, recycling off) plus its own SolverRunState, passed to the new entry points; the global flips around its solves go.
   - Phase 3: the setters and the thread-local defaults are deleted when nothing calls them.
3. **S-05: the sensitivity loop on all cores** (to_solve.cpp). Fixed z-slab chunks with partial sums added in slab order, so the bytes do not depend on the thread count. Test: identical bytes at 1 and 6 threads.
4. **Single precision (section K).** With a stable smoother the shipped attempt carries, so the FP32 V-cycle becomes reachable. Give it the same smoother, measure on the reference dumps; keep only if the solve wall drops by 15 % or more with no change in the gate; otherwise delete it (the cycle, the FP32 copies, the setter).
5. **Element product (B-06).** Stored per-element dof numbers (today: 104-byte records, 8-colour scatter, full-vector copies) against a grid stencil that derives the dofs from the voxel index. Settings: 1, 3 and 6 threads each. Measured as fine-apply time and memory on every reference part's fine operator; the faster goes in, the other is deleted.
6. **Reference table and report.** Before and after on all reference parts (04-tests.md): Release run time split into solve and the rest, iterations per solve, margins, mass, test K. Every paper and lever in the brief answered by name: coarse warm start, resolution continuation, GenEO sweep, Active Domain, MG hierarchy dropping per solve. The app-side FlexibleBatchM* tests are named for #362's gate.

Gate for every item: the bridge-way core test and the 17 solver, flexible and simp unit tests green before and after; no verdict changes; designs equal to the solve tolerance; no reference part slower.

Cases the fix is held to, besides test P's two jobs: demo solve 10 (8 loaded pieces cut off from every support, above); the demo job with `TOPOPT_FACE_LOADS=face` on TOReview's branch (7f6c9aaa or later), whose solve 19 has the design in 17 pieces. There, multigrid reaches rel res 136 after 2,500 cycles and the Jacobi-CG fallback stops at its cap of 122,682 iterations at rel res 0.092, so the 0.30 version is refused (TOReview, 11-25). The solver must converge or say plainly why not, never grow the error silently.

PROPOSAL FOR THE REVIEWER (TOReview, 11-25; a change to a ruled definition, so not built until ruled): the connection rule (multigrid.cpp, THE CONNECTION RULE above scan_islands) calls a piece ANCHORED when one of its nodes carries a Dirichlet BC OR a non-zero load. Under self-weight every solid voxel carries a load, so every piece counts as anchored and no floating piece is ever taken out (demo solve 10: "loose pieces at the floor: 0 of 11"); a piece that carries only its own weight then hangs on the 1e-9 void, the near-rigid mode the rule exists to remove (ruling 2026-10-25, "It shouldn't hang at all"). Proposed: anchored = reaches a SUPPORT (an engaged Dirichlet BC or spring) through shared faces. A piece that reaches no support is loose and its own BODY load goes with it (weight with nowhere to go). A piece that carries an APPLIED (face) load and reaches no support is a broken design: solved at the floor like the rest, but counted and reported per solve so the optimiser's step can be judged (the optimiser side is TOReview's). Expectation added to the cases above: with those pieces out, demo solve 10 converges on the geometric hierarchy too.

## 4. Side hustle: a coarse space that follows the part (outside the brief): PLAN DRAFT, awaiting the maintainer's approval

Process (his, 2026-11-25): read all the code, research beyond the surface, a plan with keep / rewrite / throw out, ship and stop criteria, HIS APPROVAL, then implement and test. Waiting time only; never slows sections 3.1-3.6. Blanks [..] fill from the all-parts sweep and the memory check, both queued.

### In plain English (for Nadim)
Every solve works with a detailed map of the part and a rough map with half the detail. Today's rough map is made by halving a grid. That works on chunky, firmly held shapes, but on thin-walled parts it is 4 to 14 times slower, and on a broken design it never finishes. A second kind of rough map, built from the part's own material (the "algebraic" one made in August and switched off), follows thin walls and loose pieces. On a plain block it is 2 to 3 times slower than the halved one, though both are fast there.
Because users can import any shape, we keep both. Each solve first tries the halved map for a short budget of steps (about [20-30]). Most easy shapes finish inside that. If the solve isn't done, it switches that same solve to the material-following map and carries on from where it got to. The choice depends only on that solve, so the same job always gives the same answer. Large software (hypre, from Lawrence Livermore) uses the same idea.
What you'd notice: shorter runs on parts like yours ([..] on Top Motor Mount, [..] on Stand v4), unchanged answers and pass/fail, and no slowdown on plain shapes.
What gets cleaned out: the August idea of switching after three stuck solves (never built, and it would never fire now), and, if the reference runs show they no longer ever help, the old give-up latch and the slow backup solver.
When we stop and delete it: if, after up to three rounds of fixes, two or more reference parts or test shapes run slower than today's halved map with the new fine step, or any pass/fail flips, or its memory at your highest resolution won't fit.

### What the research and measurements found (detail in the notes; all iteration counts, PCG to 1e-4)
| case | halved grid (stage-5 smoother) | algebraic | algebraic, smoothed | keep coarse points next to the part |
|---|---|---|---|---|
| Top Motor Mount solve 40 | 727-1,227 | 58-107 | 42-77 | 337-535 |
| Stand v4 solve 40 | 213-464 | 84-181 | 66-103 | 126 |
| demo solve 9 | 127-211 | 36-69 | 26-35 | 161 |
| demo solve 10 (loaded pieces cut loose) | never | 88 | 42-71 | never |
| plain firmly held block (August's healthy case) | 6-10 | 21-25 | - | - |
| Top Motor Mount's box made solid | 42-87 | 22-29 | - | - |
Also measured: deflating the slow modes is not a cure (dozens of them, not a handful); padding the empty space with soft material cuts the halved grid 5x but makes the system 7.5x bigger; a looser tolerance saves 6-34 %.
Others' work: hypre's hybrid solver (cheap first, switch to AMG when the convergence factor is poor) is the precedent; Peetz & Elbanna 2021 name the idea; learned or run-latched switches (PCGBandit, August's latch) depend on earlier solves, against test K; for one switch mid-solve, restart CG from the current iterate (Notay 2001; Knyazev & Lashuk 2007).

### Technical plan
KEEP: algebraic_coarsen.* (aggregation, rigid-body modes, coarsening control, deterministic, refusal to geometric), build_mf_hierarchy_algebraic, the element-local Galerkin product.
REWRITE: (1) the two smoother refusals in multigrid.cpp narrowed to the point-block smoother; (2) the switch in solve_mgcg_matfree: halved grid for K cycles, then free it, build the algebraic hierarchy, restart PCG from the iterate; an algebraic refusal restarts on the halved grid; a stall reports why; switched / cycles / refusal reported per solve; (3) not my file, exact lines to TOReview: the algebraic prolongator rows as flat CSR (memory, before res 192); (4) optional: smoothed aggregation where memory allows.
THROW OUT: the August latch-switch idea; the stagnation latch, l1 safe retry and its logging, IF the reference runs show zero engagements with the new path (same evidence as the main work's close-out).
SHIP when, on every reference part AND on test shapes beyond them (a plain held block, a chunky part with a hole, a thin-walled bracket, a dilute design, a design with a loaded piece cut loose): solve time below the halved grid + stage-5 smoother; verdicts identical; designs equal to the solve tolerance; test K identical bytes; memory under the cap at res 192 of the largest reference part ([..]); the bridge-way and unit tests green.
STOP (scrap, delete the code) after up to three rounds of fixes if: two or more of those run slower than the halved grid + stage-5 smoother; or a verdict flips beyond tolerance noise; or the algebraic memory at res 192 stays over the cap after the CSR rewrite and the switch cannot be limited to sizes that fit.
Measured next (queued): the switch prototype at K = 10 / 20 / 30 / 50 on every reference dump; memory at res 128 / 192.

## 5. Stage report (filling in as measurements land)

### Reference table, before and after (Release, his jobs read in place; one part per lock hold)
| part | today: run time (solve / rest) | iterations per solve | after: run time (solve / rest) | iterations per solve | versions, margins, mass | test K |
|---|---|---|---|---|---|---|
| (filled from run_ref.sh: today and the chosen TOPOPT_SOLVER setting) | | | | | | |

### Tests moved from failing to passing
- New: to_solver_bridge_way (12), to_solver_smoother (74, three settings each of per-level Jacobi and Chebyshev, converge on multigrid without the l1 retry); to come with their patches: to_solve_threads (S-05), to_solver_reduced_apply (B-06), to_solver_settings and to_solver_run_state (E-01).
- Today's solver on his parts: the shipped V-cycle diverges on solves 1-3 and latches; with the stage-5 smoother it carries every solve measured (replays, all reference dumps: to fill).

### The open choices, settled with their settings
- Smoother (B-05): damped Jacobi F/lambda at F = 1.0 / 1.333 / 1.6 against 4th-kind Chebyshev K = 2 / 3 / 4, on every reference dump (to fill from measureB). The stall rule: 1,000 cycles, then 2x per 500 (measured on Top Motor Mount, commit 49f28890).
- Element product (B-06): stored dofs (today, full-length copies) / reduced numbering with a spare slot (B2, B3) / grid stencil (C), at 1 / 3 / 6 threads (to fill from measureC).
- Single precision (section K): FP32 against FP64 cycle, same iterations; keep only at >= 15 % solve wall (to fill from measureC).

### Refused, and the rule
- (none so far)

### Levers named in the brief, answered (none is called "not possible"; each is measured or reported "not done yet" with what is missing)
- Trajectory warm start (warm_start.matfree; each solve starts from the previous design step's field): already on in his runs (the dumps carry a guess). Measured on the replays: today's solver gains little from it (Top Motor Mount 1,584 -> 1,495 cycles) because the slow modes dominate; with a coarse space that works it pays (algebraic + Chebyshev 2: 75 -> 51; Stand v4 139 -> 110). It stays on; its value rises with the coarse-grid work.
- Coarse warm start (warm_start.coarse, the res/2 pre-solve of the design, job.cpp 1291-1305): off, and the app never sends it. NOT DONE YET: to measure as a full-run setting on the reference parts (off / coarse / coarse + matfree) once the solver changes are in, because a cheaper solve changes its trade.
- Resolution continuation (solve coarse, carry the design up, finish fine): not in the code, and the optimiser loop is not my file. NOT DONE YET: its smallest form needs minimize_plastic / plsm changes; named to TOReview as an optimiser-side item.
- GenEO settings sweep (block 20, cut 0.05, 8^3 cores, overlap 1): GenEO acts only inside the Jacobi-CG FALLBACK. With the stage-5 smoother the fallback should rarely run (the replays count it). If it never engages on the reference table, GenEO is unused machinery, and the rebuild's rule is to delete it, not tune it; if it engages, sweep cut and block size at three settings each on those solves. To decide from the replay and reference-run counts.
- Active Domain (band 0, disarmed after PR 209 measured it net-negative in the stagnation regime): the stagnation cause is now known and fixed under the switch, so the old verdict no longer stands. NOT DONE YET: the band is a production.cpp constant with no per-job switch, so measuring it needs a job or observability override (not my file; to TOReview) or a harness run; three bands (0 / auto / auto+2).
- Multigrid hierarchy dropped part-way through a run (the stagnation latch, "0 levels"): measured per solve on the replays (used_multigrid, levels, l1 retries) and on the reference runs' logs. Today: latched on solve 3 on both test-P parts; with the stage-5 smoother: to fill.

### For #362 (exact replacement lines, carried by TOReview; not edited by TOSolver)
After E-01 phase 1 is merged (the new entry points taking `const SolverSettings&` and `SolverRunState*`):

app/TopOptKit/Sources/TopOptBridge/flexible_squish_fe.cpp, `struct Posture` (about 515-550): the five global flips and the two run-state resets go; the posture becomes a value plus the sim's own run state. Only the deadline stays global (it is an absolute time per call, not a setting):
```cpp
struct Posture {
  topopt::SolverSettings settings;   // the sim's solver posture, handed to every solve
  topopt::SolverRunState run;        // the sim's own latch / recycle / GenEO state
  double prev_deadline = 0.0;
  explicit Posture(double deadline_abs_ms, bool keep = false)
      : settings(topopt::fea_current_solver_settings()) {
    settings.matfree_threads = 1;
    settings.mg_parity_pad_mode = 1;
    settings.mg_algebraic_level1 = false;
    if (!keep) {
      settings.geneo_twolevel = false;
      settings.krylov_recycling = false;
    }
    prev_deadline = topopt::fea_set_solve_deadline_ms(deadline_abs_ms);
  }
  ~Posture() { topopt::fea_set_solve_deadline_ms(prev_deadline); }
  Posture(const Posture&) = delete;
  Posture& operator=(const Posture&) = delete;
};
```
and in core_solve (about 1223-1226), with `posture` the sim's Posture in scope:
```cpp
    sol = jacobi_only ? topopt::fea_solve_cg_matfree(P.fe.g, P.fe.E, P.nu, P.bcs, loads, P.tolerance, max_iterations,
                                                     &info, guess, nullptr, posture.settings, &posture.run)
                      : topopt::fea_solve_mgcg_matfree(P.fe.g, P.fe.E, P.nu, P.bcs, loads, P.tolerance, max_iterations,
                                                       &info, nullptr, guess, posture.settings, &posture.run);
```
Effect: a topology run's carried recycle / GenEO state and its switches are never touched by a squish solve (the race named 11-25 is gone), and the squish sim no longer resets the process's default state. core/tests/unit/test_to_solver_bridge_way.cpp (TOSolver's) follows the bridge in the same change.

core/src/cli/run_job.cpp, `ScopedLadderSolverIsolation` (about 4516-4534): NO change in phase 2 (its lattice post-process solves build their own SimpParams, so they keep reading the switches it flips). When the run's SolverRunState is wired through minimize_plastic (phase 2b, needs a ruling because certification solves then stop inheriting the trajectory's latch, which changes bytes where the latch fired), those solves get a fresh state and the class and its two uses are deleted.

### For #362's gate
- The app-side FlexibleBatchM* tests run in #362's gate on any change to the solver the bridge calls (app/TopOptKit/Tests/TopOptFlowsTests): FlexibleBatchM2Tests, FlexibleBatchM2VerifyTests, FlexibleBatchMDentTests, FlexibleBatchMGroupTests, FlexibleBatchMLegendTests, FlexibleBatchMStressTests, FlexibleBatchMVerifyTests, FlexibleBatchMXrayTests (the two *Probe files are harnesses). E-01 phase 2 changes the bridge's Posture (through TOReview).
