#!/bin/sh
# §1(c) THE ARMS — TOTAL CG ITERATIONS per tiling, on HIS captured job.
#
# ★ WHY THIS EXISTS WHEN run_nt_triage.sh ALREADY RAN A LADDER. The triage runs
# the same 4-rung ladder at `--iters 1`, and that is enough for N_t — the basis
# is built on the first solve and its dimension does not depend on how long the
# ladder runs. It is NOT enough for the ENGAGEMENT question, and the reason is
# specific and was measured, not assumed:
#
#   at --iters 1 the design is still near-uniform and the solves are EASY.
#   The triage's rung-1 solve burned 1,121 plain CG iterations against a
#   threshold of 4,816. His production run's solves burned 4,176-4,702.
#
# A solve that only ever costs 1,121 iterations declines at EVERY tiling — even
# a basis of N_t = 100 implies a threshold of 1,644, still above it. So a
# `--iters 1` sweep cannot distinguish "the tiling fixed the gate" from "the
# fixture was too easy to need it", and reading engagement off one would be
# reading the fixture, not the lever. These arms run deeper so the solves get
# hard enough for the question to be live.
#
# ★ ONE DELIBERATE REDUCTION, NAMED RATHER THAN BURIED: `--iters $ITERS` caps
# PLSM at $ITERS design iterations per rung instead of the shipped 60. It is
# applied IDENTICALLY to every arm, so it is not a variable between them; it is
# what makes the sweep fit the time available. Every "total CG" figure is a
# total over 4 x $ITERS design iterations and is comparable ONLY within this
# table — never against his 60-iteration run.
#
# ★ AND THE CAP BIASES THE TABLE AGAINST GenEO, which is the safe direction:
# it makes each solve CHEAPER than his while leaving the threshold GenEO must
# clear unchanged. A GenEO win measured here is a conservative one; a GenEO loss
# measured here is not proof of a loss at his depth, and §2 says so.
#
# ★ WALL IS NOT THE SIGNAL. This host was shared throughout (host_load.txt).
# CG ITERATION COUNTS ARE DETERMINISTIC and unaffected; wall is printed beside
# them as context only, per R1 and R2.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

ITERS=${ITERS:-3}
THREADS=${THREADS:-6}
WORK=${WORK:-"$HERE/arms"}
mkdir -p "$WORK"

run_arm() {
  name=$1; spec=$2
  # ★ -s, NOT -f. An INTERRUPTED run leaves a zero-byte summary behind, and a
  # `-f` guard would then skip it forever and report a half-finished table as a
  # finished one. Emptiness is the difference between "done" and "started".
  if [ -s "$WORK/$name.summary" ]; then
    echo "$name already present, skipping"
    return 0
  fi
  rm -f "$WORK/$name.summary"
  echo "=== $name ($spec) starting $(date '+%H:%M:%S') ITERS=$ITERS ==="
  ./build/solver_arm_sweep "$HERE/job/job.json" "$WORK/$name" \
      --arm "$spec" --threads "$THREADS" --iters "$ITERS" \
      > "$WORK/$name.log" 2>&1 || true
  # ★ Written only if the run actually produced a summary line. A run killed
  # mid-ladder leaves the .summary absent, and tables.py prints that row as
  # "INCOMPLETE — the ABSENCE of a measurement, not a zero".
  if grep -qE '^ARM_SUMMARY' "$WORK/$name.log"; then
    grep -E '^ARM_SUMMARY|^ARM_RUNG' "$WORK/$name.log" > "$WORK/$name.summary"
    cat "$WORK/$name.summary"
  else
    echo "$name: NO ARM_SUMMARY — run did not finish; leaving no summary so the"
    echo "  table reports it as incomplete rather than as a zero."
  fi
}

# base FIRST: it is the denominator every other row is read against, so if the
# machine only affords one arm it must be that one.
case "${1:-all}" in
  base)   run_arm base   base ;;
  core12) run_arm core12 core=12 ;;
  core16) run_arm core16 core=16 ;;
  core24) run_arm core24 core=24 ;;
  all)
    run_arm base   base
    run_arm core16 core=16
    run_arm core24 core=24
    run_arm core12 core=12
    ;;
  *) echo "unknown arm: $1"; exit 2 ;;
esac
