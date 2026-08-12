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
#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/materials.hpp"
#include "topopt/voxel.hpp"

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
    CHECK(!mid[0].refusal.empty() &&
              mid[0].refusal.find("VALIDITY RANGE") != std::string::npos &&
              mid[0].refusal.find("BUILDABLE AND UNCERTIFIABLE") != std::string::npos,
          "the refusal must name what is wrong in words a receipt can quote");
    CHECK(mid[0].min_member_width_certifiable_mm > 5.0,
          "and it must carry the number a user acts on: the thinnest member that "
          "COULD clear the floor at this nozzle");

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
