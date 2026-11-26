// PRINT RESOLUTION (his 11-25: "Offer print resolutions when exporting. Full detail vs medium vs coarse. All with
// information about their file size estimates and resolution."; lattice_layout_file.hpp, PRINT RESOLUTION).
//
// Every strut type and both sheets, on core's fixtures (the 10 mm cube whole at a typed cell, the filleted bore plate whole
// at Auto, the cube's top face as a 3MF), made by the file job at the three levels. Each check with its RED control:
//   parse      "print_resolution" reads full / medium / coarse, refuses anything else and an Organic job below full;
//              Full leaves the options exactly as they were               RED: Medium changes them
//   full       FULL is today's file, byte for byte: the job with no key and with "full" give the same bytes, and those
//              bytes are the ones the engine wrote before this change (pins taken with the pre-change CLI built at
//              a77c80b6: sheets-strength 2f5ac5ce with the sheets core 47c66aba; the octet's two are
//              test_lattice_types_matrix's own; the sheet plates' also by their triangles in any order, see below)
//                                                                          RED: a Medium file is not the pinned bytes
//   clean      MEDIUM and COARSE files are made and print-clean (nothing in mid-air, no long bridge), the print check
//              leaving out exactly what it left out at Full (a strut lattice's posts too)
//   struts     no strut prints thinner than at Full: the thinnest width across each sampled strut's middle at least the
//              Full bar's flat-to-flat width              RED: equal-area six-sided struts (mesh.bar_sides 6) are thinner
//   walls      a sheet's walls are two lines everywhere at every level   RED: the same job at one line
//   smaller    no level's file over Full's (5 % for Manifold's joints), Medium smaller and Coarse no larger over every
//              case (a two-line strut is 8-sided at both), a sheet's smaller by more than a third at Coarse
//   estimate   the layout's estimate of each level's triangles within its stated error of the file made, and as the
//              app shows a level not made (scaled by how Full's came out); the STL's bytes exactly 84 + 50 T; the 3MF's
//              for its triangles within the stated error                  RED: every level shown as Full's file
//   report     lattice_file.json carries the three levels (resolution words, sizes, the Mac's time)
// PRINT_RES_FIT=1 prints each run's terms (print_size_terms) and what was made, for the model's fit.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/stl.hpp"
#include "topopt/tpms_gen.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kDir = std::string(TMP_DIR) + "/print_resolution";
const std::string kFixtures = FIXTURES_DIR;
constexpr double kTwoLines = 0.9;
const char* kStruts[] = {"octet", "bcc", "kelvin", "diamond", "fcc", "sc", "rhombic", "bccz", "fccz", "reentrant"};
const char* kSheets[] = {"gyroid", "schwarz_d"};
const char* kLevelIds[] = {"full", "medium", "coarse"};

// THE ESTIMATE'S STATED ERROR (from the fit, lattice_layout/print_resolution.cpp THE MODEL; [struts, sheets]):
//   from the layout alone: every file within the first share of the file made, the mean within the second (the struts'
//     worst are the 10 mm cube's few cells, where the cut cells' staircase is most of the file);
//   as the app shows a level not made (the estimate scaled by how the made Full's came out);
//   the 3MF's bytes for the file's own triangles.
constexpr double kMostError[2] = {0.55, 0.25}, kMeanError[2] = {0.15, 0.15};
constexpr double kMostShownError[2] = {0.33, 0.15}, kMeanShownError[2] = {0.10, 0.08};
constexpr double kMost3mfError = 0.25;

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }
unsigned long long fnv(const std::string& b) {
  unsigned long long h = 1469598103934665603ULL;
  for (const unsigned char c : b) { h ^= c; h *= 1099511628211ULL; }
  return h;
}
bool sheet(const std::string& t) { return t == "gyroid" || t == "schwarz_d"; }
// A binary STL's triangles in any order: each triangle's three corners (36 bytes, no normal) turned to start at its least
// corner (its winding kept), the triangles sorted, then FNV-1a 64 of them all.
unsigned long long canonical_stl(const std::string& b) {
  if (b.size() < 84) return 0;
  std::uint32_t n = 0;
  std::memcpy(&n, b.data() + 80, 4);
  if (b.size() != 84 + 50ULL * n) return 0;
  std::vector<std::string> recs;
  recs.reserve(n);
  for (std::uint32_t i = 0; i < n; ++i) {
    const char* o = b.data() + 84 + 50ULL * i + 12;
    std::string v[3] = {std::string(o, 12), std::string(o + 12, 12), std::string(o + 24, 12)};
    int k = 0;
    for (int j = 1; j < 3; ++j)
      if (std::memcmp(v[j].data(), v[k].data(), 12) < 0) k = j;
    recs.push_back(v[k] + v[(k + 1) % 3] + v[(k + 2) % 3]);
  }
  std::sort(recs.begin(), recs.end(), [](const std::string& x, const std::string& y) {
    return std::memcmp(x.data(), y.data(), 36) < 0;
  });
  std::string all;
  all.reserve(36ULL * n);
  for (const std::string& r : recs) all += r;
  return fnv(all);
}

