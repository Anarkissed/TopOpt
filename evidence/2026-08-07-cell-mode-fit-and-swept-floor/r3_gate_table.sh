#!/usr/bin/env bash
# R3 — THE FULL GATE TABLE FOR THE SWEPT CHANGE (S1).
#
#   BASE_REF=<commit> ./r3_gate_table.sh <branch-build-dir> <out-dir>
#
# Every rung, its verdict and its margin, base vs branch, plus a VOXEL-CLASSIFICATION
# flip count against a 1e-9 negative-control floor.
#
# WHAT "FLIP" MEANS HERE. design.bin is the float64 density field. A voxel's
# CLASSIFICATION is `density > 0.5`. A flip is a voxel whose classification differs
# between the two binaries. The 1e-9 floor is a NEGATIVE CONTROL, not a tolerance: the
# same field is also compared with a 1e-9 threshold shift, and if a 1e-9 nudge produces
# flips the instrument is measuring noise and the count above means nothing.
#
# THE POINT OF THE BAR: a swept job that previously REFUSED and now RUNS is the
# intended change and is enumerated as such. A flip on a job that already ran is a
# blocked-stop, and case M below is the one place S1 could have caused one — measured,
# and DISARMED for that reason (see multiscale_floor_cell_mm's ★★ note in run_job.cpp).
set -euo pipefail
BUILD="$(cd "${1:?usage: r3_gate_table.sh <build-dir> <out-dir>}" && pwd)"
mkdir -p "${2:?}"
OUT="$(cd "$2" && pwd)"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_REF="${BASE_REF:-origin/main}"
BASE_BUILD="$OUT/.base-build"
MATS="$REPO/core/src/materials/materials.json"
RULES="$REPO/core/src/settings/rules.json"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
W = 0.20   # light floor 2.1917 mm, frontier 0.5214 mm
base = {"model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
        "resolution": 24,
        "fixture_faces": [{"kind": "cylindrical", "radius_mm": 2.5}],
        "gravity": {"direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0},
        # THREE RUNGS, so "every rung" is a real table and not one row.
        "ladder": [0.7, 0.55, 0.4], "margin_stop": 0.0,
        "simp": {"max_iterations": 12},
        "output": {"report": "report.json", "mesh_format": "stl",
                   "mesh_prefix": "variant"}}

def slab(depth):
    return [{"role": "include", "kind": "face",
             "geometry": {"origin": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0],
                          "half_u_mm": 300.0, "half_w_mm": 300.0,
                          "depth_mm": depth}}]

def swept(lo, hi, regions=None, multiscale=False):
    j = json.loads(json.dumps(base))
    lat = {"topology": "octet", "emit_stl": True, "skin": "none",
           "min_extrudable_width_mm": W}
    if regions is not None: lat["regions"] = regions
    if multiscale: lat["multiscale"] = True
    j["lattice"] = lat
    j["grading"] = {"topology": "octet", "min_extrudable_width_mm": W,
                    "cell_mode": "swept", "cell_min_mm": lo, "cell_max_mm": hi}
    return j

cases = {
  # tag                        job
  "S_above_noregion":  swept(2.5, 10.0),
  "S_above_region":    swept(2.5, 10.0, regions=slab(30.0)),
  "S_between_noregion":swept(0.6, 4.8),
  "S_between_thin":    swept(0.6, 4.8, regions=slab(1.5)),
  "S_between_thick":   swept(0.6, 4.8, regions=slab(30.0)),
  "S_underfrontier":   swept(0.3, 0.45, regions=slab(1.5)),
  "M_multiscale":      swept(0.6, 4.8, multiscale=True),
}
for tag, j in cases.items():
    json.dump(j, open(os.path.join(out, "job_%s.json" % tag), "w"), indent=1)
json.dump(sorted(cases), open(os.path.join(out, "cases.json"), "w"))
PY

WT="$OUT/.base-worktree"
rm -rf "$WT"
git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_wt.log" 2>&1
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cmake -S "$WT/core" -B "$BASE_BUILD" -DCMAKE_BUILD_TYPE=Release > "$OUT/base_cfg.log" 2>&1
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1
cmake --build "$BUILD"      --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1

BASE_CLI="$BASE_BUILD/topopt-cli"
BR_CLI="$BUILD/topopt-cli"
bs=$(shasum -a 256 "$BASE_CLI" | cut -d' ' -f1)
br=$(shasum -a 256 "$BR_CLI"   | cut -d' ' -f1)
echo "base commit : $(git -C "$REPO" rev-parse "$BASE_REF")"
echo "base   cli  : ${bs:0:16}…"
echo "branch cli  : ${br:0:16}…"
[ "$bs" != "$br" ] || { echo "R3 INVALID — the two CLIs are THE SAME BINARY."; exit 1; }
echo

