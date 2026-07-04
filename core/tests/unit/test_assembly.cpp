// Unit tests for global FEA assembly + Dirichlet BCs + nodal loads + solve
// (ROADMAP M2.2). No third-party test framework (ARCHITECTURE §4), so this uses
// the same self-contained CHECK harness as the other unit tests and exercises
// only the public API (topopt/fea.hpp, topopt/voxel.hpp).
//
// The central check is a hand-checkable 2x1x1 problem solved exactly: uniaxial
// tension held by three symmetry planes and driven by a consistent nodal load
// on the +x face. A trilinear hexahedron reproduces a uniform-strain field to
// machine precision (constant-strain patch test), so the closed-form elasticity
// solution IS the finite-element solution and every one of the 36 DOFs can be
// checked against a formula computed by hand.

#include "topopt/fea.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

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

// A dense solid grid of nx*ny*nz cubic voxels, edge `h`, origin at 0. Every
// voxel is Interior (solid) unless a test re-tags it.
VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

bool throws_invalid(const VoxelGrid& g, const std::vector<DirichletBC>& bcs,
                    const std::vector<NodalLoad>& loads) {
  try {
    topopt::fea_solve(g, 100.0, 0.25, bcs, loads);
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

}  // namespace

int main() {
  const double h = 1.0;
  VoxelGrid g = make_solid_grid(2, 1, 1, h);  // 2x1x1 voxels

  // --- Node numbering -------------------------------------------------------
  CHECK(topopt::fea_node_count(g) == 12, "2x1x1 grid has 12 corner nodes");
  // Node index round-trip against the documented formula.
  {
    bool ok = true;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int expected = (c * 2 + b) * 3 + a;
          if (topopt::fea_node_index(g, a, b, c) != expected) ok = false;
        }
    CHECK(ok, "fea_node_index matches (c*(ny+1)+b)*(nx+1)+a");
  }
  // Element node order for the -x voxel (0,0,0), Hex8 convention.
  {
    std::array<int, 8> en = topopt::fea_element_nodes(g, 0, 0, 0);
    std::array<int, 8> want = {
        topopt::fea_node_index(g, 0, 0, 0), topopt::fea_node_index(g, 1, 0, 0),
        topopt::fea_node_index(g, 1, 1, 0), topopt::fea_node_index(g, 0, 1, 0),
        topopt::fea_node_index(g, 0, 0, 1), topopt::fea_node_index(g, 1, 0, 1),
        topopt::fea_node_index(g, 1, 1, 1), topopt::fea_node_index(g, 0, 1, 1)};
    bool ok = true;
    for (int i = 0; i < 8; ++i)
      if (en[i] != want[i]) ok = false;
    CHECK(ok, "fea_element_nodes(0,0,0) uses bottom-CCW-then-top-CCW order");
  }

  // --- Tagged-voxel -> node bridge ------------------------------------------
  // Tag the +x voxel (1,0,0) as Load; its distinct corner nodes are the eight
  // it owns, sorted. This is how M1.6 face tags drive "loads on tagged voxels".
  g.set_tag(1, 0, 0, VoxelTag::Load);
  std::vector<int> load_nodes = topopt::fea_tagged_nodes(g, VoxelTag::Load);
  {
    std::vector<int> want;
    std::array<int, 8> en = topopt::fea_element_nodes(g, 1, 0, 0);
    for (int n : en) want.push_back(n);
    std::sort(want.begin(), want.end());
    CHECK(load_nodes == want, "fea_tagged_nodes(Load) = tip voxel corners");
    CHECK(topopt::fea_tagged_nodes(g, VoxelTag::Fixture).empty(),
          "no Fixture voxels tagged yet");
  }
  // The four +x-face nodes (a == nx) that a tip traction actually loads must be
  // a subset of the tagged voxel's nodes.
  std::vector<int> tip_nodes;
  for (int c = 0; c <= 1; ++c)
    for (int b = 0; b <= 1; ++b)
      tip_nodes.push_back(topopt::fea_node_index(g, 2, b, c));
  {
    bool all_tagged = true;
    for (int n : tip_nodes)
      if (std::find(load_nodes.begin(), load_nodes.end(), n) ==
          load_nodes.end())
        all_tagged = false;
    CHECK(all_tagged, "+x face nodes belong to the Load-tagged voxel");
  }

  // --- Exact uniaxial-tension patch test ------------------------------------
  // E, nu, cross-section A = (ny*h)*(nz*h) = 1. Total axial force F on the +x
  // face -> uniform stress sigma = F/A, strain eps = sigma/E. Symmetry planes
  // x=0 (u_x=0), y=0 (u_y=0), z=0 (u_z=0) carry zero transverse reaction, so
  // the field is exactly u_x = eps*x, u_y = -nu*eps*y, u_z = -nu*eps*z.
  const double E = 100.0;
  const double nu = 0.25;
  const double F = 1.0;                    // total tip force
  const double A = (g.ny * h) * (g.nz * h);
  const double eps = F / (A * E);          // = 0.01
  const double per_node = F / static_cast<double>(tip_nodes.size());

  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= 1; ++c)
    for (int b = 0; b <= 1; ++b)
      bcs.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});  // x=0: u_x=0
  for (int c = 0; c <= 1; ++c)
    for (int a = 0; a <= 2; ++a)
      bcs.push_back({topopt::fea_node_index(g, a, 0, c), 1, 0.0});  // y=0: u_y=0
  for (int b = 0; b <= 1; ++b)
    for (int a = 0; a <= 2; ++a)
      bcs.push_back({topopt::fea_node_index(g, a, b, 0), 2, 0.0});  // z=0: u_z=0

  std::vector<NodalLoad> loads;
  for (int n : tip_nodes) loads.push_back({n, 0, per_node});

  FeaSolution sol = topopt::fea_solve(g, E, nu, bcs, loads);
  CHECK(sol.u.size() == 36, "solution has 3 DOF per node");

  const double tol = 1e-9;  // direct solve residual is ~1e-14 here
  {
    int bad = 0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int n = topopt::fea_node_index(g, a, b, c);
          if (!near(sol.at(n, 0), eps * (a * h), tol)) ++bad;
          if (!near(sol.at(n, 1), -nu * eps * (b * h), tol)) ++bad;
          if (!near(sol.at(n, 2), -nu * eps * (c * h), tol)) ++bad;
        }
    CHECK(bad == 0, "every DOF matches the exact uniform-strain field");
  }
  // Named hand values: tip extension, mid extension, lateral contraction.
  CHECK(near(sol.at(topopt::fea_node_index(g, 2, 0, 0), 0), 0.02, tol),
        "tip axial displacement u_x = eps*2h = 0.02");
  CHECK(near(sol.at(topopt::fea_node_index(g, 1, 0, 0), 0), 0.01, tol),
        "mid-plane axial displacement u_x = eps*h = 0.01");
  CHECK(near(sol.at(topopt::fea_node_index(g, 2, 1, 1), 1), -0.0025, tol),
        "lateral contraction u_y = -nu*eps*h = -0.0025");
  CHECK(near(sol.at(topopt::fea_node_index(g, 0, 0, 0), 0), 0.0, tol),
        "fixed base node has zero axial displacement");

  // --- Linearity: doubling the load doubles the displacement ----------------
  {
    std::vector<NodalLoad> loads2 = loads;
    for (NodalLoad& l : loads2) l.value *= 2.0;
    FeaSolution sol2 = topopt::fea_solve(g, E, nu, bcs, loads2);
    int bad = 0;
    for (std::size_t d = 0; d < sol.u.size(); ++d)
      if (!near(sol2.u[d], 2.0 * sol.u[d], tol)) ++bad;
    CHECK(bad == 0, "2x load gives 2x displacement (linear elasticity)");
  }

  // --- Prescribed non-zero displacement reproduces the same field -----------
  // Replace the tip load with a prescribed tip extension equal to the exact
  // solution above; the interior field must come out identical.
  {
    std::vector<DirichletBC> bcs_d = bcs;
    for (int n : tip_nodes) bcs_d.push_back({n, 0, eps * (2.0 * h)});  // 0.02
    FeaSolution sold = topopt::fea_solve(g, E, nu, bcs_d, {});
    int bad = 0;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        for (int a = 0; a <= 2; ++a) {
          int n = topopt::fea_node_index(g, a, b, c);
          if (!near(sold.at(n, 0), eps * (a * h), tol)) ++bad;
          if (!near(sold.at(n, 1), -nu * eps * (b * h), tol)) ++bad;
          if (!near(sold.at(n, 2), -nu * eps * (c * h), tol)) ++bad;
        }
    CHECK(bad == 0, "prescribed tip extension yields the same uniform field");
  }

  // --- Insufficient constraints: singular system must be rejected -----------
  {
    // A load with no BCs at all: rigid-body motion is unconstrained.
    CHECK(throws_invalid(g, {}, loads), "unconstrained system throws");
    // Only x=0 plane pinned in x: y/z translation + rotations remain free.
    std::vector<DirichletBC> weak;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 1; ++b)
        weak.push_back({topopt::fea_node_index(g, 0, b, c), 0, 0.0});
    CHECK(throws_invalid(g, weak, loads),
          "partially constrained system throws");
  }

  // --- Argument validation --------------------------------------------------
  {
    std::vector<DirichletBC> bad_bc = bcs;
    bad_bc.push_back({12, 0, 0.0});  // node id == node_count
    CHECK(throws_invalid(g, bad_bc, loads), "out-of-range BC node throws");
    std::vector<DirichletBC> bad_bc2 = bcs;
    bad_bc2.push_back({0, 3, 0.0});  // component 3 invalid
    CHECK(throws_invalid(g, bad_bc2, loads), "out-of-range BC component throws");
    std::vector<NodalLoad> bad_load = loads;
    bad_load.push_back({-1, 0, 1.0});
    CHECK(throws_invalid(g, bcs, bad_load), "out-of-range load node throws");
  }

  if (g_failures == 0) {
    std::printf("fea assembly: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "fea assembly: %d/%d checks FAILED\n", g_failures,
               g_checks);
  return 1;
}
