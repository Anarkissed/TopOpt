// Lattice rebuild: the lattice file job (lattice_layout_file.hpp;
// docs/design/lattice-rebuild/04-layout-file-job.md).
// What is held here: the job's JSON becomes exactly the settings the bridge would make of
// the same values; a part goes in and a whole binary STL comes out with its numbers; and
// every way the job can fail ends in one plain line, a refusal word, the right exit code
// and NO file. Without the Manifold library the job says it cannot, and that is checked.
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <thread>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <vector>
#include <fstream>
#include <sstream>
#include <string>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/stl.hpp"
#include "topopt/threemf_stream.hpp"

#ifdef TOPOPT_HAVE_ZLIB
#include <zlib.h>
#endif

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
  // D23: protect_chip marks which Protect entries are chips' answers; absent, none is.
  {
    const FileJob c = parse_file_job(R"({"mode": "lattice_file", "model": "a.step", "layout": {
        "protect_ids": [1, 2], "protect_depth_mm": [1, 0], "protect_face_counts": [1, 1], "protect_faces": [3, 4],
        "protect_chip": [0, 1]}})");
    CHECK(c.settings.protect.size() == 2 && !c.settings.protect[0].chip && c.settings.protect[1].chip);
    const FileJob d = parse_file_job(R"({"mode": "lattice_file", "model": "a.step", "layout": {
        "protect_ids": [1], "protect_depth_mm": [1], "protect_face_counts": [1], "protect_faces": [3]}})");
    CHECK(d.settings.protect.size() == 1 && !d.settings.protect[0].chip);
  }
  CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"protect_ids": [1], "protect_depth_mm": [1],
      "protect_face_counts": [1], "protect_faces": [3], "protect_chip": [1, 0]}})", "protect_chip"));
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

// Install 2a, step 3: By stress in the file job (R16 to R18; 04-layout-file-job.md). The demand file round-trips and
// a bad one is refused with its reason; the keys land where Settings keeps them; By stress with no stress result is
// refused; and a made file's struts are wider at the hot end than at the cold end by the layout's own widths.
static void test_by_stress_file() {
  const std::string dpath = kTmp + "/lattice_file_demand.bin";
  DemandField f;
  f.origin = {-1.5, 2.25, 0.0};
  f.spacing = 0.75;
  f.nx = 3; f.ny = 4; f.nz = 5;
  for (int n = 0; n < 60; ++n) f.mpa.push_back(static_cast<float>(n * 1.25 - 7.0));
  CHECK(write_demand_file(dpath, f));
  CHECK(bytes(dpath) == 56 + 4 * 60);
  {
    DemandField g;
    std::string why;
    CHECK(read_demand_file(dpath, g, &why) && why.empty());
    CHECK(g.nx == 3 && g.ny == 4 && g.nz == 5 && g.spacing == 0.75 && g.origin.x == -1.5 && g.origin.y == 2.25 &&
          g.origin.z == 0.0 && g.mpa == f.mpa);
  }
  CHECK(!write_demand_file(dpath + ".x", DemandField{}));
  {  // Each fault refused, with its reason; the field given is left as it was.
    const std::string good = slurp(dpath);
    const auto refused = [&](std::string bad, const char* words) {
      const std::string p = kTmp + "/lattice_file_demand_bad.bin";
      { std::ofstream o(p, std::ios::binary | std::ios::trunc); o << bad; }
      DemandField g;
      g.nx = 9;
      std::string why;
      const bool ok = read_demand_file(p, g, &why);
      std::remove(p.c_str());
      if (ok || !has(why, words)) std::printf("  (demand file: \"%s\", wanted \"%s\")\n", why.c_str(), words);
      return !ok && has(why, words) && g.nx == 9;
    };
    std::string s = good;
    s[0] = 'X';
    CHECK(refused(s, "TODEMAND"));
    s = good;
    s[8] = 2;
    CHECK(refused(s, "version 2"));
    CHECK(refused(good.substr(0, good.size() - 4), "bytes"));
    CHECK(refused(good + "x", "bytes"));
    CHECK(refused(good.substr(0, 30), "cut short"));
    s = good;
    s[12] = 0;   // nx 0
    CHECK(refused(s, "no voxels"));
    s = good;
    const float nan = std::nanf("");
    std::memcpy(&s[56 + 4 * 7], &nan, 4);
    CHECK(refused(s, "not a finite number"));
    s = good;
    const double inf = HUGE_VAL;
    std::memcpy(&s[48], &inf, 8);
    CHECK(refused(s, "voxel size"));
    s = good;
    std::memcpy(&s[32], &inf, 8);
    CHECK(refused(s, "corner"));
    DemandField g;
    std::string why;
    CHECK(!read_demand_file(kTmp + "/no_such_demand.bin", g, &why) && !why.empty());
  }
  // The keys.
  {
    const FileJob j = parse_file_job(R"({"mode": "lattice_file", "model": "a.step", "demand": "stress.bin",
      "layout": {"by_stress": true, "dial_light": 0.1, "dial_heavy": 0.7, "width_light_mm": 0.6, "width_heavy_mm": 1.1,
                 "reference_mpa": 80, "percentile": 0.9, "response": 2}})");
    CHECK(j.demand == "stress.bin" && j.settings.struts.mode == Density::ByStress);
    CHECK(j.settings.struts.dial_light == 0.1 && j.settings.struts.dial_heavy == 0.7 &&
          j.settings.struts.width_light_mm == 0.6 && j.settings.struts.width_heavy_mm == 1.1);
    CHECK(j.settings.stress.reference_mpa == 80.0 && j.settings.stress.percentile == 0.9 &&
          j.settings.stress.response == 2.0 && !j.settings.stress.demand);
    const FileJob d = parse_file_job(R"({"mode": "lattice_file", "model": "a.step"})");
    CHECK(d.demand.empty() && d.settings.struts.mode == Density::Uniform);
    const auto refused = [](const char* text, const char* names) {
      try { (void)parse_file_job(text); } catch (const FileJobError& e) { return has(e.what(), names); }
      return false;
    };
    CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "layout": {"by_stress": true, "per_region": true}})",
                  "per_region"));
    CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "demand": "../s.bin"})", "demand"));
    CHECK(refused(R"({"mode": "lattice_file", "model": "a.step", "demand": ""})", "demand"));
  }
  // By stress with no stress result: refused, never made at the light end (R18).
  const std::string path = kTmp + "/lattice_file_stress.stl";
  std::remove(path.c_str());
  std::string text = kBlockJob;
  {
    const std::string at = "\"min_cells_across\": 1";
    text.replace(text.find(at), at.size(),
                 "\"min_cells_across\": 1, \"cell_mm\": 8, \"by_stress\": true, \"width_light_mm\": 0.9, "
                 "\"width_heavy_mm\": 1.3, \"reference_mpa\": 100");
  }
  FileJob job = parse_file_job(text);
  {
    const FileResult r = make_lattice_file(box_model(60, 30, 12), job, path);
    check_refused(r, "no_stress_result", 3, path);
    CHECK(has(r.why, "By stress needs a stress result"));
    CHECK(has(file_result_json(r), "\"code\": \"no_stress_result\""));
    FileJob zero = job;   // a field with no stress anywhere gives no reference either
    zero.settings.stress.reference_mpa = 0.0;
    auto none = std::make_shared<DemandField>(f);
    for (float& v : none->mpa) v = 0.0f;
    zero.settings.stress.demand = none;
    if (mesh_available()) check_refused(make_lattice_file(box_model(60, 30, 12), zero, path), "no_stress_result", 3, path);
  }
  {  // From files: a job that names a stress result that is not one.
    const std::string job_path = kTmp + "/lattice_file_stress_job.json";
    const std::string bad = kTmp + "/lattice_file_bad_demand.bin";
    { std::ofstream o(bad, std::ios::binary | std::ios::trunc); o << "not a stress result"; }
    { std::ofstream o(job_path, std::ios::binary | std::ios::trunc);
      o << R"({"mode": "lattice_file", "model": "no_such_part.stl", "demand": "lattice_file_bad_demand.bin",
               "layout": {"by_stress": true}})"; }
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "demand_unreadable", 1, kTmp + "/lattice.stl");
    CHECK(has(r.detail, "TODEMAND") && has(slurp(kTmp + "/" + kFileResultName), "\"code\": \"demand_unreadable\""));
    for (const std::string& p : {job_path, bad, kTmp + "/" + std::string(kFileResultName)}) std::remove(p.c_str());
  }
  std::remove(dpath.c_str());
  if (!mesh_available()) return;
  // Made: a 60 x 30 x 12 block, lattice under its top face, 8 mm cells; the stress 0 for x under 30, 200 MPa from 30 on
  // (reference 100): the cold cells at 0.9 mm, the hot ones at 1.3 mm. Read back from the file it wrote: across each
  // strut's flats at its middle (the narrowest chord square to its line), the hot struts are wider by 0.4 mm +- 0.01.
  DemandField hot;
  hot.spacing = 1.0;
  hot.nx = 60; hot.ny = 30; hot.nz = 12;
  for (int k = 0; k < 12; ++k)
    for (int j = 0; j < 30; ++j)
      for (int i = 0; i < 60; ++i) hot.mpa.push_back(i >= 30 ? 200.0f : 0.0f);
  CHECK(write_demand_file(dpath, hot));
  auto field = std::make_shared<DemandField>();
  CHECK(read_demand_file(dpath, *field));
  std::remove(dpath.c_str());
  job.settings.stress.demand = field;
  const FileResult r = make_lattice_file(box_model(60, 30, 12), job, path);
  CHECK(r.ok && r.by_stress && r.reference_mpa == 100.0 && r.highest_mpa == 200.0 && r.at_light > 0 && r.at_heavy > 0 &&
        r.at_light + r.at_heavy == r.cells);
  if (!r.ok) { std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str()); return; }
  CHECK(has(file_result_json(r), "\"by_stress\": true, \"reference_mpa\": 100, \"highest_mpa\": 200, \"at_light\": " +
                                     std::to_string(r.at_light) + ", \"at_heavy\": " + std::to_string(r.at_heavy) + "}"));
  Session session(box_model(60, 30, 12));
  const Outcome out = session.lay(job.settings);
  CHECK(out.layout.cells.size() == r.cells && out.bars.bars.size() == r.bars);
  const PartMeasure file(weld_mesh(read_stl_file(path).mesh));
  const PartMeasure::Probe in = file.probe();
  std::vector<double> got[2];
  int off_width = 0;
  for (const Bar& b : out.bars.bars) {
    if (b.piece || b.skin || bar_is_bridge(b) || b.end_a != Bar::End::Node || b.end_b != Bar::End::Node) continue;
    const int side = std::max(b.a.x, b.b.x) < 20.0 ? 0 : std::min(b.a.x, b.b.x) > 40.0 ? 1 : -1;
    if (side < 0) continue;
    if (std::fabs(b.width - (side ? 1.3 : 0.9)) > 1e-12) ++off_width;
    const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
    const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    d = {d.x / len, d.y / len, d.z / len};
    // Two directions square to the strut.
    Vec3 e1 = std::fabs(d.x) < 0.9 ? Vec3{0, -d.z, d.y} : Vec3{-d.z, 0, d.x};
    const double l1 = std::sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z);
    e1 = {e1.x / l1, e1.y / l1, e1.z / l1};
    const Vec3 e2{d.y * e1.z - d.z * e1.y, d.z * e1.x - d.x * e1.z, d.x * e1.y - d.y * e1.x};
    if (in.depth(m) <= 0.0) continue;
    double narrowest = 1e9;
    for (int a = 0; a < 360; ++a) {
      const double t = 3.14159265358979323846 * a / 360.0;
      const Vec3 dir{std::cos(t) * e1.x + std::sin(t) * e2.x, std::cos(t) * e1.y + std::sin(t) * e2.y,
                     std::cos(t) * e1.z + std::sin(t) * e2.z};
      narrowest = std::min(narrowest, in.wall_width(m, dir));
    }
    got[side].push_back(narrowest);
  }
  CHECK(off_width == 0 && got[0].size() >= 4 && got[1].size() >= 4);
  if (got[0].empty() || got[1].empty()) return;
  for (auto& g : got) std::sort(g.begin(), g.end());
  const double cold = got[0][got[0].size() / 2], warm = got[1][got[1].size() / 2];
  std::printf("by stress, the made file: %zu cold struts %.4f mm across the flats (%.4f .. %.4f), %zu hot struts %.4f mm "
              "(%.4f .. %.4f): wider by %.4f, the layout's widths by 0.4\n", got[0].size(), cold, got[0].front(),
              got[0].back(), got[1].size(), warm, got[1].front(), got[1].back(), warm - cold);
  CHECK(std::fabs((warm - cold) - 0.4) <= 0.01);
  std::remove(path.c_str());
}

// C22, cell size by stress: the layout key "cells_by_stress" reaches CellSpec::by_stress; a job with it on and no stress
// result is refused (no_stress_result, exit 3) before anything is made; with one it makes a file whose layout says
// cells_by_stress. The stress result is the job's own demand file (write_demand_file, read_demand_file).
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
    DemandField f;
    f.origin = {-2, -2, -2};
    f.spacing = 1.0;
    f.nx = 34; f.ny = 34; f.nz = 16;
    for (int k = 0; k < f.nz; ++k)
      for (int j = 0; j < f.ny; ++j)
        for (int i = 0; i < f.nx; ++i)
          f.mpa.push_back(static_cast<float>(100.0 * std::min(1.0, std::max(0.0, (i - 1.5 - 8.0) / 14.0))));
    CHECK(write_demand_file(demand_path, f));
  }
  {
    auto read = std::make_shared<DemandField>();
    if (read_demand_file(demand_path, *read)) job.settings.stress.demand = read;
  }
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

