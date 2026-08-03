// M5.3 — the minimize_plastic end-to-end driver (topopt/pipeline.hpp).
//
// Self-weight loading + a descending volume-fraction ladder, stopping at the
// first rung whose worst-case stress margin drops below options.margin_stop.
// See pipeline.hpp for the contract and the modeling choices. This TU drives
// simp_optimize / simp_compliance (Eigen), so it is gated on Eigen in CMake
// alongside simp.cpp.

#include "topopt/pipeline.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/analyze.hpp"
#include "topopt/fea.hpp"
#include "topopt/gate_diagnosis_eval.hpp"  // diagnose_gate (post-pass, verdict-free)
#include "topopt/observability.hpp"        // steady_clock_ms (pre-solve wall)
#include "topopt/orient.hpp"
#include "topopt/production.hpp"  // knockdown_spec_for
#include "topopt/warm_start.hpp"

namespace topopt {

namespace {

// The M3.5 iso threshold: a voxel is "printed" (solid material) when its
// physical density exceeds this.
constexpr double kIso = 0.5;

Vec3 normalized(const Vec3& v) {
  const double n = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return Vec3{v.x / n, v.y / n, v.z / n};
}

// infill_margin_knockdown (the M7.infill-margin seed curve) and element_dofs (the
// per-element displacement gather) moved to analyze.cpp when the recovery/
// certification block was extracted into analyze_fixed_design (handoff
// 2026-07-26-constrained-smooth). infill_margin_knockdown is now called through
// topopt/analyze.hpp so the ladder gate and a standalone re-analysis share ONE
// definition; element_dofs lives with the stress loop it feeds, inside analyze.cpp.

// THE ONE self-weight-under-a-mask derivation (task 2026-08-03-selfweight-
// clearance-void-crash). Self-weight is the weight of the material that is
// THERE: `self_weight_loads` keys on the grid's TAGS, but a design mask can
// remove material the tags still call solid — `expand_design_domain` tags every
// in-box Active voxel `Interior`, and the "Keep clear" overlay (handoff 100)
// then pins some of those FrozenVoid. A FrozenVoid voxel is driven to rho_min
// and its DOFs are eliminated by the M3.1 void gate, so weighing it puts body
// force on a DOF with no stiffness path and the solver refuses the whole run
// ("under-constrained system"). Voiding the tag first is exactly what
// expand_design_domain already does for a keep-out box ("Tag Empty so it
// carries no FEA element and no self-weight"); a clearance arrives later, as a
// mask, and could not.
//
// Every self-weight load case in this file goes through here — the design load
// (design_domain_loads) and the coarse warm-start pre-solve's own — so the two
// cannot drift, and neither can weigh material its mask has removed.
//
// A mask with no FrozenVoid entry over a solid voxel writes nothing (Empty over
// Empty), so this is bit-identical to weighing `grid` unmasked on every
// clearance-free run: THE ONE RULE.
std::vector<NodalLoad> masked_self_weight_loads(const VoxelGrid& grid,
                                                const DesignMask& mask,
                                                double density, double gravity,
                                                Vec3 direction) {
  if (mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "masked_self_weight_loads: mask size != grid.voxel_count()");
  VoxelGrid weighed = grid;
  for (std::size_t idx = 0; idx < mask.size(); ++idx)
    if (mask[idx] == MaskValue::FrozenVoid) weighed.tags[idx] = VoxelTag::Empty;
  return self_weight_loads(weighed, density, gravity, direction);
}

}  // namespace

// --- THE ONE design-domain resolution (pipeline.hpp) -------------------------
// The expansion + BC/load remap minimize_plastic used to perform inline, lifted
// so the re-certification paths in run_job call the SAME code rather than a
// second reconstruction of it (task 2026-08-03-design-box-recertification).
// minimize_plastic below now calls this; there is no other implementation.
SolvedDesignDomain resolve_design_domain(const VoxelGrid& part_grid,
                                         const std::vector<DirichletBC>& bcs,
                                         const MinimizePlasticOptions& options) {
  SolvedDesignDomain out;
  out.expanded = options.design_box.has_value();
  if (!out.expanded) {
    // No box: the caller's inputs verbatim. The mask stays EMPTY (the driver
    // then builds make_active_mask / uses the caller's own design_mask), so
    // this branch cannot perturb a no-box run.
    if (!options.design_mask.empty() &&
        options.design_mask.size() != part_grid.voxel_count())
      throw std::invalid_argument(
          "resolve_design_domain: design_mask size != grid.voxel_count()");
    out.grid = part_grid;
    out.bcs = bcs;
    out.external_loads = options.external_loads;
    return out;
  }

  // M7.anchor-integrity on the box path (handoff 082): a caller `design_mask` is
  // the anchor PAD (mask_step_face FrozenSolid, PART-grid indexed; diagnosis 064).
  // Its validity depends on freeze_imported_part:
  //   * freeze_imported_part == true (the "add material" feature): the WHOLE import
  //     is already FrozenSolid and the box builds the mask itself, so a caller pad
  //     is redundant AND ambiguous — REJECT it, exactly as the pre-082 driver did
  //     (test_design_domain's add-material contract still throws here).
  //   * freeze_imported_part == false (whole-domain optimize, the DEFAULT): handoff
  //     080 made the imported part an Active/REMOVABLE region, so only the 1-voxel
  //     Load/Fixture BC skin is pinned and the optimizer can carve an anchor boss
  //     thin. A caller pad is now MEANINGFUL — it re-freezes that N-voxel boss — so
  //     MERGE it into the expanded mask (below) instead of rejecting it.
  if (!options.design_mask.empty()) {
    if (options.freeze_imported_part)
      throw std::invalid_argument(
          "minimize_plastic: a caller design_mask is rejected together with a "
          "design_box when freeze_imported_part is set (the frozen box builds "
          "the effective mask itself)");
    if (options.design_mask.size() != part_grid.voxel_count())
      throw std::invalid_argument(
          "minimize_plastic: design_mask size != part grid.voxel_count()");
  }
  // Align the expanded grid's element dims to a power of two (8 => >= 3
  // multigrid levels) by appending Empty high-side voxels. The design-box
  // system is ~1e-9-contrast and ~2M-DOF; without an even-dimensioned grid the
  // geometric-multigrid hierarchy cannot coarsen (an odd axis makes it bail to
  // an effectively-hung Jacobi-CG). The padding adds no physics (Empty voxels,
  // void-gated) and leaves the BC/load remap offset unchanged. See voxel.hpp.
  const DesignDomain domain = expand_design_domain(
      part_grid, *options.design_box, options.keep_out_boxes,
      options.freeze_imported_part, kDesignBoxCoarsenAlign);
  // MERGE the caller anchor pad into the expanded mask. The pad is indexed on the
  // PART grid; the expanded grid is LARGER and sits at a whole-voxel offset
  // (domain.offset_*, the SAME offset remap_node_to_domain applies to the BCs and
  // loads just below). MERGE RULE: a part voxel the caller marked FrozenSolid
  // becomes FrozenSolid at its offset location in the expanded mask;
  // expand_design_domain's Active / FrozenVoid / Empty classification stands
  // everywhere else. The pad only ADDS keep-in (FrozenSolid) voxels — the sole
  // value mask_step_face writes — so nothing else is propagated and the box's own
  // domain is never un-frozen. A pad FrozenSolid voxel always sits on a part-solid
  // voxel (mask_step_face walks solid layers), which the whole-domain expand left
  // Active; the overlay pins it back to a keep-in boss.
  out.grid = domain.grid;
  out.mask = domain.mask;
  out.offset_i = domain.offset_i;
  out.offset_j = domain.offset_j;
  out.offset_k = domain.offset_k;
  if (!options.design_mask.empty()) {
    for (int pk = 0; pk < part_grid.nz; ++pk)
      for (int pj = 0; pj < part_grid.ny; ++pj)
        for (int pi = 0; pi < part_grid.nx; ++pi) {
          if (options.design_mask[part_grid.index(pi, pj, pk)] !=
              MaskValue::FrozenSolid)
            continue;
          out.mask[domain.grid.index(pi + domain.offset_i, pj + domain.offset_j,
                                     pk + domain.offset_k)] =
              MaskValue::FrozenSolid;
        }
  }
  out.bcs.reserve(bcs.size());
  for (const DirichletBC& bc : bcs)
    out.bcs.push_back({remap_node_to_domain(part_grid, domain, bc.node),
                       bc.component, bc.value});
  if (!options.external_loads.empty()) {
    out.external_loads.reserve(options.external_loads.size());
    for (const NodalLoad& nl : options.external_loads)
      out.external_loads.push_back(
          {remap_node_to_domain(part_grid, domain, nl.node), nl.component,
           nl.value});
  }
  return out;
}

// --- THE ONE effective design mask (pipeline.hpp) ----------------------------
// The base classification plus the "Keep clear" overlay, composed in one place
// so the mask a run OPTIMISES under and the load it SOLVES under are derived
// from the same object. minimize_plastic below consumes it; design_domain_loads
// consumes it to decide which voxels still hold material to weigh.
DesignMask design_domain_mask(const SolvedDesignDomain& domain,
                              const MinimizePlasticOptions& options) {
  const VoxelGrid& G = domain.grid;
  // Mask-aware optimize. With a design box the effective mask is built by
  // expand_design_domain (imported part FrozenSolid, keep-out FrozenVoid, the
  // rest of the design volume Active). Otherwise: an all-Active mask — Fixture
  // voxels are implicitly FrozenSolid (M3.7), so the §7 V3 retention gate holds
  // structurally. M7.anchor-integrity (FIX 1): when the caller supplies a design
  // mask (no design box) it REPLACES the all-Active default, letting the
  // anchor/load faces freeze an N-voxel structural pad (FrozenSolid) rather than
  // only the 1-voxel BC skin (diagnosis 064). Load/Fixture tags are still forced
  // FrozenSolid on top of it by the mask-aware simp path (effective_mask), so the
  // mask only ADDS keep-in pad voxels; it never un-freezes a tagged BC voxel.
  if (!domain.expanded && !options.design_mask.empty() &&
      options.design_mask.size() != G.voxel_count())
    throw std::invalid_argument(
        "minimize_plastic: design_mask size != grid.voxel_count()");
  DesignMask mask =
      domain.expanded ? domain.mask
                      : (options.design_mask.empty() ? make_active_mask(G)
                                                     : options.design_mask);

  // Handoff 100 — OR the "Keep clear" clearance overlay into the effective mask.
  // `clearance_void` is SOLVED-grid-indexed: each FrozenVoid entry forbids
  // NEW growth into a declared clearance region (a swept bolt cylinder / a slab
  // in front of a mounting face), EXCEPT where the effective mask already pins
  // the voxel FrozenSolid — the imported part / anchor pad WINS (design 095
  // STEP 1c; the rasterizer already excluded part material, this guards the pad
  // + frozen box too). EMPTY (the default) → no clearance → this is skipped and
  // the run is byte-for-byte identical to before (THE ONE RULE).
  if (!options.clearance_void.empty()) {
    if (options.clearance_void.size() != G.voxel_count())
      throw std::invalid_argument(
          "minimize_plastic: clearance_void size != solved grid voxel_count()");
    for (std::size_t idx = 0; idx < mask.size(); ++idx)
      if (options.clearance_void[idx] == MaskValue::FrozenVoid &&
          mask[idx] != MaskValue::FrozenSolid)
        mask[idx] = MaskValue::FrozenVoid;
  }
  return mask;
}

std::vector<NodalLoad> design_domain_loads(const SolvedDesignDomain& domain,
                                           const MinimizePlasticOptions& options,
                                           double material_density_g_cm3) {
  // The design load (pipeline.hpp modeling note). Mode (a): a caller-supplied
  // external load case (the user's tagged Load faces via traction_loads, already
  // remapped onto the expanded grid by resolve_design_domain) takes precedence.
  // A declared traction is a SURFACE load on the part's own faces, so the
  // clearance below has nothing to say about it.
  if (!options.external_loads.empty()) return domain.external_loads;

  // Mode (b): self-weight on the effective solid grid (self_weight_loads
  // validates density/gravity/direction and normalizes the direction
  // internally; with a design box the weight covers the frozen part plus the
  // Active design envelope).
  //
  // ...MINUS the material the effective mask has removed — see
  // masked_self_weight_loads above for why weighing a FrozenVoid voxel refuses
  // the run, and pipeline.hpp for the modeling statement. With no clearance
  // nothing in `mask` is FrozenVoid over a voxel the grid does not already tag
  // Empty, so this is bit-identical to weighing `domain.grid` itself — THE ONE
  // RULE, asserted in test_selfweight_clearance_void SW3(a).
  return masked_self_weight_loads(domain.grid, design_domain_mask(domain, options),
                                  material_density_g_cm3, options.gravity,
                                  options.gravity_direction);
}

std::vector<char> original_part_voxels(const VoxelGrid& part_grid,
                                       const SolvedDesignDomain& domain) {
  std::vector<char> in_part(domain.grid.voxel_count(), 0);
  for (int pk = 0; pk < part_grid.nz; ++pk)
    for (int pj = 0; pj < part_grid.ny; ++pj)
      for (int pi = 0; pi < part_grid.nx; ++pi) {
        if (part_grid.tags[part_grid.index(pi, pj, pk)] == VoxelTag::Empty)
          continue;
        in_part[domain.grid.index(pi + domain.offset_i, pj + domain.offset_j,
                                  pk + domain.offset_k)] = 1;
      }
  return in_part;
}

VoxelGrid minimize_plastic_solved_grid(const VoxelGrid& grid,
                                       const MinimizePlasticOptions& options) {
  // Mirror EXACTLY the design-domain expansion minimize_plastic performs: it is
  // now literally the same call (resolve_design_domain), so the two cannot
  // drift. Expansion is pure geometry (no voxelization, no solve), so this
  // returns the identical grid the driver solves on without running the ladder.
  // With no design box the solved grid IS the caller's grid.
  if (!options.design_box.has_value()) return grid;
  return resolve_design_domain(grid, /*bcs=*/{}, options).grid;
}

MinimizePlasticResult minimize_plastic(const VoxelGrid& grid,
                                       const Material& material,
                                       const std::string& material_name,
                                       const std::vector<DirichletBC>& bcs,
                                       const SettingsRules& rules,
                                       const MinimizePlasticOptions& options) {
  // --- Argument validation (the driver's own inputs) -----------------------
  const std::vector<double>& ladder = options.volume_fraction_ladder;
  if (ladder.empty())
    throw std::invalid_argument(
        "minimize_plastic: volume_fraction_ladder is empty");
  for (std::size_t r = 0; r < ladder.size(); ++r) {
    if (!(ladder[r] > 0.0) || !(ladder[r] <= 1.0) || !std::isfinite(ladder[r]))
      throw std::invalid_argument(
          "minimize_plastic: a ladder volume fraction is not in (0, 1]");
    if (r > 0 && !(ladder[r] < ladder[r - 1]))
      throw std::invalid_argument(
          "minimize_plastic: volume_fraction_ladder is not strictly "
          "descending");
  }
  if (!std::isfinite(options.margin_stop) || options.margin_stop < 0.0)
    throw std::invalid_argument(
        "minimize_plastic: margin_stop must be finite and >= 0");
  // M7.anchor-integrity (FIX 2): the floor multiple is >= 1.0 or +infinity
  // (disabled). NaN and values < 1 are rejected; +infinity is allowed as the
  // "disabled" sentinel (the default). `>= 1.0` is false for NaN, so this also
  // rejects NaN.
  if (!(options.margin_floor_multiple >= 1.0))
    throw std::invalid_argument(
        "minimize_plastic: margin_floor_multiple must be >= 1 or +infinity");
  if (!std::isfinite(options.min_feature_mm) || options.min_feature_mm < 0.0)
    throw std::invalid_argument(
        "minimize_plastic: min_feature_mm must be finite and >= 0");
  // Handoff 123 — the conditional MMA-projection grayness gate threshold; 0 (the
  // default) disables it, so this rejects only a genuinely malformed value and
  // every existing caller is unaffected.
  if (!std::isfinite(options.conditional_mma_projection_mnd_threshold) ||
      options.conditional_mma_projection_mnd_threshold < 0.0)
    throw std::invalid_argument(
        "minimize_plastic: conditional_mma_projection_mnd_threshold must be "
        "finite and >= 0");
  if (!std::isfinite(options.infill_percent))
    throw std::invalid_argument(
        "minimize_plastic: infill_percent must be finite");
  // Width-aware knockdown inputs (handoff 2026-07-26-width-aware-knockdown). Both
  // default to a no-op (wall_loops 0, and width_aware_knockdown false), so this
  // rejects only a genuinely malformed value and every existing caller is unaffected.
  if (options.wall_loops < 0)
    throw std::invalid_argument("minimize_plastic: wall_loops must be >= 0");
  if (!std::isfinite(options.wall_line_width_mm) ||
      options.wall_line_width_mm < 0.0)
    throw std::invalid_argument(
        "minimize_plastic: wall_line_width_mm must be finite and >= 0");
  // The outer-wall width's < 0 is the "mirror inner" sentinel (the default), so only a
  // finite value is required here — a NaN / +inf outer width is still rejected.
  if (!std::isfinite(options.wall_line_width_outer_mm))
    throw std::invalid_argument(
        "minimize_plastic: wall_line_width_outer_mm must be finite");
  // Diagnosis 095 — the silent-self-weight-fall-through guard. A load-case caller
  // sets require_external_loads; an empty external_loads then means the user's
  // force never reached the solver, and falling through to self-weight would ship
  // a fragmented, tab-removed design as if it succeeded. Refuse it explicitly.
  // Default false, so genuine self-weight runs and every existing caller are
  // unaffected (byte-identical).
  if (options.require_external_loads && options.external_loads.empty())
    throw std::invalid_argument(
        "minimize_plastic: require_external_loads is set but external_loads is "
        "empty — a load case produced no non-zero force, so the run would fall "
        "through to a self-weight optimize (which strips the unloaded tab and "
        "fragments the design). Refusing to silently run self-weight; check that "
        "the load case's force reached the solver.");
  // `gravity` is only the SELF-WEIGHT magnitude; it is unused when the caller
  // supplies an external load case, so only require it there.
  if (options.external_loads.empty() &&
      (!std::isfinite(options.gravity) || !(options.gravity > 0.0)))
    throw std::invalid_argument(
        "minimize_plastic: gravity must be finite and > 0");
  {
    // Always required: it defines the reported build orientation + interlayer axis.
    const Vec3& d = options.gravity_direction;
    if (!(std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z) > 1e-300))
      throw std::invalid_argument(
          "minimize_plastic: gravity_direction is (near) zero length");
  }

