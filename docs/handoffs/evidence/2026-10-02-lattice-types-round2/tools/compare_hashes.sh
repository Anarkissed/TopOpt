#!/bin/zsh
# Usage: compare_hashes.sh ARM_A ARM_B — per project: same / MOVED.
source "${0:A:h}/env.sh"
a="$EVID/dumps/${1:?A}.hashes"; b="$EVID/dumps/${2:?B}.hashes"
for id in $PROJECTS; do
  ha=$(awk -v i=$id '$1==i{print $3}' "$a"); hb=$(awk -v i=$id '$1==i{print $3}' "$b")
  printf '%s %s %s %s\n' "${id:0:8}" "$ha" "$hb" "$([[ "$ha" == "$hb" ]] && echo same || echo MOVED)"
done
