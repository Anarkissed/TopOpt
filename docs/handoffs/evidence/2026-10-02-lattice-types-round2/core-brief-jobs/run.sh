#!/bin/zsh
# Run the minimal Default Grade plan jobs (core brief 2026-10-02) through a topopt-cli.
# Usage: run.sh <topopt-cli> [workdir]. Uses core's own fixture model (dead_parity_tab.stl).
set -u
cli=${1:?topopt-cli}; here=${0:A:h}; repo=${here:h:h:h:h:h}
work=${2:-$(mktemp -d)}; mkdir -p "$work"; cp "$here"/*.json "$work/"; cp "$repo/core/tests/fixtures/organic/dead_parity_tab.stl" "$work/"
cd "$work"
for j in R2_min_corner_depth R2_control_shallower R3_no_region_in_key R3_control_shifted R5_global_finest_overlap R5_control_one_region; do
  mkdir -p "run_$j"
  "$cli" lattice-variant "$j.json" --out "run_$j" --materials "$repo/core/src/materials/materials.json" \
      --rules "$repo/core/src/settings/rules.json" > "$j.stdout" 2> "$j.stderr"
  echo "== $j exit $?"
  grep -E "^\[stepped\]|stepped_cells" "$j.stderr" | cut -c1-300
  grep -m1 "verdict" "$j.stdout"
done
