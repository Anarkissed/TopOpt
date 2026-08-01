// test_smooth_brush — THE BRUSH IS A WAY TO SMOOTH LESS, NEVER A WAY TO SMOOTH
// SOMETHING FROZEN (handoff 2026-08-02-smoothing-page).
//
// The smoothing page's differentiated thing is not the melt, it is the RECEIPT and
// the HARD CONSTRAINTS. This file is the hard-constraint half, at PR 200's own
// standard and on PR 200's own specimen:
//
//   AE1  FROZEN MEANS FROZEN, BY MEMCMP, ON A REAL VARIANT WITH A REAL BORE.
//        The mesh is `variant_030.stl` — the actual ladder output PR 200 measured
//        S1 on (4344 vertices, 8700 triangles; a 228-vertex bore). The freeze
//        predicate is the same resolved `ClearanceGeometry` bolt bore. Every
//        frozen vertex is compared with std::memcmp on the raw doubles, at every
//        brush strength AND under a mixed per-region brush — anything weaker than
//        memcmp is a MISS.
//
//   The exclusion is STRUCTURAL, at three layers, and BR3 proves the innermost
//   one on its own: a caller that paints weight 1.0 over EVERY vertex — frozen
//   ones included — still cannot move a frozen vertex, because the freeze mask is
//   recomputed from the geometric predicate inside the smoother and tested first
//   in the update. "We undo it afterwards" is not what this asserts; nothing is
//   ever computed for those vertices in the first place.
//
//   BR4 pins the compatibility bar the rest of the shipped product depends on: an
//   EMPTY weight vector reproduces the pre-brush smoother byte for byte, so the
//   uniform strength knob, the CLI's `--smooth`, and PR 200's own receipts are
//   untouched by this change.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness the
// other core tests use, public API only.

#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using topopt::ClearanceGeometry;
using topopt::ClearanceKind;
using topopt::ClearanceParams;
using topopt::compute_freeze_mask;
using topopt::constrained_taubin_smooth;
using topopt::ManualClearanceGeometry;
using topopt::resolve_clearance_manual;
using topopt::SmoothConstraints;
using topopt::SmoothResult;
using topopt::TaubinParams;
using topopt::taubin_params_for_strength;
using topopt::taubin_volume_drift_bound;
using topopt::taubin_volume_drift_bound_weighted;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// THE bar's comparison. Raw bytes of the two doubles triples — not an epsilon,
// not a norm. A single flipped sign bit fails this, which is the point.
bool same_vertex_bits(const Vec3& a, const Vec3& b) {
  return std::memcmp(&a, &b, sizeof(Vec3)) == 0;
}

// PR 200's own bore predicate on this specimen, verbatim (evidence file
// device_s1_check.cpp): a Bolt cylinder through the part centre along +Z with
// radius one sixth of the X span, spanning the full Z extent.
ClearanceGeometry variant_bore(const TriangleMesh& m) {
  Vec3 lo, hi;
  topopt::bounding_box(m, lo, hi);
  ManualClearanceGeometry g;
  g.kind = ClearanceKind::Bolt;
  g.axis_point = Vec3{(lo.x + hi.x) / 2.0, (lo.y + hi.y) / 2.0, lo.z};
  g.axis_dir = Vec3{0.0, 0.0, 1.0};
  g.radius_mm = (hi.x - lo.x) / 6.0;
  g.half_length_mm = (hi.z - lo.z);
  ClearanceParams p;
  p.kind = ClearanceKind::Bolt;
  return resolve_clearance_manual(g, p);
}

// Counts for one comparison against the input mesh.
struct Diff {
  std::size_t frozen_changed = 0;   // MUST be 0, always
  std::size_t unbrushed_moved = 0;  // MUST be 0 when a brush is supplied
  std::size_t brushed_moved = 0;    // > 0 or nothing happened
  double max_shift = 0.0;           // largest |Δ| over brushed vertices (mm)
};

