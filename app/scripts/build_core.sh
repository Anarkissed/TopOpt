#!/usr/bin/env bash
# build_core.sh — build the topopt core as a multi-platform static-library
# xcframework and vendor it (plus the OCCT libs the macOS slice needs) under the
# TopOptKit package, so both `xcodebuild test` on the package (macOS) and the
# iPad app (iOS simulator + device) can link it (ROADMAP M7.1; ARCHITECTURE §4
# "core built into the app", §10 OCCT dynamic linking).
#
# Slices (all arm64 — Apple Silicon host, arm64 simulators, arm64 devices):
#   macOS            : Eigen + OpenCASCADE  -> STEP import + full pipeline
#   iOS simulator    : Eigen only           -> OCCT-free (no STEP; STL + SIMP + export)
#   iOS device       : Eigen only           -> OCCT-free
# OpenCASCADE is not available for iOS (Homebrew ships macOS only), so the iOS
# slices are built with OCCT disabled; the bridge compiles STEP import/tagging
# only where TOPOPT_BRIDGE_HAS_OCCT is defined (macOS) and returns a clear
# "not available on this platform" error elsewhere. lib3mf is likewise absent
# (STL export is pure C++; 3MF export is M7.9). Eigen is header-only, so it is
# reused across all three slices.
#
# The absolute machine paths (Homebrew OCCT/Eigen) are resolved here and exposed
# to Package.swift only through the package-relative vendor/ tree, so the
# manifest stays machine-independent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
PKG_DIR="$APP_DIR/TopOptKit"
VENDOR="$PKG_DIR/vendor"
BUILD_ROOT="$APP_DIR/.build-core"

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
echo "==> OCCT:  $OCCT_PREFIX"
echo "==> Eigen: $EIGEN_PREFIX"

# build_slice <name> <archs> <extra-cmake-args...> -> echoes the produced libtopopt.a
build_slice() {
  local name="$1"; local archs="$2"; shift 2
  local dir="$BUILD_ROOT/$name"
  rm -rf "$dir"
  cmake -S "$CORE_DIR" -B "$dir" \
    -DCMAKE_BUILD_TYPE=Release -DTOPOPT_REQUIRE_DEPS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$archs" "$@" >/dev/null
  cmake --build "$dir" --target topopt --config Release >/dev/null
  if [[ ! -f "$dir/libtopopt.a" ]]; then
    echo "error: slice '$name' did not produce libtopopt.a" >&2; exit 1
  fi
  echo "$dir/libtopopt.a"
}

# macOS is arm64 only: Homebrew OpenCASCADE ships arm64 dylibs on Apple Silicon,
# so the OCCT-linked macOS slice must match. The OCCT-free iOS simulator slice is
# universal (arm64 for Apple-Silicon simulators, x86_64 for Intel hosts /
# universal builds); iOS devices are all arm64.
echo "==> building macOS slice (Eigen + OCCT, arm64)"
LIB_MACOS=$(build_slice macos arm64 -DCMAKE_PREFIX_PATH="$OCCT_PREFIX;$EIGEN_PREFIX")

# iOS slices: Eigen findable (header-only, platform-agnostic) via BOTH root-path
# mode; OCCT/lib3mf explicitly disabled so STEP/3MF sources are excluded and no
# OCCT symbols are referenced.
IOS_COMMON=( -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_PREFIX_PATH="$EIGEN_PREFIX" -DCMAKE_FIND_ROOT_PATH="$EIGEN_PREFIX"
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenCASCADE=ON
  -DCMAKE_DISABLE_FIND_PACKAGE_lib3mf=ON )

echo "==> building iOS simulator slice (Eigen, OCCT-free, arm64+x86_64)"
LIB_IOSSIM=$(build_slice iossimulator "arm64;x86_64" "${IOS_COMMON[@]}" -DCMAKE_OSX_SYSROOT=iphonesimulator)

echo "==> building iOS device slice (Eigen, OCCT-free, arm64)"
LIB_IOSDEV=$(build_slice iphoneos arm64 "${IOS_COMMON[@]}" -DCMAKE_OSX_SYSROOT=iphoneos)

# --- assemble the xcframework ------------------------------------------------
mkdir -p "$VENDOR"
XCF="$VENDOR/TopOptCore.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$LIB_MACOS" \
  -library "$LIB_IOSSIM" \
  -library "$LIB_IOSDEV" \
  -output "$XCF" >/dev/null
echo "==> created $XCF"

# --- vendor headers + OCCT libs (package-relative paths only) -----------------
ln -sfn "$CORE_DIR/include" "$VENDOR/include"
ln -sfn "$OCCT_PREFIX/lib" "$VENDOR/occt-lib"
# Remove any stale single-slice artifacts from earlier revisions of this script.
rm -rf "$VENDOR/lib" "$VENDOR/occt-include"

echo "==> vendored:"
echo "    $XCF (macos-arm64, ios-arm64-simulator, ios-arm64)"
echo "    $VENDOR/include   -> $CORE_DIR/include"
echo "    $VENDOR/occt-lib  -> $OCCT_PREFIX/lib   (macOS link only)"
echo "==> done. Test: (cd $PKG_DIR && xcodebuild test -scheme TopOptKit -destination 'platform=macOS')"
