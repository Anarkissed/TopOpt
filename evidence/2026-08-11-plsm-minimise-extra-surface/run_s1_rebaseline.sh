#!/bin/sh
# S1 — THE HONEST VOLUME CONSTRAINT, AND THE RE-BASELINE IT FORCES.
#
# ★ WHY THIS RUNS FIRST. PR 324 §6 found a defect and deliberately did not fix
# it: "The volume constraint controls int H_eta(-phi). The part is #{rho > 0.5}.
# With a wide band those diverge as interface area grows, and nothing notices."
# One arm held `occupancy_volume` pinned at 75,414.7 for 30 consecutive
# iterations while `achieved_vf` slid 0.6839 -> 0.6634 — 3.0% of the printed
# material and 12.3 g given up without violating its own constraint.
#
# ★ THE DRIFT IS PROPORTIONAL TO INTERFACE AREA. Every measurement in this task
# is about interface area. Left in, the constraint silently REWARDS the thing
# S3 is trying to suppress, so it is closed before anything else is measured.
#
# ★ 3 THREADS, SERIALLY, ONE ARM AT A TIME. He needs his machine.
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
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" \
      --rung 0.68 --iters "$iters" --threads 3 --snapshot-every 10 \
      --plsm-export 1 --plsm-export 2 "$@" \
      > "$HERE/arms/$name.log" 2>&1
  echo "$name done: $(grep -c '^it ' "$HERE/arms/$name.log") iterations"
}

# ── C0 — THE CONTROL THAT LICENSES EVERYTHING ELSE ─────────────────────────
#
# ★ THE NEW FLAGS ARE PRESENT AND DEFAULTED OFF, AND THIS PROVES IT ON THE
# BINARY RATHER THAN BY READING THE DIFF. PR 324's B1_scratch_max, five
# iterations, with the S1/S3 binary. Every computed column must reproduce the
# committed `arm3/B1_scratch_max/iterations.csv` EXACTLY. `check_c0.sh` diffs
# them and is the gate: if it fails, no row below means anything, because the
# "without S1" half of S1(b) is that committed file.
run C0_control_5it 5 --seed holes --plsm-mma --plsm-basis gaussian \
    --plsm-knots 2,2,2 --plsm-support 2 --plsm-refit-every 5 --hj-steps 24

# ── RB1 — ★ THE RE-BASELINE. Identical to PR 324's ARM 2 in every respect but
# the one line: the constraint now measures the PRINTED count. Every number in
# this task is measured against THIS, and PR 324's Arm 2 is stated beside it.
run RB1_volcount 60 --seed holes --plsm-mma --plsm-basis gaussian \
    --plsm-knots 2,2,2 --plsm-support 2 --plsm-refit-every 5 --hj-steps 24 \
    --volume-count

echo S1_DONE
