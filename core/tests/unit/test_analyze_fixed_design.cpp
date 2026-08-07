// test_analyze_fixed_design — THE correctness bar for the standalone analysis
// entry point (handoff 2026-07-26-constrained-smooth).
//
// The claim: analyze_fixed_design, handed a variant's OWN converged geometry
// (its density) plus the same grid / BCs / loads / params / solver / tolerance the
// run used, reproduces that variant's certification numbers BIT-FOR-BIT — not
// "within tolerance", identical. This is what says the extracted engine IS the
// optimizer's per-rung recovery block, so a standalone re-analysis of an edited
// mesh is measured on exactly the same physics the run reports.
//
// It is provable because minimize_plastic's recovery block CALLS
// analyze_fixed_design (single source of truth): run one rung, then call
// analyze_fixed_design directly on that variant's converged density and compare
// every field. No warm start and no cached solver is passed, so re-running it on
// the same inputs is exact.
//
// *** AND THE CONDITION UNDER WHICH THAT HOLDS, NAMED (task
// 2026-08-08-lattice-variant-margin-tolerance). *** It holds HERE because the
// library ships with Krylov recycling DISARMED, so nothing is carried between
// these solves. A PRODUCTION run arms it (core/src/simp/production.cpp:672) and
// carries the subspace across solves on purpose, which makes the same two calls
// land at two different points inside the same residual ball — measured at 7e-9
// relative in test_margin_reproduction, and the reason `lattice_variant`'s
// reproduction check is a band and not a `==`. Nothing below is weakened: this
// file's claim is exactly as strong as it was, and it now says what it depends on.
//
// Also asserts the engine NEVER optimizes: it runs one solve and returns; there is
// no ladder, no iteration, no design change (the density it is handed is the
// density it analyses).
//
// No third-party framework (ARCHITECTURE §4): the self-contained CHECK harness the
// other core unit tests use, public API only.

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/mesh.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/report.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <vector>

using topopt::analyze_fixed_design;
using topopt::DirichletBC;
using topopt::FixedDesignAnalysis;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::MinimizePlasticVariant;
using topopt::NodalLoad;
using topopt::SettingsRules;
using topopt::SimpParams;
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

Vec3 normalized(const Vec3& v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return Vec3{v.x / n, v.y / n, v.z / n};
}

// Count DOFs at which two fields differ AT ALL (not beyond a tol) — the only
// acceptable answer for "the same solve, re-run" is zero.
std::size_t differing(const std::vector<double>& a, const std::vector<double>& b) {
  if (a.size() != b.size()) return a.size() + b.size() + 1;
  std::size_t n = 0;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i] != b[i]) ++n;
  return n;
}

}  // namespace

