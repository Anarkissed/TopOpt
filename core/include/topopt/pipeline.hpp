#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
#include <limits>  // margin_floor_multiple's "disabled" sentinel (+infinity)
#include <optional>  // the optional design-volume box (M7.dom-core)
#include <stdexcept>  // the driver throws std::invalid_argument (see below)
#include <string>
#include <vector>

#include "topopt/build_frame.hpp"        // BakeBuildOrientation
#include "topopt/plsm.hpp"               // PlsmOptions / PlsmMode (default Off)
#include "topopt/build_orientation.hpp"  // BuildOrientationReport
#include "topopt/fea.hpp"        // DirichletBC
#include "topopt/lattice_density_field.hpp"  // LatticeRegionSpec, LatticeBetaKnots
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
//   * The PRINT / build orientation is an INPUT, and since handoff
//     2026-08-01-build-direction-separation it is ITS OWN input:
//     `options.build_direction` (the build-plate normal, "which way is up on
//     the plate"), resolved through resolve_build_direction. It is NOT
//     `options.gravity_direction`, which answers the different question "which
//     way is down in service" and drives self-weight. When no build direction
//     is declared the documented fallback still derives it as
//     unit(-gravity_direction) — today's behaviour to the byte — and the
//     receipt says the direction was assumed. The driver does not search for an
//     orientation; it CERTIFIES the one it was given, and (opt-in, via
//     `options.build_orientation_report`) RANKS the alternatives as a
//     recommendation that never moves the verdict. The interlayer-tension term
//     of the margin is evaluated for the resolved build direction
//     (max_interlayer_tension, M4.4).
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
  // The volume-fraction ladder to walk, in the order given. Must be non-empty and
  // STRICTLY DESCENDING (heaviest/strongest first), and it is one of exactly two
  // KINDS — mixing them is refused, because one run reduces plastic against the
  // part or grows it, not both (task 2026-08-03-growth-ladder):
  //
  //   REDUCTION — every entry in (0, 1]. The historical and default kind. Rung
  //       `vf` targets `vf` of the part's material; the walk recommends the
  //       LIGHTEST rung that clears margin_stop.
  //   GROWTH    — every entry in (1, kMaxLadderVolumeFraction] (report.hpp; 2.0 =
  //       "at most double the part"). Rung `vf` targets `vf` of the part's
  //       material, i.e. MORE than the part, and the SAME walk in the SAME
  //       direction then recommends the SMALLEST ADDITION that clears margin_stop.
  //       Requires a design box with the part left as a design region
  //       (`design_box` set, `freeze_imported_part` false) — otherwise the target
  //       is unreachable and the run would redistribute while calling it growth;
  //       minimize_plastic refuses that, naming the missing condition.
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

  // THE BUILD-PLATE NORMAL — "which way is up on the plate" (handoff
  // 2026-08-01-build-direction-separation). DISTINCT from `gravity_direction`,
  // which answers "which way is down in service". The two are different
  // questions and were conflated at three call sites until this field existed;
  // PR 266 measured the cost of that conflation on the V5 hook at 9.11x on the
  // macro interlayer margin and a REJECT/ACCEPT flip at resolution 48.
  //
  // (0,0,0) — the DEFAULT — means UNSET, and the documented fallback applies:
  // build = unit(-gravity_direction), exactly what every call site derived
  // before this field existed. So an unset build direction is byte-identical to
  // the pre-separation behaviour, and every existing caller/job/fixture keeps
  // its output to the byte.
  //
  // NEVER read this field directly. Call resolve_build_direction(options)
  // (production.hpp) — the ONE place the fallback lives, so no call site can
  // re-derive it differently (the failure mode PR 266's S5 named: a run's
  // report, its lattice receipt and a later re-analysis certifying against
  // different orientations, each self-consistent).
  Vec3 build_direction{0.0, 0.0, 0.0};

  // Arm the ORIENTATION SCORER — a post-pass on the certification solve that
  // already ran (handoff 2026-08-01-build-direction-separation). Ranks candidate
  // build directions on six criteria against that ONE solved field; PR 266
  // measured the whole sweep at 0.1-0.4% of the solve it rides on, and proved it
  // EXACT (15 full re-solves returned bit-identical fields).
  //
  // IT IS A RECOMMENDATION, NEVER AN AUTO-APPLY. `accepted` / `margin_effective`
  // are computed from resolve_build_direction(options) — the orientation
  // ACTUALLY USED — strictly before the scorer runs, and the scorer cannot
  // write to them. When the recommendation would gate differently, the receipt
  // states both verdicts and the user chooses.
  //
  // false (the DEFAULT) => the scorer never runs and no report field is filled:
  // byte-identical output, the same opt-in discipline as every other posture
  // flag here.
  //
  // NOTE (handoff 2026-08-01-bake-build-orientation): the AUTO-BAKE path below
  // arms the scorer on its own when it needs a recommendation, because it cannot
  // choose an orientation without one. Setting this flag remains the way to get
  // the RANKING RECEIPT written on a run that is not auto-baking.
  bool build_orientation_report = false;

  // ── BAKING THE CERTIFIED ORIENTATION INTO THE EXPORTED GEOMETRY ─────────────
  // (handoff 2026-08-01-bake-build-orientation.) A certified build direction that
  // exists only as a number in report.json is a certificate for an object the
  // slicer is not obliged to produce: the export was never reoriented, and a 3MF
  // build transform is advice any "place on bed" resets. This setting governs
  // whether the exported VERTICES are rotated so the certified build direction
  // IS +Z in the file.
  //
  // NEVER read this field directly. Call resolve_bake_plan(options, ...)
  // (production.hpp) — the ONE place the decision is made, for the same reason
  // resolve_build_direction is the one place the fallback lives.
  BakeBuildOrientation bake_build_orientation = BakeBuildOrientation::Auto;
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

  // ── THE PARAMETRIC LEVEL SET (task 2026-08-10-plsm-production) ────────────
  //
  // When `plsm.mode` is PlsmMode::Parametric the driver runs each rung through
  // `plsm_optimize` (plsm.hpp) INSTEAD of `simp_optimize`: the design variable
  // becomes a vector of RBF coefficients and the voxel field becomes a value of
  // the analytic function they define. PR 324 measured that from a plain array of
  // holes, with SIMP nowhere in the pipeline, it beats his shipped rung 0.68 on
  // margin (+4.2%), peak stress (-4%) and mass (-15%) and is ACCEPTED.
  //
  // ★ PlsmMode::Off IS THE DEFAULT AND IS THE ENTIRE EXISTING WORLD. The driver
  // branches on this field and on nothing else; with it Off not one line of
  // plsm.cpp executes and the run is BYTE-FOR-BYTE what it was — the same opt-in
  // discipline as min_feature_mm == 0 / cg_tolerance_loose == 0 / semdot. R1 of
  // that task is a stash-rebuild checksum of exactly that, on both binaries built
  // from one folder.
  //
  // EVERYTHING DOWNSTREAM IS UNCHANGED, because a PLSM rung produces the same
  // SimpOptimizeResult a SIMP rung does: the certification, `achieved_vf`, the
  // frozen/protect masks, the clearances, the design box and the lattice pass all
  // read `optimization.physical_density` and cannot tell the difference. What is
  // ADDED is the analytic export — `MinimizePlasticVariant::plsm_alpha` and the
  // lattice beside it — which is the design itself rather than a sampling of it.
  PlsmOptions plsm;

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

  // --- Width-aware infill knockdown (handoff 2026-07-26-width-aware-knockdown) ---
  // The plain infill_percent knockdown above is a pure function of infill fraction:
  // margin_effective = worst_case * f^1.5, with NO width term. Measurements 191/192
  // showed that is wrong in BOTH directions — f^1.5 is CONSERVATIVE at the ~9.4 mm
  // member scale an optimized part is made of (the slicer's solid wall loops rescue
  // a thin rib) yet still optimistic for envelope-scale solid regions. This block
  // arms the SHELL+CORE composite that 191/192 measured and validated to ~1-3 %:
  //   E_eff/E_solid = f_wall + (1 - f_wall)·f^1.5,   f_wall = 4·t·(W-t)/W²
  // per-voxel on the LOCAL member width W (a distance-transform thickness of the
  // printed field, computed once at the gate), with t = wall_loops·wall_line_width_mm.
  // See analyze.hpp width_aware_knockdown() / local_member_thickness_mm().
  //
  // width_aware_knockdown == false (the DEFAULT) is THE ONE RULE: the gate keeps the
  // pure `worst_case * f^1.5` scalar path, byte-for-byte identical to the pre-width
  // behaviour, and wall_loops / wall_line_width_mm are carried but never read. ARMING
  // is a separate maintainer act — the shipped production default (production.cpp
  // kProductionWidthAwareKnockdown) stays false in this PR (same opt-in discipline as
  // active_domain_band == 0 / min_feature_mm == 0). When true the gate credits walls
  // ONLY on the in-plane (von Mises) term — 191/192 measured axial + bending, NOT
  // z-bonding — so the interlayer term keeps the unmodified f^1.5, and the gate is
  // NEVER less conservative than today on the interlayer failure mode.
  bool width_aware_knockdown = false;
  // Slicer wall-loop (perimeter) count wrapped around each printed member. Pure
  // slicer metadata until now (app-side PrintParams.wallLoops); it crosses the bridge
  // for the first time here so the width-aware gate can size the solid wall ring. 0
  // (the DEFAULT) → wall thickness t = 0 → f_wall = 0 → the composite reduces to the
  // plain f^1.5 even when width_aware_knockdown is armed (a wall-less member gets no
  // rescue). Must be >= 0.
  int wall_loops = 0;
  // The slicer extrusion/line width (mm) of one INNER wall loop. This is a bead width
  // (a slicer setting, typically 1.0–1.2× the nozzle), NOT the nozzle diameter. 0.45 mm
  // is the common 0.4 mm-nozzle default and the value 191/192 measured with. Only read
  // when width_aware_knockdown is armed AND wall_loops > 0. Must be >= 0.
  double wall_line_width_mm = 0.45;
  // The slicer extrusion/line width (mm) of the single OUTER wall loop. Bambu Studio /
  // OrcaSlicer expose the outermost perimeter's width SEPARATELY from the inner loops
  // (users routinely run a narrower outer for surface quality, a wider inner for
  // speed/strength), so the solid wall ring the slicer actually deposits is
  //   t = wall_line_width_outer_mm + (wall_loops - 1)·wall_line_width_mm
  // rather than the naive wall_loops·wall_line_width_mm (handoff line-width-plumbing).
  // < 0 (the DEFAULT) is the "mirror inner" sentinel: outer := wall_line_width_mm, which
  // collapses the ring to the old single-width t = wall_loops·wall_line_width_mm EXACTLY
  // (byte-identical). Like the inner width, this is a bead width, not the nozzle. Only
  // read when width_aware_knockdown is armed AND wall_loops > 0. Must be finite.
  double wall_line_width_outer_mm = -1.0;

  // --- MULTISCALE LATTICE TOPOLOGY OPTIMIZATION (task multiscale-lattice-to) --
  //
  // THE PROBLEM THIS SOLVES. Until now the pipeline was a TWO-STEP: minimize_plastic
  // optimized the shape assuming SOLID material with penalty 3.0 driving density to
  // the extremes, and a lattice pass afterwards tried to fill what survived. What
  // survives is thin tendrils, and a member thinner than the cells-per-member floor
  // cannot hold a lattice cell, so it falls back to solid. On the maintainer's
  // M2_verticalStand run (128^3, ladder 0.68/0.52/0.38/0.26) that was 99–100% of
  // every lattice region: 0, 82 and 472 latticed voxels out of ~10,500. THE
  // OPTIMIZER ATE THE MATERIAL THE LATTICE NEEDED, because nothing told it a lattice
  // was coming. No post-process can undo that; the design has to be optimized
  // KNOWING the interior will be lattice.
  //
  // WHAT ARMING DOES. Inside the lattice region, the SIMP loop's material law
  // becomes the MEASURED homogenized cubic tensor C(rho) of the lattice library
  // (lattice_material.hpp) instead of rho^p * E0 — intermediate density stops being
  // a penalised fiction and becomes a real, printable, measured material. Outside
  // the region (and everywhere on a job with no lattice block) nothing changes.
  // At termination the design is PROJECTED onto the feasible set
  // {0} u [rho_lo, rho_hi] u {1}, and the volume-constraint violation that
  // projection causes is CHARGED and REPORTED, never absorbed.
  //
  // false (the DEFAULT) is THE ONE RULE: not one branch of the multiscale path is
  // taken, the SIMP loop is the classic penalized isotropic one element-for-element,
  // and every existing run/fixture/golden document is byte-for-byte what it was.
  // The named production constant is kProductionMultiscaleLatticeTO
  // (production.cpp); it is a PER-JOB posture, not a global arming, because unlike
  // the accelerators this changes the ANSWER by design.
  bool multiscale_lattice = false;
  // The lattice topology the material curve is fitted from. Must be certifiable AND
  // pass lattice_material_model_trustworthy — only OCTET does today: the other six
  // certifiable topologies stop at rho ~0.5-0.6, leaving a 0.41-0.50-wide upper gap
  // the model spans by pure interpolation across a 3.9-5.2x stiffness swing, which
  // is not something to steer a design loop across. minimize_plastic REFUSES an
  // untrustworthy topology rather than optimize on a fiction.
  LatticeTopology multiscale_topology = LatticeTopology::Octet;
  // The voxels that will be latticed — the job's lattice ROLE regions and keep-outs
  // resolved to a grid-indexed flag (non-zero = latticed), design-INDEPENDENT so it
  // cannot flicker between iterations. EMPTY means "every design voxel", which is
  // what a whole-part lattice job wants. Size must be 0 or the analysis grid's
  // voxel_count(). Only read when multiscale_lattice is true.
  std::vector<char> multiscale_region;
  // Occupancy classifiers for the feasible-set projection: a density <= this is
  // VOID, >= (1 - this) is SOLID. The probe measured on 1e-3; the value is exposed
  // rather than hardcoded so the receipt can state what it classified against.
  double multiscale_void_below = 1e-3;
  // How often (in design iterations) to measure the CELLS-PER-MEMBER FLOOR occupancy
  // of the live design — the local-member-thickness EDT is not free, so it runs on a
  // stride. 0 (the DEFAULT) disables the measurement entirely; 1 measures every
  // iteration. The measurement is READ-ONLY observability: it never moves a density,
  // a verdict or a tolerance. See MinimizePlasticVariant::floor_history.
  int multiscale_floor_stride = 0;
  // The lattice CELL SIZE (mm) the floor occupancy is measured against — a member is
  // "below the floor" when local_member_thickness_mm / cell < the topology's
  // lattice_cells_per_member_min. <= 0 disables the measurement (there is no cell to
  // measure against). This is the same cell the grading law will use at export; a
  // SWEPT plan's FINEST cell is the right one to report against, because that is the
  // most favourable cell any member could be granted.
  double multiscale_floor_cell_mm = 0.0;
  // THE PRINTED-SET THRESHOLD this run's designs are read at (see analyze.hpp for
  // the full rationale). 0.5 (the DEFAULT) is the M3.5 iso and is byte-for-byte
  // every existing run. A multiscale run lowers it BELOW the certified band's
  // floor, so "printed" means "not void": a voxel at density 0.30 is a real,
  // printable, measured 30%-dense lattice cell, and thresholding it away would
  // delete material the optimizer placed and the certification solved with.
  // minimize_plastic resolves it to multiscale_printed_iso() when
  // multiscale_lattice is armed and to 0.5 otherwise; it is not a free knob.
  // Must be in (0, 1).
  double printed_iso = 0.5;

  // --- ★ LATTICE AS A MATERIAL over the FROZEN region -------------------------
  //     (task 2026-08-13-lattice-as-a-material; see lattice_density_field.hpp
  //      for the mechanism and for why the fixed density and the graded field
  //      are ONE thing.)
  //
  // A frozen region — a face protection, an anchor pad, a BC skin — is full solid
  // to the optimiser today in all four of the ways that matter: its FEA
  // stiffness, its mass, its place in the volume budget (outside it), and its
  // sensitivity (zero, which is correct). This block makes the first three read
  // the LATTICE the region will actually be printed as, and leaves the fourth
  // alone. On the maintainer's part that region is 45.5% of the printed mass.
  //
  // false (the DEFAULT) is THE ONE RULE: no field is resolved, no region id is
  // read, `SimpParams::lattice_relative_density` stays null, the Active budget is
  // `vf * n_active` bit-for-bit, and every existing run is byte-for-byte what it
  // was. It is also inert when armed with every region SOLID or at density 1.0 —
  // a lattice at relative density 1.0 IS solid, and bar R1 verifies that by
  // checksum rather than by construction.
  bool frozen_lattice = false;

  // The topology the material curve is fitted from. Must pass
  // `lattice_material_model_trustworthy` — only OCTET does today, and
  // minimize_plastic REFUSES anything else rather than steer a gate on an
  // interpolated stretch. When `multiscale_lattice` is ALSO armed the two
  // topologies must agree: one run optimises against one material curve.
  LatticeTopology frozen_lattice_topology = LatticeTopology::Octet;

  // WHICH FROZEN VOXEL BELONGS TO WHICH DECLARED REGION. Solved-grid indexed
  // (minimize_plastic_solved_grid), size 0 or voxel_count(); 0 means "no declared
  // region". Only voxels the effective mask holds FrozenSolid are ever read — a
  // density field over a voxel the optimiser can move is a different feature and
  // must not appear by accident.
  std::vector<int> frozen_lattice_region_id;
  // The declaration, one entry per region id. A region absent from here, or in
  // mode Solid, keeps its voxels fully dense.
  std::vector<LatticeRegionSpec> frozen_lattice_regions;

  // MODE 2's coefficients, and the knot lattice they live on. Empty `beta` means
  // MODE 1 ONLY, which is what ships first (bar R2). A region in mode Optimised
  // with no beta field is a REFUSAL, not a fallback to a default density.
  std::vector<double> frozen_lattice_beta;
  LatticeBetaKnots frozen_lattice_beta_knots;   // all zero = derive from the grid
  double frozen_lattice_beta_support = 2.0;
  double frozen_lattice_beta_steepness = 1.0;
  std::string frozen_lattice_beta_basis = "gaussian";  // or "wendland"

  // The lattice CELL the cells-per-member validity is judged at. A non-positive
  // cell disables the per-region validity measurement — and with
  // `frozen_lattice_refuse_below_floor` armed that is a REFUSAL of the whole
  // feature, not a silent pass, because a law used outside its validity range
  // with nothing measuring the range is the failure mode §1(d) exists to prevent.
  double frozen_lattice_cell_mm = 0.0;

  // ── ★ THE MINIMUM EXTRUDABLE STRUT WIDTH (mm) — 0 MEANS UNSET, AND UNSET IS A
  // REFUSAL. NEVER A DEFAULT.
  //
  // ★ PRINTABILITY IS ENTIRELY USER INPUT. Every project carries a print profile
  // the user chose and the software may not change, and this number comes from
  // it — `job.hpp`'s `min_extrudable_width_mm` ("stated minimum strut width (mm),
  // finite > 0"), which the app fills from `PrintParams.strutLineWidthMM`. There
  // is no such thing as a sensible default here: a 0.25 mm nozzle and a 0.8 mm
  // nozzle disagree about the printability floor by more than 3x, so a hardcoded
  // number would either refuse a lattice that prints perfectly well or approve
  // one that comes out as gaps.
  //
  // This field defaulted to 0.45 in an earlier cut of this task. That is HIS
  // nozzle, from HIS profile, and baking it in is exactly the drift
  // `lan-job-drops-outer-line-width` and `infill-knockdown-duplicated-app-core`
  // record: a slicer number that reaches one code path and not another, or is
  // invented by the code, and is wrong for everybody else.
  //
  // `minimize_plastic` REFUSES a frozen-lattice run that does not state it.
  // Printability cannot be assumed and it cannot be skipped.
  double frozen_lattice_min_extrudable_width_mm = 0.0;

  // Refuse any region whose median cells-per-member is below
  // `lattice_cells_per_member_min` (5 for octet). true is the shipped posture and
  // the pre-registered bound B4. Settable to false ONLY to MEASURE what a refused
  // region would have done — a run with it false is not certifiable and says so.
  bool frozen_lattice_refuse_below_floor = true;

  // Fold the measured de-homogenised STRUT bound into the acceptance gate over
  // the latticed region (analyze.hpp `gate_on_strut_strength`). true is the
  // shipped posture for this feature: without it the latticed region's strength
  // is not gated at all, which is failure mode M5 moved one stage later.
  bool frozen_lattice_gate_on_strut_strength = true;

  // How much of the mass the field frees goes back to the optimiser. See
  // SimpOptions::freed_mass_return — 0.0 banks it (the assignment table's
  // posture), 1.0 is mass-neutral (the posture §3's buttressing coupling
  // demands). The §4c loop walks between them.
  double frozen_lattice_freed_mass_return = 0.0;

  // --- GATE DIAGNOSIS (handoff 2026-08-02-gate-diagnosis-recommendations) ------
  // Arm the per-rung explanation of the acceptance verdict: which term BINDS, its
  // value against the value it had to reach, and recommendations EACH VERIFIED by
  // evaluating gate_margin_effective under the proposed change (topopt/
  // gate_diagnosis.hpp). It runs strictly AFTER `accepted` / `margin_effective`
  // are sealed, writes only to VariantReport::diagnosis, and CANNOT MOVE A
  // VERDICT — the same discipline as the build-orientation post-pass.
  //
  // false (the DEFAULT) leaves every VariantReport::diagnosis default-constructed
  // and the emitted report.json byte-for-byte what it was, so every existing
  // caller, fixture and golden document is unaffected. PRODUCTION ARMS IT
  // (configure_production_options), because the whole point is that a real user's
  // rejection explains itself.
  bool gate_diagnosis = false;
  // The material catalog the diagnosis prices the MATERIAL lever against. READ
  // ONLY — the diagnosis never writes materials.json and never mutates a Material.
  // nullptr (the DEFAULT) reports the material lever as NOT EVALUABLE with that
  // reason rather than guessing. The pointee must outlive the minimize_plastic
  // call. Only read when `gate_diagnosis` is true.
  const MaterialLibrary* material_catalog = nullptr;

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
  //
  // TWO ARGUMENTS: the rung that just completed, and EVERY variant evaluated so
  // far — `result.evaluated`, live, with the new rung as its back(). The second
  // exists so a caller that needs the whole set (run_job publishes design.bin and
  // fields.bin after every rung) can read it FRESH on each call instead of
  // accumulating pointers across calls. Accumulated pointers are only valid while
  // the vector never reallocates; that invariant does hold (see the reserve() in
  // minimize_plastic.cpp) but it lives in a different file from the code that
  // would depend on it, and the penalty for breaking it is use-after-free rather
  // than a wrong answer. Handing over the container removes the dependency
  // instead of documenting it. The reference is valid FOR THE DURATION OF THE
  // CALL only — a callback that stores it is back to the same hazard.
  std::function<void(const MinimizePlasticVariant&,
                     const std::vector<MinimizePlasticVariant>&)> on_variant;

  // Optimization-history playback (app): the target number of keyframe meshes to
  // capture per variant (0 = none, the default). The driver spreads this many
  // frames across each rung's SIMP iterations and extracts a marching-cubes mesh
  // per frame into MinimizePlasticVariant::keyframe_meshes. Adds a few cheap MC
  // extractions per variant (relative to the FEA solves); no effect on the
  // optimization itself.
  int keyframe_count = 0;

  // ★ DIAGNOSTIC ONLY (task 2026-08-13-lattice-as-a-material, bar R4): the
  // ANALYSIS density at EVERY iteration, with the 1-based iteration number
  // ★ WITHIN THE CURRENT RUNG — the counter RESTARTS at each ladder rung, so a
  // multi-rung run hands out 1..n, then 1..m. A caller that wants one continuous
  // trajectory must either run a single rung or segment on the counter dropping.
  // Null by default and never set in production; with it null the driver takes
  // no new branch and the run is unchanged.
  //
  // It exists because "the margin SETTLES at iteration i" is a claim about a
  // TRAJECTORY, and every other hook here reports an endpoint. A probe cannot
  // answer it by re-implementing the ladder — a probe that runs a different loop
  // measures a different thing — so the driver hands out the trajectory instead.
  //
  // ★ DO NOT CERTIFY INSIDE THIS CALLBACK. `analyze_fixed_design` is not pure,
  // so certifying mid-loop lets the measurement change the run it is measuring.
  // Copy the density out (or write it to disk) and certify afterwards.
  //
  // Composes with `keyframe_count`: playback keeps its own cadence.
  std::function<void(int iteration, const std::vector<double>& analysis_density)>
      iteration_density;

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

  // --- DRAFT QUALITY (handoff 2026-07-25-draft-quality) --------------------
  // Approximate-trajectory / exact-certification posture: the fourth, load-bearing
  // form of the inexact-optimization idea this project rejected in its (a)-without-(c)
  // form (handoffs 129/130/160, PR 181). All four parts travel together here:
  //   (a) LOOSE early trajectory solves, (b) PROGRESSIVE tightening over the last k,
  //   (c) an EXACT solve + real certification at the end, (d) AUTO-ESCALATION when
  //   the certified result leaves a safety envelope.
  //
  // OPT-IN, default OFF (draft_quality=false) => this whole block is inert and every
  // run is BYTE-FOR-BYTE identical to the pre-draft driver (THE ONE RULE, same
  // discipline as min_feature_mm==0 / warm_start_inherit==false / active_domain_band==0).
  // Arming it is a MAINTAINER decision, NOT this handoff's — the default stays OFF.
  //
  // When ON, each ladder rung's TRAJECTORY penalized solves run on the adaptive
  // loose→tight schedule (SimpOptions::cg_tolerance_loose = draft_loose_tol; the
  // motion-keyed adaptive_traj_cg_tol tightens as max|Δρ| decays below the move
  // limit). Parts (a)+(b): the loose tolerance is spent on the EARLY, fast-moving
  // iterations whose sensitivities feed a step that is about to be overwritten, and
  // the TRAILING k iterations — where the design has settled — are resolved back
  // toward the tight cg_tolerance. k is not a magic number: it is the length of the
  // convergence tail the schedule tightens over, DERIVED from the convergence
  // criterion (the objective must be flat over mma_plateau_window iterations to
  // terminate, so those trailing iterations are the ones that lock the terminal
  // basin and must be resolved accurately) and MEASURED per rung into
  // MinimizePlasticResult::draft_rung_tail_k.
  //
  // Part (c): the FINAL certification solve inside simp_optimize AND the driver's
  // stress-recovery solve ALWAYS run at the tight cg_tolerance — draft mode writes
  // ONLY cg_tolerance_loose, never cg_tolerance — so the certificate a run ships is
  // never computed on a loosened solve. Asserted (B2), not commented: see the
  // adaptive_traj_cg_tol floor asserts in simp.cpp and the recovery-solve assert in
  // minimize_plastic.cpp.
  //
  // Part (d) — THE ESCALATION GATE. After a rung's draft optimize, the driver
  // compares the rung's own final TRAJECTORY compliance (the last loose solve)
  // against its EXACT CERTIFIED compliance (the tight final solve on the SAME
  // design). This gap is SELF-CONTAINED — it needs no exact trajectory, which is the
  // whole point — and PR 181's C_delta column already measured this exact quantity
  // (it ranged 0.87–5.09%), so it is real and instrumented. If the relative gap
  // exceeds draft_escalation_c_gap the draft basin has diverged: the driver RE-RUNS
  // that rung at tight tolerance from the rung's OWN recoverable warm-start seed
  // (opt.initial_design, still unmutated at that point) and records the escalation.
  // Escalation adds cost — it is the price of the safety net — so the summed-CG win
  // is reported NET of it.
  bool draft_quality = false;

  // The loose trajectory-tolerance endpoint the schedule interpolates FROM when the
  // design is moving at the move limit. Must be > simp.cg_tolerance to have any
  // effect (a value <= it leaves every trajectory solve tight, i.e. draft does
  // nothing). Default 1e-3 is the 128 production value. Ignored unless draft_quality.
  double draft_loose_tol = 1e-3;

  // Escalation threshold on the relative compliance gap |C_cert - C_traj| / C_cert.
  // A rung whose loose trajectory settled to within this of its own exact certified
  // compliance is trusted; a larger gap triggers the tight re-run (part d).
  //
  // PROVISIONAL — the trigger is measured NOT to separate (handoff §gap-separation).
  // On the harness stagnation grid a rung that genuinely diverged (0.15 of its solid
  // voxels flipping printed<->void under a 5e-1 loose trajectory) carried gap≈0.000,
  // while a fully-converged rung carried gap up to 0.006: the scalar compliance is a
  // flat objective near the optimum, so a different design can share its compliance
  // and a same design can differ in it. So this threshold must NOT be read as a
  // reliable divergence detector, and no value is fitted to look good on one grid.
  //
  // What IS load-bearing is part (c): the certified compliance + stress margin are
  // ALWAYS solved tight (B2, structural), so the SHIPPED part's numbers are exact
  // whatever this does. And empirically the shipped (terminal, certified) design is
  // tolerance-robust: 0 classification flips vs the tight design across a 500x loose
  // sweep, WITH and WITHOUT warm-start inheritance (a transient mid-ladder divergence
  // never reached the terminal rung). So the win is capturable on the strength of
  // exact certification; escalation is defense-in-depth, not the safety guarantee.
  //
  // The default 0.02 rarely fires (a coarse guard, win-preserving). A value <= 0 is
  // the maximally-CONSERVATIVE override: escalate EVERY rung so every shipped design
  // had a tight trajectory — correctness over the win, and note it costs MORE than a
  // plain tight run (the draft pass plus a tight re-run per rung), the honest price
  // of a safety net without a reliable trigger ("when in doubt, be slow").
  //
  // SUPERSEDED by the DESIGN-SPACE trigger below (handoff 2026-07-26-draft-quality-
  // phase2). This gap threshold is retained only as the FALLBACK when the design
  // trigger is disarmed (draft_escalation_design_flip <= 0) — keeping every existing
  // Phase-1 harness/test byte-identical — and is NOT the recommended armed posture.
  // Ignored unless draft_quality.
  double draft_escalation_c_gap = 0.02;

  // --- Phase 2 (handoff 2026-07-26-draft-quality-phase2): the DESIGN-SPACE trigger.
  // Phase 1 escalated on the scalar compliance gap and MEASURED it not to separate:
  // compliance is flat near the optimum, so a genuinely diverged rung can share the
  // certified compliance (gap≈0, a MISS) while a converged rung differs slightly in
  // it (a false alarm). The reliable signal is the DESIGN, not the objective.
  //
  // When draft_use_design_trigger is set the design trigger is ARMED and REPLACES the
  // compliance-gap decision. After a rung's loose plateau the driver takes a probe:
  // from the rung's own converged loose design it runs TWO memoryless one-step (OC)
  // reseeds — one whose FEA is solved at the LOOSE trajectory tolerance, one at the
  // exact TIGHT cg_tolerance (never looser: asserted, B2/D6) — and measures the
  // fraction of solid voxels whose printed<->void classification DIFFERS between the
  // two one-step iterates. Both reseeds share the same warm-start inverse-filter and
  // volume bisection, so that displacement cancels in the difference and only the
  // FEA-tolerance-driven step difference survives: ~0 when the loose sensitivities
  // already agree with tight (converged), large when the loose trajectory settled on
  // sensitivities a tight solve rejects (diverged). The probe results are DISCARDED
  // (never fed back), so the probe cannot disturb the trajectory it measures.
  //
  // The threshold draft_escalation_design_flip is the negative-control noise floor,
  // DERIVED not fitted: the tight-vs-tighter control (loose barely above cert) flips
  // 0 voxels, so the floor is 0 and the default threshold 0 means "escalate on ANY
  // real design disagreement".
  //
  // MEASURED LIMITATION (handoff 2026-07-26-draft-quality-phase2, bar D1): this probe
  // correctly REFUSES the compliance gap's false positive (a converged rung with a
  // 0.031 gap probes to 0), but it does NOT catch Phase-1's genuine-divergence
  // counterexample either (a rung 0.15 away from the independent tight design probes
  // to 0 at EVERY budget). The reason is structural and proven: that divergence is a
  // locally STABLE alternate basin the loose trajectory fell into upstream, so a probe
  // seeded FROM the settled plateau cannot see it — only a full tight re-run from the
  // rung's entry seed (escalation itself) escapes it. So this trigger is NOT a
  // reliable divergence detector and does not, on its own, justify arming draft in
  // production; the load-bearing safety remains the ALWAYS-exact certification. It is
  // provided, disarmed, as a sound detector of a genuinely NON-stationary loose
  // plateau, should such a regime ever arise (the harness grids do not exhibit one).
  //
  // Default: draft_use_design_trigger is OFF, so the Phase-1 gap fallback runs (every
  // pre-phase2 harness/test byte-identical). Ignored unless draft_quality.
  bool draft_use_design_trigger = false;
  double draft_escalation_design_flip = 0.0;

  // The probe budget: how many one-step OC iterations each reseed runs before
  // comparing classification. Small by design — the probe must cost a small fraction
  // of the rung it protects (measured into MinimizePlasticResult::draft_rung_probe_cg;
  // ~1% on the harness grids). 1 = a single OC step per reseed. Ignored unless the
  // design trigger is armed.
  int draft_probe_iters = 1;
};

