# Evidence — adaptive move limit, Phase 1

Produced by `core/tests/harness/adaptive_move_probe.cpp` (production posture:
MMA + matrix-free MG + conditional projection + AUTO active domain, ladder
{0.68,0.52,0.38,0.26}). Three runs per grid: FIXED (adaptive OFF, cg 1e-8),
CONTROL (adaptive OFF, cg 1e-9 — the M2 basin floor), ADAPT (adaptive ON, cg 1e-8).

`<grid>_summary.txt` — the probe's M2-M6 tables for that grid.
`<grid>_periter_{fixed,adapt}.csv` — per-iteration record: tag, rung, iter,
compliance, change, beta, move, osc_fraction, plateau.
`walltimes.txt` — fixed/control/adapt wall-clock per grid.

Grids: small = 24×8×24 loadcase (2016 solid); medium = 32×12×32 (5376);
large = 40×16×40 (11200); box = 24×8×24 part wrapped in a 1.6× design box
(solved 40×8×40, 11552 solid — the dilute marathon regime).

## Headline (M3, outer-iteration reduction ADAPT vs FIXED)

| grid | solid | Σ fixed | Σ adapt | reduction |
|---|---|---|---|---|
| small loadcase | 2016 | 659 | 645 | +2.1% |
| medium loadcase | 5376 | 636 | 640 | −0.6% |
| large loadcase | 11200 | 687 | 687 | 0.0% |
| box (dilute) | 11552 | 830 | 828 | +0.2% |

NO-GO on the 20% bar: noise-level, does not scale, absent in the dilute regime.
Gates identical on every rung (M5); terminal design exceeds the basin floor on at
least one rung per grid (M4) — gate-equivalent, not design-equivalent. Mechanism:
the fixed run's step is genuinely pinned at 0.2 (max step 0.1998) but the adapted
run's step exceeds 0.2 on only ~13/645 iterations (small grid), all in a high-β
structural stage — the trust region is not the binding constraint on convergence.
See the handoff for the full analysis.