struct Case { std::string type, name; };
std::string layout_json(const Case& c, int lines = 2) {
  std::string s = "{\"min_strut_lines\": " + std::to_string(lines) + ", \"bead_mm\": 0.45, \"topology\": \"" + c.type +
                  "\", \"algorithm\": \"default_grade\", \"cell_max_mm\": 8";
  if (!sheet(c.type)) s += ", \"min_cells_across\": 1";
  if (c.name == "cube-typed5" || c.name == "cube-typed6") {
    s += std::string(", \"cell_mm\": ") + (c.name == "cube-typed5" ? "5" : "6") + ", \"all_lattice\": true";
    if (!sheet(c.type)) s += ", \"skin\": true";
  } else if (c.name == "plate-auto") {
    s += ", \"cell_mm\": 0, \"all_lattice\": true";
    s += sheet(c.type) ? ", \"auto_by_cell\": true" : ", \"skin\": false, \"cell_search\": true, \"stretch_edges\": true";
  } else {   // cube-face-3mf
    s += ", \"cell_mm\": 0, \"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [6], "
         "\"region_expand_mm\": [0], \"region_face_counts\": [1], \"region_faces\": [4]";
    s += sheet(c.type) ? ", \"auto_by_cell\": true" : ", \"skin\": true, \"cell_search\": true, \"stretch_edges\": true";
  }
  return s + "}";
}
std::string model_of(const Case& c) {
  return c.name.rfind("cube", 0) == 0 ? kFixtures + "/step/cube.step" : kFixtures + "/mesh/filleted_bore_plate.stl";
}
// The job as the CLI's: `level` empty = no key (the job as before).
std::string job_json(const Case& c, const std::string& level, const std::string& mesh = "", int lines = 2) {
  std::string s = "{\"mode\": \"lattice_file\", \"model\": \"" + model_of(c) + "\", \"output\": \"lattice.stl\"";
  if (c.name == "cube-face-3mf") s += ", \"file_format\": \"3mf\"";
  if (!level.empty()) s += ", \"print_resolution\": \"" + level + "\"";
  if (!mesh.empty()) s += ", \"mesh\": " + mesh;
  return s + ", \"layout\": " + layout_json(c, lines) + "}";
}
struct Ran {
  FileResult r;
  std::string folder, bytes;
};
Ran run(const std::string& tag, const std::string& job) {
  Ran x;
  x.folder = kDir + "/" + tag;
  std::filesystem::remove_all(x.folder);
  std::filesystem::create_directories(x.folder);
  std::ofstream(x.folder + "/job.json") << job;
  x.r = run_file_job(x.folder + "/job.json", x.folder, 4);   // four threads: the bytes are the same for any number
  if (x.r.ok) x.bytes = slurp(x.r.file);
  return x;
}

// Print-clean, and the print check left out exactly what it left out at Full (a level never takes a strut away). A strut
// lattice's posts are Full's too; a sheet's are counted, not held: its low points are where the surface is, which the
// level moves by up to its bound, and the print loop posts each one it finds (the gyroid plate: 30 at Full, 33 and 32).
std::string check_clean(const FileResult& r, const FileResult& full, bool posts_held) {
  if (!r.ok) return "no file: " + r.code + ": " + r.why;
  if (!r.made.print_clean || r.made.midair_starts != 0 || !r.made.layers.mid_air.empty() || !r.made.layers.one_ended.empty() ||
      !r.made.layers.long_bridges.empty() || r.made.left_out_at.size() != full.made.left_out_at.size() ||
      (posts_held && r.made.posts.size() != full.made.posts.size()) || r.made.mesh.bars_left_out != full.made.mesh.bars_left_out) {
    char s[200];
    std::snprintf(s, sizeof s, "clean %d, mid-air %d, one-ended %zu, long bridges %zu, left out %zu (Full %zu), posts %zu (Full %zu)",
                  r.made.print_clean ? 1 : 0, r.made.midair_starts, r.made.layers.one_ended.size(),
                  r.made.layers.long_bridges.size(), r.made.left_out_at.size(), full.made.left_out_at.size(),
                  r.made.posts.size(), full.made.posts.size());
    return s;
  }
  return "";
}

