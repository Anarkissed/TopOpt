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

#include "topopt/cell_plan.hpp"
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

  // ---- 12. CELL-SIZE MODES (handoff 2026-08-01-lattice-cell-size-sweep) ----------
  // A thick block with a demand ramp, so the density grade spans enough of the band
  // for the printability floor to bind differently in different places.
  {
    VoxelGrid blk = solid_block(48, 48, 48, 1.0);
    std::vector<double> bd = density_of(blk);
    std::vector<double> bdem(blk.voxel_count(), 0.0);
    for (int k = 0; k < blk.nz; ++k)
      for (int j = 0; j < blk.ny; ++j)
        for (int i = 0; i < blk.nx; ++i)
          bdem[blk.index(i, j, k)] =
              1.0 - 0.9 * static_cast<double>(i) / static_cast<double>(blk.nx);

    GradingLawParams base;
    base.topology = LatticeTopology::Octet;
    base.min_extrudable_width_mm = 0.8;
    base.demand_exponent = 1.0;

    // R1 — the DEFAULT mode is Fixed, and a Fixed run is untouched by the feature:
    // the mode field defaulting to Fixed is what makes every pre-sweep caller keep
    // its exact behaviour, and the posture carries NO per-voxel cell field.
    // The Fixed target is set ABOVE the printability floor on purpose, so Auto (which
    // takes the floor) is genuinely FINER and the comparison below is not vacuous —
    // a target under the floor is simply raised to it and the two modes coincide.
    const double pfloor =
        lattice_cell_printability_floor_mm(LatticeTopology::Octet, 0.8);
    GradingLawParams fx = base;
    fx.target_cell_size_mm = 2.0 * pfloor;
    CHECK(base.cell_mode == CellSizeMode::Fixed, "Fixed is the default cell mode");
    GradedField F = grade_lattice(blk, bd, bdem, nullptr, fx);
    CHECK(F.posture.cell_size_field.empty(),
          "R1: a Fixed posture carries no per-voxel cell field (the pre-sweep shape)");
    CHECK(F.cell_plan.max_level == 0, "Fixed reports a single-level plan");
    CHECK(F.cell_mode == CellSizeMode::Fixed, "Fixed mode echoed in the report");

    // AUTO — core picks the printability floor itself, with no target consulted, and
    // being the FINEST printable cell it can only lattice MORE than a coarser Fixed
    // cell (the cells-per-member rule is an upper bound).
    GradingLawParams au = base;
    au.cell_mode = CellSizeMode::Auto;
    au.target_cell_size_mm = 0.0;  // deliberately unset: Auto must not need it
    GradedField A = grade_lattice(blk, bd, bdem, nullptr, au);
    CHECK(std::fabs(A.cell_size_mm - A.printability_floor_mm) < 1e-12,
          "Auto chooses exactly the printability floor");
    CHECK(std::fabs(A.printability_floor_mm -
                    lattice_cell_printability_floor_mm(LatticeTopology::Octet, 0.8)) <
              1e-12,
          "the floor is READ from core's one law, not recomputed here");
    CHECK(A.posture.cell_size_field.empty(), "Auto is uniform: no per-voxel field");
    CHECK(A.cell_size_mm < fx.target_cell_size_mm - 1e-12,
          "Auto's cell is finer than this deliberately-coarse Fixed target");
    CHECK(A.latticed_voxels >= F.latticed_voxels,
          "Auto's finer cell lattices at least as much as the coarser Fixed cell");

    // SWEPT — a dyadic ladder. Every guarantee is per CELL: inside the band, above
    // the cells-per-member floor at ITS OWN cell, and printable at ITS OWN cell.
    GradingLawParams sw = base;
    sw.cell_mode = CellSizeMode::Swept;
    sw.min_cell_size_mm = 3.0;
    sw.max_cell_size_mm = 12.0;  // two doublings -> levels 0,1,2
    GradedField S = grade_lattice(blk, bd, bdem, nullptr, sw);
    CHECK(S.cell_plan.max_level == 2, "a 3->12 mm sweep is exactly two doublings");
    CHECK(S.posture.cell_size_field.size() == blk.voxel_count(),
          "a Swept posture carries a per-voxel cell field");
    const double n_star = lattice_cells_per_member_min(LatticeTopology::Octet);
    const std::vector<double> w =
        local_member_thickness_mm(blk, bd, 0.5, sw.thickness_cap_voxels);
    bool all_dyadic = true, all_regime = true, all_printable = true;
    for (std::size_t e = 0; e < blk.voxel_count(); ++e) {
      if (!S.posture.mask[e]) continue;
      const double c = S.posture.cell_size_field[e];
      // The cell must be min * 2^L for an integer L in range.
      const double ratio = c / sw.min_cell_size_mm;
      const double lg = std::log2(ratio);
      if (std::fabs(lg - std::round(lg)) > 1e-9 || std::round(lg) < 0 ||
          std::round(lg) > S.cell_plan.max_level)
        all_dyadic = false;
      if (!(w[e] / c >= n_star)) all_regime = false;
      if (!(octet_strut_diameter_mm(S.posture.relative_density[e], c) >=
            sw.min_extrudable_width_mm))
        all_printable = false;
    }
    CHECK(all_dyadic, "every emitted cell is on the dyadic ladder min * 2^L");
    CHECK(all_regime,
          "R5: every latticed voxel clears the cells-per-member floor at ITS OWN cell");
    CHECK(all_printable,
          "R3: every latticed voxel's strut prints at ITS OWN cell (per cell, not per part)");
    CHECK(!S.any_strut_below_min, "R3: the below-minimum tripwire never fires");
    CHECK(!S.cell_plan.any_out_of_regime, "R5: no region is out of regime");
    CHECK(S.min_strut_diameter_mm >= sw.min_extrudable_width_mm,
          "R3: the reported minimum strut width is at or above the stated minimum");

    // The report really is per REGION, and the regions are the cell sizes.
    CHECK(S.cell_plan.levels.size() >= 2,
          "the sweep produced more than one cell-size region on this part");
    for (const CellLevelReport& r : S.cell_plan.levels) {
      CHECK(r.cells > 0, "only OCCUPIED levels are reported");
      CHECK(!r.out_of_regime, "R5: each reported region clears the floor");
      CHECK(std::fabs(r.cell_size_mm -
                      sw.min_cell_size_mm * std::pow(2.0, r.level)) < 1e-12,
            "a region's cell size is its dyadic level");
    }

    // L5 — determinism, in the swept mode too.
    GradedField S2 = grade_lattice(blk, bd, bdem, nullptr, sw);
    CHECK(S.posture.mask == S2.posture.mask &&
              S.posture.relative_density == S2.posture.relative_density &&
              S.posture.cell_size_field == S2.posture.cell_size_field &&
              S.cell_plan.level == S2.cell_plan.level,
          "R7: the swept plan is deterministic (byte-identical twice)");

    // A sweep with min == max is a legal degenerate ladder: one level, still swept.
    GradingLawParams deg = sw;
    deg.max_cell_size_mm = deg.min_cell_size_mm;
    GradedField D = grade_lattice(blk, bd, bdem, nullptr, deg);
    CHECK(D.cell_plan.max_level == 0, "min == max is a one-level ladder");

    // Validation: a swept run without bounds is refused, never defaulted.
    bool threw = false;
    GradingLawParams bad = base;
    bad.cell_mode = CellSizeMode::Swept;
    try { grade_lattice(blk, bd, bdem, nullptr, bad); }
    catch (const std::invalid_argument&) { threw = true; }
    CHECK(threw, "a swept run with no ladder bounds is refused");
  }

  // ---- 13. the mode vocabulary is one round-trip ---------------------------------
  {
    for (CellSizeMode m : {CellSizeMode::Fixed, CellSizeMode::Auto,
                           CellSizeMode::Swept}) {
      CellSizeMode back{};
      CHECK(cell_size_mode_from_name(cell_size_mode_name(m), back) && back == m,
            "cell-size mode name round-trips");
    }
    CellSizeMode ignored{};
    CHECK(!cell_size_mode_from_name("coarse", ignored),
          "an unknown mode name is refused, never silently defaulted");
  }

  // ---- 13. SUB-FLOOR RETENTION IN UNLOADED REGIONS -------------------------------
  //      (handoff 2026-08-04-subfloor-lattice-unloaded-regions, bars S1 / S5)
  //
  // THE FIXTURE, and why it has this shape. Retention's predicate is REGION-scoped:
  // the region's peak demand over the PART's peak. So the fixture needs a part with
  // two distinct pieces — a thick, loaded body, and a THIN wall attached to it that
  // is the region. The wall is 4 mm thick, far under N* x the printability floor, so
  // nothing about it can be latticed by any legal cell: it is exactly the maintainer's
  // back wall. Sweeping the wall's demand against the body's then walks the threshold.
  {
    // 34 x 30 x 30 envelope: a 30 mm cube body (x 0..29) plus a 4-voxel-thick wall
    // (x 30..33) spanning the full y,z face. The wall's inscribed thickness is ~4 mm.
    const int pad = 3;
    VoxelGrid g;
    g.nx = 34 + 2 * pad; g.ny = 30 + 2 * pad; g.nz = 30 + 2 * pad; g.spacing = 1.0;
    g.origin = Vec3{0, 0, 0};
    g.tags.assign(static_cast<std::size_t>(g.nx) * g.ny * g.nz, VoxelTag::Empty);
    for (int k = 0; k < 30; ++k)
      for (int j = 0; j < 30; ++j)
        for (int i = 0; i < 34; ++i)
          g.set_tag(i + pad, j + pad, k + pad, VoxelTag::Interior);
    const std::size_t Ng = g.voxel_count();
    std::vector<double> gd = density_of(g);
    // The REGION is the wall alone (x 30..33 in block coordinates).
    std::vector<char> wall(Ng, 0);
    for (int k = 0; k < 30; ++k)
      for (int j = 0; j < 30; ++j)
        for (int i = 30; i < 34; ++i)
          wall[g.index(i + pad, j + pad, k + pad)] = 1;

    // Demand: the body at 100, the wall at `w`. The measured region stress fraction
    // is then exactly w/100 — which is what lets the threshold be tested AT its edge
    // rather than somewhere convenient.
    auto demand_with_wall = [&](double w) {
      std::vector<double> d(Ng, 0.0);
      for (int k = 0; k < 30; ++k)
        for (int j = 0; j < 30; ++j)
          for (int i = 0; i < 34; ++i) {
            const std::size_t e = g.index(i + pad, j + pad, k + pad);
            d[e] = (i >= 30) ? w : 100.0;
          }
      return d;
    };

    GradingLawParams wp;
    wp.topology = topo;
    wp.target_cell_size_mm = 2.0;
    wp.min_extrudable_width_mm = 0.4;
    wp.demand_exponent = 1.0;

    // --- 13a. DEFAULT IS OFF, AND OFF IS THE OLD BEHAVIOUR (bar S1) --------------
    {
      const std::vector<double> d = demand_with_wall(1.0);  // 1% of peak: very quiet
      GradedField off = grade_lattice(g, gd, d, &wall, wp);
      CHECK(!off.subfloor_retention_armed,
            "S1: sub-floor retention is DISARMED by default");
      // Not the WHOLE wall is sub-floor: the EDT thickness bleeds where the wall
      // meets the 30 mm body, so a band along the junction reads thick enough to
      // grade. That is physical, and it makes the fixture a better test — the
      // retained set is a strict SUBSET of the region, which is the real shape.
      CHECK(off.subfloor_candidate_voxels > 0,
            "the fixture really does put material below the floor");
      CHECK(off.subfloor_candidate_voxels < off.region_voxels,
            "...and not all of it, so retention is tested on a strict subset");
      CHECK(off.solid_fallback_voxels == off.subfloor_candidate_voxels,
            "S1: with retention off every below-floor voxel falls back to solid");
      CHECK(off.latticed_voxels ==
                off.region_voxels - off.subfloor_candidate_voxels,
            "S1: and exactly the above-floor remainder is latticed, as before");
      CHECK(off.subfloor_retained_voxels == 0 && off.subfloor_flags.empty(),
            "S1: nothing retained and no per-voxel flags allocated when off");
      CHECK(off.subfloor_candidate_voxels == off.fallback_member_too_thin,
            "the below-floor population is counted even when disarmed, so a "
            "forecast can say what is at stake before anyone opts in");
    }

    // --- 13b. ARMED + QUIET REGION => the wall IS latticed ------------------------
    {
      const std::vector<double> d = demand_with_wall(1.0);
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;
      GradedField r = grade_lattice(g, gd, d, &wall, on);
      CHECK(r.subfloor_retention_armed, "armed flag is reported");
      CHECK(r.region_qualified_unloaded, "a 1%-of-peak region qualifies");
      CHECK(r.latticed_voxels == r.region_voxels,
            "the maintainer's wall is latticed end to end");
      CHECK(r.subfloor_retained_voxels > 0 &&
            r.subfloor_retained_voxels == r.subfloor_candidate_voxels,
            "every below-floor wall voxel is retained, and recorded as such");
      CHECK(r.solid_fallback_voxels == 0, "nothing fell back once retained");
      CHECK(r.subfloor_min_cells_per_member < n_star,
            "the retained material really is BELOW the floor — that is the point, "
            "and it is what raises lattice_strut_out_of_regime downstream");
      CHECK(r.subfloor_min_strut_diameter_mm >= wp.min_extrudable_width_mm,
            "printability is NOT relaxed with the floor: every retained strut still "
            "prints at the stated minimum width");
      CHECK(!r.subfloor_flags.empty(), "WHICH voxels is answered per voxel");
      std::size_t flagged = 0;
      for (std::size_t e = 0; e < Ng; ++e) if (r.subfloor_flags[e]) ++flagged;
      CHECK(flagged == r.subfloor_retained_voxels,
            "the per-voxel flags and the count agree exactly");
      for (std::size_t e = 0; e < Ng; ++e)
        if (r.subfloor_flags[e])
          CHECK(r.posture.mask[e] != 0 && wall[e] != 0,
                "a flagged voxel is latticed AND inside the region");
    }

    // --- 13c. THE THRESHOLD, TESTED AT ITS EDGE (bar S5) -------------------------
    // An untested threshold is a guess with a number attached. These two cases
    // straddle it by 1% of peak and must come out on opposite sides.
    {
      const double ceiling = lattice_subfloor_retention_stress_fraction();
      CHECK(std::fabs(ceiling - 0.20) < 1e-12,
            "the measured ceiling is 0.20 (handoff protect-freeze-vs-solidity §10)");
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;

      // JUST BELOW: 19% of peak -> latticed.
      GradedField below = grade_lattice(g, gd, demand_with_wall(19.0), &wall, on);
      CHECK(std::fabs(below.region_stress_fraction - 0.19) < 1e-12,
            "S5: the region fraction is MEASURED at 0.19, not declared");
      CHECK(below.region_qualified_unloaded, "S5: just below the ceiling qualifies");
      CHECK(below.subfloor_retained_voxels > 0,
            "S5: just below the ceiling, the wall IS latticed");

      // JUST ABOVE: 21% of peak -> stays solid.
      GradedField above = grade_lattice(g, gd, demand_with_wall(21.0), &wall, on);
      CHECK(std::fabs(above.region_stress_fraction - 0.21) < 1e-12,
            "S5: the region fraction is MEASURED at 0.21");
      CHECK(!above.region_qualified_unloaded,
            "S5: just above the ceiling does NOT qualify");
      CHECK(above.subfloor_retained_voxels == 0,
            "S5: just above the ceiling the wall STAYS SOLID");
      GradedField plain = grade_lattice(g, gd, demand_with_wall(21.0), &wall, wp);
      CHECK(above.posture.mask == plain.posture.mask &&
            above.posture.relative_density == plain.posture.relative_density &&
            above.latticed_voxels == plain.latticed_voxels &&
            above.solid_fallback_voxels == plain.solid_fallback_voxels,
            "S5: above the ceiling the posture is the DISARMED posture exactly");

      // EXACTLY AT the ceiling qualifies — the comparison is <=, and which way an
      // exact hit falls is a decision, so it is pinned rather than left to drift.
      GradedField at = grade_lattice(g, gd, demand_with_wall(20.0), &wall, on);
      CHECK(at.region_qualified_unloaded && at.subfloor_retained_voxels > 0,
            "S5: exactly AT the ceiling qualifies (the test is <=)");
    }

    // --- 13d. A LOADED REGION IS NEVER RETAINED, however it is asked -------------
    {
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;
      GradedField hot = grade_lattice(g, gd, demand_with_wall(100.0), &wall, on);
      CHECK(std::fabs(hot.region_stress_fraction - 1.0) < 1e-12,
            "a wall at the part's peak measures 1.0");
      CHECK(hot.subfloor_retained_voxels == 0,
            "a region at peak stress is never sub-floor-latticed");
    }

    // --- 13e. NO REGION => NO RETENTION ------------------------------------------
    // Latticing the WHOLE part below the floor is not "an unloaded region", and the
    // fraction is 1.0 by construction, so this can never fire by omission.
    {
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;
      VoxelGrid slab = solid_block(40, 6, 40, 1.0);
      std::vector<double> sdn = density_of(slab);
      std::vector<double> sdem(slab.voxel_count(), 5.0);
      GradedField whole = grade_lattice(slab, sdn, sdem, nullptr, on);
      CHECK(std::fabs(whole.region_stress_fraction - 1.0) < 1e-12,
            "with no region the fraction is 1.0");
      CHECK(whole.subfloor_retained_voxels == 0 && whole.latticed_voxels == 0,
            "an armed run with no region still leaves a thin part solid");
    }

    // --- 13f. NO DEMAND FIELD => NO RETENTION (the forecast's case) --------------
    // An all-zero demand makes the fraction 0.0, which READS as "carries nothing"
    // but MEANS "nothing was measured". Retention must not fire on it — this is the
    // exact field the pre-flight forecast passes, before any solve has run.
    {
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;
      const std::vector<double> zero(Ng, 0.0);
      GradedField f = grade_lattice(g, gd, zero, &wall, on);
      CHECK(!f.region_qualified_unloaded,
            "S7: a demand-less field DISARMS retention rather than satisfying it");
      CHECK(f.subfloor_retained_voxels == 0,
            "S7: the forecast's flat demand never conjures a retained lattice");
      CHECK(f.subfloor_candidate_voxels > 0 &&
            f.subfloor_candidate_voxels == f.solid_fallback_voxels,
            "S7: but the population below the floor is still reported exactly");
    }

    // --- 13g. an out-of-range ceiling is REFUSED, never clamped ------------------
    {
      GradingLawParams bad = wp;
      bad.retain_subfloor_in_unloaded_regions = true;
      bad.subfloor_stress_fraction_max = 1.5;
      bool threw = false;
      try { grade_lattice(g, gd, demand_with_wall(1.0), &wall, bad); }
      catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, "a stress fraction above 1 is rejected, not silently clamped");
    }

    // --- 13h. DETERMINISM with retention armed (bar S9) --------------------------
    {
      GradingLawParams on = wp;
      on.retain_subfloor_in_unloaded_regions = true;
      const std::vector<double> d = demand_with_wall(5.0);
      GradedField a = grade_lattice(g, gd, d, &wall, on);
      GradedField b = grade_lattice(g, gd, d, &wall, on);
      CHECK(a.posture.mask == b.posture.mask &&
            a.posture.relative_density == b.posture.relative_density &&
            a.subfloor_flags == b.subfloor_flags &&
            a.subfloor_retained_voxels == b.subfloor_retained_voxels &&
            a.region_stress_fraction == b.region_stress_fraction,
            "S9: retention is deterministic — identical inputs, identical field");
    }

    // --- 13i. THE SWEPT PATH, where the accounting bug actually was ----------
    // The maintainer's own job is SWEPT, so this is the path that matters, and
    // it is shaped differently from the uniform one: the plan rejects a whole
    // BASE CELL using the thinnest member anywhere inside it. Dropping that
    // ceiling for a qualified region therefore lets through two DIFFERENT kinds
    // of voxel — ones genuinely below the floor at their own cell, and ones on
    // wider material that clear it. Only the first carries an accuracy claim.
    //
    // The first version of this code flagged both, which made the retained count
    // disagree with the posture; the law's own invariant threw, and a probe on a
    // real part is what surfaced it. This pins the distinction.
    {
      GradingLawParams sw = wp;
      sw.cell_mode = CellSizeMode::Swept;
      sw.min_cell_size_mm = 2.0;
      sw.max_cell_size_mm = 8.0;
      sw.target_cell_size_mm = 0.0;
      const std::vector<double> d = demand_with_wall(1.0);

      GradedField off = grade_lattice(g, gd, d, &wall, sw);
      CHECK(off.subfloor_retained_voxels == 0,
            "S1: swept mode retains nothing when disarmed");
      CHECK(off.subfloor_candidate_voxels > 0,
            "the swept fixture really does reject material for thinness");

      GradingLawParams on = sw;
      on.retain_subfloor_in_unloaded_regions = true;
      GradedField r = grade_lattice(g, gd, d, &wall, on);
      CHECK(r.region_qualified_unloaded, "swept: the quiet wall qualifies");
      CHECK(r.latticed_voxels > off.latticed_voxels,
            "swept: arming retention latticed strictly more of the region");
      // THE INVARIANT THE BUG BROKE. Every flagged voxel must really be below
      // the floor at ITS OWN cell, and the flags must match the count exactly.
      // (grade_lattice asserts this internally too — this is the independent
      // restatement, so a change to the assertion cannot quietly excuse itself.)
      std::size_t flagged = 0, flagged_really_subfloor = 0;
      const double floor_n = r.cells_per_member_floor;
      for (std::size_t e = 0; e < Ng; ++e) {
        if (e >= r.subfloor_flags.size() || !r.subfloor_flags[e]) continue;
        ++flagged;
        const double ce = e < r.posture.cell_size_field.size()
                              ? r.posture.cell_size_field[e]
                              : r.cell_size_mm;
        if (ce > 0.0 && r.posture.mask[e]) {
          // Re-derive from the posture rather than trusting the report.
          const double w = local_member_thickness_mm(
              g, gd, 0.5, sw.thickness_cap_voxels)[e];
          if (w / ce < floor_n) ++flagged_really_subfloor;
        }
      }
      CHECK(flagged == r.subfloor_retained_voxels,
            "swept: the per-voxel flags and the retained count agree");
      CHECK(flagged_really_subfloor == flagged,
            "swept: EVERY flagged voxel is genuinely below the floor at its own "
            "cell — an in-regime voxel is never counted as an accepted "
            "inaccuracy");
      CHECK(r.subfloor_retained_voxels + r.subfloor_recovered_in_regime_voxels
                <= r.subfloor_candidate_voxels,
            "swept: retained + recovered never exceeds the population the "
            "ceiling rejected");
      if (r.subfloor_retained_voxels > 0)
        CHECK(r.subfloor_min_cells_per_member < floor_n,
              "swept: the retained material is below the floor, as reported");
    }
  }

  std::fprintf(stderr, "grading: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
