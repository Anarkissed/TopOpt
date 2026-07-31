#ifndef TOPOPT_STRUT_STRENGTH_HPP
#define TOPOPT_STRUT_STRENGTH_HPP

// De-homogenized octet strut-strength REPORT (task 2026-07-31-lattice-strut-
// strength-report). REPORT ONLY — nothing here feeds the acceptance gate;
// `lattice_accepted` keeps meaning exactly what it meant before this file existed.
//
// PR 259 (handoff 2026-07-31-lattice-dehomogenization-probe) measured the map from
// a latticed voxel's MACRO stress tensor to the peak stress in its struts:
//
//   peak strut von Mises   <= K_dev(rho)·vm(Sigma) + K_vol(rho)·|p(Sigma)|
//   peak strut layer-normal <= K_il_dev(rho)·vm(Sigma) + K_il_vol(rho)·|p(Sigma)|
//                              (build direction on a lattice cube axis)
//
// The two-invariant form is not decoration: hydrostatic macro stress carries ZERO
// macro von Mises while octet struts still load (measured — biaxial states already
// show 2x the deviatoric worst case), so any scalar K·vm law is unboundedly wrong.
// The bound is rigorous within the model (cubic eigenspace split + von Mises
// subadditivity, probe selfcheck S6), with K_dev the EXACT worst case over all
// deviatoric states (a per-voxel 5x5 generalized eigenproblem, not sampled).
//
// The table in strut_strength.cpp is the probe's fitted law — the `*_cert` columns
// of evidence/2026-07-31-lattice-dehomogenization-probe/kfit.csv VERBATIM: per rho,
// the ENVELOPE over the bulk (periodic interior), free-surface and CUT-cell strut
// populations (cut cells run 43-79% hotter and double their interlayer
// amplification; a bulk-only law would be optimistic exactly where parts fail).
// OCTET ONLY — no other topology has a measured strut law; the evaluator refuses
// them rather than borrow octet's numbers.
//
// CARRIED CAVEATS (report them, do not hide them):
//   * The peak is a voxelized joint peak and grows ~log with micro resolution
//     (+10-18% per 32->48 step where measured); rows quote the finest measured vpc
//     and the band-floor row is a still-rising LOWER bound.
//   * The law is valid where homogenization is: members spanning >= the
//     cells-per-member floor (lattice_cells_per_member_min). Below it the macro
//     stress these bounds amplify is itself out of regime — the caller must SAY so
//     (bar L4), not print the numbers as though they were trustworthy.
//   * Interlayer MARGINS divide by the material z_knockdown, whose provenance is
//     UNSOURCED (assumed 0.55 for FDM; PR 259 showed the verdict turns on it).
//     The BOUNDS in MPa are z_knockdown-free geometry and survive re-sourcing —
//     that split is deliberate; preserve it when reporting.

#include <cstddef>
#include <vector>

#include "topopt/mesh.hpp"  // Vec3

namespace topopt {

// The rho span the measured law covers (first/last kfit row). Queries outside it
// are CLAMPED to the endpoint row and COUNTED (StrutStrengthReport::
// rho_clamped_voxels) — never silently extrapolated: K rises steeply toward low
// rho (K_dev 124 at rho 0.048) and an extrapolated K is exactly how a wrong
// number would look plausible (bar L5).
double strut_law_rho_min();
double strut_law_rho_max();

// One rho's interpolated law coefficients (the kfit `*_cert` envelope columns),
// piecewise-linear in rho, clamped to the span above. `clamped` (optional) is set
// true iff rho fell outside the span. Exposed for tests and future callers; the
// field evaluator below is the production entry point.
struct StrutLawK {
  double Kd = 0.0;    // strut vm per unit macro vm (deviatoric worst case)
  double Kv = 0.0;    // strut vm per unit macro |pressure|
  double Kild = 0.0;  // strut layer-normal per unit macro vm (deviatoric worst)
  double Kilv = 0.0;  // strut layer-normal per unit macro |pressure|
};
StrutLawK strut_law_at(double rho, bool* clamped = nullptr);

// The per-field strut-strength report. All stresses MPa; margins are safety
// factors (larger is safer), +infinity when the corresponding bound is zero
// (nothing loads the struts in that mode).
struct StrutStrengthReport {
  bool evaluated = false;  // true iff the law applied to >= 1 latticed voxel

