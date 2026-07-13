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
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "topopt/fea.hpp"
#include "topopt/orient.hpp"

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
  if (!std::isfinite(options.infill_percent))
    throw std::invalid_argument(
        "minimize_plastic: infill_percent must be finite");
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

  // --- Fixed pipeline setup (shared across every rung) ---------------------
  // The design load, computed once and held across rungs (pipeline.hpp modeling
  // note). Mode (a): a caller-supplied external load case (the user's tagged Load
  // faces via traction_loads) takes precedence. Mode (b): self-weight on the
  // original solid grid (self_weight_loads validates density/gravity/direction
  // and normalizes the direction internally).
  const std::vector<NodalLoad> loads =
      options.external_loads.empty()
          ? self_weight_loads(grid, material.density_g_cm3, options.gravity,
                              options.gravity_direction)
          : options.external_loads;

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

  // Mask-aware optimize. Default: an all-Active mask — Fixture voxels are
  // implicitly FrozenSolid (M3.7), so the §7 V3 retention gate holds structurally.
  // M7.anchor-integrity (FIX 1): when the caller supplies a design mask it
  // REPLACES the all-Active default, letting the anchor/load faces freeze an
  // N-voxel structural pad (FrozenSolid) rather than only the 1-voxel BC skin
  // (diagnosis 064). Load/Fixture tags are still forced FrozenSolid on top of it
  // by the mask-aware simp path (effective_mask), so the mask only ADDS keep-in
  // pad voxels; it never un-freezes a tagged BC voxel.
  if (!options.design_mask.empty() &&
      options.design_mask.size() != grid.voxel_count())
    throw std::invalid_argument(
        "minimize_plastic: design_mask size != grid.voxel_count()");
  const DesignMask mask = options.design_mask.empty()
                              ? make_active_mask(grid)
                              : options.design_mask;

  // Part size for the settings size class: the largest grid bounding-box edge.
  const double part_dim_mm =
      std::max({static_cast<double>(grid.nx), static_cast<double>(grid.ny),
                static_cast<double>(grid.nz)}) *
      grid.spacing;

  // M7.infill-margin: a single rung-independent scalar in (0, 1] applied to the
  // worst-case margin at the acceptance gate below. 1.0 for solid/unset infill
  // (the default 100), making the whole ladder byte-identical to pre-M7.infill.
  const double infill_knockdown = infill_margin_knockdown(options.infill_percent);

  MinimizePlasticResult result;
  result.report.material = material_name;

  // Reserve result.evaluated to the ladder length (its known maximum: at most one
  // entry per rung, and the walk stops early on the first rejected/cancelled rung)
  // so it NEVER reallocates while the ladder runs. The progressive-results stream
  // (options.on_variant, below) hands its callback a reference to a variant that
  // lives inside result.evaluated; a mid-run reallocation would free the block
  // that reference points into (ASan heap-buffer-overflow, read-after-realloc —
  // the empty keyframeMeshes / displacementField symptoms). Reserving up front
  // removes the reallocation entirely; the per-push assert guards the invariant.
  result.evaluated.reserve(ladder.size());

  // --- Walk the ladder -----------------------------------------------------
  for (std::size_t rung = 0; rung < ladder.size(); ++rung) {
    const double vf = ladder[rung];
    SimpOptions opt = options.simp;
    opt.volume_fraction = vf;
    // M7.mma.4 — the switchover: the driver, not the shared SimpOptions default,
    // owns the updater. Defaults to MMA (options.updater) so real runs use MMA;
    // set options.updater = OC to fall back. Overrides any simp.updater.
    opt.updater = options.updater;

    // M7.rmin: derive the density-filter radius from a PHYSICAL length scale so
    // the filtered minimum member thickness is resolution independent. When
    // min_feature_mm is 0 the caller's voxel-unit simp.filter_radius is used
    // unchanged (back-compat: the Gate-V2 fixture and every direct simp caller
    // are untouched — they never set min_feature_mm and never route here).
    if (options.min_feature_mm > 0.0)
      opt.filter_radius =
          physical_filter_radius(options.min_feature_mm, grid.spacing);

    // M7.0a: the driver owns the optimizer's progress/cancel hooks (any set on
    // options.simp are overridden — pipeline.hpp). Per-rung progress forwards
    // (rung index, rung count, iteration); the cancel flag is polled by the
    // optimizer once per OC iteration.
    opt.cancel = options.cancel;
    opt.progress = nullptr;
    if (options.progress) {
      const std::size_t rung_count = ladder.size();
      opt.progress = [&options, rung, rung_count](int iteration, double,
                                                  double) {
        options.progress(rung, rung_count, iteration);
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
      opt.keyframe = [&variant, &grid](const std::vector<double>& d) {
        variant.keyframe_meshes.push_back(marching_cubes(grid, d, kIso));
      };
    }

    variant.optimization = simp_optimize(grid, params, bcs, loads, opt, mask);

    if (variant.optimization.cancelled) {
      // Cancelled mid-rung: report this rung as the rejected terminal rung and
      // stop. The per-rung analysis (stress solve, V3 suite, settings) is
      // skipped — the caller asked to abort, and the half-optimized field is
      // not shipped (pipeline.hpp `cancelled` contract).
      variant.accepted = false;
      result.evaluated.push_back(std::move(variant));
      result.cancelled = true;
      break;
    }

    const std::vector<double>& rho = variant.optimization.physical_density;

    // Final penalized solve on the converged density to recover the
    // displacement field (simp_optimize returns compliance/density, not u).
    const SimpCompliance sc = simp_compliance(grid, params, rho, bcs, loads,
                                              opt.cg_tolerance,
                                              opt.cg_max_iterations);

    // Peak stresses over the PRINTED material (physical density > iso), using
    // the material's solid modulus. Empty/void voxels stay at zero stress. The
    // per-voxel von Mises is also retained grid-indexed (M7.0b field (a)), and
    // the printed voxels are counted for the M7.0b mass (field (d)).
    std::vector<std::array<double, 6>> stress(grid.voxel_count(),
                                              std::array<double, 6>{});
    variant.von_mises_field.assign(grid.voxel_count(), 0.0);
    // M7.disp: mark the nodes attached to at least one printed voxel; the
    // displacement field is exposed only there (zero elsewhere), mirroring how
    // von_mises_field is zero off the printed set.
    const int node_count = fea_node_count(grid);
    std::vector<char> node_printed(static_cast<std::size_t>(node_count), 0);
    std::size_t printed_voxels = 0;
    double max_von_mises = 0.0;
    for (int k = 0; k < grid.nz; ++k)
      for (int j = 0; j < grid.ny; ++j)
        for (int i = 0; i < grid.nx; ++i) {
          if (!grid.solid(i, j, k)) continue;
          if (!(rho[grid.index(i, j, k)] > kIso)) continue;
          ++printed_voxels;
          const std::array<int, 8> en = fea_element_nodes(grid, i, j, k);
          for (int n : en) node_printed[static_cast<std::size_t>(n)] = 1;
          const std::array<double, 24> ue = element_dofs(grid, sc.solution, i, j, k);
          const Hex8Stress st = hex8_stress(params.youngs_modulus,
                                            params.poisson, grid.spacing, ue);
          stress[grid.index(i, j, k)] = st.sigma;
          variant.von_mises_field[grid.index(i, j, k)] = st.von_mises;
          if (st.von_mises > max_von_mises) max_von_mises = st.von_mises;
        }
    const double max_interlayer = max_interlayer_tension(grid, stress, build_dir);

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
                          grid.voxel_volume()) /
                         1000.0;

    // M7.0b field (c): support-volume proxy for the analysed build direction
    // over THIS variant's printed geometry. The M4.3 proxy is defined on grid
    // tags, so mark non-printed voxels Empty in a copy and count overhangs on
    // the printed shape (per-variant, unlike the fixed original solid grid).
    VoxelGrid printed_grid = grid;
    for (std::size_t idx = 0; idx < printed_grid.tags.size(); ++idx)
      if (!(rho[idx] > kIso)) printed_grid.tags[idx] = VoxelTag::Empty;
    variant.support_volume_voxels =
        support_overhang_voxels(printed_grid, build_dir);

    // Worst-case stress margin (M5.2 locked definition).
    const StressMargin margin = compute_stress_margin(
        material.yield_strength_mpa, material.z_knockdown, max_von_mises,
        max_interlayer);

    // §7 V3 property suite on this optimizer output (M3.5).
    variant.v3 = check_v3(grid, rho, kIso);

    // Assemble this rung's report line (M5.2 / M5.2b).
    VariantReport& vr = variant.report;
    vr.volume_fraction = variant.optimization.volume_fraction;
    vr.max_stress_mpa = max_von_mises;
    vr.max_interlayer_tension_mpa = max_interlayer;
    vr.margin = margin;
    vr.orientation = build_dir;
    vr.settings = recommend_settings(rules, material.family, margin.worst_case,
                                     part_dim_mm);
    vr.min_feature_violations = variant.v3.min_feature_violations;
    vr.min_feature_warning =
        min_feature_warning_text(rules, variant.v3.min_feature_violations);

    // M7.infill-margin: gate on the INFILL-ADJUSTED worst-case margin. The stored
    // report margin (vr.margin above) stays the SOLID margin — this knockdown is
    // applied ONLY to what the acceptance test compares, never to the FEA, the
    // stress field, or the displayed value. infill_knockdown == 1.0 for
    // solid/unset infill, so `margin.worst_case * 1.0 >= margin_stop` is
    // bit-for-bit the pre-M7.infill gate `margin.worst_case >= margin_stop`.
    variant.accepted =
        margin.worst_case * infill_knockdown >= options.margin_stop;
    result.evaluated.push_back(std::move(variant));
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
      // First too-weak rung: stop the ladder here (do not run lighter rungs).
      result.stopped_on_margin = true;
      break;
    }
  }

  return result;
}

}  // namespace topopt
