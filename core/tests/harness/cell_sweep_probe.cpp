// SWEPT CELL SIZE — the measurement harness (handoff 2026-08-01-lattice-cell-size-sweep).
//
// Read-only. Drives the PRODUCTION law (grading.hpp -> cell_plan.hpp -> lattice_gen.hpp's
// multilevel pass) on a part that really carries a 4 -> 8 mm transition, and measures the
// bars the feature stands on:
//
//   R2  CELL-INVARIANCE OF THE TENSOR, on the PRODUCTION path: octet_relative_density and
//       lattice_cubic_tensor queried at the same r/L across cell sizes. (The physics
//       itself is measured by graded_cell_size_probe's C1 section, re-run for this task;
//       this section proves the SHIPPED lookup carries that invariance, which is the part
//       a swept posture actually depends on.)
//   R3  STRUTS STAY PRINTABLE EVERYWHERE — per CELL, not per part. Minimum strut width
//       across the swept part + the count of cells raised to the printability floor.
//   R4  THE TRANSITION IS SOUND AND MEASURED — a real 4 -> 8 mm seam, checked for
//       FLOATING STRUT ENDS (PR 250's bar: every emitted strut endpoint must be covered
//       by another emitted solid) and for the LOCAL DENSITY ERROR at the seam, measured
//       by voxelizing the emitted geometry rather than trusting the analytic volumes.
//   R5  CELLS-PER-MEMBER PER REGION — the per-level report, with out-of-regime flags.
//
// Section gate: TOPOPT_CSW_ONLY=r2|r3|r4|r5 (default: all). CSV sink:
// TOPOPT_LATTICE_CSV_DIR.

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

#include "topopt/cell_plan.hpp"
#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"
#include "topopt/mesh.hpp"
#include "topopt/voxel.hpp"

using namespace topopt;

namespace {

int g_fail = 0;
void CHECK(bool ok, const char* what) {
  std::printf("    [%s] %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) ++g_fail;
}

FILE* csv_open(const char* name) {
  const char* dir = std::getenv("TOPOPT_LATTICE_CSV_DIR");
  if (!dir || !*dir) return nullptr;
  std::string p = std::string(dir) + "/" + name;
  FILE* f = std::fopen(p.c_str(), "w");
  if (f) std::printf("  [csv] %s\n", p.c_str());
  return f;
}

bool section(const char* name) {
  const char* only = std::getenv("TOPOPT_CSW_ONLY");
  return !only || !*only || std::strcmp(only, name) == 0;
}

// A sink that keeps nothing — the emitted primitives are captured via the observer,
// which is what the connectivity measurement needs (segments + radii, not triangles).
struct CountingSink : TriangleSink {
  std::uint64_t n = 0;
  void add_triangle(const Vec3&, const Vec3&, const Vec3&) override { ++n; }
};

struct Prim {
  Vec3 a, b;
  double r;
  bool is_strut;  // a ball reports a == b
};

double dot3(const Vec3& u, const Vec3& v) { return u.x * v.x + u.y * v.y + u.z * v.z; }
Vec3 sub3(const Vec3& u, const Vec3& v) { return {u.x - v.x, u.y - v.y, u.z - v.z}; }
double len3(const Vec3& u) { return std::sqrt(dot3(u, u)); }

// Distance from point p to segment [a,b].
double point_seg(const Vec3& p, const Vec3& a, const Vec3& b) {
  const Vec3 ab = sub3(b, a);
  const double L2 = dot3(ab, ab);
  double t = L2 > 0.0 ? dot3(sub3(p, a), ab) / L2 : 0.0;
  t = std::max(0.0, std::min(1.0, t));
  const Vec3 q{a.x + t * ab.x, a.y + t * ab.y, a.z + t * ab.z};
  return len3(sub3(p, q));
}

// ── the fixture: a THREE-ZONE plate that makes BOTH bounds bite ─────────────────
// A plate whose THICKNESS (the local member width — the cells-per-member ceiling) and
// whose DEMAND (the density, and so the printability floor) both vary along x, chosen
// so all three outcomes of the level law appear in one part:
//
//   zone A  x in [0, 32)   thick 24 mm, HIGH demand
//           ceiling allows only the 4 mm cell; the dense struts print there anyway
//           -> LEVEL 0.
//   zone B  x in [32, 64)  thick 56 mm, LOW demand
//           the sparse struts need the 8 mm cell to stay printable, and the thick
//           member has room for it -> LEVEL 1.  ** the 4 -> 8 mm SEAM is at x = 32 **
//   zone C  x in [64, 96)  thick 24 mm, VERY LOW demand
//           printability wants a cell COARSER than the ceiling allows: the two bounds
//           CROSS, so nothing here can be both printed and homogenized and the law
//           leaves it SOLID. The honest fallback, measured rather than assumed.
//
// This is the shape the Phase-0 study (PR 235) predicted: cell size has to be tied to
// the LOCAL MEMBER WIDTH, not to density alone, because a thin rib and a thick boss
// cannot share one schedule.
struct Fixture {
  VoxelGrid grid;
  std::vector<double> density, demand;
};

Fixture make_three_zone_plate(double spacing, int nx, int ny, int nz) {
  Fixture F;
  F.grid.nx = nx; F.grid.ny = ny; F.grid.nz = nz;
  F.grid.spacing = spacing;
  F.grid.origin = {0.0, 0.0, 0.0};
  // voxel_count() IS tags.size(), so the tag array has to be sized first.
  F.grid.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Empty);
  F.density.assign(F.grid.voxel_count(), 0.0);
  F.demand.assign(F.grid.voxel_count(), 0.0);
  const double Lx = nx * spacing, Ly = ny * spacing;
  for (int k = 0; k < nz; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < nx; ++i) {
        const double x = (i + 0.5) * spacing, y = (j + 0.5) * spacing;
        double thick, dem;
        if (x < Lx / 3.0)        { thick = 24.0; dem = 1.00; }
        else if (x < 2 * Lx / 3.0) { thick = 56.0; dem = 0.13; }
        else                     { thick = 24.0; dem = 0.02; }
        if (std::fabs(y - 0.5 * Ly) > 0.5 * thick) continue;  // outside the plate
        const std::size_t e = F.grid.index(i, j, k);
        F.grid.tags[e] = VoxelTag::Interior;
        F.density[e] = 1.0;
        F.demand[e] = dem;
      }
  return F;
}

}  // namespace

