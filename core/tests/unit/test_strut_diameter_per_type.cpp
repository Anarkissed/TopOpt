// test_strut_diameter_per_type — ★ ONE DEFINITION OF DENSITY → STRUT DIAMETER, AND
// R1's REFUSAL (task 2026-09-28-lattice-types-core, the plumbing commit).
//
// `octet_strut_diameter_mm` is called from 44 places in core and not one of them is
// topology-aware (the K0 inventory). Ten of those are inside
// `lattice_cell_printability_floor_mm` and `lattice_min_density_for_strut`, two
// functions that already take a `topo` argument and IGNORE it — so today a job that
// somehow reached them with any topology would be sized with octet's measured table.
//
// `lattice_strut_diameter_mm(topo, rho, cell)` is the one definition those consumers
// go through. This file pins the two properties that make it safe to put underneath
// them:
//
//   1. OCTET IS BIT-FOR-BIT UNCHANGED. Not "within a tolerance" — the same double.
//      R9 requires octet's outputs, receipts and tensor to be byte-identical, and a
//      diameter that differs in the last bit would move a strut radius, which moves a
//      mesh, which breaks the hashes. Equality is therefore the correct assertion and
//      a tolerance would be the wrong one.
//   2. EVERY OTHER TYPE REFUSES, and the refusal NAMES THE TYPE. R1: a type may not
//      borrow octet's numbers. This is the failure mode that cannot be caught later —
//      a borrowed diameter produces a strut that prints, at the wrong size, silently.
//
// ★ BOTH ASSERTIONS WERE PROVED RED BEFORE THE IMPLEMENTATION EXISTED. The function
// was first written as `(void)topo; return octet_strut_diameter_mm(...)` — today's
// behaviour for every type — and section 2 below failed for all nine non-octet ids.
//
// Self-contained CHECK harness (ARCHITECTURE §4).

#include <limits>
#include "topopt/lattice.hpp"
#include "topopt/lattice_gen.hpp"

#include <cmath>
#include <cstdio>
#include <stdexcept>   // std::invalid_argument, caught below: libc++ supplies it
                       // transitively and libstdc++ does not (AGENT_PROMPTS §1)
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

