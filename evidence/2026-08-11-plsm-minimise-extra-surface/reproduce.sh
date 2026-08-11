#!/bin/sh
# Regenerates everything in this directory. Nothing is cloned and nothing is
# downloaded; the only inputs are his STEP, his converged SIMP rung, and PR
# 324's committed sources — all already in this repository.
#
# ★ 3 THREADS THROUGHOUT, AND STRICTLY SERIAL. He needs his machine.
# ★ RUNG 0.68 ONLY (R5) — he is measuring the ladder himself.
#
# Wall clock: about five hours of state solves. The arms are the cost; every
# measurement below them is minutes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# ── 0. the binaries. R6: none of this is production. `git diff main --
# core/src core/include app/` is 0 lines, and `check_r6.sh` asserts it.
cmake -S core -B build > /dev/null
cmake --build build -j3 --target levelset_probe plsm_probe \
    external_field_surface_probe

sh "$HERE/check_r6.sh"

# ── 1. S1 — the honest volume constraint, and the control that licenses the
# rest. C0 must reproduce PR 324's ARM 2 exactly with every new flag off; if it
# does not, the "without S1" half of S1(b) is not PR 324's committed file and
# nothing below is comparable.
sh "$HERE/run_queue_a.sh"
sh "$HERE/check_c0.sh"

# ── 2. S3(d)'s pair and ARM 2. Queue B needs the frontier from queue A to pick
# its weight, so the weights it was run with are written into the script rather
# than derived here.
sh "$HERE/run_queue_b.sh"

# ── 2b. eta. The PROBE first (one fixed design, four band widths — answers the
# classification question with no optimiser at all), then the one arm the probe
# cannot answer: the perimeter functional CONTAINS eta, so the frontier is
# conditional on it until a matched pair says otherwise. It was not.
sh "$HERE/run_eta_probe.sh"
sh "$HERE/run_queue_c.sh"

# ── 2c. the nucleation band, which also carries --snapshot-every 1 so its tail
# is the margin-variance measurement.
sh "$HERE/run_queue_d.sh"

# ── 3. the measurements. Every roughness number from
# `external_field_surface_probe`, every margin/mass/load-path answer from
# `analyze_fixed_design` via `levelset_probe --certify-field`.
SNAP_ARMS="RB1_volcount" S2_ARMS="RB1_volcount" sh "$HERE/measure.sh"

# ★ AND THE MATCHED-ITERATION TABLE, WHICH IS THE ONE THE HANDOFF USES.
# `measure.sh` reads each arm's `rho`, which is its BEST-COMPLIANCE iterate —
# iteration 9 for one arm here and 60 for another. Every comparison must be at
# equal iterations, so `run_final.sh` re-measures every arm's it0060 snapshot.
# It also certifies EVERY iterate of one converged tail: the margin's own spread.
sh "$HERE/run_final.sh"

# ── 4. the tables the handoff prints.
python3 "$HERE/tables.py" > "$HERE/tables.txt"
cat "$HERE/tables.txt"

echo REPRODUCE_DONE
