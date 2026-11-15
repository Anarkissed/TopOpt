// Organic, Grown (rules G1 to G12): the owner's Grown placement, written new in the new engine (grow_strands), on
// made-up parts and made-up stress fields. Numbered as in docs/design/lattice-rebuild/02-tests.md, section 11 (G).
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_file.hpp"
#include "topopt/lattice_layout_mesh.hpp"
#include "topopt/lattice_layout_organic.hpp"
#include "topopt/stl.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

#ifndef ORGANIC_GROWN_TMP_DIR
#define ORGANIC_GROWN_TMP_DIR "."
#endif

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                                              \
  do {                                                                                           \
    ++g_checks;                                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); }   \
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
// Points every `step` mm along a polyline (its vertices included).
static std::vector<Vec3> samples(const std::vector<Vec3>& line, double step) {
  std::vector<Vec3> out;
  for (std::size_t i = 0; i + 1 < line.size(); ++i) {
    const Vec3 a = line[i], b = line[i + 1];
    const int n = std::max(1, static_cast<int>(std::ceil(dist(a, b) / step)));
    for (int k = 0; k < n; ++k) out.push_back({a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n, a.z + (b.z - a.z) * k / n});
  }
  if (!line.empty()) out.push_back(line.back());
  return out;
}
static void box_of(const std::vector<Vec3>& l, Vec3& lo, Vec3& hi) {
  lo = hi = l.front();
  for (const Vec3& p : l) {
    lo = {std::min(lo.x, p.x), std::min(lo.y, p.y), std::min(lo.z, p.z)};
    hi = {std::max(hi.x, p.x), std::max(hi.y, p.y), std::max(hi.z, p.z)};
  }
}
static double strand_mm(const Strand& s) {
  double m = 0.0;
  for (std::size_t i = 0; i + 1 < s.points.size(); ++i) m += dist(s.points[i], s.points[i + 1]);
  return m;
}

