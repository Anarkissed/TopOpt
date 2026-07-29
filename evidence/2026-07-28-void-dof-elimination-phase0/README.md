# Evidence — void-DOF elimination Phase 0 (2026-07-28)

- `void_dof_probe.cpp` — the standalone measurement harness (copy of
  `core/tests/harness/void_dof_probe.cpp`). NOT a CTest target.
- `void_dof_probe.out` — the full run: fixture census, per-rung optimize,
  E1+E2 tables (6 thresholds × 4 rungs), and the E4 full-vs-reduced CG solves.

Notes on reading `void_dof_probe.out`:
- The E4 header line prints `Jacobi-CG cap=30000`; the actual cap used for this
  run was **6000** (visible in the severed-system rows that report `iters=6000`
  with a non-convergence exception). The committed harness source prints 6000.
- `lpc` column in the E1/E2 table = load_path_connected on the reduced set
  (Y=connected, N=severed). `float` = floating (non-anchored) surviving-solid
  components counted by the reused handoff-169 26-connectivity flood-fill.
- Rungs vf=0.38 / 0.26 diverge (compliance 640 / 1669) and their optimize is
  slow (138 s / 110 s per 25 iters) — that IS the stagnation regime (BAR B1),
  captured at its last iterate.

See `docs/handoffs/2026-07-28-void-dof-elimination-phase0.md` for the full read.
