// test_surface_operator — the S2 constraint bars for the two candidate operators
// (task 2026-08-06-smoothing-operator-bakeoff, bar R2).
//
// R2 IS "FAILING TEST FIRST FOR EACH CONSTRAINT": construct the case the
// constraint exists to prevent, show it happening WITHOUT the constraint, then
// show the constraint preventing it. Every constraint case below is therefore a
// PAIR of arms, and the unconstrained arm ASSERTS THAT THE DAMAGE HAPPENS. That
// second assertion is not decoration — a constraint test whose unconstrained arm
// quietly stopped reproducing the damage would pass vacuously forever, which is
// exactly how a bar stops meaning anything.
//
//   C1  THE TRUST REGION. No vertex may leave the voxel that produced it.
//       Prevents: an operator manufacturing error outside the +/- half-voxel band
//       the export already carries.
//   C2  THE SIGNED TRUST REGION, all four cases.
//       Prevents: thinning material that matters (OutwardOnly), growing into a
//       design box or clearance (InwardOnly), and — the case with no compromise
//       available — doing anything at all when both bind (Pinned).
//   C3  VOLUME PRESERVATION.
//       Prevents: curvature flow's monotone shrink.
//   + refine_edges staying watertight and exactly volume-neutral, which is what
//     lets operator B add points without moving the surface by adding them.
//   + OFF IS IDENTITY for both operators (bar R1's unit-level half).
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness,
// public API only, meshes built in code. Runs in every configuration.

#include "topopt/mesh.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

using topopt::classify_trust_sign;
using topopt::marching_cubes;
using topopt::mean_curvature_flow;
using topopt::mean_curvature_normals;
using topopt::MeanCurvatureParams;
using topopt::mesh_edges;
using topopt::ramp_reconstruction;
using topopt::RampParams;
using topopt::refine_edges;
using topopt::signed_volume;
using topopt::SurfaceConstraints;
using topopt::SurfaceOperatorResult;
using topopt::TriangleMesh;
using topopt::TrustSign;
using topopt::TrustSignPolicy;
using topopt::Vec3;
using topopt::vertex_normals;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::printf("FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
    }                                                               \
  } while (0)

namespace {

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
        if (solid(i, j, k)) g.tags[g.index(i, j, k)] = VoxelTag::Interior;
  return g;
}

std::vector<double> occupancy(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return d;
}

// A voxelized sphere's iso-surface: the staircase every one of these operators
// exists to attack, at a known exact reference.
TriangleMesh voxel_sphere_mesh(int n, double spacing, double R, Vec3& centre) {
  const double half = 0.5 * static_cast<double>(n) * spacing;
  centre = Vec3{half, half, half};
  const VoxelGrid g = make_grid(n, spacing, [&](int i, int j, int k) {
    const Vec3 p{(i + 0.5) * spacing, (j + 0.5) * spacing, (k + 0.5) * spacing};
    const double dx = p.x - half, dy = p.y - half, dz = p.z - half;
    return dx * dx + dy * dy + dz * dz <= R * R;
  });
  return marching_cubes(g.nx, g.ny, g.nz, g.spacing, g.origin, occupancy(g), 0.5);
}

// A SMOOTH analytic sphere (UV tessellation, welded poles). Needed wherever the
// bar is about the differential geometry rather than about the staircase: a
// VOXELIZED sphere is not convex — its step edges are genuinely concave — so it
// is the wrong fixture for asking which way mean curvature points.
TriangleMesh uv_sphere_mesh(int n_theta, int n_phi, double R, const Vec3& c) {
  TriangleMesh m;
  const double kPi = 3.14159265358979323846;
  m.vertices.push_back(Vec3{c.x, c.y, c.z + R});  // north pole = 0
  for (int i = 1; i < n_theta; ++i) {
    const double th = kPi * static_cast<double>(i) / static_cast<double>(n_theta);
    for (int j = 0; j < n_phi; ++j) {
      const double ph = 2.0 * kPi * static_cast<double>(j) / static_cast<double>(n_phi);
      m.vertices.push_back(Vec3{c.x + R * std::sin(th) * std::cos(ph),
                                c.y + R * std::sin(th) * std::sin(ph),
                                c.z + R * std::cos(th)});
    }
  }
  const int south = static_cast<int>(m.vertices.size());
  m.vertices.push_back(Vec3{c.x, c.y, c.z - R});
  auto ring = [&](int i, int j) { return 1 + (i - 1) * n_phi + (j % n_phi); };
  for (int j = 0; j < n_phi; ++j)
    m.triangles.push_back({0, ring(1, j), ring(1, j + 1)});
  for (int i = 1; i < n_theta - 1; ++i)
    for (int j = 0; j < n_phi; ++j) {
      m.triangles.push_back({ring(i, j), ring(i + 1, j), ring(i + 1, j + 1)});
      m.triangles.push_back({ring(i, j), ring(i + 1, j + 1), ring(i, j + 1)});
    }
  for (int j = 0; j < n_phi; ++j)
    m.triangles.push_back({south, ring(n_theta - 1, j + 1), ring(n_theta - 1, j)});
  return m;
}

