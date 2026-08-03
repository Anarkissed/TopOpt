#!/bin/sh
# M8 (pipeline half) — a MULTISCALE run is deterministic end to end.
#
# The probe's m8 bar covers the design LOOP (identical density field, identical CG
# counts, identical compliance history, identical projection charge). This covers
# the whole PIPELINE: run the same multiscale job twice and compare sha256 of every
# artifact — report.json, run_info.json (which carries the projection charge and the
# per-iteration floor history), the lattice receipts and every mesh.
#
# A small fixture on purpose: determinism is a property of the code path, not of the
# problem size, and the maintainer's 128^3 part is measured separately for M2-M7.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EV="$ROOT/evidence/2026-08-03-multiscale-lattice-to"
WORK="$EV/m8_pipeline"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$ROOT/evidence/2026-07-28-lattice-generation-production/l-bracket.step" "$WORK/"

cat > "$WORK/job.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 40,
  "fixture_faces": [{ "kind": "cylindrical", "radius_mm": 2.5 }],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.6, 0.45],
  "margin_stop": 1.5,
  "simp": { "max_iterations": 15 },
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" },
  "lattice": { "topology": "octet", "min_extrudable_width_mm": 0.12,
               "emit_stl": true, "multiscale": true },
  "grading": { "topology": "octet", "cell_mm": 2.5,
               "min_extrudable_width_mm": 0.12, "demand_exponent": 1.0 }
}
JSON

# TWO CLASSES OF ARTIFACT, and the difference matters.
#
#   RESULT artifacts — design.bin, fields.bin, report.json, every mesh, every
#   lattice receipt — carry the ANSWER and must be bit-identical.
#
#   INSTRUMENT artifacts — iterations.csv, run_info.json and build_orientation.json
#   (whose sweep_seconds / strut_axis_measure_seconds are stopwatch readings) carry
#   WALL CLOCK and resident-memory samples (total_ms, fea_ms, created_wall_ms,
#   rss_mb, ...). Those are measurements of the machine, not of the design, and
#   they are not reproducible by construction. They are compared with the timing
#   columns stripped, so a real content change would still be caught.
sum() { find "$1" -type f | sed "s|$1/||" | sort | while read -r f; do
          printf '%s  %s\n' "$(shasum -a 256 "$1/$f" | cut -d' ' -f1)" "$f"; done; }

for r in a b; do
  "$ROOT/build/topopt-cli" run "$WORK/job.json" --out "$WORK/out_$r" > "$WORK/run_$r.log" 2>&1
  # RESULT artifacts, hashed whole.
  find "$WORK/out_$r" -type f ! -name iterations.csv ! -name run_info.json \
       ! -name build_orientation.json \
    | sed "s|$WORK/out_$r/||" | sort | while read -r f; do
        printf '%s  %s\n' "$(shasum -a 256 "$WORK/out_$r/$f" | cut -d' ' -f1)" "$f"
      done > "$WORK/result_$r.txt"
  # INSTRUMENT artifacts, timing columns stripped.
  python3 - "$WORK/out_$r" "$WORK/instr_$r.txt" <<'PY'
import csv, json, re, sys
d, out = sys.argv[1], sys.argv[2]
# Machine measurements, not design data: stopwatch readings, resident memory,
# and the OS's own paging counters (major_faults / swapins vary with what else the
# host is doing). Everything else — compliance, achieved_vf, cg_iters, matvecs,
# geneo_action, every verdict — must match exactly.
TIME = re.compile(r'(_ms$|^wall_ms$|_mb$|^rss|^peak_rss|^available|_seconds$|_s$'
                  r'|^major_faults$|^swapins$|^gen_fraction$)')
lines = []
with open(d + '/iterations.csv') as fh:
    r = csv.DictReader(fh)
    keep = [c for c in r.fieldnames if not TIME.search(c)]
    lines.append(','.join(keep))
    for row in r:
        lines.append(','.join(row[c] for c in keep))
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not TIME.search(k)}
    if isinstance(o, list):
        return [strip(v) for v in o]
    return o
lines.append(json.dumps(strip(json.load(open(d + '/run_info.json'))), sort_keys=True))
import os
bo = d + '/build_orientation.json'
if os.path.exists(bo):
    lines.append(json.dumps(strip(json.load(open(bo))), sort_keys=True))
open(out, 'w').write('\n'.join(lines))
PY
done

{
  echo "M8 — MULTISCALE PIPELINE DETERMINISM (two identical runs of the same job)"
  echo
  echo "--- RESULT artifacts (design.bin, fields.bin, report.json, meshes, receipts) ---"
  if diff -u "$WORK/result_a.txt" "$WORK/result_b.txt"; then
    echo "IDENTICAL — every result artifact matches byte for byte."
    sed 's/^/  /' "$WORK/result_a.txt"
  else
    echo "DIFFERENCES FOUND (above)."; exit 1
  fi
  echo
  echo "--- INSTRUMENT artifacts (iterations.csv, run_info.json, build_orientation.json), timings stripped ---"
  echo "    stripped: every *_ms / *_mb / rss* / *_seconds field, plus the OS paging"
  echo "    counters major_faults / swapins and gen_fraction (a ratio of two wall"
  echo "    clocks) — measurements of the machine, not of"
  echo "    the design, and not reproducible by construction."
  if diff -u "$WORK/instr_a.txt" "$WORK/instr_b.txt" > /dev/null; then
    echo "IDENTICAL — CG counts, GenEO actions, compliance history, the projection"
    echo "charge, the per-iteration floor history and every verdict all match exactly."
  else
    echo "DIFFERENCES FOUND:"; diff -u "$WORK/instr_a.txt" "$WORK/instr_b.txt" | head -40
    exit 1
  fi
} | tee "$EV/m8_pipeline_determinism.txt"
