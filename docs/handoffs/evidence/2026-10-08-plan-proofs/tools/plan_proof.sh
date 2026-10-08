#!/bin/zsh
# Usage: plan_proof.sh SNAPSHOT CLI_NAME ID ARM [convert-dg|convert-stepped-aesthetic]
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
out="$EVID/plans/$id/$arm"; rm -rf "$out"; mkdir -p "$out"
work="$EVID/work/plan-$id-$arm"; rm -rf "$work"; mkdir -p "$work"
cp -R "$EVID/snapshots/$snap/$id/." "$work/"; chmod -R u+w "$work"
case "$conv" in
  convert-dg) python3 "${0:A:h}/../../2026-10-02-lattice-types-round2/tools/convert_default_grade.py" "$work" | tee "$out/converted.txt" ;;
  convert-stepped-aesthetic) python3 "${0:A:h}/convert_stepped_aesthetic.py" "$work" | tee "$out/converted.txt" ;;
esac
anystep=0; [[ "$conv" == convert-stepped-aesthetic ]] && anystep=1
( cd "$REPO/app/TopOptKit" && DG_PROJECT_DIR="$work" DG_OUT="$out" DG_ANY_STEP=$anystep swift test --skip-build \
    --filter LatticeDefaultGradePlanProof > "$out/harness.log" 2>&1 )
grep -E "DG-PROJECT|DG-PLAN|DG-JOBS|DG-WITHHELD|error:|skipped" "$out/harness.log" | sed 's/^.*\] //'
for a in plan noplan; do
  [[ -s "$out/job_$a.json" ]] || { echo "no job_$a.json"; continue; }
  mkdir -p "$out/run_$a"
  ( cd "$out" && /usr/bin/time -p "$cli" lattice-variant "job_$a.json" --out "run_$a" \
      --materials "$REPO/core/src/materials/materials.json" --rules "$REPO/core/src/settings/rules.json" \
      > "run_$a.stdout" 2> "run_$a.stderr"; echo "exit $?" >> "run_$a.stdout" )
  echo "== $a: $(tail -1 "$out/run_$a.stdout") | $(grep -m1 'topopt-cli: core' "$out/run_$a.stderr")"
  grep -E "^\[stepped\]|stepped_cells|verdict|refus|error" "$out/run_$a.stderr" "$out/run_$a.stdout" | head -8
done
