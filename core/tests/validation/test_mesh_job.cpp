// test_mesh_job.cpp — the mesh-optimize path (handoff 2026-07-24).
//
// Closes the import loop: a MESH part (STL/3MF) must run the SAME §5 pipeline a
// STEP part does. run_job's front door was STEP-locked (import_step_file);
// import_part_file now dispatches on the extension so an STL/3MF part imports,
// segments into pseudo-faces, voxelizes, tags, runs the ladder, and reports —
// structurally identical to a STEP job.
//
// Three claims, three sections, all OCCT-gated (the ground truth is a B-rep):
//
//   A. STEP byte-identity at the front door. import_part_file(<step>) must
//      return the IDENTICAL StepModel import_step_file(<step>) does — same mesh,
//      same triangle_face, same faces, same volume — so dispatching by format
//      did not perturb the STEP path by a single value. (The end-to-end STEP
//      byte-identity of the whole run is additionally locked by cli_demo /
//      production_parity, which were untouched.)
//
//   B. STEP-vs-mesh equivalence THROUGH voxelization and tagging. Export the
//      demo L-bracket STEP to STL (exactly what a user does exporting a mesh
//      from CAD), re-import via the mesh path, and require: the voxel grid
//      (dims, spacing, origin, and the exact solid set) equal within
//      voxelization, and the fixture voxels tagged from the mesh's pseudo-faces
//      equal the set tagged from the B-rep's faces — across several resolutions.
//      This extends segment_vs_step (which proved FACE STRUCTURE equivalence)
//      the rest of the way to the grid the optimizer actually solves on.
//
//   C. End-to-end mesh job. Run run_job() in-process on the committed small STL
//      fixture (a plate with a central bore) and require a finalized report with
//      accepted variants, exported meshes, and a fields container — the same
//      shape a STEP job produces. Determinism: same STL bytes -> identical
//      report + meshes + pseudo-face ids, twice-run.
//
// Self-contained CHECK harness (ARCHITECTURE §4), like the other tests.

#include "topopt/job.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/part.hpp"
#include "topopt/settings.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

// The solid-occupancy set of a grid: the flat indices of every non-Empty voxel.
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

static std::vector<int> cylinder_faces(const StepModel& m) {
  std::vector<int> v;
  for (int f = 0; f < m.face_count; ++f)
    if (m.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Cylinder)
      v.push_back(f);
  return v;
}

// ---------------------------------------------------------------------------
// A. STEP byte-identity at the front door.
static void section_step_identity() {
  const std::string step_path = std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step";
  const StepModel direct = import_step_file(step_path);
  const StepModel viaadapter = import_part_file(step_path);

  CHECK(viaadapter.face_count == direct.face_count,
        "adapter STEP import: same face_count as import_step_file");
  CHECK(viaadapter.solid_count == direct.solid_count,
        "adapter STEP import: same solid_count");
  CHECK(viaadapter.brep_volume == direct.brep_volume,
        "adapter STEP import: identical brep_volume (bit for bit)");
  CHECK(viaadapter.mesh.vertices.size() == direct.mesh.vertices.size() &&
            viaadapter.mesh.triangles.size() == direct.mesh.triangles.size(),
        "adapter STEP import: same tessellation size");
  CHECK(viaadapter.triangle_face == direct.triangle_face,
        "adapter STEP import: identical triangle_face");

  bool verts_equal = viaadapter.mesh.vertices.size() == direct.mesh.vertices.size();
  for (std::size_t i = 0; verts_equal && i < direct.mesh.vertices.size(); ++i) {
    const Vec3& a = direct.mesh.vertices[i];
    const Vec3& b = viaadapter.mesh.vertices[i];
    if (a.x != b.x || a.y != b.y || a.z != b.z) verts_equal = false;
  }
  CHECK(verts_equal, "adapter STEP import: identical vertex coordinates");

  bool tris_equal = viaadapter.mesh.triangles == direct.mesh.triangles;
  CHECK(tris_equal, "adapter STEP import: identical triangle indices");

  bool faces_equal = viaadapter.faces.size() == direct.faces.size();
  for (std::size_t i = 0; faces_equal && i < direct.faces.size(); ++i) {
    const StepFaceInfo& a = direct.faces[i];
    const StepFaceInfo& b = viaadapter.faces[i];
    if (a.kind != b.kind || a.cylinder_radius_mm != b.cylinder_radius_mm)
      faces_equal = false;
  }
  CHECK(faces_equal, "adapter STEP import: identical per-face kind + radius");
}

