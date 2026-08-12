// plsm_topology_probe.cpp — R6 AND ITEM 4's COUNTERS, ON ANY DESIGN FIELD,
// THROUGH THE SHIPPED IMPLEMENTATION.
//
// ★ ONE IMPLEMENTATION, SO A SIMP ROW AND A PLSM ROW ARE THE SAME MEASUREMENT.
// `plsm_optimize` reports the void component count, the Euler characteristic,
// the cavity count and the sealed volume on every parametric run — but only on a
// parametric run, and R6 wants the sealed-void row for SIMP's rungs beside them.
// Re-deriving it in a script would be a second opinion about what "sealed"
// means; this calls `topopt::plsm_void_topology` — the header that ships — on a
// field read off disk.
//
// ★ THE ESCAPE RULE IS lattice_void.hpp's MANUFACTURING ONE, inherited from that
// header: the void walk is 6-CONNECTED (because the solid walk is 26-connected,
// and in 3D the complementary sets must take complementary adjacencies) and the
// exterior is the grid's six boundary planes, reached through the full
// not-printed set including the `Empty` voxels outside the part.
//
//   cmake --build build --target plsm_topology_probe
//   ./build/plsm_topology_probe <part.step> <field_prefix> [<field_prefix> ...]
//
// Each `<field_prefix>` is a `design_rung_dump` output stem: `<prefix>.f64` is
// nx*ny*nz float64 x-fastest and `<prefix>.meta` names the grid. The grid TAGS —
// which voxel is inside the part at all — come from the STEP through
// `build_production_loadcase`, the same entry point the run used, so "inside the
// part" means what it meant during the run.

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"  // import_part_file_resolved
#include "topopt/loadcase.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/plsm_topology.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 3) {
    std::printf(
        "usage: plsm_topology_probe <part.step> <field_prefix> [more...]\n");
    return 2;
  }
  const std::string step = argv[1];

  const int resolution = 128;
  ProductionLoadCase lc;
  lc.anchor_face_ids = {18};
  ProductionLoadCase::LoadGroup g;
  g.face_ids = {20, 1, 4, 19, 21, 22, 25, 26, 27, 32, 41, 42,
                43, 44, 45, 46, 47, 49, 75, 76, 24, 31};
  g.force = Vec3{0.0, 0.0, -22.241134643554688};
  lc.load_groups.push_back(g);
  lc.minimize_plastic = true;
  lc.build_dir = Vec3{0.0, 0.0, 1.0};
  lc.infill_percent = 35.0;
  lc.wall_loops = 5;
  lc.wall_line_width_mm = 0.45;
  lc.wall_line_width_outer_mm = 0.42;
  lc.face_protection_face_ids = {16};
  lc.face_protection_depth_mm = 5.0;

  const StepModel model = import_part_file_resolved(step);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required\n");
    return 2;
  }
  const ProductionRunSetup setup =
      build_production_loadcase(model, resolution, lc);
  const VoxelGrid& grid = setup.grid;
  const std::size_t n = grid.voxel_count();
  std::vector<char> in_part(n, 0);
  for (std::size_t v = 0; v < n; ++v)
    in_part[v] = grid.tags[v] != VoxelTag::Empty ? 1 : 0;

  // ★ `--dump-in-part FILE` writes the in-part mask as raw uint8, so the
  // one-off cross-check in the evidence directory can recompute these counters
  // with completely different code on the SAME grid. A second implementation is
  // only a check if it is handed the same inputs.
  for (int i = 2; i + 1 < argc; ++i)
    if (std::string(argv[i]) == "--dump-in-part") {
      std::ofstream d(argv[i + 1], std::ios::binary);
      d.write(in_part.data(), static_cast<std::streamsize>(in_part.size()));
      std::printf("wrote in-part mask (%zu bytes) to %s\n", in_part.size(),
                  argv[i + 1]);
    }

  std::printf(
      "== void topology, by the MANUFACTURING escape rule "
      "(6-connected void, exterior = the grid's boundary planes) ==\n"
      "grid %d x %d x %d   spacing %.6f mm   in-part voxels %zu of %zu\n\n",
      grid.nx, grid.ny, grid.nz, grid.spacing,
      static_cast<std::size_t>(grid.solid_count()), n);
  // ★ `b2` AND `sealed_pk` ARE DIFFERENT COLUMNS ON PURPOSE. b2 is the Betti
  // number the Euler identity needs — the SOLID ISLANDS the void encloses —
  // and `sealed_pk` is the DRAINABILITY verdict. Printing one under the other's
  // name is the defect `plsm_topology.hpp`'s header describes.
  std::printf("%-40s%9s%9s%9s%9s%11s%12s%9s%14s\n", "field", "b0", "chi",
              "b2solid", "b1tun", "sealed_pk", "sealed_vox", "sealed%",
              "sealed_mm3");

  std::printf("field,b0_components,chi,b2_enclosed_solid,b1_tunnels,"
              "sealed_pockets,void_voxels,sealed_voxels,sealed_volume_mm3\n");
  for (int i = 2; i < argc; ++i) {
    const std::string stem = argv[i];
    if (stem == "--dump-in-part") { ++i; continue; }
    std::ifstream f(stem + ".f64", std::ios::binary);
    if (!f) {
      std::printf("FATAL: cannot open %s.f64\n", stem.c_str());
      return 2;
    }
    std::vector<double> occ(n, 0.0);
    f.read(reinterpret_cast<char*>(occ.data()),
           static_cast<std::streamsize>(n * sizeof(double)));
    if (static_cast<std::size_t>(f.gcount()) != n * sizeof(double)) {
      std::printf("FATAL: %s.f64 is %lld bytes, expected %zu — a field for a "
                  "different grid is not a field this can measure\n",
                  stem.c_str(), static_cast<long long>(f.gcount()),
                  n * sizeof(double));
      return 2;
    }
    const PlsmVoidTopology t =
        plsm_void_topology(grid.nx, grid.ny, grid.nz, grid.spacing, occ, 0.5,
                           in_part);
    const double sealed_pct =
        t.void_voxels > 0
            ? 100.0 * static_cast<double>(t.sealed_voxels) /
                  static_cast<double>(t.void_voxels)
            : 0.0;
    std::printf("%-40s%9lld%9lld%9lld%9lld%11lld%12lld%8.2f%%%14.3f\n",
                stem.c_str(), t.components, t.chi, t.enclosed_solid, t.tunnels,
                t.sealed_pockets, t.sealed_voxels, sealed_pct,
                t.sealed_volume_mm3);
    std::printf("CSV,%s,%lld,%lld,%lld,%lld,%lld,%lld,%lld,%.6f\n", stem.c_str(),
                t.components, t.chi, t.enclosed_solid, t.tunnels, t.sealed_pockets,
                t.void_voxels,
                t.sealed_voxels, t.sealed_volume_mm3);
  }
  return 0;
}
