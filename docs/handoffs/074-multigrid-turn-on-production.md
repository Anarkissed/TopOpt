# 074 — Multigrid turned ON for production optimize (Option A)

**Status:** DONE. The app's production optimize path now uses the geometric-multigrid
accelerator; the library default and the locked Gate-V2 reference stay on JacobiCG.

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/modest-darwin-ad4f4c`
**Branch:** `claude/enable-multigrid-production-optimize-d01614`

## What changed (two files, +117 lines, no core defaults touched)

```
app/TopOptKit/Sources/TopOptBridge/bridge.cpp |  12 +++
core/tests/unit/test_simp.cpp                 | 105 ++++++++++++++++++++++++++
```

`git diff --stat -- core/include core/src` is **empty** — no library header/source,
no default, changed.

## The flip — exact production functions and one-line diff

The app's production runner `RunModel.bridgeRunner`
(`app/TopOptKit/Sources/TopOptFlows/RunModel.swift:354-374`) dispatches real optimize
runs to **two** bridge entry points, both of which build a
`topopt::MinimizePlasticOptions opts` (whose `.simp` is a `SimpOptions`) and call
`topopt::minimize_plastic(...)` to produce the `OptimizeResult` the app consumes:

- **`run_minimize_plastic`** (`bridge.cpp:417`) — STL / self-weight cantilever path
  (STL models: `RunModel.swift:370` → `TopOptKit.minimizePlastic`).
- **`run_minimize_plastic_loadcase`** (`bridge.cpp:502`) — STEP / declared load-case
  path, M7.6 (STEP models: `RunModel.swift:361` → `TopOptKit.minimizePlasticLoadCase`).

**Both** were flipped, because both are genuine production runs — flipping only one
would silently leave an entire class of real runs on JacobiCG. The identical one-liner
was added immediately after each `topopt::MinimizePlasticOptions opts;`:

```diff
     std::atomic<bool> cancelled{cancel_flag != nullptr && *cancel_flag};
     topopt::MinimizePlasticOptions opts;
     opts.cancel = &cancelled;
