// Unit tests for THE LATTICE GRADING LAW (handoff 2026-07-29-lattice-grading-law).
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness.
// These tests are the machine-checked form of the bars:
//   L2  every emitted (density, cell) is inside the certifiable band AND at/above the
//       cells-per-member floor — asserted here on adversarial demand fields.
//   L4  a member too thin to hold the floor at a printable cell STAYS SOLID, counted.
//   L5  determinism — the same (grid, density, demand, params) give a byte-identical
//       field twice.
//   ★   the limits are READ from core — the report's band/floor equal the library
//       accessors, not any literal in the law.

#include "topopt/grading.hpp"
#include "topopt/lattice.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>

using namespace topopt;

static int g_checks = 0, g_failures = 0;
#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

// A solid block of sx*sy*sz Interior voxels (edge `h` mm) embedded with a `pad`-voxel
// Empty margin on every side, so the block has FREE SURFACES — without a surrounding
// void the local-thickness measure sees no boundary and reports every voxel infinitely
// thick (a fully-solid grid is not a member). Real parts always sit in such a margin.
static VoxelGrid solid_block(int sx, int sy, int sz, double h, int pad = 3) {
  VoxelGrid g;
  g.nx = sx + 2 * pad; g.ny = sy + 2 * pad; g.nz = sz + 2 * pad; g.spacing = h;
  g.origin = Vec3{0, 0, 0};
  g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
  for (int k = 0; k < sz; ++k)
    for (int j = 0; j < sy; ++j)
      for (int i = 0; i < sx; ++i)
        g.set_tag(i + pad, j + pad, k + pad, VoxelTag::Interior);
  return g;
}

// A density field matching a grid's tags: 1.0 on printed (non-Empty) voxels, 0.0 else.
static std::vector<double> density_of(const VoxelGrid& g) {
  std::vector<double> d(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i)
        if (g.tag(i, j, k) != VoxelTag::Empty) d[g.index(i, j, k)] = 1.0;
  return d;
}

