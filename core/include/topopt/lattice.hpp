#ifndef TOPOPT_LATTICE_HPP
#define TOPOPT_LATTICE_HPP

// Lattice effective-material library (lattice certification Phase 1, handoff
// 2026-07-27-lattice-certification).
//
// This is the PRODUCTION-side lookup of the homogenized cubic stiffness tensors
// that PR 198's OFFLINE library (core/tests/harness/lattice_homog_probe.cpp,
// handoff 2026-07-26-lattice-homog-phase0) measured under periodic boundary
// conditions and wrote to evidence/2026-07-26-lattice-homog-phase0/
// tensor_library.csv. Phase 1 does NOT re-derive the physics — it embeds those
// measured numbers verbatim and interpolates them, so the macro solver can carry a
// latticed element's real (anisotropic, cubic) effective stiffness instead of a
// solid modulus with a scalar knockdown bolted on afterwards.
//
// SCOPE: OCTET ONLY (this task). Schwarz-D, gyroid and the rest attach to the same
// machinery later; the enum leaves room for them but only Octet is populated.
//
// ANISOTROPY IS REAL: PR 198 measured octet's Zener ratio at 1.22 (C44 vs the
// isotropic (C11-C12)/2), so the three constants C11, C12, C44 are genuinely
// independent and a scalar knockdown would misrepresent shear. That is the whole
// reason this returns a tensor.
//
// ±10% CAVEAT (carry it, do not hide it): PR 198's HR study found octet's struts
// had NOT fully converged even at vpc48 (11% drift 32->48), so octet's ABSOLUTE
// magnitudes carry ~±10% resolution uncertainty, and the low-density rows are the
// least reliable. A margin quoted to three digits on a ±10% material property is
// false precision — see the handoff.

namespace topopt {

// A cubic-symmetric stiffness tensor, three independent constants, Voigt order
// [xx,yy,zz,gxy,gyz,gzx] with engineering shear (the hex8_stiffness_cubic contract).
// Units: MPa (already scaled to the caller's solid modulus).
struct CubicTensor {
  double C11 = 0.0;
  double C12 = 0.0;
  double C44 = 0.0;
};

enum class LatticeTopology { Octet };

const char* lattice_topology_name(LatticeTopology topo);

// The relative-density range over which the embedded library is trustworthy — the
// RESOLVED rows of PR 198's octet sweep (wall >= 4 voxels at vpc48). Below the min
// the struts alias badly (the under-resolved rows PR 198 flagged and excluded from
// its fits); above the max the part is nearly solid. A query outside [min, max] is
// CLAMPED to the endpoint and `rho_clamped` is set true so the caller can flag it.
double lattice_rho_min(LatticeTopology topo);
double lattice_rho_max(LatticeTopology topo);

// ★ THE CELLS-PER-MEMBER FLOOR — the minimum number of lattice cells that must span
// a structural member for the homogenized cubic tensor to describe it, i.e. for the
// scale separation homogenization assumes to hold. Read this; do NOT hardcode it —
// the grading law (grading.hpp) clamps cell size against it via the local member
// width, so when the measurement moves this the law picks it up.
//
// TRIPWIRE — MEASURED, and being re-measured. Value = 5.0, the BENDING ceiling of
// handoff 2026-07-28-graded-cell-size-phase0 (C2b): the homogenized macro model's
// transverse-stiffness error crosses the 2.4% band BETWEEN 4 and 5 cells across a
// member "as deployed" (1c +48.5%, 2c +8.5%, 3c +4.1%, 4c +2.59%, 5c +1.78%).
// Bending is the BINDING case — the generous axial ceiling is ~1 cell (C2), but a
// member that only carries axial load is the exception, so the law uses the bending
// number. If the re-measurement (a running task) moves the crossing, change the
// number HERE, in the one place, and re-run the grading unit tests: the assertion
// that no emitted point sits below the floor (bar L2) is what catches a stale value.
double lattice_cells_per_member_min(LatticeTopology topo);

// The printed octet strut DIAMETER (mm) at relative density `rho` and cell edge
// `cell_size_mm`. For the printability CHECK of the grading law (bar L3 / requirement
// 3) — NOT the certification math (that is the tensor above; diameter never enters a
// solve). Backed by PR 235's B3 measurement (evidence/2026-07-28-graded-cell-size-
// phase0/b3_printability.csv): the diameter is EXACTLY linear in cell size (d at
// cell 8 = 2·d at cell 4 to four digits, because the octet occupancy pattern is
// scale-invariant — the same fact that makes the tensor scale-invariant), so
// d(rho, S) = S · phi(rho) with phi the measured diameter-per-unit-cell, piecewise-
// linearly interpolated in rho and clamped at the ends of the measured span
// (rho 0.05..0.60, which brackets the certifiable band). Monotonic increasing in rho
// and in cell size. Throws std::invalid_argument if cell_size_mm is not > 0 or rho
// is not finite and >= 0.
//
// TRIPWIRE — the numbers are the vpc48 B3 rows, verbatim. They carry the octet
// ±quantization the handoff logs; a diameter quoted to microns is false precision.
double octet_strut_diameter_mm(double rho, double cell_size_mm);

// The homogenized effective cubic tensor of `topo` at relative density `rho`, scaled
// to solid Young's modulus `youngs_modulus_solid` (the library is measured at PLA
// Es = 3500 MPa and effective stiffness is exactly linear in Es, so this multiplies
// by Es/3500). `rho` is piecewise-linearly interpolated between the measured resolved
// rows and clamped to [lattice_rho_min, lattice_rho_max]; if it was clamped and
// `rho_clamped` is non-null, *rho_clamped is set true. Throws std::invalid_argument
// if `youngs_modulus_solid` is not > 0. The returned tensor is guaranteed
// positive-definite (every measured row is), so it is a valid hex8_stiffness_cubic
// input.
CubicTensor lattice_cubic_tensor(LatticeTopology topo, double rho,
                                 double youngs_modulus_solid,
                                 bool* rho_clamped = nullptr);

}  // namespace topopt

#endif  // TOPOPT_LATTICE_HPP
