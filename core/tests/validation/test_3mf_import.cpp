// test_3mf_import.cpp — the 3MF IMPORT path, executed and proven end to end
// (handoff 2026-07-24-3mf-enable).
//
// Until now the 3MF code was written but the IMPORT half was never exercised
// through the pipeline: test_3mf.cpp round-trips write_3mf_file/read_3mf_file,
// and cli_demo drives 3MF *output* from a STEP part — but no committed test ever
// imported a real .3mf part, segmented it, and optimized it, and nothing proved
// an STL and a 3MF of the SAME part agree. This file closes that gap. It is
// lib3mf-gated (it reads a real 3MF package) and lives in the OCCT+Eigen block
// (it drives run_job); CI has all three (DEPS=ON), so it always runs there.
//
// The fixture core/tests/fixtures/mesh/plate_bore.3mf is the 3MF encoding of the
// SAME plate-with-a-bore as plate_bore.stl: it was produced by reading that STL
// and writing it back out with write_3mf_file (tools/gen_3mf_fixture in the
// handoff), so the two files are the same geometry in the two formats a user
// would export from CAD. 3MF stores vertices as ~6-significant-digit decimal
// text, so the coordinates differ from the STL's float32 by <=1e-6 mm; that is
// far below a voxel, so the grid the optimizer solves on is identical.
//
// Two sections:
//
//   A. STL-vs-3MF import equivalence. import_part on each file yields the SAME
//      manufactured topology (triangle_face + face_count bit-identical) and,
//      through voxelization at every solve resolution, the IDENTICAL solid voxel
//      set and the IDENTICAL per-pseudo-face tag set. Vertices agree within the
//      3MF text precision and the enclosed volume within M6.1's 0.5%.
//
//   B. 3MF end-to-end optimize + full-pipeline byte-identity. run_job on the
//      .3mf part produces a finalized report with accepted variants, an exported
//      mesh per variant, and a fields container — the same shape a STEP job does
//      — and is deterministic twice-run. Because the voxel grid + tags are
//      identical to the STL's, the whole run is BYTE-IDENTICAL to the STL job:
//      same report bytes, same exported mesh bytes, same pseudo-face ids.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests. The
// public API only names topopt/*; lib3mf itself is never named here.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static std::set<std::size_t> solid_set(const VoxelGrid& g) {
  std::set<std::size_t> s;
  for (std::size_t i = 0; i < g.tags.size(); ++i)
    if (g.tags[i] != VoxelTag::Empty) s.insert(i);
  return s;
}

static std::set<std::size_t> tag_set(const VoxelGrid& g, VoxelTag t) {
  std::set<std::size_t> s;
  for (std::size_t i = 0; i < g.tags.size(); ++i)
    if (g.tags[i] == t) s.insert(i);
  return s;
}

static std::string mesh_dir() { return std::string(MESH_FIXTURE_DIR); }

