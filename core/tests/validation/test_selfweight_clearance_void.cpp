// Self-weight must never be applied to a voxel a keep-clear has voided.
// Task 2026-08-03-selfweight-clearance-void-crash.
//
// THE DEFECT. `expand_design_domain` tags every in-box Active voxel `Interior`,
// i.e. SOLID — so `self_weight_loads`, which keys on the grid's TAGS, weighs the
// whole growth region. The "Keep clear" overlay (`options.clearance_void`,
// handoff 100) then pins those same voxels `FrozenVoid` in the effective MASK,
// which the SIMP path drives to rho_min and the M3.1 void-DOF gate eliminates.
// The result is a load on a DOF with no stiffness path, and the solver refuses
// the whole run:
//
//     fea_solve_mgcg_matfree: under-constrained system
//     (load applied to a void DOF with no stiffness — no equilibrium possible)
//
// It needs all three ingredients at once: a DESIGN BOX (without one the solved
// grid is the part grid, where the rasterizer's part-precedence guard skips every
// solid voxel and the rest carry no weight), a CLEARANCE whose sweep reaches into
// the GROWTH region, and NO DECLARED LOAD (a declared load case takes precedence
// over self-weight, so the body force is never built). PRE-EXISTING: reachable
// since 289a6a3 (2026-07-17, handoff 100), which added the third ingredient to two
// that were already there.
//
// THE FIX is in the ONE definition. `design_domain_loads` (pipeline.hpp) is the
// single load-case derivation the four re-certification paths share, and it now
// builds self-weight over the grid MINUS the voxels the effective mask pins
// FrozenVoid — the same thing `expand_design_domain` already does for a keep-out
// box ("Tag Empty so it carries no FEA element and no self-weight"). The mask it
// voids against comes from `design_domain_mask`, also ONE definition, which
// minimize_plastic itself now consumes — so the load and the mask a run solves
// under cannot disagree by construction.
//
// BARS
//   SW1  the configuration above RUNS — (a) as an ordinary run, and (b) with the
//        coarse warm-start pre-solve armed, which carries the SAME exposure one
//        level up (coarsen_grid tags a coarse cell solid if ANY child is solid;
//        coarsen_mask votes it FrozenVoid when every solid child is).
//   SW2  the fix is in the ONE definition — every site that builds the design
//        load routes through design_domain_loads, and every self-weight load
//        case through masked_self_weight_loads, asserted against the sources.
//   SW3  self-weight is still correct where it SHOULD apply: with no clearance
//        the load vector is bit-identical to the pre-fix definition, and with a
//        clearance the total drops by EXACTLY the voided material's weight —
//        not by an arbitrary amount.
//   SW4  the same load case, not merely a valid one: the load vector reached
//        through the domain the other callers resolve is bit-identical to the
//        one minimize_plastic solves under, entry for entry.
//
// Public API only, self-contained CHECK harness, same shape as its siblings.

#include "topopt/clearance.hpp"
#include "topopt/fea.hpp"
#include "topopt/materials.hpp"
#include "topopt/pipeline.hpp"
#include "topopt/settings.hpp"
#include "topopt/simp.hpp"
#include "topopt/voxel.hpp"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

using topopt::ClearanceKind;
using topopt::ClearanceParams;
using topopt::ClearanceRasterResult;
using topopt::DesignBox;
using topopt::DesignMask;
using topopt::DirichletBC;
using topopt::ManualClearanceGeometry;
using topopt::Material;
using topopt::MaterialLibrary;
using topopt::MaskValue;
using topopt::MinimizePlasticOptions;
using topopt::MinimizePlasticResult;
using topopt::NodalLoad;
using topopt::SettingsRules;
using topopt::SolvedDesignDomain;
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

// ── The specimen ────────────────────────────────────────────────────────────
// A flat plate (the imported part), a design box that adds a tall growth region
// above it, and a keep-clear slab sitting ENTIRELY in that growth region — so
// the rasterizer's part-precedence guard cannot save it. No declared load, so
// the run is in self-weight mode.
constexpr double kSpacing = 1.0;
constexpr int kNx = 16, kNy = 8, kNz = 4;
constexpr double kBoxTopZ = 12.0;