// Handoff 131 — the VariantReport::rejection_reason a rung ended on the
// rung-infeasibility signature carries. One definition, shared by the driver, the
// CLI's console line and the tests, so the string in report.json can never drift
// from the string anything checks for.
inline constexpr const char* kRungInfeasibleReason =
    "rung infeasible (load path lost)";

// Handoff 2026-07-23-gate-honesty-connectivity-rejection — the other two
// VariantReport::rejection_reason values, defined here for the same reason: one
// definition shared by the driver, the CLI console line and the tests, so the
// string in report.json cannot drift from the string anything checks for.
// TOGETHER WITH kRungInfeasibleReason and kRungNonConvergentReason (below) these
// are exhaustive: every entry of JobReport::rejected carries exactly one of the
// FOUR, and never "" (the rejection-speaks rule — a rejection that does not say why
// is a rejection the reader has to guess at).
//   * kMarginBelowRequiredReason — the ordinary strength verdict: the rung was
//     analysed and its infill-adjusted margin came in under margin_stop. The
//     margin_effective / margin_required numbers on the line are the detail.
//   * kLoadPathNotConnectedReason — the CONNECTIVITY BELT (voxel.hpp
//     load_path_connected) found no path of printed material from the anchor
//     (Fixture) voxels to the load (Load) voxels. Read this BEFORE the margin
//     numbers on such a line: they are real measurements of a severed structure,
//     which is exactly why they look excellent (no load path => no stress => a
//     huge margin). They describe nothing that can be built.
inline constexpr const char* kMarginBelowRequiredReason =
    "margin below required";
