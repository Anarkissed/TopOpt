// Lattice rebuild: the lattice file job (lattice_layout_file.hpp;
// docs/design/lattice-rebuild/04-layout-file-job.md).
// What is held here: the job's JSON becomes exactly the settings the bridge would make of
// the same values; a part goes in and a whole binary STL comes out with its numbers; and
// every way the job can fail ends in one plain line, a refusal word, the right exit code
// and NO file. Without the Manifold library the job says it cannot, and that is checked.
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>

#include "topopt/lattice_layout_file.hpp"
#include "topopt/stl.hpp"

#ifndef LATTICE_FILE_TMP_DIR
#define LATTICE_FILE_TMP_DIR "."
#endif

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static const std::string kTmp = LATTICE_FILE_TMP_DIR;

static bool exists(const std::string& path) { return static_cast<bool>(std::ifstream(path)); }
static std::size_t bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  return f ? static_cast<std::size_t>(f.tellg()) : 0;
}
static std::string slurp(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
static bool has(const std::string& text, const std::string& part) { return text.find(part) != std::string::npos; }

// A box as an imported model: six flat faces, numbered 0 bottom, 1 top, 2..5 the sides.
static StepModel box_model(double x, double y, double z) {
  StepModel m;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (const int* t : {&q[f][0], &q[f][1]}) {   // (0,1,2) and (0,2,3)
      const int n = static_cast<int>(m.mesh.vertices.size());
      const bool second = t != &q[f][0];
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][second ? 2 : 1]], p[q[f][second ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  m.brep_volume = x * y * z;
  return m;
}

// Lattice under the top face of a 30 x 30 x 12 block, 8 mm deep, pulled 2 mm in from the
// edge (the mesh test's own block): the job a maker's "Lattice region on the top" sends.
static const char* kBlockJob = R"({
  "mode": "lattice_file",
  "model": "block.step",
  "layout": {
    "min_strut_lines": 2,
    "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [8], "region_expand_mm": [-2],
    "region_face_counts": [1], "region_faces": [1],
    "algorithm": "uniform", "cell_max_mm": 8, "min_cells_across": 1
  }
})";

