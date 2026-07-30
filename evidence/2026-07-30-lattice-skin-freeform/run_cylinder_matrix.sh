#!/usr/bin/env bash
# Cylinder E2E: all three finishes x two cell sizes, each run TWICE (E10:
# byte-identical rerun; run_info.json/iterations.csv are timing and excluded).
set -euo pipefail
cd "$(dirname "$0")/../.."
EV=evidence/2026-07-30-lattice-skin-freeform
for cfg in shell_c25 skin_c25 shellskin_c25 shell_c40 skin_c40 shellskin_c40; do
  ./core/build/topopt-cli run "$EV/job_cyl_$cfg.json" --out "$EV/out_cyl_$cfg" > /dev/null
  ./core/build/topopt-cli run "$EV/job_cyl_$cfg.json" --out "$EV/out_cyl_${cfg}_rerun" > /dev/null
  same=1
  for f in "$EV/out_cyl_$cfg"/report.json "$EV/out_cyl_$cfg"/fields.bin \
           "$EV/out_cyl_$cfg"/variant_*.stl "$EV/out_cyl_$cfg"/variant_*_lattice.report.json; do
    cmp -s "$f" "$EV/out_cyl_${cfg}_rerun/$(basename "$f")" || { echo "E10 DIFFER $cfg $(basename "$f")"; same=0; }
  done
  echo "E10 $cfg byte_identical=$same"
  rm -rf "$EV/out_cyl_${cfg}_rerun"
done
echo CYL_MATRIX_DONE