inline constexpr const char* kLoadPathNotConnectedReason =
    "load path not connected";

// Handoff 2026-07-27-nonconvergence-rejection — the FOURTH rejection_reason: a
// LINEAR SOLVE of this rung did not converge (SolverNonConvergence: CG reached its
// iteration cap without meeting the requested relative-residual tolerance), so the
// rung has no trustworthy field to certify. Distinct from all three above, and
// deliberately worded so the reader knows it is a SOLVER failure, not a verdict
// about the design: the margin numbers on such a line are ABSENT (the analysis was
// skipped), exactly as on an infeasible line — NOT the "measured on a severed
// structure" numbers a connectivity rejection carries. It arises two ways, both
// honest and both this same reason: the rung's TRAJECTORY solve failed to converge
// (SimpOptimizeResult::non_convergent), or its CERTIFICATION solve did
// (FixedDesignAnalysis::non_convergent — the tight solve is never softened, so a
// design the certification cannot resolve is rejected, never certified). Like an
// infeasible rung it does NOT stop the ladder: non-convergence is a property of THIS
// carve's operator, and the next (lighter) rung gets a fresh attempt.
inline constexpr const char* kRungNonConvergentReason =
    "linear solve did not converge";

// Task 2026-08-03-preflight-feasibility-and-divergence — the FIFTH and SIXTH
// rejection_reason values, from the two DIVERGENCE guards. Both are distinct
// from kRungInfeasibleReason on purpose: neither claims the load path was lost.
// On the motivating 10-hour run the pre-flight measured the path INTACT, so
// labelling its rejection "load path lost" would have been a false statement
// about the geometry — the honest claim is about the TRAJECTORY.
//   * kRungDivergedReason — a SINGLE iteration sat >= 1000x the rung's starting
//     compliance, with a >= 4x CG blow-up, at >= 50x the wall of the rung's
//     first iteration (simp.hpp SimpOptions::infeasible_immediate_ratio). Like
//     an infeasible rung, its ANALYSIS IS NEVER RUN, so its stress / margin /
//     settings fields are zero placeholders meaning "not measured".
//   * kRungTimeBudgetReason — an iteration exceeded 100x the wall of the rung's
//     first iteration and was stopped, mid-solve where possible. This is not a
//     verdict about the design at all; it is the run refusing to spend hours
//     proving something it can already see. run_info names the phase that blew
//     up and the numbers the budget was formed from.
// Neither STOPS the ladder (as with infeasibility and non-convergence, the next
// lighter rung gets a fresh attempt from the last feasible field), and neither
// rung is ever certified, exported or inherited from.
inline constexpr const char* kRungDivergedReason =
    "rung diverging (objective exploded)";
