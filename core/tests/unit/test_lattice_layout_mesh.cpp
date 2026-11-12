// Lattice rebuild, stage F: the printable mesh made from the layout (lattice_layout_mesh.hpp).
// What is held here: the mesh is ONE closed piece as a slicer reads it (corners joined by
// place), it never leaves the part, it is the same on every run and for any number of
// threads, what the layer check asks to be left out is left out, a post is added where
// asked, a flat strut is a bridge, and a stop flag gives the work up.
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

#include "topopt/lattice_layout.hpp"
#include "topopt/lattice_layout_mesh.hpp"

using namespace topopt;
using namespace topopt::lattice_layout;

static int g_fail = 0, g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
  } while (0)

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
static Region face_region(int id, Vec3 origin, Vec3 inward, double half_u, double half_w, double depth, double expand) {
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
  r.expand_mm = expand;
  return r;
}

// The mesh as a slicer reads it: corners at one place are one corner.
struct Read {
  std::size_t edges_not_twice = 0;   // an edge that is not used once each way
  std::size_t flat = 0;              // a triangle with two corners at one place
  std::size_t shells = 0;
  double mm3 = 0.0;
  double lo[3] = {1e300, 1e300, 1e300}, hi[3] = {-1e300, -1e300, -1e300};
};
static Read read_mesh(const TriangleMesh& m) {
  Read r;
  std::map<std::array<double, 3>, int> at;
  std::vector<int> id(m.vertices.size());
  for (std::size_t v = 0; v < m.vertices.size(); ++v) {
    const Vec3& p = m.vertices[v];
    id[v] = at.emplace(std::array<double, 3>{p.x, p.y, p.z}, static_cast<int>(at.size())).first->second;
    const double c[3] = {p.x, p.y, p.z};
    for (int a = 0; a < 3; ++a) { r.lo[a] = std::min(r.lo[a], c[a]); r.hi[a] = std::max(r.hi[a], c[a]); }
  }
  std::vector<int> up(at.size());
  for (std::size_t i = 0; i < up.size(); ++i) up[i] = static_cast<int>(i);
  auto find = [&](int v) { while (up[static_cast<std::size_t>(v)] != v) v = up[static_cast<std::size_t>(v)] = up[static_cast<std::size_t>(up[static_cast<std::size_t>(v)])]; return v; };
  std::map<std::pair<int, int>, int> way;   // a -> b: +1 each time it is walked that way
  for (const auto& t : m.triangles) {
    const int c[3] = {id[static_cast<std::size_t>(t[0])], id[static_cast<std::size_t>(t[1])], id[static_cast<std::size_t>(t[2])]};
    if (c[0] == c[1] || c[1] == c[2] || c[0] == c[2]) { ++r.flat; continue; }
    for (int q = 0; q < 3; ++q) {
      ++way[{c[q], c[(q + 1) % 3]}];
      up[static_cast<std::size_t>(find(c[q]))] = find(c[0]);
    }
    const Vec3 &a = m.vertices[static_cast<std::size_t>(t[0])], &b = m.vertices[static_cast<std::size_t>(t[1])], &d = m.vertices[static_cast<std::size_t>(t[2])];
    r.mm3 += (a.x * (b.y * d.z - b.z * d.y) - a.y * (b.x * d.z - b.z * d.x) + a.z * (b.x * d.y - b.y * d.x)) / 6.0;
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
static bool same_mesh(const TriangleMesh& x, const TriangleMesh& y) {
  if (x.vertices.size() != y.vertices.size() || x.triangles != y.triangles) return false;
  for (std::size_t i = 0; i < x.vertices.size(); ++i)
    if (x.vertices[i].x != y.vertices[i].x || x.vertices[i].y != y.vertices[i].y || x.vertices[i].z != y.vertices[i].z) return false;
  return true;
}

struct Laid {
  Layout layout;
  Bars bars;
};
static Laid lay(const Domain& d, const CellSpec& cs) {
  Laid l;
  l.layout = lay_cells(d, cs);
  set_struts(l.layout, StrutSpec{});
  l.bars = lay_bars(l.layout, d);
  join_loose_bars(l.bars, d, 0, &l.layout);
  drop_loose_bars(l.bars);
  drop_adrift_bars(l.bars, d, &l.layout);
  return l;
}

// A 30 x 30 x 12 block, lattice under its top face 8 mm deep, pulled 2 mm in from the
// edge: a solid floor 4 mm thick, a solid rim, 4 mm cells cut by the region's edge.
static void test_block() {
  PartMeasure pm(weld_mesh(box(30, 30, 12)));
  DomainSpec s;
  s.min_strut_lines = 2.0;
  s.regions = {face_region(1, {15, 15, 12}, {0, 0, -1}, 15, 15, 8, -2.0)};
  Domain d(pm, s);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_max_mm = 8;
  cs.min_cells_across = 1;
  const Laid l = lay(d, cs);
  CHECK(!l.layout.cells.empty() && !l.bars.bars.empty());
  const OpenSpace open = read_open_space(d, l.layout, 0.25);
  CHECK(!open.boxes.empty());
  // The open space is the same for any number of threads.
  {
    const OpenSpace one = read_open_space(d, l.layout, 0.25, 1);
    bool same = one.boxes.size() == open.boxes.size();
    for (std::size_t i = 0; same && i < open.boxes.size(); ++i)
      same = one.boxes[i].frame == open.boxes[i].frame && !std::memcmp(one.boxes[i].lo, open.boxes[i].lo, sizeof one.boxes[i].lo) &&
             !std::memcmp(one.boxes[i].hi, open.boxes[i].hi, sizeof one.boxes[i].hi);
    CHECK(same);
  }
  MeshReport rep;
  const TriangleMesh mesh = build_mesh(pm, d, l.layout, l.bars, open, MeshSpec{}, &rep);
  CHECK(rep.ok && rep.why.empty());
  CHECK(rep.triangles == mesh.triangles.size() && rep.triangles > 1000);
  std::printf("block: %zu cells, %zu bars (%zu bridges), %zu open boxes; mesh %zu triangles, %.1f of %.1f mm3; touching places %zu, "
              "air pockets %zu, loose bits %zu\n", l.layout.cells.size(), rep.bars, rep.bridges, open.boxes.size(), rep.triangles,
              rep.mm3, rep.part_mm3, rep.touching_places, rep.air_pockets, rep.loose_bits);
  // One closed piece, as a slicer reads it.
  const Read r = read_mesh(mesh);
  CHECK(r.edges_not_twice == 0);
  CHECK(r.flat == 0);
  CHECK(r.shells == 1 && rep.sealed_spaces == 0);
  CHECK(std::fabs(r.mm3 - rep.mm3) < 1e-3 * rep.mm3);
  // It is the part with material taken out and struts put back: less than the part, more
  // than the solid body alone, no more than the two together; and it never leaves the part.
  CHECK(std::fabs(rep.part_mm3 - 30.0 * 30.0 * 12.0) < 1e-6);
  CHECK(rep.solid_mm3 < rep.part_mm3 - 1000.0);          // the open space is really open
  CHECK(rep.struts_mm3 > 10.0);
  CHECK(rep.mm3 > rep.solid_mm3 + 1.0 && rep.mm3 < rep.solid_mm3 + rep.struts_mm3 + 1.0 && rep.mm3 < rep.part_mm3);
  const double plo[3] = {0, 0, 0}, phi[3] = {30, 30, 12};
  for (int a = 0; a < 3; ++a) CHECK(r.lo[a] > plo[a] - 1e-4 && r.hi[a] < phi[a] + 1e-4);
  // The floor is whole: the lowest 3.9 mm of the block is untouched solid, so the bed
  // face is the part's own.
  CHECK(std::fabs(r.lo[2]) < 1e-6);
  // The same mesh again, and on one thread: triangle for triangle (D18).
  {
    MeshSpec one;
    one.threads = 1;
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, open, MeshSpec{})));
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, open, one)));
  }
  // A flat strut is a bridge (his rule, 2026-11-12); with the rule off none is, and the mesh differs.
  CHECK(rep.bridges > 0 && rep.bridges < rep.bars);
  {
    MeshSpec round;
    round.bridge_rise = 0.0;
    MeshReport rr;
    const TriangleMesh m2 = build_mesh(pm, d, l.layout, l.bars, open, round, &rr);
    CHECK(rr.ok && rr.bridges == 0 && rr.bars == rep.bars && !same_mesh(mesh, m2));
    CHECK(std::fabs(rr.struts_mm3 - rep.struts_mm3) > 1e-3);   // a square bar holds more than a round one
  }
  // A place the layer check names: every strut whose lowest point is there is left out,
  // and nothing else. Named at the low end of a rising strut.
  {
    const Bar* pick = nullptr;
    for (const Bar& b : l.bars.bars)
      if (std::fabs(b.a.z - b.b.z) > 1.0 && b.end_a == Bar::End::Node && b.end_b == Bar::End::Node) { pick = &b; break; }
    CHECK(pick != nullptr);
    if (pick) {
      const Vec3& low = pick->a.z < pick->b.z ? pick->a : pick->b;
      MeshSpec ms;
      ms.drop_at = {{low.x, low.y, low.z - 0.5 * pick->width}, {-50, -50, -50}};
      MeshReport rd;
      const TriangleMesh m3 = build_mesh(pm, d, l.layout, l.bars, open, ms, &rd);
      CHECK(rd.ok && rd.bars_left_out >= 1 && rd.bars + rd.bars_left_out == rep.bars);
      CHECK(rd.bars_left_out_mm > 0.0 && rd.drop_unanswered == 1);   // the far place answers to nothing
      CHECK(rd.struts_mm3 < rep.struts_mm3);
      const Read r3 = read_mesh(m3);
      CHECK(r3.edges_not_twice == 0 && r3.shells == 1);
    }
  }
  // A post: from the floor's top up into the lattice, two lines across.
  {
    MeshSpec ms;
    ms.posts = {{15.3, 14.7, 9.0, 4.0}, {1.0, 1.0, 3.0, 5.0}};   // the second is upside down: not made
    MeshReport rp;
    const TriangleMesh m4 = build_mesh(pm, d, l.layout, l.bars, open, ms, &rp);
    CHECK(rp.ok && rp.posts == 1 && std::fabs(rp.posts_mm - 5.0) < 1e-9);
    CHECK(rp.struts_mm3 > rep.struts_mm3 + 0.5);
    const Read r4 = read_mesh(m4);
    CHECK(r4.edges_not_twice == 0 && r4.shells == 1);
  }
  // Two posts standing corner to corner meet along one line: two surfaces TOUCH there
  // (separate corners at one place), which a slicer reads as an edge with four faces.
  // They are parted, and the mesh reads closed.
  {
    MeshSpec ms;
    ms.posts = {{6.45, 6.45, 9.0, 4.0}, {7.35, 7.35, 9.0, 4.0}};
    MeshReport rt;
    const TriangleMesh m5 = build_mesh(pm, d, l.layout, l.bars, open, ms, &rt);
    const Read r5 = read_mesh(m5);
    std::printf("block, two posts corner to corner: touching places %zu, edges not used twice %zu, shells %zu\n", rt.touching_places,
                r5.edges_not_twice, r5.shells);
    CHECK(rt.ok && rt.posts == 2 && rt.touching_places > 0);
    CHECK(r5.edges_not_twice == 0 && r5.flat == 0 && r5.shells == 1);
  }
  // A stop flag: the work is given up.
  {
    std::atomic<bool> stop{true};
    bool threw = false;
    try { (void)read_open_space(d, l.layout, 0.25, 0, &stop); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
    MeshSpec ms;
    ms.stop = &stop;
    threw = false;
    try { (void)build_mesh(pm, d, l.layout, l.bars, open, ms); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
  }
}

// The whole part as lattice behind a Protect skin on every face: no flat face to read
// columns from, so every cell's shape is read point by point; the skin stays whole.
static void test_whole_part() {
  const TriangleMesh b = box(16, 16, 16);
  PartMeasure pm(weld_mesh(b));
  DomainSpec s;
  s.start = Start::AllLattice;
  s.min_strut_lines = 2.0;
  s.protect.push_back({1, b, 1.2});
  Domain d(pm, s);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_mm = 6.8;
  cs.min_cells_across = 1;
  const Laid l = lay(d, cs);
  CHECK(!l.layout.cells.empty() && !l.bars.bars.empty());
  const OpenSpace open = read_open_space(d, l.layout, 0.25);
  MeshReport rep;
  const TriangleMesh mesh = build_mesh(pm, d, l.layout, l.bars, open, MeshSpec{}, &rep);
  CHECK(rep.ok);
  const Read r = read_mesh(mesh);
  std::printf("whole part: %zu cells, %zu bars, %zu open boxes; mesh %zu triangles, %.1f of %.1f mm3; shells as read %zu\n",
              l.layout.cells.size(), rep.bars, open.boxes.size(), rep.triangles, rep.mm3, rep.part_mm3, r.shells);
  // The outside is the box itself (one shell); the lattice is sealed inside the skin, so
  // its surface is a second shell the material encloses. Both closed, and the sealed
  // lattice STAYS (it is not a speck of air to fill: the file would be a solid block).
  CHECK(r.edges_not_twice == 0 && r.flat == 0);
  CHECK(r.shells == 2 && rep.sealed_spaces == 1);
  CHECK(rep.mm3 < rep.part_mm3 - 500.0 && std::fabs(r.mm3 - rep.mm3) < 1e-3 * rep.mm3);
  CHECK(rep.mm3 > rep.solid_mm3 + 1.0);          // its struts are in it
  CHECK(rep.solid_mm3 < rep.part_mm3 - 500.0);
  // The skin is whole: nothing of the outer 1 mm is opened.
  const double shell_mm3 = 16.0 * 16.0 * 16.0 - 14.0 * 14.0 * 14.0;
  CHECK(rep.solid_mm3 > shell_mm3);
  for (int a = 0; a < 3; ++a) CHECK(std::fabs(r.lo[a]) < 1e-6 && std::fabs(r.hi[a] - 16.0) < 1e-6);
}

int main() {
  if (!mesh_available()) {
    MeshReport rep;
    PartMeasure pm(weld_mesh(box(4, 4, 4)));
    Domain d(pm, DomainSpec{});
    const TriangleMesh none = build_mesh(pm, d, Layout{}, Bars{}, OpenSpace{}, MeshSpec{}, &rep);
    CHECK(none.empty() && !rep.ok && !rep.why.empty());
    std::printf("no mesh library in this build: the writer says so (%d checks, %d failed)\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
  }
  test_block();
  test_whole_part();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
