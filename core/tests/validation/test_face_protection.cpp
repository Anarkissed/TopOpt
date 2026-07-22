// Face protection (handoff 124 — preserve-skin) — the core mechanism, proven
// deterministically on a hand-built L-bracket that drives minimize_plastic
// directly (no STEP, Eigen only). A Face protection freezes the part's OWN
// material solid behind a selected face (FrozenSolid), footprint-only. This gate
// exercises the guarantees that would FAIL against a stub that ignored the
// protection:
//
//   (1) SURVIVAL vs EROSION — under an aggressive reduction ladder the SAME
//       outer-skin voxel set is carved away when UNPROTECTED (the optimizer keeps
//       a central truss and thins the redundant side skin) but is retained SOLID
//       (density == 1) when PROTECTED. A stub would let the protected skin erode
//       like its twin.
//
//   (2) PRECEDENCE — FrozenSolid (protection) WINS over FrozenVoid (keep-clear):
//       a clearance overlay that marks the very same skin voxels FrozenVoid does
//       NOT void them; they stay density == 1. This drives the real merge in
//       minimize_plastic (clearance_void only overwrites non-FrozenSolid), the
//       handoff-100 guard now with a user-facing source.
//
//   (3) PROJECTION (handoff 123) — with the conditional Heaviside projection gate
//       ARMED and FIRING, the frozen skin is STILL all density == 1: projection
//       operates on the Active design field, never on pinned FrozenSolid voxels,
//       so it cannot thin the preserved skin.
//
// Drives minimize_plastic (Eigen), so Eigen-gated in CMake like the sibling
// optimizer gates; the real settings rule table is injected. Public API only,
// same self-contained CHECK harness as test_designbox_anchor_pad.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <string>
#include <vector>

using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::MaskValue;
using topopt::Material;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::NodalLoad;
using topopt::SettingsRules;
using topopt::Vec3;
using topopt::VoxelGrid;
using topopt::VoxelTag;

static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond, msg)                                            \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
  } while (0)

namespace {

// A blocky L-bracket: a vertical arm (Fixture-clamped at the top) and a
// horizontal foot (Load-ed down at its free end). `ny` is deliberately generous
// so the y-direction carries redundant side material the optimizer thins — the
// outer y-skin of the foot is what erodes when unprotected.
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
  // Clamp the top of the arm (Fixture) — all 8 corner nodes of each Fixture voxel.
  for (int j = 0; j < ny; ++j)
    for (int i = 0; i < t; ++i) g.set_tag(i, j, arm - 1, VoxelTag::Fixture);
  bcs.clear();
  for (int b = 0; b <= ny; ++b)
    for (int a = 0; a <= t; ++a) {
      const int node = topopt::fea_node_index(g, a, b, arm);
      bcs.push_back({node, 0, 0.0});
      bcs.push_back({node, 1, 0.0});
      bcs.push_back({node, 2, 0.0});
    }
  // Load the free end of the foot (k<t at the far x face).
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

MinimizePlasticOptions aggressive_options(const std::vector<NodalLoad>& loads) {
  MinimizePlasticOptions o;
  // The production reduction ladder (mirrors test_designbox_anchor_pad's proven
  // options so the FEA solve stays well-conditioned). The lightest rung (0.26)
  // removes ~3/4 of the material — aggressive enough to carve the redundant outer
  // y-skin the protection must resist.
  o.volume_fraction_ladder = {0.68, 0.52, 0.38, 0.26};
  o.margin_stop = 1.5;
  o.margin_floor_multiple = 2.0;   // kAnchorMarginFloorMultiple
  o.external_loads = loads;
  o.gravity = 9810.0 * 1e-9;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  o.updater = topopt::SimpUpdater::MMA;
  o.infill_percent = 100.0;
  return o;
}

// The protected face's skin: the outer +y face of the FOOT (j in [0, depth)), for
// k < t (the foot), all i. This is the mask_step_face analogue built by hand — the
// first `depth` voxel layers behind the j==0 plane over that face's footprint.
DesignMask protect_foot_yface(const VoxelGrid& part, int t, int depth) {
  DesignMask m = topopt::make_active_mask(part);
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < depth && j < part.ny; ++j)
      for (int i = 0; i < part.nx; ++i)
        if (part.tag(i, j, k) != VoxelTag::Empty)
          m[part.index(i, j, k)] = MaskValue::FrozenSolid;
  return m;
}

// The last (lightest / most aggressive) rung's physical density.
const std::vector<double>& final_density(const MinimizePlasticResult& r) {
  return r.evaluated.back().optimization.physical_density;
}

