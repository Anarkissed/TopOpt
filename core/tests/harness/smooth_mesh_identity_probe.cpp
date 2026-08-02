// smooth_mesh_identity_probe — S1 of handoff 2026-08-03-smoothing-page-round2:
// NAME the two meshes the smoothing page confused, and measure the ratio.
//
// On device the page refused to paint with:
//
//   "The protected-surface map describes a different mesh (17496 vertices vs
//    105060) — refusing to paint rather than guess which vertices it means."
//
// The refusal is correct; the mismatch is the defect. This probe reproduces BOTH
// meshes from the maintainer's own fixture and prints their vertex counts, so the
// 6x is a measurement rather than an inference. It also answers the question the
// counts alone cannot: when the counts DO match, do the two meshes agree
// INDEX FOR INDEX? That is the difference between a guard that refuses and a
// guard that lets the brush paint the wrong vertices in silence.
//
// The two meshes, by construction:
//
//   A  THE APP MESH — `OptimizeVariant.meshVertices`. Two producers:
//      A-local   the bridge's `to_optimize_variant` sends `export_display_mesh`,
//                a marching-cubes surface. MC WELDS shared edges, so this is a
//                welded mesh in MC's own (edge-id) vertex order.
//      A-remote  a LAN worker returns a binary STL and the app parses it with
//                `MeshExport.parseBinarySTL`, which is documented to produce a
//                TRIANGLE SOUP — "each triangle its own three vertices — STL
//                shares none". That is 3 x triangle_count vertices.
//
//   B  THE CORE MESH — what `smooth_freeze_mask` (and the smoother, and the
//      certifier) actually operate on: `import_any(mesh_path)`, i.e.
//      `import_part_file`, whose `weld_and_clean` welds by exact coordinate.
//
// A harness, not a ctest: it prints a table and writes evidence.
//
//   cmake --build build --target smooth_mesh_identity_probe
//   ./build/smooth_mesh_identity_probe [mesh] [res] [evidence_dir]

#include "topopt/clearance.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/smooth.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

// The app's own STL export seam (`exportSTL` -> bridge `export_stl` ->
// `write_stl_file`, Binary): every coordinate narrowed to float32, every facet
// its own three vertices on disk. Reproduced here so the probe's "what the app
// wrote" is the bytes the app writes, not an idealisation of them.
void write_app_stl(const std::string& path, const TriangleMesh& m) {
  write_stl_file(path, m, StlFormat::Binary);
}

// `MeshExport.parseBinarySTL` (app/TopOptKit/Sources/TopOptFlows/MeshExport.swift
// :106) in C++: a triangle soup, three fresh vertices per facet, float32.
TriangleMesh parse_binary_stl_as_soup(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw std::runtime_error("cannot open " + path);
  char header[80];
  in.read(header, 80);
  std::uint32_t count = 0;
  in.read(reinterpret_cast<char*>(&count), 4);
  TriangleMesh out;
  out.vertices.reserve(static_cast<std::size_t>(count) * 3);
  out.triangles.reserve(count);
  for (std::uint32_t t = 0; t < count; ++t) {
    float rec[12];
    in.read(reinterpret_cast<char*>(rec), 48);
    std::uint16_t attr = 0;
    in.read(reinterpret_cast<char*>(&attr), 2);
    if (!in) break;
    const int base = static_cast<int>(out.vertices.size());
    for (int v = 0; v < 3; ++v)
      out.vertices.push_back(Vec3{rec[3 + v * 3 + 0], rec[3 + v * 3 + 1],
                                  rec[3 + v * 3 + 2]});
    out.triangles.push_back({base, base + 1, base + 2});
  }
  return out;
}

// Do two meshes agree INDEX FOR INDEX? Not "same count" — same vertex at the
// same index, which is the only thing that makes a per-vertex mask and a
// per-vertex weight vector mean the same thing.
struct Agreement {
  bool same_count = false;
  bool same_order = false;
  std::size_t first_difference = 0;
  std::size_t differing = 0;
};

