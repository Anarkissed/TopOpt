#!/bin/sh
# ★ THE NIGHT QUEUE, WITH FAILURE DETECTION ON EVERY ARM.
#
# ★ NO `timeout` ANYWHERE — it does not exist on this host (checked: neither
# `timeout` nor `gtimeout`), and using it silently returned exit 127 and ran
# nothing at all on the first smoke attempt.
#
# ★ EVERY ARM IS VERIFIED THREE WAYS and a failure NEVER stops the queue:
#   1. the process exit code
#   2. `summary.txt` exists (the probe writes it only on a complete run)
#   3. the log contains at least one iteration and no FATAL
# A failing arm writes FAIL to STATUS and the queue CONTINUES, so one bad arm
# does not cost the whole night.
#
# ★ 6 THREADS, CONSTANT ACROSS EVERY ARM. The maintainer is asleep and asked for
# the machine; holding it constant is what keeps the arms comparable to each
# other, and the wall clocks are not compared to any other task's.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BAKE="$REPO/evidence/2026-08-09-reference-implementation-bakeoff"
cd "$REPO"
STEP="$BAKE/M2_verticalStand.step"
REF="$BAKE/s2_simp_baseline/design.bin"
MATS="core/src/materials/materials.json"
ST="$HERE/STATUS"
: > "$ST"
say() { echo "$(date '+%H:%M:%S') $*" >> "$ST"; }

BASE="--rung 0.68 --iters 60 --threads 6 --snapshot-every 10 --plsm-export 1 \
--plsm-export 2 --plsm-mma --plsm-basis gaussian --plsm-knots 2,2,2 \
--plsm-support 2 --hj-steps 24 --volume-count --plsm-refit-every 5 --eta 1 \
--certify-every 10 --certify-from 30 --no-compliance-stop"

run() {
  name=$1; shift
  if [ -f "$HERE/arms/$name/summary.txt" ]; then say "SKIP $name (present)"; return 0; fi
  say "START $name"
  mkdir -p "$HERE/arms/$name"
  ./build/levelset_probe "$STEP" "$MATS" "$REF" "$HERE/arms/$name" $BASE "$@" \
      > "$HERE/arms/$name.log" 2>&1
  rc=$?
  its=$(grep -c '^it ' "$HERE/arms/$name.log" 2>/dev/null || echo 0)
  if [ $rc -ne 0 ]; then say "★ FAIL $name exit=$rc after $its iterations"; return 0; fi
  if [ ! -f "$HERE/arms/$name/summary.txt" ]; then
    say "★ FAIL $name no summary.txt after $its iterations"; return 0; fi
  if [ "$its" -lt 1 ]; then say "★ FAIL $name zero iterations"; return 0; fi
  if grep -q "FATAL" "$HERE/arms/$name.log"; then
    say "★ FAIL $name FATAL in log"; return 0; fi
  say "OK $name $its iterations"
}

# ── priority order is the addendum's: Seed A monotone is the core result, then
# the stress-aligned seed, then TPMS, then the cosine richness sweep. One
# finished arm with its curves beats four unfinished ones.
run MN_nucleating                          --seed holes --seed-period 8
run MA_holes8   --monotone                 --seed holes --seed-period 8
run MC_stress   --monotone                 --seed stress
run MB_gyr12    --monotone --seed gyroid   --seed-period 12
run MB_gyr20    --monotone --seed gyroid   --seed-period 20
run MA_poor12   --monotone --seed holes    --seed-period 12
run MA_rich6    --monotone --seed holes    --seed-period 6
run MA_phase    --monotone --seed holes    --seed-period 8 --seed-phase 0.5
say "QUEUE_DONE"