// C23, R19: a region's own cells and struts, "region_own" (one entry per region: null, or the part's own key names).
static void test_region_own_key() {
  const std::string head = R"({"mode": "lattice_file", "model": "block.step", "layout": {
    "min_strut_lines": 1,
    "region_ids": [1, 2], "region_no_lattice": [0, 0], "region_depth_mm": [6, 6], "region_expand_mm": [0, 0],
    "region_face_counts": [1, 1], "region_faces": [1, 0], "cell_max_mm": 6, "dial": 0.3)";
  const std::string own = R"(, "region_own": [{"algorithm": "stepped", "cell_mm": 4, "cell_max_mm": 5, "cell_min_mm": 1.5,
    "min_cells_across": 1, "grade_to_shape": true, "band_mm": 4, "band_cell_mm": 1.6, "cells_by_stress": false,
    "by_stress": false, "dial": 0.8, "dial_light": 0.1, "dial_heavy": 0.9, "strut_width_mm": 0.7, "width_light_mm": 0.5,
    "width_heavy_mm": 0.9, "strength": 0.5, "response": 2, "reference_mpa": 40}, null]}})";
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(head + own); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.regions.size() == 2);
  if (!parsed || job.settings.regions.size() != 2) return;
  const AreaOwn& a = job.settings.regions[0].own;
  CHECK(a.algorithm == Algorithm::Stepped && a.cell_mm == 4.0 && a.cell_max_mm == 5.0 && a.cell_min_mm == 1.5);
  CHECK(a.min_cells_across == 1 && a.grade_to_shape == true && a.band_mm == 4.0 && a.band_cell_mm == 1.6);
  CHECK(a.cells_by_stress == false && a.by_stress == false && a.dial == 0.8 && a.dial_light == 0.1 && a.dial_heavy == 0.9);
  CHECK(a.width_mm == 0.7 && a.width_light_mm == 0.5 && a.width_heavy_mm == 0.9 && a.strength == 0.5);
  CHECK(a.response == 2.0 && a.reference_mpa == 40.0);
  CHECK(!job.settings.regions[1].own.any());
  CHECK(!parse_file_job(head + "}}").settings.regions[0].own.any());   // nothing stated unless asked
  // The same layout as the Settings made directly.
  Settings direct = parse_file_job(head + "}}").settings;
  direct.regions[0].own = a;
  const Outcome x = Session(box_model(30, 30, 12)).lay(job.settings), y = Session(box_model(30, 30, 12)).lay(direct);
  const Outcome plain = Session(box_model(30, 30, 12)).lay(parse_file_job(head + "}}").settings);
  CHECK(!x.layout.cells.empty() && x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid);
  CHECK(x.bars.bars.size() == y.bars.bars.size());
  CHECK(!(x.layout.cells == plain.layout.cells));
  // An unknown key, a list of the wrong length, or an entry that is not an object refuses the job.
  const auto refused = [&](const std::string& tail, const char* names) {
    try { (void)parse_file_job(head + tail); } catch (const FileJobError& e) { return has(e.what(), names); }
    return false;
  };
  CHECK(refused(R"(, "region_own": [{"cell_mn": 4}, null]}})", "cell_mn"));
  CHECK(refused(R"(, "region_own": [{"topology": "octet"}, null]}})", "topology"));   // part only
  CHECK(refused(R"(, "region_own": [null]}})", "region_own"));
  CHECK(refused(R"(, "region_own": [4, null]}})", "region_own"));
  // A region By stress with no stress result: refused, as the part's is (R18).
  const FileJob stress = parse_file_job(head + R"(, "region_own": [{"by_stress": true}, null]}})");
  const std::string path = kTmp + "/lattice_file_region_own.stl";
  std::remove(path.c_str());
  check_refused(make_lattice_file(box_model(30, 30, 12), stress, path), "no_stress_result", 3, path);
  std::printf("region own: %zu cells with region 1's own settings, %zu without\n", x.layout.cells.size(),
              plain.layout.cells.size());
}

// D21: a region's zone in place of its faces (`region_zones`, one entry per region: null, or the zone). Both kinds
// read into the same Settings as made directly, and lay the same layout; bad numbers refuse the job.
static void test_zones_key() {
  const char* job_text = R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 2,
      "region_ids": [1, 2, 3], "region_no_lattice": [0, 0, 1], "region_depth_mm": [8, 0, 0],
      "region_expand_mm": [-2, 0.5, 0], "region_face_counts": [1, 0, 0], "region_faces": [1],
      "region_zones": [null,
        {"kind": "box", "centre": [15, 15, 6], "axes": [[0.8, 0.6, 0], [-0.6, 0.8, 0], [0, 0, 1]], "half_mm": [9, 9, 3]},
        {"kind": "cylinder", "centre": [15, 15, 6], "axis": [0, 0, 1], "radius_mm": 2.5, "half_length_mm": 6}],
      "algorithm": "uniform", "cell_max_mm": 8, "min_cells_across": 1
    }
  })";
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(job_text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.regions.size() == 3);
  if (!parsed || job.settings.regions.size() != 3) return;
  Settings direct;
  direct.min_strut_lines = 2;
  direct.cells.algorithm = Algorithm::Uniform;
  direct.cells.cell_max_mm = 8;
  direct.cells.min_cells_across = 1;
  direct.regions.resize(3);
  direct.regions[0].id = 1; direct.regions[0].faces = {1}; direct.regions[0].depth_mm = 8; direct.regions[0].expand_mm = -2;
  direct.regions[1].id = 2; direct.regions[1].expand_mm = 0.5;
  direct.regions[1].zone.kind = Zone::Kind::Box;
  direct.regions[1].zone.centre = {15, 15, 6};
  direct.regions[1].zone.axis[0] = {0.8, 0.6, 0};
  direct.regions[1].zone.axis[1] = {-0.6, 0.8, 0};
  direct.regions[1].zone.axis[2] = {0, 0, 1};
  direct.regions[1].zone.half[0] = 9; direct.regions[1].zone.half[1] = 9; direct.regions[1].zone.half[2] = 3;
  direct.regions[2].id = 3; direct.regions[2].role = Role::NoLattice;
  direct.regions[2].zone.kind = Zone::Kind::Cylinder;
  direct.regions[2].zone.centre = {15, 15, 6};
  direct.regions[2].zone.axis[2] = {0, 0, 1};
  direct.regions[2].zone.half[0] = 2.5; direct.regions[2].zone.half[2] = 6;
  int differ = 0;
  for (std::size_t r = 0; r < 3; ++r) {
    const Zone &a = job.settings.regions[r].zone, &b = direct.regions[r].zone;
    differ += a.kind != b.kind || a.centre.x != b.centre.x || a.centre.y != b.centre.y || a.centre.z != b.centre.z;
    for (int k = 0; k < 3; ++k)
      differ += a.axis[k].x != b.axis[k].x || a.axis[k].y != b.axis[k].y || a.axis[k].z != b.axis[k].z ||
                a.half[k] != b.half[k];
    differ += job.settings.regions[r].faces != direct.regions[r].faces;
  }
  CHECK(differ == 0);
  const Outcome from_job = Session(box_model(30, 30, 12)).lay(job.settings);
  const Outcome made = Session(box_model(30, 30, 12)).lay(direct);
  CHECK(from_job.empty_regions.empty() && !from_job.layout.cells.empty());
  CHECK(from_job.layout.cells == made.layout.cells && from_job.layout.solid == made.layout.solid);
  bool zone2 = false;
  for (const Cell& c : from_job.layout.cells) zone2 = zone2 || c.region == 2;
  CHECK(zone2);

  // Bad numbers, and a region with faces and a zone, refuse the job, naming the key.
  const auto refused = [](const std::string& zone, const char* counts, const char* names) {
    const std::string text = std::string(R"({"mode": "lattice_file", "model": "a.step", "layout": {"region_ids": [1],
      "region_no_lattice": [0], "region_depth_mm": [0], "region_expand_mm": [0], "region_face_counts": [)") + counts +
      R"(], "region_faces": [)" + (counts[0] == '1' ? "4" : "") + R"(], "region_zones": [)" + zone + "]}}";
    try {
      (void)parse_file_job(text);
    } catch (const FileJobError& e) {
      return has(e.what(), names);
    }
    return false;
  };
  const std::string box = R"({"kind": "box", "centre": [1, 2, 3], "axes": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "half_mm": [2, 2, 2]})";
  CHECK(!refused(box, "0", "region_zones"));   // the good one parses
  CHECK(refused(R"({"kind": "box", "centre": [1, 2, 3], "axes": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "half_mm": [2, 0, 2]})",
                "0", "half sizes above 0"));
  CHECK(refused(R"({"kind": "box", "centre": [1, 2, 3], "axes": [[1, 0, 0], [0.6, 0.8, 0], [0, 0, 1]], "half_mm": [2, 2, 2]})",
                "0", "right angles"));
  CHECK(refused(R"({"kind": "cylinder", "centre": [1, 2, 3], "axis": [0, 0, 2], "radius_mm": 1, "half_length_mm": 2})",
                "0", "unit axis"));
  CHECK(refused(R"({"kind": "cylinder", "centre": [1, 2, 3], "axis": [0, 0, 1], "radius_mm": -1, "half_length_mm": 2})",
                "0", "above 0"));
  CHECK(refused(R"({"kind": "sphere", "centre": [1, 2, 3]})", "0", "sphere"));
  CHECK(refused(R"({"kind": "box", "centre": [1, 2], "axes": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "half_mm": [2, 2, 2]})",
                "0", "centre"));
  CHECK(refused(R"({"kind": "box", "centre": [1, 2, 3], "axes": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "half_mm": [2, 2, 2], "radius_mm": 1})",
                "0", "radius_mm"));
  CHECK(refused(box, "1", "faces and a zone"));
  CHECK(refused(box + ", null", "0", "region_zones"));   // not one per region

  // The file job does not take a zone's missing faces for faces the part does not have.
  const std::string path = kTmp + "/lattice_file_zone.stl";
  std::remove(path.c_str());
  FileJob only = job;
  only.settings.regions = {job.settings.regions[1]};
  const FileResult r = make_lattice_file(box_model(30, 30, 12), only, path);
  CHECK(r.code != "region_faces_missing" && r.empty_regions.empty());
  if (mesh_available()) {
    CHECK(r.ok && r.cells > 0 && r.bars > 0);
    if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
  }
  std::remove(path.c_str());
}

// S13 in the file job: a region may carry its own Finish in "region_finish" (null = the part's). The keys land in the
// region's RegionAsk and lay exactly what the same Settings made directly lay; an unknown key, or a list of the wrong
// length, refuses the job by name. A made file with region A (the top) covered and region B (the front) not is closed
// over A's face and open over B's; with A's Finish left to the part's (none), A's face is open too.
static void test_area_finish_file() {
  const std::string text = R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 2,
      "region_ids": [1, 2], "region_no_lattice": [0, 0], "region_depth_mm": [8, 6], "region_expand_mm": [-2, -2],
      "region_face_counts": [1, 1], "region_faces": [1, 2],
      "region_finish": [{"rim_mm": 0, "cover_mm": 1.2, "skin": true, "skin_width_mm": 0.9, "skin_reach_cells": 1.0}, null],
      "algorithm": "uniform", "cell_max_mm": 8, "min_cells_across": 1
    }
  })";
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed);
  if (!parsed) return;
  const Settings::RegionAsk &a = job.settings.regions[0], &b = job.settings.regions[1];
  CHECK(a.rim_mm && *a.rim_mm == 0.0 && a.cover_mm && *a.cover_mm == 1.2 && a.skin && *a.skin &&
        a.skin_width_mm && *a.skin_width_mm == 0.9 && a.skin_reach_cells && *a.skin_reach_cells == 1.0);
  CHECK(!b.rim_mm && !b.cover_mm && !b.skin && !b.skin_width_mm && !b.skin_reach_cells);
  {  // The same Settings, made directly.
    Settings direct;
    direct.min_strut_lines = 2;
    direct.regions = {{1, Role::Lattice, {1}, 8.0, -2.0}, {2, Role::Lattice, {2}, 6.0, -2.0}};
    direct.regions[0].rim_mm = 0.0;
    direct.regions[0].cover_mm = 1.2;
    direct.regions[0].skin = true;
    direct.regions[0].skin_width_mm = 0.9;
    direct.regions[0].skin_reach_cells = 1.0;
    direct.cells.algorithm = Algorithm::Uniform;
    direct.cells.cell_max_mm = 8;
    direct.cells.min_cells_across = 1;
    const Outcome x = Session(box_model(30, 30, 12)).lay(job.settings), y = Session(box_model(30, 30, 12)).lay(direct);
    bool same = x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid &&
                x.bars.bars.size() == y.bars.bars.size() && !x.bars.bars.empty();
    for (std::size_t i = 0; same && i < x.bars.bars.size(); ++i) {
      const Bar &p = x.bars.bars[i], &q = y.bars.bars[i];
      same = p.a.x == q.a.x && p.a.y == q.a.y && p.a.z == q.a.z && p.b.x == q.b.x && p.b.y == q.b.y &&
             p.b.z == q.b.z && p.width == q.width && p.end_a == q.end_a && p.end_b == q.end_b && p.skin == q.skin;
    }
    CHECK(same);
  }
  for (const char* bad : {R"([{"cover": 1.2}, null])", R"([null])"}) {
    std::string t = text;
    const std::size_t from = t.find("[{\"rim_mm\""), to = t.find("null]") + 5;
    t.replace(from, to - from, bad);
    bool refused = false;
    try { (void)parse_file_job(t); } catch (const FileJobError& e) { refused = has(e.what(), "region_finish"); }
    CHECK(refused);
  }
  if (!mesh_available()) return;
  // Points a quarter of a millimetre inside each face, over the middle of its region (A's away from where B's reaches).
  auto empty_under = [](const std::string& path, int face) {
    const PartMeasure file(weld_mesh(read_stl_file(path).mesh));
    const PartMeasure::Probe in = file.probe();
    int empty = 0;
    for (double u = 4.1; u < 26; u += 0.25)
      for (double v = (face == 1 ? 10.1 : 3.1); v < (face == 1 ? 26 : 9); v += 0.25)
        empty += !in.inside(face == 1 ? Vec3{u, v, 12 - 0.25} : Vec3{u, 0.25, v});
    return empty;
  };
  const std::string path = kTmp + "/lattice_file_area_finish.stl";
  int covered[2] = {0, 0}, open[2] = {0, 0};
  for (int own = 1; own >= 0; --own) {
    FileJob j = job;
    if (!own) j.settings.regions[0] = Settings::RegionAsk{1, Role::Lattice, {1}, 8.0, -2.0, {}, {}, {}, {}, {}};
    std::remove(path.c_str());
    const FileResult r = make_lattice_file(box_model(30, 30, 12), j, path);
    CHECK(r.ok && r.cells > 0 && r.bars > 0);
    if (!r.ok) { std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str()); return; }
    covered[own] = empty_under(path, 1);
    open[own] = empty_under(path, 2);
  }
  std::printf("area finish file: A covered %d empty points under its face (%d with the part's Finish); B %d empty "
              "points under its face (%d)\n", covered[1], covered[0], open[1], open[0]);
  CHECK(covered[1] == 0 && covered[0] > 100);   // closed over A's face; open there without its own cover
  CHECK(open[1] > 100 && open[0] > 100);        // open over B's face either way
  std::remove(path.c_str());
}

