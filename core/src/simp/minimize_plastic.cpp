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

#include "topopt/fea.hpp"
#include "topopt/orient.hpp"
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

// M7.infill-margin — map a sparse-infill fraction to the multiplicative KNOCKDOWN
// applied to the worst-case stress margin at the ladder ACCEPTANCE gate (only).
//
// WHY: the margin (yield / stress) is computed on SOLID material — infill never
// enters the FEA (ARCHITECTURE §2). A real FDM print at infill fraction f < 1 is
// weaker than that solid part, so accepting a rung on its solid margin lets the
// ladder strip material the sparse print cannot carry. This scalar scales the
// solid margin down to the infill-aware effective margin the acceptance test
// compares against; nothing else (FEA, stress field, optimizer, or the
// stored/displayed margin) sees it.
//
// CURVE (SEED — the maintainer tunes this; do NOT treat it as final): a
// Gibson-Ashby cellular-solid scaling, effective/solid strength ~= f^p with
// p = 1.5 and f = infill_percent / 100. The exponent p > 1 puts the curve BELOW
// the linear f for f in (0, 1) (sub-linear) and pins it to 1.0 at f = 1 (solid).
// It deliberately ignores the load the solid perimeters/walls of a real slice
// carry, so it UNDER-estimates strength — i.e. it is CONSERVATIVE (stops the
// ladder sooner, retaining more material). Reasonable later tuning: raise p
// toward 2 (the foam strength exponent), add a wall-count-derived floor, or fit
// a measured relation.
//
// RANGE / DEFAULT: returns a factor in (0, 1]. f >= 1 (the default 100, and any
// "solid/unset" caller) returns EXACTLY 1.0 with no arithmetic, so
// margin * knockdown == margin bit-for-bit and an unset run reproduces the
// current ladder exactly. f in (0, 1) maps to f^p; f <= 0 (a degenerate hollow
// request) is floored to a small positive knockdown so the factor never leaves
// (0, 1].
constexpr double kKnockdownExponent = 1.5;
constexpr double kKnockdownFloor = 1e-3;

double infill_margin_knockdown(double infill_percent) {
  const double f = infill_percent / 100.0;
  if (f >= 1.0) return 1.0;  // solid / unset: exact 1.0, byte-identical gate
  if (f <= 0.0) return kKnockdownFloor;
  return std::max(std::pow(f, kKnockdownExponent), kKnockdownFloor);
}

// Gather one element's 24 nodal displacements from the global solution, in the
// hex8_stiffness DOF order (node-major interleaved), matching the recovery in
// the V4/V5 gates.
std::array<double, 24> element_dofs(const VoxelGrid& grid, const FeaSolution& sol,
                                    int i, int j, int k) {
  const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
  std::array<double, 24> ue{};
  for (int a = 0; a < 8; ++a)
    for (int c = 0; c < 3; ++c)
      ue[static_cast<std::size_t>(3 * a + c)] = sol.at(en[a], c);
  return ue;
}

}  // namespace

