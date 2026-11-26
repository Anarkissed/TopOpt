// notes28 sheets (SPEC rev 3), builder B: the strength check and the data out for gyroid and Schwarz-D on the new
// engine. Made boxes (STLs the test writes), laid by Session::lay as the file job lays them; each check with its RED
// control.
//   place      credit by PLACE (SPEC 1.4): every credited voxel's density is its own wall's (sheet_wall_at at its
//              centre), banded per voxel, on a graded (By stress) wall     RED: the cells' own walls, unblended, differ
//   floor      a member under the floor (10 / 9 cells across until D's tables) gets no credit; cut cells none (3.3)
//                                                                          RED: the same cells with the floor read as 1
//   band       a two-line wall in a cell past 18.5 / 17.2 mm is out of the band, uncredited (3.1)
//                                                                          RED: a cell under it is in the band
//   blend      no credit inside a blend band (1.5), the solid wall's voxels counted solid
//                                                                          RED: the same seam as a solid wall
//   margins    the margin per voxel by the type's law; its smallest is the check's own strut margin
//                                                                          RED: the octet's law gives another
//   cells      sheet_cells.bin as judged: each cell's worst voxel's margin, its flags, cells across; written and read
//                                                                          RED: a cut cell has no margin
//   check      a Structural sheet lay through the CLI's own check (lattice_file_strength_check): a number, cells
//              credited as lattice_credit credits them                     RED: none credited under the floor
//   file       the file job with the check: sheet_cells.bin beside strength.json, named in the block ("sheet_cells")
//                                                                          RED: no strength job, no file, no block
//   threads    the same credit on one thread
//   struts     a strut layout's credit carries none of the sheets' vectors
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/stl.hpp"
#include "topopt/strut_strength.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kDir = std::string(TMP_DIR) + "/lattice_sheets_strength";

std::string slurp(const std::string& p) {
  std::ifstream f(p, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
bool has(const std::string& s, const std::string& w) { return s.find(w) != std::string::npos; }
void write(const std::string& path, const std::string& text) { std::ofstream(path) << text; }
double num_after(const std::string& s, const std::string& key) {
  const std::size_t k = s.find("\"" + key + "\": ");
  if (k == std::string::npos) return std::numeric_limits<double>::quiet_NaN();
  const std::size_t v = k + key.size() + 4;
  if (s.compare(v, 4, "null") == 0) return std::numeric_limits<double>::quiet_NaN();
  return std::strtod(s.c_str() + v, nullptr);
}

TriangleMesh box(double L, double W, double H) {
  TriangleMesh m;
  for (const Vec3& v : std::vector<Vec3>{{0, 0, 0}, {L, 0, 0}, {L, W, 0}, {0, W, 0},
                                         {0, 0, H}, {L, 0, H}, {L, W, H}, {0, W, H}})
    m.vertices.push_back(v);
  const int t[12][3] = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                        {3, 7, 6}, {3, 6, 2}, {0, 4, 7}, {0, 7, 3}, {1, 2, 6}, {1, 6, 5}};
  for (const auto& tri : t) m.triangles.push_back({tri[0], tri[1], tri[2]});
  return m;
}
int face_with_normal(const StepModel& m, double nx, double ny, double nz) {
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind == StepSurfaceKind::Plane && fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz > 0.99)
      return f;
  }
  return -1;
}

struct Part {
  std::string path;
  int top = -1, bottom = -1, side = -1;
  Vec3 lo{}, hi{};
};
Part make_part(const std::string& name, double L, double W, double H) {
  Part p;
  p.path = kDir + "/" + name + ".stl";
  write_stl_file(p.path, box(L, W, H), StlFormat::Binary);
  const StepModel m = import_part_file_resolved(p.path);
  p.top = face_with_normal(m, 0, 0, 1);
  p.bottom = face_with_normal(m, 0, 0, -1);
  p.side = face_with_normal(m, 1, 0, 0);
  p.hi = {L, W, H};
  return p;
}

