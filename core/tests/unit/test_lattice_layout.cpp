// Lattice layout, stage B: measure and domain. Rule numbers are those of
// docs/design/lattice-rebuild/01-rules.md; the numbers are those of 02-tests.md.
#include <cmath>
#include <cstdio>
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
static StepModel plate_with_L_face(int* L, int* square, int* side) {
  ModelBuilder b;
  const double z = 10;
  *L = b.face(StepSurfaceKind::Plane, {0, 0, 1}, {0, 0, z});
  b.quad(*L, {0, 0, z}, {20, 0, z}, {20, 20, z}, {0, 20, z});
  b.quad(*L, {20, 0, z}, {60, 0, z}, {60, 20, z}, {20, 20, z});
  b.quad(*L, {0, 20, z}, {20, 20, z}, {20, 60, z}, {0, 60, z});
  *square = b.face(StepSurfaceKind::Plane, {0, 0, 1}, {20, 20, z});
  b.quad(*square, {20, 20, z}, {60, 20, z}, {60, 60, z}, {20, 60, z});
  const int bottom = b.face(StepSurfaceKind::Plane, {0, 0, -1}, {0, 0, 0});
  b.quad(bottom, {0, 0, 0}, {0, 60, 0}, {60, 60, 0}, {60, 0, 0});
  // A side whose top edge has a vertex where two top faces meet: three triangles from
  // one bottom corner, so every edge is shared by exactly two triangles.
  auto side_of = [&](int f, Vec3 bl, Vec3 br, Vec3 tr, Vec3 tm, Vec3 tl) {
    b.tri(f, bl, br, tr);
    b.tri(f, bl, tr, tm);
    b.tri(f, bl, tm, tl);
  };
  // The x = 0 side is tagged as a CURVED face on purpose (it is flat; the tag is what
  // the code reads), to exercise the shell path with a distance that is easy to state.
  *side = b.face(StepSurfaceKind::Other, {0, 0, 0}, {0, 0, 0});
  side_of(*side, {0, 60, 0}, {0, 0, 0}, {0, 0, z}, {0, 20, z}, {0, 60, z});
  const int rest = b.face(StepSurfaceKind::Other, {0, 0, 0}, {0, 0, 0});
  side_of(rest, {0, 0, 0}, {60, 0, 0}, {60, 0, z}, {20, 0, z}, {0, 0, z});
  side_of(rest, {60, 0, 0}, {60, 60, 0}, {60, 60, z}, {60, 20, z}, {60, 0, z});
  side_of(rest, {60, 60, 0}, {0, 60, 0}, {0, 60, z}, {20, 60, z}, {60, 60, z});
  return b.m;
}

static void test_face_regions() {
  int L = -1, square = -1, side = -1;
  const StepModel model = plate_with_L_face(&L, &square, &side);
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
  {  // A curved face has no prism: the region is everything within the depth of the face.
    bool ok = false;
    DomainSpec s;
    s.regions = {region_from_face(model, side, 2, Role::Lattice, 5, 0.0, &ok)};
    CHECK(ok);
    CHECK(s.regions[0].is_shell());
    Domain d(pm, s);
    auto pr = d.probe();
    CHECK((pr.where({4.99, 30, 5}) == Where{Why::Lattice, 2}));
    CHECK((pr.where({5.01, 30, 5}) == Where{Why::NotAsked, 0}));
    // ... and as No lattice it beats a Lattice prism (D6).
    s.regions = {region_from_face(model, L, 1, Role::Lattice, 6),
                 region_from_face(model, side, 2, Role::NoLattice, 5)};
    Domain d2(pm, s);
    CHECK((d2.probe().where({3, 30, 8}) == Where{Why::NoLattice, 2}));
    CHECK((d2.probe().where({7, 30, 8}) == Where{Why::Lattice, 1}));
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

int main() {
  test_face_regions();
  test_pocket_and_thin_wall();
  test_measure_box();
  test_measure_L();
  test_domain();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
