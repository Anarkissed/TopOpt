// Organic stage 1b (rules O3, O4): the owner's Traced placement through the new engine. The old tracer is called as
// it is (trace_organic_lattice) on made-up parts and made-up stress fields; its curves become strands and go through
// stage 1a's path. Numbered as in docs/design/lattice-rebuild/02-tests.md, section 11 (A to E).
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <stdexcept>
#include <vector>

#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/organic_lattice.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

static double ms_since(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}
static double dist(const Vec3& a, const Vec3& b) { return std::hypot(a.x - b.x, std::hypot(a.y - b.y, a.z - b.z)); }
static double to_segment(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  return std::hypot(p.x - a.x - d.x * t, std::hypot(p.y - a.y - d.y * t, p.z - a.z - d.z * t));
}
static double to_polyline(const Vec3& p, const std::vector<Vec3>& line) {
  double best = 1e300;
  for (std::size_t i = 0; i + 1 < line.size(); ++i) best = std::min(best, to_segment(p, line[i], line[i + 1]));
  return best;
}
static double bar_length(const Bar& b) { return dist(b.a, b.b); }

static TriangleMesh box(double x, double y, double z) {
  MeshSink s;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  for (const auto& f : q) {
    s.add_triangle(p[f[0]], p[f[1]], p[f[2]]);
    s.add_triangle(p[f[0]], p[f[2]], p[f[3]]);
  }
  return s.mesh;
}
static Region face_region(int id, Vec3 origin, Vec3 inward, double half_u, double half_w, double depth) {
  ManualClearanceGeometry m;
  m.kind = ClearanceKind::Face;
  m.origin = origin;
  m.normal = inward;
  m.half_u_mm = half_u;
  m.half_w_mm = half_w;
  ClearanceParams p;
  p.kind = ClearanceKind::Face;
  p.slab_depth_mm = depth;
  Region r;
  r.id = id;
  r.role = Role::Lattice;
  r.prism = resolve_clearance_manual(m, p);
  r.prism.declared_region_id = id;
  return r;
}

// The mesh as a slicer reads it: corners at one place are one corner (as the mesh test reads it).
struct Read {
  std::size_t edges_not_twice = 0, flat = 0, shells = 0;
};
static Read read_mesh(const TriangleMesh& m) {
  Read r;
  std::map<std::array<double, 3>, int> at;
  std::vector<int> id(m.vertices.size());
  for (std::size_t v = 0; v < m.vertices.size(); ++v) {
    const Vec3& p = m.vertices[v];
    id[v] = at.emplace(std::array<double, 3>{p.x, p.y, p.z}, static_cast<int>(at.size())).first->second;
  }
  std::vector<int> up(at.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = static_cast<int>(i);
  auto find = [&](int v) { while (up[static_cast<std::size_t>(v)] != v) v = up[static_cast<std::size_t>(v)] = up[static_cast<std::size_t>(up[static_cast<std::size_t>(v)])]; return v; };
  std::map<std::pair<int, int>, int> way;
  for (const auto& t : m.triangles) {
    const int c[3] = {id[static_cast<std::size_t>(t[0])], id[static_cast<std::size_t>(t[1])], id[static_cast<std::size_t>(t[2])]};
    if (c[0] == c[1] || c[1] == c[2] || c[0] == c[2]) { ++r.flat; continue; }
    for (int q = 0; q < 3; ++q) {
      ++way[{c[q], c[(q + 1) % 3]}];
      up[static_cast<std::size_t>(find(c[q]))] = find(c[0]);
    }
  }
  for (const auto& kv : way) {
    const auto back = way.find({kv.first.second, kv.first.first});
    if (kv.second != 1 || back == way.end() || back->second != 1) ++r.edges_not_twice;
  }
  std::map<int, int> roots;
  for (const auto& t : m.triangles) ++roots[find(id[static_cast<std::size_t>(t[0])])];
  r.shells = roots.size();
  return r;
}

// ── A, B: the old unit test's own block ──────────────────────────────────────
// test_organic_printability's grow_fixture: 12 x 12 x 24 voxels at 1 mm, uniform sigma_zz = 1 MPa, spacing 4, strut
// 0.8. Here the block is a part, all of it one weave region (a face region on its underside, 24 mm deep).
struct Block {
  PartMeasure pm{weld_mesh(box(12, 12, 24))};
  Domain d{pm, [] {
             DomainSpec s;
             s.regions = {face_region(1, {6, 6, 0}, {0, 0, 1}, 6, 6, 24)};
             s.regions[0].weave = true;
             return s;
           }()};
  TensorField field;
  OrganicAsk ask;
  Block() {
    field.nx = 12; field.ny = 12; field.nz = 24;
    field.spacing = 1.0;
    field.voigt.assign(6 * 12 * 12 * 24, 0.0);
    for (std::size_t e = 0; e < 12 * 12 * 24; ++e) field.voigt[6 * e + 2] = 1.0;   // sigma_zz
    ask.spacing_mm = 4.0;
    ask.width_mm = 0.8;
  }
};

static void test_traced_block() {
  Block b;
  auto pr = b.d.probe();
  const std::vector<Strand> strands = trace_strands(b.d, 1, b.field, b.ask);
  // The trace itself, called as trace_strands calls it: every voxel's centre is lattice of the region.
  VoxelGrid grid;
  grid.nx = 12; grid.ny = 12; grid.nz = 24; grid.spacing = 1.0;
  grid.tags.assign(12 * 12 * 24, VoxelTag::Interior);
  std::vector<char> cand(grid.tags.size(), 0);
  std::size_t centres = 0;
  for (int k = 0; k < 24; ++k)
    for (int j = 0; j < 12; ++j)
      for (int i = 0; i < 12; ++i) {
        const Where w = pr.where(grid.voxel_center(i, j, k));
        if (w.lattice() && w.id == 1) { cand[grid.index(i, j, k)] = 1; ++centres; }
      }
  OrganicParams params;
  params.min_extrudable_width_mm = b.d.spec().bead_mm * b.d.spec().min_strut_lines;
  params.strut_diameter_mm = 0.8;
  params.bead_is_stated = true;
  const std::vector<double> spacing(grid.tags.size(), 4.0);
  const OrganicLattice lat = trace_organic_lattice(grid, cand, b.field.voigt, spacing, nullptr, params);
  CHECK(centres == grid.tags.size());
  CHECK(!lat.curves.empty() && strands.size() == lat.curves.size() + lat.connectors.size());
  std::size_t traced_points = 0, kept_points = 0, straight_runs = 0, straight_halved = 0, outside = 0, widths_wrong = 0;
  double worst = 0.0;   // the farthest any traced point lies from its straightened strand, in widths
  for (std::size_t k = 0; k < strands.size() && k < lat.curves.size() + lat.connectors.size(); ++k) {
    const Strand& s = strands[k];
    const bool curve = k < lat.curves.size();
    const std::vector<Vec3> traced = curve ? lat.curves[k].points
                                           : std::vector<Vec3>{lat.connectors[k - lat.curves.size()].a,
                                                               lat.connectors[k - lat.curves.size()].b};
    const double radius = curve ? lat.curves[k].radius_mm : lat.connectors[k - lat.curves.size()].radius_mm;
    for (double w : s.width_mm) widths_wrong += w != 2.0 * radius;
    widths_wrong += s.width_mm.size() != s.points.size() || s.region != 1 || !(s.spacing_mm >= 4.0);
    for (const Vec3& p : s.points) outside += pr.part().depth(p) < -1e-9;
    for (const Vec3& p : traced) worst = std::max(worst, to_polyline(p, s.points) / (2.0 * radius));
    traced_points += traced.size();
    kept_points += s.points.size();
    // A straight run (every traced point on the chord): straightening at least halves it.
    if (traced.size() >= 4) {
      bool straight = true;
      for (const Vec3& p : traced) straight = straight && to_segment(p, traced.front(), traced.back()) < 1e-9;
      if (straight) { ++straight_runs; straight_halved += 2 * s.points.size() <= traced.size(); }
    }
  }
  std::printf("traced block: %zu curves + %zu connectors -> %zu strands; %zu traced points -> %zu; straight runs %zu, halved %zu; "
              "farthest traced point %.4f widths from its strand; %zu points outside the part; %zu widths wrong\n",
              lat.curves.size(), lat.connectors.size(), strands.size(), traced_points, kept_points, straight_runs, straight_halved,
              worst, outside, widths_wrong);
  CHECK(outside == 0 && widths_wrong == 0);
  CHECK(worst <= 0.1 + 1e-9);
  CHECK(straight_runs > 0 && straight_halved == straight_runs);
  CHECK(kept_points < traced_points);
}

// B: the same call twice gives the same strands, to the bit.
static void test_traced_repeat() {
  Block b;
  const std::vector<Strand> x = trace_strands(b.d, 1, b.field, b.ask), y = trace_strands(b.d, 1, b.field, b.ask);
  bool same = x.size() == y.size() && !x.empty();
  for (std::size_t k = 0; same && k < x.size(); ++k) {
    same = x[k].points.size() == y[k].points.size() && x[k].width_mm == y[k].width_mm && x[k].region == y[k].region &&
           x[k].spacing_mm == y[k].spacing_mm;
    for (std::size_t i = 0; same && i < x[k].points.size(); ++i)
      same = std::memcmp(&x[k].points[i], &y[k].points[i], sizeof(Vec3)) == 0;
  }
  std::printf("traced twice: %zu strands, the same %d\n", x.size(), same ? 1 : 0);
  CHECK(same);
}

// ── C, D: a block with a curved pocket, a weave region under its wall ────────
// The block of the layout tests: 40 x 14 x 20 with a half-round pocket (radius 6, axis (20, 14) along z) in its top
// edge; faces 0 the underside, 1 the pocket's wall, 2 the rest. The weave region is 4 mm deep under the wall.
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
static StepModel pocket_block() {
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
// A made-up stress: tension along the pocket's wall, turning with it (10 MPa round the axis), 3 MPa along the axis,
// 1 MPa across the wall (all three directions distinct), on a 0.5 mm grid over the block.
static TensorField hoop_field() {
  TensorField f;
  f.spacing = 0.5;
  f.nx = 80; f.ny = 28; f.nz = 40;
  f.voigt.assign(6 * static_cast<std::size_t>(f.nx) * f.ny * f.nz, 0.0);
  for (int k = 0; k < f.nz; ++k)
    for (int j = 0; j < f.ny; ++j)
      for (int i = 0; i < f.nx; ++i) {
        const double x = (i + 0.5) * f.spacing - 20.0, y = (j + 0.5) * f.spacing - 14.0, r = std::hypot(x, y);
        if (!(r > 1e-9)) continue;
        const double rx = x / r, ry = y / r, tx = -ry, ty = rx;
        double* v = &f.voigt[6 * f.index(i, j, k)];
        v[0] = 10 * tx * tx + rx * rx;
        v[1] = 10 * ty * ty + ry * ry;
        v[2] = 3.0;
        v[3] = 10 * tx * ty + rx * ry;
      }
  return f;
}
static Settings pocket_settings() {
  Settings s;
  s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}};
  return s;
}

