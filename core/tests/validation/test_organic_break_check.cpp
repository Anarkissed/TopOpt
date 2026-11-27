// Organic strength CUT 1, stages C1 and C2: the break check (lattice_layout_break.hpp).
// With no arguments: the member thickness and the verdict's own gate (break_judged) on made shapes (S4's: a 1-voxel
// column, a 3 x 3 column at its centre and corner, a 5-voxel slab), the limit law (with the review's biaxial case), and
// one end-to-end check of a small made bar (seconds). With "marks DIR": marks 1 and 2 of the plan (section 5) on the made pieces, laid here
// by the file job from the made inputs in DIR (the study's made jobs: BR.stl, BR.tensor, BRT_d_job.json,
// BRG_d_job.json, SP.stl, SP.tensor, SP_job.json), each through organic_break_check at 0.2 mm and tolerance 1e-2.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_break.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/materials.hpp"
#include "topopt/observability.hpp"
#include "topopt/step.hpp"
#include "topopt/stl.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

namespace {
int failures = 0;
void check(bool ok, const char* what) {
  std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
  failures += ok ? 0 : 1;
}
std::string slurp(const std::string& p) {
  std::ifstream f(p);
  std::stringstream s;
  s << f.rdbuf();
  return s.str();
}
void write(const std::string& p, const std::string& t) { std::ofstream(p) << t; }

void gate() {
  const int n = 21;
  auto at = [&](std::vector<char>& m, int i, int j, int k) -> char& { return m[(static_cast<std::size_t>(k) * n + j) * n + i]; };
  std::vector<char> col1(n * n * n, 0), col3(n * n * n, 0), slab5(n * n * n, 0);
  for (int k = 0; k < n; ++k) {
    at(col1, 10, 10, k) = 1;
    for (int j = 9; j <= 11; ++j)
      for (int i = 9; i <= 11; ++i) at(col3, i, j, k) = 1;
  }
  for (int k = 8; k <= 12; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) at(slab5, i, j, k) = 1;
  const double a = break_member_thickness(col1, n, n, n, 10, 10, 10), b = break_member_thickness(col3, n, n, n, 10, 10, 10),
               c = break_member_thickness(col3, n, n, n, 11, 11, 10), d = break_member_thickness(slab5, n, n, n, 10, 10, 10),
               e = break_member_thickness(slab5, n, n, n, 10, 10, 12);
  std::printf("gate: 1-voxel column %.3f; 3 x 3 column centre %.3f, corner %.3f; 5-voxel slab middle %.3f, face %.3f\n", a, b, c, d, e);
  check(std::fabs(a - 1.0) < 1e-9 && std::fabs(b - 3.0) < 1e-9 && std::fabs(c - 3.0) < 1e-9 && std::fabs(d - 5.0) < 1e-9 && std::fabs(e - 5.0) < 1e-9,
        "the member thickness reads 1, 3 (centre and corner), 5 (middle and face)");
  // the gate the verdict reads
  const std::vector<char> j1 = break_judged(col1, n, n, n, 3), j3 = break_judged(col3, n, n, n, 3), j5 = break_judged(slab5, n, n, n, 3);
  const auto J = [&](const std::vector<char>& m, int i, int j, int k) { return m[(static_cast<std::size_t>(k) * n + j) * n + i] != 0; };
  std::printf("judged: 1-voxel column %d; 3 x 3 centre %d, corner %d; 5-voxel slab middle %d, face %d\n", J(j1, 10, 10, 10), J(j3, 10, 10, 10),
              J(j3, 11, 11, 10), J(j5, 10, 10, 10), J(j5, 10, 10, 12));
  check(!J(j1, 10, 10, 10) && J(j3, 10, 10, 10) && J(j3, 11, 11, 10) && J(j5, 10, 10, 10) && J(j5, 10, 10, 12),
        "the verdict's gate: a 1-voxel column is not judged; the 3 x 3 column (centre, corner) and the slab are");
}

void law() {
  const double Y = 31.0, k = 0.55;
  const Vec3 up{0, 0, 1};
  std::string by;
  const double sx[6] = {10, 0, 0, 0, 0, 0}, sz[6] = {0, 0, 10, 0, 0, 0}, cz[6] = {0, 0, -10, 0, 0, 0};
  const double t45 = 10.0, s45[6] = {0.5 * t45, 0, 0.5 * t45, 0, 0, 0.5 * t45};   // tension 10 along (1, 0, 1)/sqrt 2
  const double m1 = break_multiple(sx, Y, k, up, &by);
  const bool b1 = by == "tension";
  const double m2 = break_multiple(sz, Y, k, up, &by);
  const double m3 = break_multiple(cz, Y, k, up, &by);
  const bool b3 = by == "compression";
  const double m4 = break_multiple(s45, Y, k, up, &by);
  std::printf("law: tension along the layers %.4f (want %.4f), across %.4f (want %.4f), compression across %.4f (want %.4f), tension at 45 deg "
              "%.4f (want %.4f)\n", m1, Y / 10, m2, Y * k / 10, m3, Y / 10, m4, (Y * 0.5 + Y * k * 0.5) / 10);
  check(b1 && b3 && std::fabs(m1 - Y / 10) < 1e-9 && std::fabs(m2 - Y * k / 10) < 1e-9 && std::fabs(m3 - Y / 10) < 1e-9 &&
            std::fabs(m4 - (Y * 0.5 + Y * k * 0.5) / 10) < 1e-6,
        "the limit law: along, across (x z_knockdown), compression, and a tilted tension");
  // the review's biaxial case: xx 10 along the layers, zz 8 across them: the across one governs, 31 x 0.55 / 8
  const double bi[6] = {10, 0, 8, 0, 0, 0};
  const double m5 = break_multiple(bi, Y, k, up, &by);
  std::printf("law: biaxial xx 10, zz 8: %.4f (want %.4f) by %s\n", m5, Y * k / 8, by.c_str());
  check(std::fabs(m5 - Y * k / 8) < 1e-9 && by == "tension", "the limit law judges every principal stress (biaxial 2.13, not 3.10)");
}

int face_where(const StepModel& m, const Vec3& n, int axis, bool want_max);

// A made bar, 10 x 3 x 3 mm along x (the part and the print the same box), held at x = 0, 20 N along +x at x = 10:
// tension 20 / 9 = 2.22 MPa along the layers, so the first break about 31 / 2.22 = 13.95 away from the ends.
void bar() {
  const std::string w = std::string(TMP_DIR) + "/organic_break_check/BAR";
  std::filesystem::remove_all(w);
  std::filesystem::create_directories(w);
  const double L = 10, B = 3;
  const Vec3 c[8] = {{0, 0, 0}, {L, 0, 0}, {L, B, 0}, {0, B, 0}, {0, 0, B}, {L, 0, B}, {L, B, B}, {0, B, B}};
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  {
    std::ofstream f(w + "/bar.stl");
    f << "solid bar\n";
    for (const auto& q : t) {
      f << " facet normal 0 0 0\n  outer loop\n";
      for (int v : q) f << "   vertex " << c[v].x << " " << c[v].y << " " << c[v].z << "\n";
      f << "  endloop\n endfacet\n";
    }
    f << "endsolid bar\n";
  }
  const StepModel m = import_part_file_resolved(w + "/bar.stl");
  const StlMesh print = read_stl_file(w + "/bar.stl");
  BreakAsk ask;
  ask.print = &print.mesh;
  ask.part = &m;
  ask.fixed_faces = {face_where(m, {-1, 0, 0}, 0, false)};
  ask.loads = {{{face_where(m, {1, 0, 0}, 0, true)}, {20, 0, 0}}};
  ask.youngs_mpa = 3500;
  ask.poisson = 0.35;
  ask.yield_mpa = 31;
  ask.z_knockdown = 0.55;
  const BreakSize sz = organic_break_size(ask);
  const BreakResult r = organic_break_check(ask);
  const double want_bytes = 11250.0 * 3200.0 + 11250.0 * 73.0;
  std::printf("bar: size %d x %d x %d, %zu material voxels, %.0f bytes (want 11250, %.0f); ok %d %s verdict %s, first break %.4f at (%.2f, %.2f, "
              "%.2f) %s; force asked %s\n", sz.nx, sz.ny, sz.nz, sz.material_voxels, sz.bytes, want_bytes, r.ok, r.why.c_str(), r.verdict.c_str(),
              r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y, r.first_resolved.at.z, r.first_resolved.by.c_str(),
              r.json.substr(r.json.find("\"force_asked_n\""), 90).c_str());
  check(sz.material_voxels == 11250 && std::fabs(sz.bytes - want_bytes) < 1.0 && r.size.material_voxels == 11250,
        "the bar's size before the solve: 11,250 material voxels and their bytes, the same count the solve uses");
  check(r.ok && r.verdict == "pass" && r.first_resolved.found && std::fabs(r.first_resolved.multiple / (31.0 / (20.0 / 9.0)) - 1.0) < 0.10,
        "the bar's verdict is pass and its first break is within 10 % of 31 / 2.22");
}

int face_where(const StepModel& m, const Vec3& n, int axis, bool want_max) {
  int best = -1;
  double bv = 0.0;
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane || fi.plane_normal.x * n.x + fi.plane_normal.y * n.y + fi.plane_normal.z * n.z <= 0.99) continue;
    const double v = axis == 0 ? fi.plane_origin.x : axis == 1 ? fi.plane_origin.y : fi.plane_origin.z;
    if (best < 0 || (want_max ? v > bv : v < bv)) { best = f; bv = v; }
  }
  return best;
}

