#!/bin/zsh
# Usage: dump_stage_hashes.sh SNAPSHOT ARM
# Dumps the lattice_part job the app would send for every project, from a FRESH writable copy of
# the snapshot per project (opening may write), through the app's own serializer
# (LatticeJobJSONDump), with SWIFT_DETERMINISTIC_HASHING UNSET (the task's condition). Uses the
# test products already built (`swift build --build-tests` first; never under a running suite).
# Prints "ID ARM sha256[0:16] <regions line>" and writes $EVID/dumps/ARM.hashes.
set -u
source "${0:A:h}/env.sh"
snap=${1:?SNAPSHOT}; arm=${2:?ARM}
src="$EVID/snapshots/$snap"; [[ -d "$src" ]] || { echo "no snapshot $src" >&2; exit 1; }
out="$EVID/dumps/$arm.hashes"; : > "$out"
for id in $PROJECTS; do
  work="$EVID/work/$arm-$id"; rm -rf "$work"; mkdir -p "$work"
  cp -R "$src/." "$work/"; chmod -R u+w "$work"
  json="$EVID/dumps/$arm-$id.json"; log="$EVID/dumps/$arm-$id.log"; rm -f "$json"
  ( cd "$REPO/app/TopOptKit" && env -u SWIFT_DETERMINISTIC_HASHING TOPOPT_PROJECT_ROOT="$work" \
      TOPOPT_PROJECT_ID=$id TOPOPT_JOB_OUT="$json" swift test --skip-build --filter LatticeJobJSONDump > "$log" 2>&1 )
  h=$([[ -s "$json" ]] && shasum -a 256 "$json" | cut -c1-16 || echo NO-JOB)
  line="$id $arm $h $(grep -m1 'lattice regions emitted' "$log")"
  echo "$line"; echo "$line" >> "$out"
done
grep -l 'SWIFT_DETERMINISTIC_HASHING=unset' "$EVID"/dumps/$arm-*.log | wc -l | xargs echo "logs confirming SWIFT_DETERMINISTIC_HASHING=unset:"