// ============================ R2 — the SHIPPED lookup is cell-invariant ============
void R2_production_lookup() {
  std::printf("\n===== R2 — the PRODUCTION lookup is cell-size invariant =====\n");
  std::printf("  TOLERANCE, stated first: relative deviation <= 1e-9 on rho and on each\n"
              "  of C11/C12/C44, across cell sizes at a fixed strut-to-cell RATIO.\n\n");
  FILE* csv = csv_open("r2_production_lookup.csv");
  if (csv) std::fprintf(csv, "ratio_r_over_L,cell_mm,strut_radius_mm,rho,C11,C12,C44,"
                             "rho_rel_dev,C11_rel_dev,C12_rel_dev,C44_rel_dev\n");
  const double Es = 3500.0;
  const std::vector<double> cells = {2.0, 4.0, 8.0, 16.0, 32.0};
  double worst = 0.0;
  for (double ratio : {0.06, 0.10, 0.14, 0.18}) {
    std::printf("  r/L = %.2f\n", ratio);
    std::printf("    %-9s %-11s %-9s %-11s %-11s %-11s\n", "cell_mm", "strut_r_mm",
                "rho", "C11", "C12", "C44");
    double rho0 = 0, c110 = 0, c120 = 0, c440 = 0;
    for (std::size_t i = 0; i < cells.size(); ++i) {
      const double L = cells[i], r = ratio * L;
      const double rho = octet_relative_density(L, r);
      const CubicTensor C = lattice_cubic_tensor(LatticeTopology::Octet, rho, Es);
      if (i == 0) { rho0 = rho; c110 = C.C11; c120 = C.C12; c440 = C.C44; }
      const double dr = std::fabs(rho - rho0) / rho0;
      const double d1 = std::fabs(C.C11 - c110) / c110;
      const double d2 = std::fabs(C.C12 - c120) / c120;
      const double d4 = std::fabs(C.C44 - c440) / c440;
      worst = std::max({worst, dr, d1, d2, d4});
      std::printf("    %-9.1f %-11.4f %-9.5f %-11.4f %-11.4f %-11.4f\n", L, r, rho,
                  C.C11, C.C12, C.C44);
      if (csv)
        std::fprintf(csv, "%.2f,%.1f,%.4f,%.8f,%.6f,%.6f,%.6f,%.3e,%.3e,%.3e,%.3e\n",
                     ratio, L, r, rho, C.C11, C.C12, C.C44, dr, d1, d2, d4);
    }
  }
  if (csv) std::fclose(csv);
  std::printf("\n  worst relative deviation across a 16x cell range = %.3e\n", worst);
  CHECK(worst <= 1e-9,
        "R2: rho and C11/C12/C44 are cell-size invariant to 1e-9 on the shipped path");
  std::printf("  READ: the library is keyed on RELATIVE DENSITY, and relative density is a\n"
              "  RATIO of strut volume to cell volume, so it cannot see the cell size. A\n"
              "  swept cell therefore perturbs the certification solve by exactly nothing.\n");
}

