# Post-merge build fix (PRs 205–209) — app + bridge

**Date:** 2026-07-27
**Branch:** `claude/post-merge-build-break-090c60`
**Evidence:** `evidence/2026-07-27-post-merge-build-fix/`

After merging PRs 205, 206, 207, 208, 209 into `main`, the iOS build was broken by
**two independent merge casualties**. Both are fixed here; nothing else in the merged
PRs is touched.

---

## Break 1 — core/bridge: `KnockdownSpec` could not bind to `const double`

**Cause.** PR 206 (width-aware accept-gate knockdown) changed
`analyze_fixed_design`'s trailing knockdown parameter from a bare scalar
`double infill_knockdown` to `const KnockdownSpec&`
([`core/include/topopt/analyze.hpp:120`](../../core/include/topopt/analyze.hpp)).
PR 206 updated its two core call sites (`run_job.cpp`, `minimize_plastic.cpp`) but
**missed the app bridge**, which kept passing a bare `double`
(`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`).

**Fix — and the posture chosen.** The bridge does **not** cast/wrap at the call site.
The whole point of the `KnockdownSpec` is the accept-gate *posture*, and the danger the
task flagged is real: if the on-device bridge silently gets a different knockdown than
the Mac worker, the iPad and the Mac certify the **same part differently**.

PR 206 armed the width-aware composite behind the named constant
`kProductionWidthAwareKnockdown`, **shipped default `false`** (pure `f^1.5` scalar
gate, byte-identical to the pre-width gate). The bridge already builds its options with
`configure_production_options(opts)` — the exact same call the CLI/worker uses — so the
correct posture for the bridge is **whatever those production options carry**, read off
the options object, never a literal.

To make "bridge ≡ CLI" structural instead of three hand-copied field blocks that can
drift (which is exactly how this break happened), the four-line `KnockdownSpec`
construction was extracted into **one shared builder**:

```cpp
KnockdownSpec knockdown_spec_for(const MinimizePlasticOptions& opts);  // production.hpp
```

- `core/src/simp/production.cpp` — the one definition (next to
  `configure_production_options` / `production_width_aware_knockdown`).
- Routed through it: the optimizer's per-rung gate (`minimize_plastic.cpp`), the CLI
  standalone re-analysis (`run_job.cpp`), and the on-device bridge (`bridge.cpp`).

All three now build the identical spec by construction. In the shipped config
`width_aware == false`, so the bridge gates on the pure `f^1.5` scalar — **byte-identical
to before**. If a maintainer ever flips `kProductionWidthAwareKnockdown`, the bridge
picks it up automatically because it reads the shared options object.