  // --- M7.dom-core: optional design-volume expansion -----------------------
  // With a design box supplied, expand the run onto a LARGER grid whose mask
  // freezes the imported part (FrozenSolid), voids the keep-out boxes
  // (FrozenVoid) and opens the rest of the design volume to the optimizer
  // (Active) — the "add material" feature. The mounting BCs and any external
  // loads are node-indexed to the imported part, so they are remapped onto the
  // expanded grid. When no design box is supplied, `G` / `B` alias the caller's
  // `grid` / `bcs` and every quantity derived below is byte-for-byte identical to
  // the pre-M7.dom-core driver (the design-box branch is simply skipped).
  //
  // THE expansion + remap lives in resolve_design_domain (above, pipeline.hpp)
  // so the re-certification paths call the SAME code rather than reconstruct it
  // (task 2026-08-03-design-box-recertification). This site is unchanged in what
  // it computes — the identical expand_design_domain call, the identical anchor-
  // pad merge and the identical remap_node_to_domain over BCs and external loads
  // — it simply no longer owns the only copy.
  const SolvedDesignDomain domain = resolve_design_domain(grid, bcs, options);
  const bool expanded = domain.expanded;
  // The effective grid + BCs the whole pipeline runs on (the expanded pair with a
  // design box, else the caller's inputs verbatim).
  const VoxelGrid& G = domain.grid;
  const std::vector<DirichletBC>& B = domain.bcs;

  // Handoff 127 (Amendment 2): start this run's multigrid stagnation latch fresh,
  // on the (single) thread that will issue every solve below — the warm-start
  // pre-solve, the ladder rungs, and the recovery solves. The latch is sticky
  // within a run and per-thread, so without this reset a prior run's stagnation
  // could carry over. Inert for the JacobiCG library default (nothing reads it).
  fea_matfree_reset_mg_stagnation_latch();
  // Handoff 133 — same discipline for the Krylov recycle basis: it is sticky and
  // thread-local, so a prior run's subspace must never leak into this one. Inert
  // when recycling is off (the library default).
  fea_reset_krylov_recycle_space();
  // Handoff 2026-07-29-geneo-arming — same discipline for the GenEO deflation
  // basis + its lifecycle counters: a prior run's coarse space (or its
  // degradation reference) must never leak into this one. Inert when the
  // deflation is off (the library default).
  fea_reset_geneo_basis();

  // --- Fixed pipeline setup (shared across every rung) ---------------------
  // The design load, computed once and held across rungs (pipeline.hpp modeling
  // note). Mode (a): a caller-supplied external load case (the user's tagged Load
  // faces via traction_loads, remapped onto the expanded grid when a design box
  // is set) takes precedence. Mode (b): self-weight on the effective solid grid
  // (self_weight_loads validates density/gravity/direction and normalizes the
  // direction internally; with a design box the weight covers the frozen part
  // plus the Active design envelope, held fixed across rungs). ONE definition
  // (design_domain_loads), shared with every re-certification site — so "the
  // load this run certified under" is reconstructed, never re-derived.
  const std::vector<NodalLoad> loads =
      design_domain_loads(domain, options, material.density_g_cm3);

  // The reported / analysed build direction is the build-plate normal — "which
  // way is up on the plate", a DIFFERENT question from "which way is down in
  // service" (handoff 2026-08-01-build-direction-separation). Resolved through
  // THE ONE resolver: the job's explicit build direction when it set one, else
  // the documented gravity fallback (unit(-gravity), byte-identical to what this
  // site derived inline before). Never re-derived here.
  const Vec3 build_dir = resolve_build_direction(options);

