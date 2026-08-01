// SIMP penalization continuation (task 2026-08-02-simp-penalization-
// continuation) — validation.
//
// SimpOptions::penalty_continuation ramps the SIMP penalization exponent p
// across a run's design iterations instead of applying the documented p = 3 from
// iteration 1. The MEASUREMENT bars (does it rescue the multigrid stagnation, at
// what wall, and what does it do to the gate table) live in the standalone probe
// and the handoff, not here. What a unit test can pin — and what this one pins —
// is the CONTRACT:
//
//   AD1  OFF is BYTE-IDENTICAL. An empty schedule (the default) forwards the
//        caller's params unchanged, on BOTH simp_optimize overloads. Stronger:
//        a schedule that is CONSTANT at params.penalty is byte-identical to OFF
//        too, which pins that the substitution machinery itself introduces no
//        arithmetic — the only thing that can move the design is a DIFFERENT p.
//   pure The schedule -> penalty map is a pure, exactly-reproducible function
//        with the documented stage semantics and hold-past-the-end rule, and the
//        ramp builder lands its endpoints EXACTLY (1.0 -> 3.0 by 0.25 ends on
//        3.00, not 2.9999999999999996).
//   lit  The two published schedules are reproduced verbatim, INCLUDING the
//        consequence that matters here: Peetz & Elbanna's 20-iterations-per-value
//        schedule never leaves p = 1.0 inside a production-length rung.
//   wire A NON-constant schedule actually MOVES the design and is REPORTED on
//        the per-iteration observation — the feature is live, not silently
//        ignored (125 §0).
//   cert The certified final compliance is ALWAYS computed at params.penalty,
//        never at the schedule's terminal p. A schedule whose last stage is not
//        params.penalty is legal but is a trajectory/certificate MISMATCH, and
//        this pins which side the certificate is on.
//   scope The stress path REFUSES a schedule; the numeric guards reject nonsense.
//
// No third-party framework (ARCHITECTURE §4) — the same self-contained CHECK
// harness and public API as test_mma.cpp / test_adaptive_move.cpp.

#include "topopt/fea.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::NodalLoad;
using topopt::PenaltyStage;
using topopt::SimpIterationObservation;
using topopt::SimpOptimizeResult;
using topopt::SimpOptions;
using topopt::SimpParams;
using topopt::SimpUpdater;
using topopt::StressConstraint;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_checks = 0;
static int g_failures = 0;
#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

VoxelGrid solid_grid(int nx, int ny, int nz) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = 1.0;
  g.origin = topopt::Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

struct Problem {
  VoxelGrid grid;
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> loads;
};

Problem make_cantilever(int nx, int ny, int nz) {
  Problem pr;
  pr.grid = solid_grid(nx, ny, nz);
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b) {
      const int n = topopt::fea_node_index(pr.grid, 0, b, c);
      pr.bcs.push_back({n, 0, 0.0});
      pr.bcs.push_back({n, 1, 0.0});
      pr.bcs.push_back({n, 2, 0.0});
    }
  const double fz = -1.0 / static_cast<double>((ny + 1) * (nz + 1));
  for (int c = 0; c <= nz; ++c)
    for (int b = 0; b <= ny; ++b)
      pr.loads.push_back({topopt::fea_node_index(pr.grid, nx, b, c), 2, fz});
  return pr;
}

SimpParams bench_params() {
  SimpParams p;
  p.youngs_modulus = 1.0;
  p.poisson = 0.3;
  p.penalty = 3.0;  // ARCHITECTURE §4 — the documented, shipped exponent
  p.density_min = 1e-3;
  return p;
}

SimpOptions bench_options() {
  SimpOptions opt;
  opt.volume_fraction = 0.3;
  opt.filter_radius = 2.5;
  opt.move = 0.2;
  opt.max_iterations = 24;
  opt.change_tol = 0.01;
  opt.cg_tolerance = 1e-9;
  opt.updater = SimpUpdater::MMA;
  return opt;
}

DesignMask all_active(const VoxelGrid& g) {
  return DesignMask(g.voxel_count(), MaskValue::Active);
}

