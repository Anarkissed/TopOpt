// test_margin_reproduction — the certification solve is NOT a pure function of
// its arguments, and this is the band that fact justifies (task
// 2026-08-08-lattice-variant-margin-tolerance, S1).
//
// WHAT WENT WRONG. `lattice_variant_job` re-certifies a stored design and refuses
// unless the margin it gets EQUALS the margin the run recorded — a bare `==` on a
// double. Pointed at the maintainer's own 128³ run it refused all four rungs, by
// 8e-10 to 1e-9 relative. The same `==` sits in the optimize run's own lattice
// receipt (`solid_reconstruction_exact`), where it has been reporting FALSE on
// every rung of that run and nobody read it.
//
// WHY. `analyze_fixed_design`'s own header used to claim the certification solve
// is "stateless (no warm start, no cached solver) so a re-analysis of the same
// field is bit-identical". It is not. The Krylov recycling subspace
// (core/src/fea/recycle.cpp:83) is production-armed (core/src/simp/production.cpp:672)
// and carried across solves; the LADDER's certification runs with it warm, and
// every RE-certification runs inside `ScopedLadderSolverIsolation`
// (core/src/cli/run_job.cpp:2517), which disables it on purpose so the lattice
// post-process cannot perturb the ladder. Two Krylov paths, one operator, one
// residual tolerance — two points inside the same residual ball.
//
// This test reproduces that IN PROCESS, on a fixture in the same solver regime the
// maintainer's part is in (matrix-free Jacobi-CG, because the hierarchy is
// rejected), and then pins the three things that matter:
//
//   B1  the two solves really do differ — the `==` really was unsatisfiable;
//   B2  the band admits that difference;
//   B3  the band still refuses a change to the OBJECT — a load moved by one part
//       in 10^4, four orders of magnitude smaller than anything a user can do by
//       accident, is refused with room to spare.
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness the
// other core unit tests use, public API only.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <vector>

using topopt::analyze_fixed_design;
using topopt::DirichletBC;
using topopt::FixedDesignAnalysis;
using topopt::KnockdownSpec;
using topopt::kMarginReproductionResidualFactor;
using topopt::margin_reproduces;
using topopt::margin_reproduction_relative_delta;
using topopt::Material;
using topopt::NodalLoad;
using topopt::SimpParams;
using topopt::SolverKind;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg)                                          \
  do {                                                            \
    ++g_checks;                                                   \
    if (!(cond)) {                                                \
      ++g_failures;                                               \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                             \
  } while (0)

namespace {

// The production certification tolerance (minimize_plastic's kCertTol). Every
// band in this file is derived from it, never from an observed spread.
constexpr double kCertTol = 1e-8;

VoxelGrid make_solid_grid(int nx, int ny, int nz, double h) {
  VoxelGrid g;
  g.nx = nx;
  g.ny = ny;
  g.nz = nz;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(nx) * ny * nz, VoxelTag::Interior);
  return g;
}

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

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0;
  m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24;
  m.z_knockdown = 0.55;
  m.poisson = 0.33;
  m.family = "fdm";
  return m;
}

// A GRADED density field, so the operator is high-contrast enough that the
// Jacobi-CG solve takes hundreds of iterations — the regime the recycler is
// there for, and the regime the maintainer's part sits in.
std::vector<double> graded_density(const VoxelGrid& g) {
  std::vector<double> rho(g.voxel_count(), 0.0);
  for (int k = 0; k < g.nz; ++k)
    for (int j = 0; j < g.ny; ++j)
      for (int i = 0; i < g.nx; ++i) {
        const double x = static_cast<double>(i) / std::max(1, g.nx - 1);
        const double z = static_cast<double>(k) / std::max(1, g.nz - 1);
        rho[g.index(i, j, k)] = 0.25 + 0.7 * std::abs(0.5 - z) * 2.0 * (1.0 - 0.5 * x);
      }
  return rho;
}

FixedDesignAnalysis certify(const VoxelGrid& g, const std::vector<double>& rho,
                            const std::vector<DirichletBC>& bcs,
                            const std::vector<NodalLoad>& loads) {
  SimpParams p;
  p.youngs_modulus = 3500.0;
  p.poisson = 0.33;
  p.penalty = 3.0;
  return analyze_fixed_design(g, p, rho, bcs, loads, fdm_material(),
                              Vec3{0.0, 0.0, 1.0}, kCertTol, 0,
                              SolverKind::MultigridCG_Matfree, /*margin_stop=*/0.0,
                              KnockdownSpec{}, /*load_path_ok=*/true,
                              /*part_solid=*/static_cast<double>(g.voxel_count()));
}

// ---------------------------------------------------------------------------
// A. The predicate itself.

