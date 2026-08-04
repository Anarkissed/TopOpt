#ifndef TOPOPT_LATTICE_MATERIAL_HPP
#define TOPOPT_LATTICE_MATERIAL_HPP

// THE MULTISCALE LATTICE MATERIAL MODEL C(rho) — the constitutive curve that lets
// the OPTIMIZER know a lattice is coming (task multiscale-lattice-to).
//
// WHY THIS EXISTS. SIMP's E(rho) = rho^p * E0 penalises intermediate density because
// a 40%-dense blob of plastic is not a thing you can print. A 40%-dense LATTICE is,
// and the homogenized library (lattice.hpp) carries its MEASURED cubic tensor. Under
// the two-step pipeline the optimizer never knew that: it optimized assuming solid
// material with p = 3 driving density to the extremes, and the lattice pass afterwards
// found only tendrils too thin to hold the cells-per-member floor, so 99–100% of every
// lattice region fell back to SOLID (the maintainer's M2_verticalStand run:
// 0 / 82 / 472 latticed voxels out of ~10,500). Post-processing cannot fix that. The
// design has to be optimized KNOWING the interior will be lattice — which means the
// SIMP loop's material law has to be this curve instead of rho^p.
//
// THE CONSTRUCTION (prototyped and measured by handoff
// 2026-07-31-multiscale-lattice-feasibility; this is that model promoted to
// production, reading its rows from lattice_resolved_rows rather than a transcript).
// Three regimes, per topology, per component (C11, C12, C44):
//
//   void    rho in [0, rho_lo)   cubic Hermite from the ZERO tensor (value 0 AND
//                                slope 0 at rho = 0) to the fitted tensor at the band
//                                floor, matching value and slope there.
//   lattice rho in [rho_lo, hi]  an origin-anchored polynomial through the MEASURED
//                                resolved rows: C(rho) = sum_k a_k rho^k, k = 1..n,
//                                weighted least squares in RELATIVE error (a 40 MPa
//                                row counts as much as a 3800 MPa one). n = 4 when
//                                the topology has >= 6 resolved rows, else 3 — a
//                                FIXED rule, stated before measuring.
//   solid   rho in (rho_hi, 1]   quadratic from the fitted tensor at the band ceiling
//                                (matching value AND slope) to the EXACT isotropic
//                                solid triplet at rho = 1: C11 = c(1-nu), C12 = c nu,
//                                C44 = E/2(1+nu), c = E/((1+nu)(1-2nu)) — the triplet
//                                hex8_stiffness_cubic reduces to isotropic.
//
// So the optimizer can REACH 0 and 1, and the curve is C1 everywhere on (0, 1) with
// the measured physics carried inside the band. The band endpoints are READ FROM CORE
// (lattice_rho_min / lattice_rho_max), never hardcoded. The explicit lower bridge is
// not decoration: simply extending the fit below rho_lo goes INADMISSIBLE for kelvin
// (C11 - |C12| reaches -0.29) and rhombic (C44 < 0).
//
// MEASURED ACCURACY (the probe's bars, all seven cubic topologies): worst row error
// 3.1%, worst leave-one-out 6.5% — both inside the library's own +-10% resolution
// caveat, which this model inherits and does not shrink. Sensitivities agree with
// central differences to 9.6e-9 away from the two C1 joints. Every point of [0, 1] is
// cubic-admissible AND has a PSD derivative, so stiffness is monotone in rho and the
// compliance sensitivity is one-signed.
//
// THE FEASIBLE SET IS NOT ALL OF [0, 1]. A printable, certifiable voxel is void,
// in-band lattice, or solid: {0} u [rho_lo, rho_hi] u {1}. The two gaps are real —
// the density filter's transition ring GUARANTEES a nonzero gap population (96.5–100%
// of parked gap voxels sit on a void<->band or band<->solid ramp), so no in-loop
// strategy zeroes them. They are closed by PROJECTION at termination
// (lattice_project_density), which the probe measured at +0.13–0.18% volume for
// -0.4–0.5% compliance, and whose volume cost this library CHARGES and REPORTS rather
// than absorbing.
//
// SCOPE — READ THIS BEFORE USING A NON-OCTET TOPOLOGY. Only OCTET is fit to steer a
// design loop today. The other six certifiable topologies have 4–7 resolved rows
// ending at rho ~0.5–0.6, so their upper gap is a 0.41–0.50-wide interval the model
// spans by pure interpolation with a 3.9–5.2x stiffness swing across it — an optimizer
// pushing a stress concentration toward solid would traverse ~40 points of unmeasured
// territory. bcc (5 rows) and rhombic (4) additionally sit below the probe's model-order
// cliff, where the C12 DERIVATIVE reaches ~35% error. build_lattice_material_model
// builds them anyway (the curve is well-defined and its bars pass), but
// lattice_material_model_trustworthy() reports false for them and the production
// arming refuses them; they need roughly 8–11 more measured rows each at the dense end
// first. octet's own gaps are 0.050 / 0.100 wide with a 1.36x C11 jump.

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"

