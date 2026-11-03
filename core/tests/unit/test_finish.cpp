// ENGINE BATCH E1 — the finished shape (finish.hpp): (c) thin-spot cleanup adds
// material only; (d) the mean-curvature surface finish in the Gibson trust region;
// the cube golden; (e)'s plain verdict lines.
//   (d1) the analytic sphere (PR 306's fixture: R 20 mm, spacing 1.620040 mm, export
//        factor 2, tricubic, through the STL round trip): >= 45 % of the stair-step
//        amplitude removed, no vertex outside its cell (0.5 x cell on every axis);
//   (d2) PR 306's dumbbell (2-voxel neck, the design box clipping one side): the
//        minimum cross-section unchanged, nothing past the box;
//   (c1) a 0.5 mm plate between two blocks is thickened to the 0.9 mm minimum;
//   (c2) the same plate between two Keep clears is left as it is and reported;
//   (g)  the cube golden: volume after >= before, CAD-face and keep-region vertices
//        bit-identical, no vertex in a Keep clear;
//   (e)  the plain lines a finished shape refuses with.

#include "topopt/cad_project.hpp"
#include "topopt/finish.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/stl.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include "surface_instruments.hpp"

#include <manifold/manifold.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace topopt;
using namespace topopt::surface_instruments;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

std::vector<double> occupancy(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (std::size_t i = 0; i < d.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) d[i] = 1.0;
  return d;
}

TriangleMesh round_trip(const TriangleMesh& m, const std::string& name) {
  const std::string p = std::string(TMP_DIR) + "/" + name;
  write_stl_file(p, m);
  return read_stl_file(p).mesh;
}

TriangleMesh from_manifold(const manifold::Manifold& man) {
  const manifold::MeshGL g = man.GetMeshGL();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1],
                            g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]),
                             static_cast<int>(g.triVerts[3 * t + 1]),
                             static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}

double max_axis_move(const TriangleMesh& a, const TriangleMesh& b) {
  double w = 0.0;
  for (std::size_t v = 0; v < a.vertices.size() && v < b.vertices.size(); ++v)
    w = std::max({w, std::fabs(a.vertices[v].x - b.vertices[v].x),
                  std::fabs(a.vertices[v].y - b.vertices[v].y),
                  std::fabs(a.vertices[v].z - b.vertices[v].z)});
  return w;
}

bool same_bits(const Vec3& a, const Vec3& b) { return std::memcmp(&a, &b, sizeof(Vec3)) == 0; }

// Two 10 mm blocks joined by a plate `t` mm thick (z centred at 5), refined dense.
TriangleMesh plate_part(double t) {
  using manifold::Manifold;
  const Manifold a = Manifold::Cube({10.0, 10.0, 10.0});
  const Manifold b = Manifold::Cube({10.0, 10.0, 10.0}).Translate({20.0, 0.0, 0.0});
  const Manifold p = Manifold::Cube({12.0, 10.0, t}).Translate({9.0, 0.0, 5.0 - 0.5 * t});
  return from_manifold((a + b + p).RefineToLength(0.4));
}

}  // namespace

