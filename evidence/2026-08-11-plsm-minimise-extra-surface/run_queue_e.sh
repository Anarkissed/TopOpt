#!/bin/sh
# QUEUE E — ★ THE TWO WINNING KNOBS, ON THE WHOLE MACHINE, TIMED.
#
# ★ THE KNOBS: the perimeter weight at the frontier's knee (C = 1) and the band
# width halved (eta = 1). Those are the two this task found; §3 and §3(e).
# Everything else is the re-baseline's configuration unchanged.
#
# ★ THE STOP: whichever comes first —
#     * the CERTIFIED margin reaches SIMP's 3254.34, or
#     * the wall clock reaches 1911.6 s, which is what the same two knobs cost
#       on 3 threads over 60 iterations (`E1_c1_eta1`).
#   ★ THE CAP IS ON OPTIMISATION TIME, NOT TOTAL WALL. The first attempt at this
#   run capped total wall and spent 559 s of its 1912 s budget on two
#   certifications — certifying an UNCONVERGED design cost 537.9 s against 20.9 s
#   for a converged one, a 26x spread. Capping total wall times the measuring
#   instrument, not the method. `--certify-from 20` for the same reason: E1
#   crossed SIMP between iterations 20 and 30, so nothing before 20 can pass and
#   an early certificate is pure cost.
#
#   Certification every 5 iterations from 20 on, by `analyze_fixed_design` at the
#   PRODUCTION tolerance, solver and penalty — the same call the end-of-run
#   certificate makes, so the rule cannot stop on a number the certificate
#   would disagree with. Its cost is reported SEPARATELY from the optimisation's.
#
# ★ 6 THREADS — the maintainer asked for the whole machine on this one. Every
# other arm in this task ran on 3, so this arm's WALL CLOCK is not comparable to
# theirs and only its own two numbers (total, and total minus certification)
# mean anything.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
if [ -f "$HERE/arms/W1_winning_6core/summary.txt" ]; then echo "W1 present"; exit 0; fi
mkdir -p "$HERE/arms/W1_winning_6core"
/usr/bin/time -l ./build/levelset_probe \
    "$BAKE/M2_verticalStand.step" core/src/materials/materials.json \
    "$BAKE/s2_simp_baseline/design.bin" "$HERE/arms/W1_winning_6core" \
    --rung 0.68 --iters 60 --threads 6 --snapshot-every 5 \
    --plsm-export 1 --plsm-export 2 \
    --seed holes --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
    --plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 \
    --eta 1 --perimeter 1 \
    --certify-every 5 --certify-from 20 --margin-stop 3254.34 --wall-cap 1911.6 \
    > "$HERE/arms/W1_winning_6core.log" 2>&1
echo "W1 done: $(grep -c '^it ' "$HERE/arms/W1_winning_6core.log") iterations"