void section_predicate() {
  const double band = kMarginReproductionResidualFactor * kCertTol;  // 1e-6
  CHECK(band == 1e-6, "A: the production band is 1e-6 relative (100 x 1e-8)");

  CHECK(margin_reproduction_relative_delta(2000.0, 2000.0) == 0.0,
        "A: an exact reproduction has zero relative delta");
  CHECK(margin_reproduces(2000.0, 2000.0, kCertTol),
        "A: …and passes");

  // The measured shape of the real thing: his vf=0.68 rung, 2169.617171 recorded
  // against 2169.617163 reproduced.
  const double d = margin_reproduction_relative_delta(2169.617171, 2169.617163);
  CHECK(d > 0.0 && d < band,
        "A: the maintainer's own rung-0.68 delta is inside the band");
  CHECK(d > 1e-9 && d < 1e-8,
        "A: …and it is of order 1e-9 — the ninth significant figure, which is "
        "what 'reproduces to 9 s.f. and no further' means as a number");
  CHECK(margin_reproduces(2169.617171, 2169.617163, kCertTol),
        "A: …so the band accepts the rung the bare == refused");
  CHECK(!(2169.617171 == 2169.617163),
        "A: …which the bare == did not, and that is the whole defect");

  // Right at the edge, both sides.
  CHECK(margin_reproduces(1000.0, 1000.0 * (1.0 + 0.9 * band), kCertTol),
        "A: 0.9 x the band passes");
  CHECK(!margin_reproduces(1000.0, 1000.0 * (1.0 + 1.1 * band), kCertTol),
        "A: 1.1 x the band does NOT");

  // A change to the OBJECT, at the scale section C measures: refused by four
  // orders of magnitude.
  CHECK(!margin_reproduces(1000.0, 1000.1, kCertTol),
        "A: one part in 10^4 is refused");
  CHECK(!margin_reproduces(1000.0, 900.0, kCertTol),
        "A: a different design is refused");

  // Degenerate inputs can never sneak through a band.
  const double inf = std::numeric_limits<double>::infinity();
  CHECK(margin_reproduces(inf, inf, kCertTol),
        "A: two infinities (a zero-stress posture) reproduce exactly");
  CHECK(!margin_reproduces(inf, 1000.0, kCertTol),
        "A: infinity against a finite margin does not");
  CHECK(!margin_reproduces(0.0, 1e-30, kCertTol),
        "A: a zero denominator admits nothing but exact equality");
  CHECK(margin_reproduces(0.0, 0.0, kCertTol), "A: …and zero against zero passes");
  CHECK(!margin_reproduces(std::nan(""), std::nan(""), kCertTol),
        "A: NaN never reproduces anything, including itself");

  // NO DECLARED TOLERANCE -> NO INVENTED BAND. The band's whole justification is
  // that it is a multiple of a residual tolerance both solves met; without one,
  // the comparison falls back to the exact equality it replaced.
  CHECK(!margin_reproduces(2169.617171, 2169.617163, 0.0),
        "A: with no declared cg_tolerance the check is EXACT again");
  CHECK(margin_reproduces(2169.617171, 2169.617171, 0.0),
        "A: …and only exact equality passes there");
}

// ---------------------------------------------------------------------------
// B. The mechanism, in process.

