// Organic cut 2 (brief E1): the print file as the carved solid plus unmerged closed tubes.
//   OF1  the layer check's NonZero fill: overlapping closed shells read as their union.
//   OF2  tubes from the final bars: every shell closed and outward, their union the merged lattice's volume.
//   OF3  trimmed to the part: nothing more than 0.05 mm outside a slanted face or into a slot, nothing below the bed.
//   OF4  the file route: tubes end clean in no more passes than merged, the layers' areas within 3 %.
// Needs the Manifold library (the test makes its reference unions with it).
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <map>
#include <string>
#include <vector>

#include <manifold/manifold.h>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/step.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static TriangleMesh box_at(Vec3 lo, Vec3 hi) {
  TriangleMesh m;
  const Vec3 p[8] = {{lo.x, lo.y, lo.z}, {hi.x, lo.y, lo.z}, {hi.x, hi.y, lo.z}, {lo.x, hi.y, lo.z},
                     {lo.x, lo.y, hi.z}, {hi.x, lo.y, hi.z}, {hi.x, hi.y, hi.z}, {lo.x, hi.y, hi.z}};
  for (const Vec3& v : p) m.vertices.push_back(v);
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  for (const auto& f : q) {
    m.triangles.push_back({f[0], f[1], f[2]});
    m.triangles.push_back({f[0], f[2], f[3]});
  }
  return m;
}
// Shells side by side in one triangle list, each on its own vertices.
static void append(TriangleMesh& to, const TriangleMesh& m) {
  const int base = static_cast<int>(to.vertices.size());
  to.vertices.insert(to.vertices.end(), m.vertices.begin(), m.vertices.end());
  for (const auto& t : m.triangles) to.triangles.push_back({t[0] + base, t[1] + base, t[2] + base});
}
static manifold::Manifold to_manifold(const TriangleMesh& m) {
  manifold::MeshGL64 g;
  g.numProp = 3;
  for (const Vec3& v : m.vertices) { g.vertProperties.push_back(v.x); g.vertProperties.push_back(v.y); g.vertProperties.push_back(v.z); }
  for (const auto& t : m.triangles)
    for (int k = 0; k < 3; ++k) g.triVerts.push_back(static_cast<std::uint64_t>(t[static_cast<std::size_t>(k)]));
  return manifold::Manifold(g);
}
static TriangleMesh from_manifold(const manifold::Manifold& m) {
  const manifold::MeshGL64 g = m.GetMeshGL64();
  TriangleMesh out;
  for (std::size_t v = 0; v < g.NumVert(); ++v)
    out.vertices.push_back({g.vertProperties[v * g.numProp], g.vertProperties[v * g.numProp + 1], g.vertProperties[v * g.numProp + 2]});
  for (std::size_t t = 0; t < g.NumTri(); ++t)
    out.triangles.push_back({static_cast<int>(g.triVerts[3 * t]), static_cast<int>(g.triVerts[3 * t + 1]), static_cast<int>(g.triVerts[3 * t + 2])});
  return out;
}
static bool same_findings(const LayerReport& a, const LayerReport& b) {
  if (a.mid_air.size() != b.mid_air.size() || a.one_ended.size() != b.one_ended.size() ||
      a.long_bridges.size() != b.long_bridges.size())
    return false;
  for (std::size_t i = 0; i < a.mid_air.size(); ++i)
    if (a.mid_air[i].x != b.mid_air[i].x || a.mid_air[i].y != b.mid_air[i].y || a.mid_air[i].z != b.mid_air[i].z ||
        a.mid_air[i].mm2 != b.mid_air[i].mm2)
      return false;
  for (std::size_t i = 0; i < a.one_ended.size(); ++i)
    if (a.one_ended[i].x != b.one_ended[i].x || a.one_ended[i].y != b.one_ended[i].y || a.one_ended[i].z != b.one_ended[i].z ||
        a.one_ended[i].reach_mm != b.one_ended[i].reach_mm)
      return false;
  return a.longest_reach_mm == b.longest_reach_mm && a.thin_islands == b.thin_islands && a.layers == b.layers &&
         a.first_layer_mm2 == b.first_layer_mm2;
}

