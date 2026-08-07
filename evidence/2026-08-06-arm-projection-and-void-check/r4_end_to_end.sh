#!/usr/bin/env bash
# R4 — DEMONSTRABLY USABLE, NOT MERELY COMPILING.
# task 2026-08-06-arm-projection-and-void-check
#
#   ./r4_end_to_end.sh <cli> <work-dir>
#
# THE WHOLE PATH, FOR BOTH OPTIONS AND BOTH DIRECTIONS:
#
#   the user's control  ->  the app's REAL serializer (RemoteRun.buildJobJSON)
#                       ->  the bytes on disk
#                       ->  the real topopt-cli
#                       ->  an effect visible in the result
#
# ★ THE APP'S BYTES ARE NOT RE-AUTHORED HERE. `DefaultArmingEvidenceGen` writes
# the `output` and `lattice` blocks the app actually emits into
# app_blocks_<tag>.json, and this script splices THOSE blocks into a runnable
# l-bracket load case. The rest of the document (model, gravity, ladder) is the
# committed demo job, because the app's own job names /tmp/l-bracket.step and
# face ids that only exist on the maintainer's part — the two blocks under test
# travel verbatim, and nothing else here is claimed to be the app's.
#
# ONE DEVIATION, STATED: the app defaults `skin` to "diagrid", and on a
# voxel-silhouette part a non-"none" finish emits no geometry and run_job refuses
# the run for THAT reason (the lattice-cell-fit-mode M4 bar, merged before this
# task). That refusal is a different rule and would abort every arm before
# either default could be observed, so `skin` is set to "none" in all four arms
# — identically, so it cannot be the source of any difference between them.
#
# "four consecutive PRs here shipped app-side defects behind green checks" is
# the reason this exists in this shape.
set -euo pipefail

CLI="$1"
W="$2"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BLOCKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rm -rf "$W"; mkdir -p "$W"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$W/"

for tag in both_on cad_off void_off both_off; do
  python3 - "$BLOCKS/app_blocks_$tag.json" "$W/job_$tag.json" <<'PY'
import json, sys
blocks = json.load(open(sys.argv[1]))
job = {
  "model": "l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
  "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
  "ladder": [0.7],
  "margin_stop": 1.5,
  "simp": {"max_iterations": 30},
}
# THE APP'S OWN TWO BLOCKS, verbatim.
job["output"] = dict(blocks["output"])
job["lattice"] = dict(blocks["lattice"])
# The one stated deviation (see the header).
job["lattice"]["skin"] = "none"
json.dump(job, open(sys.argv[2], "w"), indent=1)
PY
done

echo "=== the keys the APP put in each job (read back off disk) ============="
for tag in both_on cad_off void_off both_off; do
  printf '%-10s ' "$tag"
  python3 -c "
import json,sys
j=json.load(open('$W/job_$tag.json'))
print('output.project_cad_faces =', j['output'].get('project_cad_faces'),
      '  lattice.require_lattice_void_reaches_exterior =',
      j['lattice'].get('require_lattice_void_reaches_exterior'))"
done
echo

echo "=== running each through the REAL cli ================================"
for tag in both_on cad_off void_off both_off; do
  ( cd "$W" && "$CLI" run "job_$tag.json" --out "out_$tag" > "$tag.log" 2>&1 ) \
    && echo "  $tag: exit 0" || echo "  $tag: exit $?"
done
echo

echo "=== THE EFFECT, read out of the RESULT ==============================="
python3 - "$W" <<'PY'
import json, os, struct, sys, collections
W = sys.argv[1]

def stl_volume(p):
    d = open(p, "rb").read()
    n = struct.unpack("<I", d[80:84])[0]
    vol = 0.0; off = 84
    for _ in range(n):
        v = struct.unpack_from("<12f", d, off); off += 50
        a, b, c = v[3:6], v[6:9], v[9:12]
        vol += (a[0]*(b[1]*c[2]-b[2]*c[1]) - a[1]*(b[0]*c[2]-b[2]*c[0])
                + a[2]*(b[0]*c[1]-b[1]*c[0]))/6.0
    return abs(vol), n

print(f"{'arm':<10}{'exported mm^3':>15}{'tris':>8}{'void_escape in run_info':>26}"
      f"{'sealed':>8}")
print("-" * 67)
base = None
for tag in ("both_on", "cad_off", "void_off", "both_off"):
    d = os.path.join(W, f"out_{tag}")
    mesh = os.path.join(d, "variant_070.stl")
    ri = os.path.join(d, "run_info.json")
    if not os.path.exists(mesh):
        print(f"{tag:<10}  (no mesh — see {tag}.log)"); continue
    vol, tris = stl_volume(mesh)
    ve = None
    if os.path.exists(ri):
        ve = (json.load(open(ri)).get("lattice_export") or {}).get("void_escape")
    print(f"{tag:<10}{vol:>15.1f}{tris:>8}"
          f"{('yes' if ve else 'NO'):>26}"
          f"{str(ve.get('sealed')) if ve else '—':>8}")

print()
print("WHAT TO READ:")
print("  * `project_cad_faces` ON vs OFF must change the EXPORTED VOLUME. That")
print("    is the effect being visible in the result rather than in a log line.")
print("  * `require_lattice_void_reaches_exterior` ON vs OFF must change whether")
print("    run_info carries a `void_escape` record at all. PR 305's bar V5 is")
print("    that OFF means not one extra byte, and it still holds.")
print("  * The two must move INDEPENDENTLY across the four arms, or they are")
print("    one switch wearing two names.")
PY
