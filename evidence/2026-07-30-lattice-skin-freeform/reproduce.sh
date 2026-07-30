#!/usr/bin/env bash
# Reproduce the freeform lattice-skin measurements
# (handoff 2026-07-30-lattice-skin-freeform).
# Machine of record: Apple M2 Pro (10 cores), 16 GB, Apple clang, -O2.
# E7 wall times were taken with nothing else running, one process at a time.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
EV=evidence/2026-07-30-lattice-skin-freeform
mkdir -p "$EV"

# 1. Build the production library + CLI + unit tests.
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=ON
cmake --build core/build --target topopt topopt_cli test_lattice_gen test_lattice_boundary test_lattice_skin_freeform -j

# 2. Unit gates: PR 250's golden byte-identity (unchanged) + the freeform skin
#    gates (overshoot, keep-out exactness, connectivity, closed primitives,
#    determinism, band rejection) on a curved voxel fixture.
./core/build/test_lattice_gen           | tee "$EV/test_lattice_gen.txt"
./core/build/test_lattice_boundary      | tee "$EV/test_lattice_boundary.txt"
./core/build/test_lattice_skin_freeform | tee "$EV/test_lattice_skin_freeform.txt"

# 3. The freeform probe (curved two-sphere + dimple + slit + bolt fixture, no
#    analytic base faces): bars E2/E3/E4/E5/E6/E7/E10 measured from emitted
#    geometry. One process per configuration (per-config ru_maxrss, E6);
#    "off" is the boundary-finish behaviour = the E7 BEFORE timing.
c++ -std=c++17 -O2 -I core/include core/tests/harness/lattice_skin_freeform_probe.cpp \
    core/build/libtopopt.a -o core/build/lattice_skin_freeform_probe
"$EV/run_probe_matrix.sh"

# 4. The REAL run_job E2E (PR 250's exact cube job — the one whose receipt said
#    "skin_struts": 0) under all three outer finishes.
./core/build/topopt-cli run "$EV/job_lattice.json"           --out "$EV/out_lattice_shell"
./core/build/topopt-cli run "$EV/job_lattice_skin.json"      --out "$EV/out_lattice_skin"
./core/build/topopt-cli run "$EV/job_lattice_shellskin.json" --out "$EV/out_lattice_shellskin"
./core/build/topopt-cli run "$EV/job_nolattice.json"         --out "$EV/out_nolattice_after"

# 4b. A CURVED model (cylinder r9 x h28) through run_job: all three finishes x
#     two cell sizes, each run twice and byte-compared (bar E10).
"$EV/run_cylinder_matrix.sh"

# 5. E1 — byte-identity of the DEFAULT (shell) finish, by STASH-REBUILD:
#    stash the change set, rebuild, rerun, byte-compare everything except the
#    timing-only files (run_info.json carries created_wall_ms / gen_seconds /
#    gen_fraction; iterations.csv is per-iteration timing).
git stash push -- core
cmake --build core/build --target topopt_cli -j
./core/build/topopt-cli run "$EV/job_nolattice.json" --out "$EV/out_nolattice_before"
./core/build/topopt-cli run "$EV/job_lattice.json"   --out "$EV/out_lattice_before"
git stash pop
cmake --build core/build --target topopt_cli -j
for f in report.json fields.bin; do
  cmp "$EV/out_nolattice_after/$f" "$EV/out_nolattice_before/$f"
done
for f in report.json fields.bin variant_026.stl variant_038.stl variant_052.stl \
         variant_068.stl variant_026_lattice.stl variant_038_lattice.stl \
         variant_052_lattice.stl variant_068_lattice.stl \
         variant_026_lattice.report.json variant_038_lattice.report.json \
         variant_052_lattice.report.json variant_068_lattice.report.json; do
  cmp "$EV/out_lattice_shell/$f" "$EV/out_lattice_before/$f"
done
# The default-finish outputs are ALSO byte-identical to PR 250's committed
# evidence (evidence/2026-07-29-lattice-boundary-finish/out_lattice/).

# 6. E8 / E9 — margins and volume accounting per finish, from the receipts.
python3 - <<'EOF'
import json
for v in ["026","038","052","068"]:
    for d,n in [("out_lattice_shell","shell"),("out_lattice_skin","skin"),
                ("out_lattice_shellskin","shell+skin")]:
        r=json.load(open(f"evidence/2026-07-30-lattice-skin-freeform/{d}/variant_{v}_lattice.report.json"))
        print(v,n,r["lattice_margin_worst_case"],r["lattice_accepted"],
              r.get("finish_certified",True),r["skin_volume_mm3"],
              r.get("shell_enclosed_volume_mm3"))
EOF

# 7. Full core suite.
( cd core/build && ctest -j 8 ) | tee "$EV/ctest.txt"
