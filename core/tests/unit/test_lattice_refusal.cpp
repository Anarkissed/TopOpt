// test_lattice_refusal — ★ THE HOISTED PRE-SOLVE REFUSAL CANNOT FIRE WITH
// NOTHING STATED (task 2026-08-16-per-sector-density-override, bar R1').
//
// WHY THIS EXISTS INSTEAD OF A SECOND LADDER. R1 (C0 inertness) was measured as
// a byte-diff of one job on the pre-rebase base. A byte-diff proves ONE job. The
// reviewer's decision was that an unreachability proof is the stronger
// instrument here, because this task's delta has exactly two surfaces and one is
// already settled:
//
//   (i)  the grading-law branch — settled in test_grading.cpp, and
//        SABOTAGE-VERIFIED there (flipping the sentinel `> 0` to `>= 0` turns
//        exactly two checks red and nothing else);
//   (ii) the pre-solve refusal hoisted to a NEW call site in run_job.cpp,
//        immediately after the lattice regions resolve against the part grid.
//        THAT was the whole gap, and this file is it.
//
// ★ THE ASSERTION IS QUANTIFIED OVER REGION SHAPES, NOT OVER HIS PART. The
// hoisted call fires right after the regions resolve, so it sees whatever design
// the ladder returned — and a merge can change which design that is. Sweeping
// cells and widths far outside anything the test corpus contains is the point:
// "cannot fire" has to hold for shapes nobody has run.

#include "topopt/lattice.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace topopt;

static int g_checks = 0, g_failures = 0;
static void check(bool ok, const char* what, int line) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("FAIL (line %d): %s\n", line, what);
  }
}
#define CHECK(cond, msg) check((cond), (msg), __LINE__)

int main() {
  // The sweep. Cell sizes from a tenth of a millimetre to a decimetre, extrusion
  // widths across every nozzle this project has ever been pointed at and well
  // beyond, and every spelling of "nothing stated" core recognises.
  const std::vector<double> cells = {0.1,  0.25, 0.5,  1.0,   1.09, 1.3642,
                                     2.0,  2.7284, 4.0, 8.0,  16.0, 100.0};
  const std::vector<double> widths = {0.1, 0.2, 0.3, 0.4, 0.42, 0.45,
                                      0.6, 0.8, 1.0, 2.0};
  const std::vector<double> nothing_stated = {0.0, -0.0, -1e-300, -0.5, -1.0};

  // ── ★★ THE UNREACHABILITY ────────────────────────────────────────────────
  // With nothing stated the predicate is false for EVERY (cell, width) pair.
  {
    bool all_false = true;
    long long n = 0;
    for (double stated : nothing_stated)
      for (double c : cells)
        for (double w : widths) {
          ++n;
          if (lattice_stated_density_unprintable(stated, c, w)) all_false = false;
        }
    CHECK(n == (long long)(nothing_stated.size() * cells.size() * widths.size()),
          "the sweep actually ran every combination (a positive control: an "
          "empty sweep would make the next check vacuous)");
    CHECK(n > 500, "and the sweep is large enough to be worth calling a sweep");
    CHECK(all_false,
          "★ NOTHING STATED CANNOT REFUSE, for every cell size and every "
          "extrusion width — this is the C0 inertness of the hoisted pre-solve "
          "refusal, and it holds for region shapes no part in the corpus has");
  }

  // Degenerate geometry must not refuse either: a region whose cell could not be
  // derived (0, negative, non-finite) is not a printability failure, and the
  // hoisted call sees exactly such cells when a region is infeasible.
  {
    bool quiet = true;
    for (double bad : {0.0, -1.0, -0.0})
      for (double w : widths) {
        if (lattice_stated_density_unprintable(0.0, bad, w)) quiet = false;
        if (lattice_stated_density_unprintable(0.25, bad, w)) quiet = false;
      }
    CHECK(quiet,
          "a non-derivable cell does not refuse through THIS branch — "
          "infeasibility is refuse_infeasible_region_lattice's verdict and it "
          "carries a different remedy");
    bool width_quiet = true;
    for (double c : cells)
      for (double badw : {0.0, -1.0})
        if (lattice_stated_density_unprintable(0.25, c, badw)) width_quiet = false;
    CHECK(width_quiet,
          "an unset extrusion width does not refuse here either — the schema "
          "already refuses width 0, and guessing a default is the one thing "
          "printability is never allowed to do");
  }

  // ── THE POSITIVE SIDE. A stated density that genuinely cannot print MUST be
  // caught, or the unreachability above would be satisfied by a function that
  // always returns false.
  {
    // 0.06 on a 2.7284 mm cell at a 0.42 mm nozzle: the measured case from
    // r4_refusals.txt, where the CLI quotes a 0.2740042783 mm strut.
    CHECK(lattice_stated_density_unprintable(0.06, 2.7284, 0.42),
          "★ THE POSITIVE CONTROL — the measured too-light case still refuses, "
          "so the unreachability is not the trivial always-false function");
    CHECK(!lattice_stated_density_unprintable(0.25, 2.7284, 0.42),
          "and the measured printable case does not");
    CHECK(!lattice_stated_density_unprintable(0.60, 2.7284, 0.42),
          "nor the heavier one");

    // The frontier is the strut law itself, not a constant: at any cell, a
    // density refuses exactly when its strut is under the width.
    bool frontier_agrees = true;
    for (double c : cells)
      for (double w : widths)
        for (double rho : {0.06, 0.1385609912, 0.25, 0.5, 0.6, 0.89988}) {
          const bool refuses = lattice_stated_density_unprintable(rho, c, w);
          const bool thin = octet_strut_diameter_mm(rho, c) + 1e-12 < w;
          if (refuses != thin) frontier_agrees = false;
        }
    CHECK(frontier_agrees,
          "the verdict IS core's own strut law against the width — no second "
          "convention, at any cell or nozzle in the sweep");
  }

  std::printf("lattice_refusal: %d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
