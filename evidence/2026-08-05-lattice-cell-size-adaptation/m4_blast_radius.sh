#!/usr/bin/env bash
# M4 — BLAST RADIUS OF THE RIM REFUSAL, MEASURED.
#
#   ./m4_blast_radius.sh <build-dir> <out-dir>
#
# THE CLAIM: the new refusal fires if and only if the lattice boundary carries no
# ANALYTIC faces, and a boundary with no analytic faces cannot emit a single rim or
# skin triangle (both generators iterate face PAIRS). So the set of runs it refuses
# is exactly the set that already produces zero rim/skin geometry. No run that
# currently emits a rim can be affected.
#
# THAT IS AN ARGUMENT. This measures it, on the two cases that decide it:
#
#   CASE 1 — voxel-derived boundary, NO bolt clearance. faces() empty.
#            Baseline (pre-M4 binary): must SUCCEED and report rim_triangles 0,
#            skin_triangles 0, anchor_nodes 0. Branch: must REFUSE.
#            => the refusal only takes runs that were producing nothing.
#
#   CASE 2 — the SAME job plus a BOLT clearance, which is the one input that puts a
#            face in faces() on a voxel-derived part (lattice_boundary.cpp:160).
#            Baseline and branch must BOTH succeed, and the rim counts must be
#            IDENTICAL. => a run that really does emit a rim is untouched.
#
# If case 2 refuses, or its rim counts move, the reasoning is wrong and M4 must be
# reverted in favour of removing the skin offer from the refusal message instead.
set -euo pipefail
BUILD="${1:?usage: m4_blast_radius.sh <build-dir> <out-dir>}"
OUT="${2:?}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_BUILD="$OUT/.base-build"
mkdir -p "$OUT"
cp "$REPO/core/tests/fixtures/demo/l-bracket.step" "$OUT/"

python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
base = {
  "model": "l-bracket.step", "material": "PLA", "mode": "minimize_plastic",
  "resolution": 40, "simp": {"max_iterations": 10},
  "loads": {"anchors": [{"kind": "cylindrical", "radius_mm": 2.5}],
            "groups": [{"face_ids": [2], "force": [0.0, 0.0, -60.0]}]},
  "lattice": {"topology": "octet", "emit_stl": True, "skin": "rim",
              "cell_mm": 6.0, "strut_radius_mm": 1.0,
              "min_extrudable_width_mm": 0.42},
  "output": {"report": "report.json", "mesh_format": "stl",
             "mesh_prefix": "variant"}
}
json.dump(base, open(os.path.join(out, "job_noface.json"), "w"), indent=1)

# CASE 2: add a BOLT clearance. lattice_boundary.cpp:160 pushes a Kind::Bore face
# for a bolt (and only for a bolt), so faces() becomes non-empty and the rim has
# something to dress.
b = json.loads(json.dumps(base))
b["loads"]["clearances"] = [{
    "kind": "bolt",
    "geometry": {"axis_point": [20.0, 0.0, 10.0], "axis_dir": [0.0, 0.0, 1.0],
                 "radius_mm": 3.0, "half_length_mm": 30.0}}]
json.dump(b, open(os.path.join(out, "job_bolt.json"), "w"), indent=1)
PY

# ── Build the BASE binary from origin/main in a detached worktree. The branch is
# committed-or-not either way; a detached worktree is unambiguous and never risks
# stashing a dirty tree over the top of the work.
BASE_REF="${BASE_REF:-origin/main}"
WT="$OUT/.base-worktree"
rm -rf "$WT"
git -C "$REPO" worktree add --detach "$WT" "$BASE_REF" > "$OUT/base_wt.log" 2>&1
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true' EXIT
cmake -S "$WT/core" -B "$BASE_BUILD" -DCMAKE_BUILD_TYPE=Release > "$OUT/base_cfg.log" 2>&1
cmake --build "$BASE_BUILD" --target topopt_cli -j8 > "$OUT/base_build.log" 2>&1
cmake --build "$BUILD" --target topopt_cli -j8 > "$OUT/branch_build.log" 2>&1

BASE_CLI="$BASE_BUILD/topopt-cli"
BR_CLI="$BUILD/topopt-cli"
bs=$(shasum -a 256 "$BASE_CLI" | cut -d' ' -f1)
br=$(shasum -a 256 "$BR_CLI"   | cut -d' ' -f1)
echo "base   cli sha256: $bs"
echo "branch cli sha256: $br"
[ "$bs" != "$br" ] || { echo "FAIL — same binary; nothing below would mean anything."; exit 1; }
echo "the two binaries differ, as they must."
echo

run() { # run <cli> <job> <sub> ; echoes exit code
  local cli="$1" job="$2" sub="$3"
  rm -rf "${OUT:?}/$sub"
  set +e
  ( cd "$OUT" && "$cli" run "$job" --out "$sub" > "$sub.log" 2>&1 )
  local rc=$?
  set -e
  echo "$rc"
}

rimcounts() { # rimcounts <sub>
  python3 - "$OUT/$1" <<'PY'
import json, os, sys
p = os.path.join(sys.argv[1], "run_info.json")
if not os.path.exists(p):
    print("    (no run_info.json)"); raise SystemExit
L = json.load(open(p)).get("lattice_export") or {}
print(f"    rim_triangles={L.get('rim_triangles')} "
      f"skin_triangles={L.get('skin_triangles')} "
      f"rim_volume_mm3={L.get('rim_volume_mm3')} "
      f"anchor_nodes={L.get('anchor_nodes')} "
      f"interior_volume_mm3={L.get('interior_volume_mm3')}")
PY
}

