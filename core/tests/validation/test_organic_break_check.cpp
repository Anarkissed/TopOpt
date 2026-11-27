// Organic strength CUT 1, stage C1: the break check (lattice_layout_break.hpp).
// With no arguments: the gate on made shapes (S4's: a 1-voxel column, a 3 x 3 column at its centre and corner, a
// 5-voxel slab) and the limit law. With "marks DIR": marks 1 and 2 of the plan (section 5) on the made pieces, laid here
// by the file job from the made inputs in DIR (the study's made jobs: BR.stl, BR.tensor, BRT_d_job.json,
// BRG_d_job.json, SP.stl, SP.tensor, SP_job.json), each through organic_break_check at 0.2 mm and tolerance 1e-2.
#include <cmath>
#include <cstdio>
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
  const BreakSize sz = organic_break_size(ask);
  std::printf("[%s] before the solve: grid %d x %d x %d, material voxels %zu, bytes estimate %.0f\n", p.name.c_str(), sz.nx, sz.ny, sz.nz,
              sz.material_voxels, sz.bytes);
  const BreakResult r = organic_break_check(ask);
  std::printf("[%s] ok %d %s; verdict %s; first break (judged) %.4f at (%.2f, %.2f, %.2f) %s, thickness %.1f; all points %.4f at (%.2f, %.2f, %.2f) "
              "%s, thickness %.1f; rounds %d, %.1f s, peak %.0f MB\n[%s] json %s\n", p.name.c_str(), r.ok, r.why.c_str(), r.verdict.c_str(),
              r.first_resolved.multiple, r.first_resolved.at.x, r.first_resolved.at.y, r.first_resolved.at.z, r.first_resolved.cls.c_str(),
              r.first_resolved.thickness_voxels, r.first_all.multiple, r.first_all.at.x, r.first_all.at.y, r.first_all.at.z, r.first_all.cls.c_str(),
              r.first_all.thickness_voxels, r.rounds, r.seconds, r.peak_mb, p.name.c_str(), r.json.c_str());
  if (p.want_voxels > 0) {
    // The study counted on its own grid: origin 0 (plus its offsets), the part's box only (150 x 80 x 123 at 0.2 mm). The product voxeliser
    // on that same grid; the check's own grid (the whole print) is printed beside it.
    VoxelGrid ref;
    ref.nx = 150;
    ref.ny = 80;
    ref.nz = 123;
    ref.spacing = 0.2;
    ref.origin = {1.2345e-6, 2.3456e-6, 0.0};   // the study's offsets
    const VoxelGrid vg = voxelize_onto_grid(print.mesh, ref);
    std::size_t n = 0;
    for (VoxelTag t : vg.tags) n += t != VoxelTag::Empty;
    const double dv = std::fabs(static_cast<double>(n) - static_cast<double>(p.want_voxels)) / static_cast<double>(p.want_voxels);
    std::printf("[%s] MARK 2: material voxels on the study's grid %zu against %lld: %.4f %% (the check's own grid, the whole print: %zu)\n",
                p.name.c_str(), n, p.want_voxels, 100.0 * dv, r.size.material_voxels);
    check(dv <= 0.001, (p.name + ": mark 2, the voxels within 0.1 %").c_str());
  }
  auto near = [](double a, double b, double tol) { return std::fabs(a - b) <= tol * b; };
  const double dist = std::hypot(std::hypot(r.first_resolved.at.x - p.want_at.x, r.first_resolved.at.y - p.want_at.y), r.first_resolved.at.z - p.want_at.z);
  std::printf("[%s] MARK 1: judged %.4f against %.4f (%.2f %%)%s; place %.2f mm from the study's; class %s (study %s)\n", p.name.c_str(),
              r.first_resolved.multiple, p.want_resolved, 100.0 * (r.first_resolved.multiple / p.want_resolved - 1.0),
              p.want_all > 0 ? (", all points " + std::to_string(r.first_all.multiple) + " against " + std::to_string(p.want_all)).c_str() : "", dist,
              r.first_resolved.cls.c_str(), p.want_class.c_str());
  check(r.ok && near(r.first_resolved.multiple, p.want_resolved, 0.01) && (p.want_all <= 0 || near(r.first_all.multiple, p.want_all, 0.01)) && dist <= 0.5,
        (p.name + ": mark 1, within 1 % and 0.5 mm").c_str());
}
}  // namespace

int main(int argc, char** argv) {
  gate();
  law();
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
    for (int i = 3; i < argc; ++i) {
      std::vector<Piece> keep;
      for (const Piece& p : pieces) if (p.name == argv[i]) keep.push_back(p);
      if (!keep.empty()) pieces = keep;
    }
    for (const Piece& p : pieces) mark(dir, p, pla);
  }
  std::printf("%d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