int main() {
  SettingsRules rules;
  try {
    rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  } catch (const std::exception& e) {
    std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
    return 1;
  }

  // A clamped-root, tip-loaded cantilever — an EXTERNAL load, so the part carries
  // real stress and the margin is a finite, meaningful number (unlike a
  // self-weight demo whose margins are astronomically over-provisioned). This is
  // exactly the kind of loaded case that makes the re-certification bite.
  const VoxelGrid g = make_solid_grid(24, 12, 12, 1.0);
  const std::vector<DirichletBC> bcs = clamp_x0_face(g);
  const std::vector<NodalLoad> tip = tip_load_z(g, -50.0);
  const Material material = fdm_material();

  MinimizePlasticOptions o;
  o.volume_fraction_ladder = {0.5};
  o.margin_stop = 0.0;  // accept whatever converges (verdict tested separately below)
  o.gravity = 0.0;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.external_loads = tip;
  o.simp.cg_tolerance = 1e-8;
  o.simp.max_iterations = 40;

  const MinimizePlasticResult result =
      topopt::minimize_plastic(g, material, "PLA_test", bcs, rules, o);
  CHECK(result.evaluated.size() == 1, "one rung evaluated");
  if (result.evaluated.empty()) {
    std::fprintf(stderr, "no variant produced; aborting\n");
    return 1;
  }
  const MinimizePlasticVariant& v = result.evaluated[0];
  CHECK(!v.infeasible, "the cantilever rung is feasible (was analysed)");
  CHECK(!v.von_mises_field.empty(), "the run produced a stress field to match");

  // Reconstruct the EXACT inputs the recovery block handed analyze_fixed_design.
  // No design box => the solved grid IS `g`, the BCs are `bcs`, the loads are the
  // external tip load; params are the material's E/nu with the hardcoded penalty 3.
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;  // ARCHITECTURE §4 (density_min stays the 1e-3 default)
  // THE ORIENTATION THE RECOVERY BLOCK ACTUALLY USED. Since handoff
  // 2026-08-01-bake-build-orientation a run with no declared build direction
  // CHOOSES one (and rotates its export onto it), so the certification numbers
  // describe `applied_build_dir` — not the old unit(-gravity) inference. Feeding
  // this in is what makes the reconstruction below EXACT inputs rather than
  // nearly-the-same inputs; the bar itself is untouched.
  const Vec3 build_dir = v.applied_build_dir;
  // ... and it is genuinely load-bearing on this fixture: the run chose an
  // orientation, and the naive inference is a DIFFERENT vector. If these ever
  // coincide the checks below would pass vacuously, so say which case we are in.
  const Vec3 inferred = normalized(Vec3{-o.gravity_direction.x,
                                        -o.gravity_direction.y,
                                        -o.gravity_direction.z});
  std::printf(
      "[analyze] run certified at (%.3g, %.3g, %.3g); gravity inference was "
      "(%.3g, %.3g, %.3g); auto-applied=%s\n",
      build_dir.x, build_dir.y, build_dir.z, inferred.x, inferred.y, inferred.z,
      v.build_direction_auto_applied ? "yes" : "no");
  topopt::KnockdownSpec knockdown;
  knockdown.infill_knockdown = topopt::infill_margin_knockdown(o.infill_percent);
  const bool load_path_ok =
      topopt::load_path_connected(g, v.optimization.physical_density, 0.5);
  const double part_solid = static_cast<double>(g.solid_count());

  const FixedDesignAnalysis a = analyze_fixed_design(
      g, params, v.optimization.physical_density, bcs, tip, material, build_dir,
      o.simp.cg_tolerance, o.simp.cg_max_iterations, o.simp.solver, o.margin_stop,
      knockdown, load_path_ok, part_solid);

  // --- THE BAR: every certification number bit-identical to the run's ----------
  CHECK(differing(a.von_mises_field, v.von_mises_field) == 0,
        "von Mises field bit-identical to the run");
  CHECK(differing(a.stress_tensor_field, v.stress_tensor_field) == 0,
        "Cauchy stress tensor field bit-identical to the run");
  CHECK(differing(a.displacement_field, v.displacement_field) == 0,
        "displacement field bit-identical to the run");
  CHECK(a.mass_grams == v.mass_grams, "printed mass bit-identical to the run");
  CHECK(a.support_volume_voxels == v.support_volume_voxels,
        "support volume bit-identical to the run");
  CHECK(a.max_von_mises == v.report.max_stress_mpa,
        "peak von Mises bit-identical to the run");
  CHECK(a.max_interlayer_tension == v.report.max_interlayer_tension_mpa,
        "peak interlayer tension bit-identical to the run");
  CHECK(a.margin.in_plane == v.report.margin.in_plane,
        "in-plane margin bit-identical to the run");
  CHECK(a.margin.interlayer == v.report.margin.interlayer,
        "interlayer margin bit-identical to the run");
  CHECK(a.margin.worst_case == v.report.margin.worst_case,
        "worst-case margin bit-identical to the run");
  CHECK(a.margin_effective == v.report.margin_effective,
        "infill-adjusted margin bit-identical to the run");
  CHECK(a.v3.min_feature_violations == v.report.min_feature_violations,
        "min-feature violation count bit-identical to the run");
  CHECK(a.printed_fraction == v.report.printed_fraction,
        "printed fraction bit-identical to the run");
  CHECK(a.accepted == v.accepted, "acceptance verdict identical to the run");

  // The peak von Mises is a real, positive stress (the cantilever is loaded), so
  // the equality above is binding on a MEANINGFUL number, not a trivial zero.
  CHECK(a.max_von_mises > 0.0,
        "the loaded cantilever carries real stress (the bar is non-trivial)");

  // --- The engine NEVER optimizes: same density in, same design out ------------
  // analyze_fixed_design analyses the field it is handed; it does not move it.
  // (There is no design to return — but the invariant we can assert is that a
  // re-run on the SAME inputs is again bit-identical: pure, deterministic, no
  // hidden iteration/history.)
  const FixedDesignAnalysis a2 = analyze_fixed_design(
      g, params, v.optimization.physical_density, bcs, tip, material, build_dir,
      o.simp.cg_tolerance, o.simp.cg_max_iterations, o.simp.solver, o.margin_stop,
      knockdown, load_path_ok, part_solid);
  CHECK(differing(a2.von_mises_field, a.von_mises_field) == 0,
        "analyze_fixed_design is deterministic (re-run bit-identical)");
  CHECK(a2.mass_grams == a.mass_grams && a2.margin.worst_case == a.margin.worst_case,
        "analyze_fixed_design re-run: mass and margin bit-identical");

  // --- The gate can REJECT: a real margin threshold flips the verdict ----------
  // Same analysis, a margin_stop set just ABOVE the measured margin, must reject
  // (proving the gate is live, not a rubber stamp). Uses the actual worst-case
  // margin so the threshold is meaningful for this exact part.
  const double just_above = a.margin.worst_case * 1.0001;
  const FixedDesignAnalysis rej = analyze_fixed_design(
      g, params, v.optimization.physical_density, bcs, tip, material, build_dir,
      o.simp.cg_tolerance, o.simp.cg_max_iterations, o.simp.solver, just_above,
      knockdown, load_path_ok, part_solid);
  CHECK(!rej.accepted,
        "the gate REJECTS when margin_stop exceeds the measured margin");
  CHECK(differing(rej.von_mises_field, a.von_mises_field) == 0,
        "raising margin_stop changes only the verdict, not the physics");

  std::fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
