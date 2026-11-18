// Brief E2, item 8: the Organic strength check's frame of beams (lattice_layout_frame.hpp) on made frames, driven by
// made voxel fields (no part, no solve of the grid: each test sets the displacement and the material itself).
// §1 one straight strut pulled between two solid blocks: its stress is F / A within 2 %.
// §2 a cantilever strut loaded at its tip through the load rule (item 5): its root stress is P L r / I within 5 %.
// §3 a slender strut in compression between two solid blocks: its buckling margin is the pinned Euler load over its
//    force, within 2 %.
// §4 a T-join: a strut ending on another's middle splits it; three struts, all judged.
// §5 two struts joined by a link move as one where the link joins them.
// §6 a load on open lattice with no strut near: it is unheld, and the check says load_on_open_lattice.
// §7 a loaded face with a strut end near only part of it: the lattice's share of the whole load is held there.
// §8 a load near a piece of the frame with no driven node: counted (loaded_nodes_undriven), the load path fails there.
// §9 the bed floor (prototype --floor-shift, --floor-free): a bed-floor node reads its drive frame_floor_shift_voxels up;
//    with frame_floor_free it is not driven. The weakest's ends say what drives them.
#include "topopt/lattice_layout_frame.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

namespace {

int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace ll = topopt::lattice_layout;
using topopt::Vec3;

constexpr double kE = 1600.0, kNu = 0.39, kLevel = 38.0, kAcross = 28.5, kW = 0.9;

ll::Bar bar(Vec3 a, Vec3 b, ll::Bar::End ea, ll::Bar::End eb, double w = kW, bool link = false) {
  ll::Bar x;
  x.a = a;
  x.b = b;
  x.width = w;
  x.end_a = ea;
  x.end_b = eb;
  x.link = link;
  return x;
}

// A grid of h = 0.5 mm voxels, its low corner at `origin`; every voxel's material and every node's displacement set.
struct Field {
  topopt::VoxelGrid grid;
  std::vector<double> u;
  ll::FrameMaterial mat;
  Field(Vec3 origin, int nx, int ny, int nz, double h = 0.5) {
    grid.nx = nx;
    grid.ny = ny;
    grid.nz = nz;
    grid.spacing = h;
    grid.origin = origin;
    grid.tags.assign(static_cast<std::size_t>(nx) * ny * nz, topopt::VoxelTag::Interior);
    u.assign(3 * static_cast<std::size_t>(nx + 1) * (ny + 1) * (nz + 1), 0.0);
    mat.solid.assign(grid.voxel_count(), 1.0f);
    mat.lattice.assign(grid.voxel_count(), 0.0f);
  }
  int node(int a, int b, int c) const { return (c * (grid.ny + 1) + b) * (grid.nx + 1) + a; }
  void stretch_x(double strain) {   // u_x = strain x
    for (int c = 0; c <= grid.nz; ++c)
      for (int b = 0; b <= grid.ny; ++b)
        for (int a = 0; a <= grid.nx; ++a) u[3 * static_cast<std::size_t>(node(a, b, c))] = strain * (grid.origin.x + a * grid.spacing);
  }
};

ll::FrameStrength strength() {
  ll::FrameStrength s;
  s.youngs_mpa = kE;
  s.poisson = kNu;
  s.level_mpa = kLevel;
  s.across_mpa = kAcross;
  s.safety = 1.5;
  s.light_width_mm = kW;
  return s;
}

ll::FrameCheck run(const ll::Bars& bars, Field& f, const std::vector<ll::FrameVoxelSolve::Load>& loads, ll::FrameModel* model = nullptr) {
  const ll::FrameModel m = ll::build_frame(bars, nullptr);
  if (model) *model = m;
  ll::FrameVoxelSolve vs;
  vs.grid = &f.grid;
  vs.displacement = &f.u;
  vs.material = &f.mat;
  vs.loads = loads;
  return ll::check_frame(m, vs, strength());
}

double area() { return M_PI * 0.25 * kW * kW; }
double inertia() { return M_PI * std::pow(0.5 * kW, 4) / 4.0; }

void test_pulled_strut() {
  // §1: a 10 mm strut along x between two solid blocks, the field stretching x by 0.1 %.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {10, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  Field f({-3.0, -3.0, -3.0}, 32, 12, 12);
  const double eps = 1e-3;
  f.stretch_x(eps);
  const ll::FrameCheck c = run(bars, f, {});
  CHECK(c.solved && c.judged == 1, "the pulled strut is solved and judged");
  const double F = kE * area() * eps;   // the force its ends' pull gives
  const double stress = kLevel / c.struts[0].stress_margin;
  std::printf("§1 pulled: stress %.5f MPa, F / A %.5f MPa (%s)\n", stress, F / area(), c.struts[0].by.c_str());
  CHECK(std::fabs(stress - F / area()) <= 0.02 * F / area(), "a pulled strut's stress is F / A within 2 %");
  CHECK(c.struts[0].by == "tension", "it is limited in tension");
  CHECK(std::isinf(c.struts[0].buckling_margin), "no buckling in tension");
  CHECK(c.struts[0].n_min == 0.0 && !c.struts[0].bending_led && !c.struts[0].loaded,
        "E3a: a pulled strut has no compression, is axial-led and carries no load");
}

void test_cantilever() {
  // §2: a 6 mm strut held in the solid at x = 0, free at x = 6; a load of P down at the grid node at its tip, on
  // voxels that are all lattice there (the lattice's share is 1, so all of P goes on the frame).
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {6, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Loose));
  Field f({-3.0, -3.0, -3.0}, 24, 12, 12);
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i) {
        const double x = f.grid.origin.x + (i + 0.5) * f.grid.spacing;
        if (x > 1.0) {   // beyond the root's block: lattice only
          f.mat.solid[f.grid.index(i, j, k)] = 0.0f;
          f.mat.lattice[f.grid.index(i, j, k)] = 0.2f;
        }
      }
  const double P = 0.5;
  const int tip = f.node(18, 6, 6);   // (6, 0, 0)
  const ll::FrameCheck c = run(bars, f, {{tip, 2, -P}});
  CHECK(c.solved && c.judged == 1, "the cantilever is solved and judged");
  CHECK(std::fabs(c.load_on_frame_n - P) < 1e-12 && c.load_unheld_n == 0.0, "all of the tip load is on the frame");
  const double expect = P * 6.0 * (0.5 * kW) / inertia();
  const double stress = kLevel / c.struts[0].stress_margin;
  std::printf("§2 cantilever: root stress %.5f MPa, beam theory %.5f MPa\n", stress, expect);
  CHECK(std::fabs(stress - expect) <= 0.05 * expect, "a cantilever's root stress is P L r / I within 5 %");
  CHECK(c.struts[0].bending_led && c.struts[0].loaded, "E3a: the cantilever is bending-led and carries the load");
  CHECK(c.node_loaded.size() == 2 && c.node_loaded[0] + c.node_loaded[1] == 1, "E3a: one node carries the load");
}

