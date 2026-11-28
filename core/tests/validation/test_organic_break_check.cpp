// Organic strength CUT 1, stages C1 and C2: the break check (lattice_layout_break.hpp).
// With no arguments: the member thickness and the verdict's own gate (break_judged) on made shapes (S4's: a 1-voxel
// column, a 3 x 3 column at its centre and corner, a 5-voxel slab), the limit law (with the review's biaxial case), and
// one end-to-end check of a small made bar (seconds). With "marks DIR": marks 1 and 2 of the plan (section 5) on the made pieces, laid here
// by the file job from the made inputs in DIR (the study's made jobs: BR.stl, BR.tensor, BRT_d_job.json,
// BRG_d_job.json, SP.stl, SP.tensor, SP_job.json), each through organic_break_check at 0.2 mm and tolerance 1e-2.
#include <cmath>
#include <array>
#include <functional>
#include <map>
#include <memory>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_break.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_organic.hpp"
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
  // the tilted tension: since review C2 A5 the normal stress on every direction n is read against the limit for n, so a
  // direction between the tension and the build direction reads lower than the tension's own 2.4025; the least over
  // the xz plane, scanned finely here, is what the law must give (it computes the exact least, so within 0.1 %)
  double scan = 1e300;
  for (int i = 0; i <= 9000; ++i) {
    const double th = 0.5 * M_PI * i / 9000.0, c = std::cos(th - 0.25 * M_PI), rise = std::cos(th);
    const double t = 10.0 * c * c;
    if (t > 0.0) scan = std::min(scan, (Y * (1 - rise * rise) + Y * k * rise * rise) / t);
  }
  std::printf("law: tilted tension, least over the plane %.4f (the tension's own direction 2.4025)\n", scan);
  check(b1 && b3 && std::fabs(m1 - Y / 10) < 1e-9 && std::fabs(m2 - Y * k / 10) < 1e-9 && std::fabs(m3 - Y / 10) < 1e-9 &&
            m4 <= 2.4025 + 1e-9 && m4 <= scan + 1e-9 && m4 >= 0.999 * scan,
        "the limit law: along, across (x z_knockdown), compression, and a tilted tension (the least over every direction)");
  // the review's biaxial case: xx 10 along the layers, zz 8 across them: the across one governs, 31 x 0.55 / 8
  const double bi[6] = {10, 0, 8, 0, 0, 0};
  const double m5 = break_multiple(bi, Y, k, up, &by);
  std::printf("law: biaxial xx 10, zz 8: %.4f (want %.4f) by %s\n", m5, Y * k / 8, by.c_str());
  check(std::fabs(m5 - Y * k / 8) < 1e-9 && by == "tension", "the limit law judges every principal stress (biaxial 2.13, not 3.10)");
  // review C2 A5: principals 10 and 8 at 45 degrees to the layers (xx = zz = 9, xz = 1): the stress ACROSS the layers,
  // 9 MPa, gives 31 x 0.55 / 9 = 1.894 (the principal reading alone gave 2.40); a direction near the build direction
  // reads a little lower still, so the law gives at most 1.894
  const double ob[6] = {9, 0, 9, 0, 0, 1};
  const double m6 = break_multiple(ob, Y, k, up, &by);
  std::printf("law: 10 and 8 at 45 degrees: %.4f (at most %.4f; the principal reading alone 2.40) by %s\n", m6, Y * k / 9, by.c_str());
  check(m6 <= Y * k / 9 + 1e-9 && m6 > 1.8 && by == "tension", "the limit law judges the stress across the layers at any angle (at most 1.894)");
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
  const double want_bytes = 11250.0 * 3200.0 + 11250.0 * 157.0;
  std::printf("bar: size %d x %d x %d, %zu material voxels, %.0f bytes (want 11250, %.0f); ok %d %s verdict %s, first break %.4f at (%.2f, %.2f, "
              "%.2f) %s; force asked %s\n", sz.nx, sz.ny, sz.nz, sz.material_voxels, sz.bytes, want_bytes, r.ok, r.why.c_str(), r.verdict.c_str(),
              r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y, r.first_resolved.at.z, r.first_resolved.by.c_str(),
              r.json.substr(r.json.find("\"force_asked_n\""), 90).c_str());
  check(sz.material_voxels == 11250 && std::fabs(sz.bytes - want_bytes) < 1.0 && r.size.material_voxels == 11250,
        "the bar's size before the solve: 11,250 material voxels and their bytes, the same count the solve uses");
  // C11: with the 0.3 mm ball (the lead's ruling) the first break is read at the held face's corner, where the full
  // clamp (every direction held, so Poisson's contraction is stopped there) concentrates the stress: 10.88, 22 % under
  // the hand number. The 0.9 mm ball averaged it away (13.36). So the mark is: pass, never more than 10 % over the hand
  // number, and at most 25 % under it (the safe side, the clamp's own concentration).
  const double hand = 31.0 / (20.0 / 9.0), ratio = r.first_resolved.multiple / hand;
  check(r.ok && r.verdict == "pass" && r.first_resolved.found && ratio <= 1.10 && ratio >= 0.75,
        "the bar's verdict is pass and its first break is from 25 % under to 10 % over 31 / 2.22 (the held corner's concentration)");
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

