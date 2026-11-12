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
  // "Sealed lattice" is a space that could hold a cell. Told that a closed space must reach
  // 5,000 mm3 to stay, this one (under 2,500) is filled, and the file is the solid cube.
  {
    CHECK(std::fabs(rep.filled_under_mm3 - 6.8 * 6.8 * 6.8) < 1e-6);   // by default: one smallest cell
    MeshSpec big;
    big.fill_under_mm3 = 5000.0;
    MeshReport rf;
    const TriangleMesh filled = build_mesh(pm, d, l.layout, l.bars, open, big, &rf);
    CHECK(rf.ok && rf.sealed_spaces == 0 && rf.air_pockets >= 1 && filled.triangles.size() == 12);
    CHECK(std::fabs(rf.mm3 - 4096.0) < 1e-6);
  }
  CHECK(rep.mm3 < rep.part_mm3 - 500.0 && std::fabs(r.mm3 - rep.mm3) < 1e-3 * rep.mm3);
  CHECK(rep.mm3 > rep.solid_mm3 + 1.0);          // its struts are in it
  CHECK(rep.solid_mm3 < rep.part_mm3 - 500.0);
  // The skin is whole: nothing of the outer 1 mm is opened.
  const double shell_mm3 = 16.0 * 16.0 * 16.0 - 14.0 * 14.0 * 14.0;
  CHECK(rep.solid_mm3 > shell_mm3);
  for (int a = 0; a < 3; ++a) CHECK(std::fabs(r.lo[a]) < 1e-6 && std::fabs(r.hi[a] - 16.0) < 1e-6);
}

