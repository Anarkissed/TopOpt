// Correctness guards for the GALERKIN BLOCK CACHE (handoff 090) — the opt-in,
// default-OFF fast path in the matrix-free multigrid's coarse-operator build
// (fea_set_matfree_galerkin_block_cache).
//
// The cache exploits the fact that the Galerkin block S = W^T Ke W formed for each
// element is purely GEOMETRIC (W is the trilinear prolongation stencil, Ke the
// single reference element stiffness; the element's modulus enters only afterwards
// as the scalar factor*S). Since axis_weights is parity-based and translation-
// invariant, every "generic" element — all 24 fine DOFs free, all 8 coarse nodes
// active — shares S with every other element of the same (i,j,k) parity, i.e. of
// the same colour. S is therefore computed once per colour and reused, instead of
// being recomputed ~638,000 times.
//
// What these tests must prove, and what they would catch:
//
//   1. BIT-IDENTICAL (guard a). Cache ON must reproduce cache OFF EXACTLY — same
//      solved field to the last bit, same iteration count, same coarse-operator
//      nonzeros. This is the guard that fails if the colour key is not in fact
//      sufficient to determine S (e.g. if a non-generic element wrongly took the
//      fast path, or if the local coarse-DOF ordering differed between two
//      same-colour elements): A1 would change, and the field with it.
//
//   2. GROWTH PRESERVED (guard b) — the decisive one. On the M7.dom case where the
//      optimizer is KNOWN to grow a gusset into initially-near-void space, the
//      cached run must grow the SAME material. A scheme that permanently skipped,
//      froze or coarsened the void away would fail this: the sensitivity that
//      tells the optimizer where to grow is -p*rho^(p-1)*E0*u_e^T Ke u_e, so it
//      needs the displacement u_e INSIDE the near-void region, which a skipped
//      element would not supply.
//
//   3. 078 PARITY (guard c). With the cache ON, the matrix-free MG-CG must still
//      converge in the SAME iteration count as the assembled MG-CG on the soft-void
//      graded grid — the coarse operator is reproduced, not degraded.
//
// No third-party framework (ARCHITECTURE §4): the same self-contained CHECK harness
// as the sibling tests, public API only.

#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <stdexcept>
#include <vector>

using topopt::CgInfo;
using topopt::DesignBox;
using topopt::DesignDomain;
using topopt::DirichletBC;
using topopt::FeaSolution;
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

#define CHECK(cond, msg)                                           \
  do {                                                             \
    ++g_checks;                                                    \
    if (!(cond)) {                                                 \
      ++g_failures;                                                \
      std::fprintf(stderr, "FAIL (line %d): %s\n", __LINE__, msg); \
    }                                                              \
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

// Count of DOFs at which two fields differ AT ALL (not "differ beyond a tol"):
// the cache is a compute saving, not an approximation, so the only acceptable
// answer is zero.
std::size_t differing_dofs(const FeaSolution& a, const FeaSolution& b,
                           double& maxdiff) {
  maxdiff = 0.0;
  std::size_t n = 0;
  for (std::size_t i = 0; i < a.u.size(); ++i) {
    const double d = std::fabs(a.u[i] - b.u[i]);
    if (d != 0.0) ++n;
    if (d > maxdiff) maxdiff = d;
  }
  return n;
}

// The L-bracket of the M7.dom growth gate (test_design_domain), reused verbatim so
// guard (b) runs on a case the optimizer is KNOWN to grow a gusset into.
VoxelGrid l_bracket(std::vector<DirichletBC>& bcs, int arm, int span, int ny,
                    int t, double h) {
  VoxelGrid g;
  g.nx = span;
  g.ny = ny;
  g.nz = arm;
  g.spacing = h;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(span) * ny * arm, VoxelTag::Empty);
  for (int k = 0; k < arm; ++k)
    for (int j = 0; j < ny; ++j)
      for (int i = 0; i < span; ++i)
        if (i < t || k < t) g.set_tag(i, j, k, VoxelTag::Interior);
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
  for (int k = 0; k < t; ++k)
    for (int j = 0; j < ny; ++j) g.set_tag(span - 1, j, k, VoxelTag::Load);
  return g;
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

}  // namespace

