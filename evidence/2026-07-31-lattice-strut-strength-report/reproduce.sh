#!/bin/sh
# Reproduce the strut-strength-report evidence (task
# 2026-07-31-lattice-strut-strength-report). Run from the repo root with
# core/build configured (cmake -S core -B core/build -DTOPOPT_DEPS=ON).
set -e

cmake --build core/build --target topopt topopt_cli test_strut_strength \
  test_strut_report_j6 -j 8

# Unit bars: table transcription, L5 clamp+count, hydrostatic non-zero bound,
# L8 build-direction split, L1 verdict-unchanged, L4 regime guard.
./core/build/test_strut_strength

# Bar L2: the production path reproduces PR 259's J6 table on PR 255's three
# certified designs (reads evidence/2026-07-31-multiscale-lattice-feasibility).
./core/build/test_strut_report_j6

# End-to-end receipt: the demo L-bracket with a lattice block. Run twice; the
# receipts, report and meshes must be byte-identical (determinism_receipts.sha256).
# The receipt variant_050_lattice.report.json carries the "strut_strength" object.
D=$(mktemp -d)
cp core/tests/fixtures/demo/l-bracket.step "$D"/
sed -e 's/"ladder": \[0.7, 0.5, 0.3\]/"ladder": [0.5]/' \
    -e 's/"mesh_format": "3mf"/"mesh_format": "stl"/' \
    core/tests/fixtures/demo/job.json |
  sed -e 's/"_output_note".*/"lattice": { "topology": "octet", "cell_mm": 5.0, "strut_radius_mm": 0.6, "emit_stl": true }/' \
  > "$D"/job.json  # (the evidence run used the exact job.json quoted in the handoff)
(cd "$D" && "$OLDPWD"/core/build/topopt-cli run job.json --out runA)
(cd "$D" && "$OLDPWD"/core/build/topopt-cli run job.json --out runB)
(cd "$D" && shasum -a 256 runA/*_lattice.report.json runB/*_lattice.report.json \
             runA/report.json runB/report.json)

# Bar L3: stash the working-tree changes, rebuild, re-run the NON-lattice demo
# job, compare byte-for-byte, restore (see l3_byte_identity.txt for the record).
echo "L3 stash-rebuild: see l3_byte_identity.txt (manual git stash cycle)"

# Full suite (L7).
(cd core/build && ctest -j 4)