// ---------------------------------------------------------------------------
// A. STL-vs-3MF import equivalence.
static void section_equivalence() {
  const PartModel stl = import_part(mesh_dir() + "/plate_bore.stl");
  const PartModel tmf = import_part(mesh_dir() + "/plate_bore.3mf");

  CHECK(stl.pseudo_faces, "STL import manufactures pseudo-faces");
  CHECK(tmf.pseudo_faces, "3MF import manufactures pseudo-faces");

  const StepModel& a = stl.model;  // STL
  const StepModel& b = tmf.model;  // 3MF

  // Topology + segmentation are EXACT: the two files describe the same triangle
  // connectivity, so the dihedral segmenter manufactures the identical faces.
  CHECK(a.mesh.vertices.size() == b.mesh.vertices.size(),
        "same vertex count STL vs 3MF");
  CHECK(a.mesh.triangles == b.mesh.triangles,
        "identical triangle indices STL vs 3MF (bit for bit)");
  CHECK(a.face_count == b.face_count, "same pseudo-face count STL vs 3MF");
  CHECK(a.triangle_face == b.triangle_face,
        "identical per-triangle pseudo-face id STL vs 3MF (bit for bit)");

  // Coordinates agree within the 3MF decimal-text precision, and the enclosed
  // volume within M6.1's 0.5% (in practice ~1e-8 here).
  double max_vertex_diff = 0.0;
  const bool same_n = a.mesh.vertices.size() == b.mesh.vertices.size();
  for (std::size_t i = 0; same_n && i < a.mesh.vertices.size(); ++i) {
    max_vertex_diff = std::fmax(max_vertex_diff,
                                std::fabs(a.mesh.vertices[i].x - b.mesh.vertices[i].x));
    max_vertex_diff = std::fmax(max_vertex_diff,
                                std::fabs(a.mesh.vertices[i].y - b.mesh.vertices[i].y));
    max_vertex_diff = std::fmax(max_vertex_diff,
                                std::fabs(a.mesh.vertices[i].z - b.mesh.vertices[i].z));
  }
  CHECK(max_vertex_diff <= 1e-5,
        "max vertex coordinate diff within 3MF text precision (<=1e-5 mm)");
  const double va = std::fabs(a.brep_volume), vb = std::fabs(b.brep_volume);
  CHECK(va > 0.0 && std::fabs(vb - va) <= 0.005 * va,
        "enclosed volume agrees STL vs 3MF within 0.5% (M6.1)");

  // The decision-relevant equivalence: the grid the optimizer solves on, and the
  // voxels each pseudo-face tags, are IDENTICAL across every solve resolution.
  std::printf(
      "STL-vs-3MF plate_bore equivalence (max vertex diff %.3e mm, vol rel "
      "diff %.3e):\n",
      max_vertex_diff, std::fabs(vb - va) / va);
  std::printf("  %4s | %-12s | %8s | %10s | %s\n", "res", "grid", "solid",
              "solid-diff", "per-face tags identical");
  for (int res : {16, 24, 32, 48, 64}) {
    VoxelGrid gs = voxelize(a.mesh, res);
    VoxelGrid gm = voxelize(b.mesh, res);

    const bool same_dims = gs.nx == gm.nx && gs.ny == gm.ny && gs.nz == gm.nz &&
                           gs.spacing == gm.spacing &&
                           gs.origin.x == gm.origin.x &&
                           gs.origin.y == gm.origin.y && gs.origin.z == gm.origin.z;
    CHECK(same_dims, "voxel grid dims/spacing/origin identical STL vs 3MF");

    const std::set<std::size_t> ss = solid_set(gs);
    const std::set<std::size_t> sm = solid_set(gm);
    CHECK(ss == sm, "the exact solid voxel SET is identical STL vs 3MF");
    std::vector<std::size_t> inter;
    std::set_intersection(ss.begin(), ss.end(), sm.begin(), sm.end(),
                          std::back_inserter(inter));
    const std::size_t solid_diff = (ss.size() + sm.size()) - 2 * inter.size();

    // Face-by-face: tag each pseudo-face on a fresh copy of each grid and require
    // the tagged voxel set to match. (a and b share the identical segmentation,
    // so face id f means the same triangles in both.)
    bool all_faces_match = a.face_count == b.face_count;
    for (int f = 0; all_faces_match && f < a.face_count; ++f) {
      VoxelGrid ts = gs, tm = gm;
      const std::size_t na = tag_mesh_face(ts, a, f, VoxelTag::Fixture);
      const std::size_t nb = tag_mesh_face(tm, b, f, VoxelTag::Fixture);
      if (na != nb) all_faces_match = false;
      if (tag_set(ts, VoxelTag::Fixture) != tag_set(tm, VoxelTag::Fixture))
        all_faces_match = false;
    }
    CHECK(all_faces_match,
          "every pseudo-face tags the identical voxel set STL vs 3MF");

    std::printf("  %4d | %2dx%2dx%2d    | %8zu | %10zu | %s\n", res, gs.nx, gs.ny,
                gs.nz, ss.size(), solid_diff, all_faces_match ? "yes" : "NO");
  }
}

// ---------------------------------------------------------------------------
// B. 3MF end-to-end optimize + full-pipeline byte-identity vs STL.
static JobDescription plate_job(const std::string& model) {
  JobDescription job;
  job.model = model;
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;  // the smallest res that tags this part's r=3 bore.
  job.fixture_faces.push_back(JobFaceSelector{"cylindrical", 3.0});
  job.gravity.direction = Vec3{0.0, 0.0, -1.0};
  job.gravity.magnitude_mm_s2 = 9810.0;
  job.ladder = {0.6, 0.4};
  job.margin_stop = 1.5;
  job.simp_max_iterations = 12;
  job.output.report = "report.json";
  job.output.mesh_format = "stl";
  job.output.mesh_prefix = "variant";
  return job;
}

static std::size_t accepted_count(const RunJobResult& r) {
  std::size_t n = 0;
  for (const MinimizePlasticVariant& v : r.pipeline.evaluated)
    if (v.accepted) ++n;
  return n;
}

