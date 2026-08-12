#!/bin/sh
# §1(b) TRIAGE — what is N_t actually, at each subdomain tiling?
#
# ★ ONE SOLVE PER POINT, because N_t is decided on the FIRST solve. The GenEO
# basis is built once per structure (geneo.cpp's trigger policy) and `N_t` is a
# property of that build — the tiling, the block size and the eigenvalue cut —
# not of how long the ladder runs. So the number that decides whether a smaller
# basis is even worth a full arm costs one design iteration per rung, not four
# hundred. `run_info.geneo_basis_dim` is the answer.
#
# ★ WHY THE TILING AND NOT THE EIGENVALUE CUT. `2026-08-02-geneo-standing-probe`
# W3 swept `lambda_cut` over 50x (0.002 -> 0.100) and moved N_t by **0.7 %** and
# the iteration count by nothing. Its W4 tiling sweep moved N_t 313 -> 47 going
# from 8^3 to 16^3 cores. The cut is inert; the tiling is the lever. That is why
# this script sweeps cores and the handoff re-tests the cut's inertness rather
# than assuming it.
#
# ★ AND WHY THE SWEEP GOES UP, NOT DOWN. 4^3 cores was attempted and ABANDONED:
# it puts ~7,300 subdomains on his grid and its LOBPCG eigensolve had not
# finished a single solve after 25 minutes. That is the wrong direction anyway —
# smaller cores mean MORE subdomains and a LARGER N_t, and N_t is the term this
# whole section is trying to shrink. It is recorded here rather than dropped so
# the next reader does not spend the same 25 minutes.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

OUT="$HERE/nt_triage"
WORK=${WORK:-"${TMPDIR:-/tmp}/nt_triage"}
THREADS=${THREADS:-6}
mkdir -p "$OUT" "$WORK"

# 8 is the SHIPPED tiling (kGeneoCoreCells) and is included as the control, so
# the table's own first row is the number his run reports and the comparison is
# not against a remembered value.
for c in ${CORES:-8 16 32}; do
  if [ -s "$OUT/core$c.txt" ]; then
    echo "core=$c already present, skipping"
    continue
  fi
  rm -rf "$WORK/nt$c"
  ./build/solver_arm_sweep "$HERE/arms/job/job.json" "$WORK/nt$c" \
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
# The threshold the engagement gate would compute, from the SAME cost model the
# solver uses (geneo.cpp:897): 2*N_t + engaged_burn + 2*engaged_tail. The two
# measured legs are held at his run's values so the ONLY thing moving between
# rows is N_t — which is the point of the sweep.
burn, tail = 500, 427
print(f"core={core}  N_t={nt}  basis_MB={d['geneo_basis_mb']:.2f}  "
      f"refresh(2*N_t)={2*nt}  implied_threshold={2*nt + burn + 2*tail}  "
      f"builds={d['geneo_basis_builds']}  armed={d['geneo_armed_solves']}  "
      f"declined={d['geneo_declined_solves']}")
PY
  cat "$OUT/core$c.txt"
done