// ---------------------------------------------------------------------------
// B. STEP-vs-mesh equivalence through voxelization and tagging.
static void section_equivalence() {
  const std::string step_path = std::string(DEMO_FIXTURE_DIR) + "/l-bracket.step";
  const std::string stl_path =
      std::string(SEGMENT_TMP_DIR) + "/mesh_job_lbracket.stl";

  const StepModel step = import_step_file(step_path);
  write_stl_file(stl_path, step.mesh, StlFormat::Binary);
  const PartModel part = import_part(stl_path);
  const StepModel& mesh = part.model;

  CHECK(part.pseudo_faces, "the STL round-trip reports manufactured faces");

  // The equivalence table across resolutions (printed for the evidence file).
  std::printf("MESH-VS-STEP l-bracket equivalence (STEP export -> STL -> mesh path):\n");
  std::printf("  %4s | %-14s | %8s | %10s | %8s %8s %6s\n", "res", "grid",
              "solid", "solid-diff", "tag(step)", "tag(mesh)", "jacc");
  for (int res : {16, 24, 32, 48, 64}) {
    VoxelGrid gs = voxelize(step.mesh, res);
    VoxelGrid gm = voxelize(mesh.mesh, res);

    const bool same_dims =
        gs.nx == gm.nx && gs.ny == gm.ny && gs.nz == gm.nz &&
        gs.spacing == gm.spacing && gs.origin.x == gm.origin.x &&
        gs.origin.y == gm.origin.y && gs.origin.z == gm.origin.z;
    CHECK(same_dims, "voxel grid dims/spacing/origin identical STEP vs mesh");

    const std::set<std::size_t> ss = solid_set(gs);
    const std::set<std::size_t> sm = solid_set(gm);
    CHECK(ss == sm, "the exact solid voxel SET is identical STEP vs mesh");
    std::vector<std::size_t> sinter;
    std::set_intersection(ss.begin(), ss.end(), sm.begin(), sm.end(),
                          std::back_inserter(sinter));
    const std::size_t solid_diff =
        (ss.size() + sm.size()) - 2 * sinter.size();

    // Tag the bores (fixture) from each source and compare the voxel sets.
    std::size_t ts = 0, tm = 0;
    for (int f : cylinder_faces(step))
      ts += tag_step_face(gs, step, f, VoxelTag::Fixture);
    for (int f : cylinder_faces(mesh))
      tm += tag_mesh_face(gm, mesh, f, VoxelTag::Fixture);
    const std::set<std::size_t> fs = tag_set(gs, VoxelTag::Fixture);
    const std::set<std::size_t> fm = tag_set(gm, VoxelTag::Fixture);
    std::vector<std::size_t> finter;
    std::set_intersection(fs.begin(), fs.end(), fm.begin(), fm.end(),
                          std::back_inserter(finter));
    const double jacc =
        fs.empty() && fm.empty()
            ? 1.0
            : static_cast<double>(finter.size()) /
                  static_cast<double>(fs.size() + fm.size() - finter.size());

    std::printf("  %4d | %2dx%2dx%2d      | %8zu | %10zu | %8zu %8zu %6.3f\n",
                res, gs.nx, gs.ny, gs.nz, ss.size(), solid_diff, ts, tm, jacc);

    CHECK(ts == tm, "same number of fixture voxels tagged STEP vs mesh");
    CHECK(fs == fm, "the exact fixture voxel SET is identical STEP vs mesh");
    // Every bore that has any tessellation resolution to speak of must actually
    // tag material at a real solve resolution (48 is the demo's).
    if (res >= 48) CHECK(tm > 0, "the bore tags material at solve resolution");
  }
  std::remove(stl_path.c_str());
}

