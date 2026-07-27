Constrained smoothing with re-certification — device-real evidence (2026-07-26)
Built from this worktree: core/build/topopt-cli (OCCT+Eigen via Homebrew).

  job_stl.json         demo L-bracket job (STL output; lib3mf absent on this box)
  run/                 `topopt-cli run` output: variant_0{30,50,70}.stl + report
  smooth/sXXX/         `analyze --mesh variant_030.stl --smooth 0.XX` output:
                         analysis.json (provenance), analysis_report.json, fields.bin,
                         variant_030_smoothed.stl (the exported smoothed mesh)
  smooth/v0{5,7}0_s050 strength 0.50 on the fatter variants (CG converges there)
  smooth/s100_nomf     strength 1.0 with --no-min-feature (constraint OFF contrast)
  smooth/s000, off_a   analyse WITHOUT smoothing (baseline + S6 template)
  smooth/det_a         one of the S5 determinism runs (cmp'd against a second run)
  receipt_table.txt    per-strength drift/min-feature/margin table
  frozen_bit_identity.txt  device-real S1 (device_s1_check.cpp on variant_030.stl)
  byte_identity.txt    S5 + S6 proofs
  cg_convergence_note.txt  the variant_030@0.50 re-cert CG failure (honest limit)
