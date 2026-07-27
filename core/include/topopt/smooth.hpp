#pragma once

// Constrained Taubin smoothing with re-certification (handoff
// 2026-07-26-constrained-smooth-ui).
//
// The existing pipeline already removes GROSS terracing (the 2x tricubic export
// resample, handoff 086). This module adds the two things a plain smoother (and
// Nomad's Smooth tool) fundamentally cannot: HARD CONSTRAINTS and a RECEIPT.
//
//   * SMOOTH: shrink-compensated Taubin λ|μ smoothing with a single strength
//     knob. Taubin (SIGGRAPH '95) alternates a shrinking Laplacian pass (factor
//     λ > 0) with an inflating pass (factor μ < 0, |μ| > λ) so the surface is
//     denoised WITHOUT the monotone volume collapse pure Laplacian smoothing
//     suffers. Its per-pair transfer over the umbrella-Laplacian spectrum
//     k ∈ [0,2] is f(k) = (1−λk)(1−μk), with f(0) = 1 (rigid + uniform modes are
//     fixed — no bulk shrink) and f(k_PB) = 1 (the pass-band). See the volume-
//     drift bound below.
//   * FROZEN MEANS FROZEN: vertices on protected faces / anchor pads / keep-clear
//     bore walls are excluded from EVERY update — their coordinates are the input
//     coordinates, bit for bit. Membership is the exact geometric predicate
//     point_in_clearance_region (clearance.hpp) resolved from PR 190's
//     ClearanceGeometry, which SURVIVES re-meshing (the exported mesh carries no
//     face ids). Not damped — frozen.
//   * MIN-FEATURE AS A CONSTRAINT: the §7 V3 min-feature detector becomes a hard
//     limit. Any λ|μ pair that would raise min_feature_violations (a region
//     thinning below 2 voxels of printable width) above the input's baseline is
//     REJECTED and smoothing stops — the melt is structurally impossible, not
//     merely warned about.
//
// This is PURE GEOMETRY on a welded triangle mesh: no solve, no optimizer, no
// ML. Re-certification is a separate step (analyze_fixed_design via analyze_job):
// re-voxelize the smoothed mesh and recompute stress / mass / margins / gate, so
// the numbers shown next to smoothed geometry are always the NEW ones.
//
// Deterministic: fixed vertex order, uniform (umbrella) neighbour weights, no RNG
// and no nondeterministic reduction, so the same mesh + strength twice is
// byte-identical.

#include <cstddef>
#include <vector>

#include "topopt/clearance.hpp"  // ClearanceGeometry, point_in_clearance_region
#include "topopt/mesh.hpp"       // TriangleMesh, Vec3
#include "topopt/voxel.hpp"      // VoxelGrid