// ---------------------------------------------------------------------------
// C. End-to-end mesh job through run_job.
static JobDescription mesh_job(const std::string& model) {
  JobDescription job;
  job.model = model;
  job.material = "PLA";
  job.mode = "minimize_plastic";
  job.resolution = 32;  // res 24 aliases the r=3 bore off the grid (tags 0);
                        // 32 is the smallest that tags the bore for this part.
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

static void section_end_to_end() {
  const std::string fixture_dir = std::string(MESH_FIXTURE_DIR);
  const std::string stl_name = "plate_bore.stl";
  const MaterialLibrary materials = load_materials_file(MATERIALS_JSON_PATH);
  const SettingsRules rules = load_settings_rules_file(SETTINGS_RULES_PATH);

  const std::string out1 = std::string(CLI_TMP_DIR) + "/mesh_job_out1";
  const std::string out2 = std::string(CLI_TMP_DIR) + "/mesh_job_out2";

  const JobDescription job = mesh_job(stl_name);
  const RunJobResult r1 =
      run_job(job, fixture_dir, out1, materials, rules, /*emit_progress=*/false,
              RunObservability{});

  // The mesh imported as pseudo-faces (7: top, bottom, bore, four sides), and
  // the bore selector matched material.
  CHECK(r1.model.face_count == 7, "the plate mesh segments to 7 pseudo-faces");
  CHECK(r1.fixture_face_ids.size() == 1,
        "the cylindrical selector matched exactly the bore");

  // A finalized run: variants evaluated, at least one accepted, a mesh per
  // accepted variant, a report, and the fields container — the SAME shape a
  // STEP job produces.
  CHECK(!r1.pipeline.evaluated.empty(), "the ladder evaluated at least one rung");
  std::size_t accepted = 0;
  for (const MinimizePlasticVariant& v : r1.pipeline.evaluated)
    if (v.accepted) ++accepted;
  CHECK(accepted >= 1, "at least one variant was accepted");
  CHECK(r1.mesh_paths.size() == accepted,
        "one exported mesh per accepted variant");
  for (const std::string& p : r1.mesh_paths)
    CHECK(!read_file(p).empty(), "each exported variant mesh was written");
  CHECK(!read_file(r1.report_path).empty(), "the report.json was written");
  CHECK(r1.fields_variant_count == static_cast<int>(accepted),
        "the fields container carries one block per accepted variant");
  CHECK(!read_file(r1.fields_path).empty(), "the fields.bin was written");

  // Every accepted variant has a real, finite margin (its analysis ran) — a
  // mesh part reaches the gate exactly as a STEP part does.
  for (const MinimizePlasticVariant& v : r1.pipeline.evaluated) {
    if (!v.accepted) continue;
    CHECK(std::isfinite(v.report.margin.worst_case) &&
              v.report.margin.worst_case > 0.0,
          "an accepted mesh-job variant has a finite positive margin");
  }

  // Determinism: same STL bytes -> identical report + meshes + pseudo-face ids.
  const RunJobResult r2 =
      run_job(job, fixture_dir, out2, materials, rules, /*emit_progress=*/false,
              RunObservability{});
  CHECK(r2.model.triangle_face == r1.model.triangle_face,
        "re-running reproduces identical pseudo-face ids");
  CHECK(r2.report_json == r1.report_json,
        "re-running reproduces a byte-identical report");
  CHECK(r2.mesh_paths.size() == r1.mesh_paths.size(),
        "re-running produces the same number of meshes");
  for (std::size_t i = 0;
       i < r1.mesh_paths.size() && i < r2.mesh_paths.size(); ++i)
    CHECK(read_file(r1.mesh_paths[i]) == read_file(r2.mesh_paths[i]),
          "re-running produces byte-identical variant meshes");
}

int main() {
  section_step_identity();
  section_equivalence();
  section_end_to_end();

  if (g_failures == 0) {
    std::printf("mesh job: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "mesh job: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