static void test_parse() {
  // Every key, none at its default: each lands in the one field the bridge puts it in.
  const FileJob j = parse_file_job(R"({
    "mode": "lattice_file", "model": "parts/stand.step", "output": "stand_lattice.stl",
    "linear_deflection": 0.05, "threads": 3,
    "layout": {
      "all_lattice": true, "bead_mm": 0.4, "min_strut_lines": 2, "min_wall_mm": 1.5,
      "rim_mm": -1, "cover_mm": 0.8,
      "region_ids": [4, 9], "region_no_lattice": [false, 1], "region_depth_mm": [6, 3],
      "region_expand_mm": [-1.5, 2], "region_face_counts": [2, 1], "region_faces": [12, 13, 20],
      "protect_ids": [2], "protect_depth_mm": [1.2], "protect_face_counts": [3], "protect_faces": [5, 6, 7],
      "topology": "bcc", "algorithm": "stepped", "cell_mm": 5, "cell_max_mm": 10, "cell_min_mm": 2,
      "min_cells_across": 2, "grade_to_shape": true, "band_mm": 4, "band_cell_mm": 2.5,
      "per_region": true, "dial": 0.7, "dial_region": [4], "dial_value": [0.2],
      "strut_width_mm": 0.9, "allow_quilt": true, "strength": -0.5,
      "small_cells_in_thin_walls": true,
      "bars": false, "join_loose": false, "skin": true, "skin_width_mm": 0.6,
      "skin_reach_cells": 1.5, "drop_loose": false
    },
    "mesh": {"pitch_mm": 0.2, "bar_sides": 8, "block_mm": 10, "grow_mm": 0.03, "clean_mm": 0.005,
             "part_mm": 0.007, "fill_under_mm3": 2, "bridge_rise": 0.4, "post_mm": 1.0,
             "layer_mm": 0.16, "pixel_mm": 0.04, "most_passes": 7, "leave_out": false, "keep_if_not_clean": true}
  })");
  CHECK(j.model == "parts/stand.step" && j.output == "stand_lattice.stl");
  CHECK(j.linear_deflection == 0.05 && j.options.threads == 3);
  const Settings& s = j.settings;
  CHECK(s.start == Start::AllLattice && s.bead_mm == 0.4 && s.min_strut_lines == 2.0);
  CHECK(s.min_wall_mm == 1.5 && s.rim_mm == -1.0 && s.cover_mm == 0.8);
  CHECK(s.regions.size() == 2);
  if (s.regions.size() == 2) {
    CHECK(s.regions[0].id == 4 && s.regions[0].role == Role::Lattice && s.regions[0].depth_mm == 6.0 &&
          s.regions[0].expand_mm == -1.5 && s.regions[0].faces == std::vector<int>({12, 13}));
    CHECK(s.regions[1].id == 9 && s.regions[1].role == Role::NoLattice && s.regions[1].depth_mm == 3.0 &&
          s.regions[1].expand_mm == 2.0 && s.regions[1].faces == std::vector<int>({20}));
  }
  CHECK(s.protect.size() == 1);
  if (s.protect.size() == 1)
    CHECK(s.protect[0].id == 2 && s.protect[0].depth_mm == 1.2 && s.protect[0].faces == std::vector<int>({5, 6, 7}));
  CHECK(s.cells.topology == LatticeTopology::Bcc && s.cells.algorithm == Algorithm::Stepped);
  CHECK(s.cells.cell_mm == 5.0 && s.cells.cell_max_mm == 10.0 && s.cells.cell_min_mm == 2.0);
  CHECK(s.cells.min_cells_across == 2 && s.cells.grade_to_shape && s.cells.band_mm == 4.0 &&
        s.cells.band_cell_mm == 2.5);
  CHECK(s.struts.mode == Density::PerRegion && s.struts.dial == 0.7 && s.struts.region_dial.size() == 1);
  if (s.struts.region_dial.size() == 1)
    CHECK(s.struts.region_dial[0].region == 4 && s.struts.region_dial[0].dial == 0.2);
  CHECK(s.struts.width_mm == 0.9 && s.struts.allow_quilt && s.struts.strength == -0.5);
  CHECK(s.small_cells_in_thin_walls);
  CHECK(!s.bars && !s.join_loose && s.skin && s.skin_spec.width_mm == 0.6 && s.skin_spec.reach_cells == 1.5 &&
        !s.drop_loose);
  const FileOptions& o = j.options;
  CHECK(o.pitch_mm == 0.2 && o.mesh.bar_sides == 8 && o.mesh.block_mm == 10.0 && o.mesh.grow_mm == 0.03);
  CHECK(o.mesh.clean_mm == 0.005 && o.mesh.part_mm == 0.007 && o.mesh.fill_under_mm3 == 2.0);
  CHECK(o.mesh.bridge_rise == 0.4 && o.mesh.post_mm == 1.0);
  CHECK(o.layers.layer_mm == 0.16 && o.layers.pixel_mm == 0.04 && o.most_passes == 7 && !o.leave_out && o.keep_if_not_clean);
  {
    const FileOptions d = parse_file_job(R"({"mode": "lattice_file", "model": "a.step"})").options;
    CHECK(d.layers.layer_mm == 0.2 && d.layers.pixel_mm == 0.05 && d.most_passes == 10 && d.leave_out && !d.keep_if_not_clean);
  }

  // Nothing but the two keys it must have: core's own defaults, which are the bridge's.
  const FileJob d = parse_file_job(R"({"mode": "lattice_file", "model": "a.step"})");
  const Settings def;
  CHECK(d.output == "lattice.stl" && d.linear_deflection == 0.0 && d.options.threads == 0);
  CHECK(d.settings.start == Start::AllSolid && d.settings.bead_mm == def.bead_mm &&
        d.settings.min_strut_lines == kMinStrutLines && d.settings.regions.empty() && d.settings.protect.empty());
  CHECK(d.settings.cells.algorithm == Algorithm::DefaultGrade && d.settings.cells.topology == LatticeTopology::Octet &&
        d.settings.cells.cell_max_mm == 8.0 && d.settings.cells.min_cells_across == 1);
  CHECK(d.settings.struts.dial == 0.45 && !d.settings.struts.allow_quilt && !d.settings.small_cells_in_thin_walls);
  CHECK(d.settings.bars && d.settings.join_loose && !d.settings.skin && d.settings.drop_loose);
  CHECK(d.options.pitch_mm == 0.25 && d.options.mesh.bar_sides == 12);

  // What is refused, each with the key it is about.
  const auto refused = [](const char* text, const char* names) {
    try {
      (void)parse_file_job(text);
    } catch (const FileJobError& e) {
      return has(e.what(), names);
    }
    return false;
  };
  CHECK(refused("{", "JSON"));
  CHECK(refused(R"({"model": "a.step"})", "mode"));
  CHECK(refused(R"({"mode": "lattice_variant", "model": "a.step"})", "lattice_file"));
  CHECK(refused(R"({"mode": "lattice_file"})", "model"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "cel_mm": 4})", "cel_mm"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"cel_mm": 4}})", "cel_mm"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "mesh": {"drop_at": []}})", "drop_at"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "output": "../x.stl"})", "output"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "output": "lattice_file.json"})", "output"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"region_ids": [1]}})", "one length"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"region_ids": [1],
      "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
      "region_face_counts": [2], "region_faces": [7]}})", "region_faces"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"protect_ids": [1]}})", "one length"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"dial_region": [1]}})", "dial_region"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"algorithm": "fancy"}})", "algorithm"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"topology": "nope"}})", "topology"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"cell_mm": "4"}})", "cell_mm"));
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "mesh": {"pitch_mm": 0}})", "pitch_mm"));
}

