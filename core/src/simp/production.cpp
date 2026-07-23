#include "topopt/production.hpp"

#include <thread>  // std::thread::hardware_concurrency (portable fallback)

#include "topopt/fea.hpp"   // fea_set_matfree_galerkin_block_cache
#include "topopt/simp.hpp"  // SolverKind, projection_supported, heaviside_continuation_schedule

#if defined(__APPLE__)
// Handoff 132 (C) — the ONLY platform-conditional code in /core/, and deliberately
// confined to this file: production.cpp is the production *configuration* layer, so
// a host-topology query belongs here and not in the platform-agnostic solver. This
// is <sys/sysctl.h> (a BSD libc header), NOT an Apple framework — ARCHITECTURE §3/§4
// forbid Apple *frameworks* in /core/, and nothing here links Foundation/CoreFoundation
// or changes the CMake link line. Every non-Apple target (Linux CI included) compiles
// the #else path and gets std::thread::hardware_concurrency, i.e. today's behaviour.
#include <sys/sysctl.h>
#endif

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

// Handoff 133 — the PRODUCTION Krylov recycle dimension k. The measured optimum of
// the {8, 16, 24} sweep on the void-heavy production ladder (30.9% / 48.1% / 55.4%
// CG cut, but k=24 is slower once the per-iteration correction is charged). Named
// here so the parity test asserts the echo against the constant, not a literal.
constexpr int kProductionRecycleDim = 16;

// Handoff 132 (C) — the PRODUCTION matrix-free worker-thread count.
//
// The library default (fea_set_matfree_threads(0)) resolves to
// std::thread::hardware_concurrency(): on this Apple-silicon box, 10 = 6
// performance cores + 4 efficiency cores. Handoff 113 §"STEP 0(b) — thread sweep"
// measured the matrix-free FP64 matvec across that sweep and found the E-cores buy
// essentially nothing: 6 threads 45.0 GB/s ~= 8 threads 45.0 GB/s ~= 10 threads
// 48.3 GB/s. The apply is gather/bandwidth-bound (113 §roofline: well under half
// the bus), so four extra slow cores contending for the same memory system add
// ~0-7% at best — and under sustained thermal load 113 watched a 10-thread run
// REGRESS to 36 GB/s, below the 8-thread 41 GB/s. Defaulting to the P-core count
// therefore trades away a best-case few percent for the removal of that
// thermal-regression tail, on the ladder's long sustained soak.
//
// NO CORRECTNESS SURFACE. The apply threads a deterministic 8-colour (2x2x2)
// partition of the voxel grid, so no two threads ever touch the same node and the
// accumulation order is fixed by the colour scheme, not by the thread count: the
// result is BIT-IDENTICAL for any count (see fea.hpp on fea_set_matfree_threads,
// and test_matfree_threads which asserts 1-vs-N equality). Handoff 132 asserted
// this again end-to-end at BOTH counts, 6 and 10. This is a pure performance dial.
//
// PORTABILITY. `hw.perflevel0.physicalcpu` is the count of the FASTEST core class
// on an Apple-silicon host (perflevel0 = P, perflevel1 = E). On an Intel Mac the
// key does not exist and sysctlbyname fails; on Linux/Windows the whole branch is
// compiled out. Every one of those paths falls back to hardware_concurrency —
// exactly what production does today — so this is a no-op off Apple silicon and can
// never resolve to something worse than the current behaviour.
//
// OVERRIDABLE. This only sets the thread-global; a caller that wants a different
// count calls fea_set_matfree_threads(n) AFTER configure_production_options, and
// (n <= 0) restores automatic hardware-concurrency resolution. Exposed in the
// header so the parity test can assert the echo portably rather than hard-coding 6.
int production_matfree_thread_count() {
#if defined(__APPLE__)
  int32_t perf_cores = 0;
  std::size_t len = sizeof(perf_cores);
  if (sysctlbyname("hw.perflevel0.physicalcpu", &perf_cores, &len, nullptr, 0) == 0 &&
      perf_cores > 0)
    return static_cast<int>(perf_cores);
#endif
  const int hw = static_cast<int>(std::thread::hardware_concurrency());
  return hw > 0 ? hw : 1;
}

