#!/bin/zsh
# R6 (core brief 2026-10-02, measured 2026-10-03): an ACCEPTED stepped cell is LAID somewhere else.
# Also runs R2x, the R2 corollary: a cell one layer in FRONT of a -y face is ACCEPTED.
# Usage: run_r6_all.sh <topopt-cli> [workdir]. Uses core's own fixture model (dead_parity_tab.stl).
# Then measures where each cell was laid from the emitted STLs (r6_measure.py).
set -u
cli=${1:?topopt-cli}; cli=${cli:A}; here=${0:A:h}; repo=${here:h:h:h:h:h:h}
work=${2:-$(mktemp -d)}; mkdir -p "$work"; cp "$here"/*.json "$work/"
cp "$repo/core/tests/fixtures/organic/dead_parity_tab.stl" "$work/"
cd "$work"
"$cli" --version 2>&1 | head -1
for j in R6_base_off_grid R6_ref_at_18 R6_control_on_grid R6_off_grid_plus2 R6_far_cell \
         R6b_half_on_quarter_grid R6b_ref_half_at_22_5 R6b_control_half_at_21 \
         R6c_anystep_off_own_grid R6c_control_mirror R6c_ref_big_at_18 R6c_ref_tile_at_18 R6c_ref_tile_at_25_25 R6c_far_tile \
         R6d_anystep_second_slot R6d_ref_at_25_4 R6d_control_first_slot \
         R2x_outside_face_accepted; do
  mkdir -p "run_$j"
  "$cli" lattice-variant "$j.json" --out "run_$j" --materials "$repo/core/src/materials/materials.json" \
      --rules "$repo/core/src/settings/rules.json" > "$j.stdout" 2> "$j.stderr"
  echo "== $j exit $? | $(grep -E '^\[stepped\]|stepped_cells' "$j.stderr" | cut -c1-160) | $(grep -m1 verdict "$j.stdout" | tr -s ' ')"
done
python3 "$here/r6_measure.py" "$work"
python3 "$here/group_port.py"
