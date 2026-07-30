// test_surface_stiffness_model.cpp — unit tests for the HARNESS surface
// stiffness numerics (surface-stiffness probe,
// 2026-07-31-surface-stiffness-probe;
// core/tests/harness/surface_stiffness_model.hpp).
//
// The model is harness-side (no production file consumes it); these tests pin
// the properties the probe's K1/K2/K3 measurements lean on:
//   1. INTEGRATOR PIN — integrate_hex8_general reproduces the PRODUCTION
//      element bit-for-bit for a cubic D (hex8_stiffness_cubic) and for an
//      isotropic D (hex8_stiffness), including the library's own octet rows —
//      every harness element is on production arithmetic.
//   2. ROD SMEAR — a single axis-aligned chord inside one voxel produces
//      exactly D[0][0] = E*A*len/V and nothing else; a 45-degree in-plane
//      chord produces the known engineering-shear-consistent rank-1 tensor
//      (the m m^T outer product); the smear is symmetric PSD.
//   3. CUBIC PROJECTION — Frobenius projection is exact on a cubic D
//      (idempotent) and produces the pattern means on a general D.
//   4. EMBEDDED BAR — an axial bar whose endpoints coincide with grip-plane
//      corner nodes adds exactly 1/2 * (EA/L) * delta^2 of strain energy under
//      a prescribed unit-axis stretch (the analytic pin-jointed bar), i.e. the
//      trilinear embedding is exact at nodes and K += W^T k_bar W is wired
//      correctly.
//   5. EMBEDDING — trilinear weights are a partition of unity and reproduce a
//      linear field exactly at interior points.
//   6. COARSE == PRODUCTION — CoarseModel.solve_energy with an isotropic D
//      matches the production fea_solve (direct sparse LDLT) strain energy on
//      the same grid/BCs to solver precision: the harness assembled path and
//      the production path measure the SAME stiffness.
//   7. RASTERIZER — deterministic (two sweeps byte-identical) and volume-sane
//      (capsule voxel volume within 5% of analytic at h = r/4).

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include "../harness/surface_stiffness_model.hpp"

using namespace topopt;
using namespace surfstiff;

namespace {
int g_fail = 0;
void check(bool ok, const char* msg) {
  std::printf("  [%s] %s\n", ok ? "PASS" : "FAIL", msg);
  if (!ok) ++g_fail;
}
}  // namespace

