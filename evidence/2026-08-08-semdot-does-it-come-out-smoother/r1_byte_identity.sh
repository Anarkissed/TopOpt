#!/bin/sh
# R1 — OFF IS BYTE-IDENTICAL, and not "by construction".
#
# The claim: a job document that does NOT carry a `semdot` block produces
# byte-for-byte the same artifacts on this branch as it does at the base commit.
# Every new field defaults to the value the old code used as a literal
# (SimpOptions::semdot false, semdot_grid_points unread, JobDescription::has_semdot
# false), and semdot_law / the map are behind `if (options.semdot)` — but that is
# an argument, and this is the measurement.
#
# THE BASE IS A DETACHED WORKTREE, NOT A STASH. `git stash push -- <paths>` that
# matches nothing pops SOMEONE ELSE'S stash, and a mid-script failure would leave
# this branch's work stashed with the tree at base. A detached worktree cannot
# touch the working tree at all, which is why it is worth the extra compile —
# the same reason PR 277's m1_byteid.sh gives.
#
# BOTH BUILD OUTPUTS. The core CLI is compared artifact-by-artifact below; the app
# is a second build output that LINKS core, so it is built (not run) and its build
# result recorded in r1_app_build.txt by the caller.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-08-semdot-does-it-come-out-smoother"
BASE_REF=${1:-main}
cd "$ROOT"

W="$EV/r1_byteid"
sum() { find "$1" -type f \( -name '*.bin' -o -name '*.stl' -o -name '*.json' \
                             -o -name '*.csv' \) \
          | sed "s|$1/||" | sort | while read -r f; do
            printf '%s  %s\n' "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)" "$f"; done; }

# ── the BRANCH build, semdot ABSENT from the job document ───────────────────
rm -rf "$W/branch" "$W/branch.log"
"$ROOT/core/build/topopt-cli" run "$W/job.json" --out "$W/branch" \
    > "$W/branch.log" 2>&1
sum "$W/branch" > "$W/branch.sha256"

# ── the BASE build, in a throwaway detached worktree ────────────────────────
WT=/tmp/semdot-base-$$
BLD=$WT-build
git worktree add --detach "$WT" "$BASE_REF" >/dev/null 2>&1
cmake -S "$WT/core" -B "$BLD" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
cmake --build "$BLD" -j8 --target topopt_cli >/dev/null 2>&1
rm -rf "$W/base" "$W/base.log"
"$BLD/topopt-cli" run "$W/job.json" --out "$W/base" > "$W/base.log" 2>&1
sum "$W/base" > "$W/base.sha256"
BASE_SHA=$(git rev-parse --short "$BASE_REF")
git worktree remove --force "$WT" >/dev/null 2>&1
rm -rf "$BLD"

{
  echo "=== R1 — base worktree ($BASE_REF = $BASE_SHA) vs branch,"
  echo "         a lattice+grading job with NO \"semdot\" key ==="
  echo
  if diff -u "$W/base.sha256" "$W/branch.sha256" > /dev/null; then
    echo "IDENTICAL — every artifact matches byte for byte."
    echo
    sed 's/^/  /' "$W/branch.sha256"
  else
    echo "DIFFERENCES FOUND:"
    diff -u "$W/base.sha256" "$W/branch.sha256" || true
  fi
} | tee "$EV/r1_byte_identity.txt"