  // THE ONE BAKE DECISION (handoff 2026-08-01-bake-build-orientation): does this
  // run get to CHOOSE the orientation, and is the export rotated onto it? Read
  // once here, never re-derived per rung, so every rung of one run is governed by
  // the same plan.
  const BuildOrientationBakePlan bake_plan = resolve_bake_plan(options);
  // The scorer is armed when the ranking was ASKED FOR, or when the plan needs a
  // recommendation to act on — it cannot choose an orientation without one. This
  // is the only implicit arming in the codebase, and it is warranted: the
  // alternative is auto-apply silently doing nothing on an ordinary job.
  const bool score_orientations =
      options.build_orientation_report || bake_plan.needs_scorer;

  // Material -> SIMP params (penalty p = 3 per ARCHITECTURE §4).
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

  // The effective mask, from THE ONE definition (design_domain_mask,
  // pipeline.hpp) — the base classification plus the "Keep clear" overlay,
  // composed exactly as this site used to compose it inline. It is shared with
  // design_domain_loads above precisely so the mask this run optimises under and
  // the load it solves under cannot describe different material: weighing a
  // voxel this mask has voided is the under-constrained system the M3.1 void
  // gate refuses (task 2026-08-03-selfweight-clearance-void-crash).
  DesignMask mask = design_domain_mask(domain, options);

  // Handoff 080 (Option 2 — "whole-domain optimize"): on a design-box run that does
  // NOT freeze the imported part, the part is an Active design region the optimizer
  // may remove. Two quantities must then be normalised to the PART rather than to
  // the Active envelope, so the run reduces plastic against the part and the app's
  // savings/baseline are the honest part reference:
  //   (1) each ladder rung's volume-fraction TARGET — simp's volume constraint is
  //       `vf * n_active` over the Active envelope (part interior + add-region),
  //       which for a loose box permits far MORE material than the part; rescale it
  //       to `vf * part_solid` so rung `vf` means "keep vf of the part's worth of
  //       material" (see the near-solid diagnosis, handoff 080);
  //   (2) the reported ACHIEVED fraction — set below to printed_voxels / part_solid
  //       so `savings = 1 - achieved` and the implied baseline (mass / achieved)
  //       resolve to the part's mass, not the filled expanded domain.
  // `active_effective` mirrors what effective_mask (simp) actually optimises: Active
  // voxels minus the Empty/Load/Fixture voxels it reclassifies out of the budget.
  // Gated on the box path only, so the no-box run is byte-identical.
  const bool part_relative = expanded && !options.freeze_imported_part;
  const double part_solid = static_cast<double>(grid.solid_count());
  double active_effective = 0.0;   // voxels simp's volume constraint moves
  double frozen_effective = 0.0;   // voxels effective_mask pins solid (always printed)
  if (part_relative) {
    for (int k = 0; k < G.nz; ++k)
      for (int j = 0; j < G.ny; ++j)
        for (int i = 0; i < G.nx; ++i) {
          const std::size_t idx = G.index(i, j, k);
          const VoxelTag t = G.tag(i, j, k);
          // effective_mask (simp) pins these FrozenSolid: always printed, never
          // move, so they spend part of the part budget. TWO sources: the M1.6
          // Load/Fixture BC tags, AND (handoff 082) any voxel the merged anchor pad
          // marked FrozenSolid — the re-frozen boss behind the BC skin. Counting the
          // pad here keeps each rung's TOTAL printed material at `vf * part_solid`
          // (the target below is `vf*part_solid - frozen_effective`, so the active
          // budget shrinks by exactly the pad); omitting it would silently overshoot
          // the part budget by the pad size. No pad => no FrozenSolid on this path,
          // so this is byte-identical to the pre-082 whole-domain run.
          if (t == VoxelTag::Load || t == VoxelTag::Fixture ||
              mask[idx] == MaskValue::FrozenSolid) {
            frozen_effective += 1.0;
            continue;
          }
          if (mask[idx] != MaskValue::Active) continue;  // FrozenVoid
          if (t == VoxelTag::Empty) continue;  // effective_mask -> FrozenVoid
          active_effective += 1.0;
        }
  }

  // Part size for the settings size class: the largest grid bounding-box edge.
  const double part_dim_mm =
      std::max({static_cast<double>(G.nx), static_cast<double>(G.ny),
                static_cast<double>(G.nz)}) *
      G.spacing;

  // The acceptance-gate knockdown posture (handoff 2026-07-26-width-aware-knockdown),
  // resolved once and shared by every rung's certification. THE ONE builder
  // (knockdown_spec_for) — the SAME one the CLI re-analysis and the on-device bridge
  // use, so all three gate identically. The scalar seed is infill_margin_knockdown of
  // the job infill (1.0 for solid/unset, so byte-identical to pre-M7.infill);
  // width_aware defaults false → the pure scalar `worst_case * infill_knockdown` path.
  // When armed, the gate credits the slicer's solid wall loops per member.
  const KnockdownSpec knockdown = knockdown_spec_for(options);

  MinimizePlasticResult result;
  result.report.material = material_name;
  // Record the grid every evaluated variant's fields are indexed to — the
  // expanded domain grid under a design box, else the caller's grid. This IS the
  // grid solved on (G), not a re-derivation, so a caller reporting grid metadata
  // from it samples the von-Mises/displacement fields at the correct voxels. It
  // equals minimize_plastic_solved_grid(grid, options) voxel-for-voxel.
  result.solved_grid = G;
  // The fine grid's DOF count, by the ONE definition documented on
  // MinimizePlasticResult::warm_start_coarse_dof_touches. Recorded always (not
  // only when the cascade is armed) so the denominator of any DOF-weighted
  // comparison is in the run record either way.
  result.solved_grid_dofs = grid_nodal_dofs(G);

  // Reserve result.evaluated to the ladder length (its known maximum: at most one
  // entry per rung, and the walk stops early on the first rejected/cancelled rung)
  // so it NEVER reallocates while the ladder runs. The progressive-results stream
  // (options.on_variant, below) hands its callback a reference to a variant that
  // lives inside result.evaluated; a mid-run reallocation would free the block
  // that reference points into (ASan heap-buffer-overflow, read-after-realloc —
  // the empty keyframeMeshes / displacementField symptoms). Reserving up front
  // removes the reallocation entirely; the per-push assert guards the invariant.
  result.evaluated.reserve(ladder.size());

  // Rung-vf helper (handoff 110): the SAME "fraction of Active envelope" the loop
  // below computes for a rung, so the Part B coarse pre-solve targets rung 0 at the
  // identical effective fraction. Off the box path this is exactly `vf`.
  auto effective_vf = [&](double vf) {
    if (part_relative && active_effective > 0.0) {
      const double active_target = vf * part_solid - frozen_effective;
      return std::min(1.0,
                      std::max(params.density_min, active_target / active_effective));
    }
    return vf;
  };

  // --- Handoff 110 (Part B): coarse-to-fine cascade ------------------------
  // The fine-grid warm-start seed handed to the NEXT rung's simp_optimize
  // (SimpOptions::initial_design). EMPTY => that rung starts uniform. With
  // warm_start_coarse we fill it now from a res/2 pre-solve so RUNG 0 starts warm;
  // with warm_start_inherit each rung then re-seeds it from its own converged
  // density (below). With BOTH features off it stays empty for the whole ladder and
  // every simp_optimize call takes the uniform-start path — byte-for-byte identical
  // to the pre-110 driver (THE ONE RULE). The coarse solve is an ORDINARY
  // simp_optimize on the coarsened effective problem (grid/BCs/loads/mask), with its
  // own guard rails; its cost is reported in result.warm_start_coarse_iterations so
  // no speedup claim can hide it. Peak memory is unchanged: the coarse transient is
  // smaller but the fine rungs still each pay the full iteration-0 build (091).
  std::vector<double> warm_seed;
  if (options.warm_start_coarse) {
    // The pre-solve's own wall, charged as a separate line (AC3 of handoff
    // 2026-08-02-warm-start-coarse-experiment). The span covers EVERYTHING the
    // cascade costs — coarsening the effective problem, the res/2 solve, and the
    // prolongation — so no part of the price can hide outside it. Same steady
    // clock as the per-iteration phase instrument (handoff 2026-08-02-iteration-
    // phase-timing), so the two numbers are comparable without conversion.
    const double warm_t0 = steady_clock_ms();
    const long long warm_mv0 = fea_matvec_count();
    const VoxelGrid Gc = coarsen_grid(G);
    const std::vector<DirichletBC> Bc = coarsen_bcs(G, Gc, B);
    const DesignMask mask_c = coarsen_mask(G, Gc, mask);
    // Self-weight through THE ONE masked derivation, on the COARSE pair — the
    // pre-solve has the same exposure the fine load did, one level up.
    // coarsen_grid tags a coarse cell solid if ANY child is solid, while
    // coarsen_mask votes it FrozenVoid when every solid child is FrozenVoid, so
    // a clearance-voided region produces coarse cells that are tag-solid and
    // mask-void — exactly the mismatch that refuses the run (task 2026-08-03-
    // selfweight-clearance-void-crash). A keep-out box never reached this
    // because its voxels are tagged Empty and coarsen_mask skips non-solid
    // children, which is also why this is byte-identical with no clearance
    // declared.
    const std::vector<NodalLoad> loads_c =
        !options.external_loads.empty()
            ? restrict_loads(G, Gc, loads)
            : masked_self_weight_loads(Gc, mask_c, material.density_g_cm3,
                                       options.gravity,
                                       options.gravity_direction);

    SimpOptions opt_c = options.simp;
    opt_c.updater = options.updater;
    opt_c.volume_fraction = effective_vf(ladder[0]);
    if (options.min_feature_mm > 0.0)
      opt_c.filter_radius =
          physical_filter_radius(options.min_feature_mm, Gc.spacing);
    opt_c.cancel = options.cancel;   // a cancel during the pre-solve aborts it
    opt_c.progress = nullptr;        // the pre-solve is not a reported rung
    opt_c.keyframe = nullptr;
    opt_c.keyframe_stride = 0;
    opt_c.observe = nullptr;         // handoff 114: not a reported rung, not observed
    opt_c.density_observer = nullptr;
    opt_c.initial_design.clear();    // the coarse solve itself starts uniform

    const SimpOptimizeResult coarse =
        simp_optimize(Gc, params, Bc, loads_c, opt_c, mask_c);
    result.warm_start_coarse_iterations = coarse.iterations;
    // Upsample the converged coarse density to the fine grid to seed rung 0. A
    // cancelled pre-solve leaves the seed empty (rung 0 then starts uniform and the
    // ladder's own cancel poll stops it immediately).
    if (!coarse.cancelled)
      warm_seed = prolong_density(Gc, G, coarse.physical_density);
    result.warm_start_coarse_ms = steady_clock_ms() - warm_t0;
    result.warm_start_coarse_matvecs = fea_matvec_count() - warm_mv0;
    // DOF-WEIGHT the pre-solve's applies at the COARSE grid's DOF count — the
    // unit that is valid ACROSS the two resolutions. Every apply counted in the
    // span above ran on Gc.
    result.warm_start_coarse_grid_dofs = grid_nodal_dofs(Gc);
    result.warm_start_coarse_dof_touches =
        result.warm_start_coarse_matvecs * result.warm_start_coarse_grid_dofs;
  }

