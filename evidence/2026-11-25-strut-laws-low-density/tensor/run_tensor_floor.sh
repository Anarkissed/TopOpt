#!/usr/bin/env bash
# Step 1b: the floor block of diamond and sc, rows at vpc 96 against a vpc 144 curve. At vpc 80 their thinnest
# targets could not be landed or kept: sc's 0.014 / 0.016 / 0.019 all voxelize to the same solid (rho 0.01945, a gap in
# the voxel distance spectrum), and diamond's 0.032 drifted -2.74 % (over the 2.4 % bar). A finer pitch lands
# different voxel sets and resolves them better. Same probe, same rule; first and last targets are brackets.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-strut-laws-low-density/tensor
P=./core/build/tensor_library_nine_probe
mkdir -p "$EV/floor"
run() {  # type vfs
  TOPOPT_LATTICE_CSV_DIR=$EV/floor TOPOPT_TL_VPCS=96,144 TOPOPT_TL_VFS=$2 "$P" sweep "$1" > "$EV/floor/$1_sweep.log" 2>&1
  echo "$1 exit $?" >> "$EV/floor/$1_sweep.log"
}
run diamond 0.0300,0.0330,0.0365,0.0420 &
run sc      0.0135,0.0150,0.0162,0.0175,0.0200 &
wait