// A sheet layout's JSON (the file job's keys): the whole part, a typed cell; `extra` more keys.
std::string layout_json(const std::string& type, double cell_mm, int across, const std::string& extra = "") {
  char b[512];
  std::snprintf(b, sizeof b,
                "{\"min_strut_lines\": 2, \"bead_mm\": 0.45, \"topology\": \"%s\", \"algorithm\": \"uniform\", "
                "\"cell_max_mm\": 8, \"cell_mm\": %.6g, \"min_cells_across\": %d, \"all_lattice\": true, "
                "\"auto_by_cell\": true",
                type.c_str(), cell_mm, across);
  return std::string(b) + extra + "}";
}
Settings settings_of(const std::string& layout) {
  return parse_file_job("{\"mode\": \"lattice_file\", \"model\": \"x.stl\", \"layout\": " + layout + "}").settings;
}
std::string strength_job_json(const Part& p, const std::string& type, double newtons) {
  return "{\"model\": \"" + p.path + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(p.bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(p.top) + "], \"force\": [0, 0, " + std::to_string(-newtons) + "]}]}, "
         "\"lattice\": {\"topology\": \"" + type + "\", \"require_lattice_void_reaches_exterior\": false, \"skin\": \"none\"}, "
         "\"grading\": {\"topology\": \"" + type + "\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}

CreditGrid grid_over(const Part& p, double h) {
  CreditGrid g;
  g.origin = {p.lo.x - h, p.lo.y - h, p.lo.z - h};
  g.spacing = h;
  g.nx = static_cast<int>(std::ceil((p.hi.x - p.lo.x) / h)) + 2;
  g.ny = static_cast<int>(std::ceil((p.hi.y - p.lo.y) / h)) + 2;
  g.nz = static_cast<int>(std::ceil((p.hi.z - p.lo.z) / h)) + 2;
  return g;
}
Vec3 centre(const CreditGrid& g, std::size_t e) {
  const std::size_t i = e % static_cast<std::size_t>(g.nx), j = (e / g.nx) % static_cast<std::size_t>(g.ny),
                    k = e / (static_cast<std::size_t>(g.nx) * g.ny);
  return {g.origin.x + (i + 0.5) * g.spacing, g.origin.y + (j + 0.5) * g.spacing, g.origin.z + (k + 0.5) * g.spacing};
}
const SheetField* field_of(const Outcome& o, const Cell& c) {
  for (const SheetField& f : o.sheets)
    if (f.region == c.region && f.frame == c.frame) return &f;
  return nullptr;
}

// The check wrote sheet_cells.bin and named it; its records are the lay's cells, and the smallest margin among them is
// the strut result's (the check's own law, density and stress: lattice_voxel_margins on its composite solve).
void check_cells_against_block(const StrengthDone& d, const std::string& dir, const std::string& tag, double strut_margin,
                               std::size_t cells) {
  const bool wrote = std::find(d.files.begin(), d.files.end(), std::string(kSheetCellsName)) != d.files.end();
  CHECK(wrote && has(d.json, "\"sheet_cells\": \"sheet_cells.bin\"") && has(d.json, "\"margins\": true"));
  SheetCellsFile f;
  std::string why;
  const bool read = read_sheet_cells_file(dir + "/" + kSheetCellsName, f, &why);
  CHECK(read && f.cells.size() == cells);
  double least = std::numeric_limits<double>::infinity();
  std::size_t judged = 0;
  for (const SheetCellRecord& r : f.cells)
    if (!std::isnan(r.margin)) {
      ++judged;
      least = std::min(least, static_cast<double>(r.margin));
    }
  std::printf("[check %s] the check wrote %s itself: %s; %zu of %zu cells judged, smallest margin %.6g against the strut "
              "result's %.6g\n", tag.c_str(), kSheetCellsName, wrote ? "yes" : "NO", judged, f.cells.size(), least,
              strut_margin);
  CHECK(judged > 0 && std::isfinite(strut_margin) && std::fabs(least - strut_margin) <= 1e-5 * strut_margin);
}

}  // namespace

int main() {
  std::setvbuf(stdout, nullptr, _IOLBF, 0);   // each line as it is printed (the run is long)
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);

  // 11 x 12 x 13 cells of 4.8 mm: every member at least ten cells across (11, by room_through), the floor of both sheets (10 / 9)
  // held; no face diagonal of the box passes through a voxel centre of the check's grid (a 52 mm cube's did: the old
  // voxeliser then left three empty columns inside it, which no inscribed ball can cross).
  const Part big = make_part("big", 52.8, 57.6, 62.4);
  const Part plate = make_part("plate", 52, 52, 12);
  const Part small = make_part("small", 12, 12, 12);
  CHECK(big.top >= 0 && big.bottom >= 0);

  // ── place: a graded wall (By stress, the stress rising along x) ──
  {
    Session s(import_part_file_resolved(big.path));
    Settings st = settings_of(layout_json("gyroid", 4.8, 1, ", \"by_stress\": true, \"dial_light\": 0.01, \"dial_heavy\": 1, "
                                                            "\"reference_mpa\": 52"));
    auto d = std::make_shared<DemandField>();
    d->origin = {-1, -1, -1};
    d->spacing = 1.0;
    d->nx = d->ny = d->nz = 66;
    d->mpa.resize(static_cast<std::size_t>(66) * 66 * 66);
    for (int k = 0; k < 66; ++k)
      for (int j = 0; j < 66; ++j)
        for (int i = 0; i < 66; ++i) d->mpa[d->index(i, j, k)] = static_cast<float>(i);
    st.stress.demand = d;
    const Outcome o = s.lay(st);
    CHECK(!o.sheets.empty() && o.bars.bars.empty());
    const SheetField& f0 = o.sheets.front();
    std::printf("[place] cells %zu, fields %zu, walls %.3f..%.3f mm\n", o.layout.cells.size(), o.sheets.size(),
                f0.wall_min_mm, f0.wall_max_mm);
    CHECK(f0.wall_max_mm > f0.wall_min_mm + 0.05);
    const CreditGrid g = grid_over(big, 1.0);
    const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, g);
    CHECK(c.voxel_rho.size() == c.cell.size() && c.cell_flags.size() == o.layout.cells.size() &&
          c.cell_across.size() == o.layout.cells.size());
    const double lo = lattice_rho_min(LatticeTopology::Gyroid), hi = lattice_rho_max(LatticeTopology::Gyroid);
    std::size_t credited = 0, wrong = 0, out_band = 0, differ = 0;
    double most = 0.0;
    std::map<std::pair<double, double>, double> seen;   // the law past its table integrates: once per wall
    const auto law = [&](double cell, double wall) {
      const auto it = seen.find({cell, wall});
      if (it != seen.end()) return it->second;
      const double r = lattice_density_from_strut(LatticeTopology::Gyroid, cell, 0.5 * wall);
      seen.emplace(std::make_pair(cell, wall), r);
      return r;
    };
    for (std::size_t e = 0; e < c.cell.size(); ++e) {
      if (!c.credited[e]) {
        CHECK(c.voxel_rho[e] == 0.0f);
        continue;
      }
      ++credited;
      const Cell& cell = o.layout.cells[static_cast<std::size_t>(c.cell[e])];
      const SheetField* f = field_of(o, cell);
      const double want = law(cell.size, sheet_wall_at(*f, centre(g, e)));
      if (std::fabs(want - c.voxel_rho[e]) > 1e-6) ++wrong;
      if (c.voxel_rho[e] < lo || c.voxel_rho[e] > hi) ++out_band;
      const double d1 = std::fabs(c.voxel_rho[e] - c.cell_rho[static_cast<std::size_t>(c.cell[e])]);
      if (d1 > 1e-4) ++differ;
      most = std::max(most, d1);
    }
    std::printf("[place] voxels credited %zu (%zu counted), own density off %zu, out of band %zu; differ from the cell's "
                "own %zu (most %.4f)\n", credited, c.voxels_credited, wrong, out_band, differ, most);
    CHECK(credited > 0 && credited == c.voxels_credited && wrong == 0 && out_band == 0);
    std::printf("RED place: the cells' own walls, unblended, differ at %zu credited voxels\n", differ);
    CHECK(differ > 0);
    // threads: the same on one thread.
    const LatticeCredit one = lattice_credit(o.layout, *s.domain(), o.bars, {}, g, nullptr, 1);
    CHECK(one.cell == c.cell && one.credited == c.credited && one.voxel_rho == c.voxel_rho &&
          one.cell_flags == c.cell_flags && one.cell_across == c.cell_across && one.voxels_credited == c.voxels_credited);
  }

  // ── floor and cut: the 52 mm box (ten across) against a 12 mm plate (two across) ──
  for (const char* type : {"gyroid", "schwarz_d"}) {
    const LatticeTopology topo = std::string(type) == "gyroid" ? LatticeTopology::Gyroid : LatticeTopology::SchwarzD;
    const double cell = std::string(type) == "gyroid" ? 4.8 : 5.5;   // Schwarz-D: its smallest cell is 5.41 mm
    std::size_t plate_ok_at_one = 0;
    for (const Part* p : {&big, &plate}) {
      Session s(import_part_file_resolved(p->path));
      const Outcome o = s.lay(settings_of(layout_json(type, cell, 1)));
      const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, grid_over(*p, 1.0));
      std::size_t cut = 0, cut_credited = 0, under = 0, interior = 0, interior_credited = 0, under_voxels = 0;
      int least = 1 << 30, most = 0;
      for (std::size_t i = 0; i < o.layout.cells.size(); ++i) {
        const Cell& x = o.layout.cells[i];
        const std::uint32_t fl = c.cell_flags[i];
        if (x.cut) {
          ++cut;
          CHECK((fl & SheetCellRecord::kCut) != 0);
          cut_credited += c.cell_credit[i];
        } else {
          ++interior;
          interior_credited += c.cell_credit[i];
          least = std::min(least, c.cell_across[i]);
          most = std::max(most, c.cell_across[i]);
        }
        if (fl & SheetCellRecord::kUnderFloor) {
          ++under;
          CHECK(c.cell_across[i] >= 0 && c.cell_across[i] < c.floor_cells && !c.cell_credit[i]);
          // RED: with the floor read as 1, a whole cell in the band would be credited.
          if (!x.cut && !(fl & SheetCellRecord::kOutOfBand)) ++plate_ok_at_one;
        }
      }
      for (std::size_t e = 0; e < c.cell.size(); ++e)
        if (c.credited[e] && (c.cell_flags[static_cast<std::size_t>(c.cell[e])] & (SheetCellRecord::kUnderFloor | SheetCellRecord::kCut)))
          ++under_voxels;
      std::printf("[floor %s %s] cells %zu: cut %zu (credited %zu), whole %zu (credited %zu, across %d..%d), under the "
                  "floor %zu of %.0f; voxels credited %zu, in a cut or under-floor cell %zu\n",
                  type, p == &big ? "box" : "plate", o.layout.cells.size(), cut, cut_credited, interior,
                  interior_credited, least, most, under, c.floor_cells, c.voxels_credited, under_voxels);
      if (!o.layout.cells.empty())
        std::printf("    the cell laid %.4f mm (asked %.2f), its wall %.4f mm\n", o.layout.cells.front().size, cell,
                    o.layout.cells.front().strut);
      CHECK(c.floor_cells == sheet_structural_floor_cells(topo));
      CHECK((p == &big || cut > 0) && cut_credited == 0 && under_voxels == 0);
      if (p == &big) {
        CHECK(interior > 0 && interior_credited == interior && least >= c.floor_cells && c.voxels_credited > 0);
      } else {
        CHECK(under >= interior && interior > 0);
        CHECK(interior_credited == 0 && c.voxels_credited == 0);
      }
    }
    std::printf("RED floor %s: read as 1, %zu of the plate's cells would be credited\n", type, plate_ok_at_one);
    CHECK(plate_ok_at_one > 0);
  }

  // ── band: a two-line wall past 18.5 mm (gyroid) / 17.2 mm (Schwarz-D) ──
  for (const char* type : {"gyroid", "schwarz_d"}) {
    const bool gy = std::string(type) == "gyroid";
    {   // A record: the density of the open look's own wall (the widest without Allow quilt) against the band's top.
      const LatticeTopology topo = gy ? LatticeTopology::Gyroid : LatticeTopology::SchwarzD;
      const double ol = lattice_width_bounds(topo).open_look;
      std::printf("[band %s] the open look %.6f of the cell: density %.6f, the band %.5f - %.5f\n", type, ol,
                  lattice_density_from_strut(topo, 1.0, 0.5 * ol), lattice_rho_min(topo), lattice_rho_max(topo));
    }
    const double past = gy ? 19.0 : 18.0, under = gy ? 17.0 : 16.0;
    std::size_t flagged[2] = {0, 0}, cells[2] = {0, 0}, voxels[2] = {0, 0};
    for (int k = 0; k < 2; ++k) {
      Session s(import_part_file_resolved(big.path));
      Settings st = settings_of(layout_json(type, k ? under : past, 1, ", \"strut_width_mm\": 0.9"));
      st.struts.auto_by_cell = false;
      const Outcome o = s.lay(st);
      const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, grid_over(big, 1.0));
      cells[k] = o.layout.cells.size();
      for (std::uint32_t fl : c.cell_flags) flagged[k] += (fl & SheetCellRecord::kOutOfBand) ? 1 : 0;
      voxels[k] = c.voxels_credited;
    }
    std::printf("[band %s] %.0f mm cells: %zu of %zu out of the band, %zu voxels credited; RED %.0f mm: %zu of %zu\n",
                type, past, flagged[0], cells[0], voxels[0], under, flagged[1], cells[1]);
    CHECK(cells[0] > 0 && flagged[0] == cells[0] && voxels[0] == 0);
    CHECK(cells[1] > 0 && flagged[1] == 0);
  }

  // ── blend: two regions with different cells meet (the whole part's 4.8 mm, a top region's own 5.2 mm) ──
  {
    std::size_t band_voxels[2] = {0, 0}, membrane[2] = {0, 0}, credited[2] = {0, 0}, in_band_credited = 0;
    std::size_t seams[2] = {0, 0};
    for (int k = 0; k < 2; ++k) {
      Session s(import_part_file_resolved(big.path));
      const std::string extra = ", \"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [10], "
                                "\"region_expand_mm\": [0], \"region_face_counts\": [1], \"region_faces\": [" +
                                std::to_string(big.top) + "], \"region_own\": [{\"cell_mm\": 5.2}], \"sheet_seam\": \"" +
                                (k ? "solid_wall" : "blend") + "\"";
      const Outcome o = s.lay(settings_of(layout_json("gyroid", 4.8, 1, extra)));
      seams[k] = o.sheet_seams.size();
      const CreditGrid g = grid_over(big, 0.6);   // its centres within the membrane (0.45 mm of the seam at z = 42)
      const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, g);
      band_voxels[k] = c.blend_band;
      membrane[k] = c.membrane;
      credited[k] = c.voxels_credited;
      if (k == 0)
        for (std::size_t e = 0; e < c.cell.size(); ++e) {
          if (!c.credited[e]) continue;
          for (const SheetSeamBand& b : o.sheet_seams)
            if (!b.solid_wall) {
              const double m = sheet_seam_mm(*s.domain(), b, centre(g, e));
              const Cell& x = o.layout.cells[static_cast<std::size_t>(c.cell[e])];
              if ((x.region == b.region_a || x.region == b.region_b) && std::isfinite(m) && std::fabs(m) < 0.5 * b.band_mm)
                ++in_band_credited;
            }
        }
      std::printf("[blend %s] fields %zu, seams %zu, membrane pairs %zu; voxels credited %zu, in a blend band %zu, in the "
                  "membrane %zu\n", k ? "solid_wall" : "blend", o.sheets.size(), o.sheet_seams.size(),
                  o.layout.membrane.size(), c.voxels_credited, c.blend_band, c.membrane);
    }
    CHECK(seams[0] > 0 && seams[1] > 0);
    CHECK(band_voxels[0] > 0 && in_band_credited == 0 && credited[0] > 0);
    std::printf("RED blend: as a solid wall, %zu voxels in a blend band, %zu in the membrane\n", band_voxels[1], membrane[1]);
    CHECK(band_voxels[1] == 0 && membrane[1] > 0 && membrane[0] == 0);
  }

  // ── margins, cells and the check, on one Structural lay of the 52 mm box ──
  for (const char* type : {"gyroid", "schwarz_d"}) {
    const LatticeTopology topo = std::string(type) == "gyroid" ? LatticeTopology::Gyroid : LatticeTopology::SchwarzD;
    StepModel m = import_part_file_resolved(big.path);
    Session s(std::move(m));
    const Outcome o = s.lay(settings_of(layout_json(type, topo == LatticeTopology::Gyroid ? 4.8 : 5.5, topo == LatticeTopology::Gyroid ? 10 : 9)));   // Structural: ten across (the lay's own floor)
    CHECK(!o.sheets.empty());
    const CreditGrid g = grid_over(big, 1.3);
    const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, g);
    // margins: a made stress field (a bending-like ramp with some shear and pressure), against the law's own report.
    const std::size_t n = c.cell.size();
    std::vector<double> stress(6 * n, 0.0);
    std::vector<char> mask(n, 0);
    std::vector<double> rho(n, 0.0);
    for (std::size_t e = 0; e < n; ++e) {
      const Vec3 p = centre(g, e);
      stress[6 * e + 2] = 0.2 * (p.x - 26.0);
      stress[6 * e + 0] = 0.05 * p.y;
      stress[6 * e + 3] = 0.03 * p.z;
      mask[e] = c.credited[e];
      rho[e] = c.voxel_rho[e];
    }
    const Vec3 up{0, 0, 1};
    const double Y = 50.0, zk = 0.55;
    const std::vector<float> vm = lattice_voxel_margins(topo, c, stress, up, Y, zk);
    double least = std::numeric_limits<double>::infinity();
    std::size_t judged = 0;
    for (std::size_t e = 0; e < n; ++e) {
      if (std::isnan(vm[e])) { CHECK(!c.credited[e]); continue; }
      ++judged;
      least = std::min(least, static_cast<double>(vm[e]));
    }
    const StrutStrengthReport rep = evaluate_strut_strength(topo, stress, mask, rho, up, Y, zk);
    const StrutStrengthReport octet = evaluate_strut_strength(LatticeTopology::Octet, stress, mask, rho, up, Y, zk);
    std::printf("[margins %s] %zu voxels judged; smallest %.6g, the law's report %.6g; RED octet's law %.6g\n", type, judged,
                least, rep.margin_worst_case, octet.margin_worst_case);
    CHECK(judged == c.voxels_credited && judged > 0);
    CHECK(std::fabs(least - rep.margin_worst_case) <= 1e-5 * rep.margin_worst_case);
    CHECK(std::fabs(least - octet.margin_worst_case) > 1e-3 * rep.margin_worst_case);

    // cells: sheet_cells.bin as judged.
    const SheetCellsFile f = sheet_cells_judged(o.layout, c, vm);
    CHECK(f.cells.size() == o.layout.cells.size());
    std::vector<float> worst(o.layout.cells.size(), std::numeric_limits<float>::quiet_NaN());
    for (std::size_t e = 0; e < n; ++e)
      if (c.cell[e] >= 0 && !std::isnan(vm[e])) {
        float& w = worst[static_cast<std::size_t>(c.cell[e])];
        if (std::isnan(w) || vm[e] < w) w = vm[e];
      }
    std::size_t same = 0, judged_cells = 0;
    for (std::size_t i = 0; i < f.cells.size(); ++i) {
      const SheetCellRecord& r = f.cells[i];
      const bool a = std::isnan(r.margin), b = std::isnan(worst[i]);
      if ((a && b) || (!a && !b && r.margin == worst[i])) ++same;
      judged_cells += a ? 0 : 1;
      CHECK(r.flags == c.cell_flags[i] && r.cells_across == static_cast<float>(c.cell_across[i]));
      CHECK(r.wall_mm == static_cast<float>(o.layout.cells[i].strut) && r.size_mm == static_cast<float>(o.layout.cells[i].size));
    }
    CHECK(same == f.cells.size() && judged_cells > 0);
    {   // RED: the plate (every cell cut or under the floor, none credited): the same stress gives no cell a margin.
      Session sp(import_part_file_resolved(plate.path));
      const Outcome op = sp.lay(settings_of(layout_json(type, topo == LatticeTopology::Gyroid ? 4.8 : 5.5, 1)));
      const CreditGrid gp = grid_over(plate, 1.3);
      const LatticeCredit cp = lattice_credit(op.layout, *sp.domain(), op.bars, {}, gp);
      const std::vector<float> mp = lattice_voxel_margins(topo, cp, std::vector<double>(6 * cp.cell.size(), 1.0), up, Y, zk);
      std::size_t with = 0, cut = 0;
      for (const SheetCellRecord& r : sheet_cells_judged(op.layout, cp, mp).cells) {
        with += std::isnan(r.margin) ? 0 : 1;
        cut += (r.flags & SheetCellRecord::kCut) ? 1 : 0;
      }
      std::printf("[cells %s] %zu of %zu cells judged; RED the plate: %zu of %zu cells (%zu cut) with a margin\n", type,
                  judged_cells, f.cells.size(), with, op.layout.cells.size(), cut);
      CHECK(op.layout.cells.size() > 0 && cut > 0 && with == 0);
    }
    const SheetCheckFiles w = write_sheet_check_files(kDir, o.layout, c, vm);
    CHECK(w.ok && w.file == kSheetCellsName && has(w.keys, "\"sheet_cells\": \"sheet_cells.bin\"") &&
          has(w.keys, "\"margins\": true") && has(w.keys, "\"voxels_credited\": " + std::to_string(c.voxels_credited)));
    SheetCellsFile back;
    std::string why;
    CHECK(read_sheet_cells_file(kDir + "/" + kSheetCellsName, back, &why));
    CHECK(back.cells.size() == f.cells.size() && back.frames.size() == f.frames.size());
    std::size_t bytes_same = 0;
    for (std::size_t i = 0; i < back.cells.size() && i < f.cells.size(); ++i) {
      const SheetCellRecord &x = back.cells[i], &y = f.cells[i];
      const bool mx = std::isnan(x.margin), my = std::isnan(y.margin);
      bytes_same += (x.region == y.region && x.frame == y.frame && x.flags == y.flags && x.wall_mm == y.wall_mm &&
                     x.cells_across == y.cells_across && ((mx && my) || x.margin == y.margin)) ? 1 : 0;
    }
    CHECK(bytes_same == f.cells.size());
    // The block's keys put in right after its "{".
    const std::string b = strength_block_with("{\n    \"accepted\": true\n  }", w.keys);
    CHECK(b.rfind("{\n    \"sheet_cells\": \"sheet_cells.bin\",\n    \"sheet_credit\": {", 0) == 0 && has(b, "\"accepted\": true"));

    // check: the CLI's own check on this lay (no file made: the check reads the layout, not the mesh).
    const FileReport made;
    StrengthAsk ask;
    ask.session = &s;
    ask.outcome = &o;
    ask.made = &made;
    write(kDir + "/strength_job.json", strength_job_json(big, type, 50.0));
    ask.job_path = kDir + "/strength_job.json";
    ask.out_dir = kDir + "/check_" + type;
    std::filesystem::create_directories(ask.out_dir);
    ask.part_lo = big.lo;
    ask.part_hi = big.hi;
    const StrengthDone d = check.run(ask);
    std::printf("[check %s] ok %d %s %s\n", type, d.ok, d.why.c_str(), d.detail.c_str());
    CHECK(d.ok);
    write(ask.out_dir + "/block.json", d.json);
    const double credited = num_after(d.json, "cells_credited");
    const std::size_t strut_at = d.json.find("\"strut\": {");
    const double strut_margin = strut_at == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                                              : num_after(d.json.substr(strut_at), "margin_worst_case");
    const std::size_t fr = d.json.find("\"fail_reason\": \"");
    std::printf("[check %s] verdict %s%s, the sheet's own margin %.4g, cells credited %.0f (lattice_credit on its own "
                "grid: the lay's %zu cells, %zu credited at 1.3 mm), strut law: %s\n", type,
                has(d.json, "\"verdict\": \"pass\"") ? "pass" : has(d.json, "\"verdict\": \"fail\"") ? "fail" : "solid_only",
                fr == std::string::npos ? "" : (" (" + d.json.substr(fr + 16, d.json.find('"', fr + 16) - fr - 16) + ")").c_str(),
                strut_margin, credited, o.layout.cells.size(), c.cells_credited,
                has(d.json, "\"uncertified\": false") ? "certified" : "uncertified");
    CHECK(std::isfinite(strut_margin) && strut_margin > 0.0);
    CHECK(credited == static_cast<double>(c.cells_credited) && credited > 0);
    CHECK(has(d.json, "\"uncertified\": false"));
    // The check writes sheet_cells.bin itself (lattice_file_strength_check, write_sheet_check_files) and names it; its
    // cells' margins are its own: the smallest is the strut result's margin (the same law, density and stress).
    check_cells_against_block(d, ask.out_dir, type, strut_margin, o.layout.cells.size());
    // THE CELLS-PER-MEMBER GUARD (analyze.cpp, bar L4): every member of the box holds at least ten cells (cell_across,
    // room_through), the floor of both sheets. A record of what the old guard says of it.
    const std::size_t reg = d.json.find("\"out_of_regime\": "), why_at = d.json.find("\"not_certified_reason\": \"");
    std::printf("[guard %s] not certified: %s; out of regime: %s; verdict %s; reason: %s\n", type,
                has(d.json, "\"not_certified\": true") ? "YES" : "no",
                reg == std::string::npos ? "?" : d.json.substr(reg + 17, 5).c_str(),
                has(d.json, "\"verdict\": \"pass\"") ? "pass" : has(d.json, "\"verdict\": \"fail\"") ? "fail" : "solid_only",
                why_at == std::string::npos ? "" : d.json.substr(why_at + 25, d.json.find('"', why_at + 25) - why_at - 25).c_str());
    CHECK(!has(d.json, "\"not_certified\": true") && has(d.json, "\"out_of_regime\": false"));   // ANALYZE GUARD (sheets)
  }

  // ── check, graded: the solve sees each voxel's own density (By stress: the wall blended between cells) ──
  {
    Session s(import_part_file_resolved(big.path));
    Settings st = settings_of(layout_json("gyroid", 4.8, 10, ", \"by_stress\": true, \"dial_light\": 0.01, \"dial_heavy\": 1, "
                                                             "\"reference_mpa\": 52"));
    auto dm = std::make_shared<DemandField>();
    dm->origin = {-1, -1, -1};
    dm->spacing = 1.0;
    dm->nx = dm->ny = dm->nz = 66;
    dm->mpa.resize(static_cast<std::size_t>(66) * 66 * 66);
    for (int k = 0; k < 66; ++k)
      for (int j = 0; j < 66; ++j)
        for (int i = 0; i < 66; ++i) dm->mpa[dm->index(i, j, k)] = static_cast<float>(66 - i);   // heaviest at x = 0
    st.stress.demand = dm;
    const Outcome o = s.lay(st);
    CHECK(!o.sheets.empty() && o.sheets.front().wall_max_mm > o.sheets.front().wall_min_mm + 0.05);
    const FileReport made;
    StrengthAsk ask;
    ask.session = &s;
    ask.outcome = &o;
    ask.made = &made;
    write(kDir + "/strength_job.json", strength_job_json(big, "gyroid", 50.0));
    ask.job_path = kDir + "/strength_job.json";
    ask.out_dir = kDir + "/check_graded";
    std::filesystem::create_directories(ask.out_dir);
    ask.part_lo = big.lo;
    ask.part_hi = big.hi;
    const StrengthDone d = check.run(ask);
    CHECK(d.ok);
    const std::size_t strut_at = d.json.find("\"strut\": {");
    const double strut_margin = strut_at == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                                              : num_after(d.json.substr(strut_at), "margin_worst_case");
    std::printf("[check graded] ok %d, walls %.3f..%.3f mm, the sheet's own margin %.6g\n", d.ok,
                o.sheets.front().wall_min_mm, o.sheets.front().wall_max_mm, strut_margin);
    check_cells_against_block(d, ask.out_dir, "graded", strut_margin, o.layout.cells.size());
    // RED: the cells' own densities (what the solve read before the voxels' were sent) differ from the voxels' here.
    const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, grid_over(big, 1.3));
    std::size_t differ = 0;
    for (std::size_t e = 0; e < c.cell.size(); ++e)
      if (c.credited[e] && std::fabs(c.voxel_rho[e] - c.cell_rho[static_cast<std::size_t>(c.cell[e])]) > 1e-4) ++differ;
    std::printf("RED check graded: the cells' own densities differ from the voxels' at %zu of %zu credited voxels\n", differ,
                c.voxels_credited);
    CHECK(differ > 0);
  }

  // ── THE GUARD'S CASE: an all-lattice gyroid box whose thinnest member holds ten 4.8 mm cells (49 mm: 10.2 across by
  // room_through, the lay's Structural floor 48 mm held), through the CLI's own check ──
  {
    const Part member = make_part("member", 49.0, 57.6, 62.4);
    Session s(import_part_file_resolved(member.path));
    const Outcome o = s.lay(settings_of(layout_json("gyroid", 4.8, 10)));
    const LatticeCredit c = lattice_credit_cells(o.layout, *s.domain());
    int least = 1 << 30;
    for (std::size_t i = 0; i < o.layout.cells.size(); ++i)
      if (!o.layout.cells[i].cut) least = std::min(least, c.cell_across[i]);
    const FileReport made;
    StrengthAsk ask;
    ask.session = &s;
    ask.outcome = &o;
    ask.made = &made;
    write(kDir + "/strength_job.json", strength_job_json(member, "gyroid", 50.0));
    ask.job_path = kDir + "/strength_job.json";
    ask.out_dir = kDir + "/check_member";
    std::filesystem::create_directories(ask.out_dir);
    ask.part_lo = member.lo;
    ask.part_hi = member.hi;
    const StrengthDone d = check.run(ask);
    CHECK(d.ok && !o.layout.cells.empty() && least >= 10);
    write(ask.out_dir + "/block.json", d.json);
    const std::size_t why_at = d.json.find("\"not_certified_reason\": \"");
    std::printf("[guard member] %zu cells, whole ones %d+ across; not certified: %s; reason: %s\n", o.layout.cells.size(),
                least, has(d.json, "\"not_certified\": true") ? "YES" : "no",
                why_at == std::string::npos ? "" : d.json.substr(why_at + 25, d.json.find('"', why_at + 25) - why_at - 25).c_str());
    // ANALYZE GUARD (sheets): the guard reads the engine's own member width (sheet_member_width_mm), so a box ten cells
    // across is in regime. RED CONTROL: c347c70a, the same case with the guard on the voxel staircase: "Not certified:
    // ... its thinnest latticed member is 1.3 cells across, below the 10".
    CHECK(!has(d.json, "\"not_certified\": true") && has(d.json, "\"out_of_regime\": false"));
    const CreditGrid g = grid_over(member, 1.56);
    const LatticeCredit cg = lattice_credit(o.layout, *s.domain(), o.bars, {}, g);
    const std::vector<double> w = sheet_member_width_mm(o.layout, *s.domain(), cg, g);
    double thinnest = std::numeric_limits<double>::infinity();
    std::size_t read = 0;
    for (std::size_t e = 0; e < w.size(); ++e)
      if (cg.cell[e] >= 0) {
        ++read;
        thinnest = std::min(thinnest, w[e] / o.layout.cells[static_cast<std::size_t>(cg.cell[e])].size);
      }
    std::printf("[guard member] the width the guard reads: %zu lattice voxels, thinnest %.3f cells across\n", read, thinnest);
    CHECK(w.size() == cg.cell.size() && read > 0 && thinnest >= 10.0);
  }

  // ── file: the file job with the check, as the CLI runs it (a 12 mm box: every member under the floor) ──
  for (int k = 0; k < 2; ++k) {
    const std::string folder = kDir + (k ? "/file_none" : "/file");
    std::filesystem::create_directories(folder);
    write(folder + "/strength_job.json", strength_job_json(small, "gyroid", 20.0));
    write(folder + "/job.json", "{\"mode\": \"lattice_file\", \"model\": \"" + small.path + "\", \"output\": \"lattice.stl\"" +
                                    (k ? std::string() : std::string(", \"strength_job\": \"strength_job.json\"")) +
                                    ", \"layout\": " + layout_json("gyroid", 5.0, 1) + "}");
    const FileResult r = run_file_job(folder + "/job.json", folder, 0, nullptr, &check);
    const std::string res = slurp(folder + "/" + kFileResultName);
    std::printf("[file%s] ok %d %s %s; cells %zu, strength ran %d\n", k ? " no check" : "", r.ok, r.why.c_str(),
                r.detail.c_str(), r.cells, r.strength_ran);
    CHECK(r.ok);
    const bool there = std::filesystem::exists(folder + "/" + kSheetCellsName);
    if (k == 0) {
      CHECK(r.strength_ran && there && has(r.strength_json, "\"sheet_cells\": \"sheet_cells.bin\""));
      CHECK(has(res, "\"sheet_cells\": \"sheet_cells.bin\"") && has(res, "\"sheet_credit\": {"));
      SheetCellsFile f;
      std::string why;
      CHECK(read_sheet_cells_file(folder + "/" + kSheetCellsName, f, &why));
      std::size_t under = 0;
      for (const SheetCellRecord& x : f.cells) under += (x.flags & SheetCellRecord::kUnderFloor) ? 1 : 0;
      std::printf("[file] sheet_cells.bin: %zu cells (the lay's %zu), %zu under the floor; margins %s\n", f.cells.size(),
                  r.cells, under, has(r.strength_json, "\"margins\": true") ? "the check's" : "not judged (NaN)");
      CHECK(f.cells.size() == r.cells && under > 0);
      CHECK(has(r.strength_json, "\"margins\": true"));   // the check's own file (its cells judged; none credited here)
    } else {
      std::printf("RED file: no strength job: %s %s, a strength block %s\n", kSheetCellsName, there ? "written" : "not written",
                  has(res, "\"strength\": {") ? "written" : "not written");
      CHECK(!there && !r.strength_ran && !has(res, "\"strength\": {"));
    }
  }

  // ── struts: a strut layout's credit carries none of the sheets' vectors ──
  {
    Session s(import_part_file_resolved(small.path));
    const Outcome o = s.lay(settings_of(layout_json("octet", 5.0, 1)));
    const LatticeCredit c = lattice_credit(o.layout, *s.domain(), o.bars, {}, grid_over(small, 1.0));
    CHECK(!o.bars.bars.empty() && c.voxel_rho.empty() && c.cell_flags.empty() && c.cell_across.empty() &&
          c.voxels_credited == 0 && c.floor_cells == 0.0);
    CHECK(lattice_credit_cells(o.layout, *s.domain()).cell_flags.empty());
    CHECK(c.cell_room_mm.empty() && sheet_member_width_mm(o.layout, *s.domain(), c, grid_over(small, 1.0)).empty());   // the guard's staircase, as before
    const SheetCheckFiles w = write_sheet_check_files(kDir + "/octet_none", o.layout, c, {});
    CHECK(w.ok && w.file.empty() && w.keys.empty());
  }

  std::printf("lattice_sheets_strength: %d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
