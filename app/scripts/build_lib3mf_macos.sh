#!/usr/bin/env bash
# build_lib3mf_macos.sh — provision lib3mf for the macOS worker/CLI build via the
# SAME vcpkg registry + baseline CI uses, so a developer/worker Mac gets the
# byte-identical lib3mf CI builds against (version-locked → 3MF behavior identical).
#
# WHY THIS EXISTS (the gap this closes)
#   core/vcpkg.json lists lib3mf and CI installs it via vcpkg (DEPS=ON), but the
#   macOS path in build_core.sh pulls OCCT/Eigen from Homebrew and had NO lib3mf:
#   lib3mf is not a brew formula, and building it from a plain `git clone` fails on
#   unfetched submodules (libzip → missing config.h). So 3MF import was dead on
#   every real Mac — find_package(lib3mf) went QUIET and the worker/CLI rejected
#   `.3mf` with "this build has no 3MF support". This script gives the Mac a real,
#   one-command lib3mf.
#
# ROUTE (why vcpkg, not a hand-built lib3mf)
#   We install lib3mf from vcpkg checked out at the SAME tag CI uses
#   (.github/workflows/ci.yml → 2026.06.24, whose commit is core/vcpkg.json's
#   builtin-baseline). That pins lib3mf to the EXACT CI version (2.5.0#1) from the
#   EXACT CI registry, and vcpkg fetches lib3mf's deps (libzip, zlib, cpp-base64,
#   fast-float) as vcpkg PACKAGES — no git submodules — so the config.h breakage
#   never happens. We install ONLY lib3mf (classic mode), NOT the full manifest:
#   the full manifest would also rebuild OpenCASCADE from source (30–60+ min on
#   macOS) and diverge from the Homebrew OCCT the rest of the macOS build already
#   uses. lib3mf + its small deps build in a couple of minutes. The dynamic triplet
#   (…-osx-dynamic) matches CI's x64-linux-dynamic and the SHARED lib3mf imported
#   target core/CMakeLists.txt links (lib3mf is BSD; ARCHITECTURE §10).
#
# USAGE
#   ./app/scripts/build_lib3mf_macos.sh            # provision (idempotent)
#   eval "$(./app/scripts/build_lib3mf_macos.sh --print-env)"   # + export vars
#
# On success it prints the install prefix and lib3mf_DIR (the find_package(lib3mf
# CONFIG) location) and, with --print-env, emits `export LIB3MF_PREFIX=… ;
# export lib3mf_DIR=…` lines for `eval`. build_core.sh and build_cli_macos.sh both
# auto-detect the same install, so a plain run of this script is enough.
set -euo pipefail

PRINT_ENV=0
[[ "${1:-}" == "--print-env" ]] && PRINT_ENV=1

# Everything humans should read goes to stderr so `--print-env` stdout stays clean
# for `eval`.
say() { echo "$@" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"

# vcpkg checkout tag — MUST match .github/workflows/ci.yml (the "Check out vcpkg"
# step) so the installed lib3mf equals CI's. core/vcpkg.json's builtin-baseline is
# this tag's commit. Override VCPKG_TAG only to deliberately track a newer CI pin.
VCPKG_TAG="${VCPKG_TAG:-2026.06.24}"
VCPKG_ROOT="${VCPKG_ROOT:-$REPO_ROOT/.vcpkg}"   # gitignored (root .gitignore: .vcpkg/)
export VCPKG_DISABLE_METRICS=1

# Triplet: dynamic OSX for the host arch (matches CI's dynamic linkage). lib3mf
# supports osx x64 + arm64 in the pinned port.
case "$(uname -m)" in
  arm64) TRIPLET="${VCPKG_TRIPLET:-arm64-osx-dynamic}" ;;
  x86_64) TRIPLET="${VCPKG_TRIPLET:-x64-osx-dynamic}" ;;
  *) say "error: unsupported macOS arch $(uname -m)"; exit 1 ;;
esac

INSTALL_PREFIX="$VCPKG_ROOT/installed/$TRIPLET"
LIB3MF_DIR="$INSTALL_PREFIX/share/lib3mf"

emit_env() {
  # stdout only — consumable by `eval "$(... --print-env)"`.
  echo "export LIB3MF_PREFIX='$INSTALL_PREFIX'"
  echo "export lib3mf_DIR='$LIB3MF_DIR'"
}

# --- fast path: already provisioned -----------------------------------------
if [[ -f "$LIB3MF_DIR/lib3mfConfig.cmake" || -f "$LIB3MF_DIR/lib3mf-config.cmake" ]]; then
  say "==> lib3mf already installed: $INSTALL_PREFIX"
  say "    lib3mf_DIR=$LIB3MF_DIR"
  [[ $PRINT_ENV -eq 1 ]] && emit_env
  exit 0
fi

# --- preflight: pkg-config ---------------------------------------------------
# vcpkg builds libzip's transitive deps (bzip2, …) from source and their portfiles
# require pkg-config; it is NOT a macOS system tool. Fail early with the fix rather
# than deep inside a vcpkg BUILD_FAILED stack.
if ! command -v pkg-config >/dev/null 2>&1; then
  say "error: pkg-config not found — vcpkg needs it to build lib3mf's deps."
  say "       install it once:  brew install pkg-config"
  exit 1
fi

# --- provision vcpkg at the CI-pinned tag -----------------------------------
if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
  say "==> bootstrapping vcpkg ($VCPKG_TAG) at $VCPKG_ROOT (matches CI)"
  if [[ ! -d "$VCPKG_ROOT/.git" ]]; then
    rm -rf "$VCPKG_ROOT"
    git clone --depth 1 --branch "$VCPKG_TAG" \
      https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT" >&2
  fi
  "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics >&2
fi

# --- install lib3mf (classic mode: this port only, NOT the full manifest) ----
say "==> vcpkg install lib3mf:$TRIPLET (this may take a few minutes)"
"$VCPKG_ROOT/vcpkg" install "lib3mf:$TRIPLET" \
  --x-install-root="$VCPKG_ROOT/installed" >&2

if [[ ! -f "$LIB3MF_DIR/lib3mfConfig.cmake" && ! -f "$LIB3MF_DIR/lib3mf-config.cmake" ]]; then
  say "error: vcpkg install finished but no lib3mf CONFIG under $LIB3MF_DIR"
  exit 1
fi

INSTALLED_VER="$("$VCPKG_ROOT/vcpkg" list 2>/dev/null | awk '/^lib3mf:/{print $2; exit}')"
say "==> installed lib3mf ${INSTALLED_VER:-?} → $INSTALL_PREFIX"
say "    lib3mf_DIR=$LIB3MF_DIR"
say "    (CI pins lib3mf 2.5.0#1 via vcpkg $VCPKG_TAG — versions match)"
[[ $PRINT_ENV -eq 1 ]] && emit_env
exit 0