int main() {
  // ── (d1) the analytic sphere ───────────────────────────────────────────────
  {
    const double sp = 1.620040, R = 20.0;
    const int n = static_cast<int>(std::ceil(2.4 * R / sp));
    VoxelGrid g;
    g.nx = g.ny = g.nz = n;
    g.spacing = sp;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
    const double half = 0.5 * n * sp;
    for (int k = 0; k < n; ++k)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
          const Vec3 p = g.voxel_center(i, j, k);
          const double dx = p.x - half, dy = p.y - half, dz = p.z - half;
          if (dx * dx + dy * dy + dz * dz <= R * R) g.tags[g.index(i, j, k)] = VoxelTag::Interior;
        }
    const TriangleMesh m0 = round_trip(
        marching_cubes_resampled(g.nx, g.ny, g.nz, g.spacing, g.origin, occupancy(g), 0.5, 2,
                                 ResampleInterp::Tricubic),
        "finish_sphere.stl");
    auto rms_dev = [&](const TriangleMesh& m) {
      double s2 = 0.0;
      for (const Vec3& v : m.vertices) {
        const double e = std::sqrt((v.x - half) * (v.x - half) + (v.y - half) * (v.y - half) +
                                   (v.z - half) * (v.z - half)) - R;
        s2 += e * e;
      }
      return std::sqrt(s2 / static_cast<double>(m.vertices.size()));
    };
    FinishContext ctx;
    ctx.cell_mm = sp / 2.0;
    FinishReport rep;
    const TriangleMesh m1 = surface_finish(m0, ctx, {}, {}, &rep);
    const double d0 = rms_dev(m0), d1 = rms_dev(m1);
    const double removed = 100.0 * (1.0 - d1 / d0);
    const double move = max_axis_move(m0, m1);
    std::printf("[finish] (d1) sphere: rms deviation %.4f -> %.4f mm, %.1f %% removed (the report's "
                "conservative estimate %.1f %%); max move %.4f mm per axis, cell %.4f\n",
                d0, d1, removed, rep.stair_step_removed_pct, move, ctx.cell_mm);
    CHECK(removed >= 45.0, "(d1) >= 45 % of the stair-step amplitude removed");
    CHECK(move <= 0.5 * ctx.cell_mm + 1e-9, "(d1) no vertex leaves its cell (Gibson)");
  }

  // ── (d2) the dumbbell neck ─────────────────────────────────────────────────
  {
    const int n = 28;
    VoxelGrid g;
    g.nx = g.ny = g.nz = n;
    g.spacing = 1.0;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
    const int lo = n / 2 - 1, hi = lo + 2;
    for (int k = 0; k < n; ++k)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
          const bool a = i >= 2 && i < 10 && j >= 9 && j < 19 && k >= 9 && k < 19;
          const bool b = i >= 18 && i < 26 && j >= 9 && j < 19 && k >= 9 && k < 19;
          const bool bridge = i >= 10 && i < 18 && j >= lo && j < hi && k >= lo && k < hi;
          if (a || b || bridge) g.tags[g.index(i, j, k)] = VoxelTag::Interior;
        }
    const std::vector<double> occ = occupancy(g);
    const TriangleMesh m0 = round_trip(
        marching_cubes_resampled(g.nx, g.ny, g.nz, g.spacing, g.origin, occ, 0.5, 2,
                                 ResampleInterp::Tricubic),
        "finish_dumbbell.stl");
    Vec3 lo3{1e9, 1e9, 1e9}, hi3{-1e9, -1e9, -1e9};
    for (const Vec3& v : m0.vertices) {
      lo3 = {std::min(lo3.x, v.x), std::min(lo3.y, v.y), std::min(lo3.z, v.z)};
      hi3 = {std::max(hi3.x, v.x), std::max(hi3.y, v.y), std::max(hi3.z, v.z)};
    }
    FinishContext ctx;
    ctx.cell_mm = 0.5;
    ctx.grid = &g;
    ctx.density = &occ;
    ctx.growth = true;
    ctx.has_box = true;  // clips the +x side only, as PR 306 did
    ctx.box.min = {lo3.x - 5.0, lo3.y - 5.0, lo3.z - 5.0};
    ctx.box.max = {hi3.x, hi3.y + 5.0, hi3.z + 5.0};
    FinishReport rep;
    const TriangleMesh m1 = surface_finish(m0, ctx, {}, {}, &rep);
    const CrossSection c0 = min_cross_section(m0, g), c1 = min_cross_section(m1, g);
    double past = -1e9;
    for (const Vec3& v : m1.vertices) past = std::max(past, v.x - ctx.box.max.x);
    std::printf("[finish] (d2) dumbbell: minimum cross-section %.4f -> %.4f mm, %zu -> %zu "
                "components; furthest past the box %.4f mm\n",
                c0.min_mm, c1.min_mm, c0.components, c1.components, past);
    CHECK(c1.min_mm >= c0.min_mm - 1e-9 && c1.components == c0.components,
          "(d2) the minimum cross-section is unchanged");
    CHECK(past <= 1e-9, "(d2) nothing moves past the design box");
  }

  // ── (c1) a thin plate is thickened; (c2) a blocked one is reported ─────────
  {
    const TriangleMesh m0 = plate_part(0.5);
    const double v0 = signed_volume(m0);
    FinishContext ctx;
    ctx.min_thickness_mm = 0.9;
    ctx.min_thickness_source = "2 x outer wall line width (0.45 mm)";
    FinishReport rep;
    const TriangleMesh m1 = thin_spot_cleanup(m0, ctx, {}, &rep);
    const std::vector<double> t1 = vertex_local_thickness_mm(m1, 0.9);
    double thinnest = 0.9;
    for (std::size_t v = 0; v < m1.vertices.size(); ++v) {
      const Vec3& p = m0.vertices[v];
      if (p.x > 11.0 && p.x < 19.0 && p.y > 1.0 && p.y < 9.0) thinnest = std::min(thinnest, t1[v]);
    }
    std::printf("[finish] (c1) plate 0.5 mm: %zu spot(s) fixed, %zu left; plate thinnest after "
                "%.3f mm; volume %.2f -> %.2f mm^3\n",
                rep.fixed.size(), rep.left.size(), thinnest, v0, signed_volume(m1));
    CHECK(!rep.fixed.empty() && rep.left.empty(), "(c1) the thin plate is reported fixed");
    CHECK(thinnest >= 0.88, "(c1) the plate is thickened to the minimum");
    CHECK(signed_volume(m1) > v0, "(c1) only material is added");

    // (c2) Keep clears just above and below the plate.
    VoxelGrid g;
    g.nx = 128; g.ny = 48; g.nz = 40;  // a margin round the plate in x and y
    g.spacing = 0.25;
    g.origin = Vec3{-1.0, -1.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(128 * 48 * 40), VoxelTag::Interior);
    DesignMask forbid(g.voxel_count(), MaskValue::Active);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const Vec3 c = g.voxel_center(i, j, k);
          if (c.x > 10.0 && c.x < 20.0 && std::fabs(c.z - 5.0) > 0.25 && std::fabs(c.z - 5.0) < 2.0)
            forbid[g.index(i, j, k)] = MaskValue::FrozenVoid;
        }
    FinishContext bctx = ctx;
    bctx.grid = &g;
    bctx.forbidden = &forbid;
    bctx.growth = true;
    FinishReport brep;
    const TriangleMesh m2 = thin_spot_cleanup(m0, bctx, {}, &brep);
    bool unchanged = true;
    for (std::size_t v = 0; v < m0.vertices.size(); ++v) {
      const Vec3& p = m0.vertices[v];
      if (p.x > 11.0 && p.x < 19.0 && !same_bits(p, m2.vertices[v])) unchanged = false;
    }
    std::printf("[finish] (c2) blocked plate: %zu fixed, %zu left, reason \"%s\"\n",
                brep.fixed.size(), brep.left.size(),
                brep.left.empty() ? "" : brep.left.front().reason.c_str());
    CHECK(!brep.left.empty() && brep.left.front().reason == "blocked by a Keep clear",
          "(c2) a blocked spot is reported with its reason");
    CHECK(unchanged, "(c2) a blocked spot is left as it is");
  }

  // ── (g) the cube golden ────────────────────────────────────────────────────
  {
    // The CAD: a 20 mm cube. The "export": the cube's voxels with an optimizer bite
    // out of one corner (a sphere), through marching cubes, then CAD-projected.
    using manifold::Manifold;
    const std::string cad_path = std::string(TMP_DIR) + "/finish_cube_cad.stl";
    write_stl_file(cad_path, from_manifold(Manifold::Cube({20.0, 20.0, 20.0})));
    const StepModel cad = import_part(cad_path).model;
    VoxelGrid g;
    g.nx = g.ny = g.nz = 20;
    g.spacing = 1.0;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(20 * 20 * 20), VoxelTag::Interior);
    std::vector<double> rho(g.voxel_count(), 1.0);
    for (int k = 0; k < 20; ++k)
      for (int j = 0; j < 20; ++j)
        for (int i = 0; i < 20; ++i) {
          const Vec3 c = g.voxel_center(i, j, k);
          const double dx = c.x - 20.0, dy = c.y - 20.0, dz = c.z - 20.0;
          if (dx * dx + dy * dy + dz * dz < 9.0 * 9.0) rho[g.index(i, j, k)] = 0.0;
        }
    TriangleMesh m0 = marching_cubes_resampled(g.nx, g.ny, g.nz, g.spacing, g.origin, rho, 0.5,
                                               2, ResampleInterp::Tricubic);
    CadProjectOptions po = cad_project_options_for_grid(g.spacing);
    po.enabled = true;
    m0 = project_onto_cad_faces(m0, cad, po, attribute_to_cad_faces(m0, cad, po));
    const CadAttribution att = attribute_to_cad_faces(m0, cad, po);
    std::vector<KeepRegion> keeps(1);  // Protect the bottom face, 2 mm deep
    keeps[0].min = Vec3{-1.0, -1.0, -1.0};
    keeps[0].max = Vec3{21.0, 21.0, 2.0};
    DesignMask forbid(g.voxel_count(), MaskValue::Active);  // a Keep clear in the bite
    for (int k = 0; k < 20; ++k)
      for (int j = 0; j < 20; ++j)
        for (int i = 0; i < 20; ++i) {
          const Vec3 c = g.voxel_center(i, j, k);
          const double dx = c.x - 20.0, dy = c.y - 20.0, dz = c.z - 20.0;
          if (dx * dx + dy * dy + dz * dz < 5.0 * 5.0) forbid[g.index(i, j, k)] = MaskValue::FrozenVoid;
        }
    std::vector<char> part(g.voxel_count(), 1);
    FinishContext ctx;
    ctx.min_thickness_mm = 0.9;
    ctx.cell_mm = 0.5;
    ctx.grid = &g;
    ctx.density = &rho;
    ctx.forbidden = &forbid;
    ctx.keeps = &keeps;
    ctx.part_solid = &part;
    ctx.cad = &cad;
    ctx.cad_spacing_mm = g.spacing;
    FinishReport rep;
    const TriangleMesh m1 = finish_shape(m0, ctx, &rep);
    std::size_t cad_moved = 0, keep_moved = 0, cad_n = 0, in_clear = 0;
    for (std::size_t v = 0; v < m0.vertices.size(); ++v) {
      const bool on_cad = (v < att.face_of_vertex.size() && att.face_of_vertex[v] >= 0) ||
                          att.ambiguous_at(v);
      if (on_cad) { ++cad_n; cad_moved += !same_bits(m0.vertices[v], m1.vertices[v]); }
      if (keeps[0].contains(m0.vertices[v])) keep_moved += !same_bits(m0.vertices[v], m1.vertices[v]);
      const Vec3& p = m1.vertices[v];
      const int i = static_cast<int>(std::floor(p.x)), j = static_cast<int>(std::floor(p.y)),
                k = static_cast<int>(std::floor(p.z));
      if (i >= 0 && j >= 0 && k >= 0 && i < 20 && j < 20 && k < 20 &&
          forbid[g.index(i, j, k)] == MaskValue::FrozenVoid)
        ++in_clear;
    }
    std::printf("[finish] (g) cube: volume %.3f -> %.3f mm^3; %zu CAD-face vertices, %zu moved; "
                "%zu keep-region vertices moved; %zu vertices in the Keep clear; surface finish "
                "%.1f %%, %zu pinned, %.3f s\n",
                rep.volume_before_mm3, rep.volume_after_mm3, cad_n, cad_moved, keep_moved, in_clear,
                rep.stair_step_removed_pct, rep.pinned_vertices, rep.seconds);
    CHECK(rep.ran && rep.surface_applied, "(g) the finish ran");
    CHECK(rep.volume_after_mm3 >= rep.volume_before_mm3, "(g) volume after >= before");
    CHECK(cad_n > 0 && cad_moved == 0, "(g) CAD-face vertices are bit-identical");
    CHECK(keep_moved == 0, "(g) keep-region vertices are bit-identical");
    CHECK(in_clear == 0, "(g) the Keep clear stays empty");
    CHECK(rep.stair_step_removed_pct > 0.0, "(g) the cut surface is finished");
  }

  // ── (e) the plain lines ────────────────────────────────────────────────────
  {
    FinishRecheck r;
    r.ran = true;
    r.margin = 1.42;
    r.margin_required = 1.5;
    CHECK(finish_verdict_reason(r) == "After finishing, the margin is 1.42\xC3\x97 (needs 1.5\xC3\x97)",
          "(e) a margin under the line refuses with its numbers");
    r.margin = 2.0;
    r.pieces = 2;
    CHECK(finish_verdict_reason(r) == "After finishing, it prints in 2 pieces", "(e) pieces");
    r.pieces = 1;
    r.keep_clear_voxels = 12;
    CHECK(finish_verdict_reason(r) == "After finishing, a Keep clear has material in it",
          "(e) a Keep clear");
    r.keep_clear_voxels = 0;
    CHECK(finish_verdict_reason(r).empty(), "(e) a good finished shape keeps its verdict");
  }

  if (g_failures == 0) {
    std::printf("finish (E1): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "finish (E1): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