// A refusal: not ok, its word, its exit code, one plain line, and no file.
static void check_refused(const FileResult& r, const char* code, int exit_code, const std::string& path) {
  CHECK(!r.ok);
  CHECK(r.code == code);
  CHECK(r.exit_code == exit_code);
  CHECK(!r.why.empty() && r.why.find('\n') == std::string::npos);
  CHECK(r.file.empty() && r.file_bytes == 0);
  CHECK(!exists(path) && !exists(path + ".part"));
  if (r.code != code) std::printf("  (was %s: %s)\n", r.code.c_str(), r.why.c_str());
}

static void test_make() {
  const FileJob job = parse_file_job(kBlockJob);
  const std::string path = kTmp + "/lattice_file_block.stl";
  std::remove(path.c_str());
  const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
  if (!mesh_available()) {
    check_refused(r, "mesh_unavailable", 3, path);
    return;
  }
  CHECK(r.ok && r.code == "ok" && r.exit_code == 0 && r.why.empty());
  if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
  CHECK(r.faces == 6 && r.part_triangles == 12 && r.open_edges == 0);
  CHECK(r.cells > 0 && r.bars > 0 && r.empty_regions.empty());
  CHECK(r.made.builds >= 1 && r.made.open_boxes > 0);
  CHECK(r.made.mesh.ok && r.made.mesh.triangles > 12);
  // His print rules, measured on the mesh the file holds (P8): the block stands on its whole
  // 30 x 30 face, nothing starts in mid-air, nothing is held at one end only.
  CHECK(r.made.print_clean && r.made.midair_starts == 0 && r.made.layers.one_ended.empty());
  CHECK(std::fabs(r.made.bed_contact_mm2 - 900.0) < 1e-6 && r.made.layers.bed_flat() && r.made.layers.layers == 60);
  CHECK(r.made.found_per_pass.size() == static_cast<std::size_t>(r.made.builds) && r.made.found_per_pass.back() == 0);
  {
    const std::string t = file_result_json(r);
    CHECK(t.find("\"print_check\": {\"bed_contact_mm2\": 900, \"midair_starts\": 0, \"clean\": true") != std::string::npos);
    CHECK(t.find("\"found_per_pass\": [0]") != std::string::npos && t.find("\"posts\": []") != std::string::npos);
  }
  CHECK(r.made.mesh.mm3 > 0.0 && r.made.mesh.mm3 < r.made.mesh.part_mm3 - 100.0);   // lattice was opened in it
  // The file is whole: a binary STL of exactly the mesh's triangles, and it reads back.
  CHECK(r.file == path && exists(path) && !exists(path + ".part"));
  CHECK(r.file_bytes == 84 + 50 * r.made.mesh.triangles && bytes(path) == r.file_bytes);
  if (exists(path)) CHECK(read_stl_file(path).mesh.triangles.size() == r.made.mesh.triangles);
  const std::string text = file_result_json(r);
  CHECK(has(text, "\"ok\": true") && has(text, "\"code\": \"ok\"") && has(text, "\"file\": \"lattice_file_block.stl\""));
  CHECK(has(text, "\"cells\": " + std::to_string(r.cells)) && has(text, "\"triangles\": " + std::to_string(r.made.mesh.triangles)));
  std::printf("block: %zu cells, %zu bars, %zu open boxes; mesh %zu triangles, %.1f of %.1f mm3; %.0f ms\n", r.cells,
              r.bars, r.made.open_boxes, r.made.mesh.triangles, r.made.mesh.mm3, r.made.mesh.part_mm3, r.ms_total);

  // The make step alone, as whoever repeats it will call it: the session's last layout in,
  // the same mesh out.
  {
    Session session(box_model(30, 30, 12));
    const Outcome out = session.lay(job.settings);
    FileReport rep;
    const TriangleMesh mesh = make_file_mesh(session, out, job.options, rep);
    CHECK(rep.mesh.ok && mesh.triangles.size() == r.made.mesh.triangles && rep.open_boxes == r.made.open_boxes);
    std::atomic<bool> stop{true};
    bool threw = false;
    try { (void)make_file_mesh(session, out, job.options, rep, &stop); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
  }
  std::remove(path.c_str());
}

static void test_refusals() {
  const std::string path = kTmp + "/lattice_file_refused.stl";
  std::remove(path.c_str());
  const FileJob job = parse_file_job(kBlockJob);
  {  // nothing in the file at all
    check_refused(make_lattice_file(StepModel{}, job, path), "model_empty", 3, path);
  }
  {  // a region whose faces are not this part's: named by its own number
    FileJob j = job;
    j.settings.regions[0].id = 7;
    j.settings.regions[0].faces = {99};
    const FileResult r = make_lattice_file(box_model(30, 30, 12), j, path);
    check_refused(r, "region_faces_missing", 3, path);
    CHECK(has(r.why, "Region 7 ") && r.empty_regions == std::vector<int>({7}));
  }
  {  // a Protect skin whose faces are not this part's
    FileJob j = job;
    j.settings.protect.push_back({3, {42}, 1.0});
    j.settings.protect.push_back({5, {}, 1.0});
    const FileResult r = make_lattice_file(box_model(30, 30, 12), j, path);
    check_refused(r, "protect_faces_missing", 3, path);
    CHECK(has(r.why, "Protect skins 3 and 5 "));
  }
  {  // a sheet type has no struts to make a file from
    FileJob j = job;
    j.settings.cells.topology = LatticeTopology::Gyroid;
    check_refused(make_lattice_file(box_model(30, 30, 12), j, path), "type_not_supported", 3, path);
  }
  if (!mesh_available()) return;   // from here on the job needs the mesh library to get that far
  {  // a part with a hole in its surface
    StepModel open = box_model(30, 30, 12);
    open.mesh.triangles.pop_back();
    open.triangle_face.pop_back();
    const FileResult r = make_lattice_file(std::move(open), job, path);
    check_refused(r, "part_not_closed", 3, path);
    CHECK(r.open_edges == 3 && has(r.why, "3 open edges"));
  }
  {  // lattice asked for nowhere
    FileJob j = job;
    j.settings.regions.clear();
    check_refused(make_lattice_file(box_model(30, 30, 12), j, path), "no_cells", 3, path);
  }
  {  // cells, but no struts asked for
    FileJob j = job;
    j.settings.bars = false;
    const FileResult r = make_lattice_file(box_model(30, 30, 12), j, path);
    check_refused(r, "no_struts", 3, path);
    CHECK(r.cells > 0 && r.bars == 0);
  }
  {  // stopped
    std::atomic<bool> stop{true};
    check_refused(make_lattice_file(box_model(30, 30, 12), job, path, &stop), "cancelled", 1, path);
  }
  {  // nowhere to save it
    const std::string nowhere = kTmp + "/no_such_folder_for_lattice_file/x.stl";
    check_refused(make_lattice_file(box_model(30, 30, 12), job, nowhere), "cannot_write", 1, nowhere);
  }
}

// The job as the CLI runs it, from files: a job.json beside its model, a result file
// whatever happens. The model is an STL of a 16 mm cube (no OCCT needed to read it):
// all lattice behind a cover on every face.
static void test_run() {
  const std::string model = kTmp + "/lattice_file_cube.stl";
  const std::string job_path = kTmp + "/lattice_file_job.json";
  const std::string stl = kTmp + "/cube_lattice.stl";
  const std::string result = kTmp + "/" + kFileResultName;
  std::remove(stl.c_str());
  std::remove(result.c_str());
  write_stl_file(model, box_model(16, 16, 16).mesh);
  const auto write_job = [&](const std::string& text) {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << text;
  };
  const std::string good = R"({"mode": "lattice_file", "model": "lattice_file_cube.stl", "output": "cube_lattice.stl",
    "layout": {"all_lattice": true, "cover_mm": 1.2, "min_strut_lines": 2, "algorithm": "uniform", "cell_mm": 6.8}})";

  write_job("{ not a job");
  {
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "job_unreadable", 1, stl);
    CHECK(!r.detail.empty() && has(slurp(result), "\"ok\": false") && has(slurp(result), "\"code\": \"job_unreadable\""));
  }
  write_job(R"({"mode": "lattice_file", "model": "no_such_part.stl"})");
  {
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "model_unreadable", 3, kTmp + "/lattice.stl");
    CHECK(has(slurp(result), "\"code\": \"model_unreadable\"") && has(slurp(result), r.why));
  }
  write_job(good);
  {
    const FileResult r = run_file_job(job_path, kTmp, 2);
    if (!mesh_available()) {
      check_refused(r, "mesh_unavailable", 3, stl);
    } else {
      CHECK(r.ok && r.exit_code == 0 && r.file == stl);
      if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
      CHECK(r.cells > 0 && r.bars > 0 && r.made.mesh.sealed_spaces == 1);   // the lattice is sealed in behind the cover
      CHECK(bytes(stl) == 84 + 50 * r.made.mesh.triangles && r.made.mesh.triangles > 12);
      const std::string text = slurp(result);
      CHECK(has(text, "\"ok\": true") && has(text, "\"file\": \"cube_lattice.stl\"") && has(text, "\"why\": \"\""));
      std::printf("cube from a job file: %zu cells, %zu bars; mesh %zu triangles; %.0f ms\n", r.cells, r.bars,
                  r.made.mesh.triangles, r.ms_total);
    }
  }
  for (const std::string& p : {model, job_path, stl, result}) std::remove(p.c_str());
}