// The largest per-axis displacement of any vertex, and the largest signed motion
// along the ORIGINAL outward normal (positive = outward = material added).
struct Motion {
  double max_axis = 0.0;
  double max_outward = 0.0;
  double max_inward = 0.0;  // reported as a POSITIVE magnitude
  double max_norm = 0.0;
};

Motion motion_between(const TriangleMesh& before, const TriangleMesh& after) {
  Motion m;
  const std::vector<Vec3> n = vertex_normals(before);
  const std::size_t nv =
      before.vertices.size() < after.vertices.size() ? before.vertices.size()
                                                     : after.vertices.size();
  for (std::size_t v = 0; v < nv; ++v) {
    const Vec3 d{after.vertices[v].x - before.vertices[v].x,
                 after.vertices[v].y - before.vertices[v].y,
                 after.vertices[v].z - before.vertices[v].z};
    m.max_axis = std::fmax(m.max_axis, std::fmax(std::fabs(d.x),
                                                 std::fmax(std::fabs(d.y),
                                                           std::fabs(d.z))));
    m.max_norm = std::fmax(m.max_norm, std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z));
    const double s = d.x * n[v].x + d.y * n[v].y + d.z * n[v].z;
    if (s > 0.0) m.max_outward = std::fmax(m.max_outward, s);
    if (s < 0.0) m.max_inward = std::fmax(m.max_inward, -s);
  }
  return m;
}

bool bit_identical(const TriangleMesh& a, const TriangleMesh& b) {
  if (a.vertices.size() != b.vertices.size()) return false;
  if (a.triangles != b.triangles) return false;
  return std::memcmp(a.vertices.data(), b.vertices.data(),
                     a.vertices.size() * sizeof(Vec3)) == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// C1 — THE TRUST REGION
// ─────────────────────────────────────────────────────────────────────────────
//
// The case it exists to prevent: an operator run hard enough to walk the surface
// off the geometry the export was ever accurate about. Mean-curvature flow at 60
// steps on a voxelized sphere is exactly that operator.
void test_c1_trust_region() {
  std::printf("\n-- C1 THE TRUST REGION ------------------------------------\n");
  const double spacing = 1.0, cell = spacing;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(28, spacing, 10.0, centre);
  CHECK(!mesh.triangles.empty(), "C1 fixture built");

  MeanCurvatureParams p;
  p.steps = 60;

  // ARM 1 — WITHOUT C1. This is the damage, and it must actually occur.
  SurfaceConstraints off;
  off.cell_mm = cell;
  off.trust_voxels = 0.0;  // C1 disabled
  off.preserve_volume = false;
  const SurfaceOperatorResult unbounded = mean_curvature_flow(mesh, p, off);
  const Motion mu = motion_between(mesh, unbounded.mesh);
  std::printf("  without C1: max per-axis motion %.4f mm = %.2f cells\n", mu.max_axis,
              mu.max_axis / cell);
  CHECK(mu.max_axis > 0.5 * cell,
        "C1 POSITIVE CONTROL: unconstrained flow leaves the half-cell band");

  // ARM 2 — WITH C1.
  SurfaceConstraints on = off;
  on.trust_voxels = 0.5;
  const SurfaceOperatorResult bounded = mean_curvature_flow(mesh, p, on);
  const Motion mb = motion_between(mesh, bounded.mesh);
  std::printf("  with    C1: max per-axis motion %.4f mm = %.2f cells "
              "(%zu vertices clamped, deepest pull-back %.4f mm)\n",
              mb.max_axis, mb.max_axis / cell, bounded.stats.c1_clamped,
              bounded.stats.max_c1_pullback_mm);
  // The bound is per axis, at half a cell, with a floating-point tolerance only.
  CHECK(mb.max_axis <= 0.5 * cell + 1e-9, "C1: no vertex leaves its voxel");
  CHECK(bounded.stats.c1_clamped > 0, "C1 POSITIVE CONTROL: the clamp actually bit");

  // And the same bound for operator B, which reaches the trust region by a
  // different route (a constructed target rather than an accumulated flow).
  RampParams rp;
  rp.steps = 4;
  const SurfaceOperatorResult ramp_on = ramp_reconstruction(mesh, rp, on);
  double worst = 0.0;
  // Operator B refines, so only the first vertices_in entries have an input to
  // be compared against; the appended ones were born on the surface and carry
  // their own boxes (checked by the operator's own c1 counters).
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
    const Vec3& a = mesh.vertices[v];
    const Vec3& b = ramp_on.mesh.vertices[v];
    worst = std::fmax(worst, std::fmax(std::fabs(a.x - b.x),
                                       std::fmax(std::fabs(a.y - b.y),
                                                 std::fabs(a.z - b.z))));
  }
  std::printf("  operator B with C1: max per-axis motion %.4f mm = %.2f cells\n",
              worst, worst / cell);
  CHECK(worst <= 0.5 * cell + 1e-9, "C1 holds for operator B too");
}

