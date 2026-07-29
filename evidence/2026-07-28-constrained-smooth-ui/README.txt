Evidence — constrained smoothing with re-certification (handoff
2026-07-28-constrained-smooth-ui). Device-real unless noted; the CLI is
core/build/topopt-cli built from this worktree.

FILES
  receipt_table.txt        THE RECEIPT IS REAL (bar S3): the per-strength margin
                           drop + the ACCEPTED->REJECTED flip + the min-feature
                           safety, read out.
  cli_receipt_transcript.txt   the raw topopt-cli console for the whole sweep
                           (solid, strengths 0.05-1.00 min-feature OFF, and 1.00
                           min-feature ON), verdict + provenance line + both masses.
  cog_bar.stl              the synthetic cog specimen (written by the unit test's
                           opt-in dump), the input to every CLI row.
  job.json                 the loadcase job: anchor face 20, traction 3550 N on
                           face 21, PLA, resolution 48. Re-run any row from this.
  out_solid/               the un-smoothed certification (analysis.json + report).
  out_s0.20/               the crossing: smoothed strength 0.20 -> margin 1.122
                           REJECTED. analysis.json shows smoothed=true + both masses
                           + the quantization footnote; cog_bar_smoothed.stl is the
                           exported smoothed mesh.
  out_s1.00/               full strength, min-feature OFF (margin 1.066 REJECTED).
  out_mfon/                full strength, min-feature ON — the SAFETY: 0/20 pairs
                           applied, min_feature_limited, margin 1.635 ACCEPTED.

WHAT THE BARS MAP TO
  S3 (the receipt is real)   receipt_table.txt + cli_receipt_transcript.txt +
                             core test_smooth_recert_loadcase (30 checks): solid
                             ACCEPTED -> smoothed REJECTED, verdict flip, min-feature
                             safety. THE HEADLINE.
  S4 (drift vs bound)        reported per strength in the transcript + analysis.json
                             volume_drift_fraction / volume_drift_bound; honestly
                             exceeds the small-perturbation bound for rib-rounding.
  S5 (determinism)           smooth 0.40 twice -> smoothed STL + analysis_report.json
                             + fields.bin byte-identical (cmp clean; done in-session).
  S6 (off == byte-identical) analyse-without-smooth provenance carries ZERO smoothing
                             keys (out_solid/analysis.json); core self-weight analyze
                             regression (test_analyze_fixed_design 22/0) unchanged by
                             the loadcase refactor.
  S7 (non-convergence)       the UI honesty branch — a non-convergent re-cert returns
                             non_convergent=true / accepted=false (never a false
                             receipt); surfaced as "couldn't re-certify — try lower".
                             Proven in core (test_smooth_recert_loadcase S7 check,
                             a 1-iteration CG cap) and in the app
                             (SmoothingModelTests.testNonConvergent...).
  S8 (device-real)           every row above ran through the compiled topopt-cli.
