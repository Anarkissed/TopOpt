// Lattice rebuild, stage F: the printable mesh made from the layout (lattice_layout_mesh.hpp).
// What is held here: the mesh is ONE closed piece as a slicer reads it (corners joined by
// place), it never leaves the part, it is the same on every run and for any number of
// threads, what the layer check asks to be left out is left out, a post is added where
// asked, a flat strut is a bridge, and a stop flag gives the work up. Where the part's
// surface cuts the cells on a slant or a curve, no crust of that surface is left over the
// lattice, and nothing solid inside the part is opened (test_no_crust).
#include <algorithm>
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

// MeshSpec::strut_reach_mm: struts written longer than their bars never leave the part. A 16 mm cube latticed whole
// with no skin: every strut the cube's faces cut ends in the open (End::Surface), and the mesh stays inside the cube.
static void test_strut_reach_stays_in_the_part() {
  PartMeasure pm(weld_mesh(box(16, 16, 16)));
  DomainSpec s;
  s.start = Start::AllLattice;
  s.min_strut_lines = 2.0;
  Domain d(pm, s);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_mm = 6.8;
  Layout layout = lay_cells(d, cs);
  set_struts(layout, StrutSpec{});
  const Bars bars = lay_bars(layout, d);   // as laid: the cut ends in the open are kept
  std::size_t in_air = 0;
  for (const Bar& b : bars.bars) in_air += (b.end_a == Bar::End::Surface) + (b.end_b == Bar::End::Surface);
  CHECK(in_air > 0);
  const OpenSpace open = read_open_space(d, layout, 0.25);
  MeshReport rep;
  const TriangleMesh mesh = build_mesh(pm, d, layout, bars, open, MeshSpec{}, &rep);
  CHECK(rep.ok);
  const Read r = read_mesh(mesh);
  for (int a = 0; a < 3; ++a) CHECK(r.lo[a] >= -1e-6 && r.hi[a] <= 16.0 + 1e-6);
  CHECK(r.edges_not_twice == 0 && r.flat == 0);
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
  {  // Rule (e): the same bridge 14 mm long reaches 7 mm from either post: too far, though held at both ends.
    MeshSink s;
    add_box(s, 0, 0, 0, 2, 2, 10);
    add_box(s, 16, 0, 0, 18, 2, 10);
    add_box(s, 2, 0, 8, 16, 2, 10);
    const LayerReport r = check_layers(s.mesh);
    CHECK(r.mid_air.empty() && r.one_ended.empty() && r.long_bridges.size() == 1 && !r.clean());
    if (r.long_bridges.size() == 1) {
      const LayerReport::OneEnded& b = r.long_bridges[0];
      CHECK(b.reach_mm > 6.7 && b.reach_mm < 7.2 && std::fabs(b.z - 8.1) < 0.01 && std::fabs(b.x - 9.0) < 0.3 && !b.anything_below);
    }
    LayerSpec loose;
    loose.reach_limit_mm = 8.0;   // his number, when he names one
    CHECK(check_layers(s.mesh, loose).clean());
    LayerSpec off;
    off.reach_limit_mm = 0.0;     // 0 = no limit
    CHECK(check_layers(s.mesh, off).clean());
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
    // point along the border of the little there is that no cell holds (two crumbs, about
    // 2 mm3 in all). Before the fix the writer kept 29.67 mm3 here against the same 2.16:
    // 27.5 mm3 of the part's own surface, in 159 pieces (794 at the usual overlap, and 695
    // loose bits in the mesh).
    CHECK(std::fabs(rx.solid_mm3 - none) < 2.0);
    CHECK(rep.solid_mm3 <= rx.solid_mm3 + 1e-9 && rep.solid_mm3 > rx.solid_mm3 - 3.0);
    CHECK(rx.solid_pieces < 40 && rep.solid_pieces < 40);   // crumbs no cell holds, not slats
    // And none of them a film: the overlap of 0.02 mm neither joins two nor splits one.
    // (Opening air by faces only, not by edges and corners, leaves 430 against 76; not
    // looking past the cube's face for the cell's own lattice, 54 against 32.)
    CHECK(rx.solid_pieces == rep.solid_pieces);
    const Read r = read_mesh(mesh);
    std::printf("no crust, whole part lattice: mesh %zu triangles, %.1f mm3, shells %zu, loose bits %zu, air pockets %zu\n",
                rep.triangles, rep.mm3, r.shells, rep.loose_bits, rep.air_pockets);
    CHECK(r.edges_not_twice == 0 && r.flat == 0 && r.shells == 1);
    CHECK(rep.loose_bits < 40);     // 695 before: the slats the struts did not catch
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
    // holds). Before the fix: 1,057.11 mm3 kept, in 85 pieces, against the same 1,045.67.
    // With every point that touches the space opened, air or not: 1,034.31, the 11 mm3
    // short taken off the pillar's sides.
    // S11b (2026-11-14): against solid the file keeps up to one point more solid than the true edge, never less, so
    // along the skin's inner side and the pillar's sides it now keeps a little more (1,050.34 against the 1,045.67 no
    // cell holds). The tolerance was 4.0 mm3 when the open space reached half a point past every edge.
    CHECK(std::fabs(rx.solid_mm3 - none) < 6.0);
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

// ── a column that changes along its depth ─────────────────────────────────────
// A 24 x 24 x 14 block with a square pocket 8 x 8 mm down from its top face, lattice under
// the top face 10 mm deep. The pocket ends part-way down the top row of cells, below their
// mid-depth: a column through the pocket is air at the cube's middle and the cell's own
// lattice under the pocket's floor. With a Protect skin on the pocket's walls and floor,
// the columns beside the pocket are skin at the cube's middle and lattice below the skin.
// The writer opens exactly where `cell_holds` says lattice and solid where nothing holds
// the place, on both sides of the change (it once read each column at mid-depth only, and
// left such a column solid as a whole).
static TriangleMesh pocketed_block(double side, double tall, double p0, double p1, double floor_z, TriangleMesh* pocket) {
  MeshSink s, w;
  const Vec3 b[4] = {{0, 0, 0}, {side, 0, 0}, {side, side, 0}, {0, side, 0}};
  auto quad = [](MeshSink& m, Vec3 a, Vec3 b2, Vec3 c, Vec3 d) { m.add_triangle(a, b2, c); m.add_triangle(a, c, d); };
  auto up = [](Vec3 v, double z) { return Vec3{v.x, v.y, z}; };
  quad(s, b[0], b[3], b[2], b[1]);   // the bed face
  for (int q = 0; q < 4; ++q) quad(s, b[q], b[(q + 1) % 4], up(b[(q + 1) % 4], tall), up(b[q], tall));
  const Vec3 t[4] = {{p0, p0, tall}, {p1, p0, tall}, {p1, p1, tall}, {p0, p1, tall}};
  for (int q = 0; q < 4; ++q) quad(s, up(b[q], tall), up(b[(q + 1) % 4], tall), t[(q + 1) % 4], t[q]);   // the top, round the pocket
  for (int q = 0; q < 4; ++q) {   // the pocket's walls, facing into it
    quad(s, t[q], t[(q + 1) % 4], up(t[(q + 1) % 4], floor_z), up(t[q], floor_z));
    quad(w, t[q], t[(q + 1) % 4], up(t[(q + 1) % 4], floor_z), up(t[q], floor_z));
  }
  quad(s, up(t[0], floor_z), up(t[1], floor_z), up(t[2], floor_z), up(t[3], floor_z));   // its floor, facing up
  quad(w, up(t[0], floor_z), up(t[1], floor_z), up(t[2], floor_z), up(t[3], floor_z));
  if (pocket) *pocket = w.mesh;
  return s.mesh;
}
static void test_column_changes_down_its_depth() {
  // The top row of cells is 5 mm, from 14 down to 9: its middle (11.5) is above the floor.
  const double side = 24, tall = 14, p0 = 8, p1 = 16, floor_z = 10.5;
  TriangleMesh pocket;
  std::size_t open_edges = 1;
  PartMeasure pm(weld_mesh(pocketed_block(side, tall, p0, p1, floor_z, &pocket), 1e-5, &open_edges));
  CHECK(open_edges == 0);
  for (int skinned = 0; skinned < 2; ++skinned) {
    DomainSpec s;
    s.min_strut_lines = 2.0;
    s.regions = {face_region(1, {side / 2, side / 2, tall}, {0, 0, -1}, side / 2, side / 2, 10.0, 0.0)};
    if (skinned) s.protect.push_back({1, pocket, 1.0});
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_max_mm = 8;
    cs.min_cells_across = 1;
    const Laid l = lay(d, cs);
    CHECK(!l.layout.cells.empty());
    CHECK(!l.layout.walls.empty() && l.layout.walls[static_cast<std::size_t>(l.layout.cells.front().frame)].flat);
    const OpenSpace open = read_open_space(d, l.layout, 0.25);
    CHECK(same_boxes(open, read_open_space(d, l.layout, 0.25, 1)));   // the same boxes on one thread
    // A place is open in the file where it is inside one of the boxes the writer carves out
    // of the part (a box is in its cell's frame).
    auto open_at = [&](int frame, double a, double b, double c) {
      for (const OpenSpace::Box& x : open.boxes)
        if (x.frame == frame && a > x.lo[0] && a < x.hi[0] && b > x.lo[1] && b < x.hi[1] && c > x.lo[2] && c < x.hi[2]) return true;
      return false;
    };
    const Domain::Probe probe = d.probe();
    // Every reading point of every cube, 0.5 mm or more inside the part (nearer its surface
    // the writer opens a little past what is held, on purpose: no crust).
    long held = 0, held_solid = 0, unheld = 0, unheld_open = 0, changed = 0, changed_solid = 0;
    long held_solid_far = 0;   // held, solid in the file, and farther than 0.3 mm from any solid (S11b allows none)
    // Is there solid (inside the part, lattice of no region) within `r` of p? Read on a 0.05 mm grid in the ball.
    auto solid_within = [&](const Vec3& p, double r) {
      const int m = static_cast<int>(std::ceil(r / 0.05));
      for (int z = -m; z <= m; ++z)
        for (int y = -m; y <= m; ++y)
          for (int x = -m; x <= m; ++x) {
            const double dx = x * 0.05, dy = y * 0.05, dz = z * 0.05;
            if (dx * dx + dy * dy + dz * dz > r * r) continue;
            const Why w = probe.where({p.x + dx, p.y + dy, p.z + dz}).why;
            if (w != Why::Lattice && w != Why::Outside) return true;
          }
      return false;
    };
    for (const Cell& c : l.layout.cells) {
      const Frame& f = l.layout.frames[static_cast<std::size_t>(c.frame)];
      const int k = std::max(1, static_cast<int>(std::ceil(c.size / 0.25 - 1e-9)));
      const double h = c.size / k;
      for (int z = 0; z < k; ++z)
        for (int j = 0; j < k; ++j)
          for (int i = 0; i < k; ++i) {
            const Vec3 p = f.at(c.lo[0] + (i + 0.5) * h, c.lo[1] + (j + 0.5) * h, c.lo[2] + (z + 0.5) * h);
            if (probe.part().depth(p) < 0.5) continue;
            bool any = false;
            for (const Cell& o : l.layout.cells) if ((any = cell_holds(l.layout, probe, o, p))) break;
            const bool solid_here = !open_at(c.frame, c.lo[0] + (i + 0.5) * h, c.lo[1] + (j + 0.5) * h, c.lo[2] + (z + 0.5) * h);
            if (any) {
              ++held;
              if (solid_here) {
                ++held_solid;
                if (!solid_within(p, 0.3)) ++held_solid_far;
              }
            } else {
              ++unheld;
              if (!solid_here) ++unheld_open;
            }
            // Under the pocket and beside it, below its floor, in a cell whose middle is above the floor.
            const bool below_mid = p.z < floor_z && p.x > p0 - 1.5 && p.x < p1 + 1.5 && p.y > p0 - 1.5 && p.y < p1 + 1.5;
            if (any && below_mid) {
              const Vec3 mid = f.at(c.lo[0] + (i + 0.5) * h, c.lo[1] + (j + 0.5) * h, c.lo[2] + 0.5 * c.size);
              if (mid.z > floor_z) { ++changed; if (solid_here) ++changed_solid; }
            }
          }
    }
    std::printf("column changes down its depth (%s): %zu cells, %zu open boxes; points held %ld (solid in the file %ld), "
                "held by none %ld (open in the file %ld); held under the pocket's floor in a cube whose middle is above it %ld "
                "(solid in the file %ld)\n", skinned ? "a Protect skin round the pocket" : "a pocket", l.layout.cells.size(),
                open.boxes.size(), held, held_solid, unheld, unheld_open, changed, changed_solid);
    CHECK(held > 1000);
    CHECK(changed > 100);          // the case is really there
    // Before the fix, read at mid-depth only: 5,600 such points left solid under the pocket,
    // 6,456 with the skin.
    if (!skinned) {
      CHECK(changed_solid == 0);   // and is open where the cell holds it
      CHECK(held_solid == 0);      // open exactly where lattice,
    } else {
      // S11b (2026-11-14): against solid the file keeps up to one point more solid than the true edge. Beside the
      // skin a held point may be solid in the file, but only within 0.3 mm of solid, and few of them (800 of 399,720
      // when the rule came in). Was: held_solid == 0 and changed_solid == 0, the exactness S11b gives up on purpose.
      std::printf("  held and solid in the file: %ld, of them farther than 0.3 mm from solid: %ld\n", held_solid, held_solid_far);
      CHECK(held_solid_far == 0);
      CHECK(held_solid * 100 < held);
    }
    CHECK(unheld_open == 0);       // solid exactly where nothing holds it
  }
}

// ── the open space in as few boxes as hold it ─────────────────────────────────
// Inside a cell the points read one by one are put back together as few boxes as hold them:
// equal runs of neighbouring columns, then equal rows. The open space is the same set of
// points as with a box per run (every point of a 0.05 mm grid through the most-cut cubes
// is open in both or in neither), no two boxes overlap more than before, the mesh holds the
// same plastic to a part in a million, and it is far fewer boxes.
static bool in_any(const std::vector<const OpenSpace::Box*>& v, double a, double b, double c) {
  for (const OpenSpace::Box* x : v)
    if (a > x->lo[0] && a < x->hi[0] && b > x->lo[1] && b < x->hi[1] && c > x->lo[2] && c < x->hi[2]) return true;
  return false;
}
static long overlaps(const OpenSpace& o) {
  long n = 0;
  for (std::size_t i = 0; i < o.boxes.size(); ++i)
    for (std::size_t j = i + 1; j < o.boxes.size(); ++j) {
      const OpenSpace::Box &x = o.boxes[i], &y = o.boxes[j];
      if (x.frame != y.frame) continue;
      bool all = true;
      for (int a = 0; a < 3 && all; ++a) all = std::min(x.hi[a], y.hi[a]) - std::max(x.lo[a], y.lo[a]) > 1e-9;
      if (all) ++n;
    }
  return n;
}
static void merged_is_the_same(const char* what, const PartMeasure& pm, const Domain& d, const Laid& l) {
  const OpenSpace each = read_open_space(d, l.layout, 0.25, 0, nullptr, false);
  const OpenSpace merged = read_open_space(d, l.layout, 0.25);
  CHECK(same_boxes(merged, read_open_space(d, l.layout, 0.25, 1)));   // the same boxes on one thread
  CHECK(merged.boxes.size() < each.boxes.size());
  // The most-cut cubes: those with the most runs of their own that end inside the cube.
  std::vector<std::pair<std::size_t, std::size_t>> cut;   // (boxes in the cube, cell)
  for (std::size_t ci = 0; ci < l.layout.cells.size(); ++ci) {
    const Cell& c = l.layout.cells[ci];
    std::size_t n = 0;
    for (const OpenSpace::Box& x : each.boxes)
      if (x.frame == c.frame && x.hi[2] - x.lo[2] < c.size - 1e-9 && x.lo[0] >= c.lo[0] - 1e-9 && x.hi[0] <= c.lo[0] + c.size + 1e-9 && x.lo[1] >= c.lo[1] - 1e-9 &&
          x.hi[1] <= c.lo[1] + c.size + 1e-9 && x.lo[2] >= c.lo[2] - 1e-9 && x.hi[2] <= c.lo[2] + c.size + 1e-9) ++n;
    cut.push_back({n, ci});
  }
  std::sort(cut.rbegin(), cut.rend());
  long points = 0, differ = 0, open_points = 0;
  for (std::size_t q = 0; q < std::min<std::size_t>(3, cut.size()); ++q) {
    const Cell& c = l.layout.cells[cut[q].second];
    auto near = [&](const OpenSpace& o) {
      std::vector<const OpenSpace::Box*> v;
      for (const OpenSpace::Box& x : o.boxes) {
        bool meets = x.frame == c.frame;
        for (int a = 0; a < 3 && meets; ++a) meets = x.hi[a] > c.lo[a] && x.lo[a] < c.lo[a] + c.size;
        if (meets) v.push_back(&x);
      }
      return v;
    };
    const auto ve = near(each), vm = near(merged);
    // Off the 0.25 mm points' own faces by half a step, so no grid point lies on a box's face.
    const int n = static_cast<int>(std::lround(c.size / 0.05));
    for (int z = 0; z < n; ++z)
      for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
          const double a = c.lo[0] + 0.025 + 0.05 * i, b = c.lo[1] + 0.025 + 0.05 * j, h = c.lo[2] + 0.025 + 0.05 * z;
          const bool oe = in_any(ve, a, b, h), om = in_any(vm, a, b, h);
          ++points;
          if (oe) ++open_points;
          if (oe != om) ++differ;
        }
  }
  const long ov_each = overlaps(each), ov_merged = overlaps(merged);
  MeshReport re, rm, se, sm;
  (void)build_mesh(pm, d, l.layout, l.bars, each, MeshSpec{}, &re);
  (void)build_mesh(pm, d, l.layout, l.bars, merged, MeshSpec{}, &rm);
  (void)build_mesh(pm, d, l.layout, Bars{}, each, MeshSpec{}, &se);     // the solid body alone
  (void)build_mesh(pm, d, l.layout, Bars{}, merged, MeshSpec{}, &sm);
  std::printf("merged (%s): %zu cells, %zu boxes a run each, %zu merged; %ld grid points in the 3 most-cut cubes (%ld open), "
              "%ld differ; overlapping pairs %ld -> %ld; mesh %.6f -> %.6f mm3, the part less the open space %.6f -> %.6f mm3\n",
              what, l.layout.cells.size(), each.boxes.size(), merged.boxes.size(), points, open_points, differ, ov_each, ov_merged,
              re.mm3, rm.mm3, se.solid_mm3, sm.solid_mm3);
  CHECK(open_points > 1000 && open_points < points);   // the cubes are really cut
  CHECK(differ == 0);
  CHECK(ov_merged <= ov_each);
  CHECK(re.ok && rm.ok && se.ok && sm.ok);
  CHECK(std::fabs(rm.mm3 - re.mm3) <= 1e-6 * re.mm3);
  // The part less the open space, as carved (before the mesh is cleaned): the same shape. (The
  // body's own mesh may differ by a few hundredths of a mm3 where two of its surfaces touch
  // along a line: the writer draws such corners apart by microns, and which corners Manifold
  // gives at one place depends on the boxes it was handed.)
  CHECK(std::fabs(sm.solid_mm3 - se.solid_mm3) <= 1e-6 * se.solid_mm3);
}
static void test_open_space_merged() {
  {  // The pocket of test_column_changes_down_its_depth, with and without its skin, and laid as one grid.
    const double side = 24, tall = 14, p0 = 8, p1 = 16, floor_z = 10.5;
    TriangleMesh pocket;
    PartMeasure pm(weld_mesh(pocketed_block(side, tall, p0, p1, floor_z, &pocket)));
    for (int v = 0; v < 3; ++v) {
      DomainSpec s;
      s.min_strut_lines = 2.0;
      s.regions = {face_region(1, {side / 2, side / 2, tall}, {0, 0, -1}, side / 2, side / 2, 10.0, 0.0)};
      if (v > 0) s.protect.push_back({1, pocket, 1.0});
      Domain d(pm, s);
      CellSpec cs;
      cs.algorithm = Algorithm::Uniform;
      cs.cell_max_mm = 8;
      cs.min_cells_across = 1;
      cs.one_grid = v == 2;
      merged_is_the_same(v == 0 ? "a pocket" : v == 1 ? "a Protect skin round the pocket" : "the skinned pocket, one grid",
                         pm, d, lay(d, cs));
    }
  }
  {  // Cut cells with a slanted wall: the turned block with its 16-sided hole, the whole part lattice.
    const Holed hb = holed_block();
    PartMeasure pm(weld_mesh(hb.part));
    DomainSpec s;
    s.start = Start::AllLattice;
    s.min_strut_lines = 2.0;
    Domain d(pm, s);
    CellSpec cs;
    cs.algorithm = Algorithm::Uniform;
    cs.cell_mm = 5.0;
    cs.min_cells_across = 1;
    merged_is_the_same("the turned block with a hole, whole part", pm, d, lay(d, cs));
  }
}

// S11b: the file never opens space past the lattice's edge where that edge is against solid. A Protect skin 1 mm
// deep on the curved wall of the turned block's hole, the whole part latticed: read along the wall's normals, the
// skin in the mesh is nowhere thinner than its depth (with the step off, an opened point reached into it).
static void test_skin_never_thinned() {
  const Holed hb = holed_block();
  PartMeasure pm(weld_mesh(hb.part));
  DomainSpec s;
  s.start = Start::AllLattice;
  s.min_strut_lines = 2.0;
  const double skin = 1.0;
  s.protect.push_back({1, hb.wall, skin});
  Domain d(pm, s);
  CellSpec cs;
  cs.algorithm = Algorithm::Uniform;
  cs.cell_mm = 5.0;
  const Laid l = lay(d, cs);
  const double kPi = 3.14159265358979323846;
  int thin[2] = {0, 0}, asked = 0;
  for (int on = 0; on < 2; ++on) {
    const OpenSpace open = read_open_space(d, l.layout, 0.25, 0, nullptr, true, on == 1);
    MeshSpec ms;
    ms.grow_mm = 0.001;
    MeshReport rep;
    const TriangleMesh mesh = build_mesh(pm, d, l.layout, Bars{}, open, ms, &rep);   // the solid alone
    CHECK(rep.ok);
    const PartMeasure m(weld_mesh(mesh));
    const PartMeasure::Probe in = m.probe();
    asked = 0;
    for (int a = 0; a < 360; ++a)
      for (int h = 1; h < 12; ++h) {
        const double t = 2.0 * kPi * (a + 0.5) / 360.0, r = kHoledRadius + skin - 0.02;
        ++asked;
        thin[on] += !in.inside(turned(r * std::cos(t), r * std::sin(t), 0.5 * h));
      }
  }
  std::printf("skin never thinned: %d of %d points 0.02 mm inside the skin's depth are empty with the step off, %d with it on\n",
              thin[0], asked, thin[1]);
  CHECK(thin[1] == 0);
}

// ── ORGANIC (WEAVE), rules O1, O2: the file ──────────────────────────────────
// The layout test's block (lattice_layout.cpp, weave_block): 40 x 14 x 20 with a half-round pocket (radius 6) in its
// top edge along z; faces 0 the underside, 1 the pocket's wall, 2 the rest. The same made-up weave.
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
static Vec3 round_pocket(double r, double deg, double z) {
  const double t = deg * 3.14159265358979323846 / 180.0;
  return {20.0 + r * std::cos(t), 14.0 - r * std::sin(t), z};
}
static Strand weave_strand(std::vector<Vec3> pts, int region = 1) {
  Strand s;
  s.width_mm.assign(pts.size(), 0.9);
  s.points = std::move(pts);
  s.region = region;
  s.spacing_mm = 4.0;
  return s;
}
static std::vector<Strand> made_up_weave() {   // as in the layout test
  std::vector<Strand> w;
  const double r = 7.75;
  for (double z : {4.0, 8.0, 12.0}) {
    std::vector<Vec3> p;
    for (double t = -15; t <= 195 + 1e-9; t += 30) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {
    std::vector<Vec3> p;
    for (double t = 45; t <= 135 + 1e-9; t += 30) p.push_back(round_pocket(r, t, 16.0));
    w.push_back(weave_strand(p));
  }
  for (double t : {30.0, 60.0, 90.0, 120.0, 150.0}) {
    std::vector<Vec3> p;
    for (double z = -1; z <= 21 + 1e-9; z += 2) p.push_back(round_pocket(r, t, z));
    w.push_back(weave_strand(p));
  }
  {
    std::vector<Vec3> p;
    for (double z = 6; z <= 14 + 1e-9; z += 2) p.push_back(round_pocket(r, 165.0, z));
    w.push_back(weave_strand(p));
  }
  w.push_back(weave_strand({round_pocket(7.0, 60, 10), round_pocket(9.0, 60, 10), round_pocket(11.5, 60, 10)}));
  w.push_back(weave_strand({round_pocket(9.0, 90, 6), round_pocket(4.5, 90, 6)}));
  w.push_back(weave_strand({round_pocket(9.6, 45, 16), round_pocket(8.9, 45, 16)}));
  return w;
}
static double to_segment(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 d{b.x - a.x, b.y - a.y, b.z - a.z};
  const double l2 = d.x * d.x + d.y * d.y + d.z * d.z;
  const double t = l2 > 0 ? std::clamp(((p.x - a.x) * d.x + (p.y - a.y) * d.y + (p.z - a.z) * d.z) / l2, 0.0, 1.0) : 0.0;
  return std::hypot(p.x - a.x - d.x * t, std::hypot(p.y - a.y - d.y * t, p.z - a.z - d.z * t));
}

// O1, O2, the file of a weave: open between its struts, the struts one body with the part, nothing outside it, no
// crust at the open surface, no slit against the solid (S11b); the layer check runs to its end.
static void test_weave_file() {
  const StepModel model = weave_block();
  Session session(model);
  Settings s;
  s.regions = {{1, Role::Lattice, {1}, 4.0, 0.0, true}, {2, Role::Lattice, {0}, 3.0, 0.0, false}};
  s.cells.cell_max_mm = 4;
  s.cells.min_cells_across = 1;
  s.struts.allow_quilt = true;
  const Outcome out = session.lay_weave(s, made_up_weave());
  const Domain& d = *session.domain();
  auto pr = d.probe();
  CHECK(!out.cancelled && out.layout.weave.size() == 1 && !out.bars.bars.empty());
  const OpenSpace open = read_open_space(d, out.layout, 0.25), open1 = read_open_space(d, out.layout, 0.25, 1),
                  open8 = read_open_space(d, out.layout, 0.25, 8);
  CHECK(same_boxes(open, open1) && same_boxes(open, open8));
  OpenSpace cells_only;   // the cells' boxes alone come first and are today's
  {
    Layout no_weave = out.layout;
    no_weave.weave.clear();
    cells_only = read_open_space(d, no_weave, 0.25);
    bool first_same = cells_only.boxes.size() < open.boxes.size();
    for (std::size_t i = 0; first_same && i < cells_only.boxes.size(); ++i) {
      const OpenSpace::Box &x = cells_only.boxes[i], &y = open.boxes[i];
      first_same = x.frame == y.frame && std::equal(x.lo, x.lo + 3, y.lo) && std::equal(x.hi, x.hi + 3, y.hi);
    }
    CHECK(first_same);
  }
  PrintableReport rep;
  const TriangleMesh mesh = build_printable_mesh(session.measure(), d, out.layout, out.bars, open, PrintableSpec{}, &rep);
  CHECK(rep.mesh.ok && !mesh.empty());
  const Read r = read_mesh(mesh);
  std::printf("weave file: %zu open boxes (%zu of the cells), %zu bars (%zu bridges), %zu triangles, %zu shells, %zu edges not twice; "
              "%d builds, clean %d, found per pass %s; left out %zu bars, %zu posts; air pockets %zu, sealed %zu, loose bits %zu\n",
              open.boxes.size(), cells_only.boxes.size(), rep.mesh.bars, rep.mesh.bridges, mesh.triangles.size(), r.shells,
              r.edges_not_twice, rep.passes, rep.clean ? 1 : 0, [&] {
                static char buf[128];
                buf[0] = 0;
                for (int f : rep.found_per_pass) std::snprintf(buf + std::strlen(buf), sizeof buf - std::strlen(buf), "%d ", f);
                return buf;
              }(), rep.mesh.bars_left_out, rep.posts.size(), rep.mesh.air_pockets, rep.mesh.sealed_spaces, rep.mesh.loose_bits);
  CHECK(r.edges_not_twice == 0 && r.flat == 0);
  CHECK(r.shells == 1);   // one body: the struts are joined to the part
  CHECK(rep.passes >= 1 && rep.layers.layers > 0);   // the layer check ran to its end and reported
  // Nothing outside the part.
  long outside = 0;
  for (const Vec3& v : mesh.vertices) outside += pr.part().depth(v) < -0.01;
  CHECK(outside == 0);
  // The mesh read back as a solid.
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
  // (a) Open between the struts: points of the weave region away from every strut and from the region's edge.
  // (b) No crust: the same a fifth of a millimetre under the pocket's wall. (c) No slit: just past the region's far
  // edge, in the solid behind it.
  long a_n = 0, a_full = 0, b_n = 0, b_full = 0, c_n = 0, c_empty = 0;
  for (double z = 1.0; z < 19.5; z += 0.7)
    for (double deg = 12; deg < 170; deg += 3.1) {
      for (double rr : {7.0, 8.3, 9.2}) {
        const Vec3 p = round_pocket(rr, deg, z);
        const Where w = pr.where(p);
        if (!w.lattice() || w.id != 1 || !far_from_struts(p, 0.6)) continue;
        ++a_n;
        a_full += fp.inside(p);
      }
      const Vec3 q = round_pocket(6.2, deg, z);
      if (pr.where(q).lattice() && far_from_struts(q, 0.6)) { ++b_n; b_full += fp.inside(q); }
      const Vec3 c = round_pocket(10.4, deg, z);
      const Where wc = pr.where(c);
      if (wc.why == Why::NotAsked && far_from_struts(c, 0.6)) { ++c_n; c_empty += !fp.inside(c); }
    }
  std::printf("weave file: in the region away from struts %ld points, %ld filled; under the pocket's wall %ld, %ld filled; "
              "in the solid past the region %ld, %ld empty\n", a_n, a_full, b_n, b_full, c_n, c_empty);
  CHECK(a_n > 300 && a_full == 0);
  CHECK(b_n > 100 && b_full == 0);
  CHECK(c_n > 100 && c_empty == 0);
  // Left out as build_mesh leaves a strut out: its lowest point at a place the layer check found.
  auto left_out_bar = [&](const Bar& b) {
    const double rr = 0.5 * b.width;
    for (const Vec3& sp : rep.drop_at) {
      if (std::fabs(std::min(b.a.z, b.b.z) - rr - sp.z) > 0.45) continue;
      if (to_segment(sp, b.a, b.b) < rr + 0.35) return true;
    }
    return false;
  };
  // The struts are in the file: the middle of every bar the layer check did not leave out is material.
  long mids = 0, mids_full = 0;
  for (const Bar& b : out.bars.bars) {
    if (b.region != 1 || left_out_bar(b)) continue;
    const Vec3 m{0.5 * (b.a.x + b.b.x), 0.5 * (b.a.y + b.b.y), 0.5 * (b.a.z + b.b.z)};
    if (pr.part().depth(m) < 0.3) continue;
    ++mids;
    mids_full += fp.inside(m);
  }
  std::printf("weave file: %ld weave bars' middles inside the part, %ld of them material\n", mids, mids_full);
  CHECK(mids > 30 && mids_full == mids);

  // For the review: the weave's shallow bars (under 30 degrees from level), held at both ends, by length, and what the
  // layer check did with them.
  {
    long shallow = 0, held_both = 0, band[4] = {0, 0, 0, 0}, kept = 0, left_out = 0, posted = 0;
    auto lands = [](Bar::End e) { return e == Bar::End::Node || e == Bar::End::Solid || e == Bar::End::Joined; };
    for (const Bar& b : out.bars.bars) {
      if (b.region != 1 || !bar_is_bridge(b)) continue;
      ++shallow;
      held_both += lands(b.end_a) && lands(b.end_b);
      const double len = std::sqrt((b.b.x - b.a.x) * (b.b.x - b.a.x) + (b.b.y - b.a.y) * (b.b.y - b.a.y) + (b.b.z - b.a.z) * (b.b.z - b.a.z));
      ++band[len <= 5 ? 0 : len <= 10 ? 1 : len <= 20 ? 2 : 3];
      const double rr = 0.5 * b.width;
      const bool out_here = left_out_bar(b);
      bool post_here = false;
      for (const MeshSpec::Post& q : rep.posts)
        post_here = post_here || to_segment(Vec3{q.x, q.y, q.z_top}, b.a, b.b) < rr + 0.5;
      left_out += out_here;
      posted += !out_here && post_here;
      kept += !out_here && !post_here;
    }
    std::printf("weave shallow bars: %ld under 30 degrees, %ld held at both ends; lengths to 5 mm %ld, 5-10 %ld, 10-20 %ld, over 20 %ld; "
                "layer check: kept %ld, left out %ld, post under %ld\n", shallow, held_both, band[0], band[1], band[2], band[3], kept,
                left_out, posted);
    CHECK(shallow > 0);
  }
}

// O2: a sealed space smaller than one spacing cubed is filled; a larger one stays. Two weave regions under the top of
// a block, sealed in by a Protect skin over the whole top: 3 x 3 x 3 mm (27 mm3, under 4 cubed) and 8 x 8 x 3 mm.
static void test_weave_sealed() {
  PartMeasure pm(weld_mesh(box(30, 30, 12)));
  DomainSpec s;
  s.min_strut_lines = 2.0;
  s.regions = {face_region(1, {8, 8, 12}, {0, 0, -1}, 1.5, 1.5, 4.0, 0.0), face_region(2, {20, 20, 12}, {0, 0, -1}, 4, 4, 4.0, 0.0)};
  for (Region& r : s.regions) r.weave = true;
  ProtectSkin top;
  top.id = 1;
  {
    MeshSink f;
    f.add_triangle({0, 0, 12}, {30, 0, 12}, {30, 30, 12});
    f.add_triangle({0, 0, 12}, {30, 30, 12}, {0, 30, 12});
    top.face = f.mesh;
  }
  top.depth_mm = 1.0;
  s.protect = {top};
  Domain d(pm, s);
  Layout layout = lay_cells(d, CellSpec{});
  CHECK(layout.cells.empty() && layout.solid.empty() && layout.weave.size() == 2);
  const std::vector<Strand> strands = {weave_strand({{8, 8, 11.9}, {8, 8, 7.2}}, 1), weave_strand({{20, 20, 11.9}, {20, 20, 7.2}}, 2)};
  const Bars bars = weave_bars(d, strands);
  CHECK(bars.bars.size() == 2);
  for (const Bar& b : bars.bars) CHECK(b.end_a == Bar::End::Solid && b.end_b == Bar::End::Solid);
  const OpenSpace open = read_open_space(d, layout, 0.25);
  MeshReport none, spaced;
  (void)build_mesh(pm, d, layout, bars, open, MeshSpec{}, &none);   // no spacing yet: the floor of 1 mm3
  for (Layout::Weave& w : layout.weave) w.spacing_mm = 4.0;
  const TriangleMesh mesh = build_mesh(pm, d, layout, bars, open, MeshSpec{}, &spaced);
  std::printf("weave sealed: with no spacing filled under %.0f mm3: %zu filled, %zu kept; at 4 mm under %.0f: %zu filled (%.1f mm3), %zu kept\n",
              none.filled_under_mm3, none.air_pockets, none.sealed_spaces, spaced.filled_under_mm3, spaced.air_pockets,
              spaced.air_pockets_mm3, spaced.sealed_spaces);
  CHECK(none.ok && spaced.ok);
  CHECK(none.sealed_spaces == 2 && none.air_pockets == 0);
  CHECK(spaced.filled_under_mm3 == 64.0 && spaced.air_pockets == 1 && spaced.sealed_spaces == 1);
  CHECK(spaced.air_pockets_mm3 > 15.0 && spaced.air_pockets_mm3 < 27.5);
  // The same for one thread and eight.
  MeshSpec one, eight;
  one.threads = 1;
  eight.threads = 8;
  CHECK(same_boxes(read_open_space(d, layout, 0.25, 1), read_open_space(d, layout, 0.25, 8)));
  CHECK(same_mesh(build_mesh(pm, d, layout, bars, open, one), build_mesh(pm, d, layout, bars, open, eight)));
  CHECK(same_mesh(mesh, build_mesh(pm, d, layout, bars, open, one)));
}

// ── The owner's bridge rules for a weave (O5 to O10) ──────────────────────────
// A made-up 40 x 40 x 20 block, a weave region under its top face 30 x 30 (solid walls 5 mm thick all round), `depth`
// deep: 20.5 runs through to the bed (nothing under the lattice), 14 leaves a solid floor 6 mm thick. Bars made from
// made-up strands (weave_bars), or built by hand. `weave` false: the same block and open space, but the layout names
// no weave region, so every bar is judged as a cube-lattice bar.
struct BridgeBlock {
  PartMeasure pm;
  Domain d;
  Layout layout;
  OpenSpace open;
  static DomainSpec spec(double depth) {
    DomainSpec s;
    s.min_strut_lines = 2.0;
    s.regions = {face_region(1, {20, 20, 20}, {0, 0, -1}, 15, 15, depth, 0.0)};
    s.regions[0].weave = true;
    return s;
  }
  explicit BridgeBlock(double depth)
      : pm(weld_mesh(box(40, 40, 20))), d(pm, spec(depth)), layout(lay_cells(d, CellSpec{})), open(read_open_space(d, layout, 0.25)) {
    for (Layout::Weave& w : layout.weave) w.spacing_mm = 4.0;
  }
  Layout as_cube() const {
    Layout l = layout;
    l.weave.clear();
    return l;
  }
};
static Strand level_strand(Vec3 a, Vec3 b) { return weave_strand({a, b}, 1); }
static Bar hand_bar(Vec3 a, Bar::End ea, Vec3 b, Bar::End eb, int into_b = -1) {
  Bar x;
  x.a = a; x.b = b; x.width = 0.9; x.cell = 4.0; x.region = 1; x.end_a = ea; x.end_b = eb; x.into_b = into_b;
  return x;
}
static bool material_at(const TriangleMesh& mesh, const Vec3& p) {
  PartMeasure file(weld_mesh(mesh, 1e-6));
  return file.probe().inside(p);
}
static void say_bridges(const char* what, const PrintableReport& rep) {
  std::printf("bridges %s: %zu bars written (%zu bridges), kept any length %zu, left unheld %zu, left out at places %zu; "
              "%d builds, found per pass", what, rep.mesh.bars, rep.mesh.bridges, rep.mesh.kept_any_length,
              rep.mesh.weave_left_unheld, rep.mesh.bars_left_out, rep.passes);
  for (int f : rep.found_per_pass) std::printf(" %d", f);
  std::printf("; posts %zu (stands %zu)", rep.posts.size(), rep.stands_added);
  for (const MeshSpec::Post& p : rep.posts) std::printf(" [%.2f %.2f %.2f..%.2f]", p.x, p.y, p.z_bottom, p.z_top);
  std::printf("; mid-air %zu, one-ended %zu, long bridges %zu, longest reach %.2f mm, clean %d\n", rep.layers.mid_air.size(),
              rep.layers.one_ended.size(), rep.layers.long_bridges.size(), rep.layers.longest_reach_mm, rep.clean ? 1 : 0);
}

// O7, O8, O10 (tests 1, 6, 8): a level weave bar 30 mm long between the pocket's two walls, nothing under it, is kept
// with no post; the same bar judged as a cube-lattice bar is not (the 5 mm reach rule still bites).
static void test_weave_bridge_any_length() {
  const BridgeBlock k(20.5);
  const Bars bars = weave_bars(k.d, {level_strand({2, 20, 10}, {38, 20, 10})});
  CHECK(bars.bars.size() == 1);
  if (bars.bars.size() != 1) return;
  CHECK(bars.bars[0].end_a == Bar::End::Solid && bars.bars[0].end_b == Bar::End::Solid);
  // The same bar as a cube-lattice bar: today's rules, a bridge reaching 15 mm past what holds it.
  PrintableReport cube;
  (void)build_printable_mesh(k.pm, k.d, k.as_cube(), bars, k.open, PrintableSpec{}, &cube);
  say_bridges("level 30 mm, as a cube bar", cube);
  CHECK(cube.mesh.ok && !cube.found_per_pass.empty() && cube.found_per_pass[0] >= 1);
  CHECK(cube.posts.size() + cube.mesh.bars_left_out >= 1);   // posted or left out
  CHECK(cube.mesh.kept_any_length == 0 && cube.mesh.weave_left_unheld == 0 && cube.stands_added == 0);
  // As a weave bar: kept at any length, no post (nothing below it), nothing found.
  PrintableReport rep;
  const TriangleMesh mesh = build_printable_mesh(k.pm, k.d, k.layout, bars, k.open, PrintableSpec{}, &rep);
  say_bridges("level 30 mm, weave", rep);
  CHECK(rep.mesh.ok && rep.clean && rep.passes == 1);
  CHECK(rep.mesh.kept_any_length == 1 && rep.mesh.weave_left_unheld == 0 && rep.mesh.bars_left_out == 0);
  CHECK(rep.mesh.bridges == 1 && rep.posts.empty() && rep.stands_added == 0);
  CHECK(rep.layers.mid_air.empty() && rep.layers.one_ended.empty() && rep.layers.long_bridges.empty());
  CHECK(rep.layers.longest_reach_mm > 10.0);   // the check still measures it
  CHECK(material_at(mesh, {20, 20, 10}) && material_at(mesh, {8, 20, 10}) && !material_at(mesh, {20, 20, 5}));
  CHECK(read_mesh(mesh).shells == 1);
}

// O5 (test 2): the same bar sloping at 10 and at 25 degrees between the walls: kept, and its underside in the mesh is
// one flat plane along the bar (the downward faces over its middle share one normal within 1 degree, square to the
// bar's own line and its level side).
static void test_weave_bridge_flat_underside() {
  const BridgeBlock k(20.5);
  const double t10 = std::tan(10.0 * 3.14159265358979323846 / 180.0), t25 = std::tan(25.0 * 3.14159265358979323846 / 180.0);
  const Bars bars = weave_bars(k.d, {level_strand({2, 12, 7}, {38, 12, 7 + 36 * t10}), level_strand({2, 28, 2}, {38, 28, 2 + 36 * t25})});
  CHECK(bars.bars.size() == 2);
  if (bars.bars.size() != 2) return;
  PrintableReport rep;
  const TriangleMesh mesh = build_printable_mesh(k.pm, k.d, k.layout, bars, k.open, PrintableSpec{}, &rep);
  say_bridges("sloping 10 and 25 degrees, weave", rep);
  CHECK(rep.mesh.ok && rep.clean && rep.mesh.kept_any_length == 2 && rep.mesh.bridges == 2 && rep.mesh.weave_left_unheld == 0);
  CHECK(rep.posts.empty() && rep.layers.mid_air.empty());
  for (int q = 0; q < 2; ++q) {
    const Bar& b = bars.bars[static_cast<std::size_t>(q)];
    const double y = q == 0 ? 12.0 : 28.0;
    Vec3 d{b.b.x - b.a.x, b.b.y - b.a.y, b.b.z - b.a.z};
    const double l = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    d = {d.x / l, d.y / l, d.z / l};
    const Vec3 want{d.z * (d.x > 0 ? 1.0 : -1.0), 0.0, -std::fabs(d.x)};   // square to the bar, in its upright plane, down
    long faces = 0, off = 0;
    double worst = 0.0;
    for (const auto& t : mesh.triangles) {
      const Vec3 &p = mesh.vertices[static_cast<std::size_t>(t[0])], &r = mesh.vertices[static_cast<std::size_t>(t[1])],
                 &s = mesh.vertices[static_cast<std::size_t>(t[2])];
      const Vec3 c{(p.x + r.x + s.x) / 3, (p.y + r.y + s.y) / 3, (p.z + r.z + s.z) / 3};
      if (c.x < 12 || c.x > 28 || std::fabs(c.y - y) > 0.6) continue;
      const Vec3 e1{r.x - p.x, r.y - p.y, r.z - p.z}, e2{s.x - p.x, s.y - p.y, s.z - p.z};
      Vec3 n{e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x};
      const double ln = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
      if (ln < 1e-12) continue;
      n = {n.x / ln, n.y / ln, n.z / ln};
      if (n.z > -0.05) continue;   // the faces that look down: the underside
      ++faces;
      const double deg = std::acos(std::clamp(n.x * want.x + n.y * want.y + n.z * want.z, -1.0, 1.0)) * 180.0 / 3.14159265358979323846;
      worst = std::max(worst, deg);
      off += deg > 1.0;
    }
    std::printf("bridges flat underside at %s degrees: %ld downward faces over its middle, worst %.4f degrees off one plane\n",
                q == 0 ? "10" : "25", faces, worst);
    CHECK(faces >= 2 && off == 0);
  }
}

// O8 (test 3): the 30 mm level bar over a solid floor 6 mm below: one post at its middle with the default 20 mm; none
// with 0; none when a kept crossing bar already stands under its middle.
static void test_weave_bridge_stands() {
  const BridgeBlock k(14.0);
  const Bars bars = weave_bars(k.d, {level_strand({2, 20, 12.45}, {38, 20, 12.45})});
  CHECK(bars.bars.size() == 1);
  if (bars.bars.size() != 1) return;
  {
    PrintableReport rep;
    const TriangleMesh mesh = build_printable_mesh(k.pm, k.d, k.layout, bars, k.open, PrintableSpec{}, &rep);
    say_bridges("level 30 mm over a floor, stand every 20", rep);
    CHECK(rep.mesh.ok && rep.clean && rep.mesh.kept_any_length == 1);
    CHECK(rep.stands_added == 1 && rep.posts.size() == 1);
    if (rep.posts.size() == 1) {
      const MeshSpec::Post& p = rep.posts[0];
      CHECK(std::fabs(p.x - 20.0) < 0.01 && std::fabs(p.y - 20.0) < 1e-9 && p.z_top == 12.45);
      CHECK(p.z_bottom > 5.0 && p.z_bottom < 6.0);   // it starts on the floor
    }
    CHECK(rep.layers.mid_air.empty() && rep.layers.one_ended.empty() && rep.layers.long_bridges.empty());
    CHECK(material_at(mesh, {20, 20, 9}) && !material_at(mesh, {12, 20, 9}));
  }
  {
    PrintableSpec never;
    never.mesh.weave_stand_every_mm = 0.0;
    PrintableReport rep;
    (void)build_printable_mesh(k.pm, k.d, k.layout, bars, k.open, never, &rep);
    say_bridges("level 30 mm over a floor, stands off", rep);
    CHECK(rep.mesh.ok && rep.clean && rep.posts.empty() && rep.stands_added == 0 && rep.layers.mid_air.empty());
  }
  {
    // A strand rising from the floor through the bar's middle: the crossing is a stand, 15.9 mm from each end.
    Bars crossed = weave_bars(k.d, {level_strand({2, 20, 12.45}, {38, 20, 12.45}), level_strand({20, 20, 3}, {20, 20, 21})});
    const std::size_t joints = split_at_crossings(crossed);
    CHECK(joints == 1 && crossed.bars.size() == 4);
    PrintableReport rep;
    (void)build_printable_mesh(k.pm, k.d, k.layout, crossed, k.open, PrintableSpec{}, &rep);
    say_bridges("level 30 mm over a floor, crossed at its middle", rep);
    CHECK(rep.mesh.ok && rep.clean && rep.mesh.kept_any_length == 2 && rep.posts.empty() && rep.stands_added == 0);
    CHECK(rep.layers.mid_air.empty());
  }
}

// O9 (tests 4, 5): a shallow bar held at one end only is left out before the check, counted, never posted; one whose
// far end lands on a bar that is itself left out is left out too (held means held by something kept).
static void test_weave_bridge_leads_to_nothing() {
  const BridgeBlock k(20.5);
  {
    const Bars bars = weave_bars(k.d, {level_strand({2, 20, 10}, {15, 20, 10})});
    CHECK(bars.bars.size() == 1 && bars.bars[0].end_a == Bar::End::Solid && bars.bars[0].end_b == Bar::End::Loose);
    PrintableReport rep;
    const TriangleMesh mesh = build_printable_mesh(k.pm, k.d, k.layout, bars, k.open, PrintableSpec{}, &rep);
    say_bridges("held at one end", rep);
    CHECK(rep.mesh.ok && rep.clean && rep.passes == 1 && rep.found_per_pass == std::vector<int>{0});
    CHECK(rep.mesh.weave_left_unheld == 1 && rep.mesh.kept_any_length == 0 && rep.mesh.bars == 0 && rep.mesh.bars_left_out == 0);
    CHECK(rep.posts.empty() && rep.stands_added == 0 && rep.layers.mid_air.empty());
    CHECK(!material_at(mesh, {10, 20, 10}));
  }
  // By hand: bar 0 from the wall to the air (held at one end); bar 1 from the wall to a point of bar 0 (Joined in it).
  auto pair = [](bool far_end_held) {
    Bars b;
    b.bars.push_back(hand_bar({4.1, 26, 10}, Bar::End::Solid, {far_end_held ? 35.9 : 15.0, 26, 10},
                              far_end_held ? Bar::End::Solid : Bar::End::Loose));
    b.bars.push_back(hand_bar({4.1, 20, 10}, Bar::End::Solid, {12, 26, 10}, Bar::End::Joined, 0));
    return b;
  };
  {
    PrintableReport rep;
    const TriangleMesh mesh = build_printable_mesh(k.pm, k.d, k.layout, pair(false), k.open, PrintableSpec{}, &rep);
    say_bridges("landing on a bar left out", rep);
    CHECK(rep.mesh.ok && rep.clean && rep.found_per_pass == std::vector<int>{0});
    CHECK(rep.mesh.weave_left_unheld == 2 && rep.mesh.kept_any_length == 0 && rep.mesh.bars == 0);
    CHECK(rep.posts.empty() && rep.layers.mid_air.empty());
    CHECK(!material_at(mesh, {8.05, 23, 10}) && !material_at(mesh, {10, 26, 10}));
  }
  {
    PrintableReport rep;
    (void)build_printable_mesh(k.pm, k.d, k.layout, pair(true), k.open, PrintableSpec{}, &rep);
    say_bridges("landing on a bar held at both ends", rep);
    CHECK(rep.mesh.ok && rep.mesh.weave_left_unheld == 0 && rep.mesh.kept_any_length == 2 && rep.mesh.bars == 2);
    CHECK(rep.layers.mid_air.empty());
  }
  // The same three bars as cube-lattice bars: judged as today (the check finds them, nothing is left out before it).
  {
    PrintableReport rep;
    (void)build_printable_mesh(k.pm, k.d, k.as_cube(), pair(false), k.open, PrintableSpec{}, &rep);
    say_bridges("landing on a bar left out, as cube bars", rep);
    CHECK(rep.mesh.ok && rep.mesh.weave_left_unheld == 0 && !rep.found_per_pass.empty() && rep.found_per_pass[0] >= 1);
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
  test_weave_bridge_any_length();
  test_weave_bridge_flat_underside();
  test_weave_bridge_stands();
  test_weave_bridge_leads_to_nothing();
  test_weave_sealed();
  test_weave_file();
  test_block();
  test_whole_part();
  test_strut_reach_stays_in_the_part();
  test_skin_never_thinned();
  test_no_crust();
  test_column_changes_down_its_depth();
  test_open_space_merged();
  test_layers();
  test_printable();
  std::printf("%d checks, %d failed\n", g_checks, g_fail);
  return g_fail ? 1 : 0;
}