// ─────────────────────────────────────────────────────────────────────────────
// C2 — THE SIGNED TRUST REGION
// ─────────────────────────────────────────────────────────────────────────────
void test_c2_signed_bounds() {
  std::printf("\n-- C2 THE SIGNED TRUST REGION -----------------------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(28, spacing, 10.0, centre);

  MeanCurvatureParams p;
  p.steps = 30;
  SurfaceConstraints base;
  base.cell_mm = spacing;
  base.trust_voxels = 0.5;
  base.preserve_volume = false;  // isolate C2; C3 has its own case

  // ARM 1 — WITHOUT C2. Curvature flow on a voxelized sphere moves material BOTH
  // ways: it cuts the outward step corners in and pushes the inward ones out.
  // The inward motion is the damage — that is material leaving a section.
  const SurfaceOperatorResult free_run = mean_curvature_flow(mesh, p, base);
  const Motion mf = motion_between(mesh, free_run.mesh);
  std::printf("  without C2: max inward %.4f mm, max outward %.4f mm\n",
              mf.max_inward, mf.max_outward);
  CHECK(mf.max_inward > 1e-6,
        "C2 POSITIVE CONTROL: unsigned flow removes material somewhere");
  CHECK(mf.max_outward > 1e-6,
        "C2 POSITIVE CONTROL: unsigned flow adds material somewhere");

  // ARM 2a — OUTWARD ONLY. "Material matters here": nothing may be removed.
  {
    SurfaceConstraints k = base;
    k.sign.assign(mesh.vertices.size(), TrustSign::OutwardOnly);
    const SurfaceOperatorResult r = mean_curvature_flow(mesh, p, k);
    const Motion m = motion_between(mesh, r.mesh);
    std::printf("  OutwardOnly: max inward %.4e mm (must be 0), max outward %.4f mm,"
                " %zu vertices projected\n",
                m.max_inward, m.max_outward, r.stats.c2_projected);
    CHECK(m.max_inward <= 1e-9, "C2 OutwardOnly: no vertex removes material");
    CHECK(r.stats.c2_projected > 0, "C2 POSITIVE CONTROL: the projection bit");
  }

  // ARM 2b — INWARD ONLY. A design box or clearance binds: nothing may grow out.
  {
    SurfaceConstraints k = base;
    k.sign.assign(mesh.vertices.size(), TrustSign::InwardOnly);
    const SurfaceOperatorResult r = mean_curvature_flow(mesh, p, k);
    const Motion m = motion_between(mesh, r.mesh);
    std::printf("  InwardOnly : max outward %.4e mm (must be 0), max inward %.4f mm,"
                " %zu vertices projected\n",
                m.max_outward, m.max_inward, r.stats.c2_projected);
    CHECK(m.max_outward <= 1e-9, "C2 InwardOnly: no vertex adds material");
    CHECK(r.stats.c2_projected > 0, "C2 POSITIVE CONTROL: the projection bit");
  }

  // ARM 2c — PINNED. BOTH bind. The rule is "do nothing", NOT a compromise
  // between the two, so the assertion is bit-identity and not a small number.
  {
    SurfaceConstraints k = base;
    k.sign.assign(mesh.vertices.size(), TrustSign::Pinned);
    const SurfaceOperatorResult a = mean_curvature_flow(mesh, p, k);
    const SurfaceOperatorResult b = ramp_reconstruction(mesh, [] {
      RampParams q;
      q.steps = 4;
      q.target_edge_cells = 0.0;  // no refinement, so the vertex sets align
      return q;
    }(), k);
    std::printf("  Pinned     : A bit-identical %s, B bit-identical %s "
                "(%zu pinned)\n",
                bit_identical(mesh, a.mesh) ? "yes" : "NO",
                bit_identical(mesh, b.mesh) ? "yes" : "NO", a.stats.pinned);
    CHECK(bit_identical(mesh, a.mesh), "C2 Pinned: operator A moves nothing, bitwise");
    CHECK(bit_identical(mesh, b.mesh), "C2 Pinned: operator B moves nothing, bitwise");
    CHECK(a.stats.pinned == mesh.vertices.size(), "C2 Pinned: every vertex counted");
  }

  // ARM 2d — a MIXED field, which is the real case: the sign varies per vertex
  // and each vertex must obey its own. Half the sphere OutwardOnly, half Inward.
  {
    SurfaceConstraints k = base;
    k.sign.assign(mesh.vertices.size(), TrustSign::Both);
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
      k.sign[v] = mesh.vertices[v].z < centre.z ? TrustSign::OutwardOnly
                                                : TrustSign::InwardOnly;
    const SurfaceOperatorResult r = mean_curvature_flow(mesh, p, k);
    const std::vector<Vec3> n = vertex_normals(mesh);
    double worst_out = 0.0, worst_in = 0.0;
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      const Vec3 d{r.mesh.vertices[v].x - mesh.vertices[v].x,
                   r.mesh.vertices[v].y - mesh.vertices[v].y,
                   r.mesh.vertices[v].z - mesh.vertices[v].z};
      const double s = d.x * n[v].x + d.y * n[v].y + d.z * n[v].z;
      if (k.sign[v] == TrustSign::OutwardOnly && s < 0.0)
        worst_in = std::fmax(worst_in, -s);
      if (k.sign[v] == TrustSign::InwardOnly && s > 0.0)
        worst_out = std::fmax(worst_out, s);
    }
    std::printf("  mixed      : worst OutwardOnly violation %.4e mm, worst "
                "InwardOnly violation %.4e mm\n", worst_in, worst_out);
    CHECK(worst_in <= 1e-9 && worst_out <= 1e-9,
          "C2 mixed: every vertex obeys its OWN sign");
  }
}

