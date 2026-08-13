# path validation — resolution 48, NOT a measurement

★ **THESE NUMBERS ARE NOT COMPARABLE TO ANYTHING ELSE IN THIS DIRECTORY AND MUST
NOT BE QUOTED AS A RESULT.** The grid is 48, not 128, so the margins, the
roughness and the counters all belong to a different object. It is here to answer
one question and one only:

> does the whole shipped path — job schema → `PlsmOptions` → `plsm_optimize` →
> the driver's certification callback → the receipt and the `_alpha.meta` — work
> end to end, before six hours of state solves are spent on it?

It does, and here is what it proved, per rung, in about four minutes:

* `ersatz fraction`, `sens_weight discrete` — the new defaults reach the run.
* `plsm_frozen_floor_occupancy 0.9091549431` — which is `H_eta(h/2)` at
  **eta = 1** exactly (it is 0.7375 at eta = 2), so item 1 is in force and
  measurable rather than asserted.
* `plsm_knots_vox [2, 2, 2]` — the derived rule fired; the job named no spacing.
* ★ `stop_reason margin-plateau` on **all four rungs**, each returning
  `margin_peak_iteration 4` — the rule fires, and it returns the PEAK.
* ★ the margin-probe CURVE is written per rung, with its load-path flag:

      rung 0.68   it4 5658.97   it8 5659.01   it12 5653.19
      rung 0.38   it4 5423.47   it8 5409.57   it12 5423.76

  ★ **The 0.38 row is the tolerance doing its job**: iteration 12 reads HIGHER
  than iteration 4 — by 0.006%, far inside the 0.5% band — so it does not count
  as an improvement, the run stops, and iteration 4's design is what ships. The
  alternative would be re-selecting the shipped design on noise.
* the topology counters land in both the receipt and the sidecar
  (`void_components 7`, `void_chi 5`, `void_tunnels 2`, `void_sealed_pockets 0`).
* the fraction's cost is measured, not estimated (`frac_sample_wall_s`,
  `frac_sens_wall_s`, `frac_cut_cells 67`).

★ **AND ONE THING IT RULED OUT.** Read mid-run, `run_info.json` carries the
CONFIG fields and zeros for every MEASURED one — because the final receipt is
written at the end, deliberately, so an unfinished run claims nothing. That looked
like a plumbing bug for about a minute. It is not: the completed file above
carries all of them.
