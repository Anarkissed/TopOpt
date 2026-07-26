# Evidence — outer-iteration count, Phase 0

Read-only measurement. Harness: `core/tests/harness/outer_iter_probe.cpp` (drives
the actual production posture + production ladder; captures per-iteration state via
the byte-identity-safe `on_iteration` + `on_density_snapshot` hooks). Reducer:
`analyze.py`. Full write-up: `docs/handoffs/2026-07-26-outer-iterations-phase0.md`.

## Files
- `run_loadcase.log` — probe stdout for the L-bracket loadcase (24×8×24, 2016 solid,
  healthy multigrid). Contains the Q0 negative-control floor table.
- `periter_cg1e-8.csv` / `periter_cg1e-9.csv` — per-iteration rows for the loadcase
  baseline (1e-8) and negative control (1e-9). Columns: cg_tol, rung, iter,
  compliance, change_design (=maxₑ|Δxₑ|), max_dphys, mean_dphys, class_frac,
  class_count, solid, cg_iters, mg_used, hier_built, mg_levels, cycles, active_frac,
  beta, plateau, infeasible, vf.
- `box/run_box.log`, `box/periter_cg1e-{8,9}.csv` — same, DESIGN-BOX dilute regime
  (part 16×6×16 in a whole-domain box → solved 32×8×32, 4056 solid, ~17% dilution —
  the 96³-marathon posture).
- `analysis_loadcase.txt` / `analysis_box.txt` — `analyze.py` output: per-rung
  material-settle vs actual-stop, graded classification-change thresholds, dead tail,
  move-limit-bound iteration counts.
- `analyze.py` — reducer. `python3 analyze.py <periter.csv> <solved_solid_count>`.

## Reference (read-only, not produced here)
- `core/tests/fixtures/infeasible/iterations_96_designbox.csv` — a real 96³
  design-box marathon (compliance + solver telemetry, no density). Used only for the
  real-scale compliance/solver cross-check in §Q1 of the handoff.

## Headline numbers
- Q0 basin floor = **zero** classification flips in BOTH regimes (cg 1e-8 vs 1e-9
  perturbs densities up to max|Δρ|≈0.12 but flips no voxel across 0.5). Material
  threshold = ≥1 voxel flip.
- Strictly dead tail (no flip AND flat compliance) = **3–5%** (loadcase) / **2%**
  (design box) of outer iterations = the window-10 plateau-detector lag. Every rung
  plateau-terminates (not cap). No large free win in the stopping rule.
- Iterations after topology settles = **44% / 59%** — the deliberate β-projection
  crisping stages (compliance still dropping), not waste.
- Max design step pinned at the move limit in **24–36%** of iterations (Q2) — the
  per-iteration STEP, not the STOP, is the real throttle.
- SIMP penalty p=3 fixed, no continuation (Q3). Anderson applicable but poorly matched
  to MMA (Q4).