namespace topopt {

// C(rho) = sum_{k=1..nterms} a[k-1] * rho^k — anchored at C(0) = 0 exactly.
inline constexpr int kLatticeFitMaxTerms = 4;
struct LatticePolyFit {
  int nterms = 0;
  double a[kLatticeFitMaxTerms] = {0, 0, 0, 0};
};

// The three-regime tensor-valued material curve for ONE topology at ONE (Es, nu).
// Build with build_lattice_material_model; evaluate with value() / derivative().
// Copyable and self-contained (no pointer back into the library), so a caller may
// hold it by value for the life of a run.
struct LatticeMaterialModel {
  LatticeTopology topo = LatticeTopology::Octet;
  double Es = 0.0, nu = 0.0;
  double scale = 1.0;                  // Es / lattice_library_youngs_modulus()
  double rho_lo = 0.0, rho_hi = 0.0;   // band endpoints READ FROM CORE
  std::size_t rows = 0;                // resolved rows the fit ran through
  LatticePolyFit fit[3];               // C11, C12, C44 (library-basis MPa)
  double solid[3] = {0, 0, 0};         // exact isotropic triplet at rho = 1 (at Es)
  double v_lo[3] = {0, 0, 0}, d_lo[3] = {0, 0, 0};  // lower-joint value/slope (at Es)
  double v_hi[3] = {0, 0, 0}, d_hi[3] = {0, 0, 0};  // upper-joint value/slope (at Es)

  // The homogenized cubic tensor at relative density `rho`, and its exact
  // derivative dC/drho. `rho` outside [0, 1] is treated as the nearer endpoint
  // (the optimizer's own clamp is upstream; this is a safety net, not a policy).
  // Throws std::invalid_argument on a non-finite rho.
  CubicTensor value(double rho) const;
  CubicTensor derivative(double rho) const;