static void test_traced_pocket_and_file() {
  const StepModel model = pocket_block();
  Session session(model);
  const Settings s = pocket_settings();
  const TensorField field = hoop_field();
  OrganicAsk ask;
  ask.spacing_mm = 4.0;
  ask.width_mm = 0.9;
  auto t0 = std::chrono::steady_clock::now();
  const Outcome out = session.lay_organic(s, field, ask);
  const double ms_lay = ms_since(t0);
  const Domain& d = *session.domain();
  auto pr = d.probe();
  t0 = std::chrono::steady_clock::now();
  const std::vector<Strand> strands = trace_strands(d, 1, field, ask);
  const double ms_trace = ms_since(t0);
  std::printf("traced pocket: trace_strands %.0f ms, lay_organic %.0f ms (part read, trace, bars, joining, dropping)\n", ms_trace,
              ms_lay);
  CHECK(!out.cancelled && out.layout.weave.size() == 1 && out.layout.cells.empty());
  CHECK(!strands.empty());
  // lay_organic is exactly lay_weave with these strands.
  {
    Session other(model);
    const Outcome w = other.lay_weave(s, strands);
    bool same = w.bars.bars.size() == out.bars.bars.size() && out.layout.weave[0].spacing_mm == w.layout.weave[0].spacing_mm;
    for (std::size_t i = 0; same && i < w.bars.bars.size(); ++i) {
      const Bar &x = w.bars.bars[i], &y = out.bars.bars[i];
      same = std::memcmp(&x.a, &y.a, sizeof(Vec3)) == 0 && std::memcmp(&x.b, &y.b, sizeof(Vec3)) == 0 && x.end_a == y.end_a &&
             x.end_b == y.end_b && x.width == y.width;
    }
    CHECK(same);
  }
  auto held = [&](const Vec3& p) {
    const Where w = pr.where(p);
    return w.lattice() && w.id == 1;
  };
  // C (1): no free end is left short of a wall it was heading for: along its last segment, where the region's lattice
  // ends within one spacing ahead, the end is there (or past it, run into the solid). An end on another strand (a
  // connector's, or a curve's at a connector) is not free.
  long free_ends = 0, at_edge = 0, short_of_wall = 0, open_ahead = 0;
  for (std::size_t k = 0; k < strands.size(); ++k) {
    const Strand& st = strands[k];
    for (int e = 0; e < 2; ++e) {
      const Vec3 p = e ? st.points.back() : st.points.front();
      const Vec3 q = e ? st.points[st.points.size() - 2] : st.points[1];
      bool on_other = false;
      for (std::size_t m = 0; m < strands.size() && !on_other; ++m)
        on_other = m != k && to_polyline(p, strands[m].points) <= 0.5 * st.width_mm.front();
      if (on_other) continue;
      ++free_ends;
      const double len = dist(p, q);
      const Vec3 dir{(p.x - q.x) / len, (p.y - q.y) / len, (p.z - q.z) / len};
      double edge = -1.0;
      for (double a = 0.0; a <= st.spacing_mm + 1e-9; a += 0.01)
        if (!held(Vec3{p.x + dir.x * a, p.y + dir.y * a, p.z + dir.z * a})) { edge = a; break; }
      if (edge < 0.0) ++open_ahead;
      else if (edge <= 0.01) ++at_edge;
      else ++short_of_wall;
    }
  }
  std::printf("traced pocket: %zu strands, %ld free ends: %ld at the region's edge (or past it), %ld with no edge within one spacing, "
              "%ld short of a wall\n", strands.size(), free_ends, at_edge, open_ahead, short_of_wall);
  CHECK(free_ends > 0 && at_edge > 0 && short_of_wall == 0);
  // C (2): every bar lies in the region's lattice, or runs into the solid by its width at a Solid end, or ends on the
  // part's surface at a Surface end. A bar the trace laid ALONG the region's edge (a curve on the outermost row of
  // candidate voxels) also leaves the region's lattice along its length: into the solid it is counted as long as the
  // region's lattice is within its own width of the point, out of the part as long as it is within a hundredth of a
  // millimetre of the surface (what the file test allows); how far each goes is printed.
  auto lattice_within = [&](const Vec3& p, double reach) {
    for (double rr = 0.02; rr <= reach + 1e-9; rr += 0.02)
      for (int dx = -1; dx <= 1; ++dx)
        for (int dy = -1; dy <= 1; ++dy)
          for (int dz = -1; dz <= 1; ++dz) {
            if (!dx && !dy && !dz) continue;
            const double l = std::sqrt(static_cast<double>(dx * dx + dy * dy + dz * dz));
            if (held(Vec3{p.x + dx * rr / l, p.y + dy * rr / l, p.z + dz * rr / l})) return rr;
          }
    return -1.0;
  };
  long off_region = 0, along_edge_bars = 0;
  double deepest_in_solid = 0.0, farthest_out = 0.0;
  long samples = 0, astray = 0, weave_bars_kept = 0;
  int ends[6] = {0, 0, 0, 0, 0, 0};
  for (const Bar& b : out.bars.bars) {
    if (b.region != 1) continue;
    ++weave_bars_kept;
    ++ends[static_cast<int>(b.end_a)];
    ++ends[static_cast<int>(b.end_b)];
    const double len = bar_length(b);
    const int n = std::max(2, static_cast<int>(std::ceil(len / 0.05)));
    bool off_here = false;
    for (int i = 0; i <= n; ++i) {
      const double t = static_cast<double>(i) / n;
      const Vec3 p{b.a.x + (b.b.x - b.a.x) * t, b.a.y + (b.b.y - b.a.y) * t, b.a.z + (b.b.z - b.a.z) * t};
      ++samples;
      if (held(p)) continue;
      const double from_a = t * len, from_b = (1 - t) * len;
      if ((b.end_a == Bar::End::Solid && from_a <= b.width + 0.01) || (b.end_b == Bar::End::Solid && from_b <= b.width + 0.01)) continue;
      if ((b.end_a == Bar::End::Surface && from_a <= 0.01) || (b.end_b == Bar::End::Surface && from_b <= 0.01)) continue;
      ++off_region;
      off_here = true;
      const double depth = pr.part().depth(p);
      if (depth < 0.0) {
        farthest_out = std::max(farthest_out, -depth);
        if (depth < -0.01) ++astray;
        continue;
      }
      const double in_solid = lattice_within(p, b.width);
      if (in_solid < 0.0) { ++astray; continue; }
      deepest_in_solid = std::max(deepest_in_solid, in_solid);
    }
    along_edge_bars += off_here;
  }
  std::printf("traced pocket: %ld points along %ld bars lying along the region's edge are off its lattice: at most %.2f mm into the "
              "solid, %.4f mm out of the part\n", off_region, along_edge_bars, deepest_in_solid, farthest_out);
  std::printf("traced pocket: %ld weave bars kept, ends Node %d Solid %d Surface %d Loose %d Joined %d; %ld points along them, %ld astray; "
              "%zu pieces, %zu adrift\n", weave_bars_kept, ends[static_cast<int>(Bar::End::Node)], ends[static_cast<int>(Bar::End::Solid)],
              ends[static_cast<int>(Bar::End::Surface)], ends[static_cast<int>(Bar::End::Loose)], ends[static_cast<int>(Bar::End::Joined)],
              samples, astray, out.pieces.pieces, out.pieces.adrift);
  CHECK(weave_bars_kept > 20 && astray == 0);

  // D: the file. One body with the part, open between the struts, nothing outside the part, the layer check run to its
  // end.
  const OpenSpace open = read_open_space(d, out.layout, 0.25);
  PrintableReport rep;
  const TriangleMesh mesh = build_printable_mesh(session.measure(), d, out.layout, out.bars, open, PrintableSpec{}, &rep);
  CHECK(rep.mesh.ok && !mesh.empty());
  const Read r = read_mesh(mesh);
  long outside = 0;
  for (const Vec3& v : mesh.vertices) outside += pr.part().depth(v) < -0.01;
  std::printf("traced file: %zu open boxes, %zu bars (%zu bridges), %zu triangles, %zu shells, %zu edges not twice, %zu flat, "
              "%ld corners outside the part; %d builds, clean %d; left out %zu bars, %zu posts; layers %d\n",
              open.boxes.size(), rep.mesh.bars, rep.mesh.bridges, mesh.triangles.size(), r.shells, r.edges_not_twice, r.flat, outside,
              rep.passes, rep.clean ? 1 : 0, rep.mesh.bars_left_out, rep.posts.size(), rep.layers.layers);
  CHECK(r.shells == 1 && r.edges_not_twice == 0 && r.flat == 0);
  CHECK(outside == 0);
  CHECK(rep.passes >= 1 && rep.layers.layers > 0);
  if (const char* stl = std::getenv("ORGANIC_TRACED_STL")) {   // for the review pictures only
    if (FILE* f = std::fopen(stl, "wb")) {
      char head[80] = {0};
      std::fwrite(head, 1, 80, f);
      const std::uint32_t n = static_cast<std::uint32_t>(mesh.triangles.size());
      std::fwrite(&n, 4, 1, f);
      for (const auto& t : mesh.triangles) {
        float v[12] = {0, 0, 0};
        for (int c = 0; c < 3; ++c) {
          const Vec3& p = mesh.vertices[static_cast<std::size_t>(t[c])];
          v[3 + 3 * c] = static_cast<float>(p.x); v[4 + 3 * c] = static_cast<float>(p.y); v[5 + 3 * c] = static_cast<float>(p.z);
        }
        const std::uint16_t z = 0;
        std::fwrite(v, 4, 12, f);
        std::fwrite(&z, 2, 1, f);
      }
      std::fclose(f);
    }
  }
  std::size_t open_edges = 0;
  PartMeasure file(weld_mesh(mesh, 1e-6, &open_edges));
  auto fp = file.probe();
  auto far_from_struts = [&](const Vec3& p, double by) {
    for (const Bar& b : out.bars.bars)
      if (to_segment(p, b.a, b.b) < 0.5 * b.width + by) return false;
    for (const MeshSpec::Post& q : rep.posts)
      if (std::hypot(p.x - q.x, p.y - q.y) < 1.5 && p.z < q.z_top + 1.0) return false;
    return true;
  };
  long a_n = 0, a_full = 0;
  for (double z = 1.0; z < 19.5; z += 0.7)
    for (double deg = 12; deg < 170; deg += 3.1)
      for (double rr : {7.0, 8.3, 9.2}) {
        const double t = deg * 3.14159265358979323846 / 180.0;
        const Vec3 p{20.0 + rr * std::cos(t), 14.0 - rr * std::sin(t), z};
        if (!held(p) || !far_from_struts(p, 0.6)) continue;
        ++a_n;
        a_full += fp.inside(p);
      }
  std::printf("traced file: %ld points of the region away from the struts, %ld filled\n", a_n, a_full);
  CHECK(a_n > 100 && a_full == 0);

  // For the review (OR8-OR10, not the cube lattices' 5 mm rule): the weave's shallow bars, how they are held, their
  // lengths, and what today's layer check did with each band.
  auto left_out_bar = [&](const Bar& b) {
    const double rr = 0.5 * b.width;
    for (const Vec3& sp : rep.drop_at) {
      if (std::fabs(std::min(b.a.z, b.b.z) - rr - sp.z) > 0.45) continue;
      if (to_segment(sp, b.a, b.b) < rr + 0.35) return true;
    }
    return false;
  };
  auto holds = [](Bar::End e) { return e == Bar::End::Node || e == Bar::End::Solid || e == Bar::End::Joined; };
  long shallow = 0, both = 0, one = 0, none = 0, band[4][3] = {{0}};
  for (const Bar& b : out.bars.bars) {
    if (b.region != 1 || !bar_is_bridge(b)) continue;
    ++shallow;
    const int h = holds(b.end_a) + holds(b.end_b);
    (h == 2 ? both : h == 1 ? one : none) += 1;
    const double len = bar_length(b);
    const int k = len <= 5 ? 0 : len <= 10 ? 1 : len <= 20 ? 2 : 3;
    bool post = false;
    for (const MeshSpec::Post& q : rep.posts) post = post || to_segment(Vec3{q.x, q.y, q.z_top}, b.a, b.b) < 0.5 * b.width + 0.5;
    const bool out_here = left_out_bar(b);
    ++band[k][out_here ? 1 : post ? 2 : 0];
  }
  std::printf("traced shallow bars (under 30 degrees): %ld; held at both ends %ld, one %ld, none %ld\n", shallow, both, one, none);
  const char* names[4] = {"to 5 mm", "5 to 10", "10 to 20", "over 20"};
  for (int k = 0; k < 4; ++k)
    std::printf("  %-8s %3ld bars: kept %ld, left out %ld, post under %ld\n", names[k], band[k][0] + band[k][1] + band[k][2], band[k][0],
                band[k][1], band[k][2]);
}

