#ifndef TOPOPT_LATTICE_DENSITY_FIELD_HPP
#define TOPOPT_LATTICE_DENSITY_FIELD_HPP

// THE LATTICE DENSITY FIELD OVER A FROZEN REGION (task
// 2026-08-13-lattice-as-a-material).
//
// ── WHAT WAS WRONG, IN FOUR FIELDS ──────────────────────────────────────────
// A frozen region — a face protection, an anchor pad, a BC skin — is, to the
// optimiser today:
//
//   FEA stiffness   FULL SOLID          must be: the homogenised lattice at f
//   mass            FULL SOLID          must be: f x solid
//   volume budget   OUTSIDE it          must be: INSIDE it
//   sensitivity     zero                unchanged: zero (Mode 1) / beta-only (Mode 2)
//
// On the maintainer's M2_verticalStand run that region is 40,216 voxels — 45.5%
// of the printed mass, 247.3 g of 543.7 g. At relative density 0.30 the same
// envelope weighs 173.1 g. That is the GROSS prize; the NET one is smaller,
// because `frozen_buttress_probe` measured wall peak vM at 7.98 FROZEN against
// 20.56 ACTIVE with 94% of everything the optimiser places landing within 5 mm of
// the wall — so latticing the wall removes stiffness exactly where the structure
// leans hardest and the optimiser MUST put material back nearby. That is what
// makes this a coupled decision rather than a post-process, and it is why the
// number that decides the feature is the NET saving after the loop, never the
// gross.
//
// ── A FIXED DENSITY IS A CONSTANT DENSITY FIELD ─────────────────────────────
// Two requests meet here and they are one mechanism. A DECLARED region carrying
// a user-chosen density, and an OPTIMISER-CHOSEN graded density field, differ
// only in where the coefficients come from. This file builds the field; the
// constant is its validated special case, so the material law is written once.
//
//   MODE 1  DECLARED   t is constant over the region: t = f, the user's number.
//   MODE 2  OPTIMISED  t(x) = sum_j beta_j psi_j(x) on its OWN knot lattice,
//                      beta joining the MMA design vector alongside the density.
//
// The representation and its prior art: Deng & To, "Projection-based Implicit
// Modeling Method (PIMM) for Functionally Graded Lattice Optimization",
// arXiv 2008.07487 / JOM 73:2012-2021 (2021), DOI 10.1007/s11837-021-04659-1 —
// a second global-RBF field whose coefficients are the design variables, knots
// decoupled from the FE mesh, a projection to an ersatz density, chain-rule
// sensitivities and MMA. The basis here is the SAME basis phi already uses
// (plsm_basis.hpp), on a COARSER lattice, because a density grades more smoothly
// than a boundary does. PIMM meshes the real lattice and takes no homogenisation
// shortcut, which is more honest and puts the whole cost on the state solve — the
// one binding cost on this machine (PR 324: 99.5% of an iteration). We keep the
// homogenised operator and the re-fitted law instead, and say so.
//
// ── ★ THIS IS NOT SIMP AND MUST NOT BECOME SIMP ─────────────────────────────
// The region is NEVER a per-voxel design variable. In Mode 1 its sensitivity is
// zero; in Mode 2 the only design variables it adds are the beta coefficients.
// If a per-voxel density variable ever appears over a frozen region, that is the
// line being crossed.
//
// ── ★ THE PER-VOXEL DENSITY CONTRACT IS PRESERVED (bar R6) ──────────────────
// A latticed frozen voxel's DESIGN density stays 1.0: the lattice cell fills the
// voxel's envelope, and the pore space is a property of the MATERIAL, not of the
// occupancy. The relative density travels in a SECOND grid-indexed field —
// exactly the (mask, relative_density) pair `LatticePosture` (analyze.hpp) has
// carried since lattice certification Phase 1. So the printed-set threshold, the
// load-path walk, min-feature, the frozen/protect masks, the clearances and the
// octet grading law all still read one density per voxel and all still get the
// answer they got before. Nothing here lowers `printed_iso`.
//
// ── ★ C0 INERTNESS: f = 1.0 IS SOLID, BY DISPATCH (bar R1) ──────────────────
// A lattice at relative density 1.0 has no pore space; it IS solid material.
// `resolve_lattice_density_field` therefore emits NO latticed voxel for a region
// at f >= kLatticeSolidAt, and the run is byte-identical to one that never
// declared the region. This is a definition, not a shortcut — but it is worth
// knowing that the alternative would also have been correct to machine
// precision: LatticeMaterialModel::value(1.0) returns the EXACT isotropic solid
// triplet (C11 = c(1-nu), C12 = c nu, C44 = E/2(1+nu)) and the cubic element
// built from it agrees with hex8_stiffness to 8.5e-16 (PR 252). "Byte-identical"
// and "identical to machine precision" are different claims and only the first
// one is a bar, so the dispatch is what ships and the agreement is measured
// beside it (evidence/2026-08-13-lattice-as-a-material/r1_c0_inertness).
//
// ── ★ THE LAW IS THE MEASURED FIT, NEVER GIBSON-ASHBY ───────────────────────
// The optimiser never sees a raw f^1.5 or any asymptotic law. Stiffness comes
// from `LatticeMaterialModel` (lattice_material.hpp), which is fitted to the
// library's own MEASURED resolved rows — 19 of them for octet — not to an
// exponent. `lattice-phase0` M2 measured the Gibson-Ashby gap on this library at
// 23-52% with a fitted exponent near 2.0, OVER-PREDICTING stiffness; that gap is
// the reason the asymptotic law is not used, and it is not inherited here.
//
// What IS inherited is the library's +-10% resolution caveat and its scale
// separation requirement. `lattice-phase0` M3 measured scale separation marginal
// at ~1.9 cells across a member; core's own `lattice_cells_per_member_min` is 5,
// and the literature's rule for homogenisation accuracy is a macro/micro ratio of
// 5-6 — the same number arrived at independently. So the validity range of the
// law is stated in CELLS PER MEMBER and reported PER REGION (bar R5), and a
// region below the floor is REFUSED rather than approved with a footnote.