VoxelGrid plate(std::vector<DirichletBC>& bcs) {
  VoxelGrid g;
  g.nx = kNx; g.ny = kNy; g.nz = kNz; g.spacing = kSpacing;
  g.origin = Vec3{0.0, 0.0, 0.0};
  g.tags.assign(static_cast<std::size_t>(kNx) * kNy * kNz, VoxelTag::Interior);
  // Anchor the min-x wall.
  for (int k = 0; k < kNz; ++k)
    for (int j = 0; j < kNy; ++j) g.set_tag(0, j, k, VoxelTag::Fixture);
  bcs.clear();
  for (int k = 0; k <= kNz; ++k)
    for (int j = 0; j <= kNy; ++j) {
      const int n = topopt::fea_node_index(g, 0, j, k);
      bcs.push_back({n, 0, 0.0});
      bcs.push_back({n, 1, 0.0});
      bcs.push_back({n, 2, 0.0});
    }
  return g;
}

MinimizePlasticOptions box_selfweight_options() {
  MinimizePlasticOptions o;
  DesignBox b;
  b.min = Vec3{0.0, 0.0, 0.0};
  b.max = Vec3{static_cast<double>(kNx) * kSpacing,
               static_cast<double>(kNy) * kSpacing, kBoxTopZ};
  o.design_box = b;
  o.freeze_imported_part = true;  // "add material": grow above a frozen part
  o.gravity = 9.81;
  o.gravity_direction = Vec3{0.0, 0.0, -1.0};
  // external_loads deliberately EMPTY => self-weight mode.
  return o;
}

// The keep-clear: a bounded slab spanning z ∈ [8, 11], well above the 4 mm plate.
DesignMask clearance_overlay(const VoxelGrid& part, const VoxelGrid& solved,
                             ClearanceRasterResult& rr_out) {
  const int oi = static_cast<int>(
      std::lround((part.origin.x - solved.origin.x) / solved.spacing));
  const int oj = static_cast<int>(
      std::lround((part.origin.y - solved.origin.y) / solved.spacing));
  const int ok = static_cast<int>(
      std::lround((part.origin.z - solved.origin.z) / solved.spacing));
  ManualClearanceGeometry geom;
  geom.kind = ClearanceKind::Face;
  geom.origin = Vec3{8.0, 4.0, 8.0};
  geom.normal = Vec3{0.0, 0.0, 1.0};
  geom.half_u_mm = 6.0;
  geom.half_w_mm = 3.0;
  ClearanceParams params;
  params.kind = ClearanceKind::Face;
  params.slab_depth_mm = 3.0;
  DesignMask overlay(solved.voxel_count(), MaskValue::Active);
  rr_out = topopt::rasterize_clearance(
      solved, part, oi, oj, ok,
      topopt::resolve_clearance_manual(geom, params), overlay);
  return overlay;
}

// Total force magnitude per axis, summed over every NodalLoad entry.
struct LoadTotal {
  double fx = 0.0, fy = 0.0, fz = 0.0;
  double magnitude() const { return std::sqrt(fx * fx + fy * fy + fz * fz); }
};
LoadTotal total_force(const std::vector<NodalLoad>& loads) {
  LoadTotal t;
  for (const NodalLoad& l : loads) {
    if (l.component == 0) t.fx += l.value;
    else if (l.component == 1) t.fy += l.value;
    else t.fz += l.value;
  }
  return t;
}

bool loads_identical(const std::vector<NodalLoad>& a,
                     const std::vector<NodalLoad>& b) {
  if (a.size() != b.size()) return false;
  for (std::size_t i = 0; i < a.size(); ++i)
    if (a[i].node != b[i].node || a[i].component != b[i].component ||
        a[i].value != b[i].value)  // BIT equality, deliberately not a tolerance
      return false;
  return true;
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

std::size_t count_occurrences(const std::string& hay, const std::string& needle) {
  std::size_t n = 0, at = 0;
  while ((at = hay.find(needle, at)) != std::string::npos) {
    ++n;
    at += needle.size();
  }
  return n;
}

}  // namespace

