// THE TYPE MATRIX (2026-11-24, the owner: all nine strut types on the new lattice engine, laid, printed and checked as
// well as the octet). Every strut type through the layout (Session::lay) and the file job (run_file_job, with the CLI's
// strength check), on core's own fixtures:
//   cube    core/tests/fixtures/step/cube.step, the 10 mm cube (face 4 its top)
//   plate   core/tests/fixtures/mesh/filleted_bore_plate.stl, a round plate 44 mm across and 6 mm thick with a bore
//           whose top edge is filleted: sloped faces and a hole the lattice is cut by
//   bracket core/tests/fixtures/demo/l-bracket.step, the L-bracket stood on the end of its plate (print_frame up +X):
//           its upright wall then overhangs the plate, so the 3MF paints supports under it
// Structural = a job with a strength job (Aesthetic never sends one, U9); the strength-checked six (sc, bcc, fcc,
// diamond, kelvin, rhombic) in both, bccz, fccz and reentrant in Aesthetic only, and a Structural job naming one of
// those is refused in one plain line. Auto (cell 0: the app's Auto, cell_search and stretch_edges on) and a typed cell;
// a face region and the whole part.
//
// The checks, each with its RED control (a case it must fail on):
//   lays      cells are laid and nothing throws                       RED: a region shallower than any cell
//   two_lines every bar is at least two line widths wide              RED: the same job laid at one line
//   skin      with Finish Skin, the cut ends are joined by the skin   RED: the same job with Skin off
//             (read before Finish None's drop, which would take the open ends away and hide them)
//   loose     no bar ends loose, no piece adrift                      RED: the same job with join and drop off
//   print     the file is made, print-clean, counts sane              RED: a result that started in mid-air
//   strength  the six give a strength number                          RED: the same job with no strength job
//   credit    on whole cells the check credits the type's lattice     (its RED: the same as strength's)
//             and judges its struts by the type's own law
//   painted   the 3MF paints supports where the part overhangs        RED: the cube (no overhang)
//   refused   a Structural bccz / fccz / reentrant is refused         RED: a Structural octet is not
//   geometry  the laid struts lie at the type's own angles above level, none between level and 30 degrees
//                                                                      RED: the octet read as bcc
//   cap       Auto's largest cell keeps a level strut's bridge within the 5 mm reach
//                                                                      RED: sc's cap read as bcc's (none)
//   coupon    the type's print coupon is made, print-clean, flat on the bed, two-line struts
//                                                                      RED: a coupon with one-line struts
// And the octet is pinned: its bars and its file, on the cube and the plate, are the bytes they were before the types
// came up (hashes taken on claude/organic-1 3c2c2f90).
//
// A check a type is known to fail today is listed in kExpected with its reason: it is reported XFAIL and does not fail
// the suite; one that then passes is reported XPASS and DOES fail it (so the list is kept true).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/face_overrides.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_file_strength.hpp"
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_sample.hpp"
#include "topopt/stepped_plan.hpp"
#include "topopt/stl.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0, g_xfail = 0;
#define CHECK(cond)                                                                        \
  do {                                                                                     \
    ++g_checks;                                                                            \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

namespace {

const std::string kDir = std::string(TMP_DIR) + "/lattice_types_matrix";
const std::string kFixtures = FIXTURES_DIR;

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
unsigned long long fnv(const void* p, std::size_t n, unsigned long long h = 1469598103934665603ULL) {
  const unsigned char* c = static_cast<const unsigned char*>(p);
  for (std::size_t i = 0; i < n; ++i) { h ^= c[i]; h *= 1099511628211ULL; }
  return h;
}
// Every field of every bar, and the stubs (test_lattice_layout's bars_hash).
unsigned long long all_bars_hash(const Bars& bars) {
  unsigned long long h = 1469598103934665603ULL;
  for (const Bar& b : bars.bars) {
    const double v[13] = {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width, b.cell, b.flat.x, b.flat.y, b.flat.z,
                          static_cast<double>(b.into_a), static_cast<double>(b.into_b)};
    h = fnv(v, sizeof v, h);
    const int w[6] = {b.region, static_cast<int>(b.end_a), static_cast<int>(b.end_b), b.piece ? 1 : 0, b.skin ? 1 : 0, 0};
    h = fnv(w, sizeof w, h);
  }
  const unsigned long long s = bars.stubs;
  return fnv(&s, sizeof s, h);
}
unsigned long long cells_hash(const Layout& l) {
  unsigned long long h = 1469598103934665603ULL;
  for (const Cell& c : l.cells) {
    const double v[6] = {c.lo[0], c.lo[1], c.lo[2], c.size, c.strut, static_cast<double>(c.cut)};
    h = fnv(v, sizeof v, h);
  }
  return h;
}

int face_with_normal(const StepModel& m, double nx, double ny, double nz, double* off = nullptr) {
  int best = -1;
  double best_off = -1e300;
  for (int f = 0; f < m.face_count; ++f) {
    const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
    if (fi.kind != StepSurfaceKind::Plane ||
        fi.plane_normal.x * nx + fi.plane_normal.y * ny + fi.plane_normal.z * nz <= 0.99)
      continue;
    const double o = fi.plane_origin.x * nx + fi.plane_origin.y * ny + fi.plane_origin.z * nz;
    if (o > best_off) { best_off = o; best = f; }   // the outermost such face
  }
  if (off) *off = best_off;
  return best;
}

// The face of `m` holding the most area facing (nx, ny, nz) (an STL's faces carry no plane; the plate's top and its
// fillet are one face).
int face_by_triangles(const StepModel& m, double nx, double ny, double nz) {
  std::vector<double> area(static_cast<std::size_t>(m.face_count), 0.0);
  for (std::size_t t = 0; t < m.mesh.triangles.size() && t < m.triangle_face.size(); ++t) {
    const int f = m.triangle_face[t];
    if (f < 0 || f >= m.face_count) continue;
    const Vec3& a = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][0])];
    const Vec3& b = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][1])];
    const Vec3& c = m.mesh.vertices[static_cast<std::size_t>(m.mesh.triangles[t][2])];
    const Vec3 u{b.x - a.x, b.y - a.y, b.z - a.z}, w{c.x - a.x, c.y - a.y, c.z - a.z};
    const Vec3 n{u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x};
    const double l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
    if (!(l > 0.0)) continue;
    if ((n.x * nx + n.y * ny + n.z * nz) / l >= 0.99) area[static_cast<std::size_t>(f)] += 0.5 * l;
  }
  int best = -1;
  for (int f = 0; f < m.face_count; ++f)
    if (area[static_cast<std::size_t>(f)] > 0.0 &&
        (best < 0 || area[static_cast<std::size_t>(f)] > area[static_cast<std::size_t>(best)]))
      best = f;
  return best;
}

