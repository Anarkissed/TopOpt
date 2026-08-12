#!/bin/sh
# THE ARMS. ★ HIS OWN CAPTURED JOB (R4), ONE POSTURE CHANGE EACH (R5).
#
# The job is `evidence/2026-08-09-reference-implementation-bakeoff/job_simp.json`
# against `M2_verticalStand.step` — the same pair PR 324/326/327 measured and the
# same pair `evidence/2026-08-10-plsm-production/s1_production_run/` was produced
# from. `topopt-cli run` forces the parametric level set on (main.cpp: the verb
# has no SIMP route), so this IS the shipped PLSM production path, with
# `plsm_warm_start` and `plsm_cg_tolerance_loose 1e-4` exactly as his run_info
# reports them.
#
# ★ ONE DELIBERATE REDUCTION, NAMED HERE RATHER THAN BURIED: `--iters $ITERS`
# caps PLSM at $ITERS design iterations per rung instead of the shipped 60. It is
# applied IDENTICALLY to every arm including `base`, so it is not a variable
# between them; it is what makes five arms of a 4-rung 128^3 ladder fit in the
# time available. Every "total CG iterations" figure in the handoff is therefore
# a total over 4 x $ITERS design iterations, and is comparable ONLY within this
# table — never against his 60-iteration run.
#
# ★ WALL IS NOT THE SIGNAL AND THIS SCRIPT DOES NOT PRETEND OTHERWISE. The host
# was shared with other agents' `topopt-cli` runs throughout (host_load.txt), and
# the arms run two at a time at 3 threads each. CG ITERATION COUNTS ARE
# DETERMINISTIC and unaffected by either; wall is reported beside them as
# indicative only, which is the same discipline
# `2026-08-02-warm-start-coarse-experiment` §3 and `2026-07-29-geneo-arming`
# §Machine applied to the same condition.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

ITERS=${ITERS:-2}
THREADS=${THREADS:-3}
WORK=${WORK:-"$HERE/arms"}
mkdir -p "$WORK"

# The job, copied beside the STEP so the harness's relative model lookup resolves.
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
mkdir -p "$WORK/job"
cp "$BAKE/M2_verticalStand.step" "$WORK/job/"
cp "$BAKE/job_simp.json" "$WORK/job/job.json"

run_arm() {
  name=$1; spec=$2
  # ★ -s, NOT -f. An INTERRUPTED run leaves a zero-byte summary behind (the
  # `grep ... > summary` in the failure path still creates the file), and a
  # `-f` guard would then skip it forever and report a half-finished table as
  # a finished one. Emptiness is the difference between "done" and "started".
  if [ -s "$WORK/$name.summary" ]; then
    echo "$name already present, skipping"
    return 0
  fi
  rm -f "$WORK/$name.summary"
  ./build/solver_arm_sweep "$WORK/job/job.json" "$WORK/$name" \
      --arm "$spec" --threads "$THREADS" --iters "$ITERS" \
      > "$WORK/$name.log" 2>&1
  grep -E '^ARM_SUMMARY|^ARM_RUNG' "$WORK/$name.log" > "$WORK/$name.summary"
  cat "$WORK/$name.summary"
}

case "${1:-all}" in
  base)   run_arm base   base ;;
  rearm)  run_arm rearm1 rearm=1 ;;
  alg1)   run_arm alg1   alg1 ;;
  core16) run_arm core16 core=16 ;;
  core32) run_arm core32 core=32 ;;
  thr0)   run_arm thr0   thr=0 ;;
  all)
    run_arm base   base
    run_arm rearm1 rearm=1
    run_arm alg1   alg1
    run_arm core16 core=16
    run_arm core32 core=32
    run_arm thr0   thr=0
    ;;
  *) echo "unknown arm: $1"; exit 2 ;;
esac