double design_maxdiff(const SimpOptimizeResult& a, const SimpOptimizeResult& b) {
  double d = 0.0;
  const std::size_t n = std::min(a.design.size(), b.design.size());
  for (std::size_t e = 0; e < n; ++e)
    d = std::max(d, std::fabs(a.design[e] - b.design[e]));
  return d;
}

bool throws_invalid(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

}  // namespace

int main() {
  const SimpParams p = bench_params();
  const Problem pr = make_cantilever(24, 8, 8);
  const DesignMask mask = all_active(pr.grid);

  // ==========================================================================
  // pure. penalty_at_iteration: stage semantics, exactly.
  // ==========================================================================
  {
    const std::vector<PenaltyStage> s = {{1.0, 2}, {2.0, 3}, {3.0, 1}};
    // Stages are consumed cumulatively over the 1-based iteration index:
    // iters 1-2 -> 1.0, iters 3-5 -> 2.0, iter 6 -> 3.0.
    CHECK(topopt::penalty_at_iteration(s, 1) == 1.0, "pure: iter 1 -> stage 1");
    CHECK(topopt::penalty_at_iteration(s, 2) == 1.0, "pure: iter 2 -> stage 1");
    CHECK(topopt::penalty_at_iteration(s, 3) == 2.0, "pure: iter 3 -> stage 2");
    CHECK(topopt::penalty_at_iteration(s, 5) == 2.0, "pure: iter 5 -> stage 2");
    CHECK(topopt::penalty_at_iteration(s, 6) == 3.0, "pure: iter 6 -> stage 3");
    // Past the end the LAST stage's penalty is HELD, forever.
    CHECK(topopt::penalty_at_iteration(s, 7) == 3.0, "pure: past-end holds last");
    CHECK(topopt::penalty_at_iteration(s, 100000) == 3.0,
          "pure: past-end holds last however far past");
    // Pure: the same query twice is the same double, bit for bit.
    CHECK(topopt::penalty_at_iteration(s, 4) ==
              topopt::penalty_at_iteration(s, 4),
          "pure: repeated query is bit-identical");
    // Refusals, not silent defaults.
    CHECK(throws_invalid([] {
            topopt::penalty_at_iteration(std::vector<PenaltyStage>{}, 1);
          }),
          "pure: an EMPTY schedule is refused (empty means OFF, not p = 0)");
    CHECK(throws_invalid([&] { topopt::penalty_at_iteration(s, 0); }),
          "pure: iteration 0 is refused (the index is 1-based)");
  }

  // ==========================================================================
  // pure. penalty_continuation_ramp: endpoints land EXACTLY.
  // ==========================================================================
  {
    const std::vector<PenaltyStage> r =
        topopt::penalty_continuation_ramp(1.0, 3.0, 0.25, 2);
    CHECK(r.size() == 9, "ramp: 1.0 -> 3.0 by 0.25 is 9 stages");
    CHECK(r.front().penalty == 1.0, "ramp: starts exactly at p0");
    CHECK(r.back().penalty == 3.0,
          "ramp: ends EXACTLY at p1 (3.0, not 2.9999999999999996)");
    CHECK(r[4].penalty == 2.0, "ramp: the midpoint value is exact");
    for (const PenaltyStage& st : r)
      CHECK(st.iterations == 2, "ramp: every stage gets iterations_per_stage");
    // A degenerate ramp (p0 == p1) is a single stage, not an empty schedule.
    const std::vector<PenaltyStage> one =
        topopt::penalty_continuation_ramp(3.0, 3.0, 0.25, 5);
    CHECK(one.size() == 1 && one[0].penalty == 3.0,
          "ramp: p0 == p1 is one stage at that penalty");
    CHECK(throws_invalid([] { topopt::penalty_continuation_ramp(0.0, 3.0, 0.25, 1); }),
          "ramp: p0 <= 0 is refused");
    CHECK(throws_invalid([] { topopt::penalty_continuation_ramp(3.0, 1.0, 0.25, 1); }),
          "ramp: p1 < p0 is refused");
    CHECK(throws_invalid([] { topopt::penalty_continuation_ramp(1.0, 3.0, 0.0, 1); }),
          "ramp: step <= 0 is refused");
    CHECK(throws_invalid([] { topopt::penalty_continuation_ramp(1.0, 3.0, 0.25, 0); }),
          "ramp: iterations_per_stage < 1 is refused");
  }

  // ==========================================================================
  // lit. The published schedule, verbatim — and its consequence here.
  // ==========================================================================
  {
    const std::vector<PenaltyStage> peetz = topopt::penalty_continuation_peetz();
    // "penalty increased in increments of 0.25 from 1 to 4" -> 13 values.
    CHECK(peetz.size() == 13, "lit: Peetz has 13 penalty values (1.00 .. 4.00)");
    CHECK(peetz.front().penalty == 1.0, "lit: Peetz starts at p = 1");
    CHECK(peetz.back().penalty == 4.0, "lit: Peetz ends at p = 4");
    // "20 optimization iterations per penalty value".
    for (const PenaltyStage& st : peetz)
      CHECK(st.iterations == 20, "lit: Peetz holds each value 20 iterations");
    // THE CONSEQUENCE, pinned because it decides whether the schedule does
    // anything at all on this project: a production rung runs a 16-30 iteration
    // budget, and the literal schedule has not left its FIRST stage by then.
    CHECK(topopt::penalty_at_iteration(peetz, 16) == 1.0,
          "lit: at iteration 16 the literal Peetz schedule is STILL at p = 1.0");
    CHECK(topopt::penalty_at_iteration(peetz, 20) == 1.0,
          "lit: it only leaves p = 1.0 after its 20th iteration");
    CHECK(topopt::penalty_at_iteration(peetz, 21) == 1.25,
          "lit: stage 2 begins at iteration 21");
  }

  // ==========================================================================
  // AD1. OFF is byte-identical — and so is a CONSTANT schedule at params.penalty.
  // ==========================================================================
  {
    SimpOptions off = bench_options();  // penalty_continuation defaults empty
    // A schedule that is constant at the shipped p. Byte-identity here is the
    // stronger statement: the substitution path itself adds no arithmetic, so
    // any design motion under a real schedule is the DIFFERENT p, not the
    // plumbing.
    SimpOptions constant3 = bench_options();
    constant3.penalty_continuation = {{3.0, 1}};  // 1 stage, then held forever

    const SimpOptimizeResult a =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off);
    const SimpOptimizeResult b =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, constant3);
    CHECK(a.iterations == b.iterations,
          "AD1 plain: constant-p schedule runs the same iteration count as OFF");
    CHECK(a.compliance == b.compliance,
          "AD1 plain: constant-p schedule gives a bit-identical compliance");
    CHECK(design_maxdiff(a, b) == 0.0,
          "AD1 plain: constant-p schedule gives a bit-identical design");

    const SimpOptimizeResult am =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off, mask);
    const SimpOptimizeResult bm =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, constant3, mask);
    CHECK(am.iterations == bm.iterations,
          "AD1 masked: constant-p schedule runs the same iteration count as OFF");
    CHECK(am.compliance == bm.compliance,
          "AD1 masked: constant-p schedule gives a bit-identical compliance");
    CHECK(design_maxdiff(am, bm) == 0.0,
          "AD1 masked: constant-p schedule gives a bit-identical design");

    // Determinism of the OFF path itself (the baseline the checksum bar rests on).
    const SimpOptimizeResult a2 =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off);
    CHECK(a2.compliance == a.compliance && design_maxdiff(a, a2) == 0.0,
          "AD1: the OFF path is deterministic run-to-run");
  }

  // ==========================================================================
  // wire. A non-constant schedule MOVES the design and is REPORTED per iteration.
  // ==========================================================================
  {
    SimpOptions off = bench_options();
    SimpOptions ramp = bench_options();
    // 1.0, 1.5, 2.0, 2.5, 3.0 at 2 iterations each; p = 3.0 held from iter 11.
    ramp.penalty_continuation = topopt::penalty_continuation_ramp(1.0, 3.0, 0.5, 2);

    std::vector<double> seen;
    ramp.observe = [&](const SimpIterationObservation& o) {
      seen.push_back(o.penalty);
    };
    std::vector<double> seen_off;
    off.observe = [&](const SimpIterationObservation& o) {
      seen_off.push_back(o.penalty);
    };

    const SimpOptimizeResult a =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, off, mask);
    const SimpOptimizeResult b =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, ramp, mask);

    CHECK(design_maxdiff(a, b) > 0.0,
          "wire: a non-constant schedule CHANGES the design (not ignored)");
    CHECK(!seen.empty() && seen[0] == 1.0,
          "wire: iteration 1 is reported at the schedule's first penalty");
    CHECK(seen.size() < 3 || seen[2] == 1.5,
          "wire: iteration 3 is reported at the second stage's penalty");
    CHECK(seen.size() < 11 || seen[10] == 3.0,
          "wire: past the schedule the held penalty is reported");
    // On the OFF path the column still reads the shipped exponent on every row,
    // so the trace says which law produced each number without a special case.
    CHECK(!seen_off.empty(), "wire: the OFF path still observes iterations");
    bool all3 = true;
    for (double v : seen_off) all3 = all3 && (v == 3.0);
    CHECK(all3, "wire: OFF reports p = params.penalty (3) on EVERY row");
  }

  // ==========================================================================
  // cert. The certificate is computed at params.penalty, not the schedule's end.
  // ==========================================================================
  {
    // Two schedules with the SAME trajectory prefix but different terminal p
    // would confound this; instead compare a schedule against a direct analysis
    // of ITS OWN converged field at params.penalty. If the final solve used the
    // schedule's terminal penalty (4.0 here) the two would disagree.
    SimpOptions ramp4 = bench_options();
    ramp4.penalty_continuation = topopt::penalty_continuation_ramp(1.0, 4.0, 0.5, 2);
    const SimpOptimizeResult r =
        topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, ramp4, mask);
    const topopt::SimpCompliance at_shipped_p =
        topopt::simp_compliance(pr.grid, p, r.physical_density, pr.bcs, pr.loads,
                                bench_options().cg_tolerance);
    CHECK(std::fabs(r.compliance - at_shipped_p.compliance) <=
              1e-6 * std::fabs(at_shipped_p.compliance),
          "cert: the returned compliance is the field analysed at params.penalty");
    // And it is NOT the terminal-schedule analysis (p = 4 is a materially
    // different law on a partly-gray field), so the check above has teeth.
    SimpParams p4 = p;
    p4.penalty = 4.0;
    const topopt::SimpCompliance at_terminal_p =
        topopt::simp_compliance(pr.grid, p4, r.physical_density, pr.bcs, pr.loads,
                                bench_options().cg_tolerance);
    CHECK(std::fabs(at_terminal_p.compliance - at_shipped_p.compliance) >
              1e-6 * std::fabs(at_shipped_p.compliance),
          "cert: p = 3 and p = 4 analyses of this field genuinely differ");
  }

  // ==========================================================================
  // scope. Refusals: the stress path, and malformed stages.
  // ==========================================================================
  {
    SimpOptions bad = bench_options();
    bad.penalty_continuation = {{0.0, 5}};
    CHECK(throws_invalid([&] {
            topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, bad);
          }),
          "scope: a stage penalty <= 0 is refused (plain overload)");
    CHECK(throws_invalid([&] {
            topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, bad, mask);
          }),
          "scope: a stage penalty <= 0 is refused (masked overload)");

    SimpOptions bad_it = bench_options();
    bad_it.penalty_continuation = {{2.0, 0}};
    CHECK(throws_invalid([&] {
            topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, bad_it, mask);
          }),
          "scope: a stage with 0 iterations is refused");

    SimpOptions inf_p = bench_options();
    inf_p.penalty_continuation = {
        {std::numeric_limits<double>::infinity(), 5}};
    CHECK(throws_invalid([&] {
            topopt::simp_optimize(pr.grid, p, pr.bcs, pr.loads, inf_p, mask);
          }),
          "scope: a non-finite stage penalty is refused");

    SimpOptions stress_opt = bench_options();
    stress_opt.penalty_continuation =
        topopt::penalty_continuation_ramp(1.0, 3.0, 0.5, 2);
    StressConstraint sc;
    sc.stress_cap = 1.0;
    sc.p_norm = 8.0;
    sc.relaxation_q = 0.5;
    CHECK(throws_invalid([&] {
            topopt::simp_optimize_stress(pr.grid, p, pr.bcs, pr.loads, stress_opt,
                                         sc);
          }),
          "scope: the stress path REFUSES a schedule (never silently ignores it)");
  }

  std::printf("%s: %d checks, %d failures\n",
              g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
