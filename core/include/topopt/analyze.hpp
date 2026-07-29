#ifndef TOPOPT_ANALYZE_HPP
#define TOPOPT_ANALYZE_HPP

// analyze_fixed_design — ONE FEA analysis solve on a FIXED design, no
// optimization (handoff 2026-07-26-constrained-smooth).
//
// This is the "receipt" engine the constrained-smoothing feature needs: hand it
// a fixed density field (a converged optimizer rung, or the voxelization of an
// edited/smoothed mesh) and it recovers the physics and gates it exactly as the
// optimizer's per-rung certification does — a single penalized elastic solve, the
// per-voxel stress/displacement fields, printed mass, support proxy, worst-case
// stress margin, the §7 V3 suite, and the acceptance verdict. It NEVER runs an
// optimization iteration.
//
// SINGLE SOURCE OF TRUTH. minimize_plastic's per-rung recovery/certification block
// (minimize_plastic.cpp, "Final penalized solve on the converged density ...")
// calls THIS function, so the numbers a run reports and the numbers a standalone
// re-analysis reports are produced by the same code. Handed a variant's OWN
// converged density (plus the same grid/BCs/loads/params/solver), the outputs are
// bit-identical to that variant's report/fields — the correctness bar this entry
// point is measured against (test_analyze_fixed_design).

#include <cstddef>
#include <vector>

#include "topopt/fea.hpp"        // DirichletBC, NodalLoad
#include "topopt/materials.hpp"  // Material
#include "topopt/mesh.hpp"       // Vec3
#include "topopt/report.hpp"     // StressMargin
#include "topopt/simp.hpp"       // SimpParams, SolverKind
#include "topopt/voxel.hpp"      // VoxelGrid, V3Report

namespace topopt {

// How the acceptance gate knocks the worst-case stress margin down for a sparse
// print (handoff 2026-07-26-width-aware-knockdown). Bundles the two postures so a
// single analyze_fixed_design signature serves both, and so a caller cannot forget
// the width fields when it arms the width-aware path.
//
//   infill_knockdown  — the scalar f^1.5 (infill_margin_knockdown of the job's
//                       infill). This is the WHOLE gate in the default posture
//                       (`margin.worst_case * infill_knockdown`), and it also stays
//                       the interlayer-term knockdown in the width-aware posture
//                       (walls are credited only in-plane — 191/192 measured axial
//                       and bending, never z-bonding — so the interlayer failure
//                       mode is never made less conservative than today).
//   width_aware       — arm the SHELL+CORE composite. false (the default) → the gate
//                       is exactly the scalar path above (byte-identical).
//   infill_percent    — the job infill (percent) for the per-voxel core term.
//   wall_thickness_mm — t = outer + (wall_loops - 1)·inner, the solid perimeter ring
//                       width the slicer wraps around each member (one OUTER line width
//                       + the remaining inner loops at the INNER line width — what
//                       Bambu/Orca actually deposit). A mirror-inner outer collapses
//                       this to loops·inner. 0 → f_wall = 0 → the composite reduces to
//                       f^1.5 even when armed. Built once in knockdown_spec_for.
struct KnockdownSpec {
  double infill_knockdown = 1.0;
  bool width_aware = false;
  double infill_percent = 100.0;
  double wall_thickness_mm = 0.0;
};

// The certification outputs of one fixed-design analysis. Field-for-field the
// subset of MinimizePlasticVariant that the recovery block fills (von_mises_field,
// stress_tensor_field, displacement_field, mass_grams, support_volume_voxels,
// margin, v3, accepted) plus the intermediate scalars the report line consumes.
struct FixedDesignAnalysis {
  // Per-voxel von Mises stress over the PRINTED material (density > iso),
  // grid-indexed (grid.voxel_count()), MPa; zero off the printed set.
  std::vector<double> von_mises_field;
  // Per-voxel Cauchy stress tensor, flattened grid-indexed (6*voxel_count),
  // Voigt [xx,yy,zz,xy,yz,zx], TRUE shear, MPa; zero off the printed set.
  std::vector<double> stress_tensor_field;
  // Per-node displacement of the same solve, DOF-ordered (3*fea_node_count(grid)),
  // mm; zero on nodes attached only to non-printed voxels.
  std::vector<double> displacement_field;
  double mass_grams = 0.0;
  int support_volume_voxels = 0;
  std::size_t printed_voxels = 0;
  double printed_fraction = 0.0;  // printed_voxels / part_solid (0 if part_solid==0)
  double max_von_mises = 0.0;
  double max_interlayer_tension = 0.0;
  StressMargin margin;  // SOLID margin (the reported/displayed value)
  V3Report v3;          // §7 V3 suite on the fixed density (min-feature count, mesh, ...)
  // The acceptance gate, on the INFILL-ADJUSTED margin (the optimizer's ladder
  // gate uses the same two facts): margin_effective = margin.worst_case *
  // infill_knockdown; accepted = load_path_ok && (margin_effective >= margin_stop).
  double margin_effective = 0.0;
  bool accepted = false;
  // Handoff 2026-07-27-nonconvergence-rejection — true iff the CERTIFICATION solve
  // (simp_compliance at the tight cg_tolerance) did NOT converge. When set, every
  // field above is default/empty (the analysis never ran) and `accepted` is FALSE:
  // a design whose certification solve the CG cannot resolve is NEVER certified. The
  // caller (minimize_plastic) rejects that rung with kRungNonConvergentReason rather
  // than letting the solve's throw destroy the whole run. `non_convergent_iteration`
  // / `non_convergent_residual` are the failing solve's last CG readings (0 when it
  // converged). The certification solve is NOT softened or retried — the tolerance
  // is unchanged; this flag only records that it missed.
  bool non_convergent = false;
  int non_convergent_iteration = 0;
  double non_convergent_residual = 0.0;
};

// Run one certification analysis of `density` on `grid`.
//
//   grid, params        — the solved grid and SIMP params (E, nu, penalty) the
//                         solve runs with.
//   density             — the FIXED design field, size grid.voxel_count(); a
//                         printed voxel is density > 0.5. A re-voxelized mesh
//                         passes a binary field (1.0 solid / 0.0 void).
//   bcs, loads          — the boundary conditions and nodal loads for the solve.
//   material            — yield/z_knockdown/density for margin + mass.
//   build_dir           — build-plate normal (unit) for interlayer tension + support.
//   cg_tolerance, cg_max_iterations, solver_kind
//                       — the certification solve config. To reproduce a run's
//                         numbers bit-for-bit, pass that run's cert tolerance,
//                         max-iterations and SolverKind.
//   margin_stop         — the acceptance threshold.
//   knockdown           — the margin knockdown posture (KnockdownSpec): the scalar
//                         f^1.5 in the default posture, or the width-aware SHELL+CORE
//                         composite when armed. The stored/displayed margin stays the
//                         SOLID margin; the knockdown scales ONLY what the gate tests.
//   load_path_ok        — the connectivity belt verdict on `density` (a severed
//                         design measures ~zero stress → an enormous, meaningless
//                         margin, so the gate rejects it however good it looks).
//   part_solid          — the printed_fraction denominator (grid.solid_count()).
//
// Throws whatever simp_compliance throws for a MALFORMED problem (bad BC/load
// index, non-physical params) and ReportError from compute_stress_margin. A CG
// NON-CONVERGENCE (SolverNonConvergence) of the certification solve is NOT thrown:
// it is caught and reported via FixedDesignAnalysis::non_convergent with accepted
// forced false (handoff 2026-07-27-nonconvergence-rejection), so a run's
// certification of one hard-to-solve variant cannot abort the whole run.
FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, const KnockdownSpec& knockdown,
    bool load_path_ok, double part_solid);