void test_buckling() {
  // §3: a slender 20 mm strut between two solid blocks, the field shortening x by 0.01 %.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {20, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  Field f({-3.0, -3.0, -3.0}, 52, 12, 12);
  const double eps = -1e-4;
  f.stretch_x(eps);
  const ll::FrameCheck c = run(bars, f, {});
  CHECK(c.solved && c.judged == 1, "the compressed strut is solved and judged");
  const double N = kE * area() * -eps;
  const double expect = M_PI * M_PI * kE * inertia() / (20.0 * 20.0) / N;
  std::printf("§3 buckling: margin %.5f, pinned Euler %.5f (%s)\n", c.struts[0].buckling_margin, expect, c.struts[0].by.c_str());
  CHECK(std::fabs(c.struts[0].buckling_margin - expect) <= 0.02 * expect, "the buckling margin is the pinned Euler load's within 2 %");
  CHECK(c.struts[0].by == "buckling", "a slender strut in compression is limited by buckling");
  CHECK(std::fabs(-c.struts[0].n_min - N) <= 0.02 * N, "E3a: n_min is the strut's compressive force within 2 %");
}

void test_t_join() {
  // §4: A-B between two solid blocks; C-D standing on AB's middle (D is a loose end lying on AB).
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {10, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  bars.bars.push_back(bar({5, 0, 5}, {5, 0, 0}, ll::Bar::End::Loose, ll::Bar::End::Loose));
  Field f({-3.0, -3.0, -3.0}, 32, 12, 20);
  for (std::size_t e = 0; e < f.mat.solid.size(); ++e) {
    f.mat.solid[e] = 0.0f;
    f.mat.lattice[e] = 0.2f;
  }
  ll::FrameModel m;
  const int top = f.node(16, 6, 16);   // (5, 0, 5)
  const ll::FrameCheck c = run(bars, f, {{top, 2, -0.2}}, &m);
  CHECK(m.t_joins == 1 && m.pieces.size() == 3, "the loose end on AB's middle splits AB: three pieces");
  CHECK(m.nodes.size() == 4, "four nodes: A, B, C and the join");
  CHECK(c.solved && c.struts.size() == 3 && c.judged == 3, "three struts, all judged (the join is a joint)");
  CHECK(c.frame_nodes_loaded == 1, "the load is on C");
}

void test_link_moves_as_one() {
  // §5: strut 1 from the solid to P; strut 2 from P' (1 mm above P) out to Q, held only by the link P-P'.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {5, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Loose));
  bars.bars.push_back(bar({5, 0, 1}, {9, 0, 1}, ll::Bar::End::Loose, ll::Bar::End::Loose));
  bars.bars.push_back(bar({5, 0, 0}, {5, 0, 1}, ll::Bar::End::Joined, ll::Bar::End::Joined, kW, true));
  Field f({-3.0, -3.0, -3.0}, 28, 12, 12);
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i)
        if (f.grid.origin.x + (i + 0.5) * f.grid.spacing > 1.0) {
          f.mat.solid[f.grid.index(i, j, k)] = 0.0f;
          f.mat.lattice[f.grid.index(i, j, k)] = 0.2f;
        }
  ll::FrameModel m;
  const ll::FrameCheck c = run(bars, f, {{f.node(24, 6, 8), 2, -0.1}}, &m);   // Q = (9, 0, 1)
  CHECK(c.solved, "the linked frame is solved");
  int p = -1, q = -1;
  for (std::size_t n = 0; n < m.nodes.size(); ++n) {
    if (std::fabs(m.nodes[n].x - 5) < 1e-9 && std::fabs(m.nodes[n].z) < 1e-9) p = static_cast<int>(n);
    if (std::fabs(m.nodes[n].x - 5) < 1e-9 && std::fabs(m.nodes[n].z - 1) < 1e-9) q = static_cast<int>(n);
  }
  CHECK(p >= 0 && q >= 0 && c.node_u.size() == m.nodes.size(), "both ends of the link are nodes");
  if (p >= 0 && q >= 0 && c.solved) {
    const Vec3 a = c.node_u[static_cast<std::size_t>(p)], b = c.node_u[static_cast<std::size_t>(q)];
    const double up = std::fabs(a.z), gap = std::fabs(a.z - b.z);
    std::printf("§5 link: P moves %.6g mm down, P' differs by %.3g mm along the link\n", up, gap);
    CHECK(up > 0.0 && gap <= 1e-3 * up, "the two ends of a link move as one along it");
  }
  CHECK(c.struts.size() == 2, "a link is no strut");
}