// ============================ R3 / R5 — the swept plan, per region =================
void R3_R5_plan(const char* label, double min_cell, double max_cell, double min_width,
                FILE* csv) {
  std::printf("\n  --- %s: sweep %.1f -> %.1f mm, min extrudable width %.2f mm ---\n",
              label, min_cell, max_cell, min_width);
  Fixture F = make_three_zone_plate(1.0, 96, 64, 64);

  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.cell_mode = CellSizeMode::Swept;
  gp.min_cell_size_mm = min_cell;
  gp.max_cell_size_mm = max_cell;
  gp.min_extrudable_width_mm = min_width;
  gp.demand_exponent = 1.0;
  const GradedField gf =
      grade_lattice(F.grid, F.density, F.demand, nullptr, gp);
  const CellSizePlan& P = gf.cell_plan;

  std::printf("    candidates %zu, latticed %zu, solid fallback %zu\n",
              gf.region_voxels, gf.latticed_voxels, gf.solid_fallback_voxels);
  std::printf("    base cell %.2f mm, levels 0..%d, octree cells %lld\n",
              P.base_cell_mm, P.max_level, P.latticed_cells);
  std::printf("    rho used %.4f .. %.4f;  cells-per-member floor N* = %.1f\n",
              gf.rho_min_used, gf.rho_max_used, P.cells_per_member_floor);

  // ── R3: printability, enforced PER CELL ──────────────────────────────────────
  std::printf("\n    R3 — printability across the swept part:\n");
  std::printf("      min strut width       = %.4f mm  (stated minimum %.2f mm)\n",
              gf.min_strut_diameter_mm, min_width);
  std::printf("      max strut width       = %.4f mm\n", gf.max_strut_diameter_mm);
  std::printf("      cells raised to floor = %lld of %lld (%.1f%%)\n",
              P.cells_raised_to_floor, P.latticed_cells,
              P.latticed_cells ? 100.0 * P.cells_raised_to_floor / P.latticed_cells : 0.0);
  std::printf("      cells dropped (no printable cell inside the ceiling) = %lld\n",
              P.cells_dropped_unprintable);
  std::printf("      cells split by 2:1 balance = %lld\n", P.cells_split_by_balance);
  CHECK(gf.latticed_voxels == 0 || gf.min_strut_diameter_mm >= min_width,
        "R3: EVERY emitted strut is at or above the stated minimum extrudable width");
  CHECK(!gf.any_strut_below_min, "R3: the below-minimum tripwire never fired");

  // ── R5: cells-per-member reported PER REGION (per cell-size level) ───────────
  std::printf("\n    R5 — cells-per-member per region (a region = one cell size):\n");
  std::printf("      %-7s %-10s %-10s %-11s %-13s %-13s %-11s %s\n", "level", "cell_mm",
              "cells", "voxels", "min_member_mm", "min_cells/mem", "min_strut", "regime");
  bool regime_ok = true;
  for (const CellLevelReport& r : P.levels) {
    const bool inf_w = !std::isfinite(r.min_member_width_mm);
    std::printf("      %-7d %-10.2f %-10lld %-11lld %-13s %-13.2f %-11.4f %s\n", r.level,
                r.cell_size_mm, r.cells, r.voxels,
                inf_w ? ">cap" : (std::to_string(r.min_member_width_mm).substr(0, 8)).c_str(),
                r.min_cells_per_member, r.min_strut_diameter_mm,
                r.out_of_regime ? "OUT OF REGIME" : "in regime");
    if (r.out_of_regime) regime_ok = false;
    if (csv)
      std::fprintf(csv, "%s,%d,%.2f,%lld,%lld,%.4f,%.4f,%.4f,%.4f,%d,%d\n", label,
                   r.level, r.cell_size_mm, r.cells, r.voxels,
                   inf_w ? -1.0 : r.min_member_width_mm, r.min_cells_per_member,
                   r.min_strut_diameter_mm, r.max_strut_diameter_mm,
                   r.out_of_regime ? 1 : 0, r.any_strut_below_min ? 1 : 0);
  }
  CHECK(regime_ok, "R5: every emitted region clears the cells-per-member floor");
  CHECK(!P.any_out_of_regime, "R5: the part-level out-of-regime tripwire never fired");
}

