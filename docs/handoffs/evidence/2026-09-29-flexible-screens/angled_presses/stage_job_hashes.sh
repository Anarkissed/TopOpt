#!/bin/zsh
# Angled presses (task 2026-10-07), AP0: the stage-job hashes over the S0 set (13 rows) + the controls.
# The app's own makeLatticeRunRequest (LatticeJobJSONDump), SWIFT_DETERMINISTIC_HASHING=1, TOPOPT_JOB_REPEAT=3,
# each project from a FRESH copy. hash = the first 16 hex of SHA-256 over the dumped (pretty, sorted) job.json.
# Build the tests first (swift build --build-tests). Inputs (override by env):
#   S0_HIS  his 7-project store copy (default: the frozen snapshot S1-2026-10-02, with its own .sha256)
#   S0_A1   the A1 simulator store (default: the simulator's live Projects folder — check its hashes below)
#   WORK    scratch folder (default: a new temp folder);  OUT  the result file (default: $WORK/stage_job_hashes.txt)
EV=${0:A:h}
REPO=${EV:h:h:h:h:h}
PKG="${REPO}/app/TopOptKit"
S0_HIS=${S0_HIS:-/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/lattice-stage-frontend-37bee1/scratch/evidence/snapshots/S1-2026-10-02}
S0_A1=${S0_A1:-"/Users/nadim/Library/Developer/CoreSimulator/Devices/147E56A1-C8CA-4B9D-BE6C-CF230589A83A/data/Containers/Data/Application/15B1C2F9-9909-4D79-8CD0-3650F99D43B8/Library/Application Support/TopOpt/Projects"}
WORK=${WORK:-$(mktemp -d -t ap-stage-hashes)}
OUT=${OUT:-"${WORK}/stage_job_hashes.txt"}
R3="${REPO}/docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004"
R5="${REPO}/docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004_r5"
: > "${OUT}"
print -r -- "# sources (first 16 hex of SHA-256; compare with stage_job_hashes_base.txt before comparing rows):" >> "${OUT}"
for d in "${S0_HIS}"/*(/) "${S0_A1}"/*(/) "${R3}" "${R5}"; do
  m=$(ls "${d}" | grep -E "^model\.(step|stl)$")
  print -r -- "#   ${d:t} project.json $(shasum -a 256 ${d}/project.json | cut -c1-16) ${m} $(shasum -a 256 ${d}/${m} | cut -c1-16)" >> "${OUT}"
done
row() {   # row <label> <source project folder> [mutation]
  local label="$1" src="$2" mut="$3"
  local id=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "${src}/project.json")
  local tag="${label// /_}_${src:t}_${id}${mut:+_${mut}}"
  local root="${WORK}/${tag}/root"
  mkdir -p "${root}/${id}"
  cp -R "${src}/." "${root}/${id}/"
  if [[ -n "${mut}" ]]; then python3 -I "${EV}/mutate_project.py" "${src}/project.json" "${root}/${id}/project.json" "${mut}" > "${WORK}/${tag}/mutation.txt"; fi
  local job="${WORK}/${tag}/job.json" log="${WORK}/${tag}/dump.log"
  ( cd "${PKG}" && env SWIFT_DETERMINISTIC_HASHING=1 TOPOPT_JOB_REPEAT=3 TOPOPT_PROJECT_ROOT="${root}" TOPOPT_PROJECT_ID="${id}" TOPOPT_JOB_OUT="${job}" \
      swift test --skip-build --filter LatticeJobJSONDump > "${log}" 2>&1 )
  local code=$?
  local h="-"
  [[ -f "${job}" ]] && h=$(shasum -a 256 "${job}" | cut -c1-16)
  local emitted=$(grep -m1 "lattice regions emitted" "${log}")
  local rep=$(grep -m1 "repeats " "${log}")
  local m=""
  [[ -n "${mut}" ]] && m=" [$(cat ${WORK}/${tag}/mutation.txt)]"
  print -r -- "${label} ${id} exit ${code} ${h} ${emitted} · ${rep:-no repeat line}${m}" >> "${OUT}"
}
for d in "${S0_HIS}"/*(/); do row "base his" "${d}"; done
for d in "${S0_A1}"/*(/); do row "base his" "${d}"; done
row "base r3" "${R3}"
row "base r5" "${R5}"
row "control+ r5" "${R5}" depth
row "control- r5" "${R5}" flex
row "again r5" "${R5}"
print -r -- "DONE" >> "${OUT}"
print -r -- "${OUT}"