// E: with no weave region nothing changes: lay_organic is lay(), the layout and bars the same.
static void test_no_weave_is_lay() {
  const StepModel model = pocket_block();
  Session a(model), b(model);
  Settings s = pocket_settings();
  s.regions[0].weave = false;
  s.cells.cell_max_mm = 4;
  s.cells.min_cells_across = 1;
  s.struts.allow_quilt = true;
  const Outcome x = a.lay(s), y = b.lay_organic(s, hoop_field(), OrganicAsk{4.0, 0.9, {0, 0, 1}});
  bool same = x.layout.cells == y.layout.cells && x.bars.bars.size() == y.bars.bars.size() && !x.bars.bars.empty();
  for (std::size_t i = 0; same && i < x.bars.bars.size(); ++i)
    same = std::memcmp(&x.bars.bars[i].a, &y.bars.bars[i].a, sizeof(Vec3)) == 0 &&
           std::memcmp(&x.bars.bars[i].b, &y.bars.bars[i].b, sizeof(Vec3)) == 0;
  std::printf("no weave region: lay %zu cells %zu bars, lay_organic the same %d\n", x.layout.cells.size(), x.bars.bars.size(), same ? 1 : 0);
  CHECK(same);
}

// F (S1c, the file job's shallow-bar table): a WHOLE run is counted once, at its full length, not as its pieces.
// The field forces one long level run across the pocket: 10 MPa along x, and in the y-z plane 3 and 1 MPa along the two
// diagonals at 45 degrees, the same everywhere. The x family is the only one lying level (the two diagonal families
// rise at 45 degrees, steeper than 30), so its curves cross the pocket under its floor as straight level lines, and
// the diagonal curves that cross them cut each into pieces at joints where exactly two shallow bars (the line's two
// pieces) meet in line. At 5 mm spacing the line at z 14.75 (y 7.75, from x 11.3 to 28.7, ending in the solid on both
// sides) is made of several pieces; the table holds it as ONE run of the line's whole length, in the 10 to 20 band.
static TensorField diagonal_field() {
  TensorField f;
  f.spacing = 0.5;
  f.nx = 80; f.ny = 28; f.nz = 40;
  f.voigt.assign(6 * static_cast<std::size_t>(f.nx) * f.ny * f.nz, 0.0);
  for (std::size_t e = 0; e < static_cast<std::size_t>(f.nx) * f.ny * f.nz; ++e) {
    f.voigt[6 * e + 0] = 10.0;   // xx
    f.voigt[6 * e + 1] = 2.0;    // yy = 3 c^2 + 1 s^2, c = s = sqrt(1/2)
    f.voigt[6 * e + 2] = 2.0;    // zz
    f.voigt[6 * e + 4] = 1.0;    // yz = (3 - 1) c s
  }
  return f;
}
static void test_whole_run() {
  const StepModel model = pocket_block();
  Session session(model);
  const TensorField field = diagonal_field();
  const OrganicAsk ask{5.0, 0.9, {0, 0, 1}};
  const Outcome out = session.lay_organic(pocket_settings(), field, ask);
  const Domain& d = *session.domain();
  const std::vector<Strand> strands = trace_strands(d, 1, field, ask);
  // The line: the traced level strand at z 14.75 across the pocket (straightened to its two ends).
  const Strand* line = nullptr;
  for (const Strand& x : strands)
    if (x.points.size() == 2 && x.points[0].z == x.points[1].z && std::fabs(x.points[0].z - 14.75) < 1e-9 &&
        dist(x.points[0], x.points[1]) > 15.0)
      line = &x;
  CHECK(line != nullptr);
  if (!line) return;
  // Its pieces: the shallow bars lying along it (both ends within half a millimetre of it).
  int pieces = 0;
  double along = 0.0, longest_piece = 0.0, longest_bar = 0.0;
  for (const Bar& b : out.bars.bars) {
    if (b.region != 1 || !bar_is_bridge(b)) continue;
    longest_bar = std::max(longest_bar, bar_length(b));
    if (to_segment(b.a, line->points[0], line->points[1]) > 0.5 || to_segment(b.b, line->points[0], line->points[1]) > 0.5) continue;
    ++pieces;
    along += bar_length(b);
    longest_piece = std::max(longest_piece, bar_length(b));
  }
  // The table, with what the layer check did (the file made as the file job makes it).
  const OpenSpace open = read_open_space(d, out.layout, 0.25);
  PrintableReport rep;
  const TriangleMesh mesh = build_printable_mesh(session.measure(), d, out.layout, out.bars, open, PrintableSpec{}, &rep);
  CHECK(rep.mesh.ok && !mesh.empty());
  const ShallowTable t = shallow_bar_table(out.bars, {1}, rep.drop_at, rep.posts);
  std::printf("whole run: the level line across the pocket is %.4f mm, laid as %d pieces (longest %.4f) totalling %.4f mm; the table's "
              "longest run %.4f mm\n", dist(line->points[0], line->points[1]), pieces, longest_piece, along, t.longest_run_mm);
  std::printf("whole run table: %zu shallow bars (held both %zu, one %zu, none %zu); %zu runs, longest %.4f mm\n", t.bars, t.held_both,
              t.held_one, t.held_none, t.runs, t.longest_run_mm);
  const char* names[4] = {"to 5 mm", "5 to 10", "10 to 20", "over 20"};
  for (int k = 0; k < 4; ++k)
    std::printf("  %-8s %3zu runs: kept %zu, left out %zu, post %zu\n", names[k], t.bands[k].runs, t.bands[k].kept, t.bands[k].left_out,
                t.bands[k].post);
  CHECK(pieces >= 3 && std::fabs(along - dist(line->points[0], line->points[1])) < 0.01);   // in pieces, the whole line
  CHECK(std::fabs(t.longest_run_mm - along) < 1e-9);     // ONE run, the line's whole length
  CHECK(t.longest_run_mm > longest_bar + 5.0);          // not any of its pieces, nor any other single bar
  CHECK(t.bands[2].runs >= 1 && t.bands[3].runs == 0);  // 10 to 20 mm
  CHECK(t.runs < t.bars);
  std::size_t banded = 0;
  for (const ShallowTable::Band& b : t.bands) {
    banded += b.runs;
    CHECK(b.kept + b.left_out + b.post == b.runs);
  }
  CHECK(banded == t.runs && t.held_both + t.held_one + t.held_none == t.bars);
}

