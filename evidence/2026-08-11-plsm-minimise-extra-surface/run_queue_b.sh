#!/bin/sh
# QUEUE B — S3(d)'s pair, and ARM 2.
#
# ★ 3 THREADS, STRICTLY SERIAL, RUNG 0.68 ONLY.
#
# `ARM2_C` is the perimeter weight ARM 2 runs at. It is an argument because it
# is CHOSEN FROM QUEUE A'S FRONTIER and not derivable in advance; the value the
# handoff's tables were produced with is the default below, so re-running this
# script reproduces them.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
# ★ C = 1 IS THE KNEE, AND QUEUE A IS WHERE THAT COMES FROM. The certified
# margin over the frontier reads 2256 (C=0, seed 8) / 3028 (C=1) / 1552 (C=2) /
# 1369 (C=4). It does not decay — it falls off a cliff between 1 and 2, and
# every weight at or above 2 is below half of SIMP's 3254. So ARM 2 runs at the
# last weight that is still on the useful side of that edge.
ARM2_C="${ARM2_C:-1}"

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
      --plsm-support 2 --hj-steps 24 --volume-count"

# ── ★ S3(d) — THE PAIR THAT ACTUALLY TESTS THE MECHANISM CLAIM ─────────────
#
# PR 324 §10.3 predicted the perimeter term would behave differently on a
# parametric phi "where there is no reinitialisation to fight it". ★ BUT THE
# CONFIGURATION BEING RE-BASELINED RUNS `--plsm-refit-every 5` — the
# literature's approximate reinitialisation: re-distance phi on the grid, then
# re-project onto the basis. So every arm in queue A HAS one, and the sweep on
# its own cannot answer the question it was asked.
#
# This is the same weight with the reinitialisation OFF. Paired against
# `P3_c4`, it isolates the schedule the prediction is about and nothing else.
run N1_c4_norefit 60 $BASE --plsm-refit-every 0 --perimeter 4

# ── ★ ARM 2 — ALL MECHANISMS AT ONCE ───────────────────────────────────────
#
#   --seed-period 16     the SEED's topology scale. Not the basis: PR 324
#                        §6(ii) refuted a coarser basis and it is not retested.
#                        Adds no term and no solve, so it cannot buy smoothness
#                        by deleting load-bearing material.
#   --perimeter C        the frontier's knee, FIXED. ★ THE RAMP IS DELIBERATELY
#                        NOT HERE, AND THE BRIEF ASKED FOR IT. `PR_c4_ramp`
#                        against `P3_c4` — same weight, ramped against fixed —
#                        came out DOMINATED ON BOTH AXES: carved 14.7985 against
#                        8.1070, 65,294 triangles against 45,042, and margin 917
#                        against 1369. Putting a measured-harmful mechanism into
#                        "the best I can do" would make ARM 2 worse on purpose.
#                        See the handoff §3(b) for why it loses.
#   --perimeter-local 1  price CURVATURE, not area — the Willmore gradient with
#                        the d_n(kappa) term dropped. The literature's case for
#                        it is that curvature concentration can be controlled
#                        "without inducing shrinkage, in contrast to area
#                        minimisation", which is exactly what PR 325 measured
#                        the plain perimeter term costing: 6.4% of margin at
#                        C=2, 66% at C=8.
#   --robust 1           Sigmund 2009's worst-of-eroded/intermediate/dilated, at
#                        one voxel. THREE state solves per iteration. Not a
#                        minimum-feature rule: it lets the optimiser build thin
#                        members and declines to pay for them.
#   --plsm-refit-every 5 kept, so ARM 2 differs from the frontier in the
#                        mechanisms and not in the reinitialisation as well.
run A2_all 60 $BASE --plsm-refit-every 5 --seed-period 16 \
    --perimeter "$ARM2_C" --perimeter-local 1 --robust 1

# ── ★ A3 — THE TWO MECHANISMS THAT EACH WORKED ALONE, TOGETHER, AND NOTHING
# ELSE. `S0_seed16` bought the MARGIN back at no cost (3389 against the
# re-baseline's 2256, peak stress a third lower) and took 8.9% off the surface;
# the perimeter weight bought the SURFACE (24.7% at C=1) and gave up 7% of the
# margin. They move different things, so the pair is the point most likely to be
# worth shipping — and unlike `A2_all` it costs ONE state solve per iteration,
# not three. Run so the handoff can say what the expensive mechanisms in
# `A2_all` are worth OVER the cheap ones, rather than over nothing.
#
# ★ NO RAMP HERE, DELIBERATELY, so the arm stays ATTRIBUTABLE. Against `P1_c1` —
# the same fixed weight on the period-8 seed — it isolates the SEED and nothing
# else. The RAMP is isolated separately, by `PR_c4_ramp` against `P3_c4`.
# `A2_all` carries the seed plus the two expensive mechanisms; if every ablation
# were folded into one arm, nothing could be attributed to anything.
run A3_seed16_perim 60 $BASE --plsm-refit-every 5 --seed-period 16 \
    --perimeter "$ARM2_C"

echo QUEUE_B_DONE