void test_load_on_open_lattice() {
  // §6: the strut of §1, and a load on lattice voxels 8 mm away from it, where no frame node is near.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {10, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  Field f({-3.0, -3.0, -3.0}, 32, 32, 12);
  for (std::size_t e = 0; e < f.mat.solid.size(); ++e) {
    f.mat.solid[e] = 0.0f;
    f.mat.lattice[e] = 0.2f;
  }
  const ll::FrameCheck c = run(bars, f, {{f.node(16, 22, 6), 2, -1.0}});   // (5, 8, 0)
  std::printf("§6 open lattice: unheld %.3f N of %.3f N\n", c.load_unheld_n, c.load_total_n);
  CHECK(std::fabs(c.load_unheld_n - 1.0) < 1e-12, "the load with no frame node near is unheld");
  CHECK(c.load_on_open_lattice, "and the check says load_on_open_lattice");
}

void test_face_partly_near() {
  // §7: a face of 11 loaded grid nodes along y at x = 6 (lattice voxels), the cantilever's tip near only one of them.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {6, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Loose));
  Field f({-3.0, -3.0, -3.0}, 24, 24, 12);
  for (int k = 0; k < f.grid.nz; ++k)
    for (int j = 0; j < f.grid.ny; ++j)
      for (int i = 0; i < f.grid.nx; ++i)
        if (f.grid.origin.x + (i + 0.5) * f.grid.spacing > 1.0) {
          f.mat.solid[f.grid.index(i, j, k)] = 0.0f;
          f.mat.lattice[f.grid.index(i, j, k)] = 0.2f;
        }
  std::vector<ll::FrameVoxelSolve::Load> loads;
  for (int b = 6; b <= 16; ++b) loads.push_back({f.node(18, b, 6), 2, -0.05});   // y from 0 to 5 mm
  const ll::FrameCheck c = run(bars, f, loads);
  std::printf("§7 face partly near: on the frame %.3f N of %.3f N, unheld %.3f, nodes loaded %zu\n", c.load_on_frame_n,
              c.load_total_n, c.load_unheld_n, c.frame_nodes_loaded);
  CHECK(c.solved && std::fabs(c.load_on_frame_n - 0.55) < 1e-9 && c.load_unheld_n == 0.0, "the whole lattice share is held");
  CHECK(!c.load_on_open_lattice && c.frame_nodes_loaded == 1, "held at the one strut end near the face, not failed");
}

