# 083 — Reconcile the two 082 branches (grid-mismatch fix + anchor integrity)

## What this reconciles

Two independently-reviewed-and-accepted branches both numbered 082, both editing
`bridge.cpp`, that must land together:

- **A — 082 design-box grid-mismatch fix** (`claude/design-box-grid-mismatch-98bce0`,
  branch tip `7ddf2c3`). The STRUCTURAL grid fix. Adds
  `MinimizePlasticResult::solved_grid`, the public `minimize_plastic_solved_grid(grid,
  options)` helper, and the public `kDesignBoxCoarsenAlign` constant. `bridge.cpp` now
  derives the progressive-stream grid via `minimize_plastic_solved_grid()` up front and
  reports `mp.solved_grid` at the end. **Already merged to `main`** via PR #93
  (`d93b558`) before this reconciliation began.
- **B — 082 design-box anchor integrity** (`claude/designbox-anchor-integrity-lb2scy`,
  commit `4878201`, "Restore anchor integrity on the design-box path (082)"). The anchor
  pad on the box path. Relaxes the `design_box`+`design_mask` incompatibility ONLY when
  `freeze_imported_part == false`, merges the part-grid pad into the expanded mask at the
  offset, counts pad voxels in `frozen_effective`, and removes `bridge.cpp`'s
  `if (!has_design_box)` guard so the pad is built on both paths.

Merge base of the two: `47fda64`.

## The key finding: B predates A (so a raw `main..B` diff LIES)

