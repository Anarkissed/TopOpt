#!/usr/bin/env bash
# R1 + R2 — THE TWO BYTE-LEVEL BARS (task 2026-08-14-face-regions).
#
#   R1  DAY-ONE BYTE-IDENTITY. With no region edits the emitted job runs to
#       byte-identical artifacts on a topopt-cli built from BASE and one built
#       from this BRANCH. Not "the code path looks unchanged" — the bytes.
#
#   R2  A REGION IS THE SAME SELECTION. The SAME job expressed two ways —
#       `face_ids: [N]` and an equivalent one-member `face_regions` +
#       `region_ids` — produces byte-identical artifacts on the BRANCH cli.
#       ★ That is the strongest possible form of "CAD error and the
#       CAD-attributed triangle share are unchanged to the digit": if every
#       exported byte matches, every derived measure matches trivially. The
#       digit-level comparison of the CAD numbers themselves, WITH a union and a
#       10x5 grid split applied, is `face_region_probe` (r2_r3_his_part.txt).
#
#   usage: ./r1_r2_byte_identity.sh <base-cli> <branch-cli> <out-dir>
set -euo pipefail

BASE_CLI="${1:?usage: r1_r2_byte_identity.sh <base-cli> <branch-cli> <out-dir>}"
BRANCH_CLI="${2:?}"
OUT="${3:?}"
DEMO="${DEMO_DIR:?set DEMO_DIR to core/tests/fixtures/demo}"

mkdir -p "$OUT"
cp "$DEMO/l-bracket.step" "$OUT/"

# The R1 job: a declared load case with a protection, and NO regions at all.
cat > "$OUT/job_faces.json" <<'JSON'
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
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON

# The R2 job: IDENTICAL physics, expressed through the region layer. Face 2
# becomes a one-member region with no cuts — an IDENTITY region, which core
# asserts tags exactly what its face tags (test_face_region.cpp).
cat > "$OUT/job_regions.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 32,
  "simp": {"max_iterations": 12},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "face_regions": [{"id": 100, "name": "load wall", "add": [2]}],
    "groups": [{"region_ids": [100], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [5],
    "face_protection_depth_mm": 3.0
  },
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON

# EVERY ARM WRITES TO A DIRECTORY CALLED `run`, inside its own parent. The
# `_alpha.meta` sidecar quotes its own output path in a comment line, so two arms
# writing to differently-named directories differ in a byte that has nothing to
# do with the design. Same name, different parent: the paths differ, the bytes
# do not.
run() {  # run <cli> <job> <arm>
  local cli="$1" job="$2" arm="$3"
  rm -rf "${OUT:?}/$arm"
  mkdir -p "$OUT/$arm"
  cp "$OUT/l-bracket.step" "$OUT/$job" "$OUT/$arm/"
  ( cd "$OUT/$arm" && "$cli" run "$job" --out run > "$arm.log" 2>&1 ) || {
    echo "RUN FAILED ($arm) — tail of log:"; tail -20 "$OUT/$arm/$arm.log"; exit 1; }
  ( cd "$OUT/$arm/run" && find . -type f ! -name '*.log' | sort \
      | xargs shasum -a 256 ) > "$OUT/$arm.sha256"

  # ── THE THREE FIELDS A RUN CANNOT REPRODUCE, NAMED ─────────────────────────
  # A receipt cannot hold a wall clock. Three values in these artifacts are
  # properties of WHEN and WHERE the binary ran, not of what it computed:
  #   * run_info.json  created_wall_ms   — a timestamp
  #   * run_info.json  fingerprint       — the build's git sha (the base cli is
  #                                        built from a tarball and reports "dev")
  #   * run_info.json  preflight_ms and every *_ms timing
  #   * iterations.csv column 3          — a per-iteration wall-clock stamp
  # They are STRIPPED here, and only here, and this comment is the whole list.
  # Everything else — design.bin, fields.bin, report.json, every variant STL and
  # every alpha field — is compared raw.
  python3 - "$OUT/$arm/run" > "$OUT/$arm.norm.sha256" <<'PY'
import hashlib, json, os, re, sys
root = sys.argv[1]
DROP = re.compile(r'(_ms$|^created_wall_ms$|^fingerprint$|_seconds$)')
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not DROP.search(k)}
    if isinstance(o, list):
        return [strip(v) for v in o]
    return o
for f in sorted(os.listdir(root)):
    p = os.path.join(root, f)
    if not os.path.isfile(p) or f.endswith('.log'):
        continue
    if f == 'run_info.json':
        b = json.dumps(strip(json.load(open(p))), sort_keys=True).encode()
    elif f == 'iterations.csv':
        rows = []
        for i, line in enumerate(open(p)):
            c = line.rstrip('\n').split(',')
            if i > 0 and len(c) > 2:
                c[2] = 'T'          # the wall-clock stamp
            rows.append(','.join(c))
        b = '\n'.join(rows).encode()
    else:
        b = open(p, 'rb').read()
    print(hashlib.sha256(b).hexdigest(), ' ./' + f)
PY
}

echo "=== R1 — no regions: BASE cli vs BRANCH cli ==="
echo "base   $BASE_CLI"
echo "branch $BRANCH_CLI"
run "$BASE_CLI"   job_faces.json base_faces
run "$BRANCH_CLI" job_faces.json branch_faces
echo "-- raw comparison (a difference here is either the design or a clock) --"
diff -u "$OUT/base_faces.sha256" "$OUT/branch_faces.sha256" || true
echo "-- with the timestamps/fingerprint stripped --"
if diff -u "$OUT/base_faces.norm.sha256" "$OUT/branch_faces.norm.sha256"; then
  echo "R1 PASS — every artifact identical ($(wc -l < "$OUT/base_faces.norm.sha256") files)"
else
  echo "R1 FAIL"; exit 1
fi

echo
echo "=== R2 — face_ids vs an equivalent identity REGION, same (branch) cli ==="
run "$BRANCH_CLI" job_regions.json branch_regions
if diff -u "$OUT/branch_faces.norm.sha256" "$OUT/branch_regions.norm.sha256"; then
  echo "R2 PASS — a region tags exactly what its face tags, to the byte"
else
  echo "R2 FAIL"; exit 1
fi

echo
echo "=== R5 — the sliver guard refuses BEFORE anything runs ==="
cat > "$OUT/job_sliver.json" <<'JSON'
{
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 32,
  "simp": {"max_iterations": 4},
  "loads": {
    "anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
    "face_regions": [
      {"id": 100, "name": "wall", "add": [2]},
      {"id": 101, "name": "wall 1", "parent_id": 100, "add": [2],
       "cuts": [{"point": [0,0,0], "normal": [1,0,0]},
                {"point": [0.05,0,0], "normal": [-1,0,0], "strict": true}]}
    ],
    "groups": [{"region_ids": [100], "force": [0.0, 0.0, -60.0]}],
    "face_protections": [{"region_id": 101, "depth_mm": 3.0}]
  },
  "output": {"report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant"}
}
JSON
rm -rf "$OUT/sliver"
mkdir -p "$OUT/sliver"
cp "$OUT/l-bracket.step" "$OUT/job_sliver.json" "$OUT/sliver/"
if ( cd "$OUT/sliver" && "$BRANCH_CLI" run job_sliver.json --out run > sliver.log 2>&1 ); then
  echo "R5 FAIL — a sub-region under the floor was ACCEPTED"; exit 1
else
  echo "R5 PASS — refused. The message:"
  grep -i "under the floor" "$OUT/sliver/sliver.log" || tail -5 "$OUT/sliver/sliver.log"
fi
