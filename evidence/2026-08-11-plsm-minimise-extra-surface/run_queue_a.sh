#!/bin/sh
# QUEUE A — the re-baseline, the S3 frontier, and the one ARM 2 mechanism that
# is cheap enough to measure on its own.
#
# ★ 3 THREADS, STRICTLY SERIAL. He needs his machine, and this host's
# run-to-run offset under contention is large enough to swallow a comparison
# (evidence/2026-08-09-reference-implementation-bakeoff/host_contention.txt).
#
# ★ RUNG 0.68 ONLY. R5 — he is measuring the ladder himself.
#
# Every arm here is 60 iterations, `--seed holes` with NO SIMP anywhere, the
# gaussian basis at 85,680 coefficients, MMA, and `--volume-count`. They differ
# only in the flags named on each line.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"

run() {
  name=$1; iters=$2; shift 2
  if [ -f "$HERE/arms/$name/summary.txt" ]; then
    echo "$name already present, skipping"
    return 0
  fi
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" \
      --rung 0.68 --iters "$iters" --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations, $(date '+%H:%M:%S')"
}

BASE="--seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
      --plsm-support 2 --plsm-refit-every 5 --hj-steps 24 --volume-count"

# ── RB1 — ★ THE RE-BASELINE. PR 324's ARM 2 with S1's constraint and nothing
# else. Every number in this task is measured against THIS; PR 324's Arm 2 is
# quoted beside it, never in place of it.
run RB1_volcount 60 $BASE

# ── S0 — ★ THE SEED'S TOPOLOGY SCALE, ALONE. Not the basis (PR 324 §6(ii)
# refuted that and it is not re-tested); the STARTING POINT. Period 16 instead
# of 8 is roughly an eighth as many holes. It adds no term and no solve, so
# whatever it does to the margin it does by finding a different structure
# rather than by taxing the one it found. Run alone so it is attributable.
run S0_seed16 60 $BASE --seed-period 16

# ── S3 — THE FRONTIER. Four weights, same everything else, all certified.
# Ordered 1, 4, 2, 8 so the range is bracketed after two runs.
run P1_c1 60 $BASE --perimeter 1
run P3_c4 60 $BASE --perimeter 4
run P2_c2 60 $BASE --perimeter 2
run P4_c8 60 $BASE --perimeter 8

# ── S3(b) — CONTINUATION, PAIRED WITH ITS OWN FIXED WEIGHT. C=4 is the weight
# most likely to be too strong at iteration 1 while still being worth having at
# iteration 60, so it is the one where a ramp should show. Zero until iteration
# 10, full at 30. `P3_c4` is the same weight applied from the start, so the pair
# isolates the SCHEDULE and nothing else.
run PR_c4_ramp 60 $BASE --perimeter 4 --perimeter-ramp 10,20

echo QUEUE_A_DONE
