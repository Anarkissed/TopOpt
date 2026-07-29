# Lattice homogenized material — extending the certifiable DENSITY BAND at both ends

**Date:** 2026-07-28
**Scope:** read-only harness study. **No production change** (bar B4) — this extends
the OFFLINE library; `topopt/lattice.cpp` is left untouched. The extended rows are
emitted for a later wiring PR.
**Builds on:** PR 234 (density-band study, handoff `2026-07-28-lattice-density-band`),
PR 198 (offline homogenization library, `2026-07-26-lattice-homog-phase0`), PR 220
(lattice certification Phase 1).
**Harness:** `core/tests/harness/lattice_band_extend_probe.cpp` (standalone, not in
CTest). Evidence: `evidence/2026-07-28-density-band-extension/`.

---

## TL;DR — the new certifiable band

> **Octet homogenized material is certifiable over rho ≈ 0.05 → 0.90**, each end
> validated the way PR 234 validated the old band (periodic-homogenization truth,
> within ±2.4 %):
> - **Low end bounded at rho ≈ 0.05 by COMPUTE.** The thin struts just need more
>   voxels: at vpc96 (9 vox/strut) the periodic tensor at ρ 0.05 is converged to
>   **+0.84 %**. The old 0.148 floor was *not* a physics limit — it is where PR 198
>   stopped computing rows. Going below 0.05 is a pure-compute extension (vpc128+).
> - **High end bounded at rho = 0.90 by VALIDATION REACH, not model error.** Real
>   periodic tensors were computed and converged (< 2.4 %) all the way to 0.90; the
>   old ceiling was a **library CLAMP at 0.591** (frozen tensor wrong by ‑8 % … ‑153 %),
>   not physics. Removing it is pure library work, done here.

The two ends were genuinely different problems, exactly as the task framed them: the
low end is a **compute** problem (throw voxels at the thin struts — but beware the
raw drift is a density-landing artefact; the real resolution error is much smaller)
and the high end is a **model** problem (the frozen clamp, and an analytic density map
that over-counts because the struts merge). Both are addressed below. This *exceeds*
the maintainer's ask (0.05–0.10 low, 0.80 high).

The previously validated band (**rho 0.15–0.54 within ±2.4 %**) is **reproduced
unchanged** (B3).

---

## Method

