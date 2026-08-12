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

run() {  # run <cli> <job> <subdir>
  local cli="$1" job="$2" sub="$3"
  rm -rf "$OUT/$sub"
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 ) || {
    echo "RUN FAILED ($sub) — tail of log:"; tail -20 "$OUT/$sub.log"; exit 1; }
  ( cd "$OUT/$sub" && find . -type f ! -name '*.log' | sort \
      | xargs shasum -a 256 ) > "$OUT/$sub.sha256"
}

echo "=== R1 — no regions: BASE cli vs BRANCH cli ==="
echo "base   $BASE_CLI"
echo "branch $BRANCH_CLI"
run "$BASE_CLI"   job_faces.json base_faces
run "$BRANCH_CLI" job_faces.json branch_faces
if diff -u "$OUT/base_faces.sha256" "$OUT/branch_faces.sha256"; then
  echo "R1 PASS — every artifact byte-identical ($(wc -l < "$OUT/base_faces.sha256") files)"
else
  echo "R1 FAIL"; exit 1
fi

echo
echo "=== R2 — face_ids vs an equivalent identity REGION, same (branch) cli ==="
run "$BRANCH_CLI" job_regions.json branch_regions
# The two sha256 listings name the same files; compare the hash column only.
if diff -u "$OUT/branch_faces.sha256" "$OUT/branch_regions.sha256"; then
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
if ( cd "$OUT" && "$BRANCH_CLI" run job_sliver.json --out sliver > sliver.log 2>&1 ); then
  echo "R5 FAIL — a sub-region under the floor was ACCEPTED"; exit 1
else
  echo "R5 PASS — refused. The message:"
  grep -i "under the floor" "$OUT/sliver.log" || tail -5 "$OUT/sliver.log"
fi
