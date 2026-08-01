// Correctness guards for the MATRIX-FREE CUBIC LATTICE path (handoff
// 2026-08-01-multiscale-production-wiring) — the opt-in, LIBRARY-default-OFF
// route that puts the composite isotropic-or-cubic system of
// fea_solve_cg_lattice on the full matrix-free accelerator stack (multigrid,
// GenEO deflation, Krylov recycling), via the exact three-block decomposition
// Ke = C11*K_A + C12*K_B + C44*K_C proven in PR 252.
//
// The bars this file enforces:
//
//   1. DEFAULT OFF. fea_matfree_cubic_lattice_enabled() is false at startup and
//      the header tripwire constant holds — reference runs never see the route.
//
//   2. EXACTNESS OF THE APPLY (bar I4). The matrix-free composite apply equals
//      the per-element assembled operator (hex8_stiffness_cubic /
//      factor*hex8_stiffness accumulation) to <= 1e-12 relative on a mixed
//      void/iso/cubic fixture, and is BIT-IDENTICAL across 1/4/8 threads.
//
//   3. ALL-SCALAR BIT-IDENTITY. With an all-zero mask, the lattice apply is
//      fea_matfree_apply bit-for-bit and the lattice solve is
//      fea_solve_mgcg_matfree bit-for-bit — the cubic table being empty leaves
//      the scalar path untouched to the last bit.
//
//   4. SOLVE PARITY (bar I4). On a non-coarsenable grid (Jacobi fallback) the
//      matrix-free lattice solve agrees with the assembled fea_solve_cg_lattice
//      in iteration count within 1 and in field to <= 1e-6 relative; on a
//      coarsenable grid multigrid engages (used_multigrid) and the field still
//      matches the assembled solve.
//
//   5. THE ROUTE. Arming fea_set_matfree_cubic_lattice makes
//      fea_solve_cg_lattice return the matrix-free result bit-for-bit
//      (same code path); disarming restores the assembled path bit-for-bit.
//
//   6. THE GENEO MODULI FINGERPRINT INVALIDATES ON A TENSOR-ONLY CHANGE
//      (bar I5). Two designs sharing the SAME scalar-modulus field but
//      DIFFERENT cubic tensors: when the deflation ENGAGES, the second solve
//      must REFRESH the held coarse operator (geneo_action == 2), never
//      silently reuse it (action == 1). Against the pre-fix fingerprint (blind
//      to the cubic fields) this test FAILS — verified by reverting the
//      fingerprint hunk during development; see the handoff's negative-control
//      note.
//      Since handoff 2026-08-02-geneo-disarm a held basis must clear the
//      ENGAGEMENT GATE before it may deflate at all, and on this fixture the
//      gate DECLINES — correctly, the solve is cheaper finished plain. Both
//      branches are asserted: the closed gate keeps the solve plain and exact,
//      and with the gate opened through the harness-only probe surface the
//      fingerprint behaviour above is exercised unchanged. The gate decides
//      WHEN the coarse operator is used, never WHETHER it may be stale.
//
//   7. RECYCLING EXACTNESS ACROSS A TENSOR CHANGE. A carried recycle basis
//      applied to a tensor-changed system still converges to the same field as
//      a recycling-off solve (the SPD-additive form's unconditional exactness,
//      exercised — not assumed — on the cubic operator).

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <random>
#include <set>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"

#include "fea/geneo.hpp"  // harness-only probe surface: the engagement gate
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

constexpr double kNu = 0.3;
constexpr double kE = 3500.0;

// Mixed fixture: beam grid with a void pocket, graded isotropic material and a
// lattice band carrying real octet tensors (the PR 252 d2 fixture shape).
struct Fixture {
  VoxelGrid grid;
  std::vector<double> youngs;  // 0 on lattice voxels (analyze.cpp's contract)
  std::vector<char> mask;
  std::vector<double> c11, c12, c44;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

Fixture make_fixture(int nx, int ny, int nz, bool with_void) {
  Fixture f;
  VoxelGrid& g = f.grid;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.7;
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);

  const std::size_t nv = g.voxel_count();
  f.youngs.assign(nv, 0.0);
  f.mask.assign(nv, 0);
  f.c11.assign(nv, 0.0);
  f.c12.assign(nv, 0.0);
  f.c44.assign(nv, 0.0);