// G (O12): the spacing is a range that follows the stress.
// G1: the range with both ends at 4 mm gives stage 1b's strands (one spacing of 4 mm) to the bit.
static bool same_strands(const std::vector<Strand>& x, const std::vector<Strand>& y) {
  bool same = x.size() == y.size() && !x.empty();
  for (std::size_t k = 0; same && k < x.size(); ++k) {
    same = x[k].points.size() == y[k].points.size() && x[k].width_mm == y[k].width_mm && x[k].region == y[k].region &&
           x[k].spacing_mm == y[k].spacing_mm;
    for (std::size_t i = 0; same && i < x[k].points.size(); ++i)
      same = std::memcmp(&x[k].points[i], &y[k].points[i], sizeof(Vec3)) == 0;
  }
  return same;
}
static void test_range_equal_ends() {
  Block b;
  OrganicAsk range = b.ask;
  range.spacing_mm = 0.0;
  range.spacing_min_mm = range.spacing_max_mm = 4.0;
  OrganicTraceStats st;
  const std::vector<Strand> one = trace_strands(b.d, 1, b.field, b.ask), two = trace_strands(b.d, 1, b.field, range, &st);
  const bool same = same_strands(one, two);
  std::printf("range 4 to 4: %zu strands, the same as one spacing of 4 mm %d; spacing used %.4f to %.4f, mean %.4f\n", two.size(),
              same ? 1 : 0, st.spacing_smallest_mm, st.spacing_largest_mm, st.spacing_mean_mm);
  CHECK(same);
  CHECK(st.candidates == 12u * 12u * 24u && st.spacing_smallest_mm == 4.0 && st.spacing_largest_mm == 4.0);
  // The ask refuses a range that is not one.
  auto refuses = [&](double lo, double hi, double e) {
    OrganicAsk a = range;
    a.spacing_min_mm = lo; a.spacing_max_mm = hi; a.spacing_exponent = e;
    try { (void)organic_spacing(b.d, 1, b.field, a); } catch (const std::invalid_argument&) { return true; }
    return false;
  };
  CHECK(refuses(0.0, 8.0, 1.0) && refuses(5.0, 4.0, 1.0) && refuses(3.0, 8.0, 0.0) && !refuses(3.0, 8.0, 1.0));
}

