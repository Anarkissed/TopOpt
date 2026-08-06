#!/usr/bin/env bash
# R6 — ITERATIONS AND WALL, ALWAYS BOTH, SEPARATELY. And the file size, which is the
# cost this mode actually incurs.
#
#   ./r6_cost.sh <branch-build-dir> <out-dir>
#
# THE FIXTURE is chosen so BOTH modes actually run: ONE 12 mm include region. At a
# 0.42 mm bead `auto` plans 4.6026 mm (2.61 cells across — it percolates, so the
# pre-flight reports rather than refuses) and `fit` derives 12/5 = 2.4000 mm.
#
# WHAT THIS ISOLATES. On a graded two-step run the cell law runs AFTER the solve, so
# the optimizer's trajectory cannot depend on the cell mode. The SOLVER ITERATIONS
# must therefore be identical between the two runs and only the lattice GENERATION
# and the emitted file may move. Asserting that is what makes the wall-clock number
# mean "generation", not "a different design".
set -euo pipefail
BUILD="$(cd "${1:?usage: r6_cost.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
regions = [{"role": "include", "kind": "face",
            "geometry": {"origin": [0.0, 0.0, 10.0], "normal": [0.0, 0.0, 1.0],
                         "half_u_mm": 200.0, "half_w_mm": 200.0,
                         "depth_mm": 12.0}}]
def job(mode):
    return {
      "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
      # ONE rung, self-weight, iteration-capped — not a "loads" block: on the
      # loadcase path the schema refuses both "ladder" and "margin_stop" and the
      # production ladder runs to the MMA plateau, which is an hour per side on a
      # shared machine for a comparison about GENERATION cost.
      "resolution": 40, "simp": {"max_iterations": 20},
      "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
      "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
      "ladder": [0.6], "margin_stop": 0.0,
      "lattice": {"topology": "octet", "emit_stl": True, "skin": "none",
                  "min_extrudable_width_mm": 0.42, "regions": regions},
      "grading": {"topology": "octet", "cell_mode": mode,
                  "min_extrudable_width_mm": 0.42},
      "output": {"report": "report.json", "mesh_format": "stl",
                 "mesh_prefix": "variant"}
    }
json.dump(job("auto"), open(os.path.join(out, "job_auto.json"), "w"), indent=1)
json.dump(job("fit"),  open(os.path.join(out, "job_fit.json"),  "w"), indent=1)
PY

run() {
  rm -rf "${OUT:?}/$2"
  set +e
  ( cd "$OUT" && "$BUILD/topopt-cli" run "$1" --out "$2" > "$2.log" 2>&1 )
  echo $?
  set -e
}
echo "auto exit: $(run job_auto.json auto)"
echo "fit  exit: $(run job_fit.json  fit)"
echo
python3 - "$OUT" <<'PY'
import glob, json, os, sys
out = sys.argv[1]
rows = {}
for sub in ("auto", "fit"):
    d = os.path.join(out, sub)
    ri = os.path.join(d, "run_info.json")
    if not os.path.exists(ri):
        print(f"{sub}: no run_info.json — see {sub}.log"); continue
    info = json.load(open(ri))
    g = info.get("grading") or {}
    lat = info.get("lattice_export") or {}
    it = os.path.join(d, "iterations.csv")
    n_iter = sum(1 for _ in open(it)) - 1 if os.path.exists(it) else -1
    meshes = sorted(glob.glob(os.path.join(d, "*_lattice.stl")))
    size = sum(os.path.getsize(m) for m in meshes)
    tris = sum((os.path.getsize(m) - 84) // 50 for m in meshes)
    rows[sub] = dict(cell=g.get("cell_size_mm"),
                     latticed=g.get("latticed_voxels"),
                     region=g.get("region_voxels"),
                     iters=n_iter,
                     gen=lat.get("gen_seconds"),
                     meshes=len(meshes), bytes=size, tris=tris)
    print(f"{sub}: cell {rows[sub]['cell']} mm   latticed {rows[sub]['latticed']}"
          f" / {rows[sub]['region']} region voxels")
    print(f"      SOLVER ITERATIONS (all rungs, from iterations.csv): "
          f"{rows[sub]['iters']}")
    print(f"      LATTICE GENERATION WALL (s, run_info.lattice_export.gen_seconds): "
          f"{rows[sub]['gen']}")
    print(f"      emitted {rows[sub]['meshes']} lattice mesh(es), "
          f"{rows[sub]['tris']} triangles, {rows[sub]['bytes']} bytes")
if "auto" in rows and "fit" in rows:
    a, f = rows["auto"], rows["fit"]
    print()
    same = a["iters"] == f["iters"]
    print(f"ITERATIONS IDENTICAL: {same}  ({a['iters']} vs {f['iters']}) — the cell "
          f"law runs after the solve, so anything else would mean the modes moved "
          f"the DESIGN, not just the lattice.")
    if a["gen"] and f["gen"]:
        print(f"GENERATION WALL     : {a['gen']:.3f} s -> {f['gen']:.3f} s "
              f"({f['gen']/a['gen']:.2f}x)")
    if a["tris"]:
        print(f"TRIANGLES           : {a['tris']} -> {f['tris']} "
              f"({f['tris']/a['tris']:.2f}x)")
        print(f"BYTES               : {a['bytes']} -> {f['bytes']} "
              f"({f['bytes']/a['bytes']:.2f}x)")
    print(f"CELL RATIO          : {a['cell']:.4f} -> {f['cell']:.4f} "
          f"({a['cell']/f['cell']:.2f}x finer per axis)")
PY
echo
echo "=== R5 on both, at the job's own line width ==="
for sub in auto fit; do
  for m in "$OUT/$sub"/*_lattice.stl; do
    [ -f "$m" ] || continue
    python3 "$REPO/evidence/2026-08-05-lattice-cell-fit-mode/r5_percolation.py" \
        "$m" "$OUT/$sub/run_info.json"
  done
done
