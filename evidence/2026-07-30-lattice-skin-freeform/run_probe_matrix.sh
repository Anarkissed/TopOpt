#!/usr/bin/env bash
# E2/E3/E4/E5/E6/E7/E10 probe matrix — one process per configuration so
# ru_maxrss is per-configuration (PR 250's B8 discipline). "off" = the
# boundary-finish behaviour (the E7 BEFORE timing), "on" = the freeform skin.
set -euo pipefail
cd "$(dirname "$0")/../.."
EV=evidence/2026-07-30-lattice-skin-freeform
P=./core/build/lattice_skin_freeform_probe
for cell in 8 4 2; do
  $P run "$EV" "$cell" off > "$EV/probe_off_${cell}mm.txt"
  $P run "$EV" "$cell" on  > "$EV/probe_on_${cell}mm.txt"
done
$P run "$EV" 8 on graded > "$EV/probe_on_graded_8mm.txt"
$P run "$EV" 4 on graded > "$EV/probe_on_graded_4mm.txt"
echo MATRIX_DONE
