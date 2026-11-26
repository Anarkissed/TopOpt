#!/usr/bin/env bash
# The low-density tensor rows of bcc, diamond and sc (step 1 of reproduce.sh), tensor_library_nine_probe `sweep`, in two
# blocks per type as octet's own LOW/HIGH blocks (ruling 2026-11-02 (c)): one process per block, its own reference
# curve, one core each, the six side by side.
#   low   rows at vpc 80 against a vpc 120 curve (the thinnest struts: >= 6 voxels across at the floor, strut/cell 0.084)
#   high  rows at vpc 64 against a vpc 96 curve (octet's HIGH pair)
# Each list starts and ends with a bracket (the first and last target): reference points that keep every landed row
# inside its curve (interp_curve does not extrapolate). assemble.py says which rows land.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-11-25-strut-laws-low-density/tensor
P=./core/build/tensor_library_nine_probe
mkdir -p "$EV/low" "$EV/high"
run() {  # block vpcs type vfs
  TOPOPT_LATTICE_CSV_DIR=$EV/$1 TOPOPT_TL_VPCS=$2 TOPOPT_TL_VFS=$4 "$P" sweep "$3" > "$EV/$1/$3_sweep.log" 2>&1
  echo "$3 exit $?" >> "$EV/$1/$3_sweep.log"
}
run low  80,120 bcc     0.032,0.0355,0.043,0.052,0.063,0.076,0.092,0.110 &
run high 64,96  bcc     0.092,0.110,0.132,0.158,0.190,0.2105 &
run low  80,120 diamond 0.032,0.0355,0.043,0.052,0.063,0.076,0.092,0.110 &
run high 64,96  diamond 0.092,0.110,0.132,0.15712 &
run low  80,120 sc      0.0144,0.0158,0.019,0.023,0.028,0.034,0.041 &
run high 64,96  sc      0.034,0.041,0.050,0.060,0.072,0.08659 &
wait