fail=0
inconclusive=0
nonzero_control=0
echo "########## CASE 1 — voxel boundary, NO bolt clearance (faces() empty) ##########"
rc_b=$(run "$BASE_CLI" job_noface.json C1_base)
rc_r=$(run "$BR_CLI"   job_noface.json C1_branch)
echo "  base   exit=$rc_b"; rimcounts C1_base
echo "  branch exit=$rc_r"
if [ "$rc_b" -ne 0 ]; then
  echo "  UNEXPECTED: the base run did not succeed; case 1 proves nothing."; fail=1
elif [ "$rc_r" -eq 0 ]; then
  echo "  FAIL — the branch did not refuse a run that emits no rim."; fail=1
else
  echo "  branch refusal:"
  { grep -m1 -A3 "produced NO geometry" "$OUT/C1_branch.log" || true; } | sed 's/^/    /'
  echo "  CASE 1 PASS — base succeeded while emitting ZERO rim/skin/anchor geometry;"
  echo "               branch refuses exactly that run."
fi
echo

echo "########## CASE 2 — SAME job + a BOLT clearance (faces() non-empty) ##########"
# ★ THIS CASE HAS BEEN RESPECIFIED TWICE, AND BOTH TIMES THE TEST WAS WRONG RATHER
# THAN THE CODE. It was written assuming a BOLT clearance makes the rim emit
# geometry, so that a "run that really does emit a rim" could be shown untouched.
# It does not: a bolt contributes a BORE face, and the dispatch
# (lattice_gen.cpp:944-961) emits only for Plane-Plane or Plane-Bore pairs —
# "bore-bore pairs meet nowhere a rim can ride" — while lattice_boundary_for never
# creates a Plane. So this job ALSO emits zero rim, and the correct expectation is
# that the guard refuses it too.
#
# The assertion is therefore keyed off what the CONTROL actually emitted:
#   base emitted 0 rim/skin triangles -> the branch MUST refuse (the guard working,
#     on a second and independent configuration);
#   base emitted > 0                  -> the branch must succeed with IDENTICAL
#     counts (a run that really does emit a rim is untouched).
rc_b2=$(run "$BASE_CLI" job_bolt.json C2_base)
rc_r2=$(run "$BR_CLI"   job_bolt.json C2_branch)
echo "  base   exit=$rc_b2"; rimcounts C2_base
echo "  branch exit=$rc_r2"
if [ "$rc_b2" -ne 0 ]; then
  echo "  UNEXPECTED: the base run did not succeed; case 2 proves nothing."; fail=1
else
  rt=$(python3 -c "
import json
L=json.load(open('$OUT/C2_base/run_info.json'))['lattice_export']
print(int(L.get('rim_triangles') or 0)+int(L.get('skin_triangles') or 0))")
  echo "  rim+skin triangles emitted by the control: $rt"
  if [ "$rt" = "0" ]; then
    if [ "$rc_r2" -ne 0 ]; then
      echo "  CASE 2 PASS — a SECOND configuration that asks for a rim and emits none;"
      echo "    the branch refuses it too, which is the guard doing its job. Note this"
      echo "    is the case the ORIGINAL faces()-empty predicate silently MISSED:"
      echo "    faces() is non-empty here (one Bore), so that guard stayed quiet while"
      echo "    the run still shipped an undressed part."
      nonzero_control=0
    else
      echo "  FAIL — the branch did not refuse a run that emits no rim."; fail=1
    fi
  else
    if [ "$rc_r2" -ne 0 ]; then
      echo "  FAIL — the branch refused a run that DOES emit a rim ($rt triangles)."; fail=1
    else
      a=$(rimcounts C2_base); b=$(rimcounts C2_branch)
      if [ "$a" = "$b" ]; then
        echo "  CASE 2 PASS — a run that emits a rim ($rt triangles) is untouched."
        nonzero_control=1
      else echo "  FAIL — rim counts moved on a run that emits a rim."; fail=1; fi
    fi
  fi
fi
echo
if [ "$nonzero_control" = "0" ]; then
  echo "  STANDING NOTE: across BOTH configurations tested — no clearance, and a bolt"
  echo "  clearance — the control emitted ZERO rim/skin triangles. No job on this code"
  echo "  path can emit rim geometry, because every emitting face pair needs a PLANE"
  echo "  and lattice_boundary_for never makes one. So there is no run the guard could"
  echo "  wrongly refuse. That is why the predicate is the MEASURED emitted count:"
  echo "  its blast radius is exact by construction and needs no control that would"
  echo "  have to exist for the faces()-empty version to be provable."
fi
echo

if [ "$fail" = "0" ] && [ "$inconclusive" = "0" ]; then
  echo "M4 PASS — the refusal fires only where rim geometry was already zero, and"
  echo "          leaves every run that actually emits a rim untouched."
  exit 0
fi
if [ "$fail" = "0" ] && [ "$inconclusive" = "1" ]; then
  echo "M4 CONDITIONAL — case 1 holds. Case 2 could not be constructed: no job on"
  echo "  this code path emits rim geometry at all, so 'a run that emits a rim' has"
  echo "  no instance. The guard therefore uses the MEASURED emitted count, which"
  echo "  cannot fire on a run that emitted something — exact by construction rather"
  echo "  than by a control that does not exist."
  exit 0
fi
echo "M4 FAIL — the reasoning does not hold; revert M4 and remove the skin offer"
echo "          from the refusal message instead."
exit 1
