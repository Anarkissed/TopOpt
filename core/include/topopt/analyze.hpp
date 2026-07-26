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
//   infill_knockdown    — the multiplicative margin knockdown at the gate
//                         (infill_margin_knockdown of the job's infill; 1.0 solid).
//   load_path_ok        — the connectivity belt verdict on `density` (a severed
//                         design measures ~zero stress → an enormous, meaningless
//                         margin, so the gate rejects it however good it looks).
//   part_solid          — the printed_fraction denominator (grid.solid_count()).
//
// Throws whatever simp_compliance throws (bad BC/load index, non-physical params,
// CG non-convergence) and ReportError from compute_stress_margin.
FixedDesignAnalysis analyze_fixed_design(
    const VoxelGrid& grid, const SimpParams& params,
    const std::vector<double>& density, const std::vector<DirichletBC>& bcs,
    const std::vector<NodalLoad>& loads, const Material& material,
    const Vec3& build_dir, double cg_tolerance, int cg_max_iterations,
    SolverKind solver_kind, double margin_stop, double infill_knockdown,
    bool load_path_ok, double part_solid);

// The infill margin knockdown seed curve — effective/solid strength ~= f^1.5
// (Gibson-Ashby), f = infill_percent/100, pinned to EXACTLY 1.0 for f >= 1
// (solid/unset). Exposed here so the optimizer's ladder gate and a standalone
// re-analysis gate share ONE definition. (The maintainer tunes this curve; do NOT
// treat the exponent as final — see the definition.)
double infill_margin_knockdown(double infill_percent);

}  // namespace topopt

#endif  // TOPOPT_ANALYZE_HPP
