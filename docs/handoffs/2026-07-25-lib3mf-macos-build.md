# 2026-07-25 — lib3mf on the macOS worker/CLI build (3MF import works on a real Mac)

**Track:** build/tooling (macOS). **Territory:** `app/scripts/build_lib3mf_macos.sh`
(new), `app/scripts/build_cli_macos.sh` (new), `app/scripts/build_core.sh`,
`app/TopOptKit/Package.swift`, `tools/topopt-worker/README.md`,
`tools/TopOptWorkerApp/README.md`. **No core/solver/optimizer change** — this is
purely the missing dependency plumbing plus its proof.

**Bars (all met):**
* one command from a clean checkout builds a `topopt-cli` whose import path reads a
  real `.3mf` end to end — the 3mf-enable fixture `plate_bore.3mf` — driven exactly
  as the LAN worker drives it (`topopt-cli run job.json --out …`) AND through the
  worker's HTTP path. Evidence transcripts in
  `evidence/2026-07-25-lib3mf-macos-build/`.
* the macOS lib3mf **version matches CI** (2.5.0#1) — same vcpkg registry + baseline,
  so behavior is identical (proven byte-identical to the STL run of the same part).
* `build_core.sh`'s iOS slices are unaffected (still OCCT-free fallback).

---

## 0. The gap (verified)

`core/vcpkg.json` lists `lib3mf` and CI installs it via vcpkg (DEPS=ON), so 3MF was
"enabled" (handoff `2026-07-24-3mf-enable`). But the **macOS** build had no lib3mf:
`build_core.sh` pulls OCCT/Eigen from Homebrew, lib3mf **is not a brew formula**, and
building it from a plain `git clone` fails on unfetched submodules (libzip → missing
`config.h`). So on every real Mac `find_package(lib3mf CONFIG)` went QUIET, the
worker/CLI was built without `TOPOPT_HAVE_3MF`, and any `.3mf` job died with *"this
build has no 3MF support (lib3mf was not available)"*. 3MF import was dead outside
CI.

## 1. Route taken — and why

**vcpkg-sourced lib3mf at CI's exact baseline, classic mode (lib3mf only), keeping
Homebrew OCCT + Eigen.** Not the full vcpkg *manifest* (which the task offered first),
and not a hand-built lib3mf (the offered fallback). Reasoning:

* **Version parity is the bar**, and it is about *lib3mf*. Installing lib3mf from a
  vcpkg checked out at CI's pinned tag (`.github/workflows/ci.yml` → `2026.06.24`,
  whose commit is `core/vcpkg.json`'s `builtin-baseline`) yields the **exact** CI
  version `2.5.0#1` from the **exact** CI registry and source — no drift. (The prior
  3mf-enable handoff hand-built **2.3.2**, a mismatch; this fixes that.)
* **The full manifest would also rebuild OpenCASCADE from source** on macOS
  (30–60+ min) and diverge from the Homebrew OCCT the rest of the macOS build (and
  `build_core.sh`) already uses. Pointless cost + a second OCCT. So OCCT/Eigen stay
  on Homebrew (unchanged), and only the missing piece — lib3mf — comes from vcpkg.
* **vcpkg sidesteps the submodule breakage entirely.** The vcpkg `lib3mf` port takes
  its dependencies (`libzip`, `zlib`, `cpp-base64`, `fast-float`) as vcpkg
  *packages*, not git submodules, so the `config.h` failure the from-source fallback
  hits never occurs. No hand-built libs.
* Dynamic triplet (`arm64-osx-dynamic` / `x64-osx-dynamic`) matches CI's
  `x64-linux-dynamic` and the SHARED `lib3mf::lib3mf` imported target
  `core/CMakeLists.txt` links (lib3mf is BSD; ARCHITECTURE §10).

## 2. What shipped

**`app/scripts/build_lib3mf_macos.sh`** (new) — the one-command provisioner. Clones
vcpkg at the CI tag into `.vcpkg/` (root-gitignored, same layout CI uses),
bootstraps, and `vcpkg install lib3mf:<triplet>` (classic mode, this port only).
Idempotent (no-ops if already installed); `--print-env` emits `export LIB3MF_PREFIX=…`
for callers. Preflights `pkg-config` (a real clean-Mac prereq vcpkg needs to build
libzip's deps) with the exact fix.

**`app/scripts/build_cli_macos.sh`** (new) — the macOS analogue of CI's Configure
step: runs the provisioner, resolves Homebrew OCCT + Eigen, configures `core/` with
`-DTOPOPT_REQUIRE_DEPS=ON` (a missing dep now FAILS, exactly like CI), builds
`core/build/topopt-cli`, and prints the ready-to-run `TOPOPT_CLI=… python3
topopt_worker.py` line.

**`app/scripts/build_core.sh`** (app xcframework) — now DETECTS the provisioned
lib3mf (env `LIB3MF_PREFIX` or the default vcpkg install path) and, when present,
builds the **macOS slice WITH lib3mf** (so a macOS package build/test gets 3MF import
too) and vendors the dylib as `vendor/lib3mf-lib`. When absent it prints a one-line
hint and builds the macOS slice lib3mf-free — **today's exact behavior**. It does
NOT trigger the vcpkg build itself. **iOS slices are untouched** (they get lib3mf only
via `build_occt_ios.sh`, unchanged).

**`app/TopOptKit/Package.swift`** — adds the macOS lib3mf link flags
(`-L vendor/lib3mf-lib -l3mf` + an `-rpath` to it, since the dylib's install name is
`@rpath/lib3mf.N.dylib`) **gated on `vendor/lib3mf-lib` existing on disk** — the same
"disk presence is the gate" pattern the OCCT frameworks already use. No symlink →
no flags → a checkout without lib3mf links exactly as before (CI/macOS stay green).

## 3. Proof (the actual command sequence a user runs)

From a clean checkout (`brew install opencascade eigen pkg-config` once):

```
./app/scripts/build_cli_macos.sh          # provisions lib3mf@2.5.0#1 + builds topopt-cli
topopt-cli run job_3mf.json --out out_3mf # model: plate_bore.3mf  →  report + variants + fields
```

* `otool -L topopt-cli` shows `@rpath/lib3mf.2.5.0.0.dylib`; `vcpkg list` shows
  `lib3mf:arm64-osx-dynamic 2.5.0#1` (== CI). — `evidence/02_cli_links_lib3mf.txt`
* the `.3mf` run: `model: plate_bore.3mf (7 pseudo faces, 1 fixture faces matched)`,
  2 variants accepted, `report.json` + meshes + `run_info.json` written. The **same
  part as STL is byte-identical** (same `report.json` sha256, same variant meshes) —
  the strongest form of "STL and 3MF agree", matching the 3mf-enable bar. —
  `evidence/03_cli_e2e_3mf_byte_identity.txt`
* the LAN **worker HTTP** path: `POST plate_bore.3mf` → worker shells `topopt-cli
  run` → `state:"done"`, `run_info.json` on disk, worker.log shows the import line. —
  `evidence/04_worker_http_3mf.txt`
* the previously-**CI-only** 3MF ctests now pass on the Mac build with this vcpkg
  lib3mf: `export_3mf`, `cli_demo` (pristine 3MF-output job), `threemf_import`
  (import equivalence + end-to-end + byte-identity) — 3/3. —
  `evidence/05_ctest_3mf_gates.txt`
* `build_core.sh` green: macOS slice "Eigen + OCCT + lib3mf", iOS slices "OCCT-free",
  xcframework assembled, `vendor/lib3mf-lib` symlinked. The macOS app test bundle
  links + embeds lib3mf (rpath) via the gated Package.swift flags. —
  `evidence/06_build_core_and_app_link.txt`

## 4. Scope / honesty

* **OCCT/Eigen stay on Homebrew** — unchanged. Only lib3mf is new, and only from
  vcpkg. This is deliberate (§1), not an oversight.
* **`pkg-config` is a new clean-Mac prereq** for the vcpkg route (needed to build
  libzip's transitive deps). The provisioner preflights it with the one-line fix;
  the worker README lists it.
* **macOS app slice now compiles 3MF in when provisioned.** The 3mf-enable handoff
  had scoped the app slice out; this brings it in for **macOS** (the dev/worker Mac)
  via the gated Package.swift link. The **iOS** app slice is still lib3mf-free
  (on-device 3MF import remains the `build_occt_ios.sh` app-build task) — out of
  scope here and explicitly unaffected.
* **The vcpkg tree lives in `.vcpkg/`** (root-gitignored) — nothing committed but the
  scripts, docs, and evidence.