// OF1: two overlapping closed cubes as two shells, under NonZero, give the same filled pixels (every layer's area) and
// the same findings as their true union as one mesh; under EvenOdd they do not.
static void test_nonzero_fill() {
  const TriangleMesh a = box_at({0.0, 0.0, 0.0}, {6.02, 4.03, 6.01});
  const TriangleMesh b = box_at({3.01, 0.0, 4.11}, {11.03, 4.03, 6.01});   // runs 5 mm out past a: held at one end
  TriangleMesh two;
  append(two, a);
  append(two, b);
  const TriangleMesh one = from_manifold(to_manifold(a) + to_manifold(b));
  CHECK(one.triangles.size() > 12);
  LayerSpec nz;
  nz.fill = LayerSpec::Fill::NonZero;
  nz.layer_areas = true;
  LayerSpec eo;
  eo.layer_areas = true;
  const LayerReport two_nz = check_layers(two, nz), one_nz = check_layers(one, nz);
  const LayerReport two_eo = check_layers(two, eo), one_eo = check_layers(one, eo);
  CHECK(!one_nz.layer_mm2.empty() && one_nz.layer_mm2 == two_nz.layer_mm2);
  CHECK(same_findings(one_nz, two_nz));
  CHECK(!one_nz.one_ended.empty());   // the overhang is found, in both
  // One closed shell reads the same under either rule.
  CHECK(one_eo.layer_mm2 == one_nz.layer_mm2 && same_findings(one_eo, one_nz));
  // Under EvenOdd the overlap cancels: the layers through it read less.
  CHECK(two_eo.layer_mm2 != one_eo.layer_mm2);
  double lost = 0.0;
  for (std::size_t k = 0; k < one_eo.layer_mm2.size(); ++k) lost += one_eo.layer_mm2[k] - two_eo.layer_mm2[k];
  CHECK(lost > 1.0);
  // The default is EvenOdd, and it reports no areas unless asked.
  CHECK(LayerSpec{}.fill == LayerSpec::Fill::EvenOdd && check_layers(two).layer_mm2.empty());
  // A shell inside out under NonZero adds nothing (its crossings count down).
  TriangleMesh inv = a;
  for (auto& t : inv.triangles) std::swap(t[1], t[2]);
  TriangleMesh with_inv;
  append(with_inv, b);
  append(with_inv, inv);
  const LayerReport r_inv = check_layers(with_inv, nz);
  CHECK(r_inv.layer_mm2.size() > 25 && r_inv.layer_mm2[25] > 1.0 && r_inv.layer_mm2[25] < one_nz.layer_mm2[25] - 10.0);
}