// Print rule P8 (f), in the file: a 30 x 12 x 30 block standing up, lattice under its front face 8 mm deep pulled
// 2.6 mm in, the band's finest cells (2 mm, Allow quilt) cut 0.4 mm thick under the solid above the outline (z 27 to
// 27.4). Before the rule that row was opened: its struts were all stubs, the row below's top plane of struts (0.7 mm,
// so up to z 27.35) left an empty layer under the solid. Now the row is solid: the file holds material everywhere
// just under z 27.4, and its print check is clean in one pass.
static void test_thin_slot() {
  if (!mesh_available()) return;
  const FileJob job = parse_file_job(R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 1,
      "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [8], "region_expand_mm": [-2.6],
      "region_face_counts": [1], "region_faces": [2],
      "algorithm": "default_grade", "cell_mm": 8, "min_cells_across": 1, "grade_to_shape": true, "band_mm": 4,
      "strut_width_mm": 0.7, "allow_quilt": true
    }
  })");
  const std::string path = kTmp + "/lattice_file_slot.stl";
  std::remove(path.c_str());
  const FileResult r = make_lattice_file(box_model(30, 12, 30), job, path);
  CHECK(r.ok);
  if (!r.ok) { std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str()); return; }
  // Under the solid, between the row below's struts: material, not an empty layer.
  const PartMeasure file(weld_mesh(read_stl_file(path).mesh));
  const PartMeasure::Probe in = file.probe();
  int empty = 0, asked = 0;
  for (double x = 5.05; x < 25; x += 0.5)
    for (double y = 0.55; y < 7.5; y += 0.5) {
      ++asked;
      empty += !in.inside({x, y, 27.38});
    }
  const LayerReport& l = r.made.layers;
  std::printf("P8 (f) file: %d of %d points empty at z 27.38 under the solid; print check %s, %zu long bridges, "
              "longest reach %.2f mm, %zu one-ended, %zu mid-air, first pass found %d, %zu posts, %zu left out\n",
              empty, asked, r.made.print_clean ? "clean" : "NOT clean", l.long_bridges.size(), l.longest_reach_mm,
              l.one_ended.size(), l.mid_air.size(), r.made.found_per_pass.empty() ? -1 : r.made.found_per_pass.front(),
              r.made.posts.size(), r.made.left_out_at.size());
  CHECK(empty == 0);
  CHECK(r.thin_solid > 0 && has(file_result_json(r), "\"thin_solid\": " + std::to_string(r.thin_solid)));
  CHECK(r.made.print_clean && l.clean() && l.long_bridges.empty());
  CHECK(r.made.found_per_pass.size() == 1 && r.made.found_per_pass.front() == 0 && r.made.posts.empty() &&
        r.made.left_out_at.empty());
  std::remove(path.c_str());
}