// D22 in the file job: "region_pieces" and "protect_pieces", one entry per region / Protect skin: null, or its pieces
// (with pieces its faces are not read: the bridge may send the parent faces as well). They read into the same Settings
// as made directly and lay the same layout; bad numbers or a wrong length refuse the job naming the key; pieces that
// leave no surface are refused as faces the part does not have. A made file with a Protect skin on the left half of
// the top (x <= 15) over lattice under the whole top is closed over that half and open over the other.
static void test_pieces_key() {
  const std::string text = R"({
    "mode": "lattice_file", "model": "block.step",
    "layout": {
      "min_strut_lines": 2,
      "region_ids": [1, 2], "region_no_lattice": [0, 1], "region_depth_mm": [8, 3], "region_expand_mm": [0, 0],
      "region_face_counts": [1, 1], "region_faces": [1, 2],
      "region_pieces": [null, [{"faces": [2], "cuts": [{"point": [20, 0, 0], "normal": [1, 0, 0], "strict": true}]}]],
      "protect_ids": [7], "protect_depth_mm": [1.2], "protect_face_counts": [1], "protect_faces": [1],
      "protect_pieces": [[{"faces": [1], "cuts": [{"point": [15, 0, 0], "normal": [-1, 0, 0]}]}]],
      "algorithm": "uniform", "cell_max_mm": 8, "min_cells_across": 1
    }
  })";
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.regions.size() == 2 && job.settings.protect.size() == 1);
  if (!parsed || job.settings.regions.size() != 2 || job.settings.protect.size() != 1) return;
  Settings direct;
  direct.min_strut_lines = 2;
  direct.cells.algorithm = Algorithm::Uniform;
  direct.cells.cell_max_mm = 8;
  direct.cells.min_cells_across = 1;
  direct.regions = {{1, Role::Lattice, {1}, 8.0, 0.0}, {2, Role::NoLattice, {2}, 3.0, 0.0}};
  direct.regions[1].pieces = {FacePiece{{2}, {FaceCut{{20, 0, 0}, {1, 0, 0}, true}}}};
  direct.protect = {{7, {1}, 1.2, {FacePiece{{1}, {FaceCut{{15, 0, 0}, {-1, 0, 0}, false}}}}}};
  auto same_pieces = [](const std::vector<FacePiece>& a, const std::vector<FacePiece>& b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
      if (a[i].faces != b[i].faces || a[i].cuts.size() != b[i].cuts.size()) return false;
      for (std::size_t k = 0; k < a[i].cuts.size(); ++k) {
        const FaceCut &p = a[i].cuts[k], &q = b[i].cuts[k];
        if (p.point.x != q.point.x || p.point.y != q.point.y || p.point.z != q.point.z || p.normal.x != q.normal.x ||
            p.normal.y != q.normal.y || p.normal.z != q.normal.z || p.strict != q.strict)
          return false;
      }
    }
    return true;
  };
  CHECK(job.settings.regions[0].pieces.empty() && same_pieces(job.settings.regions[1].pieces, direct.regions[1].pieces));
  CHECK(same_pieces(job.settings.protect[0].pieces, direct.protect[0].pieces));
  const Outcome from_job = Session(box_model(30, 30, 12)).lay(job.settings);
  const Outcome made = Session(box_model(30, 30, 12)).lay(direct);
  CHECK(from_job.empty_regions.empty() && !from_job.layout.cells.empty());
  CHECK(from_job.layout.cells == made.layout.cells && from_job.layout.solid == made.layout.solid);

  // Bad numbers, a wrong length, pieces with a zone: refused, naming the key.
  const auto refused = [&](const char* from, const char* to, const char* names) {
    std::string t = text;
    const std::size_t at = t.find(from);
    if (at == std::string::npos) return false;
    t.replace(at, std::strlen(from), to);
    try {
      (void)parse_file_job(t);
    } catch (const FileJobError& e) {
      return has(e.what(), names);
    }
    return false;
  };
  CHECK(refused(R"("normal": [1, 0, 0])", R"("normal": [0, 0, 0])", "region_pieces"));
  CHECK(refused(R"("point": [20, 0, 0])", R"("point": [20, 0])", "region_pieces"));
  CHECK(refused(R"("strict": true)", R"("strict": true, "plane": 1)", "plane"));
  CHECK(refused(R"([null, [{"faces")", R"([[{"faces")", "region_pieces"));   // not one per region
  CHECK(refused(R"([null, [{"faces")", R"([[], [{"faces")", "region_pieces"));   // an empty list
  CHECK(refused(R"("normal": [-1, 0, 0])", R"("normal": [0, 0, 0])", "protect_pieces"));
  CHECK(refused(R"("protect_pieces": [[)", R"("protect_pieces": [null, [)", "protect_pieces"));
  CHECK(refused(R"("region_face_counts": [1, 1], "region_faces": [1, 2],)",
                R"("region_face_counts": [1, 0], "region_faces": [1], "region_zones": [null, {"kind": "box",
                   "centre": [15, 15, 6], "axes": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "half_mm": [3, 3, 3]}],)",
                "pieces and a zone"));

  const std::string path = kTmp + "/lattice_file_pieces.stl";
  {  // Pieces that leave nothing: refused before anything is made, as faces the part does not have.
    FileJob none = job;
    none.settings.regions[1].pieces[0].cuts[0].point.x = 100;
    std::remove(path.c_str());
    const FileResult r = make_lattice_file(box_model(30, 30, 12), none, path);
    CHECK(r.code == "region_faces_missing" && (r.empty_regions == std::vector<int>{2}) && !exists(path));
    none = job;
    none.settings.protect[0].pieces[0].faces = {42};
    const FileResult s = make_lattice_file(box_model(30, 30, 12), none, path);
    CHECK(s.code == "protect_faces_missing" && !exists(path));
  }
  if (!mesh_available()) return;
  std::remove(path.c_str());
  const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
  CHECK(r.ok && r.cells > 0 && r.bars > 0);
  if (!r.ok) { std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str()); return; }
  // Points a quarter of a millimetre under the top, over each half (clear of the cut and of region 2).
  const PartMeasure file(weld_mesh(read_stl_file(path).mesh));
  const PartMeasure::Probe in = file.probe();
  int skinned = 0, open = 0;
  for (double v = 8.1; v < 26; v += 0.25)
    for (double u = 1.1; u < 13; u += 0.25) {
      skinned += !in.inside(Vec3{u, v, 12 - 0.25});
      open += !in.inside(Vec3{u + 16, v, 12 - 0.25});
    }
  std::printf("pieces file: %d empty points under the skinned half of the top, %d under the other half\n", skinned, open);
  CHECK(skinned == 0 && open > 100);
  std::remove(path.c_str());
}

// C24, the largest size step between neighbouring cells: the layout key "max_step" reaches CellSpec::max_step, and a
// region's own in "region_own"; the file's layout reports step_held_at (1.5 on Default Grade is held at 2; 0 when none
// was asked).
static void test_max_step_key() {
  std::string text = kBlockJob;
  const std::string at = "\"algorithm\": \"uniform\"";
  text.replace(text.find(at), at.size(), "\"algorithm\": \"default_grade\", \"max_step\": 1.5");
  FileJob job;
  bool parsed = true;
  try { job = parse_file_job(text); } catch (const FileJobError& e) { parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(parsed && job.settings.cells.max_step == 1.5);
  CHECK(parse_file_job(kBlockJob).settings.cells.max_step == 0.0);   // none unless asked
  std::string own = text;
  const std::string tail = "\"min_cells_across\": 1";
  own.replace(own.find(tail), tail.size(), "\"min_cells_across\": 1, \"region_own\": [{\"max_step\": 3}]");
  bool own_parsed = true;
  FileJob oj;
  try { oj = parse_file_job(own); } catch (const FileJobError& e) { own_parsed = false; std::printf("  (%s)\n", e.what()); }
  CHECK(own_parsed && oj.settings.regions.size() == 1 && oj.settings.regions[0].own.max_step == 3.0);
  if (!parsed) return;
  const std::string path = kTmp + "/lattice_file_max_step.stl";
  std::remove(path.c_str());
  const FileResult r = make_lattice_file(box_model(30, 30, 12), job, path);
  if (!mesh_available()) {
    check_refused(r, "mesh_unavailable", 3, path);
    return;
  }
  CHECK(r.ok && r.cells > 0 && r.step_held_at == 2.0);
  CHECK(has(file_result_json(r), "\"step_held_at\": 2,"));
  FileJob plain = job;
  plain.settings.cells.max_step = 0.0;
  const FileResult p = make_lattice_file(box_model(30, 30, 12), plain, path);
  CHECK(p.ok && p.step_held_at == 0.0 && has(file_result_json(p), "\"step_held_at\": 0,"));
  std::printf("block, max_step 1.5: held at %g, %zu cells (%zu with none)\n", r.step_held_at, r.cells, p.cells);
  std::remove(path.c_str());
}

// ── ORGANIC, TRACED, THROUGH THE FILE JOB (S1c) ──────────────────────────────
// The tensor file (TOTENSOR): it round-trips, and each fault is refused with its reason. The job's keys: region_weave,
// tensor, organic_spacing_mm, organic_width_mm. A job that names a tensor file that is not one: tensor_unreadable.
static void test_tensor_file() {
  const std::string tpath = kTmp + "/lattice_file_tensor.bin";
  TensorField f;
  f.origin = {-1.5, 2.25, 0.5};
  f.spacing = 0.75;
  f.nx = 3; f.ny = 4; f.nz = 5;
  for (int n = 0; n < 6 * 60; ++n) f.voigt.push_back(n * 0.25 - 30.0);   // each a float32 exactly
  CHECK(write_tensor_file(tpath, f));
  CHECK(bytes(tpath) == 56 + 24 * 60);
  {
    TensorField g;
    std::string why;
    CHECK(read_tensor_file(tpath, g, &why) && why.empty());
    CHECK(g.nx == 3 && g.ny == 4 && g.nz == 5 && g.spacing == 0.75 && g.origin.x == -1.5 && g.origin.y == 2.25 &&
          g.origin.z == 0.5 && g.voigt == f.voigt);
    // The order within a voxel is TensorField's: voxel (i 1, j 2, k 3)'s xy is the 4th of its six.
    CHECK(g.voigt[6 * g.index(1, 2, 3) + 3] == f.voigt[6 * ((3 * 4 + 2) * 3 + 1) + 3]);
  }
  CHECK(!write_tensor_file(tpath + ".x", TensorField{}));
  {  // Each fault refused, with its reason; the field given is left as it was.
    const std::string good = slurp(tpath);
    const auto refused = [&](std::string bad, const char* words) {
      const std::string p = kTmp + "/lattice_file_tensor_bad.bin";
      { std::ofstream o(p, std::ios::binary | std::ios::trunc); o << bad; }
      TensorField g;
      g.nx = 9;
      std::string why;
      const bool ok = read_tensor_file(p, g, &why);
      std::remove(p.c_str());
      if (ok || !has(why, words)) std::printf("  (tensor file: \"%s\", wanted \"%s\")\n", why.c_str(), words);
      return !ok && has(why, words) && g.nx == 9;
    };
    std::string s = good;
    s[0] = 'X';
    CHECK(refused(s, "TOTENSOR"));
    CHECK(refused(slurp(tpath).replace(0, 8, "TODEMAND"), "TOTENSOR"));   // a demand file is not a tensor file
    s = good;
    s[8] = 2;
    CHECK(refused(s, "version 2"));
    CHECK(refused(good.substr(0, good.size() - 4), "bytes"));
    CHECK(refused(good + "x", "bytes"));
    CHECK(refused(good.substr(0, 30), "cut short"));
    s = good;
    s[16] = 0;   // ny 0
    CHECK(refused(s, "no voxels"));
    s = good;
    const float nan = std::nanf("");
    std::memcpy(&s[56 + 4 * 13], &nan, 4);
    CHECK(refused(s, "not a finite number (voxel 2)"));
    s = good;
    const double inf = HUGE_VAL;
    std::memcpy(&s[48], &inf, 8);
    CHECK(refused(s, "voxel size"));
    s = good;
    std::memcpy(&s[24], &inf, 8);
    CHECK(refused(s, "corner"));
    TensorField g;
    std::string why;
    CHECK(!read_tensor_file(kTmp + "/no_such_tensor.bin", g, &why) && !why.empty());
  }
  // The keys.
  {
    const FileJob j = parse_file_job(R"({"mode": "lattice_file", "model": "a.step", "tensor": "stress.tensor",
      "layout": {"region_ids": [3, 4], "region_no_lattice": [0, 0], "region_depth_mm": [4, 4], "region_expand_mm": [0, 0],
                 "region_face_counts": [1, 1], "region_faces": [1, 2], "region_weave": [true, 0],
                 "organic_spacing_mm": 4.5, "organic_width_mm": 1.2}})");
    CHECK(j.tensor == "stress.tensor" && !j.tensor_field);
    CHECK(j.settings.regions.size() == 2 && j.settings.regions[0].weave && !j.settings.regions[1].weave);
    CHECK(j.organic.spacing_mm == 4.5 && j.organic.width_mm == 1.2);
    const FileJob d = parse_file_job(R"({"mode": "lattice_file", "model": "a.step",
      "layout": {"region_ids": [3], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1]}})");
    CHECK(d.tensor.empty() && !d.settings.regions[0].weave && d.organic.spacing_mm == 0.0 && d.organic.width_mm == 0.0);
    const auto refused = [](const std::string& layout, const char* names, const char* top = "") {
      const std::string text = std::string(R"({"mode": "lattice_file", "model": "a.step", )") + top +
                               R"("layout": {"region_ids": [3], "region_no_lattice": [0], "region_depth_mm": [4],
                               "region_expand_mm": [0], "region_face_counts": [1], "region_faces": [1])" + layout + "}}";
      try { (void)parse_file_job(text); } catch (const FileJobError& e) {
        if (!has(e.what(), names)) std::printf("  (refused for \"%s\", wanted %s)\n", e.what(), names);
        return has(e.what(), names);
      }
      std::printf("  (not refused: %s)\n", layout.c_str());
      return false;
    };
    CHECK(refused(R"(, "region_weave": [true, false], "organic_spacing_mm": 4)", "region_weave"));   // wrong length
    CHECK(refused(R"(, "region_weave": [], "organic_spacing_mm": 4)", "region_weave"));
    CHECK(refused(R"(, "region_weave": [2], "organic_spacing_mm": 4)", "region_weave"));
    CHECK(refused(R"(, "region_weave": [true])", "organic_spacing_mm"));                             // no spacing
    CHECK(refused(R"(, "region_weave": [true], "organic_spacing_mm": 0)", "organic_spacing_mm"));
    CHECK(refused(R"(, "region_weave": [true], "organic_spacing_mm": -4)", "organic_spacing_mm"));
    CHECK(refused(R"(, "region_weave": [true], "organic_spacing_mm": "4")", "organic_spacing_mm"));
    CHECK(refused(R"(, "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": -1)", "organic_width_mm"));
    // Under the thinnest strut (0.45 x 2 = 0.9 mm at the defaults).
    CHECK(refused(R"(, "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0.6)", "organic_width_mm"));
    CHECK(refused(R"(, "organic_spacing_mm": 0)", "organic_spacing_mm"));
    CHECK(refused("", "tensor", R"("tensor": "../t.bin", )"));
    CHECK(refused("", "tensor", R"("tensor": "", )"));
  }
  {  // From files: a job that names a tensor file that is not one.
    const std::string job_path = kTmp + "/lattice_file_tensor_job.json";
    const std::string bad = kTmp + "/lattice_file_bad_tensor.bin";
    { std::ofstream o(bad, std::ios::binary | std::ios::trunc); o << "not a tensor file"; }
    { std::ofstream o(job_path, std::ios::binary | std::ios::trunc);
      o << R"({"mode": "lattice_file", "model": "no_such_part.stl", "tensor": "lattice_file_bad_tensor.bin"})"; }
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "tensor_unreadable", 1, kTmp + "/lattice.stl");
    CHECK(has(r.detail, "TOTENSOR") && has(slurp(kTmp + "/" + kFileResultName), "\"code\": \"tensor_unreadable\""));
    for (const std::string& p : {job_path, bad, kTmp + "/" + std::string(kFileResultName)}) std::remove(p.c_str());
  }
  std::remove(tpath.c_str());
}

