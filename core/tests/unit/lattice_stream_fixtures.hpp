// notes30 (the strut stream): fixtures built in code (never a file of his) and a digest of everything a lay makes, for
// test_lattice_layout_stream (T1-T7) and the timing harness. The stand-like block and the pebble are the scope's
// (agent-scratch/organic1/notes30/strut-stream/harness): grid_model is test_lattice_layout.cpp's.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"

namespace stream_fixtures {
using namespace topopt;
using namespace topopt::lattice_layout;

struct GridModel {
  StepModel model;
  std::map<std::array<long long, 3>, int> id;
  int face(int axis, int sign, double at) const {
    const auto it = id.find({axis, sign, std::llround(at * 1e6)});
    return it == id.end() ? -1 : it->second;
  }
};
// A solid made of the filled boxes of a grid (xs, ys, zs its lines); each side of the solid on one plane is one face.
inline GridModel grid_model(const std::vector<double>& xs, const std::vector<double>& ys, const std::vector<double>& zs,
                            const std::function<bool(int, int, int)>& filled) {
  GridModel g;
  StepModel& m = g.model;
  const int n[3] = {static_cast<int>(xs.size()) - 1, static_cast<int>(ys.size()) - 1, static_cast<int>(zs.size()) - 1};
  const std::vector<double>* c[3] = {&xs, &ys, &zs};
  auto full = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < n[0] && j < n[1] && k < n[2] && filled(i, j, k);
  };
  for (int i = 0; i < n[0]; ++i)
    for (int j = 0; j < n[1]; ++j)
      for (int k = 0; k < n[2]; ++k) {
        if (!full(i, j, k)) continue;
        const int ijk[3] = {i, j, k};
        for (int axis = 0; axis < 3; ++axis)
          for (int sign = -1; sign <= 1; sign += 2) {
            int o[3] = {i, j, k};
            o[axis] += sign;
            if (full(o[0], o[1], o[2])) continue;
            const double at = (*c[axis])[static_cast<std::size_t>(ijk[axis] + (sign > 0 ? 1 : 0))];
            const std::array<long long, 3> key{axis, sign, std::llround(at * 1e6)};
            auto it = g.id.find(key);
            if (it == g.id.end()) {
              it = g.id.emplace(key, m.face_count++).first;
              StepFaceInfo info;
              info.kind = StepSurfaceKind::Plane;
              info.plane_normal = {axis == 0 ? double(sign) : 0.0, axis == 1 ? double(sign) : 0.0,
                                   axis == 2 ? double(sign) : 0.0};
              info.plane_origin = {axis == 0 ? at : 0.0, axis == 1 ? at : 0.0, axis == 2 ? at : 0.0};
              m.faces.push_back(info);
            }
            const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
            Vec3 q[4];
            for (int v = 0; v < 4; ++v) {
              double xyz[3];
              xyz[axis] = at;
              xyz[a1] = (*c[a1])[static_cast<std::size_t>(ijk[a1] + ((v == 1 || v == 2) ? 1 : 0))];
              xyz[a2] = (*c[a2])[static_cast<std::size_t>(ijk[a2] + ((v >= 2) ? 1 : 0))];
              q[v] = {xyz[0], xyz[1], xyz[2]};
            }
            if (sign < 0) std::swap(q[1], q[3]);
            for (int t = 0; t < 2; ++t) {
              const int b = static_cast<int>(m.mesh.vertices.size());
              m.mesh.vertices.insert(m.mesh.vertices.end(), {q[0], q[t ? 2 : 1], q[t ? 3 : 2]});
              m.mesh.triangles.push_back({b, b + 1, b + 2});
              m.triangle_face.push_back(it->second);
            }
          }
      }
  m.solid_count = 1;
  return g;
}

// Grid lines from 0 to `len` every `step`, plus the given breaks (sorted, unique).
inline std::vector<double> lines(double len, double step, std::vector<double> breaks) {
  std::vector<double> v;
  for (double x = 0; x < len - 1e-9; x += step) v.push_back(x);
  v.push_back(len);
  v.insert(v.end(), breaks.begin(), breaks.end());
  std::sort(v.begin(), v.end());
  v.erase(std::unique(v.begin(), v.end(), [](double a, double b) { return std::fabs(a - b) < 1e-6; }), v.end());
  return v;
}

