# Handoff 068 — MMA projection-gate (Option B): skip projection under MMA

## Task
TRACK core+bridge. Resolve the MMA-vs-projection incompatibility with the quick
unblock (Option B). After the M7.mma.4 switchover MMA is the default updater, but
the app run path (`run_minimize_plastic_loadcase` → `enable_projection`) turns on
a Heaviside projection schedule, and `simp_optimize` rejects MMA + projection
("MMA updater does not support a Heaviside projection schedule; use OC or clear
options.projection"). So real app runs now fail.

**Fix:** gate projection on the updater. Enable the Heaviside schedule on the run
path ONLY when the updater is OC; when the updater is MMA (the default), skip the
schedule so MMA runs cleanly. Temporary measure — crisp-density projection on MMA
is a deferred future task (Option A), so MMA results have slightly softer density
boundaries for now. Do NOT change the optimizer math, the MMA implementation, or
OC's projection behavior — OC + projection stays byte-identical (Gate-V2).

## Worktree
`/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/mma-projection-gate-cda4c6`
Branch `claude/mma-projection-gate-cda4c6`. macOS, AppleClang, C++17,
`-DCMAKE_BUILD_TYPE=Release` (Eigen + OCCT via brew found through the QUIET path;
lib3mf absent, so `export_3mf` degrades to STL and `cli_demo` runs its STL path —
the same 31-test local profile the earlier MMA handoffs used; CI runs all under
`-DTOPOPT_REQUIRE_DEPS=ON`). ROADMAP box **not** checked (as instructed).

## Root cause
`MinimizePlasticOptions::updater` defaults to `MMA` (pipeline.hpp:143) and
replaces `simp.updater` for every ladder rung. The bridge's `enable_projection`
(bridge.cpp) unconditionally set `opts.simp.projection =
heaviside_continuation_schedule()`. Neither bridge run entry point
(`run_minimize_plastic` at bridge.cpp:399, `run_minimize_plastic_loadcase` at
:484) overrides `opts.updater`, so it stays MMA — and `validate_updater_options`
(simp.cpp:72) throws on MMA + a non-empty projection schedule. Every real run
threw.

## What I did

### 1. Core — a pure, testable gate predicate (`core/include/topopt/simp.hpp`)
Added, right after `enum class SimpUpdater`:

```cpp
constexpr bool projection_supported(SimpUpdater updater) {
  return updater == SimpUpdater::OC;
}
```

This is the single source of truth for "may a Heaviside projection schedule be
applied for this updater?" — OC yes, MMA no. It mirrors exactly the incompatibility
that `validate_updater_options` enforces, but as a *decision* callers can gate on
instead of a *rejection* they must avoid. Pure/`constexpr`, additive, changes no
existing behavior. Doc comment marks it TEMPORARY (Option B) and points at the
deferred Option A. `validate_updater_options` (the low-level guard) is UNCHANGED —
it still throws, so the core contract is untouched.

### 2. Bridge — gate `enable_projection` on the updater (`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`)
```cpp
void enable_projection(topopt::MinimizePlasticOptions& opts) {
  // ... TEMPORARY (Option B) comment ...
  if (topopt::projection_supported(opts.updater))
    opts.simp.projection = topopt::heaviside_continuation_schedule();
  opts.min_feature_mm = 2.5;  // mm; per-rung -> filter_radius = 2.5 / spacing
}
```

- The projection schedule is now applied **only under OC**. Under MMA the schedule
  is left empty, so the run completes cleanly (softer density boundaries).
- `min_feature_mm` stays set for **both** updaters. It is a physical filter radius,
  NOT projection — valid on any updater, and keeping it unconditional means the
  OC + projection path is byte-identical to before (Gate-V2 unchanged).
- `enable_projection` is the single helper both run entry points call, so both
  `run_minimize_plastic` and `run_minimize_plastic_loadcase` are covered by the
  one gate. No other site assigns `opts.simp.projection` on the run path (grep).

Only WHEN projection is enabled changed — based on the updater. The optimizer math,
the MMA implementation, and OC's projection behavior are all untouched.

### 3. Test — `core/tests/validation/test_mma_projection_gate.cpp` (+ CMake `mma_projection_gate`)
The gate lives in the bridge (`enable_projection`), a SwiftPM C++ target that is
NOT part of the core CMake/ctest build — so it can't be ctested directly. The
*decision* it makes is the pure core predicate `projection_supported`, which IS in
the ctest build. The test pins the predicate and both loop configs it selects,
driving the public `simp_optimize` (no mesh/STL needed), and mirrors
`enable_projection`'s exact logic via a `gated_options(updater, schedule)` helper:

- **Predicate:** `projection_supported(OC)==true`, `projection_supported(MMA)==false`.
- **(a) MMA:** an ungated MMA + projection config still throws `invalid_argument`
  (the bug); the *gated* MMA config has projection cleared and now runs without
  throwing, reduces compliance, and meets the volume target. Proves the gate is
  what unblocks the run.
- **(b) OC:** the gated OC config keeps the schedule and is **byte-identical**
  (design, physical_density, compliance, iterations) to the ungated OC + projection
  run — the gate is a no-op for OC. And projection visibly takes effect: the
  projected design is crisper (fraction near 0/1) than the plain no-projection OC
  loop on the same problem.

Direct run: `mma-projection-gate: all 10 checks passed`
(`crisp(projected)=0.146` vs `crisp(plain)=0.090`).

Registered next to `test_mma`, inside the Eigen-gated block.

## Scope compliance
- Touched: `core/include/topopt/simp.hpp`, `core/CMakeLists.txt`,
  `core/tests/validation/test_mma_projection_gate.cpp` (core),
  `app/TopOptKit/Sources/TopOptBridge/bridge.cpp` (bridge). All within the
  core+bridge track.
- Did NOT touch app view/Flows, `tests/fixtures/**`, or `ROADMAP.md`. ROADMAP box
  left unchecked.
- Did NOT change optimizer math, MMA, OC projection, or `validate_updater_options`.

## Tests — raw ctest
Full local suite (Release, Eigen+OCCT present, lib3mf absent → 31-test profile):

```
19/31 Test #19: gate_v2 ..........................   Passed   64.37 sec
23/31 Test #23: minimize_plastic .................   Passed   25.15 sec
25/31 Test #25: mma ..............................   Passed   55.18 sec
26/31 Test #26: mma_projection_gate ..............   Passed    1.23 sec
27/31 Test #27: stress ...........................   Passed   21.51 sec
31/31 Test #31: cli_demo .........................   Passed  386.09 sec

100% tests passed, 0 tests failed out of 31
Total Test time (real) = 677.66 sec
```

(tests #1–#8 scrolled off the captured tail; the summary line is authoritative —
all 31 passed, exit 0.) `gate_v2` (the OC-locked projected chain) and `mma` are
unchanged, confirming OC + projection stays byte-identical and MMA behavior is
otherwise untouched. The new `mma_projection_gate` covers acceptance criteria
(a) and (b).

## Follow-up (out of scope here)
Option A — projection-on-MMA support (chain the projection derivative through the
MMA subproblem so MMA can produce crisp density too). Until then MMA designs have
softer density boundaries; the gate and `projection_supported` should be removed
(or inverted) when that lands.
```
