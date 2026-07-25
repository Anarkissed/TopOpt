// repair_evidence.cpp — Phase 2 mesh-repair evidence generator.
//
// Builds REAL parts (a plate-with-bore bracket, exactly the geometry class the
// failing bracket screenshot came from), injects the three defect classes the
// task names, writes each broken mesh to disk, and prints a BEFORE/AFTER report
// straight off the shipping `inspect_part_file` — the same verdict the app and
// the CLI see. Nothing here is a mock: the meshes are written as binary STL and
// re-read through the production importer.
//
//   1. non-manifold edges from stacked duplicate facets  -> REPAIRED
//   2. a small hole (dropped facets)                     -> REPAIRED
//   3. a wall-sized hole / an ambiguous junction         -> REFUSED (cleanly)
//
// Output: STL files + a text report on stdout. Driver:
//   cmake --build core/build --target repair_evidence
//   core/build/repair_evidence <out_dir>

#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/stl.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;
static const double kPi = 3.14159265358979323846;

static void add_quad(TriangleMesh& m, int a, int b, int c, int d) {
  m.triangles.push_back({a, b, c});
  m.triangles.push_back({a, c, d});
}

// A rectangular plate [-hx,hx] x [-hy,hy] x [z0,z1] with one central through
// bore of radius r — a real bracket (flat flanges, sharp outline, a bolt bore).
// (Same construction as the handoff-134 segment evidence bracket.)
static TriangleMesh make_plate_with_bore(double hx, double hy, double z0,
                                         double z1, double r, int nseg) {
  TriangleMesh m;
  struct P { double a, x, y; };
  std::vector<P> outline;
  for (int i = 0; i < nseg; ++i) {
    const double a = 2.0 * kPi * i / nseg;
    const double ca = std::cos(a), sa = std::sin(a);
    double R = 1e30;
    if (std::fabs(ca) > 1e-12) R = std::min(R, hx / std::fabs(ca));
    if (std::fabs(sa) > 1e-12) R = std::min(R, hy / std::fabs(sa));
    outline.push_back({a, R * ca, R * sa});
  }
  const double corner_a[4] = {std::atan2(hy, hx), std::atan2(hy, -hx),
                              std::atan2(-hy, -hx) + 2 * kPi,
                              std::atan2(-hy, hx) + 2 * kPi};
  const double corner_x[4] = {hx, -hx, -hx, hx};
  const double corner_y[4] = {hy, hy, -hy, -hy};
  for (int k = 0; k < 4; ++k)
    outline.push_back({corner_a[k], corner_x[k], corner_y[k]});
  std::sort(outline.begin(), outline.end(),
            [](const P& a, const P& b) { return a.a < b.a; });
  const int n = static_cast<int>(outline.size());

  const int rim_lo = 0;
  for (const P& p : outline)
    m.vertices.push_back(Vec3{r * std::cos(p.a), r * std::sin(p.a), z0});
  const int rim_hi = static_cast<int>(m.vertices.size());
  for (const P& p : outline)
    m.vertices.push_back(Vec3{r * std::cos(p.a), r * std::sin(p.a), z1});
  const int out_lo = static_cast<int>(m.vertices.size());
  for (const P& p : outline) m.vertices.push_back(Vec3{p.x, p.y, z0});
  const int out_hi = static_cast<int>(m.vertices.size());
  for (const P& p : outline) m.vertices.push_back(Vec3{p.x, p.y, z1});

  auto RL = [&](int i) { return rim_lo + (i % n); };
  auto RH = [&](int i) { return rim_hi + (i % n); };
  auto OL = [&](int i) { return out_lo + (i % n); };
  auto OH = [&](int i) { return out_hi + (i % n); };
  for (int i = 0; i < n; ++i) {
    add_quad(m, RL(i), RL(i + 1), OL(i + 1), OL(i));
    add_quad(m, RH(i), OH(i), OH(i + 1), RH(i + 1));
    add_quad(m, RL(i), RH(i), RH(i + 1), RL(i + 1));
    add_quad(m, OL(i), OL(i + 1), OH(i + 1), OH(i));
  }
  return m;
}