// ── the weave block of the mesh test (test_lattice_layout_mesh.cpp, test_weave_file), copied ──
static TriangleMesh prism_poly(const std::vector<std::array<double, 2>>& xy, double z0, double z1) {
  const int n = static_cast<int>(xy.size());
  auto turn = [&](int a, int b, int c) {
    return (xy[b][0] - xy[a][0]) * (xy[c][1] - xy[a][1]) - (xy[b][1] - xy[a][1]) * (xy[c][0] - xy[a][0]);
  };
  std::vector<int> left(n);
  for (int i = 0; i < n; ++i) left[i] = i;
  std::vector<std::array<int, 3>> tris;
  while (left.size() > 3) {
    bool cut = false;
    const int m = static_cast<int>(left.size());
    for (int i = 0; i < m && !cut; ++i) {
      const int a = left[(i + m - 1) % m], b = left[i], c = left[(i + 1) % m];
      if (turn(a, b, c) <= 1e-12) continue;
      bool empty = true;
      for (int k : left)
        if (k != a && k != b && k != c && turn(a, b, k) >= -1e-12 && turn(b, c, k) >= -1e-12 && turn(c, a, k) >= -1e-12) empty = false;
      if (!empty) continue;
      tris.push_back({a, b, c});
      left.erase(left.begin() + i);
      cut = true;
    }
    if (!cut) return {};
  }
  tris.push_back({left[0], left[1], left[2]});
  MeshSink s;
  auto P = [&](int i, double z) { return Vec3{xy[i % n][0], xy[i % n][1], z}; };
  for (const auto& t : tris) {
    s.add_triangle(P(t[0], z1), P(t[1], z1), P(t[2], z1));
    s.add_triangle(P(t[0], z0), P(t[2], z0), P(t[1], z0));
  }
  for (int i = 0; i < n; ++i) {
    s.add_triangle(P(i, z0), P(i + 1, z0), P(i + 1, z1));
    s.add_triangle(P(i, z0), P(i + 1, z1), P(i, z1));
  }
  return s.mesh;
}
static StepModel weave_block() {
  const double H = 14.0, cx = 20.0, R = 6.0;
  std::vector<std::array<double, 2>> xy = {{0, 0}, {40, 0}, {40, H}, {cx + R, H}};
  const int N = 48;
  for (int i = 1; i < N; ++i) {
    const double t = 3.14159265358979323846 * i / N;
    xy.push_back({cx + R * std::cos(t), H - R * std::sin(t)});
  }
  xy.push_back({cx - R, H});
  xy.push_back({0, H});
  const TriangleMesh solid_mesh = prism_poly(xy, 0, 20);
  StepModel model;
  model.mesh = solid_mesh;
  StepFaceInfo under, wall, rest;
  under.kind = StepSurfaceKind::Plane;
  under.plane_normal = {0, -1, 0};
  under.plane_origin = {20, 0, 10};
  wall.kind = StepSurfaceKind::Other;
  rest.kind = StepSurfaceKind::Other;
  model.faces = {under, wall, rest};
  model.face_count = 3;
  for (const auto& t : solid_mesh.triangles) {
    const Vec3 &a = solid_mesh.vertices[static_cast<std::size_t>(t[0])], &b = solid_mesh.vertices[static_cast<std::size_t>(t[1])],
               &c = solid_mesh.vertices[static_cast<std::size_t>(t[2])];
    auto on_arc = [&](const Vec3& v) { return std::fabs(std::hypot(v.x - cx, v.y - H) - R) < 1e-6 && v.y < H + 1e-9; };
    int f = 2;
    if (a.y < 1e-9 && b.y < 1e-9 && c.y < 1e-9) f = 0;
    else if (on_arc(a) && on_arc(b) && on_arc(c) && !(a.z == b.z && b.z == c.z)) f = 1;
    model.triangle_face.push_back(f);
  }
  model.solid_count = 1;
  return model;
}
static Vec3 round_pocket(double r, double deg, double z) {
  const double t = deg * 3.14159265358979323846 / 180.0;
  return {20.0 + r * std::cos(t), 14.0 - r * std::sin(t), z};
}
static Strand weave_strand(std::vector<Vec3> pts, int region = 1) {
  Strand s;
  s.width_mm.assign(pts.size(), 0.9);
  s.points = std::move(pts);
  s.region = region;
  s.spacing_mm = 4.0;
  return s;
}
static std::vector<Strand> made_up_weave() {   // as in the layout test
  std::vector<Strand> w;
  const double r = 7.75;
  for (double z : {4.0, 8.0, 12.0}) {
    std::vector<Vec3> p;
    for (double t = -15; t <= 195 + 1e-9; t += 30) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {
    std::vector<Vec3> p;
    for (double t = 45; t <= 135 + 1e-9; t += 30) p.push_back(round_pocket(r, t, 16.0));
    w.push_back(weave_strand(p));
  }
  for (double t : {30.0, 60.0, 90.0, 120.0, 150.0}) {
    std::vector<Vec3> p;
    for (double z = -1; z <= 21 + 1e-9; z += 2) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {
    std::vector<Vec3> p;
    for (double z = 6; z <= 14 + 1e-9; z += 2) p.push_back(round_pocket(r, 165.0, z));
    w.push_back(weave_strand(p));
  }
  w.push_back(weave_strand({round_pocket(7.0, 60, 10), round_pocket(9.0, 60, 10), round_pocket(11.5, 60, 10)}));
  w.push_back(weave_strand({round_pocket(9.0, 90, 6), round_pocket(4.5, 90, 6)}));
  w.push_back(weave_strand({round_pocket(9.6, 45, 16), round_pocket(8.9, 45, 16)}));
  return w;
}

// Every shell of `w` closed (each edge once each way, by index) and outward (positive volume).
static std::size_t shells_closed_outward(const WeaveShells& w, double* least_mm3 = nullptr) {
  std::size_t good = 0;
  double least = 1e300;
  for (std::size_t s = 0; s + 1 < w.first_tri.size(); ++s) {
    std::map<std::pair<int, int>, int> edges;
    double vol = 0.0;
    for (std::size_t t = w.first_tri[s]; t < w.first_tri[s + 1]; ++t) {
      const auto& q = w.mesh.triangles[t];
      for (int e = 0; e < 3; ++e) ++edges[{q[static_cast<std::size_t>(e)], q[static_cast<std::size_t>((e + 1) % 3)]}];
      const Vec3 &a = w.mesh.vertices[static_cast<std::size_t>(q[0])], &b = w.mesh.vertices[static_cast<std::size_t>(q[1])],
                 &c = w.mesh.vertices[static_cast<std::size_t>(q[2])];
      vol += (a.x * (b.y * c.z - b.z * c.y) - a.y * (b.x * c.z - b.z * c.x) + a.z * (b.x * c.y - b.y * c.x)) / 6.0;
    }
    bool closed = true;
    for (const auto& kv : edges) {
      const auto back = edges.find({kv.first.second, kv.first.first});
      closed = closed && kv.second == 1 && back != edges.end() && back->second == 1;
    }
    least = std::min(least, vol);
    good += closed && vol > 0.0;
  }
  if (least_mm3) *least_mm3 = least;
  return good;
}
static manifold::Manifold shells_union(const WeaveShells& w) {
  std::vector<manifold::Manifold> all;
  for (std::size_t s = 0; s + 1 < w.first_tri.size(); ++s) {
    TriangleMesh one;
    std::map<int, int> at;
    for (std::size_t t = w.first_tri[s]; t < w.first_tri[s + 1]; ++t) {
      std::array<int, 3> q{};
      for (int k = 0; k < 3; ++k) {
        const int v = w.mesh.triangles[t][static_cast<std::size_t>(k)];
        auto it = at.find(v);
        if (it == at.end()) {
          it = at.emplace(v, static_cast<int>(one.vertices.size())).first;
          one.vertices.push_back(w.mesh.vertices[static_cast<std::size_t>(v)]);
        }
        q[static_cast<std::size_t>(k)] = it->second;
      }
      one.triangles.push_back(q);
    }
    all.push_back(to_manifold(one));
  }
  return manifold::Manifold::BatchBoolean(all, manifold::OpType::Add);
}
struct WeaveJob {
  StepModel model = weave_block();
  Session session{model};
  Outcome out;
  Bars weave;   // the weave's bars alone
  std::vector<int> regions;
  WeaveJob() {
    Settings s;
    s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}, {2, Role::Lattice, {0}, 3.0, 0.0, false}};
    s.cells.cell_max_mm = 4;
    s.cells.min_cells_across = 1;
    s.struts.allow_quilt = true;
    out = session.lay_weave(s, made_up_weave());
    for (const Layout::Weave& w : out.layout.weave) regions.push_back(w.region);
    for (const Bar& b : out.bars.bars)
      if (std::find(regions.begin(), regions.end(), b.region) != regions.end()) weave.bars.push_back(b);
  }
};