int main() {
  // Every topology the enum carries. Listed explicitly rather than looped over a
  // range cast, so adding an id to the enum does not silently widen this test.
  const std::vector<LatticeTopology> all = {
      LatticeTopology::Octet,   LatticeTopology::SimpleCubic,
      LatticeTopology::Bcc,     LatticeTopology::Fcc,
      LatticeTopology::Diamond, LatticeTopology::Kelvin,
      LatticeTopology::Rhombic, LatticeTopology::Bccz,
      LatticeTopology::Fccz,    LatticeTopology::Reentrant,
      LatticeTopology::Gyroid,  LatticeTopology::SchwarzD};
  CHECK(all.size() == 12, "the enum carries twelve topologies (the two sheets since K2)");
  // ★ The types whose OWN law is landed (lattice types round 1: each joins this list
  // as it goes live, with its own section below). Sections 2 and 7 assert that every
  // OTHER type still refuses.
  auto has_own_law = [](LatticeTopology t) {
    return t == LatticeTopology::Octet || t == LatticeTopology::Fcc ||
           t == LatticeTopology::Kelvin ||
           t == LatticeTopology::Rhombic ||
           t == LatticeTopology::Diamond ||
           t == LatticeTopology::Bcc ||
           t == LatticeTopology::SimpleCubic;
  };

  // ── 1. OCTET, BIT FOR BIT ───────────────────────────────────────────────────
  // Across the measured table's whole range and past both ends (the table clamps
  // below its first row and above its last), and over cell sizes spanning four
  // decades, because diameter is linear in cell size and a scaling bug would only
  // show at the extremes.
  {
    const std::vector<double> rhos = {0.0,  0.01, 0.05, 0.0999, 0.1,  0.15,
                                      0.199, 0.2,  0.25, 0.3,   0.35, 0.4,
                                      0.45,  0.5,  0.55, 0.6,   0.6001, 0.75,
                                      0.9,   1.0};
    const std::vector<double> cells = {0.01, 0.1, 1.0, 1.705, 3.41, 4.0,
                                       8.0,  12.0, 100.0};
    long long n = 0;
    bool all_equal = true;
    double worst_rho = 0.0, worst_cell = 0.0, a_bad = 0.0, b_bad = 0.0;
    for (double r : rhos)
      for (double c : cells) {
        const double a = octet_strut_diameter_mm(r, c);
        const double b = lattice_strut_diameter_mm(LatticeTopology::Octet, r, c);
        ++n;
        // EXACT equality, deliberately. See the header.
        if (!(a == b)) {
          if (all_equal) { worst_rho = r; worst_cell = c; a_bad = a; b_bad = b; }
          all_equal = false;
        }
      }
    char msg[256];
    std::snprintf(msg, sizeof msg,
                  "octet: %lld (rho, cell) pairs must be BIT-IDENTICAL through the "
                  "new function (first mismatch rho %.6g cell %.6g: %.17g vs %.17g)",
                  n, worst_rho, worst_cell, a_bad, b_bad);
    CHECK(all_equal, msg);
    std::printf("  octet parity: %lld pairs, bit-identical\n", n);
  }

  // ── 2. EVERY OTHER TYPE REFUSES, AND NAMES ITSELF ───────────────────────────
  // This is the section that was RED against the permissive first implementation.
  for (LatticeTopology t : all) {
    if (has_own_law(t)) continue;
    const std::string name = lattice_topology_name(t);
    bool threw = false;
    bool named = false;
    try {
      (void)lattice_strut_diameter_mm(t, 0.30, 8.0);
    } catch (const LatticeDiameterLawNotMeasured& e) {
      threw = true;
      named = std::string(e.what()).find(name) != std::string::npos;
    } catch (...) {
      // A different exception is not the contract: callers that mean to report
      // "not measured yet" have to be able to catch it by type.
    }
    char msg[200];
    std::snprintf(msg, sizeof msg,
                  "%s: no measured diameter law, so it must throw "
                  "LatticeDiameterLawNotMeasured (R1: never octet's table)",
                  name.c_str());
    CHECK(threw, msg);
    std::snprintf(msg, sizeof msg,
                  "%s: the refusal must NAME the type it refuses", name.c_str());
    CHECK(named, msg);
  }

  // ── 3. AND EVERY CERTIFIABLE TYPE NOW HAS ITS OWN LAW ───────────────────────
  // The two refusals are about different things and must not be conflated. This section
  // named FCC, Kelvin, then Simple cubic as a CERTIFIABLE type that still had no
  // diameter law, until each one's own law landed. With Simple cubic's (the last strut
  // type of lattice types round 1) none is left, so it holds the converse: no
  // certifiable type is refused here.
  for (LatticeTopology t : all) {
    if (!lattice_topology_certifiable(t)) continue;
    const std::string name = lattice_topology_name(t);
    bool threw = false;
    try {
      (void)lattice_strut_diameter_mm(t, 0.30, 8.0);
    } catch (const LatticeDiameterLawNotMeasured&) {
      threw = true;
    }
    char msg[160];
    std::snprintf(msg, sizeof msg,
                  "%s: certifiable, so it has its own measured diameter law",
                  name.c_str());
    CHECK(has_own_law(t) && !threw, msg);
  }

  // ── 3b. FCC'S OWN LAW (lattice types round 1) ───────────────────────────────
  // FCC's table was measured on FCC's own canonical cell, on its converged solid
  // fraction (lattice_types_probe `law`). Octet's table was measured on the legs-only
  // cell -- which IS FCC -- on the vpc48 voxel staircase, so the two agree to within
  // that staircase (<= 3 %), which is asserted as the cross-check it is.
  {
    const double rows[8][2] = {{0.05, 0.3639}, {0.08, 0.4670}, {0.10, 0.5265},
                               {0.15, 0.6580}, {0.20, 0.7739}, {0.30, 0.9807},
                               {0.40, 1.1712}, {0.60, 1.5434}};
    for (const auto& r : rows)
      CHECK(lattice_strut_diameter_mm(LatticeTopology::Fcc, r[0], 4.0) == r[1],
            "fcc: the measured table, verbatim at a 4 mm cell");
    CHECK(lattice_strut_diameter_mm(LatticeTopology::Fcc, 0.30, 8.0) == 2 * 0.9807,
          "fcc: diameter is linear in cell size");
    for (const auto& r : rows)
      CHECK(std::fabs(lattice_strut_diameter_mm(LatticeTopology::Fcc, r[0], 7.0) /
                          octet_strut_diameter_mm(r[0], 7.0) - 1.0) < 0.03,
            "fcc: within 3 % of octet's legs-only table (one geometry, two "
            "resolutions)");
    // The other direction is the same measurement read backwards, so inside the table
    // the round trip is exact; off it (a strut thinner than the 0.05 row) the density is
    // integrated on the converged solid fraction, and lands below the table's first row.
    for (double want : {0.05, 0.12, 0.30, 0.47, 0.60}) {
      const double r = 0.5 * lattice_strut_diameter_mm(LatticeTopology::Fcc, want, 8.0);
      CHECK(std::fabs(lattice_density_from_strut(LatticeTopology::Fcc, 8.0, r) - want) < 1e-12,
            "fcc: (cell, radius) -> rho is the table read backwards, an exact round trip");
    }
    {
      const double thin = lattice_density_from_strut(LatticeTopology::Fcc, 8.0, 0.30);
      CHECK(thin > 0.0 && thin < 0.05, "fcc: off the table, the solid fraction answers");
    }
    CHECK(lattice_type_numbers_measured(LatticeTopology::Fcc),
          "fcc: its numbers are measured");
    CHECK(lattice_type_numbers_measured(LatticeTopology::SimpleCubic),
          "sc: its numbers are measured (the last strut type of round 1)");
    CHECK(!lattice_type_numbers_measured(LatticeTopology::Bccz),
          "bccz: its numbers are not measured (not in round 1)");
    CHECK(lattice_cells_per_member_min(LatticeTopology::Fcc) == 5.0 &&
              lattice_percolation_cells_per_member_min(LatticeTopology::Fcc) == 0.75 &&
              aesthetic_cells_per_member_hard_floor(LatticeTopology::Fcc, true) == 2.0,
          "fcc: its own floors (5 bending, 0.75 percolation, 2 aesthetic, no finish "
          "relaxation)");
  }

  // ── 4. THE TWO CONSUMERS THAT TOOK A TOPOLOGY AND IGNORED IT ────────────────
  // Octet's answers must not move, and a type with no table must not get one.
  {
    const std::vector<double> widths = {0.2, 0.42, 0.45, 0.8};
    const std::vector<double> cells = {1.0, 4.0, 8.0, 12.0};
    for (double w : widths) {
      // Octet still answers.
      const double f = lattice_cell_printability_floor_mm(LatticeTopology::Octet, w);
      CHECK(std::isfinite(f) && f > 0.0,
            "octet: the printability floor still answers");
      for (double c : cells) {
        const double m =
            lattice_min_density_for_strut(LatticeTopology::Octet, c, w);
        CHECK(std::isfinite(m), "octet: the minimum density still answers");
      }
      // Every certifiable type with no diameter law of its own refuses, rather than being
      // handed octet's (a loop, so a type leaves it by going live, not by an edit here).
      for (LatticeTopology t : all) {
        if (has_own_law(t) || !lattice_topology_certifiable(t)) continue;
        bool threw_floor = false;
        try {
          (void)lattice_cell_printability_floor_mm(t, w);
        } catch (const LatticeDiameterLawNotMeasured&) {
          threw_floor = true;
        }
        CHECK(threw_floor,
              "no law: the printability floor must refuse, not read octet's table");
        bool threw_min = false;
        try {
          (void)lattice_min_density_for_strut(t, 8.0, w);
        } catch (const LatticeDiameterLawNotMeasured&) {
          threw_min = true;
        }
        CHECK(threw_min,
              "no law: the minimum density must refuse, not read octet's table");
      }
    }
  }

  // ── 5. THE ID ROUND TRIP, AND NO DEFAULT ────────────────────────────────────
  // `lattice_topology_from_id` is the seam run_job's 23 hard-coded `Octet`s will move
  // onto, so it has to be exactly the inverse of `lattice_topology_name` — if the two
  // ever disagree, a job's id would silently select a different type's numbers.
  {
    for (LatticeTopology t : all) {
      const std::string id = lattice_topology_name(t);
      bool ok = false;
      try {
        ok = (lattice_topology_from_id(id) == t);
      } catch (const std::exception&) {
      }
      char msg[160];
      std::snprintf(msg, sizeof msg,
                    "id round trip: \"%s\" must resolve back to itself", id.c_str());
      CHECK(ok, msg);
    }
    // An unknown id refuses and names what it was given. "Octet" with a capital O is
    // in the list on purpose: the ids are lower-case, and a near-miss must refuse
    // rather than fall back.
    for (const char* bad : {"", "Octet", "OCTET", "oct", "octet ", "gyroids",
                            "schwarz-d", "honeycomb", "bcc-z"}) {
      bool threw = false, named = false;
      try {
        (void)lattice_topology_from_id(bad);
      } catch (const std::invalid_argument& e) {
        threw = true;
        named = std::string(e.what()).find(bad) != std::string::npos ||
                std::string(bad).empty();
      }
      char msg[200];
      std::snprintf(msg, sizeof msg,
                    "id \"%s\" is unknown: it must refuse, never default to octet",
                    bad);
      CHECK(threw, msg);
      std::snprintf(msg, sizeof msg, "id \"%s\": the refusal names it", bad);
      CHECK(named, msg);
    }
  }

  // ── 6. THE STATED-DENSITY PREDICATE ─────────────────────────────────────────
  // There is ONE form and it takes the topology (the 3-argument form was removed:
  // reviewer 2026-09-30, because a future caller could have reached octet's table
  // through it on another type's job). Octet's answers are unchanged — the values
  // below are the two that test_lattice_refusal pins, restated here against the
  // per-type entry point — and "nothing stated" must return false for a type with NO
  // diameter law rather than throwing, because an absent override is not a question
  // about the type.
  {
    const double c = 2.7284, w = 0.42;
    CHECK(lattice_stated_density_unprintable(LatticeTopology::Octet, 0.06, c, w),
          "stated density: octet, rho 0.06 at cell 2.7284 and a 0.42 bead is "
          "unprintable (as test_lattice_refusal pins)");
    CHECK(!lattice_stated_density_unprintable(LatticeTopology::Octet, 0.25, c, w),
          "stated density: octet, rho 0.25 there is printable");
    for (LatticeTopology t : all) {
      if (has_own_law(t)) continue;
      bool quiet = true;
      try {
        for (double nothing : {0.0, -1.0, -1e-300})
          if (lattice_stated_density_unprintable(t, nothing, c, w)) quiet = false;
      } catch (const std::exception&) {
        quiet = false;   // it must NOT consult the diameter law when nothing is stated
      }
      CHECK(quiet,
            "stated density: nothing stated returns false for a type with no diameter "
            "law, without consulting it");
      // But a STATED density on such a type does reach the law, and refuses.
      bool threw = false;
      try {
        (void)lattice_stated_density_unprintable(t, 0.25, c, w);
      } catch (const LatticeDiameterLawNotMeasured&) {
        threw = true;
      }
      CHECK(threw,
            "stated density: a STATED density on a type with no diameter law refuses");
    }
  }

  // ── 7. R11: THE AESTHETIC CEILING, PER TYPE ─────────────────────────────────
  // Same shape as the diameter law and for the same reason, with one addition: the
  // refusal must be its OWN type. A caller answering "why can't I pick Kelvin" has to
  // be able to distinguish a missing ceiling from a missing diameter table, even
  // though today the second implies the first.
  {
    CHECK(lattice_aesthetic_density_ceiling(LatticeTopology::Octet) ==
              octet_aesthetic_density_ceiling(),
          "octet: the per-type ceiling IS octet_aesthetic_density_ceiling(), exactly");
    for (LatticeTopology t : all) {
      if (has_own_law(t)) continue;
      const std::string name = lattice_topology_name(t);
      bool threw = false, named = false, right_type = true;
      try {
        (void)lattice_aesthetic_density_ceiling(t);
      } catch (const LatticeAestheticCeilingNotMeasured& e) {
        threw = true;
        named = std::string(e.what()).find(name) != std::string::npos;
      } catch (const LatticeDiameterLawNotMeasured&) {
        // Wrong refusal: it must name the CEILING as missing, not the table.
        right_type = false;
      } catch (...) {
        right_type = false;
      }
      char msg[220];
      std::snprintf(msg, sizeof msg,
                    "%s: no measured aesthetic ceiling, so it must throw (R11)",
                    name.c_str());
      CHECK(threw, msg);
      std::snprintf(msg, sizeof msg,
                    "%s: the ceiling refusal must be LatticeAestheticCeilingNotMeasured, "
                    "not the diameter law's", name.c_str());
      CHECK(right_type, msg);
      std::snprintf(msg, sizeof msg, "%s: the ceiling refusal names the type",
                    name.c_str());
      CHECK(named, msg);
    }
  }

  // ── 8. M6: READINESS IS BOTH SETS, AND ALL FOUR STATES ARE REACHABLE ────────
  // `lattice_type_readiness` takes the two name sets as ARGUMENTS precisely so this
  // section can enter every branch. With core's real sets only three states occur --
  // nothing today is generatable-but-not-certifiable -- and that is exactly the state
  // a future type sits in between its generator landing and its rows landing. A
  // branch no test can reach is a branch nobody has checked.
  {
    const std::vector<std::string> gen_real = lattice_gen_topology_names();
    const std::vector<std::string> cert_real = lattice_certifiable_topology_names();

    // The real sets, today.
    CHECK(lattice_type_readiness("octet", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: octet is live (generatable AND certifiable)");
    CHECK(lattice_type_readiness("fcc", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: fcc is live (lattice types round 1)");
    CHECK(lattice_type_readiness("kelvin", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: kelvin is live");
    CHECK(lattice_type_readiness("rhombic", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: rhombic is live");
    CHECK(lattice_type_readiness("diamond", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: diamond is live");
    CHECK(lattice_type_readiness("bcc", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: bcc is live");
    CHECK(lattice_type_readiness("sc", gen_real, cert_real) ==
              LatticeTypeReadiness::Live,
          "readiness: sc is live");
    for (const char* tetra : {"bccz", "fccz", "reentrant"}) {
      char msg[140];
      std::snprintf(msg, sizeof msg, "readiness: %s is in neither set", tetra);
      CHECK(lattice_type_readiness(tetra, gen_real, cert_real) ==
                LatticeTypeReadiness::NotEither, msg);
    }
    CHECK(lattice_type_readiness("octopus", gen_real, cert_real) ==
              LatticeTypeReadiness::UnknownId,
          "readiness: an id core does not know is UnknownId, not NotEither");

    // ★ THE BRANCH THE REAL SETS CANNOT REACH. Synthetic sets, so it is checked
    // before a type ever lands in it.
    {
      const std::vector<std::string> gen = {"octet", "kelvin"};
      const std::vector<std::string> cert = {"octet"};
      CHECK(lattice_type_readiness("kelvin", gen, cert) ==
                LatticeTypeReadiness::NotCertifiable,
            "readiness: generatable without rows is NotCertifiable (M6: every "
            "user-facing result is certified)");
      CHECK(lattice_type_readiness("octet", gen, cert) ==
                LatticeTypeReadiness::Live,
            "readiness: and octet is still live in that world");
    }
    // Empty sets: a known id is NotEither, an unknown one is still UnknownId.
    CHECK(lattice_type_readiness("octet", {}, {}) == LatticeTypeReadiness::NotEither,
          "readiness: with both sets empty even octet is not live");
    CHECK(lattice_type_readiness("nope", {}, {}) == LatticeTypeReadiness::UnknownId,
          "readiness: with both sets empty an unknown id is still unknown");

    // ★ AND THE PLAIN-LANGUAGE LINE THE APP PUTS ON THE SCREEN. Pinned exactly,
    // because these are the words a user reads: a paraphrase in Swift is the drift
    // R12 exists to stop, and a test that only checked "non-empty" would not catch
    // the two being swapped -- which is the one mistake that matters here, since
    // "strength-checked but not buildable" and "buildable but not strength-checked"
    // send a reader in opposite directions.
    CHECK(std::string(lattice_type_readiness_plain(
              LatticeTypeReadiness::NotGeneratable)) ==
              "Strength-checked, but not buildable yet",
          "plain: NotGeneratable reads 'Strength-checked, but not buildable yet'");
    CHECK(std::string(lattice_type_readiness_plain(
              LatticeTypeReadiness::NotCertifiable)) ==
              "Buildable, but not strength-checked yet",
          "plain: NotCertifiable reads 'Buildable, but not strength-checked yet'");
    CHECK(std::string(lattice_type_readiness_plain(
              LatticeTypeReadiness::NotEither)) ==
              "Not buildable or strength-checked yet",
          "plain: NotEither reads 'Not buildable or strength-checked yet'");
    CHECK(std::string(lattice_type_readiness_plain(
              LatticeTypeReadiness::UnknownId)) == "Not a lattice type",
          "plain: UnknownId reads 'Not a lattice type'");
    for (LatticeTypeReadiness r :
         {LatticeTypeReadiness::Live, LatticeTypeReadiness::NotGeneratable,
          LatticeTypeReadiness::NotCertifiable, LatticeTypeReadiness::NotEither,
          LatticeTypeReadiness::UnknownId})
      CHECK(std::string(lattice_type_readiness_plain(r)).size() > 0 &&
                std::string(lattice_type_readiness_plain(r)).size() <= 44,
            "plain: every state has a line, short enough for a picker row");

    // Every state has a distinct human name, so a refusal can say which it is.
    const std::vector<LatticeTypeReadiness> states = {
        LatticeTypeReadiness::Live, LatticeTypeReadiness::NotGeneratable,
        LatticeTypeReadiness::NotCertifiable, LatticeTypeReadiness::NotEither,
        LatticeTypeReadiness::UnknownId};
    for (std::size_t i = 0; i < states.size(); ++i)
      for (std::size_t j = i + 1; j < states.size(); ++j)
        CHECK(std::string(lattice_type_readiness_name(states[i])) !=
                  std::string(lattice_type_readiness_name(states[j])),
              "readiness: each state has its own name");
  }

  // ── 9. THE DENSITY DIRECTION OF THE SAME LAW ────────────────────────────────
  // (cell, radius) -> rho, which a UNIFORM job states and which the stepped menu's
  // "prints open" admission asks about. Octet bit-for-bit, every other type refused
  // with the SAME exception the forward direction throws: one measurement, two
  // directions, and a type either has it or does not.
  {
    const std::vector<double> cells = {0.5, 1.0, 4.0, 6.0, 8.0, 12.0, 40.0};
    const std::vector<double> radii = {0.05, 0.1, 0.21, 0.4, 0.8, 1.2};
    long long n = 0;
    bool all_equal = true;
    for (double c : cells)
      for (double r : radii) {
        double a = -1.0, b = -2.0;
        bool athrew = false, bthrew = false;
        try { a = octet_relative_density(c, r); } catch (const std::exception&) { athrew = true; }
        try { b = lattice_density_from_strut(LatticeTopology::Octet, c, r); }
        catch (const std::exception&) { bthrew = true; }
        ++n;
        // Including the inputs octet itself REFUSES (a radius that fills the cell):
        // the wrapper must refuse there too, not return something.
        if (athrew != bthrew || (!athrew && !(a == b))) all_equal = false;
      }
    char msg[200];
    std::snprintf(msg, sizeof msg,
                  "octet density: %lld (cell, radius) pairs bit-identical through the "
                  "new function, refusals included", n);
    CHECK(all_equal, msg);
    std::printf("  octet density parity: %lld pairs, bit-identical\n", n);

    for (LatticeTopology t : all) {
      if (has_own_law(t)) continue;
      const std::string name = lattice_topology_name(t);
      bool threw = false, named = false;
      try {
        (void)lattice_density_from_strut(t, 8.0, 0.4);
      } catch (const LatticeDiameterLawNotMeasured& e) {
        threw = true;
        named = std::string(e.what()).find(name) != std::string::npos;
      }
      char m2[200];
      std::snprintf(m2, sizeof m2,
                    "%s: no measured density law -> refuses with the diameter law's "
                    "exception (one law, two directions)", name.c_str());
      CHECK(threw, m2);
      std::snprintf(m2, sizeof m2, "%s: the density refusal names the type", name.c_str());
      CHECK(named, m2);
    }
  }

  // ── ★ THE SHEET IDS ARE TYPES, NOT TYPOS (K2) ───────────────────────────────
  // gyroid and schwarz_d used to be a separate "planned" list so they would not read as
  // typos before they had enum values. At K2 they are LatticeTopology ids, so the list is
  // gone and they read like any type: known, and live exactly when both sets hold them.
  {
    const std::vector<std::string> gen = lattice_gen_topology_names();
    const std::vector<std::string> cert = lattice_certifiable_topology_names();
    for (const char* id : {"gyroid", "schwarz_d"}) {
      CHECK(lattice_type_readiness(id, gen, cert) != LatticeTypeReadiness::UnknownId,
            "a sheet id is a type core knows, never UnknownId");
      CHECK(lattice_topology_name(lattice_topology_from_id(id)) == std::string(id),
            "a sheet id round-trips through the enum");
    }
    // A genuine typo must still be UnknownId, or the distinction is lost.
    for (const char* typo : {"gyroids", "gyroid ", "schwarz-d", "schwarzd", "octett"})
      CHECK(lattice_type_readiness(typo, gen, cert) ==
                LatticeTypeReadiness::UnknownId,
            "a near-miss of a planned or live id is still UnknownId");
  }

  // ── ★ E1 / D1: ONE FUNCTION FOR "THE SMALLEST CELL THAT PRINTS" ─────────────
  // #354 reported core answering that question with five numbers on different paths, and
  // one run printing two of them under one key name. These are the three that matter, on
  // octet at a 0.45 mm bead, and they are pinned to the digits the brief quoted -- so if
  // a measured table moves, this says so instead of the app silently getting a different
  // floor from the one grade_lattice applies.
  {
    const double w = 0.45;
    const LatticeTopology t = LatticeTopology::Octet;
    const double light = lattice_cell_printability_floor_mm(t, w);
    const double uncapped = lattice_min_printable_cell_mm(t, w, 0.0);
    const double at_cap = lattice_min_printable_cell_mm(t, w, octet_aesthetic_density_ceiling());
    CHECK(std::fabs(light - 4.931378498) < 5e-9,
          "E1: the LIGHT floor w/phi(rho_min) is 4.931378498 mm");
    CHECK(std::fabs(uncapped - 1.173173434) < 5e-9,
          "E1: the UNCAPPED dense floor w/phi(rho_max) is 1.173173434 mm");
    CHECK(std::fabs(at_cap - 2.25) < 5e-9,
          "E1: and at the job's cap it is 2.25 mm -- the number grade_lattice applies");
    // The three are genuinely different answers; that is the whole defect.
    CHECK(at_cap > uncapped * 1.5 && light > at_cap * 1.5,
          "E1 premise: the three floors are far apart, so routing a path to the wrong one "
          "is not a rounding difference");

    // A cap of 0 or non-finite means NOT SENT -- the app's semantics, which core now owns.
    CHECK(lattice_min_printable_cell_mm(t, w, 0.0) == uncapped,
          "E1: a cap of 0 is 'not sent' and gives the uncapped floor");
    CHECK(lattice_min_printable_cell_mm(t, w, -1.0) == uncapped,
          "E1: so is a negative cap");
    CHECK(lattice_min_printable_cell_mm(
              t, w, std::numeric_limits<double>::infinity()) == uncapped,
          "E1: and a non-finite one");
    // A cap ABOVE the band top cannot buy a finer cell than the band allows.
    CHECK(lattice_min_printable_cell_mm(t, w, 0.99) == uncapped,
          "E1: a cap above the band top is clamped to it");

    // ★ MONOTONE: a tighter cap means a COARSER smallest-printable cell. That is the
    // property which makes it a floor at all, and it is what a path computing the
    // UNCAPPED number got wrong -- it reported a cell FINER than the job can print.
    //
    // NON-STRICTLY monotone, and the reason is the measured table, not an approximation:
    // the diameter law is CLAMPED above its last measured row (rho 0.60), so every cap
    // from 0.60 up gives the same floor. My first draft asserted strict increase and went
    // red at cap 0.60 against 0.80 -- the table's flat top, which is a fact worth pinning
    // rather than an assumption worth keeping.
    double prev = 0.0;
    for (double cap : {0.90, 0.80, 0.60, 0.55, 0.40, 0.30, 0.25, 0.20, 0.10, 0.06}) {
      const double cell = lattice_min_printable_cell_mm(t, w, cap);
      CHECK(cell >= prev, "E1: a tighter cap never gives a FINER printable cell");
      prev = cell;
    }
    // Strictly increasing once below the last measured row, where phi really varies.
    double below = 0.0;
    for (double cap : {0.55, 0.40, 0.30, 0.25, 0.20, 0.10, 0.06}) {
      const double cell = lattice_min_printable_cell_mm(t, w, cap);
      CHECK(cell > below, "E1: and below rho 0.60 a tighter cap is strictly coarser");
      below = cell;
    }
    // THE FLAT TOP ITSELF, pinned: a cap anywhere from the band floor's top region down to
    // 0.60 buys nothing, because phi is clamped there. If the table ever gains a row above
    // 0.60 this check reports it instead of the app silently getting a finer floor.
    CHECK(lattice_min_printable_cell_mm(t, w, 0.60) ==
              lattice_min_printable_cell_mm(t, w, 0.90),
          "E1: caps of 0.60 and 0.90 give the SAME floor -- the diameter law is clamped "
          "above its last measured row, so a cap up there is inert");

    // A cap under the band's own floor admits no measured density: refused, named.
    bool threw = false;
    std::string why;
    try {
      (void)lattice_min_printable_cell_mm(t, w, 0.5 * lattice_rho_min(t));
    } catch (const std::exception& e) { threw = true; why = e.what(); }
    CHECK(threw, "E1: a cap below the band floor is REFUSED, not evaluated off the table");
    CHECK(why.find("band floor") != std::string::npos && why.find("octet") != std::string::npos,
          "E1: and the refusal names the band floor and the type");
    // And a bead that is not a width at all.
    bool threw_w = false;
    try { (void)lattice_min_printable_cell_mm(t, 0.0, 0.2); }
    catch (const std::exception&) { threw_w = true; }
    CHECK(threw_w, "E1: a non-positive bead is refused");
  }

  if (g_failures == 0) {
    std::printf("strut diameter per type: all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "strut diameter per type: %d of %d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