void section_mechanism() {
  // Force the regime his part is in: the parity pad OFF plus an odd axis makes
  // the coarsening rule REJECT the hierarchy, so every solve is matrix-free
  // Jacobi-CG — which is the only path the recycler wraps
  // (fea_set_krylov_recycle_wrap_multigrid(false), production.cpp:673). On his
  // 128³ run the hierarchy built on 3 solves out of 445 for the same reason: the
  // grid does not coarsen.
  const int pad_before = topopt::fea_mg_parity_pad_mode();
  topopt::fea_set_mg_parity_pad_mode(0);
  const bool rc_before = topopt::fea_set_krylov_recycling(false);

  const VoxelGrid g = make_solid_grid(23, 7, 11, 2.0);
  const std::vector<DirichletBC> bcs = clamp_x0_face(g);
  const std::vector<NodalLoad> loads = tip_load_z(g, -40.0);
  const std::vector<double> rho = graded_density(g);

  // THE LADDER's posture: recycling armed, and a subspace already harvested from
  // the solves that came before this rung's certification. Three warm-up solves
  // stand in for the trajectory's hundreds; the recycler bootstraps on the first
  // and applies from the second.
  topopt::fea_set_krylov_recycling(true);
  for (int i = 0; i < 3; ++i) {
    std::vector<double> warm = rho;
    for (std::size_t e = 0; e < warm.size(); ++e)
      warm[e] = std::min(1.0, warm[e] * (1.0 + 0.01 * (i + 1)));
    (void)certify(g, warm, bcs, loads);
  }
  const FixedDesignAnalysis recorded = certify(g, rho, bcs, loads);

  // THE RE-CERTIFICATION's posture: ScopedLadderSolverIsolation, i.e. recycling
  // off. Identical grid, density, BCs, loads, params, solver and tolerance.
  topopt::fea_set_krylov_recycling(false);
  const FixedDesignAnalysis reproduced = certify(g, rho, bcs, loads);

  CHECK(!recorded.non_convergent && !reproduced.non_convergent,
        "B: both certification solves converged");

  const double delta = margin_reproduction_relative_delta(
      recorded.margin.worst_case, reproduced.margin.worst_case);
  std::fprintf(stderr,
               "  B: recorded %.17g  reproduced %.17g  relative delta %.3g "
               "(band %.3g)\n",
               recorded.margin.worst_case, reproduced.margin.worst_case, delta,
               kMarginReproductionResidualFactor * kCertTol);

  // B1 — the defect, pinned. If this ever passes bit-for-bit again, the band is
  // no longer needed and someone should be told rather than the test quietly
  // going green on a different fact.
  CHECK(recorded.margin.worst_case != reproduced.margin.worst_case,
        "B1: the SAME inputs give DIFFERENT margins with the recycler armed vs "
        "disarmed — analyze_fixed_design is not a pure function of its "
        "arguments, and the bare == was unsatisfiable");

  // B2 — and the band, derived from the residual tolerance both solves met,
  // admits exactly that.
  CHECK(margin_reproduces(recorded.margin.worst_case, reproduced.margin.worst_case,
                          kCertTol),
        "B2: the band accepts a difference caused only by the Krylov path");
  CHECK(delta < kMarginReproductionResidualFactor * kCertTol,
        "B2: …with the measured delta strictly inside it");

  // B3 — THE PROTECTION SURVIVES. Move the declared load by one part in 10^4 —
  // far smaller than any real "wrong load case" — and the same band refuses.
  std::vector<NodalLoad> nudged = loads;
  for (NodalLoad& l : nudged) l.value *= 1.0001;
  const FixedDesignAnalysis other = certify(g, rho, bcs, nudged);
  const double load_delta = margin_reproduction_relative_delta(
      recorded.margin.worst_case, other.margin.worst_case);
  std::fprintf(stderr, "  B3: load off by 1e-4 -> relative delta %.3g\n", load_delta);
  CHECK(!margin_reproduces(recorded.margin.worst_case, other.margin.worst_case,
                           kCertTol),
        "B3: a load case off by one part in 10^4 is still REFUSED — the check "
        "protects what it was written to protect");
  CHECK(load_delta > 100.0 * delta,
        "B3: …and the corruption is orders of magnitude clear of the solver "
        "noise the band admits, so the band is not squeezed between them");

  // A DIFFERENT DESIGN is refused too, by far more.
  std::vector<double> other_rho = rho;
  for (std::size_t e = 0; e < other_rho.size(); ++e)
    other_rho[e] = std::min(1.0, other_rho[e] * 1.02);
  const FixedDesignAnalysis other_design = certify(g, other_rho, bcs, loads);
  const double dense_delta = margin_reproduction_relative_delta(
      recorded.margin.worst_case, other_design.margin.worst_case);
  std::fprintf(stderr, "  B3: design 2 %% denser -> relative delta %.3g\n",
               dense_delta);
  CHECK(!margin_reproduces(recorded.margin.worst_case,
                           other_design.margin.worst_case, kCertTol),
        "B3: a design 2 % denser is REFUSED");

  // ★ THE FLOOR OF WHAT THE BAND MUST CATCH: ONE VOXEL. The smallest change to
  // the design that can be made at all — a single voxel taken from its graded
  // value to solid — is what sets the bottom of the "different object" range, and
  // the band has to sit below it with room. Measured rather than assumed, and the
  // voxel picked is an interior one carrying load, not a corner.
  std::vector<double> one_voxel = rho;
  one_voxel[g.index(g.nx / 2, g.ny / 2, g.nz / 2)] = 1.0;
  const FixedDesignAnalysis flipped = certify(g, one_voxel, bcs, loads);
  const double voxel_delta = margin_reproduction_relative_delta(
      recorded.margin.worst_case, flipped.margin.worst_case);
  std::fprintf(stderr, "  B3: ONE voxel flipped to solid -> relative delta %.3g\n",
               voxel_delta);
  CHECK(voxel_delta > 0.0,
        "B3: one voxel moves the margin at all — otherwise this measures nothing");
  CHECK(!margin_reproduces(recorded.margin.worst_case,
                           flipped.margin.worst_case, kCertTol),
        "B3: ONE flipped voxel is REFUSED — the band sits below the smallest "
        "change that can be made to the design");
  CHECK(voxel_delta > 10.0 * kMarginReproductionResidualFactor * kCertTol,
        "B3: …with at least an order of magnitude of clearance above the band, "
        "so the band is not wedged against the thing it must catch");

  topopt::fea_set_krylov_recycling(rc_before);
  topopt::fea_set_mg_parity_pad_mode(pad_before);
}

}  // namespace

int main() {
  section_predicate();
  section_mechanism();
  std::fprintf(stderr, "margin_reproduction: %d checks, %d failures\n", g_checks,
               g_failures);
  return g_failures == 0 ? 0 : 1;
}