// "Let walls cut cells" (his ruling 2026-11-14): the layout key "one_grid" reaches Settings::one_grid, a job with it on
// makes a file, and a misspelt key is still refused as unknown, by its own name.
static void test_one_grid_key() {
  std::string text = kBlockJob;
  const std::string at = "\"min_cells_across\": 1";
  text.replace(text.find(at), at.size(), "\"min_cells_across\": 1, \"one_grid\": true");
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.one_grid && !job.settings.cells.one_grid);
  CHECK(!parse_file_job(kBlockJob).settings.one_grid);   // off unless asked
  bool refused = false;
  try {
    (void)parse_file_job(R"({"mode": "lattice_file", "model": "a.step", "layout": {"one_gird": true}})");
  } catch (const FileJobError& e) {
    refused = has(e.what(), "one_gird");
  }
  CHECK(refused);
  if (!parsed) return;
  const std::string path = kTmp + "/lattice_file_one_grid.stl";
  std::remove(path.c_str());
  const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
  if (!mesh_available()) {
    check_refused(r, "mesh_unavailable", 3, path);
    return;
  }
  CHECK(r.ok && r.code == "ok" && r.cells > 0 && r.bars > 0);
  if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
  CHECK(r.file == path && exists(path) && r.file_bytes == 84 + 50 * r.made.mesh.triangles && bytes(path) == r.file_bytes);
  std::printf("block, one grid: %zu cells, %zu bars; mesh %zu triangles; print clean %d\n", r.cells, r.bars,
              r.made.mesh.triangles, static_cast<int>(r.made.print_clean));
  std::remove(path.c_str());
}