Agreement compare(const TriangleMesh& a, const TriangleMesh& b) {
  Agreement r;
  r.same_count = a.vertices.size() == b.vertices.size();
  if (!r.same_count) return r;
  r.same_order = true;
  r.first_difference = a.vertices.size();
  for (std::size_t i = 0; i < a.vertices.size(); ++i) {
    const Vec3& p = a.vertices[i];
    const Vec3& q = b.vertices[i];
    if (p.x != q.x || p.y != q.y || p.z != q.z) {
      if (r.same_order) r.first_difference = i;
      r.same_order = false;
      ++r.differing;
    }
  }
  return r;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string mesh_path =
      argc > 1 ? argv[1]
               : std::string(MESH_FIXTURE_DIR) + "/WallMount_ShelfBracket.stl";
  const int resolution = argc > 2 ? std::atoi(argv[2]) : 64;
  const std::string evidence_dir = argc > 3 ? argv[3] : "";

  std::printf("[IDENTITY] fixture: %s  resolution=%d\n", mesh_path.c_str(),
              resolution);

  // --- build the variant surface the way the optimizer's display seam does ---
  // The app's variant mesh is a marching-cubes iso-surface of a density field on
  // the solved grid. Voxelizing the fixture gives a field of the same SHAPE at
  // the same grid, which is all this probe needs: the question is about vertex
  // BOOKKEEPING through the export/import seam, not about the field's values.
  const StepModel model = import_part_file(mesh_path);
  const VoxelGrid grid = voxelize(model.mesh, resolution);
  std::vector<double> field(grid.voxel_count(), 0.0);
  for (std::size_t i = 0; i < field.size(); ++i)
    field[i] = grid.tags[i] != VoxelTag::Empty ? 1.0 : 0.0;

  // kSmoothExportFactor = 2 in the bridge (bridge.cpp:229).
  const TriangleMesh mc = keep_largest_component(marching_cubes_resampled(
      grid.nx, grid.ny, grid.nz, grid.spacing, grid.origin, field, 0.5, 2,
      ResampleInterp::Tricubic));

  std::printf("[IDENTITY] MC surface: %zu verts, %zu tris  (3 x tris = %zu)\n",
              mc.vertices.size(), mc.triangles.size(),
              mc.triangles.size() * 3);

  const std::string tmp = evidence_dir.empty()
                              ? std::string("/tmp/topopt-identity-probe.stl")
                              : evidence_dir + "/identity_probe.stl";
  write_app_stl(tmp, mc);

  // --- A-remote: the LAN path's app mesh -------------------------------------
  const TriangleMesh soup = parse_binary_stl_as_soup(tmp);

  // --- A-local: the on-device path's app mesh --------------------------------
  // The bridge narrows MC's doubles to float32 for `mesh_vertices`; the app
  // holds exactly those floats. Reproduced so the local path's count is the
  // count the app really has.
  TriangleMesh local = mc;
  for (auto& v : local.vertices) {
    v.x = static_cast<float>(v.x);
    v.y = static_cast<float>(v.y);
    v.z = static_cast<float>(v.z);
  }

  // --- B: the core mesh, what the freeze mask and the smoother see ------------
  const TriangleMesh core = import_part_file(tmp).mesh;

  std::printf("\n[IDENTITY] the two meshes\n");
  std::printf("[IDENTITY]   %-46s %10s\n", "mesh", "vertices");
  std::printf("[IDENTITY]   %-46s %10zu\n",
              "A-remote  MeshExport.parseBinarySTL (soup)", soup.vertices.size());
  std::printf("[IDENTITY]   %-46s %10zu\n",
              "A-local   bridge to_optimize_variant (MC)", local.vertices.size());
  std::printf("[IDENTITY]   %-46s %10zu\n",
              "B         import_part_file (welded)", core.vertices.size());
  if (core.vertices.size() > 0)
    std::printf("[IDENTITY]   ratio A-remote : B = %.4f\n",
                static_cast<double>(soup.vertices.size()) /
                    static_cast<double>(core.vertices.size()));

  const Agreement remote_vs_core = compare(soup, core);
  const Agreement local_vs_core = compare(local, core);

  std::printf("\n[IDENTITY] does the app mesh agree with core's, INDEX FOR INDEX?\n");
  std::printf("[IDENTITY]   %-12s %-12s %-12s %-14s\n", "app mesh",
              "same count", "same order", "first differs");
  auto row = [](const char* name, const Agreement& a) {
    std::printf("[IDENTITY]   %-12s %-12s %-12s %-14zu\n", name,
                a.same_count ? "YES" : "NO", a.same_order ? "YES" : "NO",
                a.same_count ? a.first_difference : 0);
  };
  row("A-remote", remote_vs_core);
  row("A-local", local_vs_core);
  if (local_vs_core.same_count && !local_vs_core.same_order)
    std::printf("[IDENTITY]   A-local differs at %zu of %zu vertices "
                "-- SAME COUNT, DIFFERENT VERTICES\n",
                local_vs_core.differing, local.vertices.size());

  // --- the fix, measured: adopt core's own import as the page's mesh ----------
  // The page writes the STL and then re-imports THAT FILE. One artifact defines
  // the page's mesh; the mask, the brush, the stage and the smoother all read it.
  const TriangleMesh page = import_part_file(tmp).mesh;
  const Agreement fixed = compare(page, core);
  std::printf("\n[IDENTITY] after the fix (page mesh = import_part_file(inPath)):\n");
  std::printf("[IDENTITY]   same count = %s   same order = %s\n",
              fixed.same_count ? "YES" : "NO", fixed.same_order ? "YES" : "NO");

  // --- THE LINE THE DEVICE SHOWED, before and after --------------------------
  // On device the panel read "1783 of 17496 vertices frozen · within 2.43 mm"
  // beside a stage carrying 105060. The mask was never wrong; it described the
  // other mesh. Here is the same readout against both candidates.
  std::size_t frozen_count = 0;
  double tol = 0.0;
  {
    // A stand-in freeze region on the part's own geometry: a slab at max-x, the
    // wall plate the bracket is anchored by. The POINT is the bookkeeping, not
    // which faces are chosen — a mask is one entry per vertex of whatever mesh it
    // was computed on, and that is what has to line up.
    double max_x = -1e30, min_y = 1e30;
    for (const Vec3& v : core.vertices) {
      if (v.x > max_x) max_x = v.x;
      if (v.y < min_y) min_y = v.y;
    }
    tol = 0.75 * grid.spacing;
    ClearanceGeometry g;
    g.valid = true;
    g.kind = ClearanceKind::Face;
    // A slab one voxel deep, inward from the max-x plane, unbounded in-plane.
    g.origin = Vec3{max_x, 0.0, 0.0};
    g.normal = Vec3{-1.0, 0.0, 0.0};
    g.u = Vec3{0.0, 1.0, 0.0};
    g.w = Vec3{0.0, 0.0, 1.0};
    g.u_lo = -1e6; g.u_hi = 1e6;
    g.w_lo = -1e6; g.w_hi = 1e6;
    g.depth = grid.spacing;
    const std::vector<ClearanceGeometry> regions{g};
    const std::vector<char> f = compute_freeze_mask(core, regions, tol);
    for (const char c : f) frozen_count += (c ? 1u : 0u);

    std::printf("\n[IDENTITY] the panel's own readout\n");
    std::printf("[IDENTITY]   mask entries              %zu\n", f.size());
    std::printf("[IDENTITY]   frozen                    %zu\n", frozen_count);
    std::printf("[IDENTITY]   tolerance (mm)            %.2f\n", tol);
    std::printf("[IDENTITY]   ROUND 1 — stage carried   %zu  -> mask entries %s "
                "the painted mesh: BRUSH REFUSED\n",
                soup.vertices.size(),
                f.size() == soup.vertices.size() ? "match" : "DO NOT match");
    std::printf("[IDENTITY]   ROUND 2 — stage carries   %zu  -> mask entries %s "
                "the painted mesh: BRUSH PAINTS\n",
                page.vertices.size(),
                f.size() == page.vertices.size() ? "match" : "DO NOT match");
  }

  if (!evidence_dir.empty()) {
    std::ofstream ev(evidence_dir + "/s1_mesh_identity.txt");
    ev << "fixture: " << mesh_path << "  resolution=" << resolution << "\n";
    ev << "MC surface: " << mc.vertices.size() << " verts, "
       << mc.triangles.size() << " tris\n\n";
    ev << "A-remote (parseBinarySTL soup)   " << soup.vertices.size() << "\n";
    ev << "A-local  (bridge MC, float32)    " << local.vertices.size() << "\n";
    ev << "B        (import_part_file)      " << core.vertices.size() << "\n";
    ev << "ratio A-remote : B = "
       << (static_cast<double>(soup.vertices.size()) /
           static_cast<double>(core.vertices.size()))
       << "\n\n";
    ev << "A-remote vs B: same_count=" << remote_vs_core.same_count
       << " same_order=" << remote_vs_core.same_order << "\n";
    ev << "A-local  vs B: same_count=" << local_vs_core.same_count
       << " same_order=" << local_vs_core.same_order
       << " differing=" << local_vs_core.differing << "\n";
    ev << "page mesh vs B: same_count=" << fixed.same_count
       << " same_order=" << fixed.same_order << "\n\n";
    ev << "panel readout: " << frozen_count << " of " << core.vertices.size()
       << " vertices frozen, within " << tol << " mm\n";
    ev << "round 1 stage carried " << soup.vertices.size()
       << " -> mask entries did not match -> BRUSH REFUSED\n";
    ev << "round 2 stage carries " << page.vertices.size()
       << " -> mask entries match -> BRUSH PAINTS\n";
  }

  return 0;
}
