#!/bin/bash
# AH1 — STASH-REBUILD BYTE IDENTITY.
#
# Extracts the tree at the REFERENCE commit (the PR 283 merge, i.e. everything
# this task changed, removed), builds it independently, runs the SAME production
# job through both CLIs, and compares the artifacts byte for byte.
#
# The claim under test is THE ONE RULE: with the algebraic level-1 path at its
# library default (OFF), a production run computes exactly what it computed
# before this task existed.
set -u
W=/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/graded-cell-size-phase-0-124b12
REF=ee5da824bb4dbd0d162f7a3852e37fff93fc918e
S=/tmp/algev/byteid
mkdir -p "$S/ref"
cd "$W" || exit 1

echo "=== extracting the reference tree ($REF) ==="
git archive "$REF" | tar -x -C "$S/ref" || exit 1

echo "=== building the reference tree (Release) ==="
cmake -S "$S/ref/core" -B "$S/ref/build" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
cmake --build "$S/ref/build" --target topopt_cli -j6 > "$S/ref_build.log" 2>&1
if [ ! -x "$S/ref/build/topopt-cli" ]; then
  echo "REFERENCE BUILD FAILED — see $S/ref_build.log"; tail -20 "$S/ref_build.log"; exit 1
fi

echo "=== building the current tree (Release) ==="
cmake --build "$W/core/build" --target topopt_cli -j6 > "$S/cur_build.log" 2>&1
if [ ! -x "$W/core/build/topopt-cli" ]; then
  echo "CURRENT BUILD FAILED"; tail -20 "$S/cur_build.log"; exit 1
fi

# The committed demo fixture verbatim; only mesh_format is STL (this build has
# no lib3mf) and the model path is absolutised. The fixture itself is untouched.
cat > "$S/job.json" <<EOF
{
  "model": "$W/core/tests/fixtures/demo/l-bracket.step",
  "material": "PLA",
  "mode": "minimize_plastic",
  "resolution": 48,
  "fixture_faces": [ { "kind": "cylindrical", "radius_mm": 2.5 } ],
  "gravity": { "direction": [0.0, 0.0, -1.0], "magnitude_mm_s2": 9810.0 },
  "ladder": [0.7, 0.5, 0.3],
  "margin_stop": 1.5,
  "simp": { "max_iterations": 30 },
  "output": { "report": "report.json", "mesh_format": "stl", "mesh_prefix": "variant" }
}
EOF

for side in ref cur; do
  OUT="$S/out_$side"
  rm -rf "$OUT"; mkdir -p "$OUT"
  BIN="$S/ref/build/topopt-cli"
  [ "$side" = cur ] && BIN="$W/core/build/topopt-cli"
  echo "=== running $side ($BIN) ==="
  ( cd "$OUT" && "$BIN" run "$S/job.json" --out "$OUT" > "$S/run_$side.log" 2>&1 )
  RC=$?
  if [ $RC -ne 0 ]; then echo "  RUN FAILED (exit $RC)"; tail -15 "$S/run_$side.log"; exit 1; fi
done

echo
echo "=== ARTIFACT COMPARISON ==="
STATUS=0
COMPARED=0
for f in report.json design.bin fields.bin loadcase.json variant_070.stl variant_050.stl variant_030.stl; do
  A="$S/out_ref/$f"; B="$S/out_cur/$f"
  if [ ! -f "$A" ] && [ ! -f "$B" ]; then echo "  $f : absent on both (skipped)"; continue; fi
  if [ ! -f "$A" ] || [ ! -f "$B" ]; then echo "  $f : PRESENT ON ONE SIDE ONLY  <<< DIFFERS"; STATUS=1; continue; fi
  HA=$(shasum -a 256 "$A" | cut -d' ' -f1)
  HB=$(shasum -a 256 "$B" | cut -d' ' -f1)
  COMPARED=$((COMPARED+1))
  if [ "$HA" = "$HB" ]; then echo "  $f : IDENTICAL  ($HA)"; else echo "  $f : DIFFERS"; echo "     ref $HA"; echo "     cur $HB"; STATUS=1; fi
done

echo
echo "=== iterations.csv, column by column (non-timing columns must all match) ==="
python3 - "$S/out_ref/iterations.csv" "$S/out_cur/iterations.csv" <<'PY'
import sys, csv
try:
    a=list(csv.reader(open(sys.argv[1]))); b=list(csv.reader(open(sys.argv[2])))
except FileNotFoundError as e:
    print("  MISSING:", e); sys.exit(0)
if not a or not b:
    print("  empty"); sys.exit(0)
ha, hb = a[0], b[0]
print(f"  rows: ref {len(a)-1}, cur {len(b)-1}; header identical: {ha==hb}")
if ha!=hb or len(a)!=len(b):
    print("  HEADER OR ROW COUNT DIFFERS"); sys.exit(0)
TIMING = {"seconds","wall_ms","t_build_ms","t_mg_build_ms","t_mg_ms","t_cg_ms",
          "t_geneo_setup_ms","t_geneo_apply_ms","t_recycle_ms","t_total_ms",
          "peak_rss_mb","rss_mb","elapsed_s","iter_seconds"}
diff = {}
for r in range(1,len(a)):
    for c,name in enumerate(ha):
        if a[r][c]!=b[r][c]:
            diff[name]=diff.get(name,0)+1
if not diff:
    print("  ZERO columns differ on any row.")
else:
    for k,v in sorted(diff.items()):
        tag = "TIMING/MEMORY (expected)" if k in TIMING else "*** NON-TIMING ***"
        print(f"  {k}: {v} rows differ   {tag}")
PY

echo
echo "=== run_info.json keys that differ ==="
python3 - "$S/out_ref/run_info.json" "$S/out_cur/run_info.json" <<'PY'
import sys, json
try:
    a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
except Exception as e:
    print("  ", e); sys.exit(0)
added = sorted(set(b) - set(a)); removed = sorted(set(a) - set(b))
changed = sorted(k for k in set(a)&set(b) if a[k]!=b[k])
print("  keys ADDED by this task:", added or "none")
print("  keys REMOVED:", removed or "none")
for k in changed:
    print(f"  changed: {k}: {a[k]!r} -> {b[k]!r}")
PY

echo
if [ "$COMPARED" -eq 0 ]; then echo "NOTHING WAS COMPARED — this proves nothing"; STATUS=1; fi
echo "artifacts compared: $COMPARED"
echo "byte-identity STATUS=$STATUS"
exit $STATUS