// The classifier that FEEDS C2 — the "material matters" determination itself.
void test_c2_classification() {
  std::printf("\n-- C2 CLASSIFICATION --------------------------------------\n");
  const double spacing = 1.0;
  const int n = 16;

  // A slab 6 voxels thick with a 1-voxel-thick fin sticking out of it. The slab
  // is thick, the fin is thinner than the 2-voxel floor §7 V3 already gates on.
  VoxelGrid g = make_grid(n, spacing, [](int i, int j, int k) {
    const bool slab = (j >= 4 && j < 10) && (i >= 2 && i < 14) && (k >= 2 && k < 14);
    const bool fin = (j >= 10 && j < 14) && (i >= 7 && i < 8) && (k >= 5 && k < 11);
    return slab || fin;
  });
  const std::vector<double> occ = occupancy(g);
  const TriangleMesh mesh =
      marching_cubes(g.nx, g.ny, g.nz, g.spacing, g.origin, occ, 0.5);
  CHECK(!mesh.triangles.empty(), "C2 classification fixture built");

  // (b) THIN SECTION alone.
  {
    TrustSignPolicy pol;
    pol.load_path_binds = false;
    const std::vector<TrustSign> s = classify_trust_sign(mesh, g, occ, pol);
    std::size_t outward = 0, both = 0;
    std::size_t fin_outward = 0, fin_total = 0;
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      if (s[v] == TrustSign::OutwardOnly) ++outward;
      if (s[v] == TrustSign::Both) ++both;
      // y > 11.5 puts the vertex in voxel row j >= 11, whose 26-neighbourhood is
      // fin and void only. A vertex nearer the junction genuinely touches the
      // 6 mm slab and is NOT on a thin section — asserting otherwise would be
      // asserting the predicate is wrong.
      if (mesh.vertices[v].y > 11.5) {
        ++fin_total;
        if (s[v] == TrustSign::OutwardOnly) ++fin_outward;
      }
    }
    std::printf("  thin section: %zu OutwardOnly, %zu Both; on the fin %zu/%zu "
                "OutwardOnly\n", outward, both, fin_outward, fin_total);
    CHECK(fin_total > 0, "C2 classification: the fin has vertices to classify");
    CHECK(fin_outward == fin_total,
          "C2 classification: EVERY fin vertex reads as material that matters");
    CHECK(both > 0,
          "C2 POSITIVE CONTROL: the thick slab is NOT all flagged (or the "
          "predicate is trivially true)");
  }

  // (a) LOAD PATH alone: tag one slab voxel Load and it must flip.
  {
    const std::size_t tagged = g.index(3, 5, 3);
    g.tags[tagged] = VoxelTag::Load;
    TrustSignPolicy pol;
    pol.thin_section_mm = 1e-9;  // thin-section half effectively off
    const std::vector<TrustSign> s = classify_trust_sign(mesh, g, occ, pol);
    std::size_t near_load = 0, flagged = 0;
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      const Vec3& p = mesh.vertices[v];
      const bool near = std::fabs(p.x - 3.5) <= 1.5 && std::fabs(p.y - 5.5) <= 1.5 &&
                        std::fabs(p.z - 3.5) <= 1.5;
      if (!near) continue;
      ++near_load;
      if (s[v] == TrustSign::OutwardOnly) ++flagged;
    }
    std::printf("  load path   : %zu/%zu vertices beside the Load voxel flagged\n",
                flagged, near_load);
    CHECK(near_load > 0, "C2 classification: the Load voxel has surface beside it");
    CHECK(flagged == near_load, "C2 classification: the load path binds outward");
    g.tags[tagged] = VoxelTag::Interior;  // restore
  }

  // The design box, and the CONFLICT. A box that clips the slab makes the
  // vertices at its wall InwardOnly; where the fin ALSO reaches that wall, both
  // bind and the answer must be Pinned rather than either one of them.
  {
    TrustSignPolicy pol;
    pol.load_path_binds = false;
    pol.has_design_box = true;
    pol.box_min = Vec3{-100.0, -100.0, -100.0};
    // y clips the FIN (thin -> both bind -> Pinned); z clips the SLAB (thick ->
    // only the box binds -> InwardOnly). One fixture, both outcomes.
    pol.box_max = Vec3{100.0, 13.0, 13.0};
    pol.bind_tol_mm = 1.0;
    const std::vector<TrustSign> s = classify_trust_sign(mesh, g, occ, pol);
    std::size_t inward = 0, pinned = 0;
    for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
      if (s[v] == TrustSign::InwardOnly) ++inward;
      if (s[v] == TrustSign::Pinned) ++pinned;
    }
    std::printf("  box + fin   : %zu InwardOnly, %zu Pinned\n", inward, pinned);
    CHECK(inward > 0, "C2 classification: the box binds inward somewhere");
    CHECK(pinned > 0,
          "C2 classification: where BOTH bind the answer is Pinned, not a "
          "compromise");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// C3 — VOLUME PRESERVATION
