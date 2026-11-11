// Lattice layout, stage B: measure and domain. Rule numbers are those of
// docs/design/lattice-rebuild/01-rules.md; the numbers are those of 02-tests.md.
#include <cmath>
#include <algorithm>
#include <array>
#include <cstdio>
#include <map>
#include <stdexcept>
#include <vector>

#include "topopt/lattice_layout.hpp"

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
  {  // The ratios are octet's. Another type is refused, never given octet's widths.
    Layout l = base;
    l.topology = LatticeTopology::Kelvin;
    bool refused = false;
    try { set_struts(l, StrutSpec{}); } catch (const std::invalid_argument&) { refused = true; }
    CHECK(refused);
    for (const Cell& c : l.cells) CHECK(c.strut == 0.0);
  }
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

    // Struts in the band (G8, R3, G4).
    Layout a = l, b = l, c2 = l;
    StrutSpec sp;
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
      if (c.strut > q + 1e-9) ++past_quilt;                               // R3, R9
      if (c.strut > (0.7592 / 4.0) * c.size + 1e-9) ++past_open;          // R3: allowed here
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
    // R11: a typed width holds inside the band too, up to the quilt.
    sp = StrutSpec{};
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
      on.band_fine_cells = true;
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
      plain_fine.band_fine_cells = true;
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
  // The same bars whichever way it is asked again.
  Bars again = laid;
  join_loose_bars(again, d);
  CHECK(same_bars(again, bars));
  drop_loose_bars(bars);
  int loose_after = 0;
  for (const Bar& b : bars.bars)
    loose_after += (b.end_a == Bar::End::Loose) + (b.end_b == Bar::End::Loose);
  CHECK(loose_after == 0);
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

// G11's two guards, each on a part that tempts it: a wall too thin for an open cell,
// (a) far from the outline with the band on, (b) with no band at all.
static void test_finer_cells_stay_in_the_band() {
  {  // (a) Behind the y = 0 face: 12 mm of material for x < 30, 2 mm for x > 30. A 2 mm
     // cell is below the open look's floor (2.37 mm on a 0.45 mm line).
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2}, {30, 2}, {30, 12}, {0, 12}}, 0, 40)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 20}, {0, 1, 0}, 30, 30, 12)};   // covers the whole face
    Domain d(pm, s);
    const Region& region = d.spec().regions[0];
    const double band = 4.0;
    for (Algorithm algo : {Algorithm::DefaultGrade, Algorithm::Stepped}) {
      CellSpec cs;
      cs.algorithm = algo;
      cs.grade_to_shape = true;
      cs.band_mm = band;
      cs.band_fine_cells = true;
      const Layout l = lay_cells(d, cs);
      int in_band = 0, outside = 0;
      for (const Cell& c : l.cells) {
        if (c.size >= l.floor_cell_mm - 1e-9) continue;
        const double e = region_edge_distance(region, cell_centre(l, c));
        (e - 0.5 * c.size < band ? in_band : outside) += 1;
      }
      // The thin wall's rim, inside the band, gets the finer cells. (Stepped. Default Grade
      // goes below the floor only where the band itself asks for a smaller cell, and this
      // wall's rim cells stand a whole cell inside the outline: it stays solid there.)
      if (algo == Algorithm::Stepped) CHECK(in_band > 0);
      CHECK(outside == 0);     // its middle, 15 mm from the outline, does not
      auto pr = d.probe();
      int held = 0;
      for (const Cell& c : l.cells)
        if (cell_holds(l, pr, c, {45, 1, 20})) ++held;
      CHECK(held == 0);        // the middle is solid, as with the switch off (D8)
    }
  }
  {  // (b) No band. A strip 2.6 mm thick and 3 mm wide beside a 12.8 mm wall: the 6.4 mm
     // cell has no fraction that fits it and prints open, so the strip is solid. A fifth
     // (1.28 mm) would give a 2.56 mm cell; a fifth does not print open, band or no band.
    PartMeasure pm(weld_mesh(prism({{0, 0}, {60, 0}, {60, 2.6}, {57, 2.6}, {57, 12.8}, {0, 12.8}}, 0, 8)));
    DomainSpec s;
    s.regions = {face_region(1, Role::Lattice, {30, 0, 4}, {0, 1, 0}, 30, 30, 12.8)};   // covers the whole face
    Domain d(pm, s);
    CellSpec off;
    off.algorithm = Algorithm::Stepped;
    CellSpec on = off;
    on.band_fine_cells = true;
    const Layout a = lay_cells(d, off), b = lay_cells(d, on);
    CHECK(!a.cells.empty());
    CHECK(a.cells == b.cells && a.solid == b.solid);
    auto pr = d.probe();
    int held = 0;
    for (const Cell& c : b.cells)
      if (cell_holds(b, pr, c, {58.5, 1.3, 4})) ++held;
    CHECK(held == 0);
    CHECK((pr.where({58.5, 1.3, 4}) == Where{Why::Lattice, 1}));   // and it was asked for
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

int main() {
  test_cells_behind_a_protect_skin();
  test_finer_cells_stay_in_the_band();
  test_cells_across_the_narrowest_width();
  test_cells_behind_a_pocket();
  test_grooves_do_not_narrow_a_wall();
  test_kept_readings();
  test_bars();
  test_bars_join();
  test_rim();
  test_struts();
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