// Stage 1b's made-up curved pocket (test_organic_traced.cpp, C): a 40 x 14 x 20 block with a half-round pocket
// (radius 6, axis (20, 14) along z) in its top edge, the weave region 4 mm deep under the pocket's wall; the made-up
// stress runs round the pocket (10 MPa round its axis, 3 along it, 1 across the wall).
static TriangleMesh prism_poly(const std::vector<std::array<double, 2>>& xy, double z0, double z1) {
  const int n = static_cast<int>(xy.size());
  auto turn = [&](int a, int b, int c) {
    return (xy[b][0] - xy[a][0]) * (xy[c][1] - xy[a][1]) - (xy[b][1] - xy[a][1]) * (xy[c][0] - xy[a][0]);
  };
  std::vector<int> left(n);
  for (int i = 0; i < n; ++i) left[i] = i;
  std::vector<std::array<int, 3>> tris;
  while (left.size() > 3) {
    bool cut = false;
    const int m = static_cast<int>(left.size());
    for (int i = 0; i < m && !cut; ++i) {
      const int a = left[(i + m - 1) % m], b = left[i], c = left[(i + 1) % m];
      if (turn(a, b, c) <= 1e-12) continue;
      bool empty = true;
      for (int k : left)
        if (k != a && k != b && k != c && turn(a, b, k) >= -1e-12 && turn(b, c, k) >= -1e-12 && turn(c, a, k) >= -1e-12) empty = false;
      if (!empty) continue;
      tris.push_back({a, b, c});
      left.erase(left.begin() + i);
      cut = true;
    }
    if (!cut) return {};
  }
  tris.push_back({left[0], left[1], left[2]});
  MeshSink s;
  auto P = [&](int i, double z) { return Vec3{xy[i % n][0], xy[i % n][1], z}; };
  for (const auto& t : tris) {
    s.add_triangle(P(t[0], z1), P(t[1], z1), P(t[2], z1));
    s.add_triangle(P(t[0], z0), P(t[2], z0), P(t[1], z0));
  }
  for (int i = 0; i < n; ++i) {
    s.add_triangle(P(i, z0), P(i + 1, z0), P(i + 1, z1));
    s.add_triangle(P(i, z0), P(i + 1, z1), P(i, z1));
  }
  return s.mesh;
}
static TriangleMesh pocket_mesh() {
  const double H = 14.0, cx = 20.0, R = 6.0;
  std::vector<std::array<double, 2>> xy = {{0, 0}, {40, 0}, {40, H}, {cx + R, H}};
  const int N = 48;
  for (int i = 1; i < N; ++i) {
    const double t = 3.14159265358979323846 * i / N;
    xy.push_back({cx + R * std::cos(t), H - R * std::sin(t)});
  }
  xy.push_back({cx - R, H});
  xy.push_back({0, H});
  return prism_poly(xy, 0, 20);
}
static bool on_pocket_wall(const TriangleMesh& m, const std::array<int, 3>& t) {
  bool all = true, level = true;
  for (int c = 0; c < 3; ++c) {
    const Vec3& v = m.vertices[static_cast<std::size_t>(t[c])];
    all = all && std::fabs(std::hypot(v.x - 20.0, v.y - 14.0) - 6.0) < 1e-4 && v.y < 14.0 + 1e-9;
    level = level && v.z == m.vertices[static_cast<std::size_t>(t[0])].z;
  }
  return all && !level;
}
static TensorField hoop_field() {
  TensorField f;
  f.spacing = 0.5;
  f.nx = 80; f.ny = 28; f.nz = 40;
  f.voigt.assign(6 * static_cast<std::size_t>(f.nx) * f.ny * f.nz, 0.0);
  for (int k = 0; k < f.nz; ++k)
    for (int j = 0; j < f.ny; ++j)
      for (int i = 0; i < f.nx; ++i) {
        const double x = (i + 0.5) * f.spacing - 20.0, y = (j + 0.5) * f.spacing - 14.0, r = std::hypot(x, y);
        if (!(r > 1e-9)) continue;
        const double rx = x / r, ry = y / r, tx = -ry, ty = rx;
        double* v = &f.voigt[6 * f.index(i, j, k)];
        v[0] = 10 * tx * tx + rx * rx;
        v[1] = 10 * ty * ty + ry * ry;
        v[2] = 3.0;
        v[3] = 10 * tx * ty + rx * ry;
      }
  return f;
}
// The mesh as a slicer reads it: corners at one place are one corner; its shells, its edges not used exactly twice.
static std::pair<std::size_t, std::size_t> shells_and_open(const TriangleMesh& m) {
  std::map<std::array<double, 3>, int> at;
  std::vector<int> id(m.vertices.size());
  for (std::size_t v = 0; v < m.vertices.size(); ++v)
    id[v] = at.emplace(std::array<double, 3>{m.vertices[v].x, m.vertices[v].y, m.vertices[v].z}, static_cast<int>(at.size())).first->second;
  std::vector<int> up(at.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = static_cast<int>(i);
  auto find = [&](int v) { while (up[static_cast<std::size_t>(v)] != v) v = up[static_cast<std::size_t>(v)] = up[static_cast<std::size_t>(up[static_cast<std::size_t>(v)])]; return v; };
  std::map<std::pair<int, int>, int> way;
  for (const auto& t : m.triangles) {
    const int c[3] = {id[static_cast<std::size_t>(t[0])], id[static_cast<std::size_t>(t[1])], id[static_cast<std::size_t>(t[2])]};
    for (int q = 0; q < 3; ++q) {
      ++way[{c[q], c[(q + 1) % 3]}];
      up[static_cast<std::size_t>(find(c[q]))] = find(c[0]);
    }
  }
  std::size_t open = 0;
  for (const auto& kv : way) {
    const auto back = way.find({kv.first.second, kv.first.first});
    if (kv.second != 1 || back == way.end() || back->second != 1) ++open;
  }
  std::map<int, int> roots;
  for (const auto& t : m.triangles) ++roots[find(id[static_cast<std::size_t>(t[0])])];
  return {roots.size(), open};
}

// 2, 3: the pocket as a job: the part an STL with the pocket's wall painted as its own face (the face sidecar), the
// weave region on it, the tensor file beside the job. The CLI's job makes the file; the weave bars it reports are the
// bars lay_organic gives directly; the file is one body, open between its struts. Then the refusals of a weave job.
static void test_organic_job() {
  const std::string model_path = kTmp + "/lattice_file_pocket.stl";
  const std::string tensor_path = kTmp + "/lattice_file_pocket.tensor";
  const std::string job_path = kTmp + "/lattice_file_pocket_job.json";
  const std::string stl = kTmp + "/pocket_lattice.stl";
  const std::string result = kTmp + "/" + kFileResultName;
  std::remove(stl.c_str());
  write_stl_file(model_path, pocket_mesh());
  int wall = -1;
  {
    std::remove(face_overrides_sidecar_path(model_path).c_str());
    const StepModel plain = import_part_file_resolved(model_path);
    FaceOverrides ov;
    ov.paint_faces.emplace_back();
    for (std::size_t t = 0; t < plain.mesh.triangles.size(); ++t)
      if (on_pocket_wall(plain.mesh, plain.mesh.triangles[t])) ov.paint_faces.back().push_back(static_cast<int>(t));
    CHECK(ov.paint_faces.back().size() == 2 * 48);
    save_face_overrides(face_overrides_sidecar_path(model_path), ov);
    wall = plain.face_count;
  }
  CHECK(write_tensor_file(tensor_path, hoop_field()));
  const auto write_job = [&](const std::string& top, const std::string& layout) {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << R"({"mode": "lattice_file", "model": "lattice_file_pocket.stl", "output": "pocket_lattice.stl", )" << top
      << R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                "region_face_counts": [1], "region_faces": [)" << wall << "]" << layout << "}}";
  };
  const std::string weave = R"(, "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0.9)";
  // 3: a weave with no stress tensor: refused (OR14), nothing made.
  write_job("", weave);
  {
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "no_stress_result", 3, stl);
    CHECK(has(r.why, "Organic") && has(slurp(result), "\"code\": \"no_stress_result\""));
  }
  // 3: no spacing: the job is refused, with the key named.
  write_job(R"("tensor": "lattice_file_pocket.tensor", )", R"(, "region_weave": [true])");
  {
    const FileResult r = run_file_job(job_path, kTmp);
    check_refused(r, "job_unreadable", 1, stl);
    CHECK(has(r.detail, "organic_spacing_mm"));
  }
  // 2: made (the merged route: one body; OF4's tubes route is test_weave_tubes').
  write_job(R"("tensor": "lattice_file_pocket.tensor", "mesh": {"weave_mesh": "merged"}, )", weave);
  const FileResult r = run_file_job(job_path, kTmp);
  if (!mesh_available()) {
    check_refused(r, "mesh_unavailable", 3, stl);
  } else {
    CHECK(r.ok && r.exit_code == 0 && r.file == stl);
    if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
    // The bars lay_organic gives directly, from the same part, settings and the field as the file holds it.
    const FileJob job = parse_file_job(slurp(job_path));
    TensorField field;
    CHECK(read_tensor_file(tensor_path, field));
    Session session(import_part_file_resolved(model_path));
    const Outcome out = session.lay_organic(job.settings, field, job.organic);
    std::size_t weave_bars = 0;
    for (const Bar& b : out.bars.bars) weave_bars += b.region == 1;
    CHECK(r.weave_regions == 1 && r.cells == 0 && r.strands == out.strands && r.strands > 0);
    CHECK(r.weave_bars == weave_bars && r.bars == out.bars.bars.size() && weave_bars > 20);
    const std::string text = slurp(result);
    CHECK(has(text, "\"weave_regions\": 1, \"strands\": " + std::to_string(out.strands) + ", \"weave_bars\": " +
                        std::to_string(weave_bars) + ","));
    CHECK(has(text, "\"organic\": {\"ms_trace\": ") && has(text, "\"run_bands\": ["));
    // The table is the one shallow_bar_table makes of those bars, with what the layer check did.
    const ShallowTable t = shallow_bar_table(out.bars, {1}, r.made.left_out_at, r.made.posts);
    CHECK(r.shallow.bars == t.bars && r.shallow.runs == t.runs && r.shallow.longest_run_mm == t.longest_run_mm && t.bars > 0);
    // The file: one body, every edge used twice, nothing outside the part; open between the struts.
    const TriangleMesh mesh = read_stl_file(stl).mesh;
    const auto [shells, open_edges] = shells_and_open(mesh);
    const PartMeasure part(weld_mesh(pocket_mesh()));
    const PartMeasure::Probe pp = part.probe();
    long outside = 0;
    for (const Vec3& v : mesh.vertices) outside += pp.depth(v) < -0.01;
    CHECK(shells == 1 && open_edges == 0 && outside == 0);
    const PartMeasure file(weld_mesh(mesh));
    const PartMeasure::Probe fp = file.probe();
    const Domain::Probe dp = session.domain()->probe();
    long away = 0, filled = 0;
    for (double z = 1.0; z < 19.5; z += 0.7)
      for (double deg = 12; deg < 170; deg += 3.1)
        for (double rr : {7.0, 8.3, 9.2}) {
          const double a = deg * 3.14159265358979323846 / 180.0;
          const Vec3 p{20.0 + rr * std::cos(a), 14.0 - rr * std::sin(a), z};
          const Where w = dp.where(p);
          if (!w.lattice() || w.id != 1) continue;
          bool near = false;
          for (const Bar& b : out.bars.bars) {
            const Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
            const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
            const double s = l2 > 0 ? std::clamp(((p.x - b.a.x) * d.x + (p.y - b.a.y) * d.y + (p.z - b.a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
            near = near || std::hypot(b.a.x + s * d.x - p.x, std::hypot(b.a.y + s * d.y - p.y, b.a.z + s * d.z - p.z)) < 0.5 * b.width + 0.6;
          }
          for (const MeshSpec::Post& q : r.made.posts) near = near || (std::hypot(p.x - q.x, p.y - q.y) < 1.5 && p.z < q.z_top + 1.0);
          if (near) continue;
          ++away;
          filled += fp.inside(p);
        }
    CHECK(away > 100 && filled == 0);
    std::printf("organic job: %zu strands, %zu weave bars (lay_organic directly: %zu); file %zu triangles, %zu shells, %zu open edges; "
                "%ld points of the region away from the struts, %ld filled; trace %.0f ms, total %.0f ms\n", r.strands, r.weave_bars,
                weave_bars, mesh.triangles.size(), shells, open_edges, away, filled, r.ms_trace, r.ms_total);
    std::printf("organic job shallow bars (under 30 degrees): %zu; held at both ends %zu, one %zu, none %zu; %zu whole runs, longest "
                "%.3f mm\n", r.shallow.bars, r.shallow.held_both, r.shallow.held_one, r.shallow.held_none, r.shallow.runs,
                r.shallow.longest_run_mm);
    const char* names[4] = {"to 5 mm", "5 to 10", "10 to 20", "over 20"};
    for (int k = 0; k < 4; ++k)
      std::printf("  %-8s %3zu runs: kept %zu, left out %zu, post %zu\n", names[k], r.shallow.bands[k].runs, r.shallow.bands[k].kept,
                  r.shallow.bands[k].left_out, r.shallow.bands[k].post);
    // The owner's bridge rules (O6 to O9): the table carries what they did, and so does the file's json.
    std::printf("organic job bridge rules: kept at any length %zu, left out leading to nothing %zu, stands added %zu; "
                "the file's posts %zu, left out at %zu places, builds %d\n", r.shallow.kept_any_length,
                r.shallow.weave_left_unheld, r.shallow.stands_added, r.made.posts.size(), r.made.left_out_at.size(), r.made.builds);
    CHECK(r.shallow.kept_any_length == t.kept_any_length && r.shallow.weave_left_unheld == t.weave_left_unheld);
    CHECK(has(text, "\"kept_any_length\": " + std::to_string(t.kept_any_length) + ", \"weave_left_unheld\": " +
                        std::to_string(t.weave_left_unheld) + ", \"stands_added\": " + std::to_string(r.made.stands_added)));
  }
  // OF5: the same job with no mesh key takes the tubes route and writes a 3MF where the STL would be: ONE object of the
  // solid and every shell, vertices shared within each, deflated where the build has zlib. Read back here (unzipped and
  // parsed): its triangles and vertices as made, every shell closed (each edge once each way).
  if (mesh_available()) {
    write_job(R"("tensor": "lattice_file_pocket.tensor", )", weave);
    const std::string three = kTmp + "/pocket_lattice.3mf";
    std::remove(three.c_str());
    const FileResult r = run_file_job(job_path, kTmp);
    CHECK(r.ok && r.file == three && r.file_format == "3mf" && r.weave_mesh == "tubes" && r.made.tubes);
    CHECK(r.compressed == StreamingThreeMfWriter::deflate_available());
    const std::string text = slurp(result);
    CHECK(has(text, "\"file_format\": \"3mf\", \"weave_mesh\": \"tubes\", \"shells\": " +
                        std::to_string(r.made.shells.shells()) + ", \"shells_left_out\": " +
                        std::to_string(r.made.shells.left_out) + ", \"compressed\": " + (r.compressed ? "true" : "false") +
                        ", \"slicer_supports\": \"off\","));
    const std::string zip = slurp(three);
    CHECK(zip.size() == r.file_bytes && r.file_bytes > 0);
    // The zip's model part.
    std::string model;
    for (std::size_t at = 0; at + 30 <= zip.size();) {
      auto u16 = [&](std::size_t i) { return static_cast<unsigned>(static_cast<unsigned char>(zip[i])) | static_cast<unsigned>(static_cast<unsigned char>(zip[i + 1])) << 8; };
      auto u32 = [&](std::size_t i) { return u16(i) | u16(i + 2) << 16; };
      if (u32(at) != 0x04034b50u) break;
      const unsigned method = u16(at + 8), csize = u32(at + 18), size = u32(at + 22), nl = u16(at + 26), xl = u16(at + 28);
      const std::string name = zip.substr(at + 30, nl);
      const std::string data = zip.substr(at + 30 + nl + xl, csize);
      if (name == "3D/3dmodel.model") {
        if (method == 0) model = data;
#ifdef TOPOPT_HAVE_ZLIB
        if (method == 8) {
          model.assign(size, '\0');
          z_stream zs;
          std::memset(&zs, 0, sizeof zs);
          inflateInit2(&zs, -15);
          zs.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(data.data()));
          zs.avail_in = static_cast<uInt>(data.size());
          zs.next_out = reinterpret_cast<Bytef*>(&model[0]);
          zs.avail_out = static_cast<uInt>(size);
          const int rc = inflate(&zs, Z_FINISH);
          inflateEnd(&zs);
          if (rc != Z_STREAM_END || zs.total_out != size) model.clear();
        }
#endif
        CHECK(method == (r.compressed ? 8u : 0u) && (method == 0 || csize < size / 2));
      }
      at += 30 + nl + xl + csize;
    }
    CHECK(!model.empty() && has(model, "<object id=\"1\" type=\"model\">") && has(model, "<item objectid=\"1\"/>"));
    std::size_t nv = 0;
    std::vector<std::array<unsigned long long, 3>> tris;
    for (std::size_t at = model.find("<vertex "); at != std::string::npos; at = model.find("<vertex ", at + 1)) ++nv;
    for (std::size_t at = model.find("<triangle "); at != std::string::npos; at = model.find("<triangle ", at + 1)) {
      std::array<unsigned long long, 3> q{};
      std::sscanf(model.c_str() + at, "<triangle v1=\"%llu\" v2=\"%llu\" v3=\"%llu\"", &q[0], &q[1], &q[2]);
      tris.push_back(q);
    }
    CHECK(tris.size() == r.made.mesh.triangles && nv > 0 && nv < 3 * tris.size());
    std::map<std::pair<unsigned long long, unsigned long long>, int> edges;
    bool in_range = true;
    for (const auto& q : tris)
      for (int e = 0; e < 3; ++e) {
        in_range = in_range && q[static_cast<std::size_t>(e)] < nv;
        ++edges[{q[static_cast<std::size_t>(e)], q[static_cast<std::size_t>((e + 1) % 3)]}];
      }
    std::size_t bad = 0;
    for (const auto& kv : edges) {
      const auto back = edges.find({kv.first.second, kv.first.first});
      bad += kv.second != 1 || back == edges.end() || back->second != 1;
    }
    std::printf("organic 3mf: %zu bytes (%s), %zu vertices, %zu triangles, %zu shells (%zu left out), %zu edges not once each way; "
                "the solid made %d times over %d passes\n", r.file_bytes, r.compressed ? "deflated" : "stored", nv, tris.size(),
                r.made.shells.shells(), r.made.shells.left_out, bad, r.made.base_builds, r.made.builds);
    CHECK(in_range && bad == 0);
    // Asked for an STL, the tubes route writes the STL (the unmerged shells as triangles); asked "merged", an STL as before.
    write_job(R"("tensor": "lattice_file_pocket.tensor", "file_format": "stl", )", weave);
    const FileResult rs = run_file_job(job_path, kTmp);
    CHECK(rs.ok && rs.file == stl && rs.file_format == "stl" && rs.weave_mesh == "tubes" && read_stl_file(stl).mesh.triangles.size() == tris.size());
    std::remove(three.c_str());
  }
  for (const std::string& p : {model_path, face_overrides_sidecar_path(model_path), tensor_path, job_path, stl, result})
    std::remove(p.c_str());
}

// 4: a job with no weave region makes the file it made before, byte for byte: the block's job, and the same job with
// region_weave all false, the organic keys and a stress tensor.
static void test_no_weave_same_file() {
  if (!mesh_available()) return;
  const std::string a = kTmp + "/lattice_file_noweave_a.stl", b = kTmp + "/lattice_file_noweave_b.stl";
  FileJob plain = parse_file_job(kBlockJob);
  std::string text = kBlockJob;
  const std::string at = "\"min_cells_across\": 1";
  text.replace(text.find(at), at.size(), "\"min_cells_across\": 1, \"region_weave\": [false], \"organic_spacing_mm\": 4, "
                                         "\"organic_width_mm\": 0");
  FileJob with = parse_file_job(text);
  TensorField f;
  f.spacing = 1.0;
  f.nx = 30; f.ny = 30; f.nz = 12;
  f.voigt.assign(6 * 30 * 30 * 12, 0.0);
  for (std::size_t e = 0; e < 30 * 30 * 12; ++e) f.voigt[6 * e] = 5.0;
  with.tensor_field = std::make_shared<TensorField>(f);
  const FileResult x = make_lattice_file(box_model(30, 30, 12), plain, a);
  const FileResult y = make_lattice_file(box_model(30, 30, 12), with, b);
  CHECK(x.ok && y.ok && !slurp(a).empty() && slurp(a) == slurp(b));
  CHECK(y.weave_regions == 0 && y.strands == 0 && y.weave_bars == 0 && y.shallow.bars == 0 && y.ms_trace == 0.0);
  // The lead's ruling (2026-11-17, brief L1): a job with no Organic region writes the released engine's result, no
  // Organic field in it (the app reads that file).
  for (const FileResult* r : {&x, &y}) {
    const std::string j = file_result_json(*r);
    CHECK(!has(j, "weave_regions") && !has(j, "\"organic\"") && !has(j, "\"grown\"") && !has(j, "strands") &&
          !has(j, "shallow_bars"));
  }
  std::printf("no weave region: the file %zu bytes, the same with the organic keys %d\n", x.file_bytes, slurp(a) == slurp(b) ? 1 : 0);
  std::remove(a.c_str());
  std::remove(b.c_str());
}

// O11, the blended foot (test 1, the file): three cube parts make the same file, byte for byte, at any weave_foot_mm
// (no key, 0, 0.7, below 0); no foot is written and the file's json says so.
static void test_cube_files_any_foot() {
  if (!mesh_available()) return;
  const double sizes[3][3] = {{30, 30, 12}, {40, 24, 14}, {24, 36, 10}};
  const char* keys[4] = {"", R"("mesh": {"weave_foot_mm": 0}, )", R"("mesh": {"weave_foot_mm": 0.7}, )", R"("mesh": {"weave_foot_mm": -1}, )"};
  for (const auto& sz : sizes) {
    std::string first;
    bool same = true;
    std::size_t feet = 0, bytes_made = 0;
    for (int k = 0; k < 4; ++k) {
      std::string text = kBlockJob;
      const std::string at = "\"layout\": {";
      text.replace(text.find(at), at.size(), std::string(keys[k]) + at);
      const std::string path = kTmp + "/lattice_file_cube_foot.stl";
      std::remove(path.c_str());
      const FileResult r = make_lattice_file(box_model(sz[0], sz[1], sz[2]), parse_file_job(text), path);
      CHECK(r.ok);
      const std::string made = slurp(path);
      if (k == 0) { first = made; bytes_made = made.size(); }
      same = same && !made.empty() && made == first;
      feet += r.made.mesh.feet + r.made.mesh.feet_held;
      CHECK(r.made.mesh.feet_mm3 == 0.0);
      std::remove(path.c_str());
    }
    std::printf("cube part %.0f x %.0f x %.0f: the file %zu bytes, the same at every foot %d, feet %zu\n", sz[0], sz[1], sz[2], bytes_made,
                same ? 1 : 0, feet);
    CHECK(same && feet == 0);
  }
}

// O11 (tests 6, 7 of the foot): stage 1b's traced pocket through the file job, at f = 0 and with the default foot.
// With feet: still one body; the layer check ends clean, leaves out no bar it kept at f = 0 and adds no post it did
// not add at f = 0; the feet are counted in the file's json; the mesh takes no more than 1.5 x the time.
static void test_organic_foot() {
  if (!mesh_available()) return;
  const std::string model_path = kTmp + "/lattice_file_foot.stl";
  const std::string tensor_path = kTmp + "/lattice_file_foot.tensor";
  const std::string job_path = kTmp + "/lattice_file_foot_job.json";
  const std::string stl = kTmp + "/foot_lattice.stl";
  const std::string result = kTmp + "/" + kFileResultName;
  write_stl_file(model_path, pocket_mesh());
  int wall = -1;
  {
    std::remove(face_overrides_sidecar_path(model_path).c_str());
    const StepModel plain = import_part_file_resolved(model_path);
    FaceOverrides ov;
    ov.paint_faces.emplace_back();
    for (std::size_t t = 0; t < plain.mesh.triangles.size(); ++t)
      if (on_pocket_wall(plain.mesh, plain.mesh.triangles[t])) ov.paint_faces.back().push_back(static_cast<int>(t));
    save_face_overrides(face_overrides_sidecar_path(model_path), ov);
    wall = plain.face_count;
  }
  CHECK(write_tensor_file(tensor_path, hoop_field()));
  struct Made { FileResult r; std::string text; TriangleMesh mesh; };
  auto make = [&](const std::string& mesh_key) {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << R"({"mode": "lattice_file", "model": "lattice_file_foot.stl", "output": "foot_lattice.stl", "tensor": "lattice_file_foot.tensor", )"
      << mesh_key
      << R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                "region_face_counts": [1], "region_faces": [)" << wall
      << R"(], "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0.9}})";
    f.close();
    std::remove(stl.c_str());
    Made m;
    m.r = run_file_job(job_path, kTmp);
    m.text = slurp(result);
    m.mesh = read_stl_file(stl).mesh;
    return m;
  };
  // The merged route (one body; OF4 keeps it): the feet are judged joined to the solid.
  const Made off = make(R"("mesh": {"weave_foot_mm": 0, "weave_mesh": "merged"}, )");
  const Made on = make(R"("mesh": {"weave_mesh": "merged"}, )");
  CHECK(off.r.ok && on.r.ok);
  if (!off.r.ok || !on.r.ok) return;
  // The bars the job laid (lay_organic directly, as test_organic_job reads them).
  const FileJob job = parse_file_job(slurp(job_path));
  TensorField field;
  CHECK(read_tensor_file(tensor_path, field));
  Session session(import_part_file_resolved(model_path));
  const Outcome out = session.lay_organic(job.settings, field, job.organic);
  const std::vector<char> kept_off = bars_present(out.bars, off.r.made.left_out_at), kept_on = bars_present(out.bars, on.r.made.left_out_at);
  long out_off = 0, out_on = 0, newly_out = 0;
  for (std::size_t i = 0; i < out.bars.bars.size(); ++i) {
    out_off += !kept_off[i];
    out_on += !kept_on[i];
    newly_out += kept_off[i] && !kept_on[i];
  }
  long new_posts = 0;
  for (const MeshSpec::Post& p : on.r.made.posts) {
    bool was = false;
    for (const MeshSpec::Post& q : off.r.made.posts) was = was || (std::hypot(p.x - q.x, p.y - q.y) < 0.01 && std::fabs(p.z_top - q.z_top) < 0.01);
    new_posts += !was;
  }
  const auto [shells_off, open_off] = shells_and_open(off.mesh);
  const auto [shells_on, open_on] = shells_and_open(on.mesh);
  const MeshReport &m0 = off.r.made.mesh, &m1 = on.r.made.mesh;
  const double ms0 = m0.ms_struts + m0.ms_solid + m0.ms_finish, ms1 = m1.ms_struts + m1.ms_solid + m1.ms_finish;
  for (const Made* m : {&off, &on}) {
    std::printf("organic foot %s: %zu triangles, %zu shells, %zu open edges, %.3f mm3; layer check clean %d, builds %d, found per pass",
                m == &off ? "f = 0  " : "default", m->mesh.triangles.size(), m == &off ? shells_off : shells_on,
                m == &off ? open_off : open_on, m->r.made.mesh.mm3, m->r.made.print_clean ? 1 : 0, m->r.made.builds);
    for (int x : m->r.made.found_per_pass) std::printf(" %d", x);
    std::printf("; left out at %zu places (%ld bars), weave left unheld %zu, posts %zu (stands %zu); feet %zu (held %zu), "
                    "feet add %.4f mm3; struts %.3f mm3; mesh (last build) %.0f ms, the whole job %.0f ms\n",
                    m->r.made.left_out_at.size(), m == &off ? out_off : out_on, m->r.made.mesh.weave_left_unheld, m->r.made.posts.size(),
                    m->r.made.stands_added, m->r.made.mesh.feet, m->r.made.mesh.feet_held, m->r.made.mesh.feet_mm3,
                    m->r.made.mesh.struts_mm3, m == &off ? ms0 : ms1, m->r.ms_total);
  }
  std::printf("organic foot: the feet add %.4f mm3, %.2f %% of the struts' material at f = 0 (%.3f mm3); bars left out with the foot "
              "that were kept without %ld, posts not at f = 0 %ld; mesh time with / without %.2f\n", m1.feet_mm3,
              100.0 * m1.feet_mm3 / std::max(1e-9, m0.struts_mm3), m0.struts_mm3, newly_out, new_posts, ms1 / std::max(1e-9, ms0));
  CHECK(shells_on == 1 && open_on == 0 && on.r.made.print_clean);
  CHECK(m1.feet > 0 && m1.feet_held == 0 && m1.feet_mm3 > 0.0 && m0.feet == 0);
  CHECK(newly_out == 0 && out_on <= out_off && new_posts == 0 && on.r.made.posts.size() <= off.r.made.posts.size());
  CHECK(m1.weave_left_unheld == m0.weave_left_unheld);
  char b[160];
  std::snprintf(b, sizeof b, "\"feet\": %zu, \"feet_held\": %zu, \"feet_mm3\": %.9g,", m1.feet, m1.feet_held, m1.feet_mm3);
  CHECK(has(on.text, b) && has(off.text, "\"feet\": 0, \"feet_held\": 0, \"feet_mm3\": 0,"));
  CHECK(ms1 <= 1.5 * ms0);
  for (const std::string& p : {model_path, face_overrides_sidecar_path(model_path), tensor_path, job_path, stl, result})
    std::remove(p.c_str());
}

