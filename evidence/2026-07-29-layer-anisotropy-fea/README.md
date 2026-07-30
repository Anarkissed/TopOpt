# Evidence — layer-line anisotropy in the lattice FEA (2026-07-29)

Companion to `docs/handoffs/2026-07-29-layer-anisotropy-fea.md`. Measure-and-report
only; no gate or production change. Builds on PR 245 (`lattice-layer-anisotropy`,
the octet measurement + rotation machinery) and PR 246 (`tensor-library-nine`, which
already refuses BCCZ/FCCZ/reentrant as tetragonal).

## Files

- **`literature-survey.md`** — STEP 1 D2/D3. Published transversely-isotropic FFF
  constants for ASA/PLA/PETG, every number with author/DOI + print conditions;
  paywalled/unusable sources flagged and NOT used. The source of the interlayer
  ratios (PLA 0.44, PETG 0.38–0.74, ASA 0.86–0.90) and the "no full 5-constant set
  exists for ASA/PETG at FFF conditions" finding that drives the BLOCKED-STOP.
- **`lattice_orientation_probe.cpp`** — the offline harness (copy of
  `core/tests/harness/lattice_orientation_probe.cpp`). Extends PR 245's octet probe
  with a BCCZ generator, a fixed-load orientation sweep, and a 3-material pass.
  Self-contained hex8 integrator (verified against production `hex8_stiffness` /
  `hex8_stiffness_transverse`), full 4th-order tensor rotation, periodic-BC
  homogenization, micro-stress interlayer recovery. NOT in CTest.
- **`sweep_vpc28.txt`** — full console output at vpc=28 (>4 voxels/wall): the four
  self-checks (all PASS) and the per-material/per-topology orientation tables.
- **`anisotropy_sweep.csv`** — machine-readable: `material, topology, rho, build_deg,
  E_build(=E along load, MPa), E_side(=E along part-z, MPa), r_int_vm, margin_k_over_r,
  k, cg_iters`. (Column names `E_build`/`E_side` are the CSV header from the harness;
  in the fixed-load framing they are E along the load axis and E along part-z — see
  the .txt header and the handoff.)

## How to reproduce

```
cd core
cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_orientation_probe.cpp build/libtopopt.a \
    -o build/lattice_orientation_probe
TOPOPT_LATTICE_CSV_DIR=../evidence/2026-07-29-layer-anisotropy-fea \
TOPOPT_ANISO_VPC=28 ./build/lattice_orientation_probe
```

## Headline numbers (PLA, vpc=28)

- **Octet:** interlayer margin `k/r` swings **~6×** with print orientation — 2.82
  (build ⊥ load) to 0.46 (build ∥ load). Octet geometry is near-isotropic, so this
  is almost entirely the layer effect. Reproduces PR 245.
- **BCCZ:** printed flat (pillars ∥ build), sideways load: **E along load ≈ 92 MPa
  vs 213 MPa along the pillars (~2.3× softer sideways)** — a geometric weakness,
  confirming the maintainer's instinct. But interlayer is *best* flat (`k/r ≈ 1.51`).
  Printing on-edge (build 45°) does NOT improve sideways stiffness (~83 MPa) and
  drops the interlayer margin to `k/r ≈ 0.68` (now governing). BCCZ is also already
  gate-refused on main (PR 246, tetragonal). Fix is a design change (pillars along
  the load), not a bed reorientation.

`k = z_knockdown` (PLA 0.55, PETG 0.70, ASA 0.60) is an ASSUMPTION (ARCHITECTURE.md
§6). The orientation *ranking* is robust to its value; any *absolute* certified
margin is not — see the handoff's B5.
