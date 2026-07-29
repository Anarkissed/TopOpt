# Deflation Phase 0 — evidence

Measurement backing `docs/handoffs/2026-07-28-deflation-phase0.md`: deflated CG using the
rigid-body modes of connected **solid** components (Jönsthövel et al. 2011), measured on
REAL per-rung design fields. Read-only; NO production change.

## What the probe does (`deflation_probe.cpp`)

Standalone harness (NOT wired into CTest). For each fixture it:
1. Runs the production ladder `{0.68,0.52,0.38,0.26}` via `minimize_plastic` (gravity off
   so the RHS reconstruction is exact) → real per-rung converged density fields (B1).
2. Rebuilds the EXACT matrix-free operator `A = K(ρ)` at each rung's density
   (`mf_build_reduced`), and **self-checks** it by reproducing the library `mf_cg_solve`
   iteration count with its own un-deflated PCG (|Δ| ≤ 1 everywhere).
3. Labels connected printed (ρ>0.5) components, 6-conn and 26-conn (D1). No such
   voxel-grid labeler exists in the library — the belt is boolean-only (B3), so the probe
   provides the pass.
4. Builds the 6-rigid-body-mode-per-component deflation basis `U` over the reduced free
   DOFs, forms `E=UᵀAU`, and runs Jacobi-PCG once plain and once with the additive
   correction `M⁻¹ + U E⁻¹ Uᵀ` — the measured deflated-CG iteration count (D2).
5. Reconstructs the effective condition number from the exact CG→Lanczos tridiagonal
   (PCG α/β), same preconditioner including the coarse correction.
6. States memory: `k=6·n_components` vectors of length `ng` + a `k×k` solve (D4).

## Fixtures / subdirs

- `load16/` — L-bracket 16×5×16 loadcase, no box (ng=2430). Fast; the near-hinge 2-comp case.
- `load24/` — L-bracket 24×8×24 loadcase, no box (ng=7749).
- `box/`   — small bracket inside a 1.5–2× **design box** → solved 32×16×24 (ng=27045),
  the dilute stand-class regime deflation was designed for.

Each holds `deflation_<load|box>.csv` and `run.log`.

## CSV columns

`vf, status, printed, solid, ng, nc6, nc26, largest_pct, small_comps, raw_k, k,
setup_mv, mem_mb, iters_base, iters_mf, iters_defl, cut_pct, lmin_base, lmax_base,
kappa_base, lmin_defl, lmax_defl, kappa_defl`

`iters_mf` is the library baseline (self-check target for `iters_base`); `raw_k`=6·nc
before rank-drop, `k`=surviving orthonormal columns.

## Headline

`n_components ≈ 1` on every real rung (deflation dim = 6) — the design does not fragment,
even in the box regime. Measured deflation cut 12–29% (mean ~18%), below the shipped
recycler's 45%; κ improves 7–35× but iterations barely move (dense internal soft-hinge
cluster remains). Verdict: NO-GO — redundant with the recycler, which uses the identical
additive machinery and harvests the actual slow modes.

## Reproduce

```bash
python3 analyze.py load16 load24 box
```
See the handoff's Reproduce section for the build + run commands.
