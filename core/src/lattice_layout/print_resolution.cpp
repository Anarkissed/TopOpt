// PRINT RESOLUTION (his 11-25: "Offer print resolutions when exporting. Full detail vs medium vs coarse. All with
// information about their file size estimates and resolution."): the three levels, what each loosens in the mesh writer,
// and each one's size estimate from the layout alone (lattice_layout_file.hpp, PRINT RESOLUTION).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <map>
#include <string>

#include "topopt/lattice_layout_file.hpp"
#include "topopt/tpms_gen.hpp"   // kSheetMaxDeviationMm

namespace topopt::lattice_layout {

const char* print_resolution_id(PrintResolution level) {
  switch (level) {
    case PrintResolution::Medium: return "medium";
    case PrintResolution::Coarse: return "coarse";
    case PrintResolution::Full: break;
  }
  return "full";
}

bool print_resolution_from_id(const std::string& id, PrintResolution& out) {
  for (const PrintResolution l : kPrintResolutions)
    if (id == print_resolution_id(l)) { out = l; return true; }
  return false;
}

PrintResolutionLevel print_resolution_level(PrintResolution level) {
  PrintResolutionLevel p;
  p.level = level;
  switch (level) {
    case PrintResolution::Full:
      p.surface_mm = kSheetMaxDeviationMm;
      p.name = "Full detail";
      p.words = "surface within 0.02 mm";
      break;
    case PrintResolution::Medium:
      p.surface_mm = 0.05;
      p.strut_facet_mm = 0.05;
      p.sheet_dc_wall_share = 2.0;
      p.sheet_dc_cell_share = 16.0;
      p.name = "Medium";
      p.words = "surface within 0.05 mm";
      break;
    case PrintResolution::Coarse:
      p.surface_mm = 0.1;
      p.strut_facet_mm = 0.1;
      p.sheet_dc_wall_share = 2.0;
      p.sheet_dc_cell_share = 16.0;
      p.name = "Coarse";
      p.words = "surface within 0.1 mm";
      break;
  }
  return p;
}

void apply_print_resolution(PrintResolution level, FileOptions& o) {
  if (level == PrintResolution::Full) return;   // the file as before, byte for byte
  const PrintResolutionLevel p = print_resolution_level(level);
  o.mesh.sheet_deviation_mm = p.surface_mm;
  o.mesh.sheet_dc_wall_share = p.sheet_dc_wall_share;
  o.mesh.sheet_dc_cell_share = p.sheet_dc_cell_share;
  o.mesh.strut_facet_mm = p.strut_facet_mm;
}

// ── the estimate ──────────────────────────────────────────────────────────────────────────────────────────────────
namespace {

std::uint64_t joint_key(const Vec3& p) {   // solid_mesh.cpp's place_key: the writer's own joints
  const std::uint64_t a = static_cast<std::uint64_t>(std::llround(p.x * 20000) + (1LL << 30)),
                      b = static_cast<std::uint64_t>(std::llround(p.y * 20000) + (1LL << 30)),
                      c = static_cast<std::uint64_t>(std::llround(p.z * 20000) + (1LL << 30));
  return (a * 0x9E3779B97F4A7C15ULL) ^ (b * 0xC2B2AE3D27D4EB4FULL) ^ (c * 0x165667B19E3779F9ULL);
}

// The sides the writer gives a round strut of radius r at the level (solid_mesh.cpp, round_sides: the same rule).
int sides_at(double r, int full, double facet_mm) {
  const double kPi = 3.14159265358979323846;
  if (!(facet_mm > 0.0) || !(r > 0.0)) return full;
  const double full_corner = std::sqrt(2.0 * kPi / (full * std::sin(2.0 * kPi / full)));
  const double flat = full_corner * std::cos(kPi / full);
  constexpr int n = 8;
  return n < full && (flat / std::cos(kPi / n) - 1.0) * r <= facet_mm ? n : full;
}
// Manifold's sphere of `n` segments: an octahedron cut (n + 3) / 4 times along each edge.
double sphere_triangles(int n) {
  const double k = std::max(1, (n + 3) / 4);
  return 8.0 * k * k;
}

}  // namespace

PrintSizeInputs print_size_inputs(const Layout& layout, const Bars& bars, const std::vector<SheetField>& sheets,
                                  std::size_t part_triangles, const FileOptions& options) {
  PrintSizeInputs in;
  in.part_triangles = part_triangles;
  in.cells = layout.cells.size();
  for (const Cell& c : layout.cells) in.cut_cells += c.cut ? 1 : 0;
  in.bar_sides = std::max(3, options.mesh.bar_sides);
  in.topology = layout.topology;
  in.weave = !layout.weave.empty();
  std::map<std::uint64_t, float> balls;   // ordered: the same inputs every run
  for (const Bar& x : bars.bars) {
    const double r = 0.5 * x.width;
    if (bar_is_bridge(x, options.mesh.bridge_rise)) ++in.bridges;
    else in.strut_r.push_back(static_cast<float>(r));
    for (int e = 0; e < 2; ++e) {
      if ((e == 0 ? x.end_a : x.end_b) == Bar::End::Surface) continue;
      float& b = balls[joint_key(e == 0 ? x.a : x.b)];
      b = std::max(b, static_cast<float>(r));
    }
  }
  in.ball_r.reserve(balls.size());
  for (const auto& kv : balls) in.ball_r.push_back(kv.second);
  for (const SheetField& f : sheets) {
    PrintSizeInputs::Sheet s;
    s.kind = f.kind;
    s.cell_mm = f.cell_mm;
    s.wall_mm = f.wall_min_mm;
    s.cells = f.cells;
    in.sheets.push_back(s);
  }
  return in;
}

// THE MODEL (fitted 2026-11-25 by relative least squares, weights held non-negative, on the 108 files
// test_print_resolution makes: core's 10 mm cube whole at a typed cell and its top face as a 3MF, the filleted bore plate
// whole at Auto; every strut type and both sheets; the three levels):
//   triangles = the sum over the terms (print_size_terms) of each term x its weight
// A round strut's triangles run along its sides, cut where the struts meet; how many a side depends on how the type's
// struts meet (its joints' angles), so the side's weight is the type's own. A cut cell's open space is a staircase against
// the solid. The sheets follow the SPEC's own law (k x cell triangles a cell), k falling as the bound grows. The part's own
// triangles, the cells and the balls took no weight in the fit (they are kept as terms: the test prints them).
// Its error on those files: struts 12.9 % on the mean, 54 % at most (the 10 mm cube's few cells), sheets 13.7 % and 22 %;
// scaled by how the made level's own estimate came out (what the app shows for a level not made): struts 9.2 % and 31 %,
// sheets 6.5 % and 12 %.
namespace {
constexpr double kWeights[kPrintSizeTerms] = {0.0, 42.73, 0.0, 0.0, 0.0, 38.45, 0.0, 0.0};
constexpr double kSheetWeights[2][3] = {{656.2, 338.7, 220.4}, {853.5, 439.0, 272.7}};   // [gyroid, Schwarz-D][level]
// A round strut's side, by type (a type with none fitted: their mean).
double side_weight(LatticeTopology t) {
  switch (t) {
    case LatticeTopology::Octet: return 2.608;
    case LatticeTopology::Bcc: return 3.583;
    case LatticeTopology::Kelvin: return 3.144;
    case LatticeTopology::Diamond: return 5.381;
    case LatticeTopology::Fcc: return 2.922;
    case LatticeTopology::SimpleCubic: return 0.0;   // its round struts stand upright: joints written fine, as at Full
    case LatticeTopology::Rhombic: return 3.479;
    case LatticeTopology::Bccz: return 3.463;
    case LatticeTopology::Fccz: return 5.515;
    case LatticeTopology::Reentrant: return 8.011;
    default: return 3.81;
  }
}
int level_index(PrintResolution level) {
  return level == PrintResolution::Full ? 0 : level == PrintResolution::Medium ? 1 : 2;
}
}  // namespace

std::array<double, kPrintSizeTerms> print_size_terms(const PrintSizeInputs& in, PrintResolution level) {
  const PrintResolutionLevel p = print_resolution_level(level);
  std::array<double, kPrintSizeTerms> t{};
  t[0] = static_cast<double>(in.part_triangles);
  t[1] = static_cast<double>(in.cut_cells);
  t[2] = in.sheets.empty() ? static_cast<double>(in.cells) : 0.0;
  for (const float r : in.strut_r) t[3] += sides_at(r, in.bar_sides, p.strut_facet_mm);
  for (const float r : in.ball_r) t[4] += sphere_triangles(sides_at(r, in.bar_sides, p.strut_facet_mm));
  t[5] = static_cast<double>(in.bridges);
  for (const PrintSizeInputs::Sheet& s : in.sheets)
    t[s.kind == TpmsKind::Gyroid ? 6 : 7] += s.cell_mm * static_cast<double>(s.cells);
  return t;
}

double print_size_weight(int term, PrintResolution level, LatticeTopology topology) {
  if (term < 0 || term >= kPrintSizeTerms) return 0.0;
  if (term >= 6) return kSheetWeights[term - 6][level_index(level)];
  if (term == 3) return side_weight(topology);
  return kWeights[term];
}

std::uint64_t stl_bytes_for(std::size_t triangles) { return 84ULL + 50ULL * static_cast<std::uint64_t>(triangles); }

std::uint64_t threemf_bytes_for(std::size_t triangles) {
  // The job's 3MF (StreamingThreeMfWriter, indexed, deflated), fitted on the same 36 3MF files by their triangles: 6.8 %
  // on the mean, 21 % at most (the smallest files; the maintainer's stand, 9-10 M triangles and about 110 MB, is 11 to
  // 12 bytes a triangle).
  return static_cast<std::uint64_t>(172.0 + 10.344 * static_cast<double>(triangles));
}

PrintSizeEstimate estimate_print_size(const PrintSizeInputs& in, PrintResolution level) {
  PrintSizeEstimate e;
  e.level = level;
  const std::array<double, kPrintSizeTerms> t = print_size_terms(in, level);
  double sum = 0.0;
  for (int k = 0; k < kPrintSizeTerms; ++k) sum += print_size_weight(k, level, in.topology) * t[static_cast<std::size_t>(k)];
  e.triangles = static_cast<std::size_t>(std::llround(std::max(0.0, sum)));
  e.stl_bytes = stl_bytes_for(e.triangles);
  e.threemf_bytes = threemf_bytes_for(e.triangles);
  return e;
}

double print_size_ms(const FileResult& r, PrintResolution level) {
  if (!r.ok || !r.sized) return -1.0;
  // The sheets' contouring at a level, over Full's (measured with the model).
  // (gyroid and Schwarz-D on core's cube and plate: Medium 0.46 to 0.76 of Full's, Coarse 0.39 to 0.95, on a busy Mac once 1.6.)
  constexpr double kSheetTime[3] = {1.0, 0.65, 0.6};
  const int made = static_cast<int>(r.resolution), want = static_cast<int>(level);
  const double sheets = r.made.mesh.ms_sheets;
  const double tri_made = static_cast<double>(std::max<std::size_t>(1, r.made.mesh.triangles));
  const double tri_est_made = static_cast<double>(std::max<std::size_t>(1, r.estimates[made].triangles));
  const double tri_want = static_cast<double>(r.estimates[want].triangles) * tri_made / tri_est_made;
  const double rest = std::max(0.0, r.ms_total - r.ms_strength - sheets - r.ms_write);
  return rest + sheets * kSheetTime[want] / kSheetTime[made] + r.ms_write * tri_want / tri_made;
}

}  // namespace topopt::lattice_layout
