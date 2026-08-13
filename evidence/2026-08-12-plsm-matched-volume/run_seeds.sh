#!/bin/sh
# ★ THE SEED EXPERIMENTS, at the matched volume, in priority order.
#
# W1-W3  ★ THE COARSE-PERIOD SWEEP — the strongest prediction available and it
#        needs no new code. At a fixed void fraction, N spheres each hold V/N,
#        so radius ~ (V/N)^(1/3) and TOTAL INTERFACIAL AREA ~ N^(1/3). Divide
#        the hole count by eight and the interior surface HALVES. Production
#        seeds at period 8, which is 882 blobs at this rung; the geometric
#        ceiling is the part's 31-voxel thin axis, so ~24-30 is the wall.
#        ★ The block-copolymer phase sequence says the sphere phase is correct
#        below ~25% minority, and the void here is 20% — so coarsening stays
#        IN the right morphology instead of changing it, which is what the
#        gyroid did wrong.
#        ★ The known cost is compliance (the level-set literature is explicit
#        that fewer initial holes gives worse compliance) and the matched-volume
#        run is what licenses paying it: all four arms certified within 0.2%.
#
# W4-W5  --renucleate, the literature's answer to the level set's inability to
#        open holes in solid material. W5 is the interesting one: a COARSE seed
#        for low surface plus nucleation to recover the compliance it gives up.
#
# W6     rods. ★ PREDICTED TO LOSE ON SURFACE — cylinders are the ~30% phase and
#        the void here is 20% — and to win on drainage, since a rod reaching a
#        face drains by construction and 14.5% of the control's void is sealed.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"; cd "$REPO"
B="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"; ST="$HERE/STATUS"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }
BASE="--rung 0.7973 --iters 60 --threads 6 --snapshot-every 10 \
--plsm-export 1 --plsm-export 2 --plsm-mma --plsm-basis gaussian \
--plsm-knots 2,2,2 --plsm-support 2 --hj-steps 24 --volume-count \
--plsm-refit-every 5 --eta 1 --no-compliance-stop"
run() {
  name=$1; shift
  [ -f "$HERE/arms/$name/summary.txt" ] && { say "SKIP $name"; return 0; }
  say "START $name"; mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$B/M2_verticalStand.step" core/src/materials/materials.json \
      "$B/s2_simp_baseline/design.bin" "$HERE/arms/$name" $BASE "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?; its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  [ $rc -ne 0 ] && { say "★ FAIL $name exit=$rc after $its"; return 0; }
  [ -f "$HERE/arms/$name/summary.txt" ] || { say "★ FAIL $name no summary"; return 0; }
  grep -q FATAL "$HERE/arms/$name.log" && { say "★ FAIL $name FATAL"; return 0; }
  # content check, not just liveness
  pv=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="printed_voxels") k=i; next} END{print $k}' \
        "$HERE/arms/$name/iterations.csv")
  b0=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="void_components") k=i; next} {print $k}' \
        "$HERE/arms/$name/iterations.csv" | sort -u | wc -l | tr -d ' ')
  [ "$b0" -le 1 ] && say "★ FAIL $name void_components CONSTANT — measuring nothing"
  say "OK $name $its it, printed=$pv (target 88424), b0 distinct=$b0"
}
run W1_p16      --seed holes --seed-period 16
run W2_p24      --seed holes --seed-period 24
run W3_p32      --seed holes --seed-period 32
run W4_renuc    --seed holes --seed-period 8  --renucleate 10 --renucleate-frac 0.02
run W5_p24renuc --seed holes --seed-period 24 --renucleate 10 --renucleate-frac 0.02
run W6_rods12   --seed rods  --seed-period 12 --seed-axis y
say "SEEDS_DONE"