// G2, G3: a 48 x 12 x 12 mm block, all of it one weave region, under a stress that rises along x from almost nothing
// at x = 0 to 24 MPa at x = 48 (sxx = s, syy = 0.3 s, szz = 0.1 s; von Mises 0.8888 s). The range 3 to 8, exponent 1,
// the reference the region's 95th percentile. The spacing asked is the old run's law (O12, corrected 2026-11-15): 8 at
// the quietest slice (x = 0), 3 over the last twentieth (at or over the reference), and the strands are closer together
// at the hot end: more of them cross a plane square to x there than at the cold end. The shape fit (O13) is OFF here:
// on this 12 mm thick block its member-width cap (12 / 5 = 2.4 mm, held to 3) would make every voxel 3 mm; G4 and G5
// test it.
static std::vector<double> old_run_spacing(const VoxelGrid& grid, const std::vector<double>& density,
                                           const std::vector<double>& vm, const std::vector<char>& region, double gamma,
                                           double cell_min, double cell_max, bool shape_fit);
struct Ramp {
  PartMeasure pm{weld_mesh(box(48, 12, 12))};
  Domain d{pm, [] {
             DomainSpec s;
             s.regions = {face_region(1, {24, 6, 0}, {0, 0, 1}, 6, 24, 12)};
             s.regions[0].weave = true;
             return s;
           }()};
  TensorField field;
  OrganicAsk ask;
  Ramp() {
    field.nx = 48; field.ny = 12; field.nz = 12;
    field.spacing = 1.0;
    field.voigt.assign(6 * 48 * 12 * 12, 0.0);
    for (int k = 0; k < 12; ++k)
      for (int j = 0; j < 12; ++j)
        for (int i = 0; i < 48; ++i) {
          const double sv = 24.0 * (i + 0.5) / 48.0;
          double* v = &field.voigt[6 * field.index(i, j, k)];
          v[0] = sv; v[1] = 0.3 * sv; v[2] = 0.1 * sv;
        }
    ask.width_mm = 0.9;   // spacing_mm 0: the range, 3 to 8 by default
    ask.shape_fit = false;
  }
};
static void test_range_ramp() {
  Ramp r;
  CHECK(r.ask.spacing_mm == 0.0 && r.ask.spacing_min_mm == 3.0 && r.ask.spacing_max_mm == 8.0 && r.ask.spacing_exponent == 1.0);
  const OrganicSpacing sp = organic_spacing(r.d, 1, r.field, r.ask);
  // The spacing asked, per slice of x (every voxel of a slice the same).
  std::vector<double> slice(48, 0.0);
  bool flat = true;
  for (int i = 0; i < 48; ++i) {
    slice[static_cast<std::size_t>(i)] = sp.spacing_mm[r.field.index(i, 0, 0)];
    for (int k = 0; k < 12; ++k)
      for (int j = 0; j < 12; ++j) flat = flat && sp.spacing_mm[r.field.index(i, j, k)] == slice[static_cast<std::size_t>(i)];
  }
  bool falls = true;
  for (int i = 1; i < 48; ++i) falls = falls && slice[static_cast<std::size_t>(i)] <= slice[static_cast<std::size_t>(i - 1)];
  const double vm_at = [&](int i) { return 0.888819442 * 24.0 * (i + 0.5) / 48.0; }(0);
  std::printf("ramp: reference %.4f MPa (95th percentile); spacing asked at x 0.5 %.4f, 12.5 %.4f, 24.5 %.4f, 36.5 %.4f, 44.5 %.4f, "
              "47.5 %.4f; von Mises at x 0.5 %.4f\n", sp.reference_mpa, slice[0], slice[12], slice[24], slice[36], slice[44], slice[47],
              vm_at);
  CHECK(sp.candidates == 48u * 12u * 12u && flat && falls);
  CHECK(slice[0] == 8.0 && slice[47] == 3.0 && slice[46] == 3.0);
  // The law itself: the old run's field (as G4 makes it: grade_lattice, then run_organic_step's arithmetic), to 1e-6.
  VoxelGrid grid;
  grid.nx = 48; grid.ny = 12; grid.nz = 12; grid.spacing = 1.0;
  grid.tags.assign(48 * 12 * 12, VoxelTag::Interior);
  std::vector<double> part(grid.tags.size(), 1.0), vms(grid.tags.size(), 0.0);
  const std::vector<char> all(grid.tags.size(), 1);
  for (std::size_t e = 0; e < vms.size(); ++e) {
    const double* t = &r.field.voigt[6 * e];
    const double a = t[0] - t[1], b = t[1] - t[2], c = t[2] - t[0];
    vms[e] = std::sqrt(0.5 * (a * a + b * b + c * c));
  }
  const std::vector<double> old = old_run_spacing(grid, part, vms, all, 1.0, 3.0, 8.0, false);
  for (int i : {0, 12, 24, 36})
    CHECK(std::fabs(slice[static_cast<std::size_t>(i)] - old[r.field.index(i, 0, 0)]) < 1e-6);
  // The trace: the spacing it used, and the strands at the two ends.
  OrganicTraceStats st;
  const std::vector<Strand> strands = trace_strands(r.d, 1, r.field, r.ask, &st);
  // Across two slices, one at each end (x 0 to 12, x 36 to 48): the strands crossing the slice's middle plane square
  // to y (y = 6) and square to z (z = 6) within it. Strands that run along x, the first family, cross both ends alike.
  auto crossings = [&](double x0, double x1) {
    std::size_t c = 0;
    for (const Strand& s : strands)
      for (std::size_t q = 0; q + 1 < s.points.size(); ++q) {
        const Vec3 &a = s.points[q], &b = s.points[q + 1];
        for (int axis : {1, 2}) {
          const double ua = axis == 1 ? a.y : a.z, ub = axis == 1 ? b.y : b.z;
          if ((ua - 6.0) * (ub - 6.0) >= 0.0) continue;
          const double t = (6.0 - ua) / (ub - ua), x = a.x + (b.x - a.x) * t;
          c += x >= x0 && x < x1;
        }
      }
    return c;
  };
  const std::size_t cold = crossings(0.0, 12.0), hot = crossings(36.0, 48.0);
  std::printf("ramp traced: %zu strands; spacing used %.4f to %.4f, mean %.4f; strands across the cold slice %zu, the hot slice %zu\n",
              strands.size(), st.spacing_smallest_mm, st.spacing_largest_mm, st.spacing_mean_mm, cold, hot);
  CHECK(st.spacing_smallest_mm == 3.0 && st.spacing_largest_mm > 7.9 && st.spacing_mean_mm > 3.0 && st.spacing_mean_mm < 8.0);
  CHECK(cold > 0 && hot >= 2 * cold);
  // The strands' own spacing: the smallest under their points, so the strands at the hot end carry the tight end.
  double hot_strand = 1e9, cold_strand = 0.0;
  for (const Strand& s : strands) {
    bool all_hot = true, all_cold = true;
    for (const Vec3& p : s.points) { all_hot = all_hot && p.x > 44.0; all_cold = all_cold && p.x < 4.0; }
    if (all_hot) hot_strand = std::min(hot_strand, s.spacing_mm);
    if (all_cold) cold_strand = std::max(cold_strand, s.spacing_mm);
  }
  CHECK(hot_strand == 3.0 && cold_strand > 7.0);
}

