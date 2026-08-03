#!/usr/bin/env bash
# BAR 1 — BIT-IDENTICAL WITHOUT LATTICE (task 2026-08-04-protect-freeze-vs-solidity).
#
# "Face protection + no lattice declaration produces bit-identical report.json,
#  fields.bin and meshes."
#
# This is the load-bearing bar, so it is measured the load-bearing way: the SAME
# job document is run by a topopt-cli built from BASE (main) and by one built
# from this BRANCH, and every artifact is compared by sha256. Not "the code path
# looks unchanged" — the bytes.
#
#   ./bar1_byte_identity.sh <base-cli> <branch-cli> <out-dir>
#
# The job (written here, not committed as a fixture — fixtures are forbidden by
# this task's scope) is the l-bracket demo with a declared load case AND a face
# protection AND NO lattice block: exactly the configuration the bar names.
set -euo pipefail

BASE_CLI="${1:?usage: bar1_byte_identity.sh <base-cli> <branch-cli> <out-dir>}"
BRANCH_CLI="${2:?}"
OUT="${3:?}"
DEMO="${DEMO_DIR:?set DEMO_DIR to core/tests/fixtures/demo}"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

cat > "$OUT/job.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 32,
  "simp": {"max_iterations": 12},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [5],
    "face_protection_depth_mm": 3.0
  },
  "output": {
    "report": "report.json",
    "mesh_format": "stl",
    "mesh_prefix": "variant"
  }
}
JSON

run() {  # run <cli> <subdir>
  local cli="$1" sub="$2"
  rm -rf "$OUT/$sub"
  ( cd "$OUT" && "$cli" run job.json --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub) — tail of log:"; tail -20 "$OUT/$sub.log"; exit 1; }
  ( cd "$OUT/$sub" && find . -type f ! -name '*.log' | sort \
      | xargs shasum -a 256 ) > "$OUT/$sub.sha256"
}

echo "=== BAR 1 — face protection + NO lattice, base vs branch ==="
echo "base   cli: $BASE_CLI"
echo "branch cli: $BRANCH_CLI"
echo

run "$BASE_CLI" base
run "$BRANCH_CLI" branch

echo "--- base artifacts ---"
cat "$OUT/base.sha256"
echo
echo "--- branch artifacts ---"
cat "$OUT/branch.sha256"
echo

# ── THE BAR ITSELF: report.json, fields.bin and the meshes, byte for byte.
fail=0
echo "--- the bar's named artifacts ---"
for f in report.json fields.bin design.bin loadcase.json variant_026.stl \
         variant_038.stl variant_052.stl variant_068.stl; do
  a=$(shasum -a 256 "$OUT/base/$f"   | cut -d' ' -f1)
  b=$(shasum -a 256 "$OUT/branch/$f" | cut -d' ' -f1)
  if [ "$a" = "$b" ]; then echo "IDENTICAL  $f  $a"
  else echo "DIFFERS    $f"; echo "  base   $a"; echo "  branch $b"; fail=1; fi
done

# ── THE TWO ARTIFACTS THAT CARRY A CLOCK, and are therefore compared with the
# clock removed — stated explicitly, because "we excluded the files that
# differed" is exactly the move that hides a real regression.
#
#   run_info.json   — `created_wall_ms` is the run's start timestamp.
#   iterations.csv  — column 3 is a wall-clock ms stamp and the trailing columns
#                     are per-phase millisecond timings. Every PHYSICS column
#                     (compliance, volume fraction, iteration counts, CG counts)
#                     is compared verbatim.
#
# Neither can be byte-identical across two runs of the SAME binary, so a strict
# comparison here would prove nothing about the change. What IS proven: with the
# clock removed they are identical.
echo
echo "--- clock-bearing artifacts, compared with the clock removed ---"
strip_run_info() {
  python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
d.pop('created_wall_ms', None)
print(json.dumps(d, sort_keys=True, indent=1))" "$1"
}
if diff -u <(strip_run_info "$OUT/base/run_info.json") \
           <(strip_run_info "$OUT/branch/run_info.json") \
           > "$OUT/run_info.stripped.diff"; then
  echo "IDENTICAL  run_info.json (minus created_wall_ms)"
else
  echo "DIFFERS    run_info.json beyond the timestamp:"; cat "$OUT/run_info.stripped.diff"; fail=1
fi
# iterations.csv: keep the header and columns 1,2,4..13 (rung, iter, compliance,
# volume fraction, and the integer iteration/CG counts) — everything that is not
# a clock reading.
strip_iters() { cut -d, -f1,2,4-13 "$1"; }
if diff -u <(strip_iters "$OUT/base/iterations.csv") \
           <(strip_iters "$OUT/branch/iterations.csv") \
           > "$OUT/iterations.stripped.diff"; then
  echo "IDENTICAL  iterations.csv (physics columns; timestamps + ms timings dropped)"
else
  echo "DIFFERS    iterations.csv in a physics column:"; cat "$OUT/iterations.stripped.diff"; fail=1
fi

echo
if [ "$fail" = "0" ]; then
  echo "BAR 1 PASS — report.json, fields.bin and every mesh are byte-identical;"
  echo "             the two clock-bearing artifacts are identical once the clock"
  echo "             is removed. Face protection with no lattice declaration is"
  echo "             unchanged by this task."
  exit 0
fi
echo "BAR 1 FAIL."
exit 1
