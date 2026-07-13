#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <limits>  // margin_floor_multiple's "disabled" sentinel (+infinity)
#include <optional>  // the optional design-volume box (M7.dom-core)
#include <stdexcept>  // the driver throws std::invalid_argument (see below)
#include <string>
#include <vector>

#include "topopt/fea.hpp"        // DirichletBC
#include "topopt/materials.hpp"  // Material
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/report.hpp"     // JobReport, VariantReport
#include "topopt/settings.hpp"   // SettingsRules
#include "topopt/simp.hpp"       // SimpOptions, SimpOptimizeResult
#include "topopt/voxel.hpp"      // VoxelGrid, V3Report

namespace topopt {

// M5.3 — the `minimize_plastic` end-to-end driver (ARCHITECTURE §1 "minimize
// plastic" directive, §5 self-weight mode). It ties the earlier milestones
// together: it loads the part with its own self-weight (M4.2), walks a
// DESCENDING volume-fraction ladder running the mask-aware SIMP optimizer
// (M3.4/M3.7) at each rung, evaluates each rung's worst-case stress margin
// (M5.2 compute_stress_margin, using the M2 von Mises field and the M4.4
// interlayer-tension field), runs the §7 V3 property suite on every optimizer
// output (M3.5), recommends slicer settings (M5.1) and the min-feature warning
// (M5.2b), and assembles the single JobReport (M5.2). It STOPS at the first
// rung whose worst-case margin drops below `margin_stop` (1.5 per ROADMAP M5.3):
// that rung is too weak, so the driver reports the accepted (margin >=
// margin_stop) rungs above it — the lighter, still-strong-enough variants.
//
// Modeling choices (documented so a reader knows the driver's boundaries):
//   * Self-weight is the DESIGN load, computed once with self_weight_loads on
//     the original solid grid (grid.solid voxels) and held fixed across rungs.
//     The optimal minimum-compliance topology is scale-invariant in the load
//     magnitude, so a fixed load vector gives comparable variants; using the
//     original-solid weight (rather than each rung's reduced weight) is the
//     simple, monotone first-order model for this milestone. A density-coupled
//     self-weight iteration is intentionally out of scope here.
//   * The PRINT / build orientation is an INPUT (options.gravity_direction is
//     the direction gravity pulls, i.e. the build-plate normal's opposite; the
//     reported build direction is its unit negation). The driver does not
//     re-run the M4.4 orientation search — the app / M4.4 scorer chooses the
//     orientation and feeds it here as the gravity direction, keeping the
//     self-weight direction and the reported orientation consistent. The
//     interlayer-tension term of the margin is evaluated for that build
//     direction (max_interlayer_tension, M4.4).
//   * Peak stresses are recovered from a final penalized solve on the converged
//     physical density and taken over the PRINTED material only (voxels whose
//     physical density > 0.5, the M3.5 iso), using the material's solid modulus
//     — the stress in the material that actually gets printed. Void/low-density
//     voxels are excluded (their penalized strains are not printed-part stress).
//   * Fixture voxels (M1.6 tags on the mounting face) are retained structurally:
//     the driver runs the mask-aware SIMP overload with an all-Active mask, so
//     Load/Fixture voxels are implicitly FrozenSolid (M3.7) and the §7 V3
//     retention gate holds by construction.
//
// STEP import, watertight checking and automatic fixture-face detection
// ("largest flat face oriented downward", §5) are the M6 CLI's concern; this
// driver takes an already-voxelized, already-fixtured grid plus the mounting
// Dirichlet BCs, exactly as the M3.x optimizer tests build their cases in code.

// Forward declaration: the on_variant progressive-results callback (below)
// references a fully-analysed variant, whose definition follows the options.
struct MinimizePlasticVariant;

// Inputs that shape one minimize_plastic run (beyond the part, material, BCs
// and rule table passed to minimize_plastic()).
struct MinimizePlasticOptions {
  // The volume-fraction ladder to walk, in the order given. Must be non-empty,
  // every entry in (0, 1], and STRICTLY DESCENDING (heaviest/strongest first).
  std::vector<double> volume_fraction_ladder{0.7, 0.5, 0.3};
  // Stop at the first rung whose worst-case stress margin is < margin_stop.
  // Must be finite and >= 0 (0 disables the margin stop: the whole ladder runs).
  double margin_stop = 1.5;

