#pragma once

#include <atomic>
#include <cstddef>
#include <functional>
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

// Inputs that shape one minimize_plastic run (beyond the part, material, BCs
// and rule table passed to minimize_plastic()).
struct MinimizePlasticOptions {
  // The volume-fraction ladder to walk, in the order given. Must be non-empty,
  // every entry in (0, 1], and STRICTLY DESCENDING (heaviest/strongest first).
  std::vector<double> volume_fraction_ladder{0.7, 0.5, 0.3};
  // Stop at the first rung whose worst-case stress margin is < margin_stop.
  // Must be finite and >= 0 (0 disables the margin stop: the whole ladder runs).
  double margin_stop = 1.5;
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
  // the driver — use the two fields below instead.
  SimpOptions simp;

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
  // (c) Support-volume proxy (M4.3 support_overhang_voxels) for the analysed
  // build direction (report.orientation), evaluated over THIS variant's printed
  // geometry (voxels with density > 0.5): the count of printed voxels that would
  // need support material. Spacing-aware volume = value * grid.voxel_volume().
  int support_volume_voxels = 0;
  // (d) Printed mass in grams = material density (g/cm^3) * printed volume,
  // spacing-aware: (# printed voxels) * grid.voxel_volume() (mm^3) / 1000.
  double mass_grams = 0.0;

  // (b) The extracted + cleaned variant isosurface, exposed for display. It is
  // ALREADY computed by check_v3 (stored in `v3.mesh`); this accessor exposes it
  // without recomputing marching cubes or copying the mesh. Empty for a
  // cancelled rung (its `v3` is default-constructed).
  const TriangleMesh& mesh() const { return v3.mesh; }
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
  // True iff options.cancel was observed during a rung's optimization (M7.0a).
  // The cancelled rung is the last `evaluated` entry, rejected, with
  // optimization.cancelled true; its per-rung analysis (v3, report line, and
  // the M7.0b visualization fields von_mises_field / support_volume_voxels /
  // mass_grams / mesh()) is NOT computed — a cancel aborts the run, so the
  // stress solve, V3 suite and settings for the half-optimized rung are skipped
  // and those fields stay default-constructed. The accepted prefix and the
  // assembled `report` are complete and valid as usual.
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