// A stand-like block 160 s x 100 s x 40 mm: two pockets from below (a 10 mm and a 4 mm web over them), a through slot,
// a step down at one end; triangulated on a `tri` mm grid. Its top face: face(2, 1, 40).
inline GridModel stand_block(double s, double tri = 2.5) {
  const std::vector<double> xs = lines(160 * s, tri, {20 * s, 70 * s, 90 * s, 140 * s, 145 * s, 150 * s});
  const std::vector<double> ys = lines(100 * s, tri, {15 * s, 45 * s, 55 * s, 85 * s});
  const std::vector<double> zs = lines(40, tri, {6, 30, 36});
  auto in = [](double lo, double hi, double v) { return v > lo && v < hi; };
  return grid_model(xs, ys, zs, [&](int i, int j, int k) {
    const double x = 0.5 * (xs[i] + xs[i + 1]), y = 0.5 * (ys[j] + ys[j + 1]), z = 0.5 * (zs[k] + zs[k + 1]);
    if (in(20 * s, 70 * s, x) && in(15 * s, 85 * s, y) && z < 30) return false;
    if (in(90 * s, 140 * s, x) && in(15 * s, 85 * s, y) && z < 36) return false;
    if (in(145 * s, 150 * s, x) && in(45 * s, 55 * s, y)) return false;
    if (x > 150 * s && z > 20) return false;
    return true;
  });
}

// A rounded slab (superellipsoid |x/a|^(2/e) + |y/b|^(2/e) + |z/c|^(2/e) = 1) on a cube-sphere grid of n x n per side:
// closed, curved at its edges, 12 n^2 triangles. Face ids: 0 -x, 1 +x, 2 -y, 3 +y, 4 -z, 5 +z (none is a plane: a
// region on one is a shell, D20).
inline StepModel pebble(double a, double b, double c, double e, int n) {
  StepModel m;
  m.face_count = 6;
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Other;
    m.faces.push_back(info);
  }
  auto surf = [&](double x, double y, double z) {
    const double l = std::sqrt(x * x + y * y + z * z);
    const double dx = x / l, dy = y / l, dz = z / l, p = 2.0 / e;
    const double s = std::pow(std::fabs(dx / a), p) + std::pow(std::fabs(dy / b), p) + std::pow(std::fabs(dz / c), p);
    const double t = std::pow(s, -1.0 / p);
    return Vec3{t * dx, t * dy, t * dz};
  };
  for (int f = 0; f < 6; ++f) {
    const int axis = f / 2;
    const double sign = (f % 2) ? 1.0 : -1.0;
    const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
    auto at = [&](int i, int j) {
      double q[3];
      q[axis] = sign;
      q[a1] = -1.0 + 2.0 * i / n;
      q[a2] = -1.0 + 2.0 * j / n;
      return surf(q[0], q[1], q[2]);
    };
    for (int i = 0; i < n; ++i)
      for (int j = 0; j < n; ++j) {
        const Vec3 p00 = at(i, j), p10 = at(i + 1, j), p11 = at(i + 1, j + 1), p01 = at(i, j + 1);
        for (int t = 0; t < 2; ++t) {
          Vec3 A = p00, B = t ? p11 : p10, C = t ? p01 : p11;
          const Vec3 u{B.x - A.x, B.y - A.y, B.z - A.z}, v{C.x - A.x, C.y - A.y, C.z - A.z};
          const Vec3 nrm{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
          if (nrm.x * A.x + nrm.y * A.y + nrm.z * A.z < 0) std::swap(B, C);
          const int base = static_cast<int>(m.mesh.vertices.size());
          m.mesh.vertices.insert(m.mesh.vertices.end(), {A, B, C});
          m.mesh.triangles.push_back({base, base + 1, base + 2});
          m.triangle_face.push_back(f);
        }
      }
  }
  m.solid_count = 1;
  return m;
}