  // M7.anchor-integrity (FIX 2) — the ladder FLOOR, symmetric to margin_stop.
  // margin_stop is the CEILING on strippedness: keep stripping until the margin
  // would drop below it. This is the FLOOR: STOP stripping once an accepted rung
  // already carries a comfortable margin, so a lightly-loaded part is not walked
  // to the lightest rung (0.26 VF, ~74% removed) purely because it can survive
  // there. After a rung is accepted, if
  //   margin.worst_case * infill_knockdown >= margin_floor_multiple * margin_stop
  // (the SAME infill-adjusted scale as the acceptance gate), the driver stops:
  // that comfortable rung is the terminal accepted variant and no lighter rung
  // runs. A multiple of 3.0 means "stop once the worst-case margin is >= 3x the
  // strength floor" (~2x headroom above margin_stop).
  //
  // The DEFAULT is +infinity ("disabled"): +inf * margin_stop is +inf (or NaN
  // when margin_stop == 0), and `x >= +inf`/`x >= NaN` is false for every finite
  // margin, so the floor NEVER fires and the ladder walks exactly as before —
  // every existing caller/fixture/benchmark is byte-for-byte identical (the same
  // opt-in discipline as min_feature_mm == 0 and infill_percent == 100). Must be
  // >= 1.0 or +infinity; a multiple below 1 would floor below the acceptance
  // threshold, which is meaningless (the accept gate already ran at margin_stop).
  double margin_floor_multiple = std::numeric_limits<double>::infinity();

  // M7.anchor-integrity (FIX 1) — an optional caller design mask (Active /
  // FrozenSolid / FrozenVoid per voxel, grid-indexed, size grid.voxel_count()).
  // When NON-EMPTY it REPLACES the driver's default all-Active mask, so the
  // caller can freeze a structural PAD: e.g. an N-voxel-deep FrozenSolid shell
  // behind each anchor/load face (via mask_step_face) that pins that material to
  // density 1 and ties the boundary condition into the body, instead of leaving
  // only the 1-voxel BC skin frozen and letting the optimizer carve out
  // everything behind it (diagnosis 064). The mask composes with the M1.6 tags
  // exactly as the mask-aware simp path already does: Load/Fixture voxels are
  // still forced FrozenSolid on top of this mask (pipeline effective_mask). When
  // EMPTY (default) the driver uses make_active_mask(grid) — byte-identical to
  // every existing caller. Must be empty or size grid.voxel_count().
  DesignMask design_mask;