// The writer's strut reach (MeshSpec::strut_reach_mm): the open space is read in 0.25 mm columns, and an opened
// column can reach up to half a column past the lattice's true edge, while a strut is cut exactly there. The block
// of test_thin_slot with its outline at z 28.85 (Expand -1.15): the band's top row of 2 mm cells (z 27 to 29) is cut
// 1.85 mm thick, the strut and more (left open by rule (f)), and the outline lies 0.1 mm past the column boundary at
// 28.75. Every strut the layout ends on that solid is fused into it (0.03 mm short of the solid, on its own line,
// is inside the file), and the file is clean in ONE pass with no post.
static void test_strut_reach() {
  if (!mesh_available()) return;
  FileJob job = parse_file_job(R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 1,
      "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [8], "region_expand_mm": [-1.15],
      "region_face_counts": [1], "region_faces": [2],
      "algorithm": "default_grade", "cell_mm": 8, "min_cells_across": 1, "grade_to_shape": true, "band_mm": 4,
      "strut_width_mm": 0.7, "allow_quilt": true
    }
  })");
  const double edge = 28.85;
  for (const double reach : {-1.0, 0.0}) {
    job.options.mesh.strut_reach_mm = reach;
    Session session(box_model(30, 12, 30));
    const Outcome out = session.lay(job.settings);
    FileReport rep;
    const TriangleMesh mesh = make_file_mesh(session, out, job.options, rep);
    CHECK(rep.mesh.ok);
    if (!rep.mesh.ok) return;
    const PartMeasure file(weld_mesh(mesh));
    const PartMeasure::Probe in = file.probe();
    std::size_t ends = 0, fused = 0;
    for (const Bar& b : out.bars.bars)
      for (int e = 0; e < 2; ++e) {
        if ((e ? b.end_b : b.end_a) != Bar::End::Solid) continue;
        const Vec3 &p = e ? b.b : b.a, &q = e ? b.a : b.b;   // p: the end in the solid; q: the other
        if (!(p.z > edge && q.z < edge)) continue;   // a strut that ends on the solid above the outline
        const Vec3 d{p.x - q.x, p.y - q.y, p.z - q.z};
        const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        const double t = (edge - q.z) / d.z;   // where its line meets the solid
        const Vec3 at{q.x + d.x * t - 0.03 * d.x / len, q.y + d.y * t - 0.03 * d.y / len, q.z + d.z * t - 0.03 * d.z / len};
        if (at.y < 0.05) continue;   // a strut lying in the part's own front face: its line is the mesh's surface
        ++ends;
        fused += in.inside(at);
      }
    std::size_t posts_under = 0;
    for (const MeshSpec::Post& p : rep.posts) posts_under += p.z_top > edge - 1.0;
    std::printf("strut reach %s: %zu of %zu struts ending on the solid fused 0.03 mm short of it; print check %s in %d "
                "passes, first found %d, %zu posts (%zu under the solid), %zu left out, longest reach %.2f mm\n",
                reach < 0 ? "on" : "off", fused, ends, rep.print_clean ? "clean" : "NOT clean", rep.builds,
                rep.found_per_pass.empty() ? -1 : rep.found_per_pass.front(), rep.posts.size(), posts_under,
                rep.left_out_at.size(), rep.layers.longest_reach_mm);
    if (reach == 0.0) continue;   // shown for the comparison only
    CHECK(ends > 0 && fused == ends);
    CHECK(rep.print_clean && rep.builds == 1 && rep.found_per_pass.size() == 1 && rep.found_per_pass.front() == 0 &&
          rep.posts.empty() && rep.left_out_at.empty());
  }
}

