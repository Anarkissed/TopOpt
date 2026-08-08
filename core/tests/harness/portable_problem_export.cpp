// portable_problem_export — S1 of task 2026-08-09-reference-implementation-bakeoff.
//
// THE JOB: get HIS problem out of core in a form a third-party topology
// optimiser can consume, WITHOUT re-deriving any of it. Five methods have now
// been refused, every one of them OUR implementation of someone else's idea, and
// the point of this task is to stop that cycle. It would be self-defeating to
// begin it by re-deriving his boundary conditions in Julia from the STEP: a
// re-derivation is exactly the kind of silent difference that makes an
// implementation defect and a bad idea indistinguishable.
//
// So this exporter calls the PRODUCTION builder — `build_production_loadcase`,
// the same function `topopt-cli run` and the iPad bridge both call — and writes
// out what it returns. Every voxel tag, every clamped DOF, every nodal load is
// core's own, byte for byte.
//
//   cmake --build build --target portable_problem_export
//   ./build/portable_problem_export <job.json-ish> <part.step> <out_dir>
//
// ── WHAT COMES OUT ───────────────────────────────────────────────────────────
//
//   problem.json     the scalars: grid, spacing, origin, material, ladder,
//                    counts, and the SHA-256-able sizes of each binary below
//   solid.u8         nx*ny*nz bytes, x-fastest — the VoxelTag of every voxel
//                    (0 Empty, 1 Interior, 2 Surface, 3 UserTagged, 4 Load,
//                    5 Fixture). This is the part.
//   mask.u8          nx*ny*nz bytes — the EFFECTIVE design mask
//                    (0 Active, 1 FrozenSolid, 2 FrozenVoid) as
//                    `effective_design_mask` returns it, i.e. with Load/Fixture
//                    already forced FrozenSolid and Empty already FrozenVoid.
//   dirichlet.i32    2 int32 per clamped DOF: (node, component)
//   loads.bin        int32 node, int32 component, float64 newtons — per entry
//
// Node indexing is core's: a node grid of (nx+1) x (ny+1) x (nz+1), x-fastest,
// node (i,j,k) at origin + (i,j,k)*spacing. `problem.json` states this so the
// consumer cannot get it wrong silently, and S1's positive control checks the
// four counts against the run of record's own `loadcase.json`.
//
// ── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────
//
// It does not write a mesh, a density, or an interpretation. The four rung
// volume fractions come out as numbers because `production_reduction_ladder()`
// is core's, but nothing here decides what a consumer should do with them. The
// fidelity accounting — which of his constraints survive the crossing and which
// do not — is the handoff's §S1.2, not this program's.

#include "topopt/face_overrides.hpp"
#include "topopt/loadcase.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/production.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

using namespace topopt;

namespace {

void write_bytes(const std::string& path, const void* p, std::size_t n) {
  std::ofstream f(path, std::ios::binary);
  f.write(static_cast<const char*>(p), static_cast<std::streamsize>(n));
  if (!f) { std::printf("FATAL: could not write %s\n", path.c_str()); std::exit(2); }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::printf("usage: portable_problem_export <part.step> <materials.json> <out_dir>\n");
    return 2;
  }
  const std::string step_path = argv[1];
  const std::string materials_path = argv[2];
  const std::string out = argv[3];

  // ── THE JOB DOCUMENT, transcribed from job_simp.json ────────────────────
  //
  // This is `evidence/2026-08-09-reference-implementation-bakeoff/job_simp.json`
  // — PR 319's SIMP arm of record, which is his own captured document with the
  // lattice/grading blocks removed. It is spelled out here rather than parsed
  // because `production_loadcase_from_job` lives inside run_job.cpp's
  // translation unit and is not on a public header; transcribing 11 scalars is
  // honest, and S1's positive control is what proves the transcription right:
  // if any of these were wrong, the four counts below would not reproduce the
  // run of record's loadcase.json.
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
  lc.build_orientation_report = true;
  lc.infill_percent = 35.0;
  lc.wall_loops = 5;
  lc.wall_line_width_mm = 0.45;
  lc.wall_line_width_outer_mm = 0.42;
  lc.face_protection_face_ids = {16};
  lc.face_protection_depth_mm = 5.0;

  const StepModel model = import_part_file_resolved(step_path);
  if (model.mesh.vertices.empty()) {
    std::printf("FATAL: the STEP imported empty — OCCT is required\n");
    return 2;
  }
  std::printf("== portable_problem_export — S1 ==\n\n");
  std::printf("part        %s (%zu B-rep faces, %zu tessellation triangles)\n",
              step_path.c_str(), model.faces.size(), model.mesh.triangles.size());

  const ProductionRunSetup setup =
      build_production_loadcase(model, resolution, lc);
  const VoxelGrid& grid = setup.grid;
  const MinimizePlasticOptions& opt = setup.options;

