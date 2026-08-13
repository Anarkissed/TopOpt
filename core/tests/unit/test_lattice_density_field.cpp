// test_lattice_density_field.cpp — task 2026-08-13-lattice-as-a-material.
//
// The unit bars for the mechanism itself: the C0 dispatch bar R1 rests on, the
// two floors that bind in opposite directions, the beta field and its analytic
// Jacobian against central differences, and the refusals.
//
// ★ THE FIRST TEST IS THE ONE THAT MATTERS. If `Lattice(f = 1.0)` is not a no-op
// the material model is wrong and no result after it can be trusted (bar R1, and
// a BLOCKED-STOP). The whole-run version of that bar is a stash-rebuild checksum
// in `frozen_lattice_probe --stage r1`; this is the same claim at the resolver,
// where it is decidable without a solve.

#include "topopt/lattice_density_field.hpp"
#include "topopt/fea.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "simp/mma_joint.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>

using namespace topopt;

namespace {

int g_failures = 0;

#define CHECK(cond, msg)                                                    \
  do {                                                                      \
    if (!(cond)) {                                                          \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, (msg));           \
      ++g_failures;                                                         \
    }                                                                       \
  } while (0)

// A 12x12x12 block of Interior voxels — thick enough that a member is not the
// subject of these tests.
VoxelGrid block(int n = 12, double spacing = 1.0) {
  VoxelGrid g;
  g.nx = g.ny = g.nz = n;
  g.spacing = spacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  // ★ NOT `g.voxel_count()` — that returns `tags.size()`, which is ZERO until
  // this line runs. Sizing a grid from its own empty tag vector produces a grid
  // whose nx/ny/nz say 12³ and whose voxel_count() says 0, and every field built
  // against it is then a different length from every loop that walks it.
  g.tags.assign(static_cast<std::size_t>(n) * n * n, VoxelTag::Interior);
  return g;
}

std::vector<int> one_region(const VoxelGrid& g, int id = 1) {
  return std::vector<int>(g.voxel_count(), id);
}

// The x = 0 face fully clamped, and a transverse -z load on the free end face —
// the same cantilever `test_simp.cpp` uses, so the fixture is not a new one.
std::vector<DirichletBC> clamp_x0_face(const VoxelGrid& g) {
  std::vector<DirichletBC> bcs;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) {
      const int n = fea_node_index(g, 0, b, c);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return bcs;
}

std::vector<NodalLoad> tip_load_z(const VoxelGrid& g, double total) {
  std::vector<int> nodes;
  for (int c = 0; c <= g.nz; ++c)
    for (int b = 0; b <= g.ny; ++b) nodes.push_back(fea_node_index(g, g.nx, b, c));
  std::vector<NodalLoad> loads;
  const double per = total / static_cast<double>(nodes.size());
  for (int n : nodes) loads.push_back({n, 2, per});
  return loads;
}

LatticeRegionSpec declared(int id, double f) {
  LatticeRegionSpec s;
  s.id = id;
  s.name = "r" + std::to_string(id);
  s.mode = LatticeRegionMode::Declared;
  s.declared_density = f;
  return s;
}

}  // namespace