// ── a digest of everything a lay makes (the timings left out) ──
struct Digest {
  std::uint64_t h = 1469598103934665603ull;
  void bytes(const void* p, std::size_t n) {
    const auto* c = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) h = (h ^ c[i]) * 1099511628211ull;
  }
  void d(double v) { bytes(&v, sizeof v); }
  void f(float v) { bytes(&v, sizeof v); }
  void i(long long v) { bytes(&v, sizeof v); }
  void v3(const Vec3& p) { d(p.x); d(p.y); d(p.z); }
  void s(const std::string& t) { i(static_cast<long long>(t.size())); bytes(t.data(), t.size()); }
};
inline void digest_cell(Digest& g, const Cell& c) {
  g.i(c.region); g.i(c.frame);
  for (double v : c.lo) g.d(v);
  g.d(c.size); g.i(c.cut); g.i(c.wall); g.d(c.strut); g.d(c.own); g.d(c.band); g.i(c.finest);
  for (double v : c.reach_lo) g.d(v);
  for (double v : c.reach_hi) g.d(v);
  g.i(c.absorbed);
}
inline void digest_bar(Digest& g, const Bar& b) {
  g.v3(b.a); g.v3(b.b); g.d(b.width); g.d(b.cell); g.i(b.region);
  g.i(static_cast<int>(b.end_a)); g.i(static_cast<int>(b.end_b));
  g.i(b.piece); g.i(b.skin); g.i(b.net); g.v3(b.flat); g.i(b.into_a); g.i(b.into_b); g.i(b.strand);
  g.i(b.support); g.i(b.level_tie); g.i(b.link); g.i(b.brace); g.i(b.relief); g.d(b.gap_cap_mm); g.d(b.local_mm);
  g.i(b.local_why); g.d(b.proud_a); g.d(b.proud_b); g.d(b.relief_a); g.d(b.relief_b); g.d(b.along_proud);
  g.i(b.along_face); g.i(b.face_skin); g.i(b.stem); g.i(b.strengthened); g.i(b.on_bed);
}
// The layout only (its cells, solid, frames, walls, tallies, the K7 / K8 reports).
inline std::uint64_t digest_layout(const Layout& L) {
  Digest g;
  g.i(L.absorb); g.d(L.floor_cell_mm); g.d(L.thin_floor_cell_mm); g.d(L.bead_mm); g.d(L.min_strut_mm);
  g.d(L.open_look); g.d(L.touch); g.i(static_cast<int>(L.topology));
  for (const Frame& f : L.frames) { g.v3(f.origin); for (const Vec3& a : f.ax) g.v3(a); }
  for (const WallMap& w : L.walls) {
    g.i(w.flat); g.d(w.depth); g.d(w.u0); g.d(w.w0); g.i(w.nu); g.i(w.nw);
    for (long v : w.bin) g.i(v);
    for (long v : w.sbin) g.i(v);
    for (int v : w.wall) g.i(v);
    for (const WallMap::Wall& x : w.walls) {
      g.d(x.start); g.d(x.width); g.d(x.cell); g.i(x.layers); g.d(x.lo[0]); g.d(x.lo[1]); g.d(x.hi[0]); g.d(x.hi[1]);
      g.i(x.thin);
    }
  }
  g.i(static_cast<long long>(L.cells.size()));
  for (const Cell& c : L.cells) digest_cell(g, c);
  g.i(static_cast<long long>(L.solid.size()));
  for (const Cell& c : L.solid) digest_cell(g, c);
  for (const SolidWhy& w : L.solid_why) { g.i(static_cast<int>(w.why)); g.f(w.have_mm); g.f(w.need_mm); }
  for (std::uint32_t t : L.thin_solid) g.i(t);
  g.i(static_cast<long long>(L.small_patch_cells));
  for (const Layout::CellSearch& c : L.cell_search) {
    g.i(c.region);
    for (const auto& t : c.tried) {
      g.d(t.base_mm); g.d(t.finest_mm); g.d(t.sliver_mm2); g.d(t.thinnest); g.d(t.bed_mm2);
      g.i(static_cast<long long>(t.slivers)); g.i(static_cast<long long>(t.at_bed)); g.i(t.grades);
    }
    g.d(c.chosen_mm); g.s(c.why); g.i(c.not_searched); g.d(c.square_mm2);
    g.i(static_cast<long long>(c.stretched)); g.i(static_cast<long long>(c.taken_in));
    g.i(static_cast<long long>(c.slivers_left));
  }
  for (const RegionCells& r : L.regions) {
    g.i(r.region); g.i(r.frame); g.d(r.base_cell_mm); g.i(static_cast<long long>(r.cells));
    g.i(static_cast<long long>(r.solid));
  }
  for (const Layout::Weave& w : L.weave) { g.i(w.region); g.i(w.frame); g.d(w.spacing_mm); }
  g.i(L.index != nullptr);
  return g.h;
}
// Everything an Outcome holds that a lay makes (not its timings, not the stream's own counts, not the map).
inline std::uint64_t digest_outcome(const Outcome& o) {
  Digest g;
  g.i(static_cast<long long>(digest_layout(o.layout)));
  g.i(static_cast<long long>(o.struts.at_bead)); g.i(static_cast<long long>(o.struts.at_ceiling));
  g.i(o.struts.no_stress); g.d(o.struts.reference_mpa); g.d(o.struts.highest_mpa);
  g.i(static_cast<long long>(o.struts.at_light)); g.i(static_cast<long long>(o.struts.at_heavy));
  g.i(static_cast<long long>(o.bars.bars.size()));
  for (const Bar& b : o.bars.bars) digest_bar(g, b);
  g.i(static_cast<long long>(o.bars.stubs)); g.i(static_cast<long long>(o.bars.dropped));
  g.i(static_cast<long long>(o.bars.joined)); g.i(static_cast<long long>(o.bars.repeats));
  for (const Bars::CutEnd& c : o.bars.cut_in_air) { g.v3(c.at); g.i(c.region); g.d(c.cell); }
  g.i(static_cast<long long>(o.pieces.pieces)); g.i(static_cast<long long>(o.pieces.adrift));
  g.i(static_cast<long long>(o.pieces.adrift_bars)); g.d(o.pieces.adrift_mm); g.d(o.pieces.largest_adrift_mm);
  for (const SteppedEdge& e : o.stepped_edges) { g.i(e.region); g.v3(e.at); g.v3(e.lo); g.v3(e.hi); g.i(static_cast<long long>(e.ends)); }
  g.i(o.read_again); g.i(o.cancelled);
  for (int r : o.empty_regions) g.i(r);
  g.i(static_cast<long long>(o.thin_solid)); g.i(static_cast<long long>(o.cut_off_joined));
  g.i(static_cast<long long>(o.empty_solid));
  for (int r : o.quilt_regions) g.i(r);
  g.i(o.cells_by_stress); g.i(o.cells_no_stress); g.d(o.stress_reference_mpa); g.d(o.step_held_at);
  return g.h;
}