  // --- Multigrid-usage tally (loud-fallback honesty) -----------------------
  // Aggregate whether the linear solves actually engaged the geometric-multigrid
  // accelerator across ALL optimize iterations of the run, so a caller can report
  // a silent Jacobi-CG fallback (run_info.json cg_multigrid + the CLI warning).
  // A single solve is NOT representative: the first iterations of a rung start
  // from a near-uniform density on which MG can stagnate past its budget and fall
  // back, even when the grid coarsens fine and the steady-state iterations run MG.
  // So `used_multigrid` is reported only when MG carried the MAJORITY of solves —
  // that cleanly separates the coarsenability BUG (MG never engages, all fall
  // back) from benign early-iteration stagnation. Tallied via the always-present
  // observe hook below; the reported grid coarsenability is grid-determined, so
  // these counts are stable run-to-run.
  std::size_t mg_solve_count = 0;
  std::size_t total_solve_count = 0;
  int observed_mg_levels = 0;
  // Handoff 128 — did ANY solve build a hierarchy? Splits a fallback into
  // stagnation (built but never carried) vs build-rejection (never coarsenable)
  // for run_info.json mg_mode. Tallied by the same always-present observe hook.
  bool mg_hierarchy_ever_built = false;

  // --- Handoff 123: conditional MMA-projection gate ------------------------
  // The gate is ARMED only on the MMA grayscale path with a positive threshold.
  // With updater == OC projection is the OC `projection` schedule (not this), and
  // with simp.mma_projection already true every rung projects unconditionally
  // (the always-on path), so in both cases the gate is inert and the run is
  // byte-identical to what it would be without this field. Loop-invariant, so
  // computed once. When disarmed the per-rung result vectors below stay EMPTY.
  const bool conditional_projection_armed =
      options.conditional_mma_projection_mnd_threshold > 0.0 &&
      options.updater == SimpUpdater::MMA && !options.simp.mma_projection;

  // --- Handoff 2026-07-25-draft-quality: the draft posture, resolved once ---
  // ARMED only when draft_quality is set AND the loose endpoint is genuinely looser
  // than the tight certification tolerance — a loose <= tight value would be a knob
  // that silently does nothing, the failure mode this codebase keeps re-learning
  // (125 §0), so it is treated as OFF (byte-identical). `kCertTol` is the tight
  // certification tolerance the whole run must never soften below (B2), captured
  // once so every assert reads the same number. `kDraftTightBand` is the derived-k
  // band: a trajectory tolerance at/below it counts as "tight" (within one decade of
  // the certification floor) for the tail measurement.
  const double kCertTol = options.simp.cg_tolerance;
  const bool draft_armed =
      options.draft_quality && options.draft_loose_tol > kCertTol;
  const double kDraftTightBand = kCertTol * 10.0;
  // Record one draft-outcome entry per EVALUATED rung, so the three vectors stay
  // aligned with `evaluated` / `rung_infeasible` across every terminal branch
  // (normal / infeasible / cancelled). No-op when draft is disarmed, so the vectors
  // stay empty on a non-draft run. A cancelled/infeasible rung records the sentinel
  // (k 0, gap -1 = not measured, not escalated).
  auto record_draft_rung = [&](int k, double gap, int escalated,
                               double probe_flip, long long probe_cg,
                               double probe_tightmove) {
    if (!draft_armed) return;
    result.draft_rung_tail_k.push_back(k);
    result.draft_rung_c_gap.push_back(gap);
    result.draft_rung_escalated.push_back(static_cast<char>(escalated));
    result.draft_rung_probe_flip.push_back(probe_flip);
    result.draft_rung_probe_cg.push_back(probe_cg);
    result.draft_rung_probe_tightmove.push_back(probe_tightmove);
  };
  // Handoff 2026-07-27-nonconvergence-rejection — record one non-convergence entry
  // per EVALUATED rung, so the three vectors stay aligned with `evaluated` /
  // `rung_infeasible` across EVERY terminal branch (normal / cancelled / infeasible /
  // non-convergent). Always filled (like rung_infeasible): all-zeros is the positive
  // statement "every rung's solves converged". Called exactly once per loop iteration,
  // beside the matching result.rung_infeasible.push_back.
  auto record_rung_convergence = [&](bool non_convergent, int iteration,
                                     double residual) {
    result.rung_non_convergent.push_back(non_convergent ? 1 : 0);
    result.rung_non_convergent_iteration.push_back(iteration);
    result.rung_non_convergent_residual.push_back(residual);
  };
  // Phase 2 design-space trigger: ARMED only when draft is armed AND the maintainer
  // opted in (draft_use_design_trigger). The threshold draft_escalation_design_flip
  // (default 0 = the measured negative-control floor) is then how much classification
  // disagreement is tolerated before escalating. When disarmed the Phase-1 compliance-
  // gap decision runs and no probe is taken (byte-identical to pre-phase2).
  const bool draft_design_trigger_armed =
      draft_armed && options.draft_use_design_trigger;

