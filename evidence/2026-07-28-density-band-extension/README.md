# Evidence — density-band extension (both ends)

Offline study extending the octet homogenized-material certifiable band from
rho 0.15–0.62 (PR 234) to **rho ≈ 0.05 → 0.90**. Read-only harness, **no production
change** (B4). Handoff: `docs/handoffs/2026-07-28-density-band-extension.md`.

## The number

**Certifiable band = rho ≈ 0.05 → 0.90.**
- Low end bounded at **0.05 by COMPUTE** (vpc96 → 9 vox/strut → clean drift +0.84 %).
- High end bounded at **0.90 by VALIDATION REACH** (real periodic tensors converged
  < 2.4 % to 0.90; the old 0.591 ceiling was a library clamp, not physics).

## Files

| file | what |
|:--|:--|
| `lattice_band_extend_probe.cpp` | the harness (also in `core/tests/harness/`) |
| `self_check.csv` | B1 — solid cell recovers E₁₀₀=3500.0000 to 4 digits (vpc 8/16/24/32) |
| `repro_band.csv`, `repro_stdout.txt` | B3 — existing band rho 0.15–0.54 reproduced, model err ≤ 2.39 % |
| `plan_geometry.csv` | geometry-only: vox/strut ladder + analytic-vs-measured rho (picks vpc per rho) |
| `low_end.csv`, `low_stdout.txt` | L1/L2/L3 — low rows at vpc {48,64,96,128}, matched-rho, cost (DOF/ms/RSS) |
| `analyze_low.py`, `analyze_low.txt` | curve-corrected CLEAN drift (removes the density-landing artefact) → floor |
| `high_end.csv`, `high_stdout.txt` | L5/L6/L7/L8 — real tensors to 0.90 vs frozen clamp, analytic-vs-measured, Zener |
| `proposed_octet_rows.txt` | the updated offline library: full kOctet (5 new low + 7 new high rows) |

## Key results

- **B1** solid-cell E₁₀₀ = 3500.0000 (rel < 1e-6) at every vpc; cubic(iso)==hex8_stiffness
  bit-identical (max|ΔK|=0).
- **B3** library-vs-periodic model error ≤ **2.39 %** across rho 0.15–0.54 (the +2.39 %
  at rho 0.451 is PR 234's exact value) → band unchanged.
- **LOW** (`analyze_low.txt`): every rho 0.05–0.148 converges to **clean drift < 2.4 %**
  at ≥ 6 vox/strut. Floor = **0.05** (vpc96, +0.84 %). The raw per-vpc drift (up to
  ±23 %) is a voxel density-landing artefact; corrected against the vpc128 truth curve
  it collapses to < 2.4 %.
- **HIGH** (`high_end.csv`): frozen clamp under-stiffness measured and fixed —
  **+8.7 % @0.615 → +153 % @0.90**; all rows drift < 1.42 % vs vpc64 (validated). The
  analytic cylinder-sum rho over-counts the measured rho by **+66 % → +138 %** (strut
  merge) — library keys on measured. Zener dips to ~0.85 then **rises to 0.923 @0.90**
  (octet trends toward isotropy as voids close).

## Reproduce

```
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_band_extend_probe.cpp build/libtopopt.a -o build/lbx
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=self  ./build/lbx     # B1  (seconds)
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=repro ./build/lbx     # B3  (~1 min)
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=plan  ./build/lbx     # ladder (~4 min)
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=high  ./build/lbx     # L5-L8 (~25 min)
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=low   ./build/lbx     # L1-L3 (~90 min; vpc128 refs)
python3 analyze_low.py                                            # clean drift + floor
```
Machine: 6-P-core / 16 GiB Mac. Largest solve vpc128 single cell = 2.05 M voxels /
6.29 M periodic DOF, 9–11 min at ~2.1 GB.