  const double vx = 0.83 * nx, vy = 0.5 * ny, vz = 0.5 * nz;
  const double rx = 0.10 * nx, ry = 0.28 * ny, rz = 0.28 * nz;
  const int lat_lo = nx / 3, lat_hi = 2 * nx / 3;

  std::mt19937 rng(20260801u);
  std::uniform_real_distribution<double> rho_d(0.20, 0.55);
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const std::size_t e = g.index(i, j, k);
        if (with_void) {
          const double dx = (i + 0.5 - vx) / rx, dy = (j + 0.5 - vy) / ry,
                       dz = (k + 0.5 - vz) / rz;
          if (dx * dx + dy * dy + dz * dz < 1.0) {
            g.tags[e] = VoxelTag::Empty;
            continue;
          }
        }
        if (i >= lat_lo && i < lat_hi) {
          f.mask[e] = 1;
          const CubicTensor T =
              lattice_cubic_tensor(LatticeTopology::Octet, rho_d(rng), kE);
          f.c11[e] = T.C11;
          f.c12[e] = T.C12;
          f.c44[e] = T.C44;
        } else {
          f.youngs[e] = kE * (0.4 + 0.6 * ((i + 2 * j + 3 * k) % 5) / 4.0);
        }
      }

  std::set<int> clamped, loaded;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j) {
      if (g.solid(0, j, k)) {
        const std::array<int, 8> en = fea_element_nodes(g, 0, j, k);
        for (int a : {0, 3, 4, 7}) clamped.insert(en[a]);
      }
      if (g.solid(nx - 1, j, k)) {
        const std::array<int, 8> en = fea_element_nodes(g, nx - 1, j, k);
        for (int a : {1, 2, 5, 6}) loaded.insert(en[a]);
      }
    }
  for (int n : clamped)
    for (int c = 0; c < 3; ++c) f.bcs.push_back({n, c, 0.0});
  for (int n : loaded)
    f.loads.push_back({n, 2, -10.0 / static_cast<double>(loaded.size())});
  return f;
}

// Assembled reference apply: per-element accumulation with the SAME element
// rule assemble_reduced_lattice scatters (public API only).
std::vector<double> assembled_apply_ref(const Fixture& f,
                                        const std::vector<double>& u) {
  const VoxelGrid& g = f.grid;
  const int ndof = 3 * fea_node_count(g);
  const Hex8Stiffness Kunit = hex8_stiffness(1.0, kNu, g.spacing);
  std::vector<double> y(static_cast<std::size_t>(ndof), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        if (!g.solid(i, j, k)) continue;
        const std::size_t e = g.index(i, j, k);
        const std::array<int, 8> en = fea_element_nodes(g, i, j, k);
        int edof[24];
        for (int a = 0; a < 8; ++a)
          for (int c = 0; c < 3; ++c) edof[3 * a + c] = 3 * en[a] + c;
        double ue[24];
        for (int r = 0; r < 24; ++r) ue[r] = u[static_cast<std::size_t>(edof[r])];
        if (f.mask[e]) {
          const Hex8Stiffness Kc =
              hex8_stiffness_cubic(f.c11[e], f.c12[e], f.c44[e], g.spacing);
          for (int r = 0; r < 24; ++r) {
            double s = 0.0;
            for (int c = 0; c < 24; ++c) s += Kc(r, c) * ue[c];
            y[static_cast<std::size_t>(edof[r])] += s;
          }
        } else {
          const double factor = f.youngs[e];
          for (int r = 0; r < 24; ++r) {
            double s = 0.0;
            for (int c = 0; c < 24; ++c) s += Kunit(r, c) * ue[c];
            y[static_cast<std::size_t>(edof[r])] += factor * s;
          }
        }
      }
  return y;
}

double rel_l2(const std::vector<double>& a, const std::vector<double>& b) {
  double num = 0, den = 0;
  for (std::size_t i = 0; i < a.size(); ++i) {
    const double d = a[i] - b[i];
    num += d * d;
    den += b[i] * b[i];
  }
  return den > 0 ? std::sqrt(num / den) : 0.0;
}