// The thinnest width across the middle of up to `most` round struts (well inside the part, 2 mm long or more, not a
// bridge, not a skin bar), each over its middle's 180 directions square to it (1 degree apart): over the Full bar's own
// flat-to-flat width, the least share any one reached (1 = as wide as Full's flat sides).
double thinnest_share(const TriangleMesh& file, const Outcome& o, const Domain& domain, std::size_t most) {
  const TriangleMesh welded = weld_mesh(file, 1e-6);
  PartMeasure pm(welded);
  const PartMeasure::Probe mp = pm.probe();
  const PartMeasure::Probe part = domain.measure().probe();
  const double kPi = 3.14159265358979323846;
  const double full_flat = std::sqrt(2.0 * kPi / (12 * std::sin(2.0 * kPi / 12))) * std::cos(kPi / 12);   // over r
  double least = std::numeric_limits<double>::infinity();
  std::size_t used = 0;
  for (std::size_t i = 0; i < o.bars.bars.size() && used < most; i += 7) {
    const Bar& b = o.bars.bars[i];
    const Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
    const double len = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    const double r = 0.5 * b.width;
    if (b.skin || len < 2.0 || bar_is_bridge(b)) continue;
    const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    if (part.depth(m) < r + 0.5 || !(mp.depth(m) > 0.0)) continue;
    const Vec3 u{d.x / len, d.y / len, d.z / len};
    const Vec3 ref = std::fabs(u.x) < 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0};
    Vec3 e1{u.y * ref.z - u.z * ref.y, u.z * ref.x - u.x * ref.z, u.x * ref.y - u.y * ref.x};
    const double l1 = std::sqrt(e1.x * e1.x + e1.y * e1.y + e1.z * e1.z);
    e1 = {e1.x / l1, e1.y / l1, e1.z / l1};
    const Vec3 e2{u.y * e1.z - u.z * e1.y, u.z * e1.x - u.x * e1.z, u.x * e1.y - u.y * e1.x};
    double w = std::numeric_limits<double>::infinity();
    for (int k = 0; k < 180; ++k) {
      const double t = kPi * k / 180.0;
      const Vec3 n{std::cos(t) * e1.x + std::sin(t) * e2.x, std::cos(t) * e1.y + std::sin(t) * e2.y,
                   std::cos(t) * e1.z + std::sin(t) * e2.z};
      w = std::min(w, mp.wall_width(m, n));
    }
    least = std::min(least, w / (2.0 * r * full_flat));
    ++used;
  }
  return used ? least : std::numeric_limits<double>::quiet_NaN();
}

