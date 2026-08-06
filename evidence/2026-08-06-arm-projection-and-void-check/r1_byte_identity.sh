#!/usr/bin/env bash
# R1 (second half) — BYTE-IDENTICAL WITH BOTH SWITCHES OFF.
# task 2026-08-06-arm-projection-and-void-check
#
#   ./r1_byte_identity.sh <base-cli> <branch-cli> <work-dir>
#
# ★ THERE IS NO BYTE-IDENTITY CLAIM FOR THE DEFAULT PATH. Both features are
# armed on purpose and the default export CHANGES; that change is measured in
# r1_before_after.py, not argued away here.
#
# WHAT IS STILL CLAIMED, and what this proves: turning both switches OFF gets
# the OLD BYTES BACK, exactly. That is what makes the OFF controls worth having
# — the maintainer can run the same job both ways and know that the "off" arm is
# not merely similar to what he had, but identical to it. If disarming produced
# something subtly different, every A/B he runs while evaluating the new default
# would be comparing against a third thing.
#
# THE SUBJECT EXERCISES BOTH FEATURES. A STEP part (so CAD-face projection has
# analytic surfaces to attribute to) with a lattice include region (so the
# enclosed-void check has a lattice to judge). A job that triggered neither would
# make this bar pass without testing anything.
#
# ★ THE BAR GUARDS ITSELF. A byte-identity comparison passes vacuously if the
# two binaries are the same file — the trap that bit PR 305 and PR 307, where
# `--target topopt-cli` (hyphen) builds NOTHING and exits 0 because the CMake
# target is `topopt_cli` (underscore). So the two binary hashes MUST differ and
# this script exits non-zero if they do not.
#
# run_info.json and iterations.csv are excluded BY NAME, and named here rather
# than quietly skipped: they carry wall-clock timings that differ between any two
# runs of anything.
set -euo pipefail

BASE="$1"
BRANCH="$2"
W="$3"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rm -rf "$W"; mkdir -p "$W"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$W/"

cat > "$W/job.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "fixture_faces": [ { "kind": "cylindrical", "radius_mm": 2.5 } ],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.7, 0.5],
  "margin_stop": 1.5,
  "simp": { "max_iterations": 30 },
  "output": {
    "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant",
    "project_cad_faces": false
  },
  "lattice": {
    "topology": "octet", "cell_mm": 8.0, "strut_radius_mm": 1.2,
    "emit_stl": true, "skin": "none",
    "require_lattice_void_reaches_exterior": false
  }
}
JSON

echo "-- the guard: the two binaries MUST differ ---------------------"
bh=$(shasum -a 256 "$BRANCH" | cut -d' ' -f1)
ah=$(shasum -a 256 "$BASE"   | cut -d' ' -f1)
echo "branch binary sha256 $bh"
echo "base   binary sha256 $ah"
if [ "$bh" = "$ah" ]; then
  echo "R1 INVALID: the two binaries are byte-identical, so this bar would pass"
  echo "            vacuously. Rebuild before trusting anything below."
  exit 2
fi
echo "the binaries differ, so the comparison is real."
echo

echo "-- the job: BOTH switches explicitly false --------------------"
grep -E 'project_cad_faces|require_lattice_void_reaches_exterior' "$W/job.json"
echo

( cd "$W" && "$BASE"   run job.json --out out_base   > base.log   2>&1 )
( cd "$W" && "$BRANCH" run job.json --out out_branch > branch.log 2>&1 )

echo "-- the bar: every artifact byte-identical ----------------------"
cd "$W"
fail=0; n=0
for f in $(cd out_base && find . -type f | sort); do
  case "$(basename "$f")" in
    run_info.json|iterations.csv)
      echo "  (excluded, carries wall-clock timings: $f)"; continue;;
    build_orientation.json)
      # NOT excluded wholesale. This file is 99% geometry and two wall clocks
      # (`sweep_seconds`, `strut_axis_measure_seconds`), and dropping the whole
      # document to avoid two timing fields would stop asserting the orientation
      # decision itself — which is exactly the kind of thing a geometry change
      # could move. So the CLOCKS are stripped and everything else is compared,
      # and the stripped keys are named on stdout rather than assumed harmless.
      n=$((n+1))
      if ! python3 - "out_base/$f" "out_branch/$f" <<'PY'
import json, re, sys
CLOCKS = ("sweep_seconds", "strut_axis_measure_seconds")
def strip(p):
    s = open(p).read()
    for k in CLOCKS:
        s = re.sub(r'"%s"\s*:\s*[-0-9.eE+]+' % k, '"%s": <clock>' % k, s)
    return s
a, b = strip(sys.argv[1]), strip(sys.argv[2])
sys.exit(0 if a == b else 1)
PY
      then
        echo "  DIFFERS: $f (beyond its wall-clock fields)"; fail=1
      else
        echo "  (identical apart from the wall clocks sweep_seconds and"
        echo "   strut_axis_measure_seconds: $f)"
      fi
      continue;;
  esac
  n=$((n+1))
  if ! cmp -s "out_base/$f" "out_branch/$f"; then
    echo "  DIFFERS: $f"; fail=1
  fi
done
# A file present in one arm and not the other is a difference too.
diff <(cd out_base && find . -type f | sort) \
     <(cd out_branch && find . -type f | sort) > /dev/null || {
  echo "  DIFFERS: the two arms wrote different FILE SETS"; fail=1; }

echo
if [ "$fail" = 0 ]; then
  echo "R1 MET: with both switches off, every artifact is byte-identical across"
  echo "        the merge-base binary and the branch binary."
  echo "files compared: $n"
  (cd out_branch && find . -type f ! -name run_info.json ! -name iterations.csv \
      | sort | xargs shasum -a 256)
  exit 0
fi
echo "R1 NOT MET — see the DIFFERS lines above."
exit 1