**Truth = periodic homogenization** (PR 198's method, re-implemented here): the
effective cubic tensor of the resolved unit cell under periodic BC. It is
resolution-clean (no free surface) and its *only* error is resolution, so "validate a
row" reduces to "show the periodic tensor has CONVERGED in vpc" — drift vs a finer
reference < 2.4 %. No finite-block resolved solves are needed (PR 234 used those only
to cross-check the periodic truth; they agreed to ~1 %). Comparison metric = apparent
Young's modulus E₁₀₀ along ⟨100⟩; the full cubic triplet (C11,C12,C44) and the Zener
ratio 2·C44/(C11−C12) are reported per row.

**Matched-rho convergence.** For a convergence sweep, r is **recalibrated at each vpc**
to the target density, so the drift is a pure *resolution* measure. This matters
because the library keys on rho and, at low density, dE/dρ is so steep that holding r
fixed (which lets the voxelised rho staircase ±10 % between resolutions) would swamp
the resolution signal with a density-landing artefact. Achieved rho is reported per
vpc to prove the match. At the low end even matched-rho cannot fully pin ρ (thin-strut
voxel quantisation), so the low table additionally reports a **curve-corrected clean
drift** — each coarse point compared to the vpc128 truth *curve* interpolated to that
point's own measured ρ (`evidence/.../analyze_low.txt`).

**vox/strut is on every row.** `2·r·vpc/L` = strut DIAMETER in voxels, which PR 198
(not vpc) identified as the quantity governing octet convergence; PR 198's rule is
**6–8 vox/strut**.

### B1 self-check (instrument recovers E_solid to 4 digits)

Periodic homogenization of a fully-solid cell:

| vpc | E₁₀₀ (MPa) | rel err | Zener |
|---:|---:|---:|---:|
| 8  | 3500.0000 | +0.000000 | 1.0000 |
| 16 | 3500.0000 | −0.000000 | 1.0000 |
| 24 | 3500.0000 | −0.000000 | 1.0000 |
| 32 | 3500.0000 | −0.000000 | 1.0000 |

`hex8_stiffness_cubic(iso triplet)` vs `hex8_stiffness`: **max|ΔK| = 0 (bit-identical)**.
Same standard PR 198 and PR 234 held.

### B3 reproduce (existing validated band must be unchanged)

Library tensor vs periodic truth at the achieved ρ (`repro_band.csv`):

| target vf | rho | vox/str | E_periodic | **model err** | verdict |
|---:|---:|---:|---:|---:|:--|
| 0.15 | 0.1476 | 7.68 | 96.13 | +0.00 % | GO |
| 0.20 | 0.1961 | 9.11 | 150.04 | −1.81 % | GO |
| 0.25 | 0.2462 | 10.63 | 213.67 | −0.48 % | GO |
| 0.30 | 0.3036 | 11.70 | 301.22 | −0.69 % | GO |
| 0.35 | 0.3443 | 13.08 | 378.91 | +0.61 % | GO |
| 0.40 | 0.3979 | 14.18 | 489.22 | −0.00 % | GO |
| 0.45 | 0.4507 | 15.07 | 629.81 | **+2.39 %** | GO |
| 0.50 | 0.4973 | 16.34 | 772.34 | +1.27 % | GO |
| 0.55 | 0.5384 | 17.23 | 917.91 | +1.14 % | GO |

**model err ≤ 2.39 % across the whole mid-band → B3 REPRODUCED (band unchanged).**
The +2.39 % at ρ 0.451 is exactly PR 234's D1 value. (A secondary `reproErr` column
vs PR 234's *absolute* E table is reported but not gated — at a fixed target vf the
calibration lands on a slightly different aliasing step, PR 234's own caveat, so it
is only meaningful at matched ρ.)

---

## HIGH END (L5/L6/L7/L8) — remove the clamp, real tensors to rho 0.90