int production_krylov_recycle_dim() { return kProductionRecycleDim; }

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

  // Handoff 132 (D) — the MIXED-PRECISION production flip is DELIBERATELY NOT MADE
  // HERE. It was implemented, gated, and BLOCKED BY ITS OWN GATE. Do not "finish"
  // this by adding fea_set_matfree_mixed_precision(true) without re-measuring.
  //
  // The proposal (113 §D): the FP32 V-cycle capability shipped complete in handoff
  // 092 but nothing production-side ever called its setter, so production has always
  // solved FP64 and echoed mixed_precision:false. 113 expected ~1.1-1.15x on the
  // iterate share for a one-line flip, since 3 of the 4 fine applies per CG iteration
  // sit inside the V-cycle and the matvec is bandwidth-bound.
  //
  // what 132 measured (full production ladder, l-bracket 48x16x48 loadcase, current
  // main = 127 latch + 128 flatness-escape, multigrid on 100% of solves, FP64 vs
  // FP32, two exact replicates each):
  //     CG iterations   fp64 40715  ->  fp32 48717   = 1.197x  (a REGRESSION)
  //       grayscale phase        13741 -> 15947      = 1.161x
  //       fired-projection phase 26974 -> 32770      = 1.215x
  // Outer MMA iterations were identical (625) and the design was unchanged
  // (mean|drho| 1e-5, identical margins and compliance) — the FP64 certificate does
  // exactly its job, so this is a COST failure, not a correctness one. The
  // regression appears in BOTH phases the conditional-projection gate (123) produces
  // and it GREW with scale (1.165x on a smaller coarsenable grid -> 1.197x here), so
  // it is not a small-problem artifact that production scale would wash out.
  //
  // WHY, MECHANICALLY. simp.cg_tolerance is 1e-8, which is essentially FP32's
  // ~1e-7 relative precision. Near convergence the single-precision V-cycle returns
  // preconditioner noise rather than a useful correction, so CG stalls and spends
  // extra iterations — the opposite end of the regime where the literature's 47-83%
  // gains (Kronbichler/Ljungkvist et al. 2019) are reported. A ~20% iteration
  // regression is not recoverable by a ~1.15x per-iteration bandwidth saving, and
  // the true cost is likely WORSE than measured: when an FP32 attempt fails to reach
  // tol in budget, solve_mgcg_matfree RETRIES the whole solve in FP64 and overwrites
  // diag.iterations with the retry's count, so the burned FP32 cycles are invisible
  // to the very counter this gate reads.
  //
  // The capability itself is untouched and still available opt-in via
  // fea_set_matfree_mixed_precision — this is a decision about PRODUCTION, not a
  // withdrawal of 092. Reviving it should mean changing what made it lose: a looser
  // trajectory cg_tolerance for the FP32 preconditioner, or FP32 only on the early
  // slack iterations. run_info.json keeps honestly echoing mixed_precision:false.

  // Handoff 133 — KRYLOV RECYCLING, armed in the JACOBI-ONLY posture (maintainer
  // decision on 133 §10). Measured: 45.4% fewer CG iterations on the void-heavy
  // design-box ladder — the 4.5k-44k-iterations-per-solve regime of 125/131 — with
  // the accepted designs reproduced to mean|drho| = 0.000000 and identical gate
  // verdicts; and EXACTLY 1.000x (to the digit, zero setup matvecs) on the healthy
  // multigrid regime, which the wrap_multigrid=false posture leaves untouched by
  // construction.
  //
  // The three settings are a package and none of them is a free parameter:
  //   * k = 16 is the measured optimum of the {8,16,24} sweep. The win is NOT
  //     monotone in k: k=24 cuts 7 more points of iterations and is SLOWER, because
  //     the per-iteration correction streams ~8*k*n bytes and past k~16 the extra
  //     columns cost more than they save.
  //   * wrap_multigrid = false restricts the correction to the Jacobi-preconditioned
  //     loop. Wrapping the V-cycle REGRESSED it 1.23x-2.07x across the whole k
  //     sweep; the +1 spectral lift is right for a weak preconditioner and
  //     spectrum-widening for a strong one, which is structural, not tunable.
  //   * reset_per_rung = false (carry the basis across rung boundaries) is the
  //     measured lifetime rule: carrying was mildly better in BOTH regimes and
  //     worse in neither, with byte-identical designs. Set on the options struct
  //     below, not here, since it is a driver policy rather than a solver global.
  // The rebuild cycle stays at the library default 1: a 4-solve-old basis measured
  // worth almost nothing (48.1% -> 2.7%) while still paying the per-iteration cost.
  //
  // Anyone changing any of these must re-run core/tests/harness/recycle_probe.cpp
  // on BOTH regimes and land new numbers; the parity test asserts the echo.
  fea_set_krylov_recycling(true);
  fea_set_krylov_recycle_dim(kProductionRecycleDim);
  fea_set_krylov_recycle_wrap_multigrid(false);
  opts.krylov_recycle_reset_per_rung = false;

  // Handoff 132 (C) — pin the matrix-free apply to the performance cores. See
  // production_matfree_thread_count() above for the measured justification (113's
  // thread sweep: 6 ~= 10, E-cores +0-7% and regressing under thermal load) and for
  // why this is bit-identical by construction. Set alongside the cache and the
  // precision flip so "production run configured" implies one known thread count,
  // which run_info.json echoes as matfree_threads. A caller may override afterwards.
  fea_set_matfree_threads(production_matfree_thread_count());
}

std::vector<double> production_reduction_ladder() {
  return {0.68, 0.52, 0.38, 0.26};
}

}  // namespace topopt