// A closed mesh of the union of 1 mm cubes (i, j, k) for which `filled` says so: the faces between filled and empty.
static TriangleMesh cubes_mesh(int nx, int ny, int nz, const std::function<bool(int, int, int)>& filled) {
  MeshSink s;
  auto in = [&](int i, int j, int k) {
    return i >= 0 && j >= 0 && k >= 0 && i < nx && j < ny && k < nz && filled(i, j, k);
  };
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        if (!in(i, j, k)) continue;
        const double x0 = i, x1 = i + 1, y0 = j, y1 = j + 1, z0 = k, z1 = k + 1;
        auto quad = [&](Vec3 a, Vec3 b, Vec3 c, Vec3 d) { s.add_triangle(a, b, c); s.add_triangle(a, c, d); };
        if (!in(i - 1, j, k)) quad({x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0});
        if (!in(i + 1, j, k)) quad({x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}, {x1, y0, z1});
        if (!in(i, j - 1, k)) quad({x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1});
        if (!in(i, j + 1, k)) quad({x0, y1, z0}, {x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0});
        if (!in(i, j, k - 1)) quad({x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}, {x1, y0, z0});
        if (!in(i, j, k + 1)) quad({x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1});
      }
  return s.mesh;
}
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
// A box as an imported model: six flat faces, numbered 0 bottom, 1 top, 2..5 the sides (the file test's own).
static StepModel box_model(double x, double y, double z) {
  StepModel m;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (const int* t : {&q[f][0], &q[f][1]}) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      const bool second = t != &q[f][0];
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][second ? 2 : 1]], p[q[f][second ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  m.brep_volume = x * y * z;
  return m;
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
using Field = std::function<std::array<double, 6>(const Vec3&)>;
static TensorField make_field(int nx, int ny, int nz, const Field& f) {
  TensorField t;
  t.nx = nx; t.ny = ny; t.nz = nz;
  t.spacing = 1.0;
  t.voigt.assign(6 * static_cast<std::size_t>(nx) * ny * nz, 0.0);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::array<double, 6> s = f(Vec3{i + 0.5, j + 0.5, k + 0.5});
        for (int c = 0; c < 6; ++c) t.voigt[6 * t.index(i, j, k) + static_cast<std::size_t>(c)] = s[static_cast<std::size_t>(c)];
      }
  return t;
}
// Uniaxial stress `s` along the unit direction d: sigma = s d d^T.
static std::array<double, 6> along(Vec3 d, double s) {
  const double l = std::hypot(d.x, std::hypot(d.y, d.z));
  d = {d.x / l, d.y / l, d.z / l};
  return {s * d.x * d.x, s * d.y * d.y, s * d.z * d.z, s * d.x * d.y, s * d.y * d.z, s * d.z * d.x};
}

// A block X x Y x Z on the bed, a solid floor `floor` mm thick, all above it one weave region (under the top face).
struct Part {
  PartMeasure pm;
  Domain d;
  TensorField field;
  OrganicAsk ask;
  double X, Y, Z, floor;
  Part(const TriangleMesh& mesh, double x, double y, double z, double fl, const Field& f, double inset = 0.0)
      : pm(weld_mesh(mesh)),
        d(pm,
          [&] {
            DomainSpec s;
            s.bead_mm = 0.45;
            s.min_strut_lines = 2.0;
            s.regions = {face_region(1, {x / 2, y / 2, z}, {0, 0, -1}, x / 2 - inset, y / 2 - inset, z - fl)};
            s.regions[0].weave = true;
            return s;
          }()),
        X(x), Y(y), Z(z), floor(fl) {
    field = make_field(static_cast<int>(x), static_cast<int>(y), static_cast<int>(z), f);
    ask.mode = OrganicMode::Grown;
    ask.spacing_min_mm = 3.0;
    ask.spacing_max_mm = 8.0;
    ask.width_mm = 0.9;
    ask.layer_mm = 0.2;
  }
};

static void print_report(const char* what, const GrowReport& g) {
  std::printf("%s: %zu strands (%zu grown); seeds floor %zu wall %zu, refused room %zu support %zu; steps %zu, clamped %zu; "
              "ended edge %zu unsupported %zu joined %zu; climbed on crowded %zu\n",
              what, g.strands, g.strands_grown, g.seeds_floor, g.seeds_wall, g.seeds_refused_room, g.seeds_refused_support,
              g.steps, g.clamped, g.ended_edge, g.ended_unsupported, g.ended_joined, g.crowded_climbed_on);
  std::printf("  branches offered %zu grown %zu links %zu, refused region %zu support %zu crowded %zu room %zu; rewinds %zu at %zu "
              "places: grew on %zu, joined %zu, ended on a joint %zu (taken back %.1f mm)\n",
              g.branches_offered, g.branches_grown, g.links, g.refused_region, g.refused_support, g.refused_crowded,
              g.refused_room, g.rewinds, g.rewind_places, g.rewind_grew_on, g.rewind_joined, g.rewind_ended_on_joint,
              g.taken_back_mm);
  std::printf("  thinned %zu (joined %zu); regrow rounds %zu, holes %zu, landed %zu, failed %zu; ties seeded %zu laid %zu, "
              "refused minor %zu reach %zu support %zu\n",
              g.thinned, g.thinned_joined, g.regrow_rounds, g.holes, g.regrow_landed, g.regrow_failed, g.ties_seeded,
              g.ties_laid, g.ties_refused_minor, g.ties_refused_reach, g.ties_refused_support);
  std::printf("  grown %.1f mm, kept %.1f mm; cut: outside %.1f, unsupported %.1f, leads to nothing %.1f, crowded %.1f, "
              "repeat %.1f; %.0f ms\n",
              g.grown_mm, g.kept_mm, g.cut_outside_mm, g.cut_unsupported_mm, g.cut_nothing_mm, g.cut_crowded_mm,
              g.cut_repeat_mm, g.ms);
}

// The strands returned are straightened (P9: each point within 0.25 x the radius, 0.1125 mm at 0.9 mm, of its line), so
// two of them may come that much nearer each other than they grew, each.
static constexpr double kStraightened = 2.0 * 0.25 * 0.45;
// The closest two different strands come, away from any joint of the two (a place within `lower` of where they touch,
// within `touch`); the smallest such gap and how many places are under `lower`.
struct Gaps {
  double smallest = 1e300;     // between any two strands, away from joints
  std::size_t under = 0;       // sample places under the lower limit, away from joints
  std::vector<double> nearest; // per strand: its nearest neighbour, away from joints
};
static Gaps gaps(const std::vector<Strand>& ss, double lower, double touch) {
  Gaps g;
  g.nearest.assign(ss.size(), 1e300);
  std::vector<std::vector<Vec3>> sm(ss.size());
  std::vector<Vec3> lo(ss.size()), hi(ss.size());
  for (std::size_t i = 0; i < ss.size(); ++i) {
    sm[i] = samples(ss[i].points, 0.1);
    box_of(ss[i].points, lo[i], hi[i]);
  }
  const double reach = 2.0 * 8.0;
  for (std::size_t a = 0; a < ss.size(); ++a)
    for (std::size_t b = 0; b < ss.size(); ++b) {
      if (a == b) continue;
      if (lo[a].x > hi[b].x + reach || lo[b].x > hi[a].x + reach || lo[a].y > hi[b].y + reach ||
          lo[b].y > hi[a].y + reach || lo[a].z > hi[b].z + reach || lo[b].z > hi[a].z + reach)
        continue;
      std::vector<double> d(sm[a].size());
      for (std::size_t k = 0; k < sm[a].size(); ++k) d[k] = to_polyline(sm[a][k], ss[b].points);
      for (std::size_t k = 0; k < sm[a].size(); ++k) {
        bool joint = false;
        for (std::size_t m = 0; m < sm[a].size() && !joint; ++m)
          joint = d[m] < touch && dist(sm[a][m], sm[a][k]) <= lower;
        if (joint) continue;
        g.nearest[a] = std::min(g.nearest[a], d[k]);
        g.smallest = std::min(g.smallest, d[k]);
        if (d[k] < lower - kStraightened) ++g.under;
      }
    }
  return g;
}

// Every strand rises at the cone or steeper on every segment, except a segment that ends on another strand (a join
// or a link: a bridge held at both ends).
static std::size_t flatter_than_cone(const std::vector<Strand>& ss) {
  std::size_t n = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    for (std::size_t k = 0; k + 1 < ss[i].points.size(); ++k) {
      const Vec3 a = ss[i].points[k], b = ss[i].points[k + 1];
      const double l = dist(a, b);
      if (l < 1e-9 || (b.z - a.z) / l >= 0.5 - 1e-9) continue;
      bool on_other = false;
      for (std::size_t j = 0; j < ss.size() && !on_other; ++j)
        if (j != i) on_other = to_polyline(b, ss[j].points) < 1e-6 || to_polyline(a, ss[j].points) < 1e-6;
      if (!on_other) ++n;
    }
  return n;
}

// An end is held: in the part's solid or on the part's surface (not lattice of the region a hair away in some
// direction), or on another strand.
static bool end_held(const Domain::Probe& pr, const std::vector<Strand>& ss, std::size_t self, const Vec3& p) {
  const Where w = pr.where(p);
  if (!(w.lattice() && w.id == 1)) return true;
  const Vec3 off[6] = {{0.02, 0, 0}, {-0.02, 0, 0}, {0, 0.02, 0}, {0, -0.02, 0}, {0, 0, 0.02}, {0, 0, -0.02}};
  for (const Vec3& o : off) {
    const Where x = pr.where({p.x + o.x, p.y + o.y, p.z + o.z});
    if (!(x.lattice() && x.id == 1)) return true;
  }
  for (std::size_t j = 0; j < ss.size(); ++j)
    if (j != self && to_polyline(p, ss[j].points) < 1e-6) return true;
  return false;
}

// Re-pinned 2026-11-15 (LatticeReview's ruling 1): these tests were written for the first spacing law, under which a
// uniform stress at reference 2 gave 5.5 mm. Under the corrected O12 a uniform stress gives the WIDEST spacing, and the
// O13 shape fit (on by default) pulls a 24 mm test block toward 3 mm. So the tests that want "5.5 everywhere, lower
// limit 3" ask for it: the range 3 to 5.5 (a uniform stress sits at its wide end) and the fit off.
static void at_5_5(OrganicAsk& a) {
  a.spacing_max_mm = 5.5;
  a.shape_fit = false;
}

// ── G1 to G4: a block under uniform upward stress ────────────────────────────
static void test_uniform_block() {
  Part b(box(24, 24, 30), 24, 24, 30, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;   // spacing 5.5 everywhere (at_5_5), the window's lower limit 3
  at_5_5(b.ask);
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-1 uniform block", rep);
  CHECK(!ss.empty() && rep.seeds_floor > 0);
  // Strands climb: each one's top is above its bottom.
  std::size_t climb = 0;
  for (const Strand& s : ss) climb += s.points.back().z > s.points.front().z + 1.0;
  CHECK(climb == ss.size());
  CHECK(flatter_than_cone(ss) == 0);
  // Every step was supported: every strand starts on the floor (in its solid, or on another strand), and every
  // segment is at the cone or steeper, so each step stands on the one below.
  const Domain::Probe pr = b.d.probe();
  std::size_t started = 0;
  for (std::size_t i = 0; i < ss.size(); ++i) started += ss[i].points.front().z <= 3.0 + 1e-6 || end_held(pr, ss, i, ss[i].points.front());
  CHECK(started == ss.size());
  // Neighbours: no closer than the lower limit (away from joints), no farther than about the local spacing.
  const Gaps g = gaps(ss, 3.0, 0.9);
  double far = 0.0;
  for (double n : g.nearest)
    if (n < 1e299) far = std::max(far, n);
  std::printf("G-1 gaps: smallest %.3f mm, largest nearest-neighbour %.3f mm (window 3 to 8, local spacing 5.5)\n",
              g.smallest, far);
  CHECK(g.under == 0 && g.smallest >= 3.0 - kStraightened);
  CHECK(far <= 1.5 * 5.5 && far > 0.0);
  // No fence at the floor: no two strands start closer than the local spacing.
  std::size_t fence = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    for (std::size_t j = i + 1; j < ss.size(); ++j)
      if (ss[i].points.front().z < 3.5 && ss[j].points.front().z < 3.5 &&
          std::hypot(ss[i].points.front().x - ss[j].points.front().x, ss[i].points.front().y - ss[j].points.front().y) <
              5.5 - 1e-6)
        ++fence;
  CHECK(fence == 0);
  CHECK(rep.seeds_floor <= static_cast<std::size_t>(std::ceil(24.0 / 5.5) * std::ceil(24.0 / 5.5)) + 1);
}

// ── G2, G7: a stress ramp across the block ───────────────────────────────────
static void test_ramp() {
  Part b(box(30, 24, 24), 30, 24, 24, 3, [](const Vec3& p) { return along({0, 0, 1}, p.x / 30.0); });
  b.ask.reference_mpa = 1.0;   // hot end 3 mm, cold end 8 mm
  b.ask.shape_fit = false;     // re-pinned (corrected O12, O13): the fit would pull this 30 mm block toward 3 mm everywhere
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-2 ramp", rep);
  // Strands crossing the middle height, in the hot third against the cold third.
  std::size_t hot = 0, cold = 0;
  for (const Strand& s : ss)
    for (std::size_t k = 0; k + 1 < s.points.size(); ++k) {
      const Vec3 a = s.points[k], c = s.points[k + 1];
      if ((a.z - 13.5) * (c.z - 13.5) > 0.0 || a.z == c.z) continue;
      const double x = a.x + (c.x - a.x) * (13.5 - a.z) / (c.z - a.z);
      hot += x > 20.0;
      cold += x < 10.0;
    }
  std::printf("G-2 strands through z 13.5: hot third %zu, cold third %zu (spacing 3 against 8: about %.1f times as many)\n",
              hot, cold, (8.0 * 8.0) / (3.0 * 3.0));
  CHECK(hot > 0 && hot >= 2 * cold);
}

// ── G5, GR-REWIND: two families driven into each other ───────────────────────
static Part converging() {
  return Part(box(24, 16, 30), 24, 16, 30, 3, [](const Vec3& p) {
    const double s = p.x < 12.0 ? 1.0 : -1.0;
    const double t = 40.0 * 3.14159265358979323846 / 180.0;
    return along({s * std::sin(t), 0.0, std::cos(t)}, 1.0);
  });
}
static void test_rewind() {
  Part b = converging();
  b.ask.reference_mpa = 2.0;   // spacing 5.5 (at_5_5), lower limit 3
  at_5_5(b.ask);
  GrowReport rep, again;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  const std::vector<Strand> s2 = grow_strands(b.d, 1, b.field, b.ask, &again);
  print_report("G-3 converging", rep);
  CHECK(rep.rewinds > 0);
  CHECK(rep.rewind_places == rep.rewind_grew_on + rep.rewind_joined + rep.rewind_ended_on_joint);
  const Gaps g = gaps(ss, 3.0, 0.9);
  std::printf("G-3 after GR-REWIND: smallest gap away from joints %.3f mm, places under 3 mm %zu\n", g.smallest, g.under);
  CHECK(g.under == 0);
  // No loose tail: both ends of every strand are held (solid, the part's surface, or another strand).
  const Domain::Probe pr = b.d.probe();
  std::size_t loose = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    loose += !end_held(pr, ss, i, ss[i].points.front()) + !end_held(pr, ss, i, ss[i].points.back());
  std::printf("G-3 loose ends: %zu of %zu strands' ends\n", loose, 2 * ss.size());
  CHECK(loose == 0);
  // A fixed number of steps: the same on a repeat, and bounded.
  CHECK(again.steps == rep.steps && again.rewinds == rep.rewinds && rep.steps < 200000);
}

// ── G3: a notch a climbing strand would leave ─────────────────────────────────
static void test_notch() {
  // 24 x 24 x 30, a slot of air 4 mm high (z 12 to 16) cut in from the x = 0 side to x = 12, all along y.
  const TriangleMesh m = cubes_mesh(24, 24, 30, [](int i, int, int k) { return !(i < 12 && k >= 12 && k < 16); });
  Part b(m, 24, 24, 30, 3, [](const Vec3&) { return along({-0.3, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-4 notch", rep);
  CHECK(!ss.empty());
  const Domain::Probe pr = b.d.probe();
  std::size_t outside = 0, in_slot = 0;
  for (const Strand& s : ss)
    for (const Vec3& p : samples(s.points, 0.05)) {
      outside += pr.where(p).why == Why::Outside;
      in_slot += p.x < 11.99 && p.z > 12.01 && p.z < 15.99;
    }
  std::printf("G-4 points outside the model: %zu, in the slot: %zu; strands ended at the edge %zu\n", outside, in_slot,
              rep.ended_edge);
  CHECK(outside == 0 && in_slot == 0 && rep.ended_edge > 0);
  std::size_t loose = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    loose += !end_held(pr, ss, i, ss[i].points.front()) + !end_held(pr, ss, i, ss[i].points.back());
  CHECK(loose == 0);
}

// ── G9: the transfer ties ─────────────────────────────────────────────────────
// Every strand stands on something: its lowest point is on the floor, in the part's solid or surface, or on another
// strand (the same test for a tie as for any strut).
static std::size_t unsupported_strands(const Domain::Probe& pr, const std::vector<Strand>& ss) {
  std::size_t n = 0;
  for (std::size_t i = 0; i < ss.size(); ++i) {
    std::size_t low = 0;
    for (std::size_t k = 1; k < ss[i].points.size(); ++k)
      if (ss[i].points[k].z < ss[i].points[low].z) low = k;
    if (!end_held(pr, ss, i, ss[i].points[low])) ++n;
  }
  return n;
}
static void test_ties() {
  // sigma1 along z, sigma2 along x at half of it: the gate (0.10) is met.
  Part b(box(24, 24, 24), 24, 24, 24, 3, [](const Vec3&) { return std::array<double, 6>{0.5, 0.0, 1.0, 0, 0, 0}; });
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  GrowReport on, off;
  const std::vector<Strand> with = grow_strands(b.d, 1, b.field, b.ask, &on);
  print_report("G-5 ties", on);
  CHECK(on.ties_seeded > 0 && on.ties_laid > 0);
  const Domain::Probe pr = b.d.probe();
  const std::size_t bad = unsupported_strands(pr, with);
  std::printf("G-5 ties laid %zu; strands whose lowest point stands on nothing: %zu\n", on.ties_laid, bad);
  CHECK(bad == 0);
  // The gate not met: sigma2 a twentieth of sigma1.
  Part c(box(24, 24, 24), 24, 24, 24, 3, [](const Vec3&) { return std::array<double, 6>{0.05, 0.0, 1.0, 0, 0, 0}; });
  c.ask.reference_mpa = 2.0;
  at_5_5(c.ask);
  grow_strands(c.d, 1, c.field, c.ask, &off);
  CHECK(off.ties_laid == 0 && off.ties_refused_minor > 0);
}

// ── G2 (idea C): walls out ────────────────────────────────────────────────────
static void test_walls_out() {
  // The region inset 3 mm from the sides: its walls are the part's solid.
  // The stress leans 45 degrees toward +x, so the strands from the floor leave the -x wall bare as they climb.
  Part b(box(24, 24, 24), 24, 24, 24, 3, [](const Vec3&) { return along({1, 0, 1}, 1.0); }, 3.0);
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  b.ask.walls_out = true;
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-6 walls out", rep);
  CHECK(rep.seeds_wall > 0);
  // Strands that start on a side wall move inward.
  std::size_t from_wall = 0, inward = 0;
  for (const Strand& s : ss) {
    const Vec3 a = s.points.front();
    const double wall = std::min({a.x - 3.0, 21.0 - a.x, a.y - 3.0, 21.0 - a.y});   // into the side wall: negative
    if (wall > 0.05 || a.z < 3.5) continue;
    ++from_wall;
    const Vec3 c = s.points[std::min<std::size_t>(s.points.size() - 1, 3)];
    inward += std::min({c.x - 3.0, 21.0 - c.x, c.y - 3.0, 21.0 - c.y}) > wall + 0.2;
  }
  std::printf("G-6 strands from the walls: %zu, of them growing inward: %zu\n", from_wall, inward);
  CHECK(from_wall > 0 && inward == from_wall);
  // Off: no wall seed.
  GrowReport none;
  b.ask.walls_out = false;
  grow_strands(b.d, 1, b.field, b.ask, &none);
  CHECK(none.seeds_wall == 0);
}

// ── G10: no repeats ───────────────────────────────────────────────────────────
static std::pair<std::size_t, std::size_t> repeats(const std::vector<Strand>& ss) {
  std::map<std::array<long long, 6>, int> seg;
  std::size_t same_ends = 0, along = 0;
  auto key = [](const Vec3& p) { return std::array<long long, 3>{std::llround(p.x * 1e5), std::llround(p.y * 1e5), std::llround(p.z * 1e5)}; };
  for (const Strand& s : ss)
    for (std::size_t k = 0; k + 1 < s.points.size(); ++k) {
      auto a = key(s.points[k]), b = key(s.points[k + 1]);
      if (b < a) std::swap(a, b);
      same_ends += seg[{a[0], a[1], a[2], b[0], b[1], b[2]}]++ > 0;
    }
  for (std::size_t i = 0; i < ss.size(); ++i)
    for (std::size_t k = 0; k + 1 < ss[i].points.size(); ++k) {
      const Vec3 a = ss[i].points[k], b = ss[i].points[k + 1];
      if (dist(a, b) < 1e-9) continue;
      for (std::size_t j = 0; j < ss.size(); ++j) {
        if (j == i) continue;
        bool all = true;
        for (int t = 0; t <= 4 && all; ++t)
          all = to_polyline({a.x + (b.x - a.x) * t / 4, a.y + (b.y - a.y) * t / 4, a.z + (b.z - a.z) * t / 4}, ss[j].points) <= 0.02;
        if (all) { ++along; break; }
      }
    }
  return {same_ends, along};
}
static void test_no_repeats() {
  Part b = converging();
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  GrowReport rep;
  const std::vector<Strand> s1 = grow_strands(b.d, 1, b.field, b.ask, &rep);
  CHECK(!s1.empty());
  const auto [ends, along] = repeats(s1);
  Part c(box(24, 24, 24), 24, 24, 24, 3, [](const Vec3&) { return std::array<double, 6>{0.5, 0.0, 1.0, 0, 0, 0}; });
  c.ask.reference_mpa = 2.0;
  at_5_5(c.ask);
  GrowReport rep2;
  const std::vector<Strand> s2 = grow_strands(c.d, 1, c.field, c.ask, &rep2);
  CHECK(!s2.empty() && rep2.ties_laid > 0);
  const auto [ends2, along2] = repeats(s2);
  std::printf("G-7 repeats: segments sharing both ends %zu and %zu; segments along another strand within 0.02 mm %zu and %zu "
              "(merged in growth: %.2f and %.2f mm)\n", ends, ends2, along, along2, rep.cut_repeat_mm, rep2.cut_repeat_mm);
  CHECK(ends == 0 && along == 0 && ends2 == 0 && along2 == 0);
}

// ── G1: the same strands every time, for any thread count ────────────────────
static Settings pocket_settings(double depth) {
  Settings s;
  s.bead_mm = 0.45;
  s.min_strut_lines = 2.0;
  Settings::RegionAsk r;
  r.id = 1;
  r.faces = {1};
  r.depth_mm = depth;
  r.expand_mm = -3.0;
  r.weave = true;
  s.regions = {r};
  return s;
}
static void test_same_every_time() {
  Part b = converging();
  b.ask.reference_mpa = 2.0;
  const std::vector<Strand> a = grow_strands(b.d, 1, b.field, b.ask);
  const std::vector<Strand> c = grow_strands(b.d, 1, b.field, b.ask);
  bool same = a.size() == c.size();
  for (std::size_t i = 0; same && i < a.size(); ++i) {
    same = a[i].points.size() == c[i].points.size() && a[i].spacing_mm == c[i].spacing_mm;
    for (std::size_t k = 0; same && k < a[i].points.size(); ++k)
      same = a[i].points[k].x == c[i].points[k].x && a[i].points[k].y == c[i].points[k].y && a[i].points[k].z == c[i].points[k].z;
  }
  CHECK(same && !a.empty());
  Session session(box_model(24, 24, 20));
  OrganicAsk ask = b.ask;
  // sigma2 half of sigma1 (ties are laid), the major direction leaning with x
  const TensorField field = make_field(24, 24, 20, [](const Vec3& p) {
    return std::array<double, 6>{0.5, 0.0, 1.0, 0.0, 0.0, 0.3 * (p.x - 12.0) / 12.0};
  });
  const Outcome one = session.lay_organic(pocket_settings(16), field, ask, 1);
  const Outcome eight = session.lay_organic(pocket_settings(16), field, ask, 8);
  bool bars = one.bars.bars.size() == eight.bars.bars.size() && !one.bars.bars.empty();
  for (std::size_t i = 0; bars && i < one.bars.bars.size(); ++i) {
    const Bar& x = one.bars.bars[i];
    const Bar& y = eight.bars.bars[i];
    bars = x.a.x == y.a.x && x.a.y == y.a.y && x.a.z == y.a.z && x.b.x == y.b.x && x.b.y == y.b.y && x.b.z == y.b.z &&
           x.end_a == y.end_a && x.end_b == y.end_b;
  }
  std::printf("G-8 lay_organic grown: %zu strands, %zu bars with 1 thread and %zu with 8\n", one.strands,
              one.bars.bars.size(), eight.bars.bars.size());
  CHECK(bars && one.grown && eight.grown && one.strands == eight.strands);
}

// ── G11 (brief G2 change 3, LatticeReview's ruling 4), O16 (ruling 2) ────────
// A 24 x 24 x 30 box, the weave under its top face 26 mm deep and 3 mm in from the sides (a 4 mm floor), a uniform
// upward stress (spacing 5.5: at_5_5): the vines climb from the floor to the top face. A vine that reaches the part's
// surface has arrived: its upper end stays Surface and it is kept back to the floor, not cut as "leads to nothing".
// With Finish Skin, Grown lays the net skin, its reach the median of the spacing field.
static void test_vines_arrive() {
  Session session(box_model(24, 24, 30));
  const TensorField field = make_field(24, 24, 30, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  OrganicAsk ask;
  ask.mode = OrganicMode::Grown;
  ask.spacing_min_mm = 3.0;
  ask.width_mm = 0.9;
  ask.layer_mm = 0.2;
  at_5_5(ask);
  Settings s = pocket_settings(26);
  const Outcome none = session.lay_organic(s, field, ask, 1);
  std::size_t at_top = 0;
  for (const Bar& b : none.bars.bars)
    at_top += (b.end_b == Bar::End::Surface && b.b.z > 30.0 - 1e-3 && b.b.z > b.a.z) ||
              (b.end_a == Bar::End::Surface && b.a.z > 30.0 - 1e-3 && b.a.z > b.b.z);
  const double kept = none.grown ? none.grown->kept_mm / std::max(1e-9, none.grown->grown_mm) : 0.0;
  std::printf("G-11 vines arrive: %zu bars, %zu end at the top face; kept %.1f %% of the grown length (leads to nothing %.1f mm)\n",
              none.bars.bars.size(), at_top, 100.0 * kept, none.grown ? none.grown->cut_nothing_mm : -1.0);
  CHECK(none.grown && at_top > 0 && kept >= 0.9);
  s.skin = true;
  const Outcome skin = session.lay_organic(s, field, ask, 1);
  std::printf("G-11 Grown with Finish Skin: %zu net struts, %.1f mm\n", skin.net_struts, skin.net_mm);
  CHECK(skin.net_struts > 0 && skin.net_mm > 0.0);
}

// ── G1, G12: through lay_organic and the file job, on a made-up pocket ───────
static std::string slurp(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::ostringstream s;
  s << f.rdbuf();
  return s.str();
}
static bool has(const std::string& text, const std::string& part) { return text.find(part) != std::string::npos; }
static std::size_t shells(const TriangleMesh& m) {
  std::map<std::array<double, 3>, int> at;
  std::vector<int> id(m.vertices.size());
  for (std::size_t v = 0; v < m.vertices.size(); ++v)
    id[v] = at.emplace(std::array<double, 3>{m.vertices[v].x, m.vertices[v].y, m.vertices[v].z}, static_cast<int>(at.size())).first->second;
  std::vector<int> up(at.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = static_cast<int>(i);
  std::function<int(int)> find = [&](int v) { return up[static_cast<std::size_t>(v)] == v ? v : up[static_cast<std::size_t>(v)] = find(up[static_cast<std::size_t>(v)]); };
  for (const auto& t : m.triangles)
    for (int q = 0; q < 3; ++q) up[static_cast<std::size_t>(find(id[static_cast<std::size_t>(t[q])]))] = find(id[static_cast<std::size_t>(t[0])]);
  std::map<int, int> roots;
  for (const auto& t : m.triangles) ++roots[find(id[static_cast<std::size_t>(t[0])])];
  return roots.size();
}
static std::string without_times(std::string t) {
  // the result's times change from run to run: drop every "ms..." number
  std::string out;
  for (std::size_t i = 0; i < t.size();) {
    const std::size_t k = t.find("\"ms", i);
    if (k == std::string::npos) { out += t.substr(i); break; }
    out += t.substr(i, k - i);
    std::size_t e = t.find_first_of(",}", k);
    if (t.compare(k, 6, "\"ms\": ") == 0 && t[k + 6] == '{') e = t.find('}', k);
    i = e;
  }
  return out;
}
static void test_file_job() {
  const std::string dir = ORGANIC_GROWN_TMP_DIR;
  const auto job_text = [](const std::string& mode) {
    return std::string(R"({"mode": "lattice_file", "model": "pocket.stl", "output": "grown.stl",
      "layout": {"bead_mm": 0.45, "min_strut_lines": 2, "region_ids": [1], "region_no_lattice": [0],
        "region_depth_mm": [12], "region_expand_mm": [-3], "region_face_counts": [1], "region_faces": [1],
        "region_weave": [true], "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8, "organic_width_mm": 0.9)") +
           mode + "}}";
  };
  auto field = std::make_shared<TensorField>(make_field(24, 24, 16, [](const Vec3& p) {
    return along({p.x < 12.0 ? 0.5 : -0.5, 0.0, 1.0}, 0.2 + p.y / 24.0);
  }));
  auto run = [&](const std::string& mode, const std::string& name, FileResult& r) {
    const std::string stl = dir + "/" + name;
    try {
      FileJob job = parse_file_job(job_text(mode));
      job.tensor_field = field;
      r = make_lattice_file(box_model(24, 24, 16), job, stl);
    } catch (const std::exception& e) {
      r = FileResult{};
      r.code = "job_unreadable";
      r.detail = e.what();
    }
    return stl;
  };
  FileResult g;
  const std::string gstl = run(R"(, "organic_mode": "grown")", "organic_grown.stl", g);
  if (!mesh_available()) {
    CHECK(!g.ok && g.code == "mesh_unavailable");
    return;
  }
  if (!g.ok) std::printf("  (%s: %s %s)\n", g.code.c_str(), g.why.c_str(), g.detail.c_str());
  CHECK(g.ok && g.grown && g.strands > 0 && g.strands == g.grown->strands);
  if (!g.ok || !g.grown) return;
  const TriangleMesh mesh = read_stl_file(gstl).mesh;
  const std::string text = file_result_json(g);
  std::printf("G-9 file job, grown: %zu strands, %zu weave bars; %zu triangles, %zu bodies; print clean %d, mid-air %zu, "
              "one-ended %zu; builds %d; grow %.0f ms, total %.0f ms\n", g.strands, g.weave_bars, mesh.triangles.size(),
              shells(mesh), g.made.print_clean ? 1 : 0, g.made.layers.mid_air.size(), g.made.layers.one_ended.size(),
              g.made.builds, g.grown ? g.grown->ms : 0.0, g.ms_total);
  if (g.grown) print_report("G-9 pocket", *g.grown);
  CHECK(shells(mesh) == 1 && g.made.print_clean);
  CHECK(has(text, "\"grown\": {\"strands\": " + std::to_string(g.strands) + ", \"grown_mm\": "));
  // Traced: the same file and result whether the mode is left out or said.
  FileResult t1, t2;
  const std::string a = run("", "organic_traced_a.stl", t1);
  const std::string b = run(R"(, "organic_mode": "traced")", "organic_traced_b.stl", t2);
  CHECK(t1.ok && t2.ok && !t1.grown && !t2.grown);
  CHECK(slurp(a) == slurp(b) && !slurp(a).empty());
  std::string j1 = without_times(file_result_json(t1)), j2 = without_times(file_result_json(t2));
  const auto name = [](std::string s, const std::string& from, const std::string& to) {
    const std::size_t k = s.find(from);
    if (k != std::string::npos) s.replace(k, from.size(), to);
    return s;
  };
  j2 = name(j2, "organic_traced_b.stl", "organic_traced_a.stl");
  CHECK(j1 == j2 && !has(j1, "\"grown\""));
  // A mode that is neither is refused, with the key named.
  bool refused = false;
  try {
    parse_file_job(job_text(R"(, "organic_mode": "vine")"));
  } catch (const std::exception& e) {
    refused = has(e.what(), "organic_mode");
  }
  CHECK(refused);
  for (const std::string& p : {gstl, a, b}) std::remove(p.c_str());
}

// ── G1: time, a 40 mm cube with a made-up bending-and-twist field ────────────
static void test_cube_time() {
  Part b(box(40, 40, 40), 40, 40, 40, 4, [](const Vec3& p) {
    // bending about y (sigma_zz grows with x), with a twist (shear growing out from the middle)
    return std::array<double, 6>{0.0, 0.0, 0.2 + 0.08 * (p.x - 20.0), 0.0, 0.3 * (p.x - 20.0) / 20.0,
                                 -0.3 * (p.y - 20.0) / 20.0};
  });
  GrowReport rep;
  const auto t0 = std::chrono::steady_clock::now();
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  const double ms = ms_since(t0);
  print_report("G-10 40 mm cube", rep);
  double mm = 0.0;
  for (const Strand& s : ss) mm += strand_mm(s);
  std::printf("G-10 the 40 mm cube: %zu strands, %.0f mm, in %.0f ms (under 5 s)\n", ss.size(), mm, ms);
  CHECK(!ss.empty() && ms < 5000.0);
  // The lengths add up: every laid segment is kept or cut once.
  const double cut = rep.cut_outside_mm + rep.cut_unsupported_mm + rep.cut_nothing_mm + rep.cut_crowded_mm + rep.cut_repeat_mm;
  std::printf("G-10 grown %.3f = kept %.3f + cut %.3f (difference %.6f mm)\n", rep.grown_mm, rep.kept_mm, cut,
              rep.grown_mm - rep.kept_mm - cut);
  CHECK(std::fabs(rep.grown_mm - rep.kept_mm - cut) < 1e-6 * std::max(1.0, rep.grown_mm));
}

int main() {
  test_uniform_block();
  test_ramp();
  test_rewind();
  test_notch();
  test_ties();
  test_walls_out();
  test_no_repeats();
  test_same_every_time();
  test_vines_arrive();
  test_file_job();
  test_cube_time();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
