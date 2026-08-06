#!/bin/bash
# C — REPRODUCTION. Send a job whose loads.wall_line_width_outer_mm is explicitly
# 0.42 and read run_info back. Run from the repo root of this worktree.
#
# The three jobs are the COMMITTED fixtures from evidence/2026-07-28-line-width-
# plumbing, so the run_info values below are directly comparable to the run_info
# values committed in that folder (which were produced at commit 4fed171, before
# the copy was deleted).
set -euo pipefail
W="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/linewidth-repro}"

cmake -S "$W/core" -B "$W/core/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$W/core/build" --target topopt_cli -j 8 >/dev/null
echo "cli built from: $(git -C "$W" rev-parse --short HEAD)"

mkdir -p "$OUT" && cd "$OUT"
cp "$W/evidence/2026-07-28-line-width-plumbing/job_maintainer_defaults.json" .
cp "$W/evidence/2026-07-28-line-width-plumbing/job_split.json" .
cp "$W/evidence/2026-07-28-line-width-plumbing/job_inner_only.json" .
cp "$W/core/tests/fixtures/demo/l-bracket.step" .

for j in job_maintainer_defaults job_split job_inner_only; do
  "$W/core/build/topopt-cli" run "$j.json" --out "out_$j" \
      --materials "$W/core/src/materials/materials.json" \
      --rules "$W/core/src/settings/rules.json" --no-iteration-csv >/dev/null 2>&1
  echo "=== $j"
  echo "  JOB SENT:"
  grep -o '"wall_line_width[a-z_]*": *[0-9.]*' "$j.json" | sed 's/^/    /'
  echo "  run_info.json GOT BACK (HEAD, $(git -C "$W" rev-parse --short HEAD)):"
  grep -E '"wall_(loops|line_width_mm|line_width_outer_mm|thickness_mm)"' \
      "out_$j/run_info.json" | sed 's/^ */    /'
  echo "  run_info.json COMMITTED 2026-07-28 (built at 4fed171, pre-drop):"
  grep -E '"wall_(loops|line_width_mm|line_width_outer_mm|thickness_mm)"' \
      "$W/evidence/2026-07-28-line-width-plumbing/out_$j/run_info.json" | sed 's/^ */    /'
done
