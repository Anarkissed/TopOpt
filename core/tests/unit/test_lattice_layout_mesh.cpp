// Lattice rebuild, stage F: the printable mesh made from the layout (lattice_layout_mesh.hpp).
// What is held here: the mesh is ONE closed piece as a slicer reads it (corners joined by
// place), it never leaves the part, it is the same on every run and for any number of
// threads, what the layer check asks to be left out is left out, a post is added where
// asked, a flat strut is a bridge, and a stop flag gives the work up. Where the part's
// surface cuts the cells on a slant or a curve, no crust of that surface is left over the
// lattice, and nothing solid inside the part is opened (test_no_crust).
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <thread>
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
  // The part carved ONCE and handed to every build gives the same mesh, triangle for triangle, whatever is then
  // left out or added (the make-check-make loop carves once: the slow half does not depend on the struts).
  {
    const Carved carved = carve_part(pm, l.layout, open);
    CHECK(carved.ok && carved.why.empty() && carved.kept);
    MeshReport rc;
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, carved, MeshSpec{}, &rc)));
    CHECK(rc.ok && rc.part_mm3 == rep.part_mm3 && rc.solid_mm3 == rep.solid_mm3 && rc.solid_pieces == rep.solid_pieces);
    MeshSpec a;
    a.posts = {{15.3, 14.7, 9.0, 4.0}};
    MeshSpec b;
    b.bridge_rise = 0.0;
    const Bar& first = l.bars.bars.front();
    b.drop_at = {{first.a.z < first.b.z ? first.a.x : first.b.x, first.a.z < first.b.z ? first.a.y : first.b.y,
                  std::min(first.a.z, first.b.z) - 0.5 * first.width}};
    // The same carving, used three times over, in any order: each as if carved for it alone.
    CHECK(same_mesh(build_mesh(pm, d, l.layout, l.bars, carved, a), build_mesh(pm, d, l.layout, l.bars, open, a)));
    CHECK(same_mesh(build_mesh(pm, d, l.layout, l.bars, carved, b), build_mesh(pm, d, l.layout, l.bars, open, b)));
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, carved, MeshSpec{})));
    // It is the carving's own overlap that counts, not the build's.
    MeshSpec wide;
    wide.grow_mm = 0.3;
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, carved, wide)));
    CHECK(!same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, open, wide)));
    // Nothing carved: said plainly, no mesh.
    MeshReport rn;
    CHECK(build_mesh(pm, d, l.layout, l.bars, Carved{}, MeshSpec{}, &rn).empty() && !rn.ok && !rn.why.empty());
    // A part that is not closed cannot be carved, and the build says why.
    TriangleMesh holed = box(30, 30, 12);
    holed.triangles.pop_back();
    PartMeasure open_part(weld_mesh(holed));
    const Carved bad = carve_part(open_part, l.layout, open);
    CHECK(!bad.ok && !bad.why.empty() && !bad.kept);
    std::atomic<bool> stop{true};
    bool threw = false;
    try { (void)carve_part(pm, l.layout, open, 0.02, &stop); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
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

// ── no crust where a curved wall cuts the cells (his major flaw, 2026-11-12) ──
// A 16 x 16 x 6 block with a round hole through it (64 flat sides, 3 mm radius), TURNED in
// space, so that no face of it lies along the cells' grid: the hole's wall and the six
// flat faces all cut the cells and their 0.25 mm reading points on a slant.
struct Holed {
  TriangleMesh part;   // closed
  TriangleMesh wall;   // the hole's wall alone (a Protect skin's face)
  double mm3 = 0.0;
  double wall_round_mm = 0.0;   // the hole's outline, all the way round
  double tall_mm = 0.0;
};
// A place of the block as it was drawn (x, y from its middle, z up from its underside), turned.
static Vec3 turned(double x, double y, double z) {
  const double kPi = 3.14159265358979323846, ax = 23.0 * kPi / 180.0, az = 37.0 * kPi / 180.0;
  const double y1 = y * std::cos(ax) - z * std::sin(ax), z1 = y * std::sin(ax) + z * std::cos(ax);
  return Vec3{x * std::cos(az) - y1 * std::sin(az) + 30.0, x * std::sin(az) + y1 * std::cos(az) + 30.0, z1 + 30.0};
}
static const double kHoledHalf = 8.0, kHoledTall = 6.0, kHoledRadius = 3.0;
static Holed holed_block() {
  const int N = 64;
  const double kPi = 3.14159265358979323846, half = kHoledHalf, R = kHoledRadius, tall = kHoledTall;
  // Round the hole, and straight out from each of its corners to the block's outline
  // (the block's own corners are at 45 degrees: every eighth).
  std::vector<std::array<double, 2>> in(N), out(N);
  for (int m = 0; m < N; ++m) {
    const double t = 2.0 * kPi * m / N, cx = std::cos(t), sy = std::sin(t);
    in[static_cast<std::size_t>(m)] = {R * cx, R * sy};
    const double far = half / std::max(std::fabs(cx), std::fabs(sy));
    out[static_cast<std::size_t>(m)] = {far * cx, far * sy};
  }
  MeshSink part, wall;
  for (int m = 0; m < N; ++m) {
    const auto &i0 = in[static_cast<std::size_t>(m)], &i1 = in[static_cast<std::size_t>((m + 1) % N)];
    const auto &o0 = out[static_cast<std::size_t>(m)], &o1 = out[static_cast<std::size_t>((m + 1) % N)];
    const Vec3 I0b = turned(i0[0], i0[1], 0), I1b = turned(i1[0], i1[1], 0), I0t = turned(i0[0], i0[1], tall), I1t = turned(i1[0], i1[1], tall);
    const Vec3 O0b = turned(o0[0], o0[1], 0), O1b = turned(o1[0], o1[1], 0), O0t = turned(o0[0], o0[1], tall), O1t = turned(o1[0], o1[1], tall);
    part.add_triangle(I0t, O0t, O1t);   // top
    part.add_triangle(I0t, O1t, I1t);
    part.add_triangle(I0b, O1b, O0b);   // bottom
    part.add_triangle(I0b, I1b, O1b);
    part.add_triangle(O0b, O1b, O1t);   // the block's side
    part.add_triangle(O0b, O1t, O0t);
    part.add_triangle(I0b, I1t, I1b);   // the hole's wall
    part.add_triangle(I0b, I0t, I1t);
    wall.add_triangle(I0b, I1t, I1b);
    wall.add_triangle(I0b, I0t, I1t);
  }
  Holed h;
  h.part = part.mesh;
  h.wall = wall.mesh;
  h.mm3 = (4.0 * half * half - 0.5 * N * R * R * std::sin(2.0 * kPi / N)) * tall;
  h.wall_round_mm = 2.0 * N * R * std::sin(kPi / N);
  h.tall_mm = tall;
  return h;
}
// Counted with no help from the writer: the part's volume that NO cell holds, point by
// point on a fine grid laid along the block as it was drawn, so not along the cells'
// (inside the part by the domain, held by `cell_holds`).
static double unheld_mm3(const Domain& d, const Layout& lay, double h, double* part_mm3) {
  const int nx = static_cast<int>(std::lround(2.0 * kHoledHalf / h)), ny = nx, nz = static_cast<int>(std::lround(kHoledTall / h));
  std::vector<long> in(static_cast<std::size_t>(nz), 0), none(static_cast<std::size_t>(nz), 0);
  std::atomic<int> next{0};
  auto work = [&] {
    const Domain::Probe probe = d.probe();
    for (int z = next.fetch_add(1); z < nz; z = next.fetch_add(1))
      for (int y = 0; y < ny; ++y)
        for (int x = 0; x < nx; ++x) {
          const Vec3 p = turned(-kHoledHalf + (x + 0.5) * h, -kHoledHalf + (y + 0.5) * h, (z + 0.5) * h);
          if (probe.where(p).why == Why::Outside) continue;
          ++in[static_cast<std::size_t>(z)];
          bool held = false;
          for (std::size_t ci = 0; ci < lay.cells.size() && !held; ++ci) held = cell_holds(lay, probe, lay.cells[ci], p);
          if (!held) ++none[static_cast<std::size_t>(z)];
        }
  };
  std::vector<std::thread> pool;
  for (unsigned t = 1; t < std::max(1u, std::thread::hardware_concurrency()); ++t) pool.emplace_back(work);
  work();
  for (std::thread& t : pool) t.join();
  long all_in = 0, all_none = 0;
  for (int z = 0; z < nz; ++z) { all_in += in[static_cast<std::size_t>(z)]; all_none += none[static_cast<std::size_t>(z)]; }
  if (part_mm3) *part_mm3 = static_cast<double>(all_in) * h * h * h;
  return static_cast<double>(all_none) * h * h * h;
}
static bool same_boxes(const OpenSpace& x, const OpenSpace& y) {
  if (x.boxes.size() != y.boxes.size()) return false;
  for (std::size_t i = 0; i < x.boxes.size(); ++i)
    if (x.boxes[i].frame != y.boxes[i].frame || std::memcmp(x.boxes[i].lo, y.boxes[i].lo, sizeof x.boxes[i].lo) ||
        std::memcmp(x.boxes[i].hi, y.boxes[i].hi, sizeof x.boxes[i].hi))
      return false;
  return true;
}
static void test_no_crust() {
  const Holed hb = holed_block();
  std::size_t open_edges = 1;
  PartMeasure pm(weld_mesh(hb.part, 1e-5, &open_edges));
  CHECK(open_edges == 0);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_mm = 5.0;
  cs.min_cells_across = 1;
  // The writer's boxes overlap by MeshSpec::grow_mm, which takes that much off every side
  // of what stays solid. To weigh the solid body against a count it is made with next to
  // no overlap.
  MeshSpec exact;
  exact.grow_mm = 0.001;
  // (a) The whole part lattice, nothing protected: the lattice runs out through every face
  // and through the hole's wall. What the writer keeps solid is then only what no cell
  // holds, and nothing of the part's own surface.
  {
    DomainSpec s;
    s.start = Start::AllLattice;
    s.min_strut_lines = 2.0;
    Domain d(pm, s);
    const Laid l = lay(d, cs);
    CHECK(!l.layout.cells.empty() && !l.bars.bars.empty());
    const OpenSpace open = read_open_space(d, l.layout, 0.25);
    const Carved carved = carve_part(pm, l.layout, open);
    MeshReport rep, rx;
    const TriangleMesh mesh = build_mesh(pm, d, l.layout, l.bars, carved, MeshSpec{}, &rep);
    CHECK(rep.ok);
    (void)build_mesh(pm, d, l.layout, Bars{}, open, exact, &rx);   // the solid body alone: no struts
    CHECK(rx.ok);
    double counted_part = 0.0;
    const double none = unheld_mm3(d, l.layout, 0.2, &counted_part);
    std::printf("no crust, whole part lattice: %zu cells, %zu open boxes read in %.0f ms; part %.1f mm3 (counted %.1f); "
                "solid kept %.2f mm3 in %zu pieces (%.2f in %zu with the usual overlap), held by no cell %.2f mm3\n",
                l.layout.cells.size(), open.boxes.size(), open.ms, rep.part_mm3, counted_part, rx.solid_mm3, rx.solid_pieces,
                rep.solid_mm3, rep.solid_pieces, none);
    CHECK(std::fabs(rep.part_mm3 - hb.mm3) < 1e-6 * hb.mm3);
    CHECK(std::fabs(counted_part - hb.mm3) < 5e-3 * hb.mm3);   // the count itself is sound
    // NO CRUST. What is left to differ: the kept solid is made of whole reading points
    // (0.25 mm cubes) and the count of whole 0.2 mm ones, so each is out by a fraction of a
    // point along the border of the little there is that no cell holds (a dozen crumbs
    // at the block's corners, about 20 mm3 in all). Before the fix the writer kept 45.49 mm3
    // here against the same 19.58: 26 mm3 of the part's own surface, in 149 pieces (713 at
    // the usual overlap, and 619 loose bits in the mesh).
    CHECK(std::fabs(rx.solid_mm3 - none) < 2.0);
    CHECK(rep.solid_mm3 <= rx.solid_mm3 + 1e-9 && rep.solid_mm3 > rx.solid_mm3 - 3.0);
    CHECK(rx.solid_pieces < 40 && rep.solid_pieces < 40);   // crumbs no cell holds, not slats
    // And none of them a film: the overlap of 0.02 mm neither joins two nor splits one.
    // (Opening air by faces only, not by edges and corners, leaves 401 against 77; not
    // looking past the cube's face for the cell's own lattice, 27 against 15.)
    CHECK(rx.solid_pieces == rep.solid_pieces);
    const Read r = read_mesh(mesh);
    std::printf("no crust, whole part lattice: mesh %zu triangles, %.1f mm3, shells %zu, loose bits %zu, air pockets %zu\n",
                rep.triangles, rep.mm3, r.shells, rep.loose_bits, rep.air_pockets);
    CHECK(r.edges_not_twice == 0 && r.flat == 0 && r.shells == 1);
    CHECK(rep.loose_bits < 40);     // 619 before: the slats the struts did not catch
    // The same mesh again, on one thread (the boxes themselves: in (b)).
    MeshSpec single;
    single.threads = 1;
    CHECK(same_mesh(mesh, build_mesh(pm, d, l.layout, l.bars, carved, single)));
    std::atomic<bool> stop{true};
    bool threw = false;
    try { (void)read_open_space(d, l.layout, 0.25, 0, &stop); } catch (const LayCancelled&) { threw = true; }
    CHECK(threw);
  }
  // (b) Solid INSIDE the part, right beside the lattice: a Protect skin 1 mm deep on the
  // hole's wall, and a No lattice pillar 4 x 4 mm standing through the block in one corner,
  // its sides cutting the cells on a slant. Both are whole: nothing inside the part is
  // opened that no cell holds.
  {
    DomainSpec s;
    s.start = Start::AllLattice;
    s.min_strut_lines = 2.0;
    const double skin = 1.0;
    s.protect.push_back({1, hb.wall, skin});
    const Vec3 o = turned(5.0, -5.0, kHoledTall), below = turned(5.0, -5.0, kHoledTall - 1.0);
    Region pillar = face_region(2, o, {below.x - o.x, below.y - o.y, below.z - o.z}, 2.0, 2.0, kHoledTall, 0.0);
    pillar.role = Role::NoLattice;
    s.regions = {pillar};
    Domain d(pm, s);
    const Laid l = lay(d, cs);
    CHECK(!l.layout.cells.empty() && !l.bars.bars.empty());
    const OpenSpace open = read_open_space(d, l.layout, 0.25);
    CHECK(same_boxes(open, read_open_space(d, l.layout, 0.25, 1)));   // the same boxes on one thread
    MeshReport rx;
    const TriangleMesh mesh = build_mesh(pm, d, l.layout, l.bars, open, exact, &rx);
    CHECK(rx.ok);
    const double none = unheld_mm3(d, l.layout, 0.2, nullptr);
    // The skin itself: everything within its depth of the wall, outside the hole.
    const double kPi = 3.14159265358979323846;
    const double skin_mm3 = (hb.wall_round_mm * skin + kPi * skin * skin) * hb.tall_mm;
    const double pillar_mm3 = 4.0 * 4.0 * hb.tall_mm;
    std::printf("no crust, a skin and a pillar: %zu cells, %zu open boxes read in %.0f ms; solid kept %.2f mm3 in %zu pieces, "
                "held by no cell %.2f mm3, the skin and the pillar alone %.2f mm3\n", l.layout.cells.size(), open.boxes.size(), open.ms,
                rx.solid_mm3, rx.solid_pieces, none, skin_mm3 + pillar_mm3);
    CHECK(none > skin_mm3 + pillar_mm3 && rx.solid_mm3 > skin_mm3 + pillar_mm3);
    // NOTHING SOLID OPENED, and still no crust: the kept solid is what no cell holds, to
    // within the same fraction of a reading point along a longer border (the skin's inner
    // side, the pillar's sides, the faces of the cells that stand beside space no cell
    // holds). Before the fix: 1,059.97 mm3 kept, in 83 pieces, against the same 1,048.86.
    // With every point that touches the space opened, air or not: 1,037.54, the 11 mm3
    // short taken off the pillar's sides.
    CHECK(std::fabs(rx.solid_mm3 - none) < 4.0);
    CHECK(rx.solid_pieces == 1);   // the skin and all the rest, one body
    const Read r = read_mesh(mesh);
    CHECK(r.edges_not_twice == 0 && r.flat == 0 && r.shells == 1);
  }
  // (c) Lattice under the block's top face only, 5 mm deep (a solid floor 1 mm thick): the
  // cells stand on the face's own frame and are read column by column. The hole's wall and
  // the block's sides run straight down through the columns and across the cells' sides.
  // (Read this way the part had no crust before the fix either, 237.31 mm3 kept then as
  // now: this holds that it stays so, and that the new step takes nothing off the floor.)
  {
    const Vec3 o = turned(0, 0, kHoledTall), below = turned(0, 0, kHoledTall - 1.0);
    DomainSpec s;
    s.min_strut_lines = 2.0;
    s.regions = {face_region(1, o, {below.x - o.x, below.y - o.y, below.z - o.z}, 12, 12, 5.0, 0.0)};
    Domain d(pm, s);
    CellSpec cf;
    cf.algorithm = Algorithm::Uniform;
    cf.cell_max_mm = 8;
    cf.min_cells_across = 1;
    const Laid l = lay(d, cf);
    CHECK(!l.layout.cells.empty() && !l.bars.bars.empty());
    CHECK(!l.layout.walls.empty() && l.layout.walls[static_cast<std::size_t>(l.layout.cells.front().frame)].flat);
    const OpenSpace open = read_open_space(d, l.layout, 0.25);
    CHECK(same_boxes(open, read_open_space(d, l.layout, 0.25, 1)));
    MeshReport rx;
    const TriangleMesh mesh = build_mesh(pm, d, l.layout, l.bars, open, exact, &rx);
    CHECK(rx.ok);
    const double none = unheld_mm3(d, l.layout, 0.2, nullptr);
    const double floor_mm3 = hb.mm3 / hb.tall_mm * 1.0;
    std::printf("no crust, lattice under the top face: %zu cells of %.2f mm, %zu open boxes read in %.0f ms; solid kept %.2f mm3 in %zu "
                "pieces, held by no cell %.2f mm3, the floor alone %.2f mm3\n", l.layout.cells.size(), l.layout.cells.front().size,
                open.boxes.size(), open.ms, rx.solid_mm3, rx.solid_pieces, none, floor_mm3);
    CHECK(none > floor_mm3 - 2.0 && rx.solid_mm3 > floor_mm3 - 2.0);
    CHECK(std::fabs(rx.solid_mm3 - none) < 4.0);
    const Read r = read_mesh(mesh);
    CHECK(r.edges_not_twice == 0 && r.flat == 0 && r.shells == 1);
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
  test_no_crust();
  test_layers();
  test_printable();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