// ── the cases (T1, T2): a fixture, the settings, a name ──
struct Case {
  std::string name;
  const StepModel* model = nullptr;
  Settings settings;
};
inline Settings base_settings(LatticeTopology t, double cell_mm) {
  Settings st;
  st.bead_mm = 0.45;
  st.min_strut_lines = kMinStrutLines;
  st.cells.algorithm = Algorithm::DefaultGrade;
  st.cells.topology = t;
  st.cells.cell_max_mm = cell_mm;
  st.cells.min_cells_across = 2;
  st.struts.dial = 0.45;
  return st;
}
inline const std::vector<LatticeTopology>& strut_types() {
  static const std::vector<LatticeTopology> types = [] {
    std::vector<LatticeTopology> t;
    for (LatticeTopology x : {LatticeTopology::Octet, LatticeTopology::SimpleCubic, LatticeTopology::Bcc,
                              LatticeTopology::Fcc, LatticeTopology::Diamond, LatticeTopology::Kelvin,
                              LatticeTopology::Rhombic, LatticeTopology::Bccz, LatticeTopology::Fccz,
                              LatticeTopology::Reentrant})
      if (lattice_has_strut_cell(x)) t.push_back(x);
    return t;
  }();
  return types;
}

}  // namespace stream_fixtures

