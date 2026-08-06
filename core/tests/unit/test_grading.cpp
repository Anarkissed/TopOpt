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
  p.min_extrudable_width_mm = 0.4;      // 0.4 mm nozzle, single bead
  // ★ PINNED to the rho_min printability floor, and READ from core rather than
  // written as a number (task 2026-08-05-lattice-cell-fit-mode, S2). It used to be
  // 2.0 mm, which the pre-S2 law RAISED to exactly this value — so every assertion
  // below ran against this cell. S2 stops raising a target that some band density can
  // print at, so leaving 2.0 here would silently re-point a dozen unrelated bars at a
  // different cell. Pinning keeps them measuring what they were written to measure;
  // the raise itself is asserted directly in section 4.
  p.target_cell_size_mm = lattice_cell_printability_floor_mm(topo, 0.4);
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
  // TWO floors, and S2 is about which one BINDS a Fixed target:
  //   printability_floor_mm  = w / phi(rho_min) — the smallest cell printing the
  //       band's LIGHTEST strut. A bound, and still what AUTO selects.
  //   min_printable_cell_mm  = w / phi(rho_max) — the smallest cell at which ANY band
  //       density prints. Below it nothing is legal at any density; at or above it the
  //       density can be raised to suit. This is what a Fixed target is raised to.
  {
    // (a) A target UNDER the absolute floor is still raised, and still reported.
    GradingLawParams under = p;
    under.target_cell_size_mm = 0.5 * gf.min_printable_cell_mm;
    const GradedField U = grade_lattice(thick, dens, demand, nullptr, under);
    CHECK(U.cell_size_floored, "target below the binding floor was raised");
    CHECK(std::fabs(U.cell_size_mm - U.min_printable_cell_mm) < 1e-12,
          "raised cell equals the floor that binds");
    // (b) A target BETWEEN the two floors SURVIVES — the S2 fix. Before it, this
    // was silently raised to printability_floor_mm.
    GradingLawParams between = p;
    between.target_cell_size_mm =
        0.5 * (gf.min_printable_cell_mm + gf.printability_floor_mm);
    const GradedField B2 = grade_lattice(thick, dens, demand, nullptr, between);
    CHECK(!B2.cell_size_floored && std::fabs(B2.cell_size_mm -
                                             between.target_cell_size_mm) < 1e-12,
          "a target between the two floors is kept, not raised to the rho_min one");
    CHECK(B2.density_raised_for_print_voxels > 0,
          "and the DENSITY is raised instead, so the strut still prints");
  }
  CHECK(std::fabs(gf.cell_size_mm - gf.printability_floor_mm) < 1e-12,
        "the pinned target is exactly the rho_min floor");
  CHECK(gf.density_raised_for_print_voxels == 0,
        "at that cell the density raise is inert — the band floor already prints");
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
    wp.min_extrudable_width_mm = 0.4;
    // PINNED for the same reason as `p` above (S2): 2.0 mm used to be raised to
    // exactly this cell, and every exposure number quoted in the comments below —
    // 1,704 of 30,600 voxels, 5.57 % — was measured at it. Reading it from core keeps
    // the cap tests measuring the CAP rather than the cell law.
    wp.target_cell_size_mm = lattice_cell_printability_floor_mm(topo, 0.4);
    wp.demand_exponent = 1.0;
    // THE AGGREGATE CAP IS LIFTED FOR THE THRESHOLD TESTS BELOW, deliberately and
    // with the number stated. This fixture is a 30 mm block with a 4 mm wall bolted
    // to it, and that wall is 1,704 of the block's 30,600 printed voxels — 5.57 %,
    // well over the 3.0 % production cap. That ratio is an artefact of keeping the
    // fixture small, not a property of any real part (the maintainer's own wall is
    // 0.930 % of his). Left at the default, the cap would refuse retention here and
    // every threshold assertion below would pass for the WRONG REASON — they would
    // be measuring the cap, not the stress predicate. So it is lifted here and
    // tested on its own in 13j.
    wp.subfloor_aggregate_cap_fraction = 1.0;

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

    // --- 13j. THE AGGREGATE EXPOSURE CAP (lattice.hpp ★★★) --------------------
    // Per-region evaluation is a WIDENING: eight regions can qualify independently
    // and the material under an unpriceable accuracy claim multiplies. The cap is
    // the only thing that bounds the total, because the certification is blind to
    // cells-per-member and cannot price any of it. These assertions are what stop
    // the cap from being decorative.
    {
      GradingLawParams cap = wp;
      cap.retain_subfloor_in_unloaded_regions = true;
      // The cap is OPT-IN (0 = no cap), so ask for the core constant explicitly —
      // which is also what a caller that wants the production ceiling must do.
      cap.subfloor_aggregate_cap_fraction =
          lattice_subfloor_aggregate_cap_fraction();
      const std::vector<double> d = demand_with_wall(1.0);

      GradedField over = grade_lattice(g, gd, d, &wall, cap);
      CHECK(over.subfloor_aggregate_cap_fraction ==
                lattice_subfloor_aggregate_cap_fraction(),
            "the cap in force is READ FROM CORE, not hardcoded in the law");
      CHECK(over.subfloor_would_retain_voxels > 0,
            "the dry run counted what retention would have kept");
      CHECK(static_cast<double>(over.subfloor_would_retain_voxels) >
                over.subfloor_aggregate_cap_fraction *
                    static_cast<double>(over.part_printed_voxels),
            "this fixture really is over the production cap (5.57% of the block)");
      CHECK(over.subfloor_over_budget, "over the cap is REPORTED, not silent");
      CHECK(over.subfloor_retained_voxels == 0,
            "over the cap retains NOTHING — never 'as much as fits', because "
            "choosing which regions to sacrifice is a judgement nothing measures");
      CHECK(over.subfloor_retained_fraction_of_part == 0.0,
            "and the reported exposure is zero, because none was taken");

      // THE OVER-BUDGET RESULT IS THE DISARMED RESULT, exactly. A refusal that
      // still perturbed the posture would be a third behaviour nobody asked for.
      // AND THE DEFAULT IS NO CAP AT ALL: same job, cap left at 0, retains freely.
      GradingLawParams uncapped = cap;
      uncapped.subfloor_aggregate_cap_fraction = 0.0;
      const GradedField unc = grade_lattice(g, gd, d, &wall, uncapped);
      CHECK(!unc.subfloor_over_budget && unc.subfloor_retained_voxels > 0,
            "cap 0 means NO CAP — the ceiling is opt-in, not defaulted on");

      GradedField off = grade_lattice(g, gd, d, &wall, wp);   // wp: armed=false
      CHECK(over.posture.mask == off.posture.mask &&
            over.posture.relative_density == off.posture.relative_density &&
            over.latticed_voxels == off.latticed_voxels &&
            over.solid_fallback_voxels == off.solid_fallback_voxels,
            "an over-budget refusal leaves the posture byte-identical to disarmed");

      // AND THE CAP BINDS AT ITS EDGE, not merely somewhere. Set the cap just above
      // and just below the fraction this fixture actually needs.
      const double need = static_cast<double>(over.subfloor_would_retain_voxels) /
                          static_cast<double>(over.part_printed_voxels);
      GradingLawParams just_under = cap;
      just_under.subfloor_aggregate_cap_fraction = need * 0.99;
      CHECK(grade_lattice(g, gd, d, &wall, just_under).subfloor_over_budget,
            "a cap just BELOW what the job needs refuses");
      GradingLawParams just_over = cap;
      just_over.subfloor_aggregate_cap_fraction = need * 1.01;
      const GradedField ok = grade_lattice(g, gd, d, &wall, just_over);
      CHECK(!ok.subfloor_over_budget, "a cap just ABOVE what the job needs admits");
      CHECK(ok.subfloor_retained_voxels == over.subfloor_would_retain_voxels,
            "and admits EXACTLY what the dry run said it would — the count the cap "
            "bounded is the count that got emitted");
    }

    // --- 13k. PER-REGION EVALUATION (the widening this task adds) --------------
    // Two regions, one quiet and one loaded. Under the shipped UNION reading the
    // loud one vetoes both. Per region, the quiet one is retained and the loud one
    // is not — which is the whole point, and also strictly more material under the
    // accuracy claim, which is why 13j exists.
    {
      // Split the wall in two along z: the LOW half stays quiet, the HIGH half is
      // driven to the part's peak.
      std::vector<int> ids(Ng, 0);
      std::vector<char> both(Ng, 0);
      for (int k = 0; k < 30; ++k)
        for (int j = 0; j < 30; ++j)
          for (int i = 30; i < 34; ++i) {
            const std::size_t e = g.index(i + pad, j + pad, k + pad);
            both[e] = 1;
            ids[e] = (k < 15) ? 1 : 2;      // 1 = quiet half, 2 = loud half
          }
      std::vector<double> d(Ng, 0.0);
      for (int k = 0; k < 30; ++k)
        for (int j = 0; j < 30; ++j)
          for (int i = 0; i < 34; ++i) {
            const std::size_t e = g.index(i + pad, j + pad, k + pad);
            d[e] = (i < 30) ? 100.0 : (k < 15 ? 1.0 : 100.0);
          }

      GradingLawParams uni = wp;
      uni.retain_subfloor_in_unloaded_regions = true;
      const GradedField u = grade_lattice(g, gd, d, &both, uni);
      CHECK(!u.region_qualified_unloaded && u.subfloor_retained_voxels == 0,
            "UNION: the loud half vetoes the quiet one — nothing retained");

      GradingLawParams per = uni;
      per.region_ids = &ids;
      const GradedField r = grade_lattice(g, gd, d, &both, per);
      CHECK(r.subfloor_regions.size() == 2, "both declared regions are reported");
      const GradedField::SubfloorRegion* q = nullptr;
      const GradedField::SubfloorRegion* l = nullptr;
      for (const GradedField::SubfloorRegion& x : r.subfloor_regions) {
        if (x.region_id == 1) q = &x;
        if (x.region_id == 2) l = &x;
      }
      CHECK(q != nullptr && l != nullptr, "the report is keyed by the caller's ids");
      CHECK(q->qualified && !l->qualified,
            "PER REGION: the quiet half qualifies and the loud half does not — the "
            "predicate is answered per region, not for their union");
      CHECK(std::fabs(q->stress_fraction - 0.01) < 1e-12,
            "the quiet half's fraction is MEASURED (1 of 100), not declared");
      CHECK(std::fabs(l->stress_fraction - 1.0) < 1e-12,
            "the loud half measures at the part's peak");
      CHECK(r.subfloor_retained_voxels > 0 && r.subfloor_retained_voxels == q->retained_voxels,
            "everything retained came from the QUALIFYING region");
      CHECK(l->retained_voxels == 0, "and nothing from the loud one");
      CHECK(r.subfloor_retained_voxels < u.subfloor_candidate_voxels,
            "per region retains a strict SUBSET of the union's below-floor set");
      for (std::size_t e = 0; e < Ng; ++e)
        if (e < r.subfloor_flags.size() && r.subfloor_flags[e])
          CHECK(ids[e] == 1, "no retained voxel came from the loud region");
      // The aggregate is reported, and it is the number the cap bounds.
      CHECK(r.part_printed_voxels > 0 &&
            std::fabs(r.subfloor_retained_fraction_of_part -
                      static_cast<double>(r.subfloor_retained_voxels) /
                          static_cast<double>(r.part_printed_voxels)) < 1e-12,
            "the aggregate exposure is reported as a fraction of the PRINTED set");
    }
  }

  // ---- 14. THE PER-MEMBER CELL DERIVATION (task lattice-cell-size-adaptation,
  //          Stage A) ----------------------------------------------------------
  // The shipped printability floor is evaluated at rho_min, so N* x it is the
  // "23 mm member" the maintainer was told he needed. The derivation answers the
  // same question per MEMBER, at the density that member can actually carry.
  {
    const double w = 0.42;  // the maintainer's nozzle
    const double phi_lo = octet_strut_diameter_mm(rho_lo, 1.0);
    const double phi_hi = octet_strut_diameter_mm(rho_hi, 1.0);

    // The number that was quoted, and the number that is true — both derived here
    // from core's own constants, so a change to the band or the table moves both.
    const double quoted_floor_mm = n_star * (w / phi_lo);
    const double real_floor_mm = n_star * (w / phi_hi);
    CHECK(std::fabs(quoted_floor_mm - 23.0131) < 1e-3,
          "the QUOTED requirement reproduces: N* x floor(rho_min) = 23.0131 mm");
    CHECK(std::fabs(real_floor_mm - 5.4748) < 1e-3,
          "the REAL requirement is N* x floor(rho_max) = 5.4748 mm");
    CHECK(real_floor_mm < quoted_floor_mm,
          "deriving per member is a WIDENING — it never demands a thicker member");

    // (a) A member ABOVE the frontier: the window exists and both ends are legal.
    {
      const LatticeCellDerivation d =
          lattice_derive_cell_for_member(topo, 8.0, w);
      CHECK(d.feasible, "an 8 mm member IS latticeable at a 0.42 mm nozzle");
      CHECK(std::fabs(d.min_member_width_mm - real_floor_mm) < 1e-9,
            "min_member_width_mm is N* x the smallest printable cell");
      CHECK(std::fabs(d.max_homogenizable_cell_mm - 8.0 / n_star) < 1e-12,
            "the coarse bound is exactly W / N*");
      // BOTH ends must satisfy BOTH constraints — this is the whole contract.
      CHECK(d.densest_strut_diameter_mm >= w - 1e-9,
            "finest end: the strut still prints");
      CHECK(d.lightest_strut_diameter_mm >= w - 1e-9,
            "coarsest end: the strut still prints");
      CHECK(d.densest_cells_per_member >= n_star - 1e-9,
            "finest end: at or above the cells-per-member floor");
      CHECK(std::fabs(d.lightest_cells_per_member - n_star) < 1e-9,
            "coarsest end sits EXACTLY on the floor, by construction");
      CHECK(d.densest_relative_density >= rho_lo - 1e-12 &&
            d.densest_relative_density <= rho_hi + 1e-12,
            "finest end's density is inside the certifiable band");
      CHECK(d.lightest_relative_density >= rho_lo - 1e-12 &&
            d.lightest_relative_density <= rho_hi + 1e-12,
            "coarsest end's density is inside the certifiable band");
      CHECK(d.lightest_relative_density <= d.densest_relative_density + 1e-12,
            "the coarse end is the LIGHTER of the two — that is why it is offered");
      CHECK(d.lightest_cell_size_mm >= d.densest_cell_size_mm - 1e-12,
            "and the coarser of the two");
      // 8 mm at N* = 5 gives a 1.6 mm cell; the lightest strut that prints there
      // needs phi >= 0.42/1.6 = 0.2625, which the measured table reaches near
      // rho 0.32 — well inside the band, i.e. a genuinely LIGHT lattice.
      CHECK(std::fabs(d.lightest_cell_size_mm - 1.6) < 1e-12,
            "8 mm / 5 = a 1.6 mm cell");
      CHECK(d.lightest_relative_density < 0.40,
            "and it certifies at under rho 0.40 — not a near-solid lattice");
    }

    // (b) THE MAINTAINER'S BACK WALL: 4 mm. Below the frontier, so the honest
    // answer is that NO pair fits — with the number he must reach to change that.
    {
      const LatticeCellDerivation d =
          lattice_derive_cell_for_member(topo, 4.0, w);
      CHECK(!d.feasible,
            "a 4 mm wall does NOT hold a certified lattice at a 0.42 mm nozzle");
      CHECK(d.min_member_width_mm > 4.0,
            "and the report says so by naming a floor above the measured width");
      CHECK(std::fabs(d.min_member_width_mm - 5.4748) < 1e-3,
            "the thinnest wall that WOULD work is 5.4748 mm — the actionable number");
      CHECK(d.max_homogenizable_cell_mm < d.min_printable_cell_mm,
            "the two bounds CROSS, which is the arithmetic that rules it out");
      CHECK(d.densest_cell_size_mm == 0.0 && d.lightest_cell_size_mm == 0.0,
            "no window is reported when none exists — never a fabricated pair");
    }

    // (c) EXACTLY ON the frontier: feasible, and the two ends coincide. This is the
    // floating-point edge where the frontier cell's strut is w to the last ULP.
    {
      const LatticeCellDerivation d =
          lattice_derive_cell_for_member(topo, real_floor_mm, w);
      CHECK(d.feasible, "the frontier width itself is feasible, not off-by-one");
      CHECK(d.densest_relative_density > 0.0 && d.lightest_relative_density > 0.0,
            "and neither end leaks the negative no-answer sentinel");
      CHECK(std::fabs(d.densest_cell_size_mm - d.lightest_cell_size_mm) < 1e-9,
            "at the frontier the window collapses to a point");
    }

    // (d) The "thicker than the EDT cap" sentinel is not a crash and not a refusal.
    {
      const LatticeCellDerivation d = lattice_derive_cell_for_member(
          topo, std::numeric_limits<double>::infinity(), w);
      CHECK(d.feasible, "an infinitely thick member is trivially latticeable");
      CHECK(std::isinf(d.max_homogenizable_cell_mm),
            "nothing bounds its cell from above, and the report says so");
      CHECK(std::isfinite(d.lightest_cell_size_mm) &&
            std::fabs(d.lightest_cell_size_mm - d.densest_cell_size_mm) < 1e-12,
            "so both ends collapse onto the printability frontier, finite");
    }

    // (e) MONOTONICITY — a thicker member is never harder to lattice, and its
    // minimum-mass density never rises. The property the whole widening rests on.
    {
      double prev_rho = 2.0;
      for (double W = 5.5; W <= 40.0; W += 0.5) {
        const LatticeCellDerivation d = lattice_derive_cell_for_member(topo, W, w);
        CHECK(d.feasible, "every member above the frontier is feasible");
        CHECK(d.lightest_relative_density <= prev_rho + 1e-9,
              "a thicker member never needs a HEAVIER minimum-mass lattice");
        prev_rho = d.lightest_relative_density;
        CHECK(d.lightest_strut_diameter_mm >= w - 1e-9,
              "and its strut prints at every width on the ladder");
      }
    }

    // (f) The floor is READ, never assumed: pass a what-if N* and the frontier moves
    // with it, proportionally. (A what-if, not a relaxation — nothing certified
    // calls this with a floor below the shipped one.)
    {
      const LatticeCellDerivation a = lattice_derive_cell_for_member(topo, 8.0, w);
      const LatticeCellDerivation b =
          lattice_derive_cell_for_member(topo, 8.0, w, 2.0 * n_star);
      CHECK(std::fabs(b.min_member_width_mm - 2.0 * a.min_member_width_mm) < 1e-9,
            "doubling the cells-per-member floor doubles the required width");
      CHECK(std::fabs(a.cells_per_member_floor - n_star) < 1e-12,
            "and the default is core's own floor, not a literal");
    }

    // (g) The strut-diameter inverse is a true inverse where it answers, and refuses
    // where it cannot — the property `feasible` is built on.
    {
      for (double cell : {0.5, 1.0, 1.0950, 2.0, 4.0, 8.0}) {
        const double r = lattice_min_density_for_strut(topo, cell, w);
        if (r < 0.0) {
          CHECK(octet_strut_diameter_mm(rho_hi, cell) < w,
                "a negative answer means even the band ceiling cannot print here");
        } else {
          CHECK(r >= rho_lo - 1e-12 && r <= rho_hi + 1e-12,
                "an answer is always inside the certifiable band");
          CHECK(octet_strut_diameter_mm(r, cell) >= w - 1e-9,
                "and the density it names really does print at that cell");
          if (r > rho_lo + 1e-6)
            CHECK(octet_strut_diameter_mm(r - 1e-4, cell) < w,
                  "it is the LIGHTEST such density — one notch down fails");
        }
      }
      bool threw = false;
      try { lattice_derive_cell_for_member(topo, -1.0, w); }
      catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, "a non-positive member width is refused, not defaulted");
      threw = false;
      try {
        lattice_derive_cell_for_member(
            topo, std::numeric_limits<double>::quiet_NaN(), w);
      } catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, "a NaN member width is refused, never read as 'thick enough'");
    }
  }

  // ==========================================================================
  // FIT MODE + THE PRINTABILITY-FLOOR OVERRIDE
  // (task 2026-08-05-lattice-cell-fit-mode, bars R3 / S1 / S2 / S3)
  //
  // THE DEFECT THESE ASSERT AGAINST, stated as arithmetic so the numbers are
  // checkable by hand at a 0.42 mm bead (the maintainer's declared bead):
  //     phi(rho_min) = 0.091252  =>  floor cell = 0.42/phi = 4.6026 mm
  //     phi(rho_max) = 0.383575  =>  finest printable cell = 0.42/phi = 1.0950 mm
  //     N* = 5  =>  4.6026 mm needs 23.0131 mm of member; 1.0950 mm needs 5.4748 mm
  // A 4 mm wall holds NEITHER at N*, but it holds 3.65 cells at the finest printable
  // cell — buildable, out of regime — and today AUTO hands it a 4.6026 mm cell and
  // lattices nothing.
  // ==========================================================================
  {
    const double w_bead = 0.42;
    const double floor_cell =
        lattice_cell_printability_floor_mm(topo, w_bead);            // 4.6026
    const double finest_cell =
        w_bead / octet_strut_diameter_mm(rho_hi, 1.0);               // 1.0950
    CHECK(std::fabs(floor_cell - 4.6026) < 1e-3,
          "FIT0: the rho_min floor is 4.6026 mm at a 0.42 mm bead");
    CHECK(std::fabs(finest_cell - 1.0950) < 1e-3,
          "FIT0: the finest printable cell is 1.0950 mm at the same bead");
    CHECK(finest_cell ==
              lattice_derive_cell_for_member(topo, 4.0, w_bead).min_printable_cell_mm,
          "FIT0: and it is core's own number, not a second derivation here");

    // A 4 mm WALL — his geometry. 0.5 mm voxels, 8 deep.
    const VoxelGrid wall = solid_block(40, 40, 8, 0.5);
    const std::vector<double> wd = density_of(wall);
    // A demand field with ONE hot voxel and a quiet remainder — the realistic shape,
    // and the one that exercises the joint (cell, rho) solve: the quiet material's
    // demand density is far under what the derived cell can print, so the law has to
    // raise it rather than emit a strut under the bead.
    std::vector<double> wdem(wall.voxel_count(), 0.0);
    wdem[wall.index(3 + 20, 3 + 20, 3 + 4)] = 1.0;
    const std::vector<double> ww =
        local_member_thickness_mm(wall, wd, 0.5, 32);

    GradingLawParams base;
    base.topology = topo;
    base.min_extrudable_width_mm = w_bead;
    base.demand_exponent = 1.0;

    // ── FIT1 — THE DEFECT, ASSERTED. AUTO plans the rho_min floor and lattices
    // NOTHING in a 4 mm wall. This is what the maintainer's job does today, and it
    // passes on unfixed code: it is the "before" half of bar R3.
    GradingLawParams au = base;
    au.cell_mode = CellSizeMode::Auto;
    const GradedField A = grade_lattice(wall, wd, wdem, nullptr, au);
    CHECK(std::fabs(A.cell_size_mm - floor_cell) < 1e-9,
          "FIT1: AUTO plans the 4.6026 mm rho_min floor in a 4 mm wall");
    CHECK(A.latticed_voxels == 0,
          "FIT1: and lattices NOTHING there — 4 mm / 4.6026 mm = 0.87 cells");
    CHECK(A.region_voxels > 0, "FIT1 is not vacuous: there were candidates");

    // ── FIT2 — FIT derives max(extent/N*, finest printable) = 1.0950 mm here and
    // DOES lattice. This is the "after" half of R3 and it cannot pass on unfixed
    // code, where the mode does not exist.
    const double want = std::max(4.0 / n_star, finest_cell);
    CHECK(std::fabs(want - finest_cell) < 1e-12,
          "FIT2: a 4 mm wall cannot hold N* cells, so the finest printable cell wins");
    std::vector<double> wfit(wall.voxel_count(), 0.0);
    for (std::size_t e = 0; e < wall.voxel_count(); ++e)
      if (wd[e] > 0.5) wfit[e] = want;
    GradingLawParams fi = base;
    fi.cell_mode = CellSizeMode::Fit;
    fi.fit_cell_size_mm = &wfit;
    const GradedField Fi = grade_lattice(wall, wd, wdem, nullptr, fi);
    CHECK(std::fabs(Fi.cell_size_mm - want) < 1e-9,
          "FIT2: FIT plans the 1.0950 mm derived cell, not the 4.6026 mm floor");
    CHECK(Fi.latticed_voxels > 0, "FIT2: and it lattices the 4 mm wall");
    CHECK(Fi.latticed_voxels > A.latticed_voxels,
          "FIT2: strictly more than AUTO, which is the point of the mode");
    CHECK(Fi.posture.cell_size_field.size() == wall.voxel_count(),
          "FIT2: a fit posture carries a per-voxel cell field");
    // EVERY strut prints, and every latticed voxel is honestly stamped.
    bool all_print = true, all_band = true, all_percolate = true;
    for (std::size_t e = 0; e < wall.voxel_count(); ++e) {
      if (!Fi.posture.mask[e]) continue;
      const double c = Fi.posture.cell_size_field[e];
      const double r = Fi.posture.relative_density[e];
      if (octet_strut_diameter_mm(r, c) < w_bead - 1e-9) all_print = false;
      if (r < rho_lo - 1e-12 || r > rho_hi + 1e-12) all_band = false;
      if (ww[e] / c < lattice_percolation_cells_per_member_min(topo) - 1e-9)
        all_percolate = false;
    }
    CHECK(all_print, "FIT2: every emitted strut is at or above the stated bead");
    CHECK(all_band, "FIT2: every emitted density is inside the certifiable band");
    CHECK(all_percolate, "FIT2: every emitted cell percolates in its own member");
    CHECK(Fi.fit_out_of_regime_voxels == Fi.latticed_voxels,
          "FIT2: a 4 mm wall is BELOW the accuracy floor at 1.0950 mm (3.65 cells), "
          "and every latticed voxel is counted as out of regime rather than hidden");
    CHECK(Fi.density_raised_for_print_voxels > 0,
          "FIT2: the density was RAISED to print at the finer cell — the joint "
          "(cell, rho) solve, not a cell chosen alone");

    // ── FIT3 — A CANDIDATE WITH NO DERIVATION STAYS SOLID, and is counted as such
    // rather than being handed a guessed cell.
    {
      std::vector<double> half = wfit;
      std::size_t cleared = 0;
      for (int k = 0; k < wall.nz; ++k)
        for (int j = 0; j < wall.ny; ++j)
          for (int i = 0; i < wall.nx / 2; ++i) {
            const std::size_t e = wall.index(i, j, k);
            if (half[e] > 0.0) { half[e] = 0.0; ++cleared; }
          }
      CHECK(cleared > 0, "FIT3 is not vacuous: some candidates lost their cell");
      GradingLawParams f3 = fi;
      f3.fit_cell_size_mm = &half;
      const GradedField F3 = grade_lattice(wall, wd, wdem, nullptr, f3);
      CHECK(F3.fit_no_derivation_voxels == cleared,
            "FIT3: every uncovered candidate is counted, not silently dropped");
      CHECK(F3.latticed_voxels < Fi.latticed_voxels,
            "FIT3: and none of them was latticed");
    }

    // ── FIT4 (bar S3) — TWO REGIONS, TWO CELLS, ONE DYADIC LADDER. The emitter can
    // only carry more than one cell size on an aligned dyadic octree, so the plan
    // must land the derived cells there: every emitted cell is base * 2^L, no cell
    // is coarser than its own region asked for, and face-adjacent cells differ by at
    // most one level (2:1 balance — what makes the levels meet at shared nodes).
    {
      // A 4 mm-thick slab whose two halves are declared with DIFFERENT cells: the
      // thin half wants 1.0950 mm, the thick half is declared as a 12 mm region and
      // wants 12/5 = 2.4 mm.
      std::vector<double> two = wfit;
      std::size_t coarse_n = 0;
      for (int k = 0; k < wall.nz; ++k)
        for (int j = 0; j < wall.ny; ++j)
          for (int i = wall.nx / 2; i < wall.nx; ++i) {
            const std::size_t e = wall.index(i, j, k);
            if (two[e] > 0.0) { two[e] = 12.0 / n_star; ++coarse_n; }
          }
      CHECK(coarse_n > 0, "FIT4 is not vacuous: a second region was declared");
      GradingLawParams f4 = fi;
      f4.fit_cell_size_mm = &two;
      const GradedField F4 = grade_lattice(wall, wd, wdem, nullptr, f4);
      CHECK(F4.cell_plan.max_level >= 1,
            "FIT4: two different derived cells produce a real ladder");
      CHECK(F4.fit_distinct_cells >= 2,
            "FIT4: and BOTH cells are actually emitted, not collapsed to one");
      bool dyadic = true, never_coarser = true;
      for (std::size_t e = 0; e < wall.voxel_count(); ++e) {
        if (!F4.posture.mask[e]) continue;
        const double c = F4.posture.cell_size_field[e];
        const double lg = std::log2(c / F4.cell_plan.base_cell_mm);
        if (std::fabs(lg - std::round(lg)) > 1e-9) dyadic = false;
        if (c > two[e] * (1.0 + 1e-9)) never_coarser = false;
      }
      CHECK(dyadic, "FIT4: every emitted cell is base * 2^L — the ladder the "
                    "multilevel emitter indexes");
      CHECK(never_coarser,
            "FIT4: no voxel got a cell COARSER than its own region derived");
      bool balanced = true;
      const CellSizePlan& P = F4.cell_plan;
      for (int k = 0; k < P.nz && balanced; ++k)
        for (int j = 0; j < P.ny && balanced; ++j)
          for (int i = 0; i < P.nx && balanced; ++i) {
            const int L = P.level[P.index(i, j, k)];
            if (L < 0) continue;
            static const int d6[6][3] = {{-1,0,0},{1,0,0},{0,-1,0},
                                         {0,1,0},{0,0,-1},{0,0,1}};
            for (int f = 0; f < 6; ++f) {
              const int ni = i + d6[f][0], nj = j + d6[f][1], nk = k + d6[f][2];
              if (ni < 0 || nj < 0 || nk < 0 || ni >= P.nx || nj >= P.ny ||
                  nk >= P.nz) continue;
              const int NL = P.level[P.index(ni, nj, nk)];
              if (NL >= 0 && std::abs(NL - L) > 1) balanced = false;
            }
          }
      CHECK(balanced, "FIT4: face-adjacent octree cells differ by at most one level");
    }

    // ── FIT5 — DETERMINISM. Same inputs, byte-identical posture.
    {
      const GradedField B = grade_lattice(wall, wd, wdem, nullptr, fi);
      CHECK(B.posture.relative_density == Fi.posture.relative_density &&
                B.posture.mask == Fi.posture.mask &&
                B.posture.cell_size_field == Fi.posture.cell_size_field,
            "FIT5: fit is deterministic");
    }

    // ── FIT6 — FIT AND SUB-FLOOR RETENTION ARE REFUSED TOGETHER, not silently
    // resolved in favour of one.
    {
      GradingLawParams f6 = fi;
      f6.retain_subfloor_in_unloaded_regions = true;
      bool threw = false;
      try { grade_lattice(wall, wd, wdem, nullptr, f6); }
      catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, "FIT6: fit + retention is refused");
      GradingLawParams f6b = fi;
      f6b.fit_cell_size_mm = nullptr;
      threw = false;
      try { grade_lattice(wall, wd, wdem, nullptr, f6b); }
      catch (const std::invalid_argument&) { threw = true; }
      CHECK(threw, "FIT6: fit without a derived field is refused, never defaulted");
    }

    // ══ S2 — THE PRINTABILITY FLOOR IS A BOUND AGAIN, NOT AN ANSWER ═══════════
    // On UNFIXED code these three fail: a Fixed target of 1.2 mm is raised to
    // 4.6026 mm, so S2a reads 4.6026 and S2b lattices nothing.
    {
      // S2a — the hand-set cell SURVIVES.
      GradingLawParams s2 = base;
      s2.cell_mode = CellSizeMode::Fixed;
      s2.target_cell_size_mm = 1.2;
      const GradedField S2 = grade_lattice(wall, wd, wdem, nullptr, s2);
      CHECK(std::fabs(S2.cell_size_mm - 1.2) < 1e-12,
            "S2a: a hand-set 1.2 mm cell is NOT raised to the 4.6026 mm rho_min "
            "floor");
      CHECK(!S2.cell_size_floored, "S2a: and it is not reported as floored");
      CHECK(std::fabs(S2.min_printable_cell_mm - finest_cell) < 1e-12,
            "S2a: the floor that binds is the one at the band's TOP");

      // S2b — on a member thick enough to hold it, that cell now LATTICES. An 8 mm
      // wall spans 6.67 cells at 1.2 mm (over N*) and 1.74 at 4.6026 mm (under it),
      // so this is exactly the material the override was throwing away.
      const VoxelGrid w8 = solid_block(40, 40, 16, 0.5);
      const std::vector<double> d8 = density_of(w8);
      const std::vector<double> dem8(w8.voxel_count(), 1.0);
      const GradedField L8 = grade_lattice(w8, d8, dem8, nullptr, s2);
      CHECK(L8.latticed_voxels > 0,
            "S2b: a 1.2 mm cell lattices an 8 mm wall — 6.67 cells across");
      GradingLawParams s2auto = base;
      s2auto.cell_mode = CellSizeMode::Auto;
      const GradedField A8 = grade_lattice(w8, d8, dem8, nullptr, s2auto);
      CHECK(A8.latticed_voxels == 0,
            "S2b control: the SAME wall under AUTO's 4.6026 mm cell lattices "
            "nothing — 1.74 cells across");
      bool print8 = true;
      for (std::size_t e = 0; e < w8.voxel_count(); ++e)
        if (L8.posture.mask[e] &&
            octet_strut_diameter_mm(L8.posture.relative_density[e], 1.2) <
                w_bead - 1e-9)
          print8 = false;
      CHECK(print8,
            "S2b: every strut at the finer cell still clears the stated bead — the "
            "density was raised with the cell, not the cell with the density");

      // S2c — INERT WHERE THE CELL WAS NEVER OVERRIDDEN. A target at or above the
      // rho_min floor is untouched and NO density is raised, which is why S2 cannot
      // move a run that was not being overridden (blocked-stop 4).
      GradingLawParams s2c = base;
      s2c.cell_mode = CellSizeMode::Fixed;
      s2c.target_cell_size_mm = 6.0;   // > 4.6026
      const GradedField C = grade_lattice(w8, d8, dem8, nullptr, s2c);
      CHECK(std::fabs(C.cell_size_mm - 6.0) < 1e-12,
            "S2c: a target above the rho_min floor is untouched");
      CHECK(C.density_raised_for_print_voxels == 0,
            "S2c: and no voxel's density is raised — the S2 path is inert here");
      const GradedField CA = grade_lattice(w8, d8, dem8, nullptr, s2auto);
      CHECK(CA.density_raised_for_print_voxels == 0,
            "S2c: AUTO likewise raises nothing — its cell IS the rho_min floor");
    }
  }

  std::fprintf(stderr, "grading: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
