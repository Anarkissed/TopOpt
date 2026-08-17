#!/bin/sh
# §2(b) — DOES A SMALLER BASIS DEFLATE WORSE? The WARM tail, per tiling.
#
# ★ WHY THIS IS NOT ANSWERED BY THE TRIAGE. The triage's rung-0 solve is a COLD
# BUILD: it burns 500 plain, builds the basis, and deflates to convergence. Its
# tail (cg - 500) is a real deflation-quality number, but it is the COLD one.
# What production actually spends its time on is the WARM path — a held basis,
# REFRESHED against moved moduli, deflating from iteration 0. His run's cold
# build tail was 427 while its warm refreshed tails were 11-889, median 170:
# the two differ by 2.5x, so reading the warm economics off the cold number
# would be reading the wrong leg.
#
# ★ HOW IT IS FORCED, CHEAPLY. `--arm thr=0` sets GeneoProbeConfig::engage_
# threshold = 0 — the harness-only override the disarm task added precisely so a
# test can pin BOTH gate branches on one fixture. With it, every solve that holds
# a basis ENGAGES instead of declining, so a 4-rung `--iters 1` ladder yields
# three warm refreshed solves per tiling for the price of one triage point.
# Combined with `--arm core=N` (the two accumulate into one Arm; `main`'s flag
# loop calls parse_arm repeatedly on the same struct), it gives the warm tail at
# a chosen tiling.
#
# ★ A LABELLING TRAP IN THE HARNESS, NAMED SO NOBODY MISREADS THE LOGS.
# `parse_arm` sets `a.name = spec` on EVERY call but assigns only its own field,
# so `--arm core=16 --arm thr=0` correctly applies BOTH overrides while printing
# `ARM thr=0` — the core setting is active but invisible in the label. The
# parser below therefore reads `geneo_dim` out of the CSV rather than trusting
# any label, and the `N_t=` it prints is what the run actually built. If a row's
# N_t does not match the same core's row in `nt_triage/`, the override did not
# take and the row must be thrown away, not explained.
#
# ★ IT MEASURES, IT DOES NOT PROPOSE. Opening the gate is NOT a posture anyone
# should ship — `2026-08-02-geneo-standing-probe` measured that arming every
# solve LOSES 1.25x on wall at the shipped tiling, which is exactly why the
# ski-rental gate exists. This probe opens it only to isolate the deflation
# QUALITY term from the gate POLICY term, so the two can be reported separately
# instead of confounded in one total.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

OUT="$HERE/engaged"
WORK=${WORK:-"${TMPDIR:-/tmp}/geneo_engaged"}
THREADS=${THREADS:-6}
mkdir -p "$OUT" "$WORK"

# ★ 8, 12, 16 AND IN THAT ORDER, AND THE ORDER IS DELIBERATE. 8 is the control
# (his shipped tiling, where the warm tail is independently known from his own
# decision log — median 170 — so the probe can be checked against a number it
# did not produce). 12 is next because MODEL B's headline result rests on the
# measured N_t = 718 there. 16 last. If the machine only affords two points, the
# two that matter are 8 and 12.
for c in ${CORES:-8 12 16}; do
  if [ -s "$OUT/core$c.txt" ] && ! grep -q "NOT MEASURED" "$OUT/core$c.txt"; then
    echo "core=$c already present, skipping"
    continue
  fi
  rm -rf "$WORK/eng$c"
  echo "=== engaged core=$c starting $(date '+%H:%M:%S') ==="
  ./build/solver_arm_sweep "$HERE/job/job.json" "$WORK/eng$c" \
      --arm "core=$c" --arm thr=0 --threads "$THREADS" --iters 1 \
      > "$OUT/core$c.log" 2>&1 || true
  python3 - "$WORK/eng$c/iterations.csv" "$c" > "$OUT/core$c.txt" <<'PY'
import csv, sys, statistics
path, core = sys.argv[1], sys.argv[2]
try:
    r = list(csv.DictReader(open(path)))
except Exception as e:
    print(f"core={core}  NOT MEASURED ({e.__class__.__name__})")
    raise SystemExit(0)
# action 2 == REFRESHED a held basis against this system and deflated. That is
# the warm leg. action 3 is the cold build and is reported separately, never
# averaged in with the warm ones — they are different quantities.
warm = [x for x in r if int(x["geneo_action"]) == 2]
cold = [x for x in r if int(x["geneo_action"]) == 3]
if not warm:
    print(f"core={core}  NOT MEASURED — no REFRESHED solve (action 2) in this "
          f"run. The gate override did not take, or the run did not reach a "
          f"second solve. This row is the ABSENCE of a measurement.")
    raise SystemExit(0)
# On an engaged solve the deflation runs from iteration 0, so the whole
# iteration count IS the deflated count; geneo_burn is 0 or near it.
tails = [int(x["cg_iters"]) - int(x["geneo_burn"]) for x in warm]
nt = int(warm[0]["geneo_dim"])
coldtail = (int(cold[0]["cg_iters"]) - int(cold[0]["geneo_burn"])) if cold else -1
print(f"core={core}  N_t={nt}  warm_solves={len(tails)}  "
      f"warm_tails={sorted(tails)}  median_warm_tail={statistics.median(tails):.0f}  "
      f"cold_build_tail={coldtail}")
PY
  cat "$OUT/core$c.txt"
done
