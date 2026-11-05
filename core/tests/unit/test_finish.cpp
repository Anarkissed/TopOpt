// ENGINE BATCH E1 — the finished shape (finish.hpp): (c) thin-spot cleanup adds
// material only; (d) the mean-curvature surface finish in the Gibson trust region;
// the cube golden; (e)'s plain verdict lines.
//   (d1) the analytic sphere (PR 306's fixture: R 20 mm, spacing 1.620040 mm, export
//        factor 2, tricubic, through the STL round trip): >= 45 % of the stair-step
//        amplitude removed, no vertex outside its cell (0.5 x cell on every axis), no
//        triangle turned over;
//   (d2) PR 306's dumbbell (2-voxel neck, the design box clipping one side): the
//        minimum cross-section unchanged, nothing past the box;
//   (c1) a 0.5 mm plate between two blocks is thickened to the 0.9 mm minimum;
//   (c2) the same plate between two Keep clears is left as it is and reported;
//   (g)  the cube golden: volume after >= before, CAD-face and keep-region vertices
//        bit-identical, no vertex in a Keep clear;
//   (e)  the plain lines a finished shape refuses with.
//   (w)  the written file is clean (ruling 2026-11-03 02:46): a sliver on two vertices
//        that are one float is welded away; fragment shells under a solve voxel go,
//        the export's own bodies never; a point contact is seen; file thin joints;
//   (s)  slim, with a safe fallback (his answer, 2026-11-03 02:48): a member between
//        the slim line (1.8 mm) and C2's (2 x spacing) is finished, not held, and
//        nothing goes under 1.8 mm that was not; the fallback decision; (s3) only a
//        move INWARD thins a member (material added never counts).

#include "topopt/cad_project.hpp"
#include "topopt/finish.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/stl.hpp"
#include "topopt/surface_operator.hpp"
#include "topopt/voxel.hpp"

#include "surface_instruments.hpp"

#include <manifold/manifold.h>

