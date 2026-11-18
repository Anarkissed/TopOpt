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
  std::printf("%s: %zu strands (%zu grown); seeds floor %zu wall %zu, refused support %zu; tips %zu (budget hit %zu); "
              "steps %zu, clamped %zu; ended edge %zu unsupported %zu on the 7th join %zu\n",
              what, g.strands, g.strands_grown, g.seeds_floor, g.seeds_wall, g.seeds_refused_support, g.tips,
              g.tip_budget_hit, g.steps, g.clamped, g.ended_edge, g.ended_unsupported, g.ended_joins);
  std::printf("  joins %zu (grew on after %zu), crowded with a longer run climbed on %zu; branches offered %zu grown %zu "
              "links %zu, refused region %zu support %zu crowded %zu\n",
              g.joins, g.grew_on_after_join, g.joins_refused_span, g.branches_offered, g.branches_grown, g.links,
              g.refused_region, g.refused_support, g.refused_crowded);
  std::printf("  bare %.1f %% before re-seeding, %.1f %% after; re-seeded voids %zu landed %zu failed %zu (%.1f mm); "
              "ties seeded %zu laid %zu, refused minor %zu reach %zu\n",
              100.0 * g.bare_before, 100.0 * g.bare_after, g.reseed_voids, g.reseed_landed, g.reseed_failed,
              g.reseed_mm, g.ties_seeded, g.ties_laid, g.ties_refused_minor, g.ties_refused_reach);
  std::printf("  grown %.1f mm, kept %.1f mm; cut: outside %.1f, unsupported %.1f, leads to nothing %.1f, repeat %.1f; "
              "%.0f ms\n",
              g.grown_mm, g.kept_mm, g.cut_outside_mm, g.cut_unsupported_mm, g.cut_nothing_mm, g.cut_repeat_mm, g.ms);
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
// `forks` (G6, rule E as amended, LatticeReview's ruling of 2026-11-15): a branch is exempt from its parent until it is
// first `lower` from it, so a strand whose start lies on another (a branch on its parent) is not counted against that
// parent from its fork to its first point `lower` from it, nor the parent's stretch facing that.
static Gaps gaps(const std::vector<Strand>& ss, double lower, double touch, bool forks = false) {
  Gaps g;
  g.nearest.assign(ss.size(), 1e300);
  std::vector<std::vector<Vec3>> sm(ss.size());
  std::vector<Vec3> lo(ss.size()), hi(ss.size());
  for (std::size_t i = 0; i < ss.size(); ++i) {
    sm[i] = samples(ss[i].points, 0.1);
    box_of(ss[i].points, lo[i], hi[i]);
  }
  std::vector<int> parent(ss.size(), -1);
  std::vector<std::size_t> leaving(ss.size(), 0);   // samples of the branch from its fork until it is `lower` clear
  std::vector<std::vector<Vec3>> stretch(ss.size());
  if (forks)
    for (std::size_t a = 0; a < ss.size(); ++a) {
      for (std::size_t c = 0; c < ss.size() && parent[a] < 0; ++c)
        if (c != a && to_polyline(ss[a].points.front(), ss[c].points) < 1e-6) parent[a] = static_cast<int>(c);
      if (parent[a] < 0) continue;
      std::size_t k = 0;
      while (k < sm[a].size() && to_polyline(sm[a][k], ss[static_cast<std::size_t>(parent[a])].points) < lower) ++k;
      leaving[a] = k;
      stretch[a].assign(sm[a].begin(), sm[a].begin() + static_cast<long>(std::min(k + 1, sm[a].size())));
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
        if (forks && parent[a] == static_cast<int>(b) && k < leaving[a]) continue;   // the branch leaving its parent
        if (forks && parent[b] == static_cast<int>(a) && stretch[b].size() >= 2 &&
            to_polyline(sm[a][k], stretch[b]) <= d[k] + 1e-9)
          continue;   // the parent's stretch facing it
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
  b.ask.foot_gap = 0.0;   // the lead's ruling (brief G5): its neighbour and first-heading checks test the seeding, not G13
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
  // Neighbours: no farther than about the local spacing. (SUPERSEDED 2026-11-15, brief G4: "no closer than the lower
  // limit" pinned GR-REWIND and the thinning to the window, both gone; the original's separation test, 0.5 x the local
  // spacing against recorded vertices, is what keeps vines apart now. The smallest gap is printed, not checked.)
  const Gaps g = gaps(ss, 3.0, 0.9);
  double far = 0.0;
  for (double n : g.nearest)
    if (n < 1e299) far = std::max(far, n);
  std::printf("G-1 gaps: smallest %.3f mm, largest nearest-neighbour %.3f mm (local spacing 5.5)\n", g.smallest, far);
  CHECK(far <= 1.5 * 5.5 && far > 0.0);
  // Re-pinned 2026-11-15 (brief G4; the owner: "I think we need to have LOADS of seeds, vines, and directions"): one
  // floor seed per stride cell of 0.25 x the median spacing (5.5) each way, placed at random in its cell: about
  // (24 / 1.375)^2, at most the 18 x 18 cells that touch the floor.
  const double stride = 0.25 * 5.5;
  std::printf("G-1 floor seeds %zu (about %.0f at one per (0.25 d)^2)\n", rep.seeds_floor, 24.0 * 24.0 / (stride * stride));
  CHECK(rep.seeds_floor >= 0.9 * 24.0 * 24.0 / (stride * stride) && rep.seeds_floor <= 18u * 18u);
  // G2 (brief G4): each seed's first heading is random inside the cone, uniformly over the cap from 30 degrees above
  // level to the build direction: most leave more than 15 degrees off it (93 % of the cap), the foot holding it for
  // two widths. Under a uniform upward stress every heading after that turns up.
  std::size_t floor_strands = 0, off15 = 0;
  for (const Strand& s : ss) {
    if (s.points.front().z > 3.0 + 1e-6 || s.points.size() < 2) continue;
    ++floor_strands;
    const Vec3 a = s.points[0], b = s.points[1];
    off15 += (b.z - a.z) / dist(a, b) < std::cos(15.0 * 3.14159265358979323846 / 180.0);
  }
  std::printf("G-1 floor strands %zu, leaving more than 15 degrees off the build direction %zu\n", floor_strands, off15);
  CHECK(floor_strands > 0 && off15 >= floor_strands / 2);
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
// Re-pinned 2026-11-15 (brief G4): GR-REWIND is gone (the owner's OR33). Two families driven into each other: a tip
// crowded within 0.5 x the local spacing by another strand's recorded vertex, the run 3 mm or less, JOINS it, moves
// onto it, is re-aimed away at the cone and GROWS ON (a deflection); no loose tail; a fixed number of steps.
static void test_joins() {
  Part b = converging();
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  GrowReport rep, again;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  const std::vector<Strand> s2 = grow_strands(b.d, 1, b.field, b.ask, &again);
  print_report("G-3 converging", rep);
  CHECK(rep.joins > 0 && rep.grew_on_after_join > 0);
  // No loose tail: both ends of every strand are held (solid, the part's surface, or another strand).
  const Domain::Probe pr = b.d.probe();
  std::size_t loose = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    loose += !end_held(pr, ss, i, ss[i].points.front()) + !end_held(pr, ss, i, ss[i].points.back());
  std::printf("G-3 joins %zu, grew on after %zu; loose ends: %zu of %zu strands' ends\n", rep.joins,
              rep.grew_on_after_join, loose, 2 * ss.size());
  CHECK(loose == 0);
  // A fixed number of steps: the same on a repeat, and bounded.
  CHECK(again.steps == rep.steps && again.joins == rep.joins && rep.steps < 2000000);
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
  // G2 (brief G4): the randomness is the ask's seed number: another number, other strands.
  OrganicAsk other = b.ask;
  other.seed = 2;
  const std::vector<Strand> o = grow_strands(b.d, 1, b.field, other);
  bool differ = o.size() != a.size();
  for (std::size_t i = 0; !differ && i < a.size(); ++i)
    differ = a[i].points.size() != o[i].points.size() || a[i].points.front().x != o[i].points.front().x;
  CHECK(differ);
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

// ── G3 (brief G4; the owner's OR35): vines reach for every face ───────────────
// A block 24 x 24 x 30 with no stress: a tip keeps its heading, pulled 0.25 toward the nearest face of the region that
// is not its floor. Near a side that face is the side: the strands' segments within 3 mm of a side (not within 3 mm of
// two), below the middle height, run on the whole toward that side (their movement toward it, summed, over their
// length, above 0.05). With the pull straight up and random first headings it would be about 0.
static void test_faces() {
  Part b(box(24, 24, 30), 24, 24, 30, 3, [](const Vec3&) { return std::array<double, 6>{0, 0, 0, 0, 0, 0}; });
  at_5_5(b.ask);
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-12 no stress", rep);
  double toward = 0.0, length = 0.0;
  for (const Strand& s : ss)
    for (std::size_t k = 0; k + 1 < s.points.size(); ++k) {
      const Vec3 a = s.points[k], e = s.points[k + 1];
      const Vec3 m{(a.x + e.x) / 2, (a.y + e.y) / 2, (a.z + e.z) / 2};
      if (m.z < 3.0 || m.z > 15.0 || e.z < a.z) continue;   // climbing segments, lower half
      const double d[4] = {m.x, 24.0 - m.x, m.y, 24.0 - m.y};
      int q = 0, near = 0;
      for (int i = 0; i < 4; ++i) {
        near += d[i] < 3.0;
        if (d[i] < d[q]) q = i;
      }
      if (near != 1) continue;
      const double mv[4] = {a.x - e.x, e.x - a.x, a.y - e.y, e.y - a.y};   // movement toward side q
      toward += mv[q];
      length += dist(a, e);
    }
  std::printf("G-12 climbing segments within 3 mm of one side: %.0f mm, moving toward it %.0f mm (%.3f)\n", length, toward,
              length > 0.0 ? toward / length : 0.0);
  CHECK(length > 0.0 && toward / length > 0.05);
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
  const double cut = rep.cut_outside_mm + rep.cut_unsupported_mm + rep.cut_nothing_mm + rep.cut_repeat_mm;
  std::printf("G-10 grown %.3f = kept %.3f + cut %.3f (difference %.6f mm)\n", rep.grown_mm, rep.kept_mm, cut,
              rep.grown_mm - rep.kept_mm - cut);
  CHECK(std::fabs(rep.grown_mm - rep.kept_mm - cut) < 1e-6 * std::max(1.0, rep.grown_mm));
}

// ── G13 (brief G5): the feet compete ─────────────────────────────────────────
// The owner (2026-11-15): "We seeded so much assuming a bunch of vines would get pruned out completely. ... Are we
// not pruning the entirety of the plant?" A slab 24 x 24 x 12 on a 3 mm floor, the spacing 5.5 everywhere, seeds on a
// stride of 0.25 x the spacing. The feet left (strands that run into the floor's solid) stand at least foot_gap x the
// spacing apart where they leave the floor; feet were removed, some whole (with what hung only on them); a removed foot
// leaves nothing at the floor (against the same growth with every foot kept); nothing ends in mid-air; the lengths add
// up. What is left standing on nothing is the path's to drop, as before (printed: the pieces it finds adrift).
static std::vector<Vec3> feet_of(const std::vector<Strand>& ss, double floor) {
  std::vector<Vec3> feet;   // where each strand that runs into the floor crosses it
  for (const Strand& s : ss) {
    if (!(s.points.front().z < floor - 1e-6)) continue;
    for (std::size_t k = 0; k + 1 < s.points.size(); ++k) {
      const Vec3 a = s.points[k], e = s.points[k + 1];
      if (a.z < floor && e.z >= floor) {
        const double t = (floor - a.z) / (e.z - a.z);
        feet.push_back({a.x + (e.x - a.x) * t, a.y + (e.y - a.y) * t, floor});
        break;
      }
    }
  }
  return feet;
}
static void test_feet() {
  Part b(box(24, 24, 12), 24, 24, 12, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  b.ask.seed_stride = 0.25;
  b.ask.foot_gap = 1.0;
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-13 slab", rep);
  const std::vector<Vec3> feet = feet_of(ss, 3.0);
  std::size_t close = 0;
  double nearest = 1e300;
  for (std::size_t i = 0; i < feet.size(); ++i)
    for (std::size_t j = i + 1; j < feet.size(); ++j) {
      const double d = std::hypot(feet[i].x - feet[j].x, feet[i].y - feet[j].y);
      nearest = std::min(nearest, d);
      close += d < b.ask.foot_gap * 5.5 - 2.0 * kStraightened;
    }
  std::printf("G-13 seeds %zu, feet kept %zu (in the file: %zu), removed at a joint %zu, whole %zu; nearest two feet %.2f mm "
              "(foot_gap x spacing %.2f); pairs closer %zu\n",
              rep.seeds_floor, rep.feet_kept, feet.size(), rep.feet_cut_at_joint, rep.vines_removed, nearest,
              b.ask.foot_gap * 5.5, close);
  CHECK(!feet.empty() && close == 0);
  CHECK(rep.feet_kept > 0 && rep.vines_removed > 0 && rep.feet_cut_at_joint + rep.vines_removed + rep.feet_kept ==
                                                            rep.seeds_floor - rep.seeds_refused_support);
  // Against the same growth with every foot kept (a gap no two feet are under): each foot not kept is cut from the floor:
  // nothing runs into the floor within a width of where it left it (unless a kept foot stands within two widths).
  OrganicAsk all = b.ask;
  all.foot_gap = 0.0;
  const std::vector<Vec3> every = feet_of(grow_strands(b.d, 1, b.field, all), 3.0);
  std::size_t removed = 0, left = 0;
  for (const Vec3& f : every) {
    bool kept = false;
    for (const Vec3& k : feet) kept = kept || std::hypot(f.x - k.x, f.y - k.y) <= 2.0 * 0.9;
    if (kept) continue;
    ++removed;
    bool any = false;
    for (const Strand& s : ss)
      for (const Vec3& p : samples(s.points, 0.05)) any = any || (p.z < 3.0 - 1e-6 && std::hypot(p.x - f.x, p.y - f.y) <= 0.9);
    left += any;
  }
  const Domain::Probe pr = b.d.probe();
  // an end is held as end_held says, or lies on another strand within the two straightenings (P9)
  std::size_t loose = 0;
  for (std::size_t i = 0; i < ss.size(); ++i)
    for (const Vec3& e : {ss[i].points.front(), ss[i].points.back()}) {
      bool on = end_held(pr, ss, i, e);
      for (std::size_t j = 0; j < ss.size() && !on; ++j) on = j != i && to_polyline(e, ss[j].points) <= kStraightened;
      loose += !on;
    }
  Bars bars = weave_bars(b.d, ss, 1);
  split_at_crossings(bars);
  join_loose_bars(bars, b.d, 1, nullptr);
  const std::vector<int> arrived{1};
  drop_loose_bars(bars, &arrived);
  const Pieces adrift = drop_adrift_bars(bars, b.d, nullptr);
  std::printf("G-13 feet with every foot kept %zu; of those removed here (%zu), any left at the floor %zu; loose ends %zu; "
              "the path finds %zu pieces adrift (%.1f mm)\n",
              every.size(), removed, left, loose, adrift.adrift, adrift.adrift_mm);
  CHECK(removed > 0 && left == 0);
  CHECK(loose == 0);
  // The lengths still add up (the feet's cuts are counted).
  const double cut = rep.cut_outside_mm + rep.cut_unsupported_mm + rep.cut_nothing_mm + rep.cut_repeat_mm;
  CHECK(std::fabs(rep.grown_mm - rep.kept_mm - cut) < 1e-6 * std::max(1.0, rep.grown_mm));
  // The file job's key: 2.5 when not given, read when given (0: the feet do not compete), refused when not a number.
  const auto job = [](const std::string& more) {
    return parse_file_job(std::string(R"({"mode": "lattice_file", "model": "pocket.stl", "output": "grown.stl",
      "layout": {"bead_mm": 0.45, "min_strut_lines": 2, "region_ids": [1], "region_no_lattice": [0],
        "region_depth_mm": [12], "region_expand_mm": [-3], "region_face_counts": [1], "region_faces": [1],
        "region_weave": [true], "organic_spacing_min_mm": 3, "organic_spacing_max_mm": 8, "organic_mode": "grown")") +
                          more + "}}");
  };
  bool refused = false;
  try {
    job(R"(, "organic_foot_gap": "wide")");
  } catch (const std::exception& e) {
    refused = has(e.what(), "organic_foot_gap");
  }
  CHECK(job("").organic.foot_gap == 2.5 && job(R"(, "organic_foot_gap": 1.5)").organic.foot_gap == 1.5 &&
        job(R"(, "organic_foot_gap": 0)").organic.foot_gap == 0.0 && refused);
}

// ── 3 (brief G5): a join or a link stays inside the region ────────────────────
// A block 24 x 16 x 24 with a slot of air 1 mm wide (x 12 to 13) down from the top to z 8, the stress leaning toward the
// slot from both sides, so vines crowd across it. No strand crosses the slot (a join or link over it is not made).
static void test_joins_inside() {
  const TriangleMesh m = cubes_mesh(24, 16, 24, [](int i, int, int k) { return !(i == 12 && k >= 8); });
  Part b(m, 24, 16, 24, 3, [](const Vec3& p) {
    const double s = p.x < 12.5 ? 1.0 : -1.0;
    const double t = 40.0 * 3.14159265358979323846 / 180.0;
    return along({s * std::sin(t), 0.0, std::cos(t)}, 1.0);
  });
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  GrowReport rep;
  const std::vector<Strand> ss = grow_strands(b.d, 1, b.field, b.ask, &rep);
  print_report("G-15 slot", rep);
  std::size_t across = 0;
  for (const Strand& s : ss)
    for (const Vec3& p : samples(s.points, 0.05)) across += p.x > 12.05 && p.x < 12.95 && p.z > 8.05;
  std::printf("G-15 joins refused outside %zu, links %zu; points in the slot %zu\n", rep.joins_refused_outside,
              rep.links_refused_outside, across);
  CHECK(across == 0);
}

// ── G16a (brief G6; the owner: "the vines need to go to a face"): the light is outside the part ───────────────
// On the G-1 block (24 x 24 x 30, 3 mm floor, voxels of 1 mm), in every boundary voxel of a side face (x = 24) and of
// the top, away from their edges: at the voxel's centre and a quarter voxel off it each way along the wall, the pull
// points through the wall (light . o at least 0.9, o the wall's outward normal). On the unchanged source it aims at the
// middle of the voxel's own face, so a quarter voxel along the wall it is 0.894 off the normal.
static void test_light_outside() {
  Part b(box(24, 24, 30), 24, 24, 30, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  std::size_t side = 0, side_bad = 0, top = 0, top_bad = 0;
  double side_worst = 1.0, top_worst = 1.0;
  const double q = 0.25;
  for (int k = 4; k <= 28; ++k)   // the side x = 24: its voxels i = 23, away from the floor, the top and the corners
    for (int j = 1; j <= 22; ++j) {
      const Vec3 c{23.5, j + 0.5, k + 0.5};
      const Vec3 pts[5] = {c, {c.x, c.y, c.z + q}, {c.x, c.y, c.z - q}, {c.x, c.y + q, c.z}, {c.x, c.y - q, c.z}};
      for (const Vec3& p : pts) {
        const double d = grown_light(b.d, 1, b.field, b.ask, p).x;
        ++side;
        side_bad += d < 0.9;
        side_worst = std::min(side_worst, d);
      }
    }
  for (int j = 1; j <= 22; ++j)   // the top: its voxels k = 29, away from the sides
    for (int i = 1; i <= 22; ++i) {
      const Vec3 c{i + 0.5, j + 0.5, 29.5};
      const Vec3 pts[5] = {c, {c.x + q, c.y, c.z}, {c.x - q, c.y, c.z}, {c.x, c.y + q, c.z}, {c.x, c.y - q, c.z}};
      for (const Vec3& p : pts) {
        const double d = grown_light(b.d, 1, b.field, b.ask, p).z;
        ++top;
        top_bad += d < 0.9;
        top_worst = std::min(top_worst, d);
      }
    }
  std::printf("G-16a light through the wall: side %zu points, under 0.9 %zu (least %.3f); top %zu points, under 0.9 %zu "
              "(least %.3f)\n", side, side_bad, side_worst, top, top_bad, top_worst);
  CHECK(side > 0 && side_bad == 0);
  CHECK(top > 0 && top_bad == 0);
}

// G16a: on the G-1 block every floor seed's tip that takes a step ends by an existing end (edge, unsupported, seventh
// join; never the step guard), and more of them end at the edge than on the unchanged source.
static constexpr std::size_t kBaseFloorEndedEdge = 123;   // the unchanged source's count (ab2759a2, brief G6)
static void test_floor_tips_leave() {
  Part b(box(24, 24, 30), 24, 24, 30, 3, [](const Vec3&) { return along({0, 0, 1}, 1.0); });
  b.ask.reference_mpa = 2.0;
  at_5_5(b.ask);
  b.ask.foot_gap = 0.0;
  GrowReport rep;
  (void)grow_strands(b.d, 1, b.field, b.ask, &rep);
  std::printf("G-16a floor tips that stepped %zu: ended edge %zu (unchanged source %zu), unsupported %zu, 7th join %zu\n",
              rep.floor_stepped, rep.floor_ended_edge, kBaseFloorEndedEdge, rep.floor_ended_unsupported,
              rep.floor_ended_joins);
  CHECK(rep.floor_stepped > 0 &&
        rep.floor_stepped == rep.floor_ended_edge + rep.floor_ended_unsupported + rep.floor_ended_joins);
  CHECK(rep.floor_ended_edge > kBaseFloorEndedEdge);
}

// ── G16c (brief G6): a bare place is filled from the nearest vine ───────────────────────────────────────────
// The G-10 cube (40 mm, the made-up bending-and-twist field): no re-seeded stub is longer INSIDE the region (from its
// landing on the floor's surface, or its root vertex, to the bare place; its run on into the floor's solid not counted,
// the lead's ruling) than 4 x the local spacing at its bare place + the landing radius there, and every stub rooted on a
// vine's vertex rises at the cone or steeper.
// On A alone the walk goes as far as the region's height + 2 spacings (poles down the corner columns).
static void test_reseed_from_vine() {
  Part b(box(40, 40, 40), 40, 40, 40, 4, [](const Vec3& p) {
    return std::array<double, 6>{0.0, 0.0, 0.2 + 0.08 * (p.x - 20.0), 0.0, 0.3 * (p.x - 20.0) / 20.0,
                                 -0.3 * (p.y - 20.0) / 20.0};
  });
  GrowReport rep;
  (void)grow_strands(b.d, 1, b.field, b.ask, &rep);
  const Domain::Probe pr = b.d.probe();
  std::size_t over = 0, flat = 0, from_vertex = 0;
  double worst = 0.0;
  for (const GrowReport::Stub& st : rep.stubs) {
    const double lim = 4.0 * st.spacing_mm + st.land_mm;
    double inside = 0.0;   // its length inside the region, read every 0.01 mm at the middle of each piece
    for (std::size_t k = 0; k + 1 < st.pts.size(); ++k) {
      const Vec3 a = st.pts[k], e = st.pts[k + 1];
      const double l = dist(a, e);
      const int n = std::max(1, static_cast<int>(std::ceil(l / 0.01)));
      for (int m = 0; m < n; ++m) {
        const double f = (m + 0.5) / n;
        const Where w = pr.where({a.x + (e.x - a.x) * f, a.y + (e.y - a.y) * f, a.z + (e.z - a.z) * f});
        if (w.lattice() && w.id == 1) inside += l / n;
      }
    }
    over += inside > lim + 1e-9;
    worst = std::max(worst, inside / lim);
    if (!st.from_vertex) continue;
    ++from_vertex;
    const double l = dist(st.root, st.top);
    flat += l > 0.0 && (st.top.z - st.root.z) < 0.5 * l - 1e-9;
  }
  std::printf("G-16c re-seeded stubs %zu (from a vertex %zu, walked %zu, failed %zu): longer than 4 spacings + the "
              "landing radius %zu (longest %.2f of it); from a vertex flatter than the cone %zu\n",
              rep.stubs.size(), from_vertex, rep.stubs.size() - from_vertex, rep.reseed_failed, over, worst, flat);
  CHECK(!rep.stubs.empty() && over == 0);
  CHECK(flat == 0);
}

int main() {
  test_uniform_block();
  test_ramp();
  test_joins();
  test_faces();
  test_notch();
  test_ties();
  test_walls_out();
  test_no_repeats();
  test_same_every_time();
  test_vines_arrive();
  test_file_job();
  test_cube_time();
  test_feet();
  test_joins_inside();
  test_light_outside();
  test_floor_tips_leave();
  test_reseed_from_vine();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail == 0 ? 0 : 1;
}
