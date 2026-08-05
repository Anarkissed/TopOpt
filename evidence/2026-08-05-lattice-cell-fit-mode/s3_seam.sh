#!/usr/bin/env bash
# S3 — THE SEAM BETWEEN TWO REGIONS WITH DIFFERENT CELLS. MEASURED, NOT SOLVED.
#
#   ./s3_seam.sh <branch-build-dir> <out-dir>
#
# WHAT THIS IS NOT. It does not attempt the transition problem. Blending lattices of
# different unit size is live research; the brief forbids attempting it and this does
# not. It MEASURES what the shipped emitter produces where two regions with different
# derived cells abut, so the defect (if any) is named rather than silent.
#
# THE FIXTURE: two include slabs that share a face on the demo l-bracket. They are
# UNBOUNDED in plane (half_u/half_w 200 mm) on purpose: a first attempt bounded them
# to 30x30 mm and the optimizer had removed all the material there, so the run
# reported include_void_voxels 7600, region_voxels 0 and measured nothing. An empty
# seam measurement is not a passing one.
#   region 0 — 4 mm deep   -> derived cell max(4/5, 1.0950)  = 1.0950 mm
#   region 1 — 24 mm deep  -> derived cell max(24/5, 1.0950) = 4.8000 mm
# One dyadic ladder with base 1.0950 mm, so region 1 lands on level 2 (4.3801 mm) —
# the coarsest rung at or below what it asked for. Levels 0 and 2 face-adjacent are
# split to level 1 by the 2:1 balance, so the seam is a graded band, not a step.
#
# WHAT IS REPORTED: the connected-component count of the emitted lattice, the count
# of components sharing space with nothing else (R5's isolated count, at the job's own
# line width), and the triangle/vertex census either side of the seam plane.
set -euo pipefail
BUILD="$(cd "${1:?usage: s3_seam.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
# Two slabs stacked along +Z, sharing the plane z = 12: [8,12] is 4 mm and [12,36]
# is 24 mm. Their derived cells differ by a factor of 4.38, so the ladder is real.
regions = [
  {"role": "include", "kind": "face",
   "geometry": {"origin": [0.0, 0.0, 8.0], "normal": [0.0, 0.0, 1.0],
                "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 4.0}},
  {"role": "include", "kind": "face",
   "geometry": {"origin": [0.0, 0.0, 12.0], "normal": [0.0, 0.0, 1.0],
                "half_u_mm": 200.0, "half_w_mm": 200.0, "depth_mm": 24.0}},
]
job = {
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  # ONE rung, self-weight, iteration-capped. A "loads" block would put the job on the
  # loadcase path, where the schema refuses both "ladder" and "margin_stop" and the
  # production ladder runs to the MMA plateau — hours on a shared machine for a bar
  # that is about the SEAM, not about the design.
  "resolution": 40, "simp": {"max_iterations": 20},
  "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
  "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
  "ladder": [0.6], "margin_stop": 0.0,
  "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
              "min_extrudable_width_mm": 0.42, "regions": regions},
  "grading": {"topology": "octet", "cell_mode": "fit",
              "min_extrudable_width_mm": 0.42},
  "output": {"report": "report.json", "mesh_format": "stl",
             "mesh_prefix": "variant"}
}
json.dump(job, open(os.path.join(out, "job_seam.json"), "w"), indent=1)
PY

rm -rf "${OUT:?}/run"
set +e
( cd "$OUT" && "$BUILD/topopt-cli" run job_seam.json --out run > run.log 2>&1 )
rc=$?
set -e
echo "exit code: $rc"
grep -E "^\[lattice\] FIT" "$OUT/run.log" | head -6 || true
echo
python3 - "$OUT/run" <<'PY'
import json, os, sys
d = sys.argv[1]
ri = os.path.join(d, "run_info.json")
if not os.path.exists(ri):
    print("no run_info.json — see run.log"); raise SystemExit
g = (json.load(open(ri)).get("grading") or {})
print(f"cell_base_mm  {g.get('cell_base_mm')}   max_level {g.get('cell_max_level')}")
print(f"cells split by the 2:1 balance: {g.get('cells_split_by_balance')}")
for L in g.get("cell_levels", []):
    print("  level {level}: cell {cell_size_mm} mm, {cells} cells, {voxels} voxels, "
          "min cells/member {min_cells_per_member}, out_of_regime {out_of_regime}"
          .format(**L))
fit = g.get("fit") or {}
for r in fit.get("regions", []):
    print("  region {region_index}: extent {extent_mm} -> derived cell {cell_mm} "
          "@ rho {relative_density}".format(**r))
PY
echo
echo "=== the seam, measured on the emitted mesh ==="
for m in "$OUT"/run/*_lattice.stl; do
  [ -f "$m" ] || continue
  # `|| true`: r5 exits non-zero when it finds an isolated component, and under
  # `set -e` that would kill this script before the seam census below — which is the
  # measurement the whole file exists for.
  python3 "$REPO/evidence/2026-08-05-lattice-cell-fit-mode/r5_percolation.py" \
      "$m" "$OUT/run/run_info.json" || true
  python3 - "$m" <<'PY'
import struct, sys
import numpy as np
d = open(sys.argv[1], "rb").read()
n = struct.unpack("<I", d[80:84])[0]
raw = np.frombuffer(d, dtype=np.uint8, count=n * 50, offset=84).reshape(n, 50)
tris = raw[:, :48].copy().view(np.float32).reshape(n, 12)[:, 3:12] \
    .reshape(n, 3, 3).astype(float)
z = tris[:, :, 2]
# The seam plane is z = 12: region 0 is [8,12], region 1 is [12,36].
below = np.count_nonzero(z.max(axis=1) <= 12.0)
above = np.count_nonzero(z.min(axis=1) >= 12.0)
straddle = n - below - above
print(f"  triangles wholly below the seam (z<=12): {below}")
print(f"  triangles wholly above the seam (z>=12): {above}")
print(f"  triangles STRADDLING the seam plane    : {straddle}")
# Is there a GAP? Look for a band with no geometry either side of the plane.
for band in (0.5, 1.0, 2.0):
    lo = np.count_nonzero((z.min(axis=1) >= 12.0 - band) & (z.max(axis=1) <= 12.0))
    hi = np.count_nonzero((z.min(axis=1) >= 12.0) & (z.max(axis=1) <= 12.0 + band))
    print(f"  triangles within {band} mm below / above the seam: {lo} / {hi}")
PY
done
