#!/bin/sh
# Shielded runner. The binary is invoked as `msrun`, NOT `topopt-cli`, so an
# unrelated session's `pkill -f "topopt-cli run"` cannot match it (that pattern
# killed two hours of runs from this task).
cd "$(dirname "$0")"
CLI=../../build/msrun
echo "START $(date -u +%FT%TZ)"; uptime
$CLI run job_reachability_probe.json --out probe_reach > probe_reach.log 2>&1
echo "reach exit=$? $(date -u +%FT%TZ)"
sh ./m2b_positive_control.sh > m2b.log 2>&1
echo "m2b exit=$? $(date -u +%FT%TZ)"
rm -rf m2_multiscale m2_multiscale.log
$CLI run job_multiscale.json --out m2_multiscale > m2_multiscale.log 2>&1
echo "multiscale exit=$? $(date -u +%FT%TZ)"; uptime
rm -rf m2_twostep m2_twostep.log
$CLI run job_twostep.json --out m2_twostep > m2_twostep.log 2>&1
echo "twostep exit=$? $(date -u +%FT%TZ)"; uptime
echo ALLDONE