int main() {
  std::printf("== 1. integrator pin: general-D == production element ==\n");
  {
    bool cubic_ok = true;
    const double hs[3] = {0.5, 1.0, 2.31};
    const double rhos[4] = {0.06, 0.26, 0.55, 0.88};
    for (double h : hs)
      for (double rho : rhos) {
        const CubicTensor t =
            lattice_cubic_tensor(LatticeTopology::Octet, rho, 3500.0);
        const Hex8Stiffness ref = hex8_stiffness_cubic(t.C11, t.C12, t.C44, h);
        const Hex8Stiffness got =
            integrate_hex8_general(d6_cubic(t.C11, t.C12, t.C44), h);
        cubic_ok = cubic_ok &&
                   std::memcmp(ref.k.data(), got.k.data(),
                               sizeof(double) * ref.k.size()) == 0;
      }
    check(cubic_ok, "cubic D: bit-identical to hex8_stiffness_cubic "
                    "(octet rows x element sizes)");

    bool iso_ok = true;
    for (double h : hs) {
      const Hex8Stiffness ref = hex8_stiffness(3500.0, 0.33, h);
      const Hex8Stiffness got = integrate_hex8_general(d6_isotropic(3500.0, 0.33), h);
      iso_ok = iso_ok && std::memcmp(ref.k.data(), got.k.data(),
                                     sizeof(double) * ref.k.size()) == 0;
    }
    check(iso_ok, "isotropic D: bit-identical to hex8_stiffness");
  }

  std::printf("== 2. rod smear ==\n");
  {
    // One chord along +x, length 0.5, centred in the single 1 mm voxel.
    std::vector<D6> dD(1);
    std::vector<Capsule> ch = {{{0.25, 0.5, 0.5}, {0.75, 0.5, 0.5}, 0.1}};
    rod_smear_accumulate(ch, 1000.0, 0.33, {0, 0, 0}, 1.0, 1, 1, 1, dD);
    const double expect = 1000.0 * M_PI * 0.01 * 0.5;  // E*A*len / V(=1)
    bool ok = std::fabs(dD[0].m[0][0] - expect) <= 1e-9 * expect;
    for (int i = 0; i < 6; ++i)
      for (int j = 0; j < 6; ++j)
        if (i != 0 || j != 0) ok = ok && std::fabs(dD[0].m[i][j]) < 1e-12;
    check(ok, "x-aligned chord -> only D[xx][xx] = E*A*len/V");

    // 45-degree chord in the xy plane: m = [1/2, 1/2, 0, 1/2, 0, 0].
    std::vector<D6> d2(1);
    const double s = std::sqrt(0.5) * 0.5;  // half-length components
    std::vector<Capsule> c2 = {
        {{0.5 - s, 0.5 - s, 0.5}, {0.5 + s, 0.5 + s, 0.5}, 0.1}};
    rod_smear_accumulate(c2, 1000.0, 0.33, {0, 0, 0}, 1.0, 1, 1, 1, d2);
    const double len = 2.0 * s * std::sqrt(2.0);
    const double w = 1000.0 * M_PI * 0.01 * len;
    const double m[6] = {0.5, 0.5, 0.0, 0.5, 0.0, 0.0};
    bool ok45 = true;
    for (int i = 0; i < 6; ++i)
      for (int j = 0; j < 6; ++j)
        ok45 = ok45 && std::fabs(d2[0].m[i][j] - w * m[i] * m[j]) <= 1e-9 * w;
    check(ok45, "45-degree chord -> w * m m^T with m=[.5,.5,0,.5,0,0]");

    // PSD: eigenvalues of the smear are >= 0 (rank-1 by construction).
    Eigen::Matrix<double, 6, 6> M;
    for (int i = 0; i < 6; ++i)
      for (int j = 0; j < 6; ++j) M(i, j) = d2[0].m[i][j];
    const Eigen::SelfAdjointEigenSolver<Eigen::Matrix<double, 6, 6>> es(M);
    check(es.eigenvalues().minCoeff() >= -1e-9, "smear is symmetric PSD");
  }

  std::printf("== 3. cubic projection ==\n");
  {
    const D6 c = d6_cubic(100.0, 40.0, 30.0);
    const CubicFit f = project_cubic(c);
    check(std::fabs(f.C11 - 100.0) < 1e-12 && std::fabs(f.C12 - 40.0) < 1e-12 &&
              std::fabs(f.C44 - 30.0) < 1e-12,
          "projection is exact (idempotent) on a cubic D");
    D6 g{};
    g.m[0][0] = 30.0; g.m[1][1] = 60.0;  // in-plane membrane-like
    const CubicFit p = project_cubic(g);
    check(std::fabs(p.C11 - 30.0) < 1e-12 && std::fabs(p.C44) < 1e-12,
          "membrane D -> C11 = mean(diag) spreads in-plane onto ALL axes "
          "(the representability failure, quantified)");
  }

  std::printf("== 4. embedded axial bar ==\n");
  {
    CoarseModel m;
    m.h = 1.0;
    m.nx = 2; m.ny = 1; m.nz = 1;
    m.D.assign(2, d6_isotropic(1000.0, 0.3));
    CoarseModel::Grip fx, mv;
    fx.nodes = m.plane_nodes(0, 0.0);
    mv.nodes = m.plane_nodes(0, 2.0);
    mv.ux = 0.01;
    const double U0 = m.solve_energy(fx, mv);
    CoarseModel mb = m;
    mb.bars.push_back({{0, 0, 0}, {2.0, 0, 0}, 500.0});  // EA=500, L=2
    const double U1 = mb.solve_energy(fx, mv);
    // Bar ends sit ON the grip planes at corner nodes: stretch is exactly
    // delta -> dU = 1/2 * (EA/L) * delta^2.
    const double expect = 0.5 * (500.0 / 2.0) * 0.01 * 0.01;
    check(std::fabs((U1 - U0) - expect) <= 1e-12 + 1e-9 * expect,
          "bar between grip corner nodes adds exactly 1/2*(EA/L)*delta^2");
  }

  std::printf("== 5. trilinear embedding ==\n");
  {
    const Vec3 p{0.37, 0.81, 0.24};
    const EmbeddedEnd e = embed_point(p, {0, 0, 0}, 1.0, 2, 2, 2,
                                      &CoarseModel::node_id_static, 2, 2);
    double sw = 0.0, lx = 0.0;
    for (int i = 0; i < 8; ++i) sw += e.w[i];
    check(std::fabs(sw - 1.0) < 1e-12, "weights are a partition of unity");
    // Reproduce the linear field f = x at node positions (grid h=1, node ids
    // decode as a + 3*b + 9*c for gnx=gny=2).
    for (int i = 0; i < 8; ++i) {
      const int a = e.node[i] % 3;
      lx += e.w[i] * a;
    }
    check(std::fabs(lx - 0.37) < 1e-12, "linear field reproduced exactly");
  }

  std::printf("== 6. coarse model == production fea_solve ==\n");
  {
    // Same 4x3x2 all-solid grid, same rigid-grip BCs, isotropic material:
    // harness assembled energy vs production direct-solver energy.
    VoxelGrid grid;
    grid.nx = 4; grid.ny = 3; grid.nz = 2;
    grid.spacing = 1.0;
    grid.origin = {0, 0, 0};
    grid.tags.assign(24, VoxelTag::Interior);
    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= grid.nz; ++c)
      for (int b = 0; b <= grid.ny; ++b) {
        const int n0 = fea_node_index(grid, 0, b, c);
        const int n1 = fea_node_index(grid, grid.nx, b, c);
        for (int comp = 0; comp < 3; ++comp) {
          bcs.push_back({n0, comp, 0.0});
          bcs.push_back({n1, comp, comp == 2 ? 0.01 : 0.0});  // bend-like
        }
      }
    const FeaSolution sol = fea_solve(grid, 3500.0, 0.33, bcs, {});
    const Hex8Stiffness Kunit = hex8_stiffness(1.0, 0.33, 1.0);
    double Uprod = 0.0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          const std::array<int, 8> nn = fea_element_nodes(grid, i, j, k);
          double ue[24];
          for (int a = 0; a < 8; ++a)
            for (int c = 0; c < 3; ++c)
              ue[3 * a + c] = sol.u[(std::size_t)(3 * nn[(std::size_t)a] + c)];
          double acc = 0.0;
          for (int r = 0; r < 24; ++r) {
            double kr = 0.0;
            for (int c = 0; c < 24; ++c) kr += Kunit.k[(std::size_t)r * 24 + c] * ue[c];
            acc += ue[r] * kr;
          }
          Uprod += 0.5 * 3500.0 * acc;
        }
    CoarseModel m;
    m.h = 1.0;
    m.nx = 4; m.ny = 3; m.nz = 2;
    m.D.assign(24, d6_isotropic(3500.0, 0.33));
    CoarseModel::Grip fx, mv;
    fx.nodes = m.plane_nodes(0, 0.0);
    mv.nodes = m.plane_nodes(0, 4.0);
    mv.uz = 0.01;
    const double Uharn = m.solve_energy(fx, mv);
    check(std::fabs(Uharn - Uprod) <= 1e-10 * std::fabs(Uprod),
          "harness assembled energy == production fea_solve energy (1e-10)");
  }

  std::printf("== 7. rasterizer ==\n");
  {
    std::vector<Capsule> caps = {{{2, 2, 2}, {8, 2, 2}, 0.8}};
    const double h = 0.2;
    const int n = 50;
    std::vector<char> s1((std::size_t)n * n * n, 0), s2 = s1;
    rasterize_solid(caps, {0, 0, 0}, h, n, n, n, s1);
    rasterize_solid(caps, {0, 0, 0}, h, n, n, n, s2);
    check(s1 == s2, "two sweeps identical (deterministic)");
    long long cnt = 0;
    for (char c : s1) cnt += c;
    const double vol = (double)cnt * h * h * h;
    const double analytic = M_PI * 0.8 * 0.8 * 6.0 + 4.0 / 3.0 * M_PI * 0.512;
    check(std::fabs(vol / analytic - 1.0) < 0.05,
          "capsule voxel volume within 5% of analytic at h = r/4");
  }

  std::printf("%s (%d failures)\n", g_fail == 0 ? "ALL PASS" : "FAILURES",
              g_fail);
  return g_fail == 0 ? 0 : 1;
}