  const std::size_t nvox = grid.voxel_count();
  const int nnx = grid.nx + 1, nny = grid.ny + 1, nnz = grid.nz + 1;

  std::printf("grid        %d x %d x %d = %zu voxels, spacing %.9f mm\n",
              grid.nx, grid.ny, grid.nz, nvox, grid.spacing);
  std::printf("origin      (%.9f, %.9f, %.9f) mm\n", grid.origin.x, grid.origin.y,
              grid.origin.z);
  std::printf("nodes       %d x %d x %d = %lld, %lld displacement DOFs\n", nnx, nny,
              nnz, static_cast<long long>(nnx) * nny * nnz,
              3LL * nnx * nny * nnz);

  // ── the tags ────────────────────────────────────────────────────────────
  std::vector<std::uint8_t> solid(nvox);
  std::size_t n_solid = 0, n_load = 0, n_fix = 0;
  for (std::size_t v = 0; v < nvox; ++v) {
    solid[v] = static_cast<std::uint8_t>(grid.tags[v]);
    if (grid.tags[v] != VoxelTag::Empty) ++n_solid;
    if (grid.tags[v] == VoxelTag::Load) ++n_load;
    if (grid.tags[v] == VoxelTag::Fixture) ++n_fix;
  }

  const DesignMask eff = effective_design_mask(grid, opt.design_mask);
  std::vector<std::uint8_t> mask(nvox);
  std::size_t n_active = 0, n_fsolid = 0, n_fvoid = 0;
  for (std::size_t v = 0; v < nvox; ++v) {
    mask[v] = static_cast<std::uint8_t>(eff[v]);
    switch (eff[v]) {
      case MaskValue::Active: ++n_active; break;
      case MaskValue::FrozenSolid: ++n_fsolid; break;
      case MaskValue::FrozenVoid: ++n_fvoid; break;
    }
  }

  // ── the BCs and the loads ───────────────────────────────────────────────
  std::vector<std::int32_t> diri;
  diri.reserve(setup.bcs.size() * 2);
  for (const auto& b : setup.bcs) {
    diri.push_back(static_cast<std::int32_t>(b.node));
    diri.push_back(static_cast<std::int32_t>(b.component));
  }

  struct LoadRec { std::int32_t node, comp; double value; };
  std::vector<LoadRec> loads;
  loads.reserve(opt.external_loads.size());
  double fx = 0, fy = 0, fz = 0;
  std::vector<char> loaded_node(static_cast<std::size_t>(nnx) * nny * nnz, 0);
  for (const auto& l : opt.external_loads) {
    loads.push_back({static_cast<std::int32_t>(l.node),
                     static_cast<std::int32_t>(l.component), l.value});
    if (l.component == 0) fx += l.value;
    if (l.component == 1) fy += l.value;
    if (l.component == 2) fz += l.value;
    loaded_node[static_cast<std::size_t>(l.node)] = 1;
  }
  std::size_t n_loaded_nodes = 0;
  for (char c : loaded_node) n_loaded_nodes += (c != 0);

  std::printf("\n-- core's own numbers, for the S1 positive control --\n");
  std::printf("anchor DOFs clamped      %zu\n", setup.bcs.size());
  std::printf("external load entries    %zu over %zu distinct nodes\n",
              opt.external_loads.size(), n_loaded_nodes);
  std::printf("load resultant           (%.8f, %.8f, %.8f) N\n", fx, fy, fz);
  std::printf("Load-tagged voxels       %zu\n", n_load);
  std::printf("Fixture-tagged voxels    %zu\n", n_fix);
  std::printf("solid voxels (the part)  %zu of %zu (%.4f%%)\n", n_solid, nvox,
              100.0 * static_cast<double>(n_solid) / static_cast<double>(nvox));
  std::printf("mask Active              %zu\n", n_active);
  std::printf("mask FrozenSolid         %zu\n", n_fsolid);
  std::printf("mask FrozenVoid          %zu\n", n_fvoid);
  for (const auto& r : setup.load_group_reports)
    std::printf("group %zu                  %zu voxels tagged, |F| = %.8f N\n",
                r.index, r.voxels_tagged, r.force_mag);

  // The FrozenSolid set minus the BC pad is the face-protection footprint; the
  // run of record's loadcase.json says 10554 for face 16. Report both so the
  // control can name which number it is checking.
  std::printf("\n(face protection is inside mask FrozenSolid together with the\n"
              " Load/Fixture pad — the run of record's loadcase.json records\n"
              " 10554 voxels frozen for face 16.)\n");

