#!/usr/bin/env bash
# build_core.sh — build the topopt core as a static library via CMake and vendor
# it (plus the OCCT headers/libs it needs) under the TopOptKit package, so
# `swift test` / `xcodebuild test` on app/TopOptKit can link it (ROADMAP M7.1;
# ARCHITECTURE §4 "core built into the app", §10 OCCT dynamic linking).
#
# This resolves the machine-specific absolute paths (Homebrew OCCT/Eigen) and
# exposes them to Package.swift only through package-relative symlinks under
# app/TopOptKit/vendor/, so the manifest itself stays machine-independent.
#
# macOS host build by default. For an iOS device slice, the maintainer re-runs
# CMake with an iOS toolchain and an iOS build of OCCT/lib3mf (not available in
# the current CI/dev environment) and points Package.swift's vendor at it, or
# packages an .xcframework — that is device-QA territory (ROADMAP M7 rules).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
PKG_DIR="$APP_DIR/TopOptKit"
VENDOR="$PKG_DIR/vendor"
BUILD_DIR="$APP_DIR/.build-core"

# --- locate dependencies -----------------------------------------------------
OCCT_PREFIX="${OCCT_PREFIX:-$(brew --prefix opencascade 2>/dev/null || true)}"
EIGEN_PREFIX="${EIGEN_PREFIX:-$(brew --prefix eigen 2>/dev/null || true)}"
if [[ -z "$OCCT_PREFIX" || ! -d "$OCCT_PREFIX" ]]; then
  echo "error: OpenCASCADE not found. Set OCCT_PREFIX or 'brew install opencascade'." >&2
  exit 1
fi
if [[ -z "$EIGEN_PREFIX" || ! -d "$EIGEN_PREFIX" ]]; then
  echo "error: Eigen not found. Set EIGEN_PREFIX or 'brew install eigen'." >&2
  exit 1
fi
OCCT_INCLUDE="$OCCT_PREFIX/include/opencascade"
OCCT_LIB="$OCCT_PREFIX/lib"

echo "==> OCCT:  $OCCT_PREFIX"
echo "==> Eigen: $EIGEN_PREFIX"

# --- configure + build the static library ------------------------------------
cmake -S "$CORE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DTOPOPT_REQUIRE_DEPS=OFF \
  -DCMAKE_PREFIX_PATH="$OCCT_PREFIX;$EIGEN_PREFIX" >/dev/null
cmake --build "$BUILD_DIR" --target topopt --config Release

LIB="$BUILD_DIR/libtopopt.a"
if [[ ! -f "$LIB" ]]; then
  echo "error: expected static library not produced at $LIB" >&2
  exit 1
fi

# --- vendor under the package (package-relative paths only) -------------------
mkdir -p "$VENDOR/lib"
cp -f "$LIB" "$VENDOR/lib/libtopopt.a"
ln -sfn "$CORE_DIR/include" "$VENDOR/include"
ln -sfn "$OCCT_INCLUDE" "$VENDOR/occt-include"
ln -sfn "$OCCT_LIB" "$VENDOR/occt-lib"

echo "==> vendored:"
echo "    $VENDOR/lib/libtopopt.a"
echo "    $VENDOR/include      -> $CORE_DIR/include"
echo "    $VENDOR/occt-include -> $OCCT_INCLUDE"
echo "    $VENDOR/occt-lib     -> $OCCT_LIB"
echo "==> done. Now: (cd $PKG_DIR && xcodebuild test -scheme TopOptKit -destination 'platform=macOS')"