static void section_end_to_end() {
  const std::string fixture_dir = mesh_dir();
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string tmp = std::string(CLI_TMP_DIR);

  // --- The 3MF part runs the full §5 pipeline. ------------------------------
  const JobDescription job3mf = plate_job("plate_bore.3mf");
  const RunJobResult r3mf =
      run_job(job3mf, fixture_dir, tmp + "/3mf_job_out1", materials, rules,
              /*emit_progress=*/false, RunObservability{});

  CHECK(r3mf.model.face_count == 7,
        "the 3MF plate segments to 7 pseudo-faces");
  CHECK(r3mf.fixture_face_ids.size() == 1,
        "the cylindrical selector matched exactly the bore on the 3MF part");
  CHECK(!r3mf.pipeline.evaluated.empty(),
        "the ladder evaluated at least one rung on the 3MF part");
  const std::size_t acc3 = accepted_count(r3mf);
  CHECK(acc3 >= 1, "at least one 3MF variant was accepted");
  CHECK(r3mf.mesh_paths.size() == acc3,
        "one exported mesh per accepted 3MF variant");
  for (const std::string& p : r3mf.mesh_paths)
    CHECK(!read_file(p).empty(), "each exported 3MF variant mesh was written");
  CHECK(!read_file(r3mf.report_path).empty(),
        "the 3MF job report.json was written");
  CHECK(r3mf.fields_variant_count == static_cast<int>(acc3),
        "the 3MF fields container carries one block per accepted variant");
  CHECK(!read_file(r3mf.fields_path).empty(), "the 3MF fields.bin was written");
  for (const MinimizePlasticVariant& v : r3mf.pipeline.evaluated) {
    if (!v.accepted) continue;
    CHECK(std::isfinite(v.report.margin.worst_case) &&
              v.report.margin.worst_case > 0.0,
          "an accepted 3MF variant has a finite positive margin");
  }

  // --- Determinism: same 3MF bytes -> byte-identical run. -------------------
  const RunJobResult r3mf2 =
      run_job(job3mf, fixture_dir, tmp + "/3mf_job_out2", materials, rules,
              /*emit_progress=*/false, RunObservability{});
  CHECK(r3mf2.model.triangle_face == r3mf.model.triangle_face,
        "re-running the 3MF job reproduces identical pseudo-face ids");
  CHECK(r3mf2.report_json == r3mf.report_json,
        "re-running the 3MF job reproduces a byte-identical report");
  CHECK(r3mf2.mesh_paths.size() == r3mf.mesh_paths.size(),
        "re-running the 3MF job produces the same number of meshes");
  for (std::size_t i = 0;
       i < r3mf.mesh_paths.size() && i < r3mf2.mesh_paths.size(); ++i)
    CHECK(read_file(r3mf.mesh_paths[i]) == read_file(r3mf2.mesh_paths[i]),
          "re-running the 3MF job produces byte-identical variant meshes");

  // --- Full-pipeline equivalence: the STL and 3MF of the same part optimize
  //     to a BYTE-IDENTICAL result (identical voxel grid + tags -> identical
  //     everything downstream). ------------------------------------------------
  const RunJobResult rstl =
      run_job(plate_job("plate_bore.stl"), fixture_dir, tmp + "/stl_job_out",
              materials, rules, /*emit_progress=*/false, RunObservability{});

  CHECK(rstl.model.face_count == r3mf.model.face_count,
        "STL and 3MF segment to the same pseudo-face count");
  CHECK(rstl.model.triangle_face == r3mf.model.triangle_face,
        "STL and 3MF produce identical pseudo-face ids");
  CHECK(accepted_count(rstl) == acc3,
        "STL and 3MF accept the same number of variants");
  CHECK(rstl.report_json == r3mf.report_json,
        "STL and 3MF of the same part produce a BYTE-IDENTICAL report");
  CHECK(rstl.mesh_paths.size() == r3mf.mesh_paths.size(),
        "STL and 3MF export the same number of variant meshes");
  for (std::size_t i = 0;
       i < rstl.mesh_paths.size() && i < r3mf.mesh_paths.size(); ++i)
    CHECK(read_file(rstl.mesh_paths[i]) == read_file(r3mf.mesh_paths[i]),
          "STL and 3MF export byte-identical variant meshes");

  std::printf(
      "3MF end-to-end: %d pseudo-faces, %zu/%zu variants accepted, report %zu "
      "bytes byte-identical to the STL run\n",
      r3mf.model.face_count, acc3, r3mf.pipeline.evaluated.size(),
      r3mf.report_json.size());
}

int main() {
  section_equivalence();
  section_end_to_end();

  if (g_failures == 0) {
    std::printf("3MF import (enable): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "3MF import (enable): %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
