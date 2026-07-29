# Evidence — graded cell size, Phase 0 (2026-07-28)

Read-only measurement study. **No production change.** Harness:
`core/tests/harness/graded_cell_size_probe.cpp`. Handoff:
`docs/handoffs/2026-07-28-graded-cell-size-phase0.md`.

## The question

The maintainer proposes growing the octet cell with the density grade (8 → 16 mm+ as
rho → 0.05) so struts stay printable at low density. The premise: the homogenized
stiffness of a strut lattice is scale-invariant (depends on relative density + topology
only), so cell size costs nothing in certification and PR 234's low-density floor is a
*printability* limit, not a model limit.

## Verdict (one line)

The tensor **is** exactly scale-invariant (C1) — so cell size is free *in the tensor* —
**but deploying it needs ≥ ~3–5 cells across a member (C2), and this project's ~9.4 mm
members can't hold even one 8–16 mm cell (C3). Graded cell size does not rescue
low-density certification here; BLOCKED-STOP triggered.**

## Files

| file | what |
|:--|:--|
| `self_check.txt` | B1: solid recovers E100=3500.0000 (4 digits) at cells 4/8/16/32 mm; cubic==iso bit-identical |
| `c1_scale_invariance.csv` | C1: cubic tensor vs cell size 4/8/16/32 mm at fixed rho — identical to 0.0; strut d spans 8× |
| `c2_cells_per_member.csv` | C2 axial: homog error vs cells-across (5..0.5); +2.36% @1 cell, DISCONNECTED @0.5 |
| `c2b_bending.csv` | C2b bending: resolved vs homogenized-macro transverse stiffness; crosses 2.4% between 4 and 5 cells |
| `b3_printability.csv` | B3: printed strut diameter d(rho, cell) vs 0.4 mm nozzle |
| `c5_conformal_warp.csv` | C5: cubic-tensor drift + Ez/Ex anisotropy vs per-cell stretch |
| `c4_dyadic.csv` | C4: dyadic interface — connectivity (nested nodes) + SCF 1.68× baseline |
| `c6_layers.csv`, `c6_summary.csv` | C6: resolved dyadic vs conformal graded column — stiffness, SCF, strut d along ramp |
| `*_stdout.txt` | full console for each section |

## Headline numbers

- **C1:** max |ΔE100| across cells 4/8/16/32 mm = **0.000e+00**; strut diameter 0.75 → 6.0 mm (8×).
- **C2 axial ceiling:** ±2.4% by **~1 cell** (1c +2.36%, 2c +1.20%, 3c +0.81%; 0.5c DISCONNECTED).
- **C2b bending ceiling:** ±2.4% by **~5 cells as deployed** (1c +48.5% → 5c +1.78%); ~3 fundamental.
- **C3:** max certifiable cell = W/N*. 9.4 mm member → **~2–3 mm** (bending). 8 mm base = 1.18 cells; 16 mm = 0.59 cells (disconnected).
- **C5:** Ez/Ex anisotropy 1.15 at ~8% stretch → cubic tensor holds only for a few-% grade.
- **C4:** dyadic bridges with 0 extra struts/triangles (nested nodes); interface SCF 1.68× baseline.
- **B3:** rho 0.05 strut d: 8 mm cell → 0.73 mm (marginal), 16 mm cell → 1.45 mm (fine).

## Reproduce

See the handoff's Reproduce block. All sections gated by `TOPOPT_GCS_ONLY`;
`TOPOPT_LATTICE_CSV_DIR` sinks the CSVs. Resolved free-surface members use assembled
Jacobi-CG (`TOPOPT_GCS_MG=0`) — matrix-free geometric MG stalls on the sparse lattice.