void R3_R5_sections() {
  std::printf("\n===== R3 / R5 — per-cell printability and per-region regime =====\n");
  FILE* csv = csv_open("r3_r5_per_region.csv");
  if (csv) std::fprintf(csv, "case,level,cell_mm,cells,voxels,min_member_mm,"
                             "min_cells_per_member,min_strut_mm,max_strut_mm,"
                             "out_of_regime,strut_below_min\n");
  R3_R5_plan("sweep_4_8", 4.0, 8.0, 0.8, csv);
  R3_R5_plan("sweep_4_16", 4.0, 16.0, 0.8, csv);
  R3_R5_plan("sweep_2_8_wide", 2.0, 8.0, 0.6, csv);
  if (csv) std::fclose(csv);
}

// ============================ R4 — the transition, measured =======================
void R4_transition() {
  std::printf("\n===== R4 — the 4 -> 8 mm transition: connectivity + seam density =====\n");
  Fixture F = make_three_zone_plate(1.0, 96, 64, 64);
  const double min_width = 0.8;

  GradingLawParams gp;
  gp.topology = LatticeTopology::Octet;
  gp.cell_mode = CellSizeMode::Swept;
  gp.min_cell_size_mm = 4.0;
  gp.max_cell_size_mm = 8.0;
  gp.min_extrudable_width_mm = min_width;
  const GradedField gf = grade_lattice(F.grid, F.density, F.demand, nullptr, gp);
  const CellSizePlan& P = gf.cell_plan;

  int n_levels = 0;
  for (const CellLevelReport& r : P.levels) if (r.cells > 0) ++n_levels;
  std::printf("  plan: base %.1f mm, %d occupied level(s), %lld octree cells\n",
              P.base_cell_mm, n_levels, P.latticed_cells);
  CHECK(n_levels >= 2, "R4: the fixture really does carry MORE THAN ONE cell size");

  // ── generate every level into one sink, tapping the observer ────────────────
  std::vector<Prim> prims;
  LatticeGenObserver obs;
  obs.on_element = [&prims](LatticeGenElement kind, const Vec3& a, const Vec3& b,
                            double r) {
    prims.push_back({a, b, r, kind == LatticeGenElement::InteriorStrut});
  };

  LatticeRegion base;
  base.origin = F.grid.origin;
  base.cell_mm = P.base_cell_mm;
  base.nx = P.nx; base.ny = P.ny; base.nz = P.nz;

  std::vector<LatticeLevelSpec> specs;
  for (const CellLevelReport& lr : P.levels) {
    if (lr.cells == 0) continue;
    LatticeLevelSpec s;
    s.level = lr.level;
    s.cell_mm = lr.cell_size_mm;
    const int L = lr.level;
    const CellSizePlan* pp = &P;
    // A cell of THIS level is latticed iff the base cell at its min corner carries
    // this level (the octree is aligned, so the min corner decides the whole block).
    s.latticed = [pp, L](int ci, int cj, int ck) {
      const int bi = ci << L, bj = cj << L, bk = ck << L;
      if (bi >= pp->nx || bj >= pp->ny || bk >= pp->nz) return false;
      return static_cast<int>(pp->level[pp->index(bi, bj, bk)]) == L;
    };
    // This level's radius field: the graded density at the point, at THIS cell.
    const VoxelGrid* g = &F.grid;
    const std::vector<double>* rho = &gf.posture.relative_density;
    const std::vector<char>* mask = &gf.posture.mask;
    const double cell = lr.cell_size_mm;
    const double rlo = gf.band_rho_min;
    s.radius.nseg = 8;
    s.radius.uniform_mm = 0.5 * octet_strut_diameter_mm(rlo, cell);
    s.radius.field = [g, rho, mask, cell, rlo](Vec3 p) {
      const int i = std::min(g->nx - 1, std::max(0, (int)std::floor(p.x / g->spacing)));
      const int j = std::min(g->ny - 1, std::max(0, (int)std::floor(p.y / g->spacing)));
      const int k = std::min(g->nz - 1, std::max(0, (int)std::floor(p.z / g->spacing)));
      const std::size_t e = g->index(i, j, k);
      const double rr = (*mask)[e] ? (*rho)[e] : rlo;
      return 0.5 * octet_strut_diameter_mm(rr, cell);
    };
    specs.push_back(s);
  }

  CountingSink sink;
  const LatticeGenStats st = generate_lattice_multilevel(
      LatticeGenTopology::Octet, base, specs, sink, LatticeSkinSpec{}, &obs);
  std::printf("  emitted: %llu struts, %llu nodes, %llu triangles across %d levels\n",
              (unsigned long long)st.struts, (unsigned long long)st.nodes,
              (unsigned long long)st.triangles, n_levels);
  std::printf("  strut diameters %.4f .. %.4f mm\n", st.min_strut_diameter_mm,
              st.max_strut_diameter_mm);
  CHECK(st.struts > 0, "R4: the multilevel pass emitted geometry");

  // ── (a) FLOATING STRUT ENDS (PR 250's bar) ──────────────────────────────────
  // Every emitted strut ENDPOINT must sit inside some OTHER emitted solid. A bucketed
  // grid keeps this exact and affordable.
  const double bucket = 8.0;
  auto key = [bucket](const Vec3& p) {
    return std::make_tuple((int)std::floor(p.x / bucket), (int)std::floor(p.y / bucket),
                           (int)std::floor(p.z / bucket));
  };
  std::vector<std::vector<int>> cells_idx;
  std::vector<std::tuple<int, int, int>> keys;
  auto bucket_of = [&](const std::tuple<int, int, int>& k) {
    for (std::size_t i = 0; i < keys.size(); ++i)
      if (keys[i] == k) return (int)i;
    keys.push_back(k);
    cells_idx.emplace_back();
    return (int)keys.size() - 1;
  };
  // Bucket by every cell the primitive's bbox touches (radius-padded).
  for (std::size_t i = 0; i < prims.size(); ++i) {
    const Prim& p = prims[i];
    const double lo[3] = {std::min(p.a.x, p.b.x) - p.r, std::min(p.a.y, p.b.y) - p.r,
                          std::min(p.a.z, p.b.z) - p.r};
    const double hi[3] = {std::max(p.a.x, p.b.x) + p.r, std::max(p.a.y, p.b.y) + p.r,
                          std::max(p.a.z, p.b.z) + p.r};
    for (int bx = (int)std::floor(lo[0] / bucket); bx <= (int)std::floor(hi[0] / bucket); ++bx)
      for (int by = (int)std::floor(lo[1] / bucket); by <= (int)std::floor(hi[1] / bucket); ++by)
        for (int bz = (int)std::floor(lo[2] / bucket); bz <= (int)std::floor(hi[2] / bucket); ++bz)
          cells_idx[bucket_of(std::make_tuple(bx, by, bz))].push_back((int)i);
  }
  auto covered_by_other = [&](const Vec3& pt, int self) {
    for (int dx = -1; dx <= 1; ++dx)
      for (int dy = -1; dy <= 1; ++dy)
        for (int dz = -1; dz <= 1; ++dz) {
          const auto k = std::make_tuple((int)std::floor(pt.x / bucket) + dx,
                                         (int)std::floor(pt.y / bucket) + dy,
                                         (int)std::floor(pt.z / bucket) + dz);
          int bi = -1;
          for (std::size_t i = 0; i < keys.size(); ++i)
            if (keys[i] == k) { bi = (int)i; break; }
          if (bi < 0) continue;
          for (int j : cells_idx[bi]) {
            if (j == self) continue;
            const Prim& q = prims[j];
            // The n=8 prism is an INNER approximation of the cylinder: its narrowest
            // half-width is r*cos(pi/8). Judge coverage on that inscribed radius, so
            // "covered" means covered by the real emitted solid, never by the
            // circumscribed ideal.
            if (point_seg(pt, q.a, q.b) <= q.r * std::cos(M_PI / 8.0)) return true;
          }
        }
    return false;
  };
  long long floating = 0, endpoints = 0;
  double worst_gap = 0.0;
  Vec3 worst_at{0, 0, 0};
  for (std::size_t i = 0; i < prims.size(); ++i) {
    if (!prims[i].is_strut) continue;
    for (int e = 0; e < 2; ++e) {
      const Vec3 pt = e == 0 ? prims[i].a : prims[i].b;
      ++endpoints;
      if (!covered_by_other(pt, (int)i)) {
        ++floating;
        if (worst_gap == 0.0) worst_at = pt;
        worst_gap = 1.0;
      }
    }
  }
  std::printf("\n  (a) connectivity across the transition:\n");
  std::printf("      strut endpoints checked = %lld\n", endpoints);
  std::printf("      FLOATING ends           = %lld\n", floating);
  if (floating > 0)
    std::printf("      first floating end at (%.3f, %.3f, %.3f)\n", worst_at.x,
                worst_at.y, worst_at.z);
  CHECK(floating == 0,
        "R4: ZERO floating strut ends across the whole swept part (PR 250's bar)");

  // Endpoints that lie exactly ON a seam (a coarse-cell node coinciding with a fine
  // node) are the interesting ones — count them so the bar is not vacuous.
  {
    long long seam_pts = 0;
    const double S0 = P.base_cell_mm;
    for (const Prim& p : prims) {
      if (!p.is_strut) continue;
      for (int e = 0; e < 2; ++e) {
        const Vec3 pt = e == 0 ? p.a : p.b;
        // On a level-1 node position (a multiple of the coarse half-cell) — i.e. a
        // point where the two levels can meet.
        const double h = S0;  // level-1 half-cell == level-0 cell
        auto near_mult = [h](double v) {
          return std::fabs(v / h - std::round(v / h)) < 1e-6;
        };
        if (near_mult(pt.x) && near_mult(pt.y) && near_mult(pt.z)) ++seam_pts;
      }
    }
    std::printf("      endpoints on shared (coarse-node) positions = %lld\n", seam_pts);
    CHECK(seam_pts > 0,
          "R4: the check is not vacuous — endpoints really do land on shared nodes");
  }

  // ── (b) LOCAL DENSITY ERROR AT THE SEAM ─────────────────────────────────────
  // Voxelize the EMITTED solid (the real interpenetrating union — overlaps counted
  // ONCE, which the analytic per-primitive volumes cannot do) and compare the local
  // solid fraction against the density the certification posture CLAIMS there.
  //
  // Three things the measurement has to get right or the number is meaningless:
  //   * SAMPLE WHOLE CELLS. A window narrower than the local cell aliases the octet's
  //     own sub-cell structure (a slab through a cell's dense mid-plane reads high, one
  //     on the cell boundary reads low). Slabs are one COARSEST cell wide, which is a
  //     whole number of cells at every level.
  //   * STAY INSIDE THE LATTICED SET. Only measurement voxels whose design voxel is
  //     actually latticed are counted, so the plate's free surface and the solid
  //     fallback zone do not dilute the fraction.
  //   * BRACKET THE PRISM. The emitted strut is an n=8 prism, an INNER approximation
  //     of the cylinder the density library is defined on. Its incircle is r*cos(pi/8)
  //     and its circumcircle is r, so the true emitted density is bracketed by the two
  //     — reported as a band rather than a single false-precision number.
  std::printf("\n  (b) local density error at the seam (voxelized emitted solid):\n");
  const double vs = 0.25;  // measurement voxel (mm)
  const int mx = (int)std::ceil(F.grid.nx * F.grid.spacing / vs);
  const int my = (int)std::ceil(F.grid.ny * F.grid.spacing / vs);
  const int mz = (int)std::ceil(F.grid.nz * F.grid.spacing / vs);
  std::vector<unsigned char> sol_in((std::size_t)mx * my * mz, 0);   // incircle
  std::vector<unsigned char> sol_out((std::size_t)mx * my * mz, 0);  // circumcircle
  auto midx = [mx, my](int i, int j, int k) {
    return ((std::size_t)k * my + j) * mx + i;
  };
  for (const Prim& p : prims) {
    const double rin = p.r * std::cos(M_PI / 8.0), rout = p.r;
    const int i0 = std::max(0, (int)std::floor((std::min(p.a.x, p.b.x) - rout) / vs));
    const int i1 = std::min(mx - 1, (int)std::ceil((std::max(p.a.x, p.b.x) + rout) / vs));
    const int j0 = std::max(0, (int)std::floor((std::min(p.a.y, p.b.y) - rout) / vs));
    const int j1 = std::min(my - 1, (int)std::ceil((std::max(p.a.y, p.b.y) + rout) / vs));
    const int k0 = std::max(0, (int)std::floor((std::min(p.a.z, p.b.z) - rout) / vs));
    const int k1 = std::min(mz - 1, (int)std::ceil((std::max(p.a.z, p.b.z) + rout) / vs));
    for (int k = k0; k <= k1; ++k)
      for (int j = j0; j <= j1; ++j)
        for (int i = i0; i <= i1; ++i) {
          const Vec3 c{(i + 0.5) * vs, (j + 0.5) * vs, (k + 0.5) * vs};
          const double d = point_seg(c, p.a, p.b);
          if (d <= rout) sol_out[midx(i, j, k)] = 1;
          if (d <= rin) sol_in[midx(i, j, k)] = 1;
        }
  }

  FILE* csv = csv_open("r4_seam_density.csv");
  if (csv) std::fprintf(csv, "x_lo_mm,x_hi_mm,cell_mm,emitted_rho_lo,emitted_rho_hi,"
                             "claimed_rho,rel_err_lo_pct,rel_err_hi_pct,in_bracket,"
                             "is_seam\n");
  // Slab width = the coarsest cell in the plan, so every slab spans whole cells at
  // every level.
  double slabw = P.base_cell_mm;
  for (const CellLevelReport& r : P.levels)
    if (r.cells > 0) slabw = std::max(slabw, r.cell_size_mm);
  const int nslab = (int)std::floor(F.grid.nx * F.grid.spacing / slabw);
  std::printf("      slab width = %.1f mm (the coarsest cell), measured only over\n"
              "      LATTICED voxels; emitted density bracketed by the prism's in/circum radius\n\n",
              slabw);
  std::printf("      %-14s %-8s %-19s %-13s %-14s %s\n", "x span (mm)", "cell",
              "emitted rho (band)", "claimed rho", "rel err (band)", "");
  double worst_bulk = 0.0, worst_seam = 0.0;
  int seam_slabs = 0, out_of_bracket = 0;
  // Per-slab record, so the SEAM can be judged against the bulk of its OWN cell size
  // (see the two-pass verdict below).
  struct Slab { double cell, emit, claim; bool seam; };
  std::vector<Slab> slabs;
  std::vector<double> slab_cell(nslab, 0.0);
  for (int s = 0; s < nslab; ++s) {
    // The cell size in this slab: the coarsest level any latticed voxel of the slab
    // carries (0 if the slab holds no lattice at all).
    double c = 0.0;
    for (int k = 0; k < F.grid.nz; ++k)
      for (int j = 0; j < F.grid.ny; ++j)
        for (int i = (int)(s * slabw / F.grid.spacing);
             i < (int)((s + 1) * slabw / F.grid.spacing) && i < F.grid.nx; ++i) {
          const std::size_t e = F.grid.index(i, j, k);
          if (gf.posture.mask[e] && !gf.posture.cell_size_field.empty())
            c = std::max(c, gf.posture.cell_size_field[e]);
        }
    slab_cell[s] = c;
  }
  for (int s = 0; s < nslab; ++s) {
    if (slab_cell[s] <= 0.0) continue;
    const double x0 = s * slabw, x1 = x0 + slabw;
    long long tot = 0, si = 0, so = 0;
    double claim_sum = 0.0;
    for (int k = 0; k < mz; ++k)
      for (int j = 0; j < my; ++j)
        for (int i = (int)(x0 / vs); i < (int)(x1 / vs) && i < mx; ++i) {
          // The design voxel this measurement voxel sits in — counted only when the
          // posture actually lattices it.
          const int di = std::min(F.grid.nx - 1, (int)((i + 0.5) * vs / F.grid.spacing));
          const int dj = std::min(F.grid.ny - 1, (int)((j + 0.5) * vs / F.grid.spacing));
          const int dk = std::min(F.grid.nz - 1, (int)((k + 0.5) * vs / F.grid.spacing));
          const std::size_t e = F.grid.index(di, dj, dk);
          if (!gf.posture.mask[e]) continue;
          ++tot;
          claim_sum += gf.posture.relative_density[e];
          if (sol_in[midx(i, j, k)]) ++si;
          if (sol_out[midx(i, j, k)]) ++so;
        }
    if (tot == 0) continue;
    const double emit_lo = (double)si / (double)tot;
    const double emit_hi = (double)so / (double)tot;
    const double claimed = claim_sum / (double)tot;
    const bool is_seam =
        (s > 0 && slab_cell[s - 1] > 0 && slab_cell[s - 1] != slab_cell[s]) ||
        (s + 1 < nslab && slab_cell[s + 1] > 0 && slab_cell[s + 1] != slab_cell[s]);
    // The error is 0 when the claim falls inside the prism bracket; otherwise it is
    // the distance to the nearer end of the bracket.
    const bool inside = claimed >= emit_lo && claimed <= emit_hi;
    const double rel =
        inside ? 0.0
               : 100.0 *
                     std::min(std::fabs(claimed - emit_lo), std::fabs(claimed - emit_hi)) /
                     claimed;
    if (!inside) ++out_of_bracket;
    if (is_seam) { worst_seam = std::max(worst_seam, rel); ++seam_slabs; }
    else worst_bulk = std::max(worst_bulk, rel);
    slabs.push_back({slab_cell[s], 0.5 * (emit_lo + emit_hi), claimed, is_seam});
    std::printf("      %5.1f - %-6.1f %-8.1f %6.4f .. %-10.4f %-13.4f %-14.1f %s\n", x0,
                x1, slab_cell[s], emit_lo, emit_hi, claimed, rel,
                is_seam ? "<- SEAM" : "");
    if (csv)
      std::fprintf(csv, "%.2f,%.2f,%.2f,%.5f,%.5f,%.5f,%.3f,%.3f,%d,%d\n", x0, x1,
                   slab_cell[s], emit_lo, emit_hi, claimed,
                   100.0 * std::fabs(claimed - emit_lo) / claimed,
                   100.0 * std::fabs(claimed - emit_hi) / claimed, inside ? 1 : 0,
                   is_seam ? 1 : 0);
  }
  if (csv) std::fclose(csv);
  std::printf("\n      seam slabs = %d;  slabs whose claim fell OUTSIDE the prism bracket = %d\n",
              seam_slabs, out_of_bracket);

  // ── the emitted-vs-claimed OFFSET is a PRE-EXISTING labelling gap, not a seam
  //    effect. lattice.hpp records it: the shipped "octet" density/tensor rows were
  //    measured on LEGS-ONLY geometry (fc<->corner), while the production generator
  //    meshes the FULL octet — legs PLUS the 12 octahedral braces, exactly 2.00x the
  //    strut volume per cell (verified analytically alongside this harness). It is
  //    present identically at a FIXED cell size and has nothing to do with sweeping,
  //    so it is REPORTED here and excluded from the seam verdict rather than folded
  //    into it. Reporting it per level is what makes that visible.
  std::printf("\n      emitted-vs-claimed offset per level (the documented legs-only\n"
              "      labelling gap of lattice.hpp, PRE-EXISTING and cell-size independent):\n");
  for (const CellLevelReport& lr : P.levels) {
    if (lr.cells == 0) continue;
    double se = 0, sc = 0; int nb = 0;
    for (const Slab& s : slabs)
      if (s.cell == lr.cell_size_mm) { se += s.emit; sc += s.claim; ++nb; }
    if (nb == 0) continue;
    std::printf("        cell %5.1f mm: emitted %.4f vs claimed %.4f  (%+.1f%%, over %d slabs)\n",
                lr.cell_size_mm, se / nb, sc / nb, 100.0 * (se / nb - sc / nb) / (sc / nb), nb);
  }

  // ── THE SEAM VERDICT: does the TRANSITION itself perturb the local density? ────
  // Each seam slab is compared against the mean of the BULK (non-seam) slabs OF ITS
  // OWN CELL SIZE, which cancels everything that is a property of the cell size
  // rather than of the transition.
  std::printf("\n      seam vs the bulk of its OWN cell size (the transition's own error):\n");
  double worst_seam_vs_own = 0.0;
  int judged = 0;
  for (const Slab& s : slabs) {
    if (!s.seam) continue;
    double se = 0; int nb = 0;
    for (const Slab& b : slabs)
      if (!b.seam && b.cell == s.cell) { se += b.emit; ++nb; }
    if (nb == 0) {
      std::printf("        cell %5.1f mm seam slab: no same-size bulk slab to compare\n", s.cell);
      continue;
    }
    const double bulk = se / nb;
    const double dev = 100.0 * std::fabs(s.emit - bulk) / bulk;
    std::printf("        cell %5.1f mm: seam %.4f vs same-size bulk %.4f  -> %.2f%%\n",
                s.cell, s.emit, bulk, dev);
    worst_seam_vs_own = std::max(worst_seam_vs_own, dev);
    ++judged;
  }
  std::printf("\n      worst seam deviation from its own level's bulk = %.2f%%\n",
              worst_seam_vs_own);
  CHECK(seam_slabs > 0, "R4: the fixture produced a real seam to measure");
  CHECK(judged > 0, "R4: at least one seam slab had a same-size bulk slab to judge against");
  CHECK(worst_seam_vs_own <= 10.0,
        "R4: the transition perturbs local density by <= 10% of its own level's bulk");
  std::printf("      READ: a shared-node dyadic transition should add no material and remove\n"
              "      none — the coarse and fine cells simply tile different volumes. What is\n"
              "      left is the ordinary sampling difference between a slab at a seam and a\n"
              "      slab in the bulk, which is what this number bounds.\n");
}

int main() {
  std::printf("=== SWEPT CELL SIZE — measurement harness ===\n");
  if (section("r2")) R2_production_lookup();
  if (section("r3") || section("r5")) R3_R5_sections();
  if (section("r4")) R4_transition();
  std::printf("\n=== %s (%d failed check%s) ===\n", g_fail ? "FAILURES" : "ALL CHECKS PASSED",
              g_fail, g_fail == 1 ? "" : "s");
  return g_fail ? 1 : 0;
}