// ── THE TYPES ─────────────────────────────────────────────────────────────────
struct Type {
  LatticeTopology t;
  const char* id;
  bool structural;   // strength-checked: offered in Structural
};
const Type kTypes[] = {
    {LatticeTopology::Octet, "octet", true},       {LatticeTopology::Bcc, "bcc", true},
    {LatticeTopology::Kelvin, "kelvin", true},     {LatticeTopology::Diamond, "diamond", true},
    {LatticeTopology::Fcc, "fcc", true},           {LatticeTopology::SimpleCubic, "sc", true},
    {LatticeTopology::Rhombic, "rhombic", true},   {LatticeTopology::Bccz, "bccz", false},
    {LatticeTopology::Fccz, "fccz", false},        {LatticeTopology::Reentrant, "reentrant", false},
};

// ── THE FIXTURES AND THE CASES ────────────────────────────────────────────────
struct Fixture {
  std::string name, path;
  int top = -1, bottom = -1, side = -1;
};
struct Case {
  std::string tag;
  const Fixture* fx = nullptr;
  bool structural = false;
  bool auto_cell = true;     // false: a typed cell
  double cell_mm = 0.0;      // typed
  bool whole = false;        // the whole part (all_lattice), else a region under the top face
  double depth_mm = 6.0;
  bool skin = true;          // Finish Skin; else Finish None
  bool three_mf = false;
  std::string up;            // print_frame up, e.g. "[1, 0, 0]"; empty: none
  std::string algorithm = "default_grade";
  std::string extra;         // more layout keys (", \"grade_to_shape\": true, ...")
};

std::string layout_json(const Type& ty, const Case& c, const std::string& extra = "", int lines = 2) {
  std::string s = "{\"min_strut_lines\": " + std::to_string(lines) + ", \"bead_mm\": 0.45, \"topology\": \"" +
                  std::string(ty.id) + "\", ";
  s += "\"algorithm\": \"" + c.algorithm + "\", \"cell_max_mm\": 8, \"min_cells_across\": 1, ";
  if (c.auto_cell) s += "\"cell_mm\": 0, \"cell_search\": true, \"stretch_edges\": true, ";
  else s += "\"cell_mm\": " + std::to_string(c.cell_mm) + ", ";
  s += std::string("\"skin\": ") + (c.skin ? "true" : "false") + ", ";
  if (c.whole) {
    s += "\"all_lattice\": true";
  } else {
    s += "\"region_ids\": [1], \"region_no_lattice\": [0], \"region_depth_mm\": [" + std::to_string(c.depth_mm) +
         "], \"region_expand_mm\": [0], \"region_face_counts\": [1], \"region_faces\": [" + std::to_string(c.fx->top) + "]";
  }
  return s + c.extra + extra + "}";
}
std::string file_job_json(const Type& ty, const Case& c, const std::string& extra = "") {
  std::string s = "{\"mode\": \"lattice_file\", \"model\": \"" + c.fx->path + "\", \"output\": \"lattice.stl\"";
  if (c.structural) s += ", \"strength_job\": \"strength_job.json\"";
  if (c.three_mf) s += ", \"file_format\": \"3mf\"";
  if (!c.up.empty()) s += ", \"print_frame\": {\"up\": " + c.up + "}";
  return s + ", \"layout\": " + layout_json(ty, c, extra) + "}";
}
// Held on the bottom, loaded on a side, as test_lattice_strength's (resolution 40).
std::string strength_job_json(const Type& ty, const Case& c, double newtons) {
  const std::string topo = ty.structural ? ty.id : "octet";
  return "{\"model\": \"" + c.fx->path + "\", \"material\": \"PLA\", \"mode\": \"lattice_part\", \"resolution\": 40, "
         "\"loads\": {\"minimize_plastic\": true, \"safety_margin\": 1.5, \"build_dir\": [0, 0, 1], "
         "\"anchor_face_ids\": [" + std::to_string(c.fx->bottom) + "], \"groups\": [{\"face_ids\": [" +
         std::to_string(c.fx->side) + "], \"force\": [0, 0, " + std::to_string(-newtons) + "]}]}, "
         "\"lattice\": {\"topology\": \"" + topo + "\", \"require_lattice_void_reaches_exterior\": false}, "
         "\"grading\": {\"topology\": \"" + topo + "\", \"cell_mm\": 8, \"min_extrudable_width_mm\": 0.45, "
         "\"intent\": \"structural\"}, "
         "\"output\": {\"report\": \"report.json\", \"mesh_format\": \"stl\", \"mesh_prefix\": \"variant\"}}";
}

