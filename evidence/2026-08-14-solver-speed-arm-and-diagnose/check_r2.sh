#!/bin/sh
# R2 — THE HARNESS IS INERT. The `base` arm applies no posture at all, so it must
# produce the SAME design as the shipped `topopt-cli run` on the same job. If it
# does not, every other arm in the table is being compared against a moved
# baseline and nothing below it means anything.
#
# ★ AND THE GUARD FIRST. [[make-topopt-cli-silently-noops]]: `--target
# topopt-cli` is the OUTPUT FILE, not the target, and make calls it up to date
# without building — three tasks have hashed one stale binary against itself and
# called it byte-identity. So this asserts the two binaries EXIST and were built
# from the same tree in one go, and prints their hashes, before comparing a
# single artifact.
#
# The two must be driven with the same iteration cap. `topopt-cli run` has no
# flag for it (`simp.max_iterations` is dropped on the floor for a load-case
# job — main.cpp says so in as many words), so the cap goes in the job's own
# `plsm.max_iterations` block, which BOTH paths read.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

ITERS=${ITERS:-2}
THREADS=${THREADS:-6}
OUT=${OUT:-"$HERE/r2"}
rm -rf "$OUT"; mkdir -p "$OUT"

# ── ONE BUILD, BOTH BINARIES, from this working tree.
cmake --build build -j8 --target topopt_cli solver_arm_sweep > "$OUT/build.log" 2>&1
[ -x build/topopt-cli ] || { echo "R2 INVALID: build/topopt-cli missing"; exit 1; }
[ -x build/solver_arm_sweep ] || { echo "R2 INVALID: build/solver_arm_sweep missing"; exit 1; }
shasum -a 256 build/topopt-cli build/solver_arm_sweep > "$OUT/binaries.sha256"
cat "$OUT/binaries.sha256"

# ── The job, with the cap in the block BOTH paths honour.
python3 - "$HERE" "$OUT" "$ITERS" <<'PY'
import json, shutil, sys, os
here, out, iters = sys.argv[1], sys.argv[2], int(sys.argv[3])
j = json.load(open(os.path.join(here, "arms", "job", "job.json")))
j["plsm"] = {"enabled": True, "max_iterations": iters}
os.makedirs(os.path.join(out, "job"), exist_ok=True)
json.dump(j, open(os.path.join(out, "job", "job.json"), "w"), indent=1)
shutil.copy(os.path.join(here, "arms", "job", "M2_verticalStand.step"),
            os.path.join(out, "job"))
PY

./build/topopt-cli run "$OUT/job/job.json" --out "$OUT/cli" \
    --materials core/src/materials/materials.json --threads "$THREADS" \
    > "$OUT/cli.log" 2>&1
./build/solver_arm_sweep "$OUT/job/job.json" "$OUT/harness" \
    --arm base --threads "$THREADS" > "$OUT/harness.log" 2>&1

echo
echo "=== R2: design.bin, the certified report, and the per-solve record ==="
rc=0
for f in design.bin report.json iterations.csv; do
  a="$OUT/cli/$f"; b="$OUT/harness/$f"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    echo "  $f: MISSING on one side — R2 INVALID"; rc=1; continue
  fi
  # iterations.csv carries a wall-clock column, so it can never be byte-equal
  # across two runs; compare the SOLVER columns instead, which is what "the
  # harness did not change the solve" actually means.
  if [ "$f" = "iterations.csv" ]; then
    for side in a b; do
      eval "p=\$$side"
      awk -F, 'NR==1{for(i=1;i<=NF;i++) c[$i]=i; next}
               {print $c["rung"],$c["iter"],$c["cg_iters"],$c["cg_multigrid"],
                      $c["hier_built"],$c["mg_cycles_attempted"],$c["compliance"],
                      $c["achieved_vf"]}' "$p" > "$OUT/$side.cols"
    done
    if cmp -s "$OUT/a.cols" "$OUT/b.cols"; then
      echo "  $f: solver columns IDENTICAL"
    else
      echo "  $f: solver columns DIFFER"; diff "$OUT/a.cols" "$OUT/b.cols" | head; rc=1
    fi
    continue
  fi
  ha=$(shasum -a 256 "$a" | cut -d' ' -f1)
  hb=$(shasum -a 256 "$b" | cut -d' ' -f1)
  if [ "$ha" = "$hb" ]; then echo "  $f: IDENTICAL  $ha"
  else echo "  $f: DIFFER"; echo "    cli     $ha"; echo "    harness $hb"; rc=1; fi
done
[ $rc -eq 0 ] && echo "R2 MET: the harness reproduces the shipped CLI bit for bit." \
              || echo "R2 NOT MET."
exit $rc