// O14, the round top (the file): the key reaches the mesh (true by default, false and true read, anything not a
// yes/no refused); three cube parts make the same file, byte for byte, with no key, false and true.
static void test_cube_files_round_top() {
  const std::string head = R"({"mode": "lattice_file", "model": "a.step", )";
  const std::string tail = R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1]}})";
  CHECK(parse_file_job(head + tail).options.mesh.weave_round_top);
  CHECK(!parse_file_job(head + R"("mesh": {"weave_round_top": false}, )" + tail).options.mesh.weave_round_top);
  CHECK(parse_file_job(head + R"("mesh": {"weave_round_top": true}, )" + tail).options.mesh.weave_round_top);
  bool refused = false;
  try { (void)parse_file_job(head + R"("mesh": {"weave_round_top": 2}, )" + tail); } catch (const FileJobError& x) {
    refused = has(x.what(), "weave_round_top");
  }
  CHECK(refused);
  if (!mesh_available()) return;
  const double sizes[3][3] = {{30, 30, 12}, {40, 24, 14}, {24, 36, 10}};
  const char* keys[3] = {"", R"("mesh": {"weave_round_top": false}, )", R"("mesh": {"weave_round_top": true}, )"};
  for (const auto& sz : sizes) {
    std::string first;
    bool same = true;
    std::size_t bytes_made = 0;
    for (int k = 0; k < 3; ++k) {
      std::string text = kBlockJob;
      const std::string at = "\"layout\": {";
      text.replace(text.find(at), at.size(), std::string(keys[k]) + at);
      const std::string path = kTmp + "/lattice_file_cube_round_top.stl";
      std::remove(path.c_str());
      const FileResult r = make_lattice_file(box_model(sz[0], sz[1], sz[2]), parse_file_job(text), path);
      CHECK(r.ok);
      const std::string made = slurp(path);
      if (k == 0) { first = made; bytes_made = made.size(); }
      same = same && !made.empty() && made == first;
      std::remove(path.c_str());
    }
    std::printf("cube part %.0f x %.0f x %.0f: the file %zu bytes, the same with the round top on and off %d\n", sz[0], sz[1], sz[2],
                bytes_made, same ? 1 : 0);
    CHECK(same);
  }
}

