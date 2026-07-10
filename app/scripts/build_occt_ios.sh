#!/usr/bin/env bash
# build_occt_ios.sh — cross-compile OpenCASCADE (and, for M7.9, lib3mf) for iOS
# (device arm64 + simulator arm64) and package each library as a dynamic
# `.framework` inside an `.xcframework` under the TopOptKit package's vendor
# tree, so the iPad app can link + embed them and STEP import works on iOS
# (ROADMAP M7.1b).
#
# WHY dynamic frameworks (LGPL, ARCHITECTURE §10): OCCT is LGPL 2.1 and MUST be
# dynamically linked — never statically archived, never source-modified. On iOS
# the App-Store-legal form of a dynamic library is an *embedded, code-signed
# dynamic framework* (Frameworks/…). So we build OCCT as shared dylibs
# (BUILD_LIBRARY_TYPE=Shared), wrap each dylib in a `.framework` with an
# `@rpath/<TK>.framework/<TK>` install name, and ship them as xcframeworks that
# SwiftPM embeds & re-signs into the app. Nothing here statically archives OCCT
# or edits its sources.
#
# WHY a separate script from build_core.sh: this is the slow, heavy, and most
# failure-prone step (a full OCCT cross-compile). It is run ONCE (per OCCT
# version / SDK bump); build_core.sh then reuses its output on every core
# rebuild. Keeping them apart means a normal core rebuild stays fast.
#
# Output (all git-ignored — see app/.gitignore):
#   app/TopOptKit/vendor/occt-ios/<TK>.xcframework      one per OCCT toolkit
#   app/TopOptKit/vendor/lib3mf-ios/lib3mf.xcframework  (if lib3mf stage runs)
#   app/.build-occt-ios/install/occt-<sdk>/             headers + CMake config,
#                                                       consumed by build_core.sh
#
# Prereqs: full Xcode (not just CLT) with the iOS SDKs, git, cmake ≥ 3.14.
# Run this BEFORE build_core.sh when you want STEP on iOS. See app/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$APP_DIR/TopOptKit"
VENDOR="$PKG_DIR/vendor"
WORK="$APP_DIR/.build-occt-ios"
TOOLCHAIN="$SCRIPT_DIR/ios.toolchain.cmake"

# --- knobs (override via env) -------------------------------------------------
# OCCT_TAG defaults to the macOS Homebrew OCCT version so both slices compile the
# core against the same OCCT API (avoids header/behaviour drift between slices).
OCCT_TAG="${OCCT_TAG:-V7_9_3}"
LIB3MF_TAG="${LIB3MF_TAG:-v2.3.2}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"   # must match Package.swift .iOS(.v16)
BUILD_LIB3MF="${BUILD_LIB3MF:-1}"                        # 0 to skip the M7.9 lib3mf stage
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
# Slices to build: "iphoneos" (device) and/or "iphonesimulator" (sim).
SLICES=("iphoneos" "iphonesimulator")

echo "==> OCCT $OCCT_TAG, lib3mf $LIB3MF_TAG, min iOS $IOS_DEPLOYMENT_TARGET, jobs $JOBS"
echo "==> slices: ${SLICES[*]}"

command -v xcrun >/dev/null || { echo "error: xcrun not found (install Xcode)"; exit 1; }
[[ -f "$TOOLCHAIN" ]] || { echo "error: missing toolchain $TOOLCHAIN"; exit 1; }
EIGEN_PREFIX="${EIGEN_PREFIX:-$(brew --prefix eigen 2>/dev/null || true)}"

mkdir -p "$WORK/src"

# --- fetch source (shallow) ---------------------------------------------------
OCCT_SRC="$WORK/src/OCCT"
if [[ ! -d "$OCCT_SRC/.git" ]]; then
  echo "==> cloning OCCT $OCCT_TAG (shallow)"
  git clone --depth 1 --branch "$OCCT_TAG" \
    https://github.com/Open-Cascade-SAS/OCCT.git "$OCCT_SRC"
else
  echo "==> reusing OCCT source at $OCCT_SRC"
fi

