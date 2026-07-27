// test_smooth — the bars for constrained Taubin smoothing with re-certification
// (handoff 2026-07-26-constrained-smooth-ui).
//
//   S1  FROZEN MEANS FROZEN. Vertices inside a freeze predicate (a bore Bolt / a
//       pad Face) are bit-identical before and after, at EVERY strength.
//   S2  NO THINNING BELOW THE FLOOR. A neck that UNCONSTRAINED smoothing pinches
//       below 2 voxels — the min-feature constraint stops it (an unexercised
//       constraint is not a constraint).
//   S4  VOLUME DRIFT reported at each strength, small (shrink-compensated) and
//       below the stated transfer-function bound envelope.
//   S5  DETERMINISM. Same mesh + strength twice → byte-identical.
//   S6  OFF IS IDENTITY. Strength 0 leaves the mesh bit-for-bit unchanged.
//   + the freeze predicate point_in_clearance_region itself.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness,
// public API only. Meshes are built in code from synthetic density fields via the
// library's own marching_cubes, so this runs in every configuration (no OCCT,
// no Eigen) like the other geometry tests.

#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/smooth.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::ClearanceGeometry;
using topopt::ClearanceKind;
using topopt::ClearanceParams;
using topopt::compute_freeze_mask;
using topopt::constrained_taubin_smooth;
using topopt::ManualClearanceGeometry;
using topopt::marching_cubes;
using topopt::min_feature_violations;
using topopt::point_in_clearance_region;
using topopt::resolve_clearance_manual;
using topopt::SmoothConstraints;
using topopt::SmoothResult;
using topopt::TaubinParams;
using topopt::taubin_params_for_strength;
using topopt::taubin_volume_drift_bound;
using topopt::TriangleMesh;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;
using topopt::voxelize_onto_grid;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                             \
  do {                                                               \
    ++g_checks;                                                      \
    if (!(cond)) {                                                   \
      ++g_failures;                                                  \
      std::printf("FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);  \
    }                                                                \
  } while (0)

namespace {

// A cubic VoxelGrid with unit spacing and the given extent, tags computed from a
// density predicate `solid(i,j,k)`.
template <typename F>
VoxelGrid make_grid(int n, double spacing, F solid) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i)
        if (solid(i, j, k))
          g.tags[g.index(i, j, k)] = VoxelTag::Interior;
  return g;
}

std::vector<double> occupancy(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return d;
}

int violations_of(const TriangleMesh& m, const VoxelGrid& ref) {
  const VoxelGrid g = voxelize_onto_grid(m, ref);
  return min_feature_violations(g, occupancy(g), 0.5);
}

// An explicit, grid-aligned, subdivided axis-aligned box (welded, watertight,
// outward winding), so its re-voxelization is EXACT — baseline min-feature 0, no
// marching-cubes terracing noise. `nu` subdivisions per face edge give interior
// rim vertices the smoother can move (a flat box's faces have zero Laplacian; its
// EDGES round and pinch a thin dimension below the floor — the S2 signal).
TriangleMesh make_box(double x0, double x1, double y0, double y1, double z0,
                      double z1, int nu) {
  TriangleMesh m;
  std::vector<Vec3> V;
  auto key = [&](double x, double y, double z) {
    for (std::size_t i = 0; i < V.size(); ++i)
      if (V[i].x == x && V[i].y == y && V[i].z == z) return static_cast<int>(i);
    V.push_back(Vec3{x, y, z});
    return static_cast<int>(V.size()) - 1;
  };
  auto quad = [&](Vec3 a, Vec3 b, Vec3 c, Vec3 d) {
    const int ia = key(a.x, a.y, a.z), ib = key(b.x, b.y, b.z);
    const int ic = key(c.x, c.y, c.z), id = key(d.x, d.y, d.z);
    m.triangles.push_back({ia, ib, ic});
    m.triangles.push_back({ia, ic, id});
  };
  auto face = [&](int axis, double val, bool pos, double a0, double a1, double b0,
                  double b1) {
    auto mk = [&](double u, double v) {
      if (axis == 0) return Vec3{val, u, v};
      if (axis == 1) return Vec3{u, val, v};
      return Vec3{u, v, val};
    };
    for (int i = 0; i < nu; ++i)
      for (int j = 0; j < nu; ++j) {
        const double ua = a0 + (a1 - a0) * i / nu, ub = a0 + (a1 - a0) * (i + 1) / nu;
        const double va = b0 + (b1 - b0) * j / nu, vb = b0 + (b1 - b0) * (j + 1) / nu;
        if (pos)
          quad(mk(ua, va), mk(ub, va), mk(ub, vb), mk(ua, vb));
        else
          quad(mk(ua, va), mk(ua, vb), mk(ub, vb), mk(ub, va));
      }
  };
  face(0, x0, false, y0, y1, z0, z1);
  face(0, x1, true, y0, y1, z0, z1);
  face(1, y0, true, x0, x1, z0, z1);
  face(1, y1, false, x0, x1, z0, z1);
  face(2, z0, false, x0, x1, y0, y1);
  face(2, z1, true, x0, x1, y0, y1);
  m.vertices = V;
  return m;
}

bool same_vertex_bits(const Vec3& a, const Vec3& b) {
  return std::memcmp(&a, &b, sizeof(Vec3)) == 0;
}

}  // namespace

int main() {
  // ── The freeze predicate: point_in_clearance_region ────────────────────────
  {
    // A Bolt cylinder about +Z through the origin, radius 2, |axial| <= 5.
    ManualClearanceGeometry mg;
    mg.kind = ClearanceKind::Bolt;
    mg.axis_point = Vec3{0.0, 0.0, 0.0};
    mg.axis_dir = Vec3{0.0, 0.0, 1.0};
    mg.radius_mm = 2.0;
    mg.half_length_mm = 5.0;
    ClearanceParams pp;  // zero margins
    pp.kind = ClearanceKind::Bolt;
    const ClearanceGeometry bolt = resolve_clearance_manual(mg, pp);
    CHECK(bolt.valid, "predicate: bolt resolves valid");
    CHECK(point_in_clearance_region(bolt, Vec3{0.0, 0.0, 0.0}, 0.0),
          "predicate: axis point inside");
    CHECK(point_in_clearance_region(bolt, Vec3{1.9, 0.0, 3.0}, 0.0),
          "predicate: within radius + band inside");
    CHECK(!point_in_clearance_region(bolt, Vec3{2.5, 0.0, 0.0}, 0.0),
          "predicate: outside radius");
    CHECK(point_in_clearance_region(bolt, Vec3{2.4, 0.0, 0.0}, 0.5),
          "predicate: tol grows radius outward");
    CHECK(!point_in_clearance_region(bolt, Vec3{0.0, 0.0, 6.0}, 0.0),
          "predicate: outside axial band");

    // A Face slab: plane at origin, +X normal, depth 1, in-plane +-3.
    ManualClearanceGeometry fg;
    fg.kind = ClearanceKind::Face;
    fg.origin = Vec3{0.0, 0.0, 0.0};
    fg.normal = Vec3{1.0, 0.0, 0.0};
    fg.half_u_mm = 3.0;
    fg.half_w_mm = 3.0;
    ClearanceParams fp;
    fp.kind = ClearanceKind::Face;
    fp.slab_depth_mm = 1.0;
    const ClearanceGeometry face = resolve_clearance_manual(fg, fp);
    CHECK(face.valid, "predicate: face resolves valid");
    CHECK(point_in_clearance_region(face, Vec3{0.0, 1.0, 1.0}, 0.0),
          "predicate: on plane within rectangle inside");
    CHECK(!point_in_clearance_region(face, Vec3{2.0, 0.0, 0.0}, 0.0),
          "predicate: beyond slab depth");
    CHECK(!point_in_clearance_region(face, Vec3{0.0, 5.0, 0.0}, 0.0),
          "predicate: outside in-plane rectangle");

    ClearanceGeometry invalid;  // valid == false
    CHECK(!point_in_clearance_region(invalid, Vec3{0.0, 0.0, 0.0}, 100.0),
          "predicate: invalid region contains nothing");
  }

  // ── A synthetic sphere mesh (smooth, low-frequency) for S1/S4/S5/S6 ─────────
  const int N = 28;
  const double C = N / 2.0;
  const double R = 9.0;
  const VoxelGrid sphere_grid = make_grid(N, 1.0, [&](int i, int j, int k) {
    const double dx = (i + 0.5) - C, dy = (j + 0.5) - C, dz = (k + 0.5) - C;
    return dx * dx + dy * dy + dz * dz <= R * R;
  });
  const TriangleMesh sphere = marching_cubes(sphere_grid, occupancy(sphere_grid));
  CHECK(!sphere.empty(), "sphere mesh non-empty");

  // A Bolt freeze region along +Z through the sphere centre (a "bore"): catches
  // the top and bottom cap vertices near the axis. Radius 3, full axial band.
  ClearanceGeometry bore;
  bore.kind = ClearanceKind::Bolt;
  bore.valid = true;
  bore.axis_point = Vec3{C, C, 0.0};
  bore.axis_dir = Vec3{0.0, 0.0, 1.0};
  bore.radius = 3.0;
  bore.t_lo = -1.0;
  bore.t_hi = static_cast<double>(N) + 1.0;

  // ── S6: strength 0 is the identity (byte-for-byte) ──────────────────────────
  {
    SmoothConstraints c;
    c.freeze_regions = {bore};
    c.min_feature_grid = &sphere_grid;
    const TaubinParams p0 = taubin_params_for_strength(0.0);
    CHECK(p0.pairs == 0, "S6: strength 0 -> 0 pairs");
    const SmoothResult r = constrained_taubin_smooth(sphere, p0, c);
    CHECK(r.stats.applied_pairs == 0, "S6: no pairs applied");
    bool identical = r.mesh.vertices.size() == sphere.vertices.size();
    for (std::size_t v = 0; identical && v < sphere.vertices.size(); ++v)
      identical = same_vertex_bits(r.mesh.vertices[v], sphere.vertices[v]);
    CHECK(identical, "S6: strength 0 leaves the mesh bit-identical");
  }

  // ── S1: FROZEN MEANS FROZEN, at every strength ──────────────────────────────
  {
    SmoothConstraints c;
    c.freeze_regions = {bore};
    c.freeze_tol_mm = 0.75;
    c.min_feature_grid = &sphere_grid;
    const std::vector<char> frozen =
        compute_freeze_mask(sphere, c.freeze_regions, c.freeze_tol_mm);
    std::size_t nfrozen = 0;
    for (char f : frozen) nfrozen += (f ? 1 : 0);
    CHECK(nfrozen > 0, "S1: freeze mask is non-empty (constraint exercised)");

    const double strengths[] = {0.1, 0.25, 0.5, 0.75, 1.0};
    for (double s : strengths) {
      const SmoothResult r =
          constrained_taubin_smooth(sphere, taubin_params_for_strength(s), c);
      CHECK(r.stats.frozen_vertices == nfrozen, "S1: frozen count matches mask");
      bool allfrozen_identical = true;
      bool some_free_moved = false;
      for (std::size_t v = 0; v < sphere.vertices.size(); ++v) {
        if (frozen[v]) {
          if (!same_vertex_bits(r.mesh.vertices[v], sphere.vertices[v]))
            allfrozen_identical = false;
        } else if (!same_vertex_bits(r.mesh.vertices[v], sphere.vertices[v])) {
          some_free_moved = true;
        }
      }
      CHECK(allfrozen_identical, "S1: every frozen vertex bit-identical");
      CHECK(some_free_moved, "S1: free vertices did move (smoothing happened)");
    }
  }

  // ── S4: volume drift small and reported against the bound, per strength ──────
  {
    SmoothConstraints c;
    c.min_feature_grid = &sphere_grid;
    std::printf("S4 volume drift (sphere): strength  pairs  drift%%   bound%%\n");
    const double strengths[] = {0.1, 0.25, 0.5, 0.75, 1.0};
    for (double s : strengths) {
      const TaubinParams p = taubin_params_for_strength(s);
      const SmoothResult r = constrained_taubin_smooth(sphere, p, c);
      const double drift = r.stats.volume_drift_fraction;
      const double bound = r.stats.volume_drift_bound;
      std::printf("   %.2f       %2d    %6.3f   %6.3f\n", s, p.pairs,
                  100.0 * drift, 100.0 * bound);
      CHECK(bound > 0.0, "S4: bound positive for pairs>0");
      CHECK(drift < 0.02, "S4: shrink-compensated drift stays under 2%");
    }
  }

  // ── S5: determinism (same mesh + strength twice = byte-identical) ───────────
  {
    SmoothConstraints c;
    c.freeze_regions = {bore};
    c.min_feature_grid = &sphere_grid;
    const TaubinParams p = taubin_params_for_strength(0.7);
    const SmoothResult a = constrained_taubin_smooth(sphere, p, c);
    const SmoothResult b = constrained_taubin_smooth(sphere, p, c);
    bool identical = a.mesh.vertices.size() == b.mesh.vertices.size();
    for (std::size_t v = 0; identical && v < a.mesh.vertices.size(); ++v)
      identical = same_vertex_bits(a.mesh.vertices[v], b.mesh.vertices[v]);
    CHECK(identical, "S5: two runs are byte-identical");
    CHECK(a.stats.applied_pairs == b.stats.applied_pairs,
          "S5: stats deterministic");
  }

  // ── S2: NO THINNING BELOW THE FLOOR ─────────────────────────────────────────
  // A thin (3-voxel) grid-aligned slab: re-voxelizes EXACTLY, so baseline
  // min-feature is 0 (no marching-cubes terrace noise). Smoothing rounds the rim
  // and pinches the 3-voxel thickness below 2 voxels — a real thinning. The
  // constraint must refuse it and hold the mesh at the baseline floor.
  {
    const int M = 40;
    const VoxelGrid slab_grid = make_grid(M, 1.0, [&](int, int, int) { return false; });
    const TriangleMesh slab = make_box(10, 30, 10, 30, 18, 21, 20);
    const int baseline = violations_of(slab, slab_grid);
    CHECK(baseline == 0, "S2: explicit slab has a clean baseline (0 violations)");

    // UNCONSTRAINED, ONE pair (the very step the constraint will judge): it raises
    // the count above baseline — smoothing WOULD thin below the floor.
    SmoothConstraints unc;
    unc.min_feature_grid = &slab_grid;
    unc.enforce_min_feature = false;
    TaubinParams one;
    one.pairs = 1;
    const SmoothResult ru1 = constrained_taubin_smooth(slab, one, unc);
    const int viol_unc1 = violations_of(ru1.mesh, slab_grid);
    std::printf("S2: baseline=%d  unconstrained@1pair=%d\n", baseline, viol_unc1);
    CHECK(viol_unc1 > baseline,
          "S2: one unconstrained pair WOULD thin below the floor");

    // CONSTRAINED (guard on): the constraint refuses the thinning pair and holds
    // the mesh at the floor — the melt is structurally impossible.
    SmoothConstraints con;
    con.min_feature_grid = &slab_grid;
    con.enforce_min_feature = true;
    const SmoothResult rc =
        constrained_taubin_smooth(slab, taubin_params_for_strength(1.0), con);
    const int viol_con = violations_of(rc.mesh, slab_grid);
    std::printf("S2: constrained applied=%d/%d  limited=%d  final=%d\n",
                rc.stats.applied_pairs, rc.stats.requested_pairs,
                rc.stats.min_feature_limited ? 1 : 0, viol_con);
    CHECK(rc.stats.min_feature_limited, "S2: the constraint fired");
    CHECK(rc.stats.applied_pairs < rc.stats.requested_pairs,
          "S2: fewer pairs applied than requested (thinning refused)");
    CHECK(viol_con <= baseline,
          "S2: constrained result never exceeds the baseline floor");

    // DISCRIMINATION: the constraint is not a blanket reject — on the FAT sphere
    // (nothing thins) it applies every requested pair.
    SmoothConstraints fat;
    fat.min_feature_grid = &sphere_grid;
    fat.enforce_min_feature = true;
    const TaubinParams pfull = taubin_params_for_strength(1.0);
    const SmoothResult rf = constrained_taubin_smooth(sphere, pfull, fat);
    CHECK(!rf.stats.min_feature_limited,
          "S2: a fat body is smoothed freely (constraint discriminates)");
    CHECK(rf.stats.applied_pairs == pfull.pairs,
          "S2: all requested pairs applied on the fat body");
  }

  std::printf("\ntest_smooth: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