#include <cstddef>
#include <string>
#include <vector>

#include "topopt/lattice.hpp"
#include "topopt/lattice_material.hpp"
#include "topopt/plsm_basis.hpp"
#include "topopt/voxel.hpp"

namespace topopt {

// A relative density at or above this IS solid: no pore space, no lattice, no
// latticed voxel emitted. Exactly 1.0 — not an epsilon band — so the C0 bar is a
// statement about the number the caller passed and not about a tolerance.
inline constexpr double kLatticeSolidAt = 1.0;

// ── the declaration ─────────────────────────────────────────────────────────

enum class LatticeRegionMode {
  Solid,      // the region stays fully dense — today, exactly
  Declared,   // MODE 1: a constant density field at `declared_density`
  Optimised,  // MODE 2: t(x) = sum_j beta_j psi_j(x), beta a design variable
};

// ── ★ WHERE THE REGION'S CELL COMES FROM ────────────────────────────────────
//
// ★ THIS IS THE DIFFERENCE BETWEEN A FEATURE THAT REFUSES AND ONE THAT WORKS.
//
// The cells-per-member floor is not a property of the region — it is a property
// of the region AND the cell. A 6.8 mm wall cannot hold 5 cells at a 2 mm cell
// and holds them comfortably at a 1.3 mm one. An earlier cut of this task took
// ONE cell for the whole run and REFUSED every region that could not hold it,
// which threw away regions that were perfectly latticeable at a cell derived
// from their own thickness.
//
// `lattice_derive_cell_for_member` (lattice.hpp) has answered this since PR 302:
// given a member width and the user's nozzle it returns the admissible (cell,
// density) window, both ends. The COARSEST end — exactly N* cells across, at the
// lightest density whose strut still prints there — is the minimum-mass
// CERTIFIED lattice for that member, and it clears the homogenisation floor BY
// CONSTRUCTION rather than by luck.
enum class LatticeRegionCellMode {
  // Use the run's single `frozen_lattice_cell_mm`. The region is REFUSED if it
  // cannot hold N* cells at that cell. Honest, and usually the wrong question.
  Fixed,
  // ★ DERIVE the cell from THIS REGION'S OWN measured thickness, so it clears
  // the floor by construction. The density floor comes with it: the lightest
  // that still prints at the derived cell, at the user's own stated width.
  Fit,
};

const char* lattice_region_cell_mode_name(LatticeRegionCellMode m);

const char* lattice_region_mode_name(LatticeRegionMode m);

// One declared region of the frozen set. `voxels` is not stored here — the
// grid-indexed `region_id` map below says which voxels belong — so a region is a
// POLICY, cheap to copy and to enumerate in an assignment table.
struct LatticeRegionSpec {
  int id = 0;                // 1-based, matching `region_id` entries
  std::string name;          // provenance, for the receipt ("face-protection 16")
  LatticeRegionMode mode = LatticeRegionMode::Solid;

