#!/usr/bin/env bash
# Step 1c: the density -> strut-diameter law of bcc, diamond and sc under rho 0.05, where their tables
# (lattice.cpp kBccDia / kDiamondDia / kScDia, docs/handoffs/evidence/2026-11-01-lattice-types-k1/<type>_law.csv)
# started: below their first row lattice_strut_diameter_mm CLAMPS to it, so with the band now reaching 0.016-0.039
# every reader of the diameter at a low density (the light cell floor, the old engine's graded struts, the aesthetic
# line) would read the 0.05 strut. Same probe and method as the K1 table: `lattice_types_probe law`, r/L bisected
# 50 steps on the cell's converged solid fraction (2^20 Halton points), diameter at a 4 mm cell; the B3 vpc48 column
# for comparison. A few seconds a type.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-strut-laws-low-density/diameter
for t in bcc diamond sc; do
  TOPOPT_LATTICE_CSV_DIR=$EV TOPOPT_LT_RHOS=0.015,0.02,0.025,0.03,0.035,0.04,0.045 \
    ./core/build/lattice_types_probe law $t > "$EV/${t}_law.log" 2>&1 &
done
wait
