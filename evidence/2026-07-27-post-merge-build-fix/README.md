# Evidence — post-merge build fix (PRs 205–209)

Handoff: `docs/handoffs/2026-07-27-post-merge-build-fix.md`

| File | Bar | What it shows |
|---|---|---|
| `F1-ios-device-build.txt` / `F1-ios-device-build-full.log` | F1 | `** BUILD SUCCEEDED **`, `arm64-apple-ios16.0`, `Debug-iphoneos/TopOpt.app` (real device destination). |
| `F2-macos-pkg-test-full.log` | F2 | Full package run: the ONLY failures are 3 `AppModelTests` 3MF tests, each with "lib3mf … not available in this build" (environmental — no vcpkg on this host). |
| `F2-macos-pkg-test-skip-lib3mf.log` | F2 | Same suite skipping those 3 lib3mf-dependent tests → 780 tests, 3 skipped, 0 failures, `** TEST SUCCEEDED **`; + 30-test bridge suite green. |
| `F3-production-parity-knockdown-checks.txt` | F3 | `production parity … all checks passed` — includes the new bridge≡CLI knockdown-posture asserts against `production_width_aware_knockdown()`. |
| `F3-core-ctest-full.log` | F3 + regression | Full core C++ suite: **100% tests passed out of 71** (proves the shared-builder refactor is byte-identical). |
| `F4-callsites.txt` | F4 | Every `analyze_fixed_design` call site; the bridge was the only missed caller. |
