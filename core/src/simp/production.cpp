#include "topopt/production.hpp"

#include "topopt/fea.hpp"   // fea_set_matfree_galerkin_block_cache
#include "topopt/simp.hpp"  // SolverKind, projection_supported, heaviside_continuation_schedule

namespace topopt {

void configure_production_options(MinimizePlasticOptions& opts) {
  // Matrix-free geometric-multigrid solver (handoff 079/091). Never assembles
  // the fine stiffness K; solves the identical system to the same tolerance,
  // with an exact Jacobi-CG fallback. This is the setting whose absence made the
  // CLI OOM / mis-solve relative to the app.
  opts.simp.solver = SolverKind::MultigridCG_Matfree;

  // Physical minimum-feature length scale (mm); the driver derives each rung's
  // voxel filter radius from grid spacing, so member thickness is resolution
  // independent. Set for BOTH updaters (it is a filter radius, not projection),
  // keeping the OC + projection Gate-V2 chain byte-identical.
  opts.min_feature_mm = 2.5;

  // Heaviside projection + beta continuation for crisp near-0/1 density — ONLY
  // when the updater supports it (OC). MMA, the production default updater,
  // rejects a projection schedule (simp_optimize throws on MMA + non-empty
  // projection), so with MMA we skip projection and rely on the min-feature
  // filter. Gating here is exactly what the bridge's old enable_projection did.
  if (projection_supported(opts.updater))
    opts.simp.projection = heaviside_continuation_schedule();

  // MMA Heaviside projection + beta continuation (handoff 116) — the MMA-CORRECT
  // analogue of the OC-locked `projection` schedule above. `projection` is
  // Gate-V2's OC formulation and MMA rejects it (handled just above); this is the
  // SEPARATE opt-in that carries the projection chain-rule through the MMA moving-
  // asymptote subproblem, so the two mechanisms stay mutually exclusive. Guarded
  // to the MMA path: with updater == OC the block above already set the `projection`
  // schedule and mma_projection would be rejected as an exclusive pair, so we only
  // flip it on when MMA actually owns the run (the production default). The driver
  // threads options.simp.mma_projection to every rung; beta0/beta_max keep their
  // SimpOptions defaults (1 → 32, the conservative OC-tested cap).
  //
  // THE PRODUCTION FLIP (handoff 116 evidence). Before this line the MMA
  // production ladder shipped a GRAYSCALE density: discreteness Mnd ≈ 0.559 and a
  // sub-threshold fringe that carried real mass in Σρ but nothing in #{ρ>0.5},
  // making volume_fraction and printed_fraction disagree by up to ~0.09. With
  // projection on, Mnd collapses 0.559 → 0.032, compliance IMPROVES (88.1 → 38.1;
  // the gray fringe was soft ρ³-penalized material), the volume-basis divergence
  // collapses 53× (0.0265 → 0.0005 — the constraint now measures what prints), and
  // min-feature holds as strongly as OC (within OC's accepted 2×2×2 regime; the
  // 2.5 mm filter contract is unchanged). THE COST: ~1.9× ladder iterations vs
  // today's warm-gray production — the run is SLOWER in exchange for a finished,
  // honest design. The stale-preconditioner task (lever B) is the designated payer
  // and follows next.
  //
  // The library default stays mma_projection == false (Gate-V2 and every core
  // reference run never call this function, so they remain byte-identical); this
  // opt-in lives at the production entry points only, exactly like the solver and
  // min-feature settings above.
  if (opts.updater == SimpUpdater::MMA)
    opts.simp.mma_projection = true;

  // Enable the process-global matrix-free Galerkin block cache (handoff 091):
  // bit-identical, a pure compute saving. Set here so "production run configured"
  // implies "cache on" for every production front-end, with no per-caller copy to
  // drift. See production.hpp for why this is a global rather than an opts field.
  fea_set_matfree_galerkin_block_cache(true);
}

std::vector<double> production_reduction_ladder() {
  return {0.68, 0.52, 0.38, 0.26};
}

}  // namespace topopt
