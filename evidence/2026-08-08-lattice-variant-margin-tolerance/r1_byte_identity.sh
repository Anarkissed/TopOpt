#!/usr/bin/env bash
# R1 — BYTE-IDENTICAL WHERE NOTHING CHANGED, by stash-rebuild checksum.
#
# Two binaries: `base` built from the merge base 966ffa6, `head` built from this
# working tree, on the same fixture and the same job.
#
# *** WITH THE CONTROL THAT MAKES IT MEAN ANYTHING. *** Some artifacts carry a
# WALL CLOCK (`created_wall_ms`, `preflight_ms`, `sweep_seconds`, and every `_ms`
# / RSS column of iterations.csv) and so are not reproducible between two runs of
# the SAME binary. So this runs `base` TWICE first and records exactly which files
# differ base-vs-base. Those are the clock-carrying set; everything OUTSIDE it must
# be byte-identical head-vs-base, and every file inside it is re-compared with the
# clock fields stripped.
#
#   A  a plain minimize_plastic run, NO lattice block
#   B  a lattice run  -> everything identical except the per-variant lattice
#                        receipt, whose only diff is the three keys this task adds
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/base-build/topopt-cli"
HEAD="/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-variant-margin-tolerance-f0902f/build/topopt-cli"
FIX="/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-variant-margin-tolerance-f0902f/core/tests/fixtures/mesh"
W="$HERE/r1"
rm -rf "$W"; mkdir -p "$W"
cd "$W"
cp "$FIX/plate_bore.stl" .

echo "== GUARD: the two binaries must actually differ =="
echo "  base  $(shasum -a 256 "$BASE" | cut -c1-32)  $(stat -f %z "$BASE") bytes"
echo "  head  $(shasum -a 256 "$HEAD" | cut -c1-32)  $(stat -f %z "$HEAD") bytes"
if cmp -s "$BASE" "$HEAD"; then
  echo "  *** GUARD FAILED: the binaries are identical — this bar would pass vacuously ***"
  exit 1
fi
echo "  binaries DIFFER — the comparison below is real"
echo

cat > A_nolattice.json <<'EOF'
{"mode":"minimize_plastic","model":"plate_bore.stl","material":"PLA","resolution":48,
 "fixture_faces":[{"kind":"cylindrical","radius_mm":3.0}],
 "gravity":{"direction":[0.0,0.0,-1.0],"magnitude_mm_s2":9810.0},
 "ladder":[0.68,0.52,0.38,0.26],"margin_stop":0.0,"simp":{"max_iterations":30},
 "output":{"report":"report.json","mesh_format":"stl","mesh_prefix":"variant"}}
EOF
cat > B_lattice.json <<'EOF'
{"mode":"minimize_plastic","model":"plate_bore.stl","material":"PLA","resolution":48,
 "fixture_faces":[{"kind":"cylindrical","radius_mm":3.0}],
 "gravity":{"direction":[0.0,0.0,-1.0],"magnitude_mm_s2":9810.0},
 "ladder":[0.68,0.52,0.38,0.26],"margin_stop":0.0,"simp":{"max_iterations":30},
 "output":{"report":"report.json","mesh_format":"stl","mesh_prefix":"variant"},
 "lattice":{"topology":"octet","cell_mm":3.0,"strut_radius_mm":0.45,"emit_stl":true}}
EOF

# Strip every clock-bearing field so a clock-carrying file can still be compared
# on its CONTENT. iterations.csv: keep the physics columns (rung, iter,
# compliance, achieved_vf, plateau, cg_iters, cg_multigrid, beta, hier_built,
# mg_cycles_attempted, infeasible, recycle_dim, active_fraction, fea_solves,
# matvecs, geneo_*) and drop wall_ms, every *_ms and every memory column.
declink() {
  local f="$1"
  case "$f" in
    iterations.csv)
      python3 - "$2" <<'PY'
import csv,sys
rows=list(csv.reader(open(sys.argv[1])))
hdr=rows[0]
drop={i for i,h in enumerate(hdr)
      if h.endswith('_ms') or h=='wall_ms' or h.endswith('_mb')
      or h in ('major_faults','swapins')}
for r in rows:
    print(','.join(v for i,v in enumerate(r) if i not in drop))
PY
      ;;
    *)
      sed -E 's/"(created_wall_ms|preflight_ms|sweep_seconds|strut_axis_measure_seconds|gen_seconds|gen_fraction|wall_seconds|[a-z_]*_ms|[a-z_]*_seconds)": [-0-9.e+]*/"\1": CLOCK/g' "$2"
      ;;
  esac
}

compare() {   # $1 = job, $2 = label, $3.. = filename globs allowed to differ
  local job="$1" label="$2"; shift 2
  local -a allowed=("$@")
  "$BASE" run "$job" --out "${label}_base"  > "${label}_base.log"  2>&1
  "$BASE" run "$job" --out "${label}_base2" > "${label}_base2.log" 2>&1
  "$HEAD" run "$job" --out "${label}_head"  > "${label}_head.log"  2>&1

  echo "== $label =="
  # The control: which files differ between two runs of the SAME (base) binary.
  local clocky=""
  for f in $(cd "${label}_base" && ls); do
    cmp -s "${label}_base/$f" "${label}_base2/$f" || clocky="$clocky $f"
  done
  echo "  CONTROL — files that differ base-vs-base (same binary, so clock only):"
  echo "   ${clocky:-  (none)}"

  local same=0 clockonly=0 expected=0 unexpected=0
  for f in $(cd "${label}_base" && ls); do
    if cmp -s "${label}_base/$f" "${label}_head/$f"; then same=$((same+1)); continue; fi
    local ok=0
    for a in "${allowed[@]:-}"; do [[ "$f" == $a ]] && ok=1; done
    if [[ $ok == 1 ]]; then
      expected=$((expected+1))
      echo "  DIFFERS (EXPECTED — this task's added keys): $f"
      diff -u "${label}_base/$f" "${label}_head/$f" | sed -n '4,30p' | sed 's/^/      /'
      continue
    fi
    if [[ " $clocky " == *" $f "* ]]; then
      # A clock-carrying file. Compare it again with the clocks stripped.
      declink "$f" "${label}_base/$f" > /tmp/r1a.$$
      declink "$f" "${label}_head/$f" > /tmp/r1b.$$
      if cmp -s /tmp/r1a.$$ /tmp/r1b.$$; then
        clockonly=$((clockonly+1))
        echo "  IDENTICAL once the clock is stripped: $f"
      else
        unexpected=$((unexpected+1))
        echo "  *** DIFFERS BEYOND THE CLOCK: $f ***"
        diff -u /tmp/r1a.$$ /tmp/r1b.$$ | head -20 | sed 's/^/      /'
      fi
      rm -f /tmp/r1a.$$ /tmp/r1b.$$
      continue
    fi
    unexpected=$((unexpected+1))
    echo "  *** DIFFERS (UNEXPECTED): $f ***"
    diff -u "${label}_base/$f" "${label}_head/$f" | head -20 | sed 's/^/      /'
  done
  echo "  byte-identical: $same   clock-only: $clockonly   expected: $expected   UNEXPECTED: $unexpected"
  echo
}

compare A_nolattice.json A          # nothing may differ beyond the clock
compare B_lattice.json  B 'variant_*_lattice.report.json'
