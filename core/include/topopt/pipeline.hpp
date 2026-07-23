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

// The design-box coarsening-alignment FLOOR minimize_plastic passes to
// expand_design_domain: each expanded element dim is rounded UP to a common
// power-of-two multiple (>= this floor) with inert Empty high-side padding so the
// geometric-multigrid hierarchy can coarsen under its DOF cap instead of bailing
// to an effectively-hung Jacobi-CG on the ~1e-9-contrast design-box system. The
// ACTUAL alignment grows above this floor for large grids (res ~128 with a box),
// where a fixed multiple of 8 leaves the coarsest MG level over the cap — the
// rule and the computed alignment live in topopt/coarsen.hpp (voxel.hpp).
// Exposed as a SINGLE public constant so no caller re-deriving the solved grid
// has to repeat the literal 8 — the grid the driver solves on and any
// externally-derived grid stay in lockstep by construction (they run the same
// adaptive computation from the same inputs). See minimize_plastic_solved_grid.
inline constexpr int kDesignBoxCoarsenAlign = 8;

// Handoff 114 — one density-snapshot event the driver feeds to
// MinimizePlasticOptions::on_density_snapshot. It carries the raw physical
// density field plus the coordinates a snapshot sidecar records; the consumer
// owns the cadence/cap/encoding policy. `density` and `grid` are borrowed
// (non-owning) and valid only for the duration of the callback.
struct DensitySnapshotEvent {
  std::size_t rung_index = 0;   // 0-based ladder index
  std::size_t rung_count = 0;   // == volume_fraction_ladder.size()
  int iteration = 0;            // 1-based iteration within the rung; for a
                                // boundary event, the rung's final iteration
  bool boundary = false;        // true = the rung's CONVERGED density (a rung
                                // boundary; the last boundary is the terminal)
  const std::vector<double>* density = nullptr;  // pinned physical density,
                                                 // grid-indexed (size voxel_count)
  const VoxelGrid* grid = nullptr;               // the solved grid (dims/spacing/origin)
};

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

  // M7.dom-core / handoff 080 — what the imported part becomes on the design-box
  // path. Only consulted when `design_box` is set.
  //   * false (DEFAULT — "whole-domain optimize"): the imported part is an Active
  //     design region the optimizer may REMOVE as well as grow beyond, so a
  //     minimize-plastic run with a box genuinely reduces plastic MEASURED AGAINST
  //     THE PART. On this path the ladder's volume fraction and the reported
  //     achieved fraction are normalised to the PART (part.solid_count()), not the
  //     Active add-region, so `savings = 1 - achieved` and the implied baseline
  //     (mass / achieved) are the honest part reference. The Load/Fixture BC skin
  //     is still pinned FrozenSolid (expand_design_domain preserves those tags).
  //   * true ("add material" feature): the imported part is FrozenSolid (never
  //     removed); the optimizer only grows new material into the Active box volume,
  //     and the fraction applies to that add-region. This is the M7.dom-core
  //     contract exercised by test_design_domain.
  // Ignored when `design_box` is unset (the no-box path is byte-identical either
  // way). See handoff 080-designbox-nearsolid-diagnosis.md.
  bool freeze_imported_part = false;

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

  // Handoff 123 — CONDITIONAL MMA Heaviside projection ("polish only when gray").
  // The design-region grayness threshold (Mnd; see design_discreteness_mnd) above
  // which a converged GRAYSCALE MMA rung is continued into β-projection to crisp
  // it. Supersedes always-on production projection (PR 146): projection's ~4×
  // iteration cost is paid ONLY on rungs that actually go gray, never on parts
  // that are already crisp.
  //
  // 0 (the DEFAULT) DISABLES the gate: the driver never measures grayness and
  // never projects, so every existing caller / fixture / Gate-V2 is BYTE-FOR-BYTE
  // identical (the same opt-in discipline as min_feature_mm == 0). > 0 arms it,
  // PER RUNG: after a rung's grayscale MMA (simp.mma_projection == false)
  // converges, the driver measures the design-region Mnd of the converged field;
  // if it EXCEEDS this threshold the SAME rung is continued into mma_projection
  // β-continuation seeded from the converged gray field (handoff 116's machinery,
  // β restarting at β0 and staging to the capped-β plateau), otherwise the rung
  // is already crisp and kept as-is (cost ≈ one field scan). Per-rung gating is
  // deliberate: a ladder can have crisp heavy rungs (gate silent) and gray light
  // ones (gate fires). configure_production_options sets the production value.
  //
  // INERT (no-op, byte-identical to gray) when it cannot apply: updater == OC
  // (projection there is the OC `projection` schedule), or simp.mma_projection is
  // already true (every rung then projects unconditionally — the always-on path).
  // Must be finite and >= 0.
  double conditional_mma_projection_mnd_threshold = 0.0;

  // Handoff 133 — KRYLOV RECYCLE-SPACE LIFETIME. The recycle basis
  // (fea_set_krylov_recycling) is sticky across solves and must be reset at some
  // boundary; this chooses which. The driver ALWAYS resets it once at run start
  // (the same discipline as the 127 multigrid stagnation latch — a sticky
  // thread-local must not leak between runs). This flag additionally resets it at
  // every LADDER RUNG boundary.
  //
  // false (the DEFAULT) = carry the basis across rung boundaries. That is the
  // MEASURED rule, not the cautious guess: handoff 133 ran both lifetimes on both
  // regime fixtures and carrying was mildly BETTER in each (+1.5 points of CG cut
  // on the void-heavy ladder, 3.4% fewer iterations on the multigrid one) and
  // worse in neither, with byte-identical accepted designs either way. The volume
  // target steps at a rung boundary but the grid, BCs and load do not, so the
  // subspace stays meaningful. true restores the conservative reset-per-rung.
  //
  // NOT COVERED by either setting: the gray -> beta-projection boundary INSIDE a
  // rung (123). The two phases are two simp_optimize calls and neither value
  // resets between them, so the basis is always carried across that boundary. On
  // the multigrid fixture the regression concentrated there (2.2x in the projected
  // phase vs 1.12x in the grayscale one) — see handoff 133 §10; whether that is
  // staleness or the V-cycle mis-scaling is unresolved, and the discriminating
  // experiment needs a per-phase reset hook that does not exist yet.
  //
  // COMPLETELY INERT when recycling is off (the library default): the reset calls
  // are no-ops on a non-existent basis, so every existing caller and fixture is
  // byte-for-byte identical for either value.
  bool krylov_recycle_reset_per_rung = false;

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

  // Handoff 100 — "Keep clear" clearance keep-out overlay. A SOLVED-grid-indexed
  // mask (size == the grid minimize_plastic solves on, i.e.
  // minimize_plastic_solved_grid(grid, *this)) carrying MaskValue::FrozenVoid on
  // the voxels a declared clearance region forbids growth into. The shared
  // builder (build_production_loadcase) rasterizes it from the STEP bore/plane
  // geometry via mask_clearance_region; the rasterizer has already excluded part
  // material. After the effective mask is built, each FrozenVoid entry is OR'd in
  // wherever the effective mask is not already FrozenSolid — so FrozenSolid
  // (imported part / anchor pad) WINS and clearance only removes NEW growth,
  // never declared/preserved material. A cleared voxel becomes FrozenVoid exactly
  // like a keep_out_boxes voxel: it carries no FEA element and no design variable.
  //
  // Must be empty or size == the solved grid's voxel_count(). EMPTY (the DEFAULT)
  // means "no clearance declared": the OR-step is skipped and the run is
  // BYTE-FOR-BYTE identical to the pre-clearance driver (the same opt-in
  // discipline as design_mask / design_box). This is THE ONE RULE — no clearance
  // → nothing changes.
  DesignMask clearance_void;

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

  // Handoff 114 — per-iteration OBSERVABILITY forwarder (additive to `progress`).
  // Forwarded once per completed optimizer iteration of every rung with the rung
  // index [0-based], the rung count, and the full SimpIterationObservation
  // (compliance, achieved vf, CG iters, plateau verdict) for that step. It is the
  // richer sibling of `progress`, driving the CLI per-iteration CSV. Read-only —
  // designs are byte-identical whether it is set or not. The coarse pre-solve
  // (warm_start_coarse) is NOT forwarded (it is not a reported rung), exactly like
  // `progress`. Absent by default; when absent the run is unchanged. Runs on the
  // optimizing thread; must not throw.
  std::function<void(std::size_t rung_index, std::size_t rung_count,
                     const SimpIterationObservation& obs)>
      on_iteration;

  // Handoff 114 — density SNAPSHOT forwarder (opt-in observability). When set, it
  // is invoked (a) once per optimizer iteration of every rung with that step's
  // pinned physical density (`boundary` false), and (b) once per non-cancelled
  // evaluated rung with the rung's CONVERGED density (`boundary` true — a rung
  // boundary; the last such is the terminal design). The consumer (the CLI
  // snapshot writer) applies its own every-N cadence, per-job cap and float16
  // encoding — the driver only feeds the raw field + coordinates. Read-only; the
  // coarse pre-solve is NOT forwarded. Absent by default (no per-iteration density
  // copy is taken — SimpOptions::density_observer stays null). Must not throw.
  std::function<void(const DensitySnapshotEvent&)> on_density_snapshot;

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

  // Diagnosis 095 (3D-block fragmentation) — the SILENT-SELF-WEIGHT-FALL-THROUGH
  // guard. `external_loads` empty means "self-weight" (mode (b) above), which is
  // correct for a genuine self-weight run but WRONG for a load-case run whose
  // force never reached the solver: the app builds `external_loads` from the
  // user's tagged Load faces, and if every load group is zero-force (or the
  // forces were lost upstream) the vector comes back EMPTY and the driver would
  // silently optimize under self-weight instead. With no external load the tab is
  // never tagged Load / frozen, so self-weight strips it (its far-cantilever
  // weight contributes ~nothing to a ~1e-7 noise-dominated compliance) and the
  // design fragments into disconnected islands — the reported "load tab removed /
  // floating fragments" result, shipped as if it succeeded.
  //
  // When TRUE, the driver REFUSES to fall through to self-weight: an empty
  // `external_loads` throws std::invalid_argument instead of silently running a
  // self-weight optimize. The app's LOAD-CASE entry point sets this whenever the
  // user defined load groups, so a lost/zero force surfaces as a clear error
  // ("your load did not reach the solver") rather than a plausible-looking but
  // garbage design. DEFAULT false: a genuine self-weight run (and every existing
  // caller/fixture/Gate-V2 path) leaves it false and is byte-for-byte unchanged.
  bool require_external_loads = false;

  // Handoff 110 — WARM START (both opt-in, DEFAULT OFF; with both false the driver
  // is byte-for-byte identical to the pre-110 ladder — THE ONE RULE). Both cut
  // ITERATIONS, never PEAK MEMORY: peak memory is the iteration-0 build transient
  // and it recurs on every rung regardless (handoff 091), so warm starting does
  // NOT shrink the transient and does NOT enable Fine-on-iPad — it only removes
  // iterations from the middle of each solve.
  //
  // A warm start changes ONLY the INITIALIZATION, so the optimizer may converge to
  // a DIFFERENT local optimum than a cold start — that is expected, not a bug. The
  // accept gate (margin * knockdown >= margin_stop, plus the floor) certifies every
  // variant EXACTLY as before: safety is initialization-independent and NO gate
  // logic changes. Determinism is preserved (same inputs -> same outputs).

  // (A) Rung-to-rung inheritance. The ladder walks HEAVIEST -> lightest; with this
  // on, rung k+1 starts from rung k's CONVERGED density (rescaled to rung k+1's
  // lighter target, clamped, one filter pass — see SimpOptions::initial_design)
  // instead of uniform grey, so each lighter rung CARVES FURTHER from a good design
  // rather than rediscovering it from scratch. Rung 0 still starts uniform (it has
  // no predecessor) unless warm_start_coarse also seeds it. FALSE (default) => every
  // rung starts uniform (byte-identical).
  bool warm_start_inherit = false;

  // (B) Coarse-to-fine cascade. BEFORE the ladder, solve the SAME effective problem
  // (grid / BCs / loads / mask the driver actually solves on, after any design-box
  // expansion) at HALF RESOLUTION — an ordinary simp_optimize at res/2, with its
  // OWN guard rails — at the heaviest rung's volume fraction, then trilinear-
  // UPSAMPLE the converged coarse density to the fine grid (warm_start.hpp) and seed
  // the FIRST fine rung from it. The coarse grid uses the same align-2 halving as
  // the multigrid hierarchy expects; its ~1/8-DOF solve is cheap but NOT free, and
  // its iteration count is reported in MinimizePlasticResult::warm_start_coarse_
  // iterations so every speedup claim can include it. FALSE (default) => no coarse
  // pre-solve (byte-identical). COMPOSES with warm_start_inherit: the coarse solve
  // seeds rung 0, then inheritance carries the warm start down the rest of the ladder.
  bool warm_start_coarse = false;
};

