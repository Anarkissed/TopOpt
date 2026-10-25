#!/bin/zsh
# Usage: plan_proof.sh SNAPSHOT CLI_NAME ID ARM [convert-dg|convert-stepped-aesthetic|stepped]
# ("stepped" = his own Aesthetic Stepped project, unconverted, with the any-step test switch on)
# Round 5's plan proof for one project and one arm (the reviewer's 2026-10-08 ruling: "send the plan
# behind a test switch, show that core accepts it and lays exactly the preview, cell for cell from
# the receipt and STL; report every refusal in core's words"). A fresh writable COPY of the project
# from the snapshot (converted when asked, labelled), the app's own bake and job builder
# (LatticeDefaultGradePlanProof: job_plan.json — through the ONE plan writer, slot origins included,
# or the reason it was withheld — job_noplan.json, and the preview's histogram in core's format),
# then both jobs through the frozen CLI. Output: scratch/evidence/plans/ID/ARM (never the round-2
# evidence: this script deletes only its own ARM folder). Test products must be built first.
set -u
source "${0:A:h}/../../2026-10-02-lattice-types-round2/tools/env.sh"
snap=${1:?SNAPSHOT}; cli="$EVID/cli/${2:?CLI_NAME}/topopt-cli"; id=${3:?ID}; arm=${4:?ARM}; conv=${5:-}
[[ -x "$cli" ]] || { echo "no CLI at $cli" >&2; exit 1; }
# PHASE=harness (the app's bake and jobs — needs the test build, no rebuild meanwhile), PHASE=cli (the
# frozen CLI on jobs already written — no build needed), or both (the default)
phase=${PHASE:-all}
out="$EVID/plans/$id/$arm"
if [[ "$phase" != cli ]]; then
rm -rf "$out"; mkdir -p "$out"
work="$EVID/work/plan-$id-$arm"; rm -rf "$work"; mkdir -p "$work"
cp -R "$EVID/snapshots/$snap/$id/." "$work/"; chmod -R u+w "$work"
case "$conv" in
  convert-dg) python3 "${0:A:h}/../../2026-10-02-lattice-types-round2/tools/convert_default_grade.py" "$work" | tee "$out/converted.txt" ;;
  convert-stepped-aesthetic) python3 "${0:A:h}/convert_stepped_aesthetic.py" "$work" | tee "$out/converted.txt" ;;
esac
anystep=0; [[ "$conv" == convert-stepped-aesthetic || "$conv" == stepped ]] && anystep=1
# RENDERS=1: offscreen frames of the preview through the app's renderer, into $out/renders (round 6)
rdir=""; [[ -n "${RENDERS:-}" ]] && rdir="$out/renders"
( cd "$REPO/app/TopOptKit" && DG_PROJECT_DIR="$work" DG_OUT="$out" DG_ANY_STEP=$anystep DG_RENDER_DIR="$rdir" swift test --skip-build \
    --filter LatticeDefaultGradePlanProof > "$out/harness.log" 2>&1 )
grep -E "DG-PROJECT|DG-PLAN|DG-OUTLINE|DG-OVERLAPS|DG-REGIONS|DG-RENDER|DG-JOBS|DG-WITHHELD|DG-SLOT|DG-K2|error:|skipped" "$out/harness.log" | sed 's/^.*\] //'
fi
[[ "$phase" == harness ]] && exit 0
# the third arm: the plan job asking core for what it ships, strut by strut (welded spans), so the
# laid cells can be checked against the plan cell for cell (compare_plan_spans.py)
[[ -s "$out/job_plan.json" ]] && python3 - "$out/job_plan.json" "$out/job_plan_spans.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
if j.get('lattice', {}).get('stepped_cells'):
    j['lattice']['emit_welded_stl'] = True
    j['lattice']['emit_organic_spans'] = True
    json.dump(j, open(sys.argv[2], 'w'), indent=1, sort_keys=True)
PY
for a in plan noplan plan_spans plan_k2; do
  [[ -s "$out/job_$a.json" ]] || { echo "no job_$a.json"; continue; }
  mkdir -p "$out/run_$a"
  ( cd "$out" && /usr/bin/time -p "$cli" lattice-variant "job_$a.json" --out "run_$a" \
      --materials "$REPO/core/src/materials/materials.json" --rules "$REPO/core/src/settings/rules.json" \
      > "run_$a.stdout" 2> "run_$a.stderr"; echo "exit $?" >> "run_$a.stdout" )
  echo "== $a: $(tail -1 "$out/run_$a.stdout") | $(grep -m1 'topopt-cli: core' "$out/run_$a.stderr")"
  grep -E "^\[stepped\]|stepped_cells|verdict|refus|error" "$out/run_$a.stderr" "$out/run_$a.stdout" | head -8
done
if [[ -s "$out/job_plan_spans.json" ]]; then
  spans=$(ls "$out"/run_plan_spans/*_SPANS.txt 2>/dev/null | head -1)
  [[ -n "$spans" ]] && python3 "${0:A:h}/compare_plan_spans.py" "$out/job_plan.json" "$spans" | tee "$out/cells_vs_spans.txt"
  # round 6: WHY a plan cell got no strut (outside outline_uv / past depth / inside the region)
  [[ -n "$spans" ]] && python3 -I "${0:A:h}/classify_unlaid_cells.py" "$out/job_plan.json" "$spans" | tee "$out/unlaid.txt"
fi
# ★ DISK (2026-10-10: the machine hit 100%): keep the verdicts, jobs, logs and summaries; drop the bulky
# outputs once measured, with their sizes on record. KEEP_BINARIES=1 keeps them.
if [[ -z "${KEEP_BINARIES:-}" ]]; then
  setopt local_options null_glob
  for f in "$out"/run_*/*.stl "$out"/run_*/*.3mf "$out"/run_*/fields.bin "$out"/run_*/*_SPANS.txt "$out"/model.step; do
    [[ -f "$f" ]] && { echo "dropped ${f#$out/} $(stat -f %z "$f") B" >> "$out/dropped.txt"; rm -f "$f"; }
  done
fi
