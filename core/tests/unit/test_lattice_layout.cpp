// Lattice layout, stage B: measure and domain. Rule numbers are those of
// docs/design/lattice-rebuild/01-rules.md; the numbers are those of 02-tests.md.
#include <cmath>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdio>
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
  // (f) What the rule made solid is never opened again: a cube of ANOTHER region's frame that reaches over it does not
  // take its lattice in (D14b). The block of (a) latticed whole (the part's own frame, 8 mm cells, behind the front
  // region from y 8), with a No lattice cap 1.5 mm deep on top: the front region's top row is cut 0.4 mm thick
  // against the cap, and the whole part's cubes (y 6 to 14) reach over its back end.
  {
    PartMeasure pm(weld_mesh(slot_block()));
    DomainSpec s;
    s.start = Start::AllLattice;
    s.regions = {slot_front(-2.6), face_region(3, Role::NoLattice, {15, 6, 30}, {0, 0, -1}, 15, 15, 1.5)};
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
  // (e) The strut changed after the cells are laid gives what a fresh session lays with that strut. Expand -2.3, the
  // row 0.7 mm thick: solid under a 0.7 mm strut, open under a 0.5 mm one, and back.
  {
    const StepModel model = slot_model();
    Settings st;
    st.min_strut_lines = kFewestStrutLines;
    st.regions = {{1, Role::Lattice, {2}, 8.0, -2.3}};
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
      CHECK(other == 0 && off_face == 0);
      CHECK(l.cells.size() == 5 * 5);                              // 60 / 12 each way, one layer
      CHECK(whole == 2 * 5 && cut == 3 * 5);                       // whole: only x < 24; the rest are cut cells
      int n = 0;
      const int a1 = holder(d, l, thick, &n);
      CHECK(a1 >= 0 && n == 1);
      const int b1 = holder(d, l, thin, &n);
      CHECK(b1 >= 0 && n == 1);
      CHECK(a1 == b1);                                             // ONE cell holds both sides of the step
      if (a1 >= 0) { CHECK(l.cells[a1].cut); NEAR(cell_centre(l, l.cells[a1]).x, 30.0, 1e-9); }   // astride the step
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
      if (at >= 0) { NEAR(l.cells[at].size, 9.0, 1e-9); CHECK(l.cells[at].cut); }
      int other = 0;
      for (const Cell& c : l.cells) if (std::fabs(c.size - 9.0) > 1e-9) ++other;
      CHECK(other == 0 && l.solid.empty());
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
      for (const Cell& c : l.cells) {
        const Vec3 m = cell_centre(l, c);
        const double dist = edge(m), h = 0.5 * c.size;
        if (c.size > finest * (1 + 1e-9) && dist < band * (c.size - finest) / (12.0 - finest) - 1e-6) ++breaks_rule;
        if (c.size > finest * (1 + 1e-9) &&
            (m.x - h < -1e-6 || m.x + h > 96 + 1e-6 || m.z - h < -1e-6 || m.z + h > 96 + 1e-6)) ++large_cut;
        if (dist <= h + 1e-9) { ++at_edge; if (c.size > f + 1e-9) ++at_edge_large; }
        if (dist >= band + 0.5 * (12.0 - c.size) && std::fabs(c.size - 12.0) > 1e-9) ++small_inside;
        all[std::lround(c.size * 1e3)] += c.size * c.size * c.size;
        if (dist >= band) inner[std::lround(c.size * 1e3)] += c.size * c.size * c.size;
      }
      CHECK(breaks_rule == 0);          // G1: a larger cell only where its centre is far enough in
      CHECK(large_cut == 0);            // G10: only the finest crosses the outline
      CHECK(at_edge > 50 && at_edge_large == 0);   // G3: the cells at the outline are the smallest
      CHECK(small_inside == 0);         // G2: beyond the band, the region's own cell
      CHECK(all.size() >= 3);           // it steps: at least three sizes
      // Away from the outline the largest cell is the most common by volume: in fact the only one.
      double inner_total = 0.0;
      for (const auto& kv : inner) inner_total += kv.second;
      CHECK(inner_total > 0.0 && inner.count(12000) == 1 && inner[12000] > 0.5 * inner_total);
      CHECK(inner[12000] >= 6 * 6 * 1728.0 - 1e-6);   // the 6 x 6 base cells whose centres are a band inside
      // ... and across the step in the wall, well inside the band: one base cell holds both walls.
      int n = 0;
      const int a = holder(d, l, {40, 3, 30}, &n);
      CHECK(a >= 0 && n == 1);
      const int b = holder(d, l, {44, 3, 30}, &n);
      CHECK(b >= 0 && n == 1 && a == b);
      if (a >= 0) NEAR(l.cells[a].size, 12.0, 1e-9);
      const Layout one = lay_cells(d, on, 1);
      CHECK(l.cells == one.cells && l.solid == one.solid);          // D18, on one thread
      // With the band off: the base cell everywhere.
      CellSpec flat = on;
      flat.grade_to_shape = false;
      const Layout plain = lay_cells(d, flat);
      int not_base = 0;
      for (const Cell& c : plain.cells) if (std::fabs(c.size - 12.0) > 1e-9) ++not_base;
      CHECK(plain.cells.size() == 8 * 8 && not_base == 0 && plain.solid.empty());
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
  std::printf("one grid: a 12 | 6 mm wall is %ld cells of 12 mm (wall by wall: %ld cells of 12 and 6); a 2 mm wall holds %ld "
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

int main() {
  test_thin_cut_pieces();
  test_solid_why();
  test_one_grid();
  test_cells_behind_a_protect_skin();
  test_thin_walls_follow_the_quilt_switch();
  test_cells_across_the_narrowest_width();
  test_band_never_quilts_without_the_switch();
  test_two_line_struts();
  test_cells_across_the_room_between_skins();
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
