// KEEP CLEAR, EXACTLY (reviewer's ruling 2026-11-03 19:55, FINDING 1): a file prints
// nothing inside a Keep clear. The exports put material there on 7 of his jobs (up to
// 14,988 voxels on efe18e33 by the voxel test, against 0 in the designs), so every file
// is cut out of its Keep clears by Manifold: file - (Keep clears - part).
//
// On a block (40 x 20 x 10 mm, built here with Manifold) with a vertical bore r 3, and a
// "file" that is the block plus material in the air where a voxel export puts it:
//   a plug inside the bore, a pad r 6 on the top face around the bore (over the bore's
//   mouth too), a bump under a TILTED face slab, and a bump far from every Keep clear.
// Keep clears (manual primitives, the app's form): a bolt on the bore (keep-out r 5,
// 2 mm past each end) and a face slab whose normal leans 30 degrees from Z.
//   (a) no point inside a Keep clear and outside the part is in the cut file;
//   (b) the part's own material inside a Keep clear stays (part wins);
//   (c) the round side is CIRCUMSCRIBED: no point at r 4.999 (inside the true keep-out,
//       outside an inscribed 128-gon) at any angle stays; the pad past r 5 stays;
//   (d) the far bump stays, its vertices bit-identical;
//   (e) one closed shell (no edge on more than two triangles, no open edge, no point
//       contact);
//   (f) a file that reaches into no Keep clear (its bore wall within 2 um of the part's)
//       comes back unchanged; the volume cut is reported (> 0 here, 0 there).
//   (g) the part's own surface inside a Keep clear is not re-cut: the bore's bottom rim
//       (in the bolt's Keep clear, on the file's surface) is in the cut file bit for bit
//       (cut against the part itself, his efe18e33 lost 13,151 such vertices).

#include "topopt/finish.hpp"
#include "topopt/job.hpp"
#include "topopt/mesh.hpp"
#include "topopt/step.hpp"

#include <manifold/manifold.h>

#include <cmath>
#include <cstdio>
#include <set>
#include <array>
#include <vector>

using namespace topopt;

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

constexpr double kPi = 3.14159265358979323846;
const Vec3 kBore{-10.0, 0.0, 0.0};
constexpr double kBoreR = 3.0, kKeepR = 5.0;  // keep-out = bore + 2 mm margin
const double kS30 = 0.5, kC30 = std::sqrt(3.0) / 2.0;
const Vec3 kSlabAt{10.0, 0.0, 10.0};
const Vec3 kSlabN{kS30, 0.0, kC30};

TriangleMesh to_mesh(const manifold::Manifold& m) {
  const manifold::MeshGL g = m.GetMeshGL();
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

manifold::Manifold box(double x0, double y0, double z0, double x1, double y1, double z1) {
  return manifold::Manifold::Cube({x1 - x0, y1 - y0, z1 - z0}).Translate({x0, y0, z0});
}

manifold::Manifold column(double r, double z0, double z1, int segments = 96) {
  return manifold::Manifold::Cylinder(z1 - z0, r, r, segments).Translate({kBore.x, kBore.y, z0});
}

std::set<std::array<float, 3>> vertex_set(const TriangleMesh& m) {
  std::set<std::array<float, 3>> s;
  for (const Vec3& v : m.vertices)
    s.insert({static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)});
  return s;
}

}  // namespace

