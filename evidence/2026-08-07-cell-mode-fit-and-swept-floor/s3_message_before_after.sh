#!/usr/bin/env bash
# S3 — THE MEASURED IMPROVEMENT, on the maintainer's OWN nine-region case.
#
#   ./s3_message_before_after.sh <branch-build-dir> <base-build-dir> <out-dir>
#
# "Shorter" without a number is not a result (bar S3d). This prints, for HIS case:
#   * characters
#   * logical lines (what the code emits)
#   * WRAPPED lines at 60 columns — the number that actually decides whether the
#     action is above the fold on an iPad, which is the complaint being answered
# before and after, plus both messages verbatim.
#
# It also runs the audit set: every OTHER multi-region message this pre-flight can
# produce (fit, and the two case-C notes), before and after.
set -euo pipefail
BR="$(cd "${1:?usage: s3_message_before_after.sh <branch-build> <base-build> <out>}" && pwd)/topopt-cli"
BASE="$(cd "${2:?}" && pwd)/topopt-cli"
mkdir -p "${3:?}"
OUT="$(cd "$3" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/evidence/2026-08-05-smoothing-must-actually-smooth/WallMount_ShelfBracket.stl" "$OUT/"
# --materials is passed EXPLICITLY. The base binary bakes in the path of the worktree
# it was configured from, and that worktree is removed after r1_byte_identity.sh
# finishes — without this the BEFORE arm dies on "cannot open materials file" and the
# comparison silently measures an error message against a refusal.
MATS="$REPO/core/src/materials/materials.json"
RULES="$REPO/core/src/settings/rules.json"
[ -f "$MATS" ] || { echo "materials.json not found at $MATS"; exit 1; }
[ -f "$RULES" ] || { echo "rules.json not found at $RULES"; exit 1; }

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
# HIS CASE: nine bolt include regions — three at 2.828 mm, three at 4.000 mm and three
# at 6.000 mm across their thinnest dimension (min(2r, 2*half_length)) — on his own
# part, at his own 0.45 mm strut line width (the max of his 0.42 outer and 0.45 inner
# wall widths, which is the rule task 2026-08-06-strut-line-width-field shipped).
radii = [1.4142135623730951]*3 + [2.0]*3 + [3.0]*3
regions = [{"role": "include", "kind": "bolt",
            "geometry": {"axis_point": [50.0, -180.0 + 21.0*i, 10.0],
                         "axis_dir": [1.0, 0.0, 0.0],
                         "radius_mm": r, "half_length_mm": 20.0}}
           for i, r in enumerate(radii)]

def job(grading):
    return {"model": "WallMount_ShelfBracket.stl", "material": "PLA",
            "mode": "minimize_plastic", "resolution": 64,
            # Cheap driving: his own `loads` block runs the production ladder to the
            # MMA plateau (the schema refuses `ladder`/`margin_stop` there), and this
            # bar only needs the PRE-FLIGHT, which runs before any solve.
            "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.0}],
            "gravity": {"direction": [0.0, 1.0, 0.0], "magnitude_mm_s2": 9810.0},
            "ladder": [0.6], "margin_stop": 0.0, "simp": {"max_iterations": 1},
            "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                        "regions": regions},
            "grading": dict({"topology": "octet",
                             "min_extrudable_width_mm": 0.45}, **grading),
            "output": {"report": "report.json", "mesh_format": "stl",
                       "mesh_prefix": "variant"}}

json.dump(job({"cell_mode": "auto"}),
          open(os.path.join(out, "his_auto.json"), "w"), indent=1)
json.dump(job({"cell_mode": "fit"}),
          open(os.path.join(out, "his_fit.json"), "w"), indent=1)
json.dump(job({"cell_mode": "swept", "cell_min_mm": 1.173,
               "cell_max_mm": 9.384}),
          open(os.path.join(out, "his_swept.json"), "w"), indent=1)
# The audit's third shape: a region THICK enough to percolate but under the accuracy
# floor — the case-C note, which is a forecast rather than a refusal.
thick = json.loads(json.dumps(job({"cell_mode": "fixed", "cell_mm": 1.5})))
json.dump(thick, open(os.path.join(out, "his_caseC.json"), "w"), indent=1)
PY

measure() { # measure <label> <file>
  local chars lines wrapped
  chars=$(wc -c < "$2" | tr -d ' ')
  lines=$(wc -l < "$2" | tr -d ' ')
  wrapped=$(fold -s -w 60 < "$2" | wc -l | tr -d ' ')
  printf "  %-34s chars=%-7s lines=%-5s wrapped@60=%s\n" "$1" "$chars" "$lines" "$wrapped"
}

# The pre-flight's own output, isolated from the rest of the run's logging.
lattice_only() { grep -E '^\[lattice\]|^topopt-cli:|^  |^Why:|^SET |^THICKEN |^ARM |^NOTHING |^This job|^A cell of' "$1" 2>/dev/null || true; }

one() { # one <job> <tag>
  local job="$1" tag="$2"
  ( cd "$OUT" && "$BASE" run "$job" --out "b_$tag" --materials "$MATS" --rules "$RULES" > "$tag.base.log" 2>&1 || true )
  ( cd "$OUT" && "$BR"   run "$job" --out "r_$tag" --materials "$MATS" --rules "$RULES" > "$tag.branch.log" 2>&1 || true )
  # A BEFORE arm that never reached the pre-flight would make any reduction look
  # spectacular. Assert it actually produced the message being compared.
  grep -qE '^\[lattice\]|^topopt-cli: .*(lattice|region)' "$OUT/$tag.base.log" || {
    echo "  ★ INVALID — the BEFORE arm never reached the pre-flight (see $tag.base.log)."
    echo "    Every number below would be measuring an unrelated error message."; }
  lattice_only "$OUT/$tag.base.log"   > "$OUT/$tag.base.msg"
  lattice_only "$OUT/$tag.branch.log" > "$OUT/$tag.branch.msg"
  echo "=== $tag ==="
  measure "BEFORE (origin/main)" "$OUT/$tag.base.msg"
  measure "AFTER  (this branch)" "$OUT/$tag.branch.msg"
  python3 - "$OUT/$tag.base.msg" "$OUT/$tag.branch.msg" <<'PY'
import sys
a = open(sys.argv[1]).read(); b = open(sys.argv[2]).read()
ca, cb = len(a), len(b)
if ca:
    print("  characters: %d -> %d  (%+.1f%%)" % (ca, cb, 100.0*(cb-ca)/ca))
PY
  echo
}

echo "##########################################################################"
echo "# HIS CASE — nine include regions, cell_mode \"auto\", 0.45 mm strut width #"
echo "##########################################################################"
one his_auto.json his_auto
echo "-------------------------- BEFORE, verbatim -----------------------------"
cat "$OUT/his_auto.base.msg"
echo "-------------------------- AFTER, verbatim ------------------------------"
cat "$OUT/his_auto.branch.msg"
echo

echo "##########################################################################"
echo "# THE AUDIT — every OTHER multi-region message this pre-flight produces   #"
echo "##########################################################################"
one his_fit.json    his_fit
one his_swept.json  his_swept
one his_caseC.json  his_caseC
echo "------------------------- FIT, AFTER, verbatim --------------------------"
cat "$OUT/his_fit.branch.msg"
echo "------------------------ SWEPT, AFTER, verbatim -------------------------"
cat "$OUT/his_swept.branch.msg"
echo "----------------------- CASE C, AFTER, verbatim -------------------------"
cat "$OUT/his_caseC.branch.msg"