  // ── the material ────────────────────────────────────────────────────────
  const MaterialLibrary lib = load_materials_file(materials_path);
  const auto it = lib.find("PLA");
  if (it == lib.end()) { std::printf("FATAL: PLA not in %s\n", materials_path.c_str()); return 2; }
  const Material& m = it->second;
  std::printf("\nPLA         E = %.6f MPa, nu = %.6f, rho = %.6f g/cm3,\n"
              "            yield = %.6f MPa, z_knockdown = %.6f, family %s\n",
              m.youngs_modulus_mpa, m.poisson, m.density_g_cm3,
              m.yield_strength_mpa, m.z_knockdown, m.family.c_str());

  const std::vector<double> ladder = production_reduction_ladder();
  std::printf("ladder      [");
  for (std::size_t i = 0; i < ladder.size(); ++i)
    std::printf("%s%.2f", i ? ", " : "", ladder[i]);
  std::printf("]\n");

  // ── write ───────────────────────────────────────────────────────────────
  write_bytes(out + "/solid.u8", solid.data(), solid.size());
  write_bytes(out + "/mask.u8", mask.data(), mask.size());
  write_bytes(out + "/dirichlet.i32", diri.data(), diri.size() * sizeof(std::int32_t));
  write_bytes(out + "/loads.bin", loads.data(), loads.size() * sizeof(LoadRec));

  std::ofstream j(out + "/problem.json");
  j.precision(17);
  j << "{\n";
  j << "  \"source\": \"build_production_loadcase, core of this worktree\",\n";
  j << "  \"part\": \"M2_verticalStand.step\",\n";
  j << "  \"resolution\": " << resolution << ",\n";
  j << "  \"nx\": " << grid.nx << ", \"ny\": " << grid.ny << ", \"nz\": " << grid.nz << ",\n";
  j << "  \"spacing_mm\": " << grid.spacing << ",\n";
  j << "  \"origin_mm\": [" << grid.origin.x << ", " << grid.origin.y << ", "
    << grid.origin.z << "],\n";
  j << "  \"node_dims\": [" << nnx << ", " << nny << ", " << nnz << "],\n";
  j << "  \"node_order\": \"x-fastest then y then z; node(i,j,k) at origin + (i,j,k)*spacing\",\n";
  j << "  \"voxel_order\": \"x-fastest then y then z; voxel(i,j,k) spans [origin+(i,j,k)*h, origin+(i+1,j+1,k+1)*h]\",\n";
  j << "  \"voxel_tag_codes\": {\"Empty\":0,\"Interior\":1,\"Surface\":2,\"UserTagged\":3,\"Load\":4,\"Fixture\":5},\n";
  j << "  \"mask_codes\": {\"Active\":0,\"FrozenSolid\":1,\"FrozenVoid\":2},\n";
  j << "  \"solid_voxels\": " << n_solid << ",\n";
  j << "  \"load_tagged_voxels\": " << n_load << ",\n";
  j << "  \"fixture_tagged_voxels\": " << n_fix << ",\n";
  j << "  \"mask_active\": " << n_active << ",\n";
  j << "  \"mask_frozen_solid\": " << n_fsolid << ",\n";
  j << "  \"mask_frozen_void\": " << n_fvoid << ",\n";
  j << "  \"dirichlet_dofs\": " << setup.bcs.size() << ",\n";
  j << "  \"load_entries\": " << loads.size() << ",\n";
  j << "  \"load_nodes\": " << n_loaded_nodes << ",\n";
  j << "  \"load_resultant_n\": [" << fx << ", " << fy << ", " << fz << "],\n";
  j << "  \"material\": {\"name\": \"PLA\", \"youngs_modulus_mpa\": " << m.youngs_modulus_mpa
    << ", \"poisson\": " << m.poisson << ", \"density_g_cm3\": " << m.density_g_cm3
    << ", \"yield_strength_mpa\": " << m.yield_strength_mpa
    << ", \"z_knockdown\": " << m.z_knockdown << "},\n";
  j << "  \"ladder\": [";
  for (std::size_t i = 0; i < ladder.size(); ++i)
    j << (i ? ", " : "") << ladder[i];
  j << "],\n";
  // Core's own SIMP penalty default (ARCHITECTURE §4 p = 3), read off the struct
  // rather than typed as a literal so it cannot drift from the solver's.
  j << "  \"simp_penalty\": " << SimpParams{}.penalty << ",\n";
  j << "  \"simp_filter_radius_voxels\": " << opt.simp.filter_radius << ",\n";
  j << "  \"min_feature_mm\": " << opt.min_feature_mm << ",\n";
  j << "  \"margin_stop\": " << opt.margin_stop << ",\n";
  j << "  \"build_direction\": [" << opt.build_direction.x << ", "
    << opt.build_direction.y << ", " << opt.build_direction.z << "]\n";
  j << "}\n";
  j.close();

  std::printf("\nwrote %s/{problem.json,solid.u8,mask.u8,dirichlet.i32,loads.bin}\n",
              out.c_str());
  return 0;
}