#include <array>
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
                "conservative estimate %.1f %%); max move %.4f mm per axis, cell %.4f; %zu fold "
                "corner(s) held, %d re-run(s)\n",
                d0, d1, removed, rep.stair_step_removed_pct, move, ctx.cell_mm,
                rep.fold_held_vertices, rep.slim_rounds);
    CHECK(removed >= 45.0, "(d1) >= 45 % of the stair-step amplitude removed");
    CHECK(move <= 0.5 * ctx.cell_mm + 1e-9, "(d1) no vertex leaves its cell (Gibson)");
    int turned = 0;
    for (const auto& t : m0.triangles) {
      auto nrm = [&](const TriangleMesh& mm) {
        const Vec3& p = mm.vertices[static_cast<std::size_t>(t[0])];
        const Vec3& q = mm.vertices[static_cast<std::size_t>(t[1])];
        const Vec3& r = mm.vertices[static_cast<std::size_t>(t[2])];
        const Vec3 u{q.x - p.x, q.y - p.y, q.z - p.z}, w{r.x - p.x, r.y - p.y, r.z - p.z};
        return Vec3{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
      };
      const Vec3 a0 = nrm(m0), a1 = nrm(m1);
      turned += a0.x * a1.x + a0.y * a1.y + a0.z * a1.z <= 0.0;
    }
    CHECK(turned == 0 && rep.fold_held_vertices > 0,
          "(d1) no triangle turned over (PR 306's flow alone turns 164 of them)");

    // (o) A version with a lattice companion: the companion is built from the
    // unfinished shape, so the finish may only move a vertex outward (the shell never
    // retreats from a strut that reaches it; the plate's lattice stood 0.072 mm out).
    FinishContext octx = ctx;
    octx.outward_only = true;
    FinishReport orep;
    const TriangleMesh mo = surface_finish(m0, octx, {}, {}, &orep);
    const std::vector<Vec3> n0 = vertex_normals(m0);
    double inward = 0.0, outward = 0.0;
    for (std::size_t v = 0; v < m0.vertices.size() && v < mo.vertices.size(); ++v) {
      const Vec3 d{mo.vertices[v].x - m0.vertices[v].x, mo.vertices[v].y - m0.vertices[v].y,
                   mo.vertices[v].z - m0.vertices[v].z};
      const double s = d.x * n0[v].x + d.y * n0[v].y + d.z * n0[v].z;
      inward = std::fmax(inward, -s);
      outward = std::fmax(outward, s);
    }
    std::printf("[finish] (o) sphere, outward only: max inward %.3e mm, max outward %.4f mm, "
                "%.1f %% stair-step removed\n",
                inward, outward, orep.stair_step_removed_pct);
    CHECK(inward <= 1e-9 && outward > 0.0, "(o) outward only: no vertex moves inward");
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
    std::printf("[finish] (g) cube: volume %.6f -> %.6f mm^3; %zu CAD-face vertices, %zu moved; "
                "%zu keep-region vertices moved; %zu vertices in the Keep clear; surface finish "
                "%.1f %%, %zu pinned, %.3f s\n",
                rep.volume_before_mm3, rep.volume_after_mm3, cad_n, cad_moved, keep_moved, in_clear,
                rep.stair_step_removed_pct, rep.pinned_vertices, rep.seconds);
    CHECK(rep.ran && rep.surface_applied, "(g) the finish ran");
    CHECK(rep.volume_after_mm3 >= rep.volume_before_mm3, "(g) volume after >= before");
    CHECK(cad_n > 0 && cad_moved == 0, "(g) CAD-face vertices are bit-identical");
    CHECK(keep_moved == 0, "(g) keep-region vertices are bit-identical");
    CHECK(in_clear == 0, "(g) the Keep clear stays empty");
    {  // and no Keep clear voxel centre the cube did not already enclose
      const VoxelGrid f0 = voxelize_onto_grid(m0, g), f1 = voxelize_onto_grid(m1, g);
      std::size_t added = 0;
      for (std::size_t i = 0; i < forbid.size(); ++i)
        added += forbid[i] == MaskValue::FrozenVoid && f1.tags[i] != VoxelTag::Empty &&
                 f0.tags[i] == VoxelTag::Empty;
      CHECK(added == 0, "(g) the finish encloses no Keep clear centre the export did not");
    }
    {  // the winding test the Keep clear rule confirms with, both windings
      TriangleMesh flipped = m1;
      for (auto& t : flipped.triangles) std::swap(t[1], t[2]);
      const Vec3 in{10.0, 10.0, 5.0}, bite{19.0, 19.0, 19.0}, out{30.0, 10.0, 10.0};
      CHECK(mesh_encloses(m1, in) && mesh_encloses(flipped, in) && !mesh_encloses(m1, bite) &&
                !mesh_encloses(flipped, bite) && !mesh_encloses(m1, out),
            "(g) the winding number tells inside from the bite and the outside");
    }
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
    // ANY material in a Keep clear refuses, whoever put it there (ruling 2026-11-03
    // 19:55): every file is cut out of its Keep clears exactly, so this should never fire.
    r.keep_clear_voxels = 12;
    r.keep_clear_before = 12;
    CHECK(finish_verdict_reason(r) == "A Keep clear has material in it",
          "(e) a Keep clear the unfinished file already printed into refuses too");
    r.keep_clear_added = 3;
    CHECK(finish_verdict_reason(r) == "A Keep clear has material in it",
          "(e) a Keep clear the finish added to");
    r.keep_clear_voxels = 0;
    r.keep_clear_before = 0;
    r.keep_clear_added = 0;
    // A Keep clear the cut left closed in on every side (his ad68d4c0 at 1.55 and 1.25:
    // material over both ends of two bolt holes) is no Keep clear: nothing reaches it.
    r.keep_clear_sealed = 2;
    CHECK(finish_verdict_reason(r) == "A Keep clear is sealed inside the part",
          "(e) a Keep clear sealed inside the part refuses");
    r.keep_clear_sealed = 0;
    CHECK(finish_verdict_reason(r).empty(), "(e) a good finished shape keeps its verdict");
  }

  // ── (w1) a float-coincident sliver ─────────────────────────────────────────
  {
    // An octahedron whose top vertex is split in two, 1e-12 mm apart (one float), with
    // the two zero-area slivers that keep it manifold IN ITS OWN INDICES — exactly what
    // the exact-Protect boolean handed back on his squish rig.
    TriangleMesh m;
    m.vertices = {{0, 0, 1}, {0, 0, -1}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}, {0, -1, 0},
                  {0, 0, 1.0 + 1e-12}};
    const int T = 0, B = 1, Tp = 6;
    auto R = [](int i) { return 2 + (i % 4); };
    m.triangles = {{R(0), R(1), T}, {R(1), R(2), T}, {R(2), R(3), Tp}, {R(3), R(0), Tp},
                   {T, R(2), Tp},   {R(0), T, Tp}};
    for (int i = 0; i < 4; ++i) m.triangles.push_back({R(i + 1), R(i), B});
    const WatertightReport own = check_watertight(m);
    const WrittenAudit as_is = audit_as_written(m);
    const TriangleMesh w = weld_as_written(m);
    const WrittenAudit after = audit_as_written(w);
    std::printf("[finish] (w1) sliver: own indices watertight %d; as written %d edge(s) on more "
                "than two triangles; welded %d, %d open, %d shell(s), %zu triangles\n",
                own.watertight ? 1 : 0, as_is.non_manifold_edges, after.non_manifold_edges,
                after.boundary_edges, after.shells, w.triangles.size());
    CHECK(own.watertight && as_is.non_manifold_edges == 2,
          "(w1) the defect: manifold in its indices, four triangles on an edge as written");
    CHECK(after.non_manifold_edges == 0 && after.boundary_edges == 0 && after.shells == 1 &&
              after.bodies == 1 && w.triangles.size() == 8,
          "(w1) welded as written: the octahedron, clean");
    CHECK(std::fabs(signed_volume(w) - signed_volume(m)) < 1e-9, "(w1) the weld moves nothing");
    TriangleMesh plain = m;
    plain.vertices.pop_back();
    plain.triangles = {};
    for (int i = 0; i < 4; ++i) plain.triangles.push_back({R(i), R(i + 1), T});
    for (int i = 0; i < 4; ++i) plain.triangles.push_back({R(i + 1), R(i), B});
    const TriangleMesh same = weld_as_written(plain);
    bool identical = same.triangles == plain.triangles && same.vertices.size() == plain.vertices.size();
    for (std::size_t v = 0; identical && v < plain.vertices.size(); ++v)
      identical = same_bits(same.vertices[v], plain.vertices[v]);
    CHECK(identical, "(w1) a clean mesh is returned as it is");
  }

  // ── (w4) a sliver on one line ──────────────────────────────────────────────
  {
    // A unit cube whose front face has a corner m in the middle of its bottom edge pq,
    // the bottom face still on pq, and the triangle (p, q, m) closing the gap: manifold
    // in its own indices, three DISTINCT floats, but on one line. A reader drops it as
    // zero-area and its three edges open (the Keep clear cut on his ad68d4c0, dda471a2
    // and efe18e33: 6 to 17 of them, along voxel lines; core's import refused the file).
    TriangleMesh m;
    m.vertices = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1},
                  {1, 0, 1}, {1, 1, 1}, {0, 1, 1}, {0.5, 0, 0}};
    const int p = 0, q = 1, M = 8;
    m.triangles = {{0, 3, 2}, {0, 2, 1},                // bottom (q -> p on the second)
                   {p, M, 4}, {M, q, 5}, {M, 5, 4},     // front, through m
                   {p, q, M},                           // the sliver
                   {4, 5, 6}, {4, 6, 7}, {3, 7, 6}, {3, 6, 2},
                   {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
    const WatertightReport own = check_watertight(m);
    const WrittenAudit as_is = audit_as_written(m);
    const TriangleMesh w = weld_as_written(m);
    const WrittenAudit after = audit_as_written(w);
    const std::string path = std::string(TMP_DIR) + "/finish_w4.stl";
    write_stl_file(path, w);
    const PartInspection read = inspect_part_file(path);
    std::printf("[finish] (w4) sliver on a line: own indices watertight %d; as read %d zero-area, "
                "%d open; flipped %d zero-area, %d open, %d shell(s); imported %s (%d dropped)\n",
                own.watertight ? 1 : 0, as_is.zero_area_triangles, as_is.boundary_edges,
                after.zero_area_triangles, after.boundary_edges, after.shells,
                read.acceptable ? "yes" : "no", read.degenerate_triangles);
    CHECK(own.watertight && as_is.zero_area_triangles == 1 && as_is.boundary_edges == 3,
          "(w4) the defect: manifold in its indices, three open edges as read");
    CHECK(after.zero_area_triangles == 0 && after.non_manifold_edges == 0 &&
              after.boundary_edges == 0 && after.shells == 1 && after.bodies == 1 &&
              w.triangles.size() == m.triangles.size() && w.vertices.size() == m.vertices.size(),
          "(w4) the sliver's long edge flipped away: the cube, clean, every corner kept");
    CHECK(std::fabs(signed_volume(w) - 1.0) < 1e-12, "(w4) the flip moves nothing");
    CHECK(read.acceptable && read.degenerate_triangles == 0, "(w4) core's import takes the file");
  }

  // ── (w5) a sliver in a flap ────────────────────────────────────────────────
  {
    // The cube's bottom triangle (R, B, M) handed back as three: (R, B, A), the sliver
    // (A, B, M) on one line and (R, A, M) folded back over the first, A past M on B's
    // line. Manifold in its own indices, the same solid; a zero-area flap sticking out
    // past the face (the Keep clear cut on his dda471a2, one per version). Flipping the
    // sliver's long edge puts (A, R, M) on (R, A, M): the two go as a fin, and so does A.
    TriangleMesh m;
    m.vertices = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1},
                  {1, 0, 1}, {1, 1, 1}, {0, 1, 1}, {1, -0.5, 0}};
    const int R = 0, B = 2, M = 1, A = 8;
    m.triangles = {{0, 3, 2}, {R, B, A}, {A, B, M}, {R, A, M},  // bottom, through the flap
                   {0, 1, 5}, {0, 5, 4}, {4, 5, 6}, {4, 6, 7}, {3, 7, 6}, {3, 6, 2},
                   {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
    const WatertightReport own = check_watertight(m);
    const WrittenAudit as_is = audit_as_written(m);
    const TriangleMesh w = weld_as_written(m);
    const WrittenAudit after = audit_as_written(w);
    const std::string path = std::string(TMP_DIR) + "/finish_w5.stl";
    write_stl_file(path, w);
    const PartInspection read = inspect_part_file(path);
    std::printf("[finish] (w5) sliver in a flap: own indices watertight %d; as read %d zero-area, "
                "%d open; flipped %d zero-area, %d open, %d on >2, %d shell(s), %zu triangles, "
                "%zu vertices; imported %s\n",
                own.watertight ? 1 : 0, as_is.zero_area_triangles, as_is.boundary_edges,
                after.zero_area_triangles, after.boundary_edges, after.non_manifold_edges,
                after.shells, w.triangles.size(), w.vertices.size(), read.acceptable ? "yes" : "no");
    CHECK(own.watertight && as_is.zero_area_triangles == 1 && as_is.boundary_edges == 3,
          "(w5) the defect: manifold in its indices, three open edges as read");
    CHECK(after.zero_area_triangles == 0 && after.non_manifold_edges == 0 &&
              after.boundary_edges == 0 && after.non_manifold_vertices == 0 && after.shells == 1 &&
              after.bodies == 1 && w.triangles.size() == 12 && w.vertices.size() == 8,
          "(w5) the flap goes: the cube, clean");
    CHECK(std::fabs(signed_volume(w) - 1.0) < 1e-12, "(w5) the flap held no volume");
    CHECK(read.acceptable && read.degenerate_triangles == 0, "(w5) core's import takes the file");
  }

  // ── (w6) a fragment on the part's edge ─────────────────────────────────────
  {
    // The cube and, outside its front face, a sliver tetrahedron closed on its OWN four
    // vertices, two of them on the face's diagonal (the Keep clear cut on his efe18e33
    // 1.25: a 1e-8 mm3 one on an edge of the part, all three tries). Manifold in its
    // indices; welded as the file reads, the diagonal carries four triangles and the
    // sliver is no longer a shell of its own to drop.
    TriangleMesh m;
    m.vertices = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1},
                  {0, 1, 1}, {0, 0, 0}, {1, 0, 1}, {0.5, -0.01, 0.4}, {0.5, -0.01, 0.6}};
    const int a = 8, b = 9, c = 11, d = 10;  // positively oriented: b - a, c - a, d - a
    m.triangles = {{0, 2, 1}, {0, 3, 2}, {0, 1, 5}, {0, 5, 4}, {4, 5, 6}, {4, 6, 7},
                   {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5},
                   {a, c, b}, {a, b, d}, {a, d, c}, {b, c, d}};
    const WatertightReport own = check_watertight(m);
    const WrittenAudit old_way =
        audit_as_written(drop_fragment_shells(weld_as_written(m), 0.87, 1, nullptr));
    int dropped = 0;
    const TriangleMesh w = clean_cut_as_written(m, 0.87, 1, &dropped);
    const WrittenAudit after = audit_as_written(w);
    std::printf("[finish] (w6) fragment on an edge: own indices watertight %d, volume %.6g; "
                "welded then dropped %d on >2, %d point(s); cleaned %d on >2, %d point(s), %d "
                "open, %d shell(s), %d dropped, volume %.6g\n",
                own.watertight ? 1 : 0, signed_volume(m), old_way.non_manifold_edges,
                old_way.non_manifold_vertices, after.non_manifold_edges,
                after.non_manifold_vertices, after.boundary_edges, after.shells, dropped,
                signed_volume(w));
    CHECK(own.watertight && signed_volume(m) > 1.0 && old_way.non_manifold_edges == 1,
          "(w6) the defect: manifold in its indices, the diagonal on four triangles welded");
    CHECK(after.non_manifold_edges == 0 && after.non_manifold_vertices == 0 &&
              after.boundary_edges == 0 && after.shells == 1 && after.bodies == 1 &&
              dropped == 1 && w.triangles.size() == 12,
          "(w6) the fragment goes in its own indices first: the cube, clean");
    CHECK(std::fabs(signed_volume(w) - 1.0) < 1e-12, "(w6) the cube is untouched");
  }

  // ── (w2) fragment shells; (w3) a point contact ─────────────────────────────
  {
    using manifold::Manifold;
    const TriangleMesh big = from_manifold(Manifold::Cube({10.0, 10.0, 10.0}));
    const TriangleMesh chip = from_manifold(
        Manifold::Cube({0.5, 0.5, 0.5}).Translate({12.0, 0.0, 0.0}));  // 0.125 mm^3
    const TriangleMesh hole = from_manifold(
        Manifold::Cube({2.0, 2.0, 2.0}).Translate({4.0, 4.0, 4.0}));  // a sealed void, 8 mm^3
    TriangleMesh m = big;
    auto append = [&](const TriangleMesh& a, bool flip) {
      const int base = static_cast<int>(m.vertices.size());
      m.vertices.insert(m.vertices.end(), a.vertices.begin(), a.vertices.end());
      for (const auto& t : a.triangles)
        m.triangles.push_back(flip ? std::array<int, 3>{base + t[0], base + t[2], base + t[1]}
                                   : std::array<int, 3>{base + t[0], base + t[1], base + t[2]});
    };
    append(chip, false);
    append(hole, true);
    int dropped = -1;
    const TriangleMesh kept = drop_fragment_shells(m, 1.0, 1, &dropped);
    const WrittenAudit a = audit_as_written(kept);
    int dropped2 = -1;
    const TriangleMesh kept2 = drop_fragment_shells(m, 1.0, 2, &dropped2);
    std::printf("[finish] (w2) fragments: %d dropped -> %d shell(s), %d body(ies); keeping the "
                "2 largest bodies: %d dropped\n", dropped, a.shells, a.bodies, dropped2);
    CHECK(dropped == 1 && a.shells == 2 && a.bodies == 1,
          "(w2) the 0.125 mm^3 chip goes; the body and its sealed void stay");
    CHECK(dropped2 == 0 && kept2.triangles.size() == m.triangles.size(),
          "(w2) one of the export's own bodies never goes, whatever its size");
    // A loose plate 0.4 mm thin (6.4 mm^3, over the volume line): a printer makes no
    // piece under the printable minimum, so with that line given it goes too; the
    // sealed void (2 mm across) stays.
    TriangleMesh thin = m;
    {
      const TriangleMesh plate = from_manifold(
          Manifold::Cube({4.0, 4.0, 0.4}).Translate({12.0, 2.0, 0.0}));
      const int b0 = static_cast<int>(thin.vertices.size());
      thin.vertices.insert(thin.vertices.end(), plate.vertices.begin(), plate.vertices.end());
      for (const auto& t : plate.triangles) thin.triangles.push_back({b0 + t[0], b0 + t[1], b0 + t[2]});
    }
    int dropped3 = -1, dropped4 = -1;
    const WrittenAudit a3 = audit_as_written(drop_fragment_shells(thin, 1.0, 1, &dropped3));
    const WrittenAudit a4 = audit_as_written(drop_fragment_shells(thin, 1.0, 1, &dropped4, 0.84));
    std::printf("[finish] (w2) a loose 0.4 mm plate: no line %d dropped (%d bodies); line 0.84 mm "
                "%d dropped (%d bodies, %d shells)\n", dropped3, a3.bodies, dropped4, a4.bodies,
                a4.shells);
    CHECK(dropped3 == 1 && a3.bodies == 2, "(w2) without a printable line the plate stays");
    CHECK(dropped4 == 2 && a4.bodies == 1 && a4.shells == 2,
          "(w2) a loose piece under the printable minimum goes; the sealed void stays");
    TriangleMesh touch = big;  // a second cube sharing one corner point with the first
    const TriangleMesh other = from_manifold(Manifold::Cube({10.0, 10.0, 10.0}).Translate({10.0, 10.0, 10.0}));
    const int base = static_cast<int>(touch.vertices.size());
    touch.vertices.insert(touch.vertices.end(), other.vertices.begin(), other.vertices.end());
    for (const auto& t : other.triangles) touch.triangles.push_back({base + t[0], base + t[1], base + t[2]});
    const WrittenAudit c = audit_as_written(touch);
    std::printf("[finish] (w3) corner contact: %d point contact(s), %d shells, %d edges on more "
                "than two triangles\n", c.non_manifold_vertices, c.shells, c.non_manifold_edges);
    CHECK(c.non_manifold_vertices == 1 && c.shells == 2 && c.non_manifold_edges == 0,
          "(w3) two shells touching at a point are seen");
  }

  // ── (j) file thin joints ───────────────────────────────────────────────────
  {
    VoxelGrid g;
    g.nx = g.ny = g.nz = 6;
    g.spacing = 1.0;
    std::vector<char> occ(216, 0);
    auto at = [](int i, int j, int k) { return static_cast<std::size_t>((k * 6 + j) * 6 + i); };
    for (int k = 0; k < 6; ++k) {
      occ[at(1, 1, k)] = 1;  // two columns that meet along an edge only
      occ[at(2, 2, k)] = 1;
    }
    const int edge_only = file_thin_joints(g, occ);
    for (int k = 0; k < 6; ++k) occ[at(2, 1, k)] = 1;  // now joined through a face
    const int joined = file_thin_joints(g, occ);
    std::printf("[finish] (j) thin joints: edge-only %d, face-joined %d\n", edge_only, joined);
    CHECK(edge_only == 1 && joined == 0, "(j) an edge-only joint is counted once, a face joint not");
    FinishRecheck r;
    r.ran = true;
    r.margin = r.margin_required = 1.5;
    r.thin_joints = 1;
    CHECK(finish_verdict_reason(r) == "After finishing, a joint holds only along an edge or at a corner",
          "(j) a joint the finishing thinned refuses with its line");
    r.thin_joints_before = 1;
    CHECK(finish_verdict_reason(r).empty(), "(j) a joint the part already had is not the finish's");
  }

  // ── (l) loose pieces; the file's own gate ──────────────────────────────────
  {
    VoxelGrid g;
    g.nx = g.ny = g.nz = 8;
    g.spacing = 1.0;
    g.tags.assign(512, VoxelTag::Interior);
    std::vector<char> occ(512, 0);
    auto at = [](int i, int j, int k) { return static_cast<std::size_t>((k * 8 + j) * 8 + i); };
    for (int i = 0; i < 4; ++i) occ[at(i, 1, 1)] = 1;  // a rod holding an anchor
    g.tags[at(0, 1, 1)] = VoxelTag::Fixture;
    occ[at(6, 6, 6)] = 1;  // a speck far away
    const int with_speck = file_loose_pieces(g, occ);
    occ[at(6, 6, 6)] = 0;
    occ[at(4, 2, 2)] = 1;  // touching the rod at a corner: one 26-connected piece
    const int corner = file_loose_pieces(g, occ);
    std::printf("[finish] (l) loose pieces: a speck %d, a corner-joined voxel %d\n", with_speck, corner);
    CHECK(with_speck == 1 && corner == 0, "(l) a piece holding no load or anchor is loose");
    FinishRecheck r;
    r.ran = true;
    r.margin = r.margin_required = 1.5;
    r.loose_pieces = r.loose_pieces_before = 2;
    CHECK(finish_verdict_reason(r).empty(), "(l) loose pieces the part already had are not the finish's");
    r.loose_pieces = 3;
    CHECK(finish_verdict_reason(r) == "After finishing, a piece is loose", "(l) one the finish made is");
    r.loose_pieces = 2;
    r.load_path_ok = false;
    CHECK(finish_verdict_reason(r) == "After finishing, the load no longer reaches an anchor",
          "(l) the file's load path");
    r.load_path_ok = true;
    r.non_convergent = true;
    r.margin = 0.0;
    CHECK(finish_verdict_reason(r) == "After finishing, the strength check on the file did not converge",
          "(l) a solve that did not converge is said as such, not as a 0x margin");
  }

  // ── (s1) the fallback decision ─────────────────────────────────────────────
  {
    std::vector<int> calls;
    auto run = [&](const std::string& slim_says, const std::string& safe_says) {
      calls.clear();
      return finish_with_fallback(
          [&](bool slim) { calls.push_back(slim ? 1 : 0); return slim; },
          [&](bool slim) { return slim ? slim_says : safe_says; });
    };
    const FallbackOutcome ok = run("", "never asked");
    CHECK(ok.slim_used && !ok.fallback && ok.refusal.empty() && calls == std::vector<int>{1},
          "(s1) a slim shape that passes ships slim, the safe one never made");
    const FallbackOutcome fb = run("After finishing, the margin is 1.42\xC3\x97 (needs 1.5\xC3\x97)", "");
    CHECK(!fb.slim_used && fb.fallback && fb.refusal.empty() && calls == std::vector<int>({1, 0}) &&
              fb.fallback_reason.find("1.42") != std::string::npos,
          "(s1) a slim shape that fails falls back to the safe one, with the reason");
    const FallbackOutcome no = run("After finishing, a piece is loose", "After finishing, it prints in 2 pieces");
    CHECK(!no.fallback && no.refusal == "After finishing, it prints in 2 pieces",
          "(s1) a version the safe finish also fails is refused on its own merits");
  }

  // ── (s2) slim on a member between the lines ────────────────────────────────
  {
    // A spherical shell 3.6 mm thick (outer radius 20 mm) on a 1.9 mm grid (his
    // resolution-64 spacing), export factor 2: the shell reads under C2's safe line
    // (2 x spacing, 3.8 mm) and is over the slim line (1.8 mm). Stair-step measured
    // against the two analytic spheres, as (d1) does.
    const double sp = 1.9, Ro = 20.0, th = 3.6, Ri = Ro - th;
    const int n = static_cast<int>(std::ceil(2.4 * Ro / sp));
    VoxelGrid g;
    g.nx = g.ny = g.nz = n;
    g.spacing = sp;
    g.origin = Vec3{0.0, 0.0, 0.0};
    g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Empty);
    const double c0 = 0.5 * n * sp;
    auto radius = [&](const Vec3& p) {
      return std::sqrt((p.x - c0) * (p.x - c0) + (p.y - c0) * (p.y - c0) + (p.z - c0) * (p.z - c0));
    };
    for (int k = 0; k < n; ++k)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
          const double r = radius(g.voxel_center(i, j, k));
          if (r <= Ro && r >= Ri) g.tags[g.index(i, j, k)] = VoxelTag::Interior;
        }
    const std::vector<double> occ = occupancy(g);
    const TriangleMesh m0 = round_trip(
        marching_cubes_resampled(g.nx, g.ny, g.nz, g.spacing, g.origin, occ, 0.5, 2,
                                 ResampleInterp::Tricubic),
        "finish_shell.stl");
    auto rms_dev = [&](const TriangleMesh& m) {
      double s2 = 0.0;
      for (const Vec3& v : m.vertices) {
        const double r = radius(v);
        const double e = r > 0.5 * (Ro + Ri) ? r - Ro : r - Ri;
        s2 += e * e;
      }
      return std::sqrt(s2 / static_cast<double>(m.vertices.size()));
    };
    FinishContext ctx;
    ctx.cell_mm = sp / 2.0;
    ctx.grid = &g;
    ctx.density = &occ;
    FinishReport safe_rep, slim_rep;
    const TriangleMesh safe = surface_finish(m0, ctx, {}, {}, &safe_rep);
    ctx.slim_line_mm = 1.8;
    const TriangleMesh slim = surface_finish(m0, ctx, {}, {}, &slim_rep);
    const double d0 = rms_dev(m0), ds = rms_dev(safe), dl = rms_dev(slim);
    const double safe_pct = 100.0 * (1.0 - ds / d0), slim_pct = 100.0 * (1.0 - dl / d0);
    const ThinnedCount tc = count_thinned(m0, slim, 1.8);
    const int new_under = tc.by_inward;
    std::printf("[finish] (s2) shell 3.6 mm on a 1.9 mm grid, %zu vertices: outward-only safe %zu, "
                "slim %zu; stair-step removed safe %.1f %% (report %.1f %%), slim %.1f %% (report "
                "%.1f %%; %d guard round(s), %zu held); folds walked back %zu / %zu; %d newly under "
                "1.8 mm; max move %.4f mm (cell %.3f)\n",
                m0.vertices.size(), safe_rep.outward_only_vertices, slim_rep.outward_only_vertices,
                safe_pct, safe_rep.stair_step_removed_pct, slim_pct, slim_rep.stair_step_removed_pct,
                slim_rep.slim_rounds, slim_rep.slim_guarded_vertices, safe_rep.fold_held_vertices,
                slim_rep.fold_held_vertices, new_under, max_axis_move(m0, slim), ctx.cell_mm);
    CHECK(slim_rep.slim && !slim_rep.fallback, "(s2) the slim finish is the one applied");
    CHECK(slim_rep.outward_only_vertices * 2 < safe_rep.outward_only_vertices,
          "(s2) slim frees the member the safe line held outward-only");
    CHECK(slim_pct > safe_pct + 5.0, "(s2) and finishes it");
    CHECK(new_under == 0, "(s2) nothing goes under 1.8 mm that was not");
    CHECK(max_axis_move(m0, slim) <= 0.5 * ctx.cell_mm + 1e-9, "(s2) no vertex leaves its cell");
  }

  // ── (s3) what counts as thinning ───────────────────────────────────────────
  {
    // A 2.0 mm plate between two blocks, the line 1.8 mm. Its top moved IN 0.3 mm is a
    // member taken under the line; its bottom moved OUT 0.3 mm only adds material.
    const TriangleMesh m0 = plate_part(2.0);
    TriangleMesh in = m0, out = m0;
    int top = 0;
    for (std::size_t v = 0; v < m0.vertices.size(); ++v) {
      const Vec3& p = m0.vertices[v];
      if (p.x > 11.0 && p.x < 19.0 && p.y > 1.0 && p.y < 9.0) {
        if (std::fabs(p.z - 6.0) < 1e-9) { in.vertices[v].z -= 0.3; ++top; }
        if (std::fabs(p.z - 4.0) < 1e-9) out.vertices[v].z -= 0.3;
      }
    }
    const ThinnedCount a = count_thinned(m0, in, 1.8), b = count_thinned(m0, out, 1.8);
    std::printf("[finish] (s3) plate 2.0 mm, line 1.8: top in 0.3 mm -> %d newly under by moving in "
                "(%d by the measure), thinnest %.3f mm; bottom out 0.3 mm -> %d (%d)\n",
                a.by_inward, a.measured, a.thinnest_mm, b.by_inward, b.measured);
    CHECK(top > 0 && a.by_inward > 0 && std::fabs(a.thinnest_mm - 1.7) < 0.02,
          "(s3) a member moved in under the line is counted, at its thickness");
    CHECK(b.by_inward == 0, "(s3) material added never counts as thinning");
  }

  if (g_failures == 0) {
    std::printf("finish (E1): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "finish (E1): %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
