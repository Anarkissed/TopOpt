// Unit tests for the SIMP density interpolation, compliance and sensitivities
// (ROADMAP M3.2: "Density field + SIMP-penalized stiffness (p=3), compliance +
// sensitivities. Finite-difference check of sensitivities on a tiny grid").
// No third-party test framework (ARCHITECTURE §4); the same self-contained
// CHECK harness as the other unit tests, public API only (topopt/simp.hpp,
// topopt/fea.hpp, topopt/voxel.hpp).
//
// Strategy:
//  * The interpolation law E(rho)=rho^p*E0 and its clamp/validation are checked
//    directly against closed form.
//  * Correctness of the penalized compliance is anchored two independent ways:
//    (a) a uniform density field must reproduce the uniform-material solve
//    fea_solve_cg(E=rho^p*E0) DOF-for-DOF, and (b) the returned compliance must
//    equal f^T u computed straight from the loads and the solution.
//  * The M3.2 deliverable — the analytic sensitivity dc/drho_e — is verified by
//    a central finite-difference check on a tiny non-uniform grid: perturbing
//    each design density by +/-h and re-solving must match the analytic gradient.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::CgInfo;
using topopt::DensityFilter;
using topopt::DirichletBC;
using topopt::FeaSolution;
using topopt::NodalLoad;
using topopt::SimpCompliance;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
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

// Clamp the whole x==0 face (removes all six rigid-body modes -> K_ff SPD).
std::vector<DirichletBC> clamp_x0_face(const VoxelGrid& g) {
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

// Transverse -z load spread over the free (x==nx) end-face nodes.
std::vector<NodalLoad> tip_load_z(const VoxelGrid& g, double total) {
  std::vector<int> nodes;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b)
      nodes.push_back(topopt::fea_node_index(g, g.nx, b, c));
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(nodes.size());
  for (int n : nodes) loads.push_back({n, 2, per});
  return loads;
}

double dot_load_solution(const std::vector<NodalLoad>& loads,
                         const FeaSolution& sol) {
  double s = 0.0;
  for (const NodalLoad& l : loads) s += l.value * sol.at(l.node, l.component);
  return s;
}

}  // namespace