int main() {
  // The part's bore in 96 facets; the file's in 200, as the CAD projection puts the file's
  // vertices ON the cylinder between the part's own: the two walls are within 2 um of
  // each other and cross along the part's edges, never one surface.
  const manifold::Manifold part_m =
      box(-20.0, -10.0, 0.0, 20.0, 10.0, 10.0) - column(kBoreR, -1.0, 11.0);
  const manifold::Manifold file_part_m =
      box(-20.0, -10.0, 0.0, 20.0, 10.0, 10.0) - column(kBoreR, -1.0, 11.0, 200);
  const manifold::Manifold far_m = box(14.0, 6.0, 10.0, 18.0, 9.0, 11.0);
  const manifold::Manifold file_m = file_part_m + column(2.0, 3.0, 7.0) +   // a plug in the bore
                                    column(6.0, 10.0, 11.0) +           // a pad on the top
                                    box(8.0, -2.0, 10.0, 12.0, 2.0, 11.5) +  // under the slab
                                    far_m;
  StepModel model;
  model.mesh = to_mesh(part_m);
  const TriangleMesh file = to_mesh(file_m);

  JobDescription job;
  job.loads.present = true;
  JobClearance bolt;
  bolt.kind = "bolt";
  bolt.manual = true;
  bolt.axis_point = Vec3{kBore.x, kBore.y, 5.0};
  bolt.axis_dir = Vec3{0.0, 0.0, 1.0};
  bolt.radius_mm = kBoreR;
  bolt.half_length_mm = 5.0;
  bolt.concentric_margin_mm = kKeepR - kBoreR;
  bolt.axial_clearance_mm = 2.0;
  job.loads.clearances.push_back(bolt);
  JobClearance slab;
  slab.kind = "face";
  slab.manual = true;
  slab.origin = kSlabAt;
  slab.normal = kSlabN;
  slab.half_u_mm = 4.0;
  slab.half_w_mm = 4.0;
  slab.slab_depth_mm = 3.0;
  job.loads.clearances.push_back(slab);

  double cut = 0.0;
  const TriangleMesh out = cut_keep_clears(file, job, model, 0.01, &cut);
  std::printf("[kc] file %zu triangles -> %zu; cut %.4f mm3\n", file.triangles.size(),
              out.triangles.size(), cut);

  // (a) inside a Keep clear, outside the part: gone.
  const Vec3 plug{kBore.x, kBore.y, 5.0};
  const Vec3 mouth{kBore.x + 1.0, kBore.y, 10.5};   // over the bore's mouth
  const Vec3 pad_in{kBore.x + 4.0, kBore.y, 10.5};  // on the top, inside r 5
  const Vec3 under_slab{10.0, 0.0, 11.2};           // 1.2 mm above the face, in the slab
  CHECK(mesh_encloses(file, plug) && mesh_encloses(file, mouth) && mesh_encloses(file, pad_in) &&
            mesh_encloses(file, under_slab),
        "precondition: the file prints into both Keep clears");
  CHECK(!mesh_encloses(out, plug), "(a) the plug in the bore is cut");
  CHECK(!mesh_encloses(out, mouth), "(a) the pad over the bore's mouth is cut");
  CHECK(!mesh_encloses(out, pad_in), "(a) the pad inside the keep-out on the top is cut");
  CHECK(!mesh_encloses(out, under_slab), "(a) the bump inside the tilted slab is cut");

  // (b) the part's own material inside a Keep clear stays.
  CHECK(mesh_encloses(out, Vec3{kBore.x + 4.0, kBore.y, 5.0}),
        "(b) the part around the bore, inside the keep-out, stays");
  CHECK(mesh_encloses(out, Vec3{10.0, 0.0, 9.5}), "(b) the part under the tilted slab stays");

  // (c) circumscribed: nothing at r 4.999 at any angle; the pad past r 5 stays.
  int left = 0;
  for (int a = 0; a < 1440; ++a) {
    const double t = 2.0 * kPi * a / 1440.0;
    left += mesh_encloses(out, Vec3{kBore.x + 4.999 * std::cos(t), kBore.y + 4.999 * std::sin(t), 10.5});
  }
  std::printf("[kc] points at r 4.999 still printed: %d of 1440\n", left);
  CHECK(left == 0, "(c) no point inside the true keep-out stays (the cutter is circumscribed)");
  CHECK(mesh_encloses(out, Vec3{kBore.x + 5.3, kBore.y, 10.5}), "(c) the pad past the keep-out stays");

  // (d) the far bump stays, its corners bit-identical.
  CHECK(mesh_encloses(out, Vec3{16.0, 7.5, 10.5}), "(d) the far bump stays");
  const std::set<std::array<float, 3>> have = vertex_set(out);
  int far_kept = 0, far_all = 0;
  for (const Vec3& v : to_mesh(far_m).vertices) {
    ++far_all;
    far_kept += have.count({static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)}) > 0;
  }
  CHECK(far_kept == far_all, "(d) the far bump's corners are in the cut file, bit for bit");

  // (e) one closed shell.
  const WrittenAudit w = audit_as_written(out);
  std::printf("[kc] cut file: %d edge(s) on >2 triangles, %d open, %d point contact(s), %d shell(s)\n",
              w.non_manifold_edges, w.boundary_edges, w.non_manifold_vertices, w.shells);
  CHECK(w.non_manifold_edges == 0 && w.boundary_edges == 0 && w.non_manifold_vertices == 0,
        "(e) the cut file is clean as written");
  CHECK(w.shells == 1 && w.bodies == 1, "(e) one closed shell");

  // (g) the bore's bottom rim stays, bit for bit.
  int rim = 0, rim_kept = 0;
  for (const Vec3& v : file.vertices) {
    const double r = std::hypot(v.x - kBore.x, v.y - kBore.y);
    if (std::fabs(v.z) > 1e-9 || std::fabs(r - kBoreR) > 1e-3) continue;
    ++rim;
    rim_kept += have.count({static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)}) > 0;
  }
  std::printf("[kc] the bore's bottom rim: %d of %d vertices kept\n", rim_kept, rim);
  CHECK(rim > 0 && rim_kept == rim, "(g) the part's own surface inside a Keep clear is not re-cut");

  // (f) the volume cut is reported; a file reaching into no Keep clear is unchanged.
  CHECK(cut > 1.0, "(f) the volume cut is reported");
  const TriangleMesh far_only = to_mesh(file_part_m + far_m);
  double cut2 = -1.0;
  const TriangleMesh same = cut_keep_clears(far_only, job, model, 0.01, &cut2);
  bool identical = same.triangles == far_only.triangles &&
                   same.vertices.size() == far_only.vertices.size();
  for (std::size_t i = 0; identical && i < same.vertices.size(); ++i)
    identical = same.vertices[i].x == far_only.vertices[i].x &&
                same.vertices[i].y == far_only.vertices[i].y &&
                same.vertices[i].z == far_only.vertices[i].z;
  CHECK(identical && cut2 == 0.0, "(f) a file reaching into no Keep clear comes back unchanged");

  if (g_failures == 0) {
    std::printf("keep clear exact: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "keep clear exact: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