inline constexpr const char* kRungTimeBudgetReason =
    "iteration time budget exceeded";

// One ladder rung actually evaluated by the driver.
// THE CONDITIONAL MMA-PROJECTION GATE'S ARMING PREDICATE (handoff 123), as a
// pure function of the options — the ONE definition, which `minimize_plastic`
// itself calls, so it cannot be reconstructed differently anywhere else.
//
// The gate polishes a CONVERGED GRAYSCALE MMA rung into a beta-projection when
// its design-region grayness (design_discreteness_mnd) exceeds the threshold. It
// is armed only on the MMA grayscale path, and three modes DISARM it:
//
//   * `simp.mma_projection` already true — every rung projects unconditionally,
//     so the conditional gate is inert by construction.
//   * SEMDOT — `simp_optimize` REFUSES semdot together with a Heaviside
//     projection (two sharpeners fighting, and beta is exactly the control
//     parameter SEMDOT claims not to need), so a fired gate would THROW mid-rung.
//   * ★ THE PARAMETRIC LEVEL SET (task 2026-08-10-plsm-production). Found by
//     running the production path, not by reading it: a PLSM ersatz is gray over
//     its whole band BY CONSTRUCTION — the band IS the smoothing law, not
//     optimiser indecision — so `design_discreteness_mnd` always clears the
//     threshold and the gate always fires. What it then does is the defect: it
//     re-runs `simp_optimize` SEEDED FROM the parametric field, which discards
//     the RBF coefficients and continues the rung as a voxel design. The run
//     would report a parametric rung and ship a SIMP one. There is also nothing
//     to project: the design variable is a coefficient, not a density, and a
//     Heaviside continuation on the ersatz would sharpen the very band the
//     representation's smoothness comes from.
//
// A disarmed run reports it the same way any other does — `rung_grayscale_mnd`
// and `conditional_projection_fired` stay EMPTY.
bool conditional_mma_projection_armed(const MinimizePlasticOptions& options);

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

  // ── THE ANALYTIC DESIGN (task 2026-08-10-plsm-production, S1(d)) ──────────
  //
  // EMPTY on every SIMP rung, and non-empty exactly when this rung ran under
  // MinimizePlasticOptions::plsm. `plsm_alpha` is the RBF coefficient vector and
  // `plsm_lattice` the knot lattice it lives on; together with `plsm_basis_kind`
  // and `plsm_eta_voxels` they are the WHOLE design — 685 KB against
  // physical_density's 3.75 MB on his part, and re-evaluable at ANY resolution
  // through `plsm_evaluate` rather than only at the one it was optimised on.
  //
  // WHAT READS IT: `run_job` writes it beside the meshes as
  // `<mesh_prefix>_<vf>_alpha.f64` + `.meta` on the CLI path (see the writer in
  // run_job.cpp), and `plsm_evaluate(plsm_lattice, plsm_basis_kind, plsm_alpha,
  // nx, ny, nz, factor, threads)` reconstructs phi on any lattice from it. The
  // ersatz is then `H_eta(-phi)` at `plsm_eta_voxels * spacing`. Nothing in the
  // ladder, the certification or the lattice pass reads it — those all read
  // `optimization.physical_density`, which is why they needed no changes.
  std::vector<double> plsm_alpha;
  PlsmKnotLattice plsm_lattice;
  PlsmBasisKind plsm_basis_kind = PlsmBasisKind::Gaussian;
  double plsm_eta_voxels = 0.0;
  // The load-path guarantee the smooth frozen boolean gives, MEASURED on this
  // rung: the smallest ersatz occupancy any FrozenSolid voxel took. > 0.5 is the
  // guarantee; plsm_optimize refuses to run if it is not, so a shipped variant
  // always carries a number above it and the receipt can say so.
  double plsm_frozen_floor_occupancy = 0.0;

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

  // Handoff 2026-07-27-nonconvergence-rejection — true iff a LINEAR SOLVE for this
  // rung did not converge: either its trajectory solve
  // (optimization.non_convergent) or its certification solve. Treated exactly like
  // an infeasible rung — NEVER accepted, per-rung analysis fields
  // (von_mises_field/…/mesh()) stay default-constructed, `report` carries
  // rejection_reason kRungNonConvergentReason with zero fabricated numbers, and the
  // ladder CONTINUES (non-convergence is a property of this carve's operator, not a
  // strength verdict). Distinct from `infeasible`: an infeasible rung's solves DID
  // converge on a frozen-high objective; a non_convergent rung's solve could not be
  // resolved at all. Mutually exclusive with `infeasible` on any one rung.
  bool non_convergent = false;

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
  // (c2) The BUILD-ORIENTATION RANKING for this variant (handoff
  // 2026-08-01-build-direction-separation). Default-constructed (evaluated ==
  // false) unless options.build_orientation_report armed the post-pass, so every
  // existing run is byte-identical. A RECOMMENDATION ONLY: `accepted` and
  // `margin_effective` above are this variant's verdict for report.orientation —
  // the orientation ACTUALLY USED — and the ranking cannot move them.
  BuildOrientationReport build_orientation;
  // (c3) THE ORIENTATION THIS VARIANT IS CERTIFIED AND EXPORTED IN (handoff
  // 2026-08-01-bake-build-orientation).
  //
  //   `applied_build_dir` — the MODEL-frame build direction every
  //       direction-bearing number on this variant was computed at. Equal to
  //       resolve_build_direction(options) unless the orientation was chosen for
  //       the user, in which case it is the chosen one.
  //   `build_direction_auto_applied` — the orientation was CHOSEN because none
  //       was declared. Only ever true then. When true the receipt and the app
  //       must say so; a silent auto-apply is the failure this feature exists to
  //       avoid, not a convenience.
  //   `export_baked` — the exported mesh (solid and latticed) is this variant's
  //       geometry ROTATED so `applied_build_dir` is +Z in the file. When true,
  //       `report.orientation` is (0,0,1) — the build direction IN THE FILE —
  //       and `applied_build_dir` is the same direction in the model frame.
  //
  // Per-variant, not per-run: each rung is a different design with its own
  // overhangs and its own interlayer field, so each may be certified in its own
  // best orientation, and each exported file carries its own rotation. The run's
  // published receipt describes the rung the user actually exports (the lightest
  // accepted one).
  Vec3 applied_build_dir{0.0, 0.0, 1.0};
  bool build_direction_auto_applied = false;
  bool export_baked = false;
  // (d) Printed mass in grams = material density (g/cm^3) * printed volume,
  // spacing-aware: (# printed voxels) * grid.voxel_volume() (mm^3) / 1000.
  double mass_grams = 0.0;

  // --- MULTISCALE LATTICE TO (task multiscale-lattice-to) ---------------------
  // Default-constructed (multiscale == false) on every run that did not arm
  // options.multiscale_lattice, so a non-multiscale variant carries exactly the
  // fields it always did.
  struct MultiscaleReport {
    bool multiscale = false;          // this variant was optimized multiscale
    std::string topology;             // the fitted topology's name
    std::size_t region_voxels = 0;    // design voxels the lattice material covered
    std::size_t fit_rows = 0;         // measured rows the C(rho) fit ran through
    double rho_lo = 0.0, rho_hi = 0.0;  // the certified band, read from core

    // The occupancy of the CONVERGED, PROJECTED design over the region, by
    // feasible class. band + void + solid == region_voxels after projection;
    // gap_* are what the projection had to move and are 0 afterwards by
    // construction (kept so the receipt can state that it is 0 because it was
    // projected, not because nothing was ever there).
    std::size_t voxels_void = 0, voxels_band = 0, voxels_solid = 0;
    std::size_t voxels_lower_gap = 0, voxels_upper_gap = 0;
    double band_rho_min = 0.0, band_rho_max = 0.0;  // observed in-band span

    // THE PROJECTION CHARGE — reported, never absorbed. `volume_constraint_
    // violation` is (achieved - target)/target after projection: the optimizer
    // satisfied the volume constraint and the projection then broke it by this
    // much, signed.
    std::size_t projected_lower = 0, projected_upper = 0;
    double projection_volume_delta = 0.0;         // signed, in voxel-fraction units
    double projection_max_density_move = 0.0;
    double volume_fraction_before_projection = 0.0;
    double volume_fraction_after_projection = 0.0;
    double volume_fraction_target = 0.0;
    double volume_constraint_violation = 0.0;

    // THE CELLS-PER-MEMBER FLOOR, measured on the converged design (and, when
    // options.multiscale_floor_stride > 0, per iteration in floor_history).
    // `floor_cells` is lattice_cells_per_member_min for the topology;
    // `floor_cell_mm` the cell the widths were divided by.
    double floor_cells = 0.0;
    double floor_cell_mm = 0.0;
    std::size_t floor_measured_voxels = 0;   // region voxels that were printed
    std::size_t floor_below_voxels = 0;      // ... whose member is below the floor
    double floor_min_cells_per_member = 0.0; // thinnest member, in cells
    // THE CEILING — how many region voxels could EVER be latticed, by ANY design.
    // Measured once per run on the FULLY SOLID part: a design can only remove
    // material, and removing material only thins members, so a region voxel whose
    // member is below the cells-per-member floor when the part is solid can never
    // clear it. This is the number that says whether a disappointing latticed
    // fraction is the optimizer's fault or the part's geometry — without it, "we
    // only latticed X%" cannot be told apart from "X% is all there was".
    std::size_t floor_ceiling_measured = 0;  // region voxels in the solid part
    std::size_t floor_ceiling_eligible = 0;  // ... whose member clears the floor
    double floor_ceiling_min_cells = 0.0;
    // Histogram of member thickness IN CELLS over the printed region voxels,
    // bucketed at 1-cell width: [0,1), [1,2), ... [9,10), [10,inf). Empty when
    // the floor measurement did not run.
    std::vector<std::size_t> floor_histogram;

    // Per-iteration floor occupancy while the design was forming — so a design
    // starving its members below the floor is visible AS IT HAPPENS rather than
    // at export. One entry per MEASURED iteration (stride-sampled).
    struct FloorSample {
      int iteration = 0;
      std::size_t measured = 0;
      std::size_t below = 0;
      double min_cells_per_member = 0.0;
    };
    std::vector<FloorSample> floor_history;
  };
  MultiscaleReport multiscale;

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