// O14 (the traced pocket): stage 1b's traced pocket through the file job with the round top off and on (the default,
// feet as default): the layer check ends the same (clean, the same places left out, the same posts and stands, the same
// weave bars kept and left unheld); with the round top the file is not the square bars' file, and is one closed body.
static void test_organic_round_top() {
  if (!mesh_available()) return;
  const std::string model_path = kTmp + "/lattice_file_round_top.stl";
  const std::string tensor_path = kTmp + "/lattice_file_round_top.tensor";
  const std::string job_path = kTmp + "/lattice_file_round_top_job.json";
  const std::string stl = kTmp + "/round_top_lattice.stl";
  const std::string result = kTmp + "/" + kFileResultName;
  write_stl_file(model_path, pocket_mesh());
  int wall = -1;
  {
    std::remove(face_overrides_sidecar_path(model_path).c_str());
    const StepModel plain = import_part_file_resolved(model_path);
    FaceOverrides ov;
    ov.paint_faces.emplace_back();
    for (std::size_t t = 0; t < plain.mesh.triangles.size(); ++t)
      if (on_pocket_wall(plain.mesh, plain.mesh.triangles[t])) ov.paint_faces.back().push_back(static_cast<int>(t));
    save_face_overrides(face_overrides_sidecar_path(model_path), ov);
    wall = plain.face_count;
  }
  CHECK(write_tensor_file(tensor_path, hoop_field()));
  struct Made { FileResult r; TriangleMesh mesh; };
  auto make = [&](const std::string& mesh_key) {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << R"({"mode": "lattice_file", "model": "lattice_file_round_top.stl", "output": "round_top_lattice.stl", "tensor": "lattice_file_round_top.tensor", )"
      << mesh_key
      << R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                "region_face_counts": [1], "region_faces": [)" << wall
      << R"(], "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0.9}})";
    f.close();
    std::remove(stl.c_str());
    Made m;
    m.r = run_file_job(job_path, kTmp);
    m.mesh = read_stl_file(stl).mesh;
    return m;
  };
  // The merged route (one body; OF4 keeps it).
  const Made off = make(R"("mesh": {"weave_round_top": false, "weave_mesh": "merged"}, )");
  const Made on = make(R"("mesh": {"weave_mesh": "merged"}, )");
  CHECK(off.r.ok && on.r.ok);
  if (!off.r.ok || !on.r.ok) return;
  const auto& a = off.r.made;
  const auto& b = on.r.made;
  bool same_drop = a.left_out_at.size() == b.left_out_at.size();
  for (std::size_t i = 0; same_drop && i < a.left_out_at.size(); ++i)
    same_drop = std::fabs(a.left_out_at[i].x - b.left_out_at[i].x) < 1e-9 && std::fabs(a.left_out_at[i].y - b.left_out_at[i].y) < 1e-9 &&
                std::fabs(a.left_out_at[i].z - b.left_out_at[i].z) < 1e-9;
  bool same_posts = a.posts.size() == b.posts.size();
  for (std::size_t i = 0; same_posts && i < a.posts.size(); ++i)
    same_posts = std::fabs(a.posts[i].x - b.posts[i].x) < 1e-9 && std::fabs(a.posts[i].y - b.posts[i].y) < 1e-9 &&
                 std::fabs(a.posts[i].z_top - b.posts[i].z_top) < 1e-9 && std::fabs(a.posts[i].z_bottom - b.posts[i].z_bottom) < 1e-9;
  const auto [shells_off, open_off] = shells_and_open(off.mesh);
  const auto [shells_on, open_on] = shells_and_open(on.mesh);
  bool same_file = off.mesh.triangles.size() == on.mesh.triangles.size();
  for (std::size_t i = 0; same_file && i < off.mesh.vertices.size(); ++i)
    same_file = off.mesh.vertices[i].x == on.mesh.vertices[i].x && off.mesh.vertices[i].y == on.mesh.vertices[i].y &&
                off.mesh.vertices[i].z == on.mesh.vertices[i].z;
  for (const Made* m : {&off, &on}) {
    const auto& x = m->r.made;
    std::printf("organic round top %s: %zu triangles, %.3f mm3, %zu bridges; layer check clean %d, builds %d, found per pass",
                m == &off ? "off" : "on ", m->mesh.triangles.size(), x.mesh.mm3, x.mesh.bridges, x.print_clean ? 1 : 0, x.builds);
    for (int v : x.found_per_pass) std::printf(" %d", v);
    std::printf("; left out at %zu places, kept any length %zu, weave left unheld %zu, posts %zu (stands %zu); feet %zu; "
                "%zu shells, %zu open edges\n", x.left_out_at.size(), x.mesh.kept_any_length, x.mesh.weave_left_unheld,
                x.posts.size(), x.stands_added, x.mesh.feet, m == &off ? shells_off : shells_on, m == &off ? open_off : open_on);
  }
  CHECK(a.print_clean == b.print_clean && a.builds == b.builds && a.found_per_pass == b.found_per_pass);
  CHECK(same_drop && same_posts && a.stands_added == b.stands_added);
  CHECK(a.mesh.kept_any_length == b.mesh.kept_any_length && a.mesh.weave_left_unheld == b.mesh.weave_left_unheld &&
        a.mesh.bars == b.mesh.bars && a.mesh.bridges == b.mesh.bridges);
  CHECK(b.mesh.bridges > 0 && !same_file && b.mesh.mm3 < a.mesh.mm3);
  CHECK(shells_on == 1 && open_on == 0);
  for (const std::string& p : {model_path, face_overrides_sidecar_path(model_path), tensor_path, job_path, stl, result})
    std::remove(p.c_str());
}

// O12, the file job's keys for the spacing range: organic_spacing_min_mm with organic_spacing_max_mm, and
// organic_spacing_exponent; organic_spacing_mm alone still means both ends; the reference is the layout's own. The
// result's "organic" object carries the spacing used (smallest, largest, mean).
static void test_organic_range_keys() {
  const std::string head = R"({"mode": "lattice_file", "model": "a.step", "tensor": "stress.tensor",
      "layout": {"region_ids": [3], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1], "region_weave": [true])";
  const FileJob j = parse_file_job(head + R"(, "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8,
                 "organic_spacing_exponent": 1.5, "reference_mpa": 12, "percentile": 0.9}})");
  CHECK(j.organic.spacing_mm == 0.0 && j.organic.spacing_min_mm == 3.0 && j.organic.spacing_max_mm == 8.0 &&
        j.organic.spacing_exponent == 1.5 && j.organic.reference_mpa == 12.0 && j.organic.percentile == 0.9);
  const FileJob e = parse_file_job(head + R"(, "organic_spacing_min_mm": 4, "organic_spacing_max_mm": 4}})");
  CHECK(e.organic.spacing_min_mm == 4.0 && e.organic.spacing_max_mm == 4.0 && e.organic.spacing_exponent == 1.0 &&
        e.organic.reference_mpa == 0.0 && e.organic.percentile == 0.95);
  const FileJob o = parse_file_job(head + R"(, "organic_spacing_mm": 5}})");
  CHECK(o.organic.spacing_mm == 5.0);
  const auto refused = [&](const std::string& keys, const char* name) {
    try { (void)parse_file_job(head + keys + "}}"); } catch (const FileJobError& x) {
      if (!has(x.what(), name)) std::printf("  (refused for \"%s\", wanted %s)\n", x.what(), name);
      return has(x.what(), name);
    }
    std::printf("  (not refused: %s)\n", keys.c_str());
    return false;
  };
  CHECK(refused(R"(, "organic_spacing_min_mm": 3)", "organic_spacing_max_mm"));
  CHECK(refused(R"(, "organic_spacing_max_mm": 8)", "organic_spacing_min_mm"));
  CHECK(refused(R"(, "organic_spacing_min_mm": 0, "organic_spacing_max_mm": 8)", "organic_spacing_min_mm"));
  CHECK(refused(R"(, "organic_spacing_min_mm": 5, "organic_spacing_max_mm": 4)", "organic_spacing_max_mm"));
  CHECK(refused(R"(, "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8, "organic_spacing_exponent": 0)",
                "organic_spacing_exponent"));
  CHECK(refused(R"(, "organic_spacing_mm": 4, "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8)", "organic_spacing_mm"));
  CHECK(refused(R"(, "organic_spacing_mm": 4, "organic_spacing_exponent": 2)", "organic_spacing_mm"));
  CHECK(refused(R"(, "organic_spacing_exponent": 2)", "organic_spacing_exponent"));
  // A file with the range: the spacing used is in the result, inside the range.
  const std::string model_path = kTmp + "/lattice_file_range.stl";
  const std::string tensor_path = kTmp + "/lattice_file_range.tensor";
  const std::string job_path = kTmp + "/lattice_file_range_job.json";
  write_stl_file(model_path, pocket_mesh());
  int wall = -1;
  {
    std::remove(face_overrides_sidecar_path(model_path).c_str());
    const StepModel plain = import_part_file_resolved(model_path);
    FaceOverrides ov;
    ov.paint_faces.emplace_back();
    for (std::size_t t = 0; t < plain.mesh.triangles.size(); ++t)
      if (on_pocket_wall(plain.mesh, plain.mesh.triangles[t])) ov.paint_faces.back().push_back(static_cast<int>(t));
    save_face_overrides(face_overrides_sidecar_path(model_path), ov);
    wall = plain.face_count;
  }
  {  // the hoop field, scaled along x from nothing to its full size, so the spacing has a range to follow
    TensorField ramp = hoop_field();
    for (int k = 0; k < ramp.nz; ++k)
      for (int j = 0; j < ramp.ny; ++j)
        for (int i = 0; i < ramp.nx; ++i)
          for (int c = 0; c < 6; ++c) ramp.voigt[6 * ramp.index(i, j, k) + static_cast<std::size_t>(c)] *= (i + 0.5) / ramp.nx;
    CHECK(write_tensor_file(tensor_path, ramp));
  }
  {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << R"({"mode": "lattice_file", "model": "lattice_file_range.stl", "output": "range_lattice.stl", "tensor": "lattice_file_range.tensor",
      "layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                "region_face_counts": [1], "region_faces": [)" << wall
      << R"(], "region_weave": [true], "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8, "organic_width_mm": 0.9}})";
  }
  const FileResult r = run_file_job(job_path, kTmp);
  const std::string text = slurp(kTmp + "/" + kFileResultName);
  std::printf("organic range file: ok %d, spacing used %.4f to %.4f, mean %.4f\n", r.ok ? 1 : 0, r.spacing_smallest_mm,
              r.spacing_largest_mm, r.spacing_mean_mm);
  CHECK(r.ok && r.strands > 0);
  CHECK(r.spacing_smallest_mm >= 3.0 && r.spacing_largest_mm <= 8.0 && r.spacing_smallest_mm < r.spacing_largest_mm &&
        r.spacing_mean_mm > r.spacing_smallest_mm && r.spacing_mean_mm < r.spacing_largest_mm);
  char b[200];
  std::snprintf(b, sizeof b, "\"spacing_used_mm\": {\"smallest\": %.9g, \"largest\": %.9g, \"mean\": %.9g}", r.spacing_smallest_mm,
                r.spacing_largest_mm, r.spacing_mean_mm);
  CHECK(has(text, b));
}

// O13, the file job's key for the shape fit: "organic_shape_fit", true when not given (as the old run reads a job
// that does not say); false turns it off; anything but true or false is refused, the key named.
static void test_organic_shape_fit_key() {
  const std::string head = R"({"mode": "lattice_file", "model": "a.step", "tensor": "stress.tensor",
      "layout": {"region_ids": [3], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1], "region_weave": [true],
                 "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8)";
  CHECK(parse_file_job(head + "}}").organic.shape_fit);
  CHECK(parse_file_job(head + R"(, "organic_shape_fit": true}})").organic.shape_fit);
  CHECK(!parse_file_job(head + R"(, "organic_shape_fit": false}})").organic.shape_fit);
  bool refused = false;
  try { (void)parse_file_job(head + R"(, "organic_shape_fit": 1}})"); } catch (const FileJobError& x) {
    refused = has(x.what(), "organic_shape_fit");
  }
  CHECK(refused);
}

// OR30, the file job's Finish for a weave region: the regular layout keys ("rim_mm", "cover_mm", "skin",
// "skin_width_mm"). The Organic rim's and net skin's own keys are gone: "organic_rim_mm" and "organic_net_skin" are
// refused as unknown keys, by name. A weave under the top of a 30 x 20 x 16 box (its outline on the part's sides, facing
// air): with no Finish keys (None) no net strut; "skin": true lays the net (in lattice_file.json's "organic" object);
// "rim_mm": -1 makes the same file as None, byte for byte (the outline faces air: no rim).
static void test_organic_finish_keys() {
  const std::string head = R"({"mode": "lattice_file", "model": "a.step", "tensor": "stress.tensor",
      "layout": {"region_ids": [3], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1], "region_weave": [true], "organic_spacing_mm": 4)";
  const auto refused = [&](const std::string& keys, const char* name) {
    try { (void)parse_file_job(head + keys + "}}"); } catch (const FileJobError& x) { return has(x.what(), name); }
    return false;
  };
  CHECK(refused(R"(, "organic_rim_mm": 1.5)", "organic_rim_mm"));
  CHECK(refused(R"(, "organic_net_skin": true)", "organic_net_skin"));
  const FileJob k = parse_file_job(head + R"(, "rim_mm": -1, "cover_mm": 0, "skin": true, "skin_width_mm": 1.1}})");
  CHECK(k.settings.rim_mm == -1.0 && k.settings.skin && k.settings.skin_spec.width_mm == 1.1);
  if (!mesh_available()) return;
  TensorField g;
  g.spacing = 1.0;
  g.nx = 30; g.ny = 20; g.nz = 16;
  g.voigt.assign(6 * 30 * 20 * 16, 0.0);
  for (std::size_t e = 0; e < 30 * 20 * 16; ++e) { g.voigt[6 * e] = 2.0; g.voigt[6 * e + 1] = 1.0; g.voigt[6 * e + 2] = 3.0; }
  const std::string weave_job = R"({"mode": "lattice_file", "model": "box.step",
      "layout": {"min_strut_lines": 2, "region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [12], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1], "region_weave": [true], "organic_spacing_mm": 4,
                 "organic_width_mm": 0.9)";
  const std::string a = kTmp + "/lattice_file_finish_a.stl", b = kTmp + "/lattice_file_finish_b.stl";
  FileResult none, skin, rim;
  for (int n = 0; n < 3; ++n) {
    FileJob j = parse_file_job(weave_job + (n == 0 ? "}}" : n == 1 ? R"(, "skin": true}})" : R"(, "rim_mm": -1}})"));
    j.tensor_field = std::make_shared<TensorField>(g);
    const std::string& out = n == 2 ? b : a;
    std::remove(out.c_str());
    (n == 0 ? none : n == 1 ? skin : rim) = make_lattice_file(box_model(30, 20, 16), j, out);
    if (n == 0) std::rename(none.file.c_str(), (a + ".none").c_str());   // the file as written (OF5: a 3MF by default)
  }
  const bool rim_same = none.ok && rim.ok && !slurp(a + ".none").empty() && slurp(a + ".none") == slurp(rim.file);
  const std::string text = file_result_json(skin);
  char want[200];
  std::snprintf(want, sizeof want, "},\n    \"net_struts\": %llu, \"net_mm\": %.9g,",
                static_cast<unsigned long long>(skin.net_struts), skin.net_mm);
  std::printf("weave Finish by the regular keys: None %zu net struts, file ok %d; Skin %zu net struts (%.1f mm), file ok %d clean %d; "
              "Rim (edges facing air) the same file as None %d\n", none.net_struts, none.ok ? 1 : 0, skin.net_struts, skin.net_mm,
              skin.ok ? 1 : 0, skin.made.print_clean ? 1 : 0, rim_same ? 1 : 0);
  CHECK(none.ok && none.net_struts == 0 && none.net_mm == 0.0);
  CHECK(has(file_result_json(none), "},\n    \"net_struts\": 0, \"net_mm\": 0,"));
  CHECK(skin.ok && skin.net_struts > 0 && skin.net_mm > 0.0 && has(text, want));
  CHECK(rim_same);
  std::remove(a.c_str());
  std::remove((a + ".none").c_str());
  std::remove(b.c_str());
  std::remove(skin.file.c_str());
  std::remove(rim.file.c_str());
}