// ── THE CHECKS (each returns "" when it holds, else what it found) ─────────────
std::string check_lays(const Outcome& o) {
  if (o.cancelled) return "cancelled";
  if (o.layout.cells.empty()) return "no cells";
  if (o.bars.bars.empty()) return "no bars";
  return "";
}
// Two lines minimum (R14): every bar of the lattice, the skin's too.
std::string check_two_lines(const Outcome& o, double bead_mm) {
  const double need = 2.0 * bead_mm - 1e-9;
  std::size_t thin = 0;
  double thinnest = 1e300;
  for (const Bar& b : o.bars.bars) {
    thinnest = std::min(thinnest, b.width);
    if (b.width < need) ++thin;
  }
  if (!thin) return "";
  char s[96];
  std::snprintf(s, sizeof s, "%zu bars under two lines (thinnest %.3f mm)", thin, thinnest);
  return s;
}
// Finish Skin closes over the cut cells: of the struts' cut ends (an end the part's surface cut: Surface, or Joined
// into a skin bar), the share still open (Surface, not on the bed). The skin may leave a lone end where no other cut end
// of its plane is in reach; the bar is the octet's own on the same job (kSkinOpenMost).
struct SkinCount { std::size_t cut = 0, open = 0, skin_bars = 0; };
SkinCount skin_count(const Outcome& o) {
  SkinCount n;
  for (const Bar& b : o.bars.bars) {
    if (b.skin) { ++n.skin_bars; continue; }
    for (int e = 0; e < 2; ++e) {
      const Bar::End k = e ? b.end_b : b.end_a;
      const int into = e ? b.into_b : b.into_a;
      const bool bed = (b.on_bed & (e ? Bar::kOnBedB : Bar::kOnBedA)) != 0;
      const bool into_skin = k == Bar::End::Joined && into >= 0 && static_cast<std::size_t>(into) < o.bars.bars.size() &&
                             o.bars.bars[static_cast<std::size_t>(into)].skin;
      if (k == Bar::End::Surface && !bed) { ++n.cut; ++n.open; }
      else if (into_skin) ++n.cut;
    }
  }
  return n;
}
// A type passes when it leaves no more of its cut ends open than a quarter, or than the octet leaves on the same case
// (and five points): "as well as the octet does". The octet is the reference (its own skin rule leaves 44 % open on the
// stepped bracket), and its bytes are pinned below.
constexpr double kSkinOpenMost = 0.25;
std::map<std::string, double> g_octet_skin;   // by case: the octet's open share
double skin_share(const Outcome& o) {
  const SkinCount n = skin_count(o);
  return n.cut ? static_cast<double>(n.open) / static_cast<double>(n.cut) : 0.0;
}
std::string check_skin(const Outcome& o, double allowed = kSkinOpenMost) {
  const SkinCount n = skin_count(o);
  if (n.cut == 0) return "";
  const double share = static_cast<double>(n.open) / static_cast<double>(n.cut);
  if (n.skin_bars > 0 && share <= allowed + 1e-12) return "";
  char s[128];
  std::snprintf(s, sizeof s, "%zu of %zu cut ends open (%.0f%%), %zu skin bars", n.open, n.cut, 100.0 * share, n.skin_bars);
  return s;
}
// No bar ends loose, no piece adrift.
std::string check_loose(const Outcome& o, const Session& session) {
  std::size_t loose = 0;
  for (const Bar& b : o.bars.bars) loose += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
  const Pieces p = count_pieces(o.bars, *session.domain(), nullptr, nullptr, &o.layout);
  if (!loose && !p.adrift) return "";
  char s[128];
  std::snprintf(s, sizeof s, "%zu loose ends, %zu pieces adrift (%zu bars)", loose, p.adrift, p.adrift_bars);
  return s;
}
// Struts meet across a change of cell size (R4) and wherever a cell's shape stops inside the lattice: of the struts'
// ends, before Finish None's drop, those join_loose_bars left loose (it runs a loose end on until it meets a bar, up to
// a cell). A loose end is a strut the drop then takes away: a hole in the lattice where two sizes meet.
struct JoinCount { std::size_t ends = 0, loose = 0; };
JoinCount join_count(const Outcome& o) {
  JoinCount n;
  for (const Bar& b : o.bars.bars) {
    if (b.skin) continue;
    n.ends += 2;
    n.loose += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
  }
  return n;
}
constexpr double kLooseMost = 0.02;
std::string check_joins(const Outcome& kept) {
  const JoinCount n = join_count(kept);
  if (n.ends == 0 || static_cast<double>(n.loose) <= kLooseMost * static_cast<double>(n.ends)) return "";
  char s[128];
  std::snprintf(s, sizeof s, "%zu of %zu strut ends loose before the drop (%.1f%%)", n.loose, n.ends,
                100.0 * static_cast<double>(n.loose) / static_cast<double>(n.ends));
  return s;
}

