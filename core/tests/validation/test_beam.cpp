// V1 validation gate (ROADMAP M2.4 / ARCHITECTURE §7 V1): cantilever and
// simply-supported beams under point and distributed transverse loads, compared
// against the Euler-Bernoulli analytical deflection to <= 2% error, with
// convergence demonstrated across three mesh resolutions. Also exercises the
// von Mises stress field output (fea_von_mises_field).
//
// No third-party test framework (ARCHITECTURE §4); same self-contained CHECK
// harness as the other tests, public API only. Eigen-gated (uses fea_solve_cg).
//
// Why Euler-Bernoulli agreement is achievable with a fully-integrated Hex8:
//   * The elements shear-lock in bending, so a coarse mesh is too STIFF; h-
//     refinement releases the locking and the deflection converges upward toward
//     the true 3D elasticity answer. The three resolutions show this convergence.
//   * Euler-Bernoulli neglects transverse shear, so it only matches the 3D answer
//     for a slender beam. The shear correction scales as (H/L)^2 and is larger for
//     the simply-supported cases; L/H = 20 keeps it well under the 2% budget for
//     every case here. (At L/H = 12 the S-S point-load case converges to +2.6%,
//     i.e. Euler-Bernoulli itself is out of tolerance — the FEA is not at fault.)
//   * Linear-elastic relative error depends only on the dimensionless shape
//     (L/H, B/H, nu) and the element-through-depth count m, not on absolute size,
//     E, or load magnitude. So scaling the integer grid by m at fixed spacing IS
//     mesh refinement of one fixed physical beam; m = 4, 8, 12 are the meshes.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <functional>
#include <vector>

using topopt::CgInfo;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// Material and solver settings shared by every beam case. The CG tolerance is
// tight enough that the discretization error (not the solver) sets the result,
// so the errors below are deterministic across platforms; the iteration cap is
// ~5x the observed count so CI never spuriously hits it.
constexpr double kE = 1000.0;
constexpr double kNu = 0.3;
constexpr double kCgTol = 1e-10;
constexpr int kCgCap = 20000;

// Slenderness and the three through-depth mesh resolutions.
constexpr int kLoverH = 20;
constexpr int kM[3] = {4, 8, 12};

// Gate tolerance (ARCHITECTURE §7 V1): 2% of the Euler-Bernoulli value.
constexpr double kGate = 0.02;

VoxelGrid solid_beam(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

// Mean vertical (u_z) deflection over the corner-node plane at x-index ia.
double mean_uz_plane(const VoxelGrid& g, const FeaSolution& s, int ia) {
  double sum = 0.0;
  int cnt = 0;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      sum += s.at(topopt::fea_node_index(g, ia, b, c), 2);
      ++cnt;
    }
  return sum / cnt;
}

// Cantilever: clamp the whole x==0 face (all 3 DOFs), removing every rigid mode.
std::vector<DirichletBC> cantilever_bcs(const VoxelGrid& g) {
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = topopt::fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return bcs;
}

// Simply-supported: vertical (u_z) supports along the bottom edge at each end,
// plus a minimal in-plane pin/roller to remove the remaining rigid modes without
// over-constraining the Poisson lateral contraction.
std::vector<DirichletBC> simply_supported_bcs(const VoxelGrid& g) {
  std::vector<DirichletBC> bcs;
  for (int b = 0; b <= g.ny; ++b)
    bcs.push_back({topopt::fea_node_index(g, 0, b, 0), 2, 0.0});  // left support
  for (int b = 0; b <= g.ny; ++b)
    bcs.push_back({topopt::fea_node_index(g, g.nx, b, 0), 2, 0.0});  // right
  bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 0, 0.0});     // pin u_x
  bcs.push_back({topopt::fea_node_index(g, 0, 0, 0), 1, 0.0});     // pin u_y
  bcs.push_back({topopt::fea_node_index(g, g.nx, 0, 0), 1, 0.0});  // roller u_y
  return bcs;
}