  // MODE 1's f. Clamped into the topology's certifiable band before use unless it
  // is >= kLatticeSolidAt, which means SOLID and emits nothing.
  double declared_density = kLatticeSolidAt;

  // MODE 2's bounds on the resolved density. Defaults (0) take the topology's own
  // band [lattice_rho_min, lattice_rho_max]. A caller may narrow, never widen:
  // `resolve_lattice_density_field` intersects with the band.
  double optimised_rho_min = 0.0;
  double optimised_rho_max = 0.0;

  // Where this region's cell comes from. `Fixed` (the default) is the run's one
  // cell and is the conservative reading; `Fit` derives it from the region's own
  // thickness so the homogenisation floor is cleared by construction.
  LatticeRegionCellMode cell_mode = LatticeRegionCellMode::Fixed;
};

// ── the beta field (MODE 2) ─────────────────────────────────────────────────
//
// The same basis family phi uses, on its OWN knot lattice. Density grades more
// smoothly than a boundary, so a COARSER lattice than phi's is expected and is
// what the default rule below produces.
struct LatticeBetaField {
  PlsmKnotLattice lattice;
  PlsmBasisKind basis = PlsmBasisKind::Gaussian;
  double support = 2.0;
  std::vector<double> beta;  // size lattice.count()
  // The monotone map t -> rho: rho = lo + (hi - lo) * H(t), H the smooth
  // Heaviside below. `steepness` is H's slope parameter in t-units.
  double steepness = 1.0;
  std::size_t count() const { return lattice.count(); }
};

// The smooth Heaviside the t -> rho map goes through, and its derivative.
// H(t) = 1 / (1 + exp(-t/s)) — monotone, C-infinity, H(0) = 0.5, so beta = 0
// seeds the MIDDLE of the admissible band rather than an endpoint.
double lattice_density_heaviside(double t, double steepness);
double lattice_density_heaviside_deriv(double t, double steepness);

// Knot spacing, VOXELS, PER AXIS. Three numbers, never one — this file takes no
// minimum and no maximum over the axes anywhere, for the reason
// `gridap-alpha-rule-breaks-on-slabs` records: his grid is a 4:1 slab and a rule
// that reads the thin axis sizes a length for a part that does not exist. It is
// deliberately NOT `PlsmKnots` (plsm.hpp), because that header pulls in the
// solver and this one is in the dependency-free base library.
struct LatticeBetaKnots {
  double dx = 0.0, dy = 0.0, dz = 0.0;
};

// The DEFAULT knot spacing for the beta field, given the grid and the spacing phi
// uses (all three zero when there is no phi — a SIMP run). The rule, stated
// before it was measured: FOUR TIMES phi's spacing on every axis. A density
// grades more smoothly than a boundary does, so the beta lattice is COARSER than
// phi's by construction, and four is the factor that makes the coefficient block
// small enough to be free (§3e) while still resolving a gradient across his
// 5 mm protection collar.
LatticeBetaKnots lattice_beta_knots_for_grid(const VoxelGrid& grid,
                                             double phi_dx, double phi_dy,
                                             double phi_dz);

// ── validity: cells per member, PER REGION (bar R5) ─────────────────────────

struct LatticeRegionValidity {
  int id = 0;
  std::string name;
  std::size_t voxels = 0;

  // The region's own member width, in mm: the MEDIAN of local_member_thickness_mm
  // over the region's voxels. Median and not minimum, because one voxel at a
  // feather edge is not what the homogenisation regime turns on; the minimum is
  // reported beside it so a caller can see the tail.
  double member_width_median_mm = 0.0;
  double member_width_min_mm = 0.0;
  double member_width_p10_mm = 0.0;

  double cell_mm = 0.0;
  // member_width / cell, at the median and at the 10th percentile.
  double cells_per_member_median = 0.0;
  double cells_per_member_p10 = 0.0;
  // The floors this is judged against.
  double floor_certifiable = 0.0;  // lattice_cells_per_member_min
  double floor_buildable = 0.0;    // lattice_percolation_cells_per_member_min

  // The verdict. `in_validity_range` is the bar B4 test: the median cells per
  // member clears the CERTIFIABLE floor. `buildable_not_certifiable` names the
  // genuinely different middle case rather than collapsing it into a refusal.
  bool in_validity_range = false;
  bool buildable_not_certifiable = false;
  // The fraction of the region's voxels whose own member clears the floor.
  double fraction_above_floor = 0.0;