// High-contrast checkerboard with a CUBIC mid-band — the test_geneo stagnation
// fixture shape, composite. Odd n keeps the grid non-coarsenable so the
// matrix-free lattice solve goes straight to the Jacobi fallback (where GenEO
// and recycling live).
struct CubFixture {
  VoxelGrid grid;
  std::vector<double> youngs;
  std::vector<char> mask;
  std::vector<double> c11, c12, c44;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

CubFixture cubic_checkerboard(int n, int cs, double c44_scale) {
  CubFixture f;
  VoxelGrid& g = f.grid;
  g.nx = n;
  g.ny = n;
  g.nz = n;
  g.spacing = 1.0;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
  for (int c = 0; c <= n; ++c)
    for (int b = 0; b <= n; ++b) {
      const int nd = fea_node_index(g, 0, b, c);
      for (int comp = 0; comp < 3; ++comp) f.bcs.push_back({nd, comp, 0.0});
    }
  for (int b = 0; b <= n; ++b)
    for (int c = 0; c <= n; ++c)
      f.loads.push_back(
          {fea_node_index(g, n, b, c), 2, -100.0 / ((n + 1.0) * (n + 1.0))});
  std::vector<double> rho(g.voxel_count(), 1.0);
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i)
        if ((((i / cs) + (j / cs) + (k / cs)) & 1) != 0)
          rho[g.index(i, j, k)] = 1e-3;
  for (int b = 0; b < n; ++b)
    for (int c = 0; c < n; ++c) {
      rho[g.index(0, b, c)] = 1.0;
      rho[g.index(n - 1, b, c)] = 1.0;
    }
  const std::size_t nv = g.voxel_count();
  f.youngs.assign(nv, 0.0);
  f.mask.assign(nv, 0);
  f.c11.assign(nv, 0.0);
  f.c12.assign(nv, 0.0);
  f.c44.assign(nv, 0.0);
  const CubicTensor T = lattice_cubic_tensor(LatticeTopology::Octet, 0.4, kE);
  for (int k = 0; k < n; ++k)
    for (int j = 0; j < n; ++j)
      for (int i = 0; i < n; ++i) {
        const std::size_t e = g.index(i, j, k);
        const double penal = std::pow(std::max(1e-3, rho[e]), 3);
        if (i >= n / 3 && i < 2 * n / 3) {
          // Cubic band: the octet tensor scaled by the SAME rho^3 penalisation,
          // so the contrast structure (the stagnation disease) is preserved.
          // C44 additionally scaled by `c44_scale` — the tensor-only design
          // knob the fingerprint test turns while the scalar field stays put.
          f.mask[e] = 1;
          f.c11[e] = penal * T.C11;
          f.c12[e] = penal * T.C12;
          f.c44[e] = penal * T.C44 * c44_scale;
        } else {
          f.youngs[e] = penal * kE;
        }
      }
  return f;
}

struct Solve {
  std::vector<double> u;
  CgInfo info;
};

Solve solve_lat(const CubFixture& f) {
  Solve s;
  FeaSolution sol = fea_solve_cg_lattice_matfree(
      f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads, 1e-8,
      60000, &s.info);
  s.u = std::move(sol.u);
  return s;
}

}  // namespace

