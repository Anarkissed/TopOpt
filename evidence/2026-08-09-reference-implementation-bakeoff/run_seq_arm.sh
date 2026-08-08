#!/bin/sh
# GTO-SEQ — SEQUENTIAL SIMP -> LEVEL-SET REFINEMENT, all four rungs.
#
# φ0 = exact signed distance to HIS converged rung's 0.5 level set; the ALM then
# refines only the boundary. This is the arm §S4c asks about, and it is the only
# one in this task's budget where GridapTopOpt's OPTIMISER actually runs on his
# part: from a cold hole-seeded start the same grid costs 277.7 s per ALM
# iteration and hundreds of iterations (see s2_from_scratch_timing.log).
#
# ★ THE TARGET IS HIS PRINTED FRACTION, NOT HIS NOMINAL RUNG. SIMP's "volume
# fraction 0.68" is the integral of a GREY density; the set it actually prints —
# the voxels above iso 0.5 — is 0.7973 of the part (PR 319's
# `printed_fraction`). A level set has no grey, so its volume IS a printed
# fraction. Targeting 0.68 would make the level-set arm remove 12% more material
# than his rung did, and the surface comparison would be measuring that instead
# of the representation. The printed fractions are PR 319's own, from
# baseline_pr319_s2_cost_and_verdict.csv.
#
# ★ AND THE ITERATION BUDGET IS A BUDGET, NOT A CONVERGENCE. 5 ALM iterations per
# rung is what fits; the ALM is NOT converged at 5 and the rows say so.
set -e
SC="$(cd "$(dirname "$0")" && pwd)"
ITERS=${ITERS:-5}
set -- "0.68 0.7973021712" "0.52 0.6940597273" "0.38 0.6048203852" "0.26 0.5283398254"
for pair in "$@"; do
  rung=$(echo "$pair" | cut -d' ' -f1); pf=$(echo "$pair" | cut -d' ' -f2)
  echo "=== SEQ rung $rung target printed-fraction $pf, $ITERS iterations $(date -u +%FT%TZ) ==="
  SEED_DENSITY="$SC/simp_rungs/rung_$rung.f64" JULIA_PROJECT="$SC/env" \
    julia --startup-file=no "$SC/his_part_ALM.jl" "$SC/problem" "$SC/out_seq_$rung" "$pf" "$ITERS" 1
done
echo SEQ_ARM_DONE
