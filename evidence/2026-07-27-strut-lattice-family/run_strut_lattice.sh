#!/bin/bash
# Reproduce the strut-lattice-family evidence (handoff 2026-07-27-strut-lattice-family).
# Builds the standalone generator, then runs every measurement into text/CSV and
# writes one 40 mm printable block (STL + 3MF) per lattice into files/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="/private/tmp/claude-501/strut-lattice-build"
BIN="$BUILD/strut_lattice_gen"
FILES="$HERE/files"
mkdir -p "$FILES"

bash "$HERE/build_strut_lattice.sh" "$BUILD"

LATS="sc bcc bccz fcc fccz octet diamond kelvin rhombic reentrant"

echo "==> list"                     ; "$BIN" list                 | tee "$HERE/lattices.txt"

# S1 self-check (one unit cell, mesh vs analytic strut volume).
{ for l in $LATS; do "$BIN" selfcheck "$l"; echo; done; } | tee "$HERE/s1_selfcheck.txt"

# Reference region (7^3 @ 8 mm) — in-memory AND streaming rows into one CSV.
CSV="$HERE/reference_region.csv"; rm -f "$CSV"
LAT_CSV="$CSV" bash -c 'true'
for l in $LATS; do LAT_CSV="$CSV" "$BIN" case "$l" 8 0 0; done   # in-memory
for l in $LATS; do LAT_CSV="$CSV" "$BIN" case "$l" 8 1 0; done   # streaming
echo "wrote $CSV"

# Printability: strut angle from vertical + horizontal (90 deg) count.
{ for l in $LATS; do "$BIN" angles "$l" 8; echo; done; } | tee "$HERE/angles.txt"

# Relative density mapping at r/L = 0.10 (r = 0.8 mm @ 8 mm cell).
{ for l in $LATS; do "$BIN" density "$l" 8 0.8; echo; done; } | tee "$HERE/density.txt"

# Union character (weld / manifold / self-intersection scan) — same as octet.
{ for l in $LATS; do "$BIN" watertight "$l" 8; echo; done; } | tee "$HERE/union_character.txt"

# S3 streaming: peak RSS flat vs block size, every topology.
{ for l in $LATS; do "$BIN" streamscan "$l"; echo; done; } | tee "$HERE/s3_streamscan.txt"

# S2 determinism: same inputs twice -> byte-identical file.
{
  echo "S2 DETERMINISM — md5 of each 40 mm STL over two independent runs"
  for l in $LATS; do
    "$BIN" block "$l" "$FILES" >/dev/null; a=$(md5 -q "$FILES/${l}_40mm.stl")
    "$BIN" block "$l" "$FILES" >/dev/null; b=$(md5 -q "$FILES/${l}_40mm.stl")
    printf "  %-10s %s %s\n" "$l" "$a" "$([ "$a" = "$b" ] && echo BYTE-IDENTICAL || echo DIFFER)"
  done
} | tee "$HERE/s2_determinism.txt"

# S4: the 40 mm blocks themselves (STL + 3MF) into files/, plus a geometry line.
{ for l in $LATS; do "$BIN" block "$l" "$FILES"; done; } | tee "$HERE/blocks.txt"

# Weaire-Phelan verdict.
"$BIN" wp | tee "$HERE/weaire_phelan.txt"

echo "== done =="
ls -la "$FILES"
