// cad_probe — DID CAD-FACE PROJECTION ACTUALLY DO ANYTHING ON THIS JOB?
// (task 2026-08-16-per-sector-density-override, bar R3's positive control.)
//
//   ./build/cad_probe <part.step> <variant.stl> <voxel_spacing_mm>
//
// R3 asks whether the CAD projection error is unchanged when a density override
// is applied. That question is only answerable if projection MOVES SOMETHING on
// this job — otherwise "unchanged" is true for the wrong reason and the bar
// passes vacuously. This measures the attribution and the displacement with the
// EXACT options run_job uses (cad_project_options_for_grid(spacing)).
//
// ★ READ THE VERDICT CAREFULLY, AND MIND WHAT `project_cad_faces` DEFAULTS TO.
// This probe re-projects an ALREADY-EXPORTED mesh, so "moved > 0" says the
// operation is capable of moving vertices on this part — NOT that the exported
// file was left unprojected. `output.project_cad_faces` is ARMED BY DEFAULT
// (test_default_arming.cpp: an ABSENT key means true), so a job that never
// mentions the key already projects. Comparing an absent-key run against an
// explicit-true run therefore compares a configuration with ITSELF and is not a
// control. The only honest control is an explicit `"project_cad_faces": false`.
// I got this backwards once and briefly concluded projection was a no-op.

#include "topopt/cad_project.hpp"
#include "topopt/face_overrides.hpp"
#include "topopt/stl.hpp"
#include "topopt/part.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace topopt;

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: cad_probe <part.step> <variant.stl> <spacing_mm>\n");
    return 2;
  }
  const StepModel m = import_part_file_resolved(argv[1]);
  const TriangleMesh src = read_stl_file(argv[2]).mesh;
  const double spacing = std::atof(argv[3]);

  std::printf("part          face_count=%d  faces.size()=%zu  faces_are_fitted=%d\n",
              m.face_count, m.faces.size(), (int)m.faces_are_fitted);
  std::printf("variant mesh  %zu vertices, %zu triangles\n",
              src.vertices.size(), src.triangles.size() / 3);

  CadProjectOptions po = cad_project_options_for_grid(spacing);
  po.enabled = true;
  std::printf("options       tolerance_mm=%.6g  (from spacing %.6g)\n",
              po.tolerance_mm, spacing);

  const CadAttribution att = attribute_to_cad_faces(src, m, po);
  long long attributed = 0, ambiguous = 0, seam = 0;
  for (std::size_t i = 0; i < att.face_of_vertex.size(); ++i) {
    if (att.face_of_vertex[i] >= 0) ++attributed;
    if (i < att.ambiguous_flag.size() && att.ambiguous_flag[i]) ++ambiguous;
    if (i < att.seam.size() && att.seam[i]) ++seam;
  }
  std::printf("attribution   attributed=%lld  ambiguous=%lld  seam=%lld  of %zu\n",
              attributed, ambiguous, seam, att.face_of_vertex.size());

  const TriangleMesh out = project_onto_cad_faces(src, m, po, att);
  if (out.vertices.size() != src.vertices.size()) {
    std::printf("RESULT        projection returned a DIFFERENT vertex count\n");
    return 0;
  }
  long long moved = 0;
  double maxd = 0.0, sumd = 0.0;
  for (std::size_t v = 0; v < src.vertices.size(); ++v) {
    const double dx = out.vertices[v].x - src.vertices[v].x;
    const double dy = out.vertices[v].y - src.vertices[v].y;
    const double dz = out.vertices[v].z - src.vertices[v].z;
    const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
    if (d > 0.0) { ++moved; sumd += d; maxd = std::max(maxd, d); }
  }
  std::printf("displacement  moved=%lld vertices  max=%.6g mm  mean(moved)=%.6g mm\n",
              moved, maxd, moved ? sumd / (double)moved : 0.0);
  std::printf("VERDICT       projection is %s on this job\n",
              moved ? "ACTIVE — R3 can discriminate"
                    : "A NO-OP — R3 WOULD PASS VACUOUSLY HERE");
  return 0;
}
