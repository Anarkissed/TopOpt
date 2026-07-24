// Integration + parity gate for warm-start (handoff 110). Drives the production
// L-bracket LOADCASE the ladder gates build and checks:
//   (1) PARITY — with both features OFF the run is byte-for-byte identical to a
//       repeat run (determinism) AND the default path is unchanged; combined with
//       the empirical pre-change baseline documented in the handoff (cold total
//       iters == the pre-110 numbers), this is the "off == pre-change" proof.
//   (2) STRUCTURAL SKIP — warm_start_coarse with inheritance OFF touches ONLY
//       rung 0: rungs >= 1 stay byte-for-byte identical to the cold run, proving
//       the feature is a clean structural addition (and coarse_iterations > 0).
//   (3) ITERATION REDUCTION — warm_start_inherit and warmAB both cut total
//       iterations vs cold while the ACCEPT GATE's verdicts stay sound on every
//       rung (accepted => margin >= margin_stop; not accepted => a stated reason):
//       safety is initialization-independent. See gate_verdicts_sound below for
//       why this is stated as soundness rather than "every rung is accepted".
//   (4) DETERMINISM — warmAB run twice is byte-for-byte identical.
//
// Drives minimize_plastic (simp_optimize / Eigen), so it is Eigen-gated like the
// sibling optimizer gates; the real settings rule table is injected.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using namespace topopt;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                              \
    ++g_checks;                                                     \
    if (!(cond)) {                                                  \
      ++g_failures;                                                 \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg);  \
    }                                                               \
  } while (0)

namespace {

VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span; g.ny = ny; g.nz = arm; g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
  auto solid = [&](int i, int j, int k) {
    if (i < 0 || j < 0 || k < 0 || i >= span || j >= ny || k >= arm) return false;
    return g.tag(i, j, k) != VoxelTag::Empty;
  };
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i) {
        if (!solid(i, j, k)) continue;
        if (!solid(i-1,j,k)||!solid(i+1,j,k)||!solid(i,j-1,k)||!solid(i,j+1,k)||
            !solid(i,j,k-1)||!solid(i,j,k+1))
          g.set_tag(i, j, k, VoxelTag::Surface);
      }
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
}

Material fdm_material() {
  Material m;
  m.youngs_modulus_mpa = 3500.0; m.yield_strength_mpa = 55.0;
  m.density_g_cm3 = 1.24; m.z_knockdown = 0.55; m.poisson = 0.33; m.family = "fdm";
  return m;
}

MinimizePlasticOptions prod_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = SimpUpdater::MMA;
  o.infill_percent = 100.0;
  return o;
}

int total_fine_iters(const MinimizePlasticResult& r) {
  int t = 0;
  for (const auto& v : r.evaluated) t += v.optimization.iterations;
  return t;
}

// Byte-for-byte equality of two runs' rung outputs (iters, densities, margins).
bool identical(const MinimizePlasticResult& a, const MinimizePlasticResult& b) {
  if (a.evaluated.size() != b.evaluated.size()) return false;
  for (std::size_t i = 0; i < a.evaluated.size(); ++i) {
    const auto& va = a.evaluated[i];
    const auto& vb = b.evaluated[i];
    if (va.optimization.iterations != vb.optimization.iterations) return false;
    if (va.optimization.physical_density != vb.optimization.physical_density)
      return false;
    if (va.report.margin.worst_case != vb.report.margin.worst_case) return false;
    if (va.accepted != vb.accepted) return false;
  }
  return true;
}

// A single rung identical between two runs.
bool rung_identical(const MinimizePlasticVariant& a,
                    const MinimizePlasticVariant& b) {
  return a.optimization.iterations == b.optimization.iterations &&
         a.optimization.physical_density == b.optimization.physical_density &&
         a.report.margin.worst_case == b.report.margin.worst_case;
}

