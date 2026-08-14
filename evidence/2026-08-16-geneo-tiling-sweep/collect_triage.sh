#!/bin/sh
# Harvest the triage runs' SMALL artifacts into this evidence directory.
#
# run_nt_triage.sh writes each point's full output set to a scratch directory
# under $TMPDIR — including a 22 MB STL and a 7.7 MB fields.bin per point, which
# do not belong in the repository. The two files that carry the measurement are
# `run_info.json` (N_t, basis MB, the decision log, the margins) and
# `iterations.csv` (per-solve cg_iters and the gate's burn/threshold columns,
# which is what §1(d)'s distribution is computed from).
#
# ★ Copied rather than regenerated: a scratch directory under $TMPDIR is subject
# to the OS's own cleanup, and a measurement that exists only there is a
# measurement that can vanish between the run and the handoff.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=${WORK:-"${TMPDIR:-/tmp}/geneo_tiling_nt"}

for d in "$WORK"/nt*; do
  [ -d "$d" ] || continue
  c=$(basename "$d" | sed 's/^nt//')
  dst="$HERE/nt_triage/run_core$c"
  mkdir -p "$dst"
  for f in run_info.json iterations.csv loadcase.json; do
    [ -f "$d/$f" ] && cp "$d/$f" "$dst/"
  done
  echo "collected core=$c -> $dst ($(ls "$dst" | tr '\n' ' '))"
done