// Handoff 131 — the VariantReport::rejection_reason a rung ended on the
// rung-infeasibility signature carries. One definition, shared by the driver, the
// CLI's console line and the tests, so the string in report.json can never drift
// from the string anything checks for.
inline constexpr const char* kRungInfeasibleReason =
    "rung infeasible (load path lost)";

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

  // Handoff 131 — true iff this rung was ENDED on the rung-infeasibility signature
  // (simp.hpp rung_infeasible): the optimizer severed the load path, so the design
  // is a corpse. Such a rung is NEVER accepted, its per-rung ANALYSIS IS SKIPPED
  // (exactly like a cancelled rung: no stress solve, no V3 suite, no settings, so
  // `v3`, the visualization fields and `mesh()` stay default-constructed), and its
  // density NEVER seeds a later rung's warm start. Its `report` line carries
  // rejection_reason "rung infeasible (load path lost)" with zero placeholders for
  // every unmeasured field, and is pushed to report.rejected. Unlike a too-weak
  // rung it does NOT stop the ladder — infeasibility is a failure of THIS carve,
  // not a strength verdict about lighter targets, and the next rung gets a fresh
  // attempt from the last FEASIBLE field.
  bool infeasible = false;

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
  // Every rung the driver actually ran, in ladder order: accepted rungs (each
  // margin >= margin_stop) — optionally interleaved with INFEASIBLE rungs, which
  // do not stop the walk (handoff 131) — followed by AT MOST ONE rejected terminal
  // rung (margin < margin_stop, or cancelled — see `cancelled` below) at which the
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
  // The grid the run ACTUALLY solved on, and to which every evaluated variant's
  // mesh, von-Mises field, displacement field and playback are indexed. With a
  // design box this is the EXPANDED domain grid (expand_design_domain, aligned to
  // kDesignBoxCoarsenAlign, freeze_imported_part honoured); with no box it is the
  // caller's `grid` verbatim. Returned so a caller sampling those grid-indexed
  // fields uses the same dims/origin/spacing the solver used — it cannot drift
  // from whatever expand_design_domain arguments the driver grows later. Callers
  // that need this grid BEFORE the solve returns (e.g. to seed a progressive
  // stream) get the identical grid from minimize_plastic_solved_grid().
  VoxelGrid solved_grid;

  // Handoff 110 (Part B) — iterations spent in the coarse-to-fine PRE-SOLVE (the
  // res/2 warm-start solve). 0 when warm_start_coarse is off (its default). These
  // iterations run at ~1/8 the fine DOF count but are NOT free — count them toward
  // the run's total cost in any speedup claim. The per-rung fine iterations are in
  // evaluated[i].optimization.iterations as usual.
  int warm_start_coarse_iterations = 0;

  // Whether the run's linear solves ACTUALLY used the geometric-multigrid
  // accelerator, and its hierarchy depth — captured from the per-rung recovery
  // solve (representative: coarsenability is grid-determined, so every solve of a
  // run agrees). `used_multigrid` is false when solver == JacobiCG (MG not
  // requested) AND when a multigrid solver silently fell back to Jacobi-CG because
  // the grid could not be coarsened under the DOF cap (the res-128 design-box bug;
  // topopt/coarsen.hpp). A caller compares this against the REQUESTED solver kind
  // to detect a silent fallback and report it (run_info.json cg_multigrid + the
  // CLI warning). `mg_levels` is 0 when MG did not run. Default false/0 when no
  // rung completed a recovery solve (e.g. cancelled at rung 0).
  bool used_multigrid = false;
  int mg_levels = 0;
  // Handoff 128 — true iff ANY optimize solve of the run built a multigrid
  // hierarchy (whether or not the V-cycle then converged). With `used_multigrid`
  // this classifies a multigrid fallback: used_multigrid=false && this=true is
  // STAGNATION (built but never carried; the 127 latch may have engaged),
  // this=false is BUILD-REJECTION (never coarsenable). Consumed by run_job to set
  // run_info.json mg_mode. False when solver==JacobiCG (MG never attempted).
  bool mg_hierarchy_ever_built = false;

  // Handoff 123 — CONDITIONAL MMA-projection outcome, one entry per EVALUATED rung
  // (same order and length as `evaluated`). Empty when the gate is disarmed
  // (conditional_mma_projection_mnd_threshold == 0, updater == OC, or an always-on
  // simp.mma_projection) — nothing was measured. When armed:
  //   * rung_grayscale_mnd[i] — the design-region Mnd measured on rung i's
  //     converged GRAYSCALE field (the gate input). NaN for a rung cancelled
  //     before it converged (grayness was never measured).
  //   * conditional_projection_fired[i] — 1 iff that Mnd exceeded the threshold and
  //     the rung was continued into β-projection (its iterations then include both
  //     the grayscale and the projection phase), else 0 (the rung was already crisp
  //     and kept as grayscale).
  // Echoed per-rung into run_info.json so a completed run states which rungs paid
  // for polish and which were already crisp — the honest cost readout.
  std::vector<double> rung_grayscale_mnd;
  std::vector<char> conditional_projection_fired;

  // Handoff 131 — RUNG-INFEASIBILITY outcome, one entry per EVALUATED rung (same
  // order and length as `evaluated`): 1 iff that rung was ended on the signature
  // ("load path lost", simp.hpp rung_infeasible), else 0. ALWAYS filled (unlike the
  // conditional-projection vectors, which are empty when disarmed), so all-zeros is
  // the positive statement "no rung lost its load path". Echoed into run_info.json
  // as `rung_infeasible`.
  std::vector<char> rung_infeasible;
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

// The grid minimize_plastic(grid, ..., options) will solve on, computed WITHOUT
// running the solve. Returns the expanded design domain grid when
// options.design_box is set (the exact expand_design_domain call the driver
// makes: options.keep_out_boxes, options.freeze_imported_part,
// kDesignBoxCoarsenAlign), else `grid` verbatim. This is the SINGLE source of
// truth for that derivation: minimize_plastic itself uses it, and it equals the
// returned MinimizePlasticResult::solved_grid voxel-for-voxel. Use it when the
// solved grid is needed up front — e.g. to index a progressive-variant stream
// registered on options before minimize_plastic returns — so the stream and the
// final result can never describe different grids. Deterministic; performs the
// same voxelization-free geometry as minimize_plastic's internal expansion.
VoxelGrid minimize_plastic_solved_grid(const VoxelGrid& grid,
                                       const MinimizePlasticOptions& options);

}  // namespace topopt