# =============================================================================
# OCCT — cross-compile one SDK slice, install headers+libs+CMake config
# =============================================================================
# Minimal STEP-capable module set: FoundationClasses + ModelingData +
# ModelingAlgorithms + DataExchange. Everything visual / interactive / doc /
# 3rd-party is OFF, so no FreeType/Tcl/VTK/OpenGL/RapidJSON/Draco is needed and
# the build is as small as OCCT gets. (STEP read = STEPControl_Reader in
# TKDESTEP; no runtime DE plugin needed.)
#
# NOTE (verified on OCCT 7.9.3): even with Visualization/ApplicationFramework
# modules OFF, the STEP toolkit drags the OCAF + presentation stack in as a hard
# link dependency: TKDESTEP -> TKXCAF -> TKV3d -> TKService (OCCT builds a
# toolkit's dependencies regardless of its owning module's flag). TKService
# contains OCCT's Apple window shim (src/Cocoa/*.mm). That code IS iOS-aware
# (it #imports <UIKit/UIKit.h> under TARGET_OS_IPHONE) and COMPILES, but OCCT's
# CMake omits the frameworks its symbols (e.g. NSAutoreleasePool) live in, so it
# fails to LINK on iOS. Adding "-framework Foundation -framework UIKit" to the
# shared-linker flags below resolves that without touching OCCT sources (LGPL).
# If a further macOS-only symbol surfaces in TKV3d/TKService, see the handoff's
# Blocked/fallback section (prebuilt iOS OCCT).
occt_build_slice() {
  local sdk="$1"
  local build="$WORK/build/occt-$sdk"
  local install="$WORK/install/occt-$sdk"
  echo "==> [OCCT/$sdk] configure"
  rm -rf "$build"
  cmake -S "$OCCT_SRC" -B "$build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DIOS_SDK="$sdk" -DIOS_ARCHS="arm64" \
    -DIOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install" \
    -DBUILD_LIBRARY_TYPE=Shared \
    -DCMAKE_SHARED_LINKER_FLAGS="-framework Foundation -framework UIKit" \
    -DBUILD_MODULE_FoundationClasses=ON \
    -DBUILD_MODULE_ModelingData=ON \
    -DBUILD_MODULE_ModelingAlgorithms=ON \
    -DBUILD_MODULE_DataExchange=ON \
    -DBUILD_MODULE_Visualization=OFF \
    -DBUILD_MODULE_ApplicationFramework=OFF \
    -DBUILD_MODULE_Draw=OFF \
    -DBUILD_MODULE_DETools=OFF \
    -DBUILD_DOC_Overview=OFF \
    -DUSE_FREETYPE=OFF -DUSE_FREEIMAGE=OFF -DUSE_OPENVR=OFF \
    -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_TK=OFF -DUSE_TBB=OFF \
    -DUSE_VTK=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_FFMPEG=OFF \
    -DUSE_XLIB=OFF
  echo "==> [OCCT/$sdk] build ($JOBS jobs) — this is the long one"
  cmake --build "$build" --config Release --parallel "$JOBS"
  echo "==> [OCCT/$sdk] install -> $install"
  rm -rf "$install"
  cmake --install "$build" --config Release
}