int main() {
  // ==========================================================================
  // 1. Interpolation law E(rho) = clamp(rho, rho_min, 1)^p * E0, and validation.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    CHECK(near(topopt::simp_youngs(p, 1.0), 2100.0, 1e-9),
          "simp_youngs: full density gives E0");
    CHECK(near(topopt::simp_youngs(p, 0.5), 0.125 * 2100.0, 1e-9),
          "simp_youngs: rho=0.5, p=3 gives 0.125*E0");
    CHECK(near(topopt::simp_youngs(p, 1e-3), 1e-9 * 2100.0, 1e-12),
          "simp_youngs: rho=rho_min gives rho_min^3 * E0");
    // Clamping: rho above 1 pins to E0, rho below rho_min pins to E(rho_min).
    CHECK(near(topopt::simp_youngs(p, 1.7), 2100.0, 1e-9),
          "simp_youngs: rho>1 clamps to E0");
    CHECK(near(topopt::simp_youngs(p, 0.0), 1e-9 * 2100.0, 1e-12),
          "simp_youngs: rho<rho_min clamps to E(rho_min)");
    // Monotone increasing in rho on [rho_min, 1].
    CHECK(topopt::simp_youngs(p, 0.4) < topopt::simp_youngs(p, 0.6),
          "simp_youngs: monotone increasing in density");

    auto throws_invalid = [](SimpParams q) {
      try {
        topopt::simp_youngs(q, 0.5);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpParams bad_e = p;
    bad_e.youngs_modulus = 0.0;
    CHECK(throws_invalid(bad_e), "simp_youngs: E0<=0 throws");
    SimpParams bad_p = p;
    bad_p.penalty = 0.0;
    CHECK(throws_invalid(bad_p), "simp_youngs: penalty<=0 throws");
    SimpParams bad_min = p;
    bad_min.density_min = 0.0;
    CHECK(throws_invalid(bad_min), "simp_youngs: density_min<=0 throws");
    SimpParams bad_min2 = p;
    bad_min2.density_min = 1.5;
    CHECK(throws_invalid(bad_min2), "simp_youngs: density_min>1 throws");
  }

  // ==========================================================================
  // 2. Uniform initial density field: solids = value, Empty = 0.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(2, 2, 2, 1.0);
    g.set_tag(1, 1, 1, VoxelTag::Empty);  // punch one void
    std::vector<double> d = topopt::simp_uniform_density(g, 0.5);
    CHECK(d.size() == g.voxel_count(), "simp_uniform_density: size = voxel_count");
    int solids = 0, voids = 0;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double v = d[g.index(i, j, k)];
          if (g.solid(i, j, k)) {
            if (near(v, 0.5, 0.0)) ++solids;
          } else {
            if (near(v, 0.0, 0.0)) ++voids;
          }
        }
    CHECK(solids == 7, "simp_uniform_density: every solid voxel = value");
    CHECK(voids == 1, "simp_uniform_density: every Empty voxel = 0");
  }

  // ==========================================================================
  // 3. Uniform density reproduces the uniform-material solve, and the returned
  //    compliance equals f^T u.  With every voxel at density rho the penalized
  //    modulus is uniform E = rho^p * E0, so simp_compliance must match
  //    fea_solve_cg(E) DOF-for-DOF and c must equal f^T u.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    const double rho = 0.6;
    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    std::vector<double> d = topopt::simp_uniform_density(g, rho);

    SimpCompliance r =
        topopt::simp_compliance(g, p, d, bcs, loads, 1e-12, 5000);
    CHECK(r.cg.converged, "uniform: penalized CG converged");

    const double E_uniform = std::pow(rho, p.penalty) * p.youngs_modulus;
    CgInfo info;
    FeaSolution ref =
        topopt::fea_solve_cg(g, E_uniform, p.poisson, bcs, loads, 1e-12, 5000, &info);

    double maxu = 0.0, maxdiff = 0.0;
    for (std::size_t k = 0; k < ref.u.size(); ++k) {
      maxu = std::max(maxu, std::fabs(ref.u[k]));
      maxdiff = std::max(maxdiff, std::fabs(ref.u[k] - r.solution.u[k]));
    }
    CHECK(maxu > 0.0, "uniform: reference field is nonzero");
    CHECK(maxdiff <= 1e-6 * maxu,
          "uniform: penalized solve matches the uniform-material solve");

    const double fTu = dot_load_solution(loads, r.solution);
    CHECK(near(r.compliance, fTu, 1e-6 * std::fabs(fTu)),
          "uniform: compliance equals f^T u");
    CHECK(r.compliance > 0.0, "uniform: compliance is positive");
    CHECK(r.dcompliance.size() == g.voxel_count(),
          "uniform: one sensitivity per voxel");
  }

  // ==========================================================================
  // 4. M3.2 GATE: finite-difference check of the analytic sensitivities on a
  //    tiny non-uniform grid.  For each tested design voxel, the analytic
  //    dc/drho_e must match the central difference (c(rho+h)-c(rho-h))/(2h) from
  //    two independent re-solves.  Densities are kept strictly inside
  //    (rho_min, 1) so the clamp is inactive and the derivative is smooth.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);

    // Deterministic non-uniform design in [0.4, 0.9].
    const std::size_t N = g.voxel_count();
    std::vector<double> d(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      d[e] = 0.4 + 0.5 * (static_cast<double>(e) / static_cast<double>(N - 1));

    const double tol = 1e-13;
    const int maxit = 8000;
    SimpCompliance base = topopt::simp_compliance(g, p, d, bcs, loads, tol, maxit);
    CHECK(base.cg.converged, "sensitivity: base penalized CG converged");

    // All design voxels under this load should have negative compliance
    // sensitivity (adding material stiffens the structure).
    bool all_negative = true;
    for (std::size_t e = 0; e < N; ++e)
      if (!(base.dcompliance[e] < 0.0)) all_negative = false;
    CHECK(all_negative, "sensitivity: dc/drho < 0 for every design voxel");

    const double h = 1e-4;
    // Cover corner, mid, and last voxels of the design domain.
    const std::size_t probes[] = {0, 3, 7, 11, N - 1};
    double worst_rel = 0.0;
    for (std::size_t e : probes) {
      std::vector<double> dp = d, dm = d;
      dp[e] += h;
      dm[e] -= h;
      const double cp =
          topopt::simp_compliance(g, p, dp, bcs, loads, tol, maxit).compliance;
      const double cm =
          topopt::simp_compliance(g, p, dm, bcs, loads, tol, maxit).compliance;
      const double fd = (cp - cm) / (2.0 * h);
      const double an = base.dcompliance[e];
      const double rel = std::fabs(fd - an) / std::max(std::fabs(an), 1e-30);
      worst_rel = std::max(worst_rel, rel);
      CHECK(rel < 1e-3,
            "sensitivity: analytic dc/drho matches central finite difference");
    }
    std::printf("SIMP sensitivity FD: worst relative error %.3e (tol 1e-3)\n",
                worst_rel);
  }

  // ==========================================================================
  // 5. Empty voxels carry zero sensitivity and are excluded from the design.
  //    A 2x2x1 grid with one Empty voxel: its dc must be exactly 0, while a
  //    loaded solid voxel keeps a nonzero (negative) sensitivity.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 1000.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    VoxelGrid g = make_solid_grid(2, 2, 1, 1.0);
    g.set_tag(1, 1, 0, VoxelTag::Empty);  // one void voxel
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    // -z load on the solid voxel (1,0,0)'s outer face nodes.
    std::vector<NodalLoad> loads;
    for (int c = 0; c <= 1; ++c)
      for (int b = 0; b <= 0; ++b)
        loads.push_back({topopt::fea_node_index(g, 2, b, c), 2, -0.5});

    std::vector<double> d = topopt::simp_uniform_density(g, 0.7);
    SimpCompliance r = topopt::simp_compliance(g, p, d, bcs, loads, 1e-12, 5000);
    CHECK(r.cg.converged, "empty: penalized CG converged");
    CHECK(near(r.dcompliance[g.index(1, 1, 0)], 0.0, 0.0),
          "empty: Empty voxel has exactly zero sensitivity");
    CHECK(r.dcompliance[g.index(1, 0, 0)] < 0.0,
          "empty: loaded solid voxel has a negative sensitivity");
  }

  // ==========================================================================
  // 6. Density filter (M3.3): partition-of-unity, finite support at `radius`,
  //    the adjoint (transpose) identity for the sensitivity chain rule, and
  //    exclusion of Empty voxels.
  // ==========================================================================
  {
    // 6a. Filtering a constant field returns the same constant (the weights
    //     sum to Hs, so sum_i H_ei x_i / Hs_e = c for x == c). This is the
    //     mesh-independence filter's basic consistency property.
    VoxelGrid g = make_solid_grid(5, 5, 1, 1.0);
    DensityFilter f = topopt::make_density_filter(g, 1.5);
    std::vector<double> c(g.voxel_count(), 0.7);
    std::vector<double> fc = f.filter_density(c);
    bool const_ok = true;
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (!near(fc[g.index(i, j, 0)], 0.7, 1e-12)) const_ok = false;
    CHECK(const_ok, "filter: constant field is preserved (partition of unity)");

    // 6b. Finite support: a unit spike at the centre spreads only to voxels
    //     strictly within `radius`. A face neighbour (dist 1 < 1.5) is nonzero,
    //     a diagonal (dist sqrt2 ~ 1.414 < 1.5) is nonzero, but a knight/edge
    //     voxel at dist 2 and a corner at dist 2*sqrt2 are outside the radius.
    std::vector<double> spike(g.voxel_count(), 0.0);
    spike[g.index(2, 2, 0)] = 1.0;
    std::vector<double> fs = f.filter_density(spike);
    CHECK(fs[g.index(2, 2, 0)] > 0.0, "filter: spike self is nonzero");
    CHECK(fs[g.index(3, 2, 0)] > 0.0, "filter: face neighbour (dist 1) nonzero");
    CHECK(fs[g.index(3, 3, 0)] > 0.0,
          "filter: diagonal neighbour (dist sqrt2) nonzero");
    CHECK(near(fs[g.index(4, 2, 0)], 0.0, 0.0),
          "filter: voxel at dist 2 is outside radius 1.5");
    CHECK(near(fs[g.index(0, 0, 0)], 0.0, 0.0),
          "filter: far corner is outside radius 1.5");

    // 6c. Adjoint identity <M x, s> == <x, M^T s>: filter_sensitivity must be
    //     the exact transpose of filter_density (this is what makes the chain
    //     rule d/dx = M^T d/dxPhys correct). Use two deterministic fields.
    std::vector<double> x(g.voxel_count(), 0.0), s(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      x[e] = 0.1 + 0.03 * static_cast<double>(e);
      s[e] = 1.0 - 0.02 * static_cast<double>(e);
    }
    std::vector<double> Mx = f.filter_density(x);
    std::vector<double> Mts = f.filter_sensitivity(s);
    double lhs = 0.0, rhs = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      lhs += Mx[e] * s[e];
      rhs += x[e] * Mts[e];
    }
    CHECK(near(lhs, rhs, 1e-9 * (std::fabs(lhs) + 1.0)),
          "filter: filter_sensitivity is the transpose of filter_density");

    // 6d. Empty voxels are not design variables: they map to 0 and are excluded
    //     from neighbours (a solid voxel next to a void has smaller Hs than an
    //     interior one, but still filters a constant to itself).
    VoxelGrid gh = make_solid_grid(3, 3, 1, 1.0);
    gh.set_tag(1, 1, 0, VoxelTag::Empty);
    DensityFilter fh = topopt::make_density_filter(gh, 1.5);
    std::vector<double> ch(gh.voxel_count(), 0.5);
    std::vector<double> fch = fh.filter_density(ch);
    CHECK(near(fch[gh.index(1, 1, 0)], 0.0, 0.0),
          "filter: Empty voxel filters to 0");
    CHECK(near(fch[gh.index(0, 0, 0)], 0.5, 1e-12),
          "filter: constant preserved on solid voxels beside a void");

    // 6e. Argument validation.
    bool threw = false;
    try {
      topopt::make_density_filter(g, 0.0);
    } catch (const std::invalid_argument&) {
      threw = true;
    }
    CHECK(threw, "filter: radius <= 0 throws");
  }

  // ==========================================================================
  // 7. Optimality-Criteria update (M3.3): the volume constraint is met on the
  //    filtered density, the move limit and box bounds are respected, the step
  //    responds monotonically to the sensitivity, and Empty voxels stay 0.
  // ==========================================================================
  {
    // 7a. Volume constraint: with a near-identity filter (radius 0.5 => each
    //     voxel only itself), a uniform design and uniform sensitivity, the
    //     updated *physical* volume must equal volfrac * n_design.
    VoxelGrid g = make_solid_grid(4, 4, 1, 1.0);
    DensityFilter idf = topopt::make_density_filter(g, 0.5);
    std::vector<double> x = topopt::simp_uniform_density(g, 0.4);
    std::vector<double> dc(g.voxel_count(), -1.0);  // dc/dxPhys < 0
    const double volfrac = 0.55, move = 0.2, dmin = 1e-3;
    std::vector<double> xnew =
        topopt::oc_update(g, idf, x, dc, volfrac, move, dmin);
    std::vector<double> xp = idf.filter_density(xnew);
    double vol = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) vol += xp[e];
    const double n_design = static_cast<double>(g.voxel_count());
    CHECK(near(vol / n_design, volfrac, 5e-3),
          "oc: filtered volume fraction equals the target");

    // 7b. Move limit and box bounds respected on every design voxel.
    bool bounds_ok = true, move_ok = true;
    for (std::size_t e = 0; e < g.voxel_count(); ++e) {
      if (xnew[e] < dmin - 1e-12 || xnew[e] > 1.0 + 1e-12) bounds_ok = false;
      if (std::fabs(xnew[e] - x[e]) > move + 1e-9) move_ok = false;
    }
    CHECK(bounds_ok, "oc: updated densities stay in [density_min, 1]");
    CHECK(move_ok, "oc: updated densities respect the move limit");

    // 7c. Monotone response to the sensitivity: a voxel with a more negative
    //     dc (adding material helps more) must receive at least as much
    //     density as one with a less negative dc, starting from equal density.
    VoxelGrid line = make_solid_grid(4, 1, 1, 1.0);
    DensityFilter lidf = topopt::make_density_filter(line, 0.5);
    std::vector<double> lx = topopt::simp_uniform_density(line, 0.5);
    std::vector<double> ldc(line.voxel_count(), 0.0);
    ldc[line.index(0, 0, 0)] = -4.0;
    ldc[line.index(1, 0, 0)] = -3.0;
    ldc[line.index(2, 0, 0)] = -2.0;
    ldc[line.index(3, 0, 0)] = -1.0;
    std::vector<double> lxn =
        topopt::oc_update(line, lidf, lx, ldc, 0.5, 0.2, 1e-3);
    CHECK(lxn[line.index(0, 0, 0)] > lxn[line.index(1, 0, 0)] &&
              lxn[line.index(1, 0, 0)] > lxn[line.index(2, 0, 0)] &&
              lxn[line.index(2, 0, 0)] > lxn[line.index(3, 0, 0)],
          "oc: density is monotone in the compliance sensitivity");

    // 7d. Empty voxels are excluded from the design and stay exactly 0.
    VoxelGrid gh = make_solid_grid(3, 3, 1, 1.0);
    gh.set_tag(1, 1, 0, VoxelTag::Empty);
    DensityFilter fh = topopt::make_density_filter(gh, 1.5);
    std::vector<double> hx = topopt::simp_uniform_density(gh, 0.5);
    std::vector<double> hdc(gh.voxel_count(), -1.0);
    std::vector<double> hxn =
        topopt::oc_update(gh, fh, hx, hdc, 0.5, 0.2, 1e-3);
    CHECK(near(hxn[gh.index(1, 1, 0)], 0.0, 0.0),
          "oc: Empty voxel stays exactly 0");

    // 7e. Argument validation.
    auto oc_throws = [&](double vf, double mv, double dm) {
      try {
        topopt::oc_update(g, idf, x, dc, vf, mv, dm);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    CHECK(oc_throws(0.0, 0.2, 1e-3), "oc: volume_fraction <= 0 throws");
    CHECK(oc_throws(1.5, 0.2, 1e-3), "oc: volume_fraction > 1 throws");
    CHECK(oc_throws(0.5, 0.0, 1e-3), "oc: move <= 0 throws");
    CHECK(oc_throws(0.5, 0.2, 0.0), "oc: density_min <= 0 throws");
  }

  // ==========================================================================
  // 8. Full SIMP loop simp_optimize (M3.4): drives the filter + penalized
  //    compliance + OC update to a volume-fraction target with convergence
  //    criteria. Here on a tiny cantilever (the fixture-based Gate V2 lives in
  //    tests/validation/test_gate_v2.cpp). Checks the loop's contract:
  //    reduces compliance, meets the volume target, reports a self-consistent
  //    final state, and honours both convergence criteria (change tol + cap).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.4;
    opt.filter_radius = 1.5;
    opt.move = 0.2;
    opt.max_iterations = 25;
    opt.change_tol = 0.0;  // no early stop: run the full cap
    opt.cg_tolerance = 1e-9;

    // 8a. A full run to the iteration cap.
    SimpOptimizeResult r = topopt::simp_optimize(g, p, bcs, loads, opt);
    CHECK(r.iterations == opt.max_iterations,
          "optimize: change_tol 0 runs the full iteration cap");
    CHECK(!r.converged,
          "optimize: not flagged converged when stopped by the cap");
    CHECK(r.history.size() == static_cast<std::size_t>(r.iterations),
          "optimize: one history entry per iteration");
    CHECK(near(r.history.front().compliance, r.initial_compliance, 0.0),
          "optimize: initial_compliance == first history compliance");
    CHECK(r.compliance > 0.0, "optimize: final compliance is positive");
    CHECK(r.compliance < r.initial_compliance,
          "optimize: compliance is reduced from the uniform start");
    CHECK(near(r.volume_fraction, opt.volume_fraction, 1e-3),
          "optimize: achieved physical volume fraction meets the target");

    // 8b. Self-consistency of the reported final state:
    //     physical_density == filter(design) and compliance ==
    //     compliance(physical_density).
    DensityFilter f = topopt::make_density_filter(g, opt.filter_radius);
    std::vector<double> xphys = f.filter_density(r.design);
    bool phys_ok = xphys.size() == r.physical_density.size();
    for (std::size_t e = 0; phys_ok && e < xphys.size(); ++e)
      if (!near(xphys[e], r.physical_density[e], 1e-12)) phys_ok = false;
    CHECK(phys_ok, "optimize: physical_density == filter(design)");
    SimpCompliance recomputed = topopt::simp_compliance(
        g, p, r.physical_density, bcs, loads, opt.cg_tolerance, 0);
    CHECK(near(r.compliance, recomputed.compliance,
               1e-5 * std::fabs(recomputed.compliance)),
          "optimize: compliance == compliance(physical_density)");
    // Design variables stay in the admissible box [density_min, 1].
    bool box_ok = true;
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double v = r.design[g.index(i, j, k)];
          if (v < p.density_min - 1e-12 || v > 1.0 + 1e-12) box_ok = false;
        }
    CHECK(box_ok, "optimize: design variables stay in [density_min, 1]");

    // 8c. Convergence criterion: a large change tolerance stops after the first
    //     step (an OC step moves any voxel by at most `move` = 0.2 < 1.0).
    SimpOptions early = opt;
    early.change_tol = 1.0;
    SimpOptimizeResult re = topopt::simp_optimize(g, p, bcs, loads, early);
    CHECK(re.iterations == 1,
          "optimize: a loose change_tol stops after one iteration");
    CHECK(re.converged, "optimize: early stop is flagged converged");
    CHECK(re.history.size() == 1, "optimize: early-stop history has one entry");

    // 8d. Argument validation.
    auto opt_throws = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpOptions o0 = opt; o0.volume_fraction = 0.0;
    SimpOptions o1 = opt; o1.volume_fraction = 1.5;
    SimpOptions o2 = opt; o2.move = 0.0;
    SimpOptions o3 = opt; o3.max_iterations = 0;
    SimpOptions o4 = opt; o4.change_tol = -0.1;
    SimpOptions o5 = opt; o5.filter_radius = 0.0;
    CHECK(opt_throws(o0), "optimize: volume_fraction <= 0 throws");
    CHECK(opt_throws(o1), "optimize: volume_fraction > 1 throws");
    CHECK(opt_throws(o2), "optimize: move <= 0 throws");
    CHECK(opt_throws(o3), "optimize: max_iterations < 1 throws");
    CHECK(opt_throws(o4), "optimize: change_tol < 0 throws");
    CHECK(opt_throws(o5), "optimize: filter_radius <= 0 throws");
  }

  // ==========================================================================
  // 9. Heaviside projection + beta continuation (M6.3). The exact analytic
  //    spot values live in fixtures/benchmarks.json and are asserted in
  //    test_gate_v2; here the projection functions are checked against their
  //    mathematical properties and finite differences (independent ground
  //    truth), and the staged simp_optimize loop against its contract.
  // ==========================================================================
  {
    const double eta = 0.5;

    // 9a. Function properties at eta = 0.5: fixed points 0 / 0.5 / 1, strict
    //     monotonicity, the symmetry project(x) + project(1-x) = 1, and
    //     sharpening with beta (higher beta pushes sub-threshold values down).
    for (double beta : {1.0, 8.0, 32.0}) {
      CHECK(near(topopt::heaviside_project(0.0, beta, eta), 0.0, 1e-12),
            "projection: project(0) == 0");
      CHECK(near(topopt::heaviside_project(0.5, beta, eta), 0.5, 1e-12),
            "projection: project(eta) == eta at eta = 0.5");
      CHECK(near(topopt::heaviside_project(1.0, beta, eta), 1.0, 1e-12),
            "projection: project(1) == 1");
      CHECK(topopt::heaviside_project(0.3, beta, eta) <
                topopt::heaviside_project(0.5, beta, eta) &&
            topopt::heaviside_project(0.5, beta, eta) <
                topopt::heaviside_project(0.7, beta, eta),
            "projection: strictly monotone in rho_tilde");
      CHECK(near(topopt::heaviside_project(0.3, beta, eta) +
                     topopt::heaviside_project(0.7, beta, eta),
                 1.0, 1e-12),
            "projection: project(x) + project(1-x) == 1 at eta = 0.5");
      CHECK(topopt::heaviside_project_derivative(0.5, beta, eta) > 0.0,
            "projection: derivative positive at the threshold");
    }
    CHECK(topopt::heaviside_project(0.3, 32.0, eta) <
              topopt::heaviside_project(0.3, 1.0, eta),
          "projection: higher beta pushes sub-threshold density toward 0");
    CHECK(topopt::heaviside_project(0.7, 32.0, eta) >
              topopt::heaviside_project(0.7, 1.0, eta),
          "projection: higher beta pushes super-threshold density toward 1");

    // 9b. Derivative vs central finite difference of the value.
    {
      const double h = 1e-6;
      double worst = 0.0;
      for (double beta : {1.0, 8.0}) {
        for (double rt : {0.1, 0.3, 0.5, 0.7, 0.9}) {
          const double fd = (topopt::heaviside_project(rt + h, beta, eta) -
                             topopt::heaviside_project(rt - h, beta, eta)) /
                            (2.0 * h);
          const double an = topopt::heaviside_project_derivative(rt, beta, eta);
          const double rel = std::fabs(fd - an) / std::max(std::fabs(an), 1e-30);
          worst = std::max(worst, rel);
          CHECK(rel < 1e-6,
                "projection: derivative matches central finite difference");
        }
      }
      std::printf("projection derivative FD: worst relative error %.3e\n",
                  worst);
    }

    // 9c. Argument validation of the projection functions.
    {
      auto proj_throws = [](double rt, double beta, double e) {
        try {
          topopt::heaviside_project(rt, beta, e);
        } catch (const std::invalid_argument&) {
          return true;
        } catch (...) {
          return false;
        }
        return false;
      };
      CHECK(proj_throws(0.5, 0.0, 0.5), "projection: beta <= 0 throws");
      CHECK(proj_throws(0.5, 8.0, 0.0), "projection: eta <= 0 throws");
      CHECK(proj_throws(0.5, 8.0, 1.0), "projection: eta >= 1 throws");
    }
  }

  // ==========================================================================
  // 10. M6.3 GATE (chain rule): the projected compliance gradient — the
  //     projection derivative chained BEFORE the filter transpose,
  //     dc/dx = H^T((dc/drho_bar * drho_bar/drho_tilde)/Hs) — matches a
  //     central finite difference of the composed objective
  //     c(project(filter(x))) on a tiny non-uniform grid. Likewise for the
  //     projected volume V(x) = sum_e project(filter(x))_e whose design-space
  //     gradient is H^T(drho_bar/drho_tilde / Hs). These are the two
  //     sensitivities the projected OC update consumes.
  // ==========================================================================
  {
    SimpParams p;
    p.youngs_modulus = 2100.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;
    const double beta = 8.0, eta = 0.5;

    VoxelGrid g = make_solid_grid(4, 2, 2, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    DensityFilter f = topopt::make_density_filter(g, 1.5);

    // Deterministic non-uniform design in [0.4, 0.9]: filtered and projected
    // values stay strictly inside (density_min, 1), so the clamp is inactive
    // and the composed objective is smooth.
    const std::size_t N = g.voxel_count();
    std::vector<double> x(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      x[e] = 0.4 + 0.5 * (static_cast<double>(e) / static_cast<double>(N - 1));

    const double tol = 1e-13;
    const int maxit = 8000;
    auto composed = [&](const std::vector<double>& xd) {
      std::vector<double> xt = f.filter_density(xd);
      std::vector<double> xb(xt.size(), 0.0);
      for (std::size_t e = 0; e < xt.size(); ++e)
        xb[e] = topopt::heaviside_project(xt[e], beta, eta);
      return topopt::simp_compliance(g, p, xb, bcs, loads, tol, maxit);
    };
    auto proj_volume = [&](const std::vector<double>& xd) {
      std::vector<double> xt = f.filter_density(xd);
      double v = 0.0;
      for (std::size_t e = 0; e < xt.size(); ++e)
        v += topopt::heaviside_project(xt[e], beta, eta);
      return v;
    };

    // Analytic design-space gradients per the locked chain.
    const std::vector<double> xtilde = f.filter_density(x);
    SimpCompliance base = composed(x);
    CHECK(base.cg.converged, "projected chain: base CG converged");
    std::vector<double> dc_phys(N, 0.0), dproj(N, 0.0);
    for (std::size_t e = 0; e < N; ++e) {
      dproj[e] = topopt::heaviside_project_derivative(xtilde[e], beta, eta);
      dc_phys[e] = base.dcompliance[e] * dproj[e];
    }
    const std::vector<double> dc = f.filter_sensitivity(dc_phys);
    const std::vector<double> dv = f.filter_sensitivity(dproj);

    const double h = 1e-4;
    const std::size_t probes[] = {0, 3, 7, 11, N - 1};
    double worst_c = 0.0, worst_v = 0.0;
    for (std::size_t e : probes) {
      std::vector<double> xp = x, xm = x;
      xp[e] += h;
      xm[e] -= h;
      const double fd_c =
          (composed(xp).compliance - composed(xm).compliance) / (2.0 * h);
      const double rel_c =
          std::fabs(fd_c - dc[e]) / std::max(std::fabs(dc[e]), 1e-30);
      worst_c = std::max(worst_c, rel_c);
      CHECK(rel_c < 1e-3,
            "projected chain: dc/dx matches FD of c(project(filter(x)))");
      const double fd_v = (proj_volume(xp) - proj_volume(xm)) / (2.0 * h);
      const double rel_v =
          std::fabs(fd_v - dv[e]) / std::max(std::fabs(dv[e]), 1e-30);
      worst_v = std::max(worst_v, rel_v);
      CHECK(rel_v < 1e-6,
            "projected chain: dV/dx matches FD of the projected volume");
    }
    std::printf(
        "projected chain FD: worst compliance rel %.3e, volume rel %.3e\n",
        worst_c, worst_v);
  }

  // ==========================================================================
  // 11. Staged projected simp_optimize (M6.3): beta continuation mechanics,
  //     per-stage move limits, self-consistent projected final state, the
  //     projected volume constraint, mask pins under projection, and argument
  //     validation. A short synthetic schedule keeps this a unit test; the
  //     locked 6x50 benchmark schedule is exercised by test_gate_v2.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(8, 4, 4, 1.0);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -1.0);

    SimpParams p;
    p.youngs_modulus = 1.0;
    p.poisson = 0.3;
    p.penalty = 3.0;
    p.density_min = 1e-3;

    SimpOptions opt;
    opt.volume_fraction = 0.4;
    opt.filter_radius = 1.5;
    opt.move = 0.2;          // ignored in projected mode (per-stage moves)
    opt.max_iterations = 60; // ignored in projected mode (per-stage iterations)
    opt.change_tol = 0.0;
    opt.cg_tolerance = 1e-9;
    opt.projection = {{1.0, 0.2, 6}, {2.0, 0.1, 5}, {4.0, 0.05, 4}};
    opt.projection_eta = 0.5;

    // 11a. Default options run the legacy (unprojected) loop: the projection
    //      schedule is empty by default.
    CHECK(SimpOptions{}.projection.empty(),
          "projected optimize: projection disabled by default");

    SimpOptimizeResult r = topopt::simp_optimize(g, p, bcs, loads, opt);

    // 11b. Iteration accounting: sum of stage iterations, one history entry
    //      per iteration, no convergence flag at change_tol 0.
    CHECK(r.iterations == 15,
          "projected optimize: iterations == sum of stage iterations");
    CHECK(r.history.size() == 15,
          "projected optimize: one history entry per iteration");
    CHECK(!r.converged, "projected optimize: change_tol 0 never converges");

    // 11c. Per-stage move limits honoured (0.2 / 0.1 / 0.05).
    bool moves_ok = true;
    for (std::size_t it = 0; it < r.history.size(); ++it) {
      const double mv = it < 6 ? 0.2 : (it < 11 ? 0.1 : 0.05);
      if (r.history[it].change > mv + 1e-9) moves_ok = false;
    }
    CHECK(moves_ok, "projected optimize: per-stage move limits respected");

    // 11d. Self-consistent projected final state: physical_density ==
    //      project(filter(design)) at the LAST stage's beta, compliance ==
    //      compliance(physical_density), volume_fraction == mean projected
    //      density == target (the constraint is on the projected field).
    DensityFilter f = topopt::make_density_filter(g, opt.filter_radius);
    std::vector<double> xt = f.filter_density(r.design);
    bool phys_ok = xt.size() == r.physical_density.size();
    double vol = 0.0;
    for (std::size_t e = 0; phys_ok && e < xt.size(); ++e) {
      const double xb = topopt::heaviside_project(xt[e], 4.0, 0.5);
      if (!near(xb, r.physical_density[e], 1e-12)) phys_ok = false;
      vol += xb;
    }
    CHECK(phys_ok,
          "projected optimize: physical_density == project(filter(design))");
    CHECK(near(vol / static_cast<double>(g.voxel_count()), r.volume_fraction,
               1e-12),
          "projected optimize: volume_fraction is the projected fraction");
    CHECK(near(r.volume_fraction, opt.volume_fraction, 1e-2),
          "projected optimize: projected volume fraction meets the target");
    SimpCompliance rc = topopt::simp_compliance(
        g, p, r.physical_density, bcs, loads, opt.cg_tolerance, 0);
    CHECK(near(r.compliance, rc.compliance, 1e-5 * std::fabs(rc.compliance)),
          "projected optimize: compliance == compliance(physical_density)");
    CHECK(r.compliance > 0.0 && r.compliance < r.initial_compliance,
          "projected optimize: compliance reduced from the uniform start");

    // 11e. change_tol still ends a stage early (each stage re-converges, then
    //      continuation moves on): a huge tolerance stops every stage after
    //      one iteration.
    SimpOptions early = opt;
    early.change_tol = 1.0;
    SimpOptimizeResult re = topopt::simp_optimize(g, p, bcs, loads, early);
    CHECK(re.iterations == 3,
          "projected optimize: loose change_tol runs one iteration per stage");
    CHECK(re.converged,
          "projected optimize: early stop of the last stage flags converged");

    // 11f. Masked overload under projection: FrozenVoid stays exactly 0,
    //      FrozenSolid exactly 1 in the projected physical density; the run
    //      completes with the same iteration accounting.
    topopt::DesignMask mask = topopt::make_active_mask(g);
    for (int j = 0; j < g.ny; ++j)  // a keep-out channel through mid-x
      mask[g.index(4, j, 2)] = topopt::MaskValue::FrozenVoid;
    mask[g.index(1, 1, 1)] = topopt::MaskValue::FrozenSolid;
    SimpOptimizeResult rm = topopt::simp_optimize(g, p, bcs, loads, opt, mask);
    CHECK(rm.iterations == 15,
          "projected masked: iterations == sum of stage iterations");
    bool pins_ok = true;
    for (int j = 0; j < g.ny; ++j)
      if (!near(rm.physical_density[g.index(4, j, 2)], 0.0, 0.0))
        pins_ok = false;
    CHECK(pins_ok, "projected masked: FrozenVoid physical density pinned 0");
    CHECK(near(rm.physical_density[g.index(1, 1, 1)], 1.0, 0.0),
          "projected masked: FrozenSolid physical density pinned 1");

    // 11g. Argument validation of the projection schedule (both overloads).
    auto opt_throws = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    auto opt_throws_masked = [&](const SimpOptions& o) {
      try {
        topopt::simp_optimize(g, p, bcs, loads, o, mask);
      } catch (const std::invalid_argument&) {
        return true;
      } catch (...) {
        return false;
      }
      return false;
    };
    SimpOptions b0 = opt; b0.projection[1].beta = 0.0;
    SimpOptions b1 = opt; b1.projection[0].move = 0.0;
    SimpOptions b2 = opt; b2.projection[2].iterations = 0;
    SimpOptions b3 = opt; b3.projection_eta = 1.0;
    CHECK(opt_throws(b0), "projected optimize: stage beta <= 0 throws");
    CHECK(opt_throws(b1), "projected optimize: stage move <= 0 throws");
    CHECK(opt_throws(b2), "projected optimize: stage iterations < 1 throws");
    CHECK(opt_throws(b3), "projected optimize: eta outside (0,1) throws");
    CHECK(opt_throws_masked(b0), "projected masked: stage beta <= 0 throws");
    CHECK(opt_throws_masked(b3), "projected masked: bad eta throws");
  }

  if (g_failures == 0) {
    std::printf("simp: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "simp: %d/%d checks FAILED\n", g_failures, g_checks);
  return 1;
}