// THE PRINT GEOMETRY (the reviewer, 2026-11-24): with the cell on its own axes and +Z up, each type's whole struts
// lie at its own angles above level, read off the laid bars, and none lies between level and the 30 degree bridge
// cut-off (a level strut is a bridge, printed flat; at 30 degrees and over a strut is a round bar, self-supporting):
//   octet, fcc, kelvin 0 and 45 (level: face diagonals; kelvin's square windows)    sc 0 and 90 (its edges)
//   bcc, diamond, rhombic 35.26 (<111>)    bccz 35.26 and 90    fccz 0, 45 and 90    reentrant 41.81 and 90
std::set<int> want_angles(LatticeTopology t) {   // tenths of a degree
  switch (t) {
    case LatticeTopology::Octet: case LatticeTopology::Fcc: case LatticeTopology::Kelvin: return {0, 450};
    case LatticeTopology::SimpleCubic: return {0, 900};
    case LatticeTopology::Bcc: case LatticeTopology::Diamond: case LatticeTopology::Rhombic: return {353};
    case LatticeTopology::Bccz: return {353, 900};
    case LatticeTopology::Fccz: return {0, 450, 900};
    case LatticeTopology::Reentrant: return {418, 900};
    default: return {};
  }
}
std::string check_geometry(const Outcome& o, LatticeTopology t) {
  std::set<int> got;
  std::size_t shallow = 0;
  for (const Bar& b : o.bars.bars) {
    if (b.skin || b.piece) continue;
    const double dx = b.b.x - b.a.x, dy = b.b.y - b.a.y, dz = b.b.z - b.a.z;
    const double deg = std::atan2(std::fabs(dz), std::sqrt(dx * dx + dy * dy)) * 180.0 / 3.14159265358979323846;
    got.insert(static_cast<int>(std::lround(deg * 10.0)));
    if (deg > 0.05 && deg < 30.0) ++shallow;
  }
  if (got == want_angles(t) && !shallow) return "";
  std::string s = "angles above level (tenths of a degree):";
  for (int a : got) s += " " + std::to_string(a);
  if (shallow) s += "; " + std::to_string(shallow) + " struts between level and 30 degrees";
  return s;
}
// Auto's largest cell (auto_cell_cap_mm): a level strut's bridge never reaches past the print rule's 5 mm. Laid on the
// coupon's outline (45 x 40 x 35) whole, Auto, Max cell 16 mm: no cell over the type's cap, and the level struts' own
// reach (half their span) within the limit.
std::string check_cap(const Outcome& o, LatticeTopology t) {
  double largest = 0.0, reach = 0.0;
  for (const Cell& c : o.layout.cells) largest = std::max(largest, c.size);
  for (const Bar& b : o.bars.bars)
    if (!b.skin && !b.piece && std::fabs(b.b.z - b.a.z) < 1e-9)
      reach = std::max(reach, 0.5 * (std::hypot(b.b.x - b.a.x, b.b.y - b.a.y) - b.width));
  char s[160];
  if (largest > auto_cell_cap_mm(t) + 1e-9 || reach > kBridgeReachLimitMm + 1e-9) {
    std::snprintf(s, sizeof s, "largest cell %.2f mm (cap %.2f), longest level reach %.2f mm", largest, auto_cell_cap_mm(t),
                  reach);
    return s;
  }
  return "";
}
// The type's print coupon (make_type_coupon): made, print-clean, flat on the bed (the 2 mm plate: 1,464 mm2 of the
// coupon's 45 x 40 underside less its tongue's notch), two-line struts.
std::string check_coupon(const FileResult& r) {
  if (!r.ok) return "not made: " + r.code + ": " + r.why;
  char s[160];
  if (!r.made.print_clean || r.made.midair_starts != 0 || r.made.bed_contact_mm2 < 1000.0 || r.min_strut_mm < 0.9 - 1e-9) {
    std::snprintf(s, sizeof s, "clean %d, mid-air %d, flat on the bed %.0f mm2, thinnest strut %.3f mm",
                  r.made.print_clean ? 1 : 0, r.made.midair_starts, r.made.bed_contact_mm2, r.min_strut_mm);
    return s;
  }
  return "";
}

// The file is made and the print check is clean, its counts sane: nothing starts in mid-air, no overhang is held at
// one end only, no bridge is too long, and the struts left out are a small share of the lattice.
std::string check_print(const FileResult& r) {
  if (!r.ok) return "no file: " + r.code + ": " + r.why;
  char s[192];
  const std::size_t left = r.made.left_out_at.size();
  if (!r.made.print_clean || r.made.midair_starts != 0 || !r.made.layers.mid_air.empty() ||
      !r.made.layers.one_ended.empty() || !r.made.layers.long_bridges.empty() ||
      (r.bars > 0 && left * 10 > r.bars)) {
    std::snprintf(s, sizeof s, "clean %d, mid-air %d/%zu, one-ended %zu, long bridges %zu, left out %zu of %zu bars",
                  r.made.print_clean ? 1 : 0, r.made.midair_starts, r.made.layers.mid_air.size(),
                  r.made.layers.one_ended.size(), r.made.layers.long_bridges.size(), left, r.bars);
    return s;
  }
  return "";
}
// The strength check gives a number: it ran, and its margin is a number: the part's (margin_worst_case) or, where no
// solid part carries the load, the struts' own by the type's law (strut.margin_worst_case).
double strut_margin(const std::string& block) {
  const std::size_t at = block.find("\"strut\": {");
  return at == std::string::npos ? std::numeric_limits<double>::quiet_NaN()
                                 : num_after(block.substr(at), "margin_worst_case");
}
std::string check_strength(const FileResult& r) {
  if (!r.ok) return "no file: " + r.code + ": " + r.why;
  if (!r.strength_ran) return "the strength check did not run";
  if (!std::isfinite(num_after(r.strength_json, "margin_worst_case")) && !std::isfinite(strut_margin(r.strength_json)))
    return "no strength number";
  return "";
}
// The type's lattice can be credited at all: on whole cells (nothing cut), the check credits them and judges the struts
// by the type's own law. A cell whose density is outside the type's measured band gets no credit (V4).
std::string check_credit(const FileResult& r) {
  if (!r.ok) return "no file: " + r.code + ": " + r.why;
  if (!r.strength_ran) return "the strength check did not run";
  const double credited = num_after(r.strength_json, "cells_credited"), none = num_after(r.strength_json, "cells_no_credit");
  char s[160];
  if (!(credited > 0)) {
    std::snprintf(s, sizeof s, "no cell credited (%.0f without credit: their density is outside the type's band)", none);
    return s;
  }
  if (has(r.strength_json, "\"law\": null")) return "credited cells, and no strut law";
  if (!std::isfinite(strut_margin(r.strength_json))) return "credited cells, and no strut margin";
  return "";
}
std::string check_painted(const FileResult& r) {
  if (!r.ok) return "no file: " + r.code + ": " + r.why;
  if (r.file_format != "3mf") return "not a 3MF";
  if (r.part_overhang_places == 0) return "no overhang found";
  if (r.painted.triangles == 0) return "nothing painted";
  const std::string j = file_result_json(r);
  const std::size_t at = j.find("\"painted\": {");
  if (at == std::string::npos || !(num_after(j.substr(at), "triangles") > 0))
    return "the result does not say what was painted";
  return "";
}
std::string check_refused(const FileResult& r) {
  if (r.ok) return "made";
  if (r.code != "type_not_supported") return "refused as " + r.code;
  if (r.why.empty() || has(r.why, "\n")) return "not one plain line";
  if (std::filesystem::exists(r.file)) return "a file was left";
  return "";
}