// THE ONE definition of "how many DOFs does a solve on this grid touch" — the
// weight that makes operator applies at DIFFERENT RESOLUTIONS commensurable
// (handoff 2026-08-02-warm-start-coarse-experiment). Trilinear hex elements put
// 3 DOFs on each node of an (nx+1) x (ny+1) x (nz+1) nodal lattice.
//
// It is a property of the GRID ALONE, deliberately: the reduced operator acts on
// the FREE DOFs, which depend on the BC set and the active-domain mask and so
// could not be re-derived from a run record. Anything comparing a res/2 pre-solve
// against a fine ladder must weight by THIS, never count raw applies — a coarse
// apply is ~1/8 of a fine one, so an unweighted sum is not a comparison at all.
inline long long grid_nodal_dofs(const VoxelGrid& g) {
  return 3LL * static_cast<long long>(g.nx + 1) *
         static_cast<long long>(g.ny + 1) * static_cast<long long>(g.nz + 1);
}

// The result of a minimize_plastic run.
// ★ WHAT THE LATTICE DENSITY FIELD ACTUALLY DID, ONCE PER RUN (task
// 2026-08-13-lattice-as-a-material). Resolved once before the ladder — every rung
// of one run optimises against the same material curve over the same region — so
// it hangs off the RESULT and not off each variant. Default-constructed
// (`armed == false`) on every run that did not arm `frozen_lattice`.
//
// ★ EVERY NUMBER HERE IS PER REGION, NEVER IN AGGREGATE (bar R5). An aggregate
// cells-per-member is exactly the shape of report that lets one region below the
// homogenisation floor hide behind four above it.
struct FrozenLatticeReport {
  bool armed = false;
  std::string topology;
  double cell_mm = 0.0;
  double min_extrudable_width_mm = 0.0;
  bool refuse_below_floor = true;
  bool gate_on_strut_strength = false;
  double freed_mass_return = 0.0;