# =============================================================================
# Wrap every libTK*.dylib in an install tree as an iOS .framework, fixing the
# install name to @rpath/<TK>.framework/<TK> and rewriting inter-OCCT deps to
# the same framework layout. Emits into $WORK/frameworks/<sdk>/<TK>.framework.
# =============================================================================
wrap_slice_frameworks() {
  local sdk="$1"
  local libdir="$WORK/install/occt-$sdk/lib"
  local out="$WORK/frameworks/$sdk"
  rm -rf "$out"; mkdir -p "$out"
  [[ -d "$libdir" ]] || { echo "error: no OCCT lib dir at $libdir"; exit 1; }

  # Toolkit list = the unversioned dylib symlinks OCCT installed (libTK*.dylib).
  local names=()
  local f tk
  for f in "$libdir"/libTK*.dylib; do
    [[ -e "$f" ]] || continue
    tk="$(basename "$f")"; tk="${tk#lib}"; tk="${tk%.dylib}"
    # keep only unversioned names (no dots -> a toolkit, not libTKMath.7.9.3.dylib)
    [[ "$tk" == *.* ]] && continue
    names+=("$tk")
  done
  [[ ${#names[@]} -gt 0 ]] || { echo "error: no libTK*.dylib in $libdir"; exit 1; }
  echo "==> [$sdk] wrapping ${#names[@]} toolkits as frameworks"

  local platform minos
  if [[ "$sdk" == "iphonesimulator" ]]; then platform="iPhoneSimulator"; else platform="iPhoneOS"; fi

  for tk in "${names[@]}"; do
    local fw="$out/$tk.framework"
    mkdir -p "$fw"
    cp -L "$libdir/lib$tk.dylib" "$fw/$tk"          # -L: copy the real binary, not the symlink
    chmod u+w "$fw/$tk"
    install_name_tool -id "@rpath/$tk.framework/$tk" "$fw/$tk"
    # Rewrite each dependency on another OCCT toolkit to its framework path.
    local dep depname deptk
    while IFS= read -r depname; do
      # depname like @rpath/libTKMath.7.9.3.dylib  OR  libTKMath.dylib
      deptk="$(basename "$depname")"; deptk="${deptk#lib}"; deptk="${deptk%%.*}"
      install_name_tool -change "$depname" "@rpath/$deptk.framework/$deptk" "$fw/$tk" 2>/dev/null || true
    done < <(otool -L "$fw/$tk" | awk 'NR>1{print $1}' | grep -E '/libTK|(^|/)libTK' || true)
    # Minimal framework Info.plist.
    /usr/libexec/PlistBuddy -c "Clear dict" "$fw/Info.plist" 2>/dev/null || true
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$tk</string>
  <key>CFBundleIdentifier</key><string>org.opencascade.$tk</string>
  <key>CFBundleName</key><string>$tk</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>7.9.3</string>
  <key>CFBundleVersion</key><string>7.9.3</string>
  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict></plist>
PLIST
    # Ad-hoc sign so the framework is loadable for direct testing; Xcode re-signs
    # with the app's identity when it embeds the xcframework.
    codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1 || true
  done
}

# =============================================================================
# Create one xcframework per toolkit from the device + simulator frameworks.
# =============================================================================
package_occt_xcframeworks() {
  local outdir="$VENDOR/occt-ios"
  rm -rf "$outdir"; mkdir -p "$outdir"
  local first="${SLICES[0]}"
  local tk fw
  for fw in "$WORK/frameworks/$first"/*.framework; do
    tk="$(basename "$fw" .framework)"
    local args=()
    local sdk
    for sdk in "${SLICES[@]}"; do
      args+=(-framework "$WORK/frameworks/$sdk/$tk.framework")
    done
    xcodebuild -create-xcframework "${args[@]}" -output "$outdir/$tk.xcframework" >/dev/null
  done
  echo "==> packaged $(ls "$outdir" | wc -l | tr -d ' ') OCCT xcframeworks -> $outdir"
}

# =============================================================================
# lib3mf (BSD, M7.9). Best-effort: a failure here does NOT fail the OCCT goal.
# lib3mf vendors its third-party in git submodules, so a shallow clone WITH
# submodules is required (a release tarball omits them).
# =============================================================================
build_lib3mf() {
  local src="$WORK/src/lib3mf"
  if [[ ! -d "$src/.git" ]]; then
    echo "==> cloning lib3mf $LIB3MF_TAG (shallow, +submodules)"
    git clone --depth 1 --branch "$LIB3MF_TAG" --recurse-submodules \
      https://github.com/3MFConsortium/lib3mf.git "$src"
  fi
  local sdk
  for sdk in "${SLICES[@]}"; do
    local build="$WORK/build/lib3mf-$sdk" install="$WORK/install/lib3mf-$sdk"
    echo "==> [lib3mf/$sdk] configure + build"
    rm -rf "$build"
    cmake -S "$src" -B "$build" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DIOS_SDK="$sdk" -DIOS_ARCHS="arm64" \
      -DIOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$install" \
      -DLIB3MF_TESTS=OFF -DBUILD_SHARED_LIBS=ON
    cmake --build "$build" --config Release --parallel "$JOBS"
    rm -rf "$install"; cmake --install "$build" --config Release
  done
  # Wrap the single lib3mf dylib as a framework per slice, then xcframework.
  local sdk2 platform
  for sdk2 in "${SLICES[@]}"; do
    local libdir="$WORK/install/lib3mf-$sdk2/lib"
    local dylib; dylib="$(ls "$libdir"/lib3mf*.dylib 2>/dev/null | head -1 || true)"
    [[ -n "$dylib" ]] || { echo "warn: no lib3mf dylib for $sdk2; skipping lib3mf"; return 0; }
    local fw="$WORK/frameworks/$sdk2/lib3mf.framework"; rm -rf "$fw"; mkdir -p "$fw"
    cp -L "$dylib" "$fw/lib3mf"; chmod u+w "$fw/lib3mf"
    install_name_tool -id "@rpath/lib3mf.framework/lib3mf" "$fw/lib3mf"
    if [[ "$sdk2" == "iphonesimulator" ]]; then platform="iPhoneSimulator"; else platform="iPhoneOS"; fi
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>lib3mf</string>
  <key>CFBundleIdentifier</key><string>io.3mf.lib3mf</string>
  <key>CFBundleName</key><string>lib3mf</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>MinimumOSVersion</key><string>$IOS_DEPLOYMENT_TARGET</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
</dict></plist>
PLIST
    codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1 || true
  done
  local outdir="$VENDOR/lib3mf-ios"; rm -rf "$outdir"; mkdir -p "$outdir"
  local args=() sdk3
  for sdk3 in "${SLICES[@]}"; do
    [[ -d "$WORK/frameworks/$sdk3/lib3mf.framework" ]] && args+=(-framework "$WORK/frameworks/$sdk3/lib3mf.framework")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$outdir/lib3mf.xcframework" >/dev/null
  echo "==> packaged lib3mf.xcframework -> $outdir"
}

# =============================================================================
# Force SwiftPM/Xcode to re-evaluate Package.swift (which re-reads the generated
# JSON below). CRITICAL for M7.1c: the framework list now lives OUTSIDE
# Package.swift, in occt-frameworks.generated.json. SwiftPM caches the compiled
# manifest keyed on Package.swift's CONTENTS, not on files it reads, so writing
# the JSON alone does NOT bust that cache — SwiftPM/Xcode would keep resolving the
# stale (empty) list. (Under M7.1b the list lived inside Package.swift, so
# rewriting it was itself the content change that busted the cache; that is gone
# now, so we must invalidate explicitly.) We (a) purge SwiftPM's on-disk manifest
# caches and (b) bump Package.swift's mtime. Bumping mtime does NOT change file
# contents, so `git status` stays clean and Package.swift remains committed-empty.
invalidate_manifest_cache() {
  # Purge SwiftPM's on-disk caches WHOLESALE. Purging only the manifests subdir was
  # not enough to flip Xcode/SwiftPM resolution in practice; removing the whole
  # org.swift.swiftpm cache trees is what reliably makes the manifest re-evaluate
  # and pick up the JSON. This package has no remote SwiftPM dependencies, so a
  # full purge only costs a manifest recompile — nothing to re-download.
  rm -rf "$HOME/Library/Caches/org.swift.swiftpm" \
         "$HOME/Library/org.swift.swiftpm" \
         "$PKG_DIR/.build/manifest.db" 2>/dev/null || true
  touch "$PKG_DIR/Package.swift"   # mtime bump only -> git status stays clean
  echo "==> invalidated SwiftPM manifest cache (purged ~/Library/{Caches/,}org.swift.swiftpm + touched Package.swift)"
  echo "    Package.swift contents are unchanged (git status stays clean)."
  echo "    IMPORTANT for Xcode: Xcode holds its OWN in-memory + DerivedData package"
  echo "    resolution that an on-disk purge does NOT reach while it is running. So:"
  echo "      • QUIT Xcode before running this script, then reopen — reliable; or"
  echo "      • if Xcode was already open, run File > Packages > Reset Package Caches."
  echo "    Otherwise Xcode keeps compiling the OCCT-off manifest and STEP stays"
  echo "    disabled (the 'requires OpenCASCADE' toast) even with the JSON written."
}

# Write the produced framework names into the GIT-IGNORED generated JSON that
# Package.swift reads at manifest-evaluation time (occt-frameworks.generated.json).
# The list is NO LONGER inside Package.swift (M7.1c), so a stray `git add -A`
# cannot re-commit a populated list and break the macOS/CI build (run 039); the
# committed default is "JSON absent" == OCCT-free. This file is regenerated like
# vendor/ — do not commit it (it is in app/.gitignore).
write_manifest_list() {
  local json="$PKG_DIR/occt-frameworks.generated.json"
  OCCT_DIR="$VENDOR/occt-ios" LIB3MF_DIR="$VENDOR/lib3mf-ios" \
  python3 - "$json" <<'PY'
import json, os, sys
out = sys.argv[1]
def names(d):
    if not os.path.isdir(d): return []
    return sorted(n[:-len(".xcframework")] for n in os.listdir(d) if n.endswith(".xcframework"))
occt = names(os.environ["OCCT_DIR"]); l3mf = names(os.environ["LIB3MF_DIR"])
with open(out, "w") as f:
    json.dump({"occt": occt, "lib3mf": l3mf}, f, indent=2)
    f.write("\n")
print("==> wrote %d OCCT + %d lib3mf framework names into %s"
      % (len(occt), len(l3mf), os.path.basename(out)))
PY
  invalidate_manifest_cache
}

# --- drive --------------------------------------------------------------------
# Fast path: if the xcframeworks already exist (e.g. you built them earlier and
# only need to (re)wire the manifest), RELINK_ONLY=1 writes the git-ignored
# occt-frameworks.generated.json from vendor/ and exits — no multi-slice OCCT rebuild.
if [[ "${RELINK_ONLY:-0}" == "1" ]]; then
  [[ -d "$VENDOR/occt-ios" ]] || { echo "error: RELINK_ONLY set but $VENDOR/occt-ios is missing — run a full build first"; exit 1; }
  echo "==> RELINK_ONLY: writing occt-frameworks.generated.json from existing vendor/ (no rebuild)"
  write_manifest_list
  echo "==> done. Now run ./app/scripts/build_core.sh, then build the app."
  exit 0
fi

for sdk in "${SLICES[@]}"; do
  occt_build_slice "$sdk"
  wrap_slice_frameworks "$sdk"
done

package_occt_xcframeworks

if [[ "$BUILD_LIB3MF" == "1" ]]; then
  build_lib3mf || echo "warn: lib3mf stage failed (non-fatal for M7.1b STEP goal); see log above"
fi

write_manifest_list

cat <<DONE

==> OCCT iOS slices ready.
    xcframeworks : $VENDOR/occt-ios/*.xcframework
    install trees: $WORK/install/occt-<sdk>/  (headers + OpenCASCADEConfig.cmake)
    framework list: $PKG_DIR/occt-frameworks.generated.json
                    (git-ignored; Package.swift stays committed-empty and shows
                    UNMODIFIED in git status — verify with: git status --short)

Next:
  1. ./app/scripts/build_core.sh        # builds the iOS core slices WITH OCCT
                                        # (STEP compiled in) — it detects
                                        # $WORK/install/occt-<sdk>/
  2. Build/run the TopOpt app on an iPad simulator/device and import a .step file.
     Package.swift's TopOptOCCT product now carries vendor/occt-ios/*.xcframework;
     the app links + embeds them and TOPOPT_BRIDGE_HAS_OCCT is defined on iOS.
     The manifest cache was invalidated above; if Xcode was already open, run
     File > Packages > Reset Package Caches once so it re-reads the framework list.
DONE