  // M7.dom-core — the "add material" feature: an optional user-defined DESIGN
  // VOLUME (an axis-aligned box in model space, mm), typically LARGER than the
  // imported part's bounding region. When set, the driver EXPANDS the run onto a
  // larger grid (expand_design_domain, voxel.hpp) so the optimizer can ADD
  // material BEYOND the import — grow ribs/gussets/buttresses into empty space
  // along the load path — instead of only removing material from the import. The
  // effective mask over the expanded grid is: imported-part voxels FrozenSolid
  // (the guaranteed-kept core — the original part is NEVER removed),
  // `keep_out_boxes` voxels FrozenVoid (the optimizer may not fill them), and the
  // remaining design-volume voxels Active (the new material the optimizer grows).
  //
  // The mounting `bcs` and any `external_loads` are node-indexed to the ORIGINAL
  // part grid; the driver remaps them onto the expanded grid automatically
  // (remap_node_to_domain). Self-weight (empty `external_loads`) is computed over
  // the expanded grid's solid voxels (the frozen part plus the Active design
  // envelope), held fixed across rungs like the original-solid self-weight model.
  //
  // Because it changes the domain, `design_box` is INCOMPATIBLE with a caller
  // `design_mask` (the driver builds the mask itself): supplying both throws. The
  // volume fraction of each ladder rung then applies to the ACTIVE design voxels
  // (the growable region), not the frozen part.
  //
  // UNSET (std::nullopt, the DEFAULT) disables the whole feature: the run uses
  // the imported `grid`/`bcs` verbatim with Active = the import, byte-for-byte
  // identical to the pre-M7.dom-core driver (the same opt-in discipline as
  // min_feature_mm == 0 / infill_percent == 100). Every existing caller, fixture
  // and benchmark is unaffected.
  std::optional<DesignBox> design_box;
  // Keep-out boxes (axis-aligned, model space) for the design volume: voxels
  // whose centre lies in any of these become FrozenVoid (the optimizer may not
  // grow material there). Only consulted when `design_box` is set; ignored
  // otherwise. A keep-out box never carves into the imported part (part voxels
  // are always FrozenSolid).
  std::vector<DesignBox> keep_out_boxes;

  // Self-weight body load. `gravity` is the acceleration magnitude (finite,
  // > 0); `gravity_direction` is the direction gravity pulls (need not be unit,
  // normalized internally; must be non-zero). Units are caller-chosen but must
  // be CONSISTENT with the material moduli: with E/yield in MPa and lengths in
  // mm, forces are in N, so density * gravity must be in N/mm^3. The margin is a
  // ratio (yield / stress), so the absolute gravity scale sets where the ladder
  // crosses margin_stop.
  double gravity = 9.81;
  Vec3 gravity_direction{0.0, 0.0, -1.0};
  // Shared SIMP loop options (filter radius, move limit, iteration cap, CG
  // tolerances). `volume_fraction` is overridden by each ladder rung and is
  // ignored here. `simp.progress` and `simp.cancel` are also overridden by
  // the driver — use the two fields below instead. `simp.updater` is overridden
  // by `updater` below (the production driver picks the updater, not the shared
  // SimpOptions default) — set `updater`, not `simp.updater`.
  SimpOptions simp;

  // M7.mma.4 — the design updater for the production ladder. Defaults to MMA
  // (the Method of Moving Asymptotes, Svanberg 1987): the switchover makes MMA,
  // not Optimality Criteria, the updater real minimize_plastic runs use. MMA
  // matches or beats OC's minimum-compliance optimum at the same volume fraction
  // (it is the convex-subproblem machinery the stress / multi-load constraints
  // build on) and runs the SAME mask-aware volume-constrained loop the driver
  // already used. Set to SimpUpdater::OC to fall back to the Optimality-Criteria
  // updater (retained, unchanged — the projected Gate-V2 path stays OC-only).
  // This value REPLACES `simp.updater` for every rung. It does NOT change the
  // FEA, the filter, the stress recovery, or the ladder logic — only the design
  // update rule inside simp_optimize, so the reported designs/compliances shift
  // to MMA's optimum while every driver contract (volume constraint, margins,
  // V3 suite, viz fields) is unchanged.
  SimpUpdater updater = SimpUpdater::MMA;

  // PHYSICAL minimum-feature length scale in millimetres (model units). When
  // > 0, the driver sets each rung's `simp.filter_radius` from the grid spacing
  // via physical_filter_radius(min_feature_mm, grid.spacing) — so the filtered
  // minimum member thickness is RESOLUTION INDEPENDENT (a fixed voxel radius is
  // not: it shrinks in mm as the grid is refined, letting thin members
  // proliferate at high resolution — diagnosis 060). The voxel radius is
  // floored at 1.5 (checkerboarding suppression, ARCHITECTURE §4). 0 (the
  // default) DISABLES the physical scaling and uses `simp.filter_radius` (voxel
  // units) verbatim, keeping every existing direct caller and fixture byte-
  // identical. Must be finite and >= 0.
  double min_feature_mm = 0.0;