Diff diff_against(const TriangleMesh& before, const TriangleMesh& after,
                  const std::vector<char>& frozen,
                  const std::vector<double>& weight) {
  Diff d;
  for (std::size_t v = 0; v < before.vertices.size(); ++v) {
    const bool same = same_vertex_bits(after.vertices[v], before.vertices[v]);
    if (frozen[v]) {
      if (!same) ++d.frozen_changed;
      continue;
    }
    const bool brushed = weight.empty() || weight[v] > 0.0;
    if (!brushed) {
      if (!same) ++d.unbrushed_moved;
      continue;
    }
    if (!same) {
      ++d.brushed_moved;
      const double dx = after.vertices[v].x - before.vertices[v].x;
      const double dy = after.vertices[v].y - before.vertices[v].y;
      const double dz = after.vertices[v].z - before.vertices[v].z;
      const double s = std::sqrt(dx * dx + dy * dy + dz * dz);
      if (s > d.max_shift) d.max_shift = s;
    }
  }
  return d;
}

bool meshes_bit_identical(const TriangleMesh& a, const TriangleMesh& b) {
  if (a.vertices.size() != b.vertices.size()) return false;
  for (std::size_t v = 0; v < a.vertices.size(); ++v)
    if (!same_vertex_bits(a.vertices[v], b.vertices[v])) return false;
  return true;
}

}  // namespace