// A sheet's wall measured on the file along the field's normal at points of its mid-surface (the sheet matrix's own
// reading, test_lattice_sheets_matrix measure_walls): the thinnest, and the samples under two lines or with no wall.
struct Walls { std::size_t samples = 0, thin = 0, holes = 0; double thinnest = 1e300; };
Walls measure_walls(const TriangleMesh& file, const Outcome& o, const Domain& domain, int per_cell, std::size_t most_cells) {
  Walls out;
  const TriangleMesh welded = weld_mesh(file, 1e-6);
  PartMeasure pm(welded);
  const PartMeasure::Probe mp = pm.probe();
  const Domain::Probe dp = domain.probe();
  const PartMeasure::Probe part = domain.measure().probe();
  unsigned long long rng = 0x9E3779B97F4A7C15ULL;
  const auto rnd = [&rng] {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return static_cast<double>(rng >> 11) / 9007199254740992.0;
  };
  for (const SheetField& f : o.sheets) {
    std::size_t used = 0;
    for (const Cell& c : o.layout.cells) {
      if (c.region != f.region || c.frame != f.frame) continue;
      if (++used > most_cells) break;
      const Frame& fr = o.layout.frames[static_cast<std::size_t>(c.frame)];
      for (int s = 0; s < per_cell; ++s) {
        Vec3 q{c.lo[0] + rnd() * c.size, c.lo[1] + rnd() * c.size, c.lo[2] + rnd() * c.size};
        bool on = false;
        for (int it = 0; it < 30; ++it) {
          const TpmsValue v = tpms_eval(f.kind, q.x - f.anchor[0], q.y - f.anchor[1], q.z - f.anchor[2], f.cell_mm);
          const double g2 = v.gx * v.gx + v.gy * v.gy + v.gz * v.gz;
          if (!(g2 > 1e-12)) break;
          const double t = v.f / g2;
          q = {q.x - t * v.gx, q.y - t * v.gy, q.z - t * v.gz};
          if (std::fabs(v.f) / std::sqrt(g2) < 1e-7) { on = true; break; }
        }
        if (!on) continue;
        bool in_cube = true;
        const double qq[3] = {q.x, q.y, q.z};
        for (int a = 0; a < 3; ++a) in_cube = in_cube && qq[a] > c.lo[a] && qq[a] < c.lo[a] + c.size;
        if (!in_cube) continue;
        const Vec3 p = fr.at(q.x, q.y, q.z);
        if (!cell_holds(o.layout, dp, c, p) || part.depth(p) < 1.0) continue;
        const TpmsValue v = tpms_eval(f.kind, q.x - f.anchor[0], q.y - f.anchor[1], q.z - f.anchor[2], f.cell_mm);
        const double g = std::sqrt(v.gx * v.gx + v.gy * v.gy + v.gz * v.gz);
        const Vec3 nq{v.gx / g, v.gy / g, v.gz / g};
        const Vec3 n{fr.ax[0].x * nq.x + fr.ax[1].x * nq.y + fr.ax[2].x * nq.z, fr.ax[0].y * nq.x + fr.ax[1].y * nq.y + fr.ax[2].y * nq.z,
                     fr.ax[0].z * nq.x + fr.ax[1].z * nq.y + fr.ax[2].z * nq.z};
        bool clear = true;
        for (double t : {-1.2, -0.6, 0.6, 1.2}) {
          const Vec3 a{p.x + t * n.x, p.y + t * n.y, p.z + t * n.z};
          bool held = false;
          for (const Cell& d : o.layout.cells)
            if (d.region == c.region && cell_holds(o.layout, dp, d, a)) { held = true; break; }
          clear = clear && held && part.depth(a) > 0.3;
        }
        if (!clear) continue;
        ++out.samples;
        if (!(mp.depth(p) > 0.0)) { ++out.holes; continue; }
        const double w = mp.reach(p, n) + mp.reach(p, Vec3{-n.x, -n.y, -n.z});
        out.thinnest = std::min(out.thinnest, w);
        if (w < kTwoLines - 2e-3) ++out.thin;   // the file's corners are 32-bit numbers
      }
    }
  }
  return out;
}

