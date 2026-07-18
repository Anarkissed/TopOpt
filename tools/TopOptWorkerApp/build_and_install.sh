#!/usr/bin/env bash
# build_and_install.sh — one command to build "TopOpt Worker.app" and install it
# to /Applications (handoff 097). Notarization/signing is OUT of scope; the app is
# ad-hoc signed, so on first launch macOS shows "unidentified developer" — the user
# right-clicks the app and chooses Open once (documented in README.md).
#
#   ./tools/TopOptWorkerApp/build_and_install.sh            # build + install
#   ./tools/TopOptWorkerApp/build_and_install.sh --build    # build only (no install)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$HERE/TopOptWorkerApp.xcodeproj"
APP_NAME="TopOpt Worker.app"

echo "==> building (Release)…"
xcodebuild -project "$PROJECT" -target TopOptWorker -configuration Release \
  build CONFIGURATION_BUILD_DIR="$HERE/build/Release" >/dev/null
APP="$HERE/build/Release/$APP_NAME"
[[ -d "$APP" ]] || { echo "error: build did not produce $APP" >&2; exit 1; }
echo "==> built $APP"

if [[ "${1:-}" == "--build" ]]; then
  echo "==> build-only; not installing."
  exit 0
fi

DEST="/Applications/$APP_NAME"
echo "==> installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "==> installed."
echo
echo "First launch: right-click “TopOpt Worker” in /Applications → Open → Open"
echo "(needed once because the app isn't notarized). Then it lives in the menu bar;"
echo "toggle “Launch at Login” so it survives reboots."
echo
echo "It needs a topopt-cli. If one isn't bundled, open the menu → Settings… and"
echo "point it at your built binary, e.g. core/build/topopt-cli, or build it:"
echo "    cmake --build core/build --target topopt_cli"
