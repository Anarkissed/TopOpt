#!/bin/sh
# §1(a) THE SWEEP, FIRST HALF — what is N_t at each subdomain tiling?
#
# ★ ONE SOLVE PER POINT, because N_t is decided on the FIRST solve. The GenEO
# basis is built once per structure (geneo.cpp's trigger policy) and N_t is a
# property of that build — the tiling, the block size and the eigenvalue cut —
# not of how long the ladder runs. `run_info.geneo_basis_dim` is the answer.
#
# This is PR 329's `run_nt_triage.sh` re-run on a machine that is not starving
# it, with two points ADDED. 329 swept `8 16 32` and got only the 8; this sweeps
# 8/12/16/24 because §1(a) asks for the prior sweep's range AND beyond it, and
# because 12 and 24 are what turn two points into a CURVE. A two-point sweep
# cannot distinguish "N_t falls like the subdomain count" from "N_t falls and
# then flattens as block_m saturates", and that distinction is exactly §2(b).
#
# ★ WHY 24 AND NOT 32. On his 128x31x118 grid a 32-core tiling puts the ENTIRE
# thin axis (31 voxels) in ONE tile, so y stops being tiled at all and the sweep
# would confound "coarser tiling" with "no tiling in y". 24 keeps y at 2 tiles
# and is the last point that still tiles every axis. 32 is run anyway, LAST and
# only if time allows, and is labelled for that confound rather than averaged in.
#
# ★ WHY THE TILING AND NOT THE EIGENVALUE CUT. `2026-08-02-geneo-standing-probe`
# W3 swept `lambda_cut` over 50x (0.002 -> 0.100) and moved N_t by 0.7% and the
# iteration count by nothing. Its W4 tiling sweep moved N_t 313 -> 47 going 8^3
# -> 16^3. The cut is inert; the tiling is the lever.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

OUT="$HERE/nt_triage"
WORK=${WORK:-"${TMPDIR:-/tmp}/geneo_tiling_nt"}
THREADS=${THREADS:-6}
mkdir -p "$OUT" "$WORK"

# 8 is the SHIPPED tiling (kGeneoCoreCells) and is the control, so the table's
# first row is the number his run reports rather than a remembered value.
for c in ${CORES:-8 12 16 24}; do
  # ★ -s is not enough: a "NOT MEASURED" row is non-empty and must NOT count as
  # done, or a killed run blocks its own retry forever.
  if [ -s "$OUT/core$c.txt" ] && ! grep -q "NOT MEASURED" "$OUT/core$c.txt"; then
    echo "core=$c already present, skipping"
    continue
  fi
  rm -rf "$WORK/nt$c"
  echo "=== core=$c starting $(date '+%H:%M:%S') ==="
  ./build/solver_arm_sweep "$HERE/job/job.json" "$WORK/nt$c" \
      --arm "core=$c" --threads "$THREADS" --iters 1 > "$OUT/core$c.log" 2>&1 || true
  python3 - "$WORK/nt$c/run_info.json" "$c" > "$OUT/core$c.txt" <<'PY'
import json, sys
path, core = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"core={core}  NOT MEASURED ({e.__class__.__name__})")
    raise SystemExit(0)
nt = d["geneo_basis_dim"]
# ★ N_t == 0 MEANS NO BASIS WAS EVER BUILT — it is not a measurement of zero, and
# it must never be fed into the cost model. PR 329's script carries the same
# guard for the same reason: an earlier version printed
# "N_t=0 ... implied_threshold=1354" on a run killed mid-eigensolve, which is a
# fabricated answer to the very question the sweep exists to ask.
if nt <= 0:
    print(f"core={core}  NOT MEASURED — the basis was never built "
          f"(geneo_basis_dim = 0). This row is the ABSENCE of a measurement, "
          f"not a measurement of zero; no threshold is derivable from it.")
    raise SystemExit(0)
# The threshold the engagement gate would compute, from the SAME cost model the
# solver uses (geneo.cpp): 2*N_t + engaged_burn + 2*engaged_tail. The two
# measured legs are held at HIS run's values (500, 427) so the ONLY thing moving
# between rows is N_t — which is the point of the sweep. The gate's OWN
# per-solve threshold, computed from this run's own legs, is read from the
# decision log by tables.py and is the number §1(b) reports.
burn, tail = 500, 427
print(f"core={core}  N_t={nt}  basis_MB={d['geneo_basis_mb']:.2f}  "
      f"refresh(2*N_t)={2*nt}  implied_threshold={2*nt + burn + 2*tail}  "
      f"builds={d['geneo_basis_builds']}  armed={d['geneo_armed_solves']}  "
      f"declined={d['geneo_declined_solves']}")
PY
  cat "$OUT/core$c.txt"
done
