#!/usr/bin/env bash
# B1 — A RUN WHOSE EVERY DECLARED INCLUDE REGION IS TOO THIN MUST REFUSE.
#
#   ./b1_all_regions_too_thin.sh <build-dir> <out-dir>
#
# THE DEFECT, in the maintainer's own shape. His overnight run (fingerprint
# b3abcf880554) declared SEVEN include regions, every one of them 4 mm across its
# thinnest dimension, against a uniform 8 mm lattice cell. The cells-per-member floor
# needs 5 x 8 = 40 mm. The forecast computed exactly that — run_info.json carries
# forecast_include_regions 7, forecast_region_too_thin 7, forecast_required_member_mm
# 40, forecast_thinnest_region_mm 4 — printed it to stderr, and the run PROCEEDED:
# four variants, all lattice_accepted true, and a part whose lattice is nowhere he
# asked for it.
#
# This reproduces that shape on the demo l-bracket: seven 4 mm include slabs, an 8 mm
# cell. Against unfixed code the run SUCCEEDS and emits lattice. It must REFUSE, name
# the arithmetic per region, and state the cell that would work.
set -euo pipefail
BUILD="${1:?usage: b1_all_regions_too_thin.sh <build-dir> <out-dir>}"
OUT="${2:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

# SEVEN include slabs, each 4 mm deep — his geometry's thinnest dimension — stacked
# up the part so they land on real material. The 8 mm cell is his run's cell verbatim.
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
regions = [{"role": "include", "kind": "face",
            "geometry": {"origin": [0.0, 0.0, 8.0 + 6.0 * i],
                         "normal": [0.0, 0.0, 1.0],
                         "half_u_mm": 200.0, "half_w_mm": 200.0,
                         "depth_mm": 4.0}}
           for i in range(7)]
job = {
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 48, "simp": {"max_iterations": 12},
  "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
  "lattice": {"topology": "octet", "emit_stl": True, "skin": "rim",
              "cell_mm": 8.0, "strut_radius_mm": 1.0953720830,
              "min_extrudable_width_mm": 0.42, "regions": regions},
  "output": {"report": "report.json", "mesh_format": "stl",
             "mesh_prefix": "variant"}
}
json.dump(job, open(os.path.join(out, "job_thin7.json"), "w"), indent=1)
PY

echo "=== B1: seven 4 mm include regions, 8 mm cell (floor needs 5 x 8 = 40 mm) ==="
rm -rf "${OUT:?}/run"
set +e
( cd "$OUT" && "$BUILD/topopt-cli" run job_thin7.json --out run > run.log 2>&1 )
rc=$?
set -e
echo "topopt-cli exit code: $rc"
echo
echo "--- the forecast it printed ---"
grep -E "FORECAST" "$OUT/run.log" | head -12 || echo "(no forecast lines)"
echo
if [ "$rc" -eq 0 ]; then
  echo "*** B1 REPRODUCED: the run SUCCEEDED with every declared region too thin. ***"
  ls "$OUT/run"/*_lattice.stl 2>/dev/null | while read -r f; do
    echo "    emitted $(basename "$f")"
  done
  python3 - "$OUT/run" <<'PY'
import glob, json, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*_lattice.report.json"))):
    d = json.load(open(f))
    print(f"    {os.path.basename(f)}: cell_mm={d.get('cell_mm')} "
          f"latticed_cells={(d.get('generation') or {}).get('latticed_cells')}")
ri = os.path.join(sys.argv[1], "run_info.json")
if os.path.exists(ri):
    L = json.load(open(ri)).get("lattice_export") or {}
    print(f"    forecast: {L.get('forecast_region_too_thin')} of "
          f"{L.get('forecast_include_regions')} regions too thin; "
          f"required {L.get('forecast_required_member_mm')} mm; "
          f"thinnest {L.get('forecast_thinnest_region_mm')} mm")
    print(f"    latticed_cells emitted anyway: {L.get('latticed_cells')}")
PY
  echo
  echo "B1 FAIL (expected, on unfixed code): a forecast that says nothing can be"
  echo "        latticed did not stop the run."
  exit 1
fi
echo "--- the refusal ---"
tail -20 "$OUT/run.log"
echo
echo "B1 PASS — the run refused before solving."
