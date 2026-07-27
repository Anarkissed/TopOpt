# Reproducing the draft-quality Phase-2 evidence

All harnesses build standalone against the core static lib (fixtures/ untouched;
grids constructed programmatically, the cg_tol_probe lineage). From the repo root:

```
cmake -S core -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target topopt -j
RULES="$PWD/core/src/settings/rules.json"
FLAGS=(-std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 -DSETTINGS_RULES_PATH="\"$RULES\"")
```

Assertions are ON (no `-DNDEBUG`), so the exact-solve gate asserts (D6) are live during
every run below. All harnesses set `std::setvbuf(stdout, _IONBF)` — watch progress live.

## Harnesses (core/tests/harness/, NOT wired into CTest)

- `draft_quality_phase2_probe.cpp` — D1/D2/D3 on grid S (16x8x16), both postures
  (AD-on production / AD-off = Phase-1's pre-187 solve). Negative-control floor FIRST
  (D2), then the gap-vs-probe-vs-truth sweep (D1), then probe cost (D3).
  ```
  c++ "${FLAGS[@]}" core/tests/harness/draft_quality_phase2_probe.cpp build/libtopopt.a -o build/probe
  ./build/probe > gridS_probe_stdout.txt
  ```
- `draft_quality_phase2_diag.cpp` — WHY the probe does not fire on Phase-1's
  genuine-divergence counterexample (D1 mechanism): the draft plateau is tight-
  STATIONARY (probe_flip == 0 at every budget; tightmove decays to 0 as OC
  re-converges), while a full tight re-run from the rung's ENTRY seed moves the design
  ~0.15 (the divergence is upstream/basin, invisible to a from-the-plateau probe).
  ```
  c++ "${FLAGS[@]}" core/tests/harness/draft_quality_phase2_diag.cpp build/libtopopt.a -o build/diag
  ./build/diag > gridS_diag_stdout.txt
  ```
- `draft_quality_phase2_scale.cpp` — D4: the loose-trajectory WIN across three grid
  sizes (16x8x16, 24x12x24, 32x16x32), both postures, with probe cost at scale.
  ```
  c++ "${FLAGS[@]}" core/tests/harness/draft_quality_phase2_scale.cpp build/libtopopt.a -o build/scale
  ./build/scale > scale_stdout.txt
  ```
- `run_d5_identity.sh` — D5: draft OFF byte-identical. Builds the branch lib (phase-2
  applied) and runs the B1 identity probe (draft OFF, references no draft field);
  stashes the tracked core changes back to pre-phase2 (== origin/main), rebuilds, runs
  again; identical checksums prove draft-OFF is byte-for-byte unchanged by phase 2.
  ```
  zsh core/tests/harness/run_d5_identity.sh > d5_identity.txt
  ```

## Determinism / thermal discipline

Every classification flip / CG count is deterministic (the base probe's lineage; a
repeated run reproduces the terminal design bit-for-bit). Each config runs ONCE;
wall-clock is thermally contaminated (handoff 113) and is corroboration only. Runs are
taskpolicy-niced to the utility QoS band. `ctest` is green with the changes applied.

## Postures

`configure_production_options` arms Active Domain (AUTO) since handoff 187 — a
deliberately NON-bit-identical approximation. So Phase-1's pre-187 numbers do not
bit-reproduce on current main under the production posture. The harnesses expose both:
AD-on (production, `simp.active_domain_band = -1`) and AD-off (`= 0`, Phase-1's solve).
AD-off reproduces Phase-1's tight baseline exactly (total_cg 95303).

## scale harness env selectors

`draft_quality_phase2_scale.cpp` honors two optional env vars for focused runs:
- `TOPOPT_SCALE_GRIDS` — subset by first letter, e.g. `L` or `S,M` (default all three).
- `TOPOPT_SCALE_AD` — `on` or `off` to run one posture (default both). AD-on tight can
  fail to converge on the 32³ restricted domain (multigrid stall → matfree throw), so
  the win-vs-scale trend is taken AD-off (`TOPOPT_SCALE_AD=off`), which converges and
  reproduces Phase 1's 2.07×@16³ and 1.53×@32³ exactly.
- `TOPOPT_SCALE_CGCAP` — per-solve CG cap; NOTE the matfree solver THROWS if a solve
  cannot reach 1e-8 within the cap, so it does not bound a stagnating tight baseline
  (left documented, not used for the reported numbers).