// Mean / min density over the FrozenSolid voxels of `skin` (indexed on `part`,
// which equals the solved grid on this no-box path).
void skin_stats(const DesignMask& skin, const std::vector<double>& rho,
                double& mean, double& mn, std::size_t& count) {
  double sum = 0.0; mn = 1.0; count = 0;
  for (std::size_t e = 0; e < skin.size(); ++e) {
    if (skin[e] != MaskValue::FrozenSolid) continue;
    ++count;
    const double v = e < rho.size() ? rho[e] : 0.0;
    sum += v;
    if (v < mn) mn = v;
  }
  mean = count ? sum / static_cast<double>(count) : 0.0;
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
  const Material material = fdm_material();

  const int arm = 8, span = 10, ny = 5, t = 2, depth = 2;
  const double h = 2.0;
  std::vector<DirichletBC> bcs;
  VoxelGrid part = l_bracket(bcs, arm, span, ny, t, h);

  const Vec3 tip_force{0.0, 0.0, -30.0};
  const std::vector<NodalLoad> tip =
      topopt::traction_loads(part, VoxelTag::Load, tip_force);

  const DesignMask skin = protect_foot_yface(part, t, depth);

  // ── UNPROTECTED twin: the redundant outer skin erodes. ────────────────────
  const MinimizePlasticResult unprot =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules,
                               aggressive_options(tip));
  CHECK(!unprot.evaluated.empty(), "unprotected run produced a rung");

  // ── PROTECTED: freeze that skin FrozenSolid via a design_mask. ────────────
  MinimizePlasticOptions prot_opts = aggressive_options(tip);
  prot_opts.design_mask = skin;
  const MinimizePlasticResult prot =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, prot_opts);
  CHECK(!prot.evaluated.empty(), "protected run produced a rung");

  double u_mean = 0, u_min = 1, p_mean = 0, p_min = 1;
  std::size_t u_n = 0, p_n = 0;
  if (!unprot.evaluated.empty())
    skin_stats(skin, final_density(unprot), u_mean, u_min, u_n);
  if (!prot.evaluated.empty())
    skin_stats(skin, final_density(prot), p_mean, p_min, p_n);
  CHECK(p_n > 0, "the protected skin is a non-empty voxel set");

  // (1) SURVIVAL: every protected skin voxel is retained SOLID (pinned density 1).
  CHECK(p_min >= 0.999,
        "(1) protected skin is retained SOLID (all voxels density ~1)");
  // (1) EROSION of the twin: the SAME skin, unprotected, is carved — a would-fail-
  // against-a-stub check (a stub leaving the skin Active lets the ladder thin it).
  CHECK(u_min < 0.5, "(1) unprotected twin erodes (some skin voxel driven to void)");
  CHECK(u_mean < p_mean - 0.05, "(1) protected skin is denser than the eroded twin");

  // ── (2) PRECEDENCE: a clearance FrozenVoid on the same skin loses. ────────
  MinimizePlasticOptions prec_opts = aggressive_options(tip);
  prec_opts.design_mask = skin;
  DesignMask clear(part.voxel_count(), MaskValue::Active);
  for (std::size_t e = 0; e < skin.size(); ++e)
    if (skin[e] == MaskValue::FrozenSolid) clear[e] = MaskValue::FrozenVoid;
  prec_opts.clearance_void = clear;
  const MinimizePlasticResult prec =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, prec_opts);
  CHECK(!prec.evaluated.empty(), "precedence run produced a rung");
  double c_mean = 0, c_min = 1; std::size_t c_n = 0;
  if (!prec.evaluated.empty())
    skin_stats(skin, final_density(prec), c_mean, c_min, c_n);
  CHECK(c_min >= 0.999,
        "(2) FrozenSolid protection WINS over an overlapping FrozenVoid clearance");

  // ── (3) PROJECTION (123) armed + firing must not thin the frozen skin. ────
  MinimizePlasticOptions proj_opts = aggressive_options(tip);
  proj_opts.design_mask = skin;
  proj_opts.conditional_mma_projection_mnd_threshold = 1e-6;  // any grayness fires
  const MinimizePlasticResult proj =
      topopt::minimize_plastic(part, material, "fdm", bcs, rules, proj_opts);
  CHECK(!proj.evaluated.empty(), "projection run produced a rung");
  bool any_fired = false;
  for (const char f : proj.conditional_projection_fired) if (f) any_fired = true;
  CHECK(any_fired, "(3) the conditional projection gate actually FIRED on some rung");
  double j_mean = 0, j_min = 1; std::size_t j_n = 0;
  if (!proj.evaluated.empty())
    skin_stats(skin, final_density(proj), j_mean, j_min, j_n);
  CHECK(j_min >= 0.999,
        "(3) a fired projection gate does NOT thin the frozen protected skin");

  std::printf("[124] skin voxels=%zu\n", p_n);
  std::printf("[124] unprotected: skin mean=%.4f min=%.4f\n", u_mean, u_min);
  std::printf("[124] protected  : skin mean=%.4f min=%.4f\n", p_mean, p_min);
  std::printf("[124] precedence : skin mean=%.4f min=%.4f (clearance overlaps)\n",
              c_mean, c_min);
  std::printf("[124] projection : skin mean=%.4f min=%.4f (gate fired=%d)\n",
              j_mean, j_min, any_fired ? 1 : 0);

  if (g_failures == 0) {
    std::printf("face_protection (124): all %d checks passed\n", g_checks);
    return 0;
  }
  std::fprintf(stderr, "face_protection (124): %d/%d checks FAILED\n",
               g_failures, g_checks);
  return 1;
}