// "Safety is initialization-independent", stated as what the GATE must satisfy
// however the run was seeded: every rung it ACCEPTED clears the strength
// threshold, and every rung it did not accept says why (REJECTION SPEAKS). The
// second clause is not slack — it is what stops this check from being satisfied
// by a run that quietly dropped a rung.
//
// It replaces a blanket "every evaluated rung is accepted", which stopped being
// true when the CONNECTIVITY BELT landed (handoff
// 2026-07-23-gate-honesty-connectivity-rejection): on THIS fixture — the thin
// 8x3x8 L-bracket with NO anchor pad — the optimizer carves the column feeding the
// frozen Load face down to sub-threshold grey, so 2 of the 4 cold rungs come out
// with the load face floating free of the arm and are now rejected. They were
// ACCEPTED and exported before the belt, at margins around 9.8. The fixture is
// left exactly as it was: it is the warm-start baseline the handoff's iteration
// numbers were measured on, and a severed rung is a perfectly good thing for a
// warm-start test to carry as long as the gate's verdict on it is honest.
bool gate_verdicts_sound(const MinimizePlasticResult& r, double stop) {
  for (const auto& v : r.evaluated) {
    if (v.accepted) {
      if (!(v.report.margin.worst_case >= stop)) return false;
      if (!v.report.rejection_reason.empty()) return false;
    } else if (v.report.rejection_reason.empty()) {
      return false;
    }
  }
  return true;
}

std::size_t accepted_count(const MinimizePlasticResult& r) {
  std::size_t n = 0;
  for (const auto& v : r.evaluated)
    if (v.accepted) ++n;
  return n;
}

}  // namespace

