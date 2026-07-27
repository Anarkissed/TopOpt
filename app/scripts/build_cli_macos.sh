#!/usr/bin/env bash
# build_cli_macos.sh — build the topopt-cli binary the LAN worker wraps, WITH 3MF
# support, on a developer/worker Mac. One command from a clean checkout.
#
# This is the macOS analogue of what CI's Configure step does on Linux: it
# configures core/ with -DTOPOPT_REQUIRE_DEPS=ON (so a missing dependency FAILS the
# build instead of silently dropping 3MF) and builds topopt-cli. The three deps:
#   * OpenCASCADE + Eigen — Homebrew (the established macOS toolchain, same as
#     build_core.sh; brew has no lib3mf formula).
#   * lib3mf            — vcpkg, at CI's exact pinned version, provisioned by
#     app/scripts/build_lib3mf_macos.sh (see that script for the route rationale).
#
# Result: `topopt-cli run job.json` imports a real .3mf end to end, identical to
# CI. Point the LAN worker at the printed binary:
#     TOPOPT_CLI=<printed path> python3 tools/topopt-worker/topopt_worker.py ...
#
#   ./app/scripts/build_cli_macos.sh          # provision lib3mf (if needed) + build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
BUILD_DIR="${TOPOPT_CLI_BUILD_DIR:-$CORE_DIR/build}"

# --- lib3mf via vcpkg (CI-matched) ------------------------------------------
# build_lib3mf_macos.sh is idempotent: it no-ops if lib3mf is already installed and
# emits the export lines we eval here (LIB3MF_PREFIX, lib3mf_DIR). Capture first so a
# provisioning failure aborts loudly instead of leaving LIB3MF_PREFIX unset.
LIB3MF_ENV="$("$SCRIPT_DIR/build_lib3mf_macos.sh" --print-env)" || {
  echo "error: lib3mf provisioning failed — see output above." >&2; exit 1; }
eval "$LIB3MF_ENV"

# --- OCCT + Eigen via Homebrew ----------------------------------------------
OCCT_PREFIX="${OCCT_PREFIX:-$(brew --prefix opencascade 2>/dev/null || true)}"
EIGEN_PREFIX="${EIGEN_PREFIX:-$(brew --prefix eigen 2>/dev/null || true)}"
if [[ -z "$OCCT_PREFIX" || ! -d "$OCCT_PREFIX" ]]; then
  echo "error: OpenCASCADE not found. 'brew install opencascade' or set OCCT_PREFIX." >&2
  exit 1
fi
if [[ -z "$EIGEN_PREFIX" || ! -d "$EIGEN_PREFIX" ]]; then
  echo "error: Eigen not found. 'brew install eigen' or set EIGEN_PREFIX." >&2
  exit 1
fi

echo "==> OCCT:   $OCCT_PREFIX"
echo "==> Eigen:  $EIGEN_PREFIX"
echo "==> lib3mf: $LIB3MF_PREFIX"

# --- configure + build (DEPS=ON: all three must be found, exactly like CI) ---
# lib3mf_FOUND / TOPOPT_HAVE_3MF are decided at CONFIGURE time and CACHED. A
# core/build left over from an earlier configure WITHOUT lib3mf (e.g. a plain
# build_core.sh run before lib3mf was provisioned) keeps `lib3mf_DIR-NOTFOUND`
# and a topopt-cli that rejects .3mf with "not available in this build" — the
# exact late-failure the LAN worker hit (handoff 2026-07-26-3mf-optimize-path).
# Re-running cmake over that cache does NOT re-search: find_package short-circuits
# on the cached NOTFOUND. So force a clean dependency re-resolution by dropping
# the cache (cheap; the object files rebuild only where the 3MF compile
# definition actually flipped). This makes a stale build structurally impossible.
if [[ -f "$BUILD_DIR/CMakeCache.txt" ]] &&
   ! grep -q "^lib3mf_DIR:.*$LIB3MF_PREFIX" "$BUILD_DIR/CMakeCache.txt" 2>/dev/null; then
  echo "==> stale $BUILD_DIR cache does not point at this lib3mf — clearing it"
  rm -f "$BUILD_DIR/CMakeCache.txt"
  rm -rf "$BUILD_DIR/CMakeFiles"
fi
echo "==> configuring core ($BUILD_DIR, TOPOPT_REQUIRE_DEPS=ON)"
cmake -S "$CORE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DTOPOPT_REQUIRE_DEPS=ON \
  -Dlib3mf_DIR="$LIB3MF_PREFIX/share/lib3mf" \
  -DCMAKE_PREFIX_PATH="$OCCT_PREFIX;$EIGEN_PREFIX;$LIB3MF_PREFIX"

echo "==> building topopt-cli"
cmake --build "$BUILD_DIR" --target topopt_cli --config Release

CLI="$BUILD_DIR/topopt-cli"
[[ -x "$CLI" ]] || { echo "error: build did not produce $CLI" >&2; exit 1; }

echo
echo "==> built $CLI"
"$CLI" --version 2>&1 | sed 's/^/    /' || true
echo
echo "Point the LAN worker at it:"
echo "    TOPOPT_CLI='$CLI' python3 tools/topopt-worker/topopt_worker.py --port 8757"
