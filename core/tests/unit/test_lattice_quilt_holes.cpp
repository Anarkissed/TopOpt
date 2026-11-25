// notes29 (his iPad notes on release 20, 2026-11-25), on his stand's wing in small: a trapezoid plate seen from the
// front (bottom 120 mm, top 50 mm, 60 mm high, 20 mm thick), latticed under its front face, as his Aesthetic stand is
// ("Start from Solid + Lattice faces", a Rim). His words: "No matter what I did, the quilting kept on happening -- even
// with quilting off. There were even *holes* in the lattice -- which should NEVER happen. And if you look closely at the
// two ends of the wings, the solid outline isn't even, there is a chunk cut out of it on either side."
//   §1 Allow quilt OFF: for every strut type, in every way the cells and struts are asked for (Auto as the app asks it,
//      Uniform at 100 %, Per region, By stress, Stepped and Default Grade with Grade to shape at full strength, cells by
//      stress, a typed strut far past the open look, Small cells in thin walls), no cell is under the type's open cell
//      (lattice_open_cell_mm of the thinnest strut) and no strut or bar is past its open look. RED control: the same
//      asks with Allow quilt ON do go past it.
//   §2 No holes: every cell laid holds some strut of the finished lattice (a cell whose struts were all left out is open
//      space in the file with nothing printed in it: a hole). Kelvin and rhombic grade into cells whose nodes do not meet
//      the next size's; such a patch was a piece adrift, and dropped.
//   §3 An even outline: no cut cell at the part's edge is opened with nothing in it (the chunk at the wing ends).
//   Each of §2 and §3 has its RED control: the checker finds a hole made by hand.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_layout.hpp"

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

// §1: what Allow quilt off must never lay. Counts the cells under the open cell, the cells and bars past the open look.
struct Past { std::size_t small = 0, wide = 0, bars = 0; };
Past past_the_open_look(const Outcome& o) {
  Past p;
  const Layout& l = o.layout;
  const double open_cell = lattice_open_cell_mm(l.topology, l.min_strut_mm);
  for (const Cell& c : l.cells) {
    if (c.size < open_cell * (1.0 - 1e-9)) ++p.small;
    if (c.strut > l.open_look * c.size * (1.0 + 1e-9)) ++p.wide;
  }
  for (const Bar& b : o.bars.bars)
    if (!b.skin && b.cell > 0.0 && b.width > l.open_look * b.cell * (1.0 + 1e-9)) ++p.bars;
  return p;
}

void test_no_type_quilts_without_the_switch() {
  const StepModel model = wing();
  Session session(model);
  const auto field = blobs();
  const char* names[] = {"auto", "uniform 100%", "per region", "by stress", "default grade band", "typed 5 mm",
                         "small cells", "by stress mm"};
  std::size_t asked = 0, control_past = 0;
  for (LatticeTopology t : kTypes) {
    for (int mode = 0; mode < 8; ++mode) {
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
      }
      st.struts.allow_quilt = false;
      const Outcome off = session.lay(st);
      const Past p = past_the_open_look(off);
      ++asked;
      if (p.small || p.wide || p.bars || !off.quilt_regions.empty())
        std::printf("  %s, %s: %zu cells under the open cell, %zu struts and %zu bars past the open look, %zu quilt "
                    "regions\n", lattice_topology_name(t), names[mode], p.small, p.wide, p.bars, off.quilt_regions.size());
      CHECK(p.small == 0 && p.wide == 0 && p.bars == 0 && off.quilt_regions.empty() && !off.layout.cells.empty());
      // RED control: the same ask with Allow quilt on goes past the open look somewhere (a typed 5 mm strut, 100 %, the
      // millimetre ends) -- the check can fail.
      if (mode == 1 || mode == 5 || mode == 7) {
        st.struts.allow_quilt = true;
        const Past q = past_the_open_look(session.lay(st));
        control_past += (q.small + q.wide + q.bars) > 0;
      }
    }
  }
  std::printf("[§1] Allow quilt off: %zu lays (10 strut types x 8 asks), none past its type's limits; the RED control "
              "(Allow quilt on) went past them in %zu of 30\n", asked, control_past);
  CHECK(control_past == 30);
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

}  // namespace

int main() {
  test_no_type_quilts_without_the_switch();
  test_no_holes_in_a_region();
  test_an_even_outline();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