void test_load_on_undriven_piece() {
  // §8: the strut of §1, and a loose strut (no end in the solid) 8 mm away with a load at its end.
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {10, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  bars.bars.push_back(bar({2, 8, 0}, {8, 8, 0}, ll::Bar::End::Loose, ll::Bar::End::Loose));
  Field f({-3.0, -3.0, -3.0}, 32, 32, 12);
  for (std::size_t e = 0; e < f.mat.solid.size(); ++e) {
    f.mat.solid[e] = 0.0f;
    f.mat.lattice[e] = 0.2f;
  }
  const ll::FrameCheck c = run(bars, f, {{f.node(16, 22, 6), 2, -1.0}});   // (5, 8, 0): its middle, 3 mm from its nodes
  const ll::FrameCheck d = run(bars, f, {{f.node(22, 22, 6), 2, -1.0}});   // (8, 8, 0): the loose strut's end
  std::printf("§8 undriven piece: loaded nodes undriven %zu (load at its end), %zu (load 3 mm from any node)\n",
              d.loaded_nodes_undriven, c.loaded_nodes_undriven);
  CHECK(d.loaded_nodes_undriven == 1 && d.undriven_pieces == 1, "a load at a node of a piece with no driven node is counted");
  CHECK(c.loaded_nodes_undriven == 0, "a load near no node of it is not");
}

void test_bed_floor() {
  // §9: a 10 mm strut along x, both ends solid, A on the bed floor; the field moves x by 1e-3 z (zero at z = 0).
  ll::Bars bars;
  bars.bars.push_back(bar({0, 0, 0}, {10, 0, 0}, ll::Bar::End::Solid, ll::Bar::End::Solid));
  Field f({-3.0, -3.0, -3.0}, 32, 12, 12);
  for (int c = 0; c <= f.grid.nz; ++c)
    for (int b = 0; b <= f.grid.ny; ++b)
      for (int a = 0; a <= f.grid.nx; ++a) f.u[3 * static_cast<std::size_t>(f.node(a, b, c))] = 1e-3 * (f.grid.origin.z + c * f.grid.spacing);
  ll::FrameModel m = ll::build_frame(bars, nullptr);
  m.floor.assign(m.nodes.size(), 0);
  int A = -1;
  for (std::size_t n = 0; n < m.nodes.size(); ++n)
    if (std::fabs(m.nodes[n].x) < 1e-9) A = static_cast<int>(n);
  if (A < 0) {
    CHECK(false, "the bed-floor node is found");
    return;
  }
  m.floor[static_cast<std::size_t>(A)] = 1;
  ll::FrameVoxelSolve vs;
  vs.grid = &f.grid;
  vs.displacement = &f.u;
  vs.material = &f.mat;
  ll::FrameSettings s0, s1, s2;
  s1.floor_shift_voxels = 4.0;   // 2 mm up
  s2.floor_free = true;
  const ll::FrameCheck c0 = ll::check_frame(m, vs, strength(), s0), c1 = ll::check_frame(m, vs, strength(), s1),
                       c2 = ll::check_frame(m, vs, strength(), s2);
  const double uA0 = c0.node_u[static_cast<std::size_t>(A)].x, uA1 = c1.node_u[static_cast<std::size_t>(A)].x;
  std::printf("§9 bed floor: A moves %.3g mm (read at the node), %.3g mm (read 2 mm up); floor free: %zu driven\n", uA0, uA1,
              c2.driven);
  CHECK(std::fabs(uA0) < 1e-9 && std::fabs(uA1 - 2e-3) < 1e-6, "a bed-floor node reads its drive frame_floor_shift_voxels up");
  CHECK(c0.driven == 2 && c2.driven == 1, "with frame_floor_free the bed-floor node is not driven");
  CHECK(c1.solved && c1.judged == 1, "the shifted strut is judged");
  if (c1.judged == 1) {
    const ll::FrameStrut& st = c1.struts[0];
    const int e = st.end_node[0] == A ? 0 : 1;
    CHECK(st.end_kind[0] == 'd' && st.end_kind[1] == 'd' && st.end_floor[e] && !st.end_floor[1 - e],
          "its ends: both driven, the floor one marked");
    CHECK(std::fabs(st.end_read[e].z - 2.0) < 1e-9 && std::fabs(st.end_read[1 - e].z) < 1e-9, "where each end read its drive");
    CHECK(st.axial_n < 0.0, "pushed by the floor node's drive: in compression");
  }
}

}  // namespace

int main() {
  test_pulled_strut();
  test_cantilever();
  test_buckling();
  test_t_join();
  test_link_moves_as_one();
  test_load_on_open_lattice();
  test_face_partly_near();
  test_load_on_undriven_piece();
  test_bed_floor();
  std::printf("organic_frame: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