  // The thinnest member that could clear the floor at this nozzle, at ANY (cell,
  // density) pair in the band — the number a user acts on when refused.
  double min_member_width_certifiable_mm = 0.0;

  // ── ★ THE FITTED CELL: what this region could hold if the cell were derived
  // from ITS OWN thickness rather than taken from the run (see
  // LatticeRegionCellMode). Populated whether or not the region asked for it, so
  // a REFUSAL under a fixed cell can name the cell that would have worked
  // instead of just saying no.
  //
  // `fit_cell_mm` is the COARSEST admissible cell — exactly N* cells across the
  // member — and `fit_min_density` is the lightest density whose strut still
  // prints there at the user's own stated width. Together they are the
  // MINIMUM-MASS CERTIFIED lattice for this member. Both 0 when no (cell,
  // density) pair in the band fits the member at this nozzle, which is the one
  // case a finer cell cannot rescue.
  bool fit_feasible = false;
  double fit_cell_mm = 0.0;
  double fit_min_density = 0.0;
  double fit_strut_diameter_mm = 0.0;

  // ★ THE SECOND, INDEPENDENT BAR: PRINTABILITY. Homogenisation asks whether the
  // member is thick enough for the law; this asks whether the STRUT comes out of
  // the nozzle at all. They bind from opposite directions — a coarser cell helps
  // printability and hurts homogenisation — so a region can clear one and miss
  // the other, and a report that merged them would hide which.
  //
  // `lightest_printable_density` is `lattice_min_density_for_strut` at this cell
  // and nozzle: NEGATIVE when no density in the band prints there. A declared
  // density below it is REFUSED, never clamped up — clamping would silently
  // print a heavier lattice than the user asked for and report the lighter one.
  double lightest_printable_density = 0.0;
  // One quotable sentence, empty when `in_validity_range`.
  std::string refusal;
};

// Does `rho` print at `cell_mm` through a `min_extrudable_width_mm` nozzle? The
// exact test `lattice_region_validity` applies, exposed so a caller building an
// assignment table refuses the same cells this does. Throws the same
// std::invalid_argument `octet_strut_diameter_mm` throws on a non-positive cell.
bool lattice_density_printable(LatticeTopology topo, double rho, double cell_mm,
                               double min_extrudable_width_mm);

// Measure `region_id`'s regions against the homogenisation floor on a FIXED
// design. `member_width_mm` is `local_member_thickness_mm(grid, density, iso, cap)`
// — passed in rather than recomputed, because the caller already has it and the
// EDT is not free. `cell_mm` is the lattice cell the assignment uses.
//
// Throws std::invalid_argument on a size mismatch or a non-positive cell.
std::vector<LatticeRegionValidity> lattice_region_validity(
    const VoxelGrid& grid, const std::vector<int>& region_id,
    const std::vector<LatticeRegionSpec>& regions,
    const std::vector<double>& member_width_mm, LatticeTopology topo,
    double cell_mm, double min_extrudable_width_mm);

// ── the resolved field ──────────────────────────────────────────────────────

struct ResolvedLatticeDensityField {
  // grid-indexed. `mask[e] != 0` iff voxel e is a LATTICED frozen voxel; `rho[e]`
  // is its relative density there and is left at 0 elsewhere. Together these are
  // exactly the (mask, relative_density) pair LatticePosture consumes, so the
  // certification path needs no second contract.
  std::vector<char> mask;
  std::vector<double> rho;
  // ★ THE PER-VOXEL CELL (mm), for a region whose cell was FITTED to its own
  // thickness. Empty when every emitting region used the run's single cell —
  // then the caller passes its scalar and nothing downstream changes. When
  // non-empty it is exactly `LatticePosture::cell_size_field`, the SWEPT posture
  // that has existed since 2026-08-01-lattice-cell-size-sweep, so the
  // certification's cells-per-member guard asks each voxel about ITS OWN cell
  // instead of one number for the whole part — which is the honest question for a
  // part whose regions were fitted separately.
  std::vector<double> cell_mm;

  std::size_t latticed_voxels = 0;
  // Mass-equivalent voxels the field FREES: sum over latticed voxels of (1 - rho).
  // This is the gross prize, in voxel units, and it is what the volume budget
  // moves by.
  double freed_mass_voxels = 0.0;
  // Per region, in `regions` order.
  std::vector<std::size_t> region_latticed_voxels;
  std::vector<double> region_freed_mass_voxels;
  std::vector<double> region_mean_rho;