// OF2: tubes from the final bars, on a made weave block: every shell closed and outward, and the shells' union (a real
// union, cut to the part as the merged struts are) within 2 % of the merged route's lattice for the same bars.
static void test_tubes_from_bars() {
  WeaveJob job;
  const Domain& d = *job.session.domain();
  const PartMeasure& pm = job.session.measure();
  CHECK(!job.out.cancelled && !job.weave.bars.empty());
  const OpenSpace open = read_open_space(d, job.out.layout, 0.25);
  const Carved carved = carve_part(pm, job.out.layout, open);
  const MeshSpec spec = file_mesh_defaults();
  MeshReport merged;
  build_mesh(pm, d, job.out.layout, job.weave, carved, spec, &merged);
  CHECK(merged.ok && merged.struts_mm3 > 10.0);
  // The same bars as the merged route keeps (its hold rules, nothing left out by the layer check).
  const std::vector<char> present = bars_present(job.weave, {}, job.regions, spec.layer_mm);
  const WeaveHolds holds = weave_holds(job.weave, job.regions, present, spec.bridge_rise);
  const WeaveShells w = weave_shells(pm, d, job.out.layout, job.weave, holds.kept, carved, spec, false);
  double least = 0.0;
  const std::size_t good = shells_closed_outward(w, &least);
  const manifold::Manifold part = to_manifold(pm.mesh());
  const double united = (shells_union(w) ^ part).Volume();
  std::printf("tubes: %zu shells (%zu tubes, %zu sharp splits, %zu shallow struts, %zu feet, %zu posts), %zu triangles; "
              "%zu closed and outward, least %.4f mm3; union in the part %.2f mm3, merged struts %.2f mm3 (%+.2f %%); "
              "shells summed %.2f mm3\n",
              w.shells(), w.tubes, w.sharp_splits, w.bridges, w.feet, w.posts, w.mesh.triangles.size(), good, least, united,
              merged.struts_mm3, 100.0 * (united / merged.struts_mm3 - 1.0), w.mm3);
  CHECK(w.tubes >= 6 && w.bridges > 0 && w.feet > 0);
  CHECK(good == w.shells() && least > 0.0);
  CHECK(std::fabs(united / merged.struts_mm3 - 1.0) < 0.02);
  CHECK(w.first_tri.back() == w.mesh.triangles.size());
  // The tube's sides are a key: 12 sides make more triangles than 8, the same shells.
  MeshSpec twelve = spec;
  twelve.tube_sides = 12;
  const WeaveShells w12 = weave_shells(pm, d, job.out.layout, job.weave, holds.kept, carved, twelve, false);
  CHECK(w12.shells() == w.shells() && w12.mesh.triangles.size() > w.mesh.triangles.size());
  // A turn sharper than 60 degrees ends the tube (two tubes, round caps overlapping at the corner); 45 degrees is mitred.
  for (double deg : {45.0, 150.0}) {   // 150: a steep turn back (a level one would be a shallow bar)
    Bars two;
    const double t = deg * 3.14159265358979323846 / 180.0;
    const Vec3 a = round_pocket(8.0, 90, 4.0), b = round_pocket(8.0, 90, 8.0);
    const Vec3 c{b.x + 3.0 * std::sin(t), b.y, b.z + 3.0 * std::cos(t)};
    for (const auto& ends : {std::pair<Vec3, Vec3>{a, b}, std::pair<Vec3, Vec3>{b, c}}) {
      Bar x;
      x.a = ends.first;
      x.b = ends.second;
      x.width = 0.9;
      x.region = 1;
      x.strand = 7;
      x.end_a = x.end_b = Bar::End::Node;
      two.bars.push_back(x);
    }
    const WeaveShells wt = weave_shells(pm, d, job.out.layout, two, {}, carved, spec, false);
    CHECK(shells_closed_outward(wt) == wt.shells());
    CHECK(deg < 60 ? (wt.tubes == 1 && wt.sharp_splits == 0) : (wt.tubes == 2 && wt.sharp_splits == 1));
  }
  // The runs' bars, as weave_runs hands them over: every segment one bar of the strand, in order.
  std::vector<std::vector<std::size_t>> bar_of;
  const std::vector<WeaveRun> runs = weave_runs(job.weave, job.regions, 0.0, &bar_of);
  bool fits = bar_of.size() == runs.size();
  for (std::size_t q = 0; fits && q < runs.size(); ++q) fits = bar_of[q].size() + 1 == runs[q].points.size();
  CHECK(fits);
  weave_runs(job.weave, job.regions, 0.1, &bar_of);
  CHECK(bar_of.empty());
}

