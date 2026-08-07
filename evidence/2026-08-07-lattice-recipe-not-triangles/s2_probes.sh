#!/usr/bin/env bash
# S2 — cost the deferred-materialisation round trip, on the maintainer's own run.
#
# Every probe here starts from the RECIPE and nothing else: the run's job
# document plus its `design.bin`. No mesh is read. `topopt-cli lattice-variant`
# (core/src/cli/run_job.cpp:5049) is the shipped mechanism the app already drives
# from the iPad (RelatticeRunner.swift), so its wall time is not a hypothetical —
# it is what "materialise on demand" costs today.
#
#   P1  materialise on demand, emit_stl=true   -> seconds + bytes
#   P2  the same job with emit_stl=false       -> what is left when nothing is
#                                                 written. `export_latticed_variant`
#                                                 only generates INSIDE the
#                                                 `if (lat.emit_stl)` /
#                                                 `if (lat.emit_3mf)` arms
#                                                 (run_job.cpp:1154-1168), so P1-P2
#                                                 is generation + write together.
#   P3  the same recipe at cell_mode=fit       -> the expansion the maintainer saw
#
# Usage:  s2_probes.sh <run_out_dir> <orig_job.json> <work_dir>
set -u

OUT_RUN="${1:?run output dir}"
JOB="${2:?original job.json}"
WORK="${3:?work dir}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$REPO/build/topopt-cli"
MAT="$REPO/core/src/materials/materials.json"
RULES="$REPO/core/src/settings/rules.json"
MK="$REPO/evidence/2026-08-07-lattice-recipe-not-triangles/s2a_make_lattice_variant_job.py"

mkdir -p "$WORK"
cp "$OUT_RUN/design.bin" "$WORK/design.bin"
# The model the load case's faces are defined on travels with the job.
MODEL=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('model',''))" "$JOB")
[ -n "$MODEL" ] && cp "$(dirname "$JOB")/$MODEL" "$WORK/" 2>/dev/null

VF="${VF:-0.68}"

probe () {           # probe <tag> <extra args to the job builder...>
  local tag="$1"; shift
  ( cd "$WORK" || exit 1
    python3 "$MK" "$JOB" design.bin "$VF" "job_$tag.json" "$@" > "mk_$tag.txt" 2>&1 \
      || { echo "== $tag: JOB BUILD FAILED =="; cat "mk_$tag.txt"; return; }
    rm -rf "out_$tag"
    echo "== $tag =="
    cat "mk_$tag.txt"
    { /usr/bin/time -p "$CLI" lattice-variant "job_$tag.json" --out "out_$tag" \
        --materials "$MAT" --rules "$RULES" ; } > "run_$tag.log" 2>&1
    echo "exit=$?"
    grep -h "^LATTICE " "run_$tag.log" || true
    tail -4 "run_$tag.log"
    echo "-- bytes written --"
    ls -l "out_$tag" 2>/dev/null | awk 'NR>1{printf "   %-40s %12d\n", $NF, $5; t+=$5} END{printf "   %-40s %12d TOTAL\n","",t}'
    echo )
}

echo "### P1 — materialise on demand (emit_stl true), skin none, swept 2 mm"
probe p1_emit --skin none --cell-mode swept --cell-min 2.0

echo "### P2 — identical recipe, emit_stl FALSE (nothing generated, nothing written)"
python3 - "$JOB" "$WORK/job_noemit_src.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
j["lattice"] = dict(j.get("lattice", {}))
j["lattice"]["emit_stl"] = False
j["lattice"]["emit_3mf"] = False
json.dump(j, open(sys.argv[2], "w"), indent=1)
PY
JOB_SAVE="$JOB"; JOB="$WORK/job_noemit_src.json"
probe p2_noemit --skin none --cell-mode swept --cell-min 2.0
JOB="$JOB_SAVE"

echo "### P3 — the same recipe at cell_mode=fit (the mode PR 310's refusal recommends)"
probe p3_fit --skin none --cell-mode fit

echo "### P4 — the same recipe at a PINNED 2 mm cell (cell_mode=fixed)"
probe p4_fixed2 --skin none --cell-mode fixed --cell 2.0

echo "### P5 — pinned at the printability floor the refusal quotes (1.094961872 mm)"
probe p5_floor --skin none --cell-mode fixed --cell 1.094961872
