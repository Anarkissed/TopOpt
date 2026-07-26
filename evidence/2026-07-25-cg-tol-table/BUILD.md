# Probe build + run provenance

Tree state: `HEAD == origin/main == 08430cc` (no source changes on this branch;
`git diff origin/main HEAD` empty). The probe measures the SHIPPING config.

## Build the core static library (Eigen present; OCCT/lib3mf not needed — the
## probe builds VoxelGrids directly, never imports STEP/STL/3MF)

```
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DEigen3_DIR=/opt/homebrew/Cellar/eigen/5.0.1/share/eigen3/cmake
cmake --build build --target topopt -j6
```

## Build the standalone probe (the command in the probe's own header comment)

```
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/cg_tol_probe.cpp build/libtopopt.a -o build/cg_tol_probe
```

## Run (CSVs land in TOPOPT_CG_PROBE_CSV_DIR)

```
TOPOPT_CG_PROBE_CSV_DIR=<evidence-dir> ./build/cg_tol_probe > <evidence-dir>/probe_stdout.txt 2>&1
```

Host: Apple Silicon, 6 P-cores. AppleClang 21. Eigen 5.0.1 (homebrew).
The probe bit-rot check: it compiled and linked UNCHANGED against the current
tree — no repair needed. Nothing measured was altered.

## Artifacts in this directory
- `probe_stdout.txt`         — the human table (both fixtures, tight + 4 loose endpoints)
- `fixture1_l_bracket_loadcase.csv` — machine-readable, healthy-MG regime (B6)
- `fixture2_design_box.csv`  — machine-readable, whole-domain stagnation regime (B2–B5)