Row solved at vpc48 (PR 198's resolution), validated against periodic vpc64
(matched ρ). Frozen-clamp reference E₁₀₀ = **1124.55 MPa** (the value the library
returns for EVERY ρ > 0.591 today). `high_end.csv`, `high_stdout.txt`.

| rho (meas) | vox/str | E₁₀₀ (MPa) | **clampFix** vs frozen | Zener | drift vs vpc64 | analytic ρ | **an over** | valid |
|---:|---:|---:|---:|---:|---:|---:|---:|:--|
| 0.5909 | 18.41 | 1124.6 | −0.0 % | 0.8705 | +1.16 % | 0.981 | +66 % | GO (anchor) |
| 0.6151 | 19.05 | 1222.1 | **+8.7 %** | 0.8662 | +0.00 % | 1.050 | +71 % | GO |
| 0.6550 | 19.67 | 1395.2 | **+24.1 %** | 0.8617 | +1.42 % | 1.119 | +71 % | GO |
| 0.6987 | 21.05 | 1630.5 | **+45.0 %** | 0.8478 | +1.10 % | 1.281 | +83 % | GO |
| 0.7521 | 22.16 | 1907.0 | **+69.6 %** | 0.8625 | +0.88 % | 1.420 | +89 % | GO |
| 0.7975 | 23.69 | 2165.5 | **+92.6 %** | 0.8744 | −0.71 % | 1.623 | +103 % | GO |
| 0.8512 | 25.16 | 2525.6 | **+124.6 %** | 0.8947 | +0.90 % | 1.831 | +115 % | GO |
| 0.8999 | 27.18 | 2848.1 | **+153.3 %** | 0.9234 | −0.25 % | 2.138 | +138 % | GO |

**L5 — the clamp was real model error, now measured and fixed.** The frozen tensor
under-predicts the true modulus by 8.7 % at ρ 0.615, growing to **+153 % at ρ 0.90**
(the frozen 1124.6 MPa is barely a third of the true 2848 MPa). This is the same
error PR 234 reported as −16 %/−31 %/−60 % (their sign is frozen-below-truth; here
clampFix = truth-above-frozen: −16 % ≡ +19 %, −60 % ≡ +150 %). Every row is a real
computed tensor, not the frozen one.

**L6 — the analytic density map breaks; the library must key on MEASURED ρ.** The
thin-strut cylinder-sum ρ(r) over-counts the measured (voxelised, union-correct)
density by **+66 % already at ρ 0.591 and +138 % at ρ 0.90**, because octet's 12
struts fuse at the nodes and the analytic sum double-counts the shared volume. Analytic
ρ passes 1.0 (a physical impossibility) by ρ_meas ≈ 0.60. **The measured value is the
truth and the library keys on it** — the extended rows are indexed by measured ρ.

**L7 — every new high row is converged.** Periodic vpc48 vs vpc64 drift is
**≤ 1.42 %** on every row, inside the 2.4 % bar (the high end is thick-strut,
18–27 vox/strut, so it resolves easily — the high end was never a resolution problem).

**L8 — octet stays cubic but trends toward isotropy as it approaches solid.** Zener
dips to ~0.85 near ρ 0.70 then **rises to 0.923 at ρ 0.90** (heading to exactly 1.0 at
solid). So near ρ 0.90 the material is ~8 % from isotropic and closing — as the voids
become isolated pockets the ⟨100⟩/⟨111⟩ anisotropy fades. This is useful: a
near-solid latticed cell can be certified with a nearly-isotropic tensor, and the
cubic tensor smoothly meets the isotropic solid anchor. (Off-cubic residual stayed 0
throughout — the tensor is exactly cubic, only the Zener magnitude moves.)

---

## LOW END (L1/L2/L3) — recompute low rows at 6–8 vox/strut

`low_end.csv`, `low_stdout.txt`, `analyze_low.txt`. Truth = periodic homogenization;
reference = vpc128 (matched ρ). vpc ladder chosen from the geometry plan
(`plan_geometry.csv`) so vox/strut spans 6–8 down to ρ 0.05.

**The raw per-vpc drift is dominated by a density-landing artefact, not resolution.**
Even with r recalibrated per vpc, octet's ρ(r) is a coarse voxel step function at
thin-strut densities, so each resolution lands on a slightly different ρ (e.g. ρ 0.05:
0.056 / 0.045 / 0.055 / 0.051 across vpc 48/64/96/128). At low density dE/dρ ≈ E·1.18/ρ
is steep, so a ±9 % ρ gap shows up as a ±11 % "drift" that is pure landing, not mesh
error. **The clean metric compares each coarse point to the vpc128 truth *curve*
interpolated to that point's own ρ** (`analyze_low.py`), isolating the resolution error:

| target ρ | certified vpc | ρ (meas) | vox/str | E₁₀₀ (MPa) | **clean drift** | raw drift | verdict |
|---:|---:|---:|---:|---:|---:|---:|:--|
| 0.05 | **96** | 0.0551 | 9.0 | 27.9 | **+0.84 %** | +12.00 % | CONVERGED |
| 0.06 | 64 | 0.0603 | 6.4 | 31.3 | +1.69 % | −4.26 % | CONVERGED |
| 0.08 | 64 | 0.0872 | 7.5 | 48.0 | −0.45 % | +9.09 % | CONVERGED |
| 0.10 | 64 | 0.1012 | 8.5 | 59.0 | +1.56 % | +4.81 % | CONVERGED |
| 0.12 | 48 | 0.1320 | 7.1 | 83.3 | +0.95 % | +16.34 % | CONVERGED |
| 0.148 | 48 | 0.1476 | 7.7 | 96.1 | +0.43 % | +1.53 % | CONVERGED (was floor) |

**L1 — vox/strut is the criterion, and it is visible.** The certified vpc is the
cheapest resolution reaching **≥ 6 vox/strut** (PR 198's 6–8 rule): ρ ≥ 0.12 already
resolves at vpc48, ρ 0.08–0.10 at vpc64, ρ 0.05 needs vpc96 (9.0 vox/strut). Exactly
the "throw more voxels at the thin struts" the task anticipated — vpc scales ~1/√ρ.

**L3 — the new floor is ρ ≈ 0.05.** Every ρ from 0.05 to 0.148 has a resolution whose
**clean drift < 2.4 %** (PR 234's achieved accuracy) at ≥ 6 vox/strut. ρ 0.05 sits at
+0.84 % (vpc96) — comfortably inside. Below 0.05 was not measured; it is a pure-compute
extension (vpc128+ for ≥ 6 vox/strut) with no new physics. The old 0.148 floor was
**not a physics limit — it was simply where PR 198 stopped computing rows.**

The library values for the new low rows are taken at the finest resolution (vpc128,
the converged truth); they connect smoothly to the existing 0.148 row (my vpc128
ρ 0.146 gives E₁₀₀ 94.7 vs the library's 96.1 — within 1.5 %) and the low-ρ Zener
rises to ~1.80 (matching PR 198's "octet 1.61 at ρ0.10"; here 1.66 at ρ 0.099).

---

## Cost (L2 / B3-B4, 6-P-core / 16 GiB Mac)

Periodic homogenization single cell, matched-ρ, Eigen diagonal-preconditioned CG,
tol 1e-9:

| solve | active periodic DOF | wall time | peak RSS |
|:--|---:|---:|---:|
| vpc48  (all densities) | 26 k – 100 k | 3–18 s | < 0.6 GB |
| vpc64  (high ρ, dense) | 0.2 M – 0.7 M | 40 s – 4 min | < 0.6 GB |
| vpc96  (low ρ) | ~0.2 M – 0.4 M | 4–5 min | ~2.1 GB |
| **vpc128 (low ρ, the low-end reference)** | 0.4 M – 0.9 M | **9–18 min** | **~2.1 GB** |

Cost scales ~vpc³. The largest solve here (vpc128 single cell = **2.05 M voxels,
6.29 M periodic DOF**) is ~4× PR 198's largest resolved solve (512 k vox / 1.5 M DOF,
"minutes"); it runs in 9–11 min at ~2.1 GB — well inside the 16 GiB envelope. The high
end never needs more than vpc64. **No coarser solve was silently substituted** — the
band is quoted against periodic homogenization at the stated reference resolution.

---

## Deliverable — the updated tensor library

The extended offline library (`evidence/.../proposed_octet_rows.txt`) is the full
`kOctet` array: **5 new low-density rows** below the old 0.148 floor (down to 0.050,
vpc128 converged truth) + the 7 existing mid-band rows unchanged + **7 new
high-density rows** above the old 0.591 clamp (up to 0.900, vpc48 validated vs vpc64).
It keys on **measured** ρ (L6). New `lattice_rho_min ≈ 0.050` (was 0.148),
`lattice_rho_max ≈ 0.900` (was 0.591).

**This is offline** — a follow-on PR wires the rows into `topopt/lattice.cpp` (extend
`kOctet`, which automatically moves `lattice_rho_min`/`lattice_rho_max` since they read
the resolved span) and, for the near-solid rows (ρ ≳ 0.85), rides the de-homogenization
step named in `2026-07-26-lattice-homog-phase0` for strut-level strength (the stiffness
tensor itself is converged and validated here). B4 respected: no production file changed.

## Reproduce

```
cd core
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_band_extend_probe.cpp build/libtopopt.a -o build/lbx
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=self  ./build/lbx    # B1
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=repro ./build/lbx    # B3
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=plan  ./build/lbx    # vox/strut ladder + analytic
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=high  ./build/lbx    # L5-L8
TOPOPT_LATTICE_CSV_DIR=<dir> TOPOPT_BX_ONLY=low   ./build/lbx    # L1-L3  (slow: vpc128 refs)
```
Knobs: `TOPOPT_BX_LOW_VFS`, `TOPOPT_BX_LOW_VPCS`, `TOPOPT_BX_HIGH_VFS`,
`TOPOPT_BX_HIGH_VPCS`, `TOPOPT_BX_DRIFT_TOL` (2.4), `TOPOPT_BX_VPS_TARGET` (6).
