#!/bin/zsh
# Usage: run_all.sh CLI_NAME — round 5's six plan-proof arms, one after another (one `swift test` at a
# time in this worktree), each arm's lines appended to $EVID/plans/ALL.log; "ALL DONE" marks the end.
set -u
source "${0:A:h}/../../2026-10-02-lattice-types-round2/tools/env.sh"
cli=${1:?CLI_NAME}
log="$EVID/plans/ALL-${PHASE:-all}.log"; mkdir -p "$EVID/plans"; : > "$log"
arms=(
  "570B38E2-3C6E-46E0-BCF6-26BE1595D204 dg -"
  "3418E167-8524-4831-A809-827B6B0742D0 dg convert-dg"
  "102117B9-DDD2-4597-9BDE-49DD47EBF393 dg convert-dg"
  "68BF7B74-3C2A-4ED6-A46D-AC040A9CA649 dg convert-dg"
  "68BF7B74-3C2A-4ED6-A46D-AC040A9CA649 stepped stepped"
  "3418E167-8524-4831-A809-827B6B0742D0 stepped convert-stepped-aesthetic"
)
for a in $arms; do
  parts=(${=a}); id=$parts[1]; arm=$parts[2]; conv=$parts[3]; [[ "$conv" == - ]] && conv=""
  [[ -n "${ONLY:-}" && "$ONLY" != *"${id:0:8}/$arm"* ]] && continue
  echo "##### ${id:0:8} $arm ${conv:-native} $(date '+%H:%M:%S')" >> "$log"
  PHASE=${PHASE:-all} zsh "${0:A:h}/plan_proof.sh" S1-2026-10-02 "$cli" "$id" "$arm" $conv >> "$log" 2>&1
done
echo "ALL DONE $(date '+%H:%M:%S')" >> "$log"
