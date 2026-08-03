#!/bin/sh
# M1 (C) — THE CONTROLLED byte-identity test.
#
# WHY THIS EXISTS. M1(B) compared a fresh base worktree against my existing build
# directory and found 1-ulp drift (0.006372359774 vs ...73) in two floats, with
# report.json, the solid meshes and every variant_060 artifact identical. A 1-ulp
# difference is not a behavioural change, but it should not appear at all if the
# code path is identical — and the obvious suspect was the METHOD: two cmake
# configurations, possibly different flags or found dependencies, hence different
# floating-point instruction scheduling.
#
# So this removes the method as a variable: ONE scratch worktree, ONE cmake cache,
# ONE set of flags. Build BASE, run. Apply the branch patch in place, rebuild, run.
# Compare. Any surviving difference is the code and nothing else.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
WT=/tmp/m1c-wt; BLD=/tmp/m1c-build
W="$EV/m1_controlled"; rm -rf "$W" "$WT" "$BLD"; mkdir -p "$W"
cd "$ROOT"
git worktree remove --force "$WT" >/dev/null 2>&1
cp "$ROOT/evidence/2026-07-28-lattice-generation-production/l-bracket.step" "$W/"
cp "$EV/m1_base/job.json" "$W/job.json"

sum() { find "$1" -type f \( -name '*.bin' -o -name '*.stl' -o -name '*.json' \) \
          | sed "s|$1/||" | sort | while read -r f; do
            printf '%s  %s\n' "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)" "$f"; done; }

git worktree add --detach "$WT" 34175a5 >/dev/null 2>&1
cmake -S "$WT/core" -B "$BLD" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1

# --- BASE ---
cmake --build "$BLD" -j10 --target topopt_cli >/dev/null 2>&1
cp "$BLD/topopt-cli" "$BLD/m1c"
"$BLD/m1c" run "$W/job.json" --out "$W/base" > "$W/base.log" 2>&1
sum "$W/base" > "$W/base.sha256"

# --- BRANCH, same worktree, same cmake cache ---
( cd "$WT" && git apply /tmp/m1_branch.patch ) || echo "PATCH FAILED" >> "$W/base.log"
while read -r f; do mkdir -p "$WT/$(dirname "$f")"; cp "$ROOT/$f" "$WT/$f"; done < /tmp/m1_newfiles.txt
cmake --build "$BLD" -j10 --target topopt_cli >/dev/null 2>&1
cp "$BLD/topopt-cli" "$BLD/m1c"
"$BLD/m1c" run "$W/job.json" --out "$W/branch" > "$W/branch.log" 2>&1
sum "$W/branch" > "$W/branch.sha256"

git worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$BLD"

{
  echo "=== M1 (C) — ONE worktree, ONE cmake cache: base 34175a5 vs branch,"
  echo "             on a lattice+grading job with multiscale ABSENT ==="
  echo
  if diff -u "$W/base.sha256" "$W/branch.sha256"; then
    echo "IDENTICAL — every artifact matches byte for byte."
    sed 's/^/  /' "$W/branch.sha256"
  else
    echo
    echo "DIFFERENCES REMAIN after removing the build method as a variable."
  fi
} | tee "$EV/m1_controlled.txt"