// A part with a slanted face and a slot (a 2 mm notch down into it, under the slanted face's low end): 30 wide, 20 deep
// (z), the slanted face from (14, 13) to (0, 18); face 0 the slanted face, 1 the rest. A weave region 6 mm under the
// slanted face.
static StepModel slanted_slot_part() {
  const std::vector<std::array<double, 2>> xy = {{0, 0}, {30, 0}, {30, 10}, {16, 10}, {16, 5}, {14, 5}, {14, 13}, {0, 18}};
  const TriangleMesh mesh = prism_poly(xy, 0, 20);
  StepModel model;
  model.mesh = mesh;
  StepFaceInfo slant, rest;
  slant.kind = StepSurfaceKind::Plane;
  const double nx = 5.0, ny = 14.0, nl = std::hypot(nx, ny);   // outward normal of the slanted face
  slant.plane_normal = {nx / nl, ny / nl, 0};
  slant.plane_origin = {7, 15.5, 10};
  rest.kind = StepSurfaceKind::Other;
  model.faces = {slant, rest};
  model.face_count = 2;
  for (const auto& t : mesh.triangles) {
    bool on = true;
    for (int k = 0; k < 3; ++k) {
      const Vec3& v = mesh.vertices[static_cast<std::size_t>(t[static_cast<std::size_t>(k)])];
      on = on && std::fabs((v.x - 7.0) * nx + (v.y - 15.5) * ny) < 1e-6;
    }
    model.triangle_face.push_back(on ? 0 : 1);
  }
  model.solid_count = 1;
  return model;
}

