// notes29 (his iPad notes on release 20, 2026-11-25), on his stand's wing in small: a trapezoid plate seen from the
// front (bottom 120 mm, top 50 mm, 60 mm high, 20 mm thick), latticed under its front face, as his Aesthetic stand is
// ("Start from Solid + Lattice faces", a Rim). His words: "No matter what I did, the quilting kept on happening -- even
// with quilting off. There were even *holes* in the lattice -- which should NEVER happen. And if you look closely at the
// two ends of the wings, the solid outline isn't even, there is a chunk cut out of it on either side."
//   §1 Allow quilt OFF: for every strut type, in every way the cells and struts are asked for (Auto as the app asks it,
//      Uniform at 100 %, Per region, By stress, Stepped and Default Grade with Grade to shape at full strength, cells by
//      stress, a typed strut far past the open look, Small cells in thin walls, the dial past 1), no strut or bar reaches
//      its type's quilt (the touch) and none is past the limit, one printed line short of it
//      (lattice_quilt_off_strut_mm: equally, no cell is under lattice_quilt_off_cell_mm of its own strut). ★ notes29b (his
//      question, 2026-11-25: "Are you saying that no matter what happens, all Small cells in thin walls are going to be
//      quilted?"): the OPEN LOOK is what the lattice lays on its own (every ask at or under it lays nothing past it and no
//      cell under its floor), not the limit: a typed strut, ends in mm and the dial past 1 go past it, up to the limit.
//      RED control: the same asks with Allow quilt ON do reach the limit.
//   §2 No holes: every cell laid holds some strut of the finished lattice (a cell whose struts were all left out is open
//      space in the file with nothing printed in it: a hole). Kelvin and rhombic grade into cells whose nodes do not meet
//      the next size's; such a patch was a piece adrift, and dropped.
//   §3 An even outline: no cut cell at the part's edge is opened with nothing in it (the chunk at the wing ends).
//   Each of §2 and §3 has its RED control: the checker finds a hole made by hand.
//   §4 ★ notes29b, Small cells in thin walls: the wing with its right half 4.2 mm thick (a thin wall: under the open
//      look's 4.74 mm cell at two 0.45 mm lines). Off, that half is solid; on, it is laid with its own small cells, never
//      under the limit's cell and never touching, no hole in it, and every other cell is the one laid without it, byte
//      for byte. RED control: Allow quilt ON (cells as small as the quilt's anywhere) lays small cells off the thin wall.
//   §5 S-1 (notes30): where an end IS joined the pieces are counted again; RED control: the join's count forced there
//      changes the bars.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_layout.hpp"
#include "lattice_outcome_print.hpp"   // S-1 (notes30): a lay as one number

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                            \
  do {                                                                                         \
    ++g_checks;                                                                                \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); }     \
  } while (0)