B was branched from an old `main` (`47fda64`) that did **not** yet contain A. A landed on
`main` afterwards (PR #93). Consequently a direct `git diff main..B` makes B look like it
*deletes* A's work — `test_designbox_grid_report.cpp` (−256), `082-designbox-grid-mismatch-fix.md`
(−160), and 34 lines of A's `pipeline.hpp` additions. **That is a diff artifact, not B's
intent.** In the real three-way merge (base `47fda64`, which lacks all of A), B never had
those files/lines to delete, so they are added-on-one-side-only and survive untouched.
B's handoff even flagged the grid mismatch as "PRE-EXISTING, not touched" — it simply did
not know A had already fixed it. **A's fix wins; B contributes only the anchor pad.**

## Conflicts

`git merge` reported a **clean textual auto-merge** (no conflict markers). Per the task
this was verified **semantically**, not just textually. The two sides touch `bridge.cpp`
in disjoint regions (B at ~706 pad guard; A at ~780–823 stream/result grid) and
`minimize_plastic.cpp` in disjoint regions (B in the `if (expanded)` mask block ~150–225
and the `part_relative` accounting loop ~294–330; A adds `result.solved_grid = G` at ~351
and the free function at ~89), so no textual overlap — and, on inspection, no semantic
clash either.

### Per-file resolution

| File | A wanted | B wanted | Merged result |
|---|---|---|---|
| `app/.../bridge.cpp` | stream grid from `minimize_plastic_solved_grid(grid, opts)`; final `to_optimize_result(mp, mp.solved_grid)`; no 3-arg `expand_design_domain` | drop `if (!has_design_box)` guard → pad on BOTH paths, passed as `opts.design_mask` | BOTH present. Pad built under `if (load_case.minimize_plastic)` only (720–728); `result_grid = minimize_plastic_solved_grid(grid, opts)` (795–796); `result = to_optimize_result(mp, mp.solved_grid)` (823). No `expand_design_domain` **call** anywhere in bridge.cpp (only prose comments). |
| `core/src/simp/minimize_plastic.cpp` | add `solved_grid` field, set `result.solved_grid = G`; 5-arg aligned `expand_design_domain(..., kDesignBoxCoarsenAlign)`; free fn `minimize_plastic_solved_grid` | gate `design_mask` reject on `freeze_imported_part`; merge pad into expanded mask at `domain.offset_*`; count pad FrozenSolid in `frozen_effective` | BOTH present and interleaved. A's `result.solved_grid = G` (351) and free fn (89) coexist with B's gated reject (179–188), pad-merge overlay (202–225), and pad accounting (322–324). The aligned 5-arg call (198–201) is A's — B's diff carried it as unchanged context, so B never had a 3-arg call here. |
| `core/CMakeLists.txt` | register `test_designbox_grid_report` | register `test_designbox_anchor_pad` | BOTH registrations present (grid_report line 447, anchor_pad line 421). |
| `core/include/topopt/pipeline.hpp` | add `solved_grid`, `kDesignBoxCoarsenAlign`, helper decl | (untouched vs base) | A's additions survive verbatim (`kDesignBoxCoarsenAlign` = 8 line 78, `solved_grid` line 406, `minimize_plastic_solved_grid` decl line 438). |
| `core/tests/validation/test_design_domain.cpp` | A's add-material-contract edits | (untouched vs base) | A's edits survive (B's `diff base..B` is empty for this file). |
| `test_designbox_grid_report.cpp` (A), `082-designbox-grid-mismatch-fix.md` (A) | added by A | never existed on B | survive (added-one-side-only). |
| `test_designbox_anchor_pad.cpp` (B), `082-designbox-anchor-integrity.md` (B) | — | added by B | added by the merge. |

No stale comments survive from either side: B replaced the false "expand_design_domain
freezes EVERY imported-part solid voxel … so the pad is unnecessary under a design box"
comment (bridge.cpp + minimize_plastic.cpp) with the true whole-domain-optimize rationale;
A's `minimize_plastic_solved_grid` comment block (bridge.cpp 780–794) is the true one and
is kept. No side was forced to lose anything, so no STOP was required.

## Survival confirmations (explicit)

- **A survives:** `MinimizePlasticResult::solved_grid` (`pipeline.hpp:406`),
  `minimize_plastic_solved_grid` decl (`pipeline.hpp:438`) + def (`minimize_plastic.cpp:89`),
  `result.solved_grid = G` (`minimize_plastic.cpp:351`), and the two bridge.cpp call sites
  (`795–796`, `823`). No 3-arg `expand_design_domain` call anywhere (grep: every remaining
  reference is either a comment or the 5-arg driver/helper call or a deliberate negative
  test).
- **B survives:** `freeze_imported_part`-gated `design_mask` reject
  (`minimize_plastic.cpp:179–188`), pad merge into expanded mask at `domain.offset_*`
  (`202–225`), pad counted in `frozen_effective` (`322–324`), and the `if (!has_design_box)`
  guard removed so the pad is built on both paths (`bridge.cpp:720–728`).
- **079/080 defaults survive:** `expand_design_domain(..., bool freeze_part = true,
  int coarsen_align = 1)` (`voxel.hpp:205`); driver whole-domain default
  `options.freeze_imported_part = false` (`pipeline.hpp:176`).

## Proof — gates (fresh core build, OCCT+Eigen; lib3mf absent locally so DEPS=OFF, which
only skips the unrelated 3MF round-trip)

THE ONE RULE — no-box / JacobiCG default path byte-identical:

```
gate_v2 ..................... Passed  53.34 sec   (100% passed, 0 failed)
```

All required gates GREEN together (raw ctest, 13/13):

```
fea_cg ...................... Passed
fea_mgcg .................... Passed
fea_matfree ................. Passed
fea_mgcg_matfree ............ Passed
minimize_plastic ............ Passed
mma ......................... Passed
mma_projection_gate ......... Passed
design_domain ............... Passed   (add-material contract)
anchor_integrity ............ Passed   (no-box pad, 080)
designbox_reduction ......... Passed   (080)
designbox_padding ........... Passed   (079)
designbox_grid_report ....... Passed   (A)
designbox_anchor_pad ........ Passed   (B)
100% tests passed, 0 tests failed
```

## Commits reconciled

- A: `7ddf2c3` (branch tip), merged to main as `d93b558` (PR #93) — already on `main`.
- B: `4878201` "Restore anchor integrity on the design-box path (082)".
- Merge base: `47fda64`.

## Territory

Only what the merge required: `bridge.cpp`, `minimize_plastic.cpp`, `CMakeLists.txt`,
B's test + handoff, and this reconcile note. No fixtures, benchmarks, `materials.json`,
`ARCHITECTURE.md`, or ROADMAP box touched. No ROADMAP box checked.