**This refactor is byte-identical.** `test_analyze_fixed_design` (which asserts the
optimizer's own gate equals a standalone `analyze_fixed_design` **bit-for-bit**) passes,
and the full 71-test core suite is 100% green — see F3 below.

## Break 2 — app: `Cannot find 'gizmoAt' in scope`

**Cause.** `gizmoAt(proj, tipModel)` is called from the gravity-arrow overlay
(`WorkspacePlaceholder.swift`, `gravityDirectionOverlay`) but had **no definition on
main**. The helper belongs to PR 199's gravity widget; its definition was lost when
PR 205's transform-gizmo rebuild (which removed the *other* `gizmoAt` call sites)
resolved its conflict with PR 199.

**Fix.** Recovered the **original** definition verbatim from PR 199's branch
(`claude/gravity-direction-widget-1d8c94`, was at line 1649) and restored it next to the
other gizmo helpers. It is byte-identical to what PR 199 shipped:

```swift
/// Project a model-space anchor and position a knob there (knob keeps its own gesture,
/// applied BEFORE `.position` — the camera-non-fighting rule).
@ViewBuilder private func gizmoAt(_ proj: CameraProjection, _ p: SIMD3<Double>,
                                  @ViewBuilder _ knob: () -> some View) -> some View {
    if let pt = proj.project(settledWorld(SIMD3<Float>(p))) { knob().position(pt) }
}
```

No guesswork, no reimplementation — the gravity widget behaves exactly as PR 199 shipped
and tested it.

---

## Bars

### F1 — iOS build succeeds for a real device destination
`xcodebuild build -project TopOpt.xcodeproj -scheme TopOpt -destination
'generic/platform=iOS' -configuration Debug` → **`** BUILD SUCCEEDED **`**, linking
`Debug-iphoneos/TopOpt.app` for `arm64-apple-ios16.0`. Both fixes compiled and linked
for device. (`build_core.sh` was re-run first so the vendored xcframework carries the new
`knockdown_spec_for` symbol + updated headers.)
Evidence: `F1-ios-device-build.txt`, `F1-ios-device-build-full.log`.

### F2 — macOS package tests pass
`xcodebuild test -scheme TopOptKit-Package -destination 'platform=macOS'`.
- Full run: the **only** failures are 3 tests, all in `AppModelTests`, all failing with
  the literal refusal *"3MF import requires lib3mf, which is not available in this
  build"*. This host has **no vcpkg**, so `build_core.sh` built the macOS slice
  3MF-free. These failures are **environmental and pre-existing** — orthogonal to this
  fix (which touches knockdown + gizmo, not 3MF) — and would pass on CI, which provisions
  lib3mf. See memory `threemf-import-enabled`.
- Skipping exactly those 3 lib3mf-dependent tests: **780 tests, 3 skipped, 0 failures →
  `** TEST SUCCEEDED **`**, plus the 30-test bridge suite green.
Evidence: `F2-macos-pkg-test-full.log` (shows the only failures are the lib3mf ones),
`F2-macos-pkg-test-skip-lib3mf.log` (clean pass).

### F3 — the bridge and the CLI agree (asserted against the named constant)
Added to `test_production_parity.cpp` (the existing parity suite): after
`configure_production_options`, assert the **shared builder's** posture —
`knockdown_spec_for(opts).width_aware` (what the bridge passes) — equals
`production_width_aware_knockdown()` (the named constant the config arms), equals
`opts.width_aware_knockdown`, and reduces to the shipped-default `false`; plus the
infill/wall fields mirror the options. **This break existed precisely because nothing
checked that.** `production_parity` passes. Evidence:
`F3-production-parity-knockdown-checks.txt`, `F3-core-ctest-full.log`
(**100% tests passed out of 71**).

### F4 — any other missed caller of a PR-206-changed signature?
PR 206 changed exactly **one** existing signature: `analyze_fixed_design`
(scalar → `const KnockdownSpec&`). Its other additions (`wall_area_fraction`,
`width_aware_knockdown`, `production_width_aware_knockdown`, `local_member_thickness_mm`)
are brand-new functions with no prior callers. Every `analyze_fixed_design` call site:

| Call site | State |
|---|---|
| `core/src/cli/run_job.cpp:464` | updated by PR 206 (now via shared builder) |
| `core/src/simp/minimize_plastic.cpp:1031` | updated by PR 206 (now via shared builder) |
| `core/tests/unit/test_analyze_fixed_design.cpp:183,226,240` | shipped with PR 206 |
| `core/tests/harness/width_aware_gate.cpp:91` | shipped with PR 206 |
| **`app/TopOptKit/Sources/TopOptBridge/bridge.cpp:801`** | **the miss — fixed here** |

The build found two (run_job, minimize_plastic compiled fine; the bridge did not); the
grep confirms the bridge was the **only** unmigrated caller. No others missed.
Evidence: `F4-callsites.txt`.

### F5 — the gravity widget still works
All **11 `GravityDirectionTests` (PR 199's tests) pass** (snap to every signed axis,
exact-not-approximate snap, tolerance boundary, both setters store the same vector,
widget↔face-tap produce identical jobs, undo/round-trip). The `gizmoAt` definition was
recovered **verbatim** (git-confirmed byte-identical to PR 199) and compiles for device,
so the draggable arrow knob renders and positions as PR 199 shipped it.

**No PR-199 test covers `gizmoAt` directly** — grep finds zero references to it in any
test. It is a `private @ViewBuilder` SwiftUI positioning helper (project a model anchor →
`.position` a knob), which unit tests don't reach; the arrow-render claim rests on the
verbatim recovery + device compile + the green gravity-logic suite, not a live UI
snapshot.

---

## Files changed
- `app/TopOptKit/Sources/TopOptBridge/bridge.cpp` — bridge builds `KnockdownSpec` via the shared builder.
- `app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift` — restored `gizmoAt`.
- `core/include/topopt/production.hpp` — declare `knockdown_spec_for`; include `analyze.hpp`.
- `core/src/simp/production.cpp` — define `knockdown_spec_for` (the one construction).
- `core/src/cli/run_job.cpp`, `core/src/simp/minimize_plastic.cpp` — route through the shared builder (byte-identical).
- `core/tests/validation/test_production_parity.cpp` — the F3 parity assertions.

(The PNG churn in `git status` is test-generated evidence-capture output from running the
macOS suite, not part of this fix.)