// ── his print rules, layer by layer (P8) ─────────────────────────────────────
static void add_box(MeshSink& s, double x0, double y0, double z0, double x1, double y1, double z1, double shear_x = 0.0) {
  // `shear_x`: the top is moved this far along x (a leaning box).
  const Vec3 p[8] = {{x0, y0, z0}, {x1, y0, z0}, {x1, y1, z0}, {x0, y1, z0},
                     {x0 + shear_x, y0, z1}, {x1 + shear_x, y0, z1}, {x1 + shear_x, y1, z1}, {x0 + shear_x, y1, z1}};
  const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
  for (const auto& f : q) {
    s.add_triangle(p[f[0]], p[f[1]], p[f[2]]);
    s.add_triangle(p[f[0]], p[f[2]], p[f[3]]);
  }
}
static void test_layers() {
  {  // A plain block: flat on the bed, nothing to find.
    MeshSink s;
    add_box(s, 0, 0, 0, 10, 10, 5);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.layers == 25 && std::fabs(r.z_bed) < 1e-12);
    CHECK(std::fabs(r.bed_mm2 - 100.0) < 1e-9 && r.sloped_mm2 == 0.0 && std::fabs(r.first_layer_mm2 - 100.0) < 1.5);
    CHECK(r.bed_flat() && r.clean() && r.thin_islands == 0 && r.longest_reach_mm < 0.1);
    LayerSpec one;
    one.threads = 1;   // the same on one thread
    const LayerReport r1 = check_layers(s.mesh, one);
    CHECK(r1.first_layer_mm2 == r.first_layer_mm2 && r1.clean());
  }
  {  // A small block floating 2 mm above it: it starts in mid-air, and the block's top is what lies below.
    MeshSink s;
    add_box(s, 0, 0, 0, 10, 10, 5);
    add_box(s, 4, 3, 7, 6, 5, 8);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.mid_air.size() == 1 && !r.clean());
    if (r.mid_air.size() == 1) {
      const LayerReport::MidAir& m = r.mid_air[0];
      CHECK(std::fabs(m.z - 7.1) < 0.01 && std::fabs(m.mm2 - 4.0) < 0.3 && std::fabs(m.x - 5.0) < 0.06 && std::fabs(m.y - 4.0) < 0.06);
      CHECK(std::fabs(m.size_x - 2.0) < 0.11 && std::fabs(m.size_y - 2.0) < 0.11);
      CHECK(m.anything_below && std::fabs(m.below_z - 4.9) < 0.01);
    }
  }
  {  // A post with an arm 6 mm long held at one end: one-ended, and nothing lies under its far end.
    MeshSink s;
    add_box(s, 0, 0, 0, 2, 2, 10);
    add_box(s, 2, 0, 8, 8, 2, 10);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.mid_air.empty() && r.one_ended.size() == 1);
    if (r.one_ended.size() == 1) {
      const LayerReport::OneEnded& o = r.one_ended[0];
      CHECK(o.reach_mm > 5.7 && o.reach_mm < 6.2 && std::fabs(o.z - 8.1) < 0.01 && o.x > 7.5 && !o.anything_below);
    }
    CHECK(std::fabs(r.longest_reach_mm - (r.one_ended.empty() ? 0.0 : r.one_ended[0].reach_mm)) < 1e-9);
  }
  {  // The same arm held at BOTH ends is a bridge: fine, and its reach is half its span.
    MeshSink s;
    add_box(s, 0, 0, 0, 2, 2, 10);
    add_box(s, 8, 0, 0, 10, 2, 10);
    add_box(s, 2, 0, 8, 8, 2, 10);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.clean() && r.longest_reach_mm > 2.7 && r.longest_reach_mm < 3.2);
  }
  {  // A block leaning at 45 degrees: every layer is held by the one below.
    MeshSink s;
    add_box(s, 0, 0, 0, 4, 4, 6, 6.0);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.clean() && r.longest_reach_mm < 0.3);
    MeshSink t;   // leaning at 63 degrees from upright: too far, each layer hangs past the last... but stays attached
    add_box(t, 0, 0, 0, 4, 4, 6, 12.0);
    CHECK(check_layers(t.mesh).longest_reach_mm > 0.15);
  }
  {  // An underside that slopes up from one edge: not a bed face.
    MeshSink s;
    const Vec3 p[8] = {{0, 0, 0}, {10, 0, 0.15}, {10, 10, 0.15}, {0, 10, 0}, {0, 0, 5}, {10, 0, 5}, {10, 10, 5}, {0, 10, 5}};
    const int q[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 0, 4, 7}};
    for (const auto& f : q) { s.add_triangle(p[f[0]], p[f[1]], p[f[2]]); s.add_triangle(p[f[0]], p[f[2]], p[f[3]]); }
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.bed_mm2 == 0.0 && std::fabs(r.sloped_mm2 - 100.0) < 0.01 && !r.bed_flat());
  }
  {  // Rule (d), a count: a fin one line thick standing on a block is thin in each of its layers; the block is not.
    MeshSink s;
    add_box(s, 0, 0, 0, 10, 10, 2);
    add_box(s, 3, 2, 2, 3.45, 8, 5);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.clean() && r.thin_islands == 15 && r.thin_layers == 15);
    MeshSink t;
    add_box(t, 0, 0, 0, 10, 10, 2);
    add_box(t, 3, 2, 2, 3.9, 8, 5);   // two lines: not thin
    CHECK(check_layers(t.mesh).thin_islands == 0);
  }
  {  // A stop flag.
    MeshSink s;
    add_box(s, 0, 0, 0, 10, 10, 5);
    std::atomic<bool> stop{true};
    LayerSpec ls;
    ls.stop = &stop;
    bool threw = false;
    try { (void)check_layers(s.mesh, ls); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
  }
}