// S11b: the file never opens space past the lattice's edge where that edge is against solid. The block of
// test_strut_reach with Finish Skin, its outline at z 28.9 (Expand -1.1): the band's top row of points ends with the
// column from 28.75 to 29.0, whose middle (28.875) is held, so it used to be opened 0.1 mm past the outline. Now no
// point of a 0.02 mm column grid between 28.80 and 28.98 (0.1 mm in x and y) is empty: the slit between the edge's
// bars and the solid is gone. With the step off it is there.
static void test_no_slit_under_solid() {
  if (!mesh_available()) return;
  FileJob job = parse_file_job(R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 1,
      "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [8], "region_expand_mm": [-1.1],
      "region_face_counts": [1], "region_faces": [2],
      "algorithm": "default_grade", "cell_mm": 8, "min_cells_across": 1, "grade_to_shape": true, "band_mm": 4,
      "strut_width_mm": 0.7, "allow_quilt": true, "skin": true
    }
  })");
  int empty[2] = {0, 0}, asked = 0;
  for (int on = 0; on < 2; ++on) {
    Session session(box_model(30, 12, 30));
    const Outcome out = session.lay(job.settings);
    const OpenSpace open = read_open_space(*session.domain(), out.layout, job.options.pitch_mm, 0, nullptr, true, on == 1);
    MeshReport rep;
    const TriangleMesh mesh = build_mesh(session.measure(), *session.domain(), out.layout, out.bars, open, job.options.mesh, &rep);
    CHECK(rep.ok);
    const PartMeasure file(weld_mesh(mesh));
    const PartMeasure::Probe in = file.probe();
    asked = 0;
    for (double x = 5.05; x < 25; x += 0.1)
      for (double y = 0.55; y < 7.5; y += 0.1)
        for (double z = 28.80; z < 28.99; z += 0.02) {
          ++asked;
          empty[on] += !in.inside({x, y, z});
        }
  }
  std::printf("no slit under the solid: %d of %d points between z 28.80 and 28.98 empty with the step off, %d with it on\n",
              empty[0], asked, empty[1]);
  CHECK(empty[1] == 0);
}

