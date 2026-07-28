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
