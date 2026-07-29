# Evidence — Conditioning Stage 0 (2026-07-28)

Measurement harness output for the stiffness-rescaling (Lever A) and rho_min
(Lever B) conditioning probe. READ-ONLY: no production code or default changed.
See the handoff: `docs/handoffs/2026-07-28-conditioning-stage0.md`.

## Contents

- `conditioning_probe.cpp` — the harness source (copy of
  `core/tests/harness/conditioning_probe.cpp`).
- `format_tables.py` — renders the CSVs into the handoff's markdown tables.
- `grid16/` — 16×8×16, all phases (cond + combo + design), full CSVs. The
  complete small-scale characterization, including the raw + explicit-rescaled CG
  columns and the S4 design-cost sweep.
  - `run.log` — full stdout.
  - `cond_sweep.csv` — S1/S2/S3: per rung × contrast — cg_unprecond, cg_jacobi,
    cg_rescaled, kappa_lanczos, lambda_min/max, mg_used, mg_hier_built, mg_cycles,
    mg_cg_iters, mg_converged.
  - `design_cost.csv` — S4: per rung × contrast — solid counts, changed voxels,
    frac_changed, margin_baseline/variant, margin_sign, accepted flags.
- `upsample/` — S5 scaling. The converged 16³ deep-rung field nearest-neighbour
  upsampled to 16/32/48/64³; production MG carry (mg_used) + cycles at contrast
  1e-9 vs 1e-6. `upsample_s5.csv`.

Note: a native FAST cond run at 48³/64³ was attempted but the deep-rung baseline
optimize STALLS under the (stagnating) production MG at that scale — the
stagnation reproduces, but too slowly to tabulate a clean per-contrast table at
Stage 0. The upsample phase is the cheap, isolated S5 substitute (see the handoff
S5 caveat: upsampling is more MG-coarsenable than a native field, so it
understates stagnation).

## What the columns mean

`contrast` is the stiffness floor E_min/E0. The SIMP law is
`E(rho)=clamp(rho,density_min,1)^p·E0`, p=3, so `density_min = contrast^(1/3)`.
Baseline (production) is contrast 1e-9 ⇔ density_min 1e-3. Both are printed.

- `cg_unprecond` — unpreconditioned CG iters on K (raw conditioning; saturates at 40000).
- `cg_jacobi` — Jacobi-CG iters on K = **the production penalized solve**.
- `cg_rescaled` — unpreconditioned CG on S·K·S, S=diag(K)^(-1/2) = **Lever A explicit**.
- `mg_used` — 1 if production geometric-MG carried; 0 if it fell back to Jacobi (stagnation/build-rejection).

## Reproduce

```bash
cd core
cmake -S . -B build-cond -DCMAKE_BUILD_TYPE=Release -DEigen3_DIR=/opt/homebrew/share/eigen3/cmake
cmake --build build-cond --target topopt -j8
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/conditioning_probe.cpp build-cond/libtopopt.a -o /tmp/cond_probe

# small complete run (all phases + CSVs)
TOPOPT_COND_CSV_DIR=<evidence>/grid16 TOPOPT_COND_NX=16 TOPOPT_COND_NY=8 TOPOPT_COND_NZ=16 \
  TOPOPT_COND_PHASE=all /tmp/cond_probe

# larger stagnation hunt (Jacobi + Lanczos + MG only)
TOPOPT_COND_FAST=1 TOPOPT_COND_CSV_DIR=<evidence>/grid48 \
  TOPOPT_COND_NX=48 TOPOPT_COND_NY=24 TOPOPT_COND_NZ=48 \
  TOPOPT_COND_PHASE=cond /tmp/cond_probe
```

Env: `TOPOPT_COND_PHASE` = cond|design|combo|upsample|all; `TOPOPT_COND_FAST`
skips the raw + explicit-rescaled CG; `TOPOPT_COND_MAXITER` caps the baseline
optimize (cond/combo operator sourcing only — never S4); `TOPOPT_COND_N{X,Y,Z}`
set the fixture dims; `TOPOPT_COND_CSV_DIR` selects the CSV sink.

```bash
# S5 scaling test (upsample the 16³ deep-rung field to 64³)
TOPOPT_COND_CSV_DIR=<evidence>/upsample TOPOPT_COND_PHASE=upsample /tmp/cond_probe
```

Iteration counts, kappa, changed-voxel counts and margins are deterministic.