// O6 (joints a hair apart, test 9): in the shallow-bar table two level bars in line whose joint's two ends are 4e-6 mm
// apart are one joint: one run, held at both ends. 2e-5 mm apart: two runs.
static void test_shallow_table_hair_apart() {
  for (double gap : {4e-6, 2e-5}) {
    Bars b;
    for (int q = 0; q < 2; ++q) {
      Bar x;
      x.a = q == 0 ? Vec3{4.1, 20, 10} : Vec3{20 + gap, 20, 10};
      x.b = q == 0 ? Vec3{20, 20, 10} : Vec3{35.9, 20, 10};
      x.width = 0.9; x.cell = 4.0; x.region = 1;
      x.end_a = q == 0 ? Bar::End::Solid : Bar::End::Node;
      x.end_b = q == 0 ? Bar::End::Node : Bar::End::Solid;
      b.bars.push_back(x);
    }
    const ShallowTable t = shallow_bar_table(b, {1}, {}, {});
    std::printf("shallow table, joint %.0e mm apart: %zu bars, %zu runs, longest %.2f mm, kept any length %zu, unheld %zu\n",
                gap, t.bars, t.runs, t.longest_run_mm, t.kept_any_length, t.weave_left_unheld);
    if (gap < 1e-5) CHECK(t.bars == 2 && t.runs == 1 && t.longest_run_mm > 31.7 && t.kept_any_length == 2 && t.weave_left_unheld == 0);
    else CHECK(t.bars == 2 && t.runs == 2 && t.kept_any_length == 0 && t.weave_left_unheld == 2);
  }
}

// O17, O18, the file job's keys: mesh "weave_sag_lift_mm" (0.9 by default, 0 = never, below 0 refused) and
// "weave_sag_legs" (true by default); a cube-lattice job's file is the same byte for byte whatever they say, and its
// result says nothing of sags; a weave job's result carries what the sag pass did.
static void test_sag_keys() {
  const std::string head = R"({"mode": "lattice_file", "model": "a.step", )";
  const std::string tail = R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                 "region_face_counts": [1], "region_faces": [1]}})";
  {
    const FileJob plain = parse_file_job(head + tail);
    const FileJob set = parse_file_job(head + R"("mesh": {"weave_sag_lift_mm": 0.4, "weave_sag_legs": false}, )" + tail);
    CHECK(plain.options.mesh.weave_sag_lift_mm == 0.9 && plain.options.mesh.weave_sag_legs);
    CHECK(set.options.mesh.weave_sag_lift_mm == 0.4 && !set.options.mesh.weave_sag_legs);
    CHECK(parse_file_job(head + R"("mesh": {"weave_sag_lift_mm": 0}, )" + tail).options.mesh.weave_sag_lift_mm == 0.0);
  }
  for (const char* bad : {R"("mesh": {"weave_sag_lift_mm": -1}, )", R"("mesh": {"weave_sag_legs": 2}, )"}) {
    bool refused = false;
    try { (void)parse_file_job(head + bad + tail); } catch (const FileJobError& x) { refused = has(x.what(), "weave_sag_"); }
    CHECK(refused);
  }
  if (!mesh_available()) return;
  const double sizes[3][3] = {{30, 30, 12}, {40, 24, 14}, {24, 36, 10}};
  const char* keys[3] = {"", R"("mesh": {"weave_sag_lift_mm": 0, "weave_sag_legs": false}, )",
                         R"("mesh": {"weave_sag_lift_mm": 5, "weave_sag_legs": true}, )"};
  for (const auto& sz : sizes) {
    std::string first;
    bool same = true, quiet = true;
    for (int k = 0; k < 3; ++k) {
      std::string text = kBlockJob;
      const std::string at = "\"layout\": {";
      text.replace(text.find(at), at.size(), std::string(keys[k]) + at);
      const std::string path = kTmp + "/lattice_file_cube_sags.stl";
      std::remove(path.c_str());
      const FileResult r = make_lattice_file(box_model(sz[0], sz[1], sz[2]), parse_file_job(text), path);
      CHECK(r.ok);
      const std::string made = slurp(path);
      if (k == 0) first = made;
      same = same && !made.empty() && made == first;
      quiet = quiet && !has(file_result_json(r), "sags_") && !r.made.sagged && r.made.sags.low_nodes == 0;
      std::remove(path.c_str());
    }
    std::printf("cube part %.0f x %.0f x %.0f: the same file with the sag keys any way %d, nothing said of sags %d\n", sz[0], sz[1],
                sz[2], same ? 1 : 0, quiet ? 1 : 0);
    CHECK(same && quiet);
  }
  // The traced pocket (stage 1b's): the result says what the sag pass did.
  const std::string model_path = kTmp + "/lattice_file_sags.stl";
  const std::string tensor_path = kTmp + "/lattice_file_sags.tensor";
  const std::string job_path = kTmp + "/lattice_file_sags_job.json";
  const std::string stl = kTmp + "/sags_lattice.stl";
  const std::string result = kTmp + "/" + kFileResultName;
  write_stl_file(model_path, pocket_mesh());
  int wall = -1;
  {
    std::remove(face_overrides_sidecar_path(model_path).c_str());
    const StepModel plain = import_part_file_resolved(model_path);
    FaceOverrides ov;
    ov.paint_faces.emplace_back();
    for (std::size_t t = 0; t < plain.mesh.triangles.size(); ++t)
      if (on_pocket_wall(plain.mesh, plain.mesh.triangles[t])) ov.paint_faces.back().push_back(static_cast<int>(t));
    save_face_overrides(face_overrides_sidecar_path(model_path), ov);
    wall = plain.face_count;
  }
  CHECK(write_tensor_file(tensor_path, hoop_field()));
  {
    std::ofstream f(job_path, std::ios::binary | std::ios::trunc);
    f << R"({"mode": "lattice_file", "model": "lattice_file_sags.stl", "output": "sags_lattice.stl", "tensor": "lattice_file_sags.tensor", )"
      << R"("layout": {"region_ids": [1], "region_no_lattice": [0], "region_depth_mm": [4], "region_expand_mm": [0],
                "region_face_counts": [1], "region_faces": [)" << wall
      << R"(], "region_weave": [true], "organic_spacing_mm": 4, "organic_width_mm": 0.9}})";
  }
  const FileResult r = run_file_job(job_path, kTmp);
  CHECK(r.ok);
  const std::string text = slurp(result);
  char want[256];
  std::snprintf(want, sizeof want, "\"sags_lifted\": %zu, \"sag_lift_largest_mm\": %.9g, \"sag_legs\": %zu, \"sag_legs_mm\": %.9g, "
                "\"sags_unsupported\": %zu", r.made.sags.lifted, r.made.sags.lift_largest_mm, r.made.sags.legs, r.made.sags.legs_mm,
                r.made.sags.unsupported);
  std::printf("organic job sags: %s (low nodes %zu, not covered %zu, open arm %zu)\n", want, r.made.sags.low_nodes,
              r.made.sags.not_covered, r.made.sags.open_arm);
  CHECK(has(text, want));
  CHECK((r.made.sagged != nullptr) == r.made.sags.changed());
  for (const std::string& p : {model_path, face_overrides_sidecar_path(model_path), tensor_path, job_path, stl, result})
    std::remove(p.c_str());
}

// L1 (brief L1, item 6): one job with a cell region AND an Organic (weave) region is laid and made: the top face's region
// is the weave, the bottom face's region cells. And a strength job on a job with an Organic region AND a cell region is
// refused (strength_mixed, brief E2) before any work, with one plain line, no file; the same job with no weave region,
// or with every region a weave, is not refused for it (it goes on to the check's own reading of its job).
static void test_cells_and_weave_job() {
  std::string text = R"({"mode": "lattice_file", "model": "block.step", "layout": {
    "min_strut_lines": 2, "bead_mm": 0.45,
    "region_ids": [1, 2], "region_no_lattice": [0, 0], "region_depth_mm": [10, 10], "region_expand_mm": [-2, -2],
    "region_face_counts": [1, 1], "region_faces": [1, 0], "region_weave": [true, false],
    "organic_spacing_mm": 4, "organic_width_mm": 0.9,
    "algorithm": "uniform", "cell_max_mm": 6, "min_cells_across": 1}})";
  TensorField f;
  f.spacing = 1.0;
  f.nx = 30; f.ny = 30; f.nz = 24;
  f.voigt.assign(6 * 30 * 30 * 24, 0.0);
  for (std::size_t e = 0; e < 30 * 30 * 24; ++e) { f.voigt[6 * e + 2] = 3.0; f.voigt[6 * e + 0] = 1.0; }
  const auto field = std::make_shared<TensorField>(f);
  FileJob job = parse_file_job(text);
  CHECK(job.settings.regions.size() == 2 && job.settings.regions[0].weave && !job.settings.regions[1].weave);
  job.tensor_field = field;
  const std::string path = kTmp + "/lattice_file_cells_and_weave.stl";
  std::remove(path.c_str());
  if (mesh_available()) {
    const FileResult r = make_lattice_file(box_model(30, 30, 24), job, path);
    if (!r.ok) std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
    std::size_t cell_bars = 0;
    std::printf("cells and weave in one job: ok %d, cells %zu, weave regions %zu, strands %zu, bars %zu (weave %zu)\n",
                r.ok ? 1 : 0, r.cells, r.weave_regions, r.strands, r.bars, r.weave_bars);
    cell_bars = r.bars - r.weave_bars;
    CHECK(r.ok && r.cells > 0 && r.weave_regions == 1 && r.strands > 0 && r.weave_bars > 0 && cell_bars > 0);
    CHECK(r.ok && exists(r.file) && r.file_bytes > 0);   // OF5: a 3MF beside the asked-for name, by default
    CHECK(has(file_result_json(r), "\"weave_regions\": 1"));
    std::remove(r.file.c_str());
  }
  // The strength check refused on it, before anything (the check is never asked).
  bool asked = false;
  StrengthCheck check;
  check.before = [&](const std::string&) { asked = true; StrengthDone d; d.ok = true; return d; };
  check.run = [&](const StrengthAsk&) { asked = true; StrengthDone d; d.ok = true; d.json = "{}"; return d; };
  std::string with_strength = text;
  with_strength.replace(with_strength.find("\"layout\""), 8, "\"strength_job\": \"strength.json\", \"layout\"");
  FileJob sj = parse_file_job(with_strength);
  CHECK(sj.strength_job == "strength.json");
  sj.tensor_field = field;
  const FileResult s = make_lattice_file(box_model(30, 30, 24), sj, path, nullptr, nullptr, &check);
  std::printf("strength job with an Organic region and a cell region: %s: %s\n", s.code.c_str(), s.why.c_str());
  check_refused(s, "strength_mixed", 1, path);
  CHECK(!asked && has(file_result_json(s), "\"code\": \"strength_mixed\""));
  // Every region a weave: not refused for it; a build with no Organic check is (strength_unavailable), before any work.
  {
    std::string weave_only = with_strength;
    weave_only.replace(weave_only.find("[true, false]"), 13, "[true, true]");
    FileJob wj = parse_file_job(weave_only);
    wj.tensor_field = field;
    const FileResult w = make_lattice_file(box_model(30, 30, 24), wj, path, nullptr, nullptr, &check);
    CHECK(!asked && w.code == "strength_unavailable");
    StrengthCheck organic = check;
    organic.before = [&](const std::string&) {
      asked = true;
      StrengthDone d;
      d.code = "strength_job_unreadable";
      d.why = "made up";
      return d;
    };
    organic.run_organic = organic.run;
    const FileResult w2 = make_lattice_file(box_model(30, 30, 24), wj, path, nullptr, nullptr, &organic);
    CHECK(asked && w2.code == "strength_job_unreadable");
    asked = false;
  }
  // No weave region: not refused for it (the check's own `before` is asked).
  std::string cells_only = with_strength;
  cells_only.replace(cells_only.find("[true, false]"), 13, "[false, false]");
  FileJob cj = parse_file_job(cells_only);
  cj.tensor_field = field;
  StrengthCheck refuse_it = check;
  refuse_it.before = [&](const std::string&) {
    asked = true;
    StrengthDone d;
    d.code = "strength_job_unreadable";
    d.why = "made up";
    return d;
  };
  const FileResult c = make_lattice_file(box_model(30, 30, 24), cj, path, nullptr, nullptr, &refuse_it);
  CHECK(asked && c.code == "strength_job_unreadable");
  std::remove(path.c_str());
}

