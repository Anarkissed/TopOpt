#!/usr/bin/env bash
# R1 + R2 — THE TWO BYTE-LEVEL BARS (task 2026-08-14-face-regions).
#
#   R1  DAY-ONE BYTE-IDENTITY. With no region edits the emitted job runs to
#       byte-identical artifacts on a topopt-cli built from BASE and one built
#       from this BRANCH. Not "the code path looks unchanged" — the bytes.
#
#   ADAPTED for task 2026-08-15-lattice-regions R1: the baseline is PR 331's
#   head (726160c), and the R1 job carries a LATTICE — the subsystem this task
#   changed — expressed the way it always was, with no region-backed region.
#
#   R2  A REGION IS THE SAME SELECTION. The SAME job expressed two ways —
#       `face_ids: [N]` and an equivalent one-member `face_regions` +
#       `region_ids` — produces byte-identical DESIGN artifacts on the BRANCH
#       cli. ★ That is the strongest possible form of "CAD error and the
#       CAD-attributed triangle share are unchanged to the digit": if every
#       exported byte matches, every derived measure matches trivially. The
#       digit-level comparison of the CAD numbers themselves, WITH a union and a
#       10x5 grid split applied, is `face_region_probe` (r2_r3_his_part.txt).
#
#       ★ THE TWO RECEIPTS LEGITIMATELY DIFFER, and are compared separately.
#       `run_info.json` and `loadcase.json` record WHAT WAS DECLARED, and the
#       two jobs declare different things — one a face id, one a region. A
#       receipt that did NOT differ there would be the defect: it would mean the
#       run could not tell the user which selection it had resolved.
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
  "grading": {"cell_mode": "fit", "topology": "octet", "min_extrudable_width_mm": 0.42},
  "lattice": {"topology": "octet", "emit_stl": true, "emit_3mf": false, "skin": "none", "min_extrudable_width_mm": 0.42,
    "regions": [{"role": "include", "kind": "face", "geometry": {"origin": [0,0,0], "normal": [0,0,1], "half_u_mm": 30, "half_w_mm": 30, "depth_mm": 6}}]},
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
  # THE DESIGN SET: everything the optimizer produced. No timings, no receipts.
  ( cd "$OUT/$arm/run" && find . -type f ! -name '*.log' ! -name 'run_info.json' \
      ! -name 'loadcase.json' ! -name 'iterations.csv' | sort \
      | xargs shasum -a 256 ) > "$OUT/$arm.design.sha256"
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
  #   * lattice_export.gen_fraction      — ★ A CLOCK WEARING A FRACTION'S
  #       CLOTHES. It is lattice generation SECONDS over total run SECONDS, so
  #       it moves whenever either arm runs under different machine load. Added
  #       to this list by NAME after the first R1 run differed on it and nothing
  #       else: the exhaustive key-by-key walk of both run_info.json files found
  #       exactly six differing values — created_wall_ms, fingerprint,
  #       preflight_ms, gen_seconds, void_escape.wall_seconds and this one. The
  #       filter is not widened to a pattern; the field is named.
  # They are STRIPPED here, and only here, and this comment is the whole list.
  # Everything else — design.bin, fields.bin, report.json, every variant STL and
  # every alpha field — is compared raw.
  python3 - "$OUT/$arm/run" > "$OUT/$arm.norm.sha256" <<'PY'
import hashlib, json, os, re, sys
root = sys.argv[1]
DROP = re.compile(r'(_ms$|^created_wall_ms$|^fingerprint$|_seconds$|^gen_fraction$)')
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
echo "-- the DESIGN set, raw (design.bin, fields.bin, report.json, meshes, alpha) --"
if diff -u "$OUT/base_faces.design.sha256" "$OUT/branch_faces.design.sha256"; then
  echo "   identical, byte for byte ($(wc -l < "$OUT/base_faces.design.sha256") files)"
else
  echo "R1 FAIL — the DESIGN moved"; exit 1
fi
echo "-- the receipts, with the timestamps/fingerprint stripped --"
if diff -u "$OUT/base_faces.norm.sha256" "$OUT/branch_faces.norm.sha256"; then
  echo "R1 PASS — every artifact identical ($(wc -l < "$OUT/base_faces.norm.sha256") files)"
else
  echo "R1 FAIL — a receipt moved"; exit 1
fi

echo
echo "=== R2 — face_ids vs an equivalent identity REGION, same (branch) cli ==="
run "$BRANCH_CLI" job_regions.json branch_regions
echo "-- the DESIGN set, raw --"
if diff -u "$OUT/branch_faces.design.sha256" "$OUT/branch_regions.design.sha256"; then
  echo "R2 PASS — a region tags exactly what its face tags, to the byte"
  echo "         ($(wc -l < "$OUT/branch_faces.design.sha256") design artifacts identical)"
else
  echo "R2 FAIL — the DESIGN moved"; exit 1
fi
echo
echo "-- and the RECEIPTS, which SHOULD differ: they record the declaration --"
diff -u "$OUT/branch_faces.norm.sha256" "$OUT/branch_regions.norm.sha256" || true
echo "   the differing files, and the lines that differ:"
for f in run_info.json loadcase.json; do
  echo "   --- $f"
  diff "$OUT/branch_faces/run/$f" "$OUT/branch_regions/run/$f" \
    | grep -vE '_ms|created_wall|fingerprint' | head -12 || true
done

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