double g_tol = 1e-2;   // the marks' solve tolerance (argv "tol:1e-8": the SPARSE split, C1 Piece 1)

struct Piece {
  std::string name, job, model, tensor;
  double yield;          // the limit along the layers it is read at
  Vec3 shift;            // the grid's shift (the study's)
  double want_all, want_resolved;   // the study's first breaks (0: not given)
  Vec3 want_at;
  std::string want_class;
  long long want_voxels;            // mark 2 (0: none)
};

void mark(const std::string& dir, const Piece& p, const Material& pla) {
  const std::string w = std::string(TMP_DIR) + "/organic_break_check/" + p.name;
  std::filesystem::remove_all(w);
  std::filesystem::create_directories(w + "/out");
  std::filesystem::copy_file(dir + "/" + p.model, w + "/" + p.model);
  std::filesystem::copy_file(dir + "/" + p.tensor, w + "/stress.tensor");
  std::string job = slurp(dir + "/" + p.job);
  write(w + "/job.json", job);
  const StepModel m = import_part_file_resolved(w + "/" + p.model);
  int fixed = -1, loaded = -1;
  Vec3 force{0, 0, -20};
  if (p.model == "BR.stl") {
    fixed = face_where(m, {-1, 0, 0}, 0, false);
    loaded = face_where(m, {0, 0, 1}, 2, true);
  } else {
    fixed = face_where(m, {0, 0, -1}, 2, false);
    loaded = face_where(m, {0, 0, 1}, 2, true);
  }
  write(w + "/strength_job.json",
        "{\"model\": \"" + p.model + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, \"loads\": {\"minimize_plastic\": "
        "true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" + std::to_string(fixed) + "], \"groups\": [{\"face_ids\": [" +
        std::to_string(loaded) + "], \"force\": [0, 0, -20]}]}, \"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
        "false}, \"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
        "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}");
  // lay it (the file job), keeping the kept bars and the posts; the check here is the new one
  std::vector<BreakBar> bars;
  std::vector<BreakPost> posts;
  const StrengthCheck real = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  StrengthCheck sc = real;
  sc.run_organic = [&](const StrengthAsk& ask) {
    if (ask.bars)
      for (std::size_t b = 0; b < ask.bars->bars.size(); ++b)
        if (!ask.kept || (b < ask.kept->size() && (*ask.kept)[b]))
          bars.push_back({ask.bars->bars[b].a, ask.bars->bars[b].b, ask.bars->bars[b].width});
    if (ask.made)
      for (const MeshSpec::Post& q : ask.made->posts) posts.push_back({q.x, q.y, q.z_bottom, q.z_top, 0.9});
    StrengthDone d;
    d.ok = true;
    d.code = "ok";
    d.exit_code = 0;
    d.json = "{\"verdict\": \"not run (C1 marks: the lay only)\"}";
    return d;
  };
  const FileResult fr = run_file_job(w + "/job.json", w + "/out", 0, nullptr, &sc);
  std::printf("[%s] lay ok %d code %s, bars %zu kept, posts %zu; faces fixed %d loaded %d\n", p.name.c_str(), fr.ok, fr.code.c_str(), bars.size(),
              posts.size(), fixed, loaded);
  if (!fr.ok) { check(false, (p.name + ": the lay").c_str()); return; }
  const StlMesh print = read_stl_file(w + "/out/lattice.stl");
  BreakAsk ask;
  ask.print = &print.mesh;
  ask.part = &m;
  ask.fixed_faces = {fixed};
  ask.loads = {{{loaded}, force}};
  ask.bars = bars;
  ask.posts = posts;
  ask.youngs_mpa = pla.youngs_modulus_mpa;
  ask.poisson = pla.poisson;
  ask.yield_mpa = p.yield;
  ask.z_knockdown = pla.z_knockdown;
  ask.grid_shift = p.shift;
  ask.tolerance = g_tol;
  const BreakSize sz = organic_break_size(ask);
  ask.also_connected_ball = true;   // the review's question 1.6, for the record
  std::printf("[%s] before the solve: grid %d x %d x %d, material voxels %zu, bytes estimate %.0f\n", p.name.c_str(), sz.nx, sz.ny, sz.nz,
              sz.material_voxels, sz.bytes);
  const BreakResult r = organic_break_check(ask);
  std::printf("[%s] ok %d %s; verdict %s; first break (judged) %.4f at (%.2f, %.2f, %.2f) %s, thickness %.1f; all points %.4f at (%.2f, %.2f, %.2f) "
              "%s, thickness %.1f; rounds %d, %.1f s, peak %.0f MB\n[%s] json %s\n", p.name.c_str(), r.ok, r.why.c_str(), r.verdict.c_str(),
              r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y, r.first_resolved.at.z, r.first_resolved.cls.c_str(),
              r.first_resolved.thickness_voxels, r.first_all.multiple, r.first_all.at.x, r.first_all.at.y, r.first_all.at.z, r.first_all.cls.c_str(),
              r.first_all.thickness_voxels, r.rounds, r.seconds, r.peak_mb, p.name.c_str(), r.json.c_str());
  if (p.want_voxels > 0) {
    // The check's own grid (review 5: what the check solves is what is counted); the size counted before the solve beside it.
    const std::size_t n = r.size.material_voxels;
    const double dv = std::fabs(static_cast<double>(n) - static_cast<double>(p.want_voxels)) / static_cast<double>(p.want_voxels);
    std::printf("[%s] MARK 2: material voxels on the check's grid %zu against %lld: %.4f %% (counted before the solve: %zu)\n", p.name.c_str(), n,
                p.want_voxels, 100.0 * dv, sz.material_voxels);
    check(dv <= 0.001, (p.name + ": mark 2, the voxels within 0.1 %").c_str());
  }
  std::printf("[%s] connected ball (the record's question): %zu voxels' balls hold material not connected to them; judged %.4f at (%.2f, %.2f, "
              "%.2f), all points %.4f at (%.2f, %.2f, %.2f)\n", p.name.c_str(), r.connected_split_voxels, r.connected_judged.multiple,
              r.connected_judged.at.x, r.connected_judged.at.y, r.connected_judged.at.z, r.connected_all.multiple, r.connected_all.at.x,
              r.connected_all.at.y, r.connected_all.at.z);
  check(r.first_resolved.cls == p.want_class, (p.name + ": mark 1, the class").c_str());
  auto near = [](double a, double b, double tol) { return std::fabs(a - b) <= tol * b; };
  const double dist = std::hypot(std::hypot(r.first_resolved.at.x - p.want_at.x, r.first_resolved.at.y - p.want_at.y), r.first_resolved.at.z - p.want_at.z);
  std::printf("[%s] MARK 1: judged %.4f against %.4f (%.2f %%)%s; place %.2f mm from the study's; class %s (study %s)\n", p.name.c_str(),
              r.first_resolved.multiple, p.want_resolved, 100.0 * (r.first_resolved.multiple / p.want_resolved - 1.0),
              p.want_all > 0 ? (", all points " + std::to_string(r.first_all.multiple) + " against " + std::to_string(p.want_all)).c_str() : "", dist,
              r.first_resolved.cls.c_str(), p.want_class.c_str());
  check(r.ok && near(r.first_resolved.multiple, p.want_resolved, 0.01) && (p.want_all <= 0 || near(r.first_all.multiple, p.want_all, 0.01)) && dist <= 0.5,
        (p.name + ": mark 1, within 1 % and 0.5 mm").c_str());
}
// Mark 5 (plan section 5): the size guard on a made job. (1) The guard alone on the made bracket's print, its memory read
// around it: it must trip with no allocation over 0.5 GB. (2) The same made job through the file job with the real
// check and a limit of 1 GB set by the test-only argument (StrengthAsk::break_memory_limit_bytes): the file is KEPT and
// the block says not checked, too big, with the numbers.
void oversize(const std::string& dir) {
  const std::string w = std::string(TMP_DIR) + "/organic_break_check/OVERSIZE";
  std::filesystem::remove_all(w);
  std::filesystem::create_directories(w + "/out");
  std::filesystem::copy_file(dir + "/BR.stl", w + "/BR.stl");
  std::filesystem::copy_file(dir + "/BR.tensor", w + "/stress.tensor");
  std::string job = slurp(dir + "/BRT_d_job.json");
  job.insert(job.find('{') + 1, "\"break_cache\": \"cache\", ");
  write(w + "/job.json", job);
  const StepModel m = import_part_file_resolved(w + "/BR.stl");
  const int fixed = face_where(m, {-1, 0, 0}, 0, false), loaded = face_where(m, {0, 0, 1}, 2, true);
  write(w + "/strength_job.json",
        "{\"model\": \"BR.stl\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, \"loads\": {\"minimize_plastic\": "
        "true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], \"anchor_face_ids\": [" + std::to_string(fixed) + "], \"groups\": [{\"face_ids\": [" +
        std::to_string(loaded) + "], \"force\": [0, 0, -20]}]}, \"lattice\": {\"topology\": \"octet\", \"require_lattice_void_reaches_exterior\": "
        "false}, \"grading\": {\"topology\": \"octet\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, \"intent\": \"structural\"}, "
        "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}");
  // (1) the guard alone, on the study's made print of this job
  {
    const StlMesh print = read_stl_file(dir + "/BRT_d_file/lattice.stl");
    BreakAsk ask;
    ask.print = &print.mesh;
    ask.part = &m;
    ask.memory_limit_bytes = 1e9;
    const double before = process_memory().peak_rss_mb, rss0 = process_memory().rss_mb;
    const BreakSize sz = organic_break_size(ask);
    const double after = process_memory().peak_rss_mb;
    std::printf("oversize (1): %zu material voxels, %.2f GB needed, %.2f GB allowed; process peak %.0f MB before (resident %.0f), %.0f MB after\n",
                sz.material_voxels, sz.bytes / 1e9, sz.limit_bytes / 1e9, before, rss0, after);
    check(sz.bytes > sz.limit_bytes && after - rss0 < 512.0, "mark 5 (1): the guard trips, with under 0.5 GB allocated by it");
  }
  // (2) through the file job, the real check, the test-only limit
  const StrengthCheck real = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);
  StrengthCheck sc = real;
  sc.run_organic = [&](const StrengthAsk& a) {
    StrengthAsk b = a;
    b.break_memory_limit_bytes = 1e9;
    return real.run_organic(b);
  };
  const FileResult fr = run_file_job(w + "/job.json", w + "/out", 0, nullptr, &sc);
  const std::string rep = slurp(w + "/out/lattice_file.json");
  const std::size_t bp = rep.find("\"break\": {");
  const std::string blk = bp == std::string::npos ? std::string() : rep.substr(bp, rep.find('}', rep.find("\"bytes_allowed\"", bp)) - bp + 1);
  std::printf("oversize (2): ok %d code %s accepted %d; file kept %d; %s\n", fr.ok, fr.code.c_str(), fr.strength_accepted,
              std::filesystem::exists(w + "/out/lattice.stl"), blk.c_str());
  check(fr.ok && !fr.strength_accepted && std::filesystem::exists(w + "/out/lattice.stl") && blk.find("\"not_checked\"") != std::string::npos &&
            blk.find("\"too_big\"") != std::string::npos && rep.find("\"answer\": \"break\"") != std::string::npos,
        "mark 5 (2): the file is kept, the block says not checked: too big, with the numbers");
}

}  // namespace