// ─────────────────────────────────────────────────────────────────────────────
//
// The case it exists to prevent is the textbook one: mean-curvature flow shrinks
// a convex body monotonically. Left alone it would eat the part.
void test_c3_volume() {
  std::printf("\n-- C3 VOLUME PRESERVATION ---------------------------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(28, spacing, 10.0, centre);
  const double v0 = std::fabs(signed_volume(mesh));

  MeanCurvatureParams p;
  p.steps = 40;

  // ARM 1 — WITHOUT C3.
  SurfaceConstraints off;
  off.cell_mm = spacing;
  off.trust_voxels = 0.5;
  off.preserve_volume = false;
  const SurfaceOperatorResult shrunk = mean_curvature_flow(mesh, p, off);
  const double v1 = std::fabs(signed_volume(shrunk.mesh));
  std::printf("  without C3: %.4f -> %.4f mm3  (%+.4f%%)\n", v0, v1,
              100.0 * (v1 - v0) / v0);
  CHECK(v1 < v0, "C3 POSITIVE CONTROL: unconstrained curvature flow SHRINKS");
  CHECK((v0 - v1) / v0 > 1e-4,
        "C3 POSITIVE CONTROL: the shrink is large enough to matter");

  // ARM 2 — WITH C3.
  SurfaceConstraints on = off;
  on.preserve_volume = true;
  const SurfaceOperatorResult kept = mean_curvature_flow(mesh, p, on);
  const double v2 = std::fabs(signed_volume(kept.mesh));
  std::printf("  with    C3: %.4f -> %.4f mm3  (%+.6f%%) in %d shift iterations\n",
              v0, v2, 100.0 * (v2 - v0) / v0, kept.stats.volume_shift_iterations);
  CHECK(kept.stats.volume_drift_fraction < 1e-6,
        "C3: drift below 1e-4 % after the uniform shift");
  CHECK(kept.stats.volume_drift_fraction < (v0 - v1) / v0,
        "C3: the compensator strictly improves on the uncompensated drift");

  // And for operator B.
  {
    RampParams rp;
    rp.steps = 4;
    const SurfaceOperatorResult b = ramp_reconstruction(mesh, rp, on);
    std::printf("  operator B: %.4f -> %.4f mm3  (drift %.6f%%)\n",
                b.stats.volume_before_mm3, b.stats.volume_after_mm3,
                100.0 * b.stats.volume_drift_fraction);
    CHECK(b.stats.volume_drift_fraction < 1e-6, "C3: operator B holds volume too");
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The pieces operator B is built out of.
// ─────────────────────────────────────────────────────────────────────────────
void test_refinement() {
  std::printf("\n-- REFINEMENT (operator B's first half) -------------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(20, spacing, 7.0, centre);
  const auto edges = mesh_edges(mesh);

  // A DELIBERATELY PARTIAL split — every third edge — because the T-junction it
  // would create is the whole reason the routine is edge-driven. A uniform 1->4
  // split would pass even if the faces disagreed about their shared edges.
  std::vector<char> flag(edges.size(), 0);
  std::size_t want = 0;
  for (std::size_t e = 0; e < edges.size(); ++e)
    if (e % 3 == 0) { flag[e] = 1; ++want; }

  const TriangleMesh fine = refine_edges(mesh, flag, edges, nullptr);
  const auto wt_before = topopt::check_watertight(mesh);
  const auto wt_after = topopt::check_watertight(fine);
  const double v_before = std::fabs(signed_volume(mesh));
  const double v_after = std::fabs(signed_volume(fine));
  std::printf("  %zu verts / %zu tris -> %zu / %zu (%zu edges split)\n",
              mesh.vertices.size(), mesh.triangles.size(), fine.vertices.size(),
              fine.triangles.size(), want);
  std::printf("  watertight %s -> %s ; volume %.6f -> %.6f mm3 (%.3e relative)\n",
              wt_before.watertight ? "yes" : "no", wt_after.watertight ? "yes" : "no",
              v_before, v_after, std::fabs(v_after - v_before) / v_before);
  CHECK(wt_before.watertight, "refinement fixture is watertight to begin with");
  CHECK(wt_after.watertight, "refine_edges keeps the mesh watertight (no T-junctions)");
  CHECK(fine.vertices.size() == mesh.vertices.size() + want,
        "refine_edges adds exactly one vertex per split edge");
  // Splitting an edge at its midpoint moves NO surface: the new vertex lies on
  // the old edge and the old faces are subdivided in their own planes. That is
  // what lets operator B add points without the addition itself being a change.
  CHECK(std::fabs(v_after - v_before) / v_before < 1e-12,
        "refine_edges is exactly volume-neutral");
}

// The orientation bar. `vertex_normals` must return GEOMETRICALLY outward
// normals on both winding conventions in this codebase — the UV sphere built
// here and core's own marching_cubes output, which is wound the other way. Every
// C2 guarantee is stated in terms of "outward", so a flipped normal turns the
// constraint that protects material into the one that removes it while still
// reporting success.
void test_normal_orientation() {
  std::printf("\n-- NORMAL ORIENTATION -------------------------------------\n");
  const double R = 8.0;
  const Vec3 c{0.0, 0.0, 0.0};
  const TriangleMesh uv = uv_sphere_mesh(24, 48, R, c);
  Vec3 vc;
  const TriangleMesh mc = voxel_sphere_mesh(28, 1.0, 10.0, vc);
  struct Case { const char* name; const TriangleMesh* m; Vec3 centre; };
  const Case cases[2] = {{"uv_sphere", &uv, c}, {"marching_cubes", &mc, vc}};
  for (const Case& cs : cases) {
    const std::vector<Vec3> n = vertex_normals(*cs.m);
    std::size_t out = 0, in = 0;
    for (std::size_t v = 0; v < cs.m->vertices.size(); ++v) {
      const Vec3 r{cs.m->vertices[v].x - cs.centre.x, cs.m->vertices[v].y - cs.centre.y,
                   cs.m->vertices[v].z - cs.centre.z};
      (r.x * n[v].x + r.y * n[v].y + r.z * n[v].z > 0.0) ? ++out : ++in;
    }
    std::printf("  %-15s signed_volume %+12.4f -> %zu radially outward, %zu inward\n",
                cs.name, signed_volume(*cs.m), out, in);
    CHECK(in == 0, "vertex_normals points geometrically OUTWARD on this winding");
  }
}

void test_curvature_sign() {
  std::printf("\n-- MEAN CURVATURE SIGN ------------------------------------\n");
  // On a convex body the mean-curvature normal must point INWARD, so following
  // it is a shrinking flow. If this convention ever flips, both operators would
  // silently INFLATE and every other bar here would still pass.
  const double R = 8.0;
  const TriangleMesh mesh = uv_sphere_mesh(24, 48, R, Vec3{0.0, 0.0, 0.0});
  const std::vector<Vec3> kn = mean_curvature_normals(mesh);
  const std::vector<Vec3> n = vertex_normals(mesh);
  std::size_t inward = 0, outward = 0;
  double worst_mag_err = 0.0;
  for (std::size_t v = 0; v < kn.size(); ++v) {
    const double s = kn[v].x * n[v].x + kn[v].y * n[v].y + kn[v].z * n[v].z;
    if (s < 0.0) ++inward;
    if (s > 0.0) ++outward;
    // |Kn| = 2H = 2/R on a sphere. The MAGNITUDE is checked too: a sign test
    // alone would pass on an operator whose strength was off by a factor.
    worst_mag_err = std::fmax(worst_mag_err, std::fabs(std::fabs(s) - 2.0 / R));
  }
  std::printf("  smooth R=%.1f sphere: %zu inward, %zu outward; |Kn| vs 2/R=%.4f "
              "worst error %.4f (1/mm)\n", R, inward, outward, 2.0 / R, worst_mag_err);
  CHECK(outward == 0, "mean curvature normal points inward EVERYWHERE on a convex body");
  CHECK(worst_mag_err < 0.02,
        "mean curvature magnitude is 2/R on a sphere (the operator's strength is "
        "a surface property, not a tessellation artefact)");

  // DENSITY INDEPENDENCE, the property that separates A from the Taubin family:
  // refining the tessellation must not change the curvature the operator reads.
  const TriangleMesh fine = uv_sphere_mesh(48, 96, R, Vec3{0.0, 0.0, 0.0});
  const std::vector<Vec3> knf = mean_curvature_normals(fine);
  const std::vector<Vec3> nf = vertex_normals(fine);
  double worst_fine = 0.0;
  for (std::size_t v = 0; v < knf.size(); ++v) {
    const double s = knf[v].x * nf[v].x + knf[v].y * nf[v].y + knf[v].z * nf[v].z;
    worst_fine = std::fmax(worst_fine, std::fabs(std::fabs(s) - 2.0 / R));
  }
  std::printf("  4x the triangles: worst error %.4f (1/mm) — unchanged, so the "
              "strength is mesh-density independent\n", worst_fine);
  CHECK(worst_fine < 0.02, "curvature is density independent under refinement");
}

void test_off_is_identity() {
  std::printf("\n-- OFF IS IDENTITY ----------------------------------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(20, spacing, 7.0, centre);
  SurfaceConstraints k;
  k.cell_mm = spacing;

  MeanCurvatureParams a;
  a.steps = 0;
  RampParams b;
  b.steps = 0;
  const TriangleMesh ma = mean_curvature_flow(mesh, a, k).mesh;
  const TriangleMesh mb = ramp_reconstruction(mesh, b, k).mesh;
  CHECK(bit_identical(mesh, ma), "operator A at 0 steps is bit-identical");
  CHECK(bit_identical(mesh, mb), "operator B at 0 steps is bit-identical");

  // DETERMINISM: the same input twice is byte-identical, for both.
  MeanCurvatureParams a2;
  a2.steps = 12;
  RampParams b2;
  b2.steps = 3;
  CHECK(bit_identical(mean_curvature_flow(mesh, a2, k).mesh,
                      mean_curvature_flow(mesh, a2, k).mesh),
        "operator A is deterministic");
  CHECK(bit_identical(ramp_reconstruction(mesh, b2, k).mesh,
                      ramp_reconstruction(mesh, b2, k).mesh),
        "operator B is deterministic");
  std::printf("  both operators: OFF is bit-identical, and both are deterministic\n");
}

// C5 — the brush. Weight 0 must be verbatim, and weight must never be a way to
// smooth something a sign forbids.
void test_c5_brush() {
  std::printf("\n-- C5 THE BRUSH -------------------------------------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(24, spacing, 8.0, centre);
  MeanCurvatureParams p;
  p.steps = 20;

  SurfaceConstraints k;
  k.cell_mm = spacing;
  k.trust_voxels = 0.5;
  k.preserve_volume = false;
  k.vertex_weight.assign(mesh.vertices.size(), 0.0);
  std::size_t painted = 0;
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
    if (mesh.vertices[v].z > centre.z) { k.vertex_weight[v] = 1.0; ++painted; }

  const SurfaceOperatorResult r = mean_curvature_flow(mesh, p, k);
  std::size_t moved_unpainted = 0;
  double moved_painted = 0.0;
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
    const bool same = std::memcmp(&mesh.vertices[v], &r.mesh.vertices[v],
                                  sizeof(Vec3)) == 0;
    if (k.vertex_weight[v] == 0.0) {
      if (!same) ++moved_unpainted;
    } else if (!same) {
      const Vec3 d{r.mesh.vertices[v].x - mesh.vertices[v].x,
                   r.mesh.vertices[v].y - mesh.vertices[v].y,
                   r.mesh.vertices[v].z - mesh.vertices[v].z};
      moved_painted = std::fmax(moved_painted,
                                std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z));
    }
  }
  std::printf("  %zu painted / %zu total; unpainted vertices moved: %zu; "
              "deepest painted motion %.4f mm\n",
              painted, mesh.vertices.size(), moved_unpainted, moved_painted);
  CHECK(moved_unpainted == 0, "C5: a weight-0 vertex is bit-identical");
  CHECK(moved_painted > 1e-6, "C5 POSITIVE CONTROL: painted vertices did move");

  // A weight on a PINNED vertex cannot move it: the sign is tested first.
  SurfaceConstraints k2 = k;
  k2.vertex_weight.assign(mesh.vertices.size(), 1.0);
  k2.sign.assign(mesh.vertices.size(), TrustSign::Pinned);
  CHECK(bit_identical(mesh, mean_curvature_flow(mesh, p, k2).mesh),
        "C5: a brush weight cannot move what C2 pinned");
}

// REFINEMENT MUST NOT MANUFACTURE UNCONSTRAINED VERTICES. Operator B splits edges
// INSIDE a terrace, so a terrace sitting on a pinned load pad would otherwise
// acquire a fresh vertex in the middle of it that no constraint had ever been
// computed for — and the operator would move it. The case this prevents is a
// protected region being smoothed through a hole in its own bookkeeping.
void test_refined_vertices_inherit_constraints() {
  std::printf("\n-- REFINED VERTICES INHERIT THEIR PARENTS -----------------\n");
  const double spacing = 1.0;
  Vec3 centre;
  const TriangleMesh mesh = voxel_sphere_mesh(24, spacing, 8.0, centre);

  RampParams p;
  p.steps = 3;
  p.target_edge_cells = 0.5;  // refinement ON — that is the point
  SurfaceConstraints base;
  base.cell_mm = spacing;
  base.trust_voxels = 0.5;
  base.preserve_volume = false;

  // The reference: everything pinned, so the mesh is refined but NOTHING moves.
  // Refinement is independent of the sign, so this gives every vertex — original
  // and appended — the position it was born at.
  SurfaceConstraints all_pin = base;
  all_pin.sign.assign(mesh.vertices.size(), TrustSign::Pinned);
  const SurfaceOperatorResult ref = ramp_reconstruction(mesh, p, all_pin);
  CHECK(ref.stats.vertices_out > ref.stats.vertices_in,
        "the fixture actually refines (otherwise this bar is vacuous)");
  CHECK(ref.stats.max_displacement_mm == 0.0,
        "all-pinned: refinement happens but nothing moves");

  // Half pinned. Every vertex born BETWEEN two pinned parents must still sit
  // exactly where the reference put it.
  SurfaceConstraints half = base;
  half.sign.assign(mesh.vertices.size(), TrustSign::Both);
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
    if (mesh.vertices[v].z > centre.z) half.sign[v] = TrustSign::Pinned;
  const SurfaceOperatorResult run = ramp_reconstruction(mesh, p, half);
  CHECK(run.mesh.vertices.size() == ref.mesh.vertices.size(),
        "refinement is deterministic and sign-independent");

  // A vertex is "in the pinned region" when it lies strictly above the plane —
  // an appended vertex qualifies only if BOTH its parents did, which is exactly
  // when its midpoint is above the plane too.
  std::size_t pinned_moved = 0, free_moved = 0, pinned_seen = 0;
  for (std::size_t v = 0; v < run.mesh.vertices.size(); ++v) {
    const bool same =
        std::memcmp(&ref.mesh.vertices[v], &run.mesh.vertices[v], sizeof(Vec3)) == 0;
    if (ref.mesh.vertices[v].z > centre.z) {
      ++pinned_seen;
      if (!same) ++pinned_moved;
    } else if (!same) {
      ++free_moved;
    }
  }
  std::printf("  %zu -> %zu verts; in the pinned half %zu vertices, %zu moved; "
              "%zu moved outside it\n", run.stats.vertices_in, run.stats.vertices_out,
              pinned_seen, pinned_moved, free_moved);
  CHECK(pinned_moved == 0,
        "no vertex in the pinned region moved — including ones refinement created");
  CHECK(free_moved > 0, "POSITIVE CONTROL: the unpinned half did move");

  // The same for the brush: a vertex born between two unpainted parents inherits
  // weight 0 and must be verbatim.
  SurfaceConstraints brushed = base;
  brushed.vertex_weight.assign(mesh.vertices.size(), 0.0);
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v)
    if (mesh.vertices[v].z <= centre.z) brushed.vertex_weight[v] = 1.0;
  const SurfaceOperatorResult br = ramp_reconstruction(mesh, p, brushed);
  std::size_t unpainted_moved = 0;
  for (std::size_t v = 0; v < br.mesh.vertices.size(); ++v)
    if (ref.mesh.vertices[v].z > centre.z &&
        std::memcmp(&ref.mesh.vertices[v], &br.mesh.vertices[v], sizeof(Vec3)) != 0)
      ++unpainted_moved;
  std::printf("  brush: %zu vertices in the unpainted half moved\n", unpainted_moved);
  CHECK(unpainted_moved == 0,
        "a vertex born between two unpainted parents inherits weight 0");
}

}  // namespace

int main() {
  std::printf("== test_surface_operator ==\n");
  test_c1_trust_region();
  test_c2_signed_bounds();
  test_c2_classification();
  test_c3_volume();
  test_refinement();
  test_normal_orientation();
  test_curvature_sign();
  test_off_is_identity();
  test_c5_brush();
  test_refined_vertices_inherit_constraints();
  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