// G4 (O12, O13): the field equals the old run's own, to 1e-6, on a made-up block. The old law, called as the old run
// calls it: grade_lattice (Aesthetic, organic geometry, the job's demand exponent) for the density, then
// run_organic_step's arithmetic as it stands in run_job.cpp (it sits in a file of its own and cannot be called): the
// stretch over the latticed voxels, f^2 (minimize_plastic on), the window line, and its shape fit (2 x the steps to the
// nearest voxel not latticed, the member width over 5, held to cell_min). The block is 24 x 16 x 20 mm on a grid with
// 2 mm of air round it; the weave is under its top face, 14 mm deep (6 mm of solid floor); the stress varies in all
// three axes and is nowhere zero.
static std::vector<double> old_run_spacing(const VoxelGrid& grid, const std::vector<double>& density,
                                           const std::vector<double>& vm, const std::vector<char>& region, double gamma,
                                           double cell_min, double cell_max, bool shape_fit) {
  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.cell_mode = CellSizeMode::Fixed;
  gp.target_cell_size_mm = cell_min;
  gp.min_extrudable_width_mm = 0.9;
  gp.demand_exponent = gamma;
  gp.organic_geometry = true;
  gp.intent = GradingIntent::Aesthetic;
  const GradedField gf = grade_lattice(grid, density, vm, &region, gp, 0.5);
  const std::vector<char>& lattice_mask = gf.posture.mask;
  const std::vector<double>& relative_density = gf.posture.relative_density;
  const std::size_t n = grid.voxel_count();
  // run_organic_step, with a window and minimize_plastic on:
  double rho_lo = 0.0, rho_hi = 0.0;
  bool any_rho = false;
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const double r = relative_density[e];
    if (!any_rho) { rho_lo = rho_hi = r; any_rho = true; }
    rho_lo = std::min(rho_lo, r);
    rho_hi = std::max(rho_hi, r);
  }
  const double rho_span = rho_hi - rho_lo;
  const double f_exponent = kAestheticOpenExponent;
  std::vector<char> cand(n, 0);
  std::vector<double> spacing(n, 0.0);
  for (std::size_t e = 0; e < n; ++e) {
    if (!lattice_mask[e]) continue;
    const double rho = relative_density[e];
    if (!(rho > 0.0)) continue;
    double f = rho_span > 0.0 ? (rho - rho_lo) / rho_span : 0.0;
    f = std::pow(std::min(1.0, std::max(0.0, f)), f_exponent);
    const double d = cell_max - (cell_max - cell_min) * f;
    if (!(d > 0.0)) continue;
    cand[e] = 1;
    spacing[e] = d;
  }
  if (!shape_fit) return spacing;
  const std::vector<double> width = local_member_thickness_mm(grid, density, 0.5, 32);
  const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
  const int nx = grid.nx, ny = grid.ny, nz = grid.nz;
  const long long BIG = 1LL << 30;
  std::vector<long long> dist(n, BIG);
  auto at = [&](int i, int j, int k) { return (static_cast<std::size_t>(k) * ny + j) * nx + i; };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = at(i, j, k);
        if (!cand[e]) { dist[e] = 0; continue; }
        if (i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1) dist[e] = 1;
      }
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = at(i, j, k);
        if (i) dist[e] = std::min(dist[e], dist[at(i - 1, j, k)] + 1);
        if (j) dist[e] = std::min(dist[e], dist[at(i, j - 1, k)] + 1);
        if (k) dist[e] = std::min(dist[e], dist[at(i, j, k - 1)] + 1);
      }
  for (int k = nz - 1; k >= 0; --k)
    for (int j = ny - 1; j >= 0; --j)
      for (int i = nx - 1; i >= 0; --i) {
        const std::size_t e = at(i, j, k);
        if (i + 1 < nx) dist[e] = std::min(dist[e], dist[at(i + 1, j, k)] + 1);
        if (j + 1 < ny) dist[e] = std::min(dist[e], dist[at(i, j + 1, k)] + 1);
        if (k + 1 < nz) dist[e] = std::min(dist[e], dist[at(i, j, k + 1)] + 1);
      }
  for (std::size_t e = 0; e < n; ++e) {
    if (!cand[e]) continue;
    const double w = width[e];
    const double cap_member = (w > 0.0 && std::isfinite(w)) ? w / n_star : std::numeric_limits<double>::infinity();
    const double cap_boundary = 2.0 * static_cast<double>(dist[e]) * grid.spacing;
    double cap = std::min(cap_member, cap_boundary);
    if (cap < cell_min) cap = cell_min;
    if (!(cap > 0.0) || !(cap < spacing[e])) continue;
    spacing[e] = cap;
  }
  return spacing;
}
static void test_old_law_block() {
  PartMeasure pm{weld_mesh(box(24, 16, 20))};
  Domain d{pm, [] {
             DomainSpec s;
             s.regions = {face_region(1, {12, 8, 20}, {0, 0, -1}, 12, 8, 14)};
             s.regions[0].weave = true;
             return s;
           }()};
  TensorField field;
  field.origin = {-2, -2, -2};
  field.spacing = 1.0;
  field.nx = 28; field.ny = 20; field.nz = 24;
  const std::size_t n = 28u * 20u * 24u;
  field.voigt.assign(6 * n, 0.0);
  VoxelGrid grid;
  grid.nx = field.nx; grid.ny = field.ny; grid.nz = field.nz; grid.spacing = 1.0; grid.origin = field.origin;
  grid.tags.assign(n, VoxelTag::Interior);
  std::vector<double> density(n, 0.0), vm(n, 0.0);
  std::vector<char> region(n, 0);
  auto pr = d.probe();
  std::size_t in_region = 0;
  for (int k = 0; k < field.nz; ++k)
    for (int j = 0; j < field.ny; ++j)
      for (int i = 0; i < field.nx; ++i) {
        const Vec3 c = grid.voxel_center(i, j, k);
        const std::size_t e = field.index(i, j, k);
        double* v = &field.voigt[6 * e];
        v[0] = 2.0 + 0.04 * c.x * c.x;
        v[1] = 3.0 * std::sin(0.3 * c.y) * std::sin(0.3 * c.y);
        v[2] = 0.15 * c.z * c.x / 24.0;
        v[3] = 0.05 * c.z;
        v[4] = 0.02 * c.x * c.y / 10.0;
        const double a = v[0] - v[1], b = v[1] - v[2], cc = v[2] - v[0];
        vm[e] = std::sqrt(0.5 * (a * a + b * b + cc * cc) + 3.0 * (v[3] * v[3] + v[4] * v[4] + v[5] * v[5]));
        const Where w = pr.where(c);
        density[e] = w.why != Why::Outside ? 1.0 : 0.0;
        if (w.lattice() && w.id == 1) { region[e] = 1; ++in_region; }
      }
  for (const double gamma : {1.0, 1.5})
    for (const bool fit : {true, false}) {
      OrganicAsk ask;
      ask.spacing_exponent = gamma;
      ask.shape_fit = fit;
      const OrganicSpacing sp = organic_spacing(d, 1, field, ask);
      const std::vector<double> old = old_run_spacing(grid, density, vm, region, gamma, 3.0, 8.0, fit);
      double worst = 0.0, sum = 0.0, lo = 1e9, hi = 0.0;
      std::size_t both = 0, one_only = 0;
      for (std::size_t e = 0; e < n; ++e) {
        const bool a = sp.candidate[e] != 0, b = old[e] > 0.0;
        if (a != b) { ++one_only; continue; }
        if (!a) continue;
        ++both;
        const double diff = std::fabs(sp.spacing_mm[e] - old[e]);
        worst = std::max(worst, diff);
        sum += diff;
        lo = std::min(lo, old[e]);
        hi = std::max(hi, old[e]);
      }
      std::printf("old law, demand exponent %.1f, shape fit %d: %zu voxels in both (%zu in one only), old field %.4f to %.4f; "
                  "largest difference %.3g mm, mean %.3g; shape fit tightened %zu\n", gamma, fit ? 1 : 0, both, one_only, lo, hi,
                  worst, both ? sum / static_cast<double>(both) : 0.0, sp.shape_fit_tightened);
      CHECK(both == in_region && in_region > 0 && one_only == 0);
      CHECK(worst <= 1e-6);
      // the old law reaches both ends; with the fit, this 16 mm wide member (W / 5 = 3.2 mm) holds nothing wider
      CHECK(lo == 3.0 && (fit ? hi < 8.0 : hi == 8.0));
      CHECK(fit ? sp.shape_fit_tightened > 0 : sp.shape_fit_tightened == 0);
    }
}