int main(int argc, char** argv) {
  gate();
  law();
  bar();
  if (argc >= 3 && std::string(argv[1]) == "oversize") oversize(argv[2]);
  if (argc >= 3 && std::string(argv[1]) == "marks") {
    const std::string dir = argv[2];
    const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
    const Material& pla = lib.at("PLA");
    // The study sampled its voxel centres 1.2345e-6 mm off in x and 2.3456e-6 mm in y (off any face), so a centre never sat
    // on a face; on the block's shifted grid the centres at x, y = 0 and 24 lie exactly ON its outer faces, and a tie
    // there adds a half-outside skin. The same offsets here, in voxels of 0.2 mm.
    const double ox = 1.2345e-6 / 0.2, oy = 2.3456e-6 / 0.2;
    std::vector<Piece> pieces = {
        // S7: BRACKET-TRACED first break 11.55 at (8.5, 13.1, 14.5), the fillet's skin (solid), 548,231 voxels
        {"BRACKET-TRACED", "BRT_d_job.json", "BR.stl", "BR.tensor", 31.0, {ox, oy, 0}, 11.5506, 11.5506, {8.5, 13.1, 14.5}, "solid", 548231},
        // S7: BRACKET-GROWN 9.20 all / 9.28 judged, at (8.1, 15.7, 14.3)
        {"BRACKET-GROWN", "BRG_d_job.json", "BR.stl", "BR.tensor", 31.0, {ox, oy, 0}, 9.2013, 9.2792, {8.1, 15.7, 14.3}, "solid", 0},
        // S5: the SPARSE block, judged first break 3.374 at 55 MPa, the corner foot (6.8, 1.6, 4.5), on the study's shifted grid
        {"SPARSE", "SP_job.json", "SP.stl", "SP.tensor", 55.0, {-0.5 + ox, -0.5 + oy, 0}, 0.0, 3.3743, {6.8, 1.6, 4.5}, "vine", 0}};
    for (int i = 3; i < argc; ++i)
      if (std::string(argv[i]).rfind("tol:", 0) == 0) g_tol = std::atof(argv[i] + 4);
    for (int i = 3; i < argc; ++i) {
      if (std::string(argv[i]).rfind("tol:", 0) == 0) continue;
      std::vector<Piece> keep;
      for (const Piece& p : pieces) if (p.name == argv[i]) keep.push_back(p);
      if (!keep.empty()) pieces = keep;
    }
    for (const Piece& p : pieces) mark(dir, p, pla);
  }
  std::printf("%d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
