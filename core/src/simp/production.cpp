#include "topopt/production.hpp"

#include <thread>  // std::thread::hardware_concurrency (portable fallback)

#include "topopt/analyze.hpp"  // KnockdownSpec, infill_margin_knockdown
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

// ===========================================================================
// TRIPWIRE — the ACTIVE DOMAIN production band (handoff 2026-07-26-ad-arming).
// ===========================================================================
// Do NOT change this value, and do NOT arm the band on the STRESS path or on any
// solver but MultigridCG_Matfree, without re-running BOTH:
//   * core/tests/harness/active_domain_gate.cpp  arm / stag / lowdil / recycle
//   * core/tests/harness/active_domain_escape.cpp gate168 / healthy 250 / stag
// and landing a new before/after gate table. The band CHANGES THE DESIGN (it is
// an approximation, not an exact accelerator: measured mean|drho| ~ 3.9e-6 on the
// shipped rung, ~2.95e-4 on a rejected one), so every rung's verdict and margin is
// re-gated when it moves — unlike the recycling / Galerkin / thread-pin dials,
// which are bit-identical. The escape latch (2026-07-25-ad-escape-latch) is what
// makes it safe to arm: it detects the first live band escape and reverts to the
// full domain for the rest of the run. arm without a current escape-latch build.
//
// -1 means AUTO: k is DERIVED PER JOB downstream in resolve_active_domain_band as
// active_domain_auto_band(options.filter_radius) = ceil(rmin) + 1, where
// options.filter_radius is physical_filter_radius(min_feature_mm, spacing). k is
// therefore NEVER a literal here — it tracks the rung's real grid spacing (4 on a
// 1.0 mm grid, 3 on a 2.5 mm grid), which is the whole point of AUTO. The parity
// test asserts this resolution on a real production run.
constexpr int kProductionActiveDomainBand = -1;  // AUTO

// ===========================================================================
// TRIPWIRE — the DRAFT-QUALITY production loose trajectory tolerance
// (handoff 2026-07-26-draft-arming).
// ===========================================================================
// Before changing this value — or arming/disarming draft_quality, the escalation
// trigger, or moving the loose endpoint — re-run BOTH:
//   * core/tests/harness/draft_arming_gate.cpp interaction  (the A5 three-way stack:
//     recycling x AD x draft — does any pair silently degrade another)
//   * core/tests/harness/draft_quality_phase2_scale.cpp     (the win-vs-scale trend;
//     the win TRACKS THE STAGNATION FRACTION, not grid size, and FALLS across the
//     size endpoints — 2.07x at 16^3 -> 1.53x at 32^3 — so a new value's payoff must
//     be re-measured at scale, never assumed to transfer)
// and land a new before/after gate table.
//
// Draft is the SECOND production dial that is NOT bit-identical when on (the active-
// domain band is the other). The loose trajectory solves answer a slightly different
// question than the tight ones, so the mid-ladder TRAJECTORY drifts on some rungs
// (185 measured non-terminal REJECT rungs flipping 0.05-0.15 of their solid voxels
// under aggressive loose tolerances). What is NOT drifted is the shipped part: the
// FINAL compliance + stress-recovery solves ALWAYS run at the tight cg_tolerance
// (part c), asserted in simp.cpp / minimize_plastic.cpp (B2/D6) — the certificate is
// the safety, not the trajectory. ARMING ACCEPTS NO MID-RUN ALARM: the escalation
// belt was measured NOT to separate (197) and ships DISARMED; the always-exact
// certification is the sole and sufficient safety.
//
// WHY 1e-3, derived not picked. 185/197 measured the shipped (terminal, certified)
// design CLASSIFICATION-IDENTICAL to a fully-tight run across a 500x loose sweep
// (1e-3 ... 5e-1), and 1e-3 is the TIGHTEST endpoint of that proven-robust range —
// the least-aggressive loose value that still moves the early ultra-dilute iterations
// off the Jacobi-CG stagnation latch and lets multigrid carry them (the win
// mechanism: 185 §B5 measured a stagnating iteration going ~2200 -> ~150 CG at 1e-3).
// Looser endpoints buy more per-iteration speed but introduce the mid-ladder
// transient divergence above; 1e-3 sits at the conservative, measured-safe end. It is
// the "128 production value" 185 built the schedule around.
constexpr double kProductionDraftLooseTol = 1e-3;