// G5 (O13): the shape fit tightens the spacing toward the weave's outline, over a band of half the spacing, and
// leaves the middle alone. A 32 mm cube, all of it one weave region, with no stress (every voxel at the widest), the
// range 3 to 5, a grid with 2 mm of air round it. Along the line in from the top face's middle: 3 (one step from the
// outline: 2 mm, held to 3), 4 (two steps), then 5 (three steps give 6: no cap). The middle 20 mm (three steps or more
// from every face) stays at 5; nothing is ever wider than with the fit off, nor under 3.
static void test_shape_fit() {
  PartMeasure pm{weld_mesh(box(32, 32, 32))};
  Domain d{pm, [] {
             DomainSpec s;
             s.regions = {face_region(1, {16, 16, 32}, {0, 0, -1}, 16, 16, 32)};
             s.regions[0].weave = true;
             return s;
           }()};
  TensorField field;
  field.origin = {-2, -2, -2};
  field.spacing = 1.0;
  field.nx = field.ny = field.nz = 36;
  field.voigt.assign(6u * 36u * 36u * 36u, 0.0);
  OrganicAsk ask;
  ask.spacing_min_mm = 3.0;
  ask.spacing_max_mm = 5.0;
  CHECK(ask.shape_fit);   // on when not asked
  const OrganicSpacing on = organic_spacing(d, 1, field, ask);
  ask.shape_fit = false;
  const OrganicSpacing off = organic_spacing(d, 1, field, ask);
  std::size_t wider = 0, under = 0, middle_moved = 0, middle = 0, tightened = 0;
  for (int k = 0; k < 36; ++k)
    for (int j = 0; j < 36; ++j)
      for (int i = 0; i < 36; ++i) {
        const std::size_t e = field.index(i, j, k);
        if (!on.candidate[e]) continue;
        wider += on.spacing_mm[e] > off.spacing_mm[e];
        under += on.spacing_mm[e] < 3.0;
        tightened += on.spacing_mm[e] < off.spacing_mm[e];
        const bool mid = i >= 8 && i <= 27 && j >= 8 && j <= 27 && k >= 8 && k <= 27;
        middle += mid;
        middle_moved += mid && on.spacing_mm[e] != 5.0;
      }
  const double top1 = on.spacing_mm[field.index(18, 18, 33)], top2 = on.spacing_mm[field.index(18, 18, 32)],
               top3 = on.spacing_mm[field.index(18, 18, 31)], top4 = on.spacing_mm[field.index(18, 18, 30)];
  std::printf("shape fit, 32 mm cube, no stress, 3 to 5: in from the top %.4f %.4f %.4f %.4f; tightened %zu of %zu; middle %zu, "
              "moved %zu; wider than off %zu, under 3 %zu\n", top1, top2, top3, top4, tightened, on.candidates, middle,
              middle_moved, wider, under);
  CHECK(off.candidates == 32u * 32u * 32u && on.candidates == off.candidates);
  for (std::size_t e = 0; e < off.spacing_mm.size(); ++e)
    if (off.candidate[e] && off.spacing_mm[e] != 5.0) { CHECK(false); break; }
  CHECK(top1 == 3.0 && top2 == 4.0 && top3 == 5.0 && top4 == 5.0);
  CHECK(middle == 20u * 20u * 20u && middle_moved == 0);
  CHECK(wider == 0 && under == 0 && tightened == on.shape_fit_tightened && tightened > 0 && off.shape_fit_tightened == 0);
}

// G6: with the shape fit on (as by default), the range 4 to 4 still gives stage 1b's strands, to the bit.
static void test_range_equal_ends_fit() {
  Block b;
  OrganicAsk range = b.ask;
  range.spacing_mm = 0.0;
  range.spacing_min_mm = range.spacing_max_mm = 4.0;
  range.shape_fit = true;
  const OrganicSpacing sp = organic_spacing(b.d, 1, b.field, range);
  CHECK(sp.shape_fit_tightened == 0);
  CHECK(same_strands(trace_strands(b.d, 1, b.field, b.ask), trace_strands(b.d, 1, b.field, range)));
}

int main() {
  test_traced_block();
  test_traced_repeat();
  test_no_weave_is_lay();
  test_traced_pocket_and_file();
  test_whole_run();
  test_range_equal_ends();
  test_range_ramp();
  test_old_law_block();
  test_shape_fit();
  test_range_equal_ends_fit();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