  // Regions refused because they are outside the law's validity range, by id.
  std::vector<int> refused_region_ids;
  // Per region, in `regions` order: the cell actually used, and whether the
  // declared density had to be RAISED to print at it. A raise is reported, never
  // silent — the user asked for a mass and got a different one.
  std::vector<double> region_cell_mm;
  std::vector<char> region_density_raised;

  bool empty() const { return latticed_voxels == 0; }
};

// Resolve the declaration into the two grid-indexed fields.
//
//   * a region in mode Solid, or Declared with f >= kLatticeSolidAt, emits
//     NOTHING — no mask bit, no rho — so the run is byte-identical (bar R1);
//   * a Declared region emits its constant f, clamped into the topology's band;
//   * an Optimised region evaluates t = sum_j beta_j psi_j at each of ITS voxels
//     and maps it through the monotone Heaviside into [rho_lo, rho_hi];
//   * a region whose id appears in `refused` emits NOTHING and is listed in
//     `refused_region_ids` — a refusal is a refusal, not a clamp.
//
// `only_where` (optional, grid-indexed) restricts emission to voxels the caller
// holds FROZEN — pass the effective mask's FrozenSolid set. A voxel outside it is
// silently skipped, because a density field over a voxel the optimiser can move is
// a different feature and must not appear by accident.
//
// Throws std::invalid_argument on a size mismatch, a duplicate region id, a
// non-finite declared density, or a beta field whose coefficient count disagrees
// with its lattice.
// `validity` (optional, parallel to `regions`) carries the FITTED cell and its
// density floor from `lattice_region_validity`. It is REQUIRED for any region in
// cell mode Fit — a fitted region with nothing to fit to is a declaration error,
// not a fallback to the run's cell — and ignored for the rest. When supplied, a
// Declared density below the fitted cell's printable floor is RAISED to it and
// the raise is reported (`region_density_raised`), because a fitted cell changes
// which densities print and silently emitting an unprintable strut is the one
// outcome a mass feature must not have.
ResolvedLatticeDensityField resolve_lattice_density_field(
    const VoxelGrid& grid, const std::vector<int>& region_id,
    const std::vector<LatticeRegionSpec>& regions, LatticeTopology topo,
    const LatticeBetaField* beta, const std::vector<char>* only_where,
    const std::vector<int>& refused,
    const std::vector<LatticeRegionValidity>* validity = nullptr);

// d rho_e / d beta_j for every latticed voxel of an Optimised region, as a sparse
// matrix in the same CSR shape `plsm_build_A` produces (rows = voxels of the grid,
// cols = beta coefficients). Rows for voxels that are not in an Optimised region
// are EMPTY, so a chain rule over the whole grid picks up exactly the coupled
// voxels. This is the only derivative Mode 2 needs beyond dc/drho, which
// simp_compliance already produces.
PlsmCsr lattice_beta_jacobian(const VoxelGrid& grid,
                              const std::vector<int>& region_id,
                              const std::vector<LatticeRegionSpec>& regions,
                              LatticeTopology topo, const LatticeBetaField& beta,
                              const std::vector<char>* only_where,
                              const std::vector<int>& refused, int threads);

// ★ THE CHAIN RULE, and the whole of what Mode 2 adds to a gradient. For any
// grid-indexed physical sensitivity dF/drho_e, the beta-space gradient is
//
//     dF/dbeta_j = sum_e (dF/drho_e) * J[e][j]        (J = lattice_beta_jacobian)
//
// i.e. J^T applied to the per-voxel field. Two callers, one function:
//
//   * the OBJECTIVE — pass `SimpCompliance::dcompliance`. On a voxel overridden
//     by the field, simp_compliance's entry is already dc/d(LATTICE relative
//     density) rather than dc/d(design density), so no rescaling belongs here.
//   * the VOLUME BUDGET — pass ones. A latticed voxel costs `rho` of a solid one,
//     so d(mass)/d(beta) is exactly J^T(1) in voxel units, which is the same units
//     `freed_mass_voxels` reports.
//
// Rows of J outside an Optimised region are empty, so a whole-grid field may be
// passed unmasked: uncoupled voxels contribute nothing by construction rather
// than by the caller remembering to zero them. Result size = J.cols, zero-filled.
//
// Throws std::invalid_argument if `dF_drho` is not J.rows long.
std::vector<double> lattice_beta_chain(const PlsmCsr& jacobian,
                                       const std::vector<double>& dF_drho);

}  // namespace topopt

#endif  // TOPOPT_LATTICE_DENSITY_FIELD_HPP
