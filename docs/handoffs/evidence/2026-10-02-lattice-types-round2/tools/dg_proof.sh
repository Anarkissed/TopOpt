#!/bin/zsh
# Usage: dg_proof.sh SNAPSHOT CLI_NAME ID [convert]
# The Default Grade plan proof for one project (ruling 4). A fresh writable COPY of the project
# folder from the snapshot (converted to Default Grade when asked, labelled), the app's own bake
# and job builder (LatticeDefaultGradePlanProof: job_plan.json + job_noplan.json + the preview's
# histogram in core's format), then BOTH jobs through the frozen CLI (lattice-variant runs a
# lattice_part job). Test products must be built first.
set -u
source "${0:A:h}/env.sh"
snap=${1:?SNAPSHOT}; cli="$EVID/cli/${2:?CLI_NAME}/topopt-cli"; id=${3:?ID}; conv=${4:-}
out="$EVID/dg/$id"; rm -rf "$out"; mkdir -p "$out"
work="$EVID/work/dg-$id"; rm -rf "$work"; mkdir -p "$work"
cp -R "$EVID/snapshots/$snap/$id/." "$work/"; chmod -R u+w "$work"
[[ "$conv" == convert ]] && python3 "${0:A:h}/convert_default_grade.py" "$work" | tee "$out/converted.txt"
( cd "$REPO/app/TopOptKit" && DG_PROJECT_DIR="$work" DG_OUT="$out" swift test --skip-build \
    --filter LatticeDefaultGradePlanProof > "$out/harness.log" 2>&1 )
grep -E "DG-PROJECT|DG-PLAN|DG-JOBS|error:|skipped" "$out/harness.log" | sed 's/^.*\] //'
for arm in plan noplan; do
  [[ -s "$out/job_$arm.json" ]] || { echo "no job_$arm.json"; continue; }
  mkdir -p "$out/run_$arm"
  ( cd "$out" && /usr/bin/time -p "$cli" lattice-variant "job_$arm.json" --out "run_$arm" \
      --materials "$REPO/core/src/materials/materials.json" --rules "$REPO/core/src/settings/rules.json" \
      > "run_$arm.stdout" 2> "run_$arm.stderr"; echo "exit $?" >> "run_$arm.stdout" )
  echo "== $arm: $(tail -1 "$out/run_$arm.stdout") | $(grep -m1 'topopt-cli: core' "$out/run_$arm.stderr")"
  grep -E "^\[stepped\]|stepped_cells|verdict|refus" "$out/run_$arm.stderr" "$out/run_$arm.stdout" | head -5
done