// Transverse (-z) point load: total `total` spread over the free-end face nodes
// (x==nx) for the cantilever, or the midspan plane (x==nx/2) for S-S.
std::vector<NodalLoad> face_load(const VoxelGrid& g, int ia, double total) {
  std::vector<int> nodes;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      nodes.push_back(topopt::fea_node_index(g, ia, b, c));
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(nodes.size());
  for (int n : nodes) loads.push_back({n, 2, per});
  return loads;
}

// Uniformly distributed transverse (-z) load: total `total` spread over every
// node, giving a uniform load per unit length along the beam axis.
std::vector<NodalLoad> distributed_load(const VoxelGrid& g, double total) {
  const int N = topopt::fea_node_count(g);
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(N);
  for (int n = 0; n < N; ++n) loads.push_back({n, 2, per});
  return loads;
}

// One beam case: builds the grid for through-depth count m, solves, and returns
// the relative error (d_fea - d_eb)/d_eb at the measurement plane.
//   bcs(g)            -> boundary conditions
//   loads(g)          -> nodal loads (unit total, -z)
//   eb(L,E,I)         -> Euler-Bernoulli deflection magnitude (signed, negative)
//   measure_plane(g)  -> x-index of the deflection measurement plane
double beam_error(int m, const std::function<std::vector<DirichletBC>(const VoxelGrid&)>& bcs,
                  const std::function<std::vector<NodalLoad>(const VoxelGrid&)>& loads,
                  const std::function<double(double, double, double)>& eb,
                  const std::function<int(const VoxelGrid&)>& measure_plane) {
  const int nz = m, ny = m, nx = kLoverH * m;
  VoxelGrid g = solid_beam(nx, ny, nz);
  const double L = nx, H = nz, B = ny;
  const double I = B * H * H * H / 12.0;

  CgInfo info;
  FeaSolution s = topopt::fea_solve_cg(g, kE, kNu, bcs(g), loads(g), kCgTol,
                                       kCgCap, &info);
  CHECK(info.converged, "beam: CG converged");

  const double d_fea = mean_uz_plane(g, s, measure_plane(g));
  const double d_eb = eb(L, kE, I);
  return (d_fea - d_eb) / d_eb;
}

// Assert the V1 gate for one beam case across the three resolutions.
void check_case(const char* name,
                const std::function<std::vector<DirichletBC>(const VoxelGrid&)>& bcs,
                const std::function<std::vector<NodalLoad>(const VoxelGrid&)>& loads,
                const std::function<double(double, double, double)>& eb,
                const std::function<int(const VoxelGrid&)>& measure_plane) {
  double e[3];
  for (int r = 0; r < 3; ++r)
    e[r] = beam_error(kM[r], bcs, loads, eb, measure_plane);

  std::printf("%-26s m=%2d: %+.3f%%   m=%2d: %+.3f%%   m=%2d: %+.3f%%\n", name,
              kM[0], 100 * e[0], kM[1], 100 * e[1], kM[2], 100 * e[2]);

  // Gate: the two finer meshes are within 2% of Euler-Bernoulli.
  CHECK(std::fabs(e[2]) <= kGate, "finest mesh within 2% of Euler-Bernoulli");
  CHECK(std::fabs(e[1]) <= kGate, "second mesh within 2% of Euler-Bernoulli");
  // Refinement reduces the error (coarsest mesh is the worst).
  CHECK(std::fabs(e[0]) > std::fabs(e[2]), "refinement reduces the error");
  // Convergence: the change between successive meshes shrinks (settling toward
  // a limit), which is sign-robust for the S-S cases whose error crosses zero.
  CHECK(std::fabs(e[2] - e[1]) < std::fabs(e[1] - e[0]),
        "successive-mesh change shrinks (convergence)");
}

}  // namespace

