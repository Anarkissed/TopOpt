#!/bin/sh
# THE CONTROLS THE HEADLINE NEEDS.
#   eta0.5 / eta1 / eta2  — their ersatz bandwidth swept. eta_coeff=2 is THEIR
#     default and is a +/- 2-voxel ramp; if the smoothness win survives at
#     eta_coeff=0.5 it is the REPRESENTATION, and if it does not it is a blur.
#   noreinit              — the exact EDT with nothing of GridapTopOpt's run on
#     it, so their reinitialiser's own contribution is isolated.
set -e
SC="$(cd "$(dirname "$0")" && pwd)"
for vf in 0.68 0.26; do
  for e in 0.5 1.0; do
    echo "=== eta $e rung $vf $(date -u +%FT%TZ) ==="
    ETA_COEFF=$e SEED_DENSITY="$SC/simp_rungs/rung_$vf.f64" JULIA_PROJECT="$SC/env" \
      julia --startup-file=no "$SC/his_part_ALM.jl" "$SC/problem" "$SC/out_eta${e}_$vf" "$vf" 0 1
  done
  echo "=== noreinit rung $vf $(date -u +%FT%TZ) ==="
  SEED_DENSITY="$SC/simp_rungs/rung_$vf.f64" JULIA_PROJECT="$SC/env" \
    julia --startup-file=no "$SC/his_part_ALM.jl" "$SC/problem" "$SC/out_noreinit_$vf" "$vf" -1 1
done
echo CONTROLS_DONE
