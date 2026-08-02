#!/bin/zsh
# Evidence harness — task 2026-08-03-selfweight-clearance-void-crash.
#
#   $1  path to the topopt-cli binary to exercise
#   $2  output root
#
# All jobs run on the committed plate_bore.stl fixture. The first four are the
# BYTE-IDENTITY bars (nothing about them may move); the rest are the defect and
# the four callers that have to reach the same load case.
#
#   A   no design box + lattice, self-weight, NO clearance     — identity bar
#   B   design box, no lattice, self-weight, NO clearance      — identity bar
#   C   design box + 4 keep-clears + DECLARED LOAD + lattice   — identity bar
#       (a declared load case takes precedence over self-weight, so the fix
#        cannot reach it — this is the bar that says so)
#   D   design box + self-weight + lattice, NO clearance       — identity bar
#   Y   NO box + 4 keep-clears + self-weight                   — identity bar
#       (the control for "this cannot happen without a design box")
#
#   X   design box + 4 keep-clears + self-weight               — THE DEFECT
#   Z   X + a lattice block            — run_job's latticed certification
#   ZV  lattice_variant on Z's design  — the re-lattice caller
#   ZA  analyze on Z's exported mesh   — the fixed-design caller
set -e
CLI="$1"; OUT="$2"; J="$(dirname "$0")/jobs"
mkdir -p "$OUT"

for j in A_nobox_lattice B_box_nolattice C_box_keepclear_lattice \
         D_box_selfweight_lattice Y_nobox_clearance_selfweight \
         X_preexisting_selfweight_clearance_crash \
         Z_box_clearance_selfweight_lattice; do
  echo "=== run $j ==="
  "$CLI" run "$J/$j.json" --out "$OUT/$j" 2>&1 | tail -3 || echo "REFUSED/FAILED: $j"
done

echo "=== lattice-variant ZV (on Z's design.bin) ==="
if [ -f "$OUT/Z_box_clearance_selfweight_lattice/design.bin" ]; then
  # Written INTO the jobs dir so "model": "plate_bore.stl" still resolves beside it.
  python3 - "$J/ZV_lattice_variant_clearance.json" \
    "$(cd "$OUT/Z_box_clearance_selfweight_lattice" && pwd)/design.bin" \
    > "$J/.ZV_resolved.json" <<'PYEOF'
import json,sys
j=json.load(open(sys.argv[1])); j['variant']['design']=sys.argv[2]
print(json.dumps(j,indent=2))
PYEOF
  "$CLI" lattice-variant "$J/.ZV_resolved.json" --out "$OUT/ZV_lattice_variant" 2>&1 | tail -3 \
    || echo "REFUSED/FAILED: ZV"
  rm -f "$J/.ZV_resolved.json"
else
  echo "SKIPPED ZV: Z produced no design.bin (Z itself refused)"
fi

echo "=== analyze ZA (self-weight form, on Z's variant mesh) ==="
ZMESH="$(find "$OUT/Z_box_clearance_selfweight_lattice" -name "variant_*.stl" ! -name "*_lattice.stl" 2>/dev/null | sort | head -1)"
if [ -n "$ZMESH" ]; then
  "$CLI" analyze "$J/ZA_analyze_on_Z_mesh.json" --mesh "$ZMESH" \
    --out "$OUT/ZA_analyze_on_Z_mesh" 2>&1 | tail -3 || echo "REFUSED/FAILED: ZA"
else
  echo "SKIPPED ZA: Z produced no variant mesh (Z itself refused)"
fi

echo "=== analyze ZQ (loadcase form, anchors + ZERO force groups) ==="
# NOT this task's defect. It refuses identically on both binaries and it refuses
# with the clearances REMOVED too, so it is a SEPARATE pre-existing defect in
# analyze_job's loadcase-with-no-groups path. Recorded so the claim is checkable.
# Run WITHOUT --mesh deliberately: Z refuses on the pre-fix binary, so a
# --mesh form would hand the two binaries DIFFERENT arguments and the comparison
# would be meaningless. No-mesh is identical input for both.
"$CLI" analyze "$J/ZQ_analyze_loadcase_no_groups.json" \
  --out "$OUT/ZQ_analyze_loadcase_no_groups" 2>&1 | tail -2 || echo "REFUSED/FAILED: ZQ"
