// sector_lattice_job_gen — BUILD THE §4 DEMONSTRATION JOB
// (task 2026-08-15-lattice-regions §4, bar R4).
//
//   ./build/sector_lattice_job_gen <part.step> <res> <n> <m> <out.json>
//
// Takes a CURVED feature on the part, grid-splits it into N sectors about its
// own axis, and emits a job in which each sector is a REGION-BACKED LATTICE
// REGION at its OWN depth. The cut planes are computed by core's own
// `grid_split_cells`, so the job the run consumes carries exactly the geometry
// the splitter produced — not a hand-typed approximation of it.
//
// The load case is the maintainer's captured one
// (evidence/2026-08-04-protect-freeze-vs-solidity/job_maintainer.json): same
// anchors, same load group, same force, so the only thing that differs from his
// real run is WHICH volume is latticed and HOW DEEP each sector goes.

#include "topopt/face_overrides.hpp"
#include "topopt/face_region.hpp"
#include "topopt/part.hpp"
#include "topopt/voxel.hpp"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 6) {
    std::fprintf(stderr,
                 "usage: sector_lattice_job_gen <part.step> <res> <n> <m> "
                 "<out.json>\n");
    return 2;
  }
  const std::string part = argv[1];
  const int res = std::atoi(argv[2]);
  // n = sectors ABOUT the axis, m = slabs ALONG it (§4b). A partial bore does
  // not fill every angular sector — the guard says so — so the axial family is
  // the one that divides a real feature evenly.
  const int n_ang = std::atoi(argv[3]);
  const int m_ax = std::atoi(argv[4]);
  // -2 = the largest face of ANY kind. The bore demonstration was invalid: its
  // axial extent is ~6 voxels, so splitting it four ways made the SLICE HEIGHT
  // the thinnest dimension and the declared depth could never bind.
  const int want_face = argc > 6 ? std::atoi(argv[6]) : -1;
  const int sectors = n_ang * m_ax;
  StepModel model = import_part_file_resolved(part);
  const VoxelGrid grid = voxelize(model.mesh, res);
  const std::vector<double> areas = face_areas_mm2(model);

  // THE CURVED FEATURE: the largest CYLINDRICAL face, which is what §4 asks for
  // and what makes the split cylindrical (sectors about the bore's own axis)
  // rather than a PCA fallback.
  int feature = -1;
  if (want_face == -2) {
    feature = 0;
    for (int f = 1; f < model.face_count; ++f)
      if (areas[(std::size_t)f] > areas[(std::size_t)feature]) feature = f;
  } else if (want_face >= 0) {
    feature = want_face;
  } else {
    for (int f = 0; f < model.face_count; ++f) {
      if (model.faces[(std::size_t)f].kind != StepSurfaceKind::Cylinder) continue;
      if (feature < 0 || areas[(std::size_t)f] > areas[(std::size_t)feature])
        feature = f;
    }
  }
  if (feature < 0) { std::fprintf(stderr, "no cylindrical face\n"); return 1; }

  FaceRegionSpec parent;
  parent.id = 100;
  parent.name = "feature";
  parent.add = {feature};
  const ResolvedFaceRegion whole = resolve_face_regions(model, {parent})[0];
  const RegionFrame frame = region_frame(model, whole);
  const std::vector<GridSplitCell> cells = grid_split_cells(frame, n_ang, m_ax);
  const std::vector<int> vox = region_member_voxels(grid, model, whole, 1);
  const std::vector<std::size_t> counts =
      grid_split_voxel_counts(grid, vox, cells);
  const SliverVerdict sv = check_sliver(counts, cells, vox.size());

  std::fprintf(stderr,
               "feature face %d  area %.4g mm^2  frame %s  %zu voxels\n"
               "split %dx%d = %d cells  smallest %zu voxels  floor %zu  -> %s\n",
               feature, areas[(std::size_t)feature],
               frame.cylindrical ? "CYLINDRICAL" : "PCA", vox.size(), n_ang,
               m_ax, sectors, sv.min_cell_voxels, sv.floor_voxels,
               sv.ok ? "OK" : "REFUSED");
  if (!sv.ok) std::fprintf(stderr, "  %s\n", sv.reason.c_str());

  auto v3 = [](const Vec3& v) {
    char b[128];
    std::snprintf(b, sizeof(b), "[%.10g, %.10g, %.10g]", v.x, v.y, v.z);
    return std::string(b);
  };

  // ★ THE DEPTHS DIFFER PER SECTOR — that is the whole demonstration.
  std::vector<double> depths;
  for (int i = 0; i < sectors; ++i)
    depths.push_back(sectors == 2 ? (i == 0 ? 3.0 : 7.5) : 3.0 + 1.5 * i);

  std::string s = "{\n";
  s += "  \"material\": \"PLA\",\n  \"mode\": \"minimize_plastic\",\n";
  s += "  \"resolution\": " + std::to_string(res) + ",\n";
  s += "  \"model\": \"" + part.substr(part.find_last_of('/') + 1) + "\",\n";
  s += "  \"bake_build_orientation\": \"off\",\n";
  s += "  \"output\": {\"mesh_format\": \"stl\", \"report\": \"report.json\", "
       "\"mesh_prefix\": \"variant\"},\n";
  s += "  \"grading\": {\"cell_mode\": \"fit\", \"topology\": \"octet\", "
       "\"min_extrudable_width_mm\": 0.42},\n";
  s += "  \"lattice\": {\"topology\": \"octet\", \"emit_stl\": true, "
       "\"emit_3mf\": false, \"skin\": \"none\", "
       "\"min_extrudable_width_mm\": 0.42,\n    \"regions\": [\n";
  for (int i = 0; i < sectors; ++i) {
    s += "      {\"role\": \"include\", \"kind\": \"region\", \"region_id\": " +
         std::to_string(200 + i) + ", \"geometry\": {\"depth_mm\": " +
         std::to_string(depths[(std::size_t)i]) + "}}";
    s += (i + 1 < sectors) ? ",\n" : "\n";
  }
  s += "    ]},\n";
  s += "  \"loads\": {\n    \"anchor_face_ids\": [18],\n";
  s += "    \"face_regions\": [\n";
  for (int i = 0; i < sectors; ++i) {
    s += "      {\"id\": " + std::to_string(200 + i) + ", \"name\": \"sector " +
         std::to_string(i + 1) + "\", \"parent_id\": 100, \"add\": [" +
         std::to_string(feature) + "], \"cuts\": [";
    for (std::size_t c = 0; c < cells[(std::size_t)i].cuts.size(); ++c) {
      const RegionCut& k = cells[(std::size_t)i].cuts[c];
      s += std::string(c ? ", " : "") + "{\"point\": " + v3(k.point) +
           ", \"normal\": " + v3(k.normal) + ", \"strict\": " +
           (k.strict ? "true" : "false") + "}";
    }
    s += "]}";
    s += (i + 1 < sectors) ? ",\n" : "\n";
  }
  s += "    ],\n";
  s += "    \"groups\": [{\"face_ids\": [20, 1, 4, 19, 21, 22, 25, 26, 27, 32, "
       "41, 42, 43, 44, 45, 46, 47, 49, 75, 76, 24, 31], "
       "\"force\": [0, 0, -22.241134643554688]}],\n";
  // ★ EACH SECTOR IS PROTECTED TO ITS OWN LATTICE DEPTH — bar R5, on the wire.
  s += "    \"face_protections\": [";
  for (int i = 0; i < sectors; ++i) {
    s += std::string(i ? ", " : "") + "{\"region_id\": " +
         std::to_string(200 + i) + ", \"depth_mm\": " +
         std::to_string(depths[(std::size_t)i]) + "}";
  }
  s += "],\n";
  s += "    \"build_dir\": [0, 0, 1], \"minimize_plastic\": true, "
       "\"infill_percent\": 35, \"wall_loops\": 5, "
       "\"wall_line_width_mm\": 0.45, \"wall_line_width_outer_mm\": 0.42\n";
  s += "  }\n}\n";

  std::FILE* f = std::fopen(argv[5], "w");
  if (!f) { std::fprintf(stderr, "cannot write %s\n", argv[5]); return 1; }
  std::fwrite(s.data(), 1, s.size(), f);
  std::fclose(f);
  std::fprintf(stderr, "wrote %s (%zu bytes)\n", argv[5], s.size());
  return 0;
}