  // The frozen set as the LOOP holds it (effective_design_mask), and what of it
  // the field latticed.
  std::size_t frozen_solid_voxels = 0;
  std::size_t latticed_voxels = 0;
  // Mass-equivalent voxels freed: sum over latticed voxels of (1 - rho). Multiply
  // by grid.voxel_volume() * material density to get grams — the GROSS prize, and
  // it is never the number that decides the feature.
  double freed_mass_voxels = 0.0;

  struct Region {
    int id = 0;
    std::string name;
    std::string mode;             // lattice_region_mode_name
    double declared_density = 0.0;
    std::size_t voxels = 0;       // frozen voxels the region owns
    std::size_t latticed = 0;     // ... the field actually latticed
    double mean_rho = 0.0;
    double freed_mass_voxels = 0.0;
    // The validity of the rho->stiffness law over THIS region, measured on the
    // FULLY SOLID part (an upper bound on any rung's cells-per-member).
    double member_width_median_mm = 0.0;
    double cells_per_member_median = 0.0;
    double cells_per_member_p10 = 0.0;
    double floor_certifiable = 0.0;
    double floor_buildable = 0.0;
    double fraction_above_floor = 0.0;
    bool in_validity_range = false;
    bool buildable_not_certifiable = false;
    bool refused = false;
    // ★ WHERE THIS REGION'S CELL CAME FROM, and what it cost. `cell_mode` is
    // "fixed" (the run's one cell) or "fit" (derived from this region's own
    // thickness, so the homogenisation floor is cleared by construction).
    // `fit_cell_mm` / `fit_min_density` are what a FIT would give, reported for
    // EVERY region so a refusal under a fixed cell can name the cell that would
    // have worked.
    std::string cell_mode;
    double cell_used_mm = 0.0;
    bool fit_feasible = false;
    double fit_cell_mm = 0.0;
    double fit_min_density = 0.0;
    // ★ The declared density had to be RAISED to print at the cell in force.
    // Reported, never silent: the user asked for one mass and got another.
    bool density_raised_to_print = false;
    std::string refusal;  // quotable, empty when in range
  };
  std::vector<Region> regions;
};

struct MinimizePlasticResult {
  // ★ The lattice density field's own receipt (task 2026-08-13-lattice-as-a-
  // material). `armed == false` on every run that did not declare one.
  FrozenLatticeReport frozen_lattice;

  // Every rung the driver actually ran, in ladder order: accepted rungs (each
  // margin >= margin_stop) — optionally interleaved with rungs that do NOT stop
  // the walk, namely INFEASIBLE ones (handoff 131), DISCONNECTED ones (handoff
  // 2026-07-23-gate-honesty-connectivity-rejection) and NON-CONVERGENT ones (handoff
  // 2026-07-27-nonconvergence-rejection) — followed by AT MOST ONE
  // rejected terminal rung (margin < margin_stop, or cancelled — see `cancelled`
  // below) at which the driver stopped. No rung after the terminal one is
  // evaluated. Only the TOO-WEAK verdict is monotone in the ladder direction, so
  // only it ends the walk; the other two are failures of one carve, and the next
  // (lighter) rung gets a fresh attempt from the last good design.
  std::vector<MinimizePlasticVariant> evaluated;
  // True iff a rung fell below margin_stop and the driver stopped early (so the
  // last `evaluated` entry is the rejected terminal rung). False iff the whole
  // ladder was accepted (every rung margin >= margin_stop) or the run was
  // cancelled (a cancel is not a margin stop).
  // Handoff 2026-07-23-gate-honesty-connectivity-rejection: this stays EXACTLY the
  // margin test — `margin_effective < margin_stop` — and it alone ends the walk, so
  // the ladder stops on precisely the rungs it stopped on before the belt existed.
  // A rung rejected ONLY by the CONNECTIVITY BELT does not set it and does not stop
  // the ladder (see `evaluated` above); a rung that fails BOTH tests still sets it
  // and still stops the walk, while its report line names the connectivity failure
  // as the reason. What the flag never means is "the belt fired": a severed rung's
  // margin is usually HUGE, so calling that a margin stop would misname it exactly
  // where the misnaming is most misleading.
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
  // WHICH LADDER RAN (task 2026-08-03-growth-ladder). false = REDUCTION: every
  // rung <= 1.0, the run removes plastic against the imported part and the
  // recommendation is the LIGHTEST rung that passes. true = GROWTH: every rung
  // > 1.0, the run adds plastic to reach the required margin and the
  // recommendation is the SMALLEST ADDITION that passes. It is the SAME walk
  // either way — the rungs descend, the first rung under margin_stop stops the
  // ladder, the last accepted rung is the recommendation — which is exactly why
  // growth needed no second optimizer. Recorded so a front-end names the mode it
  // ran instead of inferring it from the numbers (nothing about a run should be
  // guessable-only; see the handoff's G7).
  bool growth_ladder = false;
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