// The mesh that prints: made, checked, made again. The block of test_block with a strut
// added by hand that no printer could start: hanging down from a node into open space.
static void test_printable() {
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
  const OpenSpace open = read_open_space(d, l.layout, 0.25);
  // As laid, the block prints: the loop makes it once.
  {
    PrintableReport pr;
    const TriangleMesh mesh = build_printable_mesh(pm, d, l.layout, l.bars, open, PrintableSpec{}, &pr);
    std::printf("printable block: %d pass(es), found per pass %d, bed %.1f of first layer %.1f mm2, longest reach %.2f mm, thin islands %zu\n",
                pr.passes, pr.found_per_pass.empty() ? -1 : pr.found_per_pass[0], pr.layers.bed_mm2, pr.layers.first_layer_mm2,
                pr.layers.longest_reach_mm, pr.layers.thin_islands);
    CHECK(pr.clean && pr.passes == 1 && pr.mesh.ok && pr.layers.clean() && pr.layers.bed_flat());
    CHECK(pr.drop_at.empty() && pr.posts.empty());
    CHECK(std::fabs(pr.layers.bed_mm2 - 900.0) < 1e-6);
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, open, MeshSpec{})));
  }
  // A node well inside the lattice, half way up, to hang a bad strut from.
  Vec3 node{};
  bool have = false;
  for (const Bar& b : l.bars.bars)
    for (const Vec3* p : {&b.a, &b.b})
      if (!have && (p == &b.a ? b.end_a : b.end_b) == Bar::End::Node && std::fabs(p->x - 15) < 5 && std::fabs(p->y - 15) < 5 && p->z > 7.0 && p->z < 9.0) {
        node = *p;
        have = true;
      }
  CHECK(have);
  if (!have) return;
  Bars bad = l.bars;
  Bar hang;
  hang.a = node;
  hang.b = {node.x + 1.3, node.y + 0.9, node.z - 2.6};   // down into open space, ending on nothing
  hang.width = 0.9;
  hang.cell = 4.0;
  hang.region = 1;
  hang.end_a = Bar::End::Node;
  hang.end_b = Bar::End::Loose;
  bad.bars.push_back(hang);
  // First answer: what starts in mid-air is left out. Then the mesh is clean, and it is the
  // mesh of the bars as they were (the bad strut is the only thing gone).
  {
    PrintableReport pr;
    const TriangleMesh mesh = build_printable_mesh(pm, d, l.layout, bad, open, PrintableSpec{}, &pr);
    std::printf("printable, one hanging strut: %d passes, found per pass", pr.passes);
    for (int n : pr.found_per_pass) std::printf(" %d", n);
    std::printf("; left out %zu, posts %zu\n", pr.mesh.bars_left_out, pr.mesh.posts);
    CHECK(pr.clean && pr.passes >= 2 && pr.found_per_pass.front() >= 1 && pr.found_per_pass.back() == 0);
    CHECK(pr.mesh.bars_left_out == 1 && pr.mesh.posts == 0 && !pr.drop_at.empty());
    CHECK(pr.layers.clean() && check_layers(mesh).clean());
    const Read r = read_mesh(mesh);
    CHECK(r.edges_not_twice == 0 && r.shells == 1);
    // What the loop ended with gives the same mesh in one pass.
    MeshSpec again;
    again.drop_at = pr.drop_at;
    again.posts = pr.posts;
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, bad, open, again)));
    // And a single pass is told the truth: not clean.
    PrintableSpec once;
    once.most_passes = 1;
    PrintableReport p1;
    (void)build_printable_mesh(pm, d, l.layout, bad, open, once, &p1);
    CHECK(!p1.clean && p1.passes == 1 && !p1.layers.clean());
  }
  // With leaving out switched off, the same strut is tied down with a post from the material below.
  {
    PrintableSpec ps;
    ps.leave_out = false;
    PrintableReport pr;
    const TriangleMesh mesh = build_printable_mesh(pm, d, l.layout, bad, open, ps, &pr);
    std::printf("printable, posts only: %d passes, found per pass", pr.passes);
    for (int n : pr.found_per_pass) std::printf(" %d", n);
    std::printf("; left out %zu, posts %zu (%.1f mm)\n", pr.mesh.bars_left_out, pr.mesh.posts, pr.mesh.posts_mm);
    CHECK(pr.clean && pr.mesh.bars_left_out == 0 && pr.mesh.posts >= 1 && pr.drop_at.empty());
    CHECK(pr.mesh.posts_mm > 0.5 && check_layers(mesh).clean());
    CHECK(pr.mesh.bars == l.bars.bars.size() + 1);
  }
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
  test_layers();
  test_printable();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
