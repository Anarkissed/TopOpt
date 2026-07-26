# Reproducing the draft-quality evidence

All harnesses build standalone against the core static lib (fixtures/ untouched;
grids are constructed programmatically, the cg_tol_probe pattern). From the repo root:

```
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target topopt -j
FLAGS="-std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH=\"$PWD/core/src/settings/rules.json\""
```

Assertions are ON (no `-DNDEBUG`), so the B2 certification-tolerance asserts are
live during every run below.

## Harnesses (core/tests/harness/, NOT wired into CTest)

- `draft_quality_probe.cpp` — B3 noise floor, B5 win (grid S), B6 no-regression
  (grid H), B4 belt (round-1), gap-separation table. Writes per-iteration regime
  CSVs to `$TOPOPT_DRAFT_CSV_DIR`.
  ```
  c++ $FLAGS core/tests/harness/draft_quality_probe.cpp build/libtopopt.a -o build/draft_quality_probe
  TOPOPT_DRAFT_CSV_DIR=evidence/2026-07-25-draft-quality/csv ./build/draft_quality_probe > probe_stdout.txt
  ```
- `draft_quality_divergence_probe.cpp` — divergence sweep (1e-3 .. 5e-1) + gap
  separation, belt on genuine divergence, big-grid (32x16x32) win.
  ```
  c++ $FLAGS core/tests/harness/draft_quality_divergence_probe.cpp build/libtopopt.a -o build/dqd
  ./build/dqd > divergence_stdout.txt 2> divergence_stderr.txt
  ```
- `draft_quality_inherit_probe.cpp` — warm_start_inherit ON (production loadcase
  posture): does mid-ladder divergence propagate to the shipped rung, and does
  escalation recover it.
  ```
  c++ $FLAGS core/tests/harness/draft_quality_inherit_probe.cpp build/libtopopt.a -o build/dqi
  ./build/dqi > inherit_stdout.txt
  ```
- `draft_b1_identity_probe.cpp` — B1. References NO draft field, so it compiles
  UNCHANGED on pristine origin/main. Run on the branch, `git stash push -- core/`,
  rebuild the lib, run again; identical `B1_CHECKSUM` proves draft-OFF == main.
  ```
  c++ $FLAGS core/tests/harness/draft_b1_identity_probe.cpp build/libtopopt.a -o build/b1_probe
  ./build/b1_probe   # -> b1_identity.txt
  ```

## Determinism

Every count/|Δρ|/flip is deterministic (the base probe's determinism self-check is
in cg_tol_probe's lineage; a repeated run reproduces the terminal design bit-for-
bit). Each config runs ONCE; wall-clock (thermally contaminated, 113) is
corroboration only. `ctest` is 67/67 green with the changes applied.

## Files

- `probe_stdout.txt` — B3/B5/B6 + round-1 belt + gap table.
- `divergence_stdout.txt`, `divergence_stderr.txt` — divergence sweep + big-grid win.
- `inherit_stdout.txt` — warm-start-inheritance case.
- `b1_identity.txt` — the matching B1 checksums.
- `csv/` — per-iteration regime CSVs (rung,iter,cg_iters,cg_multigrid,hier_built,
  mg_mode,traj_tol,compliance,change,achieved_vf). `S_*` = 16x8x16 stagnation grid,
  `H_*` = 32x12x32 healthy grid.
