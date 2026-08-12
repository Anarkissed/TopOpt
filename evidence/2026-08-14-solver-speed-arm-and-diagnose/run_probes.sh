#!/bin/sh
# THE MECHANISM PROBES — three solves each, because three solves is the whole
# question.
#
# ★ WHY SO FEW. `kMgLatchThreshold = 3`: the latch is decided by whether the
# FIRST THREE solves of a run contract, and his run's three attempts were
# IDENTICAL — 300 cycles each, the whole budget, no contraction
# (multigrid.cpp:145, and §2a's table). A posture that does not change the first
# attempt cannot change the run, because after the third the latch closes and
# every later solve takes the identical Jacobi path. So "does this posture make
# the V-cycle carry on his part?" is answered by the attempts, and the attempts
# all happen at the start.
#
# At `ITERS=1` the ladder yields ONE multigrid attempt in iterations.csv — rung
# 0, iteration 1, the same solve his run burned 300 cycles on — because the
# other two stagnations that close the latch are the rung-boundary certification
# solves, which the per-iteration CSV does not carry a row for. One attempt
# against his one attempt, same solve, same field, is the comparison. `ITERS` is
# overridable and 3 gives three rung-0 attempts if the machine can afford them.
#
# ★ AND WHY IT IS ONE AND NOT THREE HERE, said plainly: the host was running four
# other agents' TopOpt jobs throughout (host_load.txt records load averages of
# 108-122 on a 10-core box), and a 4-rung ladder per probe would not have
# finished. The reduction is in COVERAGE, not in the comparison — every probe is
# measured against a control produced the same way, at the same ITERS.
#
# ★ AND THE ONE THING THREE SOLVES CANNOT ANSWER, said here rather than in the
# handoff's small print: a posture that does NOT rescue rung 0 might still have
# rescued a developed rung. That is the `rearm` arm's job — it attempts a
# hierarchy on every solve of every rung — and it is why `rearm` is a full arm
# and not a probe.
#
#   alg1   §4(a)  mg_algebraic_level1: does an ALGEBRAIC first coarse level make
#                 the V-cycle contract where the geometric one cannot? This is
#                 the standard remedy for exactly the geometric-coarse-space
#                 failure §2 diagnoses, and it is armed by a public fea.hpp
#                 setter with no production writer.
#   eta05  §3     the ersatz SHARPNESS, through the production knob that exists.
#                 PR 327's exact volume fraction is harness-only (§3), but
#                 `plsm.eta_voxels` is a job field, and narrowing the smoothed
#                 band from 2 voxels to 0.5 is the same sharpening applied on the
#                 production path. If a sharper ersatz tips the V-cycle further
#                 into stagnation, it shows up in these three solves.
#   eta40  §3     the CONTROL, and it is the half of §3 that makes the other half
#                 readable: the band WIDENED to 4 voxels. If neither 0.5 nor 4.0
#                 moves the cycle count, sharpness is not a variable here at all,
#                 and a one-sided test could not have told the difference between
#                 "no effect" and "an effect the run is insensitive to".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

ITERS=${ITERS:-1}
THREADS=${THREADS:-6}
WORK=${WORK:-"$HERE/probes"}
mkdir -p "$WORK"

BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
mkdir -p "$WORK/job"
cp "$BAKE/M2_verticalStand.step" "$WORK/job/"

# The three job variants. Only `plsm.eta_voxels` differs, and the base job is
# written out too so the comparison is against a job produced the same way.
python3 - "$BAKE/job_simp.json" "$WORK/job" <<'PY'
import json, sys, os
src, dst = sys.argv[1], sys.argv[2]
base = json.load(open(src))
for name, eta in (("job.json", None), ("job_eta05.json", 0.5), ("job_eta40.json", 4.0)):
    j = dict(base)
    if eta is not None:
        j["plsm"] = {"enabled": True, "eta_voxels": eta}
    json.dump(j, open(os.path.join(dst, name), "w"), indent=1)
PY

probe() {
  name=$1; job=$2; spec=$3
  # ★ -s, NOT -f. An INTERRUPTED run leaves a zero-byte summary behind (the
  # `grep ... > summary` in the failure path still creates the file), and a
  # `-f` guard would then skip it forever and report a half-finished table as
  # a finished one. Emptiness is the difference between "done" and "started".
  if [ -s "$WORK/$name.summary" ]; then
    echo "$name already present, skipping"
    return 0
  fi
  rm -f "$WORK/$name.summary"
  ./build/solver_arm_sweep "$WORK/job/$job" "$WORK/$name" \
      --arm "$spec" --threads "$THREADS" --iters "$ITERS" \
      > "$WORK/$name.log" 2>&1 || true
  grep -E '^ARM_SUMMARY|^ARM_RUNG' "$WORK/$name.log" > "$WORK/$name.summary" || true
  echo "--- $name ---"
  awk -F, 'NR==1{for(i=1;i<=NF;i++) c[$i]=i; next}
           {printf "  rung %s it %s  cg=%s  hier=%s  mg_cycles=%s  used_mg=%s\n",
                   $c["rung"],$c["iter"],$c["cg_iters"],$c["hier_built"],
                   $c["mg_cycles_attempted"],$c["cg_multigrid"]}' \
      "$WORK/$name/iterations.csv" 2>/dev/null || echo "  (no iterations.csv)"
}

case "${1:-all}" in
  ctl)   probe ctl   job.json       base ;;
  alg1)  probe alg1  job.json       alg1 ;;
  eta05) probe eta05 job_eta05.json base ;;
  eta40) probe eta40 job_eta40.json base ;;
  all)
    probe ctl   job.json       base
    probe alg1  job.json       alg1
    probe eta05 job_eta05.json base
    probe eta40 job_eta40.json base
    ;;
  *) echo "unknown probe: $1"; exit 2 ;;
esac
