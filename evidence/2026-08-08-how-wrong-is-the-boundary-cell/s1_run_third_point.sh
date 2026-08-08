#!/usr/bin/env bash
# ★ THE THIRD POINT. S1 with two resolutions can say "the coarse answer is X%
# off the finer one". It CANNOT say whether the finer one is itself converged --
# and that is the difference between "his margin is overstated by X%" and "the
# peak stress this certificate reads has no limit at all".
#
# So one more refinement, 3x (resolution 384), on two rungs: rung 0 (the only one
# whose design still carries a grey band) and rung 3 (the one with the largest
# boundary fraction, 59.7% of printed cells). With 128 / 256 / 384 the sequence
# f(h) = f0 + C h^p has three equations and three unknowns, so the observed order
# p and the extrapolated limit f0 are MEASURED rather than assumed.
#
# Run AFTER s1_run.sh, on a quiet machine.
#   ./evidence/2026-08-08-how-wrong-is-the-boundary-cell/s1_run_third_point.sh

set -u
JOB="${1:-$HOME/.topopt-worker/ca62f91cba4b422d}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$ROOT/core/build/boundary_cell_probe"
DESIGN="$JOB/out/design.bin"
CSV="$HERE/s1_refine.csv"

# R4 first: the applies-per-CG-iteration ratio was calibrated at 128 (1.234). It
# is not safe to carry a ratio measured at one problem size to another, so it is
# measured again at 2x rather than assumed. The run doubles as a third solve of
# that (rung, refinement), which is why it writes a `_calib` row: more repeats,
# not fewer.
out="$HERE/raw_replicate_rung0_r2_calib.txt"
if [ -f "$out" ]; then echo "=== SKIP (already have) $(basename "$out")"; else
  echo "=== replicate rung 0 refine 2x --calibrate -> $(basename "$out")"
  /usr/bin/time -l "$PROBE" "$JOB" "$DESIGN" 0 2 "$CSV" --mode replicate \
      --calibrate > "$out" 2>&1
  echo "    exit=$?  $(grep -m1 'calibrate  :' "$out" || true)"
fi

for rung in 0 3; do
  out="$HERE/raw_replicate_rung${rung}_r3.txt"
  [ -f "$out" ] && { echo "=== SKIP (already have) $(basename "$out")"; continue; }
  echo "=== replicate rung $rung refine 3x -> $(basename "$out")"
  /usr/bin/time -l "$PROBE" "$JOB" "$DESIGN" "$rung" 3 "$CSV" --mode replicate \
      > "$out" 2>&1
  echo "    exit=$?  $(grep -m1 'margin worst_case' "$out" || true)"
done
echo "done -> $CSV"