// Handoff 2026-07-26-draft-arming — the PRODUCTION draft escalation posture: DISARMED.
// The escalation belt was built twice and measured NOT to separate a diverged rung
// from a converged one — the Phase-1 compliance gap fires false positives and misses
// genuine divergence (185), and the Phase-2 design-space probe is structurally blind
// to the basin/path divergence that matters (197). 197's recommendation is explicit:
// "escalation DISARMED ... and do not rely on the gap"; the ALWAYS-exact final
// certification (part c) is the real and sufficient safety.
//
// The design-space trigger is left OFF (draft_use_design_trigger=false, its default).
// The Phase-1 compliance-gap fallback is DISABLED by setting its threshold to a value
// no relative compliance gap can exceed: the escalate rule is
// `gap <= 0 || gap > threshold`, so a large positive threshold means "never
// escalate" (a threshold <= 0 would mean escalate-EVERY-rung — the opposite). This is
// NOT a picked number with a tuning meaning; it is a DISABLE sentinel, the same
// 1e30 idiom draft_quality_phase2_scale.cpp uses for its no-escalation runs.
//
// WHY explicit-disable rather than the retired 0.02 default. The A5 stagnation
// measurement (docs/.../2026-07-26-draft-arming) shows the gap is ~2e-5 on a
// CONVERGED rung (inert) but ~0.79 on an UNCONVERGED / iteration-capped one — so
// leaving the 0.02 default armed would fire a spurious full tight re-run on any rung
// that reaches its iteration cap before plateauing (safe, since the re-run is exact,
// but pure wasted work that catches nothing real — 197's exact finding, reproduced).
// Disabling it lets draft deliver its win cleanly with the exact certificate as the
// sole guard. Anyone re-arming escalation must re-run the TRIPWIRE harnesses.
constexpr double kProductionDraftEscalationDisabled = 1e30;
// TRIPWIRE — the WIDTH-AWARE accept-gate knockdown (handoff 2026-07-26-width-aware-
// knockdown).
// ===========================================================================
// false = the SHIPPED default: the accept gate keeps the pure scalar `worst_case *
// f^1.5` knockdown, byte-for-byte the pre-width gate. Measurements 191/192 showed
// that scalar is CONSERVATIVE at the ~9.4 mm member scale (the slicer's solid wall
// loops rescue a thin rib) yet still optimistic for envelope-scale solid regions —
// so the honest correction is size-aware, and this constant arms the SHELL+CORE
// composite width_aware_knockdown() per member on a distance-transform thickness.
//
// ARMING IT CHANGES THE PRODUCT (like the AD band, unlike the recycle/Galerkin/
// thread dials): every rung's acceptance verdict and terminal-rung choice is re-
// gated, in the LESS-conservative direction, bounded by how much wall actually
// rescues the governing member (a thick-governed part is unchanged — f_wall→0 →
// the composite collapses to today's f^1.5, so caution on thick sections is never
// silently reduced). Do NOT flip this to true without re-running
//   * core/tests/harness/width_aware_gate.cpp   (the before/after gate table)
// and landing a new gate table + a physical-coupon calibration of the composite:
// the knockdown is a STIFFNESS proxy applied to a STRENGTH margin (191/192 caveat),
// so arming is a maintainer act with a coupon behind it, not a code flip. The
// wall geometry it needs (wall_loops / wall_line_width_mm) already crosses the
// bridge; only this constant gates whether the gate reads it.
constexpr bool kProductionWidthAwareKnockdown = false;  // OFF (shipped default)

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

int production_active_domain_band() { return kProductionActiveDomainBand; }

double production_draft_loose_tol() { return kProductionDraftLooseTol; }
bool production_width_aware_knockdown() { return kProductionWidthAwareKnockdown; }