namespace topopt {

// The Taubin low-pass parameters. `lambda` is the shrinking-pass factor (0<λ<1),
// `k_pb` the pass-band frequency (0<k_PB<1); the inflating factor μ is derived as
// μ = −λ/(1 − λ·k_PB), the value that makes f(k_PB) = 1. `pairs` is the number of
// (λ then μ) PASS PAIRS applied — the strength.
struct TaubinParams {
  double lambda = 0.33;  // classic Taubin default
  double k_pb = 0.1;     // classic Taubin default → μ ≈ −0.3413
  int pairs = 0;         // 0 = OFF (identity: the mesh is returned unchanged)
};

// The inflating factor μ = −λ/(1 − λ·k_PB) for the given (λ, k_PB). Undefined if
// λ·k_PB == 1 (never for the sane defaults). Exposed for tests / the receipt.
double taubin_mu(double lambda, double k_pb);

// Map a strength in [0,1] to TaubinParams: λ, k_PB fixed at the shrink-compensated
// defaults, `pairs` = round(strength · max_pairs). strength ≤ 0 → pairs 0 (OFF,
// identity). strength ≥ 1 → max_pairs. Monotone in strength.
TaubinParams taubin_params_for_strength(double strength, int max_pairs = 20);

// The stated per-run volume-drift BOUND for `params` (task item 1). Volume is a
// low-frequency functional: the enclosed volume is carried by the mesh's lowest
// spatial-frequency modes (k → 0), where f → 1. Over the pass band k ∈ [0, k_PB]
// the per-pair transfer f(k) = (1−λk)(1−μk) lies in [1, A] with A the pass-band
// peak (A ≳ 1 by a few 1e-4 for the defaults), so after `pairs` pairs no volume-
// carrying mode is scaled beyond A^pairs. The returned bound is A^pairs − 1, an
// upper bound on |ΔV|/V. (Contrast pure Laplacian, f(k)=1−λk<1 on (0,2], whose
// volume shrinks monotonically toward 0.) Measured drift is reported against this.
double taubin_volume_drift_bound(const TaubinParams& params);

// The constraints applied during smoothing.
struct SmoothConstraints {
  // Freeze regions (resolved once from ClearanceGeometry): a vertex within
  // `freeze_tol_mm` of ANY region is frozen for the whole run (bit-identical).
  std::vector<ClearanceGeometry> freeze_regions;
  double freeze_tol_mm = 0.0;  // ≤ 0 → default (0.75 × ref grid spacing)

  // Min-feature hard constraint. When `min_feature_grid` is non-null AND
  // `enforce_min_feature` is true, each λ|μ pair is accepted only if the smoothed
  // mesh, re-voxelized onto that grid, does not exceed the input mesh's
  // min_feature_violations; the first pair that would is reverted and smoothing
  // stops. Null grid → the constraint is not evaluated (no reference to voxelize
  // against).
  const VoxelGrid* min_feature_grid = nullptr;
  bool enforce_min_feature = true;
};

// Per-run receipt of one smoothing pass (task items 1, 4, 5; bars S2, S4).
struct SmoothStats {
  int requested_pairs = 0;        // params.pairs
  int applied_pairs = 0;          // pairs actually kept (≤ requested)
  std::size_t total_vertices = 0;
  std::size_t frozen_vertices = 0;  // vertices held bit-identical

  // Min-feature constraint (bar S2).
  bool min_feature_evaluated = false;  // a reference grid was supplied
  int min_feature_baseline = -1;       // violations of the INPUT mesh's voxelization
  int min_feature_after = -1;          // violations of the OUTPUT mesh's voxelization
  bool min_feature_limited = false;    // a pair was rejected → smoothing stopped early

  // Volume drift (bar S4), enclosed volume via the divergence theorem (mm^3).
  double volume_before_mm3 = 0.0;
  double volume_after_mm3 = 0.0;
  double volume_drift_fraction = 0.0;  // |after−before| / before (0 if before==0)
  double volume_drift_bound = 0.0;     // taubin_volume_drift_bound(params)
};

struct SmoothResult {
  TriangleMesh mesh;   // the smoothed mesh (welded topology of the input preserved)
  SmoothStats stats;
};

// The per-vertex freeze mask for `mesh`: entry v is 1 iff vertex v is within
// `tol` of ANY valid region (point_in_clearance_region). Size == vertices.size().
std::vector<char> compute_freeze_mask(const TriangleMesh& mesh,
                                      const std::vector<ClearanceGeometry>& regions,
                                      double tol);

// Smooth `mesh` with Taubin `params` under `constraints`. Frozen vertices keep
// their input coordinates bit-for-bit; free vertices are moved by the umbrella
// (uniform-weight) Laplacian using their neighbours' CURRENT positions (frozen
// neighbours contribute their fixed positions, which is what keeps a bore
// circular). `params.pairs == 0` returns the input mesh unchanged (identity), so
// strength 0 is byte-identical. Throws std::invalid_argument on an empty mesh.
SmoothResult constrained_taubin_smooth(const TriangleMesh& mesh,
                                       const TaubinParams& params,
                                       const SmoothConstraints& constraints);

}  // namespace topopt
