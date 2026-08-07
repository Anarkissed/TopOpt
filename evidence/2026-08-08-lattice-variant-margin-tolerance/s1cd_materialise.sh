#!/usr/bin/env bash
# S1(c) green + S1(d): materialise every rung of the maintainer's own run on
# demand, from {job document, design.bin} only, and compare each result with the
# file the eager optimize run wrote.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI=/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-variant-margin-tolerance-f0902f/build/topopt-cli
ORIG=/Users/nadim/.topopt-worker/ca62f91cba4b422d/out
cd "$HERE"
for vf in 0.68 0.52 0.38 0.26; do
  tag=$(python3 -c "print('%03d' % round(float('$vf')*100))")
  out="m_$vf"
  rm -rf "$out"
  echo "=== vf=$vf (variant_${tag}) ==="
  s=$(python3 -c 'import time;print(time.time())')
  "$CLI" lattice-variant "j_$vf.json" --out "$out" > "log_$vf.txt" 2>&1
  rc=$?
  e=$(python3 -c "import time;print('%.2f' % (time.time()-$s))")
  echo "  exit=$rc  wall=${e}s"
  grep -E "^(wall|mesh|lattice):" "log_$vf.txt" | sed 's/^/  /'
  mine="$out/variant_${tag}_lattice.stl"
  theirs="$ORIG/variant_${tag}_lattice.stl"
  if [[ -f "$mine" ]]; then
    echo "  on-demand: $(stat -f %z "$mine") bytes"
    echo "  eager    : $(stat -f %z "$theirs") bytes"
    if cmp -s "$mine" "$theirs"; then echo "  BYTE-IDENTICAL to the run's own file"
    else echo "  DIFFERS from the run's own file"
         echo "    sha on-demand $(shasum -a 256 "$mine" | cut -c1-16)"
         echo "    sha eager     $(shasum -a 256 "$theirs" | cut -c1-16)"; fi
    python3 - "$out/variant_${tag}_lattice.report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for k in ("solid_margin_worst_case","solid_margin_reproduced",
          "solid_reconstruction_exact","solid_reconstruction_relative_delta",
          "solid_reconstruction_band","solid_reconstruction_reproduces",
          "lattice_margin_worst_case","lattice_accepted","lattice_mass_grams"):
    if k in r: print("  receipt %-38s %s" % (k, r[k]))
PY
    python3 - "$out/lattice_variant_provenance.json" <<'PY'
import json,sys,os
p=sys.argv[1]
if os.path.exists(p):
    r=json.load(open(p)).get("reproduction",{})
    print("  provenance reproduction:", json.dumps(r))
PY
  else
    tail -3 "log_$vf.txt" | sed 's/^/  /'
  fi
  du -sh "$out" 2>/dev/null | sed 's/^/  dir: /'
  rm -f "$mine"      # 5.17 GB of triangles; the point is that they are re-derivable
done