VoxelGrid minimize_plastic_solved_grid(const VoxelGrid& grid,
                                       const MinimizePlasticOptions& options) {
  // Mirror EXACTLY the design-domain expansion minimize_plastic performs above:
  // same expand_design_domain overload, same keep-outs, same freeze flag, same
  // kDesignBoxCoarsenAlign. Expansion is pure geometry (no voxelization, no
  // solve), so this returns the identical grid the driver solves on without
  // running the ladder. With no design box the solved grid IS the caller's grid.
  if (!options.design_box.has_value()) return grid;
  return expand_design_domain(grid, *options.design_box, options.keep_out_boxes,
                              options.freeze_imported_part,
                              kDesignBoxCoarsenAlign)
      .grid;
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
  DesignDomain domain;                    // populated only when a design box is set
  std::vector<DirichletBC> remapped_bcs;  // expanded-grid BCs (design-box path)
  std::vector<NodalLoad> remapped_loads;  // expanded-grid external loads
  const bool expanded = options.design_box.has_value();
  if (expanded) {
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
      if (options.design_mask.size() != grid.voxel_count())
        throw std::invalid_argument(
            "minimize_plastic: design_mask size != part grid.voxel_count()");
    }
    // Align the expanded grid's element dims to a power of two (8 => >= 3
    // multigrid levels) by appending Empty high-side voxels. The design-box
    // system is ~1e-9-contrast and ~2M-DOF; without an even-dimensioned grid the
    // geometric-multigrid hierarchy cannot coarsen (an odd axis makes it bail to
    // an effectively-hung Jacobi-CG). The padding adds no physics (Empty voxels,
    // void-gated) and leaves the BC/load remap offset unchanged. See voxel.hpp.
    // kDesignBoxCoarsenAlign is the public constant (pipeline.hpp) so any caller
    // re-deriving this grid — via minimize_plastic_solved_grid — uses the same
    // alignment and cannot drift from what is solved here.
    domain = expand_design_domain(grid, *options.design_box,
                                  options.keep_out_boxes,
                                  options.freeze_imported_part,
                                  kDesignBoxCoarsenAlign);
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
    if (!options.design_mask.empty()) {
      for (int pk = 0; pk < grid.nz; ++pk)
        for (int pj = 0; pj < grid.ny; ++pj)
          for (int pi = 0; pi < grid.nx; ++pi) {
            if (options.design_mask[grid.index(pi, pj, pk)] !=
                MaskValue::FrozenSolid)
              continue;
            domain.mask[domain.grid.index(pi + domain.offset_i,
                                          pj + domain.offset_j,
                                          pk + domain.offset_k)] =
                MaskValue::FrozenSolid;
          }
    }
    remapped_bcs.reserve(bcs.size());
    for (const DirichletBC& bc : bcs)
      remapped_bcs.push_back({remap_node_to_domain(grid, domain, bc.node),
                              bc.component, bc.value});
    if (!options.external_loads.empty()) {
      remapped_loads.reserve(options.external_loads.size());
      for (const NodalLoad& nl : options.external_loads)
        remapped_loads.push_back({remap_node_to_domain(grid, domain, nl.node),
                                  nl.component, nl.value});
    }
  }
  // The effective grid + BCs the whole pipeline runs on (the expanded pair with a
  // design box, else the caller's inputs verbatim).
  const VoxelGrid& G = expanded ? domain.grid : grid;
  const std::vector<DirichletBC>& B = expanded ? remapped_bcs : bcs;

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

  // --- Fixed pipeline setup (shared across every rung) ---------------------
  // The design load, computed once and held across rungs (pipeline.hpp modeling
  // note). Mode (a): a caller-supplied external load case (the user's tagged Load
  // faces via traction_loads, remapped onto the expanded grid when a design box
  // is set) takes precedence. Mode (b): self-weight on the effective solid grid
  // (self_weight_loads validates density/gravity/direction and normalizes the
  // direction internally; with a design box the weight covers the frozen part
  // plus the Active design envelope, held fixed across rungs).
  const std::vector<NodalLoad> loads =
      !options.external_loads.empty()
          ? (expanded ? remapped_loads : options.external_loads)
          : self_weight_loads(G, material.density_g_cm3, options.gravity,
                              options.gravity_direction);

  // The reported / analysed build direction is the build-plate normal: gravity
  // pulls toward the plate, so the build direction is the unit negation.
  const Vec3 build_dir = normalized(Vec3{-options.gravity_direction.x,
                                         -options.gravity_direction.y,
                                         -options.gravity_direction.z});

  // Material -> SIMP params (penalty p = 3 per ARCHITECTURE §4).
  SimpParams params;
  params.youngs_modulus = material.youngs_modulus_mpa;
  params.poisson = material.poisson;
  params.penalty = 3.0;

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
  if (!expanded && !options.design_mask.empty() &&
      options.design_mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "minimize_plastic: design_mask size != grid.voxel_count()");
  DesignMask mask =
      expanded ? domain.mask
               : (options.design_mask.empty() ? make_active_mask(G)
                                              : options.design_mask);

  // Handoff 100 — OR the "Keep clear" clearance overlay into the effective mask.
  // `clearance_void` is SOLVED-grid-indexed (G): each FrozenVoid entry forbids
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

  // M7.infill-margin: a single rung-independent scalar in (0, 1] applied to the
  // worst-case margin at the acceptance gate below. 1.0 for solid/unset infill
  // (the default 100), making the whole ladder byte-identical to pre-M7.infill.
  const double infill_knockdown = infill_margin_knockdown(options.infill_percent);

  MinimizePlasticResult result;
  result.report.material = material_name;
  // Record the grid every evaluated variant's fields are indexed to — the
  // expanded domain grid under a design box, else the caller's grid. This IS the
  // grid solved on (G), not a re-derivation, so a caller reporting grid metadata
  // from it samples the von-Mises/displacement fields at the correct voxels. It
  // equals minimize_plastic_solved_grid(grid, options) voxel-for-voxel.
  result.solved_grid = G;

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
    const VoxelGrid Gc = coarsen_grid(G);
    const std::vector<DirichletBC> Bc = coarsen_bcs(G, Gc, B);
    const std::vector<NodalLoad> loads_c =
        !options.external_loads.empty()
            ? restrict_loads(G, Gc, loads)
            : self_weight_loads(Gc, material.density_g_cm3, options.gravity,
                                options.gravity_direction);
    const DesignMask mask_c = coarsen_mask(G, Gc, mask);

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
        !variant.optimization.infeasible) {
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

    // Final penalized solve on the converged density to recover the
    // displacement field (simp_optimize returns compliance/density, not u).
    // Solver selection (handoff 073) flows from options.simp.solver via `opt`;
    // default JacobiCG keeps this byte-identical. The final recovery solve uses
    // the same solver the ladder ran with.
    const SimpCompliance sc = simp_compliance(G, params, rho, B, loads,
                                              opt.cg_tolerance,
                                              opt.cg_max_iterations,
                                              /*initial_guess=*/nullptr,
                                              /*solver=*/nullptr, opt.solver);

    // Peak stresses over the PRINTED material (physical density > iso), using
    // the material's solid modulus. Empty/void voxels stay at zero stress. The
    // per-voxel von Mises is also retained grid-indexed (M7.0b field (a)), and
    // the printed voxels are counted for the M7.0b mass (field (d)).
    std::vector<std::array<double, 6>> stress(G.voxel_count(),
                                              std::array<double, 6>{});
    variant.von_mises_field.assign(G.voxel_count(), 0.0);
    // Per-voxel Cauchy stress tensor, flattened grid-indexed (size
    // 6*voxel_count): the same `stress` array below, retained instead of
    // discarded. Voigt [xx,yy,zz,xy,yz,zx], TRUE shear, MPa; zero off the
    // printed set, exactly like von_mises_field.
    variant.stress_tensor_field.assign(6 * G.voxel_count(), 0.0);
    // M7.disp: mark the nodes attached to at least one printed voxel; the
    // displacement field is exposed only there (zero elsewhere), mirroring how
    // von_mises_field is zero off the printed set.
    const int node_count = fea_node_count(G);
    std::vector<char> node_printed(static_cast<std::size_t>(node_count), 0);
    std::size_t printed_voxels = 0;
    double max_von_mises = 0.0;
    for (int k = 0; k < G.nz; ++k)
      for (int j = 0; j < G.ny; ++j)
        for (int i = 0; i < G.nx; ++i) {
          if (!G.solid(i, j, k)) continue;
          if (!(rho[G.index(i, j, k)] > kIso)) continue;
          ++printed_voxels;
          const std::array<int, 8> en = fea_element_nodes(G, i, j, k);
          for (int n : en) node_printed[static_cast<std::size_t>(n)] = 1;
          const std::array<double, 24> ue = element_dofs(G, sc.solution, i, j, k);
          const Hex8Stress st = hex8_stress(params.youngs_modulus,
                                            params.poisson, G.spacing, ue);
          stress[G.index(i, j, k)] = st.sigma;
          variant.von_mises_field[G.index(i, j, k)] = st.von_mises;
          const std::size_t base = 6 * G.index(i, j, k);
          for (int c = 0; c < 6; ++c)
            variant.stress_tensor_field[base + static_cast<std::size_t>(c)] =
                st.sigma[static_cast<std::size_t>(c)];
          if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
        }
    const double max_interlayer = max_interlayer_tension(G, stress, build_dir);

    // M7.disp field: the per-node displacement of the SAME penalized solve
    // (sc.solution) — no new solve. DOF-ordered (size 3*node_count); exposed on
    // printed nodes exactly as solved, zeroed on nodes attached only to
    // non-printed voxels (mirrors von_mises_field). Model units (mm).
    variant.displacement_field.assign(static_cast<std::size_t>(3 * node_count),
                                      0.0);
    for (int n = 0; n < node_count; ++n) {
      if (!node_printed[static_cast<std::size_t>(n)]) continue;
      for (int c = 0; c < 3; ++c)
        variant.displacement_field[static_cast<std::size_t>(3 * n + c)] =
            sc.solution.at(n, c);
    }

    // M7.0b field (d): printed mass = material density (g/cm^3) * printed volume.
    // Volumes are mm^3 (mm-MPa unit system); 1 cm^3 = 1000 mm^3, so divide by
    // 1000 to land in grams. Spacing-aware via grid.voxel_volume().
    variant.mass_grams = material.density_g_cm3 *
                         (static_cast<double>(printed_voxels) *
                          G.voxel_volume()) /
                         1000.0;

    // M7.0b field (c): support-volume proxy for the analysed build direction
    // over THIS variant's printed geometry. The M4.3 proxy is defined on grid
    // tags, so mark non-printed voxels Empty in a copy and count overhangs on
    // the printed shape (per-variant, unlike the fixed original solid grid).
    VoxelGrid printed_grid = G;
    for (std::size_t idx = 0; idx < printed_grid.tags.size(); ++idx)
      if (!(rho[idx] > kIso)) printed_grid.tags[idx] = VoxelTag::Empty;
    variant.support_volume_voxels =
        support_overhang_voxels(printed_grid, build_dir);

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

    // Worst-case stress margin (M5.2 locked definition).
    const StressMargin margin = compute_stress_margin(
        material.yield_strength_mpa, material.z_knockdown, max_von_mises,
        max_interlayer);

    // §7 V3 property suite on this optimizer output (M3.5).
    variant.v3 = check_v3(G, rho, kIso);

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
    vr.orientation = build_dir;
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

    // M7.infill-margin: gate on the INFILL-ADJUSTED worst-case margin. The stored
    // report margin (vr.margin above) stays the SOLID margin — this knockdown is
    // applied ONLY to what the acceptance test compares, never to the FEA, the
    // stress field, or the displayed value. infill_knockdown == 1.0 for
    // solid/unset infill, so `margin.worst_case * 1.0 >= margin_stop` is
    // bit-for-bit the pre-M7.infill gate `margin.worst_case >= margin_stop`.
    const double margin_effective = margin.worst_case * infill_knockdown;
    const bool margin_ok = margin_effective >= options.margin_stop;
    // THE BELT ACTS HERE: a disconnected rung is REJECTED however good its margin
    // looks (the verdict was measured above, on the converged density). The margin
    // test is UNCHANGED and still evaluated in its own right — it is what decides
    // whether the LADDER stops, below.
    variant.accepted = load_path_ok && margin_ok;
    // The acceptance verdict and the numbers behind it, carried on the report line
    // so a REJECTED rung reports its own margin-vs-required (not a silent omission).
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
    result.evaluated.push_back(std::move(variant));
    result.rung_infeasible.push_back(0);  // handoff 131 (aligned with `evaluated`)
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
      if (options.on_variant) options.on_variant(result.evaluated.back());

      // M7.anchor-integrity (FIX 2): the ladder FLOOR. Once an accepted rung
      // already clears the comfort floor, stop — do NOT keep stripping toward the
      // lightest rung just because the part could survive there. The comparison
      // uses the SAME infill-adjusted margin the acceptance gate above uses, so
      // the floor and the ceiling are measured on one scale. Disabled by default
      // (margin_floor_multiple == +infinity): the RHS is +infinity (or NaN when
      // margin_stop == 0), so the test is false for every finite margin and the
      // walk is byte-identical to the pre-M7.anchor-integrity ladder.
      if (margin.worst_case * infill_knockdown >=
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
