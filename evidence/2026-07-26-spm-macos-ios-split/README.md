# Evidence — SwiftPM macOS/iOS OCCT product split (2026-07-26)

Handoff: `docs/handoffs/2026-07-26-spm-macos-ios-split.md`

| File | Bar | What it shows |
|---|---|---|
| `P0-repro-BEFORE-package-macos.log` | repro | Unmodified manifest, `TopOptKit-Package` on macOS with `vendor/occt-ios` populated → **47×** `no library for this platform` in target `TopOptOCCT`, tests never reached. |
| `P1-AFTER-fix-package-macos-POPULATED.log` | P1 | Fixed manifest, occt-ios **populated** → **0** no-library errors, tests run. Only the pre-existing paint test fails. |
| `P1-CLEAN-populated-skip-preexisting-paint.log` | P1 | Same, skipping only the proven-pre-existing paint test → **`** TEST SUCCEEDED **`**, all bundles pass. |
| `P2-AFTER-fix-package-macos-ABSENT.log` | P2 | Fixed manifest, occt-ios **absent** (committed default) → **0** binary-artifact / no-library errors, tests run. Same single pre-existing failure only. |
| `P3-BASELINE-before-fix-app-frameworks.txt` | P3 | `.app/Frameworks` from the **unmodified** manifest — 47 OCCT frameworks (baseline). |
| `P3-AFTER-fix-app-frameworks.txt` | P3 | `.app/Frameworks` from the **fixed** manifest — 47 OCCT frameworks incl. `TKDESTEP`. `diff` vs baseline = identical. |
| `P3-AFTER-fix-ios-app-build.log` | P3 | The iOS-simulator app build, `** BUILD SUCCEEDED **`. |
| `P4-AFTER-fix-step-import-ios.log` | P4 | STEP import **runs on the iOS simulator**: `STEP-IMPORT-PROOF … triangleCount=236 …`, `** TEST SUCCEEDED **`. |
| `DIAG-paint-test-passes-with-PR186-fix.log` | caveat | The one macOS failure disappears when `main`'s PR-186 version of that test file is used → the failure is pre-existing, not from this change. |
| `CHANGE-package-and-buildscript.diff` | — | The full source diff (Package.swift + build_core.sh). |

All iOS builds are arm64-only because the OCCT-linked simulator slice is arm64-only.
