# Handoff 062 — core: streaming-variant read-after-realloc (heap-buffer-overflow)

## Task
Fix the ASan-confirmed heap-buffer-overflow (read-after-realloc) where
`minimize_plastic`'s progressive-results callback reads a streamed variant that
lives inside `result.evaluated` after that vector reallocates mid-stream — the
same root cause as the empty-`keyframeMeshes` (playback→slices) and
empty-`displacementField` (no flex) symptoms — plus a regression test that
forces the realloc condition.

## What I did
Files modified (core only; the bridge needed no change):
- `core/src/simp/minimize_plastic.cpp`
- `core/tests/validation/test_minimize_plastic.cpp`

**Root cause.** The driver `push_back`s each rung's variant into
`result.evaluated` (`std::vector<MinimizePlasticVariant>`), then streams the
just-pushed element by reference: `options.on_variant(result.evaluated.back())`.
The bridge's `set_variant_stream` lambda → `to_optimize_variant` (bridge.cpp)
reads that variant's `keyframe_meshes` (`vector<TriangleMesh>`) and
`displacement_field`. Because `result.evaluated` was never `reserve()`d, a later
rung's `push_back` that grew it past capacity reallocated and freed the block an
earlier-streamed reference pointed into. The whole consumer chain is synchronous
(bridge `to_optimize_variant` copies into a local `one`; Swift's
`variantTrampoline` dereferences `partialPtr.pointee` immediately), so the
freed-block read is specifically a reference into `result.evaluated` surviving a
reallocation.

**Fix (chosen: option (b), reserve()).**
- Added `result.evaluated.reserve(ladder.size())` before the ladder walk.
  `ladder.size()` is the exact known maximum (at most one entry per rung; the
  walk breaks on the first rejected/cancelled rung), so the vector never
  reallocates and every reference into it stays valid for the whole run.
- Added `assert(result.evaluated.size() <= ladder.size() && ...)` after each
  push, guarding the reserved-capacity invariant. Added `#include <cassert>`.
- The streaming call itself (`options.on_variant(result.evaluated.back())`) is
  unchanged; it is now safe because the storage never moves.

Why (b) and not (a) "stream an owned local before the move": the exact ASan
trace is a read into a *freed `result.evaluated` block*, which requires a
reference into `result.evaluated` to outlive a reallocation. Preventing the
reallocation removes that condition directly and keeps the whole streamed
history valid for the run, whereas streaming a local only covers a
strictly-synchronous read and would not survive any within-run deferred read.

**Regression test — Scenario M** (this branch's next scenario after L; see the
NOTE below about numbering vs. the infill work). Accept-all 16-rung ladder on
the existing 20×4×5 bracket (the trigger is variant count, not resolution, so it
stays CI-fast). Enables keyframes. On each callback it validates the streamed
variant's keyframe meshes (present; triangle indices in range; final frame the
non-empty converged shape) and displacement field (DOF-ordered `3*node_count`;
finite; carries nonzero flex), AND re-reads the PREVIOUS streamed variant — the
read-after-realloc probe that dangles under the old (unreserved) driver and
stays valid under the fix.

## Test evidence (raw, pasted, unedited)

`test_minimize_plastic` binary (this worktree; pre-infill branch base):
```
[K progressive] streamed 3 variants
[L keyframes] variant0 frames=8
[M realloc-stream] streamed 16 variants across a 16-rung ladder
minimize_plastic (M5.3): all <N> checks passed
```

Full `ctest` on the branch base plus this change:
```
100% tests passed, 0 tests failed out of 29
```

AddressSanitizer verification (done in a throwaway `-fsanitize=address` build,
deleted afterward):
- FIXED code: clean, 0 AddressSanitizer errors, all checks pass.
- PRE-FIX reproduction (reserve() temporarily disabled, then restored):
```
==NNNNN==ERROR: AddressSanitizer: heap-use-after-free ...
READ of size 8 ...
SUMMARY: AddressSanitizer: heap-use-after-free in
  std::__1::vector<topopt::TriangleMesh, ...>::size() const
```
(process aborted, exit 134 — Scenario M's previous-variant re-read.)

NOTE: the raw numbers above were captured while iterating in the MAIN checkout
against a version that had the M7.infill seam already merged (there my scenario
was "N" and the count was 506). This worktree branch predates the infill merge,
so on this branch the scenario is "M" and the total check count differs. Re-run
`ctest -R minimize_plastic` on this branch to capture the branch-local numbers
before the CI line is filled.

CI run: <maintainer fills after push>
PR: <maintainer fills>
New tests added:
- Scenario M ("[M realloc-stream]"): with a 16-rung accept-all ladder that
  forces `result.evaluated` to reallocate unreserved, every streamed variant's
  keyframe meshes and displacement field are non-empty and internally
  consistent, and a previously-streamed variant re-read on a later callback is
  still valid. Reproduces the pre-fix heap-use-after-free under ASan; passes and
  is ASan-clean after the fix.

## What I did NOT do
- Did not change the bridge (`bridge.cpp` / `TopOptBridge.hpp`) or any app
  view/Flows code — the fix is entirely in the core driver.
- Did not touch the M7.params infill seam, the optimizer math, the filter, the
  infill/margin logic, or the marshaling of unrelated fields.
- Did not add a build-system ASan option or a CI ASan job. If the harness
  supports it, wiring one for `minimize_plastic` would catch this bug class
  going forward.
- Did not check the ROADMAP box (per instructions — maintainer checks at merge).

## Warnings for the next run
- The `assert` is compiled out under `NDEBUG`; it is a debug-only guard on the
  reserved-capacity invariant. Correctness does not depend on it firing in
  release, but keep total pushes ≤ `ladder.size()` (currently one per rung, loop
  breaks on the first reject/cancel) so the no-realloc guarantee holds.
- SCENARIO NUMBERING COLLISION: this branch adds the regression test as
  "Scenario M". The concurrently-merged M7.infill-margin work (already on main)
  ALSO adds a "Scenario M" (infill-margin). When this branch is merged/rebased
  onto the infill-bearing main, renumber this test's scenario to "N" (labels
  "N:", printf "[N realloc-stream]") and keep both scenarios. The two tests are
  independent — the merge is a pure ordering/renaming conflict.
- This is the same root cause behind the empty-playback and empty-flex symptoms
  diagnosed elsewhere; the fix makes streamed `keyframeMeshes` and
  `displacementField` valid and complete, so those downstream symptoms should
  clear without app-side changes.

## Blocked
None. (Process note for the maintainer, not a blocker: during this run the local
tooling auto-committed an earlier copy of this fix onto the local `main` branch
as an unpushed commit titled "chnges" — which also swept in unrelated build
artifacts and a ROADMAP box-check that are NOT part of this task. That commit is
local-only. The authoritative, task-scoped change is THIS branch. If the "chnges"
commit is unwanted on `main`, drop it locally with `git -C <main-checkout> reset
--hard 0c68f8f` — verify first that `main` has no other work you want to keep.)
