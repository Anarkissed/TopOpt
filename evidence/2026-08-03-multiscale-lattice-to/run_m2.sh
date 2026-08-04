#!/bin/sh
# M2 — the maintainer's part, both ways, SEQUENTIALLY.
# NOTE ON HOST LOAD (PR 277's discipline): this machine also hosts an unrelated
# 128^3 acceptance run from another worktree. host_*.txt records the load average
# either side of each run so the wall numbers are read with that in mind; the CG
# ITERATION counts, matvec counts and every verdict are load-independent.
cd "$(dirname "$0")"
CLI=../../build/topopt-cli
{ echo "=== HOST before multiscale ==="; date -u +%FT%TZ; uptime; } > host_multiscale.txt
$CLI run job_multiscale.json --out m2_multiscale > m2_multiscale.log 2>&1
echo "multiscale exit=$?"
{ echo "=== HOST after multiscale ==="; date -u +%FT%TZ; uptime; } >> host_multiscale.txt
{ echo "=== HOST before two-step ==="; date -u +%FT%TZ; uptime; } > host_twostep.txt
$CLI run job_twostep.json --out m2_twostep > m2_twostep.log 2>&1
echo "twostep exit=$?"
{ echo "=== HOST after two-step ==="; date -u +%FT%TZ; uptime; } >> host_twostep.txt
echo ALLDONE
