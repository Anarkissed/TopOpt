#!/bin/sh
# M1 — OFF IS BYTE-IDENTICAL, measured two ways.
#
# The claim: a job that does NOT ask for multiscale produces byte-for-byte the same
# artifacts on this branch as without it. Every new parameter defaults to the value
# the old code used as a literal (printed_iso 0.5, prescribed_relative_density null,
# lattice_material null, multiscale_lattice false) — but that is an argument, and
# this is the measurement.
#
# (A) THE MAINTAINER'S OWN PART vs a build that PREDATES this branch.
#     `git diff 2b8b715 34175a5 -- core/` is EMPTY, so core at the commit the
#     maintainer's captured run came from is the core this branch started from.
#     Comparing this branch's two-step run against those captured artifacts is a
#     byte-identity check on the real part. Files absent from a partial run are
#     SKIPPED and counted, never reported as a difference.
#
# (B) A CLEAN BASE WORKTREE, not a stash. An earlier version of this script used
#     `git stash push` around the base build; a mid-script failure then left the
#     branch's work stashed and the tree at base. A detached worktree cannot touch
#     the working tree at all, which is why it is worth the extra compile.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
BASE_COMMIT=34175a5
cd "$ROOT"

sum() { find "$1" -type f \( -name '*.bin' -o -name '*.stl' -o -name '*.json' \) \
          | sed "s|$1/||" | sort | while read -r f; do
            printf '%s  %s\n' "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)" "$f"; done; }

# ── (A) ──────────────────────────────────────────────────────────────────────
CAP=/Users/nadim/.topopt-worker/95f4130119414636/out
{
  echo "=== M1 (A) — the maintainer's part: this branch vs the CAPTURED run ==="
  echo "captured at core commit 2b8b715; branch based on 34175a5;"
  echo "git diff 2b8b715 34175a5 -- core/ is EMPTY."
  echo
  same=0; diff=0; skip=0
  for f in fields.bin report.json variant_068.stl variant_052.stl variant_038.stl \
           variant_068_lattice.stl variant_052_lattice.stl variant_038_lattice.stl; do
    a=$(shasum -a 256 "$CAP/$f" 2>/dev/null | cut -d' ' -f1)
    b=$(shasum -a 256 "$EV/m2_twostep/$f" 2>/dev/null | cut -d' ' -f1)
    if [ -z "$b" ]; then printf 'SKIPPED    %s (not produced — run was interrupted)\n' "$f"; skip=$((skip+1)); continue; fi
    if [ -z "$a" ]; then printf 'SKIPPED    %s (absent from the captured run)\n' "$f"; skip=$((skip+1)); continue; fi
    if [ "$a" = "$b" ]; then printf 'IDENTICAL  %s  %s\n' "$f" "$a"; same=$((same+1))
    else printf 'DIFFERS    %s\n  captured %s\n  branch   %s\n' "$f" "$a" "$b"; diff=$((diff+1)); fi
  done
  echo
  printf 'identical %d, differing %d, skipped %d\n' "$same" "$diff" "$skip"
} | tee "$EV/m1_captured_vs_branch.txt"

# ── (B) ──────────────────────────────────────────────────────────────────────
WT=/tmp/m1-base-$$
BLD=$WT-build
W="$EV/m1_base"; rm -rf "$W"; mkdir -p "$W"
cp "$ROOT/evidence/2026-07-28-lattice-generation-production/l-bracket.step" "$W/"
cat > "$W/job.json" <<'JSON'
{
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 40,
  "fixture_faces": [{ "kind": "cylindrical", "radius_mm": 2.5 }],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.6, 0.45], "margin_stop": 1.5, "simp": { "max_iterations": 15 },
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet", "min_extrudable_width_mm": 0.12, "emit_stl": true },
  "grading": { "topology": "octet", "cell_mm": 2.5,
               "min_extrudable_width_mm": 0.12, "demand_exponent": 1.0 }
}
JSON

# the BRANCH build (already current)
cp "$ROOT/build/topopt-cli" "$ROOT/build/m1run"
"$ROOT/build/m1run" run "$W/job.json" --out "$W/branch" > "$W/branch.log" 2>&1
sum "$W/branch" > "$W/branch.sha256"

# the BASE build, in a throwaway worktree
git worktree add --detach "$WT" "$BASE_COMMIT" >/dev/null 2>&1
cmake -S "$WT/core" -B "$BLD" >/dev/null 2>&1
cmake --build "$BLD" -j10 --target topopt_cli >/dev/null 2>&1
cp "$BLD/topopt-cli" "$BLD/m1base"
"$BLD/m1base" run "$W/job.json" --out "$W/base" > "$W/base.log" 2>&1
sum "$W/base" > "$W/base.sha256"
git worktree remove --force "$WT" >/dev/null 2>&1
rm -rf "$BLD"

{
  echo "=== M1 (B) — base worktree ($BASE_COMMIT) vs branch, lattice+grading job,"
  echo "             multiscale ABSENT from the job document ==="
  if diff -u "$W/base.sha256" "$W/branch.sha256"; then
    echo "IDENTICAL — every artifact matches byte for byte."
    sed 's/^/  /' "$W/branch.sha256"
  else
    echo "DIFFERENCES FOUND (above)."
  fi
} | tee "$EV/m1_base_worktree.txt"