  // M7.infill-margin — the sparse-infill fraction the real print will use, as a
  // PERCENT in [0, 100]. The FEA and the stress field are always computed on
  // SOLID material — infill NEVER enters the solver (ARCHITECTURE §2). This value
  // only KNOCKS DOWN the worst-case stress margin at the ladder ACCEPTANCE gate,
  // so the driver stops stripping material against a solid-part margin the sparse
  // print will not actually deliver. It does NOT change the FEA, the stress
  // field, the optimizer math, or the stored/displayed margin (vr.margin stays
  // the SOLID margin) — only what the acceptance test compares against (see
  // minimize_plastic.cpp infill_margin_knockdown()).
  //
  // 100 (the DEFAULT) means "solid / no knockdown": the knockdown factor is
  // exactly 1.0, so the acceptance gate — hence the whole ladder, and every
  // existing caller/fixture — is byte-for-byte identical to the pre-M7.infill
  // behavior (the same back-compat discipline as min_feature_mm == 0). Values in
  // [0, 100) scale the accepted margin down by a sub-linear factor in (0, 1], so
  // a lower infill accepts a HEAVIER (more material) terminal rung. Must be
  // finite.
  double infill_percent = 100.0;

  // Per-rung progress + cancellation (M7.0a). Both optional, absent by
  // default; when absent the run is unchanged.
  //
  // `progress` is forwarded from the optimizer once per completed OC
  // iteration of every rung as (rung index [0-based, ladder order], rung
  // count [= volume_fraction_ladder.size()], iteration [1-based within the
  // rung, monotone]). It must not throw; it runs on the optimizing thread.
  //
  // `cancel` is a caller-owned flag polled once per OC iteration (SimpOptions
  // contract). When observed true, the rung being optimized stops cleanly and
  // is reported as a REJECTED terminal rung (accepted == false, its
  // optimization.cancelled true); no later rung runs and the result's
  // `cancelled` is set. The pointee must outlive the minimize_plastic call.
  std::function<void(std::size_t rung_index, std::size_t rung_count,
                     int iteration)>
      progress;
  const std::atomic<bool>* cancel = nullptr;

  // Progressive results: invoked once per ACCEPTED rung, right after its full
  // analysis (V3 + report + M7.0b viz fields), BEFORE the next lighter rung is
  // optimized. Lets a caller stream each variant to the UI as it completes
  // (jump to the first optimized variant while the rest are still running)
  // instead of waiting for the whole ladder. Optional; absent by default. It
  // runs on the optimizing thread and must not throw.
  std::function<void(const MinimizePlasticVariant&)> on_variant;

  // Optimization-history playback (app): the target number of keyframe meshes to
  // capture per variant (0 = none, the default). The driver spreads this many
  // frames across each rung's SIMP iterations and extracts a marching-cubes mesh
  // per frame into MinimizePlasticVariant::keyframe_meshes. Adds a few cheap MC
  // extractions per variant (relative to the FEA solves); no effect on the
  // optimization itself.
  int keyframe_count = 0;