namespace stream_fixtures {
// A stress field over a box: a ramp along x (MPa), so cells by stress and struts by stress grade across the part.
inline std::shared_ptr<const DemandField> ramp_field(const Vec3& lo, const Vec3& hi, double spacing) {
  auto f = std::make_shared<DemandField>();
  f->origin = {lo.x - spacing, lo.y - spacing, lo.z - spacing};
  f->spacing = spacing;
  f->nx = static_cast<int>(std::ceil((hi.x - lo.x) / spacing)) + 3;
  f->ny = static_cast<int>(std::ceil((hi.y - lo.y) / spacing)) + 3;
  f->nz = static_cast<int>(std::ceil((hi.z - lo.z) / spacing)) + 3;
  f->mpa.resize(static_cast<std::size_t>(f->nx) * f->ny * f->nz);
  for (int k = 0; k < f->nz; ++k)
    for (int j = 0; j < f->ny; ++j)
      for (int i = 0; i < f->nx; ++i)
        f->mpa[f->index(i, j, k)] = static_cast<float>(1.0 + 40.0 * i / std::max(1, f->nx - 1));
  return f;
}
// The fixtures the identity and finality cases lay (built once).
struct Fixtures {
  GridModel stand = stand_block(0.5, 2.5);     // 80 x 50 x 40
  StepModel peb = pebble(30.0, 20.0, 12.0, 0.25, 24);   // 60 x 40 x 24, curved
  int top = stand.face(2, 1, 40.0);
  int side = stand.face(0, -1, 0.0);
};
inline void with_stress(Settings& s, const StepModel& m);
// The identity cases (T1): every path the cube lay takes, all nine strut types, on small fixtures.
inline std::vector<Case> identity_cases(const Fixtures& fx) {
  std::vector<Case> out;
  const auto add = [&](const std::string& n, const StepModel& m, const Settings& s) { out.push_back({n, &m, s}); };
  for (LatticeTopology t : strut_types()) {
    const std::string tn = lattice_topology_name(t);
    Settings s = base_settings(t, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    add(tn + " top face region (walls)", fx.stand.model, s);
    Settings w = base_settings(t, 6.0);
    w.start = Start::AllLattice;
    add(tn + " whole stand", fx.stand.model, w);
    Settings p = base_settings(t, 5.0);
    p.start = Start::AllLattice;
    add(tn + " whole pebble", fx.peb, p);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    s.one_grid = true;
    add("octet one grid region", fx.stand.model, s);
    s.cells.cell_search = true;
    s.cells.stretch_edges = true;
    add("octet one grid, search + stretch (K7, K8)", fx.stand.model, s);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 4.0);
    s.start = Start::AllLattice;
    s.cells.min_cells_across = 3;   // K5, Structural
    add("octet structural k=3 (K5)", fx.stand.model, s);
    s.cells.min_cells_across = 5;
    add("octet structural k=5 (K5)", fx.stand.model, s);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    s.cells.max_step = 2.0;   // C24
    s.cells.algorithm = Algorithm::Stepped;
    add("octet stepped, size step (C24)", fx.stand.model, s);
    s.cells.algorithm = Algorithm::Uniform;
    s.cells.max_step = 0.0;
    add("octet uniform", fx.stand.model, s);
  }
  for (int finish = 0; finish < 3; ++finish) {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    if (finish == 0) s.skin = true;
    if (finish == 1) s.rim_mm = -1.0;
    if (finish == 2) s.cover_mm = -1.0;
    add(std::string("octet finish ") + (finish == 0 ? "skin" : finish == 1 ? "rim" : "covered"), fx.stand.model, s);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}, {2, Role::Lattice, {fx.side}, 12.0, 0.0}};
    add("octet two regions (absorb seams)", fx.stand.model, s);
    s.start = Start::AllLattice;
    add("octet two regions + whole part", fx.stand.model, s);
  }
  {
    Settings s = base_settings(LatticeTopology::Kelvin, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    s.cells.grade_to_shape = true;
    s.cells.band_mm = 8.0;
    add("kelvin grade to shape", fx.stand.model, s);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 4.0);
    s.regions = {{1, Role::Lattice, {5}, 12.0, 0.0}};   // the pebble's top: a shell (D20)
    add("octet pebble top shell", fx.peb, s);
    Settings z = base_settings(LatticeTopology::Octet, 6.0);
    Settings::RegionAsk r;
    r.id = 1;
    r.zone.kind = Zone::Kind::Box;
    r.zone.centre = {0.0, 0.0, 0.0};
    r.zone.axis[0] = {1, 0, 0}; r.zone.axis[1] = {0, 1, 0}; r.zone.axis[2] = {0, 0, 1};
    r.zone.half[0] = 18.0; r.zone.half[1] = 12.0; r.zone.half[2] = 30.0;
    z.regions = {r};
    add("octet pebble zone", fx.peb, z);
  }
  {
    Settings s = base_settings(LatticeTopology::Octet, 8.0);
    s.regions = {{1, Role::Lattice, {fx.top}, 30.0, 0.0}};
    with_stress(s, fx.stand.model);
    add("octet by stress (C22 cells, R16 struts)", fx.stand.model, s);
  }
  return out;
}
// The same cases with the stress: cells and struts by stress (set the demand on a copy before laying).
inline void with_stress(Settings& s, const StepModel& m) {
  Vec3 lo{1e300, 1e300, 1e300}, hi{-1e300, -1e300, -1e300};
  for (const Vec3& v : m.mesh.vertices) {
    lo = {std::min(lo.x, v.x), std::min(lo.y, v.y), std::min(lo.z, v.z)};
    hi = {std::max(hi.x, v.x), std::max(hi.y, v.y), std::max(hi.z, v.z)};
  }
  s.stress.demand = ramp_field(lo, hi, 2.0);
  s.stress.percentile = 0.95;
  s.cells.by_stress = true;
  s.struts.mode = Density::ByStress;
}
}  // namespace stream_fixtures
