#!/bin/bash
# Drive the octet generation-cost probe. Each case runs in a FRESH process so
# getrusage(ru_maxrss) — a monotonic high-water mark — reports that case's own
# peak RSS. Emits octet_cost.csv (one row per case) and *.txt transcripts.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${BIN:-/private/tmp/claude-501/octet-build/octet_gen_probe}"
CSV="$HERE/octet_cost.csv"
FILES="$HERE/files"          # written STL/3MF for size + determinism
mkdir -p "$FILES"
rm -f "$CSV"

run() { echo "+ $*"; "$@"; }

echo "===== B2 self-check ====="                | tee "$HERE/o_selfcheck.txt"
"$BIN" selfcheck                                 | tee -a "$HERE/o_selfcheck.txt"

echo "===== O1: triangles + memory vs cell size (100% uniform, in-memory) ====="
export OCTET_CSV="$CSV"
for L in 12 8 6 4; do
  OCTET_CSV="$CSV" "$BIN" case "$L" 1.0 0 0 0
done

echo "===== O2: region fraction (L=4, 15^3=3375 cells so fractions resolve) ====="
for F in 1.0 0.5 0.2; do
  OCTET_CSV="$CSV" "$BIN" case 4 "$F" 0 1 0    # stream so the finer grid is cheap
done

echo "===== O3: streaming vs in-memory at the LARGEST case (L=4, 100%) ====="
# in-memory (holds the whole mesh) then streaming (writes slab-by-slab, frees)
OCTET_CSV="$CSV" "$BIN" case 4 1.0 0 0 0
OCTET_CSV="$CSV" "$BIN" case 4 1.0 0 1 0
# flatness check: streaming peak across sizes should be ~constant
for L in 12 8 6 4; do
  OCTET_CSV="$CSV" "$BIN" case "$L" 1.0 0 1 0
done
# B4 bookend: an EXTREME streaming case at PR-184 triangle scale (L=2mm ~24M tris,
# ~1.2GB STL) — proves peak RSS stays flat even there. Written to disk then removed.
echo "----- B4 extreme streaming case (L=2mm, PR-184 triangle scale) -----"
OCTET_CSV="$CSV" "$BIN" case 2 1.0 0 1 0

echo "===== O4: graded vs uniform (L=8 and L=4, in-memory) ====="
for L in 8 4; do
  OCTET_CSV="$CSV" "$BIN" case "$L" 1.0 0 0 0
  OCTET_CSV="$CSV" "$BIN" case "$L" 1.0 1 0 0
done

echo "===== write real STL + 3MF for size (L=8, 100% uniform) ====="
OCTET_OUT="$FILES" OCTET_CSV="$CSV" "$BIN" case 8 1.0 0 0 1   # in-mem -> STL + 3MF

echo "===== B3 DETERMINISM: same inputs twice, byte-identical? ====="   | tee "$HERE/b3_determinism.txt"
# Isolate each writer path in its own dir (the output filename is path-agnostic).
SA="$FILES/det_stream_a"; SB="$FILES/det_stream_b"
MA="$FILES/det_inmem_a";  MB="$FILES/det_inmem_b"
mkdir -p "$SA" "$SB" "$MA" "$MB"
OCTET_OUT="$SA" "$BIN" case 8 1.0 0 1 1 >/dev/null   # streaming STL, run A
OCTET_OUT="$SB" "$BIN" case 8 1.0 0 1 1 >/dev/null   # streaming STL, run B
OCTET_OUT="$MA" "$BIN" case 8 1.0 0 0 1 >/dev/null   # in-mem STL + 3MF, run A
OCTET_OUT="$MB" "$BIN" case 8 1.0 0 0 1 >/dev/null   # in-mem STL + 3MF, run B
STL=octet_L8_f100_uniform.stl
MF=octet_L8_f100_uniform.3mf
cmpf() {  # label file1 file2
  if cmp -s "$2" "$3"; then
    echo "  $1 : BYTE-IDENTICAL ($(wc -c < "$2") bytes)" | tee -a "$HERE/b3_determinism.txt"
  else
    echo "  $1 : DIFFERS  ($(shasum -a256 "$2" | cut -d' ' -f1) vs $(shasum -a256 "$3" | cut -d' ' -f1))" | tee -a "$HERE/b3_determinism.txt"
  fi
}
cmpf "streaming STL  (run A vs B)"      "$SA/$STL" "$SB/$STL"
cmpf "in-memory STL  (run A vs B)"      "$MA/$STL" "$MB/$STL"
cmpf "3MF            (run A vs B)"      "$MA/$MF"  "$MB/$MF"
cmpf "streaming vs in-memory STL"       "$SA/$STL" "$MA/$STL"

echo "===== O5 watertightness ====="                | tee "$HERE/o5_watertight.txt"
"$BIN" watertight 8                                  | tee -a "$HERE/o5_watertight.txt"

echo "===== O6 printability ====="                   | tee "$HERE/o6_angles.txt"
"$BIN" angles 8                                       | tee -a "$HERE/o6_angles.txt"

echo
echo "CSV written to $CSV"
column -s, -t "$CSV"
