// Lattice layout, stage B: measure and domain. Rule numbers are those of
// docs/design/lattice-rebuild/01-rules.md; the numbers are those of 02-tests.md.
#include <cmath>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <map>
#include <stdexcept>
#include <thread>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/stepped_plan.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)
#define NEAR(a, b, tol)                                                          \
  do {                                                                           \
    ++g_checks;                                                                  \
    const double _a = (a), _b = (b);                                             \
    if (!(std::fabs(_a - _b) <= (tol))) {                                        \
      ++g_fail;                                                                  \
      std::printf("FAIL %s:%d  %s = %.6f, want %.6f +- %g\n", __FILE__, __LINE__, #a, _a, _b, (double)(tol)); \
    }                                                                            \
  } while (0)

// A closed prism: polygon `xy` (counter-clockwise, star-shaped from its first vertex)
// from z0 to z1. Every face repeats its vertices, as a tessellated STEP model does.
static TriangleMesh prism(const std::vector<std::array<double, 2>>& xy, double z0, double z1) {
  MeshSink s;
  const std::size_t n = xy.size();
  auto P = [&](std::size_t i, double z) { return Vec3{xy[i % n][0], xy[i % n][1], z}; };
  for (std::size_t i = 1; i + 1 < n; ++i) {
    s.add_triangle(P(0, z1), P(i, z1), P(i + 1, z1));  // top, outward +z
    s.add_triangle(P(0, z0), P(i + 1, z0), P(i, z0));  // bottom, outward -z
  }
  for (std::size_t i = 0; i < n; ++i) {
    s.add_triangle(P(i, z0), P(i + 1, z0), P(i + 1, z1));
    s.add_triangle(P(i, z0), P(i + 1, z1), P(i, z1));
  }
  return s.mesh;
}
// The same for any simple polygon (counter-clockwise), its ends cut into triangles ear by ear.
static TriangleMesh prism_any(const std::vector<std::array<double, 2>>& xy, double z0, double z1) {
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
      if (turn(a, b, c) <= 1e-12) continue;   // not a corner that sticks out
      bool empty = true;
      for (int k : left)
        if (k != a && k != b && k != c && turn(a, b, k) >= -1e-12 && turn(b, c, k) >= -1e-12 &&
            turn(c, a, k) >= -1e-12)
          empty = false;
      if (!empty) continue;
      tris.push_back({a, b, c});
      left.erase(left.begin() + i);
      cut = true;
    }
    if (!cut) throw std::runtime_error("prism_any: not a simple polygon");
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
static TriangleMesh box(double x, double y, double z) {
  return prism({{0, 0}, {x, 0}, {x, y}, {0, y}}, 0, z);
}
static Region face_region(int id, Role role, Vec3 origin, Vec3 inward, double half_u,
                          double half_w, double depth, double expand = 0.0) {
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
  r.role = role;
  r.prism = resolve_clearance_manual(m, p);
  r.prism.declared_region_id = id;
  r.expand_mm = expand;
  return r;
}

static void test_measure_box() {
  std::size_t open = 99;
  PartMeasure pm(weld_mesh(box(20, 40, 10), 1e-5, &open));
  CHECK(open == 0);                       // closed after the weld
  CHECK(pm.mesh().vertices.size() == 8);
  auto pr = pm.probe();
  NEAR(pr.depth({10, 20, 5}), 5.0, 1e-9);        // D9: depth below the true surface
  NEAR(pr.depth({10, 20, 12}), -2.0, 1e-9);
  NEAR(pr.wall_width({10, 20, 5}, {1, 0, 0}), 20.0, 0.01);   // C11
  NEAR(pr.wall_width({3, 31, 2}, {0, 1, 0}), 40.0, 0.01);
  NEAR(pr.wall_width({3, 31, 2}, {0, 0, 1}), 10.0, 0.01);
  const double r = std::sqrt(0.5);
  NEAR(pr.wall_width({10, 20, 5}, {r, 0, r}), 10.0 / r, 0.01);  // across at 45 degrees
  NEAR(pr.wall_width({10, 20, 12}, {1, 0, 0}), 0.0, 0.0);       // outside: no wall
  // A width read ALONG a face, half a micron from it: still the wall, 40 mm. (A cell
  // face lying in a part face; it read 0 until 2026-11-10 and turned edge cells solid.)
  NEAR(pr.wall_width({0.0005, 20, 5}, {0, 1, 0}), 40.0, 0.01);
  NEAR(pr.wall_width({10, 20, 9.9995}, {1, 0, 0}), 20.0, 0.01);
}

static void test_measure_L() {
  // Two 20 mm walls meeting at a corner (the C11 part: "the walls here are exactly 20mm").
  std::size_t open = 99;
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 20}, {20, 20}, {20, 60}, {0, 60}}, 0, 10),
                           1e-5, &open));
  CHECK(open == 0);
  auto pr = pm.probe();
  NEAR(pr.wall_width({40, 10, 5}, {0, 1, 0}), 20.0, 0.01);   // the arm along x
  NEAR(pr.wall_width({10, 40, 5}, {1, 0, 0}), 20.0, 0.01);   // the arm along y
  NEAR(pr.wall_width({40, 3, 5}, {0, 1, 0}), 20.0, 0.01);    // the same anywhere in the wall
  // In the corner the material is longer one way; the measurement says so honestly, and
  // the cell rule (C11/C12, stage C) is what refuses to call that a thicker wall.
  NEAR(pr.wall_width({10, 10, 5}, {1, 0, 0}), 60.0, 0.01);
  NEAR(pr.depth({25, 25, 5}), -5.0, 1e-9);                   // the notch is outside
}

// The straight-line readings (speed, 2026-11-11) say what the distance says.
static void test_measure_by_line() {
  // The L of C11. Its top and bottom are fans of triangles from the corner (0,0), so
  // round-number lines run exactly through triangle edges and corners.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 20}, {20, 20}, {20, 60}, {0, 60}}, 0, 10)));
  auto pr = pm.probe();
  const double r = std::sqrt(0.5), b = std::sqrt(1.0 / 3.0);
  struct Ray { Vec3 p, d; double want; };
  const Ray rays[] = {
      {{10, 10, 5}, {1, 0, 0}, 50.0},                    // the middle of the end face (on its diagonal)
      {{10, 10, 5}, {0, 0, 1}, 5.0},                     // up through the edge of two top triangles
      {{10, 10, 5}, {0, 0, -1}, 5.0},
      {{10, 10, 5}, {r, r, 0}, std::sqrt(200.0)},        // into the inside corner's edge itself
      {{40, 10, 5}, {0, 1, 0}, 10.0},
      {{10, 40, 5}, {-1, 0, 0}, 10.0},
      {{5, 5, 5}, {-r, -r, 0}, std::sqrt(50.0)},         // out through the upright edge at (0,0)
      {{5, 5, 5}, {-b, -b, -b}, 5.0 * std::sqrt(3.0)},   // out through the corner (0,0,0)
  };
  for (const Ray& q : rays) {
    NEAR(pr.reach_by_line(q.p, q.d), q.want, 1e-9);      // never slips between two triangles
    NEAR(pr.reach(q.p, q.d), q.want, 1e-9);
    NEAR(pr.reach_by_walk(q.p, q.d, pr.depth(q.p)), q.want, 2e-6);
  }
  // A line that only touches the surface has reached it (a point on the surface is not
  // inside): through the inside corner's edge with material either side of it. A
  // thousandth to one side it runs on to the far face; to the other, into the notch.
  NEAR(pr.reach_by_line({10, 30, 5}, {r, -r, 0}), std::sqrt(200.0), 1e-9);
  NEAR(pr.reach_by_line({10, 29.999, 5}, {r, -r, 0}), 29.999 / r, 1e-9);
  NEAR(pr.reach_by_line({10, 30.001, 5}, {r, -r, 0}), 10.0 / r, 1e-9);
  // Any line, from any point: the line and the walk agree; where they do not, the walk
  // has stepped over air the line met (it never steps under 0.01 mm).
  unsigned long long seed = 12345;
  auto rnd = [&]() {
    seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    return static_cast<double>(seed >> 11) / 9007199254740992.0;
  };
  int tried = 0;
  while (tried < 4000) {
    Vec3 p{60 * rnd(), 60 * rnd(), 10 * rnd()};
    if (tried % 2) p = Vec3{std::round(p.x), std::round(p.y), std::round(p.z)};
    const double dp = pr.depth(p);
    if (dp <= 1e-6) continue;
    ++tried;
    const double z = 2 * rnd() - 1, t = 6.283185307179586 * rnd(), s = std::sqrt(1 - z * z);
    const Vec3 d{s * std::cos(t), s * std::sin(t), z};
    const double line = pr.reach_by_line(p, d), walk = pr.reach_by_walk(p, d, dp);
    CHECK(line >= dp - 1e-9);          // nothing nearer than the depth is surface
    CHECK(line <= walk + 1e-5);
    if (walk - line > 1e-5) {
      const double e = line + 1e-6;
      CHECK(pr.depth({p.x + d.x * e, p.y + d.y * e, p.z + d.z * e}) <= 1e-9);
    }
  }
  // Inside by more than a micron, read without a distance: the same answer as the
  // distance gives, on faces, edges and corners and a hair either side of them.
  int in = 0, out = 0;
  for (double x = -2.5; x <= 62.5; x += 2.5)
    for (double y = -2.5; y <= 62.5; y += 2.5)
      for (double z : {-1.0, 0.0, 1e-7, 1e-5, 5.0, 10.0 - 1e-5, 10.0 - 1e-7, 10.0, 11.0})
        for (double e : {0.0, 1e-7, -1e-7, 1e-5, -1e-5}) {
          const Vec3 p{x + e, y - e, z};
          const bool by_depth = pr.depth(p) > 1e-6;
          CHECK(pr.inside(p) == by_depth);
          ++(by_depth ? in : out);
        }
  CHECK(in > 1000 && out > 1000);
  CHECK(!pr.inside({1000, 0, 0}));   // far outside the part's own box
  // The depth read only as far as asked: the depth where it is under the limit, the limit
  // where it is not.
  for (double x = 0.3; x < 60; x += 1.7)
    for (double y = 0.2; y < 60; y += 1.9)
      for (double z : {0.4, 3.0, 5.0, 9.8}) {
        const Vec3 p{x, y, z};
        const double depth = pr.depth(p);
        if (depth <= 0.0) continue;
        for (double limit : {0.5, 0.9, 2.5, 30.0}) NEAR(pr.depth_up_to(p, limit), std::min(depth, limit), 1e-9);
      }
  // "No narrower than": the answer a caller acts on is the same, read more cheaply.
  PartMeasure bx(weld_mesh(box(20, 40, 10)));
  auto pb = bx.probe();
  {
    // A point in the notch of an L (outside the part, inside its box) whose line only
    // brushes the part, exactly through the edge between the notch's wall x = 0 (seen from
    // outside) and the top (seen from inside): not inside.
    PartMeasure notch(weld_mesh(prism({{20, 60}, {-40, 60}, {-40, 40}, {0, 40}, {0, 0}, {20, 0}}, 0, 10)));
    auto pn = notch.probe();
    const Vec3 d = PartMeasure::Probe::inside_line();
    const Vec3 p{-(d.x / d.z) * 4.0, 20.0 - (d.y / d.z) * 4.0, 6.0};
    CHECK(pn.depth(p) < -1.0);
    NEAR(pn.reach_by_line(p, d), 4.0 / d.z, 1e-9);   // it does meet the edge
    CHECK(!pn.inside(p));
    CHECK(pn.inside({10, 20, 5}) && !pn.inside({-20, 20, 5}) && pn.inside({-20, 50, 5}));
  }
  for (const Vec3& p : {Vec3{1, 1, 5}, Vec3{10, 20, 5}, Vec3{3, 31, 2}, Vec3{19, 39, 9}, Vec3{10, 1, 1}})
    for (double w : {0.5, 2.0, 5.0, 10.0, 15.0, 100.0})
      NEAR(std::min(w, pb.thickness(p, w)), std::min(w, pb.thickness(p)), 1e-9);
  // Beside an upright edge the shortest line clips the corner (2.83 mm) and is not the
  // wall; the wall is the 10 mm plate, whether or not a caller asked "no narrower than 5".
  NEAR(pb.thickness({1, 1, 5}), 10.0, 1e-6);
  NEAR(pb.thickness({1, 1, 5}, 5.0), 10.0, 1e-6);
  CHECK(pb.thickness({1, 1, 5}, 2.0) >= 2.0);

  // Domain::Near: a point it rules out is farther from the surface than the distance
  // asked; and it does rule points out.
  MeshSink one;
  one.add_triangle({0, 0, 0}, {30, 0, 0}, {0, 30, 10});
  one.add_triangle({30, 0, 0}, {30, 30, 10}, {0, 30, 10});
  const Domain::Near near(one.mesh, 2.0);
  const MeshDistance md(one.mesh);
  int ruled_out = 0, kept = 0;
  for (double x = -6; x <= 36; x += 0.75)
    for (double y = -6; y <= 36; y += 0.75)
      for (double z = -6; z <= 16; z += 0.75) {
        const Vec3 p{x, y, z};
        if (near.maybe(p)) { ++kept; continue; }
        ++ruled_out;
        CHECK(md.unsigned_distance(p) > 2.0);
      }
  CHECK(ruled_out > 1000 && kept > 1000);
  CHECK(near.maybe({10, 10, 10.0 / 3.0}));   // on the surface itself
  CHECK(!Domain::Near().maybe({0, 0, 0}));   // no surface: nothing is near
}

static void test_domain() {
  PartMeasure pm(weld_mesh(box(40, 40, 20)));
  const Vec3 top{20, 20, 20}, down{0, 0, -1};
  // The top face's own two triangles, for Protect skin.
  TriangleMesh topFace;
  topFace.vertices = {{0, 0, 20}, {40, 0, 20}, {40, 40, 20}, {0, 40, 20}};
  topFace.triangles = {{0, 1, 2}, {0, 2, 3}};

  {  // D12, D2: All solid, nothing asked.
    Domain d(pm, {});
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 10}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({20, 20, 21}) == Where{Why::Outside, 0}));
  }
  {  // A point on the surface itself is not inside the part.
    DomainSpec s;
    s.start = Start::AllLattice;
    Domain d(pm, s);
    CHECK((d.probe().where({20, 20, 20}) == Where{Why::Outside, 0}));
    CHECK((d.probe().where({0, 20, 10}) == Where{Why::Outside, 0}));
  }
  {  // D4: All lattice, one layout for the whole part.
    DomainSpec s;
    s.start = Start::AllLattice;
    Domain d(pm, s);
    CHECK((d.probe().where({3, 37, 1}) == Where{Why::Lattice, 0}));
  }
  {  // D12: a Lattice prism of 8 mm under the top face, and nothing else.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 8)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 15}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({20, 20, 12.0001}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({20, 20, 11.9999}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({20, 20, 20.5}) == Where{Why::Outside, 0}));   // D2: never adds material
  }
  {  // D6: No lattice beats Lattice.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 8),
                 face_region(2, Role::NoLattice, {0, 20, 10}, {1, 0, 0}, 20, 20, 5)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({2, 20, 15}) == Where{Why::NoLattice, 2}));
    CHECK((pr.where({6, 20, 15}) == Where{Why::Lattice, 1}));
  }
  {  // D5: Protect skin, solid to exactly 1.2 mm, lattice right behind it. D15: one slab.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 8)};
    s.protect = {{7, topFace, 1.2}};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 18.801}) == Where{Why::ProtectSkin, 7}));
    CHECK((pr.where({20, 20, 18.799}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({3, 33, 18.801}) == Where{Why::ProtectSkin, 7}));
    CHECK((pr.where({20, 20, 12.5}) == Where{Why::Lattice, 1}));   // the slab's depth is still 8
  }
  {  // D5: at 0 mm, the thinnest face that prints: two line widths.
    DomainSpec s;
    s.start = Start::AllLattice;
    s.bead_mm = 0.45;
    s.protect = {{7, topFace, 0.0}};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 19.101}) == Where{Why::ProtectSkin, 7}));
    CHECK((pr.where({20, 20, 19.099}) == Where{Why::Lattice, 0}));
    s.bead_mm = 0.60;
    Domain d2(pm, s);
    CHECK((d2.probe().where({20, 20, 18.801}) == Where{Why::ProtectSkin, 7}));
    CHECK((d2.probe().where({20, 20, 18.799}) == Where{Why::Lattice, 0}));
  }
  {  // D6: two prisms overlap; the nearer face owns the point.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 12),            // z 8..20
                 face_region(3, Role::Lattice, {20, 20, 0}, {0, 0, 1}, 20, 20, 15)};  // z 0..15
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 9}) == Where{Why::Lattice, 3}));     // 9 from the bottom, 11 from the top
    CHECK((pr.where({20, 20, 14}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({20, 20, 4}) == Where{Why::Lattice, 3}));
    CHECK((pr.where({20, 20, 18}) == Where{Why::Lattice, 1}));
  }
  {  // D6: two prisms on ONE face plane; the deeper owns the overlap.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 8),
                 face_region(4, Role::Lattice, top, down, 5, 5, 12)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 15}) == Where{Why::Lattice, 4}));
    CHECK((pr.where({30, 30, 15}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({20, 20, 10}) == Where{Why::Lattice, 4}));
  }
  {  // D13: the order the regions are listed in never changes an answer.
    std::vector<Region> a = {face_region(1, Role::Lattice, top, down, 20, 20, 12),
                             face_region(2, Role::NoLattice, {0, 20, 10}, {1, 0, 0}, 20, 20, 5),
                             face_region(3, Role::Lattice, {20, 20, 0}, {0, 0, 1}, 20, 20, 15),
                             face_region(4, Role::Lattice, top, down, 5, 5, 16)};
    DomainSpec s1, s2;
    s1.regions = a;
    s2.regions.assign(a.rbegin(), a.rend());
    Domain d1(pm, s1), d2(pm, s2);
    auto p1 = d1.probe(), p2 = d2.probe();
    int differ = 0, lattice = 0;
    for (int i = 0; i < 20; ++i)
      for (int j = 0; j < 20; ++j)
        for (int k = 0; k < 20; ++k) {
          const Vec3 p{1.0 + 2.0 * i, 1.0 + 2.0 * j, 0.5 + 1.0 * k};
          const Where w1 = p1.where(p), w2 = p2.where(p);
          if (!(w1 == w2)) ++differ;
          if (w1.lattice()) ++lattice;
        }
    CHECK(differ == 0);
    CHECK(lattice > 0);
  }
  {  // D11: Expand moves the edge in the face's plane by exactly e; the depth stays.
    for (double e : {2.0, -2.0}) {
      DomainSpec s;
      s.regions = {face_region(1, Role::Lattice, top, down, 10, 10, 8, e)};
      Domain d(pm, s);
      auto pr = d.probe();
      const double edge = 10 + e;
      CHECK((pr.where({20 + edge - 0.01, 20, 15}) == Where{Why::Lattice, 1}));
      CHECK((pr.where({20 + edge + 0.01, 20, 15}) == Where{Why::NotAsked, 0}));
      CHECK((pr.where({20, 20 - edge + 0.01, 15}) == Where{Why::Lattice, 1}));
      CHECK((pr.where({20, 20 - edge - 0.01, 15}) == Where{Why::NotAsked, 0}));
      CHECK((pr.where({20, 20, 12.01}) == Where{Why::Lattice, 1}));
      CHECK((pr.where({20, 20, 11.99}) == Where{Why::NotAsked, 0}));
    }
    // Expand 0 is the old predicate itself.
    const Region r0 = face_region(1, Role::Lattice, top, down, 10, 10, 8, 0.0);
    int differ = 0;
    for (int i = 0; i < 41; ++i)
      for (int j = 0; j < 41; ++j)
        for (int k = 0; k < 21; ++k) {
          const Vec3 p{1.0 * i, 1.0 * j, 1.0 * k};
          if (region_contains(r0, p) != point_in_clearance_region(r0.prism, p, 0.0)) ++differ;
        }
    CHECK(differ == 0);
  }
}

// A model by hand, as the STEP importer would hand it over: triangles tagged with the
// face they belong to, and each face's plane.
struct ModelBuilder {
  StepModel m;
  int face(StepSurfaceKind kind, Vec3 outward, Vec3 origin) {
    StepFaceInfo f;
    f.kind = kind;
    f.plane_normal = outward;
    f.plane_origin = origin;
    m.faces.push_back(f);
    return m.face_count++;
  }
  void tri(int f, Vec3 a, Vec3 b, Vec3 c) {
    const int n = (int)m.mesh.vertices.size();
    m.mesh.vertices.insert(m.mesh.vertices.end(), {a, b, c});
    m.mesh.triangles.push_back({n, n + 1, n + 2});
    m.triangle_face.push_back(f);
  }
  void quad(int f, Vec3 a, Vec3 b, Vec3 c, Vec3 d) { tri(f, a, b, c); tri(f, a, c, d); }
};

// A 60 x 60 x 10 plate whose top is TWO faces: an L (the two 20 mm arms) and the 40 mm
// square the L wraps. The rectangle around the L covers the square too.
static StepModel plate_with_L_face(int* L, int* square, int* sideA, int* sideB) {
  ModelBuilder b;
  const double z = 10;
  *L = b.face(StepSurfaceKind::Plane, {0, 0, 1}, {0, 0, z});
  b.quad(*L, {0, 0, z}, {20, 0, z}, {20, 20, z}, {0, 20, z});
  b.quad(*L, {20, 0, z}, {60, 0, z}, {60, 20, z}, {20, 20, z});
  b.quad(*L, {0, 20, z}, {20, 20, z}, {20, 60, z}, {0, 60, z});
  *square = b.face(StepSurfaceKind::Plane, {0, 0, 1}, {20, 20, z});
  b.quad(*square, {20, 20, z}, {60, 20, z}, {60, 60, z}, {20, 60, z});
  const int bottom = b.face(StepSurfaceKind::Plane, {0, 0, -1}, {0, 0, 0});
  b.tri(bottom, {60, 0, 0}, {0, 0, 0}, {0, 20, 0});
  b.tri(bottom, {60, 0, 0}, {0, 20, 0}, {0, 60, 0});
  b.tri(bottom, {60, 0, 0}, {0, 60, 0}, {60, 60, 0});
  // A side whose top edge has a vertex where two top faces meet: three triangles from
  // one bottom corner, so every edge is shared by exactly two triangles.
  auto side_of = [&](int f, Vec3 bl, Vec3 br, Vec3 tr, Vec3 tm, Vec3 tl) {
    b.tri(f, bl, br, tr);
    b.tri(f, bl, tr, tm);
    b.tri(f, bl, tm, tl);
  };
  // The x = 0 side is TWO faces (y 0..20 and y 20..60), tagged as CURVED on purpose
  // (they are flat; the tag is what the code reads), to exercise the curved path with
  // distances that are easy to state.
  *sideA = b.face(StepSurfaceKind::Other, {0, 0, 0}, {0, 0, 0});
  b.quad(*sideA, {0, 20, 0}, {0, 0, 0}, {0, 0, z}, {0, 20, z});
  *sideB = b.face(StepSurfaceKind::Other, {0, 0, 0}, {0, 0, 0});
  b.quad(*sideB, {0, 60, 0}, {0, 20, 0}, {0, 20, z}, {0, 60, z});
  const int rest = b.face(StepSurfaceKind::Other, {0, 0, 0}, {0, 0, 0});
  side_of(rest, {0, 0, 0}, {60, 0, 0}, {60, 0, z}, {20, 0, z}, {0, 0, z});
  side_of(rest, {60, 0, 0}, {60, 60, 0}, {60, 60, z}, {60, 20, z}, {60, 0, z});
  side_of(rest, {60, 60, 0}, {0, 60, 0}, {0, 60, z}, {20, 60, z}, {60, 60, z});
  return b.m;
}

static void test_face_regions() {
  int L = -1, square = -1, sideA = -1, sideB = -1;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  std::size_t open = 99;
  PartMeasure pm(weld_mesh(model.mesh, 1e-5, &open));
  CHECK(open == 0);

  {  // D10: the region has the shape of the face, never the rectangle around it.
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 6, 0.0, &ok)};
    CHECK(ok);
    CHECK(!s.regions[0].is_shell());
    CHECK(s.regions[0].prism.outline_uv.size() == 1);
    CHECK(s.regions[0].prism.outline_uv[0].size() >= 6);
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({40, 10, 8}) == Where{Why::Lattice, 1}));    // under one arm
    CHECK((pr.where({10, 40, 8}) == Where{Why::Lattice, 1}));    // under the other
    CHECK((pr.where({40, 40, 8}) == Where{Why::NotAsked, 0}));   // under the square: not the L
    CHECK((pr.where({20.05, 40, 8}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({19.95, 40, 8}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({40, 10, 4.05}) == Where{Why::Lattice, 1})); // 6 mm INTO the material
    CHECK((pr.where({40, 10, 3.95}) == Where{Why::NotAsked, 0}));
  }
  {  // D11 on a true outline: Expand moves the L's edge by e, inner corner included.
    DomainSpec s;
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 6, 3.0)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({22.9, 40, 8}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({23.1, 40, 8}) == Where{Why::NotAsked, 0}));
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 6, -3.0)};
    Domain d2(pm, s);
    auto p2 = d2.probe();
    CHECK((p2.where({16.9, 40, 8}) == Where{Why::Lattice, 1}));
    CHECK((p2.where({17.1, 40, 8}) == Where{Why::NotAsked, 0}));
    CHECK((p2.where({2.9, 40, 8}) == Where{Why::NotAsked, 0}));   // the part's own edge moves in too
    CHECK((p2.where({3.1, 40, 8}) == Where{Why::Lattice, 1}));
  }
  {  // D20: a curved face. The region follows the face in by the depth and stops at
     // the face's own outline.
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_face(model, sideA, 2, Role::Lattice, 5, 0.0, &ok)};   // y 0..20
    CHECK(ok);
    CHECK(s.regions[0].is_shell());
    CHECK(s.regions[0].shell_edge.size() == 4);
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({4.99, 10, 5}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({5.01, 10, 5}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({3, 19.9, 5}) == Where{Why::Lattice, 2}));
    // 3.6 mm from the face, but past its edge: not under it.
    CHECK((pr.where({3, 22, 5}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({3, 20.1, 5}) == Where{Why::NotAsked, 0}));
  }
  {  // D11 on a curved face: a negative Expand pulls the region in from the outline.
    DomainSpec s;
    s.regions = {region_from_face(model, sideA, 2, Role::Lattice, 5, -2.0)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({3, 17.9, 5}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({3, 18.1, 5}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({3, 10, 7.9}) == Where{Why::Lattice, 2}));    // 2 mm in from the top edge
    CHECK((pr.where({3, 10, 8.1}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({4.9, 10, 5}) == Where{Why::Lattice, 2}));    // the depth is unchanged
    // A positive Expand cannot be done on a curved face yet: ignored, and it says so.
    const Region up = region_from_face(model, sideA, 2, Role::Lattice, 5, 2.0);
    CHECK(up.expand_ignored && up.expand_mm == 0.0);
  }
  {  // D20: two curved faces joined are ONE region: one outline, nothing lost at the seam.
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_faces(model, {sideB, sideA}, 2, Role::Lattice, 5, 0.0, &ok)};
    CHECK(ok);
    CHECK(s.regions[0].is_shell());
    CHECK(s.regions[0].shell_edge.size() == 6);                   // the seam is not a border
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({3, 20, 5}) == Where{Why::Lattice, 2}));      // right under the seam
    CHECK((pr.where({3, 22, 5}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({4.99, 30, 5}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({5.01, 30, 5}) == Where{Why::NotAsked, 0}));
    // Joined and pulled in 2 mm: the seam still is not an edge.
    s.regions = {region_from_faces(model, {sideA, sideB}, 2, Role::Lattice, 5, -2.0)};
    Domain d2(pm, s);
    CHECK((d2.probe().where({3, 20, 5}) == Where{Why::Lattice, 2}));
    CHECK((d2.probe().where({3, 1.9, 5}) == Where{Why::NotAsked, 0}));
    // ... and as No lattice it beats a Lattice prism (D6).
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 6),
                 region_from_faces(model, {sideA, sideB}, 2, Role::NoLattice, 5)};
    Domain d3(pm, s);
    CHECK((d3.probe().where({3, 30, 8}) == Where{Why::NoLattice, 2}));
    CHECK((d3.probe().where({7, 30, 8}) == Where{Why::Lattice, 1}));
  }
  {  // D20: two FLAT faces in one plane joined are one prism with one outline.
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_faces(model, {L, square}, 1, Role::Lattice, 6, -3.0, &ok)};
    CHECK(ok);
    CHECK(!s.regions[0].is_shell());
    CHECK(s.regions[0].prism.outline_uv.size() == 1);
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 40, 8}) == Where{Why::Lattice, 1}));     // on the seam, pulled in 3: still in
    CHECK((pr.where({40, 40, 8}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({2.9, 40, 8}) == Where{Why::NotAsked, 0}));   // the true edge moved in
    CHECK((pr.where({3.1, 40, 8}) == Where{Why::Lattice, 1}));
  }
  {  // D20: faces at an angle joined (the top and a side): one region around the corner.
    DomainSpec s;
    s.regions = {region_from_faces(model, {L, square, sideA, sideB}, 1, Role::Lattice, 4)};
    CHECK(s.regions[0].is_shell());
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({30, 30, 7}) == Where{Why::Lattice, 1}));     // under the top
    CHECK((pr.where({2, 30, 3}) == Where{Why::Lattice, 1}));      // behind the side
    CHECK((pr.where({2, 30, 8.5}) == Where{Why::Lattice, 1}));    // in the corner between them
    CHECK((pr.where({30, 30, 5.9}) == Where{Why::NotAsked, 0}));
  }
  {  // D19: under All lattice a shrunk prism leaves lattice behind, not solid.
    DomainSpec s;
    s.start = Start::AllLattice;
    s.regions = {region_from_faces(model, {L, square}, 1, Role::Lattice, 6, -3.0)};
    Domain d(pm, s);
    CHECK((d.probe().where({1.5, 40, 8}) == Where{Why::Lattice, 0}));
    CHECK((d.probe().where({10, 40, 8}) == Where{Why::Lattice, 1}));
    s.start = Start::AllSolid;
    Domain d2(pm, s);
    CHECK((d2.probe().where({1.5, 40, 8}) == Where{Why::NotAsked, 0}));
  }
  {  // Protect skin from the model's own faces (D5).
    DomainSpec s;
    s.start = Start::AllLattice;
    s.protect = {{9, faces_mesh(model, {L, square}), 1.5}};
    Domain d(pm, s);
    CHECK((d.probe().where({40, 40, 8.51}) == Where{Why::ProtectSkin, 9}));
    CHECK((d.probe().where({40, 40, 8.49}) == Where{Why::Lattice, 0}));
  }
  {  // A face that does not exist, or a depth of nothing, gives no region.
    bool ok = true;
    region_from_face(model, 99, 1, Role::Lattice, 6, 0.0, &ok);
    CHECK(!ok);
    ok = true;
    region_from_face(model, L, 1, Role::Lattice, 0.0, 0.0, &ok);
    CHECK(!ok);
  }
}

static void test_pocket_and_thin_wall() {
  // A 10 mm wall and a 20 mm wall, 40 tall, around an open pocket.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 10}, {20, 10}, {20, 60}, {0, 60}}, 0, 40)));
  {  // D7: a prism that spans the pocket puts nothing in it.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 30, 40}, {0, 0, -1}, 30, 30, 40)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({40, 40, 20}) == Where{Why::Outside, 0}));
    CHECK((pr.where({40, 5, 20}) == Where{Why::Lattice, 1}));
  }
  {  // D8: All lattice, walls under 15 mm go solid; the wall is read straight through it.
    DomainSpec s;
    s.start = Start::AllLattice;
    s.min_wall_mm = 15.0;
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({40, 3, 20}) == Where{Why::WallTooThin, 0}));    // the 10 mm wall
    CHECK((pr.where({45, 7.5, 12}) == Where{Why::WallTooThin, 0}));
    CHECK((pr.where({8, 40, 20}) == Where{Why::Lattice, 0}));        // the 20 mm wall
    CHECK((pr.where({14, 35, 25}) == Where{Why::Lattice, 0}));
    // At the END of the thin wall the nearest surface is the end face; the wall is
    // still 10 mm. (Seen on the stand's 3 mm plate, 2026-11-10.)
    CHECK((pr.where({58.5, 5, 20}) == Where{Why::WallTooThin, 0}));
    CHECK((pr.where({40, 5, 39}) == Where{Why::WallTooThin, 0}));
    NEAR(pr.part().thickness({58.5, 5, 20}), 10.0, 0.01);
    NEAR(pr.part().thickness({8, 40, 20}), 20.0, 0.01);
    NEAR(pr.part().thickness({59, 1, 20}), 10.0, 0.01);    // right in the wall's end corner
    // Where the two walls meet the material is not a thin wall: nothing there is under 15.
    CHECK(pr.part().thickness({5, 5, 20}) >= 15.0);
    CHECK((pr.where({5, 5, 20}) == Where{Why::Lattice, 0}));
    s.min_wall_mm = 0.0;                                             // off: asked means latticed
    Domain d0(pm, s);
    CHECK((d0.probe().where({40, 3, 20}) == Where{Why::Lattice, 0}));
  }
  {  // A plate with a slanted back (a countersink in cross-section): 3 mm at one end,
     // 9 mm at the other. The width square to the flat face is the wall at each spot.
    PartMeasure wedge(weld_mesh(prism({{0, 0}, {60, 0}, {60, 9}, {0, 3}}, 0, 40)));
    auto w = wedge.probe();
    NEAR(w.thickness({10, 1, 20}), 4.0, 0.01);
    NEAR(w.thickness({50, 1, 20}), 8.0, 0.01);
    NEAR(w.thickness({30, 4, 20}), 6.0, 0.01);
    // A back that rises at 45 degrees from a 3 mm plate (the stand's countersunk holes,
    // 2026-11-10). No line is square to both surfaces; the width square to the slope
    // is the narrowest wall there: 4.5 * sqrt(2).
    PartMeasure sunk(weld_mesh(prism({{20, 0}, {20, 13}, {10, 3}, {0, 3}, {0, 0}}, 0, 40)));
    NEAR(sunk.probe().thickness({15, 1, 20}), 4.5 * std::sqrt(2.0), 0.01);
    NEAR(sunk.probe().thickness({4, 1, 20}), 3.0, 0.01);
  }
  {  // D8 under a prism: the wall is read along the prism's own direction (C11).
    DomainSpec s;
    s.min_wall_mm = 15.0;
    // From the y = 0 side, 10 mm deep: that wall is 10 mm along y where the pocket is
    // behind it, and 60 mm along y in the 20 mm arm.
    s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 20, 10)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({40, 5, 20}) == Where{Why::WallTooThin, 1}));
    CHECK((pr.where({10, 5, 20}) == Where{Why::Lattice, 1}));
  }
}

// ── stage C: cells ────────────────────────────────────────────────────────────
// How many cells of `region` hold the point. The layout is right when the owner of
// every lattice point holds it in exactly one cell: no gap, no overlap.
static int cells_holding(const Layout& l, const Vec3& p, int region) {
  int n = 0;
  for (const Cell& c : l.cells) {
    if (c.region != region) continue;
    const Frame& f = l.frames[c.frame];
    const Vec3 r{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
    const double q[3] = {r.x * f.ax[0].x + r.y * f.ax[0].y + r.z * f.ax[0].z,
                         r.x * f.ax[1].x + r.y * f.ax[1].y + r.z * f.ax[1].z,
                         r.x * f.ax[2].x + r.y * f.ax[2].y + r.z * f.ax[2].z};
    bool in = true;
    for (int a = 0; a < 3; ++a) in = in && q[a] >= c.lo[a] && q[a] < c.lo[a] + c.size;
    if (in) ++n;
  }
  return n;
}
static Vec3 cell_centre(const Layout& l, const Cell& c) {
  return l.frames[c.frame].at(c.lo[0] + 0.5 * c.size, c.lo[1] + 0.5 * c.size, c.lo[2] + 0.5 * c.size);
}
// Over a lattice of probe points: points whose owner does not hold them in exactly one
// cell, not counting points in space the layout itself lists as solid (D14).
// A cell counts where it truly is: the part of its cube that is its own wall's lattice
// (cell_holds). Two walls' cut cells overlap as cubes where the walls meet, never as that.
static int badly_covered(const Domain& d, const Layout& l, Vec3 lo, Vec3 hi, double step) {
  auto pr = d.probe();
  int bad = 0;
  for (double x = lo.x + 0.37; x < hi.x; x += step)
    for (double y = lo.y + 0.41; y < hi.y; y += step)
      for (double z = lo.z + 0.43; z < hi.z; z += step) {
        const Where w = pr.where({x, y, z});
        if (!w.lattice()) continue;
        int held = 0;
        for (const Cell& c : l.cells)
          if (c.region == w.id && cell_holds(l, pr, c, {x, y, z})) ++held;
        if (held == 1) continue;
        Layout as_solid;
        as_solid.frames = l.frames;
        as_solid.cells = l.solid;
        if (held == 0 && cells_holding(as_solid, {x, y, z}, w.id) == 1) continue;
        ++bad;
      }
  return bad;
}

// Single-cell walls switched off (C3). The spec's own default is one across (C4).
static CellSpec two_across() {
  CellSpec c;
  c.min_cells_across = 2;
  return c;
}

static void test_cells_prism() {
  PartMeasure pm(weld_mesh(box(40, 40, 20)));
  const Vec3 top{20, 20, 20}, down{0, 0, -1};
  {  // C3, C15, C1: an 8 mm wall holds 2 cells across: 4 mm cells, 10 x 10 x 2 of them.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 8)};
    Domain d(pm, s);
    CellSpec cs = two_across();
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 8;
    const Layout l = lay_cells(d, cs);
    NEAR(l.floor_cell_mm, 0.45 * 5.268704, 1e-5);          // C14
    CHECK(l.cells.size() == 200);
    CHECK(l.solid.empty());
    CHECK(l.regions.size() == 1 && l.regions[0].region == 1);
    NEAR(l.regions[0].base_cell_mm, 4.0, 1e-9);
    int odd = 0;
    for (const Cell& c : l.cells) {
      if (std::fabs(c.size - 4.0) > 1e-9 || c.cut || c.region != 1) ++odd;
      // C15: the face and the far side of the wall are cell boundaries.
      if (std::fabs(c.lo[2] - 0.0) > 1e-9 && std::fabs(c.lo[2] - 4.0) > 1e-9) ++odd;
    }
    CHECK(odd == 0);
    CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 20}, 1.7) == 0);
  }
  {  // C2: "a 13mm cell never be on a 12mm wall; instead have a 12mm cell on the 12mm wall".
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 12)};
    Domain d(pm, s);
    CellSpec cs = two_across();
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 13;
    cs.min_cells_across = 1;                               // C4: single-cell members
    const Layout l = lay_cells(d, cs);
    CHECK(!l.cells.empty());
    for (const Cell& c : l.cells) NEAR(c.size, 12.0, 1e-9);
    cs.cell_max_mm = 8;                                    // C3: two across -> 6 mm
    cs.min_cells_across = 2;
    const Layout l2 = lay_cells(d, cs);
    CHECK(!l2.cells.empty());
    for (const Cell& c : l2.cells) NEAR(c.size, 6.0, 1e-9);
    cs.min_cells_across = 5;                               // C5: five across -> 2.4 mm
    const Layout l5 = lay_cells(d, cs);
    CHECK(!l5.cells.empty());
    for (const Cell& c : l5.cells) NEAR(c.size, 2.4, 1e-9);
  }
  {  // C9: a symmetric face gets a symmetric layout, whether or not the cells divide it.
    PartMeasure wide(weld_mesh(box(41, 40, 20)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {20.5, 20, 20}, down, 21, 21, 8)};      // covers the whole face
    Domain d(wide, s);
    CellSpec cs = two_across();
    cs.algorithm = Algorithm::Uniform;
    const Layout l = lay_cells(d, cs);
    CHECK(!l.cells.empty());
    int unmatched = 0, cut = 0;
    for (const Cell& c : l.cells) {
      if (c.cut) ++cut;
      bool found = false;
      for (const Cell& o : l.cells)
        if (std::fabs(o.lo[0] + o.size + c.lo[0]) < 1e-9 && std::fabs(o.lo[1] + o.size + c.lo[1]) < 1e-9 &&
            std::fabs(o.lo[2] - c.lo[2]) < 1e-9 && o.size == c.size && o.cut == c.cut)
          found = true;
      if (!found) ++unmatched;
    }
    CHECK(unmatched == 0);
    CHECK(cut > 0);   // D3: the cells at the edge are whole cells, cut
    CHECK(badly_covered(d, l, {0, 0, 0}, {41, 40, 20}, 1.7) == 0);
  }
  {  // D13, D18: two regions that overlap. The order they are listed in, and running
     // twice, change nothing; every lattice point is held once by its owner.
    std::vector<Region> a = {face_region(1, Role::Lattice, top, down, 20, 20, 12),
                             face_region(3, Role::Lattice, {20, 20, 0}, {0, 0, 1}, 20, 20, 15)};
    DomainSpec s1, s2;
    s1.regions = a;
    s2.regions.assign(a.rbegin(), a.rend());
    Domain d1(pm, s1), d2(pm, s2);
    CellSpec cs = two_across();
    cs.algorithm = Algorithm::Uniform;
    const Layout l1 = lay_cells(d1, cs), l2 = lay_cells(d2, cs), l3 = lay_cells(d1, cs);
    CHECK(l1.cells.size() > 100);
    CHECK(l1.cells == l2.cells);
    CHECK(l1.cells == l3.cells);
    CHECK(badly_covered(d1, l1, {0, 0, 0}, {40, 40, 20}, 1.7) == 0);
    // No region lays a whole cell in space another region owns.
    int trespass = 0;
    auto pr = d1.probe();
    for (const Cell& c : l1.cells)
      if (!c.cut && !(pr.where(cell_centre(l1, c)) == Where{Why::Lattice, c.region})) ++trespass;
    CHECK(trespass == 0);
  }
}

static void test_cells_walls_under_a_face() {
  // Behind the y = 0 face the material is 12 mm for x < 30 and 6 mm for x > 30.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 6}, {30, 6}, {30, 12}, {0, 12}}, 0, 40)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 12)};   // covers the whole face
  Domain d(pm, s);
  for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade}) {
    // C11, C12, C15 (settled 2026-11-10, item 6): each wall's cells divide THAT wall.
    // Two across: 6 mm cells in the 12 mm wall, 3 mm cells in the 6 mm wall.
    CellSpec cs = two_across();
    cs.algorithm = algo;
    const Layout l = lay_cells(d, cs);
    CHECK(l.solid.empty());
    int wrong_size = 0, off_wall = 0, thick = 0, thin = 0, cut = 0;
    for (const Cell& c : l.cells) {
      const Vec3 m = cell_centre(l, c);
      const double want = m.x < 30 ? 6.0 : 3.0, wall = m.x < 30 ? 12.0 : 6.0;
      if (std::fabs(c.size - want) > 1e-9) ++wrong_size;
      (m.x < 30 ? thick : thin) += 1;
      // The face and the wall's far side are cell boundaries: depth is a whole number
      // of cells, and no cell reaches past the wall.
      const double layer = c.lo[2] / c.size;
      if (std::fabs(layer - std::round(layer)) > 1e-9 || c.lo[2] + c.size > wall + 1e-9) ++off_wall;
      if (c.cut) ++cut;
    }
    CHECK(wrong_size == 0);
    CHECK(off_wall == 0);
    // 30 x 40 of face each: 5 x 7 x 2 cells of 6 mm (40 is not a multiple of 6: seven,
    // the two end rows cut), and 10 x 14 x 2 cells of 3 mm (fourteen, likewise).
    CHECK(thick == 5 * 7 * 2);
    CHECK(thin == 10 * 14 * 2);
    CHECK(cut == 5 * 2 * 2 + 10 * 2 * 2);   // only the rows cut by the 40 mm height
    CHECK(badly_covered(d, l, {0, 0, 0}, {60, 12, 40}, 1.3) == 0);
    const Layout again = lay_cells(d, cs);
    CHECK(l.cells == again.cells);          // D18
    const Layout one = lay_cells(d, cs, 1), three = lay_cells(d, cs, 3);   // any number of threads
    CHECK(l.cells == one.cells && l.cells == three.cells && l.solid == one.solid && l.solid == three.solid);
    CHECK(l.regions.size() == one.regions.size() && l.regions[0].cells == one.regions[0].cells &&
          l.regions[0].solid == one.regions[0].solid);
  }
}

static void test_cells_ledge_is_not_a_wall() {
  // A 12 mm wall, a 6 mm wall, and between them a ledge 0.8 mm wide and 7 mm deep that
  // runs the part's whole 60 mm height. A full row of map nodes lands on the ledge, more
  // than enough of them to count as a stretch; it is still not a wall, and no 3.5 mm
  // cells are laid for it.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 6}, {31.2, 6}, {31.2, 7}, {30.4, 7}, {30.4, 12}, {0, 12}}, 0, 60)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {30, 0, 30}, {0, 1, 0}, 30, 30, 12)};
  Domain d(pm, s);
  CellSpec cs = two_across();
  cs.algorithm = Algorithm::Uniform;
  const Layout l = lay_cells(d, cs);
  int ledge_cells = 0, six = 0, three = 0;
  for (const Cell& c : l.cells) {
    if (std::fabs(c.size - 3.5) < 1e-6) ++ledge_cells;
    if (std::fabs(c.size - 6.0) < 1e-9) ++six;
    if (std::fabs(c.size - 3.0) < 1e-9) ++three;
  }
  CHECK(ledge_cells == 0);
  CHECK(six > 80);
  CHECK(three > 300);
}

static void test_cells_whole_part() {
  // A 20 mm wall and a 6 mm wall, 40 tall.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 6}, {20, 6}, {20, 60}, {0, 60}}, 0, 40)));
  DomainSpec s;
  s.start = Start::AllLattice;
  Domain d(pm, s);
  const double floor_cell = 0.45 * 5.268704;
  {  // C7, C17, C12: Default Grade. The base is the floor doubled (4.74 mm, the largest
     // under 8 whose halves land on the floor); the thin wall takes the half.
    CellSpec cs = two_across();   // Default Grade, Auto, up to 8 mm, two across
    const Layout l = lay_cells(d, cs);
    CHECK(l.regions.size() == 1 && l.regions[0].region == 0);
    NEAR(l.regions[0].base_cell_mm, 2 * floor_cell, 1e-5);
    int big_in_thin = 0, small_in_thick = 0, off_ladder = 0, too_wide = 0, below_floor = 0;
    auto pr = d.probe();
    for (const Cell& c : l.cells) {
      const bool is_base = std::fabs(c.size - 2 * floor_cell) < 1e-5;
      const bool is_half = std::fabs(c.size - floor_cell) < 1e-5;
      if (!is_base && !is_half) ++off_ladder;                 // C7: S, S/2, ...
      if (c.size < floor_cell - 1e-6) ++below_floor;          // C14
      const Vec3 m = cell_centre(l, c);
      if (m.x > 26 && m.y > 0 && m.y < 6 && m.z > 0 && m.z < 40 && !is_half) ++big_in_thin;
      if (m.x > 6 && m.x < 14 && m.y > 14 && m.y < 54 && m.z > 6 && m.z < 34 && !is_base) ++small_in_thick;
      if (pr.part().depth(m) > 0 && c.size > pr.part().thickness(m) / 2 + 1e-6) ++too_wide;   // C3
    }
    CHECK(!l.cells.empty());
    CHECK(off_ladder == 0);
    CHECK(below_floor == 0);
    CHECK(big_in_thin == 0);
    CHECK(small_in_thick == 0);   // C1: no smaller than the wall needs
    CHECK(too_wide == 0);
    CHECK(l.solid.empty());
    CHECK(badly_covered(d, l, {0, 0, 0}, {60, 60, 40}, 2.3) == 0);
  }
  {  // C16, D8, D14: Manual 4 mm is one size everywhere. The 6 mm wall cannot hold two
     // 4 mm cells: it is solid, and listed as solid, not left as a hole.
    CellSpec cs = two_across();
    cs.algorithm = Algorithm::Uniform;
    cs.cell_mm = 4.0;
    const Layout l = lay_cells(d, cs);
    int other_size = 0, cell_in_thin = 0, solid_in_thick = 0;
    for (const Cell& c : l.cells) {
      if (std::fabs(c.size - 4.0) > 1e-9) ++other_size;
      const Vec3 m = cell_centre(l, c);
      if (m.x > 26 && m.y > 0 && m.y < 6) ++cell_in_thin;
    }
    for (const Cell& c : l.solid) {
      const Vec3 m = cell_centre(l, c);
      if (m.x > 6 && m.x < 14 && m.y > 14 && m.y < 54 && m.z > 6 && m.z < 34) ++solid_in_thick;
    }
    CHECK(!l.cells.empty());
    CHECK(other_size == 0);
    CHECK(cell_in_thin == 0);
    CHECK(!l.solid.empty());
    CHECK(solid_in_thick == 0);
    CHECK(l.regions[0].solid == l.solid.size() && l.regions[0].cells == l.cells.size());
    CHECK(badly_covered(d, l, {0, 0, 0}, {60, 60, 40}, 2.3) == 0);
    // C4: with single-cell members the same wall holds one 4 mm cell across.
    cs.min_cells_across = 1;
    const Layout l1 = lay_cells(d, cs);
    int in_thin = 0;
    for (const Cell& c : l1.cells) {
      const Vec3 m = cell_centre(l1, c);
      if (m.x > 26 && m.y > 0 && m.y < 6) ++in_thin;
    }
    CHECK(in_thin > 0);
  }
}

static void test_cells_stepped() {
  // A 20 mm wall and an 8.5 mm wall, 40 tall. Base cell 12 mm, two across.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 8.5}, {20, 8.5}, {20, 60}, {0, 60}}, 0, 40)));
  DomainSpec s;
  s.start = Start::AllLattice;
  Domain d(pm, s);
  CellSpec cs = two_across();
  cs.algorithm = Algorithm::Stepped;
  cs.cell_mm = 12.0;
  const Layout l = lay_cells(d, cs);
  CHECK(!l.cells.empty());
  // C6, C6a: every size is k x (12/n), n = 2..5 at a 0.45 mm line: never 10 or 2 mm.
  const double menu[] = {12, 9.6, 9, 8, 7.2, 6, 4.8, 4, 3, 2.4};
  int off_menu = 0, too_wide = 0, thin_not_4 = 0, thick_not_6 = 0, thin = 0, thick = 0;
  auto pr = d.probe();
  for (const Cell& c : l.cells) {
    bool on = false;
    for (double m : menu) on = on || std::fabs(c.size - m) < 1e-9;
    if (!on) ++off_menu;
    const Vec3 m = cell_centre(l, c);
    if (pr.part().depth(m) > 0 && c.size > pr.part().thickness(m) / 2 + 1e-5) ++too_wide;   // C3
    // The 8.5 mm wall allows 4.25: thirds of 12 (4 mm), not the halves' 3 mm (C6, C1).
    if (m.x > 26 && m.x < 58 && m.y > 0 && m.y < 8.5 && m.z > 0 && m.z < 40) { ++thin; if (std::fabs(c.size - 4.0) > 1e-9) ++thin_not_4; }
    // The 20 mm wall allows 10: halves of 12 (6 mm), the fewest cells that fill it (C6c).
    if (m.x > 6 && m.x < 14 && m.y > 16 && m.y < 54 && m.z > 6 && m.z < 34) { ++thick; if (std::fabs(c.size - 6.0) > 1e-9) ++thick_not_6; }
  }
  CHECK(off_menu == 0);
  CHECK(too_wide == 0);
  CHECK(thin > 20 && thin_not_4 == 0);
  CHECK(thick > 10 && thick_not_6 == 0);
  CHECK(badly_covered(d, l, {0, 0, 0}, {60, 60, 40}, 2.3) == 0);   // no gap, no overlap
  CHECK(l.cells == lay_cells(d, cs).cells);                        // D18

  // "I did not want stepped to look EXACTLY like default" (2026-11-10): the same part
  // under Default Grade takes halves, 3 mm in the thin wall.
  CellSpec dg = cs;
  dg.algorithm = Algorithm::DefaultGrade;
  const Layout h = lay_cells(d, dg);
  int thin_h = 0, thin_h_not_3 = 0;
  for (const Cell& c : h.cells) {
    const Vec3 m = cell_centre(h, c);
    if (m.x > 26 && m.x < 58 && m.y > 0 && m.y < 8.5 && m.z > 0 && m.z < 40) { ++thin_h; if (std::fabs(c.size - 3.0) > 1e-9) ++thin_h_not_3; }
  }
  CHECK(thin_h > 20 && thin_h_not_3 == 0);

  // C6a: a finer line lets sixths back in. A 4.2 mm wall allows 2.1: at 0.45 nothing
  // that small prints open, so it is solid; at 0.35 the sixths (2 mm) fill it.
  PartMeasure slim(weld_mesh(prism({{0, 0}, {60, 0}, {60, 4.2}, {20, 4.2}, {20, 60}, {0, 60}}, 0, 40)));
  for (double bead : {0.45, 0.35}) {
    DomainSpec s2;
    s2.start = Start::AllLattice;
    s2.bead_mm = bead;
    Domain d2(slim, s2);
    const Layout l2 = lay_cells(d2, cs);
    int in_thin = 0, twos = 0;
    for (const Cell& c : l2.cells) {
      const Vec3 m = cell_centre(l2, c);
      if (m.x > 26 && m.x < 58 && m.y > 0 && m.y < 4.2 && m.z > 0 && m.z < 40) { ++in_thin; if (std::fabs(c.size - 2.0) < 1e-9) ++twos; }
    }
    if (bead == 0.45) CHECK(in_thin == 0);
    else CHECK(in_thin > 50 && twos == in_thin);
  }

  // C4: single-cell walls are on unless switched off (his ruling 2026-11-11). The same
  // 4.2 mm wall at a 0.45 mm line, with nothing set: one cell across, never solid.
  // (One size everywhere is not in this list: its Auto size is the thick wall's, C16.)
  {
    DomainSpec s3;
    s3.start = Start::AllLattice;
    Domain d3(slim, s3);
    const double floor_cell = 0.45 * 5.268704;
    for (Algorithm a : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec def;
      def.algorithm = a;
      const Layout l3 = lay_cells(d3, def);
      int in_thin = 0, wrong = 0, solid_in_thin = 0;
      for (const Cell& c : l3.cells) {
        const Vec3 m = cell_centre(l3, c);
        if (m.x > 26 && m.x < 58 && m.y > 0 && m.y < 4.2 && m.z > 0 && m.z < 40) {
          ++in_thin;
          if (c.size > 4.2 + 1e-6 || c.size < floor_cell - 1e-5 || 2 * c.size <= 4.2) ++wrong;
        }
      }
      for (const Cell& c : l3.solid) {
        const Vec3 m = cell_centre(l3, c);
        if (m.x > 26 && m.x < 58 && m.y > 0 && m.y < 4.2 && m.z > 0 && m.z < 40) ++solid_in_thin;
      }
      CHECK(in_thin > 10);
      CHECK(wrong == 0);
      CHECK(solid_in_thin == 0);
    }
  }
}

// A layout written by hand: cells of 12, 6 and 2.4 mm in region 1, 8 and 4 mm in region 2.
static Layout strut_layout(double bead) {
  Layout l;
  l.bead_mm = bead;
  l.floor_cell_mm = bead / 0.1898;
  l.frames.push_back(Frame{});
  double x = 0;
  for (double size : {12.0, 6.0, 6.0, 2.4, 8.0, 4.0}) {
    Cell c;
    c.region = size == 8.0 || size == 4.0 ? 2 : 1;
    c.size = size;
    c.lo[0] = x;
    x += size;
    l.cells.push_back(c);
  }
  return l;
}

static void test_struts() {
  const double bead = 0.45, open = 0.7592 / 4.0, quilt = kQuiltStrutPerCell;
  const Layout base = strut_layout(bead);
  {  // R10 with Allow quilt: 1% is one line, 100% is the quilt, 50.5% is halfway.
    StrutSpec sp;
    sp.allow_quilt = true;
    Layout l = base;
    sp.dial = 0.01;
    set_struts(l, sp);
    for (const Cell& c : l.cells) NEAR(c.strut, bead, 1e-12);
    sp.dial = 1.0;
    const StrutReport top = set_struts(l, sp);
    for (const Cell& c : l.cells) NEAR(c.strut, quilt * c.size, 1e-9);
    CHECK(top.at_bead == 0 && top.at_ceiling == 0);
    sp.dial = 0.505;
    set_struts(l, sp);
    NEAR(l.cells[0].strut, 0.5 * (bead + quilt * 12.0), 1e-9);
    // The pass moves no cell (P: density sliders re-lay nothing).
    for (std::size_t i = 0; i < l.cells.size(); ++i) {
      Cell a = l.cells[i], b = base.cells[i];
      a.strut = b.strut = 0;
      CHECK(a == b);
    }
  }
  {  // R2: without Allow quilt the top of the dial is the open look, in every cell.
    StrutSpec sp;
    sp.dial = 1.0;
    Layout l = base;
    set_struts(l, sp);
    for (const Cell& c : l.cells) NEAR(c.strut, std::max(bead, open * c.size), 1e-9);
    for (double dial : {0.01, 0.2, 0.45, 0.8, 1.0}) {
      sp.dial = dial;
      set_struts(l, sp);
      for (const Cell& c : l.cells) {
        CHECK(c.strut >= bead - 1e-12);                                  // R5
        CHECK(c.strut <= std::max(bead, open * c.size) + 1e-9);          // R2
        CHECK(c.strut <= quilt * c.size + 1e-9);                         // R9
      }
    }
  }
  {  // R6: Uniform is one strut-to-cell ratio for the whole part, except where that
     // would be thinner than one line. Per-region dials are not read.
    StrutSpec sp;   // Auto: 45%
    Layout l = base;
    const StrutReport r = set_struts(l, sp);
    const double ratio = l.cells[0].strut / 12.0;
    NEAR(l.cells[0].strut, bead + (0.44 / 0.99) * (open * 12.0 - bead), 1e-9);
    int thin = 0;
    for (const Cell& c : l.cells) {
      if (ratio * c.size >= bead) NEAR(c.strut / c.size, ratio, 1e-6);
      else { NEAR(c.strut, bead, 1e-12); ++thin; }
    }
    CHECK(thin == 2 && r.at_bead == 2);   // the 4 and 2.4 mm cells
    Layout l2 = base;
    sp.region_dial = {{1, 1.0}, {2, 0.01}};
    set_struts(l2, sp);
    CHECK(l2.cells == l.cells);
    // Per region: each region's dial, read on that region's own largest cell.
    sp.mode = Density::PerRegion;
    set_struts(l2, sp);
    for (const Cell& c : l2.cells) {
      if (c.region == 1) NEAR(c.strut, std::max(bead, open * c.size), 1e-9);
      else NEAR(c.strut, bead, 1e-12);
    }
    sp.region_dial = {{2, 1.0}};   // region 1 is not listed: it takes the main dial
    set_struts(l2, sp);
    for (std::size_t i = 0; i < l.cells.size(); ++i)
      if (l.cells[i].region == 1) NEAR(l2.cells[i].strut, l.cells[i].strut, 1e-12);
      else NEAR(l2.cells[i].strut, open * l2.cells[i].size, 1e-9);
  }
  {  // R11: a typed width is the width in every cell that can hold it; the report counts
     // the cells that cannot.
    StrutSpec sp;
    sp.width_mm = 1.2;
    sp.dial = 0.9;   // not read
    Layout l = base;
    StrutReport r = set_struts(l, sp);
    int typed = 0;
    for (const Cell& c : l.cells) {
      if (open * c.size >= 1.2) { NEAR(c.strut, 1.2, 1e-12); ++typed; }
      else NEAR(c.strut, std::max(bead, open * c.size), 1e-9);
    }
    CHECK(typed == 2 && r.at_ceiling == 4 && r.at_bead == 0);   // 12 and 8 mm hold it
    sp.allow_quilt = true;
    r = set_struts(l, sp);
    for (const Cell& c : l.cells) NEAR(c.strut, std::min(1.2, quilt * c.size), 1e-9);
    CHECK(r.at_ceiling == 1);                                   // the 2.4 mm cell
    sp.width_mm = 0.2;                                          // under one line (R5)
    r = set_struts(l, sp);
    for (const Cell& c : l.cells) NEAR(c.strut, bead, 1e-12);
    CHECK(r.at_bead == l.cells.size());
  }
  {  // A type with no cell of its own is refused by name, never given another type's widths.
    Layout l = base;
    l.topology = LatticeTopology::Bccz;
    l.open_look = l.touch = 0.0;   // as a layout that never read its type's limits
    bool refused = false;
    try { set_struts(l, StrutSpec{}); } catch (const std::invalid_argument&) { refused = true; }
    CHECK(refused);
    for (const Cell& c : l.cells) CHECK(c.strut == 0.0);
  }
}

// R1, R2, R9: every strut type has its OWN two limits (core's lattice_width_bounds,
// LatticeTypes 2026-11-12): the open look is one number for strut types; where the struts
// touch differs by type. The layout uses the type's own, never octet's.
static void test_each_type_has_its_own_limits() {
  PartMeasure pm(weld_mesh(box(40, 40, 16)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {20, 20, 16}, {0, 0, -1}, 20, 20, 16)};
  Domain d(pm, s);
  struct Type { LatticeTopology topo; double touch; };
  const Type types[] = {{LatticeTopology::Octet, 1.0 / (2.0 * std::sqrt(2.0))},
                        {LatticeTopology::SimpleCubic, 1.0},
                        {LatticeTopology::Bcc, std::sqrt(0.5)},
                        {LatticeTopology::Fcc, 1.0 / std::sqrt(3.0)},
                        {LatticeTopology::Diamond, 1.0 / (2.0 * std::sqrt(2.0))},
                        {LatticeTopology::Kelvin, 1.0 / (2.0 * std::sqrt(2.0))},
                        {LatticeTopology::Rhombic, 1.0 / (2.0 * std::sqrt(2.0))}};
  for (const Type& ty : types) {
    CellSpec cs;
    cs.topology = ty.topo;
    Layout l = lay_cells(d, cs);
    NEAR(l.open_look, 0.7592 / 4.0, 1e-12);
    NEAR(l.touch, ty.touch, 1e-6);
    NEAR(l.floor_cell_mm, 0.45 / (0.7592 / 4.0), 1e-9);  // one-line struts, the open look
    CHECK(!l.cells.empty() && l.cells.front().size == 8.0);
    // Allow quilt off: no strut past the open look, at the dial's top too.
    StrutSpec full;
    full.dial = 1.0;
    set_struts(l, full);
    for (const Cell& c : l.cells) NEAR(c.strut, l.open_look * c.size, 1e-9);
    // Allow quilt on: up to where THIS type's struts touch.
    full.allow_quilt = true;
    set_struts(l, full);
    for (const Cell& c : l.cells) NEAR(c.strut, ty.touch * c.size, 1e-6);
    // The dial's 1% end is the thinnest strut (one line for a part) whatever the type.
    StrutSpec least;
    least.dial = 0.01;
    set_struts(l, least);
    for (const Cell& c : l.cells) NEAR(c.strut, 0.45, 1e-12);
    // And the type's own struts are laid (its own table: lattice_strut_cell).
    const Bars bars = lay_bars(l, d);
    CHECK(bars.bars.size() > 50);
  }
  // Their strut counts differ: the types are not one type under seven names.
  auto bars_of = [&](LatticeTopology topo) {
    CellSpec cs;
    cs.topology = topo;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    return lay_bars(l, d).bars.size();
  };
  CHECK(bars_of(LatticeTopology::SimpleCubic) != bars_of(LatticeTopology::Octet));
  CHECK(bars_of(LatticeTopology::Bcc) != bars_of(LatticeTopology::Octet));
  // A type with no cell is refused by name where its limits are first asked for.
  bool refused = false;
  try {
    CellSpec cs;
    cs.topology = LatticeTopology::Reentrant;
    lay_cells(d, cs);
  } catch (const std::invalid_argument&) { refused = true; }
  CHECK(refused);
}


// Grade to shape on a 60 x 60 x 16 block: the whole top face, 16 deep, 8 mm cells, a
// 0.2 mm line (ladder 8, 4, 2), band 12 mm. The face's outline is the block's own edge,
// facing air (G9).
static void test_grade_to_shape() {
  PartMeasure pm(weld_mesh(box(60, 60, 16)));
  DomainSpec s;
  s.bead_mm = 0.2;
  s.regions = {face_region(1, Role::Lattice, {30, 30, 16}, {0, 0, -1}, 30, 30, 16)};
  Domain d(pm, s);
  const double band = 12.0;
  // In the plane of the face, to its outline: nothing of z in it (G5).
  auto edge = [](const Vec3& m) { return std::max(0.0, std::min(std::min(m.x, 60 - m.x), std::min(m.y, 60 - m.y))); };
  auto size_at = [](const Layout& l, const Vec3& p) {
    for (const Cell& c : l.cells) {
      const Vec3 m = cell_centre(l, c);
      if (std::fabs(p.x - m.x) < 0.5 * c.size && std::fabs(p.y - m.y) < 0.5 * c.size &&
          std::fabs(p.z - m.z) < 0.5 * c.size) return c.size;
    }
    return 0.0;
  };
  CellSpec off;
  off.cell_max_mm = 8;
  const Layout plain = lay_cells(d, off);
  {  // G7: off, every cell is the region's own, cut where the region ends.
    int other = 0, cut = 0;
    for (const Cell& c : plain.cells) { if (std::fabs(c.size - 8.0) > 1e-9) ++other; if (c.cut) ++cut; }
    CHECK(!plain.cells.empty() && other == 0 && cut > 0);
    CellSpec zero = off;   // G2: band 0 is the same layout
    zero.grade_to_shape = true;
    CHECK(lay_cells(d, zero).cells == plain.cells);
  }
  for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
    CellSpec on = off;
    on.algorithm = algo;
    on.grade_to_shape = true;
    on.band_mm = band;
    const Layout l = lay_cells(d, on);
    CHECK(l.solid.empty());                                   // G6
    CHECK(badly_covered(d, l, {0, 0, 0}, {60, 60, 16}, 1.3) == 0);
    double f = 8.0;
    for (const Cell& c : l.cells) f = std::min(f, c.size);
    if (algo == Algorithm::DefaultGrade) NEAR(f, 2.0, 1e-9);   // G3: down to the finest
    CHECK(f < 8.0 - 1e-9);
    const double finest = algo == Algorithm::DefaultGrade ? 2.0 : 8.0 / 6.0;
    int breaks_rule = 0, small_inside = 0, at_edge = 0, at_edge_large = 0, wrong_t = 0, wrong_own = 0;
    int large_cut = 0, finest_cut = 0;
    int big[2] = {0, 0};
    for (const Cell& c : l.cells) {
      const Vec3 m = cell_centre(l, c);
      const double dist = edge(m);
      // G1-G3: the centre rule holds for every cell.
      if (c.size > finest * (1 + 1e-9) &&
          dist < band * (c.size - finest) / (8.0 - finest) - 1e-6) ++breaks_rule;
      // G10: only the finest cell crosses the outline; every larger one lies whole inside it.
      const double h = 0.5 * c.size;
      const bool crosses = m.x - h < -1e-6 || m.x + h > 60 + 1e-6 || m.y - h < -1e-6 || m.y + h > 60 + 1e-6;
      if (crosses) { if (c.size > finest * (1 + 1e-9)) ++large_cut; else ++finest_cut; }
      // G2: beyond the band, the region's own cell.
      // (A divided base cell has its centre inside the band; its own cells reach at most
      // half the difference farther in.)
      if (dist >= band + 0.5 * (8.0 - c.size) && std::fabs(c.size - 8.0) > 1e-9) ++small_inside;
      // G3: the cells at the outline are the smallest in the layout.
      if (dist <= 0.5 * c.size + 1e-9) { ++at_edge; if (c.size > f + 1e-9) ++at_edge_large; }
      if (std::fabs(c.band - std::min(1.0, dist / band)) > 1e-9) ++wrong_t;
      if (std::fabs(c.own - 8.0) > 1e-9) ++wrong_own;
      // G5: both layers of the 16 mm depth hold the same cells.
      if (std::fabs(c.size - 8.0) < 1e-9) ++big[m.z > 8 ? 1 : 0];
    }
    CHECK(breaks_rule == 0);
    CHECK(large_cut == 0);
    // (Default Grade's 2 mm cells meet this outline exactly; Stepped's finest cross it.)
    if (algo == Algorithm::Stepped) CHECK(finest_cut > 0);
    {  // G10 with a band too narrow to hold a large cell off the outline by itself.
      CellSpec narrow = on;
      narrow.band_mm = 2.0;
      const Layout n = lay_cells(d, narrow);
      int cut_large = 0, own = 0;
      for (const Cell& c : n.cells) {
        const Vec3 m = cell_centre(n, c);
        const double h = 0.5 * c.size;
        if (std::fabs(c.size - 8.0) < 1e-9) ++own;
        if (c.size > finest * (1 + 1e-9) &&
            (m.x - h < -1e-6 || m.x + h > 60 + 1e-6 || m.y - h < -1e-6 || m.y + h > 60 + 1e-6)) ++cut_large;
      }
      CHECK(cut_large == 0 && own > 0 && n.solid.empty());
      CHECK(badly_covered(d, n, {0, 0, 0}, {60, 60, 16}, 1.3) == 0);
    }
    CHECK(small_inside == 0);
    CHECK(at_edge > 50 && at_edge_large == 0);
    CHECK(wrong_t == 0 && wrong_own == 0);
    CHECK(big[0] > 0 && big[0] == big[1]);
    // G1: along 20 lines from the middle to the outline the cell never grows.
    int grew = 0;
    for (int k = 0; k < 20; ++k) {
      const double ang = 0.1 + k * 0.31;
      double before = 1e300;
      for (double r = 0.0; r < 60.0; r += 0.25) {
        const Vec3 p{30 + r * std::cos(ang), 30 + r * std::sin(ang), 12.1};
        if (p.x <= 0.05 || p.x >= 59.95 || p.y <= 0.05 || p.y >= 59.95) break;
        const double sz = size_at(l, p);
        if (sz == 0.0) continue;
        if (sz > before + 1e-9) ++grew;
        before = sz;
      }
    }
    CHECK(grew == 0);

    // Struts in the band (G8, G4), with Allow quilt ON: the band may thicken past the
    // open look, up to the quilt. (With it off the band stops at the open look:
    // test_band_never_quilts_without_the_switch.)
    Layout a = l, b = l, c2 = l;
    StrutSpec sp;
    sp.allow_quilt = true;
    sp.dial = 0.05;   // thin enough that the finest cells are not at the quilt already
    set_struts(a, sp);
    sp.strength = 1.0;
    set_struts(b, sp);
    sp.strength = -1.0;
    set_struts(c2, sp);
    double ratio = 0.0;
    for (const Cell& c : a.cells)
      if (c.band >= 1.0 && std::fabs(c.size - 8.0) < 1e-9) ratio = c.strut / c.size;
    CHECK(ratio > 0.0);
    int thinner = 0, past_quilt = 0, past_open = 0, not_lines = 0, weaker = 0, stronger = 0, moved_outside = 0, denser = 0, band_cells = 0;
    for (std::size_t i = 0; i < a.cells.size(); ++i) {
      const Cell& c = a.cells[i];
      const double q = kQuiltStrutPerCell * c.size;
      if (c.band >= 1.0) {
        if (b.cells[i].strut != c.strut || c2.cells[i].strut != c.strut) ++moved_outside;
        continue;
      }
      ++band_cells;
      if (c.strut < std::min(ratio * 8.0, q) - 1e-9) ++thinner;          // G8
      if (c.strut > q + 1e-9) ++past_quilt;                               // R9
      if (c.strut > (0.7592 / 4.0) * c.size + 1e-9) ++past_open;          // R2: allowed with the switch on
      const double lines = c.strut / 0.2;
      if (std::fabs(lines - std::round(lines)) > 1e-6 && std::fabs(c.strut - q) > 1e-9) ++not_lines;
      if (c.strut / c.size > ratio + 1e-9) ++denser;
      if (b.cells[i].strut < c.strut - 1e-12 || c2.cells[i].strut > c.strut + 1e-12) ++weaker;
      if (b.cells[i].strut > c2.cells[i].strut + 1e-9) ++stronger;
    }
    CHECK(band_cells > 100);
    CHECK(thinner == 0);
    CHECK(past_quilt == 0);
    CHECK(past_open > 0);
    CHECK(not_lines == 0);
    CHECK(denser == band_cells);          // denser all the way to the outline (G8)
    CHECK(weaker == 0 && stronger > 0);   // G4
    CHECK(moved_outside == 0);
    // R11: a typed width holds inside the band too, up to the quilt (the switch on).
    sp = StrutSpec{};
    sp.allow_quilt = true;
    sp.width_mm = 0.6;
    set_struts(a, sp);
    int not_typed = 0;
    for (const Cell& c : a.cells)
      if (c.band < 1.0 && std::fabs(c.strut - std::min(0.6, kQuiltStrutPerCell * c.size)) > 1e-9) ++not_typed;
    CHECK(not_typed == 0);
  }
  {  // G11: finer cells in the band, below the open look's floor, and only in the band.
    DomainSpec s45 = s;
    s45.bead_mm = 0.45;
    Domain d45(pm, s45);
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec on = off;
      on.algorithm = algo;
      on.grade_to_shape = true;
      on.band_mm = band;
      const Layout open_look = lay_cells(d45, on);
      on.allow_quilt = true;
      const Layout fine = lay_cells(d45, on);
      const double floor = open_look.floor_cell_mm, closes = 0.45 / kQuiltStrutPerCell;
      double f0 = 8.0, f1 = 8.0;
      int outside = 0;
      for (const Cell& c : open_look.cells) f0 = std::min(f0, c.size);
      for (const Cell& c : fine.cells) {
        f1 = std::min(f1, c.size);
        if (c.size < floor - 1e-9 && edge(cell_centre(fine, c)) - 0.5 * c.size >= band) ++outside;
      }
      CHECK(f0 >= floor - 1e-9);                       // off: never below the open look
      CHECK(f1 < floor - 1e-9 && f1 >= closes - 1e-9); // on: below it, never a closed cell
      CHECK(outside == 0);
      CHECK(fine.solid.empty());
      CHECK(badly_covered(d45, fine, {0, 0, 0}, {60, 60, 16}, 1.3) == 0);
      Layout z = fine;                                  // and their struts are stated
      set_struts(z, StrutSpec{});
      int bad = 0;
      for (const Cell& c : z.cells)
        if (c.strut < 0.45 - 1e-9 || c.strut > kQuiltStrutPerCell * c.size + 1e-9) ++bad;
      CHECK(bad == 0);
      // Away from a band nothing changes: the switch alone moves no cell.
      CellSpec plain_fine = off;
      plain_fine.algorithm = algo;
      plain_fine.allow_quilt = true;
      CellSpec plain_off = off;
      plain_off.algorithm = algo;
      CHECK(lay_cells(d45, plain_fine).cells == lay_cells(d45, plain_off).cells);
    }
  }
  {  // One size keeps its cells and grades struts only (C16).
    CellSpec on = off;
    on.algorithm = Algorithm::Uniform;
    on.grade_to_shape = true;
    on.band_mm = band;
    const Layout l = lay_cells(d, on);
    int other = 0, banded = 0;
    for (const Cell& c : l.cells) { if (std::fabs(c.size - 8.0) > 1e-9) ++other; if (c.band < 1.0) ++banded; }
    CHECK(other == 0 && banded > 0 && l.cells.size() == plain.cells.size());
  }
}


// The reviewer's rib (ruling 2026-11-11): one cell wide across the face, two deep. The
// cells a wall must hold are counted across its narrowest width, not along the prism.
static void test_cells_across_the_narrowest_width() {
  auto lay_rib = [](double wide, double bead, int across) {
    PartMeasure pm(weld_mesh(box(40, wide, 6)));
    DomainSpec s;
    s.bead_mm = bead;
    s.regions = {face_region(1, Role::Lattice, {20, 0.5 * wide, 6}, {0, 0, -1}, 20, 0.5 * wide, 6)};
    Domain d(pm, s);
    CellSpec cs;
    cs.min_cells_across = across;
    return lay_cells(d, cs);
  };
  {  // Two across asked. 6 deep would hold two 3 mm cells; 3 wide holds one. Not a lattice.
    const Layout l = lay_rib(3, 0.45, 2);
    CHECK(l.cells.empty() && !l.solid.empty());
  }
  {  // On a finer line the rib takes cells that are two across its 3 mm: 1.5 mm at most.
    const Layout l = lay_rib(3, 0.2, 2);
    double largest = 0.0;
    for (const Cell& c : l.cells) largest = std::max(largest, c.size);
    CHECK(!l.cells.empty() && largest <= 1.5 + 1e-5);
  }
  {  // Single-cell walls: one 3 mm cell across the 3 mm, two deep.
    const Layout l = lay_rib(3, 0.45, 1);
    int other = 0;
    for (const Cell& c : l.cells) if (std::fabs(c.size - 3.0) > 1e-5) ++other;
    CHECK(!l.cells.empty() && other == 0 && l.solid.empty());
  }
  {  // Structural, five across: 0.6 mm cells do not print. Solid.
    const Layout l = lay_rib(3, 0.2, 5);
    CHECK(l.cells.empty() && !l.solid.empty());
  }
  {  // The same rib 6 mm wide is two across both ways: lattice, 3 mm cells.
    const Layout l = lay_rib(6, 0.45, 2);
    int other = 0;
    for (const Cell& c : l.cells) if (std::fabs(c.size - 3.0) > 1e-5) ++other;
    CHECK(!l.cells.empty() && other == 0 && l.solid.empty());
  }
}

// The reading at a part's own point, in a layout's frame.
static Reading reading_at(const Domain::Probe& pr, const Layout& l, int frame, const Vec3& p) {
  const Frame& f = l.frames[static_cast<std::size_t>(frame)];
  const Vec3 r{p.x - f.origin.x, p.y - f.origin.y, p.z - f.origin.z};
  return read_at(pr, f, l.walls[static_cast<std::size_t>(frame)],
                 r.x * f.ax[0].x + r.y * f.ax[0].y + r.z * f.ax[0].z,
                 r.x * f.ax[1].x + r.y * f.ax[1].y + r.z * f.ax[1].z,
                 r.x * f.ax[2].x + r.y * f.ax[2].y + r.z * f.ax[2].z);
}

// C2, C12: the wall a cell divides is the lattice's own column and nothing else. With a
// pocket under the face, the material behind the pocket is a wall of its own: it starts
// where that material starts and ends at the region's depth. (Found on the stand's back
// face, 2026-11-11: the whole length of material through the point was read as the
// wall, 10.8 mm for a 4.4 mm column, and 6.5 mm cells stood in it.)
static void test_cells_behind_a_pocket() {
  // In section (x across, y into the part from the face y = 0): a 4 mm wall, a 5 mm
  // pocket open to the left, then solid from 9 mm on. For x > 50 solid all the way.
  std::size_t open = 99;
  PartMeasure pm(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 9}, {50, 9}, {50, 4}, {0, 4}}, 0, 40),
                           1e-5, &open));
  CHECK(open == 0);
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 13)};
  Domain d(pm, s);
  auto pr = d.probe();
  for (Algorithm algo : {Algorithm::Stepped, Algorithm::DefaultGrade}) {
    CellSpec cs;
    cs.algorithm = algo;
    const Layout l = lay_cells(d, cs);
    Reading r = reading_at(pr, l, 0, {25, 11, 20});     // behind the pocket
    CHECK(r.where.lattice());
    NEAR(r.start, 9.0, 1e-6);
    NEAR(r.width, 4.0, 1e-6);                           // 9 to the region's 13, not 9 to 20
    r = reading_at(pr, l, 0, {25, 2, 20});              // the wall in front of it
    NEAR(r.start, 0.0, 0.0);
    NEAR(r.width, 4.0, 1e-6);
    r = reading_at(pr, l, 0, {55, 11, 20});             // beside the pocket
    NEAR(r.start, 0.0, 0.0);
    NEAR(r.width, 13.0, 1e-6);
    CHECK(!reading_at(pr, l, 0, {25, 6, 20}).where.lattice());   // the pocket itself
    // The wall behind the pocket is a wall of its own (C15): one layer of 4 mm cells
    // that start where its material starts, 9 mm below the face. None is wider (C2).
    int held = 0, other = 0;
    for (double x = 2; x < 48; x += 3.1)
      for (double y = 9.2; y < 12.9; y += 0.45)
        for (double z = 3; z < 37; z += 4.3)
          for (const Cell& c : l.cells)
            if (cell_holds(l, pr, c, {x, y, z})) {
              ++held;
              if (std::fabs(c.size - 4.0) > 1e-5 || std::fabs(c.lo[2] - 9.0) > 1e-5) ++other;
            }
    CHECK(held > 500);
    CHECK(other == 0);
    CHECK(l.solid.empty());
    CHECK(badly_covered(d, l, {1, 0, 1}, {59, 13, 39}, 0.97) == 0);   // the pocket's end too
  }
  // Two walls in one column, one base cell deep: a 2 mm wall too thin for any cell, a
  // 2 mm pocket, then solid. The thin wall goes solid; the wall behind it is read on its
  // own (its own start, width and narrowest width) and keeps its cells.
  PartMeasure thin(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 4}, {50, 4}, {50, 2}, {0, 2}}, 0, 40)));
  Domain d2(thin, s);
  auto pr2 = d2.probe();
  for (Algorithm algo : {Algorithm::Stepped, Algorithm::DefaultGrade}) {
    CellSpec cs;
    cs.algorithm = algo;
    const Layout l = lay_cells(d2, cs);
    const Reading r = reading_at(pr2, l, 0, {25, 5, 20});
    NEAR(r.start, 4.0, 1e-6);
    NEAR(r.width, 9.0, 1e-6);
    CHECK(cells_holding(l, {25, 5, 20}, 1) == 1);     // behind the pocket: a cell
    CHECK(cells_holding(l, {25, 12, 20}, 1) == 1);
    CHECK(cells_holding(l, {25, 1, 20}, 1) == 0);     // the 2 mm wall: no cell,
    Layout as_solid;
    as_solid.frames = l.frames;
    as_solid.cells = l.solid;
    CHECK(cells_holding(as_solid, {25, 1, 20}, 1) == 1);   // listed solid
  }
  // D14: a fin 0.6 mm wide hanging into the pocket, its tip 5.6 mm below the face. It is
  // too thin for any cell and lies between the points a base cell is read at; the face's
  // map saw it under one row of nodes, and it is read again there, at its own depths.
  PartMeasure fin(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 16}, {20.7, 16}, {20.7, 5.6},
                                       {21.3, 5.6}, {21.3, 16}, {50, 16}, {50, 4}, {0, 4}}, 0, 40)));
  Domain d3(fin, s);
  for (Algorithm algo : {Algorithm::Stepped, Algorithm::DefaultGrade}) {
    CellSpec cs;
    cs.algorithm = algo;
    const Layout l = lay_cells(d3, cs);
    Layout as_solid;
    as_solid.frames = l.frames;
    as_solid.cells = l.solid;
    for (double y : {6.0, 10.0, 12.5}) {
      CHECK((d3.probe().where({21, y, 20}) == Where{Why::Lattice, 1}));
      CHECK(cells_holding(l, {21, y, 20}, 1) == 0);
      CHECK(cells_holding(as_solid, {21, y, 20}, 1) >= 1);   // listed solid, tip included
    }
    CHECK(cells_holding(l, {30, 2, 20}, 1) == 1);            // the 4 mm wall in front: cells
  }
}

// P2: what a layout reads under a face is kept with the domain and reused by the next
// layout of it. A layout must not depend on which layouts came before it.
static void test_kept_readings() {
  // The stepped wall of C12 (12 mm beside 6 mm) with lattice from its flat face, and a
  // second region on a second part of the face; cell sizes that make different walls.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 6}, {30, 6}, {30, 12}, {0, 12}}, 0, 40)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {15, 0, 20}, {0, 1, 0}, 20, 14, 12),
               face_region(2, Role::Lattice, {45, 0, 20}, {0, 1, 0}, 20, 14, 6)};
  auto spec = [](Algorithm algo, double cell, int across) {
    CellSpec cs;
    cs.algorithm = algo;
    cs.cell_max_mm = cell;
    cs.min_cells_across = across;
    return cs;
  };
  const CellSpec specs[] = {spec(Algorithm::Stepped, 8, 1), spec(Algorithm::DefaultGrade, 3, 1),
                            spec(Algorithm::Stepped, 4, 2), spec(Algorithm::Uniform, 12, 1)};
  Domain shared(pm, s);
  for (int round = 0; round < 2; ++round)
    for (const CellSpec& cs : specs) {
      const Layout again = lay_cells(shared, cs);   // after whatever was laid before
      Domain fresh(pm, s);
      const Layout first = lay_cells(fresh, cs);     // nothing kept yet
      CHECK(again.cells == first.cells);
      CHECK(again.solid == first.solid);
      CHECK(!first.cells.empty());
      CHECK((lay_cells(shared, cs, 1).cells == first.cells));
    }
  // Each region keeps its own: region 2 alone lays the cells it lays beside region 1.
  DomainSpec only2;
  only2.regions = {s.regions[1]};
  Domain alone(pm, only2);
  const Layout both = lay_cells(shared, specs[0]), one = lay_cells(alone, specs[0]);
  std::vector<Cell> of2;
  for (const Cell& c : both.cells)
    if (c.region == 2) of2.push_back(c);
  CHECK(!of2.empty() && of2.size() == one.cells.size());
  for (std::size_t i = 0; i < of2.size() && i < one.cells.size(); ++i) {
    CHECK(of2[i].size == one.cells[i].size);
    CHECK(of2[i].wall == one.cells[i].wall && of2[i].wall >= 0);   // laid as its own wall
    for (int a = 0; a < 3; ++a) NEAR(of2[i].lo[a], one.cells[i].lo[a], 1e-9);
  }
}

// G11, R2 (his rule, 2026-11-12): "it makes sense to thicken it as it gets closer to the
// walls, BUT without 'Allow quilting' set to 'on' it should NEVER QUILT." A 14 mm wall on
// a 0.45 mm line, band 6, Stepped, two-line struts.
static void test_band_never_quilts_without_the_switch() {
  PartMeasure pm(weld_mesh(box(60, 14, 40)));
  DomainSpec s;
  s.min_strut_lines = 2.0;   // the numbers below are for two-line struts
  s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 14)};
  Domain d(pm, s);
  const double open = kSteppedPrintsOpenMaxStrutPerCell;
  auto laid = [&](bool allow_quilt, double typed, double strength = 0.0, double dial = 0.45) {
    CellSpec cs;
    cs.algorithm = Algorithm::Stepped;
    cs.cell_max_mm = 14.0;
    cs.grade_to_shape = true;
    cs.band_mm = 6.0;
    cs.allow_quilt = allow_quilt;
    cs.band_cell_mm = typed;
    Layout l = lay_cells(d, cs);
    StrutSpec ss;
    ss.allow_quilt = allow_quilt;
    ss.strength = strength;
    ss.dial = dial;
    set_struts(l, ss);
    return l;
  };
  auto smallest = [](const Layout& l) {
    double least = 1e9;
    for (const Cell& c : l.cells) least = std::min(least, c.size);
    return least;
  };
  auto most_closed = [](const Layout& l) {   // the widest strut over cell there is
    double most = 0.0;
    for (const Cell& c : l.cells) most = std::max(most, c.strut / c.size);
    return most;
  };
  // The smallest cell that prints open is 4.742 mm and the quilt's cell 2.546 mm. A 14 mm
  // cell divides into 7, 4.667, 3.5, 2.8.
  // Switch off: cells never under the open look's, struts never past the open look,
  // whatever the band's strength or the dial ask.
  for (double strength : {0.0, 1.0})
    for (double dial : {0.45, 1.0}) {
      const Layout l = laid(false, 0.0, strength, dial);
      NEAR(smallest(l), 7.0, 1e-6);
      CHECK(most_closed(l) <= open + 1e-12);
    }
  {  // A typed strut width (R11) obeys it too, in the band and out of it.
    CellSpec cs;
    cs.algorithm = Algorithm::Stepped;
    cs.cell_max_mm = 14.0;
    cs.grade_to_shape = true;
    cs.band_mm = 6.0;
    Layout l = lay_cells(d, cs);
    StrutSpec typed;
    typed.width_mm = 3.0;
    const StrutReport held = set_struts(l, typed);
    CHECK(most_closed(l) <= open + 1e-12 && held.at_ceiling == l.cells.size());
    typed.allow_quilt = true;
    set_struts(l, typed);
    CHECK(most_closed(l) > open + 1e-6);
  }
  NEAR(smallest(laid(false, 3.0)), 7.0, 1e-6);         // a typed 3 mm is held at the open look's
  NEAR(smallest(laid(false, 8.0)), 14.0, 1e-6);        // a typed coarser band is honoured
  {  // The band still thickens toward the outline: at the edge the strut is wider than in
     // the middle of the face, and stops at the open look.
    const Layout l = laid(false, 0.0, 1.0);
    double at_edge = 0.0, inside = 1e9;
    for (const Cell& c : l.cells) {
      if (c.band < 0.3) at_edge = std::max(at_edge, c.strut / c.size);
      if (c.band >= 1.0) inside = std::min(inside, c.strut / c.size);
    }
    CHECK(at_edge > inside + 1e-6);
    CHECK(at_edge <= open + 1e-12);
  }
  // Switch on: the band may use the smaller, less open cells, and thicken to the quilt.
  {
    const Layout l = laid(true, 0.0, 1.0);
    NEAR(smallest(l), 2.8, 1e-6);
    CHECK(most_closed(l) > open + 1e-6 && most_closed(l) <= kQuiltStrutPerCell + 1e-12);
  }
  NEAR(smallest(laid(true, 3.0)), 3.5, 1e-6);          // typed: nothing under 3 mm
  NEAR(smallest(laid(true, 0.5)), 2.8, 1e-6);          // typed under the quilt's cell is held at it
  // Without a band the switch moves no cell.
  CellSpec plain;
  plain.algorithm = Algorithm::Stepped;
  plain.cell_max_mm = 14.0;
  plain.allow_quilt = true;
  plain.band_cell_mm = 3.0;
  CellSpec base;
  base.algorithm = Algorithm::Stepped;
  base.cell_max_mm = 14.0;
  CHECK(lay_cells(d, plain).cells == lay_cells(d, base).cells);
}

// R5, C14: the thinnest strut is a number of line widths, and no cell is smaller than the
// one such a strut leaves open. ONE line for a part; TWO for a piece that is nothing but
// the smallest lattice (his failed test print of 2026-11-11, and his correction of
// 2026-11-12 that the two-line rule was for that print only).
static void test_two_line_struts() {
  {  // A part: one line. 2.371 mm floor at 0.45; a 4 mm wall takes 4 mm cells.
    PartMeasure pm(weld_mesh(box(60, 4, 40)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 4)};
    CHECK(s.min_strut_lines == 1.0);
    Domain d(pm, s);
    Layout l = lay_cells(d, CellSpec{});
    NEAR(l.min_strut_mm, 0.45, 1e-12);
    NEAR(l.floor_cell_mm, 2.370917, 1e-5);
    CHECK(!l.cells.empty() && l.solid.empty());
    StrutSpec least;
    least.dial = 0.01;
    set_struts(l, least);
    for (const Cell& c : l.cells) NEAR(c.strut, 0.45, 1e-12);
  }
  auto wall = [](double thick, double bead, double lines = kMinStrutLinesAllSmallest) {
    PartMeasure* pm = new PartMeasure(weld_mesh(box(60, thick, 40)));   // kept for the layout's life
    DomainSpec s;
    s.bead_mm = bead;
    s.min_strut_lines = lines;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, thick)};
    Domain d(*pm, s);
    Layout l = lay_cells(d, CellSpec{});
    delete pm;
    return l;
  };
  // From here: the test print's setting, two lines.
  {  // An 8 mm wall on a 0.45 mm line: his proven size. 8 mm cells, struts of 0.9 mm or more.
    Layout l = wall(8, 0.45);
    NEAR(l.min_strut_mm, 0.9, 1e-12);
    NEAR(l.floor_cell_mm, 0.9 / kSteppedPrintsOpenMaxStrutPerCell, 1e-12);   // 4.742 mm
    NEAR(l.floor_cell_mm, 4.741834, 1e-5);
    int other = 0;
    for (const Cell& c : l.cells) if (std::fabs(c.size - 8.0) > 1e-9) ++other;
    CHECK(!l.cells.empty() && other == 0 && l.solid.empty());
    set_struts(l, StrutSpec{});
    double thinnest = 1e9;
    for (const Cell& c : l.cells) thinnest = std::min(thinnest, c.strut);
    CHECK(thinnest >= 0.9 - 1e-12);
    StrutSpec least;
    least.dial = 0.01;                       // the dial's 1% end is the thinnest strut: two lines
    set_struts(l, least);
    for (const Cell& c : l.cells) NEAR(c.strut, 0.9, 1e-12);
    StrutSpec typed;
    typed.width_mm = 0.5;                    // a typed one-line strut is held at two, and counted
    const StrutReport rep = set_struts(l, typed);
    for (const Cell& c : l.cells) NEAR(c.strut, 0.9, 1e-12);
    CHECK(rep.at_bead == l.cells.size());
  }
  {  // His failed coupon's size: a 4 mm wall cannot hold a cell that prints. Solid, and listed.
    const Layout l = wall(4, 0.45);
    CHECK(l.cells.empty() && !l.solid.empty());
  }
  {  // 5 mm is over the 4.742 mm floor: one 5 mm cell across, its strut 0.9 mm.
    Layout l = wall(5, 0.45);
    CHECK(!l.cells.empty() && l.solid.empty());
    set_struts(l, StrutSpec{});
    for (const Cell& c : l.cells) { NEAR(c.size, 5.0, 1e-9); CHECK(c.strut >= 0.9 - 1e-12 && c.strut <= 0.19 * 5.0); }
  }
  {  // The floor follows the line: at 0.4 mm it is 4.215 mm, and a 4.5 mm wall holds cells.
    const Layout l = wall(4.5, 0.4);
    NEAR(l.floor_cell_mm, 4.214964, 1e-5);
    CHECK(!l.cells.empty());
  }
  {  // The number is a setting of the domain (a type with its own print brings its own),
     // never under one line.
    NEAR(wall(8, 0.45, 1.0).floor_cell_mm, 2.370917, 1e-5);
    NEAR(wall(8, 0.45, 0.2).min_strut_mm, 0.45, 1e-12);
    NEAR(wall(8, 0.45, 3.0).min_strut_mm, 1.35, 1e-12);
  }
}

// C11a: the member's narrowest width is read once per column, at the column's middle.
// Grooves in the face of a thick plate leave teeth 1.9 mm wide and 1.5 tall; the plate is
// not a 1.9 mm member, and its cells stand whole, cut by the grooves (D3).
static void test_grooves_do_not_narrow_a_wall() {
  std::vector<std::array<double, 2>> xy;
  for (int k = 0; k < 6; ++k) {
    xy.push_back({3.7 * k, 0.0});
    xy.push_back({3.7 * k + 1.9, 0.0});
    if (k < 5) {
      xy.push_back({3.7 * k + 1.9, 1.5});
      xy.push_back({3.7 * k + 3.7, 1.5});
    }
  }
  xy.push_back({20.4, 12.0});
  xy.push_back({0.0, 12.0});
  std::size_t open = 99;
  PartMeasure pm(weld_mesh(prism_any(xy, 0, 40), 1e-5, &open));
  CHECK(open == 0);
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {10.2, 0, 20}, {0, 1, 0}, 30, 30, 12)};
  Domain d(pm, s);
  auto pr = d.probe();
  NEAR(pr.part().thickness({1.2, 1.0, 20}), 1.9, 0.01);   // inside a tooth: the tooth
  NEAR(pr.part().thickness({1.2, 6.0, 20}), 12.0, 0.01);  // the column's middle: the plate
  for (Algorithm algo : {Algorithm::Stepped, Algorithm::DefaultGrade}) {
    CellSpec cs;
    cs.algorithm = algo;
    const Layout l = lay_cells(d, cs);
    int other = 0;
    for (const Cell& c : l.cells)
      if (std::fabs(c.size - 6.0) > 1e-5) ++other;
    CHECK(!l.cells.empty() && other == 0 && l.solid.empty());
    CHECK(badly_covered(d, l, {0, 0, 1}, {20.4, 12, 39}, 0.83) == 0);
    CHECK((lay_cells(d, cs, 1).cells == l.cells));        // any number of threads (D18)
  }
}

// ── stage D: bars ─────────────────────────────────────────────────────────────
static double bar_length(const Bar& b) {
  return std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) +
                   (b.b.z - b.a.z) * (b.b.z - b.a.z));
}
static bool same_bars(const Bars& x, const Bars& y) {
  if (x.bars.size() != y.bars.size() || x.stubs != y.stubs) return false;
  for (std::size_t i = 0; i < x.bars.size(); ++i) {
    const Bar &p = x.bars[i], &q = y.bars[i];
    if (p.a.x != q.a.x || p.a.y != q.a.y || p.a.z != q.a.z || p.b.x != q.b.x || p.b.y != q.b.y ||
        p.b.z != q.b.z || p.width != q.width || p.end_a != q.end_a || p.end_b != q.end_b)
      return false;
  }
  return true;
}

// S4, S11: the struts themselves, once each, cut where their cell is cut.
static void test_bars() {
  const Vec3 down{0, 0, -1};
  {  // A 12 mm cube, all lattice, 6 mm cells: 2 x 2 x 2 whole octet cells.
    PartMeasure pm(weld_mesh(box(12, 12, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {6, 6, 12}, down, 6, 6, 12)};
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    CHECK(l.cells.size() == 8);
    set_struts(l, StrutSpec{});
    Bars bars = lay_bars(l, d);
    // A cell has 36 struts: 4 on each of its 6 faces, 12 inside. A face two cells share
    // carries its 4 once: 4 x 36 faces + 12 x 8 cells.
    CHECK(bars.bars.size() == 240);
    CHECK(bars.stubs == 0);
    int odd = 0;
    for (const Bar& b : bars.bars)
      if (b.piece || b.end_a != Bar::End::Node || b.end_b != Bar::End::Node ||
          std::fabs(bar_length(b) - 6.0 * std::sqrt(0.5)) > 1e-9 || !(b.width > 0.0) || b.region != 1)
        ++odd;
    CHECK(odd == 0);
    CHECK(same_bars(lay_bars(l, d, 1), bars));   // any number of threads (D18)
    drop_loose_bars(bars);
    CHECK(bars.bars.size() == 240 && bars.dropped == 0);   // nothing loose in a whole block
  }
  {  // A 20 x 20 x 12 block, lattice 6 deep from its top, 6 mm cells: the cells along the
     // sides are cut by the block's own sides, and stand on solid.
    PartMeasure pm(weld_mesh(box(20, 20, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {10, 10, 12}, down, 10, 10, 6)};
    Domain d(pm, s);
    auto pr = d.probe();
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    Bars bars = lay_bars(l, d);
    CHECK(same_bars(lay_bars(l, d, 1), bars));
    int outside = 0, off_surface = 0, short_piece = 0, surface_ends = 0;
    double on_top = 0.0;
    for (const Bar& b : bars.bars) {
      if (pr.part().depth(b.a) < -1e-6 || pr.part().depth(b.b) < -1e-6) ++outside;   // S11
      if (b.end_a == Bar::End::Surface) { ++surface_ends; if (std::fabs(pr.part().depth(b.a)) > 1e-6) ++off_surface; }
      if (b.end_b == Bar::End::Surface) { ++surface_ends; if (std::fabs(pr.part().depth(b.b)) > 1e-6) ++off_surface; }
      if (b.piece && bar_length(b) < b.width) ++short_piece;                           // S4
      if (std::fabs(b.a.z - 12) < 1e-9 && std::fabs(b.b.z - 12) < 1e-9) on_top += bar_length(b);
    }
    CHECK(outside == 0);           // nothing sticks out of the part
    CHECK(surface_ends > 20);
    CHECK(off_surface == 0);       // a bar cut by the part's surface ends ON it
    CHECK(short_piece == 0);
    // The struts lying IN the latticed face are part of the lattice, in cut cells too:
    // the two families of diagonals, 6 mm apart, cut to the 20 mm square. Each family is
    // sqrt(2) x (20 + 2 x 14 + 2 x 8 + 2 x 2) = 96.17 mm of strut, to the micron.
    NEAR(on_top, 2.0 * std::sqrt(2.0) * 68.0, 1e-3);
    drop_loose_bars(bars);
    CHECK(bars.dropped > 0);
    std::map<std::array<long long, 3>, int> at;
    auto key = [](const Vec3& p) {
      return std::array<long long, 3>{std::llround(p.x * 1e5), std::llround(p.y * 1e5), std::llround(p.z * 1e5)};
    };
    for (const Bar& b : bars.bars) { ++at[key(b.a)]; ++at[key(b.b)]; }
    int loose = 0;
    for (const Bar& b : bars.bars) {
      if (b.end_a == Bar::End::Surface || b.end_a == Bar::End::Loose) ++loose;
      if (b.end_b == Bar::End::Surface || b.end_b == Bar::End::Loose) ++loose;
      if (b.end_a == Bar::End::Node && at[key(b.a)] < 2) ++loose;
      if (b.end_b == Bar::End::Node && at[key(b.b)] < 2) ++loose;
    }
    CHECK(loose == 0);             // S4: every end left lands on another bar or on solid
    CHECK(bars.bars.size() > 100);
  }
  {  // A 13 mm wide block: its 6 mm cells overhang each side by 2.5 mm, and the struts
     // that clip the block's edges leave pieces 0.7 mm long, shorter than they are wide.
     // Such a stub is not kept (S4).
    PartMeasure pm(weld_mesh(box(13, 13, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {6.5, 6.5, 12}, down, 6.5, 6.5, 6)};
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    const Bars bars = lay_bars(l, d);
    CHECK(bars.stubs > 0);
    int short_piece = 0;
    for (const Bar& b : bars.bars)
      if (b.piece && bar_length(b) < b.width) ++short_piece;
    CHECK(short_piece == 0);
  }
  const Vec3 in_y{0, 1, 0};
  {  // A groove 0.3 mm wide and 2 mm deep in the latticed face of a 12 mm cube, between the
     // points the layout reads a cell at, so the layout calls its cells whole. A strut
     // across the groove has both ends and its middle in material; its own line still
     // meets the groove, and no bar crosses the air (S11).
    PartMeasure pm(weld_mesh(prism_any({{0, 0}, {1.8, 0}, {1.8, 2}, {2.1, 2}, {2.1, 0}, {12, 0}, {12, 12}, {0, 12}}, 0, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {6, 0, 6}, in_y, 6, 6, 12)};
    Domain d(pm, s);
    auto pr = d.probe();
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    CHECK(l.cells.size() == 8 && l.solid.empty());
    set_struts(l, StrutSpec{});
    const Bars bars = lay_bars(l, d);
    int in_air = 0, cut_at_groove = 0;
    for (const Bar& b : bars.bars) {
      for (int k = 0; k <= 20; ++k) {
        const double t = k / 20.0;
        if (pr.part().depth({b.a.x + (b.b.x - b.a.x) * t, b.a.y + (b.b.y - b.a.y) * t, b.a.z + (b.b.z - b.a.z) * t}) < -1e-6)
          ++in_air;
      }
      for (const Vec3& p : {b.a, b.b})
        if ((std::fabs(p.x - 1.8) < 1e-6 || std::fabs(p.x - 2.1) < 1e-6) && p.y < 2) ++cut_at_groove;
    }
    CHECK(in_air == 0);
    CHECK(cut_at_groove > 10);   // the struts stop at the groove's two walls
  }
  {  // Two grooves 0.4 mm wide ON the planes the cells' nodes lie in (x = 3 and x = 6): a
     // strut in the face from a node in one groove to a node in the other has neither end
     // in material, and its middle in material. The piece between the grooves is kept.
    PartMeasure pm(weld_mesh(prism_any({{0, 0}, {2.8, 0}, {2.8, 2}, {3.2, 2}, {3.2, 0}, {5.8, 0}, {5.8, 2},
                                        {6.2, 2}, {6.2, 0}, {12, 0}, {12, 12}, {0, 12}}, 0, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {6, 0, 6}, in_y, 6, 6, 12)};
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    const Bars bars = lay_bars(l, d);
    int between = 0;
    for (const Bar& b : bars.bars)
      if (b.end_a == Bar::End::Surface && b.end_b == Bar::End::Surface && bar_length(b) > 3.0 &&
          std::min(b.a.x, b.b.x) > 3.1 && std::max(b.a.x, b.b.x) < 5.9)
        ++between;
    CHECK(between > 0);
  }
  {  // S4, by hand: a chain of three bars from solid out to a cut end in the air. The cut
     // one lands on nothing; with it gone the next holds its node alone; and so on back
     // to the solid. A triangle of bars beside it, standing on solid, stays.
    Bars chain;
    auto bar = [](Vec3 a, Vec3 b, Bar::End ea, Bar::End eb) {
      Bar x;
      x.a = a; x.b = b; x.end_a = ea; x.end_b = eb; x.width = 0.5;
      return x;
    };
    chain.bars = {bar({0, 0, 0}, {1, 0, 0}, Bar::End::Solid, Bar::End::Node),
                  bar({1, 0, 0}, {2, 0, 0}, Bar::End::Node, Bar::End::Node),
                  bar({2, 0, 0}, {3, 0, 0}, Bar::End::Node, Bar::End::Surface),
                  bar({0, 5, 0}, {1, 6, 0}, Bar::End::Solid, Bar::End::Node),
                  bar({2, 5, 0}, {1, 6, 0}, Bar::End::Solid, Bar::End::Node),
                  bar({5, 5, 0}, {6, 5, 0}, Bar::End::Node, Bar::End::Loose)};
    drop_loose_bars(chain);
    CHECK(chain.dropped == 4);
    CHECK(chain.bars.size() == 2 && chain.bars[0].a.y == 5 && chain.bars[1].a.y == 5);
    // A bar that ends IN another has landed only while that other is there. Bar 1 ends
    // in bar 0, which is cut in the air and goes: bar 1 goes with it, and bar 2, which
    // ends in bar 1. Bar 4 ends in bar 3, which stands on solid at both ends: both stay,
    // and bar 4 still points at bar 3 after the others are gone.
    Bars into;
    into.bars = {bar({0, 0, 0}, {4, 0, 0}, Bar::End::Solid, Bar::End::Surface),
                 bar({2, 3, 0}, {2, 0, 0}, Bar::End::Solid, Bar::End::Joined),
                 bar({5, 1.5, 0}, {2, 1.5, 0}, Bar::End::Solid, Bar::End::Joined),
                 bar({0, 9, 0}, {4, 9, 0}, Bar::End::Solid, Bar::End::Solid),
                 bar({2, 12, 0}, {2, 9, 0}, Bar::End::Solid, Bar::End::Joined)};
    into.bars[1].into_b = 0;
    into.bars[2].into_b = 1;
    into.bars[4].into_b = 3;
    drop_loose_bars(into);
    CHECK(into.dropped == 3 && into.bars.size() == 2);
    CHECK(into.bars[0].a.y == 9 && into.bars[1].a.y == 12 && into.bars[1].into_b == 0);
  }
  {  // The same block, the region pulled 2 mm in from the outline: solid all round it.
     // A bar cut at the region's edge runs on into the solid by its own width (S11).
    PartMeasure pm(weld_mesh(box(20, 20, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {10, 10, 12}, down, 10, 10, 6, -2.0)};
    Domain d(pm, s);
    auto pr = d.probe();
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    const Bars bars = lay_bars(l, d);
    int solid_ends = 0, wrong = 0, surface = 0;
    for (const Bar& b : bars.bars)
      for (int e = 0; e < 2; ++e) {
        const Bar::End kind = e ? b.end_b : b.end_a;
        const Vec3& p = e ? b.b : b.a;
        if (kind == Bar::End::Surface) ++surface;
        if (kind != Bar::End::Solid) continue;
        ++solid_ends;
        const double edge = region_edge_distance(s.regions[0], p);
        // In the solid, past the region's edge, by no more than its own width.
        if (pr.where(p).lattice() || pr.part().depth(p) < -1e-6) ++wrong;
        // (An octet strut meets the region's edge at 45 degrees, so one width along it is
        // 0.7 of a width past the edge.)
        if (p.z > 6.0 + 1e-6 && !(edge < -0.6 * b.width && edge > -b.width - 1e-6)) ++wrong;
      }
    CHECK(solid_ends > 20);
    CHECK(wrong == 0);
    CHECK(surface == 0);           // the lattice nowhere reaches the block's sides
  }
}

// The distance from a point to a bar's middle line.
static double off_bar(const Vec3& p, const Bar& b) {
  const Vec3 e{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z}, r{p.x - b.a.x, p.y - b.a.y, p.z - b.a.z};
  const double ee = e.x * e.x + e.y * e.y + e.z * e.z;
  const double u = ee > 0 ? std::clamp((e.x * r.x + e.y * r.y + e.z * r.z) / ee, 0.0, 1.0) : 0.0;
  const Vec3 g{r.x - e.x * u, r.y - e.y * u, r.z - e.z * u};
  return std::sqrt(g.x * g.x + g.y * g.y + g.z * g.z);
}

// S5: where two walls with different cells meet, each side's cut struts run on until
// they end inside a bar of the other side. No join relies on the part's shell.
static void test_bars_join() {
  // A 12 mm wall beside a 5 mm wall, lattice from their common flat face: 6 mm cells
  // beside 5 mm cells, meeting along x = 32 where neither grid has a cell boundary (the
  // 6 mm cells run 2 mm past it, the 5 mm cells start 1 mm before it).
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 5}, {32, 5}, {32, 12}, {0, 12}}, 0, 41)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {30, 0, 20.5}, {0, 1, 0}, 30, 30, 12)};
  Domain d(pm, s);
  auto pr = d.probe();
  CellSpec cs;
  cs.cell_max_mm = 6;
  Layout l = lay_cells(d, cs);
  set_struts(l, StrutSpec{});
  const Bars laid = lay_bars(l, d);
  int loose_before = 0;
  for (const Bar& b : laid.bars)
    loose_before += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
  CHECK(loose_before > 50);            // both sides stop loose along the line
  Bars bars = laid;
  const std::size_t landed = join_loose_bars(bars, d);
  CHECK(landed == bars.joined && bars.bars.size() == laid.bars.size());
  CHECK(landed * 2 > static_cast<std::size_t>(loose_before));   // most of them land
  int not_inside = 0, too_far = 0, outside = 0, thick_into_thin = 0, thin_into_thick = 0, moved_other = 0;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar &b = bars.bars[i], &was = laid.bars[i];
    if (pr.part().depth(b.a) < -1e-6 || pr.part().depth(b.b) < -1e-6) ++outside;
    for (int e = 0; e < 2; ++e) {
      const Bar::End kind = e ? b.end_b : b.end_a, kind_was = e ? was.end_b : was.end_a;
      const Vec3 &p = e ? b.b : b.a, &p_was = e ? was.b : was.a;
      const double run = std::sqrt((p.x - p_was.x) * (p.x - p_was.x) + (p.y - p_was.y) * (p.y - p_was.y) +
                                   (p.z - p_was.z) * (p.z - p_was.z));
      if (kind_was != Bar::End::Loose) { if (run > 0.0 || kind != kind_was) ++moved_other; continue; }
      if (run > b.cell + b.width + 1e-9) ++too_far;        // one cell of its own, no farther
      if (kind != Bar::End::Joined) continue;
      // It ends inside another bar: its end is within that bar's half width of its middle.
      bool inside = false, into_5 = false, into_6 = false;
      for (std::size_t k = 0; k < laid.bars.size(); ++k)
        if (k != i && off_bar(p, laid.bars[k]) <= 0.5 * laid.bars[k].width + 1e-9) {
          inside = true;
          if (b.cell > laid.bars[k].cell + 0.5) into_5 = true;   // a 6 mm cell's strut in a 5 mm cell's
          if (b.cell < laid.bars[k].cell - 0.5) into_6 = true;
        }
      if (!inside) ++not_inside;
      thick_into_thin += into_5;
      thin_into_thick += into_6;
    }
  }
  CHECK(not_inside == 0);
  CHECK(too_far == 0);
  CHECK(outside == 0);                 // nothing was run out of the part
  CHECK(moved_other == 0);             // only loose ends move
  CHECK(thick_into_thin > 0 && thin_into_thick > 0);   // each wall's struts reach the other's
  // The struts lying IN the latticed face (y = 0) are cut at the line too, and run on along
  // the face: on the surface itself nothing is "inside", so they are read a hair in.
  int in_face_loose = 0, in_face_joined = 0;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar &b = bars.bars[i], &was = laid.bars[i];
    if (std::fabs(was.a.y) > 1e-9 || std::fabs(was.b.y) > 1e-9) continue;
    for (int e = 0; e < 2; ++e) {
      if ((e ? was.end_b : was.end_a) != Bar::End::Loose) continue;
      ++in_face_loose;
      if ((e ? b.end_b : b.end_a) == Bar::End::Joined) ++in_face_joined;
      CHECK(std::fabs((e ? b.b : b.a).y) < 1e-9);   // still in the face
    }
  }
  CHECK(in_face_loose > 4 && in_face_joined * 2 > in_face_loose);
  // The same bars whichever way it is asked again.
  Bars again = laid;
  join_loose_bars(again, d);
  CHECK(same_bars(again, bars));
  drop_loose_bars(bars);
  int loose_after = 0, into_nothing = 0, joined_left = 0;
  for (std::size_t i = 0; i < bars.bars.size(); ++i) {
    const Bar& b = bars.bars[i];
    loose_after += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
    for (int e = 0; e < 2; ++e) {
      if ((e ? b.end_b : b.end_a) != Bar::End::Joined) continue;
      ++joined_left;
      const int into = e ? b.into_b : b.into_a;
      // It points at a bar that is still there, and its end is inside that bar.
      if (into < 0 || into >= static_cast<int>(bars.bars.size()) || into == static_cast<int>(i) ||
          off_bar(e ? b.b : b.a, bars.bars[static_cast<std::size_t>(into)]) >
              0.5 * bars.bars[static_cast<std::size_t>(into)].width + 1e-9)
        ++into_nothing;
    }
  }
  CHECK(loose_after == 0);
  CHECK(joined_left > 20 && into_nothing == 0);
}

// S4: where Finish None leaves a stepped edge, the layout says where.
static void test_stepped_edges() {
  const Vec3 down{0, 0, -1};
  CellSpec cs;
  cs.cell_max_mm = 6;
  PartMeasure pm(weld_mesh(box(20, 20, 12)));
  auto laid = [&](double expand, bool skin) {
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {10, 10, 12}, down, 10, 10, 6, expand)};
    Domain d(pm, s);
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    Bars bars = lay_bars(l, d);
    if (skin) lay_skin(bars, d);
    drop_loose_bars(bars);
    return bars;
  };
  {  // The block's four sides cut its lattice: one edge all the way round.
    const Bars bars = laid(0.0, false);
    const std::vector<SteppedEdge> edges = stepped_edges(bars);
    CHECK(edges.size() == 1);
    if (!edges.empty()) {
      const SteppedEdge& e = edges[0];
      CHECK(e.region == 1 && e.ends == bars.cut_in_air.size() && e.ends > 100);
      NEAR(e.at.x, 10.0, 0.01);   // round a square block its middle is the block's
      NEAR(e.at.y, 10.0, 0.01);
      NEAR(e.lo.x, 0.0, 1e-6);    // and its ends are on the block's sides
      NEAR(e.hi.x, 20.0, 1e-6);
      NEAR(e.lo.y, 0.0, 1e-6);
      NEAR(e.hi.y, 20.0, 1e-6);
      CHECK(e.lo.z >= 6.0 - 1e-6 && e.hi.z <= 12.0 + 1e-6);
    }
  }
  {  // With the skin holding the cut ends there is far less of it, or none.
    const Bars bare = laid(0.0, false), skinned = laid(0.0, true);
    CHECK(skinned.cut_in_air.size() * 5 < bare.cut_in_air.size());
  }
  {  // The region pulled in from the sides: nothing is cut by air, nothing is stepped.
    const Bars bars = laid(-2.0, false);
    CHECK(bars.cut_in_air.empty() && stepped_edges(bars).empty());
  }
  {  // By hand: ends within a cell and a half are one edge; a lone pair is not an edge;
     // another region's ends are another edge; the larger edge comes first.
    Bars bars;
    auto end = [](double x, double y, int region) { return Bars::CutEnd{{x, y, 0}, region, 4.0}; };
    bars.cut_in_air = {end(0, 0, 1), end(5, 0, 1), end(10, 0, 1), end(15, 0, 1),     // 4, each 5 from the next
                       end(40, 0, 1), end(45, 0, 1),                                   // 2: not an edge
                       end(0, 3, 2), end(5, 3, 2), end(10, 3, 2),                      // region 2, right beside
                       end(22, 0, 1)};                                                 // 7 from the last of the first: not joined
    const std::vector<SteppedEdge> edges = stepped_edges(bars);
    CHECK(edges.size() == 2);
    if (edges.size() == 2) {
      CHECK(edges[0].region == 1 && edges[0].ends == 4 && edges[1].region == 2 && edges[1].ends == 3);
      NEAR(edges[0].at.x, 7.5, 1e-12);
      NEAR(edges[1].at.y, 3.0, 1e-12);
    }
  }
}

// S3: Finish Skin. Bars across the part's surface joining the cut strut ends.
static void test_skin() {
  const Vec3 down{0, 0, -1};
  CellSpec cs;
  cs.cell_max_mm = 6;
  {  // The 20 mm block: its side cells are cut by its four sides.
    PartMeasure pm(weld_mesh(box(20, 20, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {10, 10, 12}, down, 10, 10, 6)};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    const Bars laid = lay_bars(l, d);
    Bars bars = laid;
    const std::size_t made = lay_skin(bars, d);
    CHECK(made > 20 && bars.bars.size() == laid.bars.size() + made);
    int side[4] = {0, 0, 0, 0}, off = 0, too_long = 0, not_skin = 0;
    std::vector<const Bar*> on_x0;
    for (std::size_t i = laid.bars.size(); i < bars.bars.size(); ++i) {
      const Bar& b = bars.bars[i];
      const Vec3 mid{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
      if (!b.skin) ++not_skin;
      if (std::fabs(pr.part().depth(b.a)) > 1e-6 || std::fabs(pr.part().depth(b.b)) > 1e-6 ||
          std::fabs(pr.part().depth(mid)) > 1e-6)
        ++off;                                   // it lies ON the surface, end to end
      if (bar_length(b) > 1.2 * 6.0 + 1e-9) ++too_long;
      if (std::fabs(mid.x) < 1e-6) { ++side[0]; on_x0.push_back(&b); }
      if (std::fabs(mid.x - 20) < 1e-6) ++side[1];
      if (std::fabs(mid.y) < 1e-6) ++side[2];
      if (std::fabs(mid.y - 20) < 1e-6) ++side[3];
    }
    CHECK(not_skin == 0 && off == 0 && too_long == 0);
    // The block and its cells are the same on all four sides, and so is the skin (C9).
    CHECK(side[0] > 5 && side[0] == side[1] && side[1] == side[2] && side[2] == side[3]);
    // A regular pattern (his answer, 2026-11-12): the lattice's own grid drawn on the
    // side. On the side x = 0 every skin bar runs straight along y or straight along z,
    // each lies in a plane of the cells' grid (a multiple of half a cell from the cells'
    // own origin), and bars that cross do so at right angles.
    int slanted = 0, off_grid = 0, along_y = 0, along_z = 0;
    for (const Bar* b : on_x0) {
      const bool is_y = std::fabs(b->a.z - b->b.z) < 1e-9, is_z = std::fabs(b->a.y - b->b.y) < 1e-9;
      if (is_y == is_z) { ++slanted; continue; }
      ++(is_y ? along_y : along_z);
      // The cells are 6 mm, laid from y = -2 and from the top z = 12: planes every 3 mm.
      const double at = is_y ? (12.0 - b->a.z) / 3.0 : (b->a.y + 2.0) / 3.0;
      if (std::fabs(at - std::round(at)) > 1e-6) ++off_grid;
    }
    CHECK(slanted == 0 && off_grid == 0);
    CHECK(along_y > 3 && along_z > 3);
    // A cut end that got a skin bar has landed, and nothing else changed.
    int still_cut = 0, landed = 0, unpointed = 0;
    for (std::size_t i = 0; i < laid.bars.size(); ++i)
      for (int e = 0; e < 2; ++e) {
        const Bar::End was = e ? laid.bars[i].end_b : laid.bars[i].end_a, now = e ? bars.bars[i].end_b : bars.bars[i].end_a;
        if (was != Bar::End::Surface) { CHECK(now == was); continue; }
        ++(now == Bar::End::Joined ? landed : still_cut);
        if (now != Bar::End::Joined) continue;
        // It says which skin bar it ended in, and that bar starts or ends at this very point.
        const int into = e ? bars.bars[i].into_b : bars.bars[i].into_a;
        const Vec3& p = e ? bars.bars[i].b : bars.bars[i].a;
        bool right = into >= static_cast<int>(laid.bars.size()) && into < static_cast<int>(bars.bars.size());
        if (right) {
          const Bar& sk = bars.bars[static_cast<std::size_t>(into)];
          right = sk.skin && ((sk.a.x == p.x && sk.a.y == p.y && sk.a.z == p.z) || (sk.b.x == p.x && sk.b.y == p.y && sk.b.z == p.z));
        }
        if (!right) ++unpointed;
      }
    CHECK(unpointed == 0);
    CHECK(landed > 100 && still_cut * 10 < landed);
    // With the skin, Finish None's rule has far less to remove.
    Bars bare = laid;
    drop_loose_bars(bare);
    drop_loose_bars(bars);
    CHECK(bars.dropped * 3 < bare.dropped);
    CHECK(count_pieces(bars, d).adrift == 0);
  }
  {  // By hand, on the top of a block: two cut ends 5 mm apart are joined; two 9 mm apart,
     // with nothing between them, are not (no farther than 1.2 of their 6 mm cell).
    PartMeasure pm(weld_mesh(box(30, 30, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 6)};
    Domain d(pm, s);
    auto stub = [](double x, double y) {
      Bar b;
      b.a = {x, y, 10}; b.b = {x, y, 12}; b.end_b = Bar::End::Surface; b.width = 0.5; b.cell = 6.0;
      return b;
    };
    Bars bars;
    bars.bars = {stub(5, 5), stub(14, 5), stub(5, 20), stub(10, 20)};
    CHECK(lay_skin(bars, d) == 1);
    CHECK(bars.bars.size() == 5 && bars.bars[4].skin);
    NEAR(bar_length(bars.bars[4]), 5.0, 1e-12);
    NEAR(bars.bars[4].width, 0.5, 0.0);          // as wide as the struts it joins
    CHECK(bars.bars[0].end_b == Bar::End::Surface && bars.bars[1].end_b == Bar::End::Surface);
    CHECK(bars.bars[2].end_b == Bar::End::Joined && bars.bars[3].end_b == Bar::End::Joined);
    SkinSpec wide;
    wide.width_mm = 0.9;                         // or the width asked for (S7)
    Bars again;
    again.bars = {stub(5, 20), stub(10, 20)};
    CHECK(lay_skin(again, d, wide) == 1);
    NEAR(again.bars[2].width, 0.9, 0.0);
  }
  {  // By hand: ends of struts that lie in ONE plane of the grid are joined along it; an end
     // of another plane, though it is nearer, is not.
    PartMeasure pm(weld_mesh(box(30, 30, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 6)};
    Domain d(pm, s);
    auto stub = [](double x, double y, Vec3 flat) {
      Bar b;
      b.a = {x, y, 10}; b.b = {x, y, 12}; b.end_b = Bar::End::Surface; b.width = 0.5; b.cell = 6.0;
      b.flat = flat;
      return b;
    };
    Bars bars;
    bars.bars = {stub(5, 10, {0, 1, 0}), stub(9, 10, {0, 1, 0}),     // both in the plane y = 10
                 stub(6, 11, {0, 1, 0}),                             // in the plane y = 11: alone
                 stub(7, 10, {1, 0, 0})};                            // between the first two, in the plane x = 7
    CHECK(lay_skin(bars, d) == 1);
    CHECK(bars.bars.size() == 5);
    NEAR(bars.bars[4].a.y, 10.0, 0.0);
    NEAR(bars.bars[4].b.y, 10.0, 0.0);
    NEAR(bar_length(bars.bars[4]), 4.0, 1e-12);
    CHECK(bars.bars[2].end_b == Bar::End::Surface && bars.bars[3].end_b == Bar::End::Surface);
    // The same plane named from its other side is the same plane.
    Bars flipped;
    flipped.bars = {stub(5, 10, {0, 1, 0}), stub(9, 10, {0, -1, 0})};
    CHECK(lay_skin(flipped, d) == 1);
  }
  {  // An L: cut ends on the two walls of its notch. No skin bar runs across the notch.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 20}, {20, 20}, {20, 60}, {0, 60}}, 0, 12)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 30, 12}, down, 30, 30, 6)};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    Bars bars = lay_bars(l, d);
    const std::size_t before = bars.bars.size();
    CHECK(lay_skin(bars, d) > 50);
    int in_air = 0, on_notch_walls = 0;
    for (std::size_t i = before; i < bars.bars.size(); ++i) {
      const Bar& b = bars.bars[i];
      for (int k = 0; k <= 10; ++k) {
        const double t = k / 10.0;
        if (pr.part().depth({b.a.x + (b.b.x - b.a.x) * t, b.a.y + (b.b.y - b.a.y) * t, b.a.z + (b.b.z - b.a.z) * t}) < -1e-6)
          ++in_air;
      }
      if ((std::fabs(b.a.x - 20) < 1e-6 && b.a.y > 20) || (std::fabs(b.a.y - 20) < 1e-6 && b.a.x > 20)) ++on_notch_walls;
    }
    CHECK(in_air == 0);
    CHECK(on_notch_walls > 10);   // the notch's own walls do get their skin
  }
}

// S4, S5, S6: the lattice is one piece and joined to the part; a piece adrift is removed.
static void test_pieces() {
  const Vec3 down{0, 0, -1};
  PartMeasure pm(weld_mesh(box(30, 30, 12)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 12, -3.0)};   // solid all round
  Domain d(pm, s);
  auto bar = [](Vec3 a, Vec3 b, Bar::End ea = Bar::End::Node, Bar::End eb = Bar::End::Node) {
    Bar x;
    x.a = a; x.b = b; x.end_a = ea; x.end_b = eb; x.width = 0.5;
    return x;
  };
  Bars bars;
  bars.bars = {
      // 0-2: a triangle, one corner ending in solid: joined to the part.
      bar({6, 6, 6}, {8, 6, 6}, Bar::End::Solid), bar({8, 6, 6}, {7, 8, 6}), bar({7, 8, 6}, {6, 6, 6}),
      // 3-5: a triangle touching nothing: adrift.
      bar({12, 6, 6}, {14, 6, 6}), bar({14, 6, 6}, {13, 8, 6}), bar({13, 8, 6}, {12, 6, 6}),
      // 6-7: two bars crossing in one plane with no end in common, one ending in solid: one piece.
      bar({18, 6, 6}, {20, 8, 6}, Bar::End::Solid), bar({18, 8, 6}, {20, 6, 6}),
      // 8-9: a T (the end of one inside the side of the other), in the air: one piece, adrift.
      bar({6, 14, 6}, {10, 14, 6}), bar({8, 14.2, 6}, {8, 17, 6}),
      // 10-11: side by side a millimetre apart: two pieces, both adrift.
      bar({14, 14, 6}, {18, 14, 6}), bar({14, 15, 6}, {18, 15, 6}),
      // 12: one bar whose end is a node a fifth of a millimetre from the solid ring: it stands on it.
      bar({3.2, 22, 6}, {6, 22, 6}),
  };
  std::vector<char> adrift;
  std::vector<int> piece;
  const Pieces found = count_pieces(bars, d, &adrift, &piece);
  CHECK(found.pieces == 7);
  CHECK(found.adrift == 4 && found.adrift_bars == 7);
  NEAR(found.adrift_mm, (2 + 2 * std::sqrt(5.0)) + (4 + 2.8) + 4 + 4, 1e-9);
  NEAR(found.largest_adrift_mm, 4 + 2.8, 1e-9);   // the T
  CHECK(piece[0] == piece[1] && piece[1] == piece[2] && piece[6] == piece[7] && piece[8] == piece[9]);
  CHECK(piece[10] != piece[11] && piece[3] != piece[0]);
  const std::vector<char> want = {0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0};
  CHECK(adrift == want);
  const Pieces before = drop_adrift_bars(bars, d);
  CHECK(before.adrift == 4 && bars.bars.size() == 6 && bars.dropped == 7);
  CHECK(count_pieces(bars, d).adrift == 0);

  // A part that is lattice all through has no solid to be joined to: its lattice IS the
  // part, and is not adrift. A stray bar beside it is.
  PartMeasure cube(weld_mesh(box(12, 12, 12)));
  DomainSpec all;
  all.regions = {face_region(1, Role::Lattice, {6, 6, 12}, down, 6, 6, 12)};
  Domain dc(cube, all);
  CellSpec cs;
  cs.cell_max_mm = 6;
  Layout l = lay_cells(dc, cs);
  set_struts(l, StrutSpec{});
  Bars whole = lay_bars(l, dc);
  const Pieces one = count_pieces(whole, dc);
  CHECK(one.pieces == 1 && one.adrift == 0);
  whole.bars.push_back(bar({1.3, 1.1, 5.2}, {1.9, 1.4, 5.5}));
  const Pieces two = count_pieces(whole, dc);
  CHECK(two.pieces == 2 && two.adrift == 1 && two.adrift_bars == 1);

  // S5, said as it matters: two walls with different cells are ONE piece once joined.
  PartMeasure step(weld_mesh(prism({{0, 0}, {60, 0}, {60, 5}, {32, 5}, {32, 12}, {0, 12}}, 0, 41)));
  DomainSpec two_walls;
  two_walls.regions = {face_region(1, Role::Lattice, {30, 0, 20.5}, {0, 1, 0}, 30, 30, 12)};
  Domain ds(step, two_walls);
  Layout ls = lay_cells(ds, cs);
  set_struts(ls, StrutSpec{});
  Bars joined = lay_bars(ls, ds);
  join_loose_bars(joined, ds);
  drop_loose_bars(joined);
  std::vector<int> of;
  const Pieces after = count_pieces(joined, ds, nullptr, &of);
  int left = -1, right = -1;
  for (std::size_t i = 0; i < joined.bars.size(); ++i) {
    const Bar& b = joined.bars[i];
    if (std::max(b.a.x, b.b.x) < 20 && left < 0) left = of[i];
    if (std::min(b.a.x, b.b.x) > 44 && right < 0) right = of[i];
  }
  CHECK(left >= 0 && left == right);
  CHECK(after.adrift == 0);
}

// D14b (his rule on his v3 stand, 2026-11-12: "It's either consistently latticed all around the pocket, or it
// isn't"; "Why can't the pocket just cut the lattices wherever they are positioned"). His stand in small: a slab of
// lattice under a flat face, and a shell of lattice round a curved pocket cut into the opposite side, the two sharing
// the wall between them. Without the rule the wedges where one region's share is too thin for its cells are solid,
// and so is the pocket's own surface wherever a cube is cut too thinly for its sample points to see.
static void slivers_case(double cx, double slab_mm, long tally[13]) {
  // A 40 x 9.83 bar, 20 long, with a half-round pocket (radius 6) in its top edge: 3.83 mm of wall under the
  // pocket at its thinnest, his stand's own number.
  const double H = 9.83;
  std::vector<std::array<double, 2>> xy = {{0, 0}, {40, 0}, {40, H}, {cx + 6, H}};
  const int N = 48;
  for (int i = 1; i < N; ++i) {
    const double t = 3.14159265358979323846 * i / N;   // from (26, 14) round under to (14, 14)
    xy.push_back({cx + 6 * std::cos(t), H - 6 * std::sin(t)});
  }
  xy.push_back({cx - 6, H});
  xy.push_back({0, H});
  const TriangleMesh solid_mesh = prism_any(xy, 0, 20);
  // The same triangles as a model with faces: the flat underside, the pocket's wall, the rest.
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
    auto on_arc = [H, cx](const Vec3& v) { return std::fabs(std::hypot(v.x - cx, v.y - H) - 6) < 1e-6 && v.y < H + 1e-9; };
    int f = 2;
    if (a.y < 1e-9 && b.y < 1e-9 && c.y < 1e-9) f = 0;
    else if (on_arc(a) && on_arc(b) && on_arc(c) && !(a.z == b.z && b.z == c.z)) f = 1;
    model.triangle_face.push_back(f);
  }
  PartMeasure pm(weld_mesh(model.mesh));
  auto domain_spec = [&] {
    DomainSpec s;
    s.min_strut_lines = 2.0;   // as he prints
    bool ok = false;
    // As on his stand: the pocket's shell is region 1, the slab under the flat face region 2.
    s.regions.push_back(region_from_faces(model, {1}, 1, Role::Lattice, 4.0, 0.0, &ok));
    CHECK(ok && s.regions.back().is_shell());
    s.regions.push_back(region_from_faces(model, {0}, 2, Role::Lattice, slab_mm, 0.0, &ok));
    CHECK(ok && !s.regions.back().is_shell());
    return s;
  };
  Domain d(pm, domain_spec());
  auto pr = d.probe();
  CellSpec cs;
  cs.algorithm = Algorithm::Stepped;
  cs.cell_max_mm = 8;
  cs.min_cells_across = 1;
  cs.allow_quilt = true;     // his per-part choice: small cells in thin walls
  CHECK(cs.absorb_slivers);   // the rule is on unless switched off
  CellSpec plain = cs;
  plain.absorb_slivers = false;
  const Layout on = lay_cells(d, cs), off = lay_cells(d, plain);
  CHECK(on.absorb && on.index && !off.absorb);
  CHECK(!on.cells.empty() && !off.cells.empty());
  // Every lattice point of three levels, on a quarter-millimetre grid: how many cells hold it.
  long taken = 0;
  auto count = [&](const Layout& l, long* unheld, long* twice, long* lattice) {
    *unheld = *twice = *lattice = 0;
    for (double z : {4.3, 10.1, 15.7})
      for (double y = 0.125; y < H; y += 0.25)
        for (double x = 6.125; x < 34.0; x += 0.25) {
          const Vec3 p{x, y, z};
          if (!pr.where(p).lattice()) continue;
          ++*lattice;
          int holders = 0;
          for (const Cell& c : l.cells)
            if (cell_holds(l, pr, c, p)) {
              ++holders;
              if (c.region != pr.where(p).id) ++taken;   // lattice of one region, in a cell of the other
            }
          *unheld += holders == 0;
          *twice += holders > 1;
        }
  };
  long un_off = 0, tw_off = 0, lat = 0, un_on = 0, tw_on = 0;
  count(off, &un_off, &tw_off, &lat);
  CHECK(taken == 0);   // without the rule a cell holds its own region's lattice only
  count(on, &un_on, &tw_on, &lat);
  tally[8] += taken;
  std::printf("slivers, pocket at x %.1f, slab %.1f: of %ld lattice points, held by no cell: %ld without the rule, %ld with it (%ld taken in from the other region); held twice: %ld, %ld; cells %zu -> %zu\n",
              cx, slab_mm, lat, un_off, un_on, taken, tw_off, tw_on, off.cells.size(), on.cells.size());
  CHECK(un_on <= un_off);
  CHECK(tw_off == 0 && tw_on == 0);   // never by two cells: no lattice laid twice over
  tally[0] += un_off; tally[1] += un_on;
  // The pocket's own wall, a hair inside the surface, all the way round: lattice everywhere the domain says so.
  long wall_lat = 0, wall_off = 0, wall_on = 0;
  for (int i = 2; i < 4 * N - 2; ++i)
    for (double z : {2.2, 6.9, 10.4, 13.3, 17.6}) {
      const double t = 3.14159265358979323846 * i / (4 * N);
      const Vec3 p{cx + 6.12 * std::cos(t), H - 6.12 * std::sin(t), z};
      if (!pr.where(p).lattice()) continue;
      ++wall_lat;
      int h_off = 0, h_on = 0;
      for (const Cell& c : off.cells) h_off += cell_holds(off, pr, c, p);
      for (const Cell& c : on.cells) h_on += cell_holds(on, pr, c, p);
      wall_off += h_off > 0;
      wall_on += h_on > 0;
    }
  std::printf("slivers, pocket at x %.1f: round its wall, %ld lattice points: in a cell %ld without the rule, %ld with it\n", cx, wall_lat, wall_off, wall_on);
  CHECK(wall_lat > 500 && wall_on >= wall_off);
  tally[2] += wall_lat; tally[3] += wall_off; tally[4] += wall_on;
  // A cube laid by the rule alone has air in it: a sliver under solid is never opened.
  auto same_cube = [](const Cell& a, const Cell& b) {
    return a.frame == b.frame && a.region == b.region && a.size == b.size && a.lo[0] == b.lo[0] && a.lo[1] == b.lo[1] && a.lo[2] == b.lo[2];
  };
  int added = 0, added_with_air = 0;
  for (const Cell& c : on.cells) {
    bool was = false;
    for (const Cell& o : off.cells) was = was || same_cube(c, o);
    if (was) continue;
    ++added;
    const Frame& f = on.frames[static_cast<std::size_t>(c.frame)];
    bool air = false;
    for (int k = 0; k < 27 && !air; ++k)
      air = pr.where(f.at(c.lo[0] + c.size * (1 + 2 * (k % 3)) / 6.0, c.lo[1] + c.size * (1 + 2 * ((k / 3) % 3)) / 6.0,
                          c.lo[2] + c.size * (1 + 2 * (k / 9)) / 6.0)).why == Why::Outside;
    added_with_air += air;
  }
  CHECK(added_with_air == added);
  tally[5] += added;
  // The struts follow: more of them, none loose after the joining, the same on every run and on one thread.
  Layout ls = on, lp = off;
  set_struts(ls, StrutSpec{});
  set_struts(lp, StrutSpec{});
  Bars with = lay_bars(ls, d), without = lay_bars(lp, d);
  CHECK(same_bars(with, lay_bars(ls, d)) && same_bars(with, lay_bars(ls, d, 1)));
  double len_with = 0, len_without = 0;
  for (const Bar& b : with.bars) len_with += std::sqrt((b.a.x - b.b.x) * (b.a.x - b.b.x) + (b.a.y - b.b.y) * (b.a.y - b.b.y) + (b.a.z - b.b.z) * (b.a.z - b.b.z));
  for (const Bar& b : without.bars) len_without += std::sqrt((b.a.x - b.b.x) * (b.a.x - b.b.x) + (b.a.y - b.b.y) * (b.a.y - b.b.y) + (b.a.z - b.b.z) * (b.a.z - b.b.z));
  CHECK(len_with >= len_without - 1e-9);
  tally[6] += static_cast<long>(len_without); tally[7] += static_cast<long>(len_with);
  // Finish Skin on the pocket's curved wall (his words: "not just with singular vertical lines, but with a lattice all
  // along the face"). The struts the wall cuts are joined along the wall both ways: along the pocket (lines) AND round
  // it (rings). A ring's bar is a straight piece between two points of a hollow wall, so its middle is in the air by
  // the bow of the curve; with no bow allowed there are no rings at all.
  if (slab_mm == 3.8) {
    auto skinned = [&](double bow, long* along, long* round, double* worst) {
      Bars b = lay_bars(ls, d);
      join_loose_bars(b, d, 0, &ls);
      SkinSpec sk;
      sk.bow = bow;
      const std::size_t made = lay_skin(b, d, sk);
      *along = *round = 0;
      *worst = 0.0;
      for (const Bar& x : b.bars) {
        if (!x.skin) continue;
        if (std::hypot((x.a.x + x.b.x) / 2 - cx, (x.a.y + x.b.y) / 2 - H) > 6.6) continue;   // on the pocket's wall,
        if (std::min(x.a.z, x.b.z) < 0.5 || std::max(x.a.z, x.b.z) > 19.5) continue;         // not on the bar's two ends
        const double len = std::sqrt((x.a.x - x.b.x) * (x.a.x - x.b.x) + (x.a.y - x.b.y) * (x.a.y - x.b.y) + (x.a.z - x.b.z) * (x.a.z - x.b.z));
        (std::fabs(x.a.z - x.b.z) > 0.7 * len ? *along : *round) += 1;
        const double off = std::fabs(pr.part().depth(Vec3{(x.a.x + x.b.x) / 2, (x.a.y + x.b.y) / 2, (x.a.z + x.b.z) / 2}));
        *worst = std::max(*worst, off - 0.1 * len);
      }
      return made;
    };
    long along0 = 0, round0 = 0, along1 = 0, round1 = 0;
    double worst0 = 0, worst1 = 0;
    const std::size_t made0 = skinned(0.0, &along0, &round0, &worst0), made1 = skinned(0.1, &along1, &round1, &worst1);
    CHECK(made1 >= made0 && round1 >= round0 && along1 >= along0);
    CHECK(worst1 <= 0.02 + 1e-6);   // no bar strays from the wall by more than the bow allowed
    tally[9] += along1; tally[10] += round1; tally[11] += along0; tally[12] += round0;
  }
  // What it must NOT take in: a wall of the SAME region too thin for its cell stays solid (D8;
  // test_struts_end_in_no_cell_space holds that with the rule on).
}
static void test_slivers_are_taken_in() {
  // The pocket at five places across the cells' grid (where a cube is cut thinly depends on where the grid falls),
  // then three deeper slabs (where the two regions' cubes overlap).
  long tally[13] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  for (double cx : {20.0, 20.7, 21.4, 22.1, 22.8}) slivers_case(cx, 3.8, tally);
  for (double slab : {5.0, 6.0, 7.0}) slivers_case(21.4, slab, tally);
  std::printf("slivers, all eight: held by no cell %ld -> %ld; round the wall, of %ld: %ld -> %ld in a cell; cubes laid by the rule %ld; strut length %ld -> %ld mm\n",
              tally[0], tally[1], tally[2], tally[3], tally[4], tally[5], tally[6], tally[7]);
  CHECK(tally[0] > 300);                    // the fault is there to cure
  CHECK(tally[1] * 10 <= tally[0] * 6);     // at least four tenths of it is taken in (what is left lies inside, away from the wall)
  CHECK(tally[4] > tally[3]);
  CHECK(tally[4] * 100 >= tally[2] * 97);   // round the pocket's wall: consistently, all the way round
  CHECK(tally[5] > 0);
  CHECK(tally[8] > 300);                    // and the seam between the two regions: lattice of one, taken in by the other's cell
  std::printf("skin on the pocket's wall, five pockets: %ld bars along it and %ld round it (with no bow allowed: %ld along, %ld round)\n",
              tally[9], tally[10], tally[11], tally[12]);
  CHECK(tally[9] > 100 && tally[10] > 100);   // a lattice along the face: both ways
  CHECK(tally[10] > 4 * tally[12]);           // the rings are there because the bow is allowed
  CHECK(tally[7] > tally[6]);
}

// Protect skins of one depth, however many: the same lattice as ONE skin holding all their faces, and no slower for
// their number (his v4 stand, 2026-11-13: 26 skins of 4 mm took 289 s a layout, the same faces as one skin 0.7 s).
// Which skin a point is in is still told skin by skin.
static void test_many_skins_of_one_depth() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  PartMeasure pm(weld_mesh(model.mesh));
  auto lay_with = [&](const std::vector<std::vector<int>>& skins, const std::vector<double>& depth, Bars* bars) {
    DomainSpec s;
    bool ok = false;
    s.regions.push_back(region_from_face(model, square, 1, Role::Lattice, 8.0, 0.0, &ok));
    for (std::size_t i = 0; i < skins.size(); ++i) s.protect.push_back({10 + static_cast<int>(i), faces_mesh(model, skins[i]), depth[i]});
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 4;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    *bars = lay_bars(l, d);
    join_loose_bars(*bars, d, 0, &l);
    return l;
  };
  Bars b3, b1, b2, b2m;
  const Layout three = lay_with({{L}, {sideA}, {sideB}}, {1.5, 1.5, 1.5}, &b3);
  const Layout one = lay_with({{L, sideA, sideB}}, {1.5}, &b1);
  CHECK(!three.cells.empty() && three.cells == one.cells && three.solid == one.solid && same_bars(b3, b1));
  // Two depths stay two: the deeper skin takes more of the lattice than the shallower one would.
  const Layout two = lay_with({{L}, {sideA}, {sideB}}, {3.0, 1.5, 1.5}, &b2);
  const Layout two_merged = lay_with({{L}, {sideA, sideB}}, {3.0, 1.5}, &b2m);
  CHECK(two.cells == two_merged.cells && same_bars(b2, b2m) && !(two.cells == three.cells && same_bars(b2, b3)));
  // And each skin is still named by its own number.
  DomainSpec s;
  bool ok = false;
  s.regions.push_back(region_from_face(model, square, 1, Role::Lattice, 8.0, 0.0, &ok));
  s.protect.push_back({10, faces_mesh(model, {L}), 1.5});
  s.protect.push_back({11, faces_mesh(model, {sideA}), 1.5});
  Domain d(pm, s);
  auto pr = d.probe();
  CHECK((pr.where({10, 40, 9.5}) == Where{Why::ProtectSkin, 10}));   // under the L, on the top
  CHECK((pr.where({0.5, 10, 5}) == Where{Why::ProtectSkin, 11}));    // behind side A
}

// D14 for the struts: lattice space that no cell holds is solid, and a strut that reaches
// it ends IN it, like in any other solid. (Found 2026-11-12: such an end was called loose
// and dropped, and a lattice standing on such a spot was called adrift.)
static void test_struts_end_in_no_cell_space() {
  // A 12 mm wall for x < 32 and a 2 mm wall beyond, lattice from their common face. With
  // Allow quilt off the 2 mm wall takes no cell: solid by D14, though the Domain still
  // says "lattice was asked for here". The 6 mm cells of the thick wall run 2 mm past
  // x = 32 and are cut there.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2}, {32, 2}, {32, 12}, {0, 12}}, 0, 41)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {30, 0, 20.5}, {0, 1, 0}, 30, 30, 12)};
  Domain d(pm, s);
  auto pr = d.probe();
  CellSpec cs;
  cs.cell_max_mm = 6;
  Layout l = lay_cells(d, cs);
  set_struts(l, StrutSpec{});
  CHECK(!l.solid.empty());
  const SolidAt solid(l);
  CHECK((pr.where({45, 1, 20}) == Where{Why::Lattice, 1}));   // asked for ...
  CHECK(solid(pr, {45, 1, 20}));                               // ... and solid: no cell holds it
  CHECK(!solid(pr, {15, 6, 20}));                              // in a cell: lattice
  CHECK(!solid(pr, {45, 6, 20}));                              // air
  CHECK(solid(pr, {33, 1, 20}));                               // just past the thick wall's cells
  Bars bars = lay_bars(l, d);
  int into_it = 0, loose_there = 0, ran_on = 0;
  for (const Bar& b : bars.bars)
    for (int e = 0; e < 2; ++e) {
      const Vec3& p = e ? b.b : b.a;
      if (p.x < 31.5 || p.y > 2.0) continue;   // ends at the line where the 2 mm wall begins
      const Bar::End kind = e ? b.end_b : b.end_a;
      if (kind == Bar::End::Loose) ++loose_there;
      if (kind != Bar::End::Solid) continue;
      ++into_it;
      // Run on into it by its own width (S11). (A strut lying in the part's surface ends
      // on the surface: it is read a hair inside.)
      const Vec3 in{p.x, std::max(p.y, 0.02), std::clamp(p.z, 0.02, 40.98)};
      if (p.x > 32.0 + 1e-6 && solid(pr, in)) ++ran_on;
    }
  CHECK(into_it > 10 && loose_there == 0);
  CHECK(ran_on == into_it);
  // Nothing there for the joining or the dropping to do; the lattice stands on the spot.
  const std::size_t before = bars.bars.size();
  join_loose_bars(bars, d, 0, &l);
  drop_loose_bars(bars);
  int still = 0;
  for (const Bar& b : bars.bars)
    if ((b.end_a == Bar::End::Solid && b.a.x > 31.5 && b.a.y < 2.0) || (b.end_b == Bar::End::Solid && b.b.x > 31.5 && b.b.y < 2.0))
      ++still;
  CHECK(still == into_it && bars.bars.size() <= before);
  CHECK(count_pieces(bars, d, nullptr, nullptr, &l).adrift == 0);

  // A bar whose only footing is such a spot is joined to the part once the layout is
  // given. By hand: a short bar standing in the 2 mm wall's own space (no cell: solid),
  // and a longer one in the middle of the thick wall's cells, touching nothing.
  Bars two;
  Bar on_spot, floating;
  on_spot.a = {45, 1.0, 20}; on_spot.b = {45, 1.0, 21}; on_spot.width = 0.5;
  floating.a = {15, 6.0, 19}; floating.b = {15, 6.0, 22}; floating.width = 0.5;
  two.bars = {on_spot, floating};
  std::vector<char> with, without;
  count_pieces(two, d, &with, nullptr, &l);
  count_pieces(two, d, &without);
  CHECK((with == std::vector<char>{0, 1}));      // the first stands on solid; the second is adrift
  // (Without the layout nothing is known to be solid there, so the longer one passes for
  // the part itself and the one on the spot for adrift: the mistake this fixes.)
  CHECK((without == std::vector<char>{1, 0}));
}

// S1, S2, S10: Finish Rim. One solid bar round a flat Lattice region's outline, as wide as
// asked (two line widths by default), only where the part's solid backs it.
static void test_rim() {
  const Vec3 down{0, 0, -1};
  PartMeasure pm(weld_mesh(box(30, 30, 12)));
  auto domain = [&](double expand, double rim) {
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 6, expand)};
    s.rim_mm = rim;
    return s;
  };
  for (double rim : {0.9, -1.0}) {   // asked for, and the default: two 0.45 mm lines
    // The region pulled 3 mm in from the block's sides: solid all round it.
    Domain d(pm, domain(-3.0, rim));
    auto pr = d.probe();
    CHECK((pr.where({15, 15, 10}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({3.5, 15, 10}) == Where{Why::Rim, 1}));      // 0.5 mm inside the edge
    CHECK((pr.where({3.85, 15, 7}) == Where{Why::Rim, 1}));      // 0.85, and deeper: the bar is as deep as the lattice
    CHECK((pr.where({3.95, 15, 10}) == Where{Why::Lattice, 1})); // 0.95: past the bar
    CHECK((pr.where({2.5, 15, 10}) == Where{Why::NotAsked, 0})); // outside the region
    CHECK((pr.where({3.5, 15, 5}) == Where{Why::NotAsked, 0}));  // below its depth
    CHECK((pr.where({3.4, 3.4, 10}) == Where{Why::Rim, 1}));     // round the corner
    CHECK((pr.where({26.5, 20, 10}) == Where{Why::Rim, 1}));
    CHECK((pr.where({15, 26.5, 10}) == Where{Why::Rim, 1}));
    // Exactly as smooth as the outline: along a straight edge the bar's inner side is a
    // straight line, whatever the cells are doing.
    int ragged = 0;
    for (double y = 5; y < 25; y += 0.137) {
      if (!(pr.where({3.899, y, 10}) == Where{Why::Rim, 1})) ++ragged;
      if (!(pr.where({3.901, y, 10}) == Where{Why::Lattice, 1})) ++ragged;
    }
    CHECK(ragged == 0);
    // The cells keep clear of it and the struts run on into it (S11).
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    CHECK(!l.cells.empty());
    int in_rim = 0;
    for (double x = 3.05; x < 3.9; x += 0.2)
      for (double y = 4; y < 26; y += 1.3)
        for (const Cell& c : l.cells)
          if (cell_holds(l, pr, c, {x, y, 10})) ++in_rim;
    CHECK(in_rim == 0);
    const Bars bars = lay_bars(l, d);
    int into_rim = 0, bad = 0;
    for (const Bar& b : bars.bars)
      for (int e = 0; e < 2; ++e) {
        const Bar::End kind = e ? b.end_b : b.end_a;
        if (kind == Bar::End::Surface || kind == Bar::End::Loose) ++bad;
        if (kind == Bar::End::Solid && pr.where(e ? b.b : b.a).why == Why::Rim) ++into_rim;
      }
    CHECK(bad == 0);          // nothing cut by air or left loose: the rim holds every cut end
    CHECK(into_rim > 20);
  }
  {  // No rim asked (S8): the same points are lattice.
    Domain d(pm, domain(-3.0, 0.0));
    CHECK((d.probe().where({3.5, 15, 10}) == Where{Why::Lattice, 1}));
  }
  {  // S2: the region reaching the block's own sides. Its edge faces air: no bar there.
    Domain d(pm, domain(0.0, 0.9));
    auto pr = d.probe();
    CHECK((pr.where({0.5, 15, 10}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({15, 29.6, 10}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({0.4, 0.4, 10}) == Where{Why::Lattice, 1}));
  }
  {  // S2: two regions side by side. No bar along the seam between them; a bar round the rest.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {9, 15, 12}, down, 6, 6, 6),
                 face_region(2, Role::Lattice, {21, 15, 12}, down, 6, 6, 6)};
    s.rim_mm = 0.9;
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({14.6, 15, 10}) == Where{Why::Lattice, 1}));   // at the seam, x = 15
    CHECK((pr.where({15.4, 15, 10}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({3.4, 15, 10}) == Where{Why::Rim, 1}));
    CHECK((pr.where({26.6, 15, 10}) == Where{Why::Rim, 2}));
    CHECK((pr.where({9, 9.4, 10}) == Where{Why::Rim, 1}));
    CHECK((pr.where({21, 20.6, 10}) == Where{Why::Rim, 2}));
  }
}

// Speed: over squares of a face that lie wholly inside or wholly outside a region's edge
// the Domain answers without measuring to the outline. The answer is the measured one.
static void test_region_squares() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  PartMeasure pm(weld_mesh(model.mesh));
  for (double expand : {0.0, -1.5, 1.5}) {
    DomainSpec s;
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 4.0, expand)};
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0, in = 0, out = 0;
    for (double x = 0.07; x < 60; x += 0.37)
      for (double y = 0.05; y < 60; y += 0.41)
        for (double z : {9.5, 7.0, 5.9}) {   // in its depth, in its depth, below it
          const Vec3 p{x, y, z};
          const bool measured = region_contains(s.regions[0], p);
          if (pr.where(p).lattice() != measured) ++wrong;
          ++(measured ? in : out);
        }
    CHECK(wrong == 0);
    CHECK(in > 5000 && out > 5000);
  }
}

// S9: Finish Covered. A solid shell over the lattice; the cells start behind it.
static void test_cover() {
  const Vec3 down{0, 0, -1};
  PartMeasure pm(weld_mesh(box(30, 30, 12)));
  for (double cover : {1.0, -1.0}) {   // asked for, and the default: two 0.45 mm lines
    const double t = cover > 0 ? cover : 0.9;
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 12)};   // all of it
    s.cover_mm = cover;
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({15, 15, 6}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({15, 15, 12 - 0.5 * t}) == Where{Why::Cover, 1}));    // under the top
    CHECK((pr.where({15, 15, 0.5 * t}) == Where{Why::Cover, 1}));         // over the bottom
    CHECK((pr.where({0.5 * t, 15, 6}) == Where{Why::Cover, 1}));          // inside a side
    CHECK((pr.where({15, 15, 12 - 1.1 * t}) == Where{Why::Lattice, 1}));  // just behind it
    CHECK((pr.where({15, 15, 12.5}) == Where{Why::Outside, 0}));
    CellSpec cs;
    cs.cell_max_mm = 6;
    Layout l = lay_cells(d, cs);
    CHECK(!l.cells.empty() && l.solid.empty());
    // The cells divide what is left between the two shells exactly (C15), in two layers.
    double first = 1e9, last = -1e9;
    int other = 0;
    for (const Cell& c : l.cells) {
      first = std::min(first, c.lo[2]);
      last = std::max(last, c.lo[2] + c.size);
      if (std::fabs(c.size - (12 - 2 * t) / 2) > 1e-5) ++other;
    }
    NEAR(first, t, 1e-5);
    NEAR(last, 12 - t, 1e-5);
    CHECK(other == 0);
    set_struts(l, StrutSpec{});
    Bars bars = lay_bars(l, d);
    int in_air = 0, into_cover = 0;
    for (const Bar& b : bars.bars)
      for (int e = 0; e < 2; ++e) {
        const Bar::End kind = e ? b.end_b : b.end_a;
        if (kind == Bar::End::Surface) ++in_air;
        if (kind == Bar::End::Solid && pr.where(e ? b.b : b.a).why == Why::Cover) ++into_cover;
      }
    CHECK(in_air == 0);          // no strut reaches the outside
    CHECK(into_cover > 50);      // the cut ones run on into the shell (S11)
    drop_loose_bars(bars);
    CHECK(bars.dropped == 0 && stepped_edges(bars).empty());
    CHECK(count_pieces(bars, d).adrift == 0);
  }
  {  // No cover asked: the same points are lattice.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {15, 15, 12}, down, 15, 15, 12)};
    Domain d(pm, s);
    CHECK((d.probe().where({15, 15, 11.5}) == Where{Why::Lattice, 1}));
  }
}

// S13: a Lattice region's own Finish (rim, cover, skin). What it does not state it takes from the part's. A 20 x 20 x
// 12 block as a model (faces 0 bottom, 1 top, 2 front y = 0, 3 x = 20, 4 back, 5 x = 0); region A under its top,
// region B under its bottom, each 6 mm deep, so they meet at z = 6.
static StepModel finish_block() {
  StepModel m;
  const double x = 20, y = 20, z = 12;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (int t = 0; t < 2; ++t) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][t ? 2 : 1]], p[q[f][t ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  return m;
}
static Settings finish_settings(double expand) {
  Settings s;
  s.min_strut_lines = kFewestStrutLines;
  s.regions = {{1, Role::Lattice, {1}, 6.0, expand}, {2, Role::Lattice, {0}, 6.0, expand}};   // A top, B bottom
  s.cells.cell_max_mm = 6;
  return s;
}
static void test_area_finish() {
  const StepModel model = finish_block();
  auto same = [](const Outcome& x, const Outcome& y) {
    return x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid && same_bars(x.bars, y.bars);
  };
  auto skin_bars = [](const Outcome& o) {
    std::size_t n = 0;
    for (const Bar& b : o.bars.bars) n += b.skin;
    return n;
  };
  // 1. Nothing stated: each part Finish in turn (None, Rim, Skin, Covered) gives the layout and bars it gives with every
  // region stating the part's own value; and the four are four different layouts.
  {
    std::vector<Outcome> laid;
    for (int finish = 0; finish < 4; ++finish) {
      Settings plain = finish_settings(finish == 1 ? -3.0 : 0.0);
      if (finish == 1) plain.rim_mm = -1.0;
      if (finish == 2) { plain.skin = true; plain.skin_spec.width_mm = 0.5; }
      if (finish == 3) plain.cover_mm = -1.0;
      Settings stated = plain;
      for (Settings::RegionAsk& r : stated.regions) {
        r.rim_mm = plain.rim_mm;
        r.cover_mm = plain.cover_mm;
        r.skin = plain.skin;
        r.skin_width_mm = plain.skin_spec.width_mm;
        r.skin_reach_cells = plain.skin_spec.reach_cells;
      }
      const Outcome a = Session(model).lay(plain), b = Session(model).lay(stated);
      CHECK(!a.layout.cells.empty() && !a.bars.bars.empty());
      CHECK(same(a, b));
      laid.push_back(a);
    }
    CHECK(skin_bars(laid[0]) == 0 && skin_bars(laid[2]) > 20);
    CHECK(!(laid[0].layout.cells == laid[3].layout.cells));   // the cover moved the cells
    Session s(model);
    const Outcome rimmed = s.lay([&] { Settings r = finish_settings(-3.0); r.rim_mm = -1.0; return r; }());
    CHECK((s.domain()->probe().where({3.5, 10, 9}) == Where{Why::Rim, 1}));
    CHECK((s.domain()->probe().where({3.5, 10, 3}) == Where{Why::Rim, 2}));
  }
  // 2. Part Rim (two lines, 0.9 mm), A states rim 0: rim along B's backed edges, lattice along A's.
  {
    Settings st = finish_settings(-3.0);   // pulled 3 mm in: solid backs every edge
    st.rim_mm = -1.0;
    st.regions[0].rim_mm = 0.0;
    Session s(model);
    s.lay(st);
    const Domain::Probe pr = s.domain()->probe();
    int a_rim = 0, b_lattice = 0, asked = 0;
    for (double t = 4; t <= 16; t += 0.5)
      for (const Vec3& p : {Vec3{3.5, t, 9}, Vec3{16.5, t, 9}, Vec3{t, 3.5, 9}, Vec3{t, 16.5, 10.5}}) {
        ++asked;
        a_rim += !(pr.where(p) == Where{Why::Lattice, 1});
        b_lattice += !(pr.where(Vec3{p.x, p.y, 12 - p.z}) == Where{Why::Rim, 2});
      }
    CHECK(asked > 90 && a_rim == 0 && b_lattice == 0);
    CHECK((pr.where({10, 10, 9}) == Where{Why::Lattice, 1}) && (pr.where({10, 10, 3}) == Where{Why::Lattice, 2}));
  }
  // 3. Part no rim, A states rim 1.5: rim within 1.5 mm of A's backed edges only, a hair inside 1.5 rim, a hair outside
  // lattice; B has none.
  {
    Settings st = finish_settings(-3.0);
    st.regions[0].rim_mm = 1.5;
    Session s(model);
    s.lay(st);
    const Domain::Probe pr = s.domain()->probe();
    int wrong = 0;
    for (double t = 5; t <= 15; t += 0.25) {
      for (double z : {6.5, 9.0, 11.5}) {
        wrong += !(pr.where({3 + 1.5 - 0.01, t, z}) == Where{Why::Rim, 1});
        wrong += !(pr.where({3 + 1.5 + 0.01, t, z}) == Where{Why::Lattice, 1});
        wrong += !(pr.where({t, 17 - 1.5 + 0.01, z}) == Where{Why::Rim, 1});
        wrong += !(pr.where({t, 17 - 1.5 - 0.01, z}) == Where{Why::Lattice, 1});
        wrong += !(pr.where({3.2, t, 12 - z}) == Where{Why::Lattice, 2});   // B: no rim of its own, none of the part's
      }
    }
    CHECK(wrong == 0);
  }
  // A's and B's cells: the shallowest any of them starts below its own face.
  auto first_below_face = [](const Outcome& o, int region) {
    double first = 1e9;
    for (const Cell& c : o.layout.cells)
      if (c.region == region) first = std::min(first, c.lo[2]);
    return first;
  };
  // 4. Part no cover, A states cover 0.9: A's lattice within 0.9 mm of the part's surface is solid and its cells start
  // behind it; B's lattice runs to the surface as today.
  {
    Settings st = finish_settings(-3.0);
    st.regions[0].cover_mm = 0.9;
    Session s(model);
    const Outcome o = s.lay(st);
    const Domain::Probe pr = s.domain()->probe();
    CHECK((pr.where({10, 10, 12 - 0.45}) == Where{Why::Cover, 1}));
    CHECK((pr.where({10, 10, 12 - 0.89}) == Where{Why::Cover, 1}));
    CHECK((pr.where({10, 10, 12 - 0.91}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({10, 10, 0.2}) == Where{Why::Lattice, 2}));
    NEAR(first_below_face(o, 1), 0.9, 1e-5);
    NEAR(first_below_face(o, 2), 0.0, 1e-9);
    // Its cells divide what is left of its 6 mm exactly (C15): one layer of 5.1 mm.
    int a = 0, other = 0;
    for (const Cell& c : o.layout.cells)
      if (c.region == 1) { ++a; other += std::fabs(c.size - 5.1) > 1e-5; }
    CHECK(a > 0 && other == 0);
  }
  // 5. Part cover on (0.9), A states cover 0: A is not covered, B is.
  {
    Settings st = finish_settings(-3.0);
    st.cover_mm = 0.9;
    st.regions[0].cover_mm = 0.0;
    Session s(model);
    const Outcome o = s.lay(st);
    const Domain::Probe pr = s.domain()->probe();
    CHECK((pr.where({10, 10, 12 - 0.2}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({10, 10, 0.45}) == Where{Why::Cover, 2}));
    CHECK((pr.where({10, 10, 0.91}) == Where{Why::Lattice, 2}));
    NEAR(first_below_face(o, 1), 0.0, 1e-9);
    NEAR(first_below_face(o, 2), 0.9, 1e-5);
  }
  // The regions of the bars whose cut ends lie at a point (1 = A, 2 = B, 3 = both), from the bars as laid.
  auto ends_of = [](const Outcome& o) {
    std::map<std::array<double, 3>, int> at;
    for (const Bar& b : o.bars.bars) {
      if (b.skin) continue;
      for (int e = 0; e < 2; ++e) {
        const Bar::End k = e ? b.end_b : b.end_a;
        if (k != Bar::End::Surface && k != Bar::End::Joined) continue;
        const Vec3& p = e ? b.b : b.a;
        at[{p.x, p.y, p.z}] |= b.region == 1 ? 1 : 2;
      }
    }
    return at;
  };
  auto mask_at = [](const std::map<std::array<double, 3>, int>& m, const Vec3& p) {
    const auto it = m.find({p.x, p.y, p.z});
    return it == m.end() ? 0 : it->second;
  };
  // 6. Part Skin off, A states Skin on: skin bars exist; every one joins ends of A's bars, and no end of B's is joined.
  {
    Settings st = finish_settings(0.0);   // the whole faces: the block's sides cut both regions' cells
    st.drop_loose = false;
    st.regions[0].skin = true;
    const Outcome o = Session(model).lay(st);
    const auto ends = ends_of(o);
    int not_a = 0, b_joined = 0, b_cut = 0;
    for (const Bar& b : o.bars.bars)
      if (b.skin) {
        not_a += !(mask_at(ends, b.a) & 1) || !(mask_at(ends, b.b) & 1);
      } else if (b.region == 2) {
        for (int e = 0; e < 2; ++e) {
          const Bar::End k = e ? b.end_b : b.end_a;
          const int into = e ? b.into_b : b.into_a;
          b_cut += k == Bar::End::Surface;
          b_joined += k == Bar::End::Joined && into >= 0 && o.bars.bars[static_cast<std::size_t>(into)].skin;
        }
      }
    CHECK(skin_bars(o) > 20);
    CHECK(not_a == 0 && b_joined == 0 && b_cut > 20);
  }
  // 7. Both on, with different widths and reach (A 0.8 mm and 1.5 cells, B 0.6 mm and 0.6 cells): a bar between A's
  // ends has A's width; a bar joining A to B has the smaller width and is no longer than the smaller reach allows.
  {
    Settings st = finish_settings(0.0);
    st.drop_loose = false;
    st.regions[0].skin = true; st.regions[0].skin_width_mm = 0.8; st.regions[0].skin_reach_cells = 1.5;
    st.regions[1].skin = true; st.regions[1].skin_width_mm = 0.6; st.regions[1].skin_reach_cells = 0.6;
    const Outcome o = Session(model).lay(st);
    const auto ends = ends_of(o);
    int in_a = 0, in_b = 0, a_to_b = 0, wrong_width = 0, too_long = 0, past_b_reach = 0;
    for (const Bar& b : o.bars.bars) {
      if (!b.skin) continue;
      const int m = mask_at(ends, b.a), n = mask_at(ends, b.b);
      const double len = bar_length(b);
      if (m == 1 && n == 1) {
        ++in_a;
        wrong_width += std::fabs(b.width - 0.8) > 1e-12;
        too_long += len > 1.5 * b.cell + 1e-9;
        past_b_reach += len > 0.6 * b.cell + 1e-9;
      } else if (m == 2 && n == 2) {
        ++in_b;
        wrong_width += std::fabs(b.width - 0.6) > 1e-12;
        too_long += len > 0.6 * b.cell + 1e-9;
      } else if ((m == 1 && n == 2) || (m == 2 && n == 1)) {
        ++a_to_b;
        wrong_width += std::fabs(b.width - 0.6) > 1e-12;
        too_long += len > 0.6 * b.cell + 1e-9;
      }
    }
    std::printf("area finish: skin bars %d in A, %d in B, %d A to B (%d of A's longer than B's reach)\n", in_a, in_b,
                a_to_b, past_b_reach);
    CHECK(in_a > 10 && in_b > 10 && a_to_b > 0 && past_b_reach > 0);
    CHECK(wrong_width == 0 && too_long == 0);
  }
  // 8. A's own rim or cover change reads the part again; its skin change does not.
  {
    Session s(model);
    Settings st = finish_settings(-3.0);
    CHECK(s.lay(st).read_again);
    st.regions[0].rim_mm = 1.5;
    CHECK(s.lay(st).read_again);
    CHECK(!s.lay(st).read_again);
    st.regions[0].cover_mm = 0.9;
    CHECK(s.lay(st).read_again);
    st.regions[0].cover_mm = 1.2;
    CHECK(s.lay(st).read_again);
    st.regions[0].skin = true;
    const Outcome skinned = s.lay(st);
    CHECK(!skinned.read_again && same(skinned, Session(model).lay(st)));
    st.regions[0].skin_width_mm = 0.7;
    st.regions[0].skin_reach_cells = 1.0;
    CHECK(!s.lay(st).read_again);
    st.regions[0].rim_mm.reset();   // back to the part's
    CHECK(s.lay(st).read_again);
  }
}

// P2, stage E: the session the app holds for a part. A cell or strut setting re-lays
// without reading the part again; a "where" setting reads it again; either way the
// layout is the one a fresh session gives.
static void test_session() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  Session session(model);
  CHECK(session.open_edges() == 0);
  Settings st;
  st.min_strut_lines = kFewestStrutLines;   // these rules are tested at the fewest lines the engine lays
  st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}};
  st.cells.cell_max_mm = 6;
  auto same = [](const Outcome& x, const Outcome& y) {
    return x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid && same_bars(x.bars, y.bars);
  };
  auto fresh = [&](const Settings& s) { return Session(model).lay(s); };
  const Outcome first = session.lay(st);
  CHECK(first.read_again);
  CHECK(!first.layout.cells.empty() && !first.bars.bars.empty() && first.empty_regions.empty());
  CHECK(first.layout.cells.front().strut > 0.0);   // strut widths are set
  // What the app and the worker lay with unless told otherwise: TWO lines (R14; his stand failed at one, 2026-11-12).
  {
    Settings his;
    CHECK(his.min_strut_lines == 2.0 && kMinStrutLines == 2.0);
    his.regions = st.regions;
    his.cells.cell_max_mm = 6;
    const Outcome two_lines = Session(model).lay(his);
    NEAR(two_lines.layout.min_strut_mm, 0.9, 1e-12);
    double thinnest = 1e9;
    for (const Cell& c : two_lines.layout.cells) thinnest = std::min(thinnest, c.strut);
    CHECK(!two_lines.layout.cells.empty() && thinnest >= 0.9 - 1e-12);
    for (const Bar& b : two_lines.bars.bars) thinnest = std::min(thinnest, b.width);
    CHECK(thinnest >= 0.9 - 1e-12);
    CHECK(first.layout.min_strut_mm < 0.5);   // this test's own layouts are at one line, by its own asking
  }
  st.cells.cell_max_mm = 4;                         // a cell setting
  const Outcome smaller = session.lay(st);
  CHECK(!smaller.read_again);
  CHECK(same(smaller, fresh(st)));
  CHECK(smaller.layout.cells.size() > first.layout.cells.size());
  st.struts.dial = 0.9;                             // a strut setting
  const Outcome thicker = session.lay(st);
  CHECK(!thicker.read_again);
  CHECK(same(thicker, fresh(st)));
  CHECK(thicker.layout.cells.front().strut > smaller.layout.cells.front().strut);
  st.regions[0].depth_mm = 8.0;                     // a "where" setting
  const Outcome deeper = session.lay(st);
  CHECK(deeper.read_again);
  CHECK(same(deeper, fresh(st)));
  CHECK(!(deeper.layout.cells == thicker.layout.cells));
  CHECK(!session.lay(st).read_again);               // and asked again: kept
  st.rim_mm = -1.0;                                 // Finish Rim is a "where" setting too
  const Outcome rimmed = session.lay(st);
  CHECK(rimmed.read_again && same(rimmed, fresh(st)));
  // A region whose faces do not exist is named, and the rest is laid.
  st.regions.push_back({7, Role::Lattice, {9999}, 5.0, 0.0});
  const Outcome named = session.lay(st);
  CHECK(named.empty_regions == std::vector<int>{7});
  CHECK(named.layout.cells == rimmed.layout.cells);
  st.bars = false;                                  // cells only
  CHECK(session.lay(st).bars.bars.empty());
  // Two regions side by side with different cells: the session joins what is loose along
  // the seam (S5) and drops what still lands on nothing (S4), unless told not to.
  Settings two;
  two.min_strut_lines = kFewestStrutLines;   // these rules are tested at the fewest lines the engine lays
  two.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}, {2, Role::Lattice, {L}, 10.0, 0.0}};
  two.cells.cell_max_mm = 6;
  two.join_loose = false;
  two.drop_loose = false;
  const Outcome as_laid = session.lay(two);
  int loose = 0;
  for (const Bar& b : as_laid.bars.bars)
    loose += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
  CHECK(loose > 0 && as_laid.bars.joined == 0 && as_laid.bars.dropped == 0);
  two.join_loose = true;
  const Outcome joined = session.lay(two);
  CHECK(joined.bars.joined > 0 && joined.bars.dropped == 0);
  CHECK(joined.bars.bars.size() == as_laid.bars.bars.size());
  two.drop_loose = true;
  const Outcome kept = session.lay(two);
  CHECK(kept.bars.dropped > 0 && kept.bars.bars.size() < joined.bars.bars.size());
  CHECK(!kept.read_again);
  // Allow quilt is ONE switch (R2): the session hands the struts' to the cells. The
  // 10 mm plate, band 6, the region pulled 1.5 mm in so its outline cuts cells (only the
  // finest may be cut, G10). Laid as the test print is, with two-line struts: off, no
  // cell under 4.742 mm, so 5 mm; on, 3.333 mm cells.
  Settings band;
  band.min_strut_lines = 2.0;
  band.regions = {{1, Role::Lattice, {square}, 10.0, -1.5}};
  band.cells.algorithm = Algorithm::Stepped;
  band.cells.cell_max_mm = 10;
  band.cells.grade_to_shape = true;
  band.cells.band_mm = 6;
  band.cells.allow_quilt = true;          // not read: the switch is the struts'
  band.bars = false;
  auto least = [](const Outcome& o) {
    double m = 1e9;
    for (const Cell& c : o.layout.cells) m = std::min(m, c.size);
    return m;
  };
  NEAR(least(session.lay(band)), 5.0, 1e-6);
  band.struts.allow_quilt = true;
  const Outcome quilted = session.lay(band);
  NEAR(least(quilted), 10.0 / 3.0, 1e-6);
  CHECK(!quilted.read_again);             // the switch re-lays; it does not read the part again
  // His per-part choice (2026-11-12), Allow quilt OFF: the cells are the ones Allow quilt lays (3.333 mm, so the
  // band is latticed), but no strut is thicker for it. A cell too small for the open look carries the thinnest
  // strut exactly (two lines, 0.9 mm: past the open look, under touching); every other cell keeps the open look.
  band.struts.allow_quilt = false;
  band.small_cells_in_thin_walls = true;
  const Outcome small = session.lay(band);
  CHECK(!small.read_again);
  CHECK(small.layout.cells.size() == quilted.layout.cells.size());
  bool same_cubes = true, never_thicker = true, small_at_thinnest = true, none_touch = true;
  int past_open_look = 0;
  for (std::size_t i = 0; i < small.layout.cells.size(); ++i) {
    const Cell &a = small.layout.cells[i], &b = quilted.layout.cells[i];
    same_cubes = same_cubes && a.size == b.size && a.lo[0] == b.lo[0] && a.lo[1] == b.lo[1] && a.lo[2] == b.lo[2];
    never_thicker = never_thicker && a.strut <= b.strut + 1e-12;
    const double open_look = small.layout.open_look * a.size;
    if (open_look < 0.9) { small_at_thinnest = small_at_thinnest && std::fabs(a.strut - 0.9) < 1e-12; ++past_open_look; }
    else never_thicker = never_thicker && a.strut <= open_look + 1e-12;
    none_touch = none_touch && a.strut < small.layout.touch * a.size;
  }
  CHECK(same_cubes && never_thicker && small_at_thinnest && none_touch && past_open_look > 0);
  band.small_cells_in_thin_walls = false;   // and off again: 5 mm cells, as before
  NEAR(least(session.lay(band)), 5.0, 1e-6);
}

// "Let walls cut cells" through the session (Settings::one_grid, his ruling 2026-11-14): a per-part switch, off unless
// the user turns it on. Off is the layout as it was; on is CellSpec::one_grid's layout; on then off again gives back the
// off layout exactly. It is a cell setting: changing it lays the cells again and never reads the part again. The
// CellSpec's own one_grid is not read through the session: the switch is the Settings'.
static void test_session_one_grid() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  CHECK(!Settings{}.one_grid);
  Session session(model);
  Settings st;
  st.min_strut_lines = 2.0;
  st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}};
  st.cells.cell_max_mm = 6;
  st.cells.min_cells_across = 5;   // the wall must hold 5 across (C3-C5): off, a 6 mm wall cannot; one grid ignores it
  auto same = [](const Outcome& x, const Outcome& y) {
    return x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid && same_bars(x.bars, y.bars);
  };
  auto fresh = [&](const Settings& s) { return Session(model).lay(s); };
  const Outcome off = session.lay(st);
  CHECK(off.read_again);
  CHECK(same(off, fresh(st)));
  st.cells.one_grid = true;          // not read: the switch is the Settings'
  const Outcome ignored = session.lay(st);
  CHECK(!ignored.read_again && same(ignored, off));
  st.cells.one_grid = false;
  st.one_grid = true;
  const Outcome on = session.lay(st);
  CHECK(!on.read_again);             // a cell setting: laid again, the part not read again
  CHECK(on.ms_read == 0.0 && on.ms_cells > 0.0);
  CHECK(!(on.layout.cells == off.layout.cells));
  CHECK(same(on, fresh(st)));
  st.one_grid = false;
  const Outcome again = session.lay(st);
  CHECK(!again.read_again && same(again, off));
  std::printf("session one grid: off %zu cells, %zu solid; on %zu cells, %zu solid\n", off.layout.cells.size(),
              off.layout.solid.size(), on.layout.cells.size(), on.layout.solid.size());
}

// Stage E, cancel (362's bridge: his slider must not wait on a layout nobody wants). A stop flag given to lay() gives
// the layout up: the answer is `cancelled` and empty, each threaded step throws instead of handing back a part-made
// result, and NOTHING the domain or the session keeps is harmed: the same settings asked again give the layout a fresh
// session gives, whenever the stop came.
static void test_session_cancel() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  Settings st;
  st.min_strut_lines = kFewestStrutLines;   // these rules are tested at the fewest lines the engine lays
  st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}, {2, Role::Lattice, {L}, 10.0, 0.0}};
  st.cells.cell_max_mm = 3;
  auto same = [](const Outcome& x, const Outcome& y) {
    return x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid && same_bars(x.bars, y.bars);
  };
  auto empty = [](const Outcome& x) {
    return x.cancelled && x.layout.cells.empty() && x.layout.solid.empty() && x.bars.bars.empty();
  };
  const Outcome want = Session(model).lay(st);
  CHECK(!want.cancelled && !want.layout.cells.empty() && !want.bars.bars.empty());

  // Set before the call: nothing is read, nothing is laid; the session then lays as if it had never been asked.
  {
    Session session(model);
    std::atomic<bool> stop{true};
    CHECK(empty(session.lay(st, 0, &stop)));
    CHECK(session.domain() == nullptr);
    stop = false;
    const Outcome after = session.lay(st, 0, &stop);
    CHECK(!after.cancelled && after.read_again && same(after, want));
  }
  // Each step on its own, the flag already set: it throws, and keeps nothing part-made (the cells laid in the same
  // domain afterwards are the ones a new domain gives; a reading kept with rows missing would move them).
  {
    size_t open = 0;
    PartMeasure pm(weld_mesh(model.mesh, 1e-5, &open));
    auto spec = [&] {
      DomainSpec s;
      bool ok = false;
      s.regions.push_back(region_from_face(model, square, 1, Role::Lattice, 6.0, 0.0, &ok));
      s.regions.push_back(region_from_face(model, L, 2, Role::Lattice, 10.0, 0.0, &ok));
      return s;
    };
    Domain d(pm, spec());
    const Domain clean(pm, spec());
    std::atomic<bool> stop{true};
    d.watch(&stop);
    for (int threads : {1, 4}) {
      bool threw = false;
      try { (void)lay_cells(d, st.cells, threads); } catch (const LayCancelled&) { threw = true; }
      CHECK(threw);
    }
    d.watch(nullptr);
    Layout laid = lay_cells(d, st.cells);
    const Layout fresh = lay_cells(clean, st.cells);
    CHECK(laid.cells == fresh.cells && laid.solid == fresh.solid && !laid.cells.empty());
    set_struts(laid, st.struts);
    Bars bars = lay_bars(laid, d);
    d.watch(&stop);
    bool threw = false;
    try { (void)lay_bars(laid, d); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
    threw = false;
    const Bars before = bars;
    try { (void)join_loose_bars(bars, d, 0, &laid); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw && same_bars(bars, before));   // no bar was changed
    d.watch(nullptr);
    CHECK(!d.stop_asked());
    // The whole part as lattice: no face is read, so only the cell step itself can notice (one thread, and several).
    DomainSpec everywhere;
    everywhere.start = Start::AllLattice;
    Domain all(pm, everywhere);
    CHECK(!lay_cells(all, st.cells).cells.empty());
    all.watch(&stop);
    for (int threads : {1, 4}) {
      bool gave_up = false;
      try { (void)lay_cells(all, st.cells, threads); } catch (const LayCancelled&) { gave_up = true; }
      CHECK(gave_up);
    }
  }
  // Set from another thread at every moment of a layout, the first of a new session (the part is being read) and
  // the second (it is not): the answer is the whole layout or `cancelled` and empty, never part of one; and the
  // same session asked again, with no stop, gives the layout a fresh session gives.
  {
    const auto t0 = std::chrono::steady_clock::now();
    (void)Session(model).lay(st);
    const double whole_us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count();
    int given_up = 0, whole = 0, bad = 0;
    const int steps = 120;
    for (int k = 0; k < steps; ++k) {
      for (int second = 0; second < 2; ++second) {
        Session session(model);
        if (second) (void)session.lay(st);
        std::atomic<bool> stop{false};
        const auto wait = std::chrono::duration<double, std::micro>(whole_us * 1.1 * k / steps);
        std::thread setter([&] { std::this_thread::sleep_for(wait); stop = true; });
        const Outcome got = session.lay(st, 0, &stop);
        setter.join();
        if (got.cancelled) { ++given_up; bad += !empty(got); } else { ++whole; bad += !same(got, want); }
        const Outcome again = session.lay(st);
        bad += again.cancelled || !same(again, want);
      }
    }
    CHECK(bad == 0);
    CHECK(given_up > 0);
    std::printf("cancel: %d layouts given up part way, %d finished first, of %d (one whole layout %.1f ms)\n", given_up,
                whole, 2 * steps, whole_us / 1000.0);
  }
}

// C11a (reviewer's ruling 2026-11-11 23:52Z): the cells a member must hold are counted
// across the room BETWEEN the skins, where the cells live, not across the material.
static void test_cells_across_the_room_between_skins() {
  // The rib of C11a, 6 mm wide across the face and 6 deep, two across, on a 0.2 mm line at
  // one line (so small cells print and the count is what decides).
  auto side = [](double y) {
    TriangleMesh m;
    m.vertices = {{0, y, 0}, {40, y, 0}, {40, y, 6}, {0, y, 6}};
    m.triangles = {{0, 1, 2}, {0, 2, 3}};
    return m;
  };
  PartMeasure pm(weld_mesh(box(40, 6, 6)));
  auto largest = [&](double skins, double cover) {
    DomainSpec s;
    s.bead_mm = 0.2;
    s.min_strut_lines = 1.0;
    s.cover_mm = cover;
    s.regions = {face_region(1, Role::Lattice, {20, 3, 6}, {0, 0, -1}, 20, 3, 6)};
    if (skins > 0.0) s.protect = {{1, side(0), skins}, {2, side(6), skins}};
    Domain d(pm, s);
    CellSpec cs;
    cs.min_cells_across = 2;
    const Layout l = lay_cells(d, cs);
    double big = 0.0;
    for (const Cell& c : l.cells) big = std::max(big, c.size);
    return big;
  };
  NEAR(largest(0.0, 0.0), 3.0, 1e-5);        // no skins: two 3 mm cells across the 6 mm
  // A 1 mm Protect skin on each side of the rib leaves 4 mm between them: two across is
  // 2 mm cells, not 3 mm cells cut by the skins.
  CHECK(largest(1.0, 0.0) <= 2.0 + 1e-5 && largest(1.0, 0.0) > 1.0);
  // A 1 mm cover all round: 4 mm across and 4 mm deep. The same.
  CHECK(largest(0.0, 1.0) <= 2.0 + 1e-5 && largest(0.0, 1.0) > 1.0);
  // The room itself, read at the rib's middle: the material, less the two skins.
  DomainSpec s;
  s.protect = {{1, side(0), 1.0}, {2, side(6), 1.0}};
  s.regions = {face_region(1, Role::Lattice, {20, 3, 6}, {0, 0, -1}, 20, 3, 6)};
  Domain d(pm, s);
  NEAR(d.probe().room_through({20, 3, 3}), 4.0, 1e-5);
  NEAR(d.probe().room_through({20, 2.2, 3}), 4.0, 1e-5);
  NEAR(d.probe().part().thickness({20, 3, 3}), 6.0, 1e-5);
  DomainSpec bare;
  Domain d0(pm, bare);
  NEAR(d0.probe().room_through({20, 3, 3}), 6.0, 1e-5);   // no skin: the thickness itself
}

// K5 (his yes, 2026-11-23: "Structural must refuse lattice strips only one cell wide"). On his stand Structural laid a
// column of cells about 4 mm wide between an anchor hole's Protect skin and the start of the end's rounded corner: the
// member rule counted the cells across the MATERIAL (the toe's height), not across the lattice's own room. A block
// 60 x 30 x 20 latticed under its top face, 20 deep, cells up to 4 mm, 0.2 mm lines at one line (small cells print);
// a No lattice region over all of the face but a strip 4 mm wide at x 0..4. The strip's material is the whole block
// (20 deep, 30 wide), so it held five 4 mm cells across the material; read across the lattice space it is 4 mm.
static void test_structural_strips_refused() {
  PartMeasure pm(weld_mesh(box(60, 30, 20)));
  auto lay = [&](bool strip, int across, bool whole_part) {
    DomainSpec s;
    s.bead_mm = 0.2;
    s.min_strut_lines = 1.0;
    // A region under the top face, its half sizes given along x and y whichever way its own frame's axes lie.
    auto top = [](int id, Role role, double cx, double hx, double hy) {
      const Region r = face_region(id, role, {cx, 15, 20}, {0, 0, -1}, hx, hy, 20);
      return std::fabs(r.prism.u.x) > 0.5 ? r : face_region(id, role, {cx, 15, 20}, {0, 0, -1}, hy, hx, 20);
    };
    if (whole_part) s.start = Start::AllLattice;
    else s.regions = {top(1, Role::Lattice, 30, 30, 15)};
    if (strip) s.regions.push_back(top(2, Role::NoLattice, 32, 28, 15));
    Domain d(pm, s);
    CellSpec cs;
    cs.min_cells_across = across;
    cs.cell_max_mm = 4.0;
    return lay_cells(d, cs);
  };
  // Cells with any of their cube in the strip, and their largest size.
  auto in_strip = [](const Layout& l, double* largest) {
    int n = 0;
    *largest = 0.0;
    for (const Cell& c : l.cells) {
      Vec3 lo, hi;
      const Frame& f = l.frames[static_cast<std::size_t>(c.frame)];
      const Vec3 a = f.at(c.lo[0], c.lo[1], c.lo[2]), b = f.at(c.lo[0] + c.size, c.lo[1] + c.size, c.lo[2] + c.size);
      lo = {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)};
      hi = {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
      if (lo.x < 4.0 - 1e-6 && hi.x > 0.0) { ++n; *largest = std::max(*largest, c.size); }
    }
    return n;
  };
  auto too_few = [](const Layout& l) {
    std::size_t n = 0;
    for (const SolidWhy& w : l.solid_why) n += w.why == NoCell::TooFewAcross || w.why == NoCell::WallNarrow;
    return n;
  };
  double big = 0.0;
  // Structural (five across), a face region: the strip is solid, its reason a thin wall's (too few across / too narrow).
  const Layout st = lay(true, 5, false);
  const int st_n = in_strip(st, &big);
  std::printf("[K5] Structural strip: %d cells in the strip (largest %.3f mm), %zu solid as thin, %zu cells in all\n", st_n,
              big, too_few(st), st.cells.size());
  CHECK(st_n == 0 && too_few(st) > 0);
  // The whole part (no face map: the member is read across the material) is held by the minimum patch: the strip's
  // patch is one 4 mm cell across in x, under five.
  const Layout wp = lay(true, 5, true);
  const int wp_n = in_strip(wp, &big);
  std::printf("[K5] Structural strip, whole part: %d cells in the strip, %zu cells made solid by the minimum patch\n", wp_n,
              wp.small_patch_cells);
  CHECK(wp_n == 0 && wp.small_patch_cells > 0);
  // A wide wall still lattices: the block without the No lattice region, Structural, a face region and the whole part.
  for (bool whole : {false, true}) {
    const Layout wide = lay(false, 5, whole);
    const int n = in_strip(wide, &big);
    std::printf("[K5] Structural wide wall (%s): %zu cells, %d of them at x 0..4 (largest %.3f mm), %zu solid, %zu by the "
                "minimum patch\n", whole ? "whole part" : "face", wide.cells.size(), n, big, wide.solid.size(),
                wide.small_patch_cells);
    // its own cell at the edge and at its corners (nothing solid): 4 mm under the face (20 deep, five across), the
    // whole part's 2.107 mm (its base); as laid before the rule (the face: 600 cells of 4 mm, nothing solid)
    CHECK(wide.cells.size() > 100 && n > 0 && big >= (whole ? 2.1 : 4.0 - 1e-6) && wide.small_patch_cells == 0 &&
          wide.solid.empty());
    if (!whole) CHECK(wide.cells.size() == 600);
  }
  // Aesthetic (one or two across) is unchanged: the strip lattices, as before.
  for (int across : {1, 2}) {
    const Layout ae = lay(true, across, false);
    const int n = in_strip(ae, &big);
    std::printf("[K5] Aesthetic (%d across) strip: %d cells in the strip, %zu by the minimum patch\n", across, n, ae.small_patch_cells);
    CHECK(n > 0 && ae.small_patch_cells == 0);
  }
}

// D5, D15, C15: with a Protect skin on a face, the lattice starts at the skin's own depth
// and its cells divide what is left of the wall. The skin never cuts through a cell.
static void test_cells_behind_a_protect_skin() {
  const Vec3 down{0, 0, -1};
  auto quad = [](double x0, double x1, double z) {
    TriangleMesh m;
    m.vertices = {{x0, 0, z}, {x1, 0, z}, {x1, 40, z}, {x0, 40, z}};
    m.triangles = {{0, 1, 2}, {0, 2, 3}};
    return m;
  };
  PartMeasure pm(weld_mesh(box(40, 40, 20)));
  const Vec3 top{20, 20, 20};
  for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped})
    for (double skin : {1.2, 0.0}) {
      // A 12 mm slab under the top face, the face protected: the lattice has 12 less the
      // skin, in two layers (8 mm cells at most). At 0 mm the skin is two lines, 0.9 mm.
      DomainSpec s;
      s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 12)};
      s.protect = {{7, quad(0, 40, 20), skin}};
      Domain d(pm, s);
      const double from = skin > 0.0 ? skin : 0.9, cell = 0.5 * (12.0 - from);
      CellSpec cs;
      cs.algorithm = algo;
      cs.cell_max_mm = 8;
      const Layout l = lay_cells(d, cs);
      CHECK(!l.cells.empty());
      CHECK(l.solid.empty());
      int odd = 0;
      double first = 1e300, last = -1e300;
      for (const Cell& c : l.cells) {
        if (std::fabs(c.size - cell) > 1e-5) ++odd;
        // Every cell begins on the skin's inner side or one cell below it.
        if (std::fabs(c.lo[2] - from) > 1e-5 && std::fabs(c.lo[2] - from - cell) > 1e-5) ++odd;
        first = std::min(first, c.lo[2]);
        last = std::max(last, c.lo[2] + c.size);
      }
      CHECK(odd == 0);
      NEAR(first, from, 1e-5);     // D5: the lattice is right behind the skin
      NEAR(last, 12.0, 1e-5);      // D15: one slab, one depth
      CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 20}, 1.7) == 0);
      // The skin itself: solid to its depth, lattice just past it.
      auto pr = d.probe();
      CHECK((pr.where({20, 20, 20 - from + 0.005}) == Where{Why::ProtectSkin, 7}));
      CHECK((pr.where({20, 20, 20 - from - 0.005}) == Where{Why::Lattice, 1}));
    }
  {  // The same slab with no skin is laid from the face, as before.
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 12)};
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 8;
    const Layout l = lay_cells(d, cs);
    int odd = 0;
    for (const Cell& c : l.cells)
      if (std::fabs(c.size - 6.0) > 1e-9 || (std::fabs(c.lo[2]) > 1e-9 && std::fabs(c.lo[2] - 6.0) > 1e-9)) ++odd;
    CHECK(!l.cells.empty() && odd == 0);
  }
  {  // A skin on half the face: two walls, each divided on its own (C15 per wall).
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, top, down, 20, 20, 12)};
    s.protect = {{7, quad(0, 20, 20), 1.2}};
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 8;
    const Layout l = lay_cells(d, cs);
    int behind = 0, open = 0, odd = 0;
    for (const Cell& c : l.cells) {
      const Vec3 at = cell_centre(l, c);
      if (at.x < 14.0) {          // well under the skin
        ++behind;
        if (std::fabs(c.size - 5.4) > 1e-5 || c.lo[2] < 1.2 - 1e-5) ++odd;
      } else if (at.x > 26.0) {   // well clear of it
        ++open;
        if (std::fabs(c.size - 6.0) > 1e-5 || (std::fabs(c.lo[2]) > 1e-5 && std::fabs(c.lo[2] - 6.0) > 1e-5)) ++odd;
      }
    }
    CHECK(behind > 0 && open > 0);
    CHECK(odd == 0);
    // Where the two walls meet, each wall's cut cells reach over the line as whole cubes;
    // what each truly holds does not overlap, and nothing is left bare.
    CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 20}, 1.7) == 0);
    CHECK(badly_covered(d, l, {17, 0, 0}, {23, 40, 20}, 0.31) == 0);
    int cubes_overlap = 0;
    for (double z = 12.3; z < 18.0; z += 1.1)
      if (cells_holding(l, {19.07, 20.3, z}, 1) > 1) ++cubes_overlap;
    CHECK(cubes_overlap > 0);
  }
  {  // A 6 mm plate, lattice through it, both faces protected 1 mm: one 4 mm cell between.
    PartMeasure plate(weld_mesh(box(40, 40, 6)));
    TriangleMesh both = quad(0, 40, 6);
    const TriangleMesh under = quad(0, 40, 0);
    for (const Vec3& v : under.vertices) both.vertices.push_back(v);
    both.triangles.push_back({4, 5, 6});
    both.triangles.push_back({4, 6, 7});
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, Vec3{20, 20, 6}, down, 20, 20, 8)};
    s.protect = {{7, both, 1.0}};
    Domain d(plate, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 8;
    const Layout l = lay_cells(d, cs);
    CHECK(!l.cells.empty());
    CHECK(l.solid.empty());
    int odd = 0;
    for (const Cell& c : l.cells)
      if (std::fabs(c.size - 4.0) > 1e-5 || std::fabs(c.lo[2] - 1.0) > 1e-5) ++odd;
    CHECK(odd == 0);
    CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 6}, 1.7) == 0);
    // D8 reads the room between the skins, not the plate: 4 mm holds no 5 mm wall.
    s.min_wall_mm = 5.0;
    Domain thin(plate, s);
    CHECK((thin.probe().where({20, 20, 3}) == Where{Why::WallTooThin, 1}));
    s.min_wall_mm = 3.9;
    Domain wide(plate, s);
    CHECK((wide.probe().where({20, 20, 3}) == Where{Why::Lattice, 1}));
  }
}

// R2 (his rule of 2026-11-12, and "I'd prefer all areas but protected skin to be fully
// latticed"): a wall too thin for a cell that prints open is solid with Allow quilt off,
// and is latticed with it on, band or no band. Two parts, each with such a wall.
static void test_thin_walls_follow_the_quilt_switch() {
  {  // (a) Behind the y = 0 face: 12 mm of material for x < 30, 2 mm for x > 30. A 2 mm
     // cell is below the open look's floor (2.37 mm on a 0.45 mm line) and above the
     // quilt's cell (1.27 mm).
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2}, {30, 2}, {30, 12}, {0, 12}}, 0, 40)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 12)};   // covers the whole face
    Domain d(pm, s);
    auto pr = d.probe();
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped})
      for (double band : {0.0, 4.0})
        for (bool quilt : {false, true}) {
          CellSpec cs;
          cs.algorithm = algo;
          cs.grade_to_shape = band > 0.0;
          cs.band_mm = band;
          cs.allow_quilt = quilt;
          const Layout l = lay_cells(d, cs);
          int under_open = 0, under_quilt = 0, held = 0;
          for (const Cell& c : l.cells) {
            if (c.size < 0.45 / (0.7592 / 4.0) - 1e-9) ++under_open;
            if (c.size < 0.45 / kQuiltStrutPerCell - 1e-9) ++under_quilt;
            if (cell_holds(l, pr, c, {45, 1, 20})) ++held;   // the middle of the thin wall
          }
          NEAR(l.floor_cell_mm, quilt ? 0.45 / kQuiltStrutPerCell : 0.45 / (0.7592 / 4.0), 1e-9);
          CHECK(under_quilt == 0);                 // nothing under the quilt's cell, ever
          if (!quilt) {
            CHECK(under_open == 0 && held == 0);   // off: no such cell; the thin wall is solid
          } else {
            CHECK(under_open > 0 && held == 1);    // on: the thin wall takes its 2 mm cells
          }
          CHECK(cells_holding(l, {15, 6, 20}, 1) == 1);   // the 12 mm wall is latticed either way
        }
  }
  {  // (b) No band. A strip 2.6 mm thick and 3 mm wide beside a 12.8 mm wall. With the
     // switch off the 6.4 mm cell has no fraction that fits the strip and prints open
     // (a fifth, 1.28 mm, would give a 2.56 mm cell): the strip is solid. With it on, it
     // is latticed.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2.6}, {57, 2.6}, {57, 12.8}, {0, 12.8}}, 0, 8)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 4}, {0, 1, 0}, 30, 30, 12.8)};   // covers the whole face
    Domain d(pm, s);
    CellSpec off;
    off.algorithm = Algorithm::Stepped;
    CellSpec on = off;
    on.allow_quilt = true;
    const Layout a = lay_cells(d, off), b = lay_cells(d, on);
    CHECK(!a.cells.empty());
    auto pr = d.probe();
    int held_off = 0, held_on = 0;
    for (const Cell& c : a.cells)
      if (cell_holds(a, pr, c, {58.5, 1.3, 4})) ++held_off;
    for (const Cell& c : b.cells)
      if (cell_holds(b, pr, c, {58.5, 1.3, 4})) ++held_on;
    CHECK(held_off == 0 && held_on == 1);
    CHECK((pr.where({58.5, 1.3, 4}) == Where{Why::Lattice, 1}));   // it was asked for either way
  }
}

// K6 (his 11-24: "I don't understand why we can't just extend cells and cut them off where the bed is?"). A block
// latticed under its front face, one grid, Stepped: 12 mm cells cut to 6 mm at its edges, the grid centred on the face,
// so the bed cuts the bottom row thin (0.5, 1.3 and 2 mm for blocks 13, 14.6 and 16 tall). The struts the bed cuts are
// kept, cut flat on the bed (Bar::on_bed), however short, and the drop keeps them: they stand on the bed and hold the
// row above. A Surface end anywhere else (the block's sides) is dropped as before.
static void test_cells_cut_flat_at_the_bed() {
  for (double h : {13.0, 14.6, 16.0}) {
    PartMeasure pm(weld_mesh(box(24, 20, h)));
    DomainSpec s;
    s.bead_mm = 0.3;
    s.min_strut_lines = 2.0;
    Region r = face_region(1, Role::Lattice, {12, 0, h / 2}, {0, 1, 0}, 12, h / 2, 12);
    if (!(std::fabs(r.prism.u.x) > 0.5)) r = face_region(1, Role::Lattice, {12, 0, h / 2}, {0, 1, 0}, h / 2, 12, 12);
    s.regions = {r};
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Stepped;
    cs.one_grid = true;
    cs.cell_max_mm = 12;
    cs.cell_min_mm = 5;
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    const Bars laid = lay_bars(l, d);
    double lowest = 1e9;   // the lowest node: the top of the row the bed cuts
    for (const Bar& b : laid.bars) {
      if (b.end_a == Bar::End::Node) lowest = std::min(lowest, b.a.z);
      if (b.end_b == Bar::End::Node) lowest = std::min(lowest, b.b.z);
    }
    std::size_t on_bed = 0, short_on_bed = 0, unmarked = 0;
    for (const Bar& b : laid.bars) {
      const bool a_bed = b.end_a == Bar::End::Surface && b.a.z <= 0.2, b_bed = b.end_b == Bar::End::Surface && b.b.z <= 0.2;
      if (a_bed || b_bed) {
        ++on_bed;
        if (bar_length(b) < b.width) ++short_on_bed;
        if ((a_bed && !(b.on_bed & Bar::kOnBedA)) || (b_bed && !(b.on_bed & Bar::kOnBedB))) ++unmarked;
      }
      if ((b.end_a == Bar::End::Surface && b.a.z > 0.2 && (b.on_bed & Bar::kOnBedA)) ||
          (b.end_b == Bar::End::Surface && b.b.z > 0.2 && (b.on_bed & Bar::kOnBedB)))
        ++unmarked;   // marked off the bed
    }
    Bars kept = laid;
    drop_loose_bars(kept);
    std::size_t kept_on_bed = 0, surface_off_bed = 0, air_at_bed = 0;
    double kept_low = 1e9;
    for (const Bar& b : kept.bars) {
      kept_low = std::min({kept_low, b.a.z, b.b.z});
      for (int e = 0; e < 2; ++e) {
        const bool surf = (e ? b.end_b : b.end_a) == Bar::End::Surface;
        const double z = e ? b.b.z : b.a.z;
        if (surf && z <= 0.2) ++kept_on_bed;
        if (surf && z > 0.2) ++surface_off_bed;
      }
    }
    for (const Bars::CutEnd& c : kept.cut_in_air) air_at_bed += c.at.z <= 0.2;
    // RED CONTROL: without the bed's mark the drop takes every one of them (as before K6)
    Bars unmarked_bars = laid;
    for (Bar& b : unmarked_bars.bars) b.on_bed = 0;
    drop_loose_bars(unmarked_bars);
    std::size_t control_on_bed = 0;
    double control_low = 1e9;
    for (const Bar& b : unmarked_bars.bars) {
      control_low = std::min({control_low, b.a.z, b.b.z});
      control_on_bed += (b.end_a == Bar::End::Surface && b.a.z <= 0.2) + (b.end_b == Bar::End::Surface && b.b.z <= 0.2);
    }
    std::printf("[K6] %.1f mm block: the lowest node at z %.2f (the row under it cut by the bed); %zu struts cut at the bed "
                "(%zu shorter than wide), %zu unmarked; after the drop %zu ends on the bed, lowest strut z %.3f, %zu Surface ends "
                "off the bed, %zu cut ends 'in the air' at the bed; without the mark: %zu on the bed, lowest z %.3f\n",
                h, lowest, on_bed, short_on_bed, unmarked, kept_on_bed, kept_low,
                surface_off_bed, air_at_bed, control_on_bed, control_low);
    CHECK(on_bed > 10 && unmarked == 0);
    CHECK(kept_on_bed > 10 && kept_low < 1e-6);   // the bottom row stands on the bed
    CHECK(surface_off_bed == 0 && air_at_bed == 0);   // elsewhere unchanged: a cut end off the bed lands on nothing
    CHECK(control_on_bed == 0 && control_low > 0.2);   // RED CONTROL
    if (h == 13.0) CHECK(short_on_bed > 0);   // S4 keeps a stub on the bed however short
  }
}

// K7 (362's brief on his 11-24 notes: Auto tries cell sizes). A block latticed from its top face down to the bed, one
// grid, Stepped, cells 4 to 12 mm (a 0.6 mm strut). Auto lays a 12 mm base (three layers of the 36 mm depth, graded down
// to 4 mm) whose finest cells the 42 x 41 block's walls cut to slivers; the search lays the 9 mm base (four layers,
// graded to 4.5 mm), with none. The sizes that would lose the grade (a ladder of one size: 7.2, 6, 5.1, 4.5 and 4 mm)
// are tried and never laid. A 36 x 34 block leaves none at 12 mm: that size stays, and the layout is the one laid
// without the search, byte for byte. Same answer every time.
static void test_cell_search_fits_square_faces() {
  const Vec3 down{0, 0, -1};
  for (const double x : {42.0, 36.0}) {
    const double y = x == 42.0 ? 41.0 : 34.0;
    PartMeasure pm(weld_mesh(box(x, y, 36)));
    DomainSpec s;
    s.bead_mm = 0.3;
    s.min_strut_lines = 2.0;
    Region r = face_region(1, Role::Lattice, {x / 2, y / 2, 36}, down, x / 2, y / 2, 36);
    if (!(std::fabs(r.prism.u.x) > 0.5)) r = face_region(1, Role::Lattice, {x / 2, y / 2, 36}, down, y / 2, x / 2, 36);
    s.regions = {r};
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Stepped;
    cs.one_grid = true;
    cs.cell_max_mm = 12;
    cs.cell_min_mm = 4;
    const Layout plain = lay_cells(d, cs);
    CellSpec on = cs;
    on.cell_search = true;
    const Layout fit = lay_cells(d, on);
    CHECK(plain.cell_search.empty());   // not asked: nothing said, nothing changed
    CHECK(fit.cell_search.size() == 1);
    if (fit.cell_search.size() != 1) continue;
    const Layout::CellSearch& c = fit.cell_search[0];
    std::printf("[K7] %.0f x %.0f block: chose %.4g mm (%s), %.4g mm^2 of square face read in %.1f ms\n", x, y, c.chosen_mm,
                c.why.c_str(), c.square_mm2, c.ms);
    for (const Layout::CellSearch::Tried& t : c.tried)
      std::printf("[K7]   tried %.4g mm (finest %.4g, %s): %zu slivers, %.4g mm^2, thinnest %.3g of its cell\n", t.base_mm,
                  t.finest_mm, t.grades ? "grades" : "one size", t.slivers, t.sliver_mm2, t.thinnest);
    CHECK(c.tried.size() == 7 && std::fabs(c.tried[0].base_mm - 12.0) < 1e-9 && std::fabs(c.tried[0].finest_mm - 4.0) < 1e-9);
    CHECK(c.square_mm2 > 2.0 * (x + y) * 36.0 * 0.8);   // the four walls (and the bed and the face) read
    std::size_t one_size = 0;
    for (const Layout::CellSearch::Tried& t : c.tried) one_size += !t.grades;
    CHECK(one_size == 5 && c.tried[0].grades && c.tried[1].grades);
    if (x == 42.0) {
      CHECK(c.tried[0].slivers > 0 && c.tried[0].thinnest < kSliverFraction);   // RED CONTROL: Auto's own size
      CHECK(c.tried[1].slivers == 0 && std::fabs(c.tried[1].base_mm - 9.0) < 1e-9);
      CHECK(std::fabs(c.chosen_mm - 9.0) < 1e-9 && std::fabs(fit.regions[0].base_cell_mm - 9.0) < 1e-9);
      CHECK(!(plain.cells == fit.cells));
    } else {
      CHECK(c.tried[0].slivers == 0 && std::fabs(c.chosen_mm - 12.0) < 1e-9);
      CHECK(plain.cells == fit.cells);   // the size Auto lays stands, byte for byte
    }
    CHECK(lay_cells(d, on).cells == fit.cells && lay_cells(d, on, 1).cells == fit.cells);   // the same, any threads
  }
}

// K8 (362's brief: stretch the edge row). A block 38 wide and 20 tall latticed under its front face 9 deep: one grid,
// Stepped, a 9 mm base cut to 4.5 mm at its edges. The bed and the top cut the bottom and top rows to 1 mm slivers; with
// the stretch the 4.5 mm row on the bed reaches down on to it (5.5 mm tall), its own nodes stand on the bed, and the
// slivers lay none. The top's slivers stay (under a ceiling the row's top struts would lie along it as bridges), and
// so do the two side walls' (a sideways stretch would lay the struts flatter than the cells do).
static void test_edge_rows_stretch() {
  const double x = 38.0, y = 20.0, h = 20.0, depth = 9.0;
  PartMeasure pm(weld_mesh(box(x, y, h)));
  DomainSpec s;
  s.bead_mm = 0.3;
  s.min_strut_lines = 2.0;
  Region r = face_region(1, Role::Lattice, {x / 2, 0, h / 2}, {0, 1, 0}, x / 2, h / 2, depth);
  if (!(std::fabs(r.prism.u.x) > 0.5)) r = face_region(1, Role::Lattice, {x / 2, 0, h / 2}, {0, 1, 0}, h / 2, x / 2, depth);
  s.regions = {r};
  Domain d(pm, s);
  CellSpec cs;
  cs.algorithm = Algorithm::Stepped;
  cs.one_grid = true;
  cs.cell_max_mm = 12;
  cs.cell_min_mm = 4;
  Layout plain = lay_cells(d, cs);
  CellSpec on = cs;
  on.stretch_edges = true;
  Layout fit = lay_cells(d, on);
  CHECK(fit.cell_search.size() == 1);
  if (fit.cell_search.size() != 1) return;
  const Layout::CellSearch& c = fit.cell_search[0];
  std::size_t absorbed = 0, stretched = 0, sideways = 0, up = 0;
  double tallest = 0.0;
  for (const Cell& cell : fit.cells) {
    absorbed += cell.absorbed;
    for (int a = 0; a < 3; ++a)
      if (cell.reach_lo[a] > 0.0 || cell.reach_hi[a] > 0.0) {
        ++stretched;
        const double z = fit.frames[static_cast<std::size_t>(cell.frame)].ax[a].z;
        if (std::fabs(z) < 0.99) ++sideways;
        if ((z > 0.0 ? cell.reach_hi[a] : cell.reach_lo[a]) > 0.0) ++up;   // reaching up, to a ceiling
        tallest = std::max(tallest, cell.size + cell.reach_lo[a] + cell.reach_hi[a]);
      }
  }
  std::printf("[K8] %zu cells reach on to a square face (tallest %.9g mm), %zu slivers taken in, %zu left; report: %zu "
              "stretched, %zu taken in, %zu left (%s)\n", stretched, tallest, absorbed, c.slivers_left, c.stretched, c.taken_in,
              c.slivers_left, c.why.c_str());
  CHECK(stretched > 0 && sideways == 0 && up == 0 && stretched == c.stretched && absorbed == c.taken_in && absorbed >= stretched);
  CHECK(std::fabs(tallest - 5.48) < 1e-4);   // the 4.5 mm row on the bed, 1 mm taller less a hair (never past Max cell)
  CHECK(lay_cells(d, on).cells == fit.cells);   // the same every time
  CHECK(c.slivers_left > 0);   // the side walls' slivers stay (never a strut flatter)
  CHECK(c.tried.size() == 1 && std::fabs(c.chosen_mm - 9.0) < 1e-9);   // the stretch only: no size searched
  set_struts(plain, StrutSpec{});
  set_struts(fit, StrutSpec{});
  const auto at_bed = [](const Bars& bars, std::size_t* surface, std::size_t* node, double* low) {
    *surface = *node = 0;
    *low = 1e9;
    for (const Bar& b : bars.bars) {
      if (b.end_a == Bar::End::Node) *low = std::min(*low, b.a.z);   // the lowest node
      if (b.end_b == Bar::End::Node) *low = std::min(*low, b.b.z);
      for (int e = 0; e < 2; ++e) {
        const Vec3& p = e ? b.b : b.a;
        if (p.z > 0.05) continue;
        ((e ? b.end_b : b.end_a) == Bar::End::Surface ? *surface : *node) += 1;
      }
    }
  };
  Bars pb = lay_bars(plain, d), fb = lay_bars(fit, d);
  drop_loose_bars(pb);
  drop_loose_bars(fb);
  std::size_t ps = 0, pn = 0, fs = 0, fn = 0;
  double plow = 0.0, flow = 0.0;
  at_bed(pb, &ps, &pn, &plow);
  at_bed(fb, &fs, &fn, &flow);
  std::printf("[K8] bar ends on the bed: as laid %zu cut, %zu nodes; stretched %zu cut, %zu nodes (lowest %.4g)\n", ps, pn, fs,
              fn, flow);
  CHECK(ps > 0);                           // RED CONTROL: the bottom row's struts cut at the bed (K6)
  CHECK(fn > 0 && std::fabs(flow - 0.02) < 1e-4);   // the stretched row's own nodes stand on the bed (a hair above it)
  CHECK(fs < ps);                          // only the corner cells' cut struts are left there
}

// K2 (his 11-23 notes: "Look at the lack of crisp straight lines at the edges of the lattice. This was with cut cells =
// on. So why isn't it working?"). A prism whose plan is a trapezoid with a 45 degree side (0,0)-(20,20), 30 tall,
// latticed under its top face (the whole of it), Let walls cut cells on. Read a hair inside the sloped side, every
// 0.5 mm along it and up it, at 0.6, 1.2 and 2.4 mm in: lattice the domain asks for there that no cell holds is the
// solid step he sees. Printed per setting; with the cells cut along the slope there is none.
static void test_cut_cells_follow_a_slope() {
  const TriangleMesh m = prism({{0, 0}, {60, 0}, {60, 20}, {20, 20}}, 0, 30);
  PartMeasure pm(weld_mesh(m));
  for (double rim : {0.0, -1.0}) {   // no Finish, and a Rim along the outline (solid beside the slope: his stand's)
  DomainSpec s;
  s.bead_mm = 0.45;
  s.min_strut_lines = 2.0;
  s.rim_mm = rim;
  // The top face's region: its outline the trapezoid's box (the region's prism is cut by the part's own sides).
  {
    const Region r = face_region(1, Role::Lattice, {30, 10, 30}, {0, 0, -1}, 30, 10, 30);
    s.regions = {std::fabs(r.prism.u.x) > 0.5 ? r : face_region(1, Role::Lattice, {30, 10, 30}, {0, 0, -1}, 10, 30, 30)};
  }
  Domain d(pm, s);
  auto pr = d.probe();
  const double inv = 1.0 / std::sqrt(2.0);
  const Vec3 in_dir{inv, -inv, 0};   // into the part, square to the slope
  for (Algorithm algo : {Algorithm::Stepped, Algorithm::DefaultGrade})
    for (bool quilt : {false, true}) {
      CellSpec cs;
      cs.algorithm = algo;
      cs.one_grid = true;
      cs.cell_max_mm = 12;
      cs.cell_min_mm = 4;
      cs.allow_quilt = quilt;
      const Layout l = lay_cells(d, cs);
      int asked = 0, bare = 0;
      for (double depth : {0.6, 1.2, 2.4})
        for (double t = 1.0; t <= 27.3; t += 0.5)      // along the slope (its length is 28.3)
          for (double z = 1.0; z <= 29.0; z += 0.5) {
            const Vec3 p{t * inv + depth * in_dir.x, t * inv + depth * in_dir.y, z};
            if (!pr.where(p).lattice()) continue;
            ++asked;
            if (cells_holding(l, p, 1) == 0) ++bare;
          }
      std::printf("[K2] slope, %s, rim %s, quilt %s: %zu cells, %zu solid; along the slope %d of %d places asked for are held "
                  "by no cell\n", algo == Algorithm::Stepped ? "Stepped" : "Default Grade", rim < 0.0 ? "on" : "off",
                  quilt ? "on" : "off", l.cells.size(), l.solid.size(), bare, asked);
      CHECK(asked > 1000 && bare == 0);
    }
  }
}

// K3 (his 11-23 notes: quilting "should ALWAYS be off by default unless it is literally impossible to lattice without
// it"). The 20 x 20 x 12 block, two lines of 0.45 mm (a 0.9 mm strut: the open look's smallest cell is 4.74 mm, the
// quilt's 2.55 mm): a region 3 mm deep under the top face (no cell that prints open fits it) and one 6 mm deep under the
// bottom face. With the quilt off the thin region is laid again with the quilt's smallest cell, that region only, and
// named; the thick one keeps exactly the cells it lays alone. With the quilt on there is nothing to fall back to.
static void test_quilt_only_where_nothing_else_lays() {
  const StepModel model = finish_block();
  Settings st;
  st.regions = {{1, Role::Lattice, {1}, 3.0, 0.0}, {2, Role::Lattice, {0}, 6.0, 0.0}};
  st.cells.cell_max_mm = 6;
  const Outcome both = Session(model).lay(st);
  const double open_floor = 0.9 / (0.7592 / 4.0), quilt_floor = 0.9 / kQuiltStrutPerCell;
  std::size_t thin = 0, thick = 0, thin_small = 0, thick_small = 0;
  for (const Cell& c : both.layout.cells) {
    const bool top = c.region == 1;
    (top ? thin : thick) += 1;
    if (c.size < open_floor - 1e-9) (top ? thin_small : thick_small) += 1;
    CHECK(c.size >= quilt_floor - 1e-9);
  }
  std::printf("[K3] quilt off: regions laid with the quilt %zu (first %d); thin region %zu cells (%zu under the open look), "
              "thick region %zu cells (%zu under it)\n", both.quilt_regions.size(), both.quilt_regions.empty() ? -1 : both.quilt_regions.front(),
              thin, thin_small, thick, thick_small);
  CHECK(both.quilt_regions == std::vector<int>{1} && thin > 0 && thin_small == thin && thick > 0 && thick_small == 0);
  // The thick region alone: the same cells (the fallback touched the thin region only).
  Settings alone = st;
  alone.regions = {st.regions[1]};
  const Outcome one = Session(model).lay(alone);
  std::vector<std::array<double, 5>> a, b;
  for (const Cell& c : both.layout.cells)
    if (c.region == 2) a.push_back({c.lo[0], c.lo[1], c.lo[2], c.size, c.strut});
  for (const Cell& c : one.layout.cells) b.push_back({c.lo[0], c.lo[1], c.lo[2], c.size, c.strut});
  CHECK(a == b && one.quilt_regions.empty());
  // Allow quilt on: no fallback (the quilt is on everywhere already).
  Settings on = st;
  on.struts.allow_quilt = true;
  CHECK(Session(model).lay(on).quilt_regions.empty());
  // Only where the cell is Auto (362, 2026-11-24, his D4: a typed cell is his; one that fits nowhere stays solid, the
  // file job's no_cells, the app's "Cannot Lattice"). The thin region alone: Auto falls back to the quilt; a typed 6 mm
  // cell lays nothing, and is not quilted.
  Settings thin_only = st;
  thin_only.regions = {st.regions[0]};
  const Outcome auto_cell = Session(model).lay(thin_only);
  Settings typed = thin_only;
  typed.cells.cell_mm = 6;
  const Outcome typed_cell = Session(model).lay(typed);
  std::printf("[K3] the thin region alone: Auto cell %zu cells (quilted %zu), typed 6 mm cell %zu cells (quilted %zu)\n",
              auto_cell.layout.cells.size(), auto_cell.quilt_regions.size(), typed_cell.layout.cells.size(),
              typed_cell.quilt_regions.size());
  CHECK(auto_cell.quilt_regions == std::vector<int>{1} && !auto_cell.layout.cells.empty());   // as before
  CHECK(typed_cell.quilt_regions.empty() && typed_cell.layout.cells.empty());   // no fallback: nothing to lay (no_cells)
}

static void test_cells_curved_region() {
  int L = -1, square = -1, sideA = -1, sideB = -1;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  PartMeasure pm(weld_mesh(model.mesh));
  DomainSpec s;
  s.regions = {region_from_faces(model, {sideA, sideB}, 2, Role::Lattice, 5)};
  Domain d(pm, s);
  CellSpec cs = two_across();   // Default Grade
  const Layout l = lay_cells(d, cs);
  // 5 mm deep, two across: cells of at most 2.5 mm, so the floor cell (2.37).
  CHECK(!l.cells.empty());
  int wrong = 0;
  for (const Cell& c : l.cells)
    if (c.region != 2 || std::fabs(c.size - 0.45 * 5.268704) > 1e-5) ++wrong;
  CHECK(wrong == 0);
  CHECK(badly_covered(d, l, {0, 0, 0}, {60, 60, 10}, 1.3) == 0);
}

// Print rule P8 (f): a cut piece of lattice thinner than its own strut, lying against solid, is solid. His v3 stand
// had a row of cut cells 0.49 mm thick under the front wall's solid cap: every strut in it was a stub and dropped, and
// what the row below left of it was an empty layer under the cap that no printer can print over.
// The part: a 30 x 12 x 30 block standing up, lattice under its front face (y = 0) 8 mm deep, its outline pulled in
// by Expand, Default Grade from 8 mm cells with Grade to shape (band 4) and Allow quilt, as on his stand with small
// cells on: the band's finest cells (2 mm) are cut by the outline. Their top row runs z 27 to 29, so with Expand
// -2.6 the outline at z 27.4 leaves it 0.4 mm thick under the solid above (the part's own, no lattice asked there).
static const double kSlotStrut = 0.7;   // a strut leaning at 45 degrees is 0.57 mm long in a 0.4 mm row: a stub (S4)
static TriangleMesh slot_block(double z_top = 30) { return prism({{0, 0}, {30, 0}, {30, 12}, {0, 12}}, 0, z_top); }
static Region slot_front(double expand) { return face_region(1, Role::Lattice, {15, 0, 15}, {0, 1, 0}, 15, 15, 8, expand); }
static CellSpec slot_cells() {
  CellSpec cs;
  cs.algorithm = Algorithm::DefaultGrade;
  cs.cell_mm = 8;
  cs.grade_to_shape = true;
  cs.band_mm = 4;
  cs.allow_quilt = true;
  return cs;
}
static StrutSpec slot_struts(double w) {
  StrutSpec ss;
  ss.width_mm = w;
  ss.allow_quilt = true;
  return ss;
}
static std::size_t top_row(const Layout& l, double z0) {   // cut cells whose cube starts at height z0
  std::size_t n = 0;
  for (const Cell& c : l.cells) {
    const Frame& f = l.frames[static_cast<std::size_t>(c.frame)];
    double z = 1e300;
    for (int k = 0; k < 8; ++k)
      z = std::min(z, f.at(c.lo[0] + ((k & 1) ? c.size : 0), c.lo[1] + ((k & 2) ? c.size : 0), c.lo[2] + ((k & 4) ? c.size : 0)).z);
    n += c.cut && c.region == 1 && std::fabs(z - z0) < 1e-6;
  }
  return n;
}
static StepModel slot_model() {   // the block as a model: faces 0 bottom, 1 top, 2 the front (y = 0), 3..5 the rest
  StepModel m;
  const double x = 30, y = 12, z = 30;
  const Vec3 p[8] = {{0, 0, 0}, {x, 0, 0}, {x, y, 0}, {0, y, 0}, {0, 0, z}, {x, 0, z}, {x, y, z}, {0, y, z}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  const Vec3 out[6] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {1, 0, 0}, {0, 1, 0}, {-1, 0, 0}};
  for (int f = 0; f < 6; ++f) {
    StepFaceInfo info;
    info.kind = StepSurfaceKind::Plane;
    info.plane_normal = out[f];
    info.plane_origin = p[q[f][0]];
    m.faces.push_back(info);
    for (int t = 0; t < 2; ++t) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][t ? 2 : 1]], p[q[f][t ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  return m;
}
static void test_thin_cut_pieces() {
  // (a) The top row 0.4 mm thick under solid: it goes solid, and so does every other cut piece of the band that thin
  // against the solid round the outline; the struts of the row below are laid as before and end ON solid.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.6)};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    const Layout as_laid = l;
    const std::size_t row = top_row(l, 27.0);
    CHECK(row > 0);
    const Bars before = lay_bars(as_laid, d);
    std::vector<ThinCut> found;
    const std::size_t n = solidify_thin_cuts(l, d, 0, &found);
    CHECK(n >= row && found.size() == n);
    CHECK(top_row(l, 27.0) == 0);
    CHECK(l.cells.size() == as_laid.cells.size() - n && l.solid.size() == as_laid.solid.size() + n);
    bool all_thin = true;
    for (const ThinCut& t : found) {
      const Cell& c = l.solid[t.solid];
      all_thin = all_thin && c.cut && t.thick_mm > 0.2 && t.thick_mm <= 0.4 + 1e-9 && t.thick_mm < c.strut;
    }
    CHECK(all_thin);
    // Each carries its reason (D14c): a sliver, its thickness, its strut.
    bool why_ok = l.solid_why.size() == l.solid.size();
    for (const ThinCut& t : found)
      why_ok = why_ok && t.solid < l.solid_why.size() && l.solid_why[t.solid].why == NoCell::Sliver &&
               l.solid_why[t.solid].have_mm == static_cast<float>(t.thick_mm) &&
               l.solid_why[t.solid].need_mm == static_cast<float>(l.solid[t.solid].strut);
    CHECK(why_ok);
    std::size_t tally = 0;
    for (const RegionCells& r : l.regions) tally += r.cells;
    CHECK(tally == l.cells.size());
    // The slot is solid now; before, a cell held it. The row below is lattice still.
    const SolidAt was(as_laid), now(l);
    CHECK(!was(pr, {15.3, 4.1, 27.2}) && now(pr, {15.3, 4.1, 27.2}));
    CHECK(!now(pr, {15.3, 4.1, 26.8}));
    const Bars after = lay_bars(l, d);
    // Before, the row's own struts were stubs; now there are none there, and no bar stands above the row below.
    double highest = 0.0, highest_before = 0.0;
    for (const Bar& b : after.bars) highest = std::max({highest, b.a.z, b.b.z});
    for (const Bar& b : before.bars) highest_before = std::max({highest_before, b.a.z, b.b.z});
    CHECK(before.stubs > after.stubs);
    CHECK(highest <= 27.0 + 1e-6 && highest_before <= 27.0 + 1e-6);
    // The nodes in the plane z = 27, away from the outline, stand on solid.
    std::size_t on_solid = 0, nodes = 0;
    for (const Bar& b : after.bars)
      for (const Vec3& e : {b.a, b.b})
        if (std::fabs(e.z - 27) < 1e-6 && e.x > 4 && e.x < 26 && e.y > 0.5 && e.y < 7.5) {
          ++nodes;
          on_solid += now(pr, {e.x, e.y, 27.1});
        }
    CHECK(nodes > 0 && on_solid == nodes);
    // The same answer on one thread; and asked again, nothing more is thin.
    Layout one = as_laid;
    CHECK(solidify_thin_cuts(one, d, 1) == n && one.cells == l.cells && one.solid == l.solid);
    Layout again = l;
    CHECK(solidify_thin_cuts(again, d) == 0 && again.cells == l.cells && again.solid == l.solid);
    std::printf("P8 (f) a: %zu cells, %zu cut 0.4 mm thick made solid (%zu in the row under the top); stubs %zu -> %zu\n",
                as_laid.cells.size(), n, row, before.stubs, after.stubs);
  }
  // (b) Expand -2.0: the row is 1.0 mm thick, the strut and 0.3 more. Left open, with struts in it that reach the solid.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.0)};
    Domain d(pm, s);
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    CHECK(top_row(l, 27.0) > 0);
    const Layout as_laid = l;
    std::vector<ThinCut> found;
    solidify_thin_cuts(l, d, 0, &found);
    std::size_t in_row = 0;
    for (const ThinCut& t : found) {
      const Cell& c = l.solid[t.solid];
      in_row += l.frames[static_cast<std::size_t>(c.frame)].at(c.lo[0], c.lo[1], c.lo[2]).z > 26.9;
    }
    CHECK(top_row(l, 27.0) == top_row(as_laid, 27.0) && in_row == 0);
    const Bars bars = lay_bars(l, d);
    std::size_t to_cap = 0;   // struts of the row whose upper end is the outline, where the solid begins
    for (const Bar& b : bars.bars) to_cap += std::min(b.a.z, b.b.z) >= 27.0 - 1e-6 && std::max(b.a.z, b.b.z) >= 28.0 - 1e-6;
    CHECK(to_cap > 0);
  }
  // (c) A thin piece facing air: the block 27.4 mm tall, the same region (its outline above the part): the top row
  // is cut 0.4 mm thick by the part's own top face, air above. Left open.
  {
    PartMeasure pm(weld_mesh(slot_block(27.4)));
    DomainSpec s;
    s.regions = {slot_front(-2.6)};
    Domain d(pm, s);
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    std::vector<ThinCut> found;
    const Layout as_laid = l;
    solidify_thin_cuts(l, d, 0, &found);
    std::size_t in_row = 0;
    for (const ThinCut& t : found) {
      const Cell& c = l.solid[t.solid];
      in_row += l.frames[static_cast<std::size_t>(c.frame)].at(c.lo[0], c.lo[1], c.lo[2]).z > 26.9;
    }
    CHECK(top_row(as_laid, 27.0) > 0 && in_row == 0 && top_row(l, 27.0) == top_row(as_laid, 27.0));
  }
  // (d) A seam: above the outline is ANOTHER lattice region, under the top face 2.6 mm deep. The front region's top
  // row (cut 0.4 mm thick) lies against that region's lattice, not against solid: left open, whether the other region
  // lays its own cells there (one cell across: it does) or lays none and the row takes its lattice in (three across).
  for (int across : {1, 3}) {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.6), face_region(2, Role::Lattice, {15, 6, 30}, {0, 0, -1}, 15, 15, 2.6)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({15.3, 4.1, 28.5}) == Where{Why::Lattice, 2}));
    CellSpec cs = slot_cells();
    cs.min_cells_across = across;
    Layout l = lay_cells(d, cs);
    set_struts(l, slot_struts(kSlotStrut));
    std::size_t other = 0;
    for (const Cell& c : l.cells) other += c.region == 2;
    std::vector<ThinCut> found;
    const Layout as_laid = l;
    solidify_thin_cuts(l, d, 0, &found);
    std::size_t in_row = 0;
    for (const ThinCut& t : found) {
      const Cell& c = l.solid[t.solid];
      // Away from the two ends of the row (there the region's edge, x 2.6 and 27.4, puts solid in the cube too).
      const Vec3 at = l.frames[static_cast<std::size_t>(c.frame)].at(c.lo[0], c.lo[1], c.lo[2]);
      in_row += c.region == 1 && at.z > 26.9 && at.x > 2.9 && at.x + c.size < 27.1;
    }
    CHECK((across == 1 ? other > 0 : other == 0));
    CHECK(top_row(as_laid, 27.0) > 8 && in_row == 0);
  }
  // (d, one region) A seam between two walls of ONE flat region. A Protect skin 4.3 mm deep on the back face right
  // of x 15 ends the lattice's column there at 7.7 mm (D5); left of it the column is the region's 8 mm: two walls.
  // A cell of the left wall placed over the line between them holds a sliver 0.3 mm thin along x, with the right
  // wall's lattice beyond it and the skin's solid beyond only behind 7.7 mm (one line in five). Left open.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.6)};
    MeshSink back;
    back.add_triangle({15, 12, -1}, {31, 12, -1}, {31, 12, 31});
    back.add_triangle({15, 12, -1}, {31, 12, 31}, {15, 12, 31});
    s.protect = {{1, back.mesh, 4.3}};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    const WallMap& walls = l.walls[0];
    const Reading left = read_at(pr, l.frames[0], walls, 0.0, -5.0, 7.0), right = read_at(pr, l.frames[0], walls, 0.0, 5.0, 7.0);
    CHECK(left.wall >= 0 && right.wall >= 0 && left.wall != right.wall);
    double edge = -5.0;   // where the left wall ends at 7 mm deep (frame x, origin x 15)
    while (edge < 5.0 && read_at(pr, l.frames[0], walls, 0.0, edge + 0.01, 7.0).wall == left.wall) edge += 0.01;
    Cell c;
    for (const Cell& x : l.cells)
      if (x.region == 1 && x.wall == left.wall) { c = x; break; }
    c.lo[0] = -2.0;   // z 13 to 15 (the frame's first axis is z, its second x, its third the depth; origin x 15, z 15)
    c.lo[1] = edge - 0.3;
    c.lo[2] = 6.0;
    c.size = 2.0;
    c.cut = true;
    c.strut = kSlotStrut;
    Layout one = l;
    one.cells = {c};
    one.absorb = false;
    one.index.reset();
    CHECK(cell_holds_at(one, pr, 0, -1.0, edge - 0.15, 7.0) && !cell_holds_at(one, pr, 0, -1.0, edge + 0.5, 7.0));
    CHECK(pr.where(l.frames[0].at(-1.0, edge + 0.5, 7.9)).why == Why::ProtectSkin);   // a little solid at its end
    CHECK(solidify_thin_cuts(one, d) == 0);
  }
  // (g) A piece the 5 x 5 lines miss: one cell of (a)'s corner, at the outline's far end (x 27.4) under the solid,
  // moved a quarter millimetre up and along so it holds only 0.15 x 0.15 mm of lattice in its corner. No line of the
  // grid finds it; the lines through its own held sample points do. Made solid.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.6)};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    std::size_t corner = l.cells.size();
    for (std::size_t ci = 0; ci < l.cells.size(); ++ci) {
      const Cell& c = l.cells[ci];
      const Vec3 at = l.frames[static_cast<std::size_t>(c.frame)].at(c.lo[0], c.lo[1], c.lo[2]);
      if (c.cut && std::fabs(at.z - 27) < 1e-6 && std::fabs(at.x - 27) < 1e-6 && std::fabs(at.y - 2) < 1e-6) corner = ci;
    }
    CHECK(corner < l.cells.size());
    if (corner < l.cells.size()) {
      Layout one;
      one = l;
      one.cells = {l.cells[corner]};
      one.cells[0].lo[0] += 0.25;   // the frame's first axis is z here, its second x
      one.cells[0].lo[1] += 0.25;
      one.absorb = false;
      one.index.reset();
      const Cell& c = one.cells[0];
      CHECK(cell_holds_at(one, pr, 0, c.lo[0] + 0.05, c.lo[1] + 0.05, c.lo[2] + 1.0));
      std::vector<ThinCut> found;
      CHECK(solidify_thin_cuts(one, d, 0, &found) == 1 && found.size() == 1);
      if (found.size() == 1) CHECK(found[0].thick_mm > 0.1 && found[0].thick_mm < 0.2);
    }
  }
  // (f) What the rule made solid is never opened again: a cube of ANOTHER region's frame that reaches over it does not
  // take its lattice in (D14b). The block of (a) latticed whole (the part's own frame, 8 mm cells, behind the front
  // region from y 8), with a No lattice cap 2.6 mm deep on top: the front region's top row is cut 0.4 mm thick
  // against the cap, and the whole part's cubes (y 6 to 14) reach over its back end.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.start = Start::AllLattice;
    s.regions = {slot_front(-2.6), face_region(3, Role::NoLattice, {15, 6, 30}, {0, 0, -1}, 15, 15, 2.6)};
    Domain d(pm, s);
    auto pr = d.probe();
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    const Layout as_laid = l;
    std::vector<ThinCut> found;
    solidify_thin_cuts(l, d, 0, &found);
    const SolidAt now(l);
    // Every point a moved cell held as its own is solid now; and some such point lies in a cube of the other region.
    std::size_t held = 0, opened = 0, under_other = 0;
    for (const ThinCut& t : found) {
      const Cell& c = l.solid[t.solid];
      const Frame& f = l.frames[static_cast<std::size_t>(c.frame)];
      std::size_t ci = 0;
      while (ci < as_laid.cells.size() && !(as_laid.cells[ci] == c)) ++ci;
      for (int k = 0; k < 6; ++k)
        for (int j = 0; j < 6; ++j)
          for (int i = 0; i < 6; ++i) {
            const double q[3] = {c.lo[0] + c.size * (i + 0.5) / 6, c.lo[1] + c.size * (j + 0.5) / 6, c.lo[2] + c.size * (k + 0.5) / 6};
            if (!cell_holds_at(as_laid, pr, ci, q[0], q[1], q[2])) continue;
            const Vec3 p = f.at(q[0], q[1], q[2]);
            ++held;
            opened += !now(pr, p);
            for (const Cell& o : l.cells)
              if (o.region != 1) {
                const Frame& g = l.frames[static_cast<std::size_t>(o.frame)];
                const Vec3 r{p.x - g.origin.x, p.y - g.origin.y, p.z - g.origin.z};
                bool in = true;
                for (int a = 0; a < 3; ++a) {
                  const double v = r.x * g.ax[a].x + r.y * g.ax[a].y + r.z * g.ax[a].z;
                  in = in && v >= o.lo[a] && v < o.lo[a] + o.size;
                }
                if (in) { ++under_other; break; }
              }
          }
    }
    std::printf("P8 (f) f: %zu made solid, %zu of their points held before, %zu in a cube of the other region, %zu opened again\n",
                found.size(), held, under_other, opened);
    CHECK(!found.empty() && under_other > 0);
    CHECK(opened == 0);
  }
  // (e) The strut changed after the cells are laid gives what a fresh session lays with that strut. Expand -2.4, the
  // row 0.6 mm thick: solid under a 0.7 mm strut, open under a 0.5 mm one, and back.
  {
    const StepModel model = slot_model();
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.regions = {{1, Role::Lattice, {2}, 8.0, -2.4}};
    st.cells = slot_cells();
    st.struts = slot_struts(kSlotStrut);
    auto same = [](const Outcome& x, const Outcome& y) {
      return x.layout.cells == y.layout.cells && x.layout.solid == y.layout.solid && same_bars(x.bars, y.bars) &&
             x.thin_solid == y.thin_solid;
    };
    Session session(model);
    const Outcome first = session.lay(st);
    CHECK(first.thin_solid > 0 && top_row(first.layout, 27.0) == 0);
    st.struts.width_mm = 0.5;
    const Outcome thinner = session.lay(st);
    CHECK(!thinner.read_again && top_row(thinner.layout, 27.0) > 0);
    CHECK(same(thinner, Session(model).lay(st)));
    st.struts.width_mm = kSlotStrut;
    const Outcome back = session.lay(st);
    CHECK(same(back, first) && same(back, Session(model).lay(st)));
  }
}

// CellSpec::one_grid (his ruling, 2026-11-14: an option for Aesthetic, off unless the user turns it on): one regular
// grid per region that every surface, pocket, skin and the region's edge simply cuts. Off is the layout as it was.
// C20 (his ruling 2026-11-14: cells shrink toward pockets and walls): only the smallest cell of a ladder is ever cut.
// A cube is whole when its 27 points and the 26 a hair inside its faces, edges and corners are lattice (of any region).
static bool whole_cube(const Domain& d, const Layout& l, int frame, const double lo[3], double s) {
  auto pr = d.probe();
  const Frame& f = l.frames[static_cast<std::size_t>(frame)];
  const double e[2][3] = {{1.0 / 6.0, 0.5, 5.0 / 6.0}, {0.04, 0.5, 0.96}};
  for (int g = 0; g < 2; ++g)
    for (int c = 0; c < 3; ++c)
      for (int b = 0; b < 3; ++b)
        for (int a = 0; a < 3; ++a)
          if (!pr.where(f.at(lo[0] + s * e[g][a], lo[1] + s * e[g][b], lo[2] + s * e[g][c])).lattice()) return false;
  return true;
}
// Over a layout: cut cells that are not the smallest, larger cells that are not whole, and cell corners off the
// smallest cell's grid (`unit`, counted from the first cell's corner). Each is 0 under C20.
struct C20 { int cut_large = 0, large_not_whole = 0, off_grid = 0; };
static C20 c20_count(const Domain& d, const Layout& l, double unit) {
  C20 r;
  for (const Cell& c : l.cells) {
    if (c.cut && !c.finest) ++r.cut_large;
    if (!c.finest && !whole_cube(d, l, c.frame, c.lo, c.size)) ++r.large_not_whole;
    for (int k = 0; k < 3; ++k) {
      const double q = (c.lo[k] - l.cells.front().lo[k]) / unit;
      if (std::fabs(q - std::round(q)) > 1e-6) { ++r.off_grid; break; }
    }
  }
  return r;
}

// C20 with Let walls cut cells on: a block with a slot cut into it from the back, so a pocket whose floor is NOT on
// any cell boundary but the smallest. Every cut cell is the smallest of its ladder; a larger cell stands only where it
// is whole; the cells keep one grid; nothing of the region is left without a cell; any number of threads. A ladder of
// one size is what one grid gave before this rule. Two lattice regions meeting at a seam: the seam cuts nothing.
static void test_one_grid_smallest_cut() {
  // Section (x across, y into the part from the face y = 0), extruded z 0..48: 48 wide, 24 deep, a slot from the back
  // face down to y = 10, x 18..30. Lattice from the face, 24 deep, cells up to 12 mm.
  PartMeasure pm(weld_mesh(prism({{0, 0}, {48, 0}, {48, 24}, {30, 24}, {30, 10}, {18, 10}, {18, 24}, {0, 24}}, 0, 48)));
  DomainSpec s;
  s.regions = {face_region(1, Role::Lattice, {24, 0, 24}, {0, 1, 0}, 24, 24, 24)};
  Domain d(pm, s);
  long tally[3] = {0, 0, 0};
  for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
    CellSpec cs;
    cs.algorithm = algo;
    cs.cell_max_mm = 12;
    cs.one_grid = true;
    const Layout l = lay_cells(d, cs);
    double smallest = 12.0, largest = 0.0;
    int cut = 0;
    for (const Cell& c : l.cells) {
      smallest = std::min(smallest, c.size);
      largest = std::max(largest, c.size);
      cut += c.cut;
    }
    CHECK(!l.cells.empty() && l.solid.empty());                    // the smallest is cut, never refused
    // C21 withdrawn: the slot cuts 2 of the 4 columns of 12 mm cubes under the face; the other two stand as 12 mm cells,
    // and the slot is lined with smaller cells.
    CHECK(smallest < 6.0 && largest == 12.0 && cut > 0);
    const C20 r = c20_count(d, l, smallest);
    CHECK(r.cut_large == 0);                                       // every cut cell is the smallest
    CHECK(r.large_not_whole == 0);                                 // every larger cell is whole (53 points)
    if (algo == Algorithm::DefaultGrade) {
      CHECK(r.off_grid == 0);                                      // one grid: corners on the smallest cell's grid
    } else {
      // Stepped packs each base cube from one unit of its own (C6c): every corner on the base grid's 12 / n grid,
      // n the cube's own fraction, so the base grid is kept.
      double o[3] = {1e300, 1e300, 1e300};
      for (const Cell& c : l.cells) for (int k = 0; k < 3; ++k) o[k] = std::min(o[k], c.lo[k]);
      auto whole_of = [](double v, double u) { return std::fabs(v / u - std::round(v / u)) < 1e-6; };
      int off = 0;
      for (const Cell& c : l.cells) {
        bool on = false;
        for (int n = 1; n <= 6 && !on; ++n) {
          const double u = 12.0 / n;
          on = whole_of(c.size, u);
          for (int k = 0; k < 3; ++k) {
            const double rel = c.lo[k] - o[k] - 12.0 * std::floor((c.lo[k] - o[k]) / 12.0 + 1e-9);
            on = on && whole_of(rel, u);
          }
        }
        off += !on;
      }
      CHECK(off == 0);
    }
    CHECK(badly_covered(d, l, {0, 0, 0}, {48, 24, 48}, 0.97) == 0);   // nothing left out, nothing held twice
    CHECK(lay_cells(d, cs, 1).cells == l.cells && lay_cells(d, cs, 3).cells == l.cells);   // D18
    tally[algo == Algorithm::Stepped] = static_cast<long>(l.cells.size());
  }
  {  // A ladder of ONE size: the cells the slot cuts are base cells, cut, as one grid gave before this rule.
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 12;
    cs.one_grid = true;
    const Layout l = lay_cells(d, cs);
    int other = 0, cut = 0;
    for (const Cell& c : l.cells) {
      if (c.size != 12.0 || !c.finest) ++other;
      cut += c.cut;
    }
    CHECK(l.cells.size() == 4 * 2 * 4 && other == 0 && cut > 0 && l.solid.empty());
    tally[2] = cut;
  }
  {  // Two lattice regions meeting at a seam (x = 30), each its own grid centred on its own outline, so the seam runs
     // through the middle of a cell. Lattice the cell takes in from the other region counts: the cell at the seam
     // stays the base cell.
    PartMeasure pm2(weld_mesh(prism({{0, 0}, {60, 0}, {60, 24}, {0, 24}}, 0, 48)));
    DomainSpec s2;
    s2.regions = {face_region(1, Role::Lattice, {15, 0, 24}, {0, 1, 0}, 24, 15, 12),   // (the face's u runs along z)
                  face_region(2, Role::Lattice, {45, 0, 24}, {0, 1, 0}, 24, 15, 12)};
    Domain d2(pm2, s2);
    CellSpec cs;
    cs.algorithm = Algorithm::DefaultGrade;
    cs.cell_max_mm = 12;
    cs.one_grid = true;
    const Layout l = lay_cells(d2, cs);
    int at_seam = 0, small_at_seam = 0;
    for (const Cell& c : l.cells) {
      const Vec3 m = cell_centre(l, c);
      if (std::fabs(m.x - 30.0) < 0.5 * c.size - 1e-9) {           // the seam runs through it
        ++at_seam;
        if (c.size < 12.0 - 1e-9) ++small_at_seam;
      }
    }
    CHECK(at_seam > 0 && small_at_seam == 0);
    // (A seam cell is flagged cut, for its own region's lattice ends at the seam; it is whole in lattice all the same.)
    CHECK(c20_count(d2, l, 3.0).large_not_whole == 0 && l.solid.empty());
  }
  std::printf("only the smallest cut: a slotted block is %ld cells (halves) and %ld (Stepped); one size: %ld cut 12 mm cells\n",
              tally[0], tally[1], tally[2]);
}

// C21, WITHDRAWN by the owner 2026-11-14 ("if grading is on and a larger cell size can fit, it SHOULD fit"): with Let walls
// cut cells on, a larger cell that lies whole in lattice IS laid, however few of them there are on the face. These were
// C21's cases; their checks now assert the opposite where it mattered.
static void test_one_grid_main_size() {
  auto lay_part = [](const std::vector<std::array<double, 2>>& section, Algorithm algo, double cell_max, int threads,
                     bool one_grid) {
    PartMeasure pm(weld_mesh(prism(section, 0, 64)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {32, 0, 32}, {0, 1, 0}, 32, 32, 8)};   // the whole 64 x 64 face
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = algo;
    cs.cell_max_mm = cell_max;
    cs.one_grid = one_grid;
    return lay_cells(d, cs, threads);
  };
  auto largest = [](const Layout& l) {
    double m = 0.0;
    for (const Cell& c : l.cells) m = std::max(m, c.size);
    return m;
  };
  long tally[4] = {0, 0, 0, 0};
  // (1) His back plate: 6 mm behind the face under 8 mm cubes, with one boss 12 mm thick (x 32..40) where a column
  // of 8 mm cubes stands whole: those 8 cubes are 8 mm cells; the rest of the plate is cut down to 4 mm (C20).
  const std::vector<std::array<double, 2>> plate = {{0, 0}, {64, 0}, {64, 6}, {40, 6}, {40, 12}, {32, 12}, {32, 6}, {0, 6}};
  for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
    const Layout l = lay_part(plate, algo, 8, 0, true);
    int large = 0, other = 0;
    for (const Cell& c : l.cells) {
      if (c.size == 8.0) ++large;
      else if (std::fabs(c.size - 4.0) > 1e-9) ++other;
    }
    CHECK(!l.cells.empty() && l.solid.empty() && largest(l) == 8.0);      // the boss's whole 8 mm cubes are laid
    // Halves (a ladder of two sizes here, 8 and 4): the boss's 8 cubes are 8 mm cells, every other cell 4 mm.
    // (Stepped packs the plate's cubes from one unit of their own, C6c.)
    CHECK(large == 8);
    if (algo == Algorithm::DefaultGrade) CHECK(other == 0);
    CHECK(lay_part(plate, algo, 8, 1, true).cells == l.cells && lay_part(plate, algo, 8, 3, true).cells == l.cells);
    tally[0] += static_cast<long>(l.cells.size());
  }
  {  // A ladder of one size: nothing changes, the 8 mm cells stand, cut by the plate's far side.
    const Layout l = lay_part(plate, Algorithm::Uniform, 8, 0, true);
    int other = 0;
    for (const Cell& c : l.cells) other += std::fabs(c.size - 8.0) > 1e-9;
    CHECK(!l.cells.empty() && other == 0);
  }
  {  // Off: the count is not made; the boss's own cells are as wall by wall lays them.
    const Layout off = lay_part(plate, Algorithm::DefaultGrade, 8, 0, false);
    CHECK(largest(off) == 8.0);
  }
  // (2) A block 24 deep, mostly thick, with one slot from the back down to 5 mm behind the face (x 28..36): it cuts 2 of
  // the 8 columns of 8 mm cubes under the face, so the main size stays 8 mm. Large cells stand; the smallest line the
  // slot (C20 unchanged).
  const std::vector<std::array<double, 2>> slot = {{0, 0}, {64, 0}, {64, 24}, {36, 24}, {36, 5}, {28, 5}, {28, 24}, {0, 24}};
  {
    PartMeasure pm(weld_mesh(prism(slot, 0, 64)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {32, 0, 32}, {0, 1, 0}, 32, 32, 8)};
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::DefaultGrade;
    cs.cell_max_mm = 8;
    cs.one_grid = true;
    const Layout l = lay_cells(d, cs);
    int large = 0, small = 0;
    for (const Cell& c : l.cells) (c.size == 8.0 ? large : small) += 1;
    CHECK(largest(l) == 8.0 && large == 6 * 8 && small > 0 && l.solid.empty());
    const C20 r = c20_count(d, l, 4.0);
    CHECK(r.cut_large == 0 && r.large_not_whole == 0 && r.off_grid == 0);
    CHECK(lay_cells(d, cs, 1).cells == l.cells && lay_cells(d, cs, 3).cells == l.cells);
    tally[1] = large, tally[2] = small;
  }
  // (3) 5 mm behind the face for x < 32, 24 mm for x > 32 (4 of the 8 columns of 8 mm cubes whole), and the same with the
  // step at x = 24 (5 of 8 whole): both lay 8 mm cells where they are whole.
  for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
    const Layout half = lay_part({{0, 0}, {64, 0}, {64, 24}, {32, 24}, {32, 5}, {0, 5}}, algo, 8, 0, true);
    const Layout more = lay_part({{0, 0}, {64, 0}, {64, 24}, {24, 24}, {24, 5}, {0, 5}}, algo, 8, 0, true);
    CHECK(largest(half) == 8.0 && largest(more) == 8.0);
    tally[3] += static_cast<long>(half.cells.size());
  }
  std::printf("no main size: a 6 mm plate with a boss is %ld cells (halves and Stepped); a slotted block keeps %ld "
              "cells of 8 mm and %ld smaller; half the columns whole: %ld cells\n", tally[0], tally[1], tally[2], tally[3]);
}

static void test_one_grid() {
  // The cell of `region` that holds p, or -1; `n`, when given, receives how many do.
  auto holder = [](const Domain& d, const Layout& l, const Vec3& p, int* n = nullptr) {
    auto pr = d.probe();
    int found = -1, count = 0;
    for (std::size_t i = 0; i < l.cells.size(); ++i)
      if (cell_holds(l, pr, l.cells[i], p)) { if (found < 0) found = static_cast<int>(i); ++count; }
    if (n) *n = count;
    return found;
  };
  auto c20 = c20_count;
  long tally[6] = {0, 0, 0, 0, 0, 0};
  {  // ONE cell size across a step in the wall. Behind the y = 0 face the material is 12 mm for x < 30 and 6 mm
     // for x > 30. Today: 12 mm cells in the one wall, 6 mm cells in the other, each wall its own cells. One grid:
     // 12 mm cells right across, the one over the step holding both walls, the ones past it cut by the far surface.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 6}, {30, 6}, {30, 12}, {0, 12}}, 0, 60)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 30}, {0, 1, 0}, 30, 30, 12)};   // the whole face, 60 x 60
    Domain d(pm, s);
    const Vec3 thick{27, 3, 20}, thin{33, 3, 20};   // either side of the step, 3 mm apart
    for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec off;
      off.algorithm = algo;
      off.cell_max_mm = 12;
      const Layout before = lay_cells(d, off);
      const int a0 = holder(d, before, thick), b0 = holder(d, before, thin);
      CHECK(a0 >= 0 && b0 >= 0 && a0 != b0);
      if (a0 >= 0 && b0 >= 0) {
        NEAR(before.cells[a0].size, 12.0, 1e-9);                    // C2: each wall its own cell
        NEAR(before.cells[b0].size, 6.0, 1e-9);
        CHECK(before.cells[a0].wall >= 0 && before.cells[b0].wall >= 0 && before.cells[a0].wall != before.cells[b0].wall);
      }
      CHECK(before.walls.size() == 1 && before.walls[0].flat && before.walls[0].walls.size() == 2);
      CellSpec on = off;
      on.one_grid = true;
      const Layout l = lay_cells(d, on);
      CHECK(!l.cells.empty() && l.solid.empty());
      CHECK(l.walls.size() == 1 && !l.walls[0].flat && l.walls[0].walls.empty());   // no wall map
      NEAR(l.regions[0].base_cell_mm, 12.0, 1e-9);
      int other = 0, off_face = 0, cut = 0, whole = 0;
      for (const Cell& c : l.cells) {
        if (std::fabs(c.size - 12.0) > 1e-9 || c.wall != -1 || c.region != 1) ++other;
        if (std::fabs(c.lo[2]) > 1e-9) ++off_face;                  // C15: the face is a cell boundary; one layer
        (c.cut ? cut : whole) += 1;
      }
      // C20: with a ladder of more than one size, the cells the step and the far surface cut are split down to the
      // smallest; a 12 mm cell stands only where it is whole. A ladder of one size (Uniform) is what it was.
      double smallest = 12.0;
      for (const Cell& c : l.cells) smallest = std::min(smallest, c.size);
      if (algo == Algorithm::Uniform) {
        CHECK(other == 0 && off_face == 0);
        CHECK(l.cells.size() == 5 * 5);                            // 60 / 12 each way, one layer
        CHECK(whole == 2 * 5 && cut == 3 * 5);                     // whole: only x < 24; the rest are cut cells
      } else {
        const C20 r = c20(d, l, smallest);
        CHECK(r.cut_large == 0 && r.large_not_whole == 0 && r.off_grid == 0);
        int not_mine = 0, base_whole = 0;
        for (const Cell& c : l.cells) {
          if (c.wall != -1 || c.region != 1) ++not_mine;
          if (std::fabs(c.size - 12.0) < 1e-9 && !c.cut) ++base_whole;
        }
        CHECK(not_mine == 0 && smallest < 12.0 - 1e-9);
        // C21 withdrawn: the 2 of the 5 columns of 12 mm cubes under the face that are whole (x < 24) are 12 mm cells;
        // beyond them every 6 mm cube under the face is one whole 6 mm cell.
        double largest = 0.0;
        int six_whole = 0;
        for (const Cell& c : l.cells) {
          largest = std::max(largest, c.size);
          if (std::fabs(c.size - 6.0) < 1e-9 && !c.cut && c.lo[2] == l.cells.front().lo[2]) ++six_whole;
        }
        CHECK(base_whole == 2 * 5 && largest == 12.0 && six_whole == 6 * 10);
      }
      int n = 0;
      const int a1 = holder(d, l, thick, &n);
      CHECK(a1 >= 0 && n == 1);
      const int b1 = holder(d, l, thin, &n);
      CHECK(b1 >= 0 && n == 1);
      if (algo == Algorithm::Uniform) {
        CHECK(a1 == b1);                                           // ONE cell holds both sides of the step
        if (a1 >= 0) { CHECK(l.cells[a1].cut); NEAR(cell_centre(l, l.cells[a1]).x, 30.0, 1e-9); }   // astride the step
      } else {
        CHECK(a1 != b1);                                           // C20: the step is cut by the smallest cells only
        int astride = 0;
        for (const Cell& c : l.cells)
          if (!c.finest && std::fabs(cell_centre(l, c).x - 30.0) < 0.5 * c.size - 1e-9) ++astride;
        CHECK(astride == 0);
      }
      CHECK(badly_covered(d, l, {0, 0, 0}, {60, 12, 60}, 1.3) == 0);   // never held twice, nothing left out
      // D18: the same on every run and for any number of threads.
      const Layout again = lay_cells(d, on), one = lay_cells(d, on, 1), three = lay_cells(d, on, 3);
      CHECK(l.cells == again.cells && l.cells == one.cells && l.cells == three.cells);
      CHECK(l.solid == one.solid && l.regions[0].cells == one.regions[0].cells);
      // The cells a wall must hold are not counted with the switch on: 1, 2 or 5 across, the same layout.
      for (int across : {2, 5}) {
        CellSpec k = on;
        k.min_cells_across = across;
        CHECK(lay_cells(d, k).cells == l.cells);
      }
      // Off is the layout as it was: asked again after the one grid was laid in the same domain, the same bytes.
      const Layout back = lay_cells(d, off);
      CHECK(back.cells == before.cells && back.solid == before.solid);
      tally[0] += static_cast<long>(l.cells.size());
      tally[1] += static_cast<long>(before.cells.size());
    }
  }
  {  // A wall thinner than any cell that prints holds cut cells instead of going solid. The same part with 2 mm
     // behind the face for x > 30 (the smallest cell at a 0.45 mm line is 2.37 mm), a region 9 mm deep.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2}, {30, 2}, {30, 12}, {0, 12}}, 0, 60)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 30}, {0, 1, 0}, 30, 30, 9)};
    Domain d(pm, s);
    auto pr = d.probe();
    const Vec3 thin{45, 1, 20};
    CHECK(pr.where(thin) == (Where{Why::Lattice, 1}));
    for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec off;
      off.algorithm = algo;
      off.cell_max_mm = 9;
      const Layout before = lay_cells(d, off);
      CHECK(holder(d, before, thin) < 0);                          // D8: today the thin wall is solid
      int thin_cells = 0;
      for (const Cell& c : before.cells) if (cell_centre(before, c).x > 30.5) ++thin_cells;
      CHECK(thin_cells == 0 && !before.solid.empty());
      CellSpec on = off;
      on.one_grid = true;
      const Layout l = lay_cells(d, on);
      int n = 0;
      const int at = holder(d, l, thin, &n);
      CHECK(at >= 0 && n == 1);
      // C20: a ladder of one size (Uniform) holds the thin wall in cut 9 mm cells, as before; a longer ladder holds it
      // in its smallest cells, cut by the wall's far side, never refused (nothing solid).
      if (algo == Algorithm::Uniform) {
        if (at >= 0) { NEAR(l.cells[at].size, 9.0, 1e-9); CHECK(l.cells[at].cut); }
        int other = 0;
        for (const Cell& c : l.cells) if (std::fabs(c.size - 9.0) > 1e-9) ++other;
        CHECK(other == 0 && l.solid.empty());
      } else {
        if (at >= 0) CHECK(l.cells[at].cut && l.cells[at].finest && l.cells[at].size < 9.0 - 1e-9);
        double smallest = 9.0;
        for (const Cell& c : l.cells) smallest = std::min(smallest, c.size);
        const C20 r = c20(d, l, smallest);
        CHECK(r.cut_large == 0 && r.large_not_whole == 0 && r.off_grid == 0 && l.solid.empty());
      }
      CHECK(badly_covered(d, l, {0, 0, 0}, {60, 12, 60}, 1.3) == 0);
      // Its struts: pieces of the 9 mm cell's own struts, cut by the wall's far side and landing on nothing loose.
      if (algo == Algorithm::Uniform) {
        Layout with = l;
        set_struts(with, StrutSpec{});
        const Bars bars = lay_bars(with, d);
        int in_thin = 0, outside = 0;
        for (const Bar& b : bars.bars) {
          const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
          if (m.x > 31 && m.y < 2.0 + 1e-6) ++in_thin;
          if (pr.part().depth(b.a) < -1e-6 || pr.part().depth(b.b) < -1e-6) ++outside;
        }
        CHECK(in_thin > 50 && outside == 0);
        tally[2] += in_thin;
        tally[3] += static_cast<long>(bars.stubs);
      }
    }
  }
  {  // Grade to shape with one grid: the cells step down toward the region's own outline (G1-G3, G10) and the
     // base cell is what stands away from it, across the step in the wall as well. A 96 x 96 face, 12 mm behind it
     // for x < 42 and 6 mm for x > 42 (the middle of a base cell), band 12.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {96, 0}, {96, 6}, {42, 6}, {42, 12}, {0, 12}}, 0, 96)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {48, 0, 48}, {0, 1, 0}, 48, 48, 12)};
    Domain d(pm, s);
    const double band = 12.0;
    auto edge = [](const Vec3& m) { return std::max(0.0, std::min(std::min(m.x, 96 - m.x), std::min(m.z, 96 - m.z))); };
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec on;
      on.algorithm = algo;
      on.cell_max_mm = 12;
      on.grade_to_shape = true;
      on.band_mm = band;
      on.one_grid = true;
      const Layout l = lay_cells(d, on);
      CHECK(l.solid.empty());                                       // G6: the band makes nothing solid
      CHECK(badly_covered(d, l, {0, 0, 0}, {96, 12, 96}, 1.9) == 0);
      double f = 12.0;
      for (const Cell& c : l.cells) f = std::min(f, c.size);
      // The smallest cell each ladder allows at a 0.45 mm line (floor 2.37 mm): halves stop at 3, fifths at 2.4.
      const double finest = algo == Algorithm::DefaultGrade ? 3.0 : 12.0 / 5.0;
      if (algo == Algorithm::DefaultGrade) NEAR(f, finest, 1e-9);
      CHECK(f >= finest - 1e-9 && f >= l.floor_cell_mm && f < 12.0 - 1e-9);   // never under the layout's floor
      int breaks_rule = 0, large_cut = 0, at_edge = 0, at_edge_large = 0, small_inside = 0;
      std::map<long, double> inner, all;   // size (microns) -> the cubes' volume: beyond the band, everywhere
      // C20: the base grid's corner (the frame's lowest cell corner), the base cube holding a cell, and the smallest
      // cell at the outline in each base cube (Stepped packs each cube from its own unit; C20 makes it finer where
      // the step or the thin wall's far side cuts the cube).
      double o[3] = {1e300, 1e300, 1e300};
      for (const Cell& c : l.cells) for (int k = 0; k < 3; ++k) o[k] = std::min(o[k], c.lo[k]);
      // C21 withdrawn (the owner, 2026-11-14): the 24 of the 64 12 mm cubes under the face that are whole (x < 36) are
      // base cells, however few; M below is the base cell.
      const double M = 12.0;
      auto parent_whole = [&](const Layout& lay, const Cell& c) {
        double p[3];
        for (int k = 0; k < 3; ++k) p[k] = o[k] + M * std::floor((c.lo[k] - o[k]) / M + 1e-9);
        return whole_cube(d, lay, c.frame, p, M);
      };
      // Every main-size cube under the face whose centre is at least `from` inside the outline and that is whole in
      // lattice is ONE cell of the main size (C1, G2, C20, C21): how many such cubes, and how many are not one cell.
      auto base_where_whole = [&](const Layout& lay, double from, int* whole_cubes, int* not_one_cell) {
        *whole_cubes = 0, *not_one_cell = 0;
        const int n = static_cast<int>(std::lround(96.0 / M));
        for (int j = 0; j < n; ++j)
          for (int i = 0; i < n; ++i) {
            const double p[3] = {o[0] + M * i, o[1] + M * j, o[2]};
            const double ci = M * i + 0.5 * M, cj = M * j + 0.5 * M;
            if (std::min(std::min(ci, 96 - ci), std::min(cj, 96 - cj)) < from - 1e-9) continue;
            if (!whole_cube(d, lay, lay.cells.front().frame, p, M)) continue;
            ++*whole_cubes;
            bool one = false;
            for (const Cell& c : lay.cells)
              one = one || (c.size == M && c.lo[0] == p[0] && c.lo[1] == p[1] && c.lo[2] == p[2]);
            if (!one) ++*not_one_cell;
          }
      };
      auto parent_key = [&](const Cell& c) {
        long key = 0;
        for (int k = 0; k < 3; ++k) key = key * 64 + std::lround(std::floor((c.lo[k] - o[k]) / 12.0 + 1e-9));
        return key;
      };
      std::map<long, double> f_cube;   // base cube -> the smallest cell at the outline in it
      for (const Cell& c : l.cells) {
        if (edge(cell_centre(l, c)) > 0.5 * c.size + 1e-9) continue;
        auto it = f_cube.find(parent_key(c));
        if (it == f_cube.end()) f_cube[parent_key(c)] = c.size; else it->second = std::min(it->second, c.size);
      }
      for (const Cell& c : l.cells) {
        const Vec3 m = cell_centre(l, c);
        const double dist = edge(m), h = 0.5 * c.size;
        if (c.size > finest * (1 + 1e-9) && dist < band * (c.size - finest) / (12.0 - finest) - 1e-6) ++breaks_rule;
        if (c.size > finest * (1 + 1e-9) &&
            (m.x - h < -1e-6 || m.x + h > 96 + 1e-6 || m.z - h < -1e-6 || m.z + h > 96 + 1e-6)) ++large_cut;
        if (dist <= h + 1e-9) { ++at_edge; if (c.size > f_cube[parent_key(c)] + 1e-9) ++at_edge_large; }
        if (dist >= band + 0.5 * (M - c.size) && std::fabs(c.size - M) > 1e-9 && parent_whole(l, c)) ++small_inside;
        all[std::lround(c.size * 1e3)] += c.size * c.size * c.size;
        if (dist >= band) inner[std::lround(c.size * 1e3)] += c.size * c.size * c.size;
      }
      CHECK(breaks_rule == 0);          // G1: a larger cell only where its centre is far enough in
      CHECK(large_cut == 0);            // G10: only the finest crosses the outline
      CHECK(at_edge > 50 && at_edge_large == 0);   // G3: the cells at the outline are the smallest (of each base cube)
      CHECK(small_inside == 0);         // G2: beyond the band, the region's own cell wherever it is whole (C20)
      {
        const C20 r = c20(d, l, f);
        CHECK(r.cut_large == 0 && r.large_not_whole == 0);          // C20: only the smallest is cut
      CHECK(all.size() >= 2 && all.rbegin()->first == 12000);  // it steps, and the whole base cubes are base cells
      }
      // Away from the outline, every base cube that is whole is one base cell (of the 6 x 6 whose centres are a band
      // inside, those the step and the thin wall's far side do not cut).
      int whole_inner = 0, split_inner = 0;
      base_where_whole(l, band + 6.0, &whole_inner, &split_inner);
      CHECK(whole_inner > 0 && split_inner == 0);
      // ... and across the step in the wall, well inside the band: C20 splits the base cube the step cuts, so the two
      // sides are two smaller cells, neither of them cut.
      int n = 0;
      const int a = holder(d, l, {40, 3, 30}, &n);
      CHECK(a >= 0 && n == 1);
      const int b = holder(d, l, {44, 3, 30}, &n);
      CHECK(b >= 0 && n == 1 && a != b);
      if (a >= 0 && b >= 0)
        CHECK(l.cells[a].size < 12.0 - 1e-9 && l.cells[b].size < 12.0 - 1e-9 && !l.cells[a].cut && !l.cells[b].cut);
      const Layout one = lay_cells(d, on, 1);
      CHECK(l.cells == one.cells && l.solid == one.solid);          // D18, on one thread
      // With the band off: the base cell everywhere.
      CellSpec flat = on;
      flat.grade_to_shape = false;
      const Layout plain = lay_cells(d, flat);
      int not_base = 0;
      for (const Cell& c : plain.cells) if (std::fabs(c.size - 12.0) > 1e-9) ++not_base;
      // C20: the base cell wherever its cube is whole; the cubes the step and the thin wall's far side cut are split,
      // only the smallest cut, nothing refused.
      int whole_all = 0, split_all = 0;
      base_where_whole(plain, 0.0, &whole_all, &split_all);
      const C20 rp = c20(d, plain, 12.0);
      CHECK(whole_all > 0 && split_all == 0 && not_base > 0 && plain.solid.empty());
      CHECK(rp.cut_large == 0 && rp.large_not_whole == 0);
      tally[4] += static_cast<long>(l.cells.size());
    }
  }
  {  // A Protect skin cuts the grid like any other surface: the cells start AT the face (not behind the skin, as
     // they do wall by wall: D5), and no cell holds a point of the skin. A 12 mm slab, the face protected 1.2 mm.
    TriangleMesh quad;
    quad.vertices = {{0, 0, 20}, {40, 0, 20}, {40, 40, 20}, {0, 40, 20}};
    quad.triangles = {{0, 1, 2}, {0, 2, 3}};
    PartMeasure pm(weld_mesh(box(40, 40, 20)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {20, 20, 20}, {0, 0, -1}, 20, 20, 12)};
    s.protect = {{7, quad, 1.2}};
    Domain d(pm, s);
    CellSpec on;
    on.algorithm = Algorithm::Uniform;
    on.cell_max_mm = 8;
    const Layout before = lay_cells(d, on);
    on.one_grid = true;
    const Layout l = lay_cells(d, on);
    double first0 = 1e300, first1 = 1e300;
    for (const Cell& c : before.cells) first0 = std::min(first0, c.lo[2]);
    int top_whole = 0, under_whole = 0;
    for (const Cell& c : l.cells) {
      first1 = std::min(first1, c.lo[2]);
      NEAR(c.size, 6.0, 1e-9);
      if (!c.cut) (c.lo[2] < 1.0 ? top_whole : under_whole) += 1;
    }
    CHECK(top_whole == 0 && under_whole == 5 * 5);                // the skin cuts every cell of the top layer
    NEAR(first0, 1.2, 1e-5);
    NEAR(first1, 0.0, 1e-9);
    CHECK(l.cells.size() == 7 * 7 * 2 && l.solid.empty());
    int n = 0;
    CHECK(holder(d, l, {20.3, 20.3, 19.4}, &n) < 0 && n == 0);     // in the skin: solid, in no cell
    CHECK(holder(d, l, {20.3, 20.3, 18.6}, &n) >= 0 && n == 1);    // just behind it: lattice, in one
    CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 20}, 1.7) == 0);
  }
  {  // The whole part, and it applies there the same way: a 2 mm plate, All lattice, 8 mm cells. Today nothing fits
     // and the plate is solid; with one grid it is 8 mm cells cut by both faces.
    PartMeasure pm(weld_mesh(box(40, 40, 2)));
    DomainSpec s;
    s.start = Start::AllLattice;
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_mm = 8;
    const Layout before = lay_cells(d, cs);
    CHECK(before.cells.empty() && !before.solid.empty());
    cs.one_grid = true;
    const Layout l = lay_cells(d, cs);
    int odd = 0;
    for (const Cell& c : l.cells) if (std::fabs(c.size - 8.0) > 1e-9 || !c.cut || c.region != 0) ++odd;
    CHECK(l.cells.size() == 5 * 5 && odd == 0 && l.solid.empty());
    CHECK(badly_covered(d, l, {0, 0, 0}, {40, 40, 2}, 0.9) == 0);
    CHECK(lay_cells(d, cs, 1).cells == l.cells);
    tally[5] += static_cast<long>(l.cells.size());
  }
  std::printf("one grid: a 12 | 6 mm wall is %ld cells, 12 mm where whole (wall by wall: %ld cells of 12 and 6); a 2 mm wall holds %ld "
              "strut pieces (%ld stubs left out); with a band %ld cells; a 2 mm plate, all lattice, %ld cut cells\n",
              tally[0] / 3, tally[1] / 3, tally[2], tally[3], tally[4], tally[5]);
}

// D14c (his ruling 2026-11-14: "a simple explanation of why it doesn't work and one to three ways to fix it"). Every
// cube recorded solid carries why, and the two sizes; SolidAt::why gives it for a point. Each case below makes one
// reason happen on a small part, and then shows that the fix the reason points to lays cells there.
static bool same_why(const Layout& a, const Layout& b) {
  if (a.solid_why.size() != b.solid_why.size()) return false;
  for (std::size_t i = 0; i < a.solid_why.size(); ++i)
    if (a.solid_why[i].why != b.solid_why[i].why || a.solid_why[i].have_mm != b.solid_why[i].have_mm ||
        a.solid_why[i].need_mm != b.solid_why[i].need_mm)
      return false;
  return true;
}
static void test_solid_why() {
  // What a point gets: is it solid where lattice was asked, and why.
  auto ask = [](const Domain& d, const Layout& l, const Vec3& p, SolidWhy* why) {
    auto pr = d.probe();
    const SolidAt at(l);
    CHECK(l.solid_why.size() == l.solid.size());                    // one reason per solid cube
    *why = at.why(pr, p);
    return pr.where(p).lattice() && at(pr, p);
  };
  int fixed = 0;
  {  // WallNarrow: behind the face 12 mm for x < 30 and 2 mm for x > 30, a region 9 mm deep. The 2 mm wall is
     // narrower than the smallest cell (2.37 mm at a 0.45 mm line).
    auto part = [](double thin) {
      return PartMeasure(weld_mesh(prism({{0, 0}, {60, 0}, {60, thin}, {30, thin}, {30, 12}, {0, 12}}, 0, 60)));
    };
    const PartMeasure pm = part(2.0);
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 30}, {0, 1, 0}, 30, 30, 9)};
    Domain d(pm, s);
    const Vec3 p{45, 1, 20};
    for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec cs;
      cs.algorithm = algo;
      cs.cell_max_mm = 9;
      const Layout l = lay_cells(d, cs);
      SolidWhy w;
      CHECK(ask(d, l, p, &w));
      CHECK(w.why == NoCell::WallNarrow);
      NEAR(w.have_mm, 2.0, 1e-3);
      CHECK(w.have_mm < w.need_mm && w.need_mm >= l.floor_cell_mm);
      std::printf("solid why, wall narrow (algorithm %d): have %.3f, need %.3f\n", static_cast<int>(algo), w.have_mm, w.need_mm);
      // D18: the same reasons on one thread and on three.
      CHECK(same_why(l, lay_cells(d, cs, 1)) && same_why(l, lay_cells(d, cs, 3)));
      // Fix 1: Let walls cut cells.
      CellSpec on = cs;
      on.one_grid = true;
      CHECK(!ask(d, lay_cells(d, on), p, &w));
      // Fix 2: the wall made `need` wide (w is the one-grid point's answer now: ask the first layout again).
      SolidWhy before;
      ask(d, l, p, &before);
      const PartMeasure wider = part(before.need_mm);
      Domain d2(wider, s);
      SolidWhy after;
      const bool still = ask(d2, lay_cells(d2, cs), {45, 0.5 * before.need_mm, 20}, &after);
      CHECK(!still);
      fixed += !still;
    }
  }
  {  // TooFewAcross: a 6 mm plate, all lattice, 4 mm cells, two across. A 4 mm cell fits the plate, two of them do not.
    PartMeasure pm(weld_mesh(box(40, 40, 6)));
    DomainSpec s;
    s.start = Start::AllLattice;
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_mm = 4;
    cs.min_cells_across = 2;
    const Layout l = lay_cells(d, cs);
    const Vec3 p{20, 20, 3};
    SolidWhy w;
    CHECK(ask(d, l, p, &w));
    CHECK(w.why == NoCell::TooFewAcross);
    NEAR(w.have_mm, 6.0, 1e-3);
    NEAR(w.need_mm, 8.0, 1e-3);                                       // two cells of 4
    CHECK(w.have_mm < w.need_mm);
    CHECK(same_why(l, lay_cells(d, cs, 1)));
    std::printf("solid why, too few across: have %.3f, need %.3f\n", w.have_mm, w.need_mm);
    CellSpec one = cs;                                                // Fix 1: single-cell walls
    one.min_cells_across = 1;
    const bool a = ask(d, lay_cells(d, one), p, &w);
    CellSpec on = cs;                                                 // Fix 2: Let walls cut cells
    on.one_grid = true;
    const bool b = ask(d, lay_cells(d, on), p, &w);
    CHECK(!a && !b);
    fixed += !a + !b;
  }
  {  // RegionShallow: a region 1.5 mm deep, under the smallest cell (2.37 mm).
    PartMeasure pm(weld_mesh(box(40, 40, 20)));
    auto domain_spec = [](double depth) {
      DomainSpec s;
      s.regions = {face_region(1, Role::Lattice, {20, 20, 20}, {0, 0, -1}, 20, 20, depth)};
      return s;
    };
    Domain d(pm, domain_spec(1.5));
    for (Algorithm algo : {Algorithm::Uniform, Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec cs;
      cs.algorithm = algo;
      const Layout l = lay_cells(d, cs);
      SolidWhy w;
      CHECK(ask(d, l, {20, 20, 19.3}, &w));
      CHECK(w.why == NoCell::RegionShallow);
      NEAR(w.have_mm, 1.5, 1e-3);
      NEAR(w.need_mm, l.floor_cell_mm, 1e-3);
      CHECK(w.have_mm < w.need_mm);
      CHECK(same_why(l, lay_cells(d, cs, 1)));
      std::printf("solid why, region shallow (algorithm %d): have %.3f, need %.3f\n", static_cast<int>(algo), w.have_mm, w.need_mm);
      // Fix: the region made `need` deep.
      Domain deeper(pm, domain_spec(w.need_mm));
      SolidWhy after;
      const bool still = ask(deeper, lay_cells(deeper, cs), {20, 20, 20 - 0.5 * w.need_mm}, &after);
      CHECK(!still);
      fixed += !still;
    }
  }
  {  // A point that is not solid where lattice was asked has no reason, and nor does the part's own solid.
    PartMeasure pm(weld_mesh(box(40, 40, 20)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {20, 20, 20}, {0, 0, -1}, 20, 20, 8)};
    Domain d(pm, s);
    const Layout l = lay_cells(d, CellSpec{});
    SolidWhy w;
    CHECK(!ask(d, l, {20, 20, 17}, &w) && w.why == NoCell::Other && w.need_mm == 0.0f);   // lattice, in a cell
    CHECK(ask(d, l, {20, 20, 5}, &w) == false && w.why == NoCell::Other);                // solid, not lattice
    CHECK(l.solid.empty() && l.solid_why.empty());
  }
  std::printf("solid why: %d fixes tried, each lays cells where the reason was\n", fixed);
}

// Install 2a, step 1: the stress result (R16, R17). Indexing as core's VoxelGrid; the highest value in a box reads
// exactly the voxels that share volume with it; the part's own reference is the percentile over its lattice space.
static void test_demand_field() {
  {  // Indexing and emptiness.
    DemandField f;
    CHECK(f.empty());
    f.nx = 5; f.ny = 4; f.nz = 3; f.spacing = 2.0;
    CHECK(f.empty());                       // no values
    f.mpa.assign(60, 0.0f);
    CHECK(!f.empty());
    f.spacing = 0.0;
    CHECK(f.empty());
    f.spacing = 2.0;
    f.mpa.push_back(1.0f);
    CHECK(f.empty());                       // one value too many
    f.mpa.pop_back();
    CHECK(f.index(0, 0, 0) == 0 && f.index(1, 0, 0) == 1 && f.index(0, 1, 0) == 5 && f.index(0, 0, 1) == 20);
    CHECK(f.index(4, 3, 2) == 59);
    CHECK(f.highest_in({-100, -100, -100}, {100, 100, 100}) == 0.0);   // all cold
  }
  {  // One hot voxel: exactly the boxes that share volume with it see it.
    DemandField f;
    f.origin = {1, 2, 3};
    f.spacing = 2.0;
    f.nx = 5; f.ny = 4; f.nz = 3;
    f.mpa.assign(60, 0.0f);
    f.mpa[f.index(2, 1, 1)] = 7.0f;
    const double vlo[3] = {5, 4, 5}, vhi[3] = {7, 6, 7};   // that voxel's cube
    int seen = 0, unseen = 0, wrong = 0;
    for (double x0 = -1.0; x0 <= 12.0; x0 += 1.0)
      for (double y0 = 0.0; y0 <= 11.0; y0 += 1.0)
        for (double z0 = 1.0; z0 <= 10.0; z0 += 1.5)
          for (double s : {0.5, 1.0, 2.0, 3.5}) {
            const double lo[3] = {x0, y0, z0}, hi[3] = {x0 + s, y0 + s * 0.5, z0 + s};
            bool overlap = true;
            for (int a = 0; a < 3; ++a) overlap = overlap && std::min(hi[a], vhi[a]) > std::max(lo[a], vlo[a]);
            const double got = f.highest_in({lo[0], lo[1], lo[2]}, {hi[0], hi[1], hi[2]});
            if (got != (overlap ? 7.0 : 0.0)) ++wrong;
            (overlap ? seen : unseen)++;
          }
    CHECK(wrong == 0);
    CHECK(seen > 50 && unseen > 500);
    // Touching the voxel on a face only is not overlapping it; a box with no width inside it is.
    CHECK(f.highest_in({7, 4, 5}, {9, 6, 7}) == 0.0);
    CHECK(f.highest_in({6.9, 4, 5}, {9, 6, 7}) == 7.0);
    CHECK(f.highest_in({6, 5, 6}, {6, 5, 6}) == 7.0);
    // A box outside the grid sees 0; one round the whole grid sees the hot voxel.
    CHECK(f.highest_in({20, 20, 20}, {30, 30, 30}) == 0.0);
    CHECK(f.highest_in({-9, -9, -9}, {1, 2, 3}) == 0.0);
    CHECK(f.highest_in({-100, -100, -100}, {100, 100, 100}) == 7.0);
  }
  {  // The highest of many: against reading every voxel.
    DemandField f;
    f.origin = {-3, 0, 0};
    f.spacing = 1.5;
    f.nx = 7; f.ny = 6; f.nz = 5;
    f.mpa.resize(210);
    for (std::size_t n = 0; n < f.mpa.size(); ++n) f.mpa[n] = static_cast<float>((n * 37) % 101);
    int wrong = 0;
    for (double x0 = -4.0; x0 < 8.0; x0 += 0.7)
      for (double y0 = -1.0; y0 < 9.0; y0 += 1.1) {
        const Vec3 lo{x0, y0, 1.2}, hi{x0 + 2.3, y0 + 1.9, 4.6};
        double want = 0.0;
        for (int k = 0; k < f.nz; ++k)
          for (int j = 0; j < f.ny; ++j)
            for (int i = 0; i < f.nx; ++i) {
              const double a0 = -3 + 1.5 * i, b0 = 1.5 * j, c0 = 1.5 * k;
              if (std::min(hi.x, a0 + 1.5) > std::max(lo.x, a0) && std::min(hi.y, b0 + 1.5) > std::max(lo.y, b0) &&
                  std::min(hi.z, c0 + 1.5) > std::max(lo.z, c0))
                want = std::max(want, static_cast<double>(f.mpa[f.index(i, j, k)]));
            }
        if (f.highest_in(lo, hi) != want) ++wrong;
      }
    CHECK(wrong == 0);
  }
  {  // R17: the part's own reference, a block with a known ramp. 40 x 40 x 20 mm, voxels of 2 mm: 4,000 voxels in
     // the part, 200 of each value 0 .. 19 (the value is the voxel's i). Sorted, 95% is index floor(0.95 x 3999) =
     // 3799, value 18. A ring of voxels outside the part, all at 1000 MPa, never counts.
    PartMeasure pm(weld_mesh(box(40, 40, 20)));
    DomainSpec s;
    s.start = Start::AllLattice;
    Domain d(pm, s);
    DemandField f;
    f.origin = {-2, -2, -2};
    f.spacing = 2.0;
    f.nx = 22; f.ny = 22; f.nz = 12;
    f.mpa.assign(static_cast<std::size_t>(22) * 22 * 12, 1000.0f);
    for (int k = 1; k <= 10; ++k)
      for (int j = 1; j <= 20; ++j)
        for (int i = 1; i <= 20; ++i) f.mpa[f.index(i, j, k)] = static_cast<float>(i - 1);
    NEAR(stress_reference(d, f, 0.95), 18.0, 0.0);
    NEAR(stress_reference(d, f, 0.95, 1), 18.0, 0.0);   // the same for any number of threads
    NEAR(stress_reference(d, f, 0.0), 0.0, 0.0);
    NEAR(stress_reference(d, f, 1.0), 19.0, 0.0);
    NEAR(stress_reference(d, f, 0.5), 9.0, 0.0);         // index 1999: value 9
    // Nothing is lattice: 0. An empty field: 0.
    Domain none(pm, {});
    NEAR(stress_reference(none, f, 0.95), 0.0, 0.0);
    NEAR(stress_reference(d, DemandField{}, 0.95), 0.0, 0.0);
    // Only lattice space counts: a No lattice region over x < 20 leaves the values 10 .. 19 (2,000 voxels; zero-
    // valued voxels count where they are lattice, and here there are none). 95%: index 1899, value 19.
    DomainSpec half = s;
    half.regions.push_back(face_region(2, Role::NoLattice, {0, 20, 10}, {1, 0, 0}, 20, 20, 20));
    Domain dh(pm, half);
    NEAR(stress_reference(dh, f, 0.95), 19.0, 0.0);
    NEAR(stress_reference(dh, f, 0.0), 10.0, 0.0);
  }
}

// The axis-aligned box round a cell's cube (R16).
static void cell_box(const Layout& l, const Cell& c, Vec3* lo, Vec3* hi) {
  const Frame& fr = l.frames[static_cast<std::size_t>(c.frame)];
  for (int k = 0; k < 8; ++k) {
    const Vec3 p = fr.at(c.lo[0] + ((k & 1) ? c.size : 0.0), c.lo[1] + ((k & 2) ? c.size : 0.0),
                         c.lo[2] + ((k & 4) ? c.size : 0.0));
    if (k == 0) { *lo = *hi = p; continue; }
    *lo = {std::min(lo->x, p.x), std::min(lo->y, p.y), std::min(lo->z, p.z)};
    *hi = {std::max(hi->x, p.x), std::max(hi->y, p.y), std::max(hi->z, p.z)};
  }
}
// A field of 1 mm voxels over [0, nx] x [0, ny] x [0, nz], every voxel `value(i, j, k)`.
template <class F>
static std::shared_ptr<DemandField> field_of(int nx, int ny, int nz, F value, Vec3 origin = {0, 0, 0}) {
  auto f = std::make_shared<DemandField>();
  f->origin = origin;
  f->spacing = 1.0;
  f->nx = nx; f->ny = ny; f->nz = nz;
  f->mpa.resize(static_cast<std::size_t>(nx) * ny * nz);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) f->mpa[f->index(i, j, k)] = static_cast<float>(value(i, j, k));
  return f;
}

// Install 2a, steps 2 and 4: By stress in set_struts (R7, R8, R12, R16, R17, R18; 02-tests.md R7a to R18a).
static void test_by_stress() {
  // A slab 96 x 16 x 8 mm, all lattice, 4 mm cells. The stress ramps 0 -> 100 MPa along its length: 0 over the first
  // 4 mm, 100 over the last 4 mm, even steps between (by each voxel's middle).
  PartMeasure pm(weld_mesh(box(96, 16, 8)));
  DomainSpec ds;
  ds.start = Start::AllLattice;
  Domain dom(pm, ds);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_mm = 4.0;
  const Layout base = lay_cells(dom, cs);
  CHECK(base.cells.size() == 24 * 4 * 2);
  const auto ramp = field_of(96, 16, 8, [](int i, int, int) {
    return std::clamp((i + 0.5 - 4.0) / 88.0 * 100.0, 0.0, 100.0);
  });
  // The dial's strut / cell, as the Uniform mode reads it on the largest cell (R10).
  const auto ratio_of = [&](double dial) {
    Layout l = base;
    StrutSpec u;
    u.dial = dial;
    set_struts(l, u);
    return l.cells[0].strut / l.cells[0].size;
  };
  const double r2 = ratio_of(0.2), r8 = ratio_of(0.8);
  CHECK(r8 > r2 + 0.01);
  StrutSpec sp;
  sp.mode = Density::ByStress;
  sp.dial_light = 0.2;
  sp.dial_heavy = 0.8;
  sp.demand = ramp;
  sp.reference_mpa = 100.0;
  const auto f_of = [&](const Layout& l, const Cell& c, double ref) {
    Vec3 lo, hi;
    cell_box(l, c, &lo, &hi);
    return std::clamp(ramp->highest_in(lo, hi) / ref, 0.0, 1.0);
  };
  {  // 1. Along the ramp the strut / cell never falls; the 0 end is at dial 0.2, the 100 end at dial 0.8; every cell
     // matches the formula for its own highest voxel.
    Layout l = base;
    const StrutReport r = set_struts(l, sp);
    CHECK(!r.no_stress);
    NEAR(r.reference_mpa, 100.0, 0.0);
    NEAR(r.highest_mpa, 100.0, 1e-9);
    std::vector<std::pair<double, double>> along;   // (cell's middle x, strut / cell)
    int light = 0, heavy = 0, wrong = 0;
    for (const Cell& c : l.cells) {
      const double f = f_of(l, c, 100.0);
      const double want = (r2 + f * (r8 - r2)) * c.size;
      if (std::fabs(c.strut - want) > 1e-9) ++wrong;
      if (f == 0.0) { ++light; NEAR(c.strut, r2 * c.size, 1e-9); }
      if (f == 1.0) { ++heavy; NEAR(c.strut, r8 * c.size, 1e-9); }
      Vec3 lo, hi;
      cell_box(l, c, &lo, &hi);
      along.push_back({0.5 * (lo.x + hi.x), c.strut / c.size});
    }
    CHECK(wrong == 0);
    CHECK(light == 8 && heavy == 8);   // one column of 4 x 2 cells at each end
    CHECK(r.at_light == 8 && r.at_heavy == 8);
    std::sort(along.begin(), along.end());
    int falls = 0;
    for (std::size_t i = 1; i < along.size(); ++i)
      if (along[i].second < along[i - 1].second - 1e-12) ++falls;
    CHECK(falls == 0);
    CHECK(along.back().second > along.front().second + 0.01);
    // Ends given the wrong way round are swapped.
    Layout sw = base;
    StrutSpec s2 = sp;
    std::swap(s2.dial_light, s2.dial_heavy);
    set_struts(sw, s2);
    CHECK(sw.cells == l.cells);
  }
  {  // 2. Response 2 makes every in-between cell thinner than response 1 and leaves both ends alone.
    Layout one = base, two = base;
    set_struts(one, sp);
    StrutSpec s2 = sp;
    s2.response = 2.0;
    set_struts(two, s2);
    int between = 0, thinner = 0, ends_same = 0, ends = 0;
    for (std::size_t i = 0; i < one.cells.size(); ++i) {
      const double f = f_of(one, one.cells[i], 100.0);
      if (f > 0.0 && f < 1.0) { ++between; if (two.cells[i].strut < one.cells[i].strut - 1e-12) ++thinner; }
      else { ++ends; if (two.cells[i].strut == one.cells[i].strut) ++ends_same; }
    }
    CHECK(between > 100 && thinner == between);
    CHECK(ends == 16 && ends_same == ends);
    // The response is held to 0.25 .. 4.
    Layout big = base, four = base;
    s2.response = 40.0;
    set_struts(big, s2);
    s2.response = 4.0;
    set_struts(four, s2);
    CHECK(big.cells == four.cells);
  }
  {  // 4. One hot voxel: exactly the cells whose cube's box shares volume with it change. Every other voxel is 10 MPa.
     // The voxel [3.5, 4.5] x [3.5, 4.5] x [3.5, 4.5] straddles the corner of eight 4 mm cells.
    const Vec3 at{-0.5, -0.5, -0.5};
    const auto cold = field_of(98, 18, 10, [](int, int, int) { return 10.0; }, at);
    const auto hot = field_of(98, 18, 10, [](int i, int j, int k) { return i == 4 && j == 4 && k == 4 ? 90.0 : 10.0; }, at);
    StrutSpec s = sp;
    Layout a = base, b = base;
    s.demand = cold;
    set_struts(a, s);
    s.demand = hot;
    set_struts(b, s);
    int changed = 0, overlapping = 0, wrong = 0;
    for (std::size_t i = 0; i < a.cells.size(); ++i) {
      Vec3 lo, hi;
      cell_box(a, a.cells[i], &lo, &hi);
      const bool over = std::min(hi.x, 4.5) > std::max(lo.x, 3.5) && std::min(hi.y, 4.5) > std::max(lo.y, 3.5) &&
                        std::min(hi.z, 4.5) > std::max(lo.z, 3.5);
      const bool moved = a.cells[i].strut != b.cells[i].strut;
      if (over != moved) ++wrong;
      changed += moved;
      overlapping += over;
    }
    CHECK(wrong == 0);
    CHECK(overlapping == 8 && changed == 8);
  }
  {  // 5. No field (null or empty), or no reference: every cell at its light end, and the report says so (R18).
    for (int how = 0; how < 3; ++how) {
      StrutSpec s = sp;
      if (how == 0) s.demand = nullptr;
      if (how == 1) s.demand = std::make_shared<DemandField>();
      if (how == 2) s.reference_mpa = 0.0;
      Layout l = base;
      const StrutReport r = set_struts(l, s);
      CHECK(r.no_stress);
      CHECK(r.at_light == l.cells.size() && r.at_heavy == 0);
      for (const Cell& c : l.cells) NEAR(c.strut, r2 * c.size, 1e-9);
    }
    // Uniform and PerRegion read none of it: the same as with no stress settings at all, and the report is as before.
    for (Density m : {Density::Uniform, Density::PerRegion}) {
      StrutSpec plain;
      plain.mode = m;
      plain.dial = 0.6;
      plain.region_dial = {{0, 0.3}};
      StrutSpec withs = sp;
      withs.mode = m;
      withs.dial = 0.6;
      withs.region_dial = {{0, 0.3}};
      Layout x = base, y = base;
      const StrutReport rx = set_struts(x, plain), ry = set_struts(y, withs);
      CHECK(x.cells == y.cells);
      CHECK(!ry.no_stress && ry.reference_mpa == 0.0 && ry.highest_mpa == 0.0 && ry.at_light == 0 && ry.at_heavy == 0);
      CHECK(rx.at_bead == ry.at_bead && rx.at_ceiling == ry.at_ceiling);
    }
  }
  {  // 6. The cells of a ByStress layout equal the Uniform layout's in everything but the strut.
    Layout s = base, u = base;
    set_struts(s, sp);
    set_struts(u, StrutSpec{});
    int differ = 0;
    for (std::size_t i = 0; i < s.cells.size(); ++i) {
      Cell x = s.cells[i], y = u.cells[i];
      x.strut = y.strut = 0.0;
      if (!(x == y)) ++differ;
    }
    CHECK(differ == 0 && s.solid == u.solid);
  }
  {  // 7. Widths in mm: every strut lies between the two widths, the same in every cell size; the ends exact where the
     // cell can hold them, and the widest allowed where it cannot.
    StrutSpec s = sp;
    s.width_light_mm = 0.5;
    s.width_heavy_mm = 0.7;
    s.dial_light = 0.9;   // not read
    Layout l = base;
    set_struts(l, s);
    int outside = 0, wrong = 0;
    for (const Cell& c : l.cells) {
      if (c.strut < 0.5 - 1e-12 || c.strut > 0.7 + 1e-12) ++outside;
      const double f = f_of(l, c, 100.0);
      if (std::fabs(c.strut - (0.5 + f * 0.2)) > 1e-9) ++wrong;
    }
    CHECK(outside == 0 && wrong == 0);
    // Mixed cell sizes under one stress: one width in every cell that can hold it.
    const double bead = 0.45, open = 0.7592 / 4.0;
    Layout mixed = strut_layout(bead);
    s.demand = field_of(60, 4, 16, [](int, int, int) { return 50.0; }, {-1, -1, -1});
    s.width_light_mm = 1.6;   // the wrong way round: swapped
    s.width_heavy_mm = 0.6;
    const StrutReport r = set_struts(mixed, s);
    int held = 0;
    for (const Cell& c : mixed.cells) {
      const double top = std::max(bead, open * c.size);
      if (top >= 1.1) { NEAR(c.strut, 1.1, 1e-12); ++held; }
      else NEAR(c.strut, top, 1e-9);
    }
    CHECK(held == 4 && r.at_ceiling == 2);   // 12, 6, 6 and 8 mm hold 1.1 mm; 2.4 and 4 mm do not
    // The ends exact: all cold, all at the reference.
    s.demand = field_of(60, 4, 16, [](int, int, int) { return 0.0; }, {-1, -1, -1});
    set_struts(mixed, s);
    for (const Cell& c : mixed.cells) NEAR(c.strut, std::min(0.6, std::max(bead, open * c.size)), 1e-12);
    s.demand = field_of(60, 4, 16, [](int, int, int) { return 300.0; }, {-1, -1, -1});
    set_struts(mixed, s);
    for (const Cell& c : mixed.cells) NEAR(c.strut, std::min(1.6, std::max(bead, open * c.size)), 1e-9);
  }
  {  // 8. A band cell is never thinner than its by-stress width, and never past the open look without Allow quilt.
    const double bead = 0.45, open = 0.7592 / 4.0;
    Layout banded = strut_layout(bead);
    for (std::size_t i = 0; i < banded.cells.size(); ++i) {
      banded.cells[i].own = 12.0;
      banded.cells[i].band = i % 2 ? 0.3 : 1.0;
      banded.cells[i].finest = banded.cells[i].size < 3.0;
    }
    Layout flat = banded;
    for (Cell& c : flat.cells) c.band = 1.0;
    StrutSpec s = sp;
    const auto grad = field_of(60, 4, 16, [](int i, int, int) { return i * 2.0; }, {-1, -1, -1});
    s.demand = grad;
    // The dials' strut / cell on this layout's largest cell (12 mm), as Uniform reads them.
    const auto dial_ratio = [&](double dial) {
      Layout u = flat;
      StrutSpec us;
      us.dial = dial;
      set_struts(u, us);
      return u.cells[0].strut / 12.0;
    };
    const double lr = dial_ratio(0.2), hr = dial_ratio(0.8);
    for (bool mm : {false, true}) {
      s.width_light_mm = mm ? 0.5 : 0.0;
      s.width_heavy_mm = mm ? 1.0 : 0.0;
      Layout a = banded, b = flat;
      set_struts(a, s);
      set_struts(b, s);
      int thinner = 0, quilted = 0, raised = 0;
      for (std::size_t i = 0; i < a.cells.size(); ++i) {
        // The cell's by-stress width, from the formula.
        Vec3 lo, hi;
        cell_box(b, b.cells[i], &lo, &hi);
        const double f = std::clamp(grad->highest_in(lo, hi) / 100.0, 0.0, 1.0);
        const double top = std::max(bead, open * b.cells[i].size);
        const double by = std::clamp(mm ? 0.5 + f * 0.5 : (lr + f * (hr - lr)) * b.cells[i].size, bead, top);
        NEAR(b.cells[i].strut, by, 1e-9);
        if (a.cells[i].band >= 1.0) { CHECK(a.cells[i].strut == b.cells[i].strut); continue; }
        if (a.cells[i].strut < b.cells[i].strut - 1e-12) ++thinner;
        if (a.cells[i].strut > std::max(bead, open * a.cells[i].size) + 1e-9) ++quilted;
        if (a.cells[i].strut > b.cells[i].strut + 1e-12) ++raised;
      }
      CHECK(thinner == 0 && quilted == 0 && raised > 0);
    }
  }
  {  // 9. A typed width (R11) changes nothing under By stress (R12).
    Layout a = base, b = base;
    StrutSpec s = sp;
    set_struts(a, s);
    s.width_mm = 1.2;
    set_struts(b, s);
    CHECK(a.cells == b.cells);
  }
  {  // 11. Speed: 2,000 cells of 4 mm in a 64 mm cube, a 64^3 field of 1 mm voxels.
    Layout l;
    l.bead_mm = 0.45;
    l.frames.push_back(Frame{});
    for (int n = 0; n < 2000; ++n) {
      Cell c;
      c.size = 4.0;
      c.lo[0] = 4.0 * (n % 16);
      c.lo[1] = 4.0 * ((n / 16) % 16);
      c.lo[2] = 4.0 * (n / 256);
      l.cells.push_back(c);
    }
    StrutSpec s = sp;
    s.demand = field_of(64, 64, 64, [](int i, int j, int k) { return (i * 7 + j * 3 + k) % 120; }, {-0.5, -0.5, -0.5});
    double best = 1e9;
    for (int run = 0; run < 5; ++run) {
      Layout x = l;
      const auto t0 = std::chrono::steady_clock::now();
      set_struts(x, s);
      best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    }
    std::printf("by stress: set_struts on 2,000 cells with a 64^3 field: %.3f ms (best of 5)\n", best);
    CHECK(best < 5.0);
  }
}

// Install 2a, step 2: the session resolves the reference (R17) and keeps it while nothing it is made from changes.
static void test_by_stress_session() {
  int L = 0, square = 0, sideA = 0, sideB = 0;
  const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
  Session session(model);
  Settings st;
  st.start = Start::AllLattice;
  st.cells.algorithm = Algorithm::Uniform;
  st.cells.cell_mm = 5.0;
  st.bars = false;
  st.struts.mode = Density::ByStress;
  st.struts.dial_light = 0.2;
  st.struts.dial_heavy = 0.8;
  // A 60 x 60 x 10 plate; the stress rises with x and y: 0 .. 118 MPa.
  auto field = field_of(60, 60, 10, [](int i, int j, int) { return static_cast<double>(i + j); });
  st.stress.demand = field;
  // 3. Reference 0: the session's reference is the part's own.
  const Outcome own = session.lay(st);
  const double want = stress_reference(*session.domain(), *field, 0.95);
  CHECK(want > 50.0);
  NEAR(own.struts.reference_mpa, want, 0.0);
  CHECK(!own.struts.no_stress && own.struts.at_heavy > 0);
  // A stated reference half as large puts more cells at the heavy end.
  st.stress.reference_mpa = 0.5 * want;
  const Outcome half = session.lay(st);
  NEAR(half.struts.reference_mpa, 0.5 * want, 0.0);
  CHECK(half.struts.at_heavy > own.struts.at_heavy);
  // Kept: the same field (pointer) and percentile on the same domain are not read again. The field's values are
  // changed behind the session's back here only to show it; the reference stays.
  st.stress.reference_mpa = 0.0;
  for (float& v : field->mpa) v *= 2.0f;
  st.struts.dial_heavy = 0.9;   // a slider move
  NEAR(session.lay(st).struts.reference_mpa, want, 0.0);
  // A new field, a new percentile or a new domain: read again.
  st.stress.demand = std::make_shared<DemandField>(*field);
  NEAR(session.lay(st).struts.reference_mpa, 2.0 * want, 0.0);
  st.stress.percentile = 0.5;
  const double mid = stress_reference(*session.domain(), *field, 0.5);
  NEAR(session.lay(st).struts.reference_mpa, mid, 0.0);
  for (float& v : field->mpa) v *= 0.5f;   // the field the session now holds is a copy; this one is back to before
  st.stress.demand = field;
  st.min_wall_mm = 0.5;                    // a "where" setting: a new domain
  const Outcome again = session.lay(st);
  CHECK(again.read_again);
  NEAR(again.struts.reference_mpa, stress_reference(*session.domain(), *field, 0.5), 0.0);
  // The struts' own stress settings, set by a caller, are overwritten only when Settings::stress has a field.
  Settings direct = st;
  direct.stress = StressGrade{};
  direct.struts.demand = field;
  direct.struts.reference_mpa = 40.0;
  const Outcome d = session.lay(direct);
  NEAR(d.struts.reference_mpa, 40.0, 0.0);
  // No field anywhere: every strut at its light end, and the layout says so (R18).
  direct.struts.demand = nullptr;
  const Outcome none = session.lay(direct);
  CHECK(none.struts.no_stress && none.struts.at_light == none.layout.cells.size());
}

// ── C22: cell size by stress ──────────────────────────────────────────────────
// A made-up stress field over a box of voxels, each voxel's value from its centre.
template <class F>
static std::shared_ptr<DemandField> stress_field(Vec3 origin, double spacing, int nx, int ny, int nz, F value) {
  auto f = std::make_shared<DemandField>();
  f->origin = origin;
  f->spacing = spacing;
  f->nx = nx; f->ny = ny; f->nz = nz;
  f->mpa.resize(static_cast<std::size_t>(nx) * ny * nz);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i)
        f->mpa[f->index(i, j, k)] = static_cast<float>(value(Vec3{origin.x + (i + 0.5) * spacing,
                                                                  origin.y + (j + 0.5) * spacing,
                                                                  origin.z + (k + 0.5) * spacing}));
  return f;
}
// The highest stress in the axis-aligned box round a cube of the layout's frame (R16), read here on its own.
static double cube_demand(const Layout& l, int frame, const double lo[3], double s, const DemandField& f) {
  const Frame& fr = l.frames[static_cast<std::size_t>(frame)];
  Vec3 mn{1e300, 1e300, 1e300}, mx{-1e300, -1e300, -1e300};
  for (int k = 0; k < 8; ++k) {
    const Vec3 v = fr.at(lo[0] + ((k & 1) ? s : 0.0), lo[1] + ((k & 2) ? s : 0.0), lo[2] + ((k & 4) ? s : 0.0));
    mn = {std::min(mn.x, v.x), std::min(mn.y, v.y), std::min(mn.z, v.z)};
    mx = {std::max(mx.x, v.x), std::max(mx.y, v.y), std::max(mx.z, v.z)};
  }
  return f.highest_in(mn, mx);
}
// The sizes a pass of base cell `base` can lay, largest first, each once, read here from core's own menus: Default
// Grade its halves; Stepped the base and m x base / n for each admitted fraction n and m = 1 .. n - 1; Uniform the base.
static std::vector<double> ladder_of(const Layout& l, const CellSpec& c, double base) {
  const double tile_min = std::max(c.cell_min_mm, l.floor_cell_mm);
  std::vector<double> out;
  if (c.algorithm == Algorithm::DefaultGrade)
    out = stepped_size_menu(l.topology, base, l.min_strut_mm, tile_min, !c.allow_quilt, SteppedMenu::Halves);
  else
    out = {base};
  if (c.algorithm == Algorithm::Stepped)
    for (int n : stepped_admitted_divisors(l.topology, base, l.min_strut_mm, tile_min, !c.allow_quilt,
                                           SteppedMenu::AnyStep))
      for (int m = 1; m < n; ++m) out.push_back(m * (base / n));
  std::sort(out.begin(), out.end(), std::greater<double>());
  out.erase(std::unique(out.begin(), out.end(), [](double a, double b) { return std::fabs(a - b) <= 1e-9 * std::max(a, b); }),
            out.end());
  return out;
}
// The stress's t at a cube (R16, the response).
static double stress_t(const Layout& l, int frame, const double lo[3], double s, const DemandField& f, double ref,
                       double response) {
  return std::pow(std::clamp(cube_demand(l, frame, lo, s, f) / ref, 0.0, 1.0), response);
}
// C22 for one cube (LatticeReview's ruling 2026-11-15: the nearest size): S* = S_base - t (S_base - f); a cell of size s
// may stand where S* >= (s + s_below) / 2, s_below the ladder's next size down; the finest, and a size with none below,
// always may; a tie keeps the larger.
static bool stress_rule_allows(const Layout& l, int frame, const double lo[3], double s, const std::vector<double>& ladder,
                               const DemandField& f, double ref, double response) {
  const double base = ladder.front(), finest = ladder.back();
  if (s <= finest * (1 + 1e-9)) return true;
  double below = 0.0;
  for (double a : ladder)
    if (a < s * (1 - 1e-9)) { below = a; break; }
  if (below <= 0.0) return true;
  const double asked = base - stress_t(l, frame, lo, s, f, ref, response) * (base - finest);
  return asked >= 0.5 * (s + below) - 1e-9 * base;
}
// The rule as it was before 2026-11-15 (a cell stood only where S* >= s), for the check that the new one never
// allows less.
static bool old_stress_rule_allows(const Layout& l, int frame, const double lo[3], double s,
                                   const std::vector<double>& ladder, const DemandField& f, double ref, double response) {
  const double base = ladder.front(), finest = ladder.back();
  if (s <= finest * (1 + 1e-9)) return true;
  return stress_t(l, frame, lo, s, f, ref, response) <= (base - s) / (base - finest) + 1e-9;
}
// At every cell's place, every size of its ladder that the old rule allowed there the new one allows too (the new
// threshold is always under s): nothing that was lattice becomes solid for the change. Returns the places it fails.
static int tighter_than_old(const Layout& l, const CellSpec& spec, const DemandField& f, double ref, double response) {
  int tighter = 0;
  std::map<long long, std::vector<double>> ladders;
  for (const Cell& c : l.cells) {
    auto& lad = ladders[std::llround(c.own * 1e6)];
    if (lad.empty()) lad = ladder_of(l, spec, c.own);
    for (double s : lad)
      if (old_stress_rule_allows(l, c.frame, c.lo, s, lad, f, ref, response) &&
          !stress_rule_allows(l, c.frame, c.lo, s, lad, f, ref, response))
        ++tighter;
  }
  return tighter;
}
static bool same_layout(const Layout& a, const Layout& b) { return a.cells == b.cells && a.solid == b.solid; }
// The size of the cell whose cube holds p (0: none).
static double size_holding(const Layout& l, const Vec3& p) {
  for (const Cell& c : l.cells) {
    const Vec3 m = cell_centre(l, c);
    if (std::fabs(p.x - m.x) < 0.5 * c.size && std::fabs(p.y - m.y) < 0.5 * c.size && std::fabs(p.z - m.z) < 0.5 * c.size)
      return c.size;
  }
  return 0.0;
}

static void test_cells_by_stress() {
  // A slab 96 x 24 x 8 latticed from its top face, 8 mm deep: one layer of 8 mm cells, ladder 8, 4, 2 (halves, at a
  // 0.2 mm line) or 8 and its fifths/sixths (Stepped). The made-up field is 0 for x < 16, rises evenly to the
  // reference (100 MPa) at x = 80 and stays there.
  PartMeasure pm(weld_mesh(box(96, 24, 8)));
  DomainSpec s;
  s.bead_mm = 0.2;
  s.regions = {face_region(1, Role::Lattice, {48, 12, 8}, {0, 0, -1}, 12, 48, 8)};   // u along y
  Domain d(pm, s);
  const double ref = 100.0;
  auto ramp_value = [](const Vec3& c) { return 100.0 * std::clamp((c.x - 16.0) / 64.0, 0.0, 1.0); };
  const auto ramp = stress_field({-2, -2, -2}, 1.0, 100, 28, 12, ramp_value);
  CellSpec off;
  off.cell_max_mm = 8;
  auto on_with = [&](Algorithm algo, std::shared_ptr<const DemandField> f, double r) {
    CellSpec c = off;
    c.algorithm = algo;
    c.by_stress = true;
    c.demand = std::move(f);
    c.reference_mpa = r;
    return c;
  };
  const double finest_of[2] = {2.0, 8.0 / 6.0};   // Default Grade, Stepped
  int before = g_fail;
  auto block = [&](const char* name) {
    std::printf("C22 %s: %d failed\n", name, g_fail - before);
    before = g_fail;
  };

  // 1, 2. The ramp, Default Grade and Stepped.
  Layout ramp_dg;
  for (int a = 0; a < 2; ++a) {
    const Algorithm algo = a == 0 ? Algorithm::DefaultGrade : Algorithm::Stepped;
    const CellSpec on = on_with(algo, ramp, ref);
    CHECK(stress_sizes_cells(on));
    const Layout l = lay_cells(d, on);
    if (a == 0) ramp_dg = l;
    const double finest = finest_of[a];
    const std::vector<double> ladder = ladder_of(l, on, 8.0);
    NEAR(ladder.back(), finest, 1e-12);
    CHECK(tighter_than_old(l, on, *ramp, ref, 1.0) == 0);
    int breaks = 0, cold = 0, cold_wrong = 0, hot = 0, hot_wrong = 0, wrong_own = 0;
    for (const Cell& c : l.cells) {
      if (std::fabs(c.own - 8.0) > 1e-9) ++wrong_own;
      if (!stress_rule_allows(l, c.frame, c.lo, c.size, ladder, *ramp, ref, 1.0)) ++breaks;
      const Vec3 m = cell_centre(l, c);
      if (m.x < 16.0) { ++cold; if (std::fabs(c.size - 8.0) > 1e-9) ++cold_wrong; }
      if (m.x > 80.0) { ++hot; if (std::fabs(c.size - finest) > 1e-9) ++hot_wrong; }
    }
    CHECK(wrong_own == 0);
    CHECK(breaks == 0);
    CHECK(cold == 6 && cold_wrong == 0);            // the cold end: the base cell (2 x 3 of them)
    CHECK(hot > 0 && hot_wrong == 0);               // the hot end: the finest
    CHECK(l.solid.empty());                         // nothing goes solid for the stress
    CHECK(badly_covered(d, l, {0, 0, 0}, {96, 24, 8}, 1.3) == 0);
    // Along the ramp the cell never grows.
    int grew = 0, read = 0;
    for (double y = 0.6; y < 24; y += 2.9)
      for (double z = 0.3; z < 8; z += 1.9) {
        double last = 1e300;
        for (double x = 0.1; x < 96; x += 0.25) {
          const double sz = size_holding(l, {x, y, z});
          if (sz == 0.0) continue;
          ++read;
          if (sz > last + 1e-9) ++grew;
          last = sz;
        }
      }
    CHECK(read > 10000 && grew == 0);
    if (a == 0) {
      // As large as the rule lets them: no eight sibling cells stand where their parent would be allowed and fits.
      std::map<std::array<long long, 4>, int> groups;
      double o[3] = {1e300, 1e300, 1e300};
      for (const Cell& c : l.cells)
        for (int k = 0; k < 3; ++k) o[k] = std::min(o[k], c.lo[k]);
      for (const Cell& c : l.cells) {
        if (c.size >= 8.0 - 1e-9) continue;
        const double P = 2 * c.size;
        groups[{std::llround(std::floor((c.lo[0] - o[0]) / P + 1e-9) * P * 1e3),
                std::llround(std::floor((c.lo[1] - o[1]) / P + 1e-9) * P * 1e3),
                std::llround(std::floor((c.lo[2] - o[2]) / P + 1e-9) * P * 1e3), std::llround(c.size * 1e3)}]++;
      }
      int full = 0, mergeable = 0;
      for (const auto& g : groups) {
        if (g.second != 8) continue;
        ++full;
        const double P = 2e-3 * static_cast<double>(g.first[3]);
        const double plo[3] = {o[0] + g.first[0] * 1e-3, o[1] + g.first[1] * 1e-3, o[2] + g.first[2] * 1e-3};
        if (stress_rule_allows(l, 0, plo, P, ladder, *ramp, ref, 1.0)) ++mergeable;
      }
      CHECK(full > 10 && mergeable == 0);
      std::printf("C22 ramp, Default Grade: %zu cells (%d sibling groups, none mergeable)\n", l.cells.size(), full);
    } else {
      std::printf("C22 ramp, Stepped: %zu cells\n", l.cells.size());
    }
  }
  block("1-2 ramp");

  {  // 3. Off, whatever the switch says: the layout is today's, byte for byte.
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec plain = off;
      plain.algorithm = algo;
      const Layout today = lay_cells(d, plain);
      const auto zero = stress_field({-2, -2, -2}, 1.0, 100, 28, 12, [](const Vec3&) { return 0.0; });
      CellSpec no_field = on_with(algo, nullptr, ref);
      CellSpec empty_field = on_with(algo, std::make_shared<DemandField>(), ref);
      CellSpec all_zero = on_with(algo, zero, ref);
      CellSpec no_ref = on_with(algo, ramp, 0.0);
      CHECK(!stress_sizes_cells(no_field) && !stress_sizes_cells(empty_field) && !stress_sizes_cells(no_ref));
      CHECK(stress_sizes_cells(all_zero));   // applied, and a field of nothing asks for nothing
      CHECK(same_layout(lay_cells(d, no_field), today));
      CHECK(same_layout(lay_cells(d, empty_field), today));
      CHECK(same_layout(lay_cells(d, all_zero), today));
      CHECK(same_layout(lay_cells(d, no_ref), today));
      CHECK(!same_layout(lay_cells(d, on_with(algo, ramp, ref)), today));   // and on, it is not today's
      CellSpec typed = plain;                // a typed cell size: only Manual forces one size (C16)
      typed.cell_mm = 8;
      CellSpec typed_on = on_with(algo, ramp, ref);
      typed_on.cell_mm = 8;
      CHECK(!stress_sizes_cells(typed_on) && same_layout(lay_cells(d, typed_on), lay_cells(d, typed)));
    }
    CellSpec uni = off;                      // Uniform: one size
    uni.algorithm = Algorithm::Uniform;
    CellSpec uni_on = on_with(Algorithm::Uniform, ramp, ref);
    CHECK(!stress_sizes_cells(uni_on) && same_layout(lay_cells(d, uni_on), lay_cells(d, uni)));
  }
  block("3 off");

  {  // 4. Nothing goes solid: the part of test_cells_behind_a_pocket (a 4 mm wall, a 5 mm pocket, the wall behind,
     // solid beside it), a ramp along x. Every point held by a cell with the option off is held by one with it on, and
     // the layout's solid does not grow. KNOWN LIMIT (reported 2026-11-14, not changed here): under a flat face a
     // cut cell that is halved can leave a strip of its lattice under a millimetre thin to a half none of whose sample
     // points is lattice (here 0.5 mm along the part's bottom), and no cell holds it (D14: "strips under about a
     // millimetre can be unlisted"). Grade to shape's halving loses the same kind of strip on this part; Stepped loses
     // none. So on Default Grade a lost point must lie within a millimetre of the part's surface.
    PartMeasure pp(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 9}, {50, 9}, {50, 4}, {0, 4}}, 0, 40)));
    DomainSpec ps;
    ps.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 13)};
    Domain dp(pp, ps);
    const auto f = stress_field({-2, -2, -2}, 1.0, 64, 24, 44,
                            [](const Vec3& c) { return 100.0 * std::clamp((c.x - 10.0) / 40.0, 0.0, 1.0); });
    auto pr = dp.probe();
    const PartMeasure::Probe surface = pp.probe();
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec plain;
      plain.algorithm = algo;
      CellSpec on = plain;
      on.by_stress = true;
      on.demand = f;
      on.reference_mpa = 100;
      CellSpec band = plain;   // the band's own halving, for the comparison
      band.grade_to_shape = true;
      band.band_mm = 8;
      const Layout lo_ = lay_cells(dp, plain), hi_ = lay_cells(dp, on), bd = lay_cells(dp, band);
      CHECK(tighter_than_old(hi_, on, *f, 100.0, 1.0) == 0);
      auto held = [&](const Layout& l, const Vec3& p) {
        for (const Cell& c : l.cells) if (cell_holds(l, pr, c, p)) return true;
        return false;
      };
      int held_off = 0, lost = 0, lost_deep = 0, lost_band = 0;
      for (double x = 0.31; x < 60; x += 1.1)
        for (double y = 0.27; y < 20; y += 0.9)
          for (double z = 0.33; z < 40; z += 1.3) {
            const Vec3 p{x, y, z};
            if (!pr.where(p).lattice() || !held(lo_, p)) continue;
            ++held_off;
            if (!held(bd, p)) ++lost_band;
            if (held(hi_, p)) continue;
            ++lost;
            if (surface.depth(p) >= 1.0) ++lost_deep;
          }
      double v0 = 0, v1 = 0;
      for (const Cell& c : lo_.solid) v0 += c.size * c.size * c.size;
      for (const Cell& c : hi_.solid) v1 += c.size * c.size * c.size;
      CHECK(held_off > 1000 && lost_deep == 0);
      if (algo == Algorithm::Stepped) CHECK(lost == 0);
      CHECK(v1 <= v0 + 1e-9 && hi_.solid.size() <= lo_.solid.size());
      CHECK(hi_.cells.size() > lo_.cells.size());
      std::printf("C22 pocket part, %s: %d points held with it off; with it on %d of them in no cell (%d a millimetre "
                  "or more inside); Grade to shape (band 8) leaves %d; cells %zu -> %zu, solid %zu -> %zu\n",
                  algo == Algorithm::Stepped ? "Stepped" : "Default Grade", held_off, lost, lost_deep, lost_band,
                  lo_.cells.size(), hi_.cells.size(), lo_.solid.size(), hi_.solid.size());
    }
  }
  block("4 nothing solid");

  {  // 5. Grade to shape on as well (band 6 mm): every cell obeys both rules.
    for (int a = 0; a < 2; ++a) {
      const Algorithm algo = a == 0 ? Algorithm::DefaultGrade : Algorithm::Stepped;
      CellSpec band = off;
      band.algorithm = algo;
      band.grade_to_shape = true;
      band.band_mm = 6;
      CellSpec both = on_with(algo, ramp, ref);
      both.grade_to_shape = true;
      both.band_mm = 6;
      const Layout lb = lay_cells(d, band), l = lay_cells(d, both);
      const double finest = finest_of[a];
      const std::vector<double> ladder = ladder_of(l, both, 8.0);
      NEAR(ladder.back(), finest, 1e-12);
      CHECK(tighter_than_old(l, both, *ramp, ref, 1.0) == 0);
      int breaks_band = 0, breaks_stress = 0;
      for (const Cell& c : l.cells) {
        const Vec3 m = cell_centre(l, c);
        const double dist = std::max(0.0, std::min(std::min(m.x, 96 - m.x), std::min(m.y, 24 - m.y)));
        if (c.size > finest * (1 + 1e-9) && dist < 6.0 * (c.size - finest) / (8.0 - finest) - 1e-6) ++breaks_band;
        if (!stress_rule_allows(l, c.frame, c.lo, c.size, ladder, *ramp, ref, 1.0)) ++breaks_stress;
      }
      CHECK(breaks_band == 0 && breaks_stress == 0);
      CHECK(!same_layout(l, lb) && l.cells.size() > lb.cells.size());
      CHECK(l.solid.empty());
    }
  }
  block("5 with Grade to shape");

  {  // 6. One hot voxel (x 50..51, y 11..12, z 3..4): only the base cube whose box overlaps it differs from the cold
     // layout, which is the plain one.
    auto one = stress_field({-2, -2, -2}, 1.0, 100, 28, 12, [](const Vec3& c) {
      return (c.x > 50 && c.x < 51 && c.y > 11 && c.y < 12 && c.z > 3 && c.z < 4) ? 100.0 : 0.0;
    });
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      const auto zero = stress_field({-2, -2, -2}, 1.0, 100, 28, 12, [](const Vec3&) { return 0.0; });
      const Layout cold = lay_cells(d, on_with(algo, zero, ref));
      const Layout hot = lay_cells(d, on_with(algo, one, ref));
      CHECK(tighter_than_old(hot, on_with(algo, one, ref), *one, ref, 1.0) == 0);
      int overlap = 0, changed = 0, wrong = 0;
      for (const Cell& b : cold.cells) {
        const Vec3 m = cell_centre(cold, b);
        const bool over = std::fabs(m.x - 50.5) < 4.5 && std::fabs(m.y - 11.5) < 4.5 && std::fabs(m.z - 3.5) < 4.5;
        std::vector<Cell> in;
        for (const Cell& c : hot.cells) {
          const Vec3 n = cell_centre(hot, c);
          if (std::fabs(n.x - m.x) < 4 && std::fabs(n.y - m.y) < 4 && std::fabs(n.z - m.z) < 4) in.push_back(c);
        }
        const bool same = in.size() == 1 && in[0] == b;
        if (over) { ++overlap; changed += !same; }
        else if (!same) ++wrong;
      }
      CHECK(cold.cells.size() == 36);
      CHECK(overlap == 1 && changed == 1 && wrong == 0);
    }
  }
  block("6 one hot voxel");

  {  // 7. Response 2 leaves fewer small cells than response 1 on the ramp; both ends are unchanged.
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec r2 = on_with(algo, ramp, ref);
      r2.response = 2.0;
      const Layout a1 = lay_cells(d, on_with(algo, ramp, ref)), a2 = lay_cells(d, r2);
      CHECK(tighter_than_old(a2, r2, *ramp, ref, 2.0) == 0);
      auto ends = [](const Layout& l, bool cold) {
        std::vector<Cell> out;
        for (const Cell& c : l.cells) {
          const double x = cell_centre(l, c).x;
          if (cold ? x < 16.0 : x > 80.0) out.push_back(c);
        }
        return out;
      };
      CHECK(a2.cells.size() < a1.cells.size());
      CHECK(ends(a1, true) == ends(a2, true) && ends(a1, false) == ends(a2, false));
      CHECK(!ends(a1, false).empty());
      std::printf("C22 response 1: %zu cells, response 2: %zu (%s)\n", a1.cells.size(), a2.cells.size(),
                  algo == Algorithm::Stepped ? "Stepped" : "Default Grade");
    }
  }
  block("7 response");

  {  // 8. One thread and eight: the same layout (D18).
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      const CellSpec on = on_with(algo, ramp, ref);
      const Layout one = lay_cells(d, on, 1), eight = lay_cells(d, on, 8);
      CHECK(same_layout(one, eight));
      CHECK(!same_layout(one, lay_cells(d, off, 1)));
    }
  }
  block("8 threads");

  {  // 9. Through a Session: the reference, kept; cells_by_stress and cells_no_stress.
    int L = 0, square = 0, sideA = 0, sideB = 0;
    const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
    Session session(model);
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}};
    st.bead_mm = 0.2;                                         // a ladder of 6, 3 and 1.5 mm
    st.cells.cell_max_mm = 6;
    st.bars = false;
    auto f = stress_field({-2, -2, -2}, 1.0, 64, 64, 14,
                      [](const Vec3& c) { return 100.0 * std::clamp((c.x - 25.0) / 40.0, 0.0, 1.0); });
    const Outcome plain = session.lay(st);
    CHECK(!plain.cells_by_stress && !plain.cells_no_stress && plain.stress_reference_mpa == 0.0);
    {  // A field sent under Uniform struts with cells by stress off is never read for a reference: none is reported and
       // the layout is the one with no field.
      Settings sent = st;
      sent.stress.demand = f;
      const Outcome quiet = session.lay(sent);
      CHECK(quiet.stress_reference_mpa == 0.0 && !quiet.cells_by_stress && !quiet.cells_no_stress);
      CHECK(quiet.layout.cells == plain.layout.cells);
      sent.cells.by_stress = true;   // asked for, but a typed size turns it off: still no reference read
      sent.cells.cell_mm = 6;
      CHECK(session.lay(sent).stress_reference_mpa == 0.0);
    }
    st.cells.by_stress = true;
    const Outcome none = session.lay(st);                     // asked, no field
    CHECK(!none.cells_by_stress && none.cells_no_stress && none.layout.cells == plain.layout.cells);
    st.stress.demand = f;                                     // reference 0: the part's own
    const Outcome own = session.lay(st);
    const double want = stress_reference(*session.domain(), *f, st.stress.percentile);
    CHECK(want > 0.0 && want < 100.0);
    CHECK(own.cells_by_stress && !own.cells_no_stress && own.stress_reference_mpa == want);
    auto laid_with = [&](double r) {
      CellSpec c = st.cells;
      c.demand = f;
      c.reference_mpa = r;
      Layout l = lay_cells(*session.domain(), c);
      set_struts(l, st.struts);
      return l;
    };
    CHECK(own.layout.cells == laid_with(want).cells);
    CHECK(tighter_than_old(own.layout, st.cells, *f, want, 1.0) == 0);
    CHECK(!(own.layout.cells == plain.layout.cells));
    CHECK(!(laid_with(want).cells == laid_with(2.0 * want).cells));   // the reference decides
    // Kept while the domain, the field and the percentile are the same: the field changed in place is not read again
    // for its reference (a slider move never reads it), and a new field pointer is.
    const std::vector<float> was = f->mpa;
    for (float& v : f->mpa) v *= 2.0f;
    const Outcome kept = session.lay(st);
    CHECK(kept.layout.cells == laid_with(want).cells);
    CHECK(!(kept.layout.cells == laid_with(2.0 * want).cells));
    auto g = std::make_shared<DemandField>(*f);
    st.stress.demand = g;
    const Outcome fresh = session.lay(st);
    CHECK(fresh.layout.cells == laid_with(2.0 * want).cells);
    f->mpa = was;
    st.stress.demand = f;
    st.stress.percentile = 0.5;                               // a new percentile: read again
    const double half = stress_reference(*session.domain(), *f, 0.5);
    CHECK(session.lay(st).layout.cells == laid_with(half).cells);
    st.stress.percentile = 0.95;
    st.stress.reference_mpa = 40.0;                           // a stated reference is used as it is
    const Outcome stated = session.lay(st);
    CHECK(stated.cells_by_stress && stated.layout.cells == laid_with(40.0).cells);
    st.stress.reference_mpa = 0.0;
    st.stress.demand = stress_field({-2, -2, -2}, 1.0, 64, 64, 14, [](const Vec3&) { return 0.0; });
    const Outcome zero = session.lay(st);                     // the part's own reference of a cold field is 0
    CHECK(!zero.cells_by_stress && zero.cells_no_stress && zero.layout.cells == plain.layout.cells);
    st.stress.demand = f;
    st.cells.cell_mm = 6;                                     // a typed size: off, and not "no stress"
    const Outcome typed = session.lay(st);
    CHECK(!typed.cells_by_stress && !typed.cells_no_stress);
    st.cells.cell_mm = 0;
    st.one_grid = true;                                       // Let walls cut cells: applied as anywhere else
    const Outcome grid = session.lay(st);
    CHECK(grid.cells_by_stress && !grid.cells_no_stress && grid.stress_reference_mpa == want);
    st.one_grid = false;
    st.cells.by_stress = false;                               // a field, the switch off
    const Outcome unasked = session.lay(st);
    CHECK(!unasked.cells_by_stress && !unasked.cells_no_stress && unasked.layout.cells == plain.layout.cells);
    // ONE reference for the cells and the struts: with both by stress, the struts read the one the cells were laid with.
    st.cells.by_stress = true;
    st.struts.mode = Density::ByStress;
    const Outcome both = session.lay(st);
    CHECK(both.cells_by_stress && both.struts.reference_mpa == want && both.stress_reference_mpa == want);
    CHECK(both.layout.cells.size() == laid_with(want).cells.size());
    st.cells.by_stress = false;   // the struts alone ask for it
    CHECK(session.lay(st).stress_reference_mpa == want);
  }
  block("9 session");

  {  // 12. Let walls cut cells (the owner, 2026-11-14: it means "ONLY that the cells can be cut by walls. NOTHING
     // ELSE"): cell size by stress applies, with C20 (only the finest cell is cut). The back plate of
     // test_one_grid_main_size (6 mm behind the face under 8 mm cubes, one 12 mm boss at x 32..40) at a 0.2 mm line
     // (halves 8, 4, 2), a ramp along x: 0 for x < 16, the reference from x = 48.
    PartMeasure pg(weld_mesh(prism({{0, 0}, {64, 0}, {64, 6}, {40, 6}, {40, 12}, {32, 12}, {32, 6}, {0, 6}}, 0, 64)));
    DomainSpec gs;
    gs.bead_mm = 0.2;
    gs.regions = {face_region(1, Role::Lattice, {32, 0, 32}, {0, 1, 0}, 32, 32, 8)};
    Domain dg(pg, gs);
    const auto gramp = stress_field({-2, -2, -2}, 1.0, 68, 16, 68,
                                    [](const Vec3& c) { return 100.0 * std::clamp((c.x - 16.0) / 32.0, 0.0, 1.0); });
    for (int a = 0; a < 2; ++a) {
      const Algorithm algo = a == 0 ? Algorithm::DefaultGrade : Algorithm::Stepped;
      CellSpec grid = off;
      grid.algorithm = algo;
      grid.one_grid = true;
      const Layout today = lay_cells(dg, grid);
      CellSpec no_field = grid;          // (b) no field: today's one-grid layout, byte for byte
      no_field.by_stress = true;
      no_field.reference_mpa = ref;
      CHECK(same_layout(lay_cells(dg, no_field), today));
      CellSpec on = no_field;            // (a) the ramp
      on.demand = gramp;
      CHECK(stress_sizes_cells(on));
      const Layout l = lay_cells(dg, on);
      double finest = 1e300;
      for (const Cell& c : l.cells) finest = std::min(finest, c.size);
      const double want_finest = a == 0 ? 2.0 : 8.0 / 6.0;
      const std::vector<double> ladder = ladder_of(l, on, 8.0);
      NEAR(ladder.back(), want_finest, 1e-12);
      CHECK(tighter_than_old(l, on, *gramp, ref, 1.0) == 0);
      int breaks = 0, cut_large = 0, hot = 0, hot_wrong = 0;
      for (const Cell& c : l.cells) {
        if (!stress_rule_allows(l, c.frame, c.lo, c.size, ladder, *gramp, ref, 1.0)) ++breaks;
        if (c.cut && c.size > want_finest * (1 + 1e-9)) ++cut_large;        // C20
        if (cell_centre(l, c).x > 48.0) { ++hot; if (std::fabs(c.size - want_finest) > 1e-9) ++hot_wrong; }
      }
      // Where the stress is nothing (cells wholly at x < 16) the cells are today's.
      auto cold_cells = [](const Layout& lay) {
        std::vector<Cell> out;
        for (const Cell& c : lay.cells) if (cell_centre(lay, c).x + 0.5 * c.size <= 16.0) out.push_back(c);
        return out;
      };
      NEAR(finest, want_finest, 1e-9);
      CHECK(breaks == 0 && cut_large == 0);
      CHECK(hot > 0 && hot_wrong == 0);
      CHECK(!cold_cells(today).empty() && cold_cells(l) == cold_cells(today));
      CHECK(l.cells.size() > today.cells.size());
      std::printf("C22 one grid, %s: %zu cells cold, %zu with the ramp\n", a == 0 ? "Default Grade" : "Stepped",
                  today.cells.size(), l.cells.size());
    }
    {  // C20 acts only when the region grades its cells: with one size (Uniform) the base cell is cut wherever the
       // wall falls, and none is split.
      CellSpec uni = off;
      uni.algorithm = Algorithm::Uniform;
      uni.one_grid = true;
      const Layout u = lay_cells(dg, uni);
      int other = 0, cut = 0;
      for (const Cell& c : u.cells) { other += std::fabs(c.size - 8.0) > 1e-9; cut += c.cut; }
      CHECK(!u.cells.empty() && other == 0 && cut > 0 && u.solid.empty());
    }
  }
  block("12 Let walls cut cells");

  {  // 13. The nearest size (LatticeReview's ruling 2026-11-15). The slab with a smallest cell of 4: a ladder of exactly
     // two sizes, 8 and 4, on both algorithms; the 8 stands where t <= 0.5.
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      const char* name = algo == Algorithm::Stepped ? "Stepped" : "Default Grade";
      auto two = [&](std::shared_ptr<const DemandField> f) {
        CellSpec c = on_with(algo, std::move(f), ref);
        c.cell_min_mm = 4;
        return c;
      };
      auto flat = [](double mpa) {
        return stress_field({-2, -2, -2}, 1.0, 100, 28, 12, [mpa](const Vec3&) { return mpa; });
      };
      auto sizes = [](const Layout& l) {
        std::map<long long, int> n;
        for (const Cell& c : l.cells) n[std::llround(c.size * 1e3)]++;
        return n;
      };
      const auto quarter = flat(25.0), three = flat(75.0);
      const Layout lq = lay_cells(d, two(quarter)), l3 = lay_cells(d, two(three)), lr = lay_cells(d, two(ramp));
      const std::vector<double> ladder = ladder_of(lq, two(quarter), 8.0);
      CHECK(ladder.size() == 2 && std::fabs(ladder[0] - 8) < 1e-12 && std::fabs(ladder[1] - 4) < 1e-12);
      const auto nq = sizes(lq), n3 = sizes(l3);
      CHECK(nq.size() == 1 && nq.count(8000) && nq.at(8000) == 36);   // t = 0.25: every cell the region's own
      CHECK(n3.size() == 1 && n3.count(4000) && n3.at(4000) == 288);  // t = 0.75: every cell the smallest
      // The ramp (t = 0.5 at x = 48): every cell wholly at x < 40 is 8, every one wholly at x > 56 is 4, and both
      // sizes stand.
      int left = 0, left_wrong = 0, right = 0, right_wrong = 0;
      for (const Cell& c : lr.cells) {
        const Vec3 m = cell_centre(lr, c);
        if (m.x + 0.5 * c.size <= 40.0 + 1e-9) { ++left; left_wrong += std::fabs(c.size - 8) > 1e-9; }
        if (m.x - 0.5 * c.size >= 56.0 - 1e-9) { ++right; right_wrong += std::fabs(c.size - 4) > 1e-9; }
      }
      CHECK(left > 0 && left_wrong == 0 && right > 0 && right_wrong == 0);
      CHECK(lq.solid.empty() && l3.solid.empty() && lr.solid.empty());
      CHECK(tighter_than_old(lr, two(ramp), *ramp, ref, 1.0) == 0);
      std::printf("C22 nearest, two sizes, %s: t 0.25 %zu cells, t 0.75 %zu, ramp %zu (%d cells wholly under x 40, all 8; "
                  "%d wholly over x 56, all 4)\n", name, lq.cells.size(), l3.cells.size(), lr.cells.size(), left, right);
    }
    // The lead's example: base 12, smallest cell 4, Stepped admits 2 and 3: the ladder 12, 8, 6, 4; 12 stands where
    // S* >= 10, 8 where S* >= 7, 6 where S* >= 5, 4 always. S* = 12 - 8 t. A slab 96 x 24 x 12 under its top face.
    PartMeasure p12(weld_mesh(box(96, 24, 12)));
    DomainSpec s12;
    s12.bead_mm = 0.2;
    s12.regions = {face_region(1, Role::Lattice, {48, 12, 12}, {0, 0, -1}, 12, 48, 12)};
    Domain d12(p12, s12);
    auto at = [&](double t) {
      CellSpec c = off;
      c.algorithm = Algorithm::Stepped;
      c.cell_max_mm = 12;
      c.cell_min_mm = 4;
      c.by_stress = true;
      c.demand = stress_field({-2, -2, -2}, 1.0, 100, 28, 16, [t](const Vec3&) { return 100.0 * t; });
      c.reference_mpa = ref;
      return c;
    };
    const Layout tie = lay_cells(d12, at(0.25));   // S* = 10 exactly: a tie keeps the larger
    const std::vector<double> lad = ladder_of(tie, at(0.25), 12.0);
    CHECK(lad.size() == 4 && std::fabs(lad[0] - 12) < 1e-9 && std::fabs(lad[1] - 8) < 1e-9 &&
          std::fabs(lad[2] - 6) < 1e-9 && std::fabs(lad[3] - 4) < 1e-9);
    auto largest = [](const Layout& l) {
      double m = 0;
      for (const Cell& c : l.cells) m = std::max(m, c.size);
      return m;
    };
    auto smallest = [](const Layout& l) {
      double m = 1e300;
      for (const Cell& c : l.cells) m = std::min(m, c.size);
      return m;
    };
    int all12 = 0;
    for (const Cell& c : tie.cells) all12 += std::fabs(c.size - 12) < 1e-9;
    CHECK(!tie.cells.empty() && all12 == static_cast<int>(tie.cells.size()));
    const Layout under10 = lay_cells(d12, at(0.30));   // S* = 9.6: no 12; a cell is never larger than 8
    CHECK(largest(under10) <= 8 + 1e-9 && smallest(under10) >= 6 - 1e-9);
    const Layout at7 = lay_cells(d12, at(0.625));      // S* = 7: 8 may stand
    CHECK(largest(at7) <= 8 + 1e-9 && smallest(at7) >= 6 - 1e-9);
    const Layout under7 = lay_cells(d12, at(0.70));    // S* = 6.4: 6 at most, nothing under it
    CHECK(largest(under7) <= 6 + 1e-9 && smallest(under7) >= 6 - 1e-9);
    const Layout under5 = lay_cells(d12, at(0.90));    // S* = 4.8: the smallest
    CHECK(largest(under5) <= 4 + 1e-9 && !under5.cells.empty());
    for (const Layout* l : {&tie, &under10, &at7, &under7, &under5}) CHECK(l->solid.empty());
    std::printf("C22 nearest, base 12 (12, 8, 6, 4): S* 10 -> %zu cells, largest %.2f; 9.6 -> %.2f..%.2f; 7 -> "
                "%.2f..%.2f; 6.4 -> %.2f..%.2f; 4.8 -> %.2f\n", tie.cells.size(), largest(tie), smallest(under10),
                largest(under10), smallest(at7), largest(at7), smallest(under7), largest(under7), largest(under5));
  }
  block("13 nearest size");

  {  // 11. Speed: lay_cells with the option on, about 2,000 cells and a 64^3 field, against it off.
    PartMeasure pb(weld_mesh(box(128, 128, 64)));
    DomainSpec bs;
    bs.bead_mm = 0.2;
    bs.start = Start::AllLattice;
    Domain db(pb, bs);
    const auto zero = stress_field({0, 0, 0}, 2.0, 64, 64, 64, [](const Vec3&) { return 0.0; });
    const auto slope = stress_field({0, 0, 0}, 2.0, 64, 64, 64,
                                [](const Vec3& c) { return 100.0 * std::clamp((c.x - 100.0) / 28.0, 0.0, 1.0); });
    CellSpec plain = off;
    plain.cell_min_mm = 2;   // the whole part's base cell 8 mm (its halves end at 2)
    auto with_min = [](CellSpec c) { c.cell_min_mm = 2; return c; };
    auto best_ms = [&](const CellSpec& c, std::size_t* cells) {
      double best = 1e300;
      for (int k = 0; k < 3; ++k) {
        const auto t0 = std::chrono::steady_clock::now();
        const Layout l = lay_cells(db, c);
        best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
        *cells = l.cells.size();
      }
      return best;
    };
    std::size_t n0 = 0, n1 = 0, n2 = 0;
    (void)lay_cells(db, plain);   // the domain's first reading, not timed
    {  // What the part's own reference costs, once, on a 64^3 field (the session keeps it: R17).
      const auto t0 = std::chrono::steady_clock::now();
      const double r = stress_reference(db, *slope, 0.95);
      std::printf("C22 stress_reference on a 64^3 field: %.2f ms (%.3f MPa)\n",
                  std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count(), r);
    }
    const double t_off = best_ms(plain, &n0);
    const double t_on = best_ms(with_min(on_with(Algorithm::DefaultGrade, zero, ref)), &n1);
    const double t_slope = best_ms(with_min(on_with(Algorithm::DefaultGrade, slope, ref)), &n2);
    std::printf("C22 speed: off %.2f ms (%zu cells); on, a cold 64^3 field %.2f ms (%zu cells, %.2fx); on, a slope "
                "over the last 28 mm %.2f ms (%zu cells)\n",
                t_off, n0, t_on, n1, t_on / t_off, t_slope, n2);
    CHECK(n0 > 1500 && n0 < 2600 && n1 == n0);
    CHECK(t_on <= 1.5 * t_off);
    CHECK(n2 > n0);
  }
  block("11 speed");
}

// ── C23, R19: an area's own cells and struts ──────────────────────────────────
static std::vector<Cell> cells_of(const Layout& l, int region) {
  std::vector<Cell> out;
  for (const Cell& c : l.cells)
    if (c.region == region) out.push_back(c);
  return out;
}
static std::vector<double> sizes_of(const Layout& l, int region) {
  std::vector<double> out;
  for (const Cell& c : l.cells)
    if (c.region == region && std::find(out.begin(), out.end(), c.size) == out.end()) out.push_back(c.size);
  std::sort(out.begin(), out.end());
  return out;
}
// R10, as set_struts reads a dial on a cell of `ref` mm.
static double dial_ratio(const Layout& l, double dial, double ref) {
  const double bead = std::max(l.bead_mm, l.min_strut_mm);
  const double t = std::clamp((dial - 0.01) / 0.99, 0.0, 1.0);
  return (bead + t * (std::max(bead, l.open_look * ref) - bead)) / ref;
}
static double held_strut(const Layout& l, double want, double size) {
  const double bead = std::max(l.bead_mm, l.min_strut_mm);
  return std::clamp(want, bead, std::max(bead, l.open_look * size));
}
static double largest_of(const Layout& l, int region) {
  double m = 0.0;
  for (const Cell& c : l.cells)
    if (c.region == region) m = std::max(m, c.size);
  return m;
}

static void test_area_own() {
  // A block 46 x 46 x 16 at a 0.2 mm line (ladder 8, 4, 2): region A (1) under the top face and region B (2) under
  // the bottom face, each 8 mm deep. 46 is not a whole number of 8 mm cells, so the outline cuts the outer ring.
  PartMeasure pm(weld_mesh(box(46, 46, 16)));
  DomainSpec ds;
  ds.bead_mm = 0.2;
  ds.regions = {face_region(1, Role::Lattice, {23, 23, 16}, {0, 0, -1}, 23, 23, 8),
                face_region(2, Role::Lattice, {23, 23, 0}, {0, 0, 1}, 23, 23, 8)};
  Domain d(pm, ds);
  CellSpec P;
  P.cell_max_mm = 8;
  const Layout base = lay_cells(d, P);
  CHECK(sizes_of(base, 1) == std::vector<double>{8.0} && sizes_of(base, 2) == std::vector<double>{8.0});
  CellSpec P3 = P;   // with Grade to shape, band 8
  P3.grade_to_shape = true;
  P3.band_mm = 8;
  const Layout base3 = lay_cells(d, P3);
  // A stress ramp along x: 0 for x < 8, 100 MPa from x = 36 on.
  const auto ramp = stress_field({-2, -2, -2}, 1.0, 48, 48, 20,
                                 [](const Vec3& c) { return 100.0 * std::clamp((c.x - 8.0) / 28.0, 0.0, 1.0); });
  const auto only = [](int id, AreaOwn o) { AreaOwnMap m; m[id] = o; return m; };

  {  // 1. Nothing stated: today's layout. Each setting stated equal to the part's: today's layout.
    AreaOwnMap none;
    none[1] = AreaOwn{};
    none[2] = AreaOwn{};
    CellSpec ps = P3;
    ps.by_stress = true;
    ps.demand = ramp;
    ps.reference_mpa = 100.0;
    const Layout today = lay_cells(d, ps);
    CHECK(same_layout(lay_cells(d, ps, 0, &none), today));
    AreaOwn eq;
    eq.algorithm = ps.algorithm; eq.cell_mm = ps.cell_mm; eq.cell_max_mm = ps.cell_max_mm;
    eq.cell_min_mm = ps.cell_min_mm; eq.min_cells_across = ps.min_cells_across; eq.grade_to_shape = ps.grade_to_shape;
    eq.band_mm = ps.band_mm; eq.band_cell_mm = ps.band_cell_mm; eq.cells_by_stress = ps.by_stress;
    eq.response = ps.response; eq.reference_mpa = ps.reference_mpa;
    StrutSpec ss;
    ss.dial = 0.3;
    ss.strength = 0.5;
    ss.demand = ramp;
    ss.reference_mpa = 100.0;
    eq.by_stress = false; eq.dial = ss.dial; eq.width_mm = ss.width_mm; eq.strength = ss.strength;
    eq.dial_light = ss.dial_light; eq.dial_heavy = ss.dial_heavy;
    eq.width_light_mm = ss.width_light_mm; eq.width_heavy_mm = ss.width_heavy_mm;
    AreaOwnMap all;
    all[1] = eq;
    all[2] = eq;
    Layout x = lay_cells(d, ps, 0, &all), y = today;
    CHECK(same_layout(x, today));
    CHECK(largest_of(today, 1) == largest_of(today, 2) && !today.cells.empty());   // a stated dial reads the same cell
    Layout z = today;
    set_struts(x, ss, &all);
    set_struts(y, ss);
    set_struts(z, ss, &none);
    CHECK(x.cells == y.cells && z.cells == y.cells);
    ss.mode = Density::ByStress;   // and By stress, its ends and widths stated as the part's
    ss.dial_light = 0.2; ss.dial_heavy = 0.7; ss.width_light_mm = 0.0; ss.response = 1.0;
    for (auto* o : {&all[1], &all[2]}) {
      o->by_stress = true; o->dial_light = 0.2; o->dial_heavy = 0.7;
    }
    x = today; y = today;
    const StrutReport rx = set_struts(x, ss, &all), ry = set_struts(y, ss);
    CHECK(x.cells == y.cells && !rx.no_stress && rx.at_heavy == ry.at_heavy && rx.at_light == ry.at_light);
  }
  {  // 2. A states cell_mm 4 while the part's is 8: A's cells are 4 (and its ladder's), B's are 8.
    AreaOwn a;
    a.cell_mm = 4.0;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, P, 0, &m);
    CellSpec four = P;
    four.cell_mm = 4.0;
    const Layout all4 = lay_cells(d, four);
    CHECK(cells_of(l, 1) == cells_of(all4, 1) && largest_of(l, 1) == 4.0);
    CHECK(cells_of(l, 2) == cells_of(base, 2) && largest_of(l, 2) == 8.0);
    CHECK(l.regions.size() == 2 && l.regions[0].base_cell_mm == 4.0 && l.regions[1].base_cell_mm == 8.0);
  }
  {  // 3. A states Stepped while the part is Default Grade (Grade to shape on): A's sizes are Stepped fractions, B's
     // halves only.
    AreaOwn a;
    a.algorithm = Algorithm::Stepped;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, P3, 0, &m);
    CellSpec st = P3;
    st.algorithm = Algorithm::Stepped;
    CHECK(cells_of(l, 1) == cells_of(lay_cells(d, st), 1));
    CHECK(cells_of(l, 2) == cells_of(base3, 2));
    const auto half = [](double s) { const double k = std::log2(8.0 / s); return std::fabs(k - std::round(k)) < 1e-9; };
    int a_not_half = 0, b_not_half = 0;
    for (double s : sizes_of(l, 1)) a_not_half += !half(s);
    for (double s : sizes_of(l, 2)) b_not_half += !half(s);
    CHECK(a_not_half > 0 && b_not_half == 0 && sizes_of(l, 2).size() > 1);
  }
  {  // 4. A states Uniform: A has one cell size and is cut where it ends; B grades.
    AreaOwn a;
    a.algorithm = Algorithm::Uniform;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, P3, 0, &m);
    int past = 0;   // cubes reaching past the face's outline: cut by it
    for (const Cell& c : cells_of(l, 1)) {
      Vec3 lo, hi;
      cell_box(l, c, &lo, &hi);
      past += lo.x < -1e-9 || lo.y < -1e-9 || hi.x > 46 + 1e-9 || hi.y > 46 + 1e-9;
    }
    CHECK(sizes_of(l, 1) == std::vector<double>{8.0} && past > 0);
    CHECK(sizes_of(l, 2).size() > 1 && cells_of(l, 2) == cells_of(base3, 2));
  }
  {  // 5. A states Grade to shape with band 6 while the part has it off: only A's cells shrink toward its outline.
    AreaOwn a;
    a.grade_to_shape = true;
    a.band_mm = 6.0;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, P, 0, &m);
    CellSpec g = P;
    g.grade_to_shape = true;
    g.band_mm = 6.0;
    CHECK(cells_of(l, 1) == cells_of(lay_cells(d, g), 1) && sizes_of(l, 1).front() < 8.0);
    CHECK(sizes_of(l, 2) == std::vector<double>{8.0} && cells_of(l, 2) == cells_of(base, 2));
  }
  {  // 6. A states min_cells_across 1 while the part's is 2, on a plate whose regions hold one cell across:
     // lattice in A there, solid in B.
    PartMeasure thin(weld_mesh(box(44, 44, 3)));
    DomainSpec ts;
    ts.bead_mm = 0.2;
    ts.regions = {face_region(1, Role::Lattice, {22, 22, 3}, {0, 0, -1}, 22, 22, 1.5),
                  face_region(2, Role::Lattice, {22, 22, 0}, {0, 0, 1}, 22, 22, 1.5)};
    Domain td(thin, ts);
    CellSpec two = P;
    two.min_cells_across = 2;
    const Layout today = lay_cells(td, two);
    CHECK(today.cells.empty() && !today.solid.empty());
    AreaOwn a;
    a.min_cells_across = 1;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(td, two, 0, &m);
    std::size_t b_solid = 0;
    for (const Cell& c : l.solid) b_solid += c.region == 2;
    CHECK(!cells_of(l, 1).empty() && cells_of(l, 2).empty() && b_solid > 0);
  }
  {  // 7. A states cell_min_mm above the floor: no cell of A is smaller; B still goes to the floor.
    AreaOwn a;
    a.cell_min_mm = 3.0;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, P3, 0, &m);
    CHECK(sizes_of(l, 1).front() >= 3.0 && sizes_of(l, 1).size() > 1);
    CHECK(sizes_of(l, 2).front() == 2.0 && cells_of(l, 2) == cells_of(base3, 2));
  }
  {  // 8. A states cell size by stress off while the part's is on (ramp field): A's cells ignore the stress, B's follow.
    CellSpec ps = P;
    ps.by_stress = true;
    ps.demand = ramp;
    ps.reference_mpa = 100.0;
    const Layout stressed = lay_cells(d, ps);
    CHECK(!(cells_of(stressed, 2) == cells_of(base, 2)));
    AreaOwn a;
    a.cells_by_stress = false;
    const AreaOwnMap m = only(1, a);
    const Layout l = lay_cells(d, ps, 0, &m);
    CHECK(cells_of(l, 1) == cells_of(base, 1) && cells_of(l, 2) == cells_of(stressed, 2));
  }
  {  // 9. Struts: A states dial 0.9, the part Uniform 0.3: A's strut / cell is the 0.9 dial read on A's largest cell,
     // B's the part's. With A's cells 4 mm, on A's 4 mm cell, not the part's 8.
    StrutSpec u;
    u.dial = 0.3;
    for (bool small : {false, true}) {
      AreaOwn a;
      a.dial = 0.9;
      if (small) a.cell_mm = 4.0;
      const AreaOwnMap m = only(1, a);
      Layout l = lay_cells(d, P, 0, &m);
      set_struts(l, u, &m);
      const double ra = dial_ratio(l, 0.9, small ? 4.0 : 8.0), rb = dial_ratio(l, 0.3, 8.0);
      int wrong = 0;
      for (const Cell& c : l.cells)
        if (std::fabs(c.strut - held_strut(l, (c.region == 1 ? ra : rb) * c.size, c.size)) > 1e-12) ++wrong;
      CHECK(wrong == 0 && largest_of(l, 1) == (small ? 4.0 : 8.0));
    }
    // A states width_mm: every cell of A that can hold it has it; B does not.
    AreaOwn a;
    a.width_mm = 0.75;
    const AreaOwnMap m = only(1, a);
    Layout l = base;
    set_struts(l, u, &m);
    int a_has = 0, a_could = 0, b_has = 0;
    for (const Cell& c : l.cells) {
      if (c.region == 1 && l.open_look * c.size >= 0.75) { ++a_could; a_has += c.strut == 0.75; }
      if (c.region == 2) b_has += c.strut == 0.75;
    }
    CHECK(a_could > 0 && a_has == a_could && b_has == 0);
  }
  {  // 10. A states By stress with its own ends while the part is Uniform (ramp field): A's struts follow the ramp
     // between A's ends, B's are uniform. And the reverse: the part By stress, A Uniform with its own dial.
    StrutSpec u;
    u.dial = 0.3;
    u.demand = ramp;
    u.reference_mpa = 100.0;
    AreaOwn a;
    a.by_stress = true;
    a.dial_light = 0.2;
    a.dial_heavy = 0.8;
    AreaOwnMap m = only(1, a);
    Layout l = base;
    const StrutReport r = set_struts(l, u, &m);
    const double rl = dial_ratio(l, 0.2, 8.0), rh = dial_ratio(l, 0.8, 8.0), r3 = dial_ratio(l, 0.3, 8.0);
    int wrong = 0, a_light = 0, a_heavy = 0;
    for (const Cell& c : l.cells) {
      const double f = std::clamp(cube_demand(l, c.frame, c.lo, c.size, *ramp) / 100.0, 0.0, 1.0);
      const double want = c.region == 1 ? (rl + f * (rh - rl)) * c.size : r3 * c.size;
      if (std::fabs(c.strut - held_strut(l, want, c.size)) > 1e-12) ++wrong;
      if (c.region == 1) { a_light += f == 0.0; a_heavy += f == 1.0; }
    }
    CHECK(wrong == 0 && a_light > 0 && a_heavy > 0 && !r.no_stress);
    CHECK(r.at_light == static_cast<std::size_t>(a_light) && r.at_heavy == static_cast<std::size_t>(a_heavy));
    // No field: A at its light end, and the layout says so (R18).
    StrutSpec nofield = u;
    nofield.demand = nullptr;
    Layout n = base;
    CHECK(set_struts(n, nofield, &m).no_stress);
    // The reverse.
    StrutSpec bs = u;
    bs.mode = Density::ByStress;
    bs.dial_light = 0.2;
    bs.dial_heavy = 0.8;
    AreaOwn b;
    b.by_stress = false;
    b.dial = 0.6;
    m = only(1, b);
    l = base;
    set_struts(l, bs, &m);
    const double r6 = dial_ratio(l, 0.6, 8.0);
    wrong = 0;
    for (const Cell& c : l.cells) {
      const double f = std::clamp(cube_demand(l, c.frame, c.lo, c.size, *ramp) / 100.0, 0.0, 1.0);
      const double want = c.region == 1 ? r6 * c.size : (rl + f * (rh - rl)) * c.size;
      if (std::fabs(c.strut - held_strut(l, want, c.size)) > 1e-12) ++wrong;
    }
    CHECK(wrong == 0);
    // Through the session: the part Uniform, a region By stress with no reference of its own reads the part's (R17).
    int L = 0, square = 0, sideA = 0, sideB = 0;
    Session session(plate_with_L_face(&L, &square, &sideA, &sideB));
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.bars = false;
    st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}, {2, Role::Lattice, {L}, 6.0, 0.0}};
    st.regions[0].own.by_stress = true;
    st.cells.cell_max_mm = 6;
    st.stress.demand = field_of(60, 60, 10, [](int i, int j, int) { return static_cast<double>(i + j); });
    const Outcome o = session.lay(st);
    const double part_ref = stress_reference(*session.domain(), *st.stress.demand, 0.95);
    CHECK(part_ref > 0.0 && o.stress_reference_mpa == part_ref && !o.struts.no_stress && o.struts.at_heavy > 0);
    std::vector<double> ra, rb;
    for (const Cell& c : o.layout.cells) {
      auto& v = c.region == 1 ? ra : rb;
      if (std::find(v.begin(), v.end(), c.strut / c.size) == v.end()) v.push_back(c.strut / c.size);
    }
    CHECK(ra.size() > 2 && rb.size() <= 2);   // B: one ratio, two at most where a cell is held at a limit
  }
  {  // 11. A's own response and reference change A's struts and cells and nothing of B's.
    CellSpec ps = P;
    ps.by_stress = true;
    ps.demand = ramp;
    ps.reference_mpa = 100.0;
    StrutSpec bs;
    bs.mode = Density::ByStress;
    bs.dial_light = 0.2;
    bs.dial_heavy = 0.8;
    bs.demand = ramp;
    bs.reference_mpa = 100.0;
    Layout before = lay_cells(d, ps);
    set_struts(before, bs);
    AreaOwn a;
    a.response = 2.0;
    a.reference_mpa = 50.0;
    const AreaOwnMap m = only(1, a);
    Layout l = lay_cells(d, ps, 0, &m);
    set_struts(l, bs, &m);
    CHECK(cells_of(l, 2) == cells_of(before, 2));
    CellSpec theirs = ps;
    theirs.response = 2.0;
    theirs.reference_mpa = 50.0;
    std::vector<Cell> want_a = cells_of(lay_cells(d, theirs), 1), got_a = cells_of(l, 1), old_a = cells_of(before, 1);
    for (Cell& c : got_a) c.strut = 0.0;
    for (Cell& c : old_a) c.strut = 0.0;
    CHECK(got_a == want_a && !(got_a == old_a));
    // A's struts: f = stress / 50, to the power 2, between the part's ends read on the part's largest cell.
    double part_big = 0.0;
    for (const Cell& c : l.cells) part_big = std::max(part_big, c.size);
    const double pl = dial_ratio(l, 0.2, part_big), ph = dial_ratio(l, 0.8, part_big);
    int wrong = 0;
    for (const Cell& c : l.cells) {
      if (c.region != 1) continue;
      const double f = std::clamp(cube_demand(l, c.frame, c.lo, c.size, *ramp) / 50.0, 0.0, 1.0);
      if (std::fabs(c.strut - held_strut(l, (pl + f * f * (ph - pl)) * c.size, c.size)) > 1e-12) ++wrong;
    }
    CHECK(wrong == 0);
  }
  {  // 12. Per region with region_dial is today's; a stated dial wins over the region's region_dial entry.
    StrutSpec pr;
    pr.mode = Density::PerRegion;
    pr.region_dial = {{1, 0.7}, {2, 0.2}};
    AreaOwnMap none;
    none[1] = AreaOwn{};
    Layout x = base, y = base;
    set_struts(x, pr);
    set_struts(y, pr, &none);
    CHECK(x.cells == y.cells);
    AreaOwn a;
    a.dial = 0.4;
    const AreaOwnMap m = only(1, a);
    Layout l = base;
    set_struts(l, pr, &m);
    int wrong = 0;
    for (std::size_t i = 0; i < l.cells.size(); ++i) {
      const Cell& c = l.cells[i];
      const double want = c.region == 1 ? held_strut(l, dial_ratio(l, 0.4, 8.0) * c.size, c.size) : x.cells[i].strut;
      if (std::fabs(c.strut - want) > 1e-12) ++wrong;
    }
    CHECK(wrong == 0 && l.cells[0].region == 1 && l.cells[0].strut != x.cells[0].strut);
  }
  {  // 13. One thread and eight give the same layout. Speed: every region stating everything (as the part's values)
     // takes no more than 1.2 x the same layout stated at part level.
    AreaOwn a, b;
    a.algorithm = Algorithm::Stepped; a.cell_mm = 4.0; a.dial = 0.7;
    b.grade_to_shape = false; b.cell_min_mm = 3.0; b.by_stress = true; b.reference_mpa = 60.0;
    AreaOwnMap m;
    m[1] = a;
    m[2] = b;
    StrutSpec u;
    u.demand = ramp;
    u.reference_mpa = 100.0;
    Layout one = lay_cells(d, P3, 1, &m), eight = lay_cells(d, P3, 8, &m);
    set_struts(one, u, &m);
    set_struts(eight, u, &m);
    CHECK(same_layout(one, eight) && one.cells == eight.cells);
    AreaOwn eq;
    eq.algorithm = P3.algorithm; eq.cell_mm = P3.cell_mm; eq.cell_max_mm = P3.cell_max_mm;
    eq.cell_min_mm = P3.cell_min_mm; eq.min_cells_across = P3.min_cells_across; eq.grade_to_shape = P3.grade_to_shape;
    eq.band_mm = P3.band_mm; eq.band_cell_mm = P3.band_cell_mm; eq.cells_by_stress = P3.by_stress;
    eq.response = 1.0; eq.reference_mpa = 0.0;
    eq.by_stress = false; eq.dial = u.dial; eq.width_mm = 0.0; eq.strength = 0.0; eq.dial_light = u.dial_light;
    eq.dial_heavy = u.dial_heavy; eq.width_light_mm = 0.0; eq.width_heavy_mm = 0.0;
    AreaOwnMap all;
    all[1] = eq;
    all[2] = eq;
    const auto time = [&](const AreaOwnMap* own) {
      double best = 1e9;
      for (int run = 0; run < 9; ++run) {
        const auto t0 = std::chrono::steady_clock::now();
        Layout l = lay_cells(d, P3, 0, own);
        set_struts(l, u, own);
        best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
      }
      return best;
    };
    const double plain = time(nullptr), stated = time(&all);
    std::printf("area own: a layout stated at part level %.2f ms, every region stating everything %.2f ms (best of 9)\n",
                plain, stated);
    CHECK(stated <= 1.2 * plain);
  }
}

// D21: zones. A block as a model (faces 0 bottom, 1 top, 2 the front at y = 0, 3..5 the rest), for the Session.
static StepModel zone_block(double x, double y, double z) {
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
    for (int t = 0; t < 2; ++t) {
      const int n = static_cast<int>(m.mesh.vertices.size());
      m.mesh.vertices.insert(m.mesh.vertices.end(), {p[q[f][0]], p[q[f][t ? 2 : 1]], p[q[f][t ? 3 : 2]]});
      m.mesh.triangles.push_back({n, n + 1, n + 2});
      m.triangle_face.push_back(f);
    }
  }
  m.face_count = 6;
  m.solid_count = 1;
  return m;
}
static Zone box_zone(Vec3 centre, Vec3 a0, Vec3 a1, Vec3 a2, double h0, double h1, double h2) {
  Zone z;
  z.kind = Zone::Kind::Box;
  z.centre = centre;
  z.axis[0] = a0; z.axis[1] = a1; z.axis[2] = a2;
  z.half[0] = h0; z.half[1] = h1; z.half[2] = h2;
  return z;
}
static Zone cylinder_zone(Vec3 centre, Vec3 axis, double radius, double half_length) {
  Zone z;
  z.kind = Zone::Kind::Cylinder;
  z.centre = centre;
  z.axis[2] = axis;
  z.half[0] = radius;
  z.half[2] = half_length;
  return z;
}
// A point of a box zone, from its own coordinates.
static Vec3 in_zone(const Zone& z, double q0, double q1, double q2) {
  const Vec3* a = z.axis;
  return {z.centre.x + a[0].x * q0 + a[1].x * q1 + a[2].x * q2, z.centre.y + a[0].y * q0 + a[1].y * q1 + a[2].y * q2,
          z.centre.z + a[0].z * q0 + a[1].z * q1 + a[2].z * q2};
}
static double zone_coord(const Zone& z, const Vec3& p, int a) {
  const Vec3 r{p.x - z.centre.x, p.y - z.centre.y, p.z - z.centre.z};
  return r.x * z.axis[a].x + r.y * z.axis[a].y + r.z * z.axis[a].z;
}

static void test_zones() {
  const double hair = 0.05;
  PartMeasure pm(weld_mesh(box(40, 40, 20)));
  const double c30 = std::cos(3.14159265358979323846 / 6), s30 = 0.5;
  // 1, 2: a box zone inside a solid block, Start from Solid, square to the part and turned 30 degrees about a2.
  for (const Zone& z : {box_zone({20, 20, 10}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 8, 6, 5),
                        box_zone({20, 20, 10}, {c30, s30, 0}, {-s30, c30, 0}, {0, 0, 1}, 8, 6, 5)}) {
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_zone(z, 3, Role::Lattice, 0.0, &ok)};
    CHECK(ok);
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (int a = 0; a < 3; ++a)
      for (int side : {-1, 1})
        for (double off : {-0.6, 0.0, 0.6}) {   // a few places along each of the six sides
          double q[3] = {off * z.half[0], off * z.half[1], off * z.half[2]};
          q[a] = side * (z.half[a] - hair);
          wrong += !(pr.where(in_zone(z, q[0], q[1], q[2])) == Where{Why::Lattice, 3});
          q[a] = side * (z.half[a] + hair);
          wrong += !(pr.where(in_zone(z, q[0], q[1], q[2])) == Where{Why::NotAsked, 0});
        }
    CHECK(wrong == 0);
    CellSpec cs;
    cs.cell_max_mm = 4;
    const Layout l = lay_cells(d, cs);
    int astray = 0;
    for (const Cell& c : l.cells) {   // each cell's cube meets the box; its centre is within the box's depth
      const Vec3 m = cell_centre(l, c);
      astray += c.region != 3 || std::fabs(zone_coord(z, m, 0)) >= z.half[0] + 0.5 * c.size - 1e-9 ||
                std::fabs(zone_coord(z, m, 1)) >= z.half[1] + 0.5 * c.size - 1e-9 ||
                std::fabs(zone_coord(z, m, 2)) > z.half[2] + 1e-9;
    }
    CHECK(!l.cells.empty() && astray == 0);
    // The box's own axes are the cells' frame: the cells line up with its sides.
    if (!l.cells.empty()) {
      const Vec3& u = l.frames[l.cells.front().frame].ax[0];
      NEAR(u.x * z.axis[0].x + u.y * z.axis[0].y + u.z * z.axis[0].z, 1.0, 1e-12);
    }
  }
  // 3: a cylinder zone: lattice inside 0.98 r, not outside 1.02 r, at 24 angles and three heights.
  {
    const Vec3 axis{0.0, 0.6, 0.8};   // tilted, so the in-plane axes are the engine's own pick
    const Zone z = cylinder_zone({20, 20, 10}, axis, 7, 5);
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_zone(z, 4, Role::Lattice, 0.0, &ok)};
    CHECK(ok);
    Domain d(pm, s);
    auto pr = d.probe();
    const Vec3 e1{1, 0, 0}, e2{0, 0.8, -0.6};   // square to the axis
    int wrong = 0;
    for (int k = 0; k < 24; ++k)
      for (double t : {-4.5, 0.0, 4.5}) {
        const double ang = 2 * 3.14159265358979323846 * k / 24 + 0.01;
        auto at = [&](double rr) {
          return Vec3{20 + axis.x * t + (e1.x * std::cos(ang) + e2.x * std::sin(ang)) * rr,
                      20 + axis.y * t + (e1.y * std::cos(ang) + e2.y * std::sin(ang)) * rr,
                      10 + axis.z * t + (e1.z * std::cos(ang) + e2.z * std::sin(ang)) * rr};
        };
        wrong += !(pr.where(at(0.98 * 7)) == Where{Why::Lattice, 4});
        wrong += !(pr.where(at(1.02 * 7)) == Where{Why::NotAsked, 0});
      }
    CHECK(wrong == 0);
    // Its two ends, a hair either side.
    CHECK((pr.where({20, 20 + 0.6 * 4.95, 10 + 0.8 * 4.95}) == Where{Why::Lattice, 4}));
    CHECK((pr.where({20, 20 + 0.6 * 5.05, 10 + 0.8 * 5.05}) == Where{Why::NotAsked, 0}));
    CHECK((pr.where({20, 20 - 0.6 * 4.95, 10 - 0.8 * 4.95}) == Where{Why::Lattice, 4}));
    CHECK((pr.where({20, 20 - 0.6 * 5.05, 10 - 0.8 * 5.05}) == Where{Why::NotAsked, 0}));
    // The loop's area is the circle's.
    double area = 0.0;
    const auto& loops = s.regions[0].prism.outline_uv;
    CHECK(loops.size() == 1 && loops[0].size() == 96);
    for (const auto& loop : loops)
      for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++)
        area += loop[j][0] * loop[i][1] - loop[i][0] * loop[j][1];
    NEAR(0.5 * std::fabs(area), 3.14159265358979323846 * 49.0, 1e-9);
    CellSpec cs;
    cs.cell_max_mm = 4;
    CHECK(!lay_cells(d, cs).cells.empty());
  }
  // 4: a zone half outside the part: lattice only where the part has material.
  {
    const Zone z = box_zone({40, 20, 10}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 8, 6, 5);
    DomainSpec s;
    s.regions = {region_from_zone(z, 1, Role::Lattice)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({36, 20, 10}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({39.9, 24, 6}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({40.1, 20, 10}) == Where{Why::Outside, 0}));
    CHECK((pr.where({44, 24, 6}) == Where{Why::Outside, 0}));
    CellSpec cs;
    cs.cell_max_mm = 4;
    const Layout l = lay_cells(d, cs);
    int outside = 0;   // no cell stands wholly outside the part
    for (const Cell& c : l.cells) outside += cell_centre(l, c).x - 0.5 * c.size >= 40.0;
    CHECK(!l.cells.empty() && outside == 0);
  }
  // 5: Start from All lattice with a No lattice box zone: no lattice inside it, lattice round it.
  {
    const Zone z = box_zone({20, 20, 10}, {c30, s30, 0}, {-s30, c30, 0}, {0, 0, 1}, 8, 6, 5);
    DomainSpec s;
    s.start = Start::AllLattice;
    s.regions = {region_from_zone(z, 2, Role::NoLattice)};
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (int a = 0; a < 3; ++a)
      for (int side : {-1, 1}) {
        double q[3] = {0, 0, 0};
        q[a] = side * (z.half[a] - hair);
        wrong += !(pr.where(in_zone(z, q[0], q[1], q[2])) == Where{Why::NoLattice, 2});
        q[a] = side * (z.half[a] + hair);
        wrong += !(pr.where(in_zone(z, q[0], q[1], q[2])) == Where{Why::Lattice, 0});
      }
    CHECK(wrong == 0);
  }
  // 6: Expand +1 and -1 move the four in-plane sides by that, and leave the two ends alone (D11).
  for (double e : {1.0, -1.0}) {
    const Zone z = box_zone({20, 20, 10}, {c30, s30, 0}, {-s30, c30, 0}, {0, 0, 1}, 8, 6, 5);
    DomainSpec s;
    s.regions = {region_from_zone(z, 1, Role::Lattice, e)};
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (int a = 0; a < 2; ++a)
      for (int side : {-1, 1}) {
        double q[3] = {0, 0, 0};
        q[a] = side * (z.half[a] + e - hair);
        wrong += !pr.where(in_zone(z, q[0], q[1], q[2])).lattice();
        q[a] = side * (z.half[a] + e + hair);
        wrong += pr.where(in_zone(z, q[0], q[1], q[2])).lattice();
      }
    for (int side : {-1, 1}) {
      wrong += !pr.where(in_zone(z, 0, 0, side * (z.half[2] - hair))).lattice();
      wrong += pr.where(in_zone(z, 0, 0, side * (z.half[2] + hair))).lattice();
    }
    CHECK(wrong == 0);
  }
  // 7: Grade to shape in a box zone: the band is measured from the box's outline, not the part's.
  {
    PartMeasure big(weld_mesh(box(60, 60, 20)));
    const Zone z = box_zone({30, 30, 10}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 20, 20, 8);
    DomainSpec s;
    s.bead_mm = 0.2;
    s.regions = {region_from_zone(z, 1, Role::Lattice)};
    Domain d(big, s);
    CellSpec cs;
    cs.cell_max_mm = 8;
    cs.grade_to_shape = true;
    cs.band_mm = 8;
    const Layout l = lay_cells(d, cs);
    double finest = 1e9, largest = 0.0;
    for (const Cell& c : l.cells) { finest = std::min(finest, c.size); largest = std::max(largest, c.size); }
    int wrong_t = 0, at_edge = 0, at_edge_large = 0;
    for (const Cell& c : l.cells) {
      const Vec3 m = cell_centre(l, c);
      const double dist = std::max(0.0, std::min(20 - std::fabs(m.x - 30), 20 - std::fabs(m.y - 30)));
      if (std::fabs(c.band - std::min(1.0, dist / 8.0)) > 1e-9) ++wrong_t;
      if (dist <= 0.5 * c.size + 1e-9) { ++at_edge; if (c.size > finest + 1e-9) ++at_edge_large; }
    }
    CHECK(!l.cells.empty() && largest == 8.0 && finest < 8.0 - 1e-9);
    CHECK(wrong_t == 0 && at_edge > 0 && at_edge_large == 0);
  }
  // 8: a box zone over part of a face region. The existing order (D6): the nearer face owns the space; the zone's
  // face is the side it starts on (centre - a2 half2). Face region 1 under the top (z 20, 10 deep, down); zone 2 from
  // z 9 up to 15: at z the face is 20 - z away and the zone's side z - 9, so the zone owns below z 14.5, the face above.
  {
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {20, 20, 20}, {0, 0, -1}, 20, 20, 10),
                 region_from_zone(box_zone({20, 20, 12}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 6, 6, 3), 2, Role::Lattice)};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({20, 20, 9.5}) == Where{Why::Lattice, 2}));    // the zone alone
    CHECK((pr.where({20, 20, 12}) == Where{Why::Lattice, 2}));     // both: the zone's side is nearer
    CHECK((pr.where({20, 20, 14.9}) == Where{Why::Lattice, 1}));   // both: the face is nearer
    CHECK((pr.where({30, 20, 12}) == Where{Why::Lattice, 1}));     // the face alone
    CHECK((pr.where({20, 20, 8.5}) == Where{Why::NotAsked, 0}));
  }
  // 9: bad zones are left out and listed; the rest still lay.
  {
    const StepModel model = zone_block(40, 40, 20);
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.cells.cell_max_mm = 4;
    const Zone good = box_zone({20, 20, 10}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 8, 6, 5);
    Zone flat = good;  flat.half[1] = 0.0;                 // zero size
    Zone skew = good;  skew.axis[1] = {0.1, 0.995, 0.0};   // not square (and not unit)
    Zone tilt = good;  tilt.axis[1] = {std::sqrt(0.5), std::sqrt(0.5), 0.0};   // unit, not square
    Zone nan = good;   nan.centre.x = std::nan("");
    Zone cyl0 = cylinder_zone({20, 20, 10}, {0, 0, 1}, 0.0, 5);
    Settings::RegionAsk both{6, Role::Lattice, {1}, 5.0, 0.0};
    both.zone = good;
    st.regions = {{1, Role::Lattice, {}, 0.0, 0.0}, {2, Role::Lattice, {}, 0.0, 0.0}, {3, Role::Lattice, {}, 0.0, 0.0},
                  {4, Role::Lattice, {}, 0.0, 0.0}, {5, Role::Lattice, {}, 0.0, 0.0}, both,
                  {7, Role::Lattice, {}, 0.0, 0.0}};
    st.regions[0].zone = good;
    st.regions[1].zone = flat;
    st.regions[2].zone = skew;
    st.regions[3].zone = tilt;
    st.regions[4].zone = nan;
    st.regions[6].zone = cyl0;
    const Outcome out = Session(model).lay(st);
    CHECK((out.empty_regions == std::vector<int>{2, 3, 4, 5, 6, 7}));
    Settings only = st;
    only.regions = {st.regions[0]};
    const Outcome alone = Session(model).lay(only);
    CHECK(!out.layout.cells.empty() && out.layout.cells == alone.layout.cells && alone.empty_regions.empty());
    // 12: with no zone the layout is today's: a Session of face regions lays what the face regions laid directly do.
    Settings faces = st;
    faces.bars = false;   // the cells as lay_cells gives them
    faces.regions = {{1, Role::Lattice, {1}, 6.0, -2.0}};
    const Outcome by_faces = Session(model).lay(faces);
    PartMeasure m(weld_mesh(model.mesh));
    DomainSpec ds;
    ds.min_strut_lines = kFewestStrutLines;
    ds.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 6.0, -2.0)};
    Domain dd(m, ds);
    CellSpec cs = faces.cells;
    Layout direct = lay_cells(dd, cs);
    set_struts(direct, faces.struts);
    CHECK(!by_faces.layout.cells.empty() && by_faces.layout.cells == direct.cells);
  }
  // 10: through a Session, moving a zone reads the part again; a cell-size setting does not.
  {
    const StepModel model = zone_block(40, 40, 20);
    Session session(model);
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.cells.cell_max_mm = 4;
    st.regions = {{1, Role::Lattice, {}, 0.0, 0.0}};
    st.regions[0].zone = box_zone({20, 20, 10}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, 8, 6, 5);
    const Outcome first = session.lay(st);
    CHECK(first.read_again && !first.layout.cells.empty() && first.empty_regions.empty());
    st.cells.cell_max_mm = 3;
    const Outcome smaller = session.lay(st);
    CHECK(!smaller.read_again);
    st.regions[0].zone.centre.x = 21;   // moved
    const Outcome moved = session.lay(st);
    CHECK(moved.read_again && moved.layout.cells == Session(model).lay(st).layout.cells);
    if (!moved.layout.cells.empty() && !smaller.layout.cells.empty())   // the cells moved with it
      NEAR(cell_centre(moved.layout, moved.layout.cells.front()).x -
               cell_centre(smaller.layout, smaller.layout.cells.front()).x, 1.0, 1e-9);
    st.regions[0].zone.axis[0] = {c30, s30, 0};   // turned
    st.regions[0].zone.axis[1] = {-s30, c30, 0};
    CHECK(session.lay(st).read_again);
    st.regions[0].zone.half[2] = 4;               // shallower
    CHECK(session.lay(st).read_again);
    CHECK(!session.lay(st).read_again);           // and asked again: kept
  }
}

// D22: a region, and a Protect skin, given as pieces of faces (the app's Edit faces). zone_block(40, 40, 20): face 1
// is the top (z = 20), 0 the bottom, 2 the front (y = 0), 3 x = 40, 4 the back, 5 x = 0.
static FacePiece face_piece(std::vector<int> faces, std::vector<FaceCut> cuts) {
  FacePiece p;
  p.faces = std::move(faces);
  p.cuts = std::move(cuts);
  return p;
}
// A block 40 (x) by 20 (y) whose top is a cylinder about y (radius 25, axis at x 20, z -5, so its top is z 20 at
// x 20 and z 10 at either side), in 96 flat strips: faces 0 the bottom, 1 the right side, 2 the arch (Cylinder),
// 3 the left side, 4 the front (y = 0), 5 the back (y = 20).
static StepModel arch_block() {
  const double R = 25, cx = 20, cz = -5;
  std::vector<std::array<double, 2>> xz = {{0, 0}, {40, 0}, {40, 10}};
  const double a0 = std::asin(20.0 / R);   // the arch runs from +a0 (x 40) to -a0 (x 0), angle from the top
  for (int k = 1; k < 96; ++k) {
    const double a = a0 - 2.0 * a0 * k / 96.0;
    xz.push_back({cx + R * std::sin(a), cz + R * std::cos(a)});
  }
  xz.push_back({0, 10});
  const int n = static_cast<int>(xz.size());
  ModelBuilder b;
  const int bottom = b.face(StepSurfaceKind::Plane, {0, 0, -1}, {0, 0, 0});
  const int right = b.face(StepSurfaceKind::Plane, {1, 0, 0}, {40, 0, 0});
  const int arch = b.face(StepSurfaceKind::Cylinder, {0, 0, 0}, {0, 0, 0});
  const int left = b.face(StepSurfaceKind::Plane, {-1, 0, 0}, {0, 0, 0});
  const int front = b.face(StepSurfaceKind::Plane, {0, -1, 0}, {0, 0, 0});
  const int back = b.face(StepSurfaceKind::Plane, {0, 1, 0}, {0, 20, 0});
  const Vec3 mid{20, 10, 8};
  auto out_tri = [&](int f, Vec3 p, Vec3 q, Vec3 r) {   // wound to face away from the middle (the block is convex)
    const Vec3 u{q.x - p.x, q.y - p.y, q.z - p.z}, v{r.x - p.x, r.y - p.y, r.z - p.z};
    const Vec3 nn{u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x};
    const Vec3 c{(p.x + q.x + r.x) / 3 - mid.x, (p.y + q.y + r.y) / 3 - mid.y, (p.z + q.z + r.z) / 3 - mid.z};
    if (nn.x * c.x + nn.y * c.y + nn.z * c.z >= 0) b.tri(f, p, q, r); else b.tri(f, p, r, q);
  };
  for (int i = 0; i < n; ++i) {
    const int j = (i + 1) % n;
    const int f = i == 0 ? bottom : i == 1 ? right : i == n - 1 ? left : arch;
    const Vec3 p0{xz[i][0], 0, xz[i][1]}, p1{xz[j][0], 0, xz[j][1]}, q0{xz[i][0], 20, xz[i][1]}, q1{xz[j][0], 20, xz[j][1]};
    out_tri(f, p0, p1, q1);
    out_tri(f, p0, q1, q0);
  }
  for (int i = 1; i + 1 < n; ++i) {
    out_tri(front, {xz[0][0], 0, xz[0][1]}, {xz[i][0], 0, xz[i][1]}, {xz[i + 1][0], 0, xz[i + 1][1]});
    out_tri(back, {xz[0][0], 20, xz[0][1]}, {xz[i][0], 20, xz[i][1]}, {xz[i + 1][0], 20, xz[i + 1][1]});
  }
  b.m.solid_count = 1;
  return b.m;
}

static void test_face_pieces() {
  const StepModel model = zone_block(40, 40, 20);
  PartMeasure pm(weld_mesh(model.mesh));
  const double hair = 0.01;
  // A slanted cut across the top: kept (left) where (p - c) . n >= 0.
  const Vec3 c{20, 20, 0};
  const double nl = std::sqrt(1.0 + 0.09);
  const Vec3 n{-1.0 / nl, -0.3 / nl, 0}, along{-0.3 / nl, 1.0 / nl, 0};
  const FaceCut keep_left{c, {-1, -0.3, 0}, false}, keep_right{c, {1, 0.3, 0}, true};
  auto off = [&](double s, double side, double z) {   // s along the cut, side across it (+ = the left piece)
    return Vec3{c.x + along.x * s + n.x * side, c.y + along.y * s + n.y * side, z};
  };
  CellSpec cs;
  cs.cell_max_mm = 4;

  // 1: the left piece alone: lattice a hair left of the cut and not a hair right, along it and at three depths;
  // cells only under the piece.
  {
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_pieces(model, {face_piece({1}, {keep_left})}, 1, Role::Lattice, 6.0, 0.0, &ok)};
    CHECK(ok && !s.regions[0].is_shell());
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (double t : {-15.0, -7.0, 0.0, 7.0, 15.0})
      for (double z : {19.5, 17.0, 14.5}) {
        wrong += !(pr.where(off(t, hair, z)) == Where{Why::Lattice, 1});
        wrong += !(pr.where(off(t, -hair, z)) == Where{Why::NotAsked, 0});
      }
    CHECK(wrong == 0);
    const Layout l = lay_cells(d, cs);
    int astray = 0;
    for (const Cell& cell : l.cells) {   // each cube reaches the kept side of the cut
      const Vec3 m = cell_centre(l, cell);
      const double side = (m.x - c.x) * n.x + (m.y - c.y) * n.y;
      astray += cell.region != 1 || side < -0.5 * cell.size * (std::fabs(n.x) + std::fabs(n.y)) - 1e-9;
    }
    CHECK(!l.cells.empty() && astray == 0);
  }

  // 2: the left piece one region, the right piece another (its cut strict): every point under the face is held by
  // exactly one, points exactly on a cut along x included. Which one takes those is the prism's own edge rule: printed.
  {
    const FacePiece L = face_piece({1}, {keep_left}), Rp = face_piece({1}, {keep_right});
    DomainSpec a, b;
    a.regions = {region_from_pieces(model, {L}, 1, Role::Lattice, 6.0)};
    b.regions = {region_from_pieces(model, {Rp}, 2, Role::Lattice, 6.0)};
    Domain da(pm, a), db(pm, b);
    auto pa = da.probe(), pb = db.probe();
    int twice = 0, never = 0, points = 0;
    for (double x = 0.37; x < 40; x += 0.83)
      for (double y = 0.41; y < 40; y += 0.79) {
        const Vec3 p{x, y, 17.3};
        const int held = (pa.where(p) == Where{Why::Lattice, 1}) + (pb.where(p) == Where{Why::Lattice, 2});
        twice += held > 1;
        never += held < 1;
        ++points;
      }
    CHECK(points > 2000 && twice == 0 && never == 0);
    // Exactly on an axis cut x = 20, both senses of strict.
    for (bool left_strict : {false, true}) {
      DomainSpec e, f;
      e.regions = {region_from_pieces(model, {face_piece({1}, {{{20, 0, 0}, {-1, 0, 0}, left_strict}})}, 1, Role::Lattice, 6.0)};
      f.regions = {region_from_pieces(model, {face_piece({1}, {{{20, 0, 0}, {1, 0, 0}, !left_strict}})}, 2, Role::Lattice, 6.0)};
      Domain de(pm, e), df(pm, f);
      auto pe = de.probe(), pf = df.probe();
      int on_twice = 0, on_never = 0, to_left = 0, to_right = 0;
      for (double y = 0.5; y < 40; y += 1.5) {
        const Vec3 p{20, y, 17.0};
        const bool l = pe.where(p) == Where{Why::Lattice, 1}, r = pf.where(p) == Where{Why::Lattice, 2};
        on_twice += l && r;
        on_never += !l && !r;
        to_left += l && !r;
        to_right += r && !l;
      }
      CHECK(on_twice == 0 && on_never == 0);
      std::printf("face pieces, on the cut x = 20 (left %s, right %s): %d points to the left piece, %d to the right\n",
                  left_strict ? "strict" : "not strict", left_strict ? "not strict" : "strict", to_left, to_right);
    }
  }

  // 3: ONE region of both pieces is the region of the whole face: the same `where` at 2,000 points and the same cells.
  {
    bool ok = false;
    DomainSpec a, b;
    a.regions = {region_from_pieces(model, {face_piece({1}, {keep_left}), face_piece({1}, {keep_right})}, 1,
                                    Role::Lattice, 6.0, 0.0, &ok)};
    b.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 6.0)};
    CHECK(ok && a.regions[0].prism.outline_uv.size() == 1);
    Domain da(pm, a), db(pm, b);
    auto pa = da.probe(), pb = db.probe();
    int differ = 0, points = 0;
    for (int i = 0; i < 2000; ++i) {
      const Vec3 p{-1 + 42 * std::fmod(i * 0.6180339887, 1.0), -1 + 42 * std::fmod(i * 0.7548776662, 1.0),
                   10 + 11 * std::fmod(i * 0.5698402910, 1.0)};
      differ += !(pa.where(p) == pb.where(p));
      ++points;
    }
    CHECK(points == 2000 && differ == 0);
    const Layout la = lay_cells(da, cs), lb = lay_cells(db, cs);
    CHECK(!la.cells.empty() && la.cells == lb.cells && la.solid == lb.solid);
  }

  // 4: a T. The top cut at x 14, x 26 and y 28 into six pieces (each takes its lower side as it is, its upper side
  // strict, as core's own splits do); the region is the bar (y >= 28) and the stem (14 <= x <= 26).
  {
    auto cell_piece = [&](int i, int j) {   // i: x band 0..2, j: y band 0..1
      const double xs[4] = {0, 14, 26, 40}, ys[3] = {0, 28, 40};
      std::vector<FaceCut> cuts;
      if (i > 0) cuts.push_back({{xs[i], 0, 0}, {1, 0, 0}, false});
      if (i < 2) cuts.push_back({{xs[i + 1], 0, 0}, {-1, 0, 0}, true});
      if (j > 0) cuts.push_back({{0, ys[j], 0}, {0, 1, 0}, false});
      if (j < 1) cuts.push_back({{0, ys[j + 1], 0}, {0, -1, 0}, true});
      return face_piece({1}, cuts);
    };
    bool ok = false;
    DomainSpec s;
    s.rim_mm = 1.0;
    s.regions = {region_from_pieces(model, {cell_piece(0, 1), cell_piece(1, 1), cell_piece(2, 1), cell_piece(1, 0)}, 1,
                                    Role::Lattice, 6.0, 0.0, &ok)};
    CHECK(ok && !s.regions[0].is_shell() && s.regions[0].prism.outline_uv.size() == 1);   // one outline
    DomainSpec plain = s;
    plain.rim_mm = 0.0;
    Domain d(pm, plain), rim(pm, s);
    auto pr = d.probe(), rr = rim.probe();
    auto in_t = [](double x, double y) { return x > 0 && x < 40 && y > 0 && y < 40 && (y >= 28 || (x >= 14 && x <= 26)); };
    // A hair inside and outside each of the T's eight edges, at three places along each.
    struct Edge { double x0, y0, x1, y1; };
    const Edge edges[8] = {{0, 28, 0, 40}, {0, 40, 40, 40}, {40, 40, 40, 28}, {40, 28, 26, 28},
                           {26, 28, 26, 0}, {26, 0, 14, 0}, {14, 0, 14, 28}, {14, 28, 0, 28}};
    int wrong = 0, tried = 0;
    for (const Edge& e : edges)
      for (double t : {0.2, 0.5, 0.8}) {
        const double x = e.x0 + (e.x1 - e.x0) * t, y = e.y0 + (e.y1 - e.y0) * t;
        const double len = std::hypot(e.x1 - e.x0, e.y1 - e.y0);
        const double nx = (e.y1 - e.y0) / len, ny = -(e.x1 - e.x0) / len;   // one side of it
        for (double side : {hair, -hair}) {
          const double px = x + nx * side, py = y + ny * side;
          const bool want = in_t(px, py);
          wrong += pr.where({px, py, 17}).lattice() != want;
          ++tried;
        }
      }
    CHECK(tried == 48 && wrong == 0);
    // Finish Rim follows the T: on its edges inside the part (the stem's sides, the bar's underside), not on the part's.
    int rim_wrong = 0;
    for (double y : {5.0, 15.0, 25.0}) {
      rim_wrong += !(rr.where({14.5, y, 17}) == Where{Why::Rim, 1}) + !(rr.where({25.5, y, 17}) == Where{Why::Rim, 1});
      rim_wrong += !(rr.where({16, y, 17}) == Where{Why::Lattice, 1});
    }
    for (double x : {5.0, 35.0}) {
      rim_wrong += !(rr.where({x, 28.5, 17}) == Where{Why::Rim, 1});
      rim_wrong += !(rr.where({x, 30, 17}) == Where{Why::Lattice, 1});
    }
    rim_wrong += !(rr.where({0.5, 34, 17}) == Where{Why::Lattice, 1});   // the part's own edge: no rim
    CHECK(rim_wrong == 0);
  }

  // 5: Protect skin on the left piece (x <= 20) over a Lattice region of the whole top, 12 deep: the skin under that
  // piece only, the lattice under the other running to the surface; the cells start below the skin only there.
  {
    DomainSpec s;
    s.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 12.0)};
    s.protect = {{7, pieces_mesh(model, {face_piece({1}, {{{20, 0, 0}, {-1, 0, 0}, false}})}), 1.2}};
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({10, 20, 19.4}) == Where{Why::ProtectSkin, 7}));
    CHECK((pr.where({10, 20, 18.7}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({30, 20, 19.99}) == Where{Why::Lattice, 1}));
    CHECK((pr.where({21.5, 20, 19.4}) == Where{Why::Lattice, 1}));   // more than the skin's depth past the cut
    CellSpec u;
    u.algorithm = Algorithm::Uniform;
    u.cell_max_mm = 8;
    const Layout l = lay_cells(d, u);
    int behind = 0, open = 0, odd = 0;
    for (const Cell& cell : l.cells) {
      const Vec3 at = cell_centre(l, cell);
      if (at.x < 14.0) {
        ++behind;
        if (std::fabs(cell.size - 5.4) > 1e-5 || cell.lo[2] < 1.2 - 1e-5) ++odd;
      } else if (at.x > 26.0) {
        ++open;
        if (std::fabs(cell.size - 6.0) > 1e-5 || (std::fabs(cell.lo[2]) > 1e-5 && std::fabs(cell.lo[2] - 6.0) > 1e-5)) ++odd;
      }
    }
    CHECK(behind > 0 && open > 0 && odd == 0);
  }

  // 5b: the cuts stand up out of the face. A Protect skin on the left piece (x <= 20) does not reach past the cut:
  // 0.05 mm, half its depth and 0.9 of its depth past it, at the surface and half its depth down, is the lattice
  // under the right side; the same distances on the kept side are skin. Given through a Session as well. A Lattice
  // region and a No lattice region on the same piece stop at the cut too.
  {
    const double depth = 1.2;
    const FacePiece left = face_piece({1}, {{{20, 0, 0}, {-1, 0, 0}, false}});
    DomainSpec s;
    s.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 12.0)};
    s.protect = {{7, pieces_mesh(model, {left}), depth, {left}}};
    Domain d(pm, s);
    Settings st5;
    st5.min_strut_lines = kFewestStrutLines;
    st5.cells.cell_max_mm = 8;
    st5.regions = {{1, Role::Lattice, {1}, 12.0, 0.0}};
    st5.protect = {{7, {1}, depth, {left}}};
    Session session(model);
    session.lay(st5);
    DomainSpec lat, nol;
    lat.regions = {region_from_pieces(model, {left}, 2, Role::Lattice, 6.0)};
    nol.start = Start::AllLattice;
    nol.regions = {region_from_pieces(model, {left}, 3, Role::NoLattice, 6.0)};
    Domain dl(pm, lat), dn(pm, nol);
    auto pr = d.probe(), ps = session.domain()->probe(), pl = dl.probe(), pn = dn.probe();
    int skin_past = 0, skin_kept = 0, region_past = 0;
    for (double past : {0.05, 0.5 * depth, 0.9 * depth})
      for (double down : {0.01, 0.5 * depth})
        for (double y : {5.0, 20.0, 35.0}) {
          const Vec3 out{20 + past, y, 20 - down}, in{20 - past, y, 20 - down};
          skin_past += !(pr.where(out) == Where{Why::Lattice, 1}) + !(ps.where(out) == Where{Why::Lattice, 1});
          skin_kept += !(pr.where(in) == Where{Why::ProtectSkin, 7}) + !(ps.where(in) == Where{Why::ProtectSkin, 7});
          region_past += !(pl.where(out) == Where{Why::NotAsked, 0}) + !(pn.where(out) == Where{Why::Lattice, 0});
          region_past += !(pl.where(in) == Where{Why::Lattice, 2}) + !(pn.where(in) == Where{Why::NoLattice, 3});
        }
    CHECK(skin_past == 0);
    CHECK(skin_kept == 0);
    CHECK(region_past == 0);
    std::printf("face pieces, cut skin: %d points past the cut taken by the skin, %d on the kept side missed, "
                "%d region answers wrong\n", skin_past, skin_kept, region_past);
  }

  // 6: No lattice on a piece inside Start from All lattice: solid under the piece only.
  {
    DomainSpec s;
    s.start = Start::AllLattice;
    s.regions = {region_from_pieces(model, {face_piece({1}, {keep_left})}, 2, Role::NoLattice, 6.0)};
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (double t : {-12.0, 0.0, 12.0}) {
      wrong += !(pr.where(off(t, hair, 17)) == Where{Why::NoLattice, 2});
      wrong += !(pr.where(off(t, -hair, 17)) == Where{Why::Lattice, 0});
      wrong += !(pr.where(off(t, 3, 13.9)) == Where{Why::Lattice, 0});   // below its depth
    }
    CHECK(wrong == 0);
  }

  // 7: a curved face cut by a plane (x >= 26): lattice under the kept side only; the cut is the region's edge.
  {
    const StepModel archm = arch_block();
    PartMeasure am(weld_mesh(archm.mesh));
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_pieces(archm, {face_piece({2}, {{{26, 0, 0}, {1, 0, 0}, false}})}, 3, Role::Lattice, 4.0,
                                    0.0, &ok)};
    CHECK(ok && s.regions[0].is_shell());
    int west = 0;
    for (const auto& e : s.regions[0].shell_edge) west += e[0].x < 26 - 1e-9 || e[1].x < 26 - 1e-9;
    CHECK(west == 0 && !s.regions[0].shell_edge.empty());
    Domain d(am, s);
    auto pr = d.probe();
    const double R = 25;
    auto under = [&](double x_on_face, double y, double depth) {   // `depth` in along the radius from the face at x
      const double a = std::asin((x_on_face - 20) / R);
      return Vec3{20 + (R - depth) * std::sin(a), y, -5 + (R - depth) * std::cos(a)};
    };
    int wrong = 0;
    for (double y : {5.0, 10.0, 15.0})
      for (double depth : {0.5, 2.0, 3.5}) {
        wrong += !(pr.where(under(26.1, y, depth)) == Where{Why::Lattice, 3});
        wrong += !(pr.where(under(25.9, y, depth)) == Where{Why::NotAsked, 0});
        wrong += !(pr.where(under(33, y, depth)) == Where{Why::Lattice, 3});
        wrong += !(pr.where(under(14, y, depth)) == Where{Why::NotAsked, 0});
      }
    CHECK(wrong == 0);
  }

  // 8: Expand +1 and -1 on the left piece (cut x <= 20) move its whole outline, the cut edge included.
  for (double e : {1.0, -1.0}) {
    DomainSpec s;
    s.regions = {region_from_pieces(model, {face_piece({1}, {{{20, 0, 0}, {-1, 0, 0}, false}})}, 1, Role::Lattice, 6.0, e)};
    Domain d(pm, s);
    auto pr = d.probe();
    int wrong = 0;
    for (double y : {10.0, 20.0, 30.0}) {
      wrong += !pr.where({20 + e - 0.05, y, 17}).lattice();
      wrong += pr.where({20 + e + 0.05, y, 17}).lattice();
    }
    if (e < 0) {   // the part's own edges move in too
      wrong += !pr.where({10, 1.05, 17}).lattice() + pr.where({10, 0.95, 17}).lattice();
      wrong += !pr.where({1.05, 20, 17}).lattice() + pr.where({0.95, 20, 17}).lattice();
    }
    CHECK(wrong == 0);
  }

  // 9, 10, 12: through a Session.
  Settings st;
  st.min_strut_lines = kFewestStrutLines;
  st.cells.cell_max_mm = 4;
  {  // 9: a cut that keeps nothing, a zero or not finite normal, a piece with no faces, a face with no triangles,
     // pieces with a zone: left out and listed; the rest still lay. A piece that keeps nothing beside one that does
     // is not refused.
    const FacePiece good = face_piece({1}, {keep_left});
    st.regions.assign(9, Settings::RegionAsk{});
    for (int i = 0; i < 9; ++i) {
      st.regions[i].id = i + 1;
      st.regions[i].depth_mm = 6.0;
    }
    st.regions[0].pieces = {good};
    st.regions[1].pieces = {face_piece({1}, {{{100, 0, 0}, {1, 0, 0}, false}})};   // keeps nothing
    st.regions[2].pieces = {face_piece({1}, {{{20, 0, 0}, {0, 0, 0}, false}})};    // zero normal
    st.regions[3].pieces = {face_piece({}, {})};                                  // no faces
    st.regions[4].pieces = {face_piece({99}, {})};                                // a face the part does not have
    st.regions[5].pieces = {face_piece({1}, {{{20, 0, 0}, {std::nan(""), 0, 0}, false}})};
    st.regions[6].pieces = {good};
    st.regions[6].zone.kind = Zone::Kind::Box;   // a zone with pieces
    st.regions[6].zone.centre = {20, 20, 10};
    st.regions[6].zone.axis[0] = {1, 0, 0}; st.regions[6].zone.axis[1] = {0, 1, 0}; st.regions[6].zone.axis[2] = {0, 0, 1};
    st.regions[6].zone.half[0] = st.regions[6].zone.half[1] = st.regions[6].zone.half[2] = 4;
    st.regions[7].pieces = {face_piece({1}, {{{100, 0, 0}, {1, 0, 0}, false}}), face_piece({0}, {})};   // half kept
    st.regions[7].depth_mm = 3.0;
    st.regions[8].pieces = {good, face_piece({0}, {{{20, 0, 0}, {0, 0, 0}, false}})};   // one bad piece of two
    const Outcome out = Session(model).lay(st);
    CHECK((out.empty_regions == std::vector<int>{2, 3, 4, 5, 6, 7, 9}));
    Settings only = st;
    only.regions = {st.regions[0], st.regions[7]};
    const Outcome alone = Session(model).lay(only);
    CHECK(!out.layout.cells.empty() && out.layout.cells == alone.layout.cells && alone.empty_regions.empty());
    bool p8 = false;
    for (const Cell& cell : alone.layout.cells) p8 = p8 || cell.region == 8;
    CHECK(p8);
    bool made = true;   // a Protect skin of a refused piece has no surface
    pieces_mesh(model, {face_piece({1}, {{{20, 0, 0}, {0, 0, 0}, false}})}, &made);
    CHECK(!made);
  }
  {  // 10: moving a cut reads the part again; so does turning it strict; a cell size does not.
    Session session(model);
    Settings s = st;
    s.regions = {Settings::RegionAsk{}};
    s.regions[0].id = 1;
    s.regions[0].depth_mm = 6.0;
    s.regions[0].pieces = {face_piece({1}, {{{20, 0, 0}, {-1, 0, 0}, false}})};
    CHECK(session.lay(s).read_again);
    s.cells.cell_max_mm = 3;
    CHECK(!session.lay(s).read_again);
    s.regions[0].pieces[0].cuts[0].point.x = 21;
    const Outcome moved = session.lay(s);
    CHECK(moved.read_again && moved.layout.cells == Session(model).lay(s).layout.cells);
    s.regions[0].pieces[0].cuts[0].strict = true;
    CHECK(session.lay(s).read_again);
    s.protect = {{5, {}, 1.0, {face_piece({1}, {{{20, 0, 0}, {1, 0, 0}, false}})}}};
    CHECK(session.lay(s).read_again);
    s.protect[0].pieces[0].cuts[0].normal.y = 0.1;
    CHECK(session.lay(s).read_again);
    CHECK(!session.lay(s).read_again);
  }
  {  // 12: no pieces is today's: three parts, each region and skin also given as one piece of its faces with no cut,
     // lay the same cells, solid and bars.
    int L = 0, square = 0, sideA = 0, sideB = 0;
    const StepModel plate = plate_with_L_face(&L, &square, &sideA, &sideB);
    const StepModel finish = finish_block();
    int differ = 0, laid = 0;
    for (int part = 0; part < 3; ++part) {
      Settings s;
      s.min_strut_lines = kFewestStrutLines;
      s.cells.cell_max_mm = 6;
      s.rim_mm = -1.0;
      if (part == 0) {
        s.regions = {{1, Role::Lattice, {1}, 6.0, -2.0}, {2, Role::NoLattice, {2}, 4.0, 0.0}};
        s.protect = {{5, {1}, 1.0}};
      } else if (part == 1) {
        s.regions = {{1, Role::Lattice, {L}, 6.0, -1.0}, {2, Role::Lattice, {sideA, sideB}, 4.0, 0.0}};
        s.protect = {{5, {square}, 0.0}};
      } else {
        s.start = Start::AllLattice;
        s.regions = {{1, Role::Lattice, {1}, 6.0, 0.0}, {2, Role::NoLattice, {0}, 3.0, 0.0}};
      }
      Settings p = s;
      for (Settings::RegionAsk& r : p.regions) r.pieces = {face_piece(r.faces, {})};
      for (Settings::ProtectAsk& k : p.protect) k.pieces = {face_piece(k.faces, {})};
      const StepModel& m = part == 0 ? model : part == 1 ? plate : finish;
      const Outcome a = Session(m).lay(s), b = Session(m).lay(p);
      differ += !(a.layout.cells == b.layout.cells && a.layout.solid == b.layout.solid && same_bars(a.bars, b.bars) &&
                  a.empty_regions.empty() && b.empty_regions.empty());
      laid += !a.layout.cells.empty() && !a.bars.bars.empty();
    }
    CHECK(differ == 0 && laid == 3);
  }
}

// ── C24: the largest size step between neighbouring cells ─────────────────────
// Pairs of cells of one region and one frame that share any part of a face and differ in size by more than `limit`.
static int step_breaks(const Layout& l, double limit, int region = -1) {
  int n = 0;
  const double tol = 1e-6;
  for (std::size_t i = 0; i < l.cells.size(); ++i)
    for (std::size_t j = i + 1; j < l.cells.size(); ++j) {
      const Cell& A = l.cells[i];
      const Cell& B = l.cells[j];
      if (A.region != B.region || A.frame != B.frame || (region >= 0 && A.region != region)) continue;
      if (std::max(A.size, B.size) <= limit * std::min(A.size, B.size) * (1 + 1e-9)) continue;
      int touch = 0, over = 0;
      for (int a = 0; a < 3; ++a) {
        if (std::fabs(A.lo[a] + A.size - B.lo[a]) <= tol || std::fabs(B.lo[a] + B.size - A.lo[a]) <= tol) ++touch;
        else if (std::min(A.lo[a] + A.size, B.lo[a] + B.size) - std::max(A.lo[a], B.lo[a]) > tol) ++over;
      }
      n += touch == 1 && over == 2;
    }
  return n;
}
// The largest step between face neighbours of the layout (1 when none differ).
static double largest_step(const Layout& l) {
  double m = 1.0;
  for (double r = 1.0; r < 16.0; r *= 1.0625)
    if (step_breaks(l, r) > 0) m = r * 1.0625;
  return m;
}

static void test_size_step() {
  int before = g_fail;
  auto block = [&](const char* name) {
    std::printf("C24 %s: %d failed\n", name, g_fail - before);
    before = g_fail;
  };
  // The plate of test_cells_by_stress: 96 x 24 x 8 latticed from its top face, 8 mm deep, at a 0.2 mm line: one
  // layer of 8 mm cells, ladder 8, 4, 2 (Default Grade) or 8 and its fractions (Stepped). One hot voxel (x 47..48,
  // y 11..12, z 6..7, 1 to 2 mm under the face, at the reference) inside the base cube x 40..48: that cube goes down to 2 mm cells at its face
  // x = 48, against the 8 mm cube beside it.
  PartMeasure pm(weld_mesh(box(96, 24, 8)));
  DomainSpec s;
  s.bead_mm = 0.2;
  s.regions = {face_region(1, Role::Lattice, {48, 12, 8}, {0, 0, -1}, 12, 48, 8)};
  Domain d(pm, s);
  const auto hot = stress_field({-2, -2, -2}, 1.0, 100, 28, 12, [](const Vec3& c) {
    return (c.x > 47 && c.x < 48 && c.y > 11 && c.y < 12 && c.z > 6 && c.z < 7) ? 100.0 : 0.0;
  });
  CellSpec off;
  off.cell_max_mm = 8;
  off.by_stress = true;
  off.demand = hot;
  off.reference_mpa = 100.0;
  auto with = [](CellSpec c, double step, Algorithm algo = Algorithm::DefaultGrade) {
    c.algorithm = algo;
    c.max_step = step;
    return c;
  };

  {  // 1. max_step 0 is today's layout, byte for byte, on three parts (and a negative value is none as well).
    CHECK(step_held(off) == 0.0 && step_held(with(off, -1)) == 0.0);
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CHECK(same_layout(lay_cells(d, with(off, 0, algo)), lay_cells(d, with(off, 0, algo))));
      CellSpec today = off;
      today.algorithm = algo;
      CHECK(same_layout(lay_cells(d, with(off, 0, algo)), lay_cells(d, today)));
      CHECK(same_layout(lay_cells(d, with(off, -1, algo)), lay_cells(d, today)));
    }
    // The pocket part (a 4 mm wall, a 5 mm pocket, the wall behind: walls of their own under one face).
    PartMeasure pp(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 9}, {50, 9}, {50, 4}, {0, 4}}, 0, 40)));
    DomainSpec ps;
    ps.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 13)};
    Domain dp(pp, ps);
    CellSpec band;
    band.grade_to_shape = true;
    band.band_mm = 8;
    CHECK(same_layout(lay_cells(dp, with(band, 0)), lay_cells(dp, band)));
    // The whole part, All lattice.
    PartMeasure pw(weld_mesh(box(40, 30, 20)));
    DomainSpec ws;
    ws.start = Start::AllLattice;
    Domain dw(pw, ws);
    CellSpec whole;
    whole.algorithm = Algorithm::Stepped;
    CHECK(same_layout(lay_cells(dw, with(whole, 0, Algorithm::Stepped)), lay_cells(dw, whole)));
  }
  block("1 none is today's");

  {  // 2. Default Grade: without the limit an 8 mm cell shares a face with a 2 mm cell; with max_step 2 no pair of face
     // neighbours differs by more than 2 x, and cells farther than three base cells from any changed place are
     // unchanged.
    const Layout free_ = lay_cells(d, off), kept = lay_cells(d, with(off, 2));
    CHECK(step_breaks(free_, 2.0) > 0 && step_breaks(free_, 3.9) > 0);   // 8 against 2
    CHECK(step_breaks(kept, 2.0) == 0);
    CHECK(kept.solid.empty() && kept.cells.size() > free_.cells.size());
    std::vector<Vec3> changed;
    for (const Cell& c : kept.cells)
      if (std::find(free_.cells.begin(), free_.cells.end(), c) == free_.cells.end()) changed.push_back(cell_centre(kept, c));
    for (const Cell& c : free_.cells)
      if (std::find(kept.cells.begin(), kept.cells.end(), c) == kept.cells.end()) changed.push_back(cell_centre(free_, c));
    int far = 0, far_changed = 0;
    for (const Cell& c : free_.cells) {
      const Vec3 m = cell_centre(free_, c);
      double near = 1e300;
      for (const Vec3& p : changed) near = std::min(near, std::max({std::fabs(p.x - m.x), std::fabs(p.y - m.y), std::fabs(p.z - m.z)}));
      if (near <= 24.0) continue;
      ++far;
      far_changed += std::find(kept.cells.begin(), kept.cells.end(), c) == kept.cells.end();
    }
    CHECK(!changed.empty() && far > 10 && far_changed == 0);
    std::printf("C24 hot spot, Default Grade: largest step %.2f without the limit (%zu cells), %.2f with 2 (%zu cells)\n",
                largest_step(free_), free_.cells.size(), largest_step(kept), kept.cells.size());
  }
  block("2 Default Grade, stress");

  {  // 3. The same with Grade to shape and a narrow band in place of the stress: a plate 89 long, so the end cubes
     // overhang its outline by 3.5 mm; band 8: the inner half of an end cube is too near the outline for a 4 mm
     // cell, so 2 mm cells stand against the 8 mm cube beside it.
    PartMeasure pb(weld_mesh(box(89, 24, 8)));
    DomainSpec bs;
    bs.bead_mm = 0.2;
    bs.regions = {face_region(1, Role::Lattice, {44.5, 12, 8}, {0, 0, -1}, 12, 44.5, 8)};
    Domain db(pb, bs);
    CellSpec band;
    band.cell_max_mm = 8;
    band.grade_to_shape = true;
    band.band_mm = 8;
    const Layout free_ = lay_cells(db, band), kept = lay_cells(db, with(band, 2));
    CHECK(step_breaks(free_, 3.9) > 0);
    CHECK(step_breaks(kept, 2.0) == 0);
    CHECK(kept.solid.size() <= free_.solid.size() && kept.cells.size() > free_.cells.size());
    std::printf("C24 band, Default Grade: largest step %.2f without the limit (%zu cells), %.2f with 2 (%zu cells)\n",
                largest_step(free_), free_.cells.size(), largest_step(kept), kept.cells.size());
  }
  block("3 Default Grade, band");

  {  // 4. Stepped with max_step 2 and with 3: the rule holds for every pair; with 3 at least one cell is larger.
    const Layout free_ = lay_cells(d, with(off, 0, Algorithm::Stepped));
    const Layout two = lay_cells(d, with(off, 2, Algorithm::Stepped)), three = lay_cells(d, with(off, 3, Algorithm::Stepped));
    CHECK(step_breaks(free_, 3.0) > 0);
    CHECK(step_breaks(two, 2.0) == 0 && step_breaks(three, 3.0) == 0);
    int larger = 0, smaller = 0, grew = 0;   // grew: points in a larger cell with a limit than without
    for (double x = 0.3; x < 96; x += 0.5)
      for (double y = 0.3; y < 24; y += 0.5)
        for (double z = 0.3; z < 8; z += 1.0) {
          const double a = size_holding(two, {x, y, z}), b = size_holding(three, {x, y, z});
          const double f0 = size_holding(free_, {x, y, z});
          grew += a > f0 + 1e-9 || b > f0 + 1e-9;
          larger += b > a + 1e-9;
          smaller += b < a - 1e-9;
        }
    CHECK(larger > 0 && grew == 0);
    std::printf("C24 Stepped: points in a larger cell with a limit than without: %d\n", grew);
    CHECK(two.solid.size() <= free_.solid.size() && three.solid.size() <= free_.solid.size());
    std::printf("C24 hot spot, Stepped: largest step %.2f free (%zu cells), %.2f with 2 (%zu), %.2f with 3 (%zu); "
                "points in a larger cell with 3 than with 2: %d (in a smaller: %d)\n",
                largest_step(free_), free_.cells.size(), largest_step(two), two.cells.size(), largest_step(three),
                three.cells.size(), larger, smaller);
  }
  block("4 Stepped");

  {  // 5. 1.5 on Default Grade is held at 2: the layout is the max_step 2 layout. (Stepped keeps 1.5; nothing under 1.)
    CHECK(step_held(with(off, 1.5)) == 2.0 && step_held(with(off, 3)) == 3.0);
    CHECK(step_held(with(off, 1.5, Algorithm::Stepped)) == 1.5 && step_held(with(off, 0.5, Algorithm::Stepped)) == 1.0);
    CHECK(same_layout(lay_cells(d, with(off, 1.5)), lay_cells(d, with(off, 2))));
    CHECK(!same_layout(lay_cells(d, with(off, 1.5)), lay_cells(d, off)));   // and it is a limit, not none
    // Through a session: step_held_at is the value used, 0 when none was asked.
    int L = 0, square = 0, sideA = 0, sideB = 0;
    Session session(plate_with_L_face(&L, &square, &sideA, &sideB));
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.regions = {{1, Role::Lattice, {square}, 6.0, 0.0}};
    st.bead_mm = 0.2;
    st.cells.cell_max_mm = 6;
    st.bars = false;
    CHECK(session.lay(st).step_held_at == 0.0);
    st.cells.max_step = 1.5;
    const Outcome a = session.lay(st);
    st.cells.max_step = 2.0;
    const Outcome b = session.lay(st);
    CHECK(a.step_held_at == 2.0 && b.step_held_at == 2.0 && a.layout.cells == b.layout.cells);
    st.cells.algorithm = Algorithm::Stepped;
    st.cells.max_step = 2.5;
    CHECK(session.lay(st).step_held_at == 2.5);
  }
  block("5 held at 2");

  {  // 6. Nothing goes solid: the pocket part of test_cells_by_stress (4) at a 0.2 mm
     // line, the stress a step at x = 56.7: the far end of the deep wall behind the pocket (cubes of 6.5 from x 50.125)
     // goes down to its finest against a 6.5 mm cube. Every point held by a cell
     // without the limit is held with it (on Default Grade within a millimetre of the surface: the D14 strip under a
     // halved cube, as C22's test allows), and the layout's solid does not grow.
    PartMeasure pp(weld_mesh(prism_any({{0, 0}, {60, 0}, {60, 20}, {0, 20}, {0, 9}, {50, 9}, {50, 4}, {0, 4}}, 0, 40)));
    DomainSpec ps;
    ps.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 13)};
    ps.bead_mm = 0.2;
    Domain dp(pp, ps);
    const auto f = stress_field({-2, -2, -2}, 1.0, 64, 24, 44, [](const Vec3& c) { return c.x > 56.7 ? 100.0 : 0.0; });
    auto pr = dp.probe();
    const PartMeasure::Probe surface = pp.probe();
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec plain;
      plain.algorithm = algo;
      plain.by_stress = true;
      plain.demand = f;
      plain.reference_mpa = 100;
      const Layout lo_ = lay_cells(dp, plain), hi_ = lay_cells(dp, with(plain, 2, algo));
      auto held = [&](const Layout& l, const Vec3& p) {
        for (const Cell& c : l.cells) if (cell_holds(l, pr, c, p)) return true;
        return false;
      };
      int held_off = 0, lost = 0, lost_deep = 0;
      for (double x = 0.31; x < 60; x += 1.1)
        for (double y = 0.27; y < 20; y += 0.9)
          for (double z = 0.33; z < 40; z += 1.3) {
            const Vec3 p{x, y, z};
            if (!pr.where(p).lattice() || !held(lo_, p)) continue;
            ++held_off;
            if (held(hi_, p)) continue;
            ++lost;
            if (surface.depth(p) >= 1.0) ++lost_deep;
          }
      double v0 = 0, v1 = 0;
      for (const Cell& c : lo_.solid) v0 += c.size * c.size * c.size;
      for (const Cell& c : hi_.solid) v1 += c.size * c.size * c.size;
      std::printf("C24 pocket part: largest step %.2f without the limit, %.2f with 2\n", largest_step(lo_), largest_step(hi_));
      CHECK(step_breaks(lo_, 2.0) > 0 && step_breaks(hi_, 2.0) == 0);
      CHECK(held_off > 1000 && lost_deep == 0);
      if (algo == Algorithm::Stepped) CHECK(lost == 0);
      CHECK(v1 <= v0 + 1e-9 && hi_.solid.size() <= lo_.solid.size());
      std::printf("C24 pocket part, %s: %d points held without the limit; with 2, %d of them in no cell (%d a "
                  "millimetre or more inside); cells %zu -> %zu, solid %zu -> %zu\n",
                  algo == Algorithm::Stepped ? "Stepped" : "Default Grade", held_off, lost, lost_deep,
                  lo_.cells.size(), hi_.cells.size(), lo_.solid.size(), hi_.solid.size());
    }
  }
  block("6 nothing solid");

  {  // 7. Let walls cut cells: the back plate of test_cells_by_stress (12) with a hot voxel by the boss: the rule
     // holds and no cut cell is above the finest (C20).
    PartMeasure pg(weld_mesh(prism({{0, 0}, {64, 0}, {64, 6}, {40, 6}, {40, 12}, {32, 12}, {32, 6}, {0, 6}}, 0, 64)));
    DomainSpec gs;
    gs.bead_mm = 0.2;
    gs.regions = {face_region(1, Role::Lattice, {32, 0, 32}, {0, 1, 0}, 32, 32, 8)};
    Domain dg(pg, gs);
    const auto g = stress_field({-2, -2, -2}, 1.0, 68, 16, 68, [](const Vec3& c) {
      return (c.x > 15 && c.x < 16 && c.z > 30 && c.z < 31) ? 100.0 : 0.0;
    });
    for (int a = 0; a < 2; ++a) {
      const Algorithm algo = a == 0 ? Algorithm::DefaultGrade : Algorithm::Stepped;
      CellSpec grid;
      grid.algorithm = algo;
      grid.one_grid = true;
      grid.by_stress = true;
      grid.demand = g;
      grid.reference_mpa = 100;
      const Layout free_ = lay_cells(dg, grid), kept = lay_cells(dg, with(grid, 2, algo));
      const double finest = a == 0 ? 2.0 : 8.0 / 6.0;
      int cut_large = 0;
      for (const Cell& c : kept.cells) cut_large += c.cut && c.size > finest * (1 + 1e-9);
      CHECK(step_breaks(free_, 2.0) > 0 && step_breaks(kept, 2.0) == 0 && cut_large == 0);
      CHECK(kept.solid.size() <= free_.solid.size());
      std::printf("C24 one grid, %s: %zu cells without the limit, %zu with 2\n", a == 0 ? "Default Grade" : "Stepped",
                  free_.cells.size(), kept.cells.size());
    }
  }
  block("7 Let walls cut cells");

  {  // 8. A region's own max_step acts on that region only: the block of test_area_own, a hot voxel under each face.
    PartMeasure pa(weld_mesh(box(46, 46, 16)));
    DomainSpec as;
    as.bead_mm = 0.2;
    as.regions = {face_region(1, Role::Lattice, {23, 23, 16}, {0, 0, -1}, 23, 23, 8),
                  face_region(2, Role::Lattice, {23, 23, 0}, {0, 0, 1}, 23, 23, 8)};
    Domain da(pa, as);
    const auto two_hot = stress_field({-2, -2, -2}, 1.0, 50, 50, 20, [](const Vec3& c) {
      return (c.x > 22 && c.x < 23 && c.y > 22 && c.y < 23 && (std::fabs(c.z - 12.5) < 0.6 || std::fabs(c.z - 3.5) < 0.6))
                 ? 100.0 : 0.0;
    });
    CellSpec P;
    P.cell_max_mm = 8;
    P.by_stress = true;
    P.demand = two_hot;
    P.reference_mpa = 100;
    AreaOwn a;
    a.max_step = 2.0;
    AreaOwnMap m;
    m[1] = a;
    CHECK(a.any());
    const Layout free_ = lay_cells(da, P), l = lay_cells(da, P, 0, &m);
    CHECK(step_breaks(free_, 2.0, 1) > 0 && step_breaks(free_, 2.0, 2) > 0);
    CHECK(step_breaks(l, 2.0, 1) == 0 && !(cells_of(l, 1) == cells_of(free_, 1)));
    CHECK(cells_of(l, 2) == cells_of(free_, 2));
    CHECK(region_cells(P, a).max_step == 2.0 && region_cells(P, AreaOwn{}).max_step == 0.0);
    // And the reverse: the part asks 2, region 2 states 0 (none).
    AreaOwn b;
    b.max_step = 0.0;
    AreaOwnMap mb;
    mb[2] = b;
    const Layout r = lay_cells(da, with(P, 2), 0, &mb);
    CHECK(step_breaks(r, 2.0, 1) == 0 && cells_of(r, 2) == cells_of(free_, 2) && cells_of(r, 1) == cells_of(l, 1));
  }
  block("8 a region's own");

  {  // 9. One thread and eight: the same layout (D18). Speed: about 2,000 cells, a hot spot, against no limit.
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      const CellSpec on = with(off, 2, algo);
      CHECK(same_layout(lay_cells(d, on, 1), lay_cells(d, on, 8)));
    }
    PartMeasure pb(weld_mesh(box(128, 128, 64)));
    DomainSpec bs;
    bs.bead_mm = 0.2;
    bs.start = Start::AllLattice;
    Domain db(pb, bs);
    const auto spot = stress_field({0, 0, 0}, 2.0, 64, 64, 64, [](const Vec3& c) {
      const double dx = c.x - 61, dy = c.y - 59, dz = c.z - 33;
      return std::sqrt(dx * dx + dy * dy + dz * dz) < 10.0 ? 100.0 : 0.0;
    });
    CellSpec plain = off;
    plain.cell_min_mm = 2;   // the whole part's base cell 8 mm (its halves end at 2)
    plain.demand = spot;
    const CellSpec limited = with(plain, 2);
    auto best_ms = [&](const CellSpec& c, Layout* keep) {
      double best = 1e300;
      for (int k = 0; k < 3; ++k) {
        const auto t0 = std::chrono::steady_clock::now();
        Layout l = lay_cells(db, c);
        best = std::min(best, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
        *keep = std::move(l);
      }
      return best;
    };
    (void)lay_cells(db, plain);   // the domain's first reading, not timed
    Layout a, b;
    const double t_free = best_ms(plain, &a), t_kept = best_ms(limited, &b);
    std::printf("C24 speed: no limit %.2f ms (%zu cells, largest step %.0f); max_step 2 %.2f ms (%zu cells, %.2fx)\n",
                t_free, a.cells.size(), largest_step(a), t_kept, b.cells.size(), t_kept / t_free);
    CHECK(a.cells.size() > 1500 && a.cells.size() < 3000 && step_breaks(a, 2.0) > 0 && step_breaks(b, 2.0) == 0);
    CHECK(same_layout(lay_cells(db, limited, 1), b));
    CHECK(t_kept <= 2.0 * t_free);
  }
  block("9 threads and speed");
}


// ── D23: places (the faces a region's prism runs into that no rule decides) ─────────────────────────────────────────
// A solid made of filled cells of a grid (xs, ys, zs), its boundary as quads of the grid, so the mesh has no
// T-junction. A face is every quad of one oriented plane: its id is the order that plane is first met in.
struct GridModel {
  StepModel model;
  std::map<std::array<long long, 3>, int> id;   // (axis, sign, coordinate in microns) -> face id
  int face(int axis, int sign, double at) const {
    const auto it = id.find({axis, sign, std::llround(at * 1e6)});
    return it == id.end() ? -1 : it->second;
  }
};
static GridModel grid_model(const std::vector<double>& xs, const std::vector<double>& ys,
                            const std::vector<double>& zs, const std::function<bool(int, int, int)>& filled) {
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
            // (a1, a2) is right-handed about +axis: flip for the -axis side.
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
static bool same_places(const std::vector<Place>& a, const std::vector<Place>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i].region != b[i].region || a[i].faces != b[i].faces || a[i].area_mm2 != b[i].area_mm2 ||
        a[i].now != b[i].now || a[i].point.x != b[i].point.x || a[i].point.y != b[i].point.y ||
        a[i].point.z != b[i].point.z || a[i].normal.x != b[i].normal.x || a[i].normal.y != b[i].normal.y ||
        a[i].normal.z != b[i].normal.z)
      return false;
  return true;
}
static void test_places() {
  // A 60 x 60 x 20 block, lattice under its whole top face 18 mm deep. A tunnel x 20..40, y 0..30, z 5..12 runs in
  // from the front (y = 0) under it: the prism crosses its floor, its two walls and its back.
  const GridModel tunnel = grid_model({0, 20, 40, 60}, {0, 30, 60}, {0, 5, 12, 20},
                                      [](int i, int j, int k) { return !(i == 1 && j == 0 && k == 1); });
  const int top = tunnel.face(2, 1, 20), floor = tunnel.face(2, 1, 5), ceiling = tunnel.face(2, -1, 12);
  const int wall_l = tunnel.face(0, 1, 20), wall_r = tunnel.face(0, -1, 40), back = tunnel.face(1, -1, 30);
  CHECK(top >= 0 && floor >= 0 && ceiling >= 0 && wall_l >= 0 && wall_r >= 0 && back >= 0);
  Settings st;
  st.min_strut_lines = kFewestStrutLines;
  st.regions = {{1, Role::Lattice, {top}, 18.0, 0.0}};
  st.cells.cell_max_mm = 6;
  // Places with every layout of a session (lay, then places) and the same bytes from a fresh one; the time of each.
  const auto lay_and_place = [](const StepModel& model, const Settings& set, double* ms_lay = nullptr,
                                double* ms_places = nullptr) {
    Session one(model);
    const auto t0 = std::chrono::steady_clock::now();
    (void)one.lay(set);
    const auto t1 = std::chrono::steady_clock::now();
    std::vector<Place> got = one.places(set);
    const auto t2 = std::chrono::steady_clock::now();
    if (ms_lay) *ms_lay = std::chrono::duration<double, std::milli>(t1 - t0).count();
    if (ms_places) *ms_places = std::chrono::duration<double, std::milli>(t2 - t1).count();
    return got;
  };
  {
    Session session(tunnel.model);
    CHECK(session.open_edges() == 0);
    struct { std::vector<Place> places; } o;
    (void)session.lay(st);
    o.places = session.places(st);
    double ms_lay = 0.0, ms_places = 0.0;
    (void)lay_and_place(tunnel.model, st, &ms_lay, &ms_places);
    std::printf("[places] tunnel: %zu place(s); a fresh lay %.1f ms, its places %.1f ms\n", o.places.size(), ms_lay,
                ms_places);
    // Asked with other "where" settings than the last lay's: none.
    Settings deeper_st = st;
    deeper_st.regions[0].depth_mm = 17.0;
    CHECK(session.places(deeper_st).empty());
    CHECK(o.places.size() == 1);
    if (o.places.size() == 1) {
      const Place& p = o.places[0];
      std::printf("[places]   faces");
      for (int f : p.faces) std::printf(" %d", f);
      std::printf(", %.2f mm2 at (%.2f, %.2f, %.2f) normal (%.2f, %.2f, %.2f), now %s\n", p.area_mm2, p.point.x,
                  p.point.y, p.point.z, p.normal.x, p.normal.y, p.normal.z, p.now.c_str());
      CHECK(p.region == 1);
      // The floor, the two walls and the back are crossed deep: seeds, joined by their edges, one place. The ceiling
      // faces the prism's own way (rule (a): latticed through); the top is the region's own.
      std::vector<int> want{floor, wall_l, wall_r, back};
      std::sort(want.begin(), want.end());
      CHECK(p.faces == want);
      CHECK(std::find(p.faces.begin(), p.faces.end(), ceiling) == p.faces.end());
      // Area: floor 20 x 30 + two walls 30 x 7 + back 20 x 7 = 1160 mm2, within 2 %.
      CHECK(std::fabs(p.area_mm2 - 1160.0) <= 0.02 * 1160.0);
      // The point lies on one of its faces, and its normal is that face's outward one.
      const bool on_floor = std::fabs(p.point.z - 5.0) < 1e-9 && std::fabs(p.normal.z - 1.0) < 1e-9;
      const bool on_wall = (std::fabs(p.point.x - 20.0) < 1e-9 && p.normal.x > 0.999) ||
                           (std::fabs(p.point.x - 40.0) < 1e-9 && p.normal.x < -0.999) ||
                           (std::fabs(p.point.y - 30.0) < 1e-9 && p.normal.y < -0.999);
      CHECK(on_floor || on_wall);
      CHECK(p.now == "lattice");
    }
    // The same bytes twice (a fresh session).
    CHECK(same_places(o.places, lay_and_place(tunnel.model, st)));
    // Finish Covered: every surface the lattice meets is solid; no places.
    Settings covered = st;
    covered.cover_mm = -1.0;
    CHECK(lay_and_place(tunnel.model, covered).empty());
    // The answer "Solid" (a protect_chip entry on the place's faces): the place stays, now "solid", and the space
    // under it is solid to the protect depth. The owner's own Protect skin on the same faces is a rule: no place.
    if (o.places.size() == 1) {
      Settings answered = st;
      Settings::ProtectAsk chip;
      chip.id = 7;
      chip.faces = o.places[0].faces;
      chip.depth_mm = 1.0;
      chip.chip = true;
      answered.protect = {chip};
      Session with_chip(tunnel.model);
      (void)with_chip.lay(answered);
      struct { std::vector<Place> places; } a;
      a.places = with_chip.places(answered);
      CHECK(a.places.size() == 1);
      if (a.places.size() == 1) {
        CHECK(a.places[0].faces == o.places[0].faces && a.places[0].now == "solid");
        CHECK(std::fabs(a.places[0].area_mm2 - o.places[0].area_mm2) <= 1e-6 * o.places[0].area_mm2);
      }
      const Domain::Probe probe = with_chip.domain()->probe();
      const Where under = probe.where({30.0, 15.0, 4.5}), deeper = probe.where({30.0, 15.0, 3.5});
      CHECK(under.why == Why::ProtectSkin && under.id == 7);   // 0.5 mm under the floor: the chip's solid
      CHECK(deeper.lattice() && deeper.id == 1);               // 1.5 mm under it: the region's lattice again
      Settings owned = answered;
      owned.protect[0].chip = false;
      CHECK(lay_and_place(tunnel.model, owned).empty());
    }
  }
  {
    // Through: a plain block, the prism deeper than the block. The bottom is straight opposite (latticed through),
    // the sides are reached only along the outline: no place.
    const GridModel block = grid_model({0, 60}, {0, 60}, {0, 20}, [](int, int, int) { return true; });
    Settings through = st;
    through.regions = {{1, Role::Lattice, {block.face(2, 1, 20)}, 25.0, 0.0}};
    CHECK(lay_and_place(block.model, through).empty());
  }
  {
    // A small crossed face: a 3 x 3 mm hole up from the bottom to z 10, crossed by the prism (to z 2): its walls are
    // crossed deep over 4 x 3 x 8 = 96 mm2, under 100: no place (the rule keeps it lattice).
    const GridModel hole = grid_model({0, 25, 28, 60}, {0, 25, 28, 60}, {0, 10, 20},
                                      [](int i, int j, int k) { return !(i == 1 && j == 1 && k == 0); });
    Settings small = st;
    small.regions = {{1, Role::Lattice, {hole.face(2, 1, 20)}, 18.0, 0.0}};
    CHECK(lay_and_place(hole.model, small).empty());
    // The same hole 6 x 6 mm (192 mm2 of walls): one place of its four edge-joined walls.
    const GridModel wide = grid_model({0, 25, 31, 60}, {0, 25, 31, 60}, {0, 10, 20},
                                      [](int i, int j, int k) { return !(i == 1 && j == 1 && k == 0); });
    small.regions = {{1, Role::Lattice, {wide.face(2, 1, 20)}, 18.0, 0.0}};
    struct { std::vector<Place> places; } w;
    w.places = lay_and_place(wide.model, small);
    CHECK(w.places.size() == 1 && w.places[0].faces.size() == 4);
    if (w.places.size() == 1) CHECK(std::fabs(w.places[0].area_mm2 - 192.0) <= 0.02 * 192.0);
  }
}

// ── ORGANIC (WEAVE), rules O1, O2 ─────────────────────────────────────────────
// A 40 x 14 x 20 block with a half-round pocket (radius 6) in its top edge, running the block's whole length (z):
// 8 mm of wall under the pocket. Faces: 0 the flat underside (y = 0), 1 the pocket's curved wall, 2 the rest.
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
  const TriangleMesh solid_mesh = prism_any(xy, 0, 20);
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

// Every field of every bar, and the stubs, as one number: two bar lists with the same number are the same bars.
static unsigned long long bars_hash(const Bars& bars) {
  unsigned long long h = 1469598103934665603ULL;
  auto eat = [&](const void* p, std::size_t n) {
    const unsigned char* c = static_cast<const unsigned char*>(p);
    for (std::size_t i = 0; i < n; ++i) { h ^= c[i]; h *= 1099511628211ULL; }
  };
  for (const Bar& b : bars.bars) {
    const double v[13] = {b.a.x, b.a.y, b.a.z, b.b.x, b.b.y, b.b.z, b.width, b.cell, b.flat.x, b.flat.y, b.flat.z,
                          static_cast<double>(b.into_a), static_cast<double>(b.into_b)};
    eat(v, sizeof v);
    const int w[6] = {b.region, static_cast<int>(b.end_a), static_cast<int>(b.end_b), b.piece ? 1 : 0, b.skin ? 1 : 0, 0};
    eat(w, sizeof w);
  }
  const unsigned long long s = bars.stubs;
  eat(&s, sizeof s);
  return h;
}

// The bars of three parts, laid as the cube lattices lay them, held to what lay_bars returned before the end code was
// lifted out of it (O2: lay_bars lays exactly the bars it laid; numbers taken on f63ff6ae).
static void test_lay_bars_unchanged() {
  auto bars_of = [](const Domain& d, const CellSpec& cs) {
    Layout l = lay_cells(d, cs);
    set_struts(l, StrutSpec{});
    solidify_thin_cuts(l, d);
    return lay_bars(l, d);
  };
  unsigned long long got[3] = {0, 0, 0};
  std::size_t count[3] = {0, 0, 0};
  {  // the curved pocket: a shell under its wall and a slab under the flat underside, both cube regions
    const StepModel model = weave_block();
    PartMeasure pm(weld_mesh(model.mesh));
    DomainSpec s;
    s.min_strut_lines = 2.0;
    s.regions = {region_from_faces(model, {1}, 1, Role::Lattice, 4.0), region_from_faces(model, {0}, 2, Role::Lattice, 3.0)};
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 4;
    cs.min_cells_across = 1;
    cs.allow_quilt = true;
    const Bars b = bars_of(d, cs);
    got[0] = bars_hash(b);
    count[0] = b.bars.size();
  }
  {  // the plate with the L face: a flat region and a curved one
    int L = 0, square = 0, sideA = 0, sideB = 0;
    const StepModel model = plate_with_L_face(&L, &square, &sideA, &sideB);
    PartMeasure pm(weld_mesh(model.mesh));
    DomainSpec s;
    s.min_strut_lines = 2.0;
    s.regions = {region_from_faces(model, {L}, 1, Role::Lattice, 6.0), region_from_faces(model, {sideA, sideB}, 2, Role::Lattice, 5.0)};
    Domain d(pm, s);
    CellSpec cs;
    cs.cell_max_mm = 6;
    const Bars b = bars_of(d, cs);
    got[1] = bars_hash(b);
    count[1] = b.bars.size();
  }
  {  // the slot block of the thin-piece rule: its front cut 2.6 mm in, thin cut pieces against the solid made solid
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.regions = {slot_front(-2.6)};
    Domain d(pm, s);
    Layout l = lay_cells(d, slot_cells());
    set_struts(l, slot_struts(kSlotStrut));
    solidify_thin_cuts(l, d);
    const Bars b = lay_bars(l, d);
    got[2] = bars_hash(b);
    count[2] = b.bars.size();
  }
  // K6 (2026-11-24): the struts the bed cuts are kept however short (S4 keeps a piece cut flat on the bed): the first
  // two parts' bottom rows now stand on the bed (was 0x935840c703eb5f33, 5392 and 0xff5cc5b3af9fe0d9, 2267).
  const unsigned long long want[3] = {0x3b61a1c514810738ULL, 0x36346af0f7436e68ULL, 0x17631120b9e61b43ULL};
  const std::size_t want_count[3] = {5403, 2367, 1328};
  std::printf("lay_bars as before: %zu, %zu, %zu bars; %016llx %016llx %016llx\n", count[0], count[1], count[2], got[0], got[1],
              got[2]);
  for (int i = 0; i < 3; ++i) CHECK(got[i] == want[i] && count[i] == want_count[i]);
}

// The made-up weave in the block's pocket (O2): strands at radius 7.75 round the pocket's axis (the middle of the
// 4 mm of lattice under its wall), 0.9 mm wide, 4 mm apart. Two families crossing: rings round the pocket (vertices
// every 30 degrees), three running out through the block's top face at both ends and one ending in the air; and lines
// along the pocket, five running out through the block's two ends and one ending in the air whose crossings fall on
// the rings' own vertices. And across them: R1 from the air through a line and out through the wall into solid; R2
// from the air through a line and out through the pocket's wall; J, a short piece in the air pointing at a ring.
// No strand has a vertex within half the widths of a bar it crosses near it: split_at_crossings joins pair by pair, and
// there a crossing next to a vertex gives two joints a hair apart (reported, not ruled: S1a report).
static Vec3 round_pocket(double r, double deg, double z) {
  const double t = deg * 3.14159265358979323846 / 180.0;
  return {20.0 + r * std::cos(t), 14.0 - r * std::sin(t), z};
}
static Strand weave_strand(std::vector<Vec3> pts) {
  Strand s;
  s.width_mm.assign(pts.size(), 0.9);
  s.points = std::move(pts);
  s.region = 1;
  s.spacing_mm = 4.0;
  return s;
}
static std::vector<Strand> made_up_weave() {
  std::vector<Strand> w;
  const double r = 7.75;
  for (double z : {4.0, 8.0, 12.0}) {   // rings out through the top face
    std::vector<Vec3> p;
    for (double t = -15; t <= 195 + 1e-9; t += 30) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {  // a ring ending in the air at both ends
    std::vector<Vec3> p;
    for (double t = 45; t <= 135 + 1e-9; t += 30) p.push_back(round_pocket(r, t, 16.0));
    w.push_back(weave_strand(p));
  }
  for (double t : {30.0, 60.0, 90.0, 120.0, 150.0}) {   // lines out through the two ends
    std::vector<Vec3> p;
    for (double z = -1; z <= 21 + 1e-9; z += 2) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {  // a line ending in the air, crossing two rings at their vertices
    std::vector<Vec3> p;
    for (double z = 6; z <= 14 + 1e-9; z += 2) p.push_back(round_pocket(r, 165.0, z));
    w.push_back(weave_strand(p));
  }
  w.push_back(weave_strand({round_pocket(7.0, 60, 10), round_pocket(9.0, 60, 10), round_pocket(11.5, 60, 10)}));   // R1
  w.push_back(weave_strand({round_pocket(9.0, 90, 6), round_pocket(4.5, 90, 6)}));      // R2
  w.push_back(weave_strand({round_pocket(9.6, 45, 16), round_pocket(8.9, 45, 16)}));                              // J
  return w;
}
static DomainSpec weave_domain(const StepModel& model, bool weave_region, bool slab) {
  DomainSpec s;
  s.min_strut_lines = 2.0;
  if (weave_region) {
    s.regions.push_back(region_from_faces(model, {1}, 1, Role::Lattice, 4.0));
    s.regions.back().weave = true;
  }
  if (slab) s.regions.push_back(region_from_faces(model, {0}, 2, Role::Lattice, 3.0));
  return s;
}
static CellSpec weave_cells() {
  CellSpec cs;
  cs.cell_max_mm = 4;
  cs.min_cells_across = 1;
  cs.allow_quilt = true;
  return cs;
}
// The nearest approach of point p to segment a..b.
static double to_segment(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  return std::hypot(p.x - a.x - d.x * t, std::hypot(p.y - a.y - d.y * t, p.z - a.z - d.z * t));
}
static bool same_point(const Vec3& a, const Vec3& b) { return a.x == b.x && a.y == b.y && a.z == b.z; }
static bool share_end(const Bar& x, const Bar& y) {
  return same_point(x.a, y.a) || same_point(x.a, y.b) || same_point(x.b, y.a) || same_point(x.b, y.b);
}
// The closest approach of two segments, by sampling one finely against the other (the test's own, not the engine's).
static double segments_apart(const Bar& x, const Bar& y) {
  double best = 1e300;
  for (int i = 0; i <= 400; ++i) {
    const double t = i / 400.0;
    best = std::min(best, to_segment(Vec3{x.a.x + (x.b.x - x.a.x) * t, x.a.y + (x.b.y - x.a.y) * t, x.a.z + (x.b.z - x.a.z) * t}, y.a, y.b));
  }
  return best;
}

// O1: no cell, no solid cube, in a weave region; its lattice is open; the cube region beside it lays as it lays alone.
static void test_weave_cells() {
  const StepModel model = weave_block();
  PartMeasure pm(weld_mesh(model.mesh));
  Domain dw(pm, weave_domain(model, true, true)), d2(pm, weave_domain(model, false, true));
  auto pr = dw.probe();
  const Layout lw = lay_cells(dw, weave_cells()), l2 = lay_cells(d2, weave_cells());
  CHECK(lw.weave.size() == 1 && lw.weave[0].region == 1 && lw.weave[0].spacing_mm == 0.0);
  CHECK(lw.is_weave(1) && !lw.is_weave(2) && l2.weave.empty());
  std::size_t in_weave = 0, solid_weave = 0;
  for (const Cell& c : lw.cells) in_weave += c.region == 1;
  for (const Cell& c : lw.solid) solid_weave += c.region == 1;
  CHECK(in_weave == 0 && solid_weave == 0);
  for (const RegionCells& r : lw.regions) CHECK(r.region != 1);
  // The slab's cells and solid cubes are the cells it lays alone (on the same frame; the weave's frame comes first).
  auto same_but_frame = [&](const std::vector<Cell>& x, const std::vector<Cell>& y) {
    if (x.size() != y.size()) return false;
    for (std::size_t i = 0; i < x.size(); ++i) {
      Cell p = x[i], q = y[i];
      const Frame &fp = lw.frames[static_cast<std::size_t>(p.frame)], &fq = l2.frames[static_cast<std::size_t>(q.frame)];
      if (!same_point(fp.origin, fq.origin) || !same_point(fp.ax[0], fq.ax[0]) || !same_point(fp.ax[2], fq.ax[2])) return false;
      p.frame = q.frame = 0;
      if (!(p == q)) return false;
    }
    return true;
  };
  CHECK(!l2.cells.empty() && same_but_frame(lw.cells, l2.cells) && same_but_frame(lw.solid, l2.solid));
  // Every point of the weave region is open: no cell holds it, and it is not solid (D14 does not reach it).
  const SolidAt solid(lw);
  long weave_pts = 0, held = 0, called_solid = 0;
  for (double z = 1.1; z < 20; z += 2.3)
    for (double y = 2.05; y < 14; y += 0.4)
      for (double x = 8.05; x < 32; x += 0.4) {
        const Vec3 p{x, y, z};
        const Where w = pr.where(p);
        if (!w.lattice() || w.id != 1) continue;
        ++weave_pts;
        for (const Cell& c : lw.cells) held += cell_holds(lw, pr, c, p);
        called_solid += solid(pr, p);
      }
  std::printf("weave cells: %zu cells (the slab alone %zu), %zu solid cubes; %ld points of the weave region: held by a cell %ld, solid %ld\n",
              lw.cells.size(), l2.cells.size(), lw.solid.size(), weave_pts, held, called_solid);
  CHECK(weave_pts > 1000 && held == 0 && called_solid == 0);
  CHECK(solid(pr, {20, 3.5, 10}));   // the solid between the weave and the slab is solid still
}

// O2: every end tagged right, the bars cut at their crossings, a loose tail eaten back to its first crossing only,
// loose ends joined, pieces counted; the same for any number of threads.
static void test_weave_bars() {
  const StepModel model = weave_block();
  PartMeasure pm(weld_mesh(model.mesh));
  Domain d(pm, weave_domain(model, true, true));
  auto pr = d.probe();
  Layout layout = lay_cells(d, weave_cells());
  set_struts(layout, StrutSpec{});
  const std::vector<Strand> weave = made_up_weave();
  const Bars wb = weave_bars(d, weave);
  CHECK(bars_hash(wb) == bars_hash(weave_bars(d, weave, 1)) && bars_hash(wb) == bars_hash(weave_bars(d, weave, 8)));
  // (2) Ends.
  int surface = 0, solid = 0, loose = 0, bad = 0, wall = 0, ends_of_block = 0, top = 0;
  bool r1_solid = false, r2_wall = false;
  for (const Bar& b : wb.bars) {
    CHECK(b.region == 1 && b.cell == 4.0 && b.width == 0.9 && !b.skin);
    for (int e = 0; e < 2; ++e) {
      const Bar::End tag = e ? b.end_b : b.end_a;
      const Vec3 p = e ? b.b : b.a, q = e ? b.a : b.b;
      const double len = bar_length(b);
      const Vec3 out{(p.x - q.x) / len, (p.y - q.y) / len, (p.z - q.z) / len};
      auto along = [&](double s) { return Vec3{p.x + out.x * s, p.y + out.y * s, p.z + out.z * s}; };
      if (tag == Bar::End::Surface) {
        ++surface;
        if (std::fabs(pr.part().depth(p)) > 2e-3) ++bad;
        if (std::fabs(std::hypot(p.x - 20, p.y - 14) - 6.0) < 0.05) { ++wall; r2_wall = r2_wall || std::fabs(p.z - 6) < 1e-9; }
        if (std::fabs(p.z) < 1e-3 || std::fabs(p.z - 20) < 1e-3) ++ends_of_block;
        if (std::fabs(p.y - 14) < 1e-3) ++top;
      } else if (tag == Bar::End::Solid) {
        ++solid;
        // It ran into solid and on by its own width: a width back is the edge, lattice before it, solid after.
        const Where before = pr.where(along(-b.width - 0.05)), after = pr.where(along(-b.width + 0.05));
        if (!(before.lattice() && before.id == 1) || after.lattice() || after.why == Why::Outside) ++bad;
        if (!(pr.where(p).why == Why::NotAsked)) ++bad;
        r1_solid = r1_solid || (std::fabs(p.z - 10) < 1e-9 && std::fabs(std::hypot(p.x - 20, p.y - 14) - 10.9) < 0.02);
      } else if (tag == Bar::End::Loose) {
        ++loose;
        const Where w = pr.where(p);
        if (!(w.lattice() && w.id == 1)) ++bad;
      }
    }
  }
  std::printf("weave bars: %zu from %zu strands (%zu stubs); ends: %d surface (%d on the pocket's wall, %d on the block's ends, %d on its top), %d solid, %d loose, %d wrong\n",
              wb.bars.size(), weave.size(), wb.stubs, surface, wall, ends_of_block, top, solid, loose, bad);
  CHECK(bad == 0);
  CHECK(surface == 17 && wall == 1 && ends_of_block == 10 && top == 6);
  CHECK(solid == 1 && r1_solid && r2_wall);
  CHECK(loose == 8);   // the short ring's two, the short line's two, R1's and R2's ends in the air, J's two
  // (3) Crossings.
  Bars cut = wb;
  CrossingCutStats cst;
  const std::size_t joints = split_at_crossings(cut, 0.0, 0.2, &cst);
  Bars again = wb;
  split_at_crossings(again);
  CHECK(bars_hash(again) == bars_hash(cut));
  long close_pairs = 0, unshared = 0;
  for (std::size_t i = 0; i < cut.bars.size(); ++i)
    for (std::size_t j = i + 1; j < cut.bars.size(); ++j) {
      const Bar &x = cut.bars[i], &y = cut.bars[j];
      if (segments_apart(x, y) > 0.5 * (x.width + y.width) - 1e-3) continue;
      ++close_pairs;
      if (!share_end(x, y)) ++unshared;
    }
  // Rings x lines: 3 x 5 + the short ring x 3 + the short line x 2; R1 and R2 each through a line: 22 crossings.
  std::printf("weave crossings: %zu joints, %zu bars -> %zu; %ld pairs within their half widths, %ld not sharing an end\n", joints,
              wb.bars.size(), cut.bars.size(), close_pairs, unshared);
  // Every crossing is one point where four bars end. The short line meets two rings at points both strands already
  // have (the same vertex): those two need no joint.
  std::map<std::array<double, 3>, int> ends_at;
  for (const Bar& b : cut.bars) { ++ends_at[{b.a.x, b.a.y, b.a.z}]; ++ends_at[{b.b.x, b.b.y, b.b.z}]; }
  int fours = 0, threes = 0;
  for (const auto& kv : ends_at) { fours += kv.second == 4; threes += kv.second == 3 || kv.second > 4; }
  // Re-pinned 2026-11-18 (brief L1) to rule S (brief G28, the lead's ruling), which replaced O2's cut for weave bars:
  // each bar is cut at ITS OWN closest point (never moved off its line, never lengthened) and, where the two points
  // differ, ONE link bar joins them (one per pair of strands, then one per 10 light widths along them). So a crossing
  // is no longer one point where four bars end, and a close pair need not share an end. Was: fours 22, threes 0,
  // joints 20, unshared 0.
  std::size_t links = 0;
  for (const Bar& b : cut.bars) links += b.link;
  std::printf("weave crossings (rule S): %d four-way points, %d other; contacts %zu, strand pairs %zu, kept %zu; links %zu "
              "(%.3f mm, longest %.3f); off the line %zu (largest %.2e mm), backwards %zu\n", fours, threes, cst.contacts,
              cst.strand_pairs, cst.kept, cst.links, cst.links_mm, cst.link_max_mm, cst.off_line, cst.off_line_max_mm,
              cst.backwards);
  CHECK(cst.off_line == 0 && cst.backwards == 0);
  CHECK(links == cst.links && links > 0 && close_pairs > 0);
  CHECK(joints == 38);
  auto is_r1 = [](const Bar& b) {
    return std::fabs(b.a.z - 10) < 1e-9 && std::fabs(b.b.z - 10) < 1e-9 &&
           std::fabs(std::atan2(14 - b.a.y, b.a.x - 20) - 3.14159265358979323846 / 3) < 1e-6;
  };
  int r1_before = 0;
  for (const Bar& b : cut.bars) r1_before += is_r1(b);
  Bars dropped = cut;
  drop_loose_bars(dropped);
  int r1_after = 0;
  bool r1_tail = false;
  for (const Bar& b : dropped.bars)
    if (is_r1(b)) {
      ++r1_after;
      r1_tail = r1_tail || std::hypot(b.a.x - 20, b.a.y - 14) < 7.5 || std::hypot(b.b.x - 20, b.b.y - 14) < 7.5;
    }
  std::printf("weave, R1 (a loose tail, through a line, into solid): %d bars after the cut, %d after loose bars go; %zu of %zu bars kept in all\n",
              r1_before, r1_after, dropped.bars.size(), cut.bars.size());
  CHECK(r1_before == 3 && r1_after == 2 && !r1_tail);   // only its tail, back to the crossing
  // Without the cut the same strand goes whole: nothing holds it at the line it crosses.
  Bars uncut = wb;
  drop_loose_bars(uncut);
  int r1_uncut = 0;
  for (const Bar& b : uncut.bars) r1_uncut += is_r1(b);
  CHECK(r1_uncut == 0);
  // (4) Joining: every loose end that has another bar within one spacing straight ahead, through open lattice, lands.
  const SolidAt solid_at(layout);
  Bars joined = cut;
  std::vector<std::pair<std::size_t, int>> loose_ends;
  long expect = 0, landed_as_expected = 0;
  std::vector<char> should(2 * joined.bars.size(), 0);
  for (std::size_t i = 0; i < cut.bars.size(); ++i)
    for (int e = 0; e < 2; ++e) {
      const Bar& b = cut.bars[i];
      if ((e ? b.end_b : b.end_a) != Bar::End::Loose) continue;
      const Vec3 p = e ? b.b : b.a, q = e ? b.a : b.b;
      const double len = bar_length(b);
      const Vec3 dir{(p.x - q.x) / len, (p.y - q.y) / len, (p.z - q.z) / len};
      bool hit = false;
      for (double s = 0.0; s <= b.cell && !hit; s += 0.02) {
        const Vec3 at{p.x + dir.x * s, p.y + dir.y * s, p.z + dir.z * s};
        const Where w = pr.where(at);
        if (!w.lattice() || solid_at(pr, at, w)) break;   // it meets solid or air first
        for (std::size_t k = 0; k < cut.bars.size() && !hit; ++k)
          hit = k != i && to_segment(at, cut.bars[k].a, cut.bars[k].b) < 0.5 * cut.bars[k].width - 0.01;
      }
      should[2 * i + e] = hit;
      expect += hit;
    }
  join_loose_bars(joined, d, 0, &layout);
  bool j_in = false, j_out = false;
  for (std::size_t i = 0; i < joined.bars.size(); ++i)
    for (int e = 0; e < 2; ++e) {
      const Bar& b = joined.bars[i];
      if (should[2 * i + e] && (e ? b.end_b : b.end_a) == Bar::End::Joined) ++landed_as_expected;
      const Vec3 p = e ? b.b : b.a;
      if (std::fabs(p.z - 16) < 1e-9 && std::fabs(std::atan2(14 - p.y, p.x - 20) - 3.14159265358979323846 / 4) < 1e-6) {
        const double r = std::hypot(p.x - 20, p.y - 14);
        if ((e ? b.end_b : b.end_a) == Bar::End::Joined && r < 8.9) j_in = true;
        if ((e ? b.end_b : b.end_a) == Bar::End::Solid && r > 10.0) j_out = true;
      }
    }
  const Pieces pieces = count_pieces(joined, d, nullptr, nullptr, &layout);
  std::printf("weave joining: %zu ends joined; %ld loose ends had a bar within one spacing ahead, %ld of them landed in it; %zu pieces, %zu adrift\n",
              joined.joined, expect, landed_as_expected, pieces.pieces, pieces.adrift);
  CHECK(expect >= 1 && landed_as_expected == expect);
  CHECK(j_in && j_out);   // J: on into the ring ahead, and out into the solid behind
  CHECK(pieces.pieces >= 1 && pieces.adrift == 0);
}

// O2, S1b: a strand with a vertex next to a crossing stays in one piece. Line A along the pocket (out through both
// ends of the block) has a vertex 0.3 mm above the ring B it crosses (within their half widths, 0.9 mm): both of A's
// bars there cross B. The crossing is made AT A's vertex: A's bars share their ends end to end (one piece), and the
// one point where A and B meet is A's own vertex, exactly, where four bars end.
static void test_weave_crossing_at_a_vertex() {
  const StepModel model = weave_block();
  PartMeasure pm(weld_mesh(model.mesh));
  Domain d(pm, weave_domain(model, true, false));
  const Vec3 vertex = round_pocket(7.75, 90, 10.3);
  std::vector<Strand> strands;
  strands.push_back(weave_strand({round_pocket(7.75, 90, -1), round_pocket(7.75, 90, 8), vertex, round_pocket(7.75, 90, 21)}));
  {
    std::vector<Vec3> p;
    for (double t = -15; t <= 195 + 1e-9; t += 30) p.push_back(round_pocket(7.75, t, 10.0));
    strands.push_back(weave_strand(p));
  }
  Bars bars = weave_bars(d, strands);
  CrossingCutStats vst;
  const std::size_t joints = split_at_crossings(bars, 0.0, 0.2, &vst);
  auto on_a = [&](const Vec3& p) { return std::fabs(p.x - vertex.x) < 1e-6 && std::fabs(p.y - vertex.y) < 1e-6; };
  std::vector<const Bar*> a;
  for (const Bar& b : bars.bars)
    if (on_a(b.a) && on_a(b.b)) a.push_back(&b);
  // A's pieces, joined end to end where they share an exact end.
  std::vector<int> up(a.size());
  for (std::size_t i = 0; i < a.size(); ++i) up[i] = static_cast<int>(i);
  auto find = [&](int v) { while (up[static_cast<std::size_t>(v)] != v) v = up[static_cast<std::size_t>(v)]; return v; };
  for (std::size_t i = 0; i < a.size(); ++i)
    for (std::size_t j = i + 1; j < a.size(); ++j)
      if (share_end(*a[i], *a[j])) up[static_cast<std::size_t>(find(static_cast<int>(j)))] = find(static_cast<int>(i));
  std::size_t pieces = 0;
  for (std::size_t i = 0; i < a.size(); ++i) pieces += find(static_cast<int>(i)) == static_cast<int>(i);
  int at_vertex = 0, b_at_vertex = 0;
  for (const Bar& b : bars.bars)
    for (const Vec3& p : {b.a, b.b})
      if (same_point(p, vertex)) { ++at_vertex; b_at_vertex += !(on_a(b.a) && on_a(b.b)); }
  std::printf("weave crossing at a vertex: %zu joint(s), line A in %zu bars, %zu piece(s); %d bars end at A's vertex (%d of ring B)\n",
              joints, a.size(), pieces, at_vertex, b_at_vertex);
  // Re-pinned 2026-11-18 (brief L1) to rule S (brief G28): a crossing is moved onto a strand's own vertex only within
  // 0.1 x the light width (0.09 mm); A's vertex is 0.3 mm from ring B, so A is cut at its own closest point (A stays
  // one piece on its own line, now in 4 bars), B at its own, and one link joins the two. Was: joints 1, A in 3 bars,
  // 4 bars ending at A's vertex (2 of ring B).
  std::printf("weave crossing at a vertex (rule S): links %zu (%.3f mm), off the line %zu\n", vst.links, vst.links_mm,
              vst.off_line);
  CHECK(joints == 2);
  CHECK(pieces == 1 && a.size() == 4);
  CHECK(at_vertex == 2 && b_at_vertex == 0);
  CHECK(vst.links == 1 && vst.off_line == 0);
}

// O1, O2 through the session: the cube region laid as lay() lays it, the weave's bars after its bars, the spacing
// carried by the layout; the same on one thread and on eight.
static void test_weave_session() {
  const StepModel model = weave_block();
  Session session(model);
  Settings s;
  s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}, {2, Role::Lattice, {0}, 3.0, 0.0, false}};
  s.cells = weave_cells();
  s.struts.allow_quilt = true;
  const std::vector<Strand> weave = made_up_weave();
  const Outcome a = session.lay_weave(s, weave, 1), b = session.lay_weave(s, weave, 8);
  CHECK(!a.cancelled && a.layout.weave.size() == 1 && a.layout.weave[0].spacing_mm == 4.0);
  CHECK(a.layout.cells == b.layout.cells && bars_hash(a.bars) == bars_hash(b.bars));
  std::size_t weave_bars_kept = 0, slab_bars = 0;
  for (const Bar& x : a.bars.bars) (x.region == 1 ? weave_bars_kept : slab_bars) += 1;
  const Outcome plain = session.lay(s, 1);   // no strands: the weave region has nothing
  std::size_t plain_weave = 0;
  for (const Bar& x : plain.bars.bars) plain_weave += x.region == 1;
  std::printf("weave session: %zu cells, %zu bars (%zu of the weave, %zu of the slab), %zu pieces, %zu adrift; without strands %zu bars\n",
              a.layout.cells.size(), a.bars.bars.size(), weave_bars_kept, slab_bars, a.pieces.pieces, a.pieces.adrift,
              plain.bars.bars.size());
  CHECK(weave_bars_kept > 50 && slab_bars > 0 && plain_weave == 0);
  CHECK(plain.layout.cells == a.layout.cells && plain.bars.bars.size() == slab_bars);
}

// O2 (one bar per two points, test 16): of a weave's bars, those on the same two points (within a hundredth of a
// micron, either way round) are one, of the widest width; its ends take the best-landed tag of the repeats; a Joined
// end in a repeat lands in the bar kept; a cube region's bar on the same points, and a bar 2e-5 mm off, are not touched.
static Bar repeat_bar(Vec3 a, Vec3 b, double w, int region, Bar::End ea, Bar::End eb, int into_b = -1) {
  Bar x;
  x.a = a; x.b = b; x.width = w; x.cell = 4.0; x.region = region; x.end_a = ea; x.end_b = eb; x.into_b = into_b;
  return x;
}
static void test_weave_repeats() {
  const Vec3 A{10, 10, 10}, B{14, 10, 11};
  const Bar::End N = Bar::End::Node, J = Bar::End::Joined, S = Bar::End::Solid;
  Bars b;
  b.bars.push_back(repeat_bar(A, B, 0.9, 1, N, N));                                     // 0
  b.bars.push_back(repeat_bar(B, {A.x + 5e-6, A.y, A.z}, 1.2, 1, N, N));                // 1 the other way round, 5e-6 off
  b.bars.push_back(repeat_bar(A, B, 0.8, 1, N, J, 5));                                  // 2 its b end Joined in bar 5
  b.bars.push_back(repeat_bar(A, B, 0.9, 2, N, N));                                     // 3 a cube region's
  b.bars.push_back(repeat_bar({12, 14, 10}, {12, 10.2, 10.5}, 0.9, 1, S, J, 2));        // 4 Joined in repeat 2
  b.bars.push_back(repeat_bar({14, 10, 9}, {14, 12, 13}, 0.9, 1, S, S));                // 5
  b.bars.push_back(repeat_bar({A.x + 2e-5, A.y, A.z}, B, 0.9, 1, N, N));                // 6 2e-5 off: not a repeat
  Bars untouched = b;
  CHECK(merge_repeated_bars(untouched, {}) == 0 && bars_hash(untouched) == bars_hash(b) && untouched.repeats == 0);
  const std::size_t merged = merge_repeated_bars(b, {1});
  std::printf("weave repeats by hand: %zu merged, %zu bars left; kept width %.2f, ends %d %d (into %d); bar 4 into %d\n",
              merged, b.bars.size(), b.bars.empty() ? 0.0 : b.bars[0].width, b.bars.empty() ? -1 : static_cast<int>(b.bars[0].end_a),
              b.bars.empty() ? -1 : static_cast<int>(b.bars[0].end_b), b.bars.empty() ? -9 : b.bars[0].into_b,
              b.bars.size() > 2 ? b.bars[2].into_b : -9);
  CHECK(merged == 2 && b.repeats == 2 && b.bars.size() == 5 && b.dropped == 0);
  if (b.bars.size() == 5) {
    CHECK(b.bars[0].width == 1.2 && b.bars[0].a.x == A.x && b.bars[0].b.x == B.x);
    CHECK(b.bars[0].end_a == N && b.bars[0].end_b == J && b.bars[0].into_b == 3);   // bar 5 is now 3
    CHECK(b.bars[1].region == 2 && b.bars[1].width == 0.9);
    CHECK(b.bars[2].end_b == J && b.bars[2].into_b == 0);
    CHECK(b.bars[4].a.x == A.x + 2e-5);
  }
  // Through the session: the made-up weave with one of its rings laid twice (the second 1.1 mm wide) lays exactly the
  // bars of the weave laid once, that ring's at 1.1 mm; no two weave bars on the same two points.
  const StepModel model = weave_block();
  Session session(model);
  Settings s;
  s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}, {2, Role::Lattice, {0}, 3.0, 0.0, false}};
  s.cells = weave_cells();
  s.struts.allow_quilt = true;
  const std::vector<Strand> once = made_up_weave();
  std::vector<Strand> twice = once;
  Strand again = once[0];
  again.width_mm.assign(again.points.size(), 1.1);
  twice.push_back(again);
  const Outcome a = session.lay_weave(s, once, 1);
  const Outcome t = session.lay_weave(s, twice, 1);
  auto weave_count = [](const Bars& x) {
    std::size_t n = 0;
    for (const Bar& y : x.bars) n += y.region == 1;
    return n;
  };
  auto repeats_left = [](const Bars& x) {
    std::size_t n = 0;
    for (std::size_t i = 0; i < x.bars.size(); ++i)
      for (std::size_t j = i + 1; j < x.bars.size(); ++j) {
        const Bar &p = x.bars[i], &q = x.bars[j];
        if (p.region != 1 || q.region != 1) continue;
        n += (same_point(p.a, q.a) && same_point(p.b, q.b)) || (same_point(p.a, q.b) && same_point(p.b, q.a));
      }
    return n;
  };
  std::size_t wide = 0;
  for (const Bar& y : t.bars.bars) wide += y.region == 1 && y.width == 1.1;
  std::printf("weave repeats in the session: once %zu weave bars, ring twice %zu (merged %zu, %zu at 1.1 mm), repeats left %zu\n",
              weave_count(a.bars), weave_count(t.bars), t.bars.repeats, wide, repeats_left(t.bars));
  CHECK(weave_count(t.bars) == weave_count(a.bars) && t.bars.repeats > 0 && wide > 0 && repeats_left(t.bars) == 0);
  CHECK(repeats_left(a.bars) == 0);
}

int main() {
  test_places();
  test_size_step();
  test_face_pieces();
  test_area_own();
  test_area_finish();
  test_lay_bars_unchanged();
  test_weave_cells();
  test_weave_bars();
  test_weave_crossing_at_a_vertex();
  test_weave_session();
  test_weave_repeats();
  test_cells_by_stress();
  test_zones();
  test_by_stress();
  test_by_stress_session();
  test_demand_field();
  test_thin_cut_pieces();
  test_one_grid_main_size();
  test_one_grid_smallest_cut();
  test_solid_why();
  test_one_grid();
  test_cells_behind_a_protect_skin();
  test_thin_walls_follow_the_quilt_switch();
  test_quilt_only_where_nothing_else_lays();   // K3
  test_cut_cells_follow_a_slope();   // K2
  test_cells_cut_flat_at_the_bed();   // K6
  test_cell_search_fits_square_faces();   // K7
  test_edge_rows_stretch();   // K8
  test_cells_across_the_narrowest_width();
  test_band_never_quilts_without_the_switch();
  test_two_line_struts();
  test_cells_across_the_room_between_skins();
  test_structural_strips_refused();   // K5
  test_cells_behind_a_pocket();
  test_grooves_do_not_narrow_a_wall();
  test_kept_readings();
  test_bars();
  test_bars_join();
  test_pieces();
  test_struts_end_in_no_cell_space();
  test_slivers_are_taken_in();
  test_many_skins_of_one_depth();
  test_skin();
  test_stepped_edges();
  test_rim();
  test_session();
  test_session_one_grid();
  test_session_cancel();
  test_cover();
  test_region_squares();
  test_struts();
  test_each_type_has_its_own_limits();
  test_grade_to_shape();
  test_cells_prism();
  test_cells_walls_under_a_face();
  test_cells_ledge_is_not_a_wall();
  test_cells_whole_part();
  test_cells_stepped();
  test_cells_curved_region();
  test_face_regions();
  test_pocket_and_thin_wall();
  test_measure_box();
  test_measure_L();
  test_measure_by_line();
  test_domain();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
