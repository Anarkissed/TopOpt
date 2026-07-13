# Handoff 066 — remove the diag-064 load-path/stress instrumentation

**Track:** core (`/core/`) + app (`/app/`) cleanup. This reverts the temporary
diagnostic logging added in handoff **064-INSTRUMENT-loadpath-stress**. No real
logic, BC, math, or anchor-integrity fix was touched — only the `TEMP-INSTRUMENT`
log statements and the scratch variables/loops that existed solely to feed them.
The ROADMAP box was **not** checked (this is cleanup, not a roadmap task).

**Worktree:** `/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/modest-rubin-1fe0ef`
**Branch:** `claude/remove-temp-instrumentation-5beef6` (base `d4b02a7`).

---

## What was removed

All 18 `TEMP-INSTRUMENT`-tagged sites across three source files, plus their
dedicated scratch code and now-unused `<cstdio>` includes:

### `core/src/simp/minimize_plastic.cpp`
- `#include <cstdio>` (only present for the diag `std::fprintf`s — no other
  `printf`/`stderr`/`fopen` usage in the TU, verified by grep).
- The load-path log block + its `load_abs_sum` accumulator loop (log #6).
- The two-solves peak-VM log block + its `display_peak_vm` scan loop (log #5A).
- The acceptance-decision log after `variant.accepted = …` (log #5B).
- **Kept untouched:** the `loads` selection, `variant.accepted` computation,
  `compute_stress_margin`, the infill-knockdown gate, and every field assignment.

### `app/TopOptKit/Sources/TopOptBridge/bridge.cpp`
- `#include <cstdio>` (only present for the diag `std::fprintf`s — verified by grep).
- The per-load-group force/face log (log #3, part A).
- The `tagged_load_voxels` counter + its triple-nested recount loop + the
  any/empty-group log (log #3, part B).
- The `ext_abs_sum` accumulator + total-applied-force log block (log #2).
- The `any_fixture`/clamped-nodes log before the min-x fallback (log #4).
- **Kept untouched:** the zero-force `continue` skip, the `bool any` /
  `if (!any) continue;` empty-group skip, `retained_load_faces`, the `any_fixture`
  variable and the min-x Dirichlet fallback it gates, and all traction/BC assembly.

### `app/TopOptKit/Sources/TopOptFlows/RunModel.swift`
- The `isStepModel`/load-group dump `NSLog` block at the top of `bridgeRunner`
  (log #1), including the per-group `fsum` loop.
- **Kept untouched:** the STEP vs STL branch and both `minimizePlastic*` calls.

## Grep confirmation — ZERO matches

```
$ grep -rn "TEMP-INSTRUMENT" core/src app/TopOptKit
$ echo $?
1        # grep found nothing → exit 1
```

(The only remaining hit anywhere was inside a tracked build artifact,
`core/build-release/Testing/Temporary/LastTest.log.tmp*`, which is removed below.)

## Build-artifact tracking removed

`core/build-release/` (54 files: `libtopopt.a`, CMake trees, CTest logs, cli_out*
STLs, …) was committed to git. Untracked it and ignored it going forward:

```
$ git rm -r --cached core/build-release      # 54 files removed from the index
$ git check-ignore core/build-release/Makefile
core/build-release/Makefile                   # now ignored
```

`.gitignore` gains one line under the CMake/build-trees section:

```
 # CMake / build trees
 build/
+build-release/
 cmake-build-*/
```

---

## Verification

### Core — build + raw `ctest`

`cmake --build core/build` compiled clean. Full suite from `core/build`:

```
      Start 13: beam_validation
13/30 Test #13: beam_validation ..................   Passed   61.86 sec
14/30 Test #14: gate_v4 ..........................   Passed    0.69 sec
15/30 Test #15: gate_v5 ..........................   Passed    0.48 sec
16/30 Test #16: simp .............................   Passed    0.73 sec
17/30 Test #17: rmin .............................   Passed    0.32 sec
18/30 Test #18: mbb_validation ...................   Passed    4.31 sec
19/30 Test #19: gate_v2 ..........................   Passed   64.69 sec
20/30 Test #20: property_v3 ......................   Passed    3.37 sec
21/30 Test #21: variants .........................   Passed    6.47 sec
22/30 Test #22: passive_regions ..................   Passed    8.72 sec
23/30 Test #23: minimize_plastic .................   Passed   23.21 sec
24/30 Test #24: anchor_integrity .................   Passed    4.49 sec
25/30 Test #25: mma ..............................   Passed   47.99 sec
26/30 Test #26: stress ...........................   Passed   21.13 sec
27/30 Test #27: step_import ......................   Passed    0.31 sec
28/30 Test #28: face_tag .........................   Passed    0.42 sec
29/30 Test #29: mask_face ........................   Passed    0.47 sec
30/30 Test #30: cli_demo .........................   Passed  416.62 sec

100% tests passed, 0 tests failed out of 30

Total Test time (real) = 693.64 sec
```

### App package — `xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`

Core xcframework re-vendored first via `./app/scripts/build_core.sh` (so the
macOS slice picks up the `minimize_plastic.cpp` change), then the full package
test suite (which compiles the edited `bridge.cpp` + `RunModel.swift`):

```
Test Case '-[TopOptKitTests.TopOptKitTests testMinimizePlasticLoadCaseUsesDeclaredForces]' passed (10.108 seconds).
Test Case '-[TopOptKitTests.TopOptKitTests testMinimizePlasticResultsFields]' passed (5.876 seconds).
Test Case '-[TopOptKitTests.TopOptKitTests testMinimizePlasticWithProgress]' passed (5.651 seconds).
Test Case '-[TopOptKitTests.TopOptKitTests testMinimizePlasticCancel]' passed (0.011 seconds).
... (all 21 cases passed)
Test Suite 'TopOptKitTests' passed at 2026-07-12 23:51:14.505.
	 Executed 21 tests, with 0 failures (0 unexpected) in 21.963 (21.970) seconds
Test Suite 'All tests' passed at 2026-07-12 23:51:14.505.
	 Executed 21 tests, with 0 failures (0 unexpected) in 21.963 (21.971) seconds

** TEST SUCCEEDED **
```

---

## Diff summary

```
 .gitignore                                       |  1 +
 app/TopOptKit/Sources/TopOptBridge/bridge.cpp    | 47 ------------------------
 app/TopOptKit/Sources/TopOptFlows/RunModel.swift | 12 ------
 core/src/simp/minimize_plastic.cpp               | 43 ----------------------
 4 files changed, 1 insertion(+), 102 deletions(-)
 + 54 deletions of core/build-release/** from the index (git rm --cached)
```

## Notes for the maintainer

- Nothing in the runtime behavior changes: the removed code only wrote to
  `stderr`/`NSLog` and accumulated locals consumed exclusively by those writes.
- `core/build-release/` still exists on disk (untouched build output) — it is
  simply no longer tracked. Delete it locally if you want; git now ignores it.
- The diag docs `064-INSTRUMENT-loadpath-stress.md` and
  `064-DIAGNOSIS-anchor-eaten-and-zero-stress.md` are left in place as history.