  // One evaluation of all three components and/or their rho-derivatives.
  // `c` and `d` may each be null; both null is a no-op.
  void eval(double rho, double* c, double* d) const;
};

// Build the model for `topo` at solid modulus `Es` (MPa) and Poisson ratio `nu`.
// Rows come from lattice_resolved_rows (CORE — never a transcript), scaled by
// Es/library-Es exactly as lattice_cubic_tensor scales them. Throws
// std::invalid_argument for a non-physical Es/nu, and LatticeTopologyNotCertifiable
// for a topology the library carries no validated cubic rows for — the same refusal
// lattice_cubic_tensor gives, for the same reason (there is nothing to fit).
LatticeMaterialModel build_lattice_material_model(LatticeTopology topo, double Es,
                                                  double nu);

// Whether `topo`'s measured table is adequate to STEER A DESIGN LOOP on — not merely
// to certify a fixed design against. False for the six analysis-only topologies (see
// the SCOPE note above): their upper gap is too wide to optimize across and/or their
// row count sits below the model-order cliff. `reason` (optional) receives a
// one-sentence, quotable explanation when the answer is false, empty when true.
// This is a REPORTING predicate — build_lattice_material_model does not consult it;
// the production arming does.
bool lattice_material_model_trustworthy(LatticeTopology topo,
                                        std::string* reason = nullptr);

// THE PRINTED-SET THRESHOLD a MULTISCALE design must be read at.
//
// Under classic SIMP, density is penalised toward 0/1, so "is there material here"
// and "is this voxel more than half full" are the same question and the M3.5 iso of
// 0.5 answers both. Under the lattice material law they come apart: a converged
// multiscale voxel at density 0.30 is not a half-empty solid voxel, it is a real,
// printable, MEASURED 30%-dense lattice cell whose stiffness the optimizer's
// objective was evaluated at. Reading such a design at 0.5 would delete every
// in-band voxel below it — material the optimizer placed, the certification solved
// with, and the lattice pass exists to build — which is exactly the loop/export
// disagreement the two-step pipeline failed on.
//
// So the threshold is HALF THE BAND FLOOR: strictly below every certifiable lattice
// density (so no in-band voxel is ever thresholded away) and strictly above zero (so
// a projected void voxel, which is exactly 0.0, is still void). After the
// feasible-set projection nothing lies strictly between 0 and rho_lo, so any value
// in (0, rho_lo) picks out the same set; half the floor is the middle of that
// interval and is not a knife edge. It is derived, never a free knob — a caller
// cannot set it to something that would silently reinterpret a design.
double multiscale_printed_iso(LatticeTopology topo);

// ── the feasible set and its projection ────────────────────────────────────────
// A printable, certifiable relative density is void, in-band, or solid:
//     {0} u [rho_lo, rho_hi] u {1}
// `void_below` / `solid_above` are the occupancy classifiers the receipts use
// (a density within them of the endpoint IS that endpoint).

// Which class `rho` falls in.
enum class LatticeDensityClass { Void, LowerGap, Band, UpperGap, Solid };
LatticeDensityClass lattice_density_class(const LatticeMaterialModel& m, double rho,
                                          double void_below, double solid_above);

// The NEAREST feasible density to `rho` — the projection the design is snapped
// through at termination. Ties (exactly mid-gap) resolve DOWNWARD, the lighter
// choice, deterministically. Values already feasible are returned unchanged, so
// projecting a feasible field is the identity.
double lattice_project_density(const LatticeMaterialModel& m, double rho,
                               double void_below, double solid_above);

// What one projection pass did to a field — the CHARGE, reported rather than
// absorbed (task item 3). Volumes are in voxel-fraction units (sum of density over
// the design voxels), so `volume_delta / volume_before` is the relative volume the
// projection added or removed.
struct LatticeProjectionReport {
  std::size_t voxels_considered = 0;  // design voxels the projection ran over
  std::size_t projected_lower = 0;    // were in the LOWER gap
  std::size_t projected_upper = 0;    // were in the UPPER gap
  std::size_t snapped_to_void = 0;
  std::size_t snapped_to_band_lo = 0;
  std::size_t snapped_to_band_hi = 0;
  std::size_t snapped_to_solid = 0;
  double volume_before = 0.0;         // sum of density before
  double volume_after = 0.0;          // sum of density after
  double volume_delta = 0.0;          // after - before (signed)
  double max_density_move = 0.0;      // largest single-voxel |delta|
  // The VOLUME-CONSTRAINT violation this projection caused, as a fraction of the
  // target: (achieved_after - target) / target over the counted voxels. Set by
  // lattice_project_field when a target is supplied (negative when the projection
  // came in UNDER target). This is the number the receipt must carry — the
  // constraint was satisfied by the optimizer and then broken by the projection,
  // and pretending otherwise would hide a real (small) infeasibility.
  double volume_fraction_before = 0.0;
  double volume_fraction_after = 0.0;
  double volume_fraction_target = 0.0;
  double volume_constraint_violation = 0.0;
};

// Project every voxel of `density` where `mask` is non-zero (or every voxel when
// `mask` is null) onto the feasible set, in place, and report the charge.
// `n_counted` is the voxel count the achieved volume fraction is taken over
// (0 => the number of masked voxels); `target_fraction` <= 0 leaves the
// volume_constraint_violation fields at 0. Deterministic; no allocation beyond the
// report. Throws std::invalid_argument on a mask/density size mismatch.
LatticeProjectionReport lattice_project_field(const LatticeMaterialModel& m,
                                              std::vector<double>& density,
                                              const std::vector<char>* mask,
                                              double void_below, double solid_above,
                                              double n_counted,
                                              double target_fraction);

}  // namespace topopt

#endif  // TOPOPT_LATTICE_MATERIAL_HPP