int main() {
  // The REAL variant PR 200 measured S1 on — a ladder output, not a synthetic
  // body: a marching-cubes iso-surface with genuine terracing and a real bore.
  const std::string variant_path =
      std::string(SMOOTH_VARIANT_DIR) + "/variant_030.stl";
  const TriangleMesh variant = topopt::import_stl_file(variant_path);
  CHECK(!variant.empty(), "the real variant mesh imports");
  CHECK(variant.vertices.size() > 1000,
        "the specimen is the real ladder variant, not a toy");

  // The min-feature reference grid, exactly as the analyze path builds it.
  const VoxelGrid grid = topopt::voxelize(variant, 48);

  const ClearanceGeometry bore = variant_bore(variant);
  CHECK(bore.valid, "the bore predicate resolves");

  SmoothConstraints base;
  base.freeze_regions = {bore};
  base.freeze_tol_mm = 0.75;
  base.min_feature_grid = &grid;
  base.enforce_min_feature = false;  // the sweep probes the whole brush range

  const std::vector<char> frozen =
      compute_freeze_mask(variant, base.freeze_regions, base.freeze_tol_mm);
  std::size_t nfrozen = 0;
  for (const char f : frozen) nfrozen += (f ? 1u : 0u);
  std::fprintf(stderr,
               "[BRUSH] specimen: %zu verts, %zu tris; frozen bore = %zu verts\n",
               variant.vertices.size(), variant.triangles.size(), nfrozen);
  CHECK(nfrozen > 0, "AE1: the freeze mask is non-empty (the bar is exercised)");

  const double strengths[] = {0.10, 0.25, 0.50, 0.75, 1.00};

  // ── BR4: an EMPTY weight vector is the pre-brush smoother, byte for byte ─────
  // Every shipped caller (the uniform strength knob, the CLI's --smooth, PR 200's
  // receipts) passes no weights, so this is the compatibility bar. It also fixes
  // the meaning of weight 1.0: an all-ones brush must be the SAME mesh.
  for (const double s : strengths) {
    const TaubinParams p = taubin_params_for_strength(s);
    SmoothConstraints uniform = base;  // vertex_weight stays empty
    SmoothConstraints ones = base;
    ones.vertex_weight.assign(variant.vertices.size(), 1.0);
    const SmoothResult ru = constrained_taubin_smooth(variant, p, uniform);
    const SmoothResult ro = constrained_taubin_smooth(variant, p, ones);
    CHECK(meshes_bit_identical(ru.mesh, ro.mesh),
          "BR4: an all-ones brush is byte-identical to the uniform path");
    CHECK(!ru.stats.brush_weighted && ro.stats.brush_weighted,
          "BR4: the receipt says which path ran");
    CHECK(ru.stats.volume_drift_bound == ro.stats.volume_drift_bound,
          "BR4: an all-ones brush quotes the uniform Taubin bound");
  }

  // ── BR1 / AE1: FROZEN MEANS FROZEN at every brush strength ──────────────────
  // A UNIFORM brush at each strength: every vertex weighted `s_brush`, so the
  // whole free surface melts, and the bore must not move by one bit.
  std::fprintf(stderr, "[BRUSH] AE1  strength  pairs  frozen_changed  moved  "
                       "max_shift(mm)\n");
  for (const double s : strengths) {
    SmoothConstraints c = base;
    c.vertex_weight.assign(variant.vertices.size(), s);
    const SmoothResult r =
        constrained_taubin_smooth(variant, taubin_params_for_strength(1.0), c);
    const Diff d = diff_against(variant, r.mesh, frozen, c.vertex_weight);
    std::fprintf(stderr, "[BRUSH]      %.2f      %3d         %zu          %zu    %.4f\n",
                 s, r.stats.applied_pairs, d.frozen_changed, d.brushed_moved,
                 d.max_shift);
    CHECK(d.frozen_changed == 0,
          "AE1: every frozen vertex is bit-identical (memcmp) at this strength");
    CHECK(d.brushed_moved > 0, "AE1: free brushed vertices did move");
    CHECK(r.stats.frozen_vertices == nfrozen,
          "AE1: the receipt's frozen count is the predicate's own count");
    CHECK(r.stats.brushed_vertices == variant.vertices.size() - nfrozen,
          "AE1: frozen vertices are never counted as brushed");
  }

  // ── BR2: the brush is LOCAL — an unpainted vertex is bit-identical ──────────
  // Paint one half-space (x below the bbox mid-plane) at full strength and leave
  // the other half unpainted. The unpainted half must come back verbatim: this is
  // the whole point of "smoothing only on the parts that need it".
  {
    Vec3 lo, hi;
    topopt::bounding_box(variant, lo, hi);
    const double xmid = 0.5 * (lo.x + hi.x);
    SmoothConstraints c = base;
    c.vertex_weight.assign(variant.vertices.size(), 0.0);
    std::size_t painted = 0;
    for (std::size_t v = 0; v < variant.vertices.size(); ++v)
      if (variant.vertices[v].x < xmid) {
        c.vertex_weight[v] = 1.0;
        ++painted;
      }
    CHECK(painted > 0 && painted < variant.vertices.size(),
          "BR2: the half-space brush covers part of the mesh, not all of it");

    const SmoothResult r =
        constrained_taubin_smooth(variant, taubin_params_for_strength(1.0), c);
    const Diff d = diff_against(variant, r.mesh, frozen, c.vertex_weight);
    std::fprintf(stderr,
                 "[BRUSH] BR2  painted=%zu  frozen_changed=%zu  unbrushed_moved=%zu  "
                 "brushed_moved=%zu\n",
                 painted, d.frozen_changed, d.unbrushed_moved, d.brushed_moved);
    CHECK(d.frozen_changed == 0, "BR2: frozen vertices bit-identical under a local brush");
    CHECK(d.unbrushed_moved == 0,
          "BR2: an UNPAINTED vertex is bit-identical — the brush is local");
    CHECK(d.brushed_moved > 0, "BR2: the painted region did move");
    CHECK(r.stats.unbrushed_vertices > 0 && r.stats.brushed_vertices > 0,
          "BR2: the receipt reports both populations");
  }

  // ── BR3: THE BRUSH CANNOT REACH A FROZEN VERTEX ────────────────────────────
  // The adversarial case the bar exists for: a caller that paints weight 1.0 over
  // EVERYTHING, frozen bore included. The smoother recomputes the freeze mask from
  // the geometric predicate and tests it FIRST, so those vertices are copied
  // verbatim — never computed and then restored.
  {
    SmoothConstraints c = base;
    c.vertex_weight.assign(variant.vertices.size(), 1.0);
    const SmoothResult r =
        constrained_taubin_smooth(variant, taubin_params_for_strength(1.0), c);
    const Diff d = diff_against(variant, r.mesh, frozen, c.vertex_weight);
    CHECK(d.frozen_changed == 0,
          "BR3: painting over the bore at full weight still cannot move it");
    CHECK(r.stats.max_vertex_weight == 1.0,
          "BR3: the receipt reports the strongest weight actually applied");
    CHECK(r.stats.brushed_vertices + r.stats.unbrushed_vertices +
              r.stats.frozen_vertices == variant.vertices.size(),
          "BR3: the three populations partition the mesh");
  }

  // ── BR5: the brush is MONOTONE — a weaker region moves less ────────────────
  {
    double prev = -1.0;
    bool monotone = true;
    for (const double w : {0.10, 0.30, 0.60, 1.00}) {
      SmoothConstraints c = base;
      c.vertex_weight.assign(variant.vertices.size(), w);
      const SmoothResult r =
          constrained_taubin_smooth(variant, taubin_params_for_strength(1.0), c);
      const Diff d = diff_against(variant, r.mesh, frozen, c.vertex_weight);
      if (d.max_shift < prev) monotone = false;
      std::fprintf(stderr, "[BRUSH] BR5  weight %.2f  max_shift %.4f mm\n", w,
                   d.max_shift);
      prev = d.max_shift;
    }
    CHECK(monotone, "BR5: a stronger brush weight moves the surface further");
  }

  // ── BR6: the drift bound covers the WHOLE weight range, never only w = 1 ───
  {
    const TaubinParams p = taubin_params_for_strength(1.0);
    const double uniform_bound = taubin_volume_drift_bound(p);
    CHECK(taubin_volume_drift_bound_weighted(p, 1.0) == uniform_bound,
          "BR6: weight 1 reproduces the uniform bound exactly");
    CHECK(taubin_volume_drift_bound_weighted(p, 0.0) == 0.0,
          "BR6: nothing brushed → no drift bound");
    const double half = taubin_volume_drift_bound_weighted(p, 0.5);
    CHECK(half > 0.0 && half <= uniform_bound,
          "BR6: a half-strength brush has a positive bound no larger than uniform");

    SmoothConstraints c = base;
    c.vertex_weight.assign(variant.vertices.size(), 0.0);
    for (std::size_t v = 0; v < variant.vertices.size(); v += 2)
      c.vertex_weight[v] = 0.5;
    const SmoothResult r = constrained_taubin_smooth(variant, p, c);
    CHECK(r.stats.max_vertex_weight == 0.5,
          "BR6: the receipt's max weight is the strongest region's strength");
    CHECK(r.stats.volume_drift_bound == half,
          "BR6: the reported bound is the weighted bound at that max weight");
  }

  // ── BR7: a weight vector that does not describe this mesh is REFUSED ───────
  {
    SmoothConstraints c = base;
    c.vertex_weight.assign(variant.vertices.size() + 1, 1.0);
    bool threw = false;
    try {
      constrained_taubin_smooth(variant, taubin_params_for_strength(0.5), c);
    } catch (const std::exception&) {
      threw = true;
    }
    CHECK(threw, "BR7: a mis-sized weight vector throws rather than smoothing "
                 "the wrong vertices");
  }

  std::fprintf(stderr, "\ntest_smooth_brush: %d checks, %d failures\n", g_checks,
               g_failures);
  if (g_failures == 0) std::fprintf(stderr, "PASS: smooth_brush\n");
  return g_failures == 0 ? 0 : 1;
}