  // The pre-solve's own WALL, in milliseconds — the companion the iteration count
  // alone cannot supply. Handoff 2026-08-02-warm-start-coarse-experiment: the
  // whole point of the coarse cascade is that its iterations are ~1/8-DOF CHEAP,
  // so an iteration count is not a cost and a speedup claim priced in iterations
  // is the exact mistake handoff 2026-08-02-iteration-phase-timing measured on
  // the GenEO path. Charged as a SEPARATE line: a net win must be net OF this.
  // 0.0 when warm_start_coarse is off (its default). Measured on the same steady
  // clock as the per-iteration phase instrument, around the whole pre-solve
  // (coarsen + simp_optimize + prolong), so nothing about it is unattributed.
  double warm_start_coarse_ms = 0.0;

  // The pre-solve's OPERATOR APPLIES — the pre-solve's cost in the one unit
  // that is DETERMINISTIC and machine-independent. Handoff 2026-08-02-
  // iteration-phase-timing named `matvecs` the honest work unit when `cg_iters`
  // is not (the GenEO refresh runs N_t applies that move no CG counter), and it
  // has the further property that a contended host cannot change it. The wall
  // above is the number the maintainer feels; this is the number a second
  // machine can reproduce. Both are reported, neither alone. 0 when the feature
  // is off. Measured as the delta of the process-global fea_matvec_count()
  // across the whole pre-solve.
  long long warm_start_coarse_matvecs = 0;

  // The pre-solve's DOF-TOUCHES — matvecs WEIGHTED BY THE DOF COUNT OF THE GRID
  // EACH APPLY RAN ON. *** THIS IS THE PRIMARY COST UNIT, and raw matvecs above
  // must NOT be compared across the two resolutions. *** The whole point of the
  // cascade is that it works at res/2, where one operator apply touches ~1/8 the
  // DOFs of a fine one; adding a coarse apply to a fine apply as if they cost
  // the same is not an accounting error of degree but of kind. Weighting makes
  // the two levels commensurable, and it removes a bias that runs AGAINST the
  // pre-solve (an unweighted sum charges each cheap coarse apply at full fine
  // price). Deterministic and contention-immune, so unlike wall it is evidence
  // on a shared host.
  //
  // DEFINITION, stated so it can be re-derived: dof_touches = sum over applies
  // of 3*(nx+1)*(ny+1)*(nz+1) for that apply's grid — the full nodal DOF count
  // of the grid the solve ran on. (The reduced operator acts on the FREE DOFs, a
  // mask-dependent subset; the full nodal count is used because it is a property
  // of the grid alone and therefore reproducible from the run record.) Every
  // apply the counter sees within one solve is at that solve's own resolution:
  // fea_matvec_count() is bumped in MatfreeReduced::apply_kgg_raw, and a
  // V-cycle's coarse levels use Galerkin operators that do not route through it
  // (handoff 2026-08-02-iteration-phase-timing §1c). 0 when the feature is off.
  long long warm_start_coarse_dof_touches = 0;

  // The DOF count of the COARSE grid the pre-solve ran on, and of the FINE grid
  // the ladder ran on — both by the definition above. Recorded so a reader can
  // re-derive the weighting from the run record instead of trusting it, and so
  // the actual coarse/fine ratio is visible rather than assumed to be 8.
  long long warm_start_coarse_grid_dofs = 0;
  long long solved_grid_dofs = 0;

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

  // Handoff 2026-07-27-nonconvergence-rejection — RUNG-NON-CONVERGENCE outcome, one
  // entry per EVALUATED rung (same order and length as `evaluated`), ALWAYS filled
  // (like rung_infeasible): `rung_non_convergent[i]` is 1 iff rung i was rejected
  // because a linear solve did not converge (else 0), so all-zeros is the positive
  // statement "every rung's solves converged". `rung_non_convergent_iteration[i]` is
  // the CG iteration the failing solve reached and `rung_non_convergent_residual[i]`
  // the residual it stalled at (both 0 on a rung that converged) — the two numbers
  // the report and the run_info echo need to say HOW FAR the solve missed. Echoed
  // into run_info.json as `rung_non_convergent` / `_iteration` / `_residual`.
  std::vector<char> rung_non_convergent;
  std::vector<int> rung_non_convergent_iteration;
  std::vector<double> rung_non_convergent_residual;
  // Task 2026-08-03-preflight-feasibility-and-divergence (bar P6: THE GUARDS ARE
  // OBSERVABLE) — the per-rung outcome of the two DIVERGENCE guards, filled with
  // the same finalize-only discipline and always parallel to `evaluated`. Every
  // trip carries THE NUMBERS IT FIRED ON, so the next investigation of a stopped
  // run is a read of run_info.json rather than another instrumentation task.
  //   rung_diverged[i]              1 iff guard 2 ended rung i
  //   rung_diverged_iteration[i]    the 1-based iteration it fired on
  //   rung_diverged_c_ratio[i]      c[iter]/c[0] there
  //   rung_diverged_cg_ratio[i]     cg[iter] / the prefix-minimum CG count
  //   rung_diverged_wall_ratio[i]   wall[iter]/wall[0] — the separating column
  //   rung_time_budget[i]           1 iff guard 3 ended rung i
  //   rung_time_budget_iteration[i] the 1-based iteration it fired on
  //   rung_time_budget_ms[i]        the budget (100x iteration 1, floored)
  //   rung_time_budget_elapsed_ms[i]what that iteration actually spent
  //   rung_time_budget_baseline_ms[i] iteration 1 of that rung
  //   rung_time_budget_phase[i]     WHICH PHASE dominated ("cg", "mg_build", ...)
  //   rung_time_budget_phase_ms[i]  and how much of the iteration it was
  // All-zero / all-empty is the positive statement "no guard fired on any rung".
  std::vector<char> rung_diverged;
  std::vector<int> rung_diverged_iteration;
  std::vector<double> rung_diverged_c_ratio;
  std::vector<double> rung_diverged_cg_ratio;
  std::vector<double> rung_diverged_wall_ratio;
  std::vector<char> rung_time_budget;
  std::vector<int> rung_time_budget_iteration;
  std::vector<double> rung_time_budget_ms;
  std::vector<double> rung_time_budget_elapsed_ms;
  std::vector<double> rung_time_budget_baseline_ms;
  std::vector<std::string> rung_time_budget_phase;
  std::vector<double> rung_time_budget_phase_ms;