  // User-defined design load (ARCHITECTURE §1 mode (a): "user-defined loads").
  // When NON-EMPTY, these nodal loads REPLACE self-weight as the design load —
  // the driver optimizes and analyses the part under this load case instead of
  // its own weight, so the reported margins/stresses are for the user's forces.
  // Assemble it from the app's tagged Load faces via `traction_loads` (M7.6-core)
  // and pass the mounting faces as `bcs`. When EMPTY (default), the driver uses
  // self-weight exactly as before (mode (b), unchanged — all existing callers).
  // `gravity_direction` is still required (it defines the reported build
  // orientation and the interlayer-tension axis, M4.4); `gravity` is only
  // consulted in the self-weight (empty) case.
  std::vector<NodalLoad> external_loads;
};

// One ladder rung actually evaluated by the driver.
struct MinimizePlasticVariant {
  // The ladder rung this variant targeted (options.volume_fraction_ladder[i]).
  double requested_volume_fraction = 0.0;
  // The full SIMP result at that rung (physical_density, compliance, ...).
  SimpOptimizeResult optimization;
  // The §7 V3 property suite on this rung's optimizer output (M3.5). Computed
  // for every rung ("every optimized output, every run").
  V3Report v3;
  // This rung's report line (achieved volume fraction, peak stresses, margin,
  // build orientation, recommended settings, min-feature warning).
  VariantReport report;
  // True iff report.margin.worst_case >= options.margin_stop (strong enough).
  // The driver appends only accepted variants to the JobReport, and stops after
  // the first rejected (too-weak) rung.
  bool accepted = false;

  // --- M7.0b visualization data (for the app results screen) ---------------
  // Populated for every evaluated NON-cancelled rung, alongside `v3`/`report`.
  // A cancelled rung's analysis is skipped, so these stay default-constructed
  // there (see MinimizePlasticResult::cancelled).

  // (a) Per-voxel von Mises stress over the PRINTED material, grid-indexed
  // (size grid.voxel_count()), in MPa. Nonzero only on printed voxels (physical
  // density > 0.5, the M3.5 iso — the same threshold the variant mesh is
  // extracted at); zero on void and Empty voxels. This is the field the stress
  // solve already computes for the peak-stress reduction, retained per voxel.
  std::vector<double> von_mises_field;
  // Per-voxel Cauchy stress tensor over the PRINTED material, grid-indexed and
  // flattened (size 6*grid.voxel_count()): voxel idx occupies entries
  // [6*idx .. 6*idx+5] in Voigt order [xx, yy, zz, xy, yz, zx] with TRUE shear
  // stresses (tau, not doubled) — the SAME std::array<double,6> convention as
  // Hex8Stress::sigma. In MPa. This is the tensor the stress solve already
  // computes for the peak-stress reduction (the same tensor von_mises_field is
  // derived from), retained per voxel instead of discarded — EXPOSURE, not new
  // physics. Nonzero only on printed voxels (physical density > 0.5, the M3.5
  // iso); the six components are zero on void/Empty voxels, gated exactly like
  // von_mises_field. Empty for a cancelled rung (its analysis is skipped).
  std::vector<double> stress_tensor_field;
  // (c) Support-volume proxy (M4.3 support_overhang_voxels) for the analysed
  // build direction (report.orientation), evaluated over THIS variant's printed
  // geometry (voxels with density > 0.5): the count of printed voxels that would
  // need support material. Spacing-aware volume = value * grid.voxel_volume().
  int support_volume_voxels = 0;
  // (d) Printed mass in grams = material density (g/cm^3) * printed volume,
  // spacing-aware: (# printed voxels) * grid.voxel_volume() (mm^3) / 1000.
  double mass_grams = 0.0;

  // M7.disp — the per-node displacement field (the sibling of von_mises_field
  // that M7.viz.3's flex animation needs to move mesh vertices; the scalar
  // von Mises field cannot drive motion). DOF-ordered, size
  // 3*fea_node_count(grid): entries [3n, 3n+1, 3n+2] are (ux, uy, uz) of node n
  // in model units (mm). This is EXPOSURE, not new physics: it is the nodal
  // displacement of the SAME final penalized solve that produces von_mises_field
  // (SimpCompliance::solution), retained per node. Zero on nodes attached only
  // to non-printed voxels (physical density <= the M3.5 iso 0.5), mirroring how
  // von_mises_field is zero off the printed set, so the two fields agree on
  // which nodes/voxels are "printed". Empty for a cancelled rung (its analysis
  // is skipped, exactly like von_mises_field).
  std::vector<double> displacement_field;