int main() {
  SettingsRules rules;
  try {
    rules = load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }
  const Material material = fdm_material();

  const int arm = 8, span = 8, ny = 3, t = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);
  const std::vector<NodalLoad> tip =
      traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -5.0});

  auto run = [&](const MinimizePlasticOptions& o) {
    return minimize_plastic(part, material, "fdm", bcs, rules, o);
  };

  // --- Cold baseline (both features OFF, the default) ----------------------
  MinimizePlasticOptions cold_opts = prod_options(tip);
  const MinimizePlasticResult cold = run(cold_opts);
  const int cold_iters = total_fine_iters(cold);
  CHECK(cold.evaluated.size() >= 3, "cold: multi-rung ladder");
  CHECK(gate_verdicts_sound(cold, cold_opts.margin_stop),
        "cold: every accepted rung clears the gate, every rejected one says why");
  CHECK(accepted_count(cold) > 0, "cold: the run accepts at least one rung");
  CHECK(cold.warm_start_coarse_iterations == 0,
        "cold: no coarse pre-solve (feature off)");

  // (0) RESCALE+FILTER START (unit-level, synthetic seed): SimpOptions::initial_
  // design rescales the seed's MEAN over the design set to volume_fraction, clamps,
  // and applies one filter pass. So a CONSTANT seed at ANY level rescales to a
  // constant target_vf, which clamp+filter leave as the uniform field — i.e. a warm
  // start from a uniform field must be byte-for-byte identical to the cold uniform
  // start. This isolates and proves the documented rescale+filter seed math.
  {
    SimpParams p; p.youngs_modulus = 3500.0; p.poisson = 0.33; p.penalty = 3.0;
    SimpOptions so;
    so.volume_fraction = 0.5; so.updater = SimpUpdater::MMA; so.max_iterations = 12;
    const SimpOptimizeResult cold_s = simp_optimize(part, p, bcs, tip, so);
    so.initial_design = std::vector<double>(part.voxel_count(), 0.9);  // constant
    const SimpOptimizeResult warm_s = simp_optimize(part, p, bcs, tip, so);
    CHECK(warm_s.iterations == cold_s.iterations &&
          warm_s.physical_density == cold_s.physical_density,
          "RESCALE: constant seed rescales to uniform start -> identical to cold");
  }

  // (1) PARITY / DETERMINISM: an identical cold run is byte-for-byte identical,
  // and both flags default to OFF (prod_options never sets them).
  const MinimizePlasticResult cold2 = run(cold_opts);
  CHECK(identical(cold, cold2), "PARITY: cold run is deterministic / default path stable");
  CHECK(cold_opts.warm_start_inherit == false &&
        cold_opts.warm_start_coarse == false,
        "PARITY: warm-start defaults are OFF");

  // (2) STRUCTURAL SKIP: coarse ON, inherit OFF warm-starts ONLY rung 0. Rungs
  // >= 1 must be byte-for-byte identical to cold (they still start uniform), and
  // the coarse pre-solve must have run (coarse_iterations > 0).
  MinimizePlasticOptions b_opts = prod_options(tip);
  b_opts.warm_start_coarse = true;
  const MinimizePlasticResult warmB = run(b_opts);
  CHECK(warmB.warm_start_coarse_iterations > 0,
        "warmB: coarse pre-solve ran (coarse_iterations > 0)");
  CHECK(warmB.evaluated.size() == cold.evaluated.size(),
        "warmB: same rung count as cold");
  bool tail_identical = true;
  for (std::size_t i = 1; i < cold.evaluated.size() && i < warmB.evaluated.size();
       ++i)
    if (!rung_identical(cold.evaluated[i], warmB.evaluated[i]))
      tail_identical = false;
  CHECK(tail_identical,
        "STRUCTURAL SKIP: warmB rungs >= 1 byte-identical to cold (only rung 0 seeded)");
  CHECK(gate_verdicts_sound(warmB, b_opts.margin_stop),
        "warmB: gate verdicts still sound on every rung");
  CHECK(accepted_count(warmB) > 0, "warmB: the run accepts at least one rung");

  // (3) ITERATION REDUCTION with the gate intact — inheritance alone.
  MinimizePlasticOptions a_opts = prod_options(tip);
  a_opts.warm_start_inherit = true;
  const MinimizePlasticResult warmA = run(a_opts);
  CHECK(warmA.evaluated.size() == cold.evaluated.size(),
        "warmA: same rung count as cold");
  CHECK(total_fine_iters(warmA) < cold_iters,
        "ITERATION REDUCTION: warmA total fine iters < cold");
  CHECK(gate_verdicts_sound(warmA, a_opts.margin_stop),
        "warmA: gate verdicts still sound on every rung (safety init-independent)");
  CHECK(accepted_count(warmA) > 0, "warmA: the run accepts at least one rung");

  // (4) warmAB — the compounded win — and its determinism.
  MinimizePlasticOptions ab_opts = prod_options(tip);
  ab_opts.warm_start_inherit = true;
  ab_opts.warm_start_coarse = true;
  const MinimizePlasticResult warmAB = run(ab_opts);
  const int ab_total = total_fine_iters(warmAB) + warmAB.warm_start_coarse_iterations;
  CHECK(ab_total < cold_iters,
        "ITERATION REDUCTION: warmAB total (fine+coarse) iters < cold");
  CHECK(gate_verdicts_sound(warmAB, ab_opts.margin_stop),
        "warmAB: gate verdicts still sound on every rung");
  CHECK(accepted_count(warmAB) > 0, "warmAB: the run accepts at least one rung");
  const MinimizePlasticResult warmAB2 = run(ab_opts);
  CHECK(identical(warmAB, warmAB2), "DETERMINISM: warmAB run twice is identical");

  std::printf(
      "cold=%d  warmA=%d  warmB(fine=%d,coarse=%d)  warmAB(fine=%d,coarse=%d)\n",
      cold_iters, total_fine_iters(warmA), total_fine_iters(warmB),
      warmB.warm_start_coarse_iterations, total_fine_iters(warmAB),
      warmAB.warm_start_coarse_iterations);
  // Accepted counts alongside the iteration counts: on this un-padded bracket the
  // belt rejects the severed rungs, and a warm start (which reaches a different
  // local optimum) severs FEWER of them — reported, not asserted, because which
  // rungs sever is a property of the optimizer's basin, not a law.
  std::printf("accepted: cold=%zu  warmA=%zu  warmB=%zu  warmAB=%zu (of %zu rungs)\n",
              accepted_count(cold), accepted_count(warmA), accepted_count(warmB),
              accepted_count(warmAB), cold.evaluated.size());

  if (g_failures == 0)
    std::printf("PASS: warm_start_integration (%d checks)\n", g_checks);
  else
    std::fprintf(stderr, "FAILED: %d/%d checks\n", g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