  // --- the RATIOS' numerators: bounds in MPa, z_knockdown- and yield-free ------
  // These are (measured geometry) x (this solve's macro field) and survive any
  // re-sourcing of z_knockdown or yield — report them SEPARATELY from margins.
  double vm_bound_max_mpa = 0.0;  // max over latticed voxels of Kd·vm + Kv·|p|
  double il_bound_max_mpa = 0.0;  // max of the build-direction-resolved
                                  // layer-normal bound (see il_cross_term below)
  double max_macro_vm_mpa = 0.0;  // max lattice macro (effective) von Mises
  // Amplification ratios bound/macro (0 when max_macro_vm is 0).
  double amplification_vm = 0.0;  // vm_bound_max / max_macro_vm
  double amplification_il = 0.0;  // il_bound_max / max_macro_vm

  // --- the MARGINS (divide by yield; interlayer additionally by z_knockdown) ---
  double margin_in_plane = 0.0;    // yield / vm_bound_max
  double margin_interlayer = 0.0;  // (z_knockdown·yield) / il_bound_max
  double margin_worst_case = 0.0;  // min of the two
  double z_knockdown_used = 0.0;   // the UNSOURCED constant the interlayer margin
                                   // divided by — named so the receipt can say so

  // --- argmax voxels: where each bound peaks, with its macro invariants --------
  std::size_t vm_argmax_voxel = 0;  // grid index of the in-plane worst voxel
  double vm_argmax_rho = 0.0;
  double vm_argmax_macro_vm_mpa = 0.0;
  double vm_argmax_macro_pressure_mpa = 0.0;  // signed p = tr(Sigma)/3
  std::size_t il_argmax_voxel = 0;  // grid index of the interlayer worst voxel
  double il_argmax_rho = 0.0;
  double il_argmax_macro_vm_mpa = 0.0;
  double il_argmax_macro_pressure_mpa = 0.0;

  // --- honesty accounting ------------------------------------------------------
  std::size_t lattice_voxels = 0;      // latticed voxels evaluated
  std::size_t rho_clamped_voxels = 0;  // rho outside [strut_law_rho_min, _max]:
                                       // clamped to the endpoint row and COUNTED
                                       // (bar L5), never extrapolated
  // Build-direction resolution of the interlayer bound. The measured law is for a
  // build direction ON a lattice cube axis (x, y and z are the same law — cubic
  // symmetry, pinned by the probe's uni_x/uni_z instrument check). For an off-axis
  // build direction n the strut layer-normal stress picks up strut SHEAR
  // components the axis law does not see; those are rigorously bounded by the
  // strut von Mises bound via |sigma_ab| <= vm/sqrt(3), giving
  //   il_bound(n) = [Kild·vm + Kilv·|p|]
  //              + (2/sqrt(3))·(|nx·ny| + |ny·nz| + |nz·nx|)·[Kd·vm + Kv·|p|].
  // On a cube axis the cross factor is 0 and this reduces EXACTLY to the probe's
  // J6 recipe; off-axis it is conservative (the honest direction for a report).
  double il_cross_factor = 0.0;        // (2/sqrt(3))·(|nx ny|+|ny nz|+|nz nx|)
  bool build_dir_on_lattice_axis = false;  // cross factor == 0 (within 1e-9)
};

// Evaluate the measured octet strut-strength law over one solved macro stress
// field. REPORT ONLY — callers must not gate on the result (bar L1).
//
//   stress_tensor_field — flattened grid-indexed (6·n), Voigt [xx,yy,zz,xy,yz,zx],
//                         TRUE shear, MPa — FixedDesignAnalysis::stress_tensor_field.
//                         The full TENSOR is required: the law needs vm AND
//                         pressure (a scalar von Mises field cannot evaluate it).
//   lattice_mask        — size n; mask[e] != 0 marks voxel e latticed. Only masked
//                         voxels are evaluated.
//   relative_density    — size n; the lattice's local rho at masked voxels (the
//                         same field the certification tensor used).
//   build_dir           — the build-plate normal the interlayer bound resolves
//                         against. AN EXPLICIT PARAMETER, deliberately not read
//                         from any global/options state (bar L8): an orientation
//                         scorer must be able to call this N times with N build
//                         directions against ONE solved field (the way PR 247's
//                         probe swept orientation cheaply). Need not be unit
//                         (normalized internally); must be nonzero and finite.
//   yield_strength_mpa  — the solid material yield the margins divide into.
//   z_knockdown         — the interlayer knockdown the interlayer margin divides
//                         by (UNSOURCED; recorded in the report by name).
//
// Deterministic, single pass, no allocation beyond the report. Throws
// std::invalid_argument on size mismatch, a zero/non-finite build_dir, or a
// non-positive yield/z_knockdown.
StrutStrengthReport evaluate_strut_strength(
    const std::vector<double>& stress_tensor_field,
    const std::vector<char>& lattice_mask,
    const std::vector<double>& relative_density, const Vec3& build_dir,
    double yield_strength_mpa, double z_knockdown);

}  // namespace topopt

#endif  // TOPOPT_STRUT_STRENGTH_HPP