// ── KNOWN FAILURES TODAY ──────────────────────────────────────────────────────
struct Expected { const char* type; const char* check; const char* reason; };
// The strength-credit checks of bcc, diamond and sc were listed here until builder F (claude/notes28-strut-laws,
// 2026-11-25) landed their laws measured down to the engine's two-line struts (their bands now start at strut/cell
// 0.080 / 0.088 / 0.085, evidence/2026-11-25-strut-laws-low-density): they then passed (XPASS) and came off.
const std::vector<Expected> kExpected = {
    // Step (b), 2026-11-24.
    {"fccz", "coupon",
     "the mesh writer leaves a thin web between a level bridge's square bar and the 12-sided tube of a leg where they "
     "meet a z column (3 mid-air islands at x 21, y 20.4, z 18.5 to 18.9 that the print loop cannot clear); with 16 "
     "sides it prints clean: the writer's union, not the type's geometry"},
    {"reentrant", "print",
     "on the cube's face region its cells are cut by the cube's sides: the waist struts there start in the air just "
     "above the solid floor, the print loop leaves them out and, as each waist hangs from only two struts below it, "
     "the rest go after them (120 of 121 struts left out; print-clean, but no lattice)"},
};
const char* expected(const std::string& type, const std::string& check) {
  for (const Expected& e : kExpected)
    if (type == e.type && check == e.check) return e.reason;
  return nullptr;
}

// One verdict per (type, check): the first case that fails it names it.
struct Verdict { int ran = 0; std::string first; };
std::map<std::string, std::map<std::string, Verdict>> g_matrix;
void record(const std::string& type, const std::string& check, const std::string& tag, const std::string& found) {
  Verdict& v = g_matrix[type][check];
  ++v.ran;
  if (!found.empty() && v.first.empty()) v.first = tag + ": " + found;
  std::printf("  %-10s %-9s %-26s %s\n", type.c_str(), check.c_str(), tag.c_str(), found.empty() ? "ok" : found.c_str());
}

Settings parsed_settings(const std::string& layout) {
  const FileJob j = parse_file_job("{\"mode\": \"lattice_file\", \"model\": \"x.step\", \"layout\": " + layout + "}");
  return j.settings;
}

struct Ran {
  FileResult r;
  std::string folder;
};
Ran run_job(const std::string& tag, const std::string& job, const std::string& sjob, const StrengthCheck& check) {
  Ran x;
  x.folder = kDir + "/" + tag;
  std::filesystem::remove_all(x.folder);
  std::filesystem::create_directories(x.folder);
  write(x.folder + "/job.json", job);
  if (!sjob.empty()) write(x.folder + "/strength_job.json", sjob);
  x.r = run_file_job(x.folder + "/job.json", x.folder, 0, nullptr, &check);
  return x;
}

}  // namespace

