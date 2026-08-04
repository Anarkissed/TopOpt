#!/bin/sh
# Final measurement sequence, shielded (binary invoked as msrun2, not topopt-cli).
cd "$(dirname "$0")"
CLI=../../build/msrun2
echo "START $(date -u +%FT%TZ)"; uptime
rm -rf m2_multiscale m2_multiscale.log
$CLI run job_multiscale.json --out m2_multiscale > m2_multiscale.log 2>&1
echo "multiscale exit=$? $(date -u +%FT%TZ)"; uptime
echo M2DONE