// OF3: trimmed to the part, on a made part with a slanted face and a slot: no vertex of any shell more than 0.05 mm
// outside the part, nothing below the bed; every shell still closed and outward; what was left out is counted.
static void test_trimmed_to_part() {
  const StepModel model = slanted_slot_part();
  Session session(model);
  Settings s;
  s.regions = {{1, Role::Lattice, {0}, 6.0, 0.0, true}};
  s.cells.cell_max_mm = 4;
  s.cells.min_cells_across = 1;
  // Strands through the region: steep ones from beyond the slanted face down into the part (they meet the face on a
  // slant), steep ones down past the slot, and level ones across it.
  std::vector<Strand> strands;
  for (double x = 1.0; x < 14.0; x += 2.5)
    for (double z = 2.0; z < 18.0; z += 4.0) {
      const double yf = 18.0 - 5.0 * x / 14.0;   // the face's height here
      strands.push_back(weave_strand({{x, yf + 1.0, z}, {x + 0.7, yf - 2.0, z + 2.0}, {x + 1.4, yf - 5.0, z + 4.5},
                                      {x + 2.0, yf - 9.0, z + 7.0}}));
    }
  for (double z = 3.0; z < 18.0; z += 3.0) strands.push_back(weave_strand({{4.0, 9.0, z}, {15.0, 7.0, z + 0.3}, {19.0, 9.0, z}}));
  for (double x : {13.2, 14.6, 15.4, 16.8}) strands.push_back(weave_strand({{x, 9.5, -1.0}, {x + 0.3, 6.0, 9.0}, {x, 9.5, 21.0}}));
  for (double z = 1.0; z < 20.0; z += 2.0) strands.push_back(weave_strand({{-1.0, 16.7, z}, {15.0, 12.1, z}}));
  const Outcome out = session.lay_weave(s, strands);
  std::printf("slanted part: cancelled %d, weave regions %zu, bars %zu, empty regions %zu\n", out.cancelled ? 1 : 0,
              out.layout.weave.size(), out.bars.bars.size(), out.empty_regions.size());
  CHECK(!out.cancelled && out.layout.weave.size() == 1 && !out.bars.bars.empty());
  const Domain& d = *session.domain();
  const PartMeasure& pm = session.measure();
  const OpenSpace open = read_open_space(d, out.layout, 0.25);
  const Carved carved = carve_part(pm, out.layout, open);
  const MeshSpec spec = file_mesh_defaults();
  const WeaveShells raw = weave_shells(pm, d, out.layout, out.bars, {}, carved, spec, false);
  const WeaveShells w = weave_shells(pm, d, out.layout, out.bars, {}, carved, spec, true);
  auto pr = pm.probe();
  double worst_raw = 0.0, worst = 0.0, z_low = 1e9;
  for (const Vec3& v : raw.mesh.vertices) worst_raw = std::max(worst_raw, -pr.depth(v));
  for (const Vec3& v : w.mesh.vertices) { worst = std::max(worst, -pr.depth(v)); z_low = std::min(z_low, v.z); }
  double least = 0.0;
  const std::size_t good = shells_closed_outward(w, &least);
  std::printf("trimmed: %zu shells (%zu tubes, %zu shallow struts, %zu feet) from %zu; before trimming %.3f mm outside at most, "
              "after %.4f mm (reported %.4f); %zu vertices moved, %.3f mm at most; %zu made again, %zu left out; lowest z %.4f\n",
              w.shells(), w.tubes, w.bridges, w.feet, raw.shells(), worst_raw, worst, w.outside_largest_mm, w.trimmed_vertices,
              w.trimmed_largest_mm, w.rebuilt, w.left_out, z_low);
  CHECK(worst_raw > 0.1);                      // there was something to trim
  CHECK(w.trimmed_vertices > 0 && worst <= 0.05);
  CHECK(std::fabs(w.outside_largest_mm - worst) < 1e-3);
  CHECK(z_low >= 0.0);                         // the bed is the part's lowest z, 0: nothing under it at all
  CHECK(good == w.shells() && least > 0.0);
  CHECK(w.shells() + w.left_out == raw.shells());
}