int main() {
  std::filesystem::remove_all(kDir);
  std::filesystem::create_directories(kDir);
  const StrengthCheck check = lattice_file_strength_check(MATERIALS_JSON_PATH, SETTINGS_RULES_PATH);

  Fixture cube{"cube", kFixtures + "/step/cube.step"};
  Fixture plate{"plate", kFixtures + "/mesh/filleted_bore_plate.stl"};
  Fixture bracket{"bracket", kFixtures + "/demo/l-bracket.step"};
  std::map<std::string, StepModel> models;
  for (Fixture* f : {&cube, &plate, &bracket}) {
    const StepModel m = import_part_file_resolved(f->path);
    f->top = face_with_normal(m, 0, 0, 1);
    f->bottom = face_with_normal(m, 0, 0, -1);
    f->side = face_with_normal(m, 1, 0, 0);
    if (f->top < 0) f->top = face_by_triangles(m, 0, 0, 1);
    if (f->bottom < 0) f->bottom = face_by_triangles(m, 0, 0, -1);
    std::printf("%s: %d faces, top %d bottom %d side %d\n", f->name.c_str(), m.face_count, f->top, f->bottom, f->side);
    CHECK(f->top >= 0 && f->bottom >= 0);
    models.emplace(f->name, m);
  }
  CHECK(cube.top == 4);   // the fixture's own job names face 4 its top
  // The coupon's outline (lattice_coupon_solid), as the coupon's file job opens it.
  StepModel coupon_model;
  {
    std::filesystem::create_directories(kDir);
    write_stl_file(kDir + "/coupon_part.stl", lattice_coupon_solid(), StlFormat::Binary);
    coupon_model = import_part_file_resolved(kDir + "/coupon_part.stl");
  }
  if (plate.side < 0) plate.side = plate.top;   // a round plate has no flat side: the load goes on its top

  // The bracket's plate top (z = 8) is its region: the outermost +Z face is the wall's top (z = 60).
  {
    const StepModel& m = models.at("bracket");
    for (int f = 0; f < m.face_count; ++f) {
      const StepFaceInfo& fi = m.faces[static_cast<std::size_t>(f)];
      if (fi.kind == StepSurfaceKind::Plane && fi.plane_normal.z > 0.99 && std::fabs(fi.plane_origin.z - 8.0) < 1e-6)
        bracket.top = f;
    }
  }

  // The cases. Structural (a strength job) is laid with one cell across: the app's five across (C5) holds in no
  // fixture of core's (the widest wall is the plate's 6 mm), and the strength job is what makes a job Structural.
  // Two more Aesthetic cases change the cell size inside one region, so the struts must meet across a size step (R4):
  // Grade to shape on the plate's top (cells shrink toward its outline and the bore), and Stepped on the bracket's
  // plate (its two holes).
  std::vector<Case> cases = {
      {"aes-auto-face-cube", &cube, false, true, 0.0, false, 6.0, true, false, ""},
      {"aes-typed-whole-cube", &cube, false, false, 5.0, true, 6.0, true, false, ""},
      {"aes-auto-whole-plate", &plate, false, true, 0.0, true, 6.0, false, false, ""},
      {"aes-typed-face-plate", &plate, false, false, 5.0, false, 6.0, true, false, ""},
      {"aes-auto-3mf-bracket", &bracket, false, true, 0.0, false, 6.0, true, true, "[1, 0, 0]"},
      {"str-auto-face-cube", &cube, true, true, 0.0, false, 6.0, true, false, ""},
      {"str-typed-whole-cube", &cube, true, false, 5.0, true, 6.0, true, false, ""},
  };
  {
    Case g{"aes-grade-face-plate", &plate, false, true, 0.0, false, 6.0, true, false, ""};
    g.extra = ", \"grade_to_shape\": true, \"band_mm\": 8, \"allow_quilt\": true";
    cases.insert(cases.begin() + 5, g);
    Case st{"aes-stepped-face-bracket", &bracket, false, false, 8.0, false, 6.0, true, false, ""};
    st.algorithm = "stepped";
    st.extra = ", \"grade_to_shape\": true, \"band_mm\": 10, \"allow_quilt\": true";
    cases.insert(cases.begin() + 6, st);
  }
  const Case str_face = *std::find_if(cases.begin(), cases.end(), [](const Case& c) { return c.tag == "str-auto-face-cube"; });

  // ── per type: the layout, then the file ─────────────────────────────────────
  std::map<std::string, unsigned long long> octet_pins;
  // MATRIX_ONLY="bcc,kelvin" runs those types alone (while working on one; the suite runs them all).
  const char* only = std::getenv("MATRIX_ONLY");
  for (const Type& ty : kTypes) {
    if (only && !has("," + std::string(only) + ",", "," + std::string(ty.id) + ",")) continue;
    std::printf("\n== %s ==\n", ty.id);
    try {
      const LatticeWidthBounds wb = lattice_width_bounds(ty.t);
      std::printf("  width bounds: open look %.4f, touch %.4f; floor cell at two lines %.2f mm (quilt %.2f mm)\n",
                  wb.open_look, wb.touch, 0.9 / wb.open_look, 0.9 / wb.touch);
      // The type's measured density band against its open look (the widest strut without the quilt, as Structural Auto
      // lays): the strut / cell where its density reaches the band's floor, and the density at the open look.
      if (lattice_topology_certifiable(ty.t)) {
        const double lo = lattice_rho_min(ty.t), hi = lattice_rho_max(ty.t);
        const auto rho = [&](double w) { return lattice_density_from_strut(ty.t, 8.0, 0.5 * w * 8.0); };
        double a = 0.01, b = wb.touch;
        for (int i = 0; i < 60; ++i) (rho(0.5 * (a + b)) < lo ? a : b) = 0.5 * (a + b);
        std::printf("  band %.4f..%.4f; density at the open look %.4f; the band's floor at strut/cell %.4f (%s the open "
                    "look)\n",
                    lo, hi, rho(wb.open_look), 0.5 * (a + b), 0.5 * (a + b) <= wb.open_look ? "within" : "PAST");
      }
    } catch (const std::exception& e) {
      std::printf("  width bounds: none (%s)\n", e.what());
    }
    for (const Case& c : cases) {
      if (c.structural && !ty.structural) continue;
      const std::string tag = std::string(ty.id) + "-" + c.tag;
      // The layout.
      bool laid = false;
      try {
        Session session(models.at(c.fx->name));
        const Settings s = parsed_settings(layout_json(ty, c));
        const Outcome o = session.lay(s);
        laid = true;
        const SkinCount sk = skin_count(o);
        std::printf("  [%s] cells %zu (floor %.2f mm, largest %.2f), bars %zu, cut ends %zu (%zu open), skin bars %zu\n",
                    tag.c_str(), o.layout.cells.size(), o.layout.floor_cell_mm,
                    o.layout.cells.empty() ? 0.0
                                           : std::max_element(o.layout.cells.begin(), o.layout.cells.end(),
                                                              [](const Cell& x, const Cell& y) { return x.size < y.size; })->size,
                    o.bars.bars.size(), sk.cut, sk.open, sk.skin_bars);
        record(ty.id, "lays", c.tag, check_lays(o));
        if (!o.layout.cells.empty()) {
          record(ty.id, "two_lines", c.tag, check_two_lines(o, 0.45));
          // The ends as the skin and the joins left them, before Finish None's drop takes the open ones away.
          const Outcome kept = session.lay(parsed_settings(layout_json(ty, c, ", \"drop_loose\": false")));
          const SkinCount k = skin_count(kept);
          const JoinCount j = join_count(kept);
          std::printf("  [%s] before the drop: cut ends %zu (%zu open), skin bars %zu; strut ends %zu (%zu loose)\n",
                      tag.c_str(), k.cut, k.open, k.skin_bars, j.ends, j.loose);
          if (c.skin) {
            if (ty.t == LatticeTopology::Octet) g_octet_skin[c.tag] = skin_share(kept);
            const auto oct = g_octet_skin.find(c.tag);
            const double allowed = std::max(kSkinOpenMost, oct == g_octet_skin.end() ? 0.0 : oct->second + 0.05);
            record(ty.id, "skin", c.tag, check_skin(kept, allowed));
          }
          record(ty.id, "joins", c.tag, check_joins(kept));
          record(ty.id, "loose", c.tag, check_loose(o, session));
          if (c.tag == "aes-typed-whole-cube") record(ty.id, "geometry", c.tag, check_geometry(o, ty.t));
        }
        if (ty.t == LatticeTopology::Octet && !c.structural && c.fx != &bracket) {
          octet_pins[c.tag + " bars"] = all_bars_hash(o.bars);
          octet_pins[c.tag + " cells"] = cells_hash(o.layout);
        }
      } catch (const std::exception& e) {
        record(ty.id, "lays", c.tag, std::string("threw: ") + e.what());
      }
      // The file.
      const Ran f = run_job(tag, file_job_json(ty, c), c.structural ? strength_job_json(ty, c, 20.0) : "", check);
      std::printf("  [%s] file: ok %d %s %s (cells %zu, bars %zu, left out %zu, builds %d, %.0f ms)\n", tag.c_str(),
                  f.r.ok ? 1 : 0, f.r.code.c_str(), f.r.ok ? "" : f.r.why.c_str(), f.r.cells, f.r.bars,
                  f.r.made.left_out_at.size(), f.r.made.builds, f.r.ms_total);
      if (laid || f.r.ok) record(ty.id, "print", c.tag, check_print(f.r));
      if (c.structural) {
        record(ty.id, "strength", c.tag, check_strength(f.r));
        if (!c.auto_cell && c.whole) record(ty.id, "credit", c.tag, check_credit(f.r));
        if (f.r.ok) std::printf("  [%s] margin %.3f\n", tag.c_str(), num_after(f.r.strength_json, "margin_worst_case"));
      }
      if (c.three_mf) record(ty.id, "painted", c.tag, check_painted(f.r));
      if (ty.t == LatticeTopology::Octet && !c.structural && c.fx != &bracket && f.r.ok)
        octet_pins[c.tag + " file"] = fnv(slurp(f.r.file).data(), slurp(f.r.file).size());
    }
    if (!ty.structural) {   // a Structural job naming it is refused, in one line
      Case c = str_face;
      const Ran f = run_job(std::string(ty.id) + "-str-refused", file_job_json(ty, c), strength_job_json(ty, c, 20.0), check);
      std::printf("  [%s-str-refused] %s: %s\n", ty.id, f.r.code.c_str(), f.r.why.c_str());
      record(ty.id, "refused", "str-auto-face-cube", check_refused(f.r));
    }
    // Auto's cap, on the coupon's outline laid whole (the layout only).
    try {
      Session session(coupon_model);
      const Outcome o = session.lay(parsed_settings(
          "{\"all_lattice\": true, \"min_strut_lines\": 2, \"topology\": \"" + std::string(ty.id) +
          "\", \"algorithm\": \"default_grade\", \"cell_mm\": 0, \"cell_max_mm\": 16, \"min_cells_across\": 1}"));
      record(ty.id, "cap", "auto-whole-coupon16", check_cap(o, ty.t));
    } catch (const std::exception& e) {
      record(ty.id, "cap", "auto-whole-coupon16", std::string("threw: ") + e.what());
    }
    // The print coupon.
    {
      const std::string folder = kDir + "/coupon-" + ty.id;
      std::filesystem::create_directories(folder);
      CouponAsk ask;
      ask.topology = ty.t;
      const FileResult r = make_type_coupon(ask, folder);
      std::printf("  [%s-coupon] %s %s (cells %zu, bars %zu, bed %.0f mm2, builds %d) -> %s\n", ty.id, r.code.c_str(),
                  r.ok ? "" : r.why.c_str(), r.cells, r.bars, r.made.bed_contact_mm2, r.made.builds, r.file.c_str());
      record(ty.id, "coupon", "8mm", check_coupon(r));
    }
  }

  // ── the RED controls: each check fails where it must ─────────────────────────
  std::printf("\n== RED controls ==\n");
  {
    const Type& oct = kTypes[0];
    Session session(models.at("cube"));
    // lays: a region shallower than the smallest cell lays none.
    Case shallow = cases[0];
    shallow.depth_mm = 1.0;
    shallow.auto_cell = false;
    shallow.cell_mm = 5.0;
    const Outcome o_shallow = session.lay(parsed_settings(layout_json(oct, shallow)));
    std::printf("  lays on a 1 mm region: %s\n", check_lays(o_shallow).c_str());
    CHECK(!check_lays(o_shallow).empty());
    // two_lines: laid at one line, the two-line check finds it.
    const Outcome o_one = session.lay(parsed_settings(layout_json(oct, cases[0], ", \"dial\": 0", 1)));
    std::printf("  two_lines at one line: %s\n", check_two_lines(o_one, 0.45).c_str());
    CHECK(!check_two_lines(o_one, 0.45).empty());
    // skin: the same job with Skin off leaves its cut ends open.
    Case bare = cases[0];
    bare.skin = false;
    const Outcome o_bare = session.lay(parsed_settings(layout_json(oct, bare, ", \"drop_loose\": false")));
    std::printf("  skin with Skin off: %s\n", check_skin(o_bare).c_str());
    CHECK(!check_skin(o_bare).empty());
    // loose: join and drop off leave loose ends (the typed whole cube cut by nothing: the face region's cut cells).
    const Outcome o_loose =
        session.lay(parsed_settings(layout_json(oct, bare, ", \"drop_loose\": false, \"join_loose\": false")));
    std::printf("  loose with join and drop off: %s\n", check_loose(o_loose, session).c_str());
    CHECK(!check_loose(o_loose, session).empty());
  }
  {
    FileResult r;
    r.ok = true;
    r.bars = 100;
    r.made.print_clean = false;
    r.made.midair_starts = 2;
    std::printf("  print on a result that starts in mid-air: %s\n", check_print(r).c_str());
    CHECK(!check_print(r).empty());
  }
  {
    const Type& bcc = kTypes[1];
    Case c = str_face;
    c.structural = false;   // no strength job
    const Ran f = run_job("red-strength", file_job_json(bcc, c), "", check);
    std::printf("  strength with no strength job: %s\n", check_strength(f.r).c_str());
    CHECK(f.r.ok && !check_strength(f.r).empty() && !check_credit(f.r).empty());
    Case cube3mf = cases[0];
    cube3mf.three_mf = true;
    const Ran g = run_job("red-painted", file_job_json(kTypes[0], cube3mf), "", check);
    std::printf("  painted on the cube: %s\n", check_painted(g.r).c_str());
    CHECK(g.r.ok && !check_painted(g.r).empty());
    const Ran h = run_job("red-refused", file_job_json(kTypes[0], str_face), strength_job_json(kTypes[0], str_face, 20.0), check);
    std::printf("  refused on a Structural octet: %s\n", check_refused(h.r).c_str());
    CHECK(!check_refused(h.r).empty());
  }

  {
    // geometry: the octet's struts read as bcc's (35.26 only) fail.
    Session session(models.at("cube"));
    const Outcome o = session.lay(parsed_settings(layout_json(kTypes[0], cases[1])));
    std::printf("  geometry of the octet read as bcc: %s\n", check_geometry(o, LatticeTopology::Bcc).c_str());
    CHECK(!check_geometry(o, LatticeTopology::Bcc).empty() && check_geometry(o, LatticeTopology::Octet).empty());
    // cap: sc laid with no cap (as bcc, Max cell 16 on the coupon) breaks the reach (its cap is what holds it).
    Session cs(coupon_model);
    const Outcome big = cs.lay(parsed_settings(
        "{\"all_lattice\": true, \"min_strut_lines\": 2, \"topology\": \"sc\", \"algorithm\": \"default_grade\", "
        "\"cell_mm\": 16, \"min_cells_across\": 1}"));   // typed: laid as typed, past the cap
    std::printf("  cap on sc typed at 16 mm: %s\n", check_cap(big, LatticeTopology::SimpleCubic).c_str());
    CHECK(!check_cap(big, LatticeTopology::SimpleCubic).empty());
    CHECK(auto_cell_cap_mm(LatticeTopology::SimpleCubic) == 10.0 && std::isinf(auto_cell_cap_mm(LatticeTopology::Octet)) &&
          std::isinf(auto_cell_cap_mm(LatticeTopology::Bcc)));
    // coupon: the same coupon at one-line struts (the 0.2 mm nozzle's case) fails the two-line test.
    FileResult one;
    one.ok = true;
    one.made.print_clean = true;
    one.made.midair_starts = 0;
    one.made.bed_contact_mm2 = 1464.0;
    one.min_strut_mm = 0.45;
    std::printf("  coupon at one line: %s\n", check_coupon(one).c_str());
    CHECK(!check_coupon(one).empty());
  }

  // ── the octet, pinned ────────────────────────────────────────────────────────
  std::printf("\n== the octet's bytes ==\n");
  // Taken on claude/organic-1 3c2c2f90, before any type came up. The bars and cells are the engine's own numbers (pinned
  // on every build, as test_lattice_layout pins its bars); the file's bytes also pass through the mesh library's
  // floating point, so they are pinned on the Mac the owner's worker runs on, and printed elsewhere.
  const std::map<std::string, unsigned long long> want = {
      {"aes-auto-face-cube bars", 0x42f01b1238a2936dULL},   {"aes-auto-face-cube cells", 0x73ffd5cd82417e43ULL},
      {"aes-auto-face-cube file", 0x49c0ff53e378304dULL},   {"aes-auto-whole-plate bars", 0x131dd17dc90d3857ULL},
      {"aes-auto-whole-plate cells", 0x0790363c35c968efULL}, {"aes-auto-whole-plate file", 0xd749eeefc8c47ae3ULL},
      {"aes-typed-face-plate bars", 0x5bdf2c55ab6a5217ULL}, {"aes-typed-face-plate cells", 0xf58ae9d5e07bc243ULL},
      {"aes-typed-face-plate file", 0x9071ab450398365fULL}, {"aes-typed-whole-cube bars", 0xaa81ce86b5f9abd7ULL},
      {"aes-typed-whole-cube cells", 0x3dca4e3ec5a17343ULL}, {"aes-typed-whole-cube file", 0xdf8272ddea526aceULL},
      // Step (b): the graded case came in with it, so its pins are taken there; the octet's path through step (b) is
      // the one it had (cell_struts hands it its own struts list; Max cell is not held for it), and the 12 above,
      // taken on 3c2c2f90, still hold.
      {"aes-grade-face-plate bars", 0x5e4368bb32d28806ULL}, {"aes-grade-face-plate cells", 0xdc10f18a3d7d6373ULL},
      {"aes-grade-face-plate file", 0xafd0ede2728f6535ULL},
  };
  std::size_t pinned = 0;
  for (const auto& [k, h] : octet_pins) {
    const auto it = want.find(k);
    std::printf("  {\"%s\", 0x%016llxULL},%s\n", k.c_str(), h,
                it == want.end() ? "  (not pinned)" : it->second == h ? "" : "  CHANGED");
#ifndef __APPLE__
    if (has(k, " file")) continue;
#endif
    CHECK(it != want.end() && it->second == h);
    ++pinned;
  }
  if (!only || has("," + std::string(only) + ",", ",octet,")) CHECK(pinned >= 8);   // every pin was taken

  // ── the matrix ───────────────────────────────────────────────────────────────
  std::printf("\n== the matrix ==\n");
  const char* checks[] = {"lays", "two_lines", "skin", "joins", "loose", "print", "strength", "credit", "painted", "refused", "geometry",
                          "cap", "coupon"};
  for (const Type& ty : kTypes) {
    for (const char* ck : checks) {
      const auto t = g_matrix.find(ty.id);
      if (t == g_matrix.end()) continue;
      const auto v = t->second.find(ck);
      if (v == t->second.end()) continue;
      const char* why = expected(ty.id, ck);
      const bool pass = v->second.first.empty();
      if (pass && why) {
        ++g_fail;
        std::printf("XPASS %-10s %-9s (listed as known: %s): take it off kExpected\n", ty.id, ck, why);
      } else if (!pass && why) {
        ++g_xfail;
        std::printf("XFAIL %-10s %-9s %s  [known: %s]\n", ty.id, ck, v->second.first.c_str(), why);
      } else if (!pass) {
        ++g_fail;
        std::printf("FAIL  %-10s %-9s %s\n", ty.id, ck, v->second.first.c_str());
      } else {
        std::printf("ok    %-10s %-9s (%d cases)\n", ty.id, ck, v->second.ran);
      }
      ++g_checks;
    }
  }
  std::printf("\n%d checks, %d failed, %d known failures\n", g_checks, g_fail, g_xfail);
  return g_fail == 0 ? 0 : 1;
}