std::string g_print;       // argv "print:PATH": read this print file instead of the lay's (C3 item b: the study's own print)
bool g_matched = false;   // argv "matched": the study's voxels (C3 item b), see study_voxels
// The study's voxel rule (S5: each closed shell of the print filled by its own inside test, the shells' union), written
// here from the product voxeliser: the print split into its closed shells (triangles joined by shared corners, the
// corners welded by their exact coordinates), each shell voxelised on its own (one closed shell: winding = inside), OR-ed.
std::vector<char> study_voxels(const TriangleMesh& mesh, const VoxelGrid& ref) {
  std::map<std::array<double, 3>, int> weld;
  std::vector<int> id(mesh.vertices.size());
  for (std::size_t v = 0; v < mesh.vertices.size(); ++v) {
    const std::array<double, 3> k{mesh.vertices[v].x, mesh.vertices[v].y, mesh.vertices[v].z};
    id[v] = weld.emplace(k, static_cast<int>(weld.size())).first->second;
  }
  std::vector<int> up(weld.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = static_cast<int>(i);
  std::function<int(int)> find = [&](int x) { return up[static_cast<std::size_t>(x)] == x ? x : up[static_cast<std::size_t>(x)] = find(up[static_cast<std::size_t>(x)]); };
  for (const auto& t : mesh.triangles) {
    const int a = find(id[static_cast<std::size_t>(t[0])]), b = find(id[static_cast<std::size_t>(t[1])]), c = find(id[static_cast<std::size_t>(t[2])]);
    up[static_cast<std::size_t>(b)] = a;
    up[static_cast<std::size_t>(find(c))] = find(a);
  }
  std::map<int, TriangleMesh> shells;
  for (const auto& t : mesh.triangles) {
    TriangleMesh& m = shells[find(id[static_cast<std::size_t>(t[0])])];
    const int base = static_cast<int>(m.vertices.size());
    for (int q = 0; q < 3; ++q) m.vertices.push_back(mesh.vertices[static_cast<std::size_t>(t[q])]);
    m.triangles.push_back({base, base + 1, base + 2});
  }
  std::vector<char> out(static_cast<std::size_t>(ref.nx) * ref.ny * ref.nz, 0);
  for (const auto& [k, m] : shells) {
    const VoxelGrid v = voxelize_onto_grid(m, ref);
    for (std::size_t e = 0; e < out.size(); ++e) out[e] = out[e] || v.tags[e] != VoxelTag::Empty;
  }
  std::size_t n = 0;
  for (char c : out) n += c != 0;
  std::printf("study voxels: %zu closed shells, %zu material voxels\n", shells.size(), n);
  return out;
}

// C10 G2, TEST-ONLY candidates (argv "smooth:R" the smoothing ball's radius in mm, "connected" also the connected-ball
// reading); the product's default (0.9 mm radius, every material voxel in the ball) is never changed by them
double g_smooth = BreakAsk{}.smooth_mm;   // C11: the shipping default unless "smooth:R" is given
bool g_connected = false;
bool g_big = false;   // C11, mark 6 (TEST-ONLY): "big" lets the steady mode run over 3 GB; run only while the lead holds HEAVY.lock
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
  const StlMesh print = read_stl_file(g_print.empty() ? w + "/out/lattice.stl" : g_print);
  if (!g_print.empty()) std::printf("[%s] the print read from %s\n", p.name.c_str(), g_print.c_str());
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
  if (g_matched) ask.material_override = [&](const VoxelGrid& ref) { return study_voxels(print.mesh, ref); };
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

// C3 helpers on made files (no solve): "size PRINT PART VOXEL_MM" = organic_break_size at that grid (M1's 0.1 mm need);
// "postwidth PRINT X Y Z" = the material across a post at height Z, along x and along y through (X, Y), read on a 0.02 mm
// grid (P2: no touched post under two lines).
void size_of(const std::string& print_path, const std::string& part_path, double voxel) {
  const StlMesh print = read_stl_file(print_path);
  const StepModel m = import_part_file_resolved(part_path);
  BreakAsk ask;
  ask.print = &print.mesh;
  ask.part = &m;
  ask.voxel_mm = voxel;
  ask.memory_limit_bytes = 1e15;   // read the size only
  const BreakSize sz = organic_break_size(ask);
  std::printf("size at %.3f mm: grid %d x %d x %d, material voxels %zu, bytes %.0f (%.2f GB); 40 %% of this machine %.2f GB\n", voxel, sz.nx,
              sz.ny, sz.nz, sz.material_voxels, sz.bytes, sz.bytes / 1e9, break_memory_limit_bytes() / 1e9);
}
void post_width(const std::string& print_path, double x, double y, double z) {
  const StlMesh print = read_stl_file(print_path);
  const double h = 0.02;
  const int n = 200;   // 4 mm each way
  VoxelGrid ref;
  ref.nx = n;
  ref.ny = n;
  ref.nz = 1;
  ref.spacing = h;
  ref.origin = {x - 0.5 * n * h + 1.2345e-7, y - 0.5 * n * h + 2.3456e-7, z - 0.5 * h};
  const VoxelGrid vg = voxelize_onto_grid(print.mesh, ref);
  const auto in = [&](int i, int j) { return vg.tags[static_cast<std::size_t>(j) * n + i] != VoxelTag::Empty; };
  const int c = n / 2;
  int x0 = c, x1 = c, y0 = c, y1 = c;
  if (in(c, c)) {
    while (x0 > 0 && in(x0 - 1, c)) --x0;
    while (x1 < n - 1 && in(x1 + 1, c)) ++x1;
    while (y0 > 0 && in(c, y0 - 1)) --y0;
    while (y1 < n - 1 && in(c, y1 + 1)) ++y1;
  }
  std::printf("postwidth at (%.3f, %.3f, %.3f): material %s; across x %.3f mm, across y %.3f mm\n", x, y, z, in(c, c) ? "yes" : "NO",
              in(c, c) ? (x1 - x0 + 1) * h : 0.0, in(c, c) ? (y1 - y0 + 1) * h : 0.0);
}

// C4, mark 7 (grid-placement steadiness): "steady PRINT PART FIXED LOADED FZ YIELD SHIFT_MM POSTS" runs the check on a
// made print at one grid shift (the same shift on all three axes), one solver thread, and prints the verdict, the first
// break, the posts' share of the force and the places under the pass line. POSTS: "x,y,zb,zt;..." (the file's
// print_check.posts), or "-" for none.
void steady(char** a) {
  const StlMesh print = read_stl_file(a[0]);
  const StepModel m = import_part_file_resolved(a[1]);
  const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
  const Material& pla = lib.at("PLA");
  BreakAsk ask;
  ask.print = &print.mesh;
  ask.part = &m;
  ask.fixed_faces = {std::atoi(a[2])};
  ask.loads = {{{std::atoi(a[3])}, {0, 0, std::atof(a[4])}}};
  ask.youngs_mpa = pla.youngs_modulus_mpa;
  ask.poisson = pla.poisson;
  ask.yield_mpa = std::atof(a[5]);
  ask.z_knockdown = pla.z_knockdown;
  const double sh = std::atof(a[6]) / ask.voxel_mm;
  ask.grid_shift = {sh, sh, sh};
  if (std::string(a[7]) != "-") {
    std::stringstream ss(a[7]);
    std::string one;
    while (std::getline(ss, one, ';')) {
      BreakPost q;
      double w = 0.0;   // C6: an optional fifth number, the drawn width (x, y then the drawn centre)
      if (std::sscanf(one.c_str(), "%lf,%lf,%lf,%lf,%lf", &q.x, &q.y, &q.z_bottom, &q.z_top, &w) == 5 && w > 0.0) q.width = w;
      ask.posts.push_back(q);
    }
  }
  // C5: optional a[8] = the voxel size in mm; a[9] = "binary": whole voxels by their centre (the product voxeliser through
  // the test-only material_override, which also keeps the whole-voxel gate and equal weights): the rule before C4
  if (a[8]) ask.voxel_mm = std::atof(a[8]);
  if (a[8] && a[9] && std::string(a[9]) == "binary")
    ask.material_override = [&](const VoxelGrid& ref) {
      const VoxelGrid v = voxelize_onto_grid(print.mesh, ref);
      std::vector<char> m(v.tags.size(), 0);
      for (std::size_t e = 0; e < m.size(); ++e) m[e] = v.tags[e] != VoxelTag::Empty;
      return m;
    };
  ask.grid_shift = {std::atof(a[6]) / ask.voxel_mm, std::atof(a[6]) / ask.voxel_mm, std::atof(a[6]) / ask.voxel_mm};
  const BreakSize sz0 = organic_break_size(ask);
  std::printf("STEADY size at %.3f mm: %zu material voxels (centre count), %.2f GB estimate\n", ask.voxel_mm, sz0.material_voxels, sz0.bytes / 1e9);
  if (sz0.bytes > 3e9 && !g_big) { std::printf("STEADY skipped: over 3 GB\n"); return; }   // C11: "big" (mark 6, run only under the lead's lock)
  fea_set_matfree_threads(1);
  ask.smooth_mm = g_smooth;                // C10 G2 (test-only)
  ask.also_connected_ball = g_connected;
  const BreakResult r = organic_break_check(ask);
  if (g_connected)
    std::printf("STEADY connected ball (radius %.2f): judged %.4f at (%.2f, %.2f, %.2f); all points %.4f\n", g_smooth, r.connected_judged.multiple,
                r.connected_judged.at.x, r.connected_judged.at.y, r.connected_judged.at.z, r.connected_all.multiple);
  else
    std::printf("STEADY ball radius %.2f\n", g_smooth);
  double pf = 0.0;
  std::string per;
  for (const BreakClass& c : r.classes)
    if (c.cls == "post") {
      pf += std::fabs(c.section_force_n);
      char b[160];
      std::snprintf(b, sizeof b, " post %d: own %.4f (%s), section %.4f, %.4f N", c.post, c.all.multiple, c.all.resolved ? "judged" : "not judged",
                    c.section_multiple, c.section_force_n);
      per += b;
    }
  const double F = std::fabs(std::atof(a[4]));
  std::printf("STEADY shift %.2f mm: ok %d %s; verdict %s; first break %.4f at (%.2f, %.2f, %.2f) %s; all points %.4f; posts' share %.2f %%;%s; "
              "voxels %zu; rounds %d, %.1f s, peak %.0f MB\n",
              std::atof(a[6]), r.ok, r.why.c_str(), r.verdict.c_str(), r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y,
              r.first_resolved.at.z, r.first_resolved.cls.c_str(), r.first_all.multiple, F > 0 ? 100.0 * pf / F : 0.0, per.c_str(),
              r.size.material_voxels, r.rounds, r.seconds, r.peak_mb);
  std::printf("STEADY all points %.4f at (%.2f, %.2f, %.2f) %s %s; voxel %.3f mm%s\n", r.first_all.multiple, r.first_all.at.x, r.first_all.at.y,
              r.first_all.at.z, r.first_all.cls.c_str(), r.first_all.resolved ? "judged" : "not judged", ask.voxel_mm, ask.material_override ? ", binary" : "");
  {
    std::string pp, why;
    for (std::size_t q = 0; q < r.post_paths.size(); ++q) {
      char b[160];
      std::snprintf(b, sizeof b, " post %zu %.2f %% (shaft %d foot %d top %d)", q, 100.0 * r.post_paths[q].share, r.post_paths[q].shaft, r.post_paths[q].foot,
                    r.post_paths[q].top);
      pp += b;
    }
    for (const std::string& x : r.not_proven_because) why += x + " ";
    std::printf("STEADY load path: %zu voxels not resolved; thin regions: %zu slivers (%zu voxels, left out), %zu members, %zu connectors\n",
                r.unresolved_voxels, r.sliver_regions, r.sliver_voxels, r.member_regions, r.connector_regions);
    std::printf("STEADY load path: because [%s]; unresolved energy %.2f %%, largest region %.2f %% at (%.2f, %.2f, %.2f), %zu voxels;%s\n", why.c_str(),
                100.0 * r.unresolved_energy_share, 100.0 * r.largest_unresolved_share, r.largest_unresolved_at.x, r.largest_unresolved_at.y,
                r.largest_unresolved_at.z, r.largest_unresolved_voxels, pp.c_str());
    if (!r.joint_regions.empty())
      std::printf("STEADY load path: the region with the most load %.2f %% at (%.2f, %.2f, %.2f), %zu voxels (energy %.2f %%)\n",
                  100.0 * r.joint_regions.front().load_share, r.joint_regions.front().at.x, r.joint_regions.front().at.y, r.joint_regions.front().at.z,
                  r.joint_regions.front().voxels, 100.0 * r.joint_regions.front().energy_share);
    else
      std::printf("STEADY load path: no region carries over 1 %% of the load\n");
  }
  std::printf("STEADY places under the pass line:");
  for (const BreakPoint& q : r.not_judged_under) std::printf(" %.3f@(%.1f,%.1f,%.1f)%s", q.multiple, q.at.x, q.at.y, q.at.z, q.cls.c_str());
  std::printf("\n");
}

// C6: "remake JOB OUTDIR" makes the made job's file (no strength job) once as it is, then again with EVERY post kept at
// two lines or more: each post drawn max(post_mm, 2 x bead_mm) wide and moved inward where the part's surface would trim
// it (the posts step's own MeshSpec::post_wide, set here by the test, no product input). Prints each post before and
// after and the print check's verdict; the re-made file is OUTDIR/lattice.stl.
double reach(const TriangleMesh& m, const Vec3& o, double dx, double dy) {
  double best = 1e300;
  for (const auto& t : m.triangles) {
    const Vec3& a = m.vertices[static_cast<std::size_t>(t[0])];
    const Vec3& b = m.vertices[static_cast<std::size_t>(t[1])];
    const Vec3& c = m.vertices[static_cast<std::size_t>(t[2])];
    const Vec3 e1{b.x - a.x, b.y - a.y, b.z - a.z}, e2{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 pv{dy * e2.z, -dx * e2.z, dx * e2.y - dy * e2.x};
    const double det = e1.x * pv.x + e1.y * pv.y + e1.z * pv.z;
    if (std::fabs(det) < 1e-14) continue;
    const Vec3 tv{o.x - a.x, o.y - a.y, o.z - a.z};
    const double u = (tv.x * pv.x + tv.y * pv.y + tv.z * pv.z) / det;
    if (u < 0.0 || u > 1.0) continue;
    const Vec3 qv{tv.y * e1.z - tv.z * e1.y, tv.z * e1.x - tv.x * e1.z, tv.x * e1.y - tv.y * e1.x};
    const double v = (dx * qv.x + dy * qv.y) / det;
    if (v < 0.0 || u + v > 1.0) continue;
    const double sd = (e2.x * qv.x + e2.y * qv.y + e2.z * qv.z) / det;
    if (sd > 0.0) best = std::min(best, sd);
  }
  return best;
}
void remake(const std::string& job_path, const std::string& out) {
  FileJob job;
  StepModel model;
  FileResult r;
  if (!load_file_job(job_path, 1, job, model, r, nullptr)) { std::printf("REMAKE load failed: %s\n", r.why.c_str()); return; }
  job.strength_job.clear();
  std::filesystem::create_directories(out + "/before");
  const FileResult r0 = make_lattice_file(model, job, out + "/before/lattice.stl", nullptr, nullptr, nullptr);
  std::printf("REMAKE as made: ok %d code %s, posts %zu\n", r0.ok, r0.code.c_str(), r0.made.posts.size());
  const double w = std::max(job.options.mesh.post_mm, 2.0 * job.settings.bead_mm);
  std::vector<MeshSpec::PostWide> wide;
  for (const MeshSpec::Post& p : r0.made.posts) {
    double px = 1e300, nx = 1e300, py = 1e300, ny = 1e300;
    for (int s2 = 0; s2 < 3; ++s2) {
      const double z = s2 == 0 ? p.z_bottom + 0.3 : s2 == 1 ? 0.5 * (p.z_bottom + p.z_top) : p.z_top - 0.3;
      px = std::min(px, reach(model.mesh, {p.x, p.y, z}, 1, 0));
      nx = std::min(nx, reach(model.mesh, {p.x, p.y, z}, -1, 0));
      py = std::min(py, reach(model.mesh, {p.x, p.y, z}, 0, 1));
      ny = std::min(ny, reach(model.mesh, {p.x, p.y, z}, 0, -1));
    }
    const double h = 0.5 * w;
    const double ox = px < h ? -(h - px) : nx < h ? (h - nx) : 0.0, oy = py < h ? -(h - py) : ny < h ? (h - ny) : 0.0;
    wide.push_back({p.x, p.y, p.z_top, p.z_bottom, w, ox, oy});
    std::printf("REMAKE post at (%.4f, %.4f) z %.2f-%.2f: room +x %.3f -x %.3f +y %.3f -y %.3f; drawn %.3f wide, moved (%.3f, %.3f)\n", p.x, p.y,
                p.z_bottom, p.z_top, px, nx, py, ny, w, ox, oy);
  }
  job.options.mesh.post_wide = wide;
  std::filesystem::create_directories(out);
  const FileResult r1 = make_lattice_file(model, job, out + "/lattice.stl", nullptr, nullptr, nullptr);
  std::printf("REMAKE re-made: ok %d code %s (%s), print clean %d, posts %zu\n", r1.ok, r1.code.c_str(), r1.why.c_str(), r1.made.print_clean,
              r1.made.posts.size());
  std::string list;
  for (const MeshSpec::Post& p : r1.made.posts) {
    double ww, cx, cy;
    job.options.mesh.post_box(p, ww, cx, cy);
    char b[160];
    std::snprintf(b, sizeof b, "%s%.4f,%.4f,%.4f,%.4f,%.4f", list.empty() ? "" : ";", cx, cy, p.z_bottom, p.z_top, ww);
    list += b;
  }
  std::printf("REMAKE posts (drawn centre, z, width): %s\n", list.c_str());
}

// C7: the load-path rule on two made shapes. Boxes written as one STL (each its own closed shell, overlapping a little).
// extra convex prisms: each a list of triangles, oriented outward from the prism's own centroid
std::vector<std::vector<std::array<Vec3, 3>>> g_prisms;
void write_boxes(const std::string& path, const std::vector<std::array<double, 6>>& boxes) {
  std::ofstream f(path);
  f << "solid boxes\n";
  for (const auto& pr : g_prisms) {
    Vec3 cen{0, 0, 0};
    int nv = 0;
    for (const auto& t : pr)
      for (const Vec3& v : t) { cen = {cen.x + v.x, cen.y + v.y, cen.z + v.z}; ++nv; }
    cen = {cen.x / nv, cen.y / nv, cen.z / nv};
    for (auto t : pr) {
      const Vec3 u{t[1].x - t[0].x, t[1].y - t[0].y, t[1].z - t[0].z}, w{t[2].x - t[0].x, t[2].y - t[0].y, t[2].z - t[0].z};
      const Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
      if (n.x * (t[0].x - cen.x) + n.y * (t[0].y - cen.y) + n.z * (t[0].z - cen.z) < 0) std::swap(t[1], t[2]);
      f << " facet normal 0 0 0\n  outer loop\n";
      for (const Vec3& v : t) f << "   vertex " << v.x << " " << v.y << " " << v.z << "\n";
      f << "  endloop\n endfacet\n";
    }
  }
  for (const auto& b : boxes) {
    const Vec3 c[8] = {{b[0], b[1], b[2]}, {b[3], b[1], b[2]}, {b[3], b[4], b[2]}, {b[0], b[4], b[2]},
                       {b[0], b[1], b[5]}, {b[3], b[1], b[5]}, {b[3], b[4], b[5]}, {b[0], b[4], b[5]}};
    const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4}, {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
    for (const auto& q : t) {
      f << " facet normal 0 0 0\n  outer loop\n";
      for (int v : q) f << "   vertex " << c[v].x << " " << c[v].y << " " << c[v].z << "\n";
      f << "  endloop\n endfacet\n";
    }
  }
  f << "endsolid boxes\n";
}
BreakResult load_path_case(const std::string& name, const std::vector<std::array<double, 6>>& boxes, double force = 1.0,
                           bool part_is_print = false, double shift_voxels = 0.0) {
  const std::string w = std::string(TMP_DIR) + "/organic_break_check/" + name;
  std::filesystem::remove_all(w);
  std::filesystem::create_directories(w);
  // the part: the plain 10 x 3 x 3 bar (its two end faces are the hold and the load); the print: the boxes
  {
    const auto keep = g_prisms;
    g_prisms.clear();   // the part has no prisms
    write_boxes(w + "/part.stl", part_is_print ? boxes : std::vector<std::array<double, 6>>{{0, 0, 0, 10, 3, 3}});
    g_prisms = keep;
  }
  write_boxes(w + "/print.stl", boxes);
  const StepModel m = import_part_file_resolved(w + "/part.stl");
  const StlMesh print = read_stl_file(w + "/print.stl");
  BreakAsk ask;
  ask.print = &print.mesh;
  ask.part = &m;
  ask.fixed_faces = {face_where(m, {-1, 0, 0}, 0, false)};
  ask.loads = {{{face_where(m, {1, 0, 0}, 0, true)}, {force, 0, 0}}};   // small: a thin member's own reading stays over the pass line
  ask.youngs_mpa = 3500;
  ask.poisson = 0.35;
  ask.yield_mpa = 31;
  ask.z_knockdown = 0.55;
  ask.grid_shift = {shift_voxels, 0.0, 0.0};
  const BreakResult r = organic_break_check(ask);
  std::string why;
  for (const std::string& x : r.not_proven_because) why += x + " ";
  std::printf("%s: verdict %s (%s); first break %.3f; unresolved energy %.4f, largest region %.4f at (%.2f, %.2f, %.2f), %zu voxels\n", name.c_str(),
              r.verdict.c_str(), why.c_str(), r.first_resolved.multiple, r.unresolved_energy_share, r.largest_unresolved_share,
              r.largest_unresolved_at.x, r.largest_unresolved_at.y, r.largest_unresolved_at.z, r.largest_unresolved_voxels);
  std::printf("%s: thin regions: %zu sliver voxels, %zu member regions, %zu connector regions\n", name.c_str(), r.sliver_voxels, r.member_regions,
              r.connector_regions);
  if (!r.joint_regions.empty())
    std::printf("%s: the region with the most load: %s, %.4f of the load at (%.2f, %.2f, %.2f), %zu voxels\n", name.c_str(),
                r.joint_regions.front().member ? "thin member" : "connector", r.joint_regions.front().load_share, r.joint_regions.front().at.x,
                r.joint_regions.front().at.y, r.joint_regions.front().at.z, r.joint_regions.front().voxels);
  return r;
}
void load_path() {
  // a thick bar, 10 x 3 x 3, cut at mid-length and joined by a 0.4 x 0.4 mm neck 1.2 mm long: the neck is the load path
  const BreakResult a = load_path_case("NECK", {{0, 0, 0, 4.45, 3, 3}, {5.55, 0, 0, 10, 3, 3}, {4.4, 1.3, 1.3, 5.6, 1.7, 1.7}});
  check(a.ok && a.verdict == "not_proven" && a.unresolved_energy_share > kBreakLoadPathShare &&
            std::fabs(a.largest_unresolved_at.x - 5.0) < 0.7,
        "the load-path rule: a thin neck in the load path is named (not_proven, the region at the neck)");
  // a thin JOINT in the load path (the reviewer's 21:21): two thick blocks, 5 x 3 x 3 each, offset 2.6 mm in y and z so
  // they touch only along a 0.4 x 0.4 mm patch 0.1 mm long (x 4.9 to 5.0): the joint carries the whole load. A general
  // joint is measured by the strain-energy share of its not-resolved material (posts by their section force); named.
  const BreakResult c = load_path_case("JOINT", {{0, 0, 0, 5, 3, 3}, {4.9, 2.6, 2.6, 10, 5.6, 5.6}}, 0.1, true);
  check(c.ok && c.verdict == "not_proven" && !c.joint_regions.empty() && c.joint_regions.front().load_share > kBreakLoadPathShare &&
            std::hypot(std::hypot(c.joint_regions.front().at.x - 4.95, c.joint_regions.front().at.y - 2.8), c.joint_regions.front().at.z - 2.8) < 1.5,
        "the load-path rule: a thin joint in the load path is named (not_proven, the region at the joint)");
  // the same JOINT on a grid placed half a voxel (0.1 mm) further along the load axis: still named
  const BreakResult c2 = load_path_case("JOINT_SHIFTED", {{0, 0, 0, 5, 3, 3}, {4.9, 2.6, 2.6, 10, 5.6, 5.6}}, 0.1, true, 0.5);
  check(c2.ok && c2.verdict == "not_proven" && !c2.joint_regions.empty() && c2.joint_regions.front().load_share > kBreakLoadPathShare,
        "the load-path rule: the thin joint is still named on a grid shifted half a voxel along the load");
  // the gate on a thick block whose faces fall inside voxels (the lead's ruling on C8): a 6 x 6 x 6 mm block at
  // (0.03, 0.07, 0.11), so every face voxel is partly filled. Its face and edge voxels must all read resolved except at
  // most a line along each of the 12 sharp edges (12 x 32 voxels at 0.2 mm).
  {
    const BreakResult d = load_path_case("BLOCK", {{0.03, 0.07, 0.11, 6.03, 6.07, 6.11}}, 1.0, true);
    std::printf("BLOCK: %zu material voxels not resolved, %zu of them slivers (verdict %s)\n", d.unresolved_voxels, d.sliver_voxels, d.verdict.c_str());
    check(d.ok && d.unresolved_voxels <= 12 * 32 && d.member_regions == 0 && d.connector_regions == 0 && d.verdict == "pass",
          "the gate: a thick block's partly filled face and edge voxels are resolved or slivers (exempt): pass");
  }
  // C8 rule by cores, two more made shapes (no pass marks: what they read is recorded)
  {   // a 60-degree knife edge: an equilateral prism (side 1.5 mm) along y on the bar's top face at its loaded end
    const double zt = 3.0 + 0.75 * std::sqrt(3.0);
    const Vec3 A0{8.5, 0, 3}, B0{10, 0, 3}, C0{9.25, 0, zt}, A1{8.5, 3, 3}, B1{10, 3, 3}, C1{9.25, 3, zt};
    g_prisms = {{{A0, B0, C0}, {A1, C1, B1}, {A0, B0, B1}, {A0, B1, A1}, {B0, C0, C1}, {B0, C1, B1}, {C0, A0, A1}, {C0, A1, C1}}};
    const BreakResult k = load_path_case("KNIFE", {{0, 0, 0, 10, 3, 3}}, 1.0);
    g_prisms.clear();
    std::printf("KNIFE reads: verdict %s, members %zu, the largest measured load share %.4f, unresolved energy %.4f\n", k.verdict.c_str(),
                k.member_regions, k.joint_regions.empty() ? 0.0 : k.joint_regions.front().load_share, k.unresolved_energy_share);
  }
  {   // two thick blocks joined by a thick bridge AND, in parallel, a short thin patch: one BODY, so the patch is a sliver
    const BreakResult q = load_path_case("PARALLEL", {{0, 0, 0, 4.9, 3, 3}, {5.1, 0, 0, 10, 3, 3}, {4.8, 0, 0, 5.2, 1.5, 3}, {4.8, 2.6, 2.6, 5.2, 3.0, 3.0}},
                                         1.0, true);
    std::printf("PARALLEL reads: verdict %s, sliver voxels %zu, member regions %zu, connector regions %zu; the region with the most load %.4f\n",
                q.verdict.c_str(), q.sliver_voxels, q.member_regions, q.connector_regions,
                q.joint_regions.empty() ? 0.0 : q.joint_regions.front().load_share);
  }
  // the same bar whole, with a 0.4 mm fin off the load path (on its +y face): not named
  const BreakResult b = load_path_case("FIN", {{0, 0, 0, 10, 3, 3}, {4, 2.9, 1.3, 6, 5, 1.7}});
  check(b.ok && b.verdict == "pass" && b.unresolved_energy_share <= kBreakLoadPathShare,
        "the load-path rule: a thin fin off the load path is not named (pass)");
}

// C10, the review's small fixes (review-c9.md), each on the smallest made shape that read wrong before.
struct Made {
  StepModel m;
  StlMesh print;
  BreakAsk ask;
};
// boxes as the part and the print; held at the -x face (or `hold` normal), `force` on the face with normal `at`
std::unique_ptr<Made> made(const std::string& name, const std::vector<std::array<double, 6>>& boxes, const Vec3& force,
                           const Vec3& hold = {-1, 0, 0}, const Vec3& at = {1, 0, 0}) {
  const std::string w = std::string(TMP_DIR) + "/organic_break_check/" + name;
  std::filesystem::remove_all(w);
  std::filesystem::create_directories(w);
  write_boxes(w + "/part.stl", boxes);
  auto x = std::make_unique<Made>();
  x->m = import_part_file_resolved(w + "/part.stl");
  x->print = read_stl_file(w + "/part.stl");
  const auto axis = [](const Vec3& n) { return std::fabs(n.x) > 0.5 ? 0 : std::fabs(n.y) > 0.5 ? 1 : 2; };
  const auto hi = [](const Vec3& n) { return n.x + n.y + n.z > 0; };
  x->ask.print = &x->print.mesh;
  x->ask.part = &x->m;
  x->ask.fixed_faces = {face_where(x->m, hold, axis(hold), hi(hold))};
  x->ask.loads = {{{face_where(x->m, at, axis(at), hi(at))}, force}};
  x->ask.youngs_mpa = 3500;
  x->ask.poisson = 0.35;
  x->ask.yield_mpa = 31;
  x->ask.z_knockdown = 0.55;
  return x;
}
void review_fixes() {
  {   // 7: a thin bar whose voxel centres miss most of it: the guard on the true count
    auto x = made("R7", {{0, 0.15, 0.15, 6, 0.65, 0.65}}, {0.1, 0, 0});
    const BreakSize sz = organic_break_size(x->ask);
    x->ask.memory_limit_bytes = 1e12;
    const BreakResult big = organic_break_check(x->ask);
    x->ask.memory_limit_bytes = 0.5 * (sz.bytes + big.size.bytes);
    const BreakResult r = organic_break_check(x->ask);
    std::printf("review 7: centre count %zu voxels (%.0f B), true count %zu (%.0f B); limit %.0f B: %s %s\n", sz.material_voxels, sz.bytes,
                big.size.material_voxels, big.size.bytes, x->ask.memory_limit_bytes, r.verdict.c_str(), r.not_checked.c_str());
    check(big.size.bytes > sz.bytes && r.verdict == "not_checked" && r.not_checked == "too_big",
          "review 7: the size guard is read again on the true voxel count (over the limit: not checked)");
  }
  {   // 8: a grid past the solver's range: not checked, and the block is JSON (no inf)
    auto x = made("R8", {{0, 0, 0, 2, 1, 1}}, {1, 0, 0});
    x->ask.voxel_mm = 0.0005;   // 4000 x 2000 x 2000 voxels: past the solver's int node range
    const BreakResult r = organic_break_check(x->ask);
    std::printf("review 8: %s %s; block: %s\n", r.verdict.c_str(), r.not_checked.c_str(), r.json.c_str());
    check(r.verdict == "not_checked" && r.json.find("inf") == std::string::npos && r.json.find("nan") == std::string::npos,
          "review 8: no inf or nan in the block");
  }
  {   // 14: a pass line that is not a number above 0
    auto x = made("R14", {{0, 0, 0, 2, 1, 1}}, {1, 0, 0});
    x->ask.pass_line = std::nan("");
    const BreakResult a = organic_break_check(x->ask);
    x->ask.pass_line = 0.0;
    const BreakResult b = organic_break_check(x->ask);
    std::printf("review 14: NaN: %s (%s); 0: %s (%s)\n", a.verdict.c_str(), a.why.c_str(), b.verdict.c_str(), b.why.c_str());
    check(a.verdict == "not_checked" && b.verdict == "not_checked", "review 14: a pass line not above 0 is not checked, never a pass");
  }
  {   // 3: bearing anchors are not modelled: not checked
    auto x = made("R3", {{0, 0, 0, 2, 1, 1}}, {1, 0, 0});
    x->ask.anchors_bearing = true;
    const BreakResult r = organic_break_check(x->ask);
    check(r.verdict == "not_checked" && r.not_checked == "bearing_anchors", "review 3: a job on bearing anchors is not checked");
  }
  {   // 13: the loaded face falls 0.15 voxel into a layer INSIDE the grid (a bar 4.03 long under a plate that runs on to
      // x = 6, so the grid holds the layer 4.0 to 4.2): the face is still found
    auto x = made("R13", {{0, 0, 0, 4.03, 2, 2}, {0, 0, 1.99, 6, 2, 3}}, {1, 0, 0});
    for (int f = 0; f < x->m.face_count; ++f) {
      const StepFaceInfo& fi = x->m.faces[static_cast<std::size_t>(f)];
      if (fi.kind == StepSurfaceKind::Plane && fi.plane_normal.x > 0.99 && std::fabs(fi.plane_origin.x - 4.03) < 1e-6) x->ask.loads[0].faces = {f};
    }
    const BreakResult r = organic_break_check(x->ask);
    std::printf("review 13: %s %s %s; first break %.3f (want about %.3f)\n", r.verdict.c_str(), r.not_checked.c_str(), r.why.c_str(),
                r.first_resolved.multiple, 31.0 / (1.0 / 4.0));
    check(r.ok && r.verdict == "pass", "review 13: a face a tenth of a voxel into a layer is found (no load_on_empty_space)");
  }
  {   // 12 and 6a: a post 0.9 mm square between two plates, the top plate pushed sideways: the post's section is the
      // material there (0.81 mm2, not the 2 mm box it was declared as) and its share is the whole force through it
    auto x = made("R12", {{0, 0, 0, 4, 4, 1}, {1.55, 1.55, 0.95, 2.45, 2.45, 3.05}, {0, 0, 3, 4, 4, 4}}, {0.5, 0, 0}, {0, 0, -1}, {0, 0, 1});
    x->ask.posts = {{2.0, 2.0, 1.0, 3.0, 2.0}};
    const BreakResult r = organic_break_check(x->ask);
    double area = 0.0, axial = 0.0, total = 0.0;
    for (const BreakClass& c : r.classes)
      if (c.cls == "post") { area = c.section_mm2; axial = c.section_force_n; total = c.section_force_total_n; }
    const double share = r.post_paths.empty() ? 0.0 : r.post_paths.front().share;
    std::printf("review 12 / 6a: %s; post section %.4f mm2 (want 0.81), axial force %.4f N, whole force %.4f N, share %.4f (want 1)\n",
                r.verdict.c_str(), area, axial, total, share);
    check(r.ok && std::fabs(area - 0.81) < 0.12, "review 12: a post's section is the material actually there");
    check(r.ok && share > 0.8, "review 6a: a post's share is the whole force through its section (along and across)");
  }
  {   // 6b: the JOINT's connectors carry energy: counted in the not-resolved energy
    const BreakResult c = load_path_case("JOINT_ENERGY", {{0, 0, 0, 5, 3, 3}, {4.9, 2.6, 2.6, 10, 5.6, 5.6}}, 0.1, true);
    check(c.ok && c.connector_regions > 0 && c.unresolved_energy_share > 0.0, "review 6b: contact material is in the not-resolved energy");
  }
  {   // 9: a slanted wall (a right prism over the triangle (0,0) (10,0) (0,10)): a 1.2 mm square at (4.5, 4.5) clears it
      // along x and y from its axis, but its corner (5.1, 5.1) is outside
    const std::string w = std::string(TMP_DIR) + "/organic_break_check/R9";
    std::filesystem::create_directories(w);
    const Vec3 A0{0, 0, 0}, B0{10, 0, 0}, C0{0, 10, 0}, A1{0, 0, 5}, B1{10, 0, 5}, C1{0, 10, 5};
    g_prisms = {{{A0, C0, B0}, {A1, B1, C1}, {A0, B0, B1}, {A0, B1, A1}, {B0, C0, C1}, {B0, C1, B1}, {C0, A0, A1}, {C0, A1, C1}}};
    write_boxes(w + "/part.stl", {});
    g_prisms.clear();
    const StlMesh pm = read_stl_file(w + "/part.stl");
    const bool corner = post_rect_inside_part(pm.mesh, 3.9, 5.1, 3.9, 5.1, {2.5});
    const bool ok_small = post_rect_inside_part(pm.mesh, 4.1, 4.9, 4.1, 4.9, {2.5});
    check(!corner && ok_small, "review 9: a post's new section is read at its corners and edge midpoints (a slanted wall the axis clears)");
  }
}

// C10 G1 (review 1): two thick blocks (2 x 2 x 2 mm) joined by a 0.4 x 0.4 mm neck, all the load through the neck in
// tension along x (in a layer), PA6 (31 MPa, 0.40 across). Every neck length 0.2 to 0.8 mm must lie in a measured region
// and give not_proven naming it.
void set_pa6(BreakAsk& a) {
  a.youngs_mpa = 3760;
  a.poisson = 0.39;
  a.yield_mpa = 31;
  a.z_knockdown = 0.40;
}
void g1_necks() {
  for (const double L : {0.2, 0.3, 0.4, 0.5, 0.6, 0.8}) {
    char name[40];
    std::snprintf(name, sizeof name, "G1_NECK_%.1f", L);
    auto x = made(name, {{0, 0, 0, 2, 2, 2}, {2 + L, 0, 0, 4 + L, 2, 2}, {1.95, 0.8, 0.8, 2.05 + L, 1.2, 1.2}}, {0.1, 0, 0});
    set_pa6(x->ask);
    const BreakResult r = organic_break_check(x->ask);
    std::string why;
    for (const std::string& w : r.not_proven_because) why += w + " ";
    const bool named = !r.joint_regions.empty() && r.joint_regions.front().load_share > kBreakLoadPathShare &&
                       std::fabs(r.joint_regions.front().at.x - (2.0 + 0.5 * L)) <= 0.5 * L + 0.3 &&
                       std::hypot(r.joint_regions.front().at.y - 1.0, r.joint_regions.front().at.z - 1.0) < 0.6;
    std::printf("G1 neck %.1f mm: %s (%s); first break %.3f; slivers %zu, members %zu, connectors %zu; the region with the most load: %s "
                "%.4f at (%.2f, %.2f, %.2f), %zu voxels\n",
                L, r.verdict.c_str(), why.c_str(), r.first_resolved.multiple, r.sliver_voxels, r.member_regions, r.connector_regions,
                r.joint_regions.empty() ? "none" : r.joint_regions.front().member ? "member" : "connector",
                r.joint_regions.empty() ? 0.0 : r.joint_regions.front().load_share, r.joint_regions.empty() ? 0.0 : r.joint_regions.front().at.x,
                r.joint_regions.empty() ? 0.0 : r.joint_regions.front().at.y, r.joint_regions.empty() ? 0.0 : r.joint_regions.front().at.z,
                r.joint_regions.empty() ? std::size_t{0} : r.joint_regions.front().voxels);
    char what[120];
    std::snprintf(what, sizeof what, "G1: a %.1f mm neck between two blocks lies in a measured region and is named (not_proven)", L);
    check(r.ok && r.verdict == "not_proven" && named, what);
  }
}

// C10 G2 (review 2), bending and neighbours, PA6 (31 MPa along the layers), x in a layer, up z:
// (a) a vine b x b, 8 mm long, grown out of a held 3 mm block, a tip load F across (-z): first yield at the root
//     31 b h^2 / (6 F L), the plastic hinge 1.5 x that; MARK: the check's first break <= 1.10 x the hinge.
// (b) two parallel 0.9 mm vines 0.6 mm apart on one held block, one pulled (F along +x, 8 mm long), the other free
//     (7 mm): MARK: the first break within 10 % of 31 x 0.81 / F.
void g2() {
  const double F = 0.1, L = 8.0;
  for (const double b : {0.9, 1.35}) {
    char name[40];
    std::snprintf(name, sizeof name, "G2_CANTILEVER_%.2f", b);
    const double c0 = 1.5 - 0.5 * b, c1 = 1.5 + 0.5 * b;
    auto x = made(name, {{0, 0, 0, 3, 3, 3}, {2.95, c0, c0, 3 + L, c1, c1}}, {0, 0, -F});
    set_pa6(x->ask);
    x->ask.smooth_mm = g_smooth;
    x->ask.also_connected_ball = g_connected;
    const BreakResult r = organic_break_check(x->ask);
    const double fy = 31.0 * b * b * b / (6.0 * F * L), hinge = 1.5 * fy;
    std::printf("G2a %.2f mm (ball radius %.2f%s): %s; first break %.4f at (%.2f, %.2f, %.2f) %s; all points %.4f; connected %.4f / %.4f; "
                "first yield %.4f, hinge %.4f; check / first yield %.3f; MARK (<= 1.10 x hinge = %.4f) %s\n",
                b, g_smooth, g_connected ? ", connected" : "", r.verdict.c_str(), r.first_resolved.multiple, r.first_resolved.at.x,
                r.first_resolved.at.y, r.first_resolved.at.z, r.first_resolved.cls.c_str(), r.first_all.multiple, r.connected_judged.multiple,
                r.connected_all.multiple, fy, hinge, r.first_resolved.multiple / fy, 1.10 * hinge,
                r.first_resolved.multiple <= 1.10 * hinge ? "MET" : "MISSED");
  }
  {
    auto x = made("G2_PARALLEL", {{0, 0, 0, 3, 3, 3}, {2.95, 0.6, 1.05, 11, 1.5, 1.95}, {2.95, 2.1, 1.05, 10, 3.0, 1.95}}, {1.0, 0, 0});
    set_pa6(x->ask);
    x->ask.smooth_mm = g_smooth;
    x->ask.also_connected_ball = g_connected;
    const BreakResult r = organic_break_check(x->ask);
    const double want = 31.0 * 0.81 / 1.0;
    std::printf("G2b parallel (ball radius %.2f%s): %s; first break %.4f at (%.2f, %.2f, %.2f) %s; all points %.4f; connected %.4f / %.4f; "
                "want %.4f; MARK (within 10 %%) %s\n",
                g_smooth, g_connected ? ", connected" : "", r.verdict.c_str(), r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y,
                r.first_resolved.at.z, r.first_resolved.cls.c_str(), r.first_all.multiple, r.connected_judged.multiple, r.connected_all.multiple, want,
                std::fabs(r.first_resolved.multiple / want - 1.0) <= 0.10 ? "MET" : "MISSED");
  }
}

// C9: the Auto Sweep limits the app's Organic page reads before a lay (Session::sweep_limits_for over the job's weave
// regions, the line its bead, the gap 1.5 lines: LatticeOrganicLook.Check.gapLines), for laying a piece at the app's defaults.
void limits(const std::string& job_path) {
  FileJob job;
  StepModel model;
  FileResult r;
  if (!load_file_job(job_path, 1, job, model, r, nullptr)) { std::printf("LIMITS load failed: %s\n", r.why.c_str()); return; }
  std::vector<int> ids;
  for (const auto& g : job.settings.regions)
    if (g.weave) ids.push_back(g.id);
  Session s(model);
  const SweepLimitsUnion u = s.sweep_limits_for(job.settings, ids, job.settings.bead_mm, 1.5);
  std::printf("LIMITS measured %d strut %.6g %.6g auto %.6g cell %.6g %.6g auto %.6g gap %.6g (bead %.6g)\n", u.measured, u.strut_lower_mm,
              u.strut_upper_mm, u.strut_auto_mm, u.cell_lower_mm, u.cell_upper_mm, u.cell_auto_mm, u.gap_mm, job.settings.bead_mm);
}

}  // namespace

int main(int argc, char** argv) {
  // C10 G2 (test-only): the candidates' tokens, read anywhere on the command line
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]).rfind("smooth:", 0) == 0) g_smooth = std::atof(argv[i] + 7);
    if (std::string(argv[i]) == "connected") g_connected = true;
    if (std::string(argv[i]) == "big") g_big = true;
  }
  if (argc >= 2 && std::string(argv[1]) == "g2") { g2(); return 0; }   // C10: test-only, no default checks first
  // the steady mode (argv[10], [11] optional, C5) runs alone (C10: the default checks are not run first)
  if (argc >= 10 && std::string(argv[1]) == "steady") { steady(argv + 2); return 0; }
  if (argc >= 3 && std::string(argv[1]) == "limits") { limits(argv[2]); return 0; }   // C9
  gate();
  law();
  bar();
  load_path();
  review_fixes();
  g1_necks();
  if (argc >= 4 && std::string(argv[1]) == "remake") { remake(argv[2], argv[3]); return 0; }
  if (argc >= 3 && std::string(argv[1]) == "oversize") oversize(argv[2]);
  if (argc >= 5 && std::string(argv[1]) == "size") { size_of(argv[2], argv[3], std::atof(argv[4])); return failures == 0 ? 0 : 1; }
  if (argc >= 6 && std::string(argv[1]) == "postwidth") {
    post_width(argv[2], std::atof(argv[3]), std::atof(argv[4]), std::atof(argv[5]));
    return 0;
  }
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
    for (int i = 3; i < argc; ++i) g_matched = g_matched || std::string(argv[i]) == "matched";
    for (int i = 3; i < argc; ++i)
      if (std::string(argv[i]).rfind("print:", 0) == 0) g_print = argv[i] + 6;
    {   // the pieces named on the command line (none named: all)
      std::vector<Piece> keep;
      for (const Piece& p : pieces)
        for (int i = 3; i < argc; ++i)
          if (p.name == argv[i]) keep.push_back(p);
      if (!keep.empty()) pieces = keep;
    }
    for (const Piece& p : pieces) mark(dir, p, pla);
  }
  std::printf("%d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
