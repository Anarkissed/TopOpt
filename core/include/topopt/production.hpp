#pragma once

#include <vector>

#include "topopt/pipeline.hpp"  // MinimizePlasticOptions

namespace topopt {

// The single source of truth for the PRODUCTION run configuration (STEP-0 of the
// LAN-offload work / handoff 093). A "production run" is any run that must
// produce the shippable PRODUCT part: the iPad app (via TopOptBridge) and the
// headless `topopt-cli` are BOTH production front-ends and must configure the
// optimizer identically, or they silently return different parts for the same
// input. Everything below used to live inline in bridge.cpp only, so the CLI
// diverged (assembled Jacobi-CG, no projection, no Galerkin cache) and would
// have OOM'd on / mis-solved the exact runs the app solves. Both front-ends now
// call this one function, so the configuration cannot drift again.
//
// This is deliberately NOT a MinimizePlasticOptions default and NOT applied
// inside minimize_plastic(): the locked reference runs (Gate-V2, the property
// suite, every core test) use the library SimpOptions/MinimizePlasticOptions
// defaults and must stay byte-identical, so the production config is opt-in at
// the production entry points only. See docs/handoffs/093-lan-offload.md.
//
// What it sets (the enumerated bridge/CLI divergence, factored into one place):
//   * simp.solver = MultigridCG_Matfree — the matrix-free geometric-multigrid
//     accelerator. Solves the identical BC-reduced, void-gated system to the same
//     tolerance and falls back to exact Jacobi-CG when no hierarchy applies, so
//     the result is always correct; it never assembles the fine stiffness K,
//     whose multi-GB peak was the design-box std::bad_alloc (handoff 079/091).
//   * min_feature_mm = 2.5 — the PHYSICAL minimum-feature length scale (mm), so
//     the filtered minimum member thickness is resolution-independent (the
//     per-rung voxel filter radius is derived from grid spacing; diagnosis 060).
//   * simp.projection = heaviside_continuation_schedule() — ONLY when the updater
//     supports it (OC). MMA (the production default updater) rejects a projection
//     schedule, so with MMA this is skipped and the run uses the physical
//     min-feature filter alone; the OC + projection Gate-V2 chain is untouched.
//   * conditional_mma_projection_mnd_threshold = 0.07 — CONDITIONAL MMA Heaviside
//     projection (handoff 123, superseding always-on PR 146). Arms the driver's
//     per-rung grayness gate: a converged grayscale MMA rung whose design-region
//     Mnd exceeds 0.07 is continued into β-projection to crisp it; an already-crisp
//     rung is kept as-is. Projection's ~4× iteration cost is paid ONLY on rungs
//     that go gray — never the tax on already-crisp parts PR 146's evidence
//     surfaced. Library default 0 (gate off) keeps Gate-V2 / reference byte-
//     identical; the threshold is echoed into run_info.json (+ per-rung fired).
//   * the process-global matrix-free Galerkin block cache is ENABLED (see below).
//   * the process-global matrix-free THREAD COUNT is pinned to
//     production_matfree_thread_count() (handoff 132 (C)) — the performance-core
//     count on Apple silicon, hardware_concurrency everywhere else. Bit-identical
//     by construction (8-colour partition); a pure performance dial. Echoed into
//     run_info.json as matfree_threads.
//
// What it deliberately does NOT arm — MIXED PRECISION (handoff 132 (D), BLOCKED).
// The FP32 V-cycle capability (092) is complete and opt-in, but 132 gated the
// production flip on a full l-bracket ladder and it LOST: CG iterations 40715 ->
// 48717 (1.197x MORE), in BOTH the grayscale (1.161x) and fired-projection (1.215x)
// phases, worsening with scale. The design was unchanged (mean|drho| 1e-5), so the
// FP64 certificate holds — it is a cost failure. Cause: cg_tolerance 1e-8 is at
// FP32's ~1e-7 precision, so the preconditioner degrades to noise near convergence.
// The global therefore stays at its library default (false) in production too, and
// run_info.json honestly echoes mixed_precision:false. See production.cpp for the
// full record and what a revival would have to change.
//
// What it deliberately does NOT set (per-front-end / per-job, not shared config):
//   * keyframe_count — optimization-history PLAYBACK, a viz choice that does not
//     affect the design. The app sets 12; the CLI leaves 0 (it exports meshes,
//     not playback, and 12 MC extractions per variant are pure waste at 5M+
//     voxels). The DESIGN is byte-identical either way.
//   * the volume-fraction ladder, gravity, external loads, the design box /
//     keep-outs, the anchor pad, infill_percent, margin_stop — these ARE the load
//     case and come from the job (CLI job.json) or the UI (BridgeLoadCase). Given
//     the SAME load case, both front-ends build the same options; that is what the
//     CLI==bridge parity test asserts.
//
// GALERKIN CACHE — a PROCESS GLOBAL, not a MinimizePlasticOptions field. Handoff
// 091 turned the matrix-free coarse-operator block cache on via the thread-global
// setter fea_set_matfree_galerkin_block_cache(true), because it is a property of
// the matrix-free solver, not of one options object. It is BIT-IDENTICAL (handoff
// 091: 0 differing DOFs, same iteration count, +36 KB) — a pure compute saving —
// so enabling it never changes any design. configure_production_options() calls
// the setter so that "configured a production run" and "the Galerkin cache is on"
// can never disagree between the bridge and the CLI. Gate-V2 and the core tests
// never call this function, so the global stays at its library default for them,
// and even if it did not, being bit-identical it could not change their result.
// The core reference process never links the bridge; the CLI is the only new
// caller, and it runs the matrix-free solver too, so the setting matches.
// THREAD COUNT is a PROCESS GLOBAL for the same reason the Galerkin cache is: it is
// a property of the matrix-free solver itself, not of one options object.
// configure_production_options sets both through their setters so that "configured a
// production run" and "the cache is on, the apply is on N threads" can never disagree
// between the bridge and the CLI. Gate-V2 and the core tests never call this
// function, so both globals — and mixed precision, which production leaves alone —
// stay at their library defaults (cache off, FP64, automatic hardware-concurrency).
void configure_production_options(MinimizePlasticOptions& opts);

// The matrix-free worker-thread count a PRODUCTION run uses (handoff 132 (C)), which
// configure_production_options installs via fea_set_matfree_threads.
//
// Returns the PERFORMANCE-core count on Apple silicon (sysctl
// hw.perflevel0.physicalcpu — perflevel0 is the fastest core class), and
// std::thread::hardware_concurrency() everywhere else: on Intel Macs (where the key
// does not exist), on Linux and Windows (where the query is compiled out), and if
// the query fails for any reason. Always >= 1. Off Apple silicon this is therefore
// exactly today's behaviour.
//
// WHY NOT ALL CORES. Handoff 113's thread sweep measured the matrix-free FP64 matvec
// at 6 / 8 / 10 threads on a 6P+4E box: 45.0 / 45.0 / 48.3 GB/s. The apply is
// gather/bandwidth-bound, so the four efficiency cores buy ~0-7% at best while
// contending for the same memory system — and under sustained thermal load a
// 10-thread run was measured REGRESSING to 36 GB/s, below the 8-thread 41 GB/s. The
// production ladder is exactly such a sustained soak.
//
// SAFE BY CONSTRUCTION. The matrix-free apply threads a deterministic 8-colour
// (2x2x2) grid partition, so no two threads ever touch the same node and the
// accumulation order is set by the colour scheme, NOT the thread count: the computed
// field is bit-identical at any count (fea.hpp, fea_set_matfree_threads). Changing
// this can only change speed.
//
// Exposed so callers and tests can name the production count portably instead of
// hard-coding a machine-specific literal. To override, call fea_set_matfree_threads
// AFTER configure_production_options (n <= 0 restores automatic resolution).
int production_matfree_thread_count();

// Handoff 133 — the PRODUCTION Krylov recycle dimension k that
// configure_production_options arms (the measured optimum of the {8,16,24} sweep).
// Exposed so the parity test asserts the echo against the named constant rather
// than a literal, exactly as production_matfree_thread_count does for the P-core pin.
int production_krylov_recycle_dim();

// The canonical recommendation-driven volume-fraction ladder for production runs
// (finer + lighter than the historical fixed {0.7, 0.5, 0.3}). minimize_plastic
// walks the margin-SAFE prefix and stops at the first rung below margin_stop, so
// a stronger part keeps lighter rungs and a weaker one shows fewer/heavier ones;
// the lightest safe rung is the recommendation the app surfaces. Exposed here so
// the bridge and a CLI job.json reference the SAME literal instead of copies that
// can drift. The CLI still lets a job.json override the ladder explicitly (a
// headless run may want a specific sweep); the app always uses this one.
std::vector<double> production_reduction_ladder();

}  // namespace topopt
