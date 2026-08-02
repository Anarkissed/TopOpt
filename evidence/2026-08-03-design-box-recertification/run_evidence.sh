#!/bin/zsh
# Evidence harness — task 2026-08-03-design-box-recertification.
#
#   $1  path to the topopt-cli binary to exercise
#   $2  output root
#
# Jobs (jobs/*.json), all on the committed plate_bore.stl fixture:
#   A  no design box + lattice          — the EXISTING path (byte-identity bar)
#   B  design box, no lattice           — the EXISTING path (byte-identity bar)
#   C  design box + 4 keep-clears + declared load + lattice — the maintainer's shape
#   D  design box + self-weight + lattice — the added-material specimen
#   E  lattice_variant on D's design.bin  — re-lattice a stored design-box variant
#   F  analyze --smooth on D's variant    — the smoothing re-certification (AI5)
set -e
CLI="$1"; OUT="$2"; J="$(dirname "$0")/jobs"
mkdir -p "$OUT"
for j in A_nobox_lattice B_box_nolattice C_box_keepclear_lattice D_box_selfweight_lattice; do
  echo "=== run $j ==="
  "$CLI" run "$J/$j.json" --out "$OUT/$j" 2>&1 | tail -2 || echo "REFUSED/FAILED: $j"
done
echo "=== lattice-variant E (on D's design.bin) ==="
# Written INTO the jobs dir so "model": "plate_bore.stl" still resolves beside it.
python3 - "$J/E_box_lattice_variant.json" "$(cd "$OUT/D_box_selfweight_lattice" && pwd)/design.bin" > "$J/.E_resolved.json" <<'PYEOF'
import json,sys
j=json.load(open(sys.argv[1])); j['variant']['design']=sys.argv[2]
print(json.dumps(j,indent=2))
PYEOF
"$CLI" lattice-variant "$J/.E_resolved.json" --out "$OUT/E_lattice_variant" 2>&1 | tail -3 || echo "REFUSED/FAILED: E"
rm -f "$J/.E_resolved.json"
echo "=== analyze --smooth F (on D's variant_080.stl) ==="
"$CLI" analyze "$J/F_box_analyze_smooth.json" \
  --mesh "$OUT/D_box_selfweight_lattice/variant_080.stl" --smooth 0.4 \
  --out "$OUT/F_analyze_smooth" 2>&1 | tail -4 || echo "REFUSED/FAILED: F"