  // Handoff 2026-07-25-draft-quality — DRAFT QUALITY outcome, one entry per
  // EVALUATED rung (same order and length as `evaluated`), filled as each rung
  // finishes. EMPTY across the whole run when draft_quality is off (nothing was
  // measured), so a non-empty vector is itself the statement "this run ran draft".
  //   * draft_rung_tail_k[i]   — the DERIVED k: the count of rung i's TRAILING
  //     trajectory iterations whose adaptive CG tolerance had tightened to within
  //     one decade of the tight cg_tolerance. The measured length of the tightening
  //     tail (0 for a rung with no loose phase at all).
  //   * draft_rung_c_gap[i]    — the escalation SIGNAL: rung i's relative compliance
  //     gap |C_cert - C_traj| / C_cert between its final loose trajectory solve and
  //     its exact certified solve, measured on the DRAFT run (before any escalation
  //     replaced it).
  //   * draft_rung_escalated[i] — 1 iff that gap exceeded draft_escalation_c_gap and
  //     rung i was RE-RUN at tight tolerance from its own warm-start seed. When 1,
  //     evaluated[i].optimization is the TIGHT re-run, and this rung's trajectory CG
  //     cost includes BOTH passes (the honest, net-of-escalation accounting).
  //   * draft_rung_probe_flip[i] — Phase 2 DESIGN-SPACE signal: the fraction of rung
  //     i's loose-plateau solid voxels whose printed<->void classification changed
  //     under the one-shot tight probe (see draft_escalation_design_flip). -1 when
  //     the probe did not run (design trigger disarmed, or a cancelled/infeasible
  //     rung). This is the number the escalation decision is made on when the design
  //     trigger is armed; recorded even when armed only for measurement (a very high
  //     threshold measures the signal without firing).
  //   * draft_rung_probe_cg[i]  — the probe's summed CG iterations, the measured cost
  //     of the safety belt for rung i (D3: it must be a small fraction of the rung's
  //     own trajectory CG). 0 when the probe did not run.
  std::vector<int> draft_rung_tail_k;
  std::vector<double> draft_rung_c_gap;
  std::vector<char> draft_rung_escalated;
  std::vector<double> draft_rung_probe_flip;
  std::vector<long long> draft_rung_probe_cg;
  //   * draft_rung_probe_tightmove[i] — DIAGNOSTIC: the fraction of the plateau's
  //     solid voxels whose classification the tight probe iterate moves relative to
  //     the loose PLATEAU itself (flip(plateau, tight-step)). Distinct from
  //     draft_rung_probe_flip (loose-step vs tight-step). Near 0 means the plateau is
  //     already tight-stationary — a locally stable basin a from-the-plateau probe
  //     cannot escape. -1 when the probe did not run.
  std::vector<double> draft_rung_probe_tightmove;
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

// ---------------------------------------------------------------------------
// THE ONE design-domain resolution (task 2026-08-03-design-box-recertification).
//
// WHY IT EXISTS. A design box EXPANDS the voxel grid, and every node-indexed
// input — the mounting Dirichlet BCs, the declared external loads — is indexed
// to the ORIGINAL part grid, so it must be REMAPPED onto the expanded grid
// before anything is solved. minimize_plastic has always done that, inline. The
// latticed RE-CERTIFICATION (run_job) rebuilds the same load case a SECOND time
// and did NOT, which is why a design-box run refused to be latticed at all: two
// reconstructions that must agree, one of which was written on the assumption
// that the grid never expands.
//
// This is that derivation, ONCE. minimize_plastic calls it; run_job's lattice
// certification, its re-lattice entry point and its fixed-design analysis call
// it. There is no second implementation to drift from — which is the whole
// point, and the reason this lives in core rather than in the CLI.
//
// With no design box (`options.design_box` unset) every field is the caller's
// input verbatim (`expanded == false`, `mask` empty, offsets 0), so a no-box
// caller is byte-for-byte what it was before this existed.
struct SolvedDesignDomain {
  bool expanded = false;  // options.design_box was set
  VoxelGrid grid;         // the grid the run solves on (expanded, or the part's)
  DesignMask mask;        // the effective mask; EMPTY when !expanded
  // Voxel offset of the original part inside `grid` (0,0,0 when !expanded).
  int offset_i = 0, offset_j = 0, offset_k = 0;
  // Node-indexed inputs REMAPPED onto `grid` (verbatim copies when !expanded).
  std::vector<DirichletBC> bcs;
  std::vector<NodalLoad> external_loads;  // empty when the caller declared none
};

// Resolve the domain `minimize_plastic(part_grid, ..., options)` solves on.
// Performs the identical expand_design_domain call the driver makes (the
// caller's keep-outs, freeze flag and kDesignBoxCoarsenAlign), merges a caller
// anchor pad into the expanded mask under the same rule, and remaps `bcs` +
// `options.external_loads` through remap_node_to_domain.
//
// Throws std::invalid_argument on the same two design_mask conditions the
// driver rejects: a caller mask together with a design box when
// `freeze_imported_part` is set, and a mask whose size is not
// part_grid.voxel_count().
SolvedDesignDomain resolve_design_domain(const VoxelGrid& part_grid,
                                         const std::vector<DirichletBC>& bcs,
                                         const MinimizePlasticOptions& options);

// THE effective design mask `domain` is optimised under, before the mask-aware
// SIMP path applies its own Load/Fixture/Empty reclassification (effective_mask,
// simp.hpp). Composed in one place from the two things that build it:
//
//   * the BASE — `domain.mask` under a design box (expand_design_domain's
//     FrozenSolid part / FrozenVoid keep-out / Active design volume, with any
//     caller anchor pad already merged), else the caller's own `design_mask`,
//     else an all-Active mask;
//   * the "Keep clear" OVERLAY (`options.clearance_void`, handoff 100) OR'd on
//     top: each FrozenVoid entry forbids NEW growth into a declared clearance
//     region, EXCEPT where the base already pins the voxel FrozenSolid — the
//     imported part / anchor pad WINS (design 095 STEP 1c).
//
// EMPTY `clearance_void` (the default) => the overlay step is skipped and the
// result is the base verbatim, so a clearance-free caller is byte-identical to
// what it was before this existed (THE ONE RULE).
//
// It is public because `design_domain_loads` must void the same voxels this
// masks — a load that lands where the mask has removed the material is exactly
// the under-constrained system the M3.1 void-DOF gate refuses. Deriving both
// from ONE mask is what makes that impossible rather than merely unlikely.
//
// Throws std::invalid_argument if a no-box `options.design_mask` or a
// non-empty `options.clearance_void` is not sized `domain.grid.voxel_count()`.
DesignMask design_domain_mask(const SolvedDesignDomain& domain,
                              const MinimizePlasticOptions& options);

// THE load case that domain is solved under: the caller's declared external
// loads REMAPPED onto `domain.grid` when it declared any, else self-weight
// computed on `domain.grid` (which, expanded, covers the part plus the Active
// design envelope — exactly what the driver's ladder carries). ONE definition,
// so "the load the run certified under" is the same object at every site that
// has to reconstruct it.
//
// SELF-WEIGHT IS THE WEIGHT OF THE MATERIAL THAT IS THERE. `self_weight_loads`
// keys on the grid's TAGS, and `expand_design_domain` tags every in-box Active
// voxel `Interior` — so on the box path the raw grid weighs the whole growth
// region, including any part of it a keep-clear has removed. This function
// therefore weighs `domain.grid` MINUS every voxel `design_domain_mask` pins
// FrozenVoid, which is the same thing expand_design_domain already does for a
// keep-out box ("Tag Empty so it carries no FEA element and no self-weight").
// Without it, a design-box run whose clearance reaches into the growth region
// and which declares no load puts body force on DOFs the void gate then
// eliminates, and the solver refuses the run outright:
//
//     under-constrained system (load applied to a void DOF with no stiffness)
//
// The subtraction is EXACTLY the voided material's weight — g * rho * V per
// voxel — never an approximation or a scaling (test_selfweight_clearance_void,
// bar SW3). With no clearance nothing is voided and the result is bit-identical
// to `self_weight_loads(domain.grid, ...)`, the definition this replaced.
std::vector<NodalLoad> design_domain_loads(const SolvedDesignDomain& domain,
                                           const MinimizePlasticOptions& options,
                                           double material_density_g_cm3);

// Which voxels of `domain.grid` are the ORIGINAL part — 1 where the voxel maps
// back into `part_grid` and the part voxel there is not Empty, 0 elsewhere
// (i.e. 0 for every voxel the expansion ADDED). Size domain.grid.voxel_count().
// This is the envelope test for "material the optimizer grew OUTSIDE the part",
// which the lattice path must be able to name in order to treat it explicitly.
// With no design box every part-solid voxel is 1 and nothing was added.
std::vector<char> original_part_voxels(const VoxelGrid& part_grid,
                                       const SolvedDesignDomain& domain);

// ---------------------------------------------------------------------------
// PRE-FLIGHT LOAD-PATH CONNECTIVITY (task 2026-08-03-preflight-feasibility-and-
// divergence, guard 1).
//
// WHY IT EXISTS. A real job (worker 7fbc7ee2900e425a, 2026-08-02) ran TEN HOURS
// and completed three design iterations: 27 s, then 34 min, then 6.3 h, with the
// objective rising 1,689x in a single step. Ten hours to learn something a flood
// fill can answer in milliseconds — and the job was not a mistake. It carried a
// legitimate 70 mm axial bolt clearance, because a bolt you cannot get a driver
// onto is not a bolt hole.
//
// WHAT IT DECIDES. With the clearances frozen and the design domain resolved,
// and assuming the optimizer fills EVERYTHING it is allowed to fill, can the
// load-tagged voxels reach the anchor-tagged voxels at all? The "allowed" field
// is density 1 on every voxel `effective_design_mask` does NOT pin FrozenVoid,
// 0 elsewhere — the MAXIMAL structure this job could ever produce. The walk is
// the CONNECTIVITY BELT itself (voxel.hpp walk_load_path); there is one flood
// fill in the project and this reuses it rather than adding a second.
//
// WHAT IT DOES NOT DECIDE. Connectivity is NECESSARY, NOT SUFFICIENT. A
// connected but hopeless load path — one long thin thread through a bore — still
// diverges, and this check will pass it. So a caller may REFUSE only on
// `connected == false`, which is a provable statement about geometry: no field
// the optimizer can produce carries force from the load to the anchor, because
// the material it would need is forbidden. The marginality fields
// (`walk.narrowest_separator_*`) are INFORMATION for the operator, never grounds
// for a refusal — they are an upper bound on a cut, not a strength claim.
//
// It is READ-ONLY and runs no solve, so arming it cannot change a design.
struct PreflightLoadPath {
  bool ran = false;  // false only if a caller skipped it
  LoadPathWalk walk;
  // The allowed set the walk ran over, split by why a voxel is in it. The sum
  // allowed_frozen_solid + allowed_active == walk.printed_voxels.
  std::size_t allowed_frozen_solid = 0;  // always material (part, pad, BC skin)
  std::size_t allowed_active = 0;        // the optimizer MAY fill it
  std::size_t forbidden_voxels = 0;      // FrozenVoid: it may NEVER hold material
  double wall_ms = 0.0;  // measured, because "cheap" has to be a number (bar P4)
};

// Run the pre-flight on the domain `minimize_plastic` will solve. Uses
// `design_domain_mask(domain, options)` (the clearance overlay included) and
// `effective_design_mask` — the identical two calls the optimizer makes — so the
// allowed set is the optimizer's own, not a re-derivation of it.
//
// `connected` is true VACUOUSLY when the grid carries no Load or no Fixture
// voxels (a self-weight run tags no Load faces): `walk.decidable` is then false
// and a caller must not read a verdict into it.
PreflightLoadPath preflight_load_path(const SolvedDesignDomain& domain,
                                      const MinimizePlasticOptions& options);

}  // namespace topopt