static void report(const char* title, const std::string& path) {
  std::printf("\n%s\n  file: %s\n", title, path.c_str());
  const WatertightReport wt = check_watertight(read_stl_file(path).mesh);
  std::printf("  BEFORE (raw file): triangles=%zu  boundary_edges=%d  "
              "non_manifold_edges=%d  watertight=%s\n",
              read_stl_file(path).mesh.triangles.size(), wt.boundary_edges,
              wt.non_manifold_edges, wt.watertight ? "yes" : "no");
  const PartInspection insp = inspect_part_file(path);
  std::printf("  AFTER  (repair+inspect): acceptable=%s\n",
              insp.acceptable ? "YES" : "no");
  std::printf("    repaired: welded=%d degenerate=%d duplicates_removed=%d "
              "holes_filled=%d (+%d tris) flipped=%d\n",
              insp.welded_vertices, insp.degenerate_triangles,
              insp.removed_duplicate_triangles, insp.filled_holes,
              insp.filled_hole_triangles, insp.flipped_triangles);
  std::printf("    residual: boundary_edges=%d non_manifold_edges=%d\n",
              insp.boundary_edges, insp.non_manifold_edges);
  if (!insp.acceptable) {
    std::printf("    REFUSED:\n");
    for (const auto d : insp.defects)
      std::printf("      - %s\n", describe_defect(d).c_str());
  } else {
    std::printf("    volume=%.3f mm^3  bbox=[%.1f %.1f %.1f]\n", insp.volume,
                insp.bbox_max.x - insp.bbox_min.x,
                insp.bbox_max.y - insp.bbox_min.y,
                insp.bbox_max.z - insp.bbox_min.z);
  }
}

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : ".";

  // Base part: a 60 x 40 x 6 mm plate with a 5 mm bore, 48 outline segments.
  const TriangleMesh base = make_plate_with_bore(30, 20, 0, 6, 5, 48);
  {
    const std::string p = dir + "/bracket_clean.stl";
    write_stl_file(p, base, StlFormat::Binary);
    report("[0] CONTROL: the clean bracket (repair is a no-op)", p);
  }

  // 1. Non-manifold from stacked duplicate facets — the bracket screenshot's
  //    "N edges shared by three or more triangles". Duplicate 6 facets.
  {
    TriangleMesh m = base;
    for (int k : {0, 5, 17, 40, 88, 130})
      m.triangles.push_back(m.triangles[static_cast<std::size_t>(k) %
                                        m.triangles.size()]);
    const std::string p = dir + "/bracket_duplicate_facets.stl";
    write_stl_file(p, m, StlFormat::Binary);
    report("[1] DEFECT: non-manifold edges from stacked duplicate facets", p);
  }

  // 2. Small hole: drop two adjacent facets from the (large) bottom face, well
  //    within the conservative bound.
  {
    TriangleMesh m = base;
    // The first two triangles are a bottom-face quad near the bore; dropping
    // them opens a small quad hole in the flange.
    m.triangles.erase(m.triangles.begin(), m.triangles.begin() + 2);
    const std::string p = dir + "/bracket_small_hole.stl";
    write_stl_file(p, m, StlFormat::Binary);
    report("[2] DEFECT: a small hole (two dropped facets)", p);
  }

  // 3a. Beyond repair — a wall-sized hole: strip the entire top face. Its span
  //     is a large fraction of the part, so the conservative bound refuses it.
  {
    TriangleMesh m = base;
    // Remove every +z top-face triangle (they were emitted as the 2nd quad of
    // each outline segment: indices 2,3 mod 8 across the ring). Simplest robust
    // strip: drop triangles whose three vertices all sit at z==6 (the top).
    TriangleMesh out;
    out.vertices = m.vertices;
    for (const auto& t : m.triangles) {
      const bool all_top = m.vertices[static_cast<std::size_t>(t[0])].z > 5.999 &&
                           m.vertices[static_cast<std::size_t>(t[1])].z > 5.999 &&
                           m.vertices[static_cast<std::size_t>(t[2])].z > 5.999;
      if (!all_top) out.triangles.push_back(t);
    }
    const std::string p = dir + "/bracket_wall_hole.stl";
    write_stl_file(p, out, StlFormat::Binary);
    report("[3a] BEYOND REPAIR: a wall-sized hole (whole top face removed)", p);
  }

  // 3b. Beyond repair — an ambiguous non-manifold junction: a fin welded onto a
  //     real bracket edge, three distinct facets at one edge. Not a duplicate,
  //     so it cannot be resolved automatically.
  {
    TriangleMesh m = base;
    // Pick an existing edge (vertices 0 and 1 are both bore-rim, adjacent) and
    // hang a fin off it to a new vertex.
    const int a = m.triangles[0][0], b = m.triangles[0][1];
    m.vertices.push_back(Vec3{0, 0, 20});  // a spike above the part
    const int c = static_cast<int>(m.vertices.size()) - 1;
    m.triangles.push_back({a, b, c});
    const std::string p = dir + "/bracket_ambiguous_junction.stl";
    write_stl_file(p, m, StlFormat::Binary);
    report("[3b] BEYOND REPAIR: an ambiguous non-manifold junction (a fin)", p);
  }

  std::printf("\ndone.\n");
  return 0;
}