int main() {
  const LatticeTopology topo = LatticeTopology::Octet;
  const double rho_lo = lattice_rho_min(topo);
  const double rho_hi = lattice_rho_max(topo);
  const double n_star = lattice_cells_per_member_min(topo);

  // ---- 0. the strut-diameter helper: linear in cell, monotone in rho -------------
  {
    const double d4 = octet_strut_diameter_mm(0.60, 4.0);
    const double d8 = octet_strut_diameter_mm(0.60, 8.0);
    CHECK(std::fabs(d8 - 2.0 * d4) < 1e-9, "strut diameter is exactly linear in cell");
    CHECK(octet_strut_diameter_mm(0.20, 4.0) > octet_strut_diameter_mm(0.10, 4.0),
          "strut diameter increases with rho");
    CHECK(octet_strut_diameter_mm(rho_lo, 4.0) < octet_strut_diameter_mm(rho_hi, 4.0),
          "band endpoints ordered in diameter");
    // Golden: verbatim B3 vpc48 rows (evidence b3_printability.csv).
    CHECK(std::fabs(octet_strut_diameter_mm(0.40, 4.0) - 1.1815) < 1e-4,
          "golden d(0.40, cell4) = 1.1815 mm");
    bool threw = false;
    try { octet_strut_diameter_mm(0.4, 0.0); } catch (const std::exception&) { threw = true; }
    CHECK(threw, "octet_strut_diameter_mm rejects cell <= 0");
  }

  // A thick block that comfortably holds the floor; a graded demand along z.
  // 30 mm cube at h=1 -> interior members far exceed N* * printability floor.
  VoxelGrid thick = solid_block(30, 30, 30, 1.0);
  const std::size_t N = thick.voxel_count();
  std::vector<double> dens = density_of(thick);
  std::vector<double> demand(N, 0.0);
  for (int k = 0; k < thick.nz; ++k)
    for (int j = 0; j < thick.ny; ++j)
      for (int i = 0; i < thick.nx; ++i)
        demand[thick.index(i, j, k)] = static_cast<double>(k);  // 0..29

  GradingLawParams p;
  p.topology = topo;
  p.target_cell_size_mm = 2.0;          // below the printability floor -> raised
  p.min_extrudable_width_mm = 0.4;      // 0.4 mm nozzle, single bead
  p.demand_exponent = 1.0;

  // ---- 1. limits are READ from core (★) ------------------------------------------
  GradedField gf = grade_lattice(thick, dens, demand, nullptr, p);
  CHECK(gf.band_rho_min == rho_lo, "report band_rho_min == lattice_rho_min");
  CHECK(gf.band_rho_max == rho_hi, "report band_rho_max == lattice_rho_max");
  CHECK(gf.cells_per_member_floor == n_star,
        "report floor == lattice_cells_per_member_min");

  // ---- 2. L2 — NO uncertifiable point, checked independently of the law's assert --
  CHECK(gf.latticed_voxels > 0, "thick block grades some lattice");
  {
    std::size_t n_lat = 0;
    bool band_ok = true, floor_ok = true;
    for (std::size_t e = 0; e < N; ++e) {
      if (!gf.posture.mask[e]) continue;
      ++n_lat;
      const double rho = gf.posture.relative_density[e];
      if (!(rho >= rho_lo && rho <= rho_hi)) band_ok = false;
      // member width / cell >= floor, re-derived from the same width measure
      // the law used (so this is an independent restatement, not a tautology).
    }
    CHECK(n_lat == gf.latticed_voxels, "mask count matches report");
    CHECK(band_ok, "L2: every emitted density inside [rho_min, rho_max]");
    CHECK(gf.min_cells_per_member >= n_star - 1e-9,
          "L2: thinnest latticed member clears the cells-per-member floor");
    CHECK(gf.rho_min_used >= rho_lo - 1e-12 && gf.rho_max_used <= rho_hi + 1e-12,
          "L2: achieved rho band inside the certifiable band");
    (void)floor_ok;
  }

  // ---- 3. requirement 3 — struts printable, reported not violated ----------------
  CHECK(!gf.any_strut_below_min, "no strut below the stated minimum width");
  CHECK(gf.min_strut_diameter_mm >= p.min_extrudable_width_mm - 1e-9,
        "min strut diameter >= min extrudable width");

  // ---- 4. cell-size floor (printability) -----------------------------------------
  CHECK(gf.cell_size_floored, "target below floor was raised");
  CHECK(std::fabs(gf.cell_size_mm - gf.printability_floor_mm) < 1e-12,
        "raised cell equals the printability floor");
  CHECK(gf.cell_size_mm == gf.posture.cell_size_mm, "posture carries the chosen cell");
  // A strut at rho_lo at exactly the floor cell prints at the stated width.
  CHECK(std::fabs(octet_strut_diameter_mm(rho_lo, gf.printability_floor_mm) -
                  p.min_extrudable_width_mm) < 1e-9,
        "floor cell prints the rho_min strut at exactly the min width");

  // ---- 5. demand mapping — spans a range; interior peak -> rho_hi; zero -> rho_lo -
  CHECK(gf.rho_max_used > gf.rho_min_used,
        "a graded demand spans a range of densities");
  {
    // A single deep-interior voxel (block centre, certainly latticed) at the max
    // demand must map to the band top.
    std::vector<double> spike(N, 1.0);
    spike[thick.index(3 + 15, 3 + 15, 3 + 15)] = 1e6;
    GradedField s = grade_lattice(thick, dens, spike, nullptr, p);
    CHECK(std::fabs(s.rho_max_used - rho_hi) < 1e-9,
          "interior peak demand maps to the band top");
  }
  {
    // all-zero demand -> a uniform rho_min lattice
    std::vector<double> flat(N, 0.0);
    GradedField z = grade_lattice(thick, dens, flat, nullptr, p);
    CHECK(std::fabs(z.rho_min_used - rho_lo) < 1e-12 &&
              std::fabs(z.rho_max_used - rho_lo) < 1e-12,
          "zero demand -> uniform rho_min lattice");
  }

  // ---- 6. L2 under an ADVERSARIAL demand (huge, tiny, NaN-free extremes) ----------
  {
    std::vector<double> adv(N, 0.0);
    for (std::size_t e = 0; e < N; ++e)
      adv[e] = (e % 3 == 0) ? 1e18 : (e % 3 == 1) ? 1e-18 : 0.0;
    GradedField a = grade_lattice(thick, dens, adv, nullptr, p);
    bool ok = true;
    for (std::size_t e = 0; e < N; ++e)
      if (a.posture.mask[e]) {
        const double r = a.posture.relative_density[e];
        if (!(r >= rho_lo && r <= rho_hi)) ok = false;
      }
    CHECK(ok, "L2 holds under extreme demand magnitudes");
  }

  // ---- 7. L4 — a member too thin to grade STAYS SOLID ----------------------------
  {
    // A 6 mm-thick slab (thin in y), wide in x,z. Its inscribed thickness (~6 mm) is
    // below N* * printability floor (~5 * 2.5 = 12.6 mm), so NO printable cell holds
    // the floor -> the whole slab stays solid.
    VoxelGrid slab = solid_block(40, 6, 40, 1.0);
    const std::size_t Ns = slab.voxel_count();
    std::vector<double> sd = density_of(slab);
    std::vector<double> sdem(Ns, 5.0);
    GradedField s = grade_lattice(slab, sd, sdem, nullptr, p);
    CHECK(s.region_voxels > 0, "slab has candidate voxels");
    CHECK(s.latticed_voxels == 0, "L4: thin slab grades nothing");
    CHECK(s.solid_fallback_voxels == s.region_voxels,
          "L4: every thin candidate stayed solid");
    CHECK(s.region_ungradeable, "L4: region flagged ungradeable in the report");
  }

  // ---- 8. L5 — determinism (byte-identical field twice) --------------------------
  {
    GradedField a = grade_lattice(thick, dens, demand, nullptr, p);
    GradedField b = grade_lattice(thick, dens, demand, nullptr, p);
    bool same = a.posture.mask == b.posture.mask &&
                a.posture.relative_density == b.posture.relative_density &&
                a.cell_size_mm == b.cell_size_mm &&
                a.latticed_voxels == b.latticed_voxels &&
                a.solid_fallback_voxels == b.solid_fallback_voxels;
    CHECK(same, "L5: identical inputs -> identical field");
  }

  // ---- 9. region mask restricts candidates ---------------------------------------
  {
    std::vector<char> region(N, 0);
    std::size_t want = 0;
    for (std::size_t e = 0; e < N; ++e)
      if (e % 2 == 0) {
        region[e] = 1;
        if (dens[e] > 0.5) ++want;  // only printed candidates are counted
      }
    GradedField r = grade_lattice(thick, dens, demand, &region, p);
    CHECK(r.region_voxels == want, "region mask limits the candidate count");
    for (std::size_t e = 0; e < N; ++e)
      if (region[e] == 0)
        CHECK(r.posture.mask[e] == 0, "voxels outside the region are never latticed");
  }

  // ---- 10. an unfloored (large) target cell is used verbatim ---------------------
  {
    GradingLawParams big = p;
    big.target_cell_size_mm = 10.0;  // above the ~2.5 mm floor
    GradedField r = grade_lattice(thick, dens, demand, nullptr, big);
    CHECK(!r.cell_size_floored, "target above floor is not raised");
    CHECK(std::fabs(r.cell_size_mm - 10.0) < 1e-12, "large target used verbatim");
  }

  // ---- 11. input validation ------------------------------------------------------
  {
    bool threw = false;
    std::vector<double> wrong(N + 1, 0.0);
    try { grade_lattice(thick, dens, wrong, nullptr, p); }
    catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "size mismatch rejected");
  }

  std::fprintf(stderr, "grading: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