// Brief E2, items 9 and 11: the width floors and the job key "strengthened". The file job's own lay (as its strength
// check is handed it) and lay_organic_preview Exact are the same lattice, bar for bar: with floors (the strut width on a
// Sweep: bars in the floor's ball widened, never above the upper width; a single width: not applied), and with a
// strengthened.json (a boosted stress input, the stated reference, floors) read by the file job from its job key and by
// the preview through apply_strengthened. The reference reads back as the same double.
static bool same_bars(const Bars& x, const Bars& y) {
  if (x.bars.size() != y.bars.size()) return false;
  for (std::size_t i = 0; i < x.bars.size(); ++i) {
    const Bar& a = x.bars[i];
    const Bar& b = y.bars[i];
    if (a.a.x != b.a.x || a.a.y != b.a.y || a.a.z != b.a.z || a.b.x != b.b.x || a.b.y != b.b.y || a.b.z != b.b.z ||
        a.width != b.width || a.link != b.link)
      return false;
  }
  return true;
}
static void test_floors_and_strengthened() {
  if (!mesh_available()) return;
  const std::string dir = kTmp + "/e2_floors";
  std::system(("mkdir -p " + dir + "/s").c_str());
  write_stl_file(dir + "/block.stl", box_model(30, 30, 24).mesh);
  int top = -1;
  {
    const StepModel m = import_part_file_resolved(dir + "/block.stl");
    for (int f = 0; f < m.face_count; ++f)
      if (m.faces[static_cast<std::size_t>(f)].kind == StepSurfaceKind::Plane && m.faces[static_cast<std::size_t>(f)].plane_normal.z > 0.99) top = f;
  }
  CHECK(top >= 0);
  TensorField f;
  f.spacing = 1.0;
  f.nx = 30; f.ny = 30; f.nz = 24;
  f.voigt.assign(6 * 30 * 30 * 24, 0.0);
  for (int k = 0; k < 24; ++k)
    for (int j = 0; j < 30; ++j)
      for (int i = 0; i < 30; ++i) {
        const std::size_t e = f.index(i, j, k);
        f.voigt[6 * e + 2] = 0.5 + 3.0 * i / 29.0;
        f.voigt[6 * e + 0] = 1.0;
      }
  CHECK(write_tensor_file(dir + "/stress.tensor", f));
  const auto job_text = [&](const std::string& extra, double heavy) {
    char h[32];
    std::snprintf(h, sizeof h, "%g", heavy);
    return std::string(R"({"mode": "lattice_file", "model": "block.stl", "tensor": "stress.tensor", "strength_job": "none.json")") + extra +
           R"(, "layout": {"min_strut_lines": 2, "bead_mm": 0.45, "region_ids": [1], "region_no_lattice": [0],
             "region_depth_mm": [10], "region_expand_mm": [-2], "region_face_counts": [1], "region_faces": [)" +
           std::to_string(top) + R"(], "region_weave": [true], "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 6,
             "organic_width_mm": 0.9, "organic_width_heavy_mm": )" + h + "}}";
  };
  // The file job's own lay, as handed to its (Organic) strength check.
  const auto file_lay = [&](const std::string& path, const std::vector<WidthFloor>& floors, Bars& got) {
    FileJob job;
    StepModel model;
    FileResult r;
    if (!load_file_job(path, 0, job, model, r)) {
      std::printf("  (%s: %s %s)\n", r.code.c_str(), r.why.c_str(), r.detail.c_str());
      return job;
    }
    job.organic.floors.insert(job.organic.floors.end(), floors.begin(), floors.end());
    StrengthCheck cap;
    cap.before = [](const std::string&) { StrengthDone d; d.ok = true; return d; };
    cap.run = [](const StrengthAsk&) { StrengthDone d; d.ok = true; d.json = "{}"; return d; };
    cap.run_organic = [&](const StrengthAsk& ask) {
      got = ask.outcome->bars;
      StrengthDone d;
      d.ok = true;
      d.json = "{}";
      return d;
    };
    const FileResult made = make_lattice_file(std::move(model), job, dir + "/out.stl", nullptr, nullptr, &cap);
    if (!made.ok) std::printf("  (%s: %s %s)\n", made.code.c_str(), made.why.c_str(), made.detail.c_str());
    CHECK(made.ok && made.strength_ran);
    std::remove(made.file.c_str());
    return job;
  };
  const WidthFloor floor{{15.0, 15.0, 19.0}, 6.0, 1.6};
  // Item 9: with the width on a Sweep.
  {
    std::ofstream(dir + "/job.json") << job_text("", 1.8);
    Bars got;
    const FileJob job = file_lay(dir + "/job.json", {floor}, got);
    Session s(import_part_file_resolved(dir + "/block.stl"));
    OrganicPreviewAsk pa;
    pa.quality = PreviewQuality::Exact;
    const OrganicPreview pv = lay_organic_preview(s, job.settings, *job.tensor_field, job.organic, pa);
    std::size_t at_floor = 0;
    for (const Bar& b : pv.outcome.bars.bars) at_floor += !b.link && b.width == 1.6;
    std::printf("floors (Sweep): file %zu bars, preview %zu; widened %zu (links %zu), at the floor %zu\n", got.bars.size(),
                pv.outcome.bars.bars.size(), pv.outcome.floors_widened, pv.outcome.floor_links_widened, at_floor);
    CHECK(!got.bars.empty() && same_bars(got, pv.outcome.bars));
    CHECK(pv.outcome.floors_widened > 0 && at_floor > 0);
    for (const Bar& b : pv.outcome.bars.bars) CHECK(b.width <= 1.8 + 1e-12);
    // The same job with no floors: the bars the floor's ball holds are thinner.
    Session s2(import_part_file_resolved(dir + "/block.stl"));
    FileJob plain = job;
    plain.organic.floors.clear();
    const OrganicPreview p0 = lay_organic_preview(s2, plain.settings, *plain.tensor_field, plain.organic, pa);
    CHECK(p0.outcome.floors_widened == 0 && p0.outcome.bars.bars.size() == pv.outcome.bars.bars.size());
    // Item 11: a strengthened.json (a boosted stress input, the reference the plain lay resolved, the floor).
    double ref = 0.0;
    for (const auto& r : p0.outcome.organic_references) ref = std::max(ref, r.second);
    CHECK(ref > 0.0);
    TensorField boosted = f;
    for (std::size_t e = 0; e < boosted.voigt.size() / 6; ++e)
      if (e % 3 == 0)
        for (int q = 0; q < 6; ++q) boosted.voigt[6 * e + q] *= 3.0;
    CHECK(write_tensor_file(dir + "/s/stress.tensor", boosted));
    CHECK(write_floors_file(dir + "/s/floors.bin", {floor}));
    Strengthened st;
    st.stress_input = "stress.tensor";
    st.floors = "floors.bin";
    st.reference_mpa = ref * (1.0 + 1e-13) / 3.0;   // any double: it must read back the same
    CHECK(write_strengthened_file(dir + "/s/strengthened.json", st, "  \"round\": 1"));
    std::ofstream(dir + "/job_s.json") << job_text(R"(, "strengthened": "s/strengthened.json")", 1.8);
    Bars got_s;
    const FileJob js = file_lay(dir + "/job_s.json", {}, got_s);
    CHECK(js.organic.reference_mpa == st.reference_mpa && js.organic.floors.size() == 1);
    TensorField pf;
    OrganicAsk pask = plain.organic;
    std::string why;
    CHECK(apply_strengthened(dir + "/s/strengthened.json", pf, pask, &why));
    CHECK(pask.reference_mpa == st.reference_mpa);
    Session s3(import_part_file_resolved(dir + "/block.stl"));
    const OrganicPreview ps = lay_organic_preview(s3, plain.settings, pf, pask, pa);
    std::printf("strengthened: file %zu bars, preview %zu; widened %zu\n", got_s.bars.size(), ps.outcome.bars.bars.size(),
                ps.outcome.floors_widened);
    CHECK(!got_s.bars.empty() && same_bars(got_s, ps.outcome.bars));
    CHECK(!same_bars(got_s, pv.outcome.bars));   // the boosted input and the stated reference changed the lattice
  }
  // Item 9: a single width (no Sweep): the floors are not applied.
  {
    std::ofstream(dir + "/job1.json") << job_text("", 0.0);
    Bars got;
    const FileJob job = file_lay(dir + "/job1.json", {floor}, got);
    Session s(import_part_file_resolved(dir + "/block.stl"));
    OrganicPreviewAsk pa;
    const OrganicPreview pv = lay_organic_preview(s, job.settings, *job.tensor_field, job.organic, pa);
    CHECK(same_bars(got, pv.outcome.bars) && pv.outcome.floors_widened == 0);
    for (const Bar& b : pv.outcome.bars.bars) CHECK(b.link || b.width == 0.9);
  }
}

// Leg T (OS1 R2 completed; the lead, 2026-11-21): the app's own Organic sample asks make a print file. At 10cc65bd the
// rounded ends of the shallow runs (weave_bridge_domes, on in file_mesh_defaults) used up the print check's passes and
// these jobs came back would_not_print; at release 12's engine (bc34b79c) they printed clean. The asks exactly as the
// Lattice page's sample makes them (the sample cube, a box zone 1 mm round it, the made-up stress of one focus, the
// Auto Sweep ask at Look 50): Grown with depth variation off, and Traced with it on.
static void test_app_sample_asks_print() {
  auto half = [](double v) { return std::round(v * 2.0) / 2.0; };
  auto smallest_cell = [](double t) { return std::ceil(2.0 * 0.5 * std::sqrt(3.0 * 3.14159265358979323846) * t) / 2.0; };
  topopt::LatticeSampleSpec spec;
  spec.shape = "cube";
  const std::string body = std::string(LATTICE_FILE_TMP_DIR) + "/app_sample_cube.stl";
  write_stl_file(body, topopt::lattice_sample_body(spec), StlFormat::Binary);
  const StepModel model = import_part_file_resolved(body);
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (const Vec3& v : model.mesh.vertices) {
    lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
    hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
  }
  for (const bool grown : {true, false}) {
    namespace ll = topopt::lattice_layout;
    ll::Session session(model);
    ll::Settings s;
    s.bead_mm = 0.45;
    s.min_strut_lines = 2;
    ll::Settings::RegionAsk r;
    r.id = 1;
    r.role = ll::Role::Lattice;
    r.weave = true;
    r.zone.kind = ll::Zone::Kind::Box;
    r.zone.centre = {0.5 * (lo.x + hi.x), 0.5 * (lo.y + hi.y), 0.5 * (lo.z + hi.z)};
    r.zone.axis[0] = {1, 0, 0};
    r.zone.axis[1] = {0, 1, 0};
    r.zone.axis[2] = {0, 0, 1};
    for (int k = 0; k < 3; ++k) r.zone.half[k] = 0.5 * ((k == 0 ? hi.x - lo.x : k == 1 ? hi.y - lo.y : hi.z - lo.z)) + 1;
    s.regions = {r};
    const ll::SweepLimitsUnion L = session.sweep_limits_for(s, {1}, 0.45);
    const double cl = std::max(half(L.cell_lower_mm), smallest_cell(L.strut_lower_mm)), cu = std::max(cl, half(L.cell_upper_mm));
    ll::OrganicAsk a;
    a.mode = grown ? ll::OrganicMode::Grown : ll::OrganicMode::Traced;
    a.spacing_min_mm = cl;
    a.spacing_max_mm = cu;
    a.width_mm = L.strut_lower_mm;
    a.width_heavy_mm = L.strut_upper_mm;
    a.walls_out = grown;
    a.wall_gap = grown ? 2.5 : 0.0;
    a.wall_gap_heavy = grown ? 1.0 : 0.0;
    a.wall_cross = grown ? 1 : 0;
    a.cross_gap = 2.5;
    a.cross_gap_heavy = grown ? 1.0 : 0.0;
    a.tie_level = true;
    a.ties = true;
    a.tie_gap = 1.0;
    a.tie_gap_heavy = 0.5;
    if (grown) { a.foot_gap = 2.5; a.stress_goal = true; a.prune = true; }
    a.shape_fit = true;
    a.shape_reach = 1;
    a.member_cap = false;
    a.hold_parts = true;
    a.part_to_floor = true;
    a.part_reach_mm = 1.5 * cu;
    a.part_support_mm = 0.75 * cl;
    a.unbraced_max = 10;
    a.bed_floor_mm = 0.8;
    a.layer_mm = 0.2;
    a.strand_keep = 0.5;
    a.face_relief_mm = grown ? 0.0 : 1.0;
    const std::vector<ll::OrganicGroup> groups = {{{1}, a}};
    const ll::SyntheticStress syn = ll::organic_synthetic_stress(session, s, ll::TensorField{}, {{1, 1}}, groups);
    CHECK(syn.refused.empty());
    if (!syn.refused.empty()) continue;
    FileJob job;   // the file's own defaults (file_mesh_defaults: the rounded ends on)
    job.settings = s;
    job.organic = a;
    job.organic.layer_mm = job.options.layers.layer_mm;
    job.tensor_field = std::make_shared<ll::TensorField>(syn.field);
    job.file_format = "stl";
    const FileResult fr = make_lattice_file(model, job, std::string(LATTICE_FILE_TMP_DIR) + "/app_sample_cube_lattice.stl");
    std::printf("app sample, cube %s, depth variation %s: ok %d (%s), print clean %d, rounded ends kept %zu, held flat %zu, "
                "dome rounds %d, passes found [%zu]\n", grown ? "Grown" : "Traced", grown ? "off" : "on", fr.ok ? 1 : 0,
                fr.code.c_str(), fr.made.print_clean ? 1 : 0, fr.made.shells.bridge_domes, fr.made.domes_flattened,
                fr.made.dome_rounds, fr.made.found_per_pass.size());
    CHECK(fr.ok && fr.made.print_clean && fr.made.shells.bridge_domes > 0);
    // Leg U (the flat ends, the lead's ruling 2026-11-21): the Exact preview of the same ask runs the file's print check
    // whenever shallow runs have rounded ends (depth variation on or off) and lists the ends it held flat: the file's
    // flat_domes_at exactly, each one a point of a run within 1e-4 mm; the Draft lists none; a stop during the check
    // answers "cancelled" (SB1).
    {
      ll::Session ps(model);
      ll::OrganicPreviewAsk pa;
      pa.quality = ll::PreviewQuality::Exact;
      const ll::OrganicPreview pv = ll::lay_organic_preview(ps, s, syn.field, groups, pa);
      std::size_t same = 0, lifted = 0, on_run = 0;
      for (const Vec3& f : pv.flat_ends) {
        bool in = false, near = false;
        for (const Vec3& g : fr.made.flat_domes_at) {
          in = in || (f.x == g.x && f.y == g.y && f.z == g.z);
          // a joint the sag pass lifted (O17, at most weave_sag_lift_mm): the file's end there, the runs' end here
          near = near || std::hypot(f.x - g.x, std::hypot(f.y - g.y, f.z - g.z)) <= job.options.mesh.weave_sag_lift_mm + 1e-9;
        }
        same += in;
        lifted += !in && near;
        bool run = false;
        for (const ll::WeaveRun& w : pv.runs)
          for (const Vec3& q : w.points)
            run = run || (std::fabs(q.x - f.x) < 1e-4 && std::fabs(q.y - f.y) < 1e-4 && std::fabs(q.z - f.z) < 1e-4);
        on_run += run;
      }
      ll::Session ds(model);
      ll::OrganicPreviewAsk da;
      da.quality = ll::PreviewQuality::Draft;
      const ll::OrganicPreview dv = ll::lay_organic_preview(ds, s, syn.field, groups, da);
      std::printf("  the Exact preview's flat ends %zu (the file's %zu: the same %zu, at a joint the sag pass lifted %zu; on a run "
                  "point %zu); the Draft's %zu\n", pv.flat_ends.size(), fr.made.flat_domes_at.size(), same, lifted, on_run,
                  dv.flat_ends.size());
      CHECK(!pv.flat_ends.empty() && pv.flat_ends.size() == fr.made.flat_domes_at.size() && same + lifted == pv.flat_ends.size() &&
            on_run == pv.flat_ends.size() && dv.flat_ends.empty());
      if (grown) {   // depth variation off: the check runs for the rounded ends alone; a stop during it is a cancel
        std::size_t threw = 0, cancelled = 0;
        for (const int ms : {200, 400, 600}) {
          ll::Session cs(model);
          std::atomic<bool> stop{false};
          std::thread t([&] { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); stop = true; });
          try {
            cancelled += ll::lay_organic_preview(cs, s, syn.field, groups, pa, 0, &stop).outcome.cancelled;
          } catch (...) {
            ++threw;
          }
          t.join();
        }
        std::printf("  stopped at 200, 400, 600 ms: threw %zu, cancelled %zu\n", threw, cancelled);
        CHECK(threw == 0);
      }
    }
  }
}

int main() {
  test_app_sample_asks_print();
  test_floors_and_strengthened();
  test_cells_and_weave_job();
  test_max_step_key();
  test_pieces_key();
  test_region_own_key();
  test_area_finish_file();
  test_shallow_table_hair_apart();
  test_tensor_file();
  test_organic_job();
  test_no_weave_same_file();
  test_cells_by_stress_key();
  test_zones_key();
  test_by_stress_file();
  test_no_slit_under_solid();
  test_strut_reach();
  test_thin_slot();
  test_parse();
  test_make();
  test_refusals();
  test_run();
  test_one_grid_key();
  test_organic_foot();
  test_cube_files_any_foot();
  test_organic_range_keys();
  test_organic_shape_fit_key();
  test_cube_files_round_top();
  test_organic_round_top();
  test_organic_finish_keys();
  test_sag_keys();
  if (!mesh_available()) std::printf("no mesh library in this build: the job says so\n");
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
