# Evidence — 3MF import on iPad / iOS lib3mf

Companion to `docs/handoffs/2026-07-26-lib3mf-ios.md`. Host: macOS 26.5.1,
CMake 4.4.0, Xcode 26.5; simulator iPhone 17 / iOS 26.5.

| file | shows | bar |
|---|---|---|
| `00_root_cause.txt` | CMake 4.4.0 + lib3mf v2.3.2's `cmake_minimum_required(VERSION 3.0)` | root cause |
| `01_prefix_configure_fails.txt` | the exact configure error the OLD script swallowed (`exit=1`) | root cause |
| `02_ios_dylib_arch_platform.txt` | cross-built dylibs: sim IOSSIMULATOR/arm64, device IOS/arm64, minos 16.0 | BLOCKED-STOP, L2 |
| `03_ios_sim_reads_real_3mf.txt` | iOS-sim-arch lib3mf reads real `plate_bore.3mf` on the sim runtime (208 v / 416 t, exit 0) | **L3** |
| `04_build_core_WITHOUT_ios_lib3mf.txt` | build succeeds; report says `.3mf` UNAVAILABLE on iPad + fix cmd | **L1** |
| `05_build_core_WITH_ios_lib3mf.txt` | report says 3MF available; iOS slices built WITH lib3mf, arm64-only sim | **L2** |
| `06_end_of_run_summary_states.txt` | new end-of-run summary in FAILED ❌ / SKIPPED / BUILT ✅ states | fix #1 |
| `10_macos_provision_lib3mf.txt` | vcpkg installs lib3mf **2.5.0#1** (CI pin) | L4 setup |
| `11_macos_2.5.0_reads_same_3mf.txt` | macOS 2.5.0 reads the same file identically (208 v / 416 t) | **L4**, version parity |
| `12_macos_build_cli.txt` | `topopt-cli` built with DEPS=ON + lib3mf (worker's exact binary) | **L4** |
| `13_cli_3mf_worker_real.txt` | CLI imports `.3mf`; `report.json` byte-identical to STL (same sha256) | **L4** |
| `14_lib3mf_2.5.0_ios_configure.txt` | lib3mf 2.5.0 cross-configures for iOS (exit 0), min 3.10, no shim needed | version rec |

## Key results
- **BLOCKED-STOP not triggered:** lib3mf cross-compiles for iOS.
- **Root cause:** CMake 4.x rejects lib3mf v2.3.2's pre-3.5 minimum; the old
  `build_lib3mf` returned 0 anyway → silent no-3MF build.
- **Version parity (measured):** 2.3.2 (iOS) and 2.5.0 (macOS) read the same
  `.3mf` to identical geometry.
- **Not produced:** physical-iPad app-UI import; full `xcodebuild` app-bundle
  Frameworks listing. See handoff "What I could not produce".
