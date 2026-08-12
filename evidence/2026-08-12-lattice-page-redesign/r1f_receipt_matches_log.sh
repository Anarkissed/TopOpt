#!/usr/bin/env bash
# ★ §1f — THE RECEIPT MUST SAY WHAT THE LOG SAYS.
#
# `loadcase_receipt_json` is file-static inside run_job.cpp, so there is no unit
# test seam for it — and the echo it reads from is a HAND-COPIED SUBSET of the
# setup, whose own comment warns that every new field has to be added twice. I
# added `anchor_pad_report` to the setup and missed the echo, and the receipt
# then said `applied: false, voxels_frozen: 0` while the log said 32,648 on the
# maintainer's own job. A value-type test would not have caught that; only
# reading the SHIPPED artifact does.
#
# So this is the guard: run the CLI, and require the receipt's anchor_pad to
# agree with the [loadcase] anchor-pad line, field for field.
#
#   ./r1f_receipt_matches_log.sh <cli> <out-dir>
set -euo pipefail

CLI="${1:?usage: r1f_receipt_matches_log.sh <cli> <out-dir>}"
OUT="${2:?}"
DEMO="${DEMO_DIR:?set DEMO_DIR to core/tests/fixtures/demo}"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"
cat > "$OUT/job.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 24,
  "simp": {"max_iterations": 6},
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "v"},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [{"face_id": 5, "depth_mm": 3.0}]
  }
}
JSON

"$CLI" run "$OUT/job.json" --out "$OUT/out" --no-iteration-csv > "$OUT/run.log" 2>&1 || true

LOG_LINE=$(grep -m1 "anchor-pad" "$OUT/run.log" || true)
echo "log:     ${LOG_LINE:-<none>}"

if [ ! -f "$OUT/out/loadcase.json" ]; then
  echo "FAIL — no loadcase.json was written"; exit 1
fi

python3 - "$OUT/out/loadcase.json" "${LOG_LINE:-}" <<'PY'
import json, re, sys
receipt = json.load(open(sys.argv[1]))
line = sys.argv[2]
ap = receipt.get("anchor_pad")
if ap is None:
    print("FAIL — the receipt carries no anchor_pad block at all"); sys.exit(1)
print("receipt:", json.dumps({k: v for k, v in ap.items() if k != "note"}))

def num(key):
    m = re.search(key + r"=(\d+)", line)
    return int(m.group(1)) if m else None

fails = []
if line:
    for logkey, jsonkey in [("depth", "depth_voxels"), ("anchor_faces", "anchor_faces"),
                            ("load_faces", "load_faces"), ("voxels_frozen", "voxels_frozen")]:
        want, got = num(logkey), ap.get(jsonkey)
        if want is not None and want != got:
            fails.append(f"{jsonkey}: log says {want}, receipt says {got}")
    if not ap.get("applied"):
        fails.append("the log emitted an anchor-pad line but the receipt says applied=false")
else:
    # No pad on this configuration — then the receipt must say so, not lie.
    if ap.get("applied"):
        fails.append("no anchor-pad line was logged but the receipt says applied=true")

# The user's declaration must be EXACTLY what was declared: face 5, nothing else.
prot = receipt.get("face_protections") or []
ids = sorted(p.get("face_id") for p in prot)
if ids != [5]:
    fails.append(f"face_protections should be exactly [5], got {ids}")
if prot and abs((prot[0].get("depth_requested_mm") or 0) - 3.0) > 1e-9:
    fails.append("the per-face depth did not reach the receipt")

for f in fails:
    print("FAIL —", f)
print("PASS — the receipt says what the log says" if not fails else "FAILED")
sys.exit(1 if fails else 0)
PY
