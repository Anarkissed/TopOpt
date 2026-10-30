#!/bin/zsh
# Usage: copy_cli.sh BUILT_BINARY NAME
# Freezes a built topopt-cli: copies it to $EVID/cli/NAME/ read-only BEFORE any run, and records
# its provenance from the stderr fingerprint line and --version (run_info.json's fingerprint is
# "unknown" on lattice-variant at the linked core — dispatch order, core main.cpp).
set -eu
source "${0:A:h}/env.sh"
bin=${1:?BINARY}; name=${2:?NAME}
dst="$EVID/cli/$name"; mkdir -p "$dst"
cp "$bin" "$dst/topopt-cli"; chmod a-w "$dst/topopt-cli"
{ "$dst/topopt-cli" --version 2>&1; stat -f 'mtime %Sm' "$dst/topopt-cli"; shasum -a 256 "$dst/topopt-cli"; } | tee "$dst/provenance.txt"