for tag in $(python3 -c "import json;print(' '.join(json.load(open('$OUT/cases.json'))))"); do
  for side in base branch; do
    cli=$BASE_CLI; [ "$side" = branch ] && cli=$BR_CLI
    rm -rf "$OUT/${side}_$tag"
    set +e
    ( cd "$OUT" && "$cli" run "job_$tag.json" --out "${side}_$tag" \
        --materials "$MATS" --rules "$RULES" > "${side}_$tag.log" 2>&1 )
    echo $? > "$OUT/${side}_$tag.rc"
    set -e
  done
done

python3 - "$OUT" <<'PY'
import json, os, struct, sys
out = sys.argv[1]
tags = json.load(open(os.path.join(out, "cases.json")))

def rc(side, tag):
    p = os.path.join(out, "%s_%s.rc" % (side, tag))
    return int(open(p).read().strip()) if os.path.exists(p) else -1

def rungs(side, tag):
    p = os.path.join(out, "%s_%s" % (side, tag), "report.json")
    if not os.path.exists(p): return []
    d = json.load(open(p))
    vs = d.get("variants") or d.get("results") or []
    rows = []
    for v in vs:
        rows.append((v.get("requested_volume_fraction", v.get("volume_fraction")),
                     v.get("accepted", v.get("verdict")),
                     v.get("margin", v.get("margin_effective"))))
    return rows

def field(side, tag):
    p = os.path.join(out, "%s_%s" % (side, tag), "design.bin")
    if not os.path.exists(p): return None
    raw = open(p, "rb").read()
    n = len(raw) // 8
    return struct.unpack("<%dd" % n, raw[:8*n])

print("=" * 78)
print("R3 GATE TABLE — swept jobs, base (origin/main) vs branch")
print("=" * 78)
newly = []
for tag in tags:
    rb, rr = rc("base", tag), rc("branch", tag)
    print("\n--- %s   base exit=%d  branch exit=%d" % (tag, rb, rr))
    if rb != 0 and rr == 0:
        newly.append(tag)
        print("    ★ PREVIOUSLY REFUSED, NOW RUNS — this is the POINT of S1.")
        for line in open(os.path.join(out, "base_%s.log" % tag)):
            if "topopt-cli:" in line:
                print("      base refusal: " + line.strip()[:150]); break
    if rb != 0 and rr != 0:
        print("    both sides refused (unchanged).")
    if rb == 0 and rr != 0:
        print("    ★★ BLOCKED-STOP: branch REFUSES a job base ran.")
    print("    %-6s %-12s %-10s | %-12s %-10s" %
          ("rung", "base verdict", "base margin", "branch verdict", "branch margin"))
    rbv, rrv = rungs("base", tag), rungs("branch", tag)
    for i in range(max(len(rbv), len(rrv))):
        b = rbv[i] if i < len(rbv) else (None, None, None)
        r = rrv[i] if i < len(rrv) else (None, None, None)
        print("    %-6s %-12s %-10s | %-12s %-10s" %
              (b[0] if b[0] is not None else r[0], b[1], b[2], r[1], r[2]))
    fb, fr = field("base", tag), field("branch", tag)
    if fb is None or fr is None:
        print("    voxel flips: n/a (one side produced no design.bin)")
        continue
    if len(fb) != len(fr):
        print("    voxel flips: GRID SIZE DIFFERS (%d vs %d)" % (len(fb), len(fr)))
        continue
    flips = sum(1 for x, y in zip(fb, fr) if (x > 0.5) != (y > 0.5))
    # NEGATIVE CONTROL — the same field against ITSELF with the classification
    # threshold nudged by 1e-9. Any count here means the instrument is reading noise
    # and the number above is not a measurement.
    nc = sum(1 for x in fb if (x > 0.5) != (x > 0.5 + 1e-9))
    print("    voxel flips: %d of %d   (negative control at 1e-9: %d)" %
          (flips, len(fb), nc))
    if nc:
        print("    ★ the negative control is NON-ZERO — this instrument is reading noise.")

print("\n" + "=" * 78)
print("Jobs that previously refused and now run: %s" %
      (", ".join(newly) if newly else "(none)"))
print("=" * 78)
PY