namespace {

struct ModelBuilder {
  StepModel m;
  int face(Vec3 outward, Vec3 origin) {
    StepFaceInfo f;
    f.kind = StepSurfaceKind::Plane;
    f.plane_normal = outward;
    f.plane_origin = origin;
    m.faces.push_back(f);
    return m.face_count++;
  }
  void tri(int f, Vec3 a, Vec3 b, Vec3 c) {
    const int n = static_cast<int>(m.mesh.vertices.size());
    m.mesh.vertices.insert(m.mesh.vertices.end(), {a, b, c});
    m.mesh.triangles.push_back({n, n + 1, n + 2});
    m.triangle_face.push_back(f);
  }
  void quad(int f, Vec3 a, Vec3 b, Vec3 c, Vec3 d) { tri(f, a, b, c); tri(f, a, c, d); }
};
Vec3 unit(Vec3 v) {
  const double l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return {v.x / l, v.y / l, v.z / l};
}
// The wing: a trapezoid in (x, z), bottom W, top W - 2a, height H, thickness T along y. Face 0 is the front (y = 0),
// face 1 the back (y = T); the two slanted ends are the wing's ends.
constexpr double kW = 120, kA = 35, kH = 60, kT = 20;
StepModel wing() {
  ModelBuilder b;
  const Vec3 f0{0, 0, 0}, f1{kW, 0, 0}, f2{kW - kA, 0, kH}, f3{kA, 0, kH};
  const Vec3 b0{0, kT, 0}, b1{kW, kT, 0}, b2{kW - kA, kT, kH}, b3{kA, kT, kH};
  const int front = b.face({0, -1, 0}, f0);
  b.quad(front, f0, f1, f2, f3);
  const int back = b.face({0, 1, 0}, b0);
  b.quad(back, b0, b3, b2, b1);
  const int bottom = b.face({0, 0, -1}, f0);
  b.quad(bottom, f0, b0, b1, f1);
  const int top = b.face({0, 0, 1}, f3);
  b.quad(top, f3, f2, b2, b3);
  const int right = b.face(unit({kH, 0, kA}), f1);
  b.quad(right, f1, b1, b2, f2);
  const int left = b.face(unit({-kH, 0, kA}), f0);
  b.quad(left, f0, f3, b3, b0);
  b.m.solid_count = 1;
  return b.m;
}
// A made-up stress: two blobs in the wing's halves (as his pictures' dense patches sit), 2 .. 30 MPa.
std::shared_ptr<DemandField> blobs() {
  auto f = std::make_shared<DemandField>();
  f->origin = {-2, -2, -2};
  f->spacing = 1.0;
  f->nx = static_cast<int>(kW) + 4;
  f->ny = static_cast<int>(kT) + 4;
  f->nz = static_cast<int>(kH) + 4;
  f->mpa.assign(static_cast<std::size_t>(f->nx) * f->ny * f->nz, 0.0f);
  for (int k = 0; k < f->nz; ++k)
    for (int j = 0; j < f->ny; ++j)
      for (int i = 0; i < f->nx; ++i) {
        const double x = f->origin.x + i + 0.5, z = f->origin.z + k + 0.5;
        double s = 2.0;
        for (double cx : {0.25 * kW, 0.75 * kW}) s += 28.0 * std::exp(-((x - cx) * (x - cx) + (z - 20) * (z - 20)) / 288.0);
        f->mpa[f->index(i, j, k)] = static_cast<float>(s);
      }
  return f;
}
const LatticeTopology kTypes[] = {LatticeTopology::Octet, LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                                  LatticeTopology::Fcc,   LatticeTopology::Diamond,     LatticeTopology::Kelvin,
                                  LatticeTopology::Rhombic, LatticeTopology::Bccz,      LatticeTopology::Fccz,
                                  LatticeTopology::Reentrant};

// His stand's settings in small: the front face 10 mm deep, Rim, two 0.45 mm lines, Stepped with Grade to shape.
Settings stand(LatticeTopology t) {
  Settings st;
  st.bead_mm = 0.45;
  st.min_strut_lines = 2;
  st.rim_mm = -1;
  st.regions = {{1, Role::Lattice, {0}, 10.0, 0.0}};
  st.cells.topology = t;
  st.cells.algorithm = Algorithm::Stepped;
  st.cells.cell_max_mm = 10;
  st.cells.min_cells_across = 1;
  st.cells.grade_to_shape = true;
  st.cells.band_mm = 6;
  return st;
}

Vec3 to_frame(const Frame& f, const Vec3& p) {
  const Vec3 d{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  return {d.x * f.ax[0].x + d.y * f.ax[0].y + d.z * f.ax[0].z, d.x * f.ax[1].x + d.y * f.ax[1].y + d.z * f.ax[1].z,
          d.x * f.ax[2].x + d.y * f.ax[2].y + d.z * f.ax[2].z};
}
// Does the segment p..q (frame coordinates) pass through the closed cube lo .. lo + s (grown by a hair)?
bool through_cube(const Vec3& p, const Vec3& q, const double lo[3], double s) {
  double t0 = 0, t1 = 1;
  const double P[3] = {p.x, p.y, p.z}, Q[3] = {q.x, q.y, q.z};
  for (int k = 0; k < 3; ++k) {
    const double a = lo[k] - 1e-6, b = lo[k] + s + 1e-6, d = Q[k] - P[k];
    if (std::fabs(d) < 1e-12) {
      if (P[k] < a || P[k] > b) return false;
      continue;
    }
    double u = (a - P[k]) / d, v = (b - P[k]) / d;
    if (u > v) std::swap(u, v);
    t0 = std::max(t0, u);
    t1 = std::min(t1, v);
    if (t0 > t1) return false;
  }
  return true;
}
// The cells of the layout holding no strut of their own: no bar laid for a cell of its size has its middle in the cube
// (a K8 sliver, whose place another cell's struts span, is not read). A neighbour's strut ending on the face is not one.
std::vector<std::size_t> empty_cells(const Layout& l, const Bars& bars) {
  std::vector<std::size_t> out;
  for (std::size_t i = 0; i < l.cells.size(); ++i) {
    const Cell& c = l.cells[i];
    if (c.absorbed) continue;
    const Frame& f = l.frames.at(static_cast<std::size_t>(c.frame));
    bool any = false;
    for (const Bar& b : bars.bars) {
      if (std::fabs(b.cell - c.size) > 1e-9 * c.size) continue;
      const Vec3 m = to_frame(f, Vec3{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)});
      if (through_cube(m, m, c.lo, c.size)) { any = true; break; }
    }
    if (!any) out.push_back(i);
  }
  return out;
}

// §1: against the type's limits. `fused`: struts at or past the touch, the quilt itself; `past`: past the limit of Allow
// quilt off (one printed line short of the touch, lattice_quilt_off_strut_mm) -- `small` the same read on the cell: under
// lattice_quilt_off_cell_mm of its own strut; `open`: struts past the open look, `under`: cells under the open look's
// smallest cell (what the lattice lays on its own).
struct Past { std::size_t fused = 0, past = 0, bars = 0, open = 0, under = 0, small = 0; };
Past against_the_limits(const Outcome& o) {
  Past p;
  const Layout& l = o.layout;
  const double line = l.bead_mm;
  const double open_cell = lattice_open_cell_mm(l.topology, l.min_strut_mm);
  for (const Cell& c : l.cells) {
    if (c.strut >= l.touch * c.size * (1.0 - 1e-9)) ++p.fused;
    if (c.strut > lattice_quilt_off_strut_mm(l.topology, c.size, line) + 1e-9) ++p.past;
    if (c.size < lattice_quilt_off_cell_mm(l.topology, c.strut, line) - 1e-9) ++p.small;
    if (c.strut > l.open_look * c.size * (1.0 + 1e-9)) ++p.open;
    if (c.size < open_cell * (1.0 - 1e-9)) ++p.under;
  }
  for (const Bar& b : o.bars.bars)
    if (!b.skin && b.cell > 0.0 && b.width > lattice_quilt_off_strut_mm(l.topology, b.cell, line) + 1e-9) ++p.bars;
  return p;
}

void test_no_type_quilts_without_the_switch() {
  const StepModel model = wing();
  Session session(model);
  const auto field = blobs();
  const char* names[] = {"auto", "uniform 100%", "per region", "by stress", "default grade band", "typed 5 mm",
                         "small cells", "by stress mm", "dial past 1"};
  std::size_t asked = 0, control_past = 0, went_past_open = 0;
  for (LatticeTopology t : kTypes) {
    for (int mode = 0; mode < 9; ++mode) {
      Settings st = stand(t);
      st.stress.demand = field;
      switch (mode) {
        case 0:   // Auto, as the app asks it (K3: thinnest struts, cells by stress, the cell search and stretch)
          st.struts.width_mm = 0.9;
          st.cells.by_stress = true;
          st.cells.cell_search = true;
          st.cells.stretch_edges = true;
          break;
        case 1: st.struts.dial = 1.0; st.struts.strength = 1.0; break;
        case 2:   // the front 100 %, the back 50 %, each its own region
          st.regions.push_back({2, Role::Lattice, {1}, 6.0, 0.0});
          st.struts.mode = Density::PerRegion;
          st.struts.region_dial = {{1, 1.0}, {2, 0.5}};
          break;
        case 3:
          st.struts.mode = Density::ByStress;
          st.struts.dial_light = 0.01;
          st.struts.dial_heavy = 1.0;
          st.struts.strength = 1.0;
          st.cells.by_stress = true;
          break;
        case 4:
          st.cells.algorithm = Algorithm::DefaultGrade;
          st.struts.dial = 1.0;
          st.struts.strength = 1.0;
          break;
        case 5: st.struts.width_mm = 5.0; break;
        case 6:
          st.small_cells_in_thin_walls = true;
          st.struts.dial = 1.0;
          st.cells.by_stress = true;
          st.struts.mode = Density::ByStress;
          break;
        case 7:
          st.struts.mode = Density::ByStress;
          st.struts.width_light_mm = 0.9;
          st.struts.width_heavy_mm = 6.0;
          st.cells.by_stress = true;
          break;
        case 8:   // ★ notes29b: the app's Density percent past the open look (core's dial past 1), far past the limit
          st.struts.dial = 3.0;
          st.struts.strength = 1.0;
          break;
      }
      st.struts.allow_quilt = false;
      const Outcome off = session.lay(st);
      const Past p = against_the_limits(off);
      ++asked;
      // Asked at or under the open look: the open look and its smallest cell, as the lattice lays them on its own (the
      // wing has no thin wall, so Small cells in thin walls lays nothing smaller). Asked past it: past it, up to the limit.
      const bool asks_past = mode == 5 || mode == 7 || mode == 8;
      if (p.fused || p.past || p.small || p.bars || (!asks_past && (p.open || p.under)) || !off.quilt_regions.empty())
        std::printf("  %s, %s: %zu struts fused, %zu past the limit (%zu bars, %zu cells under its cell); %zu past the "
                    "open look, %zu cells under its floor; %zu quilt regions\n", lattice_topology_name(t), names[mode],
                    p.fused, p.past, p.bars, p.small, p.open, p.under, off.quilt_regions.size());
      CHECK(p.fused == 0 && p.past == 0 && p.small == 0 && p.bars == 0 && off.quilt_regions.empty() &&
            !off.layout.cells.empty());
      if (!asks_past) {
        CHECK(p.open == 0 && p.under == 0);
      } else {
        CHECK(p.under == 0);
        went_past_open += p.open > 0;   // the open look is not the limit: these asks go past it
      }
      // RED control: the same ask with Allow quilt on goes past the limit somewhere (100 %, a typed 5 mm strut, the
      // millimetre ends, the dial past 1) -- the check can fail.
      if (mode == 1 || mode == 5 || mode == 7 || mode == 8) {
        st.struts.allow_quilt = true;
        const Past q = against_the_limits(session.lay(st));
        control_past += (q.past + q.bars) > 0;
      }
    }
  }
  std::printf("[§1] Allow quilt off: %zu lays (10 strut types x 9 asks), none fused, none past one printed line short of "
              "the touch; the asks past the open look went past it (up to that limit) in %zu of 30; the RED control "
              "(Allow quilt on) went past the limit in %zu of 40\n", asked, went_past_open, control_past);
  CHECK(went_past_open == 30);
  CHECK(control_past == 40);
}

void test_no_holes_in_a_region() {
  const StepModel model = wing();
  Session session(model);
  const auto field = blobs();
  std::size_t total = 0;
  for (LatticeTopology t : kTypes) {
    for (int mode = 0; mode < 2; ++mode) {
      Settings st = stand(t);
      st.regions = {{1, Role::Lattice, {0}, 20.0, -3.0}};   // the outline pulled 3 mm in: a solid border all round
      st.cells.cell_max_mm = 12;
      st.cells.min_cells_across = 2;
      st.stress.demand = field;
      st.cells.by_stress = true;
      if (mode == 0) { st.struts.width_mm = 0.9; st.cells.cell_search = true; st.cells.stretch_edges = true; }
      else { st.struts.mode = Density::ByStress; st.struts.dial_heavy = 1.0; }
      const Outcome o = session.lay(st);
      const std::vector<std::size_t> holes = empty_cells(o.layout, o.bars);
      double lo = 1e9, hi = 0;
      for (const Cell& c : o.layout.cells) { lo = std::min(lo, c.size); hi = std::max(hi, c.size); }
      if (!holes.empty())
        std::printf("  %s %s: %zu of %zu cells (%.2f .. %.2f mm) hold no strut (pieces adrift %zu)\n",
                    lattice_topology_name(t), mode ? "by stress" : "auto", holes.size(), o.layout.cells.size(), lo, hi,
                    o.pieces.adrift);
      CHECK(holes.empty());
      total += holes.size();
      if (t == LatticeTopology::Kelvin && mode == 0) {
        CHECK(hi > lo + 1e-9);   // the fixture does grade (the patches of another size are what lost their struts)
        // RED control: a hole made by hand (every bar through one whole cell taken out) is found.
        std::size_t whole = 0;
        while (whole < o.layout.cells.size() && (o.layout.cells[whole].cut || o.layout.cells[whole].absorbed)) ++whole;
        CHECK(whole < o.layout.cells.size());
        if (whole < o.layout.cells.size()) {
          Bars cut = o.bars;
          const Cell& c = o.layout.cells[whole];
          const Frame& f = o.layout.frames.at(static_cast<std::size_t>(c.frame));
          cut.bars.erase(std::remove_if(cut.bars.begin(), cut.bars.end(), [&](const Bar& b) {
                           return through_cube(to_frame(f, b.a), to_frame(f, b.b), c.lo, c.size);
                         }), cut.bars.end());
          const std::vector<std::size_t> made = empty_cells(o.layout, cut);
          CHECK(std::find(made.begin(), made.end(), whole) != made.end());
        }
      }
    }
  }
  std::printf("[§2] no holes: %zu cells laid with nothing in them, over 10 strut types x 2 asks\n", total);
}

void test_an_even_outline() {
  const StepModel model = wing();
  Session session(model);
  const auto field = blobs();
  std::size_t total = 0;
  for (LatticeTopology t : kTypes) {
    Settings st = stand(t);
    st.regions = {{1, Role::Lattice, {0}, 12.0, 0.0}};   // the face's own outline: the wing's slanted ends cut the cells
    st.cells.cell_max_mm = 12;
    st.cells.min_cells_across = 2;
    st.stress.demand = field;
    st.cells.by_stress = true;
    st.struts.width_mm = 0.9;
    st.cells.cell_search = true;
    st.cells.stretch_edges = true;
    const Outcome o = session.lay(st);
    std::size_t cut_empty = 0, cut = 0;
    for (std::size_t i : empty_cells(o.layout, o.bars)) cut_empty += o.layout.cells[i].cut;
    for (const Cell& c : o.layout.cells) cut += c.cut;
    if (cut_empty) std::printf("  %s: %zu of %zu cut cells opened at the edge with no strut in them\n",
                               lattice_topology_name(t), cut_empty, cut);
    CHECK(cut > 0 && cut_empty == 0);
    total += cut_empty;
  }
  std::printf("[§3] an even outline: %zu cut cells opened with nothing in them, over 10 strut types\n", total);
}

// ★ notes29b, §4: the wing with its right half (x > kStep) only kThin thick: under its front face (the region 10 mm deep)
// the left half is a 10 mm wall, the right half a 4.2 mm wall, too thin for the open look's smallest cell (4.74 mm at two
// 0.45 mm lines) and not too thin for any type's limit cell (reentrant's, the largest, 4.05 mm). The back is stepped at
// x = kStep (a face facing +x between the two backs); every edge is shared whole (no T-junction).
constexpr double kThin = 4.2, kStep = 60;
StepModel thin_wing() {
  ModelBuilder b;
  // A flat polygon, fanned from its first point, wound so its normal is `out`.
  const auto poly = [&](int f, std::vector<Vec3> p, Vec3 out) {
    const Vec3 u{p[1].x - p[0].x, p[1].y - p[0].y, p[1].z - p[0].z}, v{p[2].x - p[0].x, p[2].y - p[0].y, p[2].z - p[0].z};
    const Vec3 n{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    if (n.x * out.x + n.y * out.y + n.z * out.z < 0) std::reverse(p.begin() + 1, p.end());
    for (std::size_t i = 1; i + 1 < p.size(); ++i) b.tri(f, p[0], p[i], p[i + 1]);
  };
  const double T = kT, t = kThin, X = kStep, top_l = kA, top_r = kW - kA;
  const Vec3 F{0, -1, 0}, B{0, 1, 0}, D{0, 0, -1}, U{0, 0, 1}, R{1, 0, 0};
  const int front = b.face(F, {0, 0, 0});
  poly(front, {{0, 0, 0}, {X, 0, 0}, {X, 0, kH}, {top_l, 0, kH}}, F);
  poly(front, {{X, 0, 0}, {kW, 0, 0}, {top_r, 0, kH}, {X, 0, kH}}, F);
  const int back = b.face(B, {0, T, 0});
  poly(back, {{0, T, 0}, {X, T, 0}, {X, T, kH}, {top_l, T, kH}}, B);
  const int back_thin = b.face(B, {X, t, 0});
  poly(back_thin, {{X, t, 0}, {kW, t, 0}, {top_r, t, kH}, {X, t, kH}}, B);
  const int step = b.face(R, {X, t, 0});
  poly(step, {{X, t, 0}, {X, T, 0}, {X, T, kH}, {X, t, kH}}, R);
  const int bottom = b.face(D, {0, 0, 0});
  poly(bottom, {{0, 0, 0}, {X, 0, 0}, {X, t, 0}, {X, T, 0}, {0, T, 0}}, D);
  poly(bottom, {{X, 0, 0}, {kW, 0, 0}, {kW, t, 0}, {X, t, 0}}, D);
  const int top = b.face(U, {0, 0, kH});
  poly(top, {{top_l, 0, kH}, {X, 0, kH}, {X, t, kH}, {X, T, kH}, {top_l, T, kH}}, U);
  poly(top, {{X, 0, kH}, {top_r, 0, kH}, {top_r, t, kH}, {X, t, kH}}, U);
  const Vec3 Ln = unit({-kH, 0, kA}), Rn = unit({kH, 0, kA});
  const int left = b.face(Ln, {0, 0, 0});
  poly(left, {{0, 0, 0}, {top_l, 0, kH}, {top_l, T, kH}, {0, T, 0}}, Ln);
  const int right = b.face(Rn, {kW, 0, 0});
  poly(right, {{kW, 0, 0}, {kW, t, 0}, {top_r, t, kH}, {top_r, 0, kH}}, Rn);
  b.m.solid_count = 1;
  return b.m;
}
// The world x of a cell's centre.
double centre_x(const Layout& l, const Cell& c) {
  const Frame& f = l.frames.at(static_cast<std::size_t>(c.frame));
  return f.at(c.lo[0] + 0.5 * c.size, c.lo[1] + 0.5 * c.size, c.lo[2] + 0.5 * c.size).x;
}

void test_small_cells_only_in_thin_walls() {
  const StepModel model = thin_wing();
  Session session(model);
  const auto field = blobs();
  std::size_t types_laid = 0, control_outside = 0;
  for (LatticeTopology t : kTypes) {
    // His stand's Manual in small: Stepped, Grade to shape, cells by stress and By stress up to 100 % (where the band and
    // the stress shrink the cells: where the old switch laid the quilt).
    Settings st = stand(t);
    st.stress.demand = field;
    st.cells.by_stress = true;
    st.struts.mode = Density::ByStress;
    st.struts.dial_light = 0.01;
    st.struts.dial_heavy = 1.0;
    st.struts.allow_quilt = false;
    const Outcome plain = session.lay(st);
    st.small_cells_in_thin_walls = true;
    const Outcome small = session.lay(st);
    const Layout& L = small.layout;
    const double open_cell = lattice_open_cell_mm(t, L.min_strut_mm);
    const double limit_cell = lattice_quilt_off_cell_mm(t, L.min_strut_mm, L.bead_mm);
    std::size_t thin_plain = 0, thin_small = 0, outside = 0, denser = 0;
    double least = 1e9;
    for (const Cell& c : plain.layout.cells) thin_plain += centre_x(plain.layout, c) > kStep;
    for (const Cell& c : L.cells) {
      const bool thin_side = centre_x(L, c) > kStep;
      thin_small += thin_side;
      if (c.size < open_cell * (1.0 - 1e-9)) {
        if (!thin_side) ++outside;
        least = std::min(least, c.size);
      }
      denser += c.strut > L.open_look * c.size * (1.0 + 1e-9);
    }
    // Every cell off the thin wall is the one laid without the switch, byte for byte (position, size, strut).
    std::vector<std::array<double, 5>> a, b;
    for (const Cell& c : plain.layout.cells)
      if (centre_x(plain.layout, c) < kStep) a.push_back({c.lo[0], c.lo[1], c.lo[2], c.size, c.strut});
    for (const Cell& c : L.cells)
      if (centre_x(L, c) < kStep) b.push_back({c.lo[0], c.lo[1], c.lo[2], c.size, c.strut});
    const Past p = against_the_limits(small);
    std::size_t holes = 0;
    for (std::size_t i : empty_cells(L, small.bars)) holes += centre_x(L, L.cells[i]) > kStep;
    std::printf("  %s: thin half %zu cells without the switch, %zu with it (smallest %.2f mm; open look's %.2f, the "
                "limit's %.2f); %zu cells denser than the open look, %zu fused, %zu past the limit; %zu small cells off "
                "the thin wall; %zu holes in it; the rest the same: %s\n", lattice_topology_name(t), thin_plain,
                thin_small, least < 1e9 ? least : 0.0, open_cell, limit_cell, denser, p.fused, p.past, outside, holes,
                a == b ? "yes" : "NO");
    CHECK(thin_plain == 0);                       // without it the thin wall is solid
    CHECK(thin_small > 0 && least >= limit_cell * (1.0 - 1e-9) && least < open_cell);   // with it, its small cells
    CHECK(outside == 0);                          // ONLY in the thin wall
    CHECK(p.fused == 0 && p.past == 0 && p.small == 0 && p.bars == 0);   // never fused, never past the limit
    CHECK(holes == 0);
    CHECK(a == b && !a.empty());
    types_laid += thin_small > 0;
    // RED control: Allow quilt on (the cells may go to the quilt's anywhere) lays small cells off the thin wall too, where
    // the band and the stress shrink them -- what the switch did with Allow quilt off until notes29.
    st.struts.allow_quilt = true;
    const Outcome on = session.lay(st);
    std::size_t on_outside = 0;
    for (const Cell& c : on.layout.cells)
      on_outside += c.size < open_cell * (1.0 - 1e-9) && centre_x(on.layout, c) < kStep;
    control_outside += on_outside > 0;
  }
  std::printf("[§4] Small cells in thin walls: the thin wall latticed for %zu of 10 types, small cells only there, none "
              "fused; RED control (Allow quilt on) laid small cells off the thin wall for %zu of 10\n", types_laid,
              control_outside);
  CHECK(types_laid == 10 && control_outside == 10);
}

// §5 S-1 (notes30, the maintainer's yes 2026-11-26: "count pieces once"). The adrift drop takes the cut-off join's own
// count of the pieces only when the join changed no bar. On §2's Kelvin wing an end IS joined (its patches of another
// size run on into the lattice beside them), so the drop counts again: the session's counted_once does not move, and
// the lay is the lay that always counts twice, byte for byte, on 1, 3 and every thread. Step by step on the session's
// own domain (the lay without the drop, then drop_loose_bars, the join, the drop): join_cut_off_pieces hands over no
// count, and the drop's bars and pieces are the session's. RED control: the count forced on the drop there (the one
// taken before the join, of the bars as they were) changes the bars: the patches the join held would go again, the
// holes of notes29.
void test_a_joined_end_counts_again() {
  using lattice_outcome_print::bars_print;
  using lattice_outcome_print::outcome_print;
  using lattice_outcome_print::pieces_print;
  const StepModel model = wing();
  Settings st = stand(LatticeTopology::Kelvin);
  st.regions = {{1, Role::Lattice, {0}, 20.0, -3.0}};   // as §2, auto
  st.cells.cell_max_mm = 12;
  st.cells.min_cells_across = 2;
  st.stress.demand = blobs();
  st.cells.by_stress = true;
  st.struts.width_mm = 0.9;
  st.cells.cell_search = true;
  st.cells.stretch_edges = true;
  Session on(model), off(model);
  off.count_pieces_once(false);
  for (int threads : {1, 3, 0}) {
    const std::size_t before = on.counted_once();
    const Outcome a = on.lay(st, threads), b = off.lay(st, threads);
    std::printf("[§5] %d thread(s): %zu ends joined, %zu bars; counted once %zu time(s); the same as counted twice: %s\n",
                threads, a.cut_off_joined, a.bars.bars.size(), on.counted_once() - before,
                outcome_print(a) == outcome_print(b) ? "yes" : "NO");
    CHECK(a.cut_off_joined > 0);                    // the case: an end is joined
    CHECK(on.counted_once() == before);             // so the pieces were counted again
    CHECK(outcome_print(a) == outcome_print(b));    // and the lay is the one that always counts twice
  }
  // Step by step on the session's domain.
  Session s(model);
  Settings no_drop = st;
  no_drop.drop_loose = false;   // the bars as they stand before the drop (nothing before it reads drop_loose)
  const Outcome pre = s.lay(no_drop);
  const Outcome full = s.lay(st);   // the same "where": the same domain
  const Domain& d = *s.domain();
  Bars bars = pre.bars;
  drop_loose_bars(bars);
  std::vector<char> was_adrift;
  const Pieces was = count_pieces(bars, d, &was_adrift, nullptr, &pre.layout);
  const PiecesCount stale{was, was_adrift};   // of the bars as they were before the join
  std::optional<PiecesCount> unchanged = PiecesCount{};   // set, so the join must reset it
  const std::size_t joined = join_cut_off_pieces(bars, d, 0, &pre.layout, &unchanged);
  CHECK(joined > 0 && joined == full.cut_off_joined);
  CHECK(!unchanged.has_value());   // the bars changed: no count handed over
  Bars counted = bars, forced = bars;
  const Pieces again = drop_adrift_bars(counted, d, &pre.layout, unchanged ? &*unchanged : nullptr);
  CHECK(bars_print(counted) == bars_print(full.bars));
  CHECK(pieces_print(again) == pieces_print(full.pieces));
  // RED control: the join's count forced on the drop.
  const Pieces stale_found = drop_adrift_bars(forced, d, &pre.layout, &stale);
  std::printf("[§5] step by step: %zu pieces adrift before the join (%zu bars), %zu ends joined, %zu adrift after; the "
              "count forced: %zu bars kept, counted again: %zu (the session's %zu)\n",
              was.adrift, was.adrift_bars, joined, again.adrift, forced.bars.size(), counted.bars.size(),
              full.bars.bars.size());
  CHECK(was.adrift > 0);
  CHECK(bars_print(forced) != bars_print(full.bars) && forced.bars.size() < full.bars.bars.size());
  CHECK(pieces_print(stale_found) != pieces_print(full.pieces));
  // And where the join joined nothing, the count it hands over is the one the drop would make: the finished bars of the
  // wing again (nothing adrift is left in them: the join returns at once), and the same bars with a piece adrift that no
  // end can join (one strut 40 mm behind the wing, out of the part: its ends run on into nothing; the join reads every
  // end and joins none).
  for (int k = 0; k < 2; ++k) {
    Bars x = full.bars;
    if (k == 1) x.bars.push_back(Bar{Vec3{60, 60, 30}, Vec3{60.5, 60, 30.5}, 0.9, 6.0, 1});
    Bars y = x;
    std::optional<PiecesCount> kept;
    const std::size_t j = join_cut_off_pieces(x, d, 0, &full.layout, &kept);
    CHECK(j == 0 && kept.has_value());
    CHECK(bars_print(x) == bars_print(y));   // the join changed nothing
    Bars by_kept = x, by_count = y;
    const Pieces pk = drop_adrift_bars(by_kept, d, &full.layout, kept ? &*kept : nullptr);
    const Pieces pc = drop_adrift_bars(by_count, d, &full.layout);
    CHECK(bars_print(by_kept) == bars_print(by_count) && pieces_print(pk) == pieces_print(pc));
    CHECK(k == 0 ? pc.adrift == 0 : (pc.adrift == 1 && by_count.bars.size() == full.bars.bars.size()));
  }
}

}  // namespace

int main() {
  test_no_type_quilts_without_the_switch();
  test_no_holes_in_a_region();
  test_an_even_outline();
  test_small_cells_only_in_thin_walls();
  test_a_joined_end_counts_again();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