int main() {
  const VoxelGrid g = block();
  const std::vector<int> rid = one_region(g);
  const LatticeTopology T = LatticeTopology::Octet;

  // ── ★ R1: f = 1.0 IS SOLID, AND SOLID EMITS NOTHING ──────────────────────
  {
    const ResolvedLatticeDensityField f1 = resolve_lattice_density_field(
        g, rid, {declared(1, 1.0)}, T, nullptr, nullptr, {});
    CHECK(f1.empty(), "f = 1.0 must lattice NOTHING — a lattice at relative "
                      "density 1 has no pore space and IS solid");
    CHECK(f1.mask.empty() && f1.rho.empty(),
          "an inert field must not even allocate its grid vectors — the caller's "
          "byte-identical path is chosen on emptiness");
    CHECK(f1.latticed_voxels == 0 && f1.freed_mass_voxels == 0.0,
          "f = 1.0 frees no mass, so the volume budget cannot move");

    const ResolvedLatticeDensityField solid = resolve_lattice_density_field(
        g, rid, {LatticeRegionSpec{1, "r1", LatticeRegionMode::Solid, 0.3, 0, 0}},
        T, nullptr, nullptr, {});
    CHECK(solid.empty(), "mode Solid must lattice nothing whatever density it "
                         "carries — the mode wins over the number");

    // ★ AND IT IS NOT A CLAMP. Above the band, 1.0 must not silently become
    // rho_max: that would turn "leave this solid" into "lattice it at 0.90".
    const ResolvedLatticeDensityField above = resolve_lattice_density_field(
        g, rid, {declared(1, 0.95)}, T, nullptr, nullptr, {});
    CHECK(!above.empty(), "0.95 is below kLatticeSolidAt and must still lattice");
    CHECK(std::fabs(above.rho[0] - lattice_rho_max(T)) < 1e-12,
          "0.95 is above the band and IS clamped to rho_max — only exactly 1.0 "
          "means solid");
  }

  // ── the constant field, and the mass it frees ────────────────────────────
  {
    const ResolvedLatticeDensityField f = resolve_lattice_density_field(
        g, rid, {declared(1, 0.30)}, T, nullptr, nullptr, {});
    CHECK(f.latticed_voxels == g.voxel_count(),
          "every voxel of the region is latticed when nothing restricts it");
    CHECK(std::fabs(f.rho[0] - 0.30) < 1e-12, "the declared density is used verbatim");
    CHECK(std::fabs(f.freed_mass_voxels -
                    0.70 * static_cast<double>(g.voxel_count())) < 1e-9,
          "the freed mass is sum(1 - rho) — this is what enters the budget");
    CHECK(std::fabs(f.region_mean_rho[0] - 0.30) < 1e-12,
          "a constant field's mean is its constant");
  }

  // ── `only_where` — a density field may NEVER appear off the frozen set ───
  {
    std::vector<char> only(g.voxel_count(), 0);
    only[0] = 1;
    const ResolvedLatticeDensityField f = resolve_lattice_density_field(
        g, rid, {declared(1, 0.30)}, T, nullptr, &only, {});
    CHECK(f.latticed_voxels == 1,
          "only voxels the caller holds FROZEN may carry a density field — a "
          "field over a voxel the optimiser can move is a different feature");
    CHECK(f.mask[0] != 0 && f.mask[1] == 0, "and it is the right voxel");
  }

  // ── a REFUSED region emits nothing, and a refusal is not a clamp ─────────
  {
    const ResolvedLatticeDensityField f = resolve_lattice_density_field(
        g, rid, {declared(1, 0.30)}, T, nullptr, nullptr, {1});
    CHECK(f.empty(), "a refused region is REFUSED, not latticed at some other "
                     "density");
  }

  // ── the two floors, which are different questions with different remedies ─
  {
    // A 30 mm member at a 2 mm cell is 15 cells: comfortably above N* = 5.
    std::vector<double> width(g.voxel_count(), 30.0);
    const std::vector<LatticeRegionValidity> ok = lattice_region_validity(
        g, rid, {declared(1, 0.30)}, width, T, 2.0, 0.45);
    CHECK(ok.size() == 1 && ok[0].in_validity_range,
          "15 cells per member clears the 5-cell homogenisation floor");
    CHECK(ok[0].refusal.empty(), "an in-range region carries no refusal");
    CHECK(std::fabs(ok[0].cells_per_member_median - 15.0) < 1e-9,
          "cells per member is member width / cell, and nothing else");

    // 5 mm at a 2 mm cell is 2.5 cells: under N* = 5, over percolation = 1.
    std::vector<double> thin(g.voxel_count(), 5.0);
    const std::vector<LatticeRegionValidity> mid = lattice_region_validity(
        g, rid, {declared(1, 0.30)}, thin, T, 2.0, 0.45);
    CHECK(!mid[0].in_validity_range, "2.5 cells is below the certifiable floor");
    CHECK(mid[0].buildable_not_certifiable,
          "and above the percolation floor — BUILDABLE AND UNCERTIFIABLE is a "
          "third verdict, not a rounding of the other two");
    // ★ 5 mm is below the thinnest member ANY cell can certify at this nozzle
    // (5.8659 mm), so no finer cell rescues it and the refusal must SAY so —
    // the remedy is a thicker member or a finer nozzle, not a cell change.
    CHECK(!mid[0].fit_feasible,
          "a 5 mm member cannot be fitted at a 0.45 mm strut width");
    CHECK(mid[0].refusal.find("NO FINER CELL RESCUES IT") != std::string::npos,
          "the refusal must say that the cell is not the lever here");
    CHECK(mid[0].min_member_width_certifiable_mm > 5.0,
          "and it must carry the number a user acts on: the thinnest member that "
          "COULD clear the floor at this nozzle");

    // ★★ AND THE CASE THE WHOLE FEATURE TURNS ON: a member that MISSES the floor
    // at the run's cell and CLEARS it at its own. 8 mm at a 2 mm cell is 4 cells
    // — under the floor — but 8 mm is above the 5.8659 mm minimum, so a fitted
    // cell of 8/5 = 1.6 mm holds exactly 5 cells. An earlier cut of this task
    // refused this region outright; on his part that was the region holding 73%
    // of the prize.
    std::vector<double> fitme(g.voxel_count(), 8.0);
    const std::vector<LatticeRegionValidity> fit = lattice_region_validity(
        g, rid, {declared(1, 0.30)}, fitme, T, 2.0, 0.45);
    CHECK(!fit[0].in_validity_range,
          "8 mm at the RUN'S 2 mm cell is 4 cells — under the floor");
    CHECK(fit[0].fit_feasible,
          "★ but it FITS at a cell derived from its own thickness");
    CHECK(std::fabs(fit[0].fit_cell_mm - 8.0 / 5.0) < 1e-9,
          "the fitted cell is exactly N* cells across the member");
    CHECK(fit[0].fit_min_density > 0.0 &&
              lattice_density_printable(T, fit[0].fit_min_density,
                                        fit[0].fit_cell_mm, 0.45),
          "and the density that comes with it PRINTS at that cell — the fit "
          "answers both bounds at once or it answers neither");
    CHECK(fit[0].refusal.find("IT FITS AT ITS OWN CELL") != std::string::npos,
          "★ and the refusal under the fixed cell must NAME the cell that works "
          "— \"too thin for a 2 mm cell\" and \"cannot be latticed\" are very "
          "different statements and only one of them is true here");

    // 1 mm at a 2 mm cell is 0.5 cells: under BOTH floors.
    std::vector<double> hair(g.voxel_count(), 1.0);
    const std::vector<LatticeRegionValidity> bad = lattice_region_validity(
        g, rid, {declared(1, 0.30)}, hair, T, 2.0, 0.45);
    CHECK(!bad[0].in_validity_range && !bad[0].buildable_not_certifiable,
          "0.5 cells clears neither floor");
  }

  // ── PRINTABILITY, which binds from the OTHER direction ───────────────────
  {
    // A coarser cell helps printability and hurts homogenisation; they cross.
    CHECK(!lattice_density_printable(T, lattice_rho_min(T), 1.0, 0.45),
          "the band's lightest strut does not print at a 1 mm cell");
    CHECK(lattice_density_printable(T, lattice_rho_min(T), 8.0, 0.45),
          "and it does at an 8 mm cell — the two floors bind opposite ways");
    CHECK(!lattice_density_printable(T, 0.20, 2.0, 0.45),
          "at HIS 2 mm cell a 20% lattice does not come out of a 0.45 mm nozzle");
    CHECK(lattice_density_printable(T, 0.30, 2.0, 0.45),
          "a 30% one does");
  }

  // ── the beta field: the map, and the Jacobian against a central difference ─
  {
    LatticeBetaField B;
    const LatticeBetaKnots k = lattice_beta_knots_for_grid(g, 0.0, 0.0, 0.0);
    CHECK(k.dx == k.dy && k.dy == k.dz,
          "the knot spacing is the same number of voxels on every axis — no "
          "minimum and no maximum is taken over the axes");
    B.lattice = plsm_make_lattice(g.nx, g.ny, g.nz, k.dx, k.dy, k.dz, 2.0);
    B.basis = PlsmBasisKind::Gaussian;
    B.steepness = 1.0;
    B.beta.assign(B.lattice.count(), 0.0);

    LatticeRegionSpec opt;
    opt.id = 1;
    opt.name = "r1";
    opt.mode = LatticeRegionMode::Optimised;

    // beta = 0 must land in the MIDDLE of the band, not at an endpoint: a seed
    // pinned to a bound has no gradient to move on in one direction.
    const ResolvedLatticeDensityField f0 =
        resolve_lattice_density_field(g, rid, {opt}, T, &B, nullptr, {});
    const double mid = 0.5 * (lattice_rho_min(T) + lattice_rho_max(T));
    CHECK(std::fabs(f0.rho[0] - mid) < 1e-9,
          "beta = 0 seeds the middle of the band (H(0) = 0.5)");

    // The analytic Jacobian against a central difference on one coefficient.
    for (std::size_t j = 0; j < B.beta.size(); ++j)
      B.beta[j] = 0.37 * std::sin(0.7 * static_cast<double>(j));
    const PlsmCsr J =
        lattice_beta_jacobian(g, rid, {opt}, T, B, nullptr, {}, 1);
    CHECK(J.rows == g.voxel_count(), "the Jacobian is grid-indexed by row");
    CHECK(J.cols == B.lattice.count(), "and coefficient-indexed by column");

    const std::size_t probe_voxel = g.index(6, 6, 6);
    double worst = 0.0;
    for (std::size_t p = J.row[probe_voxel]; p < J.row[probe_voxel + 1]; ++p) {
      const std::size_t col = static_cast<std::size_t>(J.col[p]);
      const double h = 1e-5;
      LatticeBetaField up = B, dn = B;
      up.beta[col] += h;
      dn.beta[col] -= h;
      const double ru = resolve_lattice_density_field(g, rid, {opt}, T, &up,
                                                      nullptr, {}).rho[probe_voxel];
      const double rd = resolve_lattice_density_field(g, rid, {opt}, T, &dn,
                                                      nullptr, {}).rho[probe_voxel];
      const double fd = (ru - rd) / (2.0 * h);
      const double rel = std::fabs(fd - J.val[p]) /
                         std::max(1e-12, std::fabs(fd));
      if (rel > worst) worst = rel;
    }
    CHECK(worst < 1e-6,
          "d rho / d beta must agree with a central difference — this is the "
          "only derivative MODE 2 needs beyond dc/drho, and a wrong one would "
          "converge slowly rather than fail");
    std::printf("beta Jacobian vs central difference: worst rel err %.3e\n", worst);

    // A row for a voxel NOT in an Optimised region must be EMPTY, so a chain
    // rule over the whole grid picks up exactly the coupled voxels.
    const PlsmCsr J2 = lattice_beta_jacobian(g, rid, {declared(1, 0.3)}, T, B,
                                             nullptr, {}, 1);
    CHECK(J2.nnz() == 0,
          "a DECLARED region has no beta coupling — its sensitivity is zero, and "
          "that is the whole difference between the two modes");
  }

  // ── ★ dC/dbeta END TO END, against a central difference of the COMPLIANCE ──
  //
  // The Jacobian bar above checks one link. This checks the CHAIN the optimiser
  // would actually descend: resolve -> tensor -> solve -> dc/d(lattice rho) ->
  // J^T. A sign error or a missing factor anywhere in it produces a gradient
  // that still LOOKS plausible and makes MMA wander, so the finite difference is
  // taken on the compliance itself rather than on any intermediate.
  {
    LatticeBetaField B;
    const LatticeBetaKnots k = lattice_beta_knots_for_grid(g, 0.0, 0.0, 0.0);
    B.lattice = plsm_make_lattice(g.nx, g.ny, g.nz, k.dx, k.dy, k.dz, 2.0);
    B.basis = PlsmBasisKind::Gaussian;
    B.steepness = 1.0;
    B.beta.assign(B.lattice.count(), 0.0);
    for (std::size_t j = 0; j < B.beta.size(); ++j)
      B.beta[j] = 0.31 * std::sin(0.9 * static_cast<double>(j) + 0.4);

    LatticeRegionSpec opt;
    opt.id = 1;
    opt.name = "r1";
    opt.mode = LatticeRegionMode::Optimised;

    const LatticeMaterialModel M =
        build_lattice_material_model(T, 2300.0, 0.35);

    SimpParams p;
    p.youngs_modulus = 2300.0;
    p.poisson = 0.35;
    p.penalty = 3.0;
    p.lattice_material = &M;

    const std::vector<DirichletBC> bcs = clamp_x0_face(g);
    const std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    const std::vector<double> dens(g.voxel_count(), 1.0);

    // ★ A TIGHT tolerance, because the finite difference differences two SOLVES.
    // At the trajectory tolerance the CG noise is larger than the h-step effect
    // and the check would compare solver residuals, not derivatives.
    const double tol = 1e-13;
    auto compliance_at = [&](const LatticeBetaField& bf) {
      const ResolvedLatticeDensityField f =
          resolve_lattice_density_field(g, rid, {opt}, T, &bf, nullptr, {});
      std::vector<double> lr(g.voxel_count(), -1.0);
      for (std::size_t e = 0; e < g.voxel_count(); ++e)
        if (f.mask[e]) lr[e] = f.rho[e];
      SimpParams q = p;
      q.lattice_relative_density = &lr;
      return simp_compliance(g, q, dens, bcs, loads, tol, 20000);
    };

    const ResolvedLatticeDensityField f =
        resolve_lattice_density_field(g, rid, {opt}, T, &B, nullptr, {});
    CHECK(f.latticed_voxels == g.voxel_count(),
          "every voxel of the single Optimised region is latticed");
    const SimpCompliance c0 = compliance_at(B);
    const PlsmCsr J = lattice_beta_jacobian(g, rid, {opt}, T, B, nullptr, {}, 1);
    const std::vector<double> grad = lattice_beta_chain(J, c0.dcompliance);
    CHECK(grad.size() == B.beta.size(),
          "the beta gradient is one number per coefficient");

    // ★ THE PROBES MUST BE COEFFICIENTS THAT ACTUALLY MOVE THE COMPLIANCE.
    // The knot lattice is PADDED, so its first and last coefficients can have no
    // support inside the grid: probing those compares 0 against 0 and passes
    // while measuring nothing. Pick the three largest |dC/dbeta| instead, and
    // assert each is non-trivial before believing the agreement.
    std::vector<std::size_t> order(grad.size());
    for (std::size_t i = 0; i < order.size(); ++i) order[i] = i;
    std::sort(order.begin(), order.end(), [&](std::size_t a, std::size_t b) {
      return std::fabs(grad[a]) > std::fabs(grad[b]);
    });
    CHECK(order.size() >= 3 && std::fabs(grad[order[2]]) > 1e-12,
          "at least three coefficients must have a NON-ZERO analytic gradient — "
          "otherwise the comparison below is 0 == 0 and measures nothing");

    double worst = 0.0;
    for (std::size_t pi = 0; pi < 3; ++pi) {
      const std::size_t j = order[pi];
      CHECK(std::fabs(grad[j]) > 1e-12,
            "positive control: this probe's analytic gradient is non-zero");
      const double h = 1e-4;
      LatticeBetaField up = B, dn = B;
      up.beta[j] += h;
      dn.beta[j] -= h;
      const double fd =
          (compliance_at(up).compliance - compliance_at(dn).compliance) /
          (2.0 * h);
      const double rel =
          std::fabs(fd - grad[j]) / std::max(1e-30, std::fabs(fd));
      if (rel > worst) worst = rel;
      std::printf("  beta[%zu]: analytic %+.10e  central %+.10e  rel %.3e\n", j,
                  grad[j], fd, rel);
    }
    CHECK(worst < 1e-5,
          "dC/dbeta must agree with a central difference of the COMPLIANCE — "
          "this is the gradient MMA descends in Mode 2, and a wrong one wanders "
          "instead of failing");
    std::printf("dC/dbeta vs central difference: worst rel err %.3e\n", worst);

    // ★ AND A DECLARED REGION CONTRIBUTES NOTHING. Mode 1 is Mode 2 with an
    // identically zero gradient — the fixed density is a CONSTANT field, so the
    // optimiser sees no direction to move it in. That is the whole claim the
    // brief rests on, stated as an assertion rather than as prose.
    const PlsmCsr Jd = lattice_beta_jacobian(g, rid, {declared(1, 0.35)}, T, B,
                                             nullptr, {}, 1);
    const std::vector<double> gd = lattice_beta_chain(Jd, c0.dcompliance);
    bool all_zero = true;
    for (double v : gd) all_zero = all_zero && (v == 0.0);
    CHECK(all_zero && gd.size() == B.beta.size(),
          "a Declared region's beta gradient is EXACTLY zero — a fixed density "
          "is a constant density field");
  }

  // ── ★ MODE 2 ACTUALLY OPTIMISES: a loop, not just a gradient ─────────────
  //
  // The gradient bar above says the direction is right. This says the loop that
  // follows it goes DOWNHILL and stays on budget — which is a different claim,
  // and the one that decides whether Mode 2 is a feature or an assertion.
  //
  // Half the block is Active design space; the other half is FROZEN and carries
  // the density field. One volume constraint prices both, so the optimiser is
  // free to spend the budget on whichever buys stiffness more cheaply. That
  // trade IS Mode 2.
  {
    LatticeBetaField B;
    const LatticeBetaKnots kn = lattice_beta_knots_for_grid(g, 0.0, 0.0, 0.0);
    B.lattice = plsm_make_lattice(g.nx, g.ny, g.nz, kn.dx, kn.dy, kn.dz, 2.0);
    B.basis = PlsmBasisKind::Gaussian;
    B.steepness = 1.0;
    B.beta.assign(B.lattice.count(), 0.0);  // the band midpoint everywhere

    // Region 1 = the frozen half (latticed); region 0 = nowhere.
    std::vector<int> rid2(g.voxel_count(), 0);
    DesignMask eff(g.voxel_count(), MaskValue::Active);
    std::vector<char> only(g.voxel_count(), 0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i)
          if (i >= g.nx / 2) {
            const std::size_t e = g.index(i, j, k);
            rid2[e] = 1;
            eff[e] = MaskValue::FrozenSolid;
            only[e] = 1;
          }
    LatticeRegionSpec opt;
    opt.id = 1;
    opt.name = "field";
    opt.mode = LatticeRegionMode::Optimised;

    const LatticeMaterialModel M = build_lattice_material_model(T, 2300.0, 0.35);
    SimpParams p;
    p.youngs_modulus = 2300.0;
    p.poisson = 0.35;
    p.penalty = 3.0;
    p.lattice_material = &M;

    const std::vector<DirichletBC> bcs = clamp_x0_face(g);
    const std::vector<NodalLoad> loads = tip_load_z(g, -4.0);
    const DensityFilter filt = make_density_filter(g, 1.5, eff);

    double n_active = 0.0;
    for (MaskValue m : eff)
      if (m == MaskValue::Active) n_active += 1.0;

    // The budget: 40% of the Active envelope, plus whatever the seed field
    // occupies. Stated here rather than derived, because the convention is a
    // CHOICE (see the handoff §3d) and a buried one would be unauditable.
    std::vector<double> x(g.voxel_count(), 0.0);
    for (std::size_t e = 0; e < x.size(); ++e)
      x[e] = (eff[e] == MaskValue::Active) ? 0.40 : 1.0;
    const ResolvedLatticeDensityField seed =
        resolve_lattice_density_field(g, rid2, {opt}, T, &B, &only, {});
    double seed_mass = 0.0;
    for (std::size_t e = 0; e < g.voxel_count(); ++e)
      if (seed.mask[e]) seed_mass += seed.rho[e];
    const double total_target = 0.40 * n_active + seed_mass;

    MmaJointState st;
    double c_first = 0.0, c_last = 0.0, mass_last = 0.0;
    double beta_span = 0.0;
    for (int it = 1; it <= 12; ++it) {
      const ResolvedLatticeDensityField f =
          resolve_lattice_density_field(g, rid2, {opt}, T, &B, &only, {});
      std::vector<double> lr(g.voxel_count(), -1.0);
      double lat_mass = 0.0;
      for (std::size_t e = 0; e < g.voxel_count(); ++e)
        if (f.mask[e]) {
          lr[e] = f.rho[e];
          lat_mass += f.rho[e];
        }
      SimpParams q = p;
      q.lattice_relative_density = &lr;
      const SimpCompliance c = simp_compliance(g, q, x, bcs, loads, 1e-11, 20000);
      if (it == 1) c_first = c.compliance;
      c_last = c.compliance;

      const PlsmCsr J =
          lattice_beta_jacobian(g, rid2, {opt}, T, B, &only, {}, 1);
      std::vector<double> ones_lat(g.voxel_count(), 0.0);
      for (std::size_t e = 0; e < g.voxel_count(); ++e)
        if (f.mask[e]) ones_lat[e] = 1.0;
      const std::vector<double> dobj_b = lattice_beta_chain(J, c.dcompliance);
      const std::vector<double> dmass_b = lattice_beta_chain(J, ones_lat);

      const std::vector<double> nx_ = mma_update_masked_lattice(
          st, it, g, filt, eff, x, B.beta, c.dcompliance, dobj_b, dmass_b,
          lat_mass, total_target, -8.0, 8.0, 0.2, p.density_min);
      for (std::size_t e = 0; e < g.voxel_count(); ++e)
        if (eff[e] == MaskValue::Active) x[e] = nx_[e];
      for (std::size_t j = 0; j < B.beta.size(); ++j)
        B.beta[j] = nx_[g.voxel_count() + j];

      // Total mass-equivalent actually held, at the END of the step.
      const std::vector<double> xph = filt.filter_density(x);
      double v = 0.0;
      for (double t : xph) v += t;
      const ResolvedLatticeDensityField fe =
          resolve_lattice_density_field(g, rid2, {opt}, T, &B, &only, {});
      double lm = 0.0;
      for (std::size_t e = 0; e < g.voxel_count(); ++e)
        if (fe.mask[e]) lm += fe.rho[e];
      mass_last = v + lm;
    }
    for (double bv : B.beta) beta_span = std::max(beta_span, std::fabs(bv));

    std::printf("MODE 2 loop: c %.6e -> %.6e (%.2f%%), mass %.3f vs budget %.3f,"
                " max|beta| %.4f\n",
                c_first, c_last, 100.0 * (c_last - c_first) / c_first, mass_last,
                total_target, beta_span);

    CHECK(c_last < c_first,
          "★ Mode 2 must go DOWNHILL — a joint update that raises the objective "
          "is a wrong gradient or a wrong constraint, not a slow start");
    CHECK(mass_last <= total_target * 1.02,
          "and it must stay on the ONE budget that prices both blocks — a "
          "lattice that pays for itself twice would look like free stiffness");
    // ★ POSITIVE CONTROL. If beta never moved, the two checks above would pass
    // on a pure density run and this whole block would be measuring nothing.
    CHECK(beta_span > 1e-6,
          "the beta block must actually MOVE — otherwise this bar is the Mode 1 "
          "bar wearing a Mode 2 label");
  }

  // ── the refusals ─────────────────────────────────────────────────────────
  {
    bool threw = false;
    try {
      LatticeRegionSpec opt;
      opt.id = 1;
      opt.mode = LatticeRegionMode::Optimised;
      resolve_lattice_density_field(g, rid, {opt}, T, nullptr, nullptr, {});
    } catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "an Optimised region with no beta field is a REFUSAL, not a "
                 "silent fallback to some default density");

    threw = false;
    try {
      resolve_lattice_density_field(g, std::vector<int>(3, 1),
                                    {declared(1, 0.3)}, T, nullptr, nullptr, {});
    } catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "a region_id sized to the wrong grid is refused");

    threw = false;
    try {
      LatticeRegionSpec s = declared(1, 0.3);
      s.optimised_rho_min = 0.8;
      s.optimised_rho_max = 0.2;
      resolve_lattice_density_field(g, rid, {s}, T, nullptr, nullptr, {});
    } catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "a narrowing that empties the band is a declaration error, not "
                 "something to silently widen back out");

    threw = false;
    try {
      resolve_lattice_density_field(g, rid, {declared(1, 0.3), declared(1, 0.4)},
                                    T, nullptr, nullptr, {});
    } catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "a duplicate region id is refused — two policies for one id has "
                 "no answer");
  }

  // ── ★ PRINTABILITY IS ENTIRELY USER INPUT — no default, ever ─────────────
  //
  // Every project carries a print profile the user chose and the software may not
  // change. The minimum extrudable strut width comes from THERE. A hardcoded one
  // is wrong for everybody whose nozzle differs, and the two ends of the common
  // range disagree by more than 3x — so "unset" must be a REFUSAL and never a
  // number the code picked. (`frozen_lattice_min_extrudable_width_mm` defaulted
  // to 0.45 — his nozzle — in an earlier cut of this task. This is that bug's
  // gravestone.)
  {
    // The SAME density, the SAME cell, three different profiles: the verdicts
    // must differ, which is the whole reason the number cannot be assumed.
    CHECK(lattice_density_printable(T, 0.30, 2.0, 0.25),
          "a 0.25 mm nozzle prints a 30% lattice at a 2 mm cell");
    CHECK(lattice_density_printable(T, 0.30, 2.0, 0.45),
          "and so does a 0.45 mm one");
    CHECK(!lattice_density_printable(T, 0.30, 2.0, 0.80),
          "★ and a 0.80 mm one does NOT — same lattice, same cell, opposite "
          "verdict. That is why there is no default width.");

    // The FLOOR moves with the profile too, monotonically: a fatter bead needs a
    // bigger cell before the band's lightest strut prints.
    const double f25 = lattice_cell_printability_floor_mm(T, 0.25);
    const double f45 = lattice_cell_printability_floor_mm(T, 0.45);
    const double f80 = lattice_cell_printability_floor_mm(T, 0.80);
    CHECK(f25 < f45 && f45 < f80,
          "the printability floor is a function of the USER'S width and moves "
          "with it");
    CHECK(f80 / f25 > 3.0,
          "★ across the common nozzle range the floor moves by more than 3x — a "
          "hardcoded width would refuse a lattice that prints, or approve one "
          "that comes out as gaps");
  }

  // ── ★ the law reaches SOLID exactly at rho = 1 ───────────────────────────
  // The claim R1's dispatch rule rests beside: routing f = 1.0 through the cubic
  // law would ALSO have been right, to machine precision. Measured here so the
  // dispatch is a choice about exactness and not a patch over a discontinuity.
  {
    const MaterialLibrary lib = load_materials_file(MATERIALS_JSON_PATH);
    const Material m = lib.at("PLA");
    const LatticeMaterialModel M =
        build_lattice_material_model(T, m.youngs_modulus_mpa, m.poisson);
    const CubicTensor C = M.value(1.0);
    const double E = m.youngs_modulus_mpa, nu = m.poisson;
    const double c = E / ((1.0 + nu) * (1.0 - 2.0 * nu));
    CHECK(std::fabs(C.C11 - c * (1.0 - nu)) / (c * (1.0 - nu)) < 1e-12,
          "C(1) is the EXACT isotropic solid C11");
    CHECK(std::fabs(C.C12 - c * nu) / (c * nu) < 1e-12,
          "C(1) is the EXACT isotropic solid C12");
    CHECK(std::fabs(C.C44 - E / (2.0 * (1.0 + nu))) / (E / (2.0 * (1.0 + nu))) < 1e-12,
          "C(1) is the EXACT isotropic solid C44");
  }

  if (g_failures == 0) std::printf("test_lattice_density_field: OK\n");
  return g_failures == 0 ? 0 : 1;
}
