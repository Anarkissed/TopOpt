#!/usr/bin/env bash
# build_core.sh — build the topopt core as a multi-platform static-library
# xcframework and vendor it (plus the OCCT libs the macOS slice needs) under the
# TopOptKit package, so both `xcodebuild test` on the package (macOS) and the
# iPad app (iOS simulator + device) can link it (ROADMAP M7.1; ARCHITECTURE §4
# "core built into the app", §10 OCCT dynamic linking).
#
# Slices:
#   macOS            : Eigen + OpenCASCADE  -> STEP import + full pipeline
#   iOS simulator    : Eigen [+ OCCT/lib3mf if cross-built]
#   iOS device       : Eigen [+ OCCT/lib3mf if cross-built]
# The iOS slices are built WITH OpenCASCADE (so STEP import compiles in) when an
# iOS OCCT install produced by build_occt_ios.sh is present under
# .build-occt-ios/install/occt-<sdk>/; otherwise they fall back to OCCT-free
# (the pre-M7.1b behavior). In the OCCT-free case the bridge compiles STEP
# import/tagging only where TOPOPT_BRIDGE_HAS_OCCT is defined (macOS + any iOS
# slice that found OCCT) and returns a clear "not available on this platform"
# error elsewhere. lib3mf (3MF export, M7.9) is wired the same way. Eigen is
# header-only, reused across every slice.
#
# So the two-step flow for STEP-on-iOS is:
#   ./app/scripts/build_occt_ios.sh   # once: cross-build OCCT (+lib3mf) for iOS
#   ./app/scripts/build_core.sh       # detects it, builds iOS slices with OCCT
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

# --- iOS slices --------------------------------------------------------------
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"   # match Package.swift .iOS(.v16)

# iOS OCCT/lib3mf install trees produced by build_occt_ios.sh (optional). When a
# slice's tree is present the slice is built WITH the dependency (STEP / 3MF
# compile in); otherwise it is built dependency-free. Eigen (header-only) is
# always findable across the iOS root via BOTH-mode package/include resolution.
OCCT_IOS_SIM="$APP_DIR/.build-occt-ios/install/occt-iphonesimulator"
OCCT_IOS_DEV="$APP_DIR/.build-occt-ios/install/occt-iphoneos"
LIB3MF_IOS_SIM="$APP_DIR/.build-occt-ios/install/lib3mf-iphonesimulator"
LIB3MF_IOS_DEV="$APP_DIR/.build-occt-ios/install/lib3mf-iphoneos"

# build_ios_slice <name> <sdk> <archs> <occt-install> <lib3mf-install>
#   -> echoes the produced libtopopt.a (like build_slice). Composes the CMAKE_
#      PREFIX_PATH / find-root and the per-dependency disable flags based on what
#      is actually cross-built. (Written for bash 3.2 — no mapfile/readarray.)
build_ios_slice() {
  local name="$1" sdk="$2" archs="$3" occt="$4" l3mf="$5"
  local prefix="$EIGEN_PREFIX"
  local extra
  extra=( -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH )
  if [[ -d "$occt" ]]; then prefix="$occt;$prefix"
  else extra+=( -DCMAKE_DISABLE_FIND_PACKAGE_OpenCASCADE=ON ); fi
  if [[ -d "$l3mf" ]]; then prefix="$l3mf;$prefix"
  else extra+=( -DCMAKE_DISABLE_FIND_PACKAGE_lib3mf=ON ); fi
  extra+=( -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" )
  build_slice "$name" "$archs" "${extra[@]}"
}

# When OCCT is present the simulator slice must be arm64-only: the cross-built
# OCCT ships arm64 only (Apple-Silicon simulator), so a fat arm64+x86_64 sim
# slice would carry STEP object code with no x86_64 OCCT to link against. The
# OCCT-free sim slice stays universal (arm64+x86_64) as before.
if [[ -d "$OCCT_IOS_SIM" ]]; then SIM_ARCHS="arm64"; else SIM_ARCHS="arm64;x86_64"; fi

[[ -d "$OCCT_IOS_SIM" ]] && SIM_KIND="Eigen + OCCT" || SIM_KIND="Eigen, OCCT-free"
[[ -d "$OCCT_IOS_DEV" ]] && DEV_KIND="Eigen + OCCT" || DEV_KIND="Eigen, OCCT-free"
echo "==> building iOS simulator slice ($SIM_KIND, $SIM_ARCHS)"
LIB_IOSSIM=$(build_ios_slice iossimulator iphonesimulator "$SIM_ARCHS" "$OCCT_IOS_SIM" "$LIB3MF_IOS_SIM")

echo "==> building iOS device slice ($DEV_KIND, arm64)"
LIB_IOSDEV=$(build_ios_slice iphoneos iphoneos arm64 "$OCCT_IOS_DEV" "$LIB3MF_IOS_DEV")

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
if [[ -d "$VENDOR/occt-ios" ]]; then
  echo "    $VENDOR/occt-ios  ($(ls "$VENDOR/occt-ios" 2>/dev/null | wc -l | tr -d ' ') OCCT xcframeworks, iOS device+sim — linked+embedded on iOS)"
  echo "    iOS slices built WITH OCCT: STEP import is available on iPad/simulator."
else
  echo "    (no vendor/occt-ios — iOS slices are OCCT-free; run build_occt_ios.sh for STEP on iOS)"
fi
echo "==> done. Test: (cd $PKG_DIR && xcodebuild test -scheme TopOptKit -destination 'platform=macOS')"
