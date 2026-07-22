# 127 — Walk back the coarsenability padding; the real blockers are convergence + plateau

**Track:** core only. **Territory:** `/core/` (`src/fea`, `src/voxel`, `src/simp`,
`src/cli`, headers, tests). **NO app, NO bridge.** **Builds on / reverts:** 122
(= PR #151, the coarsenability padding). This is a **surgical FORWARD-FIX off
`origin/main`** — a `git revert` of the #151 merge conflicts with PRs 152–155
(which share `minimize_plastic.cpp` / `observability.cpp` / `simp.cpp` /
`run_job.cpp`), so it was NOT used.

**Handoff-number note:** `origin/main` handoffs top at 124; PR-review context
placed the next-free at ~126, so this takes **127** to clear it. It amends
**122** (not "124" — the merged file is `122-multigrid-coarsenability-padding.md`).

---

## Why (the premise 122 rested on was falsified in production)

122 shipped an **adaptive escalation** of the design-box coarsening pad: instead
of a fixed align-8, `expand_design_domain` grew the alignment (`required_coarsen_align`)
to whatever power of two made the grid coarsenable under the multigrid DOF cap —
on the theory that the production res-128 fallback was a **coarsenability** failure.

A real run disproved it. Job `12f27504…` (build fingerprint `92e702008a9b`, the
#151 build), res-128 loadcase + design box + face clearance, infill 30:

| symptom | value |
|---|---|
| `cg_multigrid` (iterations.csv) | **0 on all 158 rows** — MG never carried a solve |
| progress | **stuck in rung 0**, 158 iters, ~430–615 s/iter, **19.4 h**, 0 rungs done |
| CG iters/solve | 4390–20156 (the Jacobi fallback) |

Reconstructing the solved grid (`import_step → voxelize(128) → expand_design_domain`):

| pad | grid | coarsenable? |
|---|---|---|
| fixed align-8 (pre-#151) | **232×64×216** | **NO** |
| #151 escalation (align-16) | **240×64×224** | **YES** |

So #151's escalation **did** change this job's grid (232→240) and made it
coarsenable — MG then **built a hierarchy and stagnated**, falling back anyway. The
failure is **CONVERGENCE STAGNATION** on the ~1e-9-contrast SIMP field with a large
clearance keep-out void (the adversarial-coefficient regime `multigrid.cpp`'s own
`kMgIterBudget` comment names), which no padding fixes. Forcing the build was
**net-negative** — see the latch measurement below.

**Honesty rider (do not over-correct).** The coarsenability *rule*
(`mg_grid_coarsenable`) and the fixture-scale flip 122 proved are **true**; a grid
that genuinely can't coarsen does fall back. The error was extrapolating that to
production. And the **original 128³ bracket run** (122's headline `cg_multigrid=0`
on 535 iters) is now **UNVERIFIED**: the CSV can't tell build-rejection from
stagnation and its grid was never reconstructed. One confident story was not
replaced with its mirror.

---

## What this handoff changes (core only)

1. **Neutralize the escalation** (`src/voxel/voxelize.cpp`). `expand_design_domain`
   pads to the **fixed** `coarsen_align` floor again — the exact pre-#151 grid.
   `required_coarsen_align` is removed from `topopt/coarsen.hpp`; the constants,
   `round_up_to`, and `mg_grid_coarsenable` stay (documentation + future gate).
   Byte-identity: proven by `test_coarsen_rule` (2) — a deeper floor only appends
   inert Empty voxels, giving `|Δvf|=0`, `max|Δρ|=0` on the shared design.

2. **run_info honesty (Amendment 1)** (`observability.{hpp,cpp}`, `run_job.cpp`).
   `cg_multigrid`/`mg_levels` are an OUTCOME: the up-front write leaves
   `cg_multigrid_observed=false` and the serializer emits **`null`**; the post-run
   finalize sets the observed value. An unfinished run asserts NOTHING (the #151
   build wrote the optimistic intent `true`, and this very run kept that
   false-positive because it never finished — the trap that misdiagnosed it). The
   **authoritative per-solve record is `iterations.csv`'s `cg_multigrid` column.**

3. **Per-run stagnation latch (Amendment 2)** (`src/fea/multigrid.cpp`, matrix-free
   path only; `fea.hpp`; one reset call in `minimize_plastic.cpp`). After
   `kMgLatchThreshold=3` consecutive **stagnated** solves (built a hierarchy but hit
   the `kMgIterBudget=100` cap without converging), stop even BUILDING the hierarchy
   for the rest of the run (straight to Jacobi). Thread-local, sticky, **reset per
   run** by `fea_matfree_reset_mg_stagnation_latch()`; a converging solve clears the
   counter, so a healthy run never latches and is **bit-identical** to before.
   `cg_multigrid` stays 0 in the CSV while latched.

   **Measured (64³ stagnating checkerboard, 1e-4 tol):**

   | solve | wall | state |
   |---|---|---|
   | 1–3 | 10.7 / 14.3 / 12.4 s | MG built + stagnated |
   | 4–6 | **4.5 / 4.8 / 4.6 s** | latched — **build skipped** |

   The doomed hierarchy build is ~60% of a stagnating solve; the latch removes it
   (~2.5× faster per stagnating solve once latched).

   **NO within-solve fast-fail (a measured finding, not an omission).** Amendment 2
   also asked for an *early* bail — bail a single MG attempt to Jacobi once its
   residual is still high after a probe iteration, instead of burning the full
   budget. Implemented, it **failed the correctness bar** and was removed. Real
   design-box MG solves (e.g. `test_galerkin_cache`'s 16×8×16 gusset case) routinely
   sit at **relative residual 2–8 at iter 15** — a CG transient under a weak V-cycle
   — yet **converge by iter ~60–90, within the budget**. Any early residual-level or
   rate probe bails those legitimate solves (it flipped that solve's `used_multigrid`
   1→0 and broke the test). No early signature separates slow-but-converging from
   stagnating on these systems, and the binding rule is *never abandon a solve MG
   would have solved*. So the only cutoff stays the existing full-budget one; the
   latch just stops REPEATING a proven-doomed build. (A rate model robust to the
   transient is folded into blocker (a) below.)

4. **Correct the record:** 122 gets a WALK-BACK banner; `test_coarsen_rule` reworked
   (rule + byte-identity + loud-fallback reporting kept; the escalation/"padding
   makes MG engage" assertions removed; the stagnation-guard test added).

**Gates:** full `ctest` green (see PR evidence). THE ONE RULE holds: the JacobiCG
library default is untouched; the fast-fail/latch live on the matrix-free MG
fallback path and are proven inert on healthy solves.

---

## The two REAL blockers (the follow-up task — TEST before assuming)

These are the actual production pain. **Do not fix them in the walk-back.**

**(a) MG does not CONVERGE on high-contrast design-box + clearance systems.** The
V-cycle stagnates past the budget; the fast-fail/latch only make the *fallback*
cheaper, they do not make MG *work*. Options to investigate: a stronger smoother
(e.g. block/ILU on the fine level), an algebraic or operator-dependent coarsening
that captures the ~1e-9 modulus jumps a linear prolongation cannot, or accepting
Jacobi-CG here and attacking its iteration count another way. The grid dims are a
red herring; the coefficient field is the problem.

**(b) The MMA plateau-stop never fired.** Rung 0's objective was flat (~0.00279
from iter ~20) yet it ground to iter 158 toward the 200 cap — that alone is ~a day
per rung. **Reviewer's hypothesis to TEST FIRST, not assume:** 086's
minimum-total-progress gate may never *arm* when the run is iteration-capped, and
the inaccurate Jacobi solves feeding MMA may give it poor descent — i.e. the
plateau bug and the solver bug could be **one** bug. Reproduce the flat trajectory,
instrument the plateau predicate's inputs, and confirm cause before changing it.
