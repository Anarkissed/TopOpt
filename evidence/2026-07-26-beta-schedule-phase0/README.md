# β-continuation schedule — Phase 0 evidence

Measurement for `docs/handoffs/2026-07-26-beta-schedule-phase0.md`. READ-ONLY: no
production source or default was changed (B6). All schedule alternatives are expressed
through existing `SimpOptions` knobs (`mma_projection_beta0` / `mma_projection_beta_max`
/ `mma_plateau_flat_windows` / `mma_plateau_tol`). Draft quality pinned OFF explicitly
and echoed in every CSV row (`draft=0`, `traj_tol=1e-8`) — B7.

## Files
- `beta_schedule_probe.cpp` — the standalone harness (build/run in the handoff's Reproduce).
- `analyze.py <grid_dir>` — per-grid reducer: B1 basin floor, S1 per-β-stage buys,
  S4 per-stage plateau lag, S2/S3 schedule comparison + gate verdicts.
- `cross_grid.py small med large` — B4 cross-grid trend of the two headline findings.
- `cross_grid.txt`, `<grid>/analysis.txt` — captured outputs.
- `{small,med,large}/` loadcase grids (16×6×16 / 24×8×24 / 32×10×32, 672 / 2016 / 4480
  solid); `box/` = a dilute whole-domain design-box spot-check of the headline finding.
  Each has `periter_<schedule>.csv` (per-iteration, incl. `beta,mnd,mfv,mnd_proj,mfv_proj,
  draft,traj_tol` and full solver telemetry cg/mg for B5), `summary.csv` (per-rung gate
  verdict + terminal cross-schedule diff), `run.log`.

## Schedules (all via existing knobs)
| name | β0 | β_max | advance | what it tests |
|---|---|---|---|---|
| base | 1 | 32 | plateau (3 flat win) | SHIPPED 1→2→4→8→16→32 |
| base_ctrl | 1 | 32 | " | negative control (cg 1e-9) — B1 basin floor |
| cap16 | 1 | 16 | " | S2: is the last doubling worth it |
| cap8 | 1 | 8 | " | S2: stop even earlier |
| start4 | 4 | 16 | " | S3: skip the β=1,2 warmup |
| jump16 | 16 | 16 | " | S3: single jump, no continuation |
| jump32 | 32 | 32 | " | S3: single jump to max (infeasible on small) |
| aggr | 1 | 32 | plateau (1 flat win) | S3/S4: promote β sooner |

## Headline
cap16 (β_max=16) is a gate-identical ~7% iteration win at every scale (β=32 moves
projected Mnd by ~0.001, buys nothing). Per-stage plateau lag compounds to 18-29%
(vs PR 193's 3-5% per-run). See the handoff for the full reading and Phase-1 targets.
