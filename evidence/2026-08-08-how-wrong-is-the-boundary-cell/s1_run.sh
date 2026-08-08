#!/usr/bin/env bash
# S1 of task 2026-08-08-how-wrong-is-the-boundary-cell.
#
# Re-solve each of the maintainer's four rungs at the resolution it was CERTIFIED
# at (128) and at 2x that, and write one CSV row per solve.
#
# TWO MODES, because there are two different questions (see the probe's header):
#   replicate  ONLY the element size changes -- the reference.
#   retag      the whole job re-discretized at 2x, load case included.
#
# Every solve is a separate process, so the Krylov recycle space starts empty
# every time and no solve can inherit state from the one before it.
#
# Sequential BY DESIGN: R4 wants wall clock, and a wall clock measured against
# other solves competing for the same 10 cores is not a measurement (this
# machine's run-to-run offset is already ~10%, evidence 2026-08-07).
#
#   ./evidence/2026-08-08-how-wrong-is-the-boundary-cell/s1_run.sh [job_dir]

set -u
JOB="${1:-$HOME/.topopt-worker/ca62f91cba4b422d}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROBE="$ROOT/core/build/boundary_cell_probe"
DESIGN="$JOB/out/design.bin"
CSV="$HERE/s1_refine.csv"

[ -x "$PROBE" ] || { echo "build it first: cmake --build core/build --target boundary_cell_probe"; exit 1; }
[ -f "$DESIGN" ] || { echo "no design.bin at $DESIGN"; exit 1; }

run() {  # mode rung refine tag extra...
  local mode="$1" rung="$2" refine="$3" tag="$4"; shift 4
  local out="$HERE/raw_${mode}_rung${rung}_r${refine}${tag}.txt"
  [ -f "$out" ] && { echo "=== SKIP (already have) $out"; return; }
  echo "=== $mode rung $rung refine ${refine}x ${tag:-} -> $(basename "$out")"
  /usr/bin/time -l "$PROBE" "$JOB" "$DESIGN" "$rung" "$refine" "$CSV" \
      --mode "$mode" "$@" > "$out" 2>&1
  echo "    exit=$?  $(grep -m1 'margin worst_case' "$out" || true)  $(grep -m1 'wall  ' "$out" || true)"
}

# ── THE COARSE SIDE: the resolution the certificate was issued at. --calibrate on
# rung 0 only; it costs a second full solve and its only job is to put a real CG
# iteration count beside the operator-apply count once (R4).
#
# ★ These four are also THE POSITIVE CONTROL. At refine 1 the subdivision is the
# identity, so a `replicate` run still executes the whole reference construction
# (tag copy, BC rebuild, traction rebuild) and must land on the margin the run
# RECORDED. The `retag` row beside it is the shipped setup for the same rung, so
# the two together prove the construction is the identity where it must be.
run replicate 0 1 "" --calibrate
run replicate 1 1 ""
run replicate 2 1 ""
run replicate 3 1 ""
run retag 0 1 ""
run retag 1 1 ""
run retag 2 1 ""
run retag 3 1 ""

# ── THE FINE REFERENCE.
run replicate 0 2 ""
run replicate 1 2 ""
run replicate 2 2 ""
run replicate 3 2 ""

# ── ★ R2: THE REFERENCE'S OWN NOISE. Same rung, same refinement, same arguments,
# fresh process. Nothing may be quoted against the reference without this beside
# it. Two rungs, so the floor is not read off a single pair.
run replicate 0 2 "_repeat"
run replicate 3 2 "_repeat"

# ── THE OTHER QUESTION: the whole job re-discretized at 2x, load case included.
run retag 0 2 ""
run retag 1 2 ""
run retag 2 2 ""
run retag 3 2 ""

echo "done -> $CSV"
