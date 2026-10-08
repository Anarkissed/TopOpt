#!/bin/zsh
# Angled presses (task 2026-10-07), AP0: the stage-job hashes over the S0 set (13 rows) + the controls.
# The app's own makeLatticeRunRequest (LatticeJobJSONDump), SWIFT_DETERMINISTIC_HASHING=1, TOPOPT_JOB_REPEAT=3,
# each project from a FRESH copy. hash = the first 16 hex of SHA-256 over the dumped (pretty, sorted) job.json.
# Build the tests first (swift build --build-tests). Inputs (override by env):
#   S0_HIS  his 7-project store copy (default: s0_frozen/his7, this folder — the snapshot S1-2026-10-02, frozen)
#   S0_A1   the A1 store's four projects (default: s0_frozen/a1, this folder — frozen from the simulator's store)
#   WORK    scratch folder (default: a new temp folder);  OUT  the result file (default: $WORK/stage_job_hashes.txt)
# ★ The inputs are CHECKED before any row is dumped: every file of s0_frozen/SHA256SUMS (his7/… against S0_HIS,
# a1/… against S0_A1) and the committed r3 / r5 copies must have the recorded SHA-256, or the script stops
# (exit 2) — a row from a moved input is not this base's row.
EV=${0:A:h}
REPO=${EV:h:h:h:h:h}
PKG="${REPO}/app/TopOptKit"
FROZEN="${EV}/s0_frozen"
S0_HIS=${S0_HIS:-"${FROZEN}/his7"}
S0_A1=${S0_A1:-"${FROZEN}/a1"}
WORK=${WORK:-$(mktemp -d -t ap-stage-hashes)}
OUT=${OUT:-"${WORK}/stage_job_hashes.txt"}
R3="${REPO}/docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004"
R5="${REPO}/docs/handoffs/evidence/2026-09-29-flexible-screens/his_project_0004_r5"

# --- the inputs are the recorded ones, or nothing is dumped ---------------------------------------------
moved=0
while read -r sum rel; do
  case "${rel}" in
    his7/*) f="${S0_HIS}/${rel#his7/}" ;;
    a1/*)   f="${S0_A1}/${rel#a1/}" ;;
    *)      continue ;;
  esac
  now=$(shasum -a 256 "${f}" 2>/dev/null | cut -d' ' -f1)
  if [[ "${now}" != "${sum}" ]]; then print -r -- "MOVED INPUT ${rel}: ${now:-missing} (recorded ${sum})" >&2; moved=1; fi
done < "${FROZEN}/SHA256SUMS"
for pair in "${R3}/project.json dabdc3db0523c2ece35a01a9680b0610d500429984f864338eefa885c1b27754" \
            "${R3}/model.stl 53964b38e3354f5a613bcf6523796166749f97c3ea2296b2358b6f315229957a" \
            "${R5}/project.json 5fb79a0d628011a214ec0347d4a39184bdeb7d8ff66408d74b16c9f30a4b3cfa" \
            "${R5}/model.stl 53964b38e3354f5a613bcf6523796166749f97c3ea2296b2358b6f315229957a"; do
  f=${pair% *}; sum=${pair##* }
  now=$(shasum -a 256 "${f}" 2>/dev/null | cut -d' ' -f1)
  if [[ "${now}" != "${sum}" ]]; then print -r -- "MOVED INPUT ${f}: ${now:-missing} (recorded ${sum})" >&2; moved=1; fi
done
if (( moved )); then print -r -- "stage_job_hashes.sh: an input differs from the recorded base — no row dumped" >&2; exit 2; fi

: > "${OUT}"
print -r -- "# sources (first 16 hex of SHA-256; checked in full against s0_frozen/SHA256SUMS and the r3/r5 sums in the script):" >> "${OUT}"
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
      swift test --skip-build ${=SWIFT_TEST_ARGS} --filter LatticeJobJSONDump > "${log}" 2>&1 )
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
for d in "${S0_A1}"/*(/); do row "base A1" "${d}"; done
row "base r3" "${R3}"
row "base r5" "${R5}"
row "control+ r5" "${R5}" depth
row "control- r5" "${R5}" flex
row "again r5" "${R5}"
print -r -- "DONE" >> "${OUT}"
print -r -- "${OUT}"