KnockdownSpec knockdown_spec_for(const MinimizePlasticOptions& opts) {
  // The ONE construction (handoff 2026-07-26-post-merge-build-fix). All four fields
  // are read straight off `opts`: the scalar f^1.5 seed from the job infill, the
  // width-aware arming flag (equals production_width_aware_knockdown() once the
  // options came through configure_production_options), the infill for the per-voxel
  // core term, and the slicer wall-ring thickness t = wall_loops · wall_line_width_mm.
  KnockdownSpec knockdown;
  knockdown.infill_knockdown = infill_margin_knockdown(opts.infill_percent);
  knockdown.width_aware = opts.width_aware_knockdown;
  knockdown.infill_percent = opts.infill_percent;
  knockdown.wall_thickness_mm =
      static_cast<double>(opts.wall_loops) * opts.wall_line_width_mm;
  return knockdown;
}

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

  // Handoff 2026-07-26-ad-arming — ACTIVE DOMAIN, armed in AUTO (maintainer
  // decision, recorded verbatim in the handoff §"THE DECISION"). The band
  // restricts every TRAJECTORY penalized solve to the material plus a derived
  // growth band, shrinking the solved system on ultra-dilute design-box runs —
  // the 46x-dilution / stagnating-multigrid class that dominates production. Phase
  // 1 (168) measured 1.79x wall on the healthy-multigrid gate fixture at 46.5x
  // dilution WITH the 1.33x CG-iteration penalty already charged; the design moved
  // mean|drho| ~ 3.9e-6 on the shipped rung with identical gate verdicts.
  //
  // Unlike every other dial this function sets, THIS ONE IS NOT BIT-IDENTICAL: the
  // eliminated elements carry a real rho_min^p ~ 1e-9 stiffness, so the restricted
  // solve answers a slightly different question and the trajectory (never the
  // certificate — the FINAL compliance solve is always full-domain) drifts. That
  // is why arming waited on the ESCAPE LATCH (2026-07-25-ad-escape-latch): the
  // growth invariant that makes the mask sound is EMPIRICAL, not a theorem (168
  // measured 6 979 escapes on a stagnating trajectory), and the latch detects the
  // first live escape at O(N) cost and reverts to the full domain for the rest of
  // the run. The DEGENERACY LATCH (kActiveDomainLatchFraction/Window) covers the
  // other end: at low dilution the band covers the domain and buys nothing, so it
  // turns the feature off and SAYS so rather than silently costing.
  //
  //   -1 = AUTO. k is DERIVED PER JOB, never pinned here: resolve_active_domain_band
  //     resolves it once per run to active_domain_auto_band(options.filter_radius) =
  //     ceil(rmin) + 1, keyed to the rung's actual grid spacing. See the TRIPWIRE
  //     above. The library default stays 0 (OFF) — Gate-V2 and every reference run
  //     never call this function, so they are BYTE-FOR-BYTE unchanged (THE ONE RULE),
  //     asserted in test_production_parity before AND after this call.
  //
  // Anyone changing this must re-run the harnesses named in the TRIPWIRE and land a
  // new gate table; the parity test asserts the echo against production_active_
  // domain_band() and asserts the DERIVED k on a real run. run_info.json echoes the
  // requested band (-1), the resolved per-rung k, and both latch outcomes.
  opts.simp.active_domain_band = kProductionActiveDomainBand;

  // Handoff 2026-07-26-draft-arming — DRAFT QUALITY, armed (maintainer decision,
  // recorded verbatim in the handoff §"THE DECISION"). Every ladder rung's TRAJECTORY
  // penalized solves run on the adaptive loose->tight schedule (loose endpoint
  // kProductionDraftLooseTol = 1e-3, tightening back to the exact cg_tolerance as the
  // design settles); the FINAL certification + stress-recovery solves ALWAYS run
  // tight. The win is that on the ultra-dilute design-box class that dominates
  // production, the early fast-moving iterations — whose sensitivities feed a step
  // about to be overwritten — no longer grind Jacobi-CG at full tolerance; multigrid
  // carries the loose residual instead. See the TRIPWIRE beside kProductionDraftLooseTol.
  //
  // Like the active-domain band, and UNLIKE every bit-identical dial this function
  // sets, THIS ONE CHANGES THE PRODUCT slightly: the loose trajectory drifts on some
  // mid-ladder rungs (never the certificate). THE ONE RULE still holds — the LIBRARY
  // default is draft_quality=false, so Gate-V2, the property suite and every core
  // reference run (none of which call this function) are BYTE-FOR-BYTE unchanged,
  // asserted in test_production_parity before AND after this call.
  //
  // ARMING ACCEPTS NO MID-RUN ALARM. The escalation belt (a mid-run divergence
  // trigger) was built in two forms and measured NOT to separate: the Phase-1
  // compliance gap fires false positives and misses genuine divergence (185), and the
  // Phase-2 design-space probe is structurally blind to the basin/path divergence
  // that matters (197). Both ship DISARMED — the design-space trigger OFF and the
  // compliance-gap threshold set to the DISABLE sentinel (see
  // kProductionDraftEscalationDisabled for why explicit-disable beats the retired 0.02
  // default). The load-bearing safety is part (c) — the ALWAYS-exact final
  // certification, enforced by the parity test's NDEBUG-independent gate check.
  opts.draft_quality = true;
  opts.draft_loose_tol = kProductionDraftLooseTol;
  opts.draft_use_design_trigger = false;  // 197: the design-space trigger stays disarmed
  opts.draft_escalation_c_gap = kProductionDraftEscalationDisabled;  // gap fallback OFF
  // Width-aware accept-gate knockdown (handoff 2026-07-26-width-aware-knockdown).
  // The shipped default is FALSE (see the TRIPWIRE above), so this sets the gate to
  // the pure scalar f^1.5 path and production is byte-for-byte unchanged in THIS PR
  // — arming is a separate maintainer act (flip kProductionWidthAwareKnockdown).
  // The library default (MinimizePlasticOptions::width_aware_knockdown == false) is
  // the same value, so Gate-V2 and every reference run, which never call this
  // function, are unaffected either way (THE ONE RULE).
  opts.width_aware_knockdown = kProductionWidthAwareKnockdown;

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