// C22, cell size by stress: the layout key "cells_by_stress" reaches CellSpec::by_stress; a job with it on and no stress
// result is refused (no_stress_result, exit 3) before anything is made; with one it makes a file whose layout says
// cells_by_stress. The stress result is the top-level "demand" file of brief A (8 bytes TODEMAND, int32 version 1, int32
// nx, ny, nz, float64 origin x, y, z, float64 spacing, nx*ny*nz float32), written and read back here by a small reader
// of this test's own until the job reads the key itself.
static std::shared_ptr<const DemandField> read_demand(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  char magic[8] = {};
  std::int32_t version = 0, n[3] = {0, 0, 0};
  double o[3] = {0, 0, 0}, spacing = 0;
  f.read(magic, 8);
  f.read(reinterpret_cast<char*>(&version), 4);
  f.read(reinterpret_cast<char*>(n), 12);
  f.read(reinterpret_cast<char*>(o), 24);
  f.read(reinterpret_cast<char*>(&spacing), 8);
  if (!f || std::string(magic, 8) != "TODEMAND" || version != 1) return nullptr;
  auto d = std::make_shared<DemandField>();
  d->origin = {o[0], o[1], o[2]};
  d->spacing = spacing;
  d->nx = n[0]; d->ny = n[1]; d->nz = n[2];
  d->mpa.resize(static_cast<std::size_t>(n[0]) * n[1] * n[2]);
  f.read(reinterpret_cast<char*>(d->mpa.data()), static_cast<std::streamsize>(d->mpa.size() * 4));
  return f ? d : nullptr;
}
static void test_cells_by_stress_key() {
  std::string text = kBlockJob;
  const std::string at = "\"algorithm\": \"uniform\"";
  text.replace(text.find(at), at.size(), "\"algorithm\": \"default_grade\", \"cells_by_stress\": true");
  const std::string lines = "\"min_strut_lines\": 2";   // one line: a ladder of 8 and 4 mm
  text.replace(text.find(lines), lines.size(), "\"min_strut_lines\": 1");
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.cells.by_stress);
  CHECK(!parse_file_job(kBlockJob).settings.cells.by_stress);   // off unless asked
  if (!parsed) return;
  const std::string path = kTmp + "/lattice_file_cells_by_stress.stl";
  std::remove(path.c_str());
  {  // No stress result: refused, in plain words, and nothing made.
    const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
    check_refused(r, "no_stress_result", 3, path);
    CHECK(has(r.why, "stress result"));
    CHECK(has(file_result_json(r), "\"code\": \"no_stress_result\""));
  }
  // A ramp along x over the block, 1 mm voxels: 0 for x < 8, 100 MPa from x = 22.
  const std::string demand_path = kTmp + "/cells_by_stress.demand";
  {
    std::ofstream f(demand_path, std::ios::binary | std::ios::trunc);
    const std::int32_t version = 1, n[3] = {34, 34, 16};
    const double o[3] = {-2, -2, -2}, spacing = 1.0;
    f.write("TODEMAND", 8);
    f.write(reinterpret_cast<const char*>(&version), 4);
    f.write(reinterpret_cast<const char*>(n), 12);
    f.write(reinterpret_cast<const char*>(o), 24);
    f.write(reinterpret_cast<const char*>(&spacing), 8);
    for (int k = 0; k < n[2]; ++k)
      for (int j = 0; j < n[1]; ++j)
        for (int i = 0; i < n[0]; ++i) {
          const double x = o[0] + i + 0.5;
          const float v = static_cast<float>(100.0 * std::min(1.0, std::max(0.0, (x - 8.0) / 14.0)));
          f.write(reinterpret_cast<const char*>(&v), 4);
        }
  }
  job.settings.stress.demand = read_demand(demand_path);
  job.settings.stress.reference_mpa = 100.0;
  std::remove(demand_path.c_str());
  CHECK(job.settings.stress.demand && !job.settings.stress.demand->empty());
  if (!job.settings.stress.demand) return;
  const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
  if (!mesh_available()) {
    check_refused(r, "mesh_unavailable", 3, path);
    return;
  }
  CHECK(r.ok && r.code == "ok" && r.cells > 0 && r.cells_by_stress);
  if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
  CHECK(has(file_result_json(r), "\"cells_by_stress\": true"));
  FileJob plain = job;
  plain.settings.cells.by_stress = false;
  const FileResult p = make_lattice_file(box_model(30, 30, 12), plain, path);
  CHECK(p.ok && !p.cells_by_stress && p.cells < r.cells);
  CHECK(has(file_result_json(p), "\"cells_by_stress\": false"));
  std::printf("block, cells by stress: %zu cells (%zu with it off); print clean %d\n", r.cells, p.cells,
              static_cast<int>(r.made.print_clean));
  std::remove(path.c_str());
}

int main() {
  test_cells_by_stress_key();
  test_no_slit_under_solid();
  test_strut_reach();
  test_thin_slot();
  test_parse();
  test_make();
  test_refusals();
  test_run();
  test_one_grid_key();
  if (!mesh_available()) std::printf("no mesh library in this build: the job says so\n");
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