// The infill margin knockdown seed curve — effective/solid strength ~= f^1.5
// (Gibson-Ashby), f = infill_percent/100, pinned to EXACTLY 1.0 for f >= 1
// (solid/unset). Exposed here so the optimizer's ladder gate and a standalone
// re-analysis gate share ONE definition. (The maintainer tunes this curve; do NOT
// treat the exponent as final — see the definition.)
double infill_margin_knockdown(double infill_percent);

// The solid-wall AREA FRACTION of a square W×W member cross-section wrapped by a
// solid perimeter ring of thickness t: f_wall = 4·t·(W-t)/W² (191/192's φ_wall).
// Degenerate-safe (handoff 2026-07-26-width-aware-knockdown, bar K5):
//   * member_width_mm <= 0 or non-finite (an "unbounded"/thick sentinel) → 0 (a
//     region too thick to be a member gets NO wall rescue — the conservative choice);
//   * wall_thickness_mm <= 0 (no walls) → 0;
//   * a ring thicker than the half-width (t > W/2, i.e. a member thinner than the
//     wall stack) is clamped to t = W/2 → f_wall = 1 (the member is all wall = solid).
// Always in [0, 1]; never divides by zero.
double wall_area_fraction(double member_width_mm, double wall_thickness_mm);

// The WIDTH-AWARE infill knockdown — the SHELL+CORE Voigt composite 191/192
// measured and validated to ~1-3 % (handoff 2026-07-26-width-aware-knockdown):
//   E_eff/E_solid = f_wall + (1 - f_wall)·infill_margin_knockdown(infill_percent)
// with f_wall = wall_area_fraction(member_width_mm, wall_thickness_mm). The core
// term REUSES infill_margin_knockdown so the Gibson-Ashby f^1.5 curve has ONE
// definition. Reduces EXACTLY to infill_margin_knockdown when there is no wall ring
// (t = 0 or W unbounded), and to 1.0 for solid infill. Never exceeds 1.0 and never
// divides by zero. This is the ONE definition of the width-aware law: the per-voxel
// gate calls it per element on the local member width, and the reproduction test
// (bar K3) calls it directly against 191/192's member table.
double width_aware_knockdown(double infill_percent, double member_width_mm,
                             double wall_thickness_mm);

}  // namespace topopt

#endif  // TOPOPT_ANALYZE_HPP