// OF4: the file route on the weave block, with a V of one strand hanging in the open lattice (an overhanging start): the tubes route ends with 0 findings in no more passes than the merged route, and per layer the filled area of
// the two routes differs by under 3 % summed over the part.
static void test_tubes_route() {
  const StepModel model = weave_block();
  Session session(model);
  Settings s;
  s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}, {2, Role::Lattice, {0}, 3.0, 0.0, false}};
  s.cells.cell_max_mm = 4;
  s.cells.min_cells_across = 1;
  s.struts.allow_quilt = true;
  std::vector<Strand> strands = made_up_weave();
  strands.erase(strands.begin());   // the ring at z 4: a level ring over open lattice the check never clears, either route
  // A V hanging in the open lattice (its two arms hold each other at the bottom): a start in mid-air, no sag lift or leg.
  strands.push_back(weave_strand({round_pocket(11.0, 100, 15.0), round_pocket(8.6, 105, 11.0), round_pocket(11.0, 110, 15.0)}));
  const Outcome out = session.lay_weave(s, strands);
  const Domain& d = *session.domain();
  const OpenSpace open = read_open_space(d, out.layout, 0.25);
  PrintableSpec merged_spec;
  merged_spec.mesh = file_mesh_defaults();
  merged_spec.mesh.weave_sag_lift_mm = 0.0;
  merged_spec.mesh.weave_sag_legs = false;
  PrintableSpec tubes_spec = merged_spec;
  tubes_spec.mesh.weave_mesh = MeshSpec::WeaveMesh::Tubes;
  PrintableReport rm, rt;
  const TriangleMesh mm = build_printable_mesh(session.measure(), d, out.layout, out.bars, open, merged_spec, &rm);
  const TriangleMesh mt = build_printable_mesh(session.measure(), d, out.layout, out.bars, open, tubes_spec, &rt);
  CHECK(rm.mesh.ok && rt.mesh.ok && !rm.tubes && rt.tubes);
  CHECK(rt.shell_first_tri.size() == rt.shells.shells() + 1 && rt.shell_first_tri.back() == mt.triangles.size());
  CHECK(rt.base_triangles == rt.shell_first_tri.front() && rt.base_builds >= 1 && rt.base_builds <= rt.passes);
  LayerSpec eo, nz;
  eo.layer_areas = nz.layer_areas = true;
  nz.fill = LayerSpec::Fill::NonZero;
  const LayerReport lm = check_layers(mm, eo), lt = check_layers(mt, nz);
  double diff = 0.0, total = 0.0;
  for (std::size_t k = 0; k < std::max(lm.layer_mm2.size(), lt.layer_mm2.size()); ++k) {
    const double a = k < lm.layer_mm2.size() ? lm.layer_mm2[k] : 0.0, b = k < lt.layer_mm2.size() ? lt.layer_mm2[k] : 0.0;
    diff += std::fabs(a - b);
    total += a;
  }
  auto passes = [](const PrintableReport& r) {
    std::string o;
    for (int f : r.found_per_pass) o += std::to_string(f) + " ";
    return o;
  };
  std::printf("route: merged %d passes (found %s), clean %d, %zu triangles; tubes %d passes (found %s), clean %d, %zu triangles, "
              "%zu shells (%zu tubes, %zu shallow, %zu feet, %zu posts), %zu left out, solid made %d times; layers differ by "
              "%.3f %% of %.1f mm2\n",
              rm.passes, passes(rm).c_str(), rm.clean ? 1 : 0, mm.triangles.size(), rt.passes, passes(rt).c_str(),
              rt.clean ? 1 : 0, mt.triangles.size(), rt.shells.shells(), rt.shells.tubes, rt.shells.bridges, rt.shells.feet,
              rt.shells.posts, rt.shells.left_out, rt.base_builds, 100.0 * diff / total, total);
  for (const PrintableReport* r : {&rm, &rt}) {
    for (const auto& m : r->layers.mid_air) std::printf("  mid-air at %.2f %.2f %.2f (%.3f mm2)\n", m.x, m.y, m.z, m.mm2);
    for (const auto& o : r->layers.one_ended) std::printf("  one-ended at %.2f %.2f %.2f reach %.2f\n", o.x, o.y, o.z, o.reach_mm);
    for (const auto& o : r->layers.long_bridges) std::printf("  long bridge at %.2f %.2f %.2f reach %.2f\n", o.x, o.y, o.z, o.reach_mm);
  }
  CHECK(!rm.found_per_pass.empty() && rm.found_per_pass.front() > 0);   // it did start overhanging
  CHECK(rt.clean && rt.found_per_pass.back() == 0 && rt.passes <= rm.passes);
  CHECK(total > 0.0 && diff < 0.03 * total);
  // The keys: mesh "weave_mesh" ("tubes" or "merged"; anything else refused, by name) and "tube_sides" (3 or more).
  {
    auto job = [](const std::string& mesh) { return R"({"mode": "lattice_file", "model": "a.step", "mesh": {)" + mesh + "}}"; };
    const FileJob plain = parse_file_job(job(""));
    CHECK(!plain.options.weave_mesh_asked && plain.options.mesh.weave_mesh == MeshSpec::WeaveMesh::Merged &&
          plain.options.mesh.tube_sides == 8);
    const FileJob t = parse_file_job(job(R"("weave_mesh": "tubes", "tube_sides": 12)"));
    CHECK(t.options.weave_mesh_asked && t.options.mesh.weave_mesh == MeshSpec::WeaveMesh::Tubes && t.options.mesh.tube_sides == 12);
    const FileJob m = parse_file_job(job(R"("weave_mesh": "merged")"));
    CHECK(m.options.weave_mesh_asked && m.options.mesh.weave_mesh == MeshSpec::WeaveMesh::Merged);
    for (const char* bad : {R"("weave_mesh": "solid")", R"("tube_sides": 2)"}) {
      bool refused = false;
      try { (void)parse_file_job(job(bad)); } catch (const FileJobError& e) {
        refused = std::string(e.what()).find(std::string(bad).substr(1, 9)) != std::string::npos;
      }
      CHECK(refused);
    }
  }
  // The route is the writer's choice only with a weave region: a cube-lattice part reads it as Merged, the same mesh.
  {
    PrintableReport a, b;
    Layout no_weave = out.layout;
    no_weave.weave.clear();
    Bars cube;
    for (const Bar& x : out.bars.bars)
      if (x.region == 2) cube.bars.push_back(x);
    const OpenSpace o2 = read_open_space(d, no_weave, 0.25);
    const TriangleMesh x = build_printable_mesh(session.measure(), d, no_weave, cube, o2, merged_spec, &a);
    const TriangleMesh y = build_printable_mesh(session.measure(), d, no_weave, cube, o2, tubes_spec, &b);
    bool same = x.vertices.size() == y.vertices.size() && x.triangles == y.triangles && !b.tubes;
    for (std::size_t i = 0; same && i < x.vertices.size(); ++i)
      same = x.vertices[i].x == y.vertices[i].x && x.vertices[i].y == y.vertices[i].y && x.vertices[i].z == y.vertices[i].z;
    CHECK(same && !x.triangles.empty());
  }
}

int main() {
  if (!mesh_available()) {
    std::printf("no mesh library in this build (%d checks, %d failed)\n", g_checks, g_fail);
    return 0;
  }
  test_nonzero_fill();
  test_tubes_from_bars();
  test_trimmed_to_part();
  test_tubes_route();
  std::printf("weave tubes: %d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