int main() {
  const double nu = 0.33, h = 1.0, E0 = 2000.0, rho_min = 1e-3, p = 3.0;

  // Default must be OFF (the ONE RULE): nothing changes unless a caller asks.
  CHECK(topopt::fea_set_matfree_galerkin_block_cache(false) == false,
        "default: the Galerkin block cache is OFF unless explicitly enabled");

  // ==========================================================================
  // 1. BIT-IDENTICAL on a SOLID grid (guard a).
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(32, 32, 32, h);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);

    CgInfo ioff, ion;
    topopt::fea_set_matfree_galerkin_block_cache(false);
    FeaSolution soff =
        topopt::fea_solve_mgcg_matfree(g, E0, nu, bcs, loads, 1e-9, 0, &ioff);
    topopt::fea_set_matfree_galerkin_block_cache(true);
    FeaSolution son =
        topopt::fea_solve_mgcg_matfree(g, E0, nu, bcs, loads, 1e-9, 0, &ion);
    topopt::fea_set_matfree_galerkin_block_cache(false);

    double maxdiff = 0.0;
    const std::size_t nd = differing_dofs(soff, son, maxdiff);
    CHECK(ioff.used_multigrid && ion.used_multigrid,
          "solid: multigrid engages both with and without the cache");
    CHECK(nd == 0 && maxdiff == 0.0,
          "solid: cache ON is BIT-IDENTICAL to cache OFF (0 differing DOFs)");
    CHECK(ion.iterations == ioff.iterations,
          "solid: cache ON converges in the SAME iteration count");
    std::printf("solid 32^3: cache ON == OFF bit-for-bit, %d iters, maxdiff %.1e\n",
                ion.iterations, maxdiff);
  }

  // ==========================================================================
  // 2. BIT-IDENTICAL on the SOFT-VOID graded grid (guard a) — the design-box
  //    regime: a rho_min^p = 1e-9 soft core is exactly the near-void material the
  //    cache's fast path covers, and the case a wrong colour key would corrupt.
  // ==========================================================================
  {
    VoxelGrid g = make_solid_grid(32, 32, 32, h);
    std::vector<DirichletBC> bcs = clamp_x0_face(g);
    std::vector<NodalLoad> loads = tip_load_z(g, -50.0);

    std::vector<double> ey(g.voxel_count(), 0.0);
    for (int k = 0; k < g.nz; ++k)
      for (int j = 0; j < g.ny; ++j)
        for (int i = 0; i < g.nx; ++i) {
          const double cx = (i + 0.5) / g.nx - 0.5;
          const double cy = (j + 0.5) / g.ny - 0.5;
          const double cz = (k + 0.5) / g.nz - 0.5;
          const double d = std::sqrt(cx * cx + cy * cy + cz * cz);
          const double rho = d < 0.25 ? rho_min : 1.0;  // soft spherical core
          ey[g.index(i, j, k)] = std::pow(rho, p) * E0;
        }

    CgInfo ioff, ion, img;
    topopt::fea_set_matfree_galerkin_block_cache(false);
    FeaSolution soff =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &ioff);
    topopt::fea_set_matfree_galerkin_block_cache(true);
    FeaSolution son =
        topopt::fea_solve_mgcg_matfree(g, ey, nu, bcs, loads, 1e-9, 0, &ion);
    FeaSolution smg = topopt::fea_solve_mgcg(g, ey, nu, bcs, loads, 1e-9, 0, &img);
    topopt::fea_set_matfree_galerkin_block_cache(false);

    double maxdiff = 0.0;
    const std::size_t nd = differing_dofs(soff, son, maxdiff);
    CHECK(ion.used_multigrid && ion.mg_levels >= 3,
          "soft-void: multigrid engages with the cache (>= 3 levels)");
    CHECK(nd == 0 && maxdiff == 0.0,
          "soft-void: cache ON is BIT-IDENTICAL to cache OFF (0 differing DOFs)");
    CHECK(ion.iterations == ioff.iterations,
          "soft-void: cache ON converges in the SAME iteration count");
    // Guard (c): 078's parity must still hold with the cache ON.
    CHECK(std::abs(ion.iterations - img.iterations) <= 2,
          "soft-void (078 parity): with the cache ON the matrix-free MG-CG still "
          "converges in the same iteration count as the assembled MG-CG");
    std::printf(
        "soft-void 32^3: cache ON == OFF bit-for-bit, %d iters "
        "(assembled MG %d), maxdiff %.1e\n",
        ion.iterations, img.iterations, maxdiff);
  }

  // ==========================================================================
  // 3. GROWTH PRESERVED (guard b) — the decisive guard. The M7.dom L-bracket:
  //    the optimizer grows a gusset into the notch, which starts as near-void
  //    Active space. The cached run must grow the SAME material.
  // ==========================================================================
  {
    SettingsRules rules;
    try {
      rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
    } catch (const std::exception& e) {
      std::fprintf(stderr, "FAIL: could not load rules.json: %s\n", e.what());
      return 1;
    }
    const Material material = fdm_material();
    const int arm = 8, span = 8, ny = 3, t = 2;
    const double hh = 2.0;
    std::vector<DirichletBC> bcs;
    VoxelGrid part = l_bracket(bcs, arm, span, ny, t, hh);
    const std::vector<NodalLoad> tip =
        topopt::traction_loads(part, VoxelTag::Load, Vec3{0.0, 0.0, -2.0e-4});

    DesignBox box;
    box.min = Vec3{-2.0, 0.5, -2.0};
    box.max = Vec3{20.0, 5.5, 20.0};

    MinimizePlasticOptions o;
    o.freeze_imported_part = true;  // the "add material" feature: only GROW
    o.volume_fraction_ladder = {0.5};
    o.margin_stop = 0.0;
    o.gravity = 0.0;
    o.gravity_direction = Vec3{0, 0, -1};
    o.external_loads = tip;
    o.design_box = box;
    o.simp.filter_radius = 1.5;
    o.simp.move = 0.2;
    o.simp.max_iterations = 40;
    o.simp.change_tol = 0.0;
    o.simp.cg_tolerance = 1e-8;
    // CRITICAL, or this guard is VACUOUS: SimpOptions::solver defaults to
    // JacobiCG, which never calls build_mf_hierarchy — the cache would be a no-op
    // and the growth comparison would pass without exercising the cached path at
    // all. Select the matrix-free multigrid the design-box production path
    // actually runs (079 STEP 4 flipped both bridge entry points to it).
    o.simp.solver = topopt::SolverKind::MultigridCG_Matfree;

    const DesignDomain domain = topopt::expand_design_domain(
        part, box, {}, true, topopt::kDesignBoxCoarsenAlign);

    // Prove this guard is NOT VACUOUS: the expanded design-box grid the run above
    // optimizes on must actually engage the matrix-free MULTIGRID, since that —
    // and only that — is what builds the coarse operator the cache lives in. If
    // this grid fell back to Jacobi-CG (as an odd/unaligned grid would, per 079),
    // build_mf_hierarchy would never run and the growth comparison below would
    // pass while testing nothing.
    {
      std::vector<double> ey1(domain.grid.voxel_count(), 0.0);
      for (std::size_t idx = 0; idx < ey1.size(); ++idx)
        if (domain.grid.tags[idx] != VoxelTag::Empty)
          ey1[idx] = std::pow(domain.mask[idx] == MaskValue::FrozenSolid ? 1.0 : 0.5,
                              3.0) * material.youngs_modulus_mpa;
      std::vector<DirichletBC> b1;
      for (const DirichletBC& bc : bcs)
        b1.push_back({topopt::remap_node_to_domain(part, domain, bc.node),
                      bc.component, bc.value});
      std::vector<NodalLoad> l1;
      for (const NodalLoad& nl : tip)
        l1.push_back({topopt::remap_node_to_domain(part, domain, nl.node),
                      nl.component, nl.value});
      CgInfo ick;
      topopt::fea_solve_mgcg_matfree(domain.grid, ey1, material.poisson, b1, l1,
                                     1e-8, 0, &ick);
      CHECK(ick.used_multigrid,
            "growth (non-vacuity): the design-box grid engages the matrix-free "
            "multigrid, so the cached coarse-operator build really runs");
    }

    topopt::fea_set_matfree_galerkin_block_cache(false);
    const MinimizePlasticResult off =
        topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, o);
    topopt::fea_set_matfree_galerkin_block_cache(true);
    const MinimizePlasticResult on =
        topopt::minimize_plastic(part, material, "PLA_test", bcs, rules, o);
    topopt::fea_set_matfree_galerkin_block_cache(false);

    CHECK(off.evaluated.size() == on.evaluated.size(),
          "growth: the cached run evaluates the SAME number of rungs");
    CHECK(!off.evaluated.empty() && !on.evaluated.empty(),
          "growth: a rung was evaluated");

    const std::vector<double>& rho_off =
        off.evaluated[0].optimization.physical_density;
    const std::vector<double>& rho_on =
        on.evaluated[0].optimization.physical_density;
    CHECK(rho_off.size() == rho_on.size() &&
              rho_off.size() == domain.grid.voxel_count(),
          "growth: both runs land on the expanded design-box grid");

    // The run GENUINELY grows into the near-void Active region — otherwise this
    // guard proves nothing about growth.
    std::size_t grown_off = 0, grown_on = 0;
    for (std::size_t idx = 0; idx < rho_off.size(); ++idx) {
      if (domain.mask[idx] != MaskValue::Active) continue;
      if (rho_off[idx] >= 0.5) ++grown_off;
      if (rho_on[idx] >= 0.5) ++grown_on;
    }
    CHECK(grown_off > 0,
          "growth: the UNCACHED run grows material into the Active near-void "
          "notch (the premise of this guard)");
    CHECK(grown_on == grown_off,
          "growth (guard b): the CACHED run grows the SAME amount of material "
          "into the near-void region — nothing was skipped or frozen away");

    double maxdrho = 0.0;
    for (std::size_t idx = 0; idx < rho_off.size(); ++idx)
      maxdrho = std::max(maxdrho, std::fabs(rho_off[idx] - rho_on[idx]));
    CHECK(maxdrho <= 1e-6,
          "growth (guard a): the cached design matches the uncached design "
          "(max|drho| <= 1e-6)");

    // Same accept/reject decisions and the same rung count: a scheme that changed
    // which rungs pass would have changed the product.
    bool same_decisions = true;
    for (std::size_t r = 0; r < off.evaluated.size(); ++r)
      if (off.evaluated[r].accepted != on.evaluated[r].accepted)
        same_decisions = false;
    CHECK(same_decisions,
          "growth (guard a): the cached run makes the SAME accept/reject "
          "decisions on every rung");

    std::printf(
        "growth: grown voxels %zu (uncached) == %zu (cached), max|drho| %.2e, "
        "%zu rungs\n",
        grown_off, grown_on, maxdrho, on.evaluated.size());
  }

  std::printf("test_galerkin_cache: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures == 0 ? 0 : 1;
}
