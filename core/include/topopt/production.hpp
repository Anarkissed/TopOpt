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
void configure_production_options(MinimizePlasticOptions& opts);

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
