#include "topopt/production.hpp"

#include "topopt/fea.hpp"   // fea_set_matfree_galerkin_block_cache
#include "topopt/simp.hpp"  // SolverKind, projection_supported, heaviside_continuation_schedule

namespace topopt {

// Handoff 123 — the CONDITIONAL MMA Heaviside-projection grayness threshold for
// production. A converged grayscale MMA rung whose design-region discreteness
// Mnd (design_discreteness_mnd) EXCEEDS this is continued into β-projection to
// crisp it; a rung at or below it is already printable and kept as grayscale.
//
// VALUE (0.07), justified from the measured separation:
//   * CRISP baseline — a well-conditioned part that projection cannot improve
//     (PR 146's 64-scale L-bracket confirmation): warm-gray Mnd ≈ 0.02-0.03, and
//     its compliance already equals the projected design's. Projection there is
//     ~4× iterations for zero quality gain — the tax this gate exists to refuse.
//   * GRAY baseline — a part that genuinely goes grayscale (the maintainer's
//     instrumented 128³+box production run): Mnd ≈ 0.27, with 180/218/380
//     min-feature violations across the accepted rungs — the disease projection
//     cures (116 measured Mnd 0.56 → 0.03 on its coarse cantilever).
// 0.07 sits ~2.3× above the crisp ceiling (0.03) and ~3.9× below the gray floor
// (0.27): comfortably clear of crisp-run noise so the tax is never charged on an
// already-crisp part, yet far below any genuinely gray field so the polish always
// fires when it is needed. It is a production-config constant (NOT a library
// default — the library gate stays disabled at 0), echoed into run_info.json.
constexpr double kConditionalProjectionGrayThreshold = 0.07;

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

  // CONDITIONAL MMA Heaviside projection (handoff 123) — "polish only when gray",
  // superseding always-on projection (PR 146, closed unmerged). This ARMS the
  // driver's per-rung grayness gate: after each grayscale MMA rung converges, if
  // its design-region Mnd exceeds the threshold the SAME rung is continued into
  // β-projection to crisp it, otherwise the already-crisp rung is kept as-is. So
  // projection's ~4× iteration cost is paid ONLY on rungs that go gray, never on
  // parts that are already crisp (PR 146's evidence: always-on charged that 4× tax
  // for zero quality gain on well-conditioned parts). The library default leaves
  // this 0 (gate disabled) and simp.mma_projection false, so Gate-V2 and every
  // core reference run — which never call this function — are byte-identical; the
  // gate is armed only at the production entry points, exactly like the solver /
  // min-feature settings above. Inert with updater == OC (projection there is the
  // OC schedule set just above), so this line only bites the MMA production path.
  opts.conditional_mma_projection_mnd_threshold =
      kConditionalProjectionGrayThreshold;

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
