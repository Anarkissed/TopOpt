# Evidence — lattice homogenized material density band + ramp (2026-07-28)

First-hand measurements for handoff `docs/handoffs/2026-07-28-lattice-density-band.md`.
Read-only harness study; **no production change**. All numbers produced by
`lattice_density_band_probe.cpp` (copied here) on a 6-P-core Mac, octet, PLA
E_solid = 3500 MPa, nu = 0.33, cell L = 5 mm.

## The question in one line
Is the homogenized octet material trustworthy across a density ramp, and can a
lattice grade continuously up to solid? **Trustworthy for rho ≈ 0.15–0.62;
the ramp lives above 0.59 where the library clamps, so it is not certifiable today.**

## Files

| file | what |
|:--|:--|
| `lattice_density_band_probe.cpp` | the harness (self / D1 / D4 / D5, env-gated) |
| `self_check.txt` | **B1** — periodic homog of solid recovers E₁₀₀=3500.0000 (rel<1e-6); cubic==hex8_stiffness bit-identical; library clamps to 1124.6 at solid limit |
| `d1_density_band.csv` / `d1_stdout.txt` | **D1/D2/D3** — model vs periodic truth + resolved finite cross-check, rho 0.15–0.90 × vpc 16/32/48, with vox/strut, achieved rho, resolution drift |
| `d1b_resolved_finite_subset_vpc32.txt` | **B2/B3** — resolved finite blocks vf 0.50/0.60 at vpc16/32 (vpc48 killed at 16+ min — B4); finite-block ≈ periodic to ~1% |
| `d4_ramp_summary.csv` / `d4_ramp_layers.csv` / `d4_stdout.txt` | **D4** — graded ramp vs hard boundary: overall E, per-layer strain error, SCF, clamped-cell count |
| `d5_ramp_length.csv` / `d5_stdout.txt` | **D5** — transition length 1–8 cells: model gap grows, SCF flat |

## Column keys

`d1_density_band.csv`: `target_vf, rho (achieved), vpc, vox_per_strut, cells,
E_periodic_MPa (truth @vpc), E_periodic_ref_MPa (@vpc48), E_library_MPa,
model_err_pct (library vs periodic@vpc), res_drift_pct (periodic@vpc vs @48),
E_resolved_finite_MPa (−1 if skipped by cost gate), fs_err_pct (finite vs periodic),
finite_gap_pct (library vs resolved finite = PR220's C2 metric), clamped (rho>0.591),
resolved_dof, resolved_ms, verdict_ref`.

`d4_ramp_summary.csv`: `design, vpc, Nl, pad_lo, Ltrans, pad_hi, E_resolved_MPa,
E_homog_MPa, model_gap_pct, scf, clamped_cells, resolved_dof, resolved_ms`.
`d4_ramp_layers.csv`: `design, layer, cell_rho, eps_resolved, eps_homog, err_pct`.
`d5_ramp_length.csv`: `Ltrans_cells, vpc, Nl, E_resolved_MPa, E_homog_MPa,
model_gap_pct, scf, clamped_cells, resolved_dof, resolved_ms`.

## Headline numbers

- **Band (vpc48):** model error ≤ 2.4% for rho 0.15–0.54; −3.35% at 0.60; **−16% at
  0.645, −31% at 0.70, −60% at 0.90** — all `[CLAMPED]`, resolution-drift ≈ 0.
- **vf 0.40 "miss" (D2):** library error at rho 0.398 = 0.00% at vpc48; PR220's 16%
  was the vpc16 resolved reference over-stiff (+16.8% resolution drift, 4.7 vox/strut).
- **Ramp (D4):** graded gap 22.0% vs hard boundary 5.8%; SCF 2.60 ≈ 2.60; 2 clamped cells.
- **Length (D5):** SCF flat 2.59–2.60 for lengths 1–8; gap 15%→28% (clamped cells 1→4).

## Caveats
- Ramp solves use vpc12 + lateral confinement + base rho 0.40. Rationale in the
  handoff: an unconfined, barely-connected rho~0.20 lattice column is near-singular
  and CG cannot solve it — a solver-conditioning limit, not the model's. The clamp
  findings are resolution-independent (D1 shows resolution drift ≈ 0 in the clamped
  band), so vpc12 does not affect the verdict.
- SCF is a crude proxy (global peak / far-field-lattice von Mises). It shows the
  concentration is lattice-internal; it does not resolve a junction-localized SCF.