int main() {
  std::printf("V1 beam validation (relative error vs Euler-Bernoulli):\n");

  // Cantilever, tip point load: delta = P L^3 / (3 E I).
  check_case(
      "cantilever point", cantilever_bcs,
      [](const VoxelGrid& g) { return face_load(g, g.nx, -1.0); },
      [](double L, double E, double I) { return -1.0 * L * L * L / (3.0 * E * I); },
      [](const VoxelGrid& g) { return g.nx; });

  // Cantilever, uniformly distributed load: delta = W L^3 / (8 E I), W total.
  check_case(
      "cantilever distributed", cantilever_bcs,
      [](const VoxelGrid& g) { return distributed_load(g, -1.0); },
      [](double L, double E, double I) { return -1.0 * L * L * L / (8.0 * E * I); },
      [](const VoxelGrid& g) { return g.nx; });

  // Simply-supported, midspan point load: delta = P L^3 / (48 E I).
  check_case(
      "simply-supported point", simply_supported_bcs,
      [](const VoxelGrid& g) { return face_load(g, g.nx / 2, -1.0); },
      [](double L, double E, double I) { return -1.0 * L * L * L / (48.0 * E * I); },
      [](const VoxelGrid& g) { return g.nx / 2; });

  // Simply-supported, distributed load: delta = 5 W L^3 / (384 E I), W total.
  check_case(
      "simply-supported distributed", simply_supported_bcs,
      [](const VoxelGrid& g) { return distributed_load(g, -1.0); },
      [](double L, double E, double I) {
        return -5.0 * L * L * L / (384.0 * E * I);
      },
      [](const VoxelGrid& g) { return g.nx / 2; });

  // ==========================================================================
  // Von Mises stress field (fea_von_mises_field). Exact case: 2x1x1 uniaxial
  // tension held by three symmetry planes and a consistent +x tip load. The
  // uniform stress state is sigma_xx = F/A, all else zero, so von Mises = F/A on
  // every solid voxel. (Same field the M2.2 direct test verifies for u.)
  // ==========================================================================
  {
    const double E = 100.0, nu = 0.25, F = 1.0;
    VoxelGrid g = solid_beam(2, 1, 1);
    const double area = (g.ny * g.spacing) * (g.nz * g.spacing);  // = 1
    const double sigma_xx = F / area;  // = 1.0

    std::vector<DirichletBC> bcs;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        bcs.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});  // x=0
    for (int c = 0; c <= 1; ++c)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, 0, c), 1, 0.0});  // y=0
    for (int b = 0; b <= 1; ++b)
      for (int a = 0; a <= 2; ++a)
        bcs.push_back({topopt::fea_node_index(g, a, b, 0), 2, 0.0});  // z=0
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        loads.push_back({topopt::fea_node_index(g, 2, b, c), 0, F / 4.0});

    FeaSolution s = topopt::fea_solve(g, E, nu, bcs, loads);
    std::vector<double> vm = topopt::fea_von_mises_field(g, E, nu, s);

    CHECK(vm.size() == g.voxel_count(), "von Mises field has one value per voxel");
    int bad = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          if (std::fabs(vm[g.index(i, j, k)] - sigma_xx) > 1e-6) ++bad;
    CHECK(bad == 0, "uniaxial patch: von Mises == sigma_xx on every solid voxel");
  }

  // ==========================================================================
  // Von Mises field, beam sanity: on a cantilever the bending moment (hence the
  // axial stress that dominates von Mises) is largest at the clamped root, so
  // the peak von Mises voxel must lie in the root half of the span. Confirms the
  // field is physically scaled on a real solve, not just the exact patch.
  // ==========================================================================
  {
    VoxelGrid g = solid_beam(48, 4, 4);
    CgInfo info;
    FeaSolution s = topopt::fea_solve_cg(g, kE, kNu, cantilever_bcs(g),
                                         face_load(g, g.nx, -1.0), kCgTol,
                                         kCgCap, &info);
    std::vector<double> vm = topopt::fea_von_mises_field(g, kE, kNu, s);

    double peak = 0.0;
    int peak_i = -1;
    bool all_finite = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double v = vm[g.index(i, j, k)];
          if (!std::isfinite(v)) all_finite = false;
          if (v > peak) {
            peak = v;
            peak_i = i;
          }
        }
    CHECK(all_finite, "cantilever von Mises field is finite");
    CHECK(peak > 0.0, "cantilever von Mises field is nonzero");
    CHECK(peak_i >= 0 && peak_i < g.nx / 2,
          "cantilever peak von Mises lies in the clamped-root half");
  }

  if (g_failures == 0) {
    std::printf("beam validation: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "beam validation: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