Outcome lay_again(const Case& c, int lines, std::unique_ptr<Session>& session) {
  const FileJob job = parse_file_job(job_json(c, "", "", lines));
  session = std::make_unique<Session>(import_part_file_resolved(model_of(c)));
  return session->lay(job.settings);
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  if (!mesh_available()) {
    std::printf("SKIP: this build has no mesh writer (Manifold)\n");
    return 0;
  }
  const bool fit = std::getenv("PRINT_RES_FIT") != nullptr;
  const char* only = std::getenv("PRINT_RES_ONLY");   // "octet,gyroid": those types alone (while working on one)

  // ── parse ────────────────────────────────────────────────────────────────────────────────────────────────────────
  {
    std::printf("== parse ==\n");
    const Case cube{"octet", "cube-typed5"};
    const FileJob none = parse_file_job(job_json(cube, ""));
    const FileJob full = parse_file_job(job_json(cube, "full"));
    const FileJob medium = parse_file_job(job_json(cube, "medium"));
    const FileJob coarse = parse_file_job(job_json(cube, "coarse"));
    CHECK(none.resolution == PrintResolution::Full && full.resolution == PrintResolution::Full);
    CHECK(medium.resolution == PrintResolution::Medium && coarse.resolution == PrintResolution::Coarse);
    const auto same = [](const FileOptions& a, const FileOptions& b) {
      return a.mesh.sheet_deviation_mm == b.mesh.sheet_deviation_mm && a.mesh.sheet_dc_wall_share == b.mesh.sheet_dc_wall_share &&
             a.mesh.sheet_dc_cell_share == b.mesh.sheet_dc_cell_share && a.mesh.strut_facet_mm == b.mesh.strut_facet_mm &&
             a.mesh.bar_sides == b.mesh.bar_sides && a.pitch_mm == b.pitch_mm;
    };
    CHECK(same(none.options, full.options));        // Full: the options as they were
    CHECK(!same(none.options, medium.options));     // RED: Medium changes them
    CHECK(medium.options.mesh.sheet_deviation_mm == 0.05 && coarse.options.mesh.sheet_deviation_mm == 0.1);
    CHECK(medium.options.mesh.strut_facet_mm == 0.05 && coarse.options.mesh.strut_facet_mm == 0.1);
    bool refused = false;
    try { parse_file_job(job_json(cube, "fine")); } catch (const FileJobError& e) { refused = has(e.what(), "print_resolution"); }
    CHECK(refused);
    refused = false;
    try {
      parse_file_job("{\"mode\": \"lattice_file\", \"model\": \"x.step\", \"print_resolution\": \"coarse\", \"layout\": "
                     "{\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [6], \"region_expand_mm\": [0], "
                     "\"region_face_counts\": [1], \"region_faces\": [4], \"region_weave\": [true], "
                     "\"organic_spacing_mm\": 3}}");
    } catch (const FileJobError& e) {
      refused = has(e.what(), "full detail only");
      if (!refused) std::printf("  (the Organic job was refused for another reason: %s)\n", e.what());
    }
    CHECK(refused);   // an Organic job below full is refused
    for (const PrintResolution l : kPrintResolutions) {
      const PrintResolutionLevel p = print_resolution_level(l);
      std::printf("  %-6s %-11s \"%s\"\n", print_resolution_id(l), p.name, p.words);
      int words = 1;
      for (const char* w = p.words; *w; ++w) words += *w == ' ';
      CHECK(words <= 5);   // his rule: a caption five words at most
    }
  }

  // ── the cases ────────────────────────────────────────────────────────────────────────────────────────────────────
  // Pins: the files the engine made before this change (the pre-change CLI on 47c66aba, --threads 4; the bytes do not
  // depend on the threads). FNV-1a 64 of the file's bytes.
  const std::map<std::string, unsigned long long> pins = {
      {"bcc-cube-face-3mf", 0xce3a41ba881712bdULL},       {"bcc-cube-typed5", 0xd5d7d6b70ff3fa56ULL},
      {"bcc-plate-auto", 0x16b5aa563f8794a3ULL},          {"bccz-cube-face-3mf", 0x4ac1b26a10aae466ULL},
      {"bccz-cube-typed5", 0xf4ff1139baa88b05ULL},        {"bccz-plate-auto", 0x521b457e2f2040b4ULL},
      {"diamond-cube-face-3mf", 0x893a7c90eca97ae5ULL},   {"diamond-cube-typed5", 0x342653e55882e6acULL},
      {"diamond-plate-auto", 0x7c4bb60b5bbadf14ULL},      {"fcc-cube-face-3mf", 0x0751b08ebd50ed07ULL},
      {"fcc-cube-typed5", 0x3e9f5be2b18186fcULL},         {"fcc-plate-auto", 0x636a978a93805899ULL},
      {"fccz-cube-face-3mf", 0xf400f4eda6bf0378ULL},      {"fccz-cube-typed5", 0xd2ffd4c450d7c0c8ULL},
      {"fccz-plate-auto", 0x2c87498f6192c07aULL},         {"gyroid-cube-face-3mf", 0xf51576abd87f3adeULL},
      {"gyroid-cube-typed5", 0xc125730a46461661ULL},      {"gyroid-plate-auto", 0x02cdaccd43af4f45ULL},
      {"kelvin-cube-face-3mf", 0x882d65d16a6a12d5ULL},    {"kelvin-cube-typed5", 0x652d43ac01435198ULL},
      {"kelvin-plate-auto", 0x55c042c55646f670ULL},       {"octet-cube-face-3mf", 0x0500abdf9595c49bULL},
      {"octet-cube-typed5", 0xdf8272ddea526aceULL},       {"octet-plate-auto", 0xd749eeefc8c47ae3ULL},
      {"reentrant-cube-face-3mf", 0x433da6bf0ec58a21ULL}, {"reentrant-cube-typed5", 0x980e39f2d9414e18ULL},
      {"reentrant-plate-auto", 0x3246025329531f86ULL},    {"rhombic-cube-face-3mf", 0xa10d89008d06029eULL},
      {"rhombic-cube-typed5", 0xbbdf78e74e271ad0ULL},     {"rhombic-plate-auto", 0xe6d888245b45523bULL},
      {"sc-cube-face-3mf", 0xf882d65a8ea7047fULL},        {"sc-cube-typed5", 0xb2894e3d58389d98ULL},
      {"sc-plate-auto", 0xf96abd9b18580910ULL},           {"schwarz_d-cube-face-3mf", 0xaf8887ba22fe0187ULL},
      {"schwarz_d-cube-typed6", 0x3190b98b6f4a2ffaULL},                {"schwarz_d-plate-auto", 0xd97655fde106cf28ULL},
  };
  // The two sheet plates' files by their triangles in any order (canonical_stl of the same pre-change files).
  const std::map<std::string, unsigned long long> canon_pins = {
      {"gyroid-plate-auto", 0xe253e284e3a22aacULL}, {"schwarz_d-plate-auto", 0xddbbb88b4d25448eULL}};
  std::vector<Case> cases;
  for (const char* t : kStruts)
    for (const char* n : {"cube-typed5", "plate-auto", "cube-face-3mf"}) cases.push_back({t, n});
  for (const char* t : kSheets)
    for (const char* n : {t == std::string("gyroid") ? "cube-typed5" : "cube-typed6", "plate-auto", "cube-face-3mf"})
      cases.push_back({t, n});

  struct Err { std::string tag; double tri = 0.0, mf = -9.0, anchored = -9.0; bool sheet = false; };
  std::vector<Err> errs;
  std::vector<Err> ignored;   // RED: the estimate with the level ignored (Full's weights at every level)
  std::size_t pinned = 0;
  std::size_t level_tris[3] = {0, 0, 0};
  for (const Case& c : cases) {
    if (only && !has("," + std::string(only) + ",", "," + c.type + ",")) continue;
    const std::string tag = c.type + "-" + c.name;
    std::printf("\n== %s ==\n", tag.c_str());
    Ran made[3];
    for (int k = 0; k < 3; ++k) {
      made[k] = run(tag + "-" + kLevelIds[k], job_json(c, kLevelIds[k]));
      const FileResult& r = made[k].r;
      std::printf("  %-6s ok %d %s: %zu triangles, %zu bytes, est %zu, %.1f mm3, %.0f ms (sheets %.0f ms; est %.0f ms)\n",
                  kLevelIds[k], r.ok ? 1 : 0, r.code.c_str(), r.made.mesh.triangles, r.file_bytes, r.estimates[k].triangles,
                  r.made.mesh.mm3, r.ms_total, r.made.mesh.ms_sheets,
                  made[0].r.ok ? print_size_ms(made[0].r, kPrintResolutions[k]) : -1.0);
    }
    // full: the same bytes with no key, and the bytes the engine made before
    {
      const bool cheap = !(sheet(c.type) && c.name == "plate-auto");   // a sheet's plate: the pin alone (a minute a run)
      if (cheap) {
        const Ran none = run(tag + "-none", job_json(c, ""));
        CHECK(none.r.ok == made[0].r.ok && none.bytes == made[0].bytes);
      }
      const auto pin = pins.find(tag);
      if (made[0].r.ok && pin != pins.end() && pin->second != 0) {
        const unsigned long long h = fnv(made[0].bytes);
        // A sheet laid in several blocks (the plate's six) is meshed block by block on several threads, and Manifold
        // numbers each block's mesh as it is made: on a busy machine the blocks can finish in another order and the
        // file's triangles come out in another order (the same triangles: measured 11-25 with a vendor build alongside).
        // That is the engine's as it was (not this change's); such a file is held to the pin by its triangles, in any
        // order (canonical_stl: the pinned file's own, taken the same way).
        const auto canon = canon_pins.find(tag);
        const bool reordered = h != pin->second && canon != canon_pins.end() && canonical_stl(made[0].bytes) == canon->second;
        std::printf("  full: 0x%016llx %s\n", h,
                    h == pin->second ? "(the pinned bytes)" : reordered ? "(the pinned triangles, in another order)" : "CHANGED");
#ifdef __APPLE__
        CHECK(h == pin->second || reordered);
        ++pinned;
        if (made[1].r.ok && c.type != "sc") CHECK(fnv(made[1].bytes) != pin->second);   // RED: a Medium file is not
#endif
      } else {
        std::printf("  full: 0x%016llx (not pinned)\n", made[0].r.ok ? fnv(made[0].bytes) : 0ULL);
      }
    }
    if (!made[0].r.ok) {   // a case that makes no file at Full makes none at any level
      std::printf("  (no file at full: %s)\n", made[0].r.why.c_str());
      CHECK(!made[1].r.ok && !made[2].r.ok);
      continue;
    }
    // clean
    for (int k = 1; k < 3; ++k) {
      const std::string why = check_clean(made[k].r, made[0].r, !sheet(c.type));
      std::printf("  %s: posts %zu (Full %zu), left out %zu (Full %zu)\n", kLevelIds[k], made[k].r.made.posts.size(),
                  made[0].r.made.posts.size(), made[k].r.made.left_out_at.size(), made[0].r.made.left_out_at.size());
      if (!why.empty()) std::printf("  %s not clean: %s\n", kLevelIds[k], why.c_str());
      CHECK(why.empty());
    }
    // smaller (a case may come out a few triangles over Full where Manifold's union of fewer sides cuts the joints
    // differently: within 5 %; over every case each level is smaller than the one above, below)
    for (int k = 0; k < 3; ++k)
      if (made[k].r.ok) {
        if (k > 0) CHECK(made[k].r.made.mesh.triangles <= made[0].r.made.mesh.triangles * 105 / 100);
        level_tris[k] += made[k].r.made.mesh.triangles;
      }
    if (sheet(c.type) && made[2].r.ok)
      CHECK(3 * made[2].r.made.mesh.triangles < 2 * made[0].r.made.mesh.triangles);
    // estimate
    std::unique_ptr<Session> session;
    const Outcome o = lay_again(c, 2, session);
    FileOptions opts;
    const PrintSizeInputs in = print_size_inputs(o.layout, o.bars, o.sheets, made[0].r.part_triangles, opts);
    for (int k = 0; k < 3; ++k) {
      const FileResult& r = made[k].r;
      if (!r.ok) continue;
      CHECK(r.sized && r.resolution == kPrintResolutions[k]);
      const PrintSizeEstimate e = estimate_print_size(in, kPrintResolutions[k]);
      CHECK(e.triangles == r.estimates[k].triangles);   // the job's own estimate is the layout's
      const double actual = static_cast<double>(r.made.mesh.triangles);
      Err er{tag + " " + kLevelIds[k], (static_cast<double>(e.triangles) - actual) / actual};
      er.sheet = sheet(c.type);
      const bool mf = r.file_format == "3mf";
      // the 3MF's bytes for its own triangles (the model of the writer, apart from the triangles' estimate)
      if (mf) er.mf = (static_cast<double>(threemf_bytes_for(r.made.mesh.triangles)) - static_cast<double>(r.file_bytes)) /
                      static_cast<double>(r.file_bytes);
      else CHECK(stl_bytes_for(r.made.mesh.triangles) == r.file_bytes);   // the STL's bytes, exactly
      // what the app shows for a level not made: the estimate scaled by how Full's own came out (PrintResolutionFacts)
      if (k > 0) {
        const double full_est = static_cast<double>(std::max<std::size_t>(1, made[0].r.estimates[0].triangles));
        const double shown = static_cast<double>(e.triangles) / full_est * static_cast<double>(made[0].r.made.mesh.triangles);
        er.anchored = (shown - actual) / actual;
        // RED: the level ignored (every level shown as Full's file)
        ignored.push_back({er.tag, (static_cast<double>(made[0].r.made.mesh.triangles) - actual) / actual});
      }
      errs.push_back(er);
      if (fit) {
        const auto t = print_size_terms(in, kPrintResolutions[k]);
        std::printf("FIT,%s,%s,%s", c.type.c_str(), c.name.c_str(), kLevelIds[k]);
        for (const double v : t) std::printf(",%.6g", v);
        std::printf(",%zu,%zu,%s,%.1f,%.1f,%.1f\n", r.made.mesh.triangles, r.file_bytes, mf ? "3mf" : "stl", r.ms_total,
                    r.made.mesh.ms_sheets, r.ms_write);
      }
      // the report carries the three levels
      const std::string rep = slurp(made[k].folder + "/" + kFileResultName);
      CHECK(has(rep, std::string("\"print_resolution\": {\"level\": \"") + kLevelIds[k] + "\""));
      CHECK(has(rep, "\"words\": \"surface within 0.05 mm\"") && has(rep, "\"threemf_bytes\": "));
      CHECK(!has(rep, "\"ms\": null"));
    }
    // struts: no strut thinner than at Full
    if (!sheet(c.type) && c.name != "cube-face-3mf") {
      for (int k = 0; k < 3; ++k) {
        if (!made[k].r.ok) continue;
        const StlMesh file = read_stl_file(made[k].r.file);   // as written (welded exactly; no repair)
        const double s = thinnest_share(file.mesh, o, *session->domain(), 40);
        std::printf("  %s: thinnest strut %.4f x Full's flat-to-flat\n", kLevelIds[k], s);
        CHECK(std::isnan(s) || s >= 0.998);
      }
    }
    // walls: a sheet's walls two lines at every level
    if (sheet(c.type) && c.name != "cube-face-3mf") {
      for (int k = 0; k < 3; ++k) {
        if (!made[k].r.ok) continue;
        const StlMesh file = read_stl_file(made[k].r.file);   // as written (welded exactly; no repair)
        const Walls w = measure_walls(file.mesh, o, *session->domain(), 24, 48);
        std::printf("  %s: walls %zu samples, thinnest %.4f mm, %zu under two lines, %zu holes\n", kLevelIds[k], w.samples,
                    w.thinnest, w.thin, w.holes);
        CHECK(w.samples >= 20 && w.thin == 0 && w.holes == 0);
      }
    }
  }

  // ── the RED controls that need a file of their own ──────────────────────────────────────────────────────────────
  if (!only || has("," + std::string(only) + ",", ",octet,")) {
    // struts: equal-area six-sided struts (the writer's own bar_sides 6, the round's area) are thinner than Full's
    const Case c{"octet", "plate-auto"};
    const Ran six = run("red-six-sides", job_json(c, "", "{\"bar_sides\": 6}"));
    std::unique_ptr<Session> session;
    const Outcome o = lay_again(c, 2, session);
    if (six.r.ok) {
      const StlMesh file = read_stl_file(six.r.file);
      const double s = thinnest_share(file.mesh, o, *session->domain(), 40);
      std::printf("\nRED: equal-area six-sided struts: thinnest %.4f x Full's flat-to-flat\n", s);
      CHECK(s < 0.998);
    }
    CHECK(six.r.ok);
  }
  if (!only || has("," + std::string(only) + ",", ",gyroid,")) {
    // walls: the same job at one line has walls under two lines
    const Case c{"gyroid", "cube-typed5"};
    const Ran one = run("red-one-line", job_json(c, "coarse", "", 1));
    std::unique_ptr<Session> session;
    const Outcome o = lay_again(c, 1, session);
    if (one.r.ok) {
      const StlMesh file = read_stl_file(one.r.file);
      const Walls w = measure_walls(file.mesh, o, *session->domain(), 24, 48);
      std::printf("RED: one line at coarse: %zu samples, thinnest %.4f mm, %zu under two lines\n", w.samples, w.thinnest, w.thin);
      CHECK(w.thin > 0);
    }
    CHECK(one.r.ok);
  }

  std::printf("\n== smaller ==\n  triangles over every case: full %zu, medium %zu, coarse %zu\n", level_tris[0], level_tris[1],
              level_tris[2]);
  CHECK(level_tris[1] < level_tris[0] && level_tris[2] <= level_tris[1]);   // (a two-line strut is 8-sided at both)

  // ── the estimate's error ─────────────────────────────────────────────────────────────────────────────────────────
  if (!errs.empty()) {
    struct Stat { double most = 0.0, sum = 0.0; std::size_t n = 0; std::string worst; };
    const auto add = [](Stat& s, double e, const std::string& tag) {
      s.sum += std::fabs(e);
      ++s.n;
      if (std::fabs(e) > s.most) { s.most = std::fabs(e); s.worst = tag; }
    };
    Stat tri[2], anc[2], mf;   // [struts, sheets]
    for (const Err& e : errs) {
      add(tri[e.sheet], e.tri, e.tag);
      if (e.anchored > -9.0) add(anc[e.sheet], e.anchored, e.tag);
      if (e.mf > -9.0) add(mf, e.mf, e.tag);
    }
    double most_ignored = 0.0;
    for (const Err& e : ignored) most_ignored = std::max(most_ignored, std::fabs(e.tri));
    const auto say = [](const char* what, const Stat& s) {
      std::printf("  %-34s %3zu files, mean %5.1f %%, largest %5.1f %% (%s)\n", what, s.n,
                  s.n ? 100.0 * s.sum / static_cast<double>(s.n) : 0.0, 100.0 * s.most, s.worst.c_str());
    };
    std::printf("\n== the estimate ==\n");
    say("triangles from the layout, struts", tri[0]);
    say("triangles from the layout, sheets", tri[1]);
    say("as the app shows a level, struts", anc[0]);
    say("as the app shows a level, sheets", anc[1]);
    say("3MF bytes for the file's triangles", mf);
    std::printf("  RED, the level ignored: largest %.1f %%\n", 100.0 * most_ignored);
    if (!fit) {
      for (int f = 0; f < 2; ++f) {
        if (!tri[f].n) continue;
        CHECK(tri[f].most <= kMostError[f]);
        CHECK(tri[f].sum / static_cast<double>(tri[f].n) <= kMeanError[f]);
        if (anc[f].n) CHECK(anc[f].most <= kMostShownError[f]);
        if (anc[f].n) CHECK(anc[f].sum / static_cast<double>(anc[f].n) <= kMeanShownError[f]);
      }
      if (mf.n) CHECK(mf.most <= kMost3mfError);
      if (!only) CHECK(most_ignored > kMostShownError[0]);   // RED: every level shown as Full's file is out
    }
  }
#ifdef __APPLE__
  if (!only) CHECK(pinned >= 36);
#endif
  std::printf("\n%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
