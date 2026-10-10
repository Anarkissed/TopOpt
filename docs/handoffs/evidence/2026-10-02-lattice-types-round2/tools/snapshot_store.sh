#!/bin/zsh
# Usage: snapshot_store.sh NAME
# Copies his live store into $EVID/snapshots/NAME, read-only, with the copy time and a sha256 per
# project.json. The source is only READ (cp -R from the container); nothing is written there.
set -eu
source "${0:A:h}/env.sh"
name=${1:?NAME}
dst="$EVID/snapshots/$name"
[[ -e "$dst" ]] && { echo "exists: $dst" >&2; exit 1; }
mkdir -p "$dst"
cp -R "$STORE/." "$dst/"
date '+%Y-%m-%d %H:%M:%S %Z' > "$dst.copied_at"
( cd "$dst" && for id in */; do printf '%s %s\n' "${id%/}" "$(shasum -a 256 "$id/project.json" | cut -c1-16)"; done ) > "$dst.sha256"
chmod -R a-w "$dst"
echo "snapshot $name -> $dst ($(cat "$dst.copied_at"))"; cat "$dst.sha256"