  // (b) The extracted + cleaned variant isosurface, exposed for display. It is
  // ALREADY computed by check_v3 (stored in `v3.mesh`); this accessor exposes it
  // without recomputing marching cubes or copying the mesh. Empty for a
  // cancelled rung (its `v3` is default-constructed).
  const TriangleMesh& mesh() const { return v3.mesh; }

  // --- Optimization-history keyframes (app playback) -----------------------
  // Raw marching-cubes isosurfaces of the analysis density at snapshots through
  // this variant's SIMP iterations, in order from ~solid (first) to optimized
  // (last, ~= mesh()), so the app can play back the shape being carved out.
  // Populated only when MinimizePlasticOptions::keyframe_count > 0; empty
  // otherwise and for a cancelled rung.
  std::vector<TriangleMesh> keyframe_meshes;
};

// The result of a minimize_plastic run.
struct MinimizePlasticResult {
  // Every rung the driver actually ran, in ladder order: an accepted prefix
  // (each margin >= margin_stop) followed by AT MOST ONE rejected terminal rung
  // (margin < margin_stop, or cancelled — see `cancelled` below) at which the
  // driver stopped. No rung after the terminal one is evaluated.
  std::vector<MinimizePlasticVariant> evaluated;
  // True iff a rung fell below margin_stop and the driver stopped early (so the
  // last `evaluated` entry is the rejected terminal rung). False iff the whole
  // ladder was accepted (every rung margin >= margin_stop) or the run was
  // cancelled (a cancel is not a margin stop).
  bool stopped_on_margin = false;
  // M7.anchor-integrity (FIX 2): true iff the ladder stopped EARLY because an
  // accepted rung already met the comfort floor (margin >= margin_floor_multiple
  // * margin_stop) — so the last `evaluated` entry is an ACCEPTED terminal rung
  // and lighter rungs were deliberately not run. Distinct from stopped_on_margin
  // (which marks a REJECTED terminal rung). Always false when margin_floor_multiple
  // is disabled (+infinity, the default).
  bool stopped_on_floor = false;
  // True iff options.cancel was observed during a rung's optimization (M7.0a).
  // The cancelled rung is the last `evaluated` entry, rejected, with
  // optimization.cancelled true; its per-rung analysis (v3, report line, and
  // the visualization fields von_mises_field / displacement_field /
  // support_volume_voxels / mass_grams / mesh()) is NOT computed — a cancel
  // aborts the run, so the stress solve, V3 suite and settings for the
  // half-optimized rung are skipped and those fields stay default-constructed.
  // The accepted prefix and the assembled `report` are complete and valid as
  // usual.
  bool cancelled = false;
  // The assembled job report: the material name and one VariantReport per
  // ACCEPTED rung (report.variants[i] == evaluated[i].report for the accepted
  // prefix). validate_job_report_json(job_report_json(report)) always passes.
  JobReport report;
};

// Run the minimize_plastic pipeline over `grid` (an already-voxelized part with
// its mounting face tagged Fixture), using `material` (properties + name via
// `material_name`), the mounting Dirichlet `bcs`, and the parsed settings
// `rules`. Returns the evaluated ladder + the assembled JobReport (see
// MinimizePlasticResult).
//
// Throws std::invalid_argument if the ladder is empty, has an entry not in
// (0, 1], or is not strictly descending; if margin_stop is not finite/>= 0; or
// if gravity is not finite/> 0 or gravity_direction is (near) zero length.
// Propagates simp_optimize / recommend_settings / compute_stress_margin throws
// for a non-physical material, a bad BC index, or a CG non-convergence.
MinimizePlasticResult minimize_plastic(const VoxelGrid& grid,
                                       const Material& material,
                                       const std::string& material_name,
                                       const std::vector<DirichletBC>& bcs,
                                       const SettingsRules& rules,
                                       const MinimizePlasticOptions& options);

}  // namespace topopt