+    // Production runs use the geometric-multigrid accelerator (handoff 072/073): it
+    // solves the identical system to the same tolerance and falls back to exact
+    // Jacobi-CG if a hierarchy is not applicable, so the result is always correct.
+    // The library default stays JacobiCG so Gate-V2 and the locked reference are
+    // untouched. This is the flip.
+    opts.simp.solver = topopt::SolverKind::MultigridCG;
```

The CLI (`core/src/cli/run_job.cpp`) and every other consumer were left on the library
default (JacobiCG), per the task.

## Precondition note (important, was a false-alarm block first pass)

The vendored `TopOptCore.xcframework` binary is **gitignored**, so it does NOT propagate
into git worktrees. This worktree initially carried a stale `libtopopt.a` (Jul 12,
pre-072/073) even though `build_core.sh` had been run against the **main checkout**
(`/Users/nadim/dev/TopOpt/TopOpt/…`, Jul 13 20:55, 891 KB, now contains
`multigrid.cpp.o` + `fea_solve_mgcg` + the SolverKind-aware `simp_compliance`). I
verified the main-checkout framework is current and rsync'd it into the worktree so this
branch is self-consistent and app-buildable. Takeaway for future bridge tasks in a
worktree: the xcframework must be copied in from the main checkout (git won't do it).

The bridge is not part of the xcframework, so the flip takes effect on the **next Xcode
app build** against the current framework (072+073+#79 merged). This branch's worktree
now has that current framework.

## Evidence — realistic same-answer proof (new core test §14, test_simp.cpp)

`test_simp.cpp` §14 runs the SAME optimization through the FULL `simp_optimize` loop
TWICE — once `SolverKind::JacobiCG`, once `SolverKind::MultigridCG` — on a realistic
**32³** grid (a 3-level multigrid hierarchy, vs the 8×4×4 / 2-level grid §13 uses).
`change_tol = 0` so both runs hit the full cap deterministically (10 OC iterations).
It asserts identical iteration count + outcome, final `max|drho| <= 1e-6`, and final
compliance to 1e-6 relative; then it probes every analysis density the MultigridCG loop
visited and tallies V-cycle vs Jacobi-CG fallback.

Raw stdout (final, cap = 10):

```
realistic(32^3, cap 10): MultigridCG V-cycle engaged on 11/11 analysis densities the
loop visited (0 fell back to exact Jacobi-CG); hierarchy = 3 levels; final compliance
jac=0.723107851 mg=0.723107851; max|drho|=1.559e-10 over 10 iters
simp: all 178 checks passed
```

### MG-vs-fallback reality check (the point of the test)

**11 of 11** MultigridCG solves in the loop genuinely engaged the V-cycle; **0** fell
back to exact Jacobi-CG. Real filtered/coherent SIMP fields at production scale get the
multigrid win — they do NOT silently degrade to Jacobi. (Correctness holds either way,
since a fallback IS an exact Jacobi-CG solve; this is purely the speedup-reality check.)
Cross-checked at other caps during sizing: 9/9 at cap 8, 13/13 at cap 12 — always 0
fallbacks, always a 3-level hierarchy.

How the count is read: `SimpOptimizeResult` doesn't expose per-solve `CgInfo`, so the
MultigridCG run captures each OC iteration's analysis density via the read-only
`keyframe` callback (the exact field the penalized solve consumes), and §14c re-solves
each with `simp_compliance(..., SolverKind::MultigridCG)` at the same tolerance —
deterministic + stateless, so each probe reproduces that solve's own MG/fallback
decision. `CgInfo::used_multigrid` / `mg_levels` are tallied.

Sizing: 32³ with a 10-iteration cap keeps `test_simp` at **42.75 s** in the full ctest
run (well under the ~2 min budget, with margin for slower CI). cap 8 → 34 s, cap 12 →
66 s were also measured; 10 was chosen for a healthy margin.

## Verification — full core suite (Release, `-DTOPOPT_REQUIRE_DEPS` off, Eigen found)

```
17/33 Test #17: simp .............................   Passed   42.75 sec
20/33 Test #20: gate_v2 ..........................   Passed   52.18 sec
...
100% tests passed, 0 tests failed out of 33
```

Per-test (tests #13–#33 shown; #1–#12 are the OCCT/Eigen-free quick tests, all passed —
`ctest -N` lists all 33):

```
13/33 fea_mgcg ............ Passed  10.43   14/33 beam_validation .... Passed  65.48
15/33 gate_v4 ............. Passed   0.56   16/33 gate_v5 ............ Passed   0.59
17/33 simp ................ Passed  42.75   18/33 rmin ............... Passed   0.77
19/33 mbb_validation ...... Passed   4.43   20/33 gate_v2 ............ Passed  52.18
21/33 property_v3 ......... Passed   2.84   22/33 variants ........... Passed   4.66
23/33 passive_regions ..... Passed   6.20   24/33 minimize_plastic ... Passed  17.61
25/33 anchor_integrity .... Passed   3.10   26/33 design_domain ...... Passed   0.59
27/33 mma ................. Passed  42.89   28/33 mma_projection_gate  Passed   1.21
29/33 stress .............. Passed  18.95   30/33 step_import ........ Passed   0.49
31/33 face_tag ............ Passed   0.57   32/33 mask_face .......... Passed   0.53
33/33 cli_demo ............ Passed 353.09
100% tests passed, 0 tests failed out of 33   (total 669.70 sec; cli_demo dominates)
```

- **Gate-V2 (test #20): GREEN and UNCHANGED.** I made no edit to any core source, so
  the Gate-V2 reference path is byte-identical and still runs JacobiCG (its `SimpOptions`
  uses the untouched default).
- **New realistic same-answer test (§14 inside `simp` #17): PASSES** — fast engine ==
  slow engine at 32³ through the full loop.
- **Full suite: 33/33 GREEN.**

## Explicit statements (the Option-A contract)

- The **library default is UNCHANGED**: `SolverKind::JacobiCG` remains the default on
  `SimpOptions::solver` (`simp.hpp:332`), on `simp_compliance`'s `solver_kind` param
  (`simp.hpp:123`), and on `MinimizePlasticOptions::simp.solver`. `git diff` on
  `core/include` + `core/src` is empty.
- The **only behavioural change is at the app's production entry points** in
  `bridge.cpp` (the two functions named above).
- **Gate-V2 and the locked reference are untouched.**
- No core rebuild was performed by this task (the bridge is not in the xcframework); the
  main-checkout framework was already current, and I synced it into the worktree.
- The stress path (`simp_optimize_stress`) and the CLI stay on the library default
  (JacobiCG) — out of scope for this task.
- ROADMAP box **not** checked (per instructions).

## Nothing left undone

All requested deliverables are complete and verified. One judgement call to flag for
review: the task text is phrased around a single production entry point / one-line diff,
but there are genuinely two (STL self-weight + STEP load-case), so the diff is two lines
across two functions. I flipped both deliberately; if only one is wanted, reverting
either block is trivial.