int main() {
  const MaterialLibrary materials = topopt::load_materials_file(MATERIALS_JSON_PATH);
  const Material material = materials.at("PLA");
  const SettingsRules rules = topopt::load_settings_rules_file(SETTINGS_RULES_PATH);
  const std::string src_dir = TOPOPT_SRC_DIR;

  std::printf(
      "=========================================================\n"
      " SELF-WEIGHT ON CLEARANCE-VOIDED VOXELS -- SW1..SW4\n"
      "=========================================================\n\n");

  std::vector<DirichletBC> bcs;
  const VoxelGrid part = plate(bcs);
  MinimizePlasticOptions clean = box_selfweight_options();
  const SolvedDesignDomain domain = topopt::resolve_design_domain(part, bcs, clean);
  CHECK(domain.expanded, "the specimen really does expand a design box");
  CHECK(domain.grid.nz > part.nz,
        "the expanded grid has a growth region above the plate");

  ClearanceRasterResult rr;
  const DesignMask overlay = clearance_overlay(part, domain.grid, rr);
  CHECK(rr.region_in_grid && rr.voxels_frozen > 0,
        "the keep-clear reaches into the solved grid and freezes voxels");

  MinimizePlasticOptions cleared = clean;
  cleared.clearance_void = overlay;

  // How many voxels are BOTH clearance-voided AND tagged solid (i.e. weighed)?
  // These are exactly the voxels the defect loads without stiffness.
  std::size_t voided_and_solid = 0;
  for (int k = 0; k < domain.grid.nz; ++k)
    for (int j = 0; j < domain.grid.ny; ++j)
      for (int i = 0; i < domain.grid.nx; ++i) {
        const std::size_t idx = domain.grid.index(i, j, k);
        if (overlay[idx] == MaskValue::FrozenVoid && domain.grid.solid(i, j, k))
          ++voided_and_solid;
      }
  std::printf(
      "specimen: part %dx%dx%d -> solved %dx%dx%d; keep-clear froze %zu voxels, "
      "%zu of them tagged SOLID\n",
      part.nx, part.ny, part.nz, domain.grid.nx, domain.grid.ny, domain.grid.nz,
      rr.voxels_frozen, voided_and_solid);
  CHECK(voided_and_solid > 0,
        "the specimen really does void voxels the grid tags SOLID (without this "
        "the test could not reproduce the defect at all)");

  // ═══ SW1 — THE RUN COMPLETES ════════════════════════════════════════════
  // Before the fix this throws "under-constrained system (load applied to a void
  // DOF ...)" from the M3.1 void-DOF gate, and the whole job is refused.
  std::printf("\nSW1 -- design box + keep-clear into the growth region + self-weight\n");
  {
    bool threw = false;
    std::string what;
    try {
      const MinimizePlasticResult r =
          topopt::minimize_plastic(part, material, "PLA", bcs, rules, cleared);
      std::printf("[SW1] run completed: %zu rung(s) evaluated\n",
                  r.evaluated.size());
      CHECK(!r.evaluated.empty(), "SW1: the run evaluated at least one rung");
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    if (threw) std::fprintf(stderr, "[SW1] threw: %s\n", what.c_str());
    CHECK(!threw,
          "SW1: a self-weight design-box run whose keep-clear reaches into the "
          "growth region must SOLVE, not throw 'under-constrained system'");
  }
  {
    // SW1(b) — the SAME exposure one level up. The coarse warm-start pre-solve
    // builds its own self-weight on coarsen_grid(G), which tags a coarse cell
    // solid if ANY child is solid, while coarsen_mask votes that cell FrozenVoid
    // when every solid child is. Armed here because it is OFF by default, so
    // nothing else in the suite would reach it.
    MinimizePlasticOptions warm = cleared;
    warm.warm_start_coarse = true;
    bool threw = false;
    std::string what;
    try {
      const MinimizePlasticResult r =
          topopt::minimize_plastic(part, material, "PLA", bcs, rules, warm);
      std::printf("[SW1b] warm-start run completed: %zu rung(s), %d coarse iters\n",
                  r.evaluated.size(), r.warm_start_coarse_iterations);
    } catch (const std::exception& e) {
      threw = true;
      what = e.what();
    }
    if (threw) std::fprintf(stderr, "[SW1b] threw: %s\n", what.c_str());
    CHECK(!threw,
          "SW1(b): the coarse warm-start pre-solve must not weigh coarse cells "
          "its own coarse mask has voided");
  }

  // ═══ SW3 — SELF-WEIGHT IS STILL CORRECT WHERE IT SHOULD APPLY ═══════════
  std::printf("\nSW3 -- the weight that remains is the weight that is there\n");
  const std::vector<NodalLoad> loads_clean =
      topopt::design_domain_loads(domain, clean, material.density_g_cm3);
  const std::vector<NodalLoad> loads_cleared =
      topopt::design_domain_loads(domain, cleared, material.density_g_cm3);
  {
    // (a) NO clearance => bit-identical to the pre-fix definition, which was
    //     literally self_weight_loads on the resolved grid. THE ONE RULE.
    const std::vector<NodalLoad> pre_fix = topopt::self_weight_loads(
        domain.grid, material.density_g_cm3, clean.gravity,
        clean.gravity_direction);
    CHECK(loads_identical(loads_clean, pre_fix),
          "SW3(a): with no clearance the load vector is BIT-identical to the "
          "pre-fix definition (self_weight_loads on the resolved grid)");

    // (b) WITH a clearance the total drops by EXACTLY the voided material's
    //     weight: one voxel's body force is g * rho * V, and exactly
    //     `voided_and_solid` voxels stopped carrying one.
    const LoadTotal t_clean = total_force(loads_clean);
    const LoadTotal t_cleared = total_force(loads_cleared);
    const double per_voxel =
        clean.gravity * material.density_g_cm3 * domain.grid.voxel_volume();
    const double expected_drop =
        per_voxel * static_cast<double>(voided_and_solid);
    const double actual_drop = t_clean.magnitude() - t_cleared.magnitude();
    std::printf(
        "[SW3] total self-weight  before %.12e N  after %.12e N\n"
        "[SW3] drop %.12e N; %zu voxels x %.12e N/voxel = %.12e N\n",
        t_clean.magnitude(), t_cleared.magnitude(), actual_drop,
        voided_and_solid, per_voxel, expected_drop);
    CHECK(std::fabs(actual_drop - expected_drop) <=
              1e-9 * std::fabs(expected_drop),
          "SW3(b): the total self-weight drops by EXACTLY the voided material's "
          "weight (voided voxel count x g x rho x voxel volume)");
    CHECK(t_cleared.magnitude() > 0.0,
          "SW3(b): the run still carries the weight of everything else");
    // The direction is untouched — only magnitude is removed.
    CHECK(t_cleared.fx == 0.0 && t_cleared.fy == 0.0,
          "SW3(b): a -z gravity leaves the x/y components exactly zero");

    // (c) NOT AN ARBITRARY AMOUNT: every load entry that survives sits on a node
    //     of a voxel that still has material. Stated as the invariant the void
    //     gate actually enforces — no load entry may name a DOF whose every
    //     incident voxel is masked FrozenVoid or Empty.
    const DesignMask eff = topopt::design_domain_mask(domain, cleared);
    std::vector<char> node_has_material(
        static_cast<std::size_t>(topopt::fea_node_count(domain.grid)), 0);
    for (int k = 0; k < domain.grid.nz; ++k)
      for (int j = 0; j < domain.grid.ny; ++j)
        for (int i = 0; i < domain.grid.nx; ++i) {
          const std::size_t idx = domain.grid.index(i, j, k);
          if (!domain.grid.solid(i, j, k)) continue;
          if (eff[idx] == MaskValue::FrozenVoid) continue;
          for (int n : topopt::fea_element_nodes(domain.grid, i, j, k))
            node_has_material[static_cast<std::size_t>(n)] = 1;
        }
    std::size_t orphaned = 0;
    for (const NodalLoad& l : loads_cleared)
      if (!node_has_material[static_cast<std::size_t>(l.node)]) ++orphaned;
    CHECK(orphaned == 0,
          "SW3(c): no surviving load entry sits on a DOF whose every incident "
          "voxel is void — this is the invariant the M3.1 gate enforces");
    // And the defect really did violate it (so (c) is a live bar, not a tautology).
    std::size_t orphaned_pre_fix = 0;
    for (const NodalLoad& l : pre_fix)
      if (!node_has_material[static_cast<std::size_t>(l.node)])
        ++orphaned_pre_fix;
    std::printf("[SW3] orphaned load DOFs: pre-fix definition %zu, fixed %zu\n",
                orphaned_pre_fix, orphaned);
    CHECK(orphaned_pre_fix > 0,
          "SW3(c): the PRE-FIX definition did strand load on void DOFs — the "
          "bar above is live");
  }
  {
    // (d) THE KEEP-OUT BOX — the one configuration where the effective mask
    // genuinely carries FrozenVoid entries with NO clearance declared. The
    // byte-identity argument rests on expand_design_domain having ALREADY
    // tagged those voxels Empty ("Tag Empty so it carries no FEA element and no
    // self-weight"), so the new masking step writes Empty over Empty and
    // changes nothing. Asserted rather than argued.
    MinimizePlasticOptions ko = box_selfweight_options();
    DesignBox keep_out;
    keep_out.min = Vec3{4.0, 2.0, 5.0};
    keep_out.max = Vec3{12.0, 6.0, 11.0};
    ko.keep_out_boxes.push_back(keep_out);
    const SolvedDesignDomain d_ko = topopt::resolve_design_domain(part, bcs, ko);
    const DesignMask m_ko = topopt::design_domain_mask(d_ko, ko);
    std::size_t frozen_void = 0, void_and_solid = 0;
    for (int k = 0; k < d_ko.grid.nz; ++k)
      for (int j = 0; j < d_ko.grid.ny; ++j)
        for (int i = 0; i < d_ko.grid.nx; ++i) {
          const std::size_t idx = d_ko.grid.index(i, j, k);
          if (m_ko[idx] != MaskValue::FrozenVoid) continue;
          ++frozen_void;
          if (d_ko.grid.solid(i, j, k)) ++void_and_solid;
        }
    std::printf("[SW3] keep-out box, NO clearance: %zu FrozenVoid voxels, "
                "%zu of them tagged solid\n", frozen_void, void_and_solid);
    CHECK(frozen_void > 0,
          "SW3(d): a keep-out box really does put FrozenVoid in the mask — the "
          "bar below is live, not vacuous");
    CHECK(void_and_solid == 0,
          "SW3(d): expand_design_domain already tagged every keep-out voxel "
          "Empty, so masking them changes no tag");
    CHECK(loads_identical(
              topopt::design_domain_loads(d_ko, ko, material.density_g_cm3),
              topopt::self_weight_loads(d_ko.grid, material.density_g_cm3,
                                        ko.gravity, ko.gravity_direction)),
          "SW3(d): a keep-out-box run with no clearance is BIT-identical to the "
          "pre-fix definition");
  }

  // ═══ SW4 — THE SAME LOAD CASE, NOT MERELY A VALID ONE ═══════════════════
  // run_job's latticed certification, lattice_variant_job and analyze_job all
  // rebuild the domain with resolve_design_domain and then call
  // design_domain_loads on it. Rebuild it exactly as they do and require the
  // load vector to be the SAME OBJECT minimize_plastic solves under — entry for
  // entry, bit for bit — not merely another well-formed one.
  std::printf("\nSW4 -- every caller reaches the SAME load case\n");
  {
    const SolvedDesignDomain rebuilt =
        topopt::resolve_design_domain(part, bcs, cleared);
    const std::vector<NodalLoad> theirs =
        topopt::design_domain_loads(rebuilt, cleared, material.density_g_cm3);
    CHECK(loads_identical(theirs, loads_cleared),
          "SW4: a caller that re-resolves the domain reaches a BIT-identical "
          "load case");
    CHECK(!theirs.empty(), "SW4: and it is a real load case, not an empty one");
    std::printf("[SW4] %zu load entries, identical across callers\n",
                theirs.size());

    // The declared-load mode is untouched: with external loads the clearance
    // never enters the load case at all (tractions are not body forces).
    MinimizePlasticOptions with_ext = cleared;
    with_ext.external_loads.push_back({0, 2, -1.0});
    const SolvedDesignDomain d_ext =
        topopt::resolve_design_domain(part, bcs, with_ext);
    const std::vector<NodalLoad> ext =
        topopt::design_domain_loads(d_ext, with_ext, material.density_g_cm3);
    CHECK(loads_identical(ext, d_ext.external_loads),
          "SW4: a declared load case is returned verbatim — the clearance does "
          "not touch it");
  }

  // ═══ SW2 — THE FIX IS IN THE ONE DEFINITION ═════════════════════════════
  // Structural, against the sources: every site that builds the design load for
  // a resolved domain must route through design_domain_loads, and no site may
  // carry a second `self_weight_loads(<a resolved domain grid>, ...)`.
  std::printf("\nSW2 -- the ONE definition, asserted against the sources\n");
  {
    const std::string mp = read_file(src_dir + "/src/simp/minimize_plastic.cpp");
    const std::string rj = read_file(src_dir + "/src/cli/run_job.cpp");
    CHECK(!mp.empty() && !rj.empty(), "SW2: both production sources are readable");

    // Exactly ONE raw self_weight_loads call survives in the optimizer, and it
    // is the one inside masked_self_weight_loads. Both self-weight load cases
    // this file builds — the design load and the coarse warm-start pre-solve's
    // — go through that helper, so neither can weigh masked-away material.
    // Every mention but one is the `masked_` form (its definition plus its two
    // call sites); the single bare mention is the raw call INSIDE the helper.
    const std::size_t all_swl = count_occurrences(mp, "self_weight_loads(");
    const std::size_t masked_swl = count_occurrences(mp, "masked_self_weight_loads(");
    std::printf("[SW2] minimize_plastic.cpp: %zu self_weight_loads( mentions, "
                "%zu of them masked_\n", all_swl, masked_swl);
    CHECK(all_swl - masked_swl == 1,
          "SW2: minimize_plastic.cpp holds exactly ONE raw self_weight_loads "
          "call — the one inside masked_self_weight_loads");
    CHECK(masked_swl == 3,
          "SW2: the helper is defined once and called by BOTH self-weight sites "
          "(the design load and the coarse pre-solve)");
    CHECK(mp.find("masked_self_weight_loads(Gc, mask_c") != std::string::npos,
          "SW2: the coarse warm-start pre-solve weighs its COARSE grid against "
          "its COARSE mask — the same defect one level up");
    CHECK(count_occurrences(mp, "design_domain_loads(domain, options") >= 1,
          "SW2: minimize_plastic consumes design_domain_loads");
    CHECK(count_occurrences(mp, "design_domain_mask(domain, options") >= 1,
          "SW2: minimize_plastic consumes design_domain_mask, so the mask it "
          "optimises under and the load it solves under are derived together");

    // run_job holds three of the four callers: the latticed certification, the
    // analyze path and lattice_variant_job. All three must call the shared
    // definition; a count below three means one kept its own derivation.
    const std::size_t rj_calls =
        count_occurrences(rj, "design_domain_loads(domain, options");
    std::printf("[SW2] run_job.cpp calls design_domain_loads %zu time(s)\n",
                rj_calls);
    CHECK(rj_calls >= 3,
          "SW2: run_job's three callers (latticed certification, analyze, "
          "lattice_variant) all route through design_domain_loads");
    // run_job keeps exactly ONE self_weight_loads call of its own, and it weighs
    // a FIXED DESIGN's own occupancy grid (`design_grid` — a substitute or
    // smoothed mesh carries its own mass, which is a different question from
    // "what did the run solve under"). That grid carries no clearance overlay,
    // so it cannot disagree with a mask the way the domain grid could. What must
    // never reappear is a run_job site weighing a resolved DOMAIN grid.
    CHECK(count_occurrences(rj, "self_weight_loads(") == 1,
          "SW2: run_job.cpp keeps exactly ONE self_weight_loads call of its own");
    CHECK(rj.find("self_weight_loads(design_grid") != std::string::npos,
          "SW2: and it weighs the FIXED DESIGN's own occupancy grid");
    CHECK(rj.find("self_weight_loads(domain.grid") == std::string::npos &&
              rj.find("self_weight_loads(sg,") == std::string::npos &&
              rj.find("self_weight_loads(model_grid") == std::string::npos,
          "SW2: no run_job site weighs a resolved domain grid directly");
  }

  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