int main() {
  // --- 1. DEFAULT OFF ------------------------------------------------------
  CHECK(!fea_matfree_cubic_lattice_enabled(),
        "matrix-free cubic lattice route: library default is OFF");
  CHECK(kMatfreeCubicLatticeLibraryDefaultOff,
        "the header default-off tripwire constant holds");

  // --- 2. APPLY EXACTNESS + THREAD DETERMINISM (bar I4) --------------------
  {
    Fixture f = make_fixture(24, 12, 12, /*with_void=*/true);
    const int ndof = 3 * fea_node_count(f.grid);
    std::mt19937 rng(424242u);
    std::normal_distribution<double> nd(0.0, 1.0);
    double worst = 0.0;
    for (int trial = 0; trial < 5; ++trial) {
      std::vector<double> x(static_cast<std::size_t>(ndof));
      for (double& v : x) v = nd(rng);
      const std::vector<double> y_mf = fea_matfree_apply_lattice(
          f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, x);
      const std::vector<double> y_ref = assembled_apply_ref(f, x);
      double mx = 0, scale = 0;
      for (int d = 0; d < ndof; ++d) {
        mx = std::max(mx, std::fabs(y_mf[static_cast<std::size_t>(d)] -
                                    y_ref[static_cast<std::size_t>(d)]));
        scale = std::max(scale, std::fabs(y_ref[static_cast<std::size_t>(d)]));
      }
      worst = std::max(worst, mx / scale);
    }
    std::printf("apply vs assembled: worst rel diff %.3e\n", worst);
    CHECK(worst <= 1e-12, "matrix-free cubic apply == assembled to <= 1e-12");

    // Thread determinism: 1 vs 4 vs 8 bit-identical.
    std::vector<double> x(static_cast<std::size_t>(ndof));
    for (double& v : x) v = nd(rng);
    const int prev = fea_set_matfree_threads(1);
    const std::vector<double> y1 = fea_matfree_apply_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, x);
    bool det = true;
    for (int t : {4, 8}) {
      fea_set_matfree_threads(t);
      const std::vector<double> yt = fea_matfree_apply_lattice(
          f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, x);
      if (std::memcmp(y1.data(), yt.data(), sizeof(double) * y1.size()) != 0)
        det = false;
    }
    fea_set_matfree_threads(prev);
    CHECK(det, "cubic apply bit-identical across 1/4/8 threads");
  }

  // --- 3. ALL-SCALAR BIT-IDENTITY ------------------------------------------
  {
    Fixture f = make_fixture(20, 10, 10, /*with_void=*/true);
    // Rebuild as all-scalar: no mask, every solid voxel graded iso.
    std::fill(f.mask.begin(), f.mask.end(), 0);
    for (std::size_t e = 0; e < f.youngs.size(); ++e) {
      f.c11[e] = f.c12[e] = f.c44[e] = 0.0;
      if (f.grid.tags[e] != VoxelTag::Empty && f.youngs[e] == 0.0)
        f.youngs[e] = kE;
    }
    const int ndof = 3 * fea_node_count(f.grid);
    std::mt19937 rng(5u);
    std::normal_distribution<double> nd(0.0, 1.0);
    bool apply_bitid = true;
    for (int trial = 0; trial < 3; ++trial) {
      std::vector<double> x(static_cast<std::size_t>(ndof));
      for (double& v : x) v = nd(rng);
      const std::vector<double> ylat = fea_matfree_apply_lattice(
          f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, x);
      const std::vector<double> yg = fea_matfree_apply(f.grid, f.youngs, kNu, x);
      if (std::memcmp(ylat.data(), yg.data(), sizeof(double) * ylat.size()) != 0)
        apply_bitid = false;
    }
    CHECK(apply_bitid, "all-zero mask: lattice apply == fea_matfree_apply "
                       "bit-for-bit");

    CgInfo ia, ib;
    const FeaSolution sa = fea_solve_cg_lattice_matfree(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 60000, &ia);
    const FeaSolution sb = fea_solve_mgcg_matfree(
        f.grid, f.youngs, kNu, f.bcs, f.loads, 1e-8, 60000, &ib, nullptr);
    CHECK(ia.converged && ib.converged, "all-scalar solves converge");
    CHECK(std::memcmp(sa.u.data(), sb.u.data(),
                      sizeof(double) * sa.u.size()) == 0,
          "all-zero mask: lattice solve == fea_solve_mgcg_matfree bit-for-bit");
    CHECK(ia.iterations == ib.iterations,
          "all-zero mask: identical iteration count");
  }

  // --- 4a. SOLVE PARITY, JACOBI REGIME (bar I4: iterations within 1) -------
  // Blocks 4a and 5-7 use ODD grids as the routing device into the Jacobi /
  // GenEO / recycling regimes they exist to test. The parity pad (task:
  // multigrid-odd-axis-cliff) would now send those grids to multigrid, so it
  // is switched OFF here (and restored after block 7) to keep each block in
  // its intended regime with its assertions verbatim. The padded-odd behavior
  // itself is asserted in test_mgcg_matfree / test_coarsen_rule.
  fea_set_mg_parity_pad_mode(0);
  {
    Fixture f = make_fixture(23, 11, 11, /*with_void=*/true);  // odd: no MG
    CgInfo ia, im;
    const FeaSolution ua = fea_solve_cg_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-10, 200000, &ia);
    const FeaSolution um = fea_solve_cg_lattice_matfree(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-10, 200000, &im);
    std::printf("jacobi parity: assembled %d iters, matfree %d iters, "
                "field rel L2 %.3e\n",
                ia.iterations, im.iterations, rel_l2(um.u, ua.u));
    CHECK(ia.converged && im.converged, "both lattice solves converge");
    CHECK(!im.used_multigrid, "odd grid falls back to Jacobi as intended");
    CHECK(std::abs(ia.iterations - im.iterations) <= 1,
          "iteration count agrees within 1 (same algorithm, same operator)");
    CHECK(rel_l2(um.u, ua.u) <= 1e-6, "fields agree to <= 1e-6 relative");
  }

  // --- 4b. MULTIGRID ENGAGES ON THE CUBIC OPERATOR -------------------------
  {
    Fixture f = make_fixture(24, 12, 12, /*with_void=*/true);
    CgInfo ia, im;
    const FeaSolution ua = fea_solve_cg_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &ia);
    const FeaSolution um = fea_solve_cg_lattice_matfree(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &im);
    std::printf("mg engage: assembled %d Jacobi iters; matfree used_mg=%d "
                "levels=%d iters=%d; field rel L2 %.3e\n",
                ia.iterations, im.used_multigrid ? 1 : 0, im.mg_levels,
                im.iterations, rel_l2(um.u, ua.u));
    CHECK(im.converged, "matfree lattice MG solve converges");
    CHECK(im.used_multigrid, "the Galerkin hierarchy builds and carries the "
                             "composite operator");
    CHECK(rel_l2(um.u, ua.u) <= 1e-6,
          "MG-solved field matches the assembled solve to <= 1e-6");
  }

  // --- 5. THE ROUTE --------------------------------------------------------
  {
    Fixture f = make_fixture(23, 11, 11, /*with_void=*/true);
    CgInfo i0;
    const FeaSolution asm0 = fea_solve_cg_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &i0);
    const bool prev = fea_set_matfree_cubic_lattice(true);
    CHECK(!prev, "route was OFF before arming");
    CgInfo i1, i2;
    const FeaSolution routed = fea_solve_cg_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &i1);
    const FeaSolution direct = fea_solve_cg_lattice_matfree(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &i2);
    fea_set_matfree_cubic_lattice(false);
    CHECK(std::memcmp(routed.u.data(), direct.u.data(),
                      sizeof(double) * routed.u.size()) == 0 &&
              i1.iterations == i2.iterations,
          "armed fea_solve_cg_lattice IS the matrix-free path bit-for-bit");
    CgInfo i3;
    const FeaSolution asm1 = fea_solve_cg_lattice(
        f.grid, f.youngs, f.mask, f.c11, f.c12, f.c44, kNu, f.bcs, f.loads,
        1e-8, 200000, &i3);
    CHECK(std::memcmp(asm0.u.data(), asm1.u.data(),
                      sizeof(double) * asm0.u.size()) == 0 &&
              i0.iterations == i3.iterations,
          "disarmed fea_solve_cg_lattice is the assembled path bit-for-bit");
  }

  // --- 6. GENEO MODULI FINGERPRINT INVALIDATES ON TENSOR-ONLY CHANGE -------
  {
    // Design A and design B share the SAME scalar youngs field and the SAME
    // mask; ONLY the cubic tensors differ (C44 x1.5). n=33 (odd): straight to
    // the Jacobi fallback where GenEO lives.
    CubFixture A = cubic_checkerboard(33, 4, 1.0);
    CubFixture B = cubic_checkerboard(33, 4, 1.5);
    CHECK(std::memcmp(A.youngs.data(), B.youngs.data(),
                      sizeof(double) * A.youngs.size()) == 0,
          "fixture: the scalar-modulus fields are IDENTICAL");
    CHECK(std::memcmp(A.c44.data(), B.c44.data(),
                      sizeof(double) * A.c44.size()) != 0,
          "fixture: the cubic tensors DIFFER");

    fea_set_geneo_twolevel(true);
    fea_reset_geneo_basis();
    fea_reset_krylov_recycle_space();
    const Solve a1 = solve_lat(A);
    std::printf("geneo fp: A#1 %d iters action=%d Nt=%d burn=%d\n",
                a1.info.iterations, a1.info.geneo_action, a1.info.geneo_dim,
                a1.info.geneo_trigger_burn);
    CHECK(a1.info.converged, "A#1 converges");
    CHECK(a1.info.geneo_action == 3,
          "A#1 stagnates past the trigger and BUILDS the basis (action 3)");
    // CLOSED GATE (the shipped default). The held basis is offered to this
    // solve and the gate declines it — the solve is cheaper finished plain.
    const Solve a2_gated = solve_lat(A);
    std::printf("geneo fp: A#2 gated %d iters action=%d thr=%d\n",
                a2_gated.info.iterations, a2_gated.info.geneo_action,
                a2_gated.info.geneo_threshold);
    CHECK(a2_gated.info.geneo_action == 5,
          "A#2 under the shipped gate: a held basis that cannot pay is "
          "DECLINED (action 5), and the solve stays plain and exact");
    CHECK(a2_gated.info.geneo_threshold > 0 && a2_gated.info.geneo_dim > 0,
          "and the decision is REPORTED — the threshold it was graded on and "
          "the basis it declined to engage");

    // OPEN GATE (harness-only override). Everything below is the ORIGINAL bar:
    // the gate changes when the coarse operator is used, never whether it may
    // be stale, so the fingerprint must still invalidate on a tensor-only move.
    {
      fea_detail::GeneoProbeConfig cfg;
      cfg.engage_threshold = 0;
      fea_detail::geneo_set_probe_config(cfg);
    }
    const Solve a2 = solve_lat(A);
    CHECK(a2.info.geneo_action == 1,
          "A#2 (identical system) REUSES basis + coarse operator (action 1)");
    const Solve b1 = solve_lat(B);
    fea_detail::geneo_set_probe_config(fea_detail::GeneoProbeConfig{});
    std::printf("geneo fp: B#1 %d iters action=%d (2 = refresh — the "
                "fingerprint saw the tensor change)\n",
                b1.info.iterations, b1.info.geneo_action);
    CHECK(b1.info.geneo_action == 2,
          "TENSOR-ONLY change invalidates the moduli fingerprint: the coarse "
          "operator REFRESHES (action 2), never silently reuses (action 1)");
    CHECK(b1.info.converged, "B#1 converges deflated");
    // Exactness of the deflated tensor-changed solve.
    fea_set_geneo_twolevel(false);
    fea_reset_geneo_basis();
    const Solve b_plain = solve_lat(B);
    CHECK(rel_l2(b1.u, b_plain.u) <= 1e-6,
          "deflated solve of B matches the plain solve (exactness)");
  }

  // --- 7. RECYCLING ACROSS A TENSOR CHANGE STAYS EXACT ---------------------
  {
    CubFixture A = cubic_checkerboard(33, 4, 1.0);
    CubFixture B = cubic_checkerboard(33, 4, 1.5);
    fea_set_geneo_twolevel(false);
    fea_reset_geneo_basis();
    fea_set_krylov_recycling(true);
    fea_reset_krylov_recycle_space();
    const Solve ra = solve_lat(A);  // harvests a basis on A's operator
    const Solve rb = solve_lat(B);  // carried basis applied to B's operator
    fea_set_krylov_recycling(false);
    fea_reset_krylov_recycle_space();
    const Solve rb_off = solve_lat(B);
    std::printf("recycle across tensors: A %d iters (dim %d), B %d iters "
                "(dim %d), B-off %d iters, field rel L2 %.3e\n",
                ra.info.iterations, ra.info.recycle_dim, rb.info.iterations,
                rb.info.recycle_dim, rb_off.info.iterations,
                rel_l2(rb.u, rb_off.u));
    CHECK(ra.info.converged && rb.info.converged && rb_off.info.converged,
          "all three solves converge");
    CHECK(rb.info.recycle_dim > 0,
          "the carried basis actually preconditioned the tensor-changed solve");
    CHECK(rel_l2(rb.u, rb_off.u) <= 1e-6,
          "recycled solve of the tensor-changed system matches recycling-off "
          "(SPD-additive exactness on the cubic operator)");
  }
  fea_set_mg_parity_pad_mode(1);  // restore the production default

  std::printf("test_matfree_cubic: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
