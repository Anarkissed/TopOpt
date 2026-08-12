#!/bin/sh
# Regenerates everything in this directory. Nothing is cloned and nothing is
# downloaded; the only inputs are his STEP, his converged SIMP rung, PR 326's
# committed coefficients, and this repository's own sources.
#
# ★ 3 THREADS THROUGHOUT, AND STRICTLY SERIAL. He needs his machine.
# ★ RUNG 0.68 ONLY (R5) — he is measuring the ladder himself.
#
# Wall clock: about four hours, almost all of it the two arms' state solves.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# ── 0. the binaries. R6: none of this is production.
cmake -S core -B build > /dev/null
cmake --build build -j3 --target levelset_probe plsm_probe \
    external_field_surface_probe
sh "$HERE/check_r6.sh"

# ── 1. ★ THE TREE ITSELF, VERIFIED. This branch is main MERGED WITH PR 326's
# open sandbox: the brief's bar and seed are PR 326's, and PR 326 branched from
# PR 324 before PR 325 shipped the production PLSM. `check_merge.sh` runs three
# iterations of PR 326's own re-baseline configuration on this tree and diffs
# them against PR 326's committed `iterations.csv`. Identical or nothing below
# is comparable.
sh "$HERE/check_merge.sh"

# ── 2. S1(a) — the fraction against k, on ONE fixed design (PR 326's
# re-baseline at iteration 60, read back through `--alpha`). No optimiser.
sh "$HERE/run_probes.sh"

# ── 3. ★ R4 — the sensitivity against a central difference, BEFORE the arms are
# spent. Four (density, gradient) pairs on the same design, including PR 326's
# own as the control.
sh "$HERE/run_fd.sh"

# ── 4. THE TWO ARMS. One variable. 120 iterations, because PR 326 measured the
# margin still climbing at 60.
sh "$HERE/run_arms.sh"

# ── 5. the measurements. Every roughness number from
# `external_field_surface_probe` with SIMP in the same run; every margin, mass
# and load-path answer from `analyze_fixed_design` via `--certify-field`.
sh "$HERE/measure.sh"

# ── 6. the tables the handoff prints.
python3 "$HERE/tables.py" > "$HERE/tables.txt"
cat "$HERE/tables.txt"

echo REPRODUCE_DONE
