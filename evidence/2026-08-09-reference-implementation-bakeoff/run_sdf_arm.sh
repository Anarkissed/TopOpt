#!/bin/sh
# GTO-SDF — the REPRESENTATION-ONLY arm, all four rungs.
# φ0 = exact signed distance to HIS converged rung's 0.5 level set; GridapTopOpt's
# own reinitialiser runs once; no optimisation, no state solve. It isolates the
# LEVEL-SET REPRESENTATION from the level-set OPTIMISATION.
set -e
SC="$(cd "$(dirname "$0")" && pwd)"
for vf in 0.68 0.52 0.38 0.26; do
  echo "=== SDF rung $vf $(date -u +%FT%TZ) ==="
  SEED_DENSITY="$SC/simp_rungs/rung_$vf.f64" JULIA_PROJECT="$SC/env" \
    julia --startup-file=no "$SC/his_part_ALM.jl" "$SC/problem" "$SC/out_sdf_$vf" \
      "$vf" 0 1
done
echo SDF_ARM_DONE
