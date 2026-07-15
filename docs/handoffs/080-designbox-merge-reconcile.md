# 080 — Design-box / matrix-free branch reconciled onto main

**Track:** merge reconciliation (no redesign). **Scope:** only the merge; no source
behaviour changed on either side. Do NOT touch fixtures/benchmarks/materials.json/
ARCHITECTURE.md/ROADMAP.

## Commits reconciled

- **Reconciled onto main:** `c5cd09d` — *Merge PR #90 from
  claude/intelligent-archimedes-a6b1a7* (main's tip: it independently merged
  handoff 078 matrix-free multigrid, and carries the orientation-gizmo
  liquid-glass reskin, app-track).
- **Branch tip (pre-merge):** `f20680a` — the design-box work (handoffs 078 + 079).
- **Reconciliation merge commit:** `f8c2bf1` — parents `f20680a` + `c5cd09d`.
- **Shared merge-base:** `483df44` — the 078 branch tip
  (`claude/intelligent-archimedes-a6b1a7`), which BOTH sides had already merged.

## STEP 1 — Conflicts: NONE (and why)

`git merge main` reported *"Automatic merge went well"* with **zero conflicted
files**. This is expected, not luck:

- The merge-base (`483df44`) is the 078 tip, so the entire matrix-free-multigrid
  codebase is in the COMMON base — both sides start from identical 078 code.
- **main** added, on top of 078, only the **orientation-gizmo liquid-glass
  reskin** (app-track): `app/TopOptKit/Sources/TopOptFlows/OrientationGizmoView.swift`
  (+reskin), `ResultsScreen.swift`, `WorkspacePlaceholder.swift`,
  `OrientationGizmoTests.swift`, `ViewerVisibilityRegressionTests.swift`,
  `docs/handoffs/075-viewer-regression-diagnosis.md`,
  `docs/handoffs/078-gizmo-liquid-glass-reskin.md`.
- **This branch** added, on top of 078, only the **design-box core work + the
  bridge flip** (handoff 079): `core/**` (multigrid, voxelize, simp,
  minimize_plastic, headers, CMakeLists, the two design-box tests) and the single
  app file `app/.../TopOptBridge/bridge.cpp`.

The two change-sets touch **disjoint files** — the only near-overlap is the app
tree, and even there main worked in `TopOptFlows/` while the branch touched
`TopOptBridge/bridge.cpp`, so nothing collides. Every core file the branch
modified was untouched by main (main only re-merged the same 078 into them), so
git's 3-way merge kept the branch's version for each with no ambiguity.

**Any conflict outside the bridge?** None anywhere — including the bridge. Nothing
required choosing one side over the other.

Sanity: `git diff f20680a f8c2bf1` is **empty** — the merge is content-neutral (it
only adds the topology link so `main` is now an ancestor of the tip); the reconciled
tree equals the branch tip that handoff 079 already validated, now sitting on top
of main.

## STEP 2 — Both sides preserved (survival confirmations)

Verified in the merged tree (`f8c2bf1`):

- **PenalizedSolver JacobiCG gate — SURVIVED (load-bearing).** Both
  `simp_optimize` variants build `PenalizedSolver` only under
  `options.solver == SolverKind::JacobiCG` (2 occurrences in
  `core/src/simp/simp.cpp`). The multigrid kinds skip the fine-K-assembling
  constructor — this is what keeps the design-box path from re-OOMing.
- **coarsen_align default 1 — SURVIVED.** `expand_design_domain(..., int
  coarsen_align = 1)` (byte-identical default); the driver passes 8
  (`kDesignBoxCoarsenAlign` in `minimize_plastic.cpp`).
- **build_hierarchy frugal default false — SURVIVED.** `build_hierarchy(...,
  bool frugal = false)`; the assembled `else` branch is the original
  `AP = f.A * P; Ac = P.transpose() * AP`, byte-for-byte; only
  `build_mf_hierarchy` passes `/*frugal=*/true`.
- **In-place A1 (coeffRef) + frugal coarse Galerkin — SURVIVED**
  (`A1.coeffRef(...) += v`; `galerkin_pt_a_p_frugal`).
- **SolverKind::MultigridCG_Matfree — SURVIVED** (enum is the 3-value form;
  dispatch in `simp_compliance`).
- **Bridge flip on BOTH entry points — SURVIVED.** `SolverKind::MultigridCG_Matfree`
  appears twice in `bridge.cpp` (run_minimize_plastic + run_minimize_plastic_loadcase).
- **main's gizmo reskin — PRESENT.** `OrientationGizmoView.swift` carries the
  liquid-glass lens; `OrientationGizmoTests.swift`,
  `ViewerVisibilityRegressionTests.swift`, and handoffs 075/078-gizmo present.

## THE ONE RULE — assembled/JacobiCG default byte-identical

Source-level confirmation (`git diff main HEAD`):
- `simp.cpp`: for `JacobiCG`, the gate constructs the SAME `PenalizedSolver` with
  the SAME args and `usable()` check (a `unique_ptr` wrapper — same object via
  `.get()`); behaviour is identical. Only the multigrid branches differ.
- `multigrid.cpp`: `build_hierarchy(frugal=false)` is the original product; the
  assembled `fea_solve_mgcg` and all its coarse operators are unchanged.
- `voxelize.cpp`: `coarsen_align` defaults to 1 → existing callers unchanged.

Empirical: **Gate-V2 GREEN** (see Evidence).

## Evidence

- **Core ctest: <FILL: N/36 passed>** — including `test_designbox_padding`,
  `test_design_domain`, `fea_mgcg_matfree`, `fea_matfree`, `fea_mgcg`, `fea_cg`,
  and **gate_v2 (green, byte-identical)**.
- **App suite: <FILL: swift test count>** — including `OrientationGizmoTests` and
  `ViewerVisibilityRegressionTests`.
- Reconciliation merge is content-neutral (`git diff f20680a f8c2bf1` empty).

## Not done / honest notes

- This is a reconciliation only — no behaviour changed; the design-box end-to-end
  peak remains ~1.97 GB as reported in handoff 079 (a known limitation with a
  documented follow-up, not re-opened here).
- `/core/` changed → `app/scripts/build_core.sh` was run to re-vendor the core for
  the app tests.