  // --- Walk the ladder -----------------------------------------------------
  for (std::size_t rung = 0; rung < ladder.size(); ++rung) {
    const double vf = ladder[rung];
    // Handoff 133 — recycle-space lifetime (see MinimizePlasticOptions). A rung
    // boundary steps the volume target and jumps the design, so by default the
    // basis harvested from the previous rung is dropped here rather than applied
    // to a system it no longer describes. Inert when recycling is off.
    if (options.krylov_recycle_reset_per_rung) fea_reset_krylov_recycle_space();
    SimpOptions opt = options.simp;
    // Handoff 123 — when the conditional gate fires, this rung runs in TWO
    // phases (grayscale MMA, then β-projection seeded from it) as two
    // simp_optimize calls. The projection phase's own iteration counter restarts
    // at 1, so this base offsets its forwarded progress/observe/snapshot iteration
    // numbers by the grayscale phase's iteration count, keeping `iter` MONOTONE
    // within the rung across both phases. 0 for the (single-phase) grayscale phase
    // and for every non-firing rung; captured by reference by the hooks below and
    // raised to the grayscale iteration count just before the projection phase.
    std::size_t rung_iter_base = 0;
    // Whole-domain optimize (handoff 080): rescale the rung's fraction from
    // "fraction of the Active envelope" to "fraction of the part" so a loose box
    // does not let the optimizer keep MORE material than the part. Target total
    // printed material is `vf * part_solid` voxels; `frozen_effective` of those are
    // spent on the always-printed Load/Fixture skin, so the Active budget targets
    // the remainder, and dividing by the Active count gives the simp fraction that
    // lands the TOTAL at `vf * part_solid`. Clamped to (0, 1]. Off the box path this
    // is exactly `vf` (byte-identical).
    opt.volume_fraction = vf;
    if (part_relative && active_effective > 0.0) {
      const double active_target = vf * part_solid - frozen_effective;
      opt.volume_fraction =
          std::min(1.0, std::max(params.density_min,
                                 active_target / active_effective));
    }
    // M7.mma.4 — the switchover: the driver, not the shared SimpOptions default,
    // owns the updater. Defaults to MMA (options.updater) so real runs use MMA;
    // set options.updater = OC to fall back. Overrides any simp.updater.
    opt.updater = options.updater;

    // Handoff draft-quality (a)+(b): drive this rung's adaptive loose→tight
    // trajectory tolerance. Draft writes ONLY the loose endpoint — opt.cg_tolerance
    // (the certification tolerance) is left untouched, so the final/certification
    // solves stay tight (B2). Disarmed => opt.cg_tolerance_loose keeps options.simp's
    // value (0 in production), byte-identical. Per-rung draft measurements (the
    // derived k, the escalation gap/verdict) reset here for this rung.
    if (draft_armed) opt.cg_tolerance_loose = options.draft_loose_tol;
    int draft_trailing_tight = 0;  // running trailing-tight count -> derived k
    int draft_k = 0;               // this rung's measured k (captured pre-projection)
    double draft_gap = -1.0;       // this rung's escalation signal (-1 = not measured)
    int draft_escalated = 0;       // 1 iff this rung was re-run tight (part d)
    double draft_probe_flip = -1.0;  // Phase 2 design-space signal (-1 = not probed)
    long long draft_probe_cg = 0;    // Phase 2 probe cost (CG iters)
    double draft_probe_tightmove = -1.0;  // diagnostic: flip(plateau, tight-step)

    // Handoff 110 — the warm-start seed for THIS rung (Part B coarse upsample for
    // rung 0, Part A carry-over from the previous rung otherwise). EMPTY (the
    // default with both features off) selects simp_optimize's uniform start, so
    // the default path is byte-identical. The driver OWNS this field: any value on
    // options.simp.initial_design is overridden here, exactly like progress/cancel.
    opt.initial_design = warm_seed;

    // M7.rmin: derive the density-filter radius from a PHYSICAL length scale so
    // the filtered minimum member thickness is resolution independent. When
    // min_feature_mm is 0 the caller's voxel-unit simp.filter_radius is used
    // unchanged (back-compat: the Gate-V2 fixture and every direct simp caller
    // are untouched — they never set min_feature_mm and never route here).
    if (options.min_feature_mm > 0.0)
      opt.filter_radius =
          physical_filter_radius(options.min_feature_mm, G.spacing);

    // M7.0a: the driver owns the optimizer's progress/cancel hooks (any set on
    // options.simp are overridden — pipeline.hpp). Per-rung progress forwards
    // (rung index, rung count, iteration); the cancel flag is polled by the
    // optimizer once per OC iteration.
    opt.cancel = options.cancel;
    opt.progress = nullptr;
    if (options.progress) {
      const std::size_t rung_count = ladder.size();
      opt.progress = [&options, &rung_iter_base, rung, rung_count](
                         int iteration, double, double) {
        options.progress(rung, rung_count,
                         iteration + static_cast<int>(rung_iter_base));
      };
    }

    // Handoff 114 — per-iteration observability forwarding. `observe` carries the
    // rich per-row record (CSV) with the rung index attached; `density_observer`
    // feeds the raw per-iteration physical field to the snapshot writer as a
    // non-boundary event. Both wired only when the caller attached the driver-level
    // sink, so the default path leaves opt.observe / opt.density_observer null and
    // is byte-identical. `G` (the solved grid) outlives the synchronous solve.
    // The observe hook is ALWAYS set now (read-only, does not change the design):
    // it tallies multigrid engagement for the loud-fallback report, and ALSO
    // forwards to the caller's on_iteration sink when one is attached. With no
    // sink attached the tally is the only effect, and the design is byte-identical
    // (observability, not solver behavior — THE ONE RULE, handoff 114).
    {
      const std::size_t rung_count = ladder.size();
      opt.observe = [&, rung, rung_count](const SimpIterationObservation& obs) {
        ++total_solve_count;
        if (obs.cg_used_multigrid) {
          ++mg_solve_count;
          observed_mg_levels = obs.cg_mg_levels;
        }
        if (obs.cg_hier_built) mg_hierarchy_ever_built = true;
        // Handoff draft-quality: the DERIVED k. Count this rung's TRAILING
        // iterations whose adaptive trajectory tolerance has tightened to within one
        // decade of the certification floor. A tight iteration extends the run; a
        // loose one resets it, so at rung end the counter holds the trailing tight
        // tail. Read before any conditional-projection phase (which reuses this same
        // hook) so it is the grayscale draft rung's tail, not the projection's.
        if (draft_armed) {
          if (obs.cg_trajectory_tol <= kDraftTightBand) ++draft_trailing_tight;
          else draft_trailing_tight = 0;
        }
        if (options.on_iteration) {
          // Offset the projection phase's restarted iteration counter so `iter`
          // stays monotone within the rung (handoff 123). obs.beta already carries
          // the continuation sharpness (0 in the grayscale phase).
          SimpIterationObservation o = obs;
          o.iteration += static_cast<int>(rung_iter_base);
          options.on_iteration(rung, rung_count, o);
        }
      };
    }
    opt.density_observer = nullptr;
    if (options.on_density_snapshot) {
      const std::size_t rung_count = ladder.size();
      opt.density_observer = [&options, &G, &rung_iter_base, rung, rung_count](
                                 int iteration, const std::vector<double>& d) {
        DensitySnapshotEvent ev;
        ev.rung_index = rung;
        ev.rung_count = rung_count;
        ev.iteration = iteration + static_cast<int>(rung_iter_base);
        ev.boundary = false;
        ev.density = &d;
        ev.grid = &G;
        options.on_density_snapshot(ev);
      };
    }

    MinimizePlasticVariant variant;
    variant.requested_volume_fraction = vf;

    // Playback keyframes (M7): capture ~keyframe_count meshes of the analysis
    // density across this rung's iterations (stride spreads them over the run —
    // projection = summed stage iterations, else max_iterations). The callback
    // extracts a raw marching-cubes isosurface per snapshot, so no density fields
    // accumulate. `variant` outlives the (synchronous) simp_optimize call.
    if (options.keyframe_count > 0) {
      int total_iters = 0;
      if (!opt.projection.empty())
        for (const ProjectionStage& s : opt.projection) total_iters += s.iterations;
      else
        total_iters = opt.max_iterations;
      opt.keyframe_stride =
          std::max(1, total_iters / std::max(1, options.keyframe_count));
      opt.keyframe = [&variant, &G](const std::vector<double>& d) {
        variant.keyframe_meshes.push_back(marching_cubes(G, d, kIso));
      };
    }

    variant.optimization = simp_optimize(G, params, B, loads, opt, mask);

    // --- Handoff 2026-07-25-draft-quality (d): THE ESCALATION GATE ------------
    // The draft grayscale rung is done. Its self-contained divergence signal is the
    // gap between its FINAL LOOSE trajectory compliance (history.back()) and its
    // EXACT CERTIFIED compliance (variant.optimization.compliance — the tight final
    // solve inside simp_optimize, B2). Both are already computed; NO exact trajectory
    // is run to obtain the signal, which is the whole point. If the gap exceeds the
    // envelope the draft basin diverged, so RE-RUN this rung at the tight tolerance
    // from its OWN warm-start seed — opt.initial_design still holds `warm_seed`,
    // which is not mutated until AFTER this rung (the seed guard runs post-analysis
    // below), so the rung IS re-runnable from recoverable state. Measured here,
    // before conditional projection, so projection (if it fires) runs on the
    // corrected field. Skipped for a cancelled/infeasible rung (no terminal design
    // to trust). Inert (and the draft_rung_* vectors stay empty) unless draft armed.
    if (draft_armed && !variant.optimization.cancelled &&
        !variant.optimization.infeasible && !variant.optimization.non_convergent) {
      draft_k = draft_trailing_tight;  // grayscale draft rung's tightening tail
      const double c_cert = variant.optimization.compliance;  // tight final solve (B2)
      const double c_traj = variant.optimization.history.empty()
                                ? c_cert
                                : variant.optimization.history.back().compliance;
      draft_gap = c_cert > 0.0 ? std::fabs(c_cert - c_traj) / c_cert : 0.0;

      // --- Phase 2 (2026-07-26): the DESIGN-SPACE escalation decision -----------
      // Phase 1 escalated on `draft_gap`, which was MEASURED not to separate. When
      // the design trigger is armed the decision is made instead on a self-contained
      // DESIGN-SPACE probe that asks, directly: at THIS rung's converged loose design,
      // does a TIGHT solve want to move the design somewhere a LOOSE solve does not?
      //
      // The probe takes TWO one-step reseeds from the SAME plateau design
      // (variant.optimization.physical_density), with the memoryless OC updater:
      //   rho_loose = one OC step whose FEA is solved at the trajectory's LOOSE tol,
      //   rho_tight = one OC step whose FEA is solved at the exact cert tol,
      // and reports the fraction of solid voxels whose printed<->void classification
      // DIFFERS between them. Both steps reseed identically (same warm_start_design
      // inverse-filter of the same field) and take one OC step, so the reseed / filter
      // / volume-bisection displacement is COMMON to both and cancels in the diff — a
      // naive "plateau vs one tight step" comparison instead carried that displacement
      // as a 0.36 spurious floor (measured). What survives is only the difference the
      // FEA tolerance makes to the step direction: ~0 when the loose sensitivities
      // already agree with tight (converged), and large when the loose trajectory
      // settled on sensitivities a tight solve rejects (diverged). The negative-
      // control floor (D2, tight-vs-tighter) is this same construction with the loose
      // tol set barely above cert, so it needs no special path.
      //
      // Both probe results are DISCARDED (never assigned back into `variant`), so the
      // probe is read-only with respect to the trajectory it measures — the
      // BLOCKED-STOP condition (a probe that disturbs its own measurement) does not
      // arise. When the trigger is disarmed the Phase-1 gap decision runs unchanged.
      bool escalate;
      if (draft_design_trigger_armed) {
        const std::vector<double> plateau = variant.optimization.physical_density;
        // One memoryless OC step from `plateau`, its FEA solved at `step_loose_tol`
        // (0 => exact cert tol). max_iterations == draft_probe_iters. Tally-only
        // observe (counts CG cost; never a second on_iteration/CSV row for this rung).
        auto probe_step = [&](double step_loose_tol, long long& cg_out) {
          SimpOptions op = opt;
          op.updater = SimpUpdater::OC;   // memoryless: a KKT point maps to itself
          op.adaptive_move = false;       // OC path: adaptive move is MMA-only (rejected)
          op.cg_tolerance = kCertTol;     // the tight endpoint is always exact (D6)
          op.cg_tolerance_loose = step_loose_tol;  // this step's FEA tolerance
          op.max_iterations = std::max(1, options.draft_probe_iters);
          op.mma_plateau_window = 0;      // run the fixed budget, no early plateau stop
          op.projection.clear();
          op.mma_projection = false;
          op.initial_design = plateau;
          op.progress = nullptr;
          op.density_observer = nullptr;
          op.keyframe = nullptr;
          op.cancel = options.cancel;
          op.observe = [&](const SimpIterationObservation& o) {
            ++total_solve_count;
            cg_out += o.cg_iterations;
            if (o.cg_used_multigrid) {
              ++mg_solve_count;
              observed_mg_levels = o.cg_mg_levels;
            }
            if (o.cg_hier_built) mg_hierarchy_ever_built = true;
          };
          return simp_optimize(G, params, B, loads, op, mask).physical_density;
        };
        long long cg_loose = 0, cg_tight = 0;
        const std::vector<double> rho_loose =
            probe_step(options.draft_loose_tol, cg_loose);  // loose-FEA step
        const std::vector<double> rho_tight = probe_step(0.0, cg_tight);  // tight step
        assert(opt.cg_tolerance == kCertTol &&
               "draft quality: the design-space probe's tight endpoint must equal the "
               "certification tolerance — the gate never softens (D6)");
        draft_probe_cg = cg_loose + cg_tight;
        // Design-space divergence: fraction of the plateau design's SOLID voxels whose
        // classification differs between the loose-FEA and tight-FEA one-step iterates.
        // Also the DIAGNOSTIC `tightmove`: how far the tight step alone moves the
        // plateau (flip(plateau, rho_tight)) — near 0 means the plateau is already
        // tight-stationary, a locally stable basin the probe cannot escape.
        long long ref_solid = 0, flips = 0, tmove = 0;
        for (std::size_t v = 0; v < plateau.size(); ++v) {
          const bool s = plateau[v] > kIso;   // count over the shipped design's solid
          if (s) ++ref_solid;
          if ((rho_loose[v] > kIso) != (rho_tight[v] > kIso)) ++flips;
          if (s != (rho_tight[v] > kIso)) ++tmove;
        }
        draft_probe_flip =
            ref_solid > 0 ? static_cast<double>(flips) / static_cast<double>(ref_solid)
                          : 0.0;
        draft_probe_tightmove =
            ref_solid > 0 ? static_cast<double>(tmove) / static_cast<double>(ref_solid)
                          : 0.0;
        escalate = draft_probe_flip > options.draft_escalation_design_flip;
      } else {
        // Phase 1 fallback: the provisional compliance-gap trigger (superseded). A
        // threshold <= 0 escalates EVERY rung (the maximally-conservative posture).
        escalate = options.draft_escalation_c_gap <= 0.0 ||
                   draft_gap > options.draft_escalation_c_gap;
      }
      if (escalate) {
        // Re-run at the tight tolerance from the SAME seed. Disable the loose
        // schedule; leave cg_tolerance (certification) untouched. The re-run's
        // observe is TALLY-ONLY: its iterations are real cost counted toward the
        // multigrid tally, but they are not a second set of per-iteration CSV /
        // on_iteration rows for the same rung index, and they must not disturb the
        // already-captured draft_k.
        SimpOptions opt_esc = opt;
        opt_esc.cg_tolerance_loose = 0.0;
        assert(opt_esc.cg_tolerance == kCertTol &&
               "draft quality: escalation must never loosen the certification "
               "tolerance");
        opt_esc.progress = nullptr;
        opt_esc.density_observer = nullptr;
        opt_esc.keyframe = nullptr;
        opt_esc.observe = [&](const SimpIterationObservation& o) {
          ++total_solve_count;
          if (o.cg_used_multigrid) {
            ++mg_solve_count;
            observed_mg_levels = o.cg_mg_levels;
          }
          if (o.cg_hier_built) mg_hierarchy_ever_built = true;
        };
        variant.optimization = simp_optimize(G, params, B, loads, opt_esc, mask);
        draft_escalated = 1;
      }
    }

    // --- Handoff 123: conditional MMA projection ("polish only when gray") ----
    // After the rung's GRAYSCALE MMA converges, measure the design-region
    // grayness of the converged field. BELOW the threshold the rung is already
    // crisp — keep it as-is (the whole cost was one field scan; the always-on
    // ~4× projection tax is never charged). ABOVE it, continue THE SAME RUNG into
    // β-continuation seeded from the converged gray field (handoff 116's
    // machinery, β restarting at β0 and staging to the capped-β plateau, exactly
    // as a warm-started rung projects — 116 interaction a). The two phases are
    // merged into one rung result: summed iterations, contiguous history, the
    // rung's true grayscale start compliance, and the CRISP projected field the
    // downstream stress/mass/V3 analysis reads. Only on a non-cancelled rung; a
    // cancel in either phase falls through to the cancelled branch below. When the
    // gate is disarmed this block is skipped entirely (byte-identical).
    double rung_mnd = std::numeric_limits<double>::quiet_NaN();
    bool rung_fired = false;
    // Handoff 131 — an INFEASIBLE grayscale phase is never polished: β-projection
    // on a severed structure is hours spent sharpening a corpse. The gate is
    // skipped exactly as it is for a cancelled rung.
    if (conditional_projection_armed && !variant.optimization.cancelled &&
        !variant.optimization.infeasible && !variant.optimization.non_convergent) {
      rung_mnd = design_discreteness_mnd(G, variant.optimization.physical_density,
                                         mask);
      if (rung_mnd > options.conditional_mma_projection_mnd_threshold) {
        rung_fired = true;
        std::vector<double> gray_field = variant.optimization.physical_density;
        std::vector<SimpIteration> gray_history =
            std::move(variant.optimization.history);
        const int gray_iters = variant.optimization.iterations;
        const double gray_initial_c = variant.optimization.initial_compliance;

        // Seed the projection phase from the converged gray density and turn the
        // MMA-correct Heaviside continuation ON for this rung only. `opt` is a
        // per-rung copy (rebuilt from options.simp next iteration), so this never
        // leaks to another rung. rung_iter_base makes the forwarded progress/
        // observe/snapshot iteration numbers continue this rung's count.
        opt.mma_projection = true;
        opt.initial_design = std::move(gray_field);
        rung_iter_base = static_cast<std::size_t>(gray_iters);

        SimpOptimizeResult proj =
            simp_optimize(G, params, B, loads, opt, mask);

        proj.iterations += gray_iters;
        // Handoff 131 — if the PROJECTION phase is the one that went infeasible,
        // its iteration counter restarted at 1, so offset it by the grayscale
        // phase exactly as `iterations` and the forwarded CSV `iter` are offset.
        // The reported firing iteration then indexes the rung, not the phase.
        if (proj.infeasible) proj.infeasible_iteration += gray_iters;
        proj.initial_compliance = gray_initial_c;
        std::vector<SimpIteration> merged = std::move(gray_history);
        merged.insert(merged.end(), proj.history.begin(), proj.history.end());
        proj.history = std::move(merged);
        variant.optimization = std::move(proj);
      }
    }
    // Record the per-rung gate outcome (aligned with `evaluated` — one push per
    // loop iteration, exactly like the evaluated push below / in the cancel
    // branch). Left EMPTY across the whole run when the gate is disarmed.
    if (conditional_projection_armed) {
      result.rung_grayscale_mnd.push_back(rung_mnd);
      result.conditional_projection_fired.push_back(rung_fired ? 1 : 0);
    }

    if (variant.optimization.cancelled) {
      // Cancelled mid-rung: report this rung as the rejected terminal rung and
      // stop. The per-rung analysis (stress solve, V3 suite, settings) is
      // skipped — the caller asked to abort, and the half-optimized field is
      // not shipped (pipeline.hpp `cancelled` contract).
      variant.accepted = false;
      result.evaluated.push_back(std::move(variant));
      result.rung_infeasible.push_back(0);
      record_rung_convergence(false, 0, 0.0);  // cancelled: no solve verdict
      record_draft_rung(draft_k, draft_gap, draft_escalated, draft_probe_flip, draft_probe_cg, draft_probe_tightmove);  // sentinel: cancelled
      result.cancelled = true;
      break;
    }

    // --- Handoff 131: RUNG INFEASIBLE (load path lost) -----------------------
    // The optimizer ended this rung on the infeasibility signature: for 5
    // consecutive iterations the objective sat >= 100x the rung's starting
    // compliance, FROZEN to within 1e-3 (the design no longer moves it at all),
    // with a >= 4x CG blow-up (simp.hpp rung_infeasible). The design is a corpse.
    // Three things follow, and each one is a fix for something the motivating 96³
    // run actually did:
    //   (1) NO ANALYSIS. The stress solve, V3 suite and settings engine are
    //       skipped, exactly as for a cancelled rung. Analysing a corpse produces
    //       confident nonsense: that run's severed rung measured margin 680.9 —
    //       a structure carrying nothing has no stress — and was ACCEPTED and
    //       exported as variant_038.stl on the strength of it.
    //   (2) NO INHERITANCE. `warm_seed` is left UNTOUCHED, so it still holds the
    //       last FEASIBLE rung's converged density (or is empty when there has
    //       been none / inheritance is off). That run seeded rung 3 from rung 2's
    //       corpse and spent 27 more iterations at the same dead compliance —
    //       and, note, a rung seeded from a corpse cannot even be DETECTED,
    //       because its own starting compliance is already the dead value, so
    //       nothing is ever 100x above it. Not inheriting is what keeps the
    //       detector able to see the next rung at all.
    //   (3) NO STOP. The ladder continues. Infeasibility is a failure of THIS
    //       carve — not the strength verdict that `stopped_on_margin` is — so the
    //       next (lighter) rung gets a fresh attempt from the last feasible field.
    //       If it too disconnects it also fast-fails, so the worst case is
    //       window+1 iterations per remaining rung instead of a full rung each.
    // The rung is REPORTED, never silently dropped: a rejected report line whose
    // rejection_reason says why, with the measured geometry it does have
    // (achieved/printed fraction) and zero placeholders for everything the skipped
    // analysis would have filled.
    if (variant.optimization.infeasible) {
      variant.infeasible = true;
      variant.accepted = false;

      // Geometry is a voxel count, not an analysis: report it honestly.
      std::size_t printed_voxels = 0;
      for (int k = 0; k < G.nz; ++k)
        for (int j = 0; j < G.ny; ++j)
          for (int i = 0; i < G.nx; ++i) {
            if (!G.solid(i, j, k)) continue;
            if (variant.optimization.physical_density[G.index(i, j, k)] > kIso)
              ++printed_voxels;
          }
      const double printed_fraction =
          part_solid > 0.0 ? static_cast<double>(printed_voxels) / part_solid
                           : 0.0;

      VariantReport& vr = variant.report;
      vr.volume_fraction = std::min(1.0, printed_fraction);
      vr.printed_fraction = std::min(1.0, printed_fraction);
      vr.accepted = false;
      vr.margin_required = options.margin_stop;
      vr.rejection_reason = kRungInfeasibleReason;
      // Every other field stays default-constructed: zero stress, zero margin,
      // zero orientation, empty settings. They are NOT measurements — the
      // rejection_reason is the flag that says so (report.hpp).

      result.evaluated.push_back(std::move(variant));
      result.rung_infeasible.push_back(1);
      record_rung_convergence(false, 0, 0.0);  // infeasible: the solves converged
      record_draft_rung(draft_k, draft_gap, draft_escalated, draft_probe_flip, draft_probe_cg, draft_probe_tightmove);  // sentinel: infeasible
      result.report.rejected.push_back(result.evaluated.back().report);
      assert(result.evaluated.size() <= ladder.size() &&
             "minimize_plastic: result.evaluated grew past its reserved capacity");
      continue;  // (2) warm_seed untouched, (3) ladder continues
    }

    // --- Handoff 2026-07-27-nonconvergence-rejection: RUNG NON-CONVERGENT --------
    // A TRAJECTORY solve for this rung did not converge (SolverNonConvergence: CG
    // hit its cap short of tolerance), so simp_optimize ended the rung with
    // `non_convergent` set instead of throwing out of the whole run (PR 209's AD-on-
    // at-L posture is exactly this: it does not converge at all). This rung is
    // handled EXACTLY as an infeasible one — the SAME three consequences, each for
    // the same reason:
    //   (1) NO ANALYSIS. There is no trustworthy field: the solver could not resolve
    //       the displacement, so stress/margin/mesh would be built on garbage. The
    //       stress solve, V3 suite and settings are skipped, exactly as for a
    //       cancelled or infeasible rung.
    //   (2) NO INHERITANCE. This branch sits BEFORE the warm_seed update below, so
    //       `warm_seed` is left holding the last FEASIBLE (converged, connected)
    //       rung's density (or empty). A rung that could not be solved must not seed
    //       the next — handoff 131's rule, for the same reason. Shown by the test:
    //       the rung AFTER a non-convergent one inherits what it would have inherited
    //       had the non-convergent rung not run.
    //   (3) NO STOP. The ladder continues. Non-convergence is a property of THIS
    //       carve's operator (a near-singular high-contrast field), not a strength
    //       verdict about lighter targets, so the next rung gets a fresh attempt.
    // Reported, never dropped: a rejected line whose rejection_reason is
    // kRungNonConvergentReason, carrying the geometry it honestly has (printed voxel
    // count) and ZERO placeholders for the analysis it never ran; the iteration and
    // residual the solve reached go to run_info.json (rung_non_convergent_*).
    if (variant.optimization.non_convergent) {
      variant.non_convergent = true;
      variant.accepted = false;

      std::size_t printed_voxels = 0;
      for (int k = 0; k < G.nz; ++k)
        for (int j = 0; j < G.ny; ++j)
          for (int i = 0; i < G.nx; ++i) {
            if (!G.solid(i, j, k)) continue;
            if (variant.optimization.physical_density[G.index(i, j, k)] > kIso)
              ++printed_voxels;
          }
      const double printed_fraction =
          part_solid > 0.0 ? static_cast<double>(printed_voxels) / part_solid
                           : 0.0;

      VariantReport& vr = variant.report;
      vr.volume_fraction = std::min(1.0, printed_fraction);
      vr.printed_fraction = std::min(1.0, printed_fraction);
      vr.accepted = false;
      vr.margin_required = options.margin_stop;
      vr.rejection_reason = kRungNonConvergentReason;
      // Every other field stays default-constructed — NOT measurements. The
      // rejection_reason is the flag that says so.

      const int nc_iter = variant.optimization.non_convergent_iteration;
      const double nc_resid = variant.optimization.non_convergent_residual;
      result.evaluated.push_back(std::move(variant));
      result.rung_infeasible.push_back(0);
      record_rung_convergence(true, nc_iter, nc_resid);
      record_draft_rung(draft_k, draft_gap, draft_escalated, draft_probe_flip, draft_probe_cg, draft_probe_tightmove);  // sentinel: non-convergent
      result.report.rejected.push_back(result.evaluated.back().report);
      assert(result.evaluated.size() <= ladder.size() &&
             "minimize_plastic: result.evaluated grew past its reserved capacity");
      continue;  // (2) warm_seed untouched, (3) ladder continues
    }

    const std::vector<double>& rho = variant.optimization.physical_density;

    // --- The CONNECTIVITY BELT ------------------------------------------------
    // (handoff 2026-07-23-gate-honesty-connectivity-rejection). Ask the converged
    // geometry the one question the margin cannot answer: is there any path of
    // PRINTED material from the anchor to the load? A severed design carries
    // nothing, so it measures NO stress, and no stress reads as an ENORMOUS margin
    // — the motivating run's severed rung measured 680.9 and was accepted and
    // exported on that basis (handoff 131 §evidence). The rung-infeasibility
    // fast-fail catches the SUSTAINED case mid-rung; this belt covers the window it
    // cannot see: a design that breaks LATE and then converges, whose compliance
    // never sits frozen at 100x its start for 5 iterations.
    //
    // Measured HERE (read-only on `rho`, before anything consumes this rung) so the
    // verdict governs BOTH the warm seed below and the acceptance gate further down;
    // it is the gate that acts on it, so no variant is ever certified without it.
    // Vacuously true when the run has no Load or no Fixture voxels (a self-weight
    // run tags no load faces), so a CONNECTED variant — every existing fixture —
    // takes exactly the pre-belt path to exactly the pre-belt verdict.
    const bool load_path_ok = load_path_connected(G, rho, kIso);

    // Handoff 110 (Part A) — carry this rung's CONVERGED density forward to seed
    // the next (lighter) rung when inheritance is on; otherwise clear the seed so
    // the next rung starts uniform (Part B only warm-starts rung 0). Copied HERE,
    // before `variant` is moved into result.evaluated below, since `rho` aliases
    // its density. With warm_start_inherit off this always clears to empty, so the
    // next rung's opt.initial_design is empty — the uniform, byte-identical path.
    //
    // A DISCONNECTED rung never seeds anything — handoff 131's rule (2) for the
    // same reason: seeding the next rung from a severed field propagates the
    // severance and buries the evidence of where it started. `warm_seed` is left
    // UNTOUCHED, so it still holds the last CONNECTED rung's density (or is empty).
    // With inheritance off it is empty either way, so this guard is inert there.
    if (load_path_ok)
      warm_seed = options.warm_start_inherit ? rho : std::vector<double>();

    // Handoff 114 — rung-BOUNDARY density snapshot: the converged physical field
    // of this (non-cancelled) rung. `rho` already carries the mask pins (it is
    // variant.optimization.physical_density). The last boundary emitted across the
    // ladder is the terminal design. Only fired when a sink is attached.
    if (options.on_density_snapshot) {
      DensitySnapshotEvent ev;
      ev.rung_index = rung;
      ev.rung_count = ladder.size();
      ev.iteration = variant.optimization.iterations;
      ev.boundary = true;
      ev.density = &rho;
      ev.grid = &G;
      options.on_density_snapshot(ev);
    }

    // The per-rung CERTIFICATION: ONE penalized solve on the converged density,
    // recovering the per-voxel von Mises / Cauchy-tensor / displacement fields,
    // printed mass, the support proxy, the worst-case margin, the §7 V3 suite and
    // the acceptance verdict. Extracted to analyze_fixed_design (handoff
    // 2026-07-26-constrained-smooth) so a standalone re-analysis of an edited /
    // smoothed mesh runs the IDENTICAL code: handed THIS variant's own converged
    // density (with the same grid/BCs/loads/params/solver/tolerance) it reproduces
    // every number below bit-for-bit — the correctness bar test_analyze_fixed_design
    // pins.
    //
    // Solver selection (handoff 073) and the cert tolerance / max-iterations flow
    // from `opt` exactly as the inline recovery block used them; default JacobiCG
    // keeps this byte-identical. B2 (draft quality): the certification solve ALWAYS
    // runs at the tight cg_tolerance — draft mode writes only cg_tolerance_loose —
    // asserted (not commented) so draft is structurally incapable of certifying a
    // stress margin on a loosened solve. load_path_ok is the connectivity belt
    // verdict measured above, on the converged density; analyze_fixed_design gates
    // on it so a severed rung is rejected however good its (meaningless) margin.
    assert(opt.cg_tolerance == kCertTol &&
           "draft quality: recovery/certification solve must use the tight "
           "tolerance");
    FixedDesignAnalysis fda = analyze_fixed_design(
        G, params, rho, B, loads, material, build_dir, opt.cg_tolerance,
        opt.cg_max_iterations, opt.solver, options.margin_stop, knockdown,
        load_path_ok, part_solid, /*lattice=*/nullptr,
        // The orientation ranking rides on THIS rung's certification solve
        // (handoff 2026-08-01-build-direction-separation). Per-rung, because
        // each rung is a different design and so has its own overhangs and its
        // own interlayer field — a ranking taken from one rung would not
        // describe the others. PR 266 measured the sweep at 0.1-0.4% of the
        // solve it rides on, so paying it per rung is a rounding error.
        // Disarmed by default => byte-identical.
        score_orientations, resolve_build_direction_is_inferred(options),
        // AUTO-APPLY (handoff 2026-08-01-bake-build-orientation): when no build
        // direction was declared, the recommendation BECOMES this rung's
        // certified orientation and the export below is rotated onto it. Never
        // when the user declared one — resolve_bake_plan is what guarantees that.
        bake_plan.auto_apply);

    // --- Handoff 2026-07-27-nonconvergence-rejection: CERTIFICATION NON-CONVERGENT ─
    // The trajectory converged to a connected design, but the CERTIFICATION solve —
    // stateless, cold, at the tight cg_tolerance — did not converge (PR 200 found a
    // real variant that does exactly this during re-certification). N2's rule is
    // absolute: the certification tolerance was NOT softened (analyze_fixed_design
    // asserts it), so a design the certification solve cannot resolve is REJECTED,
    // never certified. `fda.accepted` is forced false on this path, but we branch on
    // the flag directly and reject here — before reading ANY of fda's default/empty
    // fields as if they were measurements.
    //
    // Warm-start (N3): unlike the trajectory-non-convergent branch above, warm_seed
    // was ALREADY updated (a few lines up, gated on load_path_ok) with THIS rung's
    // converged, connected density — and it is left as-is. That is handoff 131's rule
    // exactly: warm_seed carries the last rung that produced a converged, connected
    // field, whether or not it was ultimately accepted (a too-weak rung seeds the next
    // one the same way). The certification solve failing does not make the trajectory
    // design a corpse: it converged, it is connected, and it is the right seed. What
    // does NOT seed is a rung whose TRAJECTORY could not be solved (handled above,
    // before this update). The two branches differ because the facts differ.
    if (fda.non_convergent) {
      variant.non_convergent = true;
      variant.accepted = false;

      // The trajectory converged, so `rho` is a real design: count its printed
      // voxels honestly (analyze returned early with printed_voxels == 0, so we do
      // NOT read that). This is the one geometry number we legitimately have.
      std::size_t printed_voxels_nc = 0;
      for (int k = 0; k < G.nz; ++k)
        for (int j = 0; j < G.ny; ++j)
          for (int i = 0; i < G.nx; ++i) {
            if (!G.solid(i, j, k)) continue;
            if (rho[G.index(i, j, k)] > kIso) ++printed_voxels_nc;
          }
      VariantReport& vr = variant.report;
      const double printed_fraction_nc =
          part_solid > 0.0
              ? static_cast<double>(printed_voxels_nc) / part_solid
              : 0.0;
      vr.volume_fraction = std::min(1.0, printed_fraction_nc);
      vr.printed_fraction = std::min(1.0, printed_fraction_nc);
      vr.accepted = false;
      vr.margin_required = options.margin_stop;
      vr.rejection_reason = kRungNonConvergentReason;
      // No margin, stress, orientation or settings — the certification never
      // completed. The rejection_reason is the flag that says so.

      result.evaluated.push_back(std::move(variant));
      result.rung_infeasible.push_back(0);
      record_rung_convergence(true, fda.non_convergent_iteration,
                              fda.non_convergent_residual);
      record_draft_rung(draft_k, draft_gap, draft_escalated, draft_probe_flip, draft_probe_cg, draft_probe_tightmove);  // sentinel: non-convergent
      result.report.rejected.push_back(result.evaluated.back().report);
      assert(result.evaluated.size() <= ladder.size() &&
             "minimize_plastic: result.evaluated grew past its reserved capacity");
      continue;  // (3) ladder continues
    }

    variant.von_mises_field = std::move(fda.von_mises_field);
    variant.stress_tensor_field = std::move(fda.stress_tensor_field);
    variant.displacement_field = std::move(fda.displacement_field);
    variant.mass_grams = fda.mass_grams;
    variant.support_volume_voxels = fda.support_volume_voxels;
    // The orientation RANKING for this rung (empty unless armed). Carried onto
    // the variant beside the numbers it was measured with; it is a
    // recommendation and nothing downstream may gate on it.
    variant.build_orientation = std::move(fda.build_orientation);
    // The orientation this rung is CERTIFIED in, and whether its exported mesh
    // carries it (handoff 2026-08-01-bake-build-orientation). `applied_build_dir`
    // is `build_dir` unless the orientation was chosen for the user; `bake`
    // comes from the ONE plan, so the file and this record cannot disagree.
    variant.applied_build_dir = fda.applied_build_dir;
    variant.build_direction_auto_applied = fda.build_direction_auto_applied;
    variant.export_baked = bake_plan.bake;
    const std::size_t printed_voxels = fda.printed_voxels;
    const double max_von_mises = fda.max_von_mises;
    const double max_interlayer = fda.max_interlayer_tension;

    // --- Two-basis volume reporting (handoff 104, resolving 102) --------------
    // TWO distinct quantities are reported, each answering ONE question, because on
    // a grayscale MMA field the two genuinely disagree and grow apart as the target
    // shrinks (MMA has no Heaviside projection — projection_supported(MMA)==false —
    // so the physical density is a ramp ~1 filter-radius wide, and a large
    // sub-threshold fringe carries real mass in Σρ but 0 in #{ρ>0.5}):
    //
    //  (1) variant.optimization.volume_fraction — the OPTIMIZER'S ACHIEVED fraction
    //      ("did the solve hit its volume target?"). NO-BOX path: the optimizer's
    //      continuous fraction Σρ/n_active over the active design set (== the part
    //      here: G==grid, and the only frozen voxels are the 1-voxel BC skin), which
    //      the volume constraint drives to the request — 0.6997/0.4997/0.2997 for
    //      0.7/0.5/0.3 (102's transcripts). It is simp_optimize's own value, left
    //      UNTOUCHED here: handoff 094 had overwritten it with the count basis (2)
    //      below, which silently redefined the cli_demo line-252 invariant to test
    //      the count instead of the achieved fraction; 104 reverts that. BOX path
    //      (080 whole-domain): the solve targets the Active ENVELOPE, so simp's raw
    //      fraction is not part-relative; 080's overwrite to printed_voxels/part_solid
    //      stands (the `part_relative` branch below) — the "same part-relative
    //      normalization handoff 080 established on the box path".
    //
    //  (2) printed_fraction — the PRINTED / thresholded count basis ("how much
    //      material actually prints?") = #{ρ>0.5}/part_solid, the SAME voxel count the
    //      reported mass is built from (mass = density·printed_voxels·voxel_volume
    //      /1000). Savings% (= 1 - printed_fraction) and mass are therefore two views
    //      of one count and can never disagree — this is handoff 094's fix, preserved
    //      exactly but moved to its own field. On the no-box path printed_voxels is the
    //      printed shape on the part grid; on the box add-material path it counts kept
    //      part + grown material, so the value can exceed 1 (net material added →
    //      negative savings), which is honest.
    //
    // Both bases, and why they diverge on gray MMA fields, are stated in
    // tests/fixtures/demo/expected_values.json and docs/handoffs/104.
    const double printed_fraction =
        part_solid > 0.0 ? static_cast<double>(printed_voxels) / part_solid : 0.0;
    if (part_relative && part_solid > 0.0)
      variant.optimization.volume_fraction = printed_fraction;

    // Worst-case stress margin (M5.2 locked definition) and the §7 V3 property
    // suite (M3.5), both computed inside analyze_fixed_design above.
    const StressMargin margin = fda.margin;
    variant.v3 = std::move(fda.v3);
    // The acceptance verdict, also decided inside analyze_fixed_design: gate on the
    // INFILL-ADJUSTED margin (margin_effective), rejected if the load path is
    // severed. The stored/displayed margin (vr.margin) stays the SOLID margin.
    // margin_ok is the margin test ALONE (no belt) — it decides whether the LADDER
    // stops (below), exactly the pre-belt condition on the pre-belt numbers.
    const double margin_effective = fda.margin_effective;
    const bool margin_ok = margin_effective >= options.margin_stop;
    variant.accepted = fda.accepted;

    // Assemble this rung's report line (M5.2 / M5.2b).
    VariantReport& vr = variant.report;
    // (1) the optimizer's achieved fraction (continuous no-box; 080 part-relative
    // count on the box path — see the two-basis note above). (2) the printed/count
    // basis that savings% and mass share (handoff 104).
    vr.volume_fraction = variant.optimization.volume_fraction;
    vr.printed_fraction = printed_fraction;
    vr.max_stress_mpa = max_von_mises;
    vr.max_interlayer_tension_mpa = max_interlayer;
    vr.margin = margin;
    // `orientation` is the build direction IN THE FRAME OF THE EXPORTED MESH
    // (handoff 2026-08-01-bake-build-orientation). Un-baked: the model-frame
    // direction, exactly as before. Baked: +Z, because the exported vertices
    // were rotated so that is true of the file — and the model-frame direction
    // travels beside it so nothing is lost.
    vr.export_baked = variant.export_baked;
    vr.orientation_model = variant.applied_build_dir;
    vr.orientation = variant.export_baked ? Vec3{0.0, 0.0, 1.0}
                                          : variant.applied_build_dir;
    vr.settings = recommend_settings(rules, material.family, margin.worst_case,
                                     part_dim_mm);
    // Report-honesty (handoff: multigrid-coarsenability-padding): when the job
    // requested a SPARSE infill (< 100), the run gated the margin for THAT infill
    // (the knockdown below), so the report's slicer infill must ECHO the job's
    // infill — the value the part is actually printed at and that run_info.json
    // records — not the rules engine's margin-derived recommendation, which would
    // slice the part at a different infill than its accepted margin assumes. At
    // solid/unset infill (100) the knockdown is a no-op and the engine
    // recommendation stands, so this is byte-identical for every existing run.
    if (options.infill_percent < 100.0)
      vr.settings.infill_percent =
          static_cast<int>(std::lround(options.infill_percent));
    vr.min_feature_violations = variant.v3.min_feature_violations;
    vr.min_feature_warning =
        min_feature_warning_text(rules, variant.v3.min_feature_violations);

    // The acceptance verdict (variant.accepted) and margin_effective were computed
    // by analyze_fixed_design above. Carry the numbers behind the verdict on the
    // report line so a REJECTED rung reports its own margin-vs-required (not a
    // silent omission).
    vr.accepted = variant.accepted;
    vr.margin_required = options.margin_stop;
    vr.margin_effective = margin_effective;
    // REJECTION SPEAKS: a rejected line always names its cause. When BOTH tests
    // fail the CONNECTIVITY reason wins, because it is the more fundamental fact
    // and it tells the reader what the margin on that line is worth: a number
    // measured on a severed structure, whichever side of the threshold it landed.
    if (!variant.accepted)
      vr.rejection_reason =
          load_path_ok ? kMarginBelowRequiredReason : kLoadPathNotConnectedReason;

    // ── WHY (handoff 2026-08-02-gate-diagnosis-recommendations) ───────────────
    // A POST-PASS, exactly like the build-orientation ranking: it runs AFTER
    // `variant.accepted` / `vr.margin_effective` above were sealed, it reads
    // them as INPUTS, and it writes ONLY to `vr.diagnosis`. It cannot move a
    // verdict — there is no assignment back to any gate field below this line.
    //
    // Every recommendation it emits was priced by gate_margin_effective, the
    // same expression the verdict came from. Off by default; production arms it
    // (configure_production_options), and with it off `vr.diagnosis.evaluated`
    // stays false and report.json is byte-for-byte what it was.
    if (options.gate_diagnosis) {
      GateDiagnosisInputs gd;
      gd.accepted = variant.accepted;
      gd.load_path_ok = load_path_ok;
      gd.margin_stop = options.margin_stop;
      gd.margin_effective = margin_effective;
      gd.margin = margin;
      gd.material = material;
      gd.material_name = material_name;
      gd.knockdown = knockdown;
      gd.max_von_mises = max_von_mises;
      gd.max_von_mises_effective = max_von_mises;  // default posture: unused
      gd.max_interlayer = max_interlayer;
      gd.infill_percent = options.infill_percent;
      gd.wall_loops = options.wall_loops;
      gd.wall_line_width_mm = options.wall_line_width_mm;
      gd.wall_line_width_outer_mm = options.wall_line_width_outer_mm;
      gd.min_feature_violations = vr.min_feature_violations;
      // 0 disables the min-feature binding entirely, which is the right reading
      // of an absent rules section ("no warning is configured").
      gd.min_feature_warning_threshold =
          rules.min_feature_warning.message_template.empty()
              ? 0
              : rules.min_feature_warning.threshold;
      gd.voxel_spacing_mm = G.spacing;
      gd.orientation = variant.build_orientation.evaluated
                           ? &variant.build_orientation
                           : nullptr;
      gd.materials = options.material_catalog;
      // A material swap only leaves the solved stress field alone when the
      // modulus is the ONLY thing that moves — true for a FORCE-driven linear
      // solve. A prescribed NON-ZERO displacement breaks that cancellation, so
      // the diagnosis is told and refuses to recommend a material swap.
      gd.poisson_locked = true;
      for (const DirichletBC& bc : bcs)
        if (bc.value != 0.0) { gd.poisson_locked = false; break; }
      gd.this_volume_fraction = vr.volume_fraction;
      for (const MinimizePlasticVariant& ev : result.evaluated) {
        GateSolvedRung r;
        r.volume_fraction = ev.report.volume_fraction;
        r.margin_effective = ev.report.margin_effective;
        r.accepted = ev.accepted;
        gd.solved_rungs.push_back(r);
      }
      // The width-aware posture's per-voxel population, so a candidate infill /
      // wall ring can be repriced exactly. Empty on the default (production)
      // path — analyze_fixed_design only fills them when width_aware is armed.
      gd.printed_von_mises = std::move(fda.gate_printed_von_mises);
      gd.printed_member_width_mm = std::move(fda.gate_printed_member_width_mm);
      // The RESOLUTION lever's one input. Measured only when the min-feature term
      // can actually bind (the strength gate passed and a warning is configured
      // and tripped) — the distance transform is O(cap · voxels) and no other
      // lever reads it, so no run pays for it speculatively.
      if (variant.accepted && gd.min_feature_warning_threshold > 0 &&
          vr.min_feature_violations >= gd.min_feature_warning_threshold) {
        const std::vector<double> thick =
            local_member_thickness_mm(G, rho, kIso, 32);
        double thinnest = std::numeric_limits<double>::infinity();
        for (std::size_t e = 0; e < thick.size(); ++e)
          if (rho[e] > kIso && thick[e] > 0.0 && thick[e] < thinnest)
            thinnest = thick[e];
        if (std::isfinite(thinnest)) gd.min_member_thickness_mm = thinnest;
      }
      vr.diagnosis = diagnose_gate(gd);
    }

    result.evaluated.push_back(std::move(variant));
    result.rung_infeasible.push_back(0);  // handoff 131 (aligned with `evaluated`)
    record_rung_convergence(false, 0, 0.0);  // analysed rung: solves converged
    record_draft_rung(draft_k, draft_gap, draft_escalated, draft_probe_flip, draft_probe_cg, draft_probe_tightmove);  // draft outcome (aligned)
    // Storage never reallocates (reserved to ladder.size() above), so the
    // references taken below stay valid for the whole run — see the reserve() note.
    assert(result.evaluated.size() <= ladder.size() &&
           "minimize_plastic: result.evaluated grew past its reserved capacity");

    if (result.evaluated.back().accepted) {
      result.report.variants.push_back(result.evaluated.back().report);
      // Progressive results: stream this accepted variant now, before optimizing
      // the next lighter rung. This hands the callback (bridge to_optimize_variant)
      // a REFERENCE to the variant living inside result.evaluated, which reads its
      // keyframe-mesh vector and displacement field. That is safe ONLY because
      // result.evaluated is reserved to its final size up front and so never
      // reallocates: without the reserve, a later rung's push_back that grew the
      // vector past capacity would reallocate and free the block a streamed
      // reference pointed into (ASan heap-buffer-overflow, read-after-realloc),
      // surfacing downstream as empty keyframeMeshes / displacementField.
      // The second argument is `result.evaluated` itself — the live container, so
      // a caller needing every rung so far reads it fresh rather than holding
      // pointers across calls (see MinimizePlasticOptions::on_variant).
      if (options.on_variant)
        options.on_variant(result.evaluated.back(), result.evaluated);

      // M7.anchor-integrity (FIX 2): the ladder FLOOR. Once an accepted rung
      // already clears the comfort floor, stop — do NOT keep stripping toward the
      // lightest rung just because the part could survive there. The comparison
      // uses `margin_effective` — the SAME infill-adjusted margin the acceptance
      // gate above uses (the width-aware composite when armed, else the scalar
      // worst_case·infill_knockdown), so the floor and the ceiling stay on one
      // scale (byte-identical to the pre-width test on the default path, where
      // margin_effective == worst_case·infill_knockdown). Disabled by default
      // (margin_floor_multiple == +infinity): the RHS is +infinity (or NaN when
      // margin_stop == 0), so the test is false for every finite margin and the
      // walk is byte-identical to the pre-M7.anchor-integrity ladder.
      if (margin_effective >=
          options.margin_floor_multiple * options.margin_stop) {
        result.stopped_on_floor = true;
        break;
      }
    } else {
      // A rejected rung is NOT dropped from the report — record it in
      // report.rejected (accepted=false, with its margin_effective vs
      // margin_required AND its rejection_reason) so the gate rejection is
      // reported, not a silent lie of absence.
      result.report.rejected.push_back(result.evaluated.back().report);
      // WHETHER THE LADDER STOPS is decided by the MARGIN TEST ALONE — exactly the
      // pre-belt condition, on exactly the pre-belt numbers. Strength is monotone in
      // the ladder direction, so once a rung falls under margin_stop no lighter rung
      // can pass and the walk ends; that is true whether or not the rung was also
      // severed, so the belt never suppresses a margin stop (a rung failing both
      // tests still ends the ladder, and its report line names the connectivity
      // failure as the reason it cannot be built).
      //
      // A rung rejected ONLY by the belt does NOT stop the walk. Severance is not a
      // strength verdict and is NOT monotone: each rung is optimized independently,
      // so it is a failure of THIS carve, and a lighter rung can perfectly well
      // converge to a connected topology. Measured on the 8x3x8 L-bracket
      // (test_warm_start_integration's fixture): rung 0 at vf 0.68 comes out SEVERED
      // while rungs 1 and 2 at 0.52 and 0.38 are connected and accepted. Stopping at
      // rung 0 there would return the user NOTHING while two good variants existed.
      // This mirrors an INFEASIBLE rung (handoff 131 rule (3)); like it, the walk
      // continues from the last CONNECTED design (the warm-seed guard above).
      if (!margin_ok) {
        result.stopped_on_margin = true;
        break;
      }
      continue;
    }
  }

  // Finalize the multigrid-usage report: MG "ran" for the run iff it carried the
  // majority of the optimize solves (see the tally note above). mg_levels is the
  // hierarchy depth observed on those MG solves (0 when MG did not carry the run).
  result.used_multigrid =
      total_solve_count > 0 && 2 * mg_solve_count >= total_solve_count;
  result.mg_levels = result.used_multigrid ? observed_mg_levels : 0;
  result.mg_hierarchy_ever_built = mg_hierarchy_ever_built;

  return result;
}

}  // namespace topopt
