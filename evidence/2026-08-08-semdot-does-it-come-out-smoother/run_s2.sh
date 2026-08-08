#!/bin/sh
# S2 — THE MEASUREMENT. His captured job document, run twice, SEQUENTIALLY on an
# otherwise idle host so the wall numbers compare like for like (PR 277's
# discipline; host_s2.txt records the load average either side of each run).
#
# THE TWO ARMS DIFFER BY ONE KEY. `job_simp.json` is
# evidence/2026-08-03-multiscale-lattice-to/job_twostep.json — the maintainer's own
# captured job document from ~/.topopt-worker — with its `lattice` and `grading`
# blocks removed. `job_semdot.json` is that same document with
# `"semdot": {"enabled": true, "grid_points": 4}` added and nothing else changed.
#
# WHY THE LATTICE AND GRADING BLOCKS COME OUT, and why it costs the answer
# nothing. Two reasons, in order of force:
#   1. THEY DO NOT REACH THE OPTIMIZER. On a NON-multiscale job the only lattice
#      keys that touch MinimizePlasticOptions are behind `job.lattice.multiscale`
#      (core/src/cli/run_job.cpp:7181-7195: multiscale_lattice, _topology,
#      _region, _floor_cell_mm, _floor_stride — the complete list). Everything
#      else in both blocks is consumed AFTER the ladder, on the converged design.
#      design.bin and variant_*.stl are therefore identical with the blocks and
#      without them, and those are the only artifacts this task reads.
#   2. HIS DOCUMENT NO LONGER RUNS WITH THEM. The cell-fit pre-flight refuses it
#      on current main: 5 of its 8 declared include regions are thinner than the
#      planned 4.6026 mm cell (0.87 cells across a 4 mm region against a
#      percolation floor of 1), so the run stops before it solves. That refusal is
#      correct and is not this task's to move — see s2_simp_preflight_refusal.txt,
#      which records it verbatim.
#
# ★ WHY THE CAPTURED DOCUMENT AND NOT THE MULTISCALE ONE. The four rungs PR
# 314/315 measured came from `job_multiscale.json`, which is the same document
# plus `lattice.multiscale: true`. Under multiscale the printed-set threshold
# stops being 0.5 and becomes `0.5 * lattice_rho_min(octet)` ~ 0.025
# (core/src/fea/lattice_material.cpp:256), and the optimizer's per-voxel density
# is handed to the grading law as the lattice's RELATIVE DENSITY
# (core/src/cli/run_job.cpp:2703). Both of those readings are wrong for a SEMDOT
# field, in which a voxel's number is the fraction of its VOLUME inside the part
# and not the density of a lattice cell — so a multiscale SEMDOT arm would differ
# from its SIMP arm by an iso shift and a unit error as well as by the optimizer,
# and the smoothness question could not be read out of it. The classic document
# puts BOTH arms at printed_iso 0.5 and leaves the optimizer as the only
# difference. See §S3 of the handoff; this is the same finding, measured from the
# other side.
set -e
cd "$(dirname "$0")"
CLI=../../core/build/topopt-cli

{
  echo "=== HOST before SIMP ==="; date -u +%FT%TZ; uptime
} > host_s2.txt

rm -rf s2_simp s2_simp.log
echo "START SIMP $(date -u +%FT%TZ)"
/usr/bin/time -l "$CLI" run job_simp.json --out s2_simp > s2_simp.log 2>&1
echo "SIMP exit=$? $(date -u +%FT%TZ)"

{
  echo "=== HOST between ==="; date -u +%FT%TZ; uptime
} >> host_s2.txt

rm -rf s2_semdot s2_semdot.log
echo "START SEMDOT $(date -u +%FT%TZ)"
/usr/bin/time -l "$CLI" run job_semdot.json --out s2_semdot > s2_semdot.log 2>&1
echo "SEMDOT exit=$? $(date -u +%FT%TZ)"

{
  echo "=== HOST after SEMDOT ==="; date -u +%FT%TZ; uptime
} >> host_s2.txt
echo S2DONE
