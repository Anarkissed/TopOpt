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
// SCOPE: the SEVEN CUBIC strut topologies (octet-legs, sc, bcc, fcc, diamond, kelvin,
// rhombic) carry a validated tensor; handoff 2026-07-29-tensor-library-nine widened
// this from octet-only by re-running PR 198's homogenization over the strut-lattice
// family. The three "z-privileged" family members (bccz, fccz, reentrant) are
// TETRAGONAL and are deliberately NOT populated — a cubic tensor cannot represent
// them, so they are generate-but-not-certify (see lattice_topology_certifiable). TPMS
// sheets (Schwarz-D, gyroid) attach to the same machinery later.
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

#include <stdexcept>
#include <string>
#include <vector>

namespace topopt {

// A cubic-symmetric stiffness tensor, three independent constants, Voigt order
// [xx,yy,zz,gxy,gyz,gzx] with engineering shear (the hex8_stiffness_cubic contract).
// Units: MPa (already scaled to the caller's solid modulus).
struct CubicTensor {
  double C11 = 0.0;
  double C12 = 0.0;
  double C44 = 0.0;
};

// The strut-lattice topologies of the generation family (PR 219). The homogenized
// cubic-tensor library (this task, 2026-07-29-tensor-library-nine) covers the ones
// whose effective stiffness is genuinely CUBIC — for those a single (C11,C12,C44)
// tensor is exact and lattice_topology_certifiable() is true. The three "z-privileged"
// variants (Bccz, Fccz, Reentrant) add vertical struts / an auxetic waist on ONE axis,
// which makes the effective tensor TETRAGONAL (C33 != C11): a cubic tensor structurally
// cannot represent them, so they are GENERATE-but-NOT-CERTIFY — certifiable() is false
// and lattice_cubic_tensor() REFUSES them (bar B3). Octet is UNCHANGED and its rows are
// byte-identical to the shipped library. NOTE (carried, see the handoff): the shipped
// "octet" tensor was measured on LEGS-ONLY geometry (fc<->corner, no octahedral braces)
// — geometrically identical to Fcc — while the production generator meshes the full
// octet; that pre-existing labelling gap is documented, not silently changed here.
enum class LatticeTopology {
  Octet,        // shipped rows (legs-only fc<->corner geometry); cubic; UNCHANGED
  SimpleCubic,  // "sc"      — cubic, extreme low shear (Zener << 1)
  Bcc,          // "bcc"     — cubic, bending-dominated (Zener >> 1)
  Fcc,          // "fcc"     — cubic (== the shipped octet-legs geometry)
  Diamond,      // "diamond" — cubic
  Kelvin,       // "kelvin"  — cubic (truncated octahedron / BCC Voronoi)
  Rhombic,      // "rhombic" — cubic (rhombic dodecahedron / FCC Voronoi)
  Bccz,         // "bccz"    — TETRAGONAL (z columns): generate-but-NOT-certify
  Fccz,         // "fccz"    — TETRAGONAL (z columns): generate-but-NOT-certify
  Reentrant,    // "reentrant" — TETRAGONAL/auxetic (z waist): generate-but-NOT-certify
};

const char* lattice_topology_name(LatticeTopology topo);

// True iff the homogenized library carries a validated CUBIC tensor for `topo` (the
// cubic-symmetric, resolution-converged topologies). False for the tetragonal
// variants and any topology with no validated rows — for those lattice_cubic_tensor
// THROWS rather than certify against a wrong-symmetry or default tensor (bar B3).
bool lattice_topology_certifiable(LatticeTopology topo);

// The names of the certifiable topologies, in enum order — the single source the app
// bridge mirrors so its UI set can never drift from the core library.
std::vector<std::string> lattice_certifiable_topology_names();

// The relative-density range over which the embedded library is trustworthy, PER
// TOPOLOGY — derived from that topology's own RESOLVED rows (the contiguous validated
// block), so each topology reports its own band. Octet's band was widened to
// ~0.05..0.90 by PR 237 (evidence/2026-07-28-density-band-extension): its LOW end is
// vpc128 converged truth and its HIGH end vpc48 validated vs vpc64, each within ±2.4%
// of periodic-homogenization truth; the eight other topologies keep the ~0.15..0.60
// bands their sweeps validated. Below the min the struts alias badly; above the max
// the part is nearly solid. A query outside [min, max] is CLAMPED to the endpoint and
// `rho_clamped` is set true so the caller can flag it.
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

// ★ THE OTHER FLOOR, AND IT IS NOT THE ONE ABOVE. The minimum cells across a member
// for the strut network to PERCOLATE — to be connected geometry at all. Measured for
// octet in the same study as the accuracy floor (0.5 cells is DISCONNECTED, 1 cell is
// connected at +2.36 % axial error), so it returns 1.0.
//
// WHY BOTH EXIST. They answer different questions and have different remedies:
//   * lattice_cells_per_member_min (5) protects the CERTIFICATE. Below it the
//     homogenized tensor stops describing the member, so the margin is not
//     trustworthy — but the part still prints.
//   * this one (1) protects the OBJECT. Below it there is no connected strut network
//     to print, and what comes out of the generator is debris.
// A member between them is BUILDABLE AND UNCERTIFIABLE. That is the regime sub-floor
// retention exists for; it is emphatically NOT the same as un-latticeable, and a
// pipeline that refuses both with one message is collapsing two verdicts that need
// different answers.
//
// See the definition for its measurement conditions (rho ~= 0.199, AXIAL, octet only)
// — they do not cover the top of the band or bending, and this must not be quoted
// unconditionally.
double lattice_percolation_cells_per_member_min(LatticeTopology topo);

// ★ THE SUB-FLOOR RETENTION STRESS FRACTION — the ceiling on a REGION's macro stress,
// as a fraction of the PART's peak von Mises, under which the grading law is permitted
// to keep a below-the-floor voxel as lattice instead of falling back to solid
// (handoff 2026-08-04-subfloor-lattice-unloaded-regions, bar S1/S5). Read this; do NOT
// hardcode it.
//
// IT DOES NOT RELAX A GATE. Nothing in this codebase ever REFUSED a sub-floor lattice:
// the floor above is a CANDIDATE FILTER inside grade_lattice, and `analyze_fixed_design`
// only RAISES `lattice_strut_out_of_regime`, a reported flag. This number conditions
// that filter. It is DISARMED by default; a job opts in explicitly
// (GradingLawParams::retain_subfloor_in_unloaded_regions).
//
// WHERE 0.20 COMES FROM — measured, not chosen. Handoff 2026-08-04-protect-freeze-vs-
// solidity §10 (`item8_subfloor_floor.txt`) swept a 4 mm flange latticed at 1.33 cells
// per member across six stations of a cantilever and recorded how far the CERTIFIED
// margin moved against the same design with the flange solid:
//
//     region peak vM, % of part peak :  11.66   14.02   16.57   19.37   22.09   23.48
//     Δ certified margin             : +0.0001 +0.0002 +0.0003 +0.0008 +0.0203 +0.0823  (%)
//
// The effect is flat to within +0.0008 % up to 19.37 % of peak and then turns up by a
// factor of 25 at 22.09 %. 0.20 is the round threshold that sits in that knee: it admits
// every station measured flat and excludes every station measured steep. Move the
// measurement and this number moves with it.
//
// ★★ WHAT THIS NUMBER IS NOT — read before trusting it. §10's CONTROL swept the cell
// across the floor at fixed rho and got a margin identical to TEN DECIMAL PLACES
// (0.7526820834 at 5.00, 4.00, 2.00, 1.33 and 1.00 cells per member). The homogenized
// tensor is a function of relative density ALONE — cell size never enters the composite
// solve — so the certification is STRUCTURALLY BLIND to cells-per-member. The Δ margin
// above is therefore NOT evidence that a sub-floor lattice is accurate; it is only
// evidence that substituting C(rho) for solid did not move that part's margin. The
// accuracy question the floor exists to answer needs direct FEA of the real strut
// geometry, which the lattice Phase-0 probe measured at a 44-276x cost ceiling.
// Retaining a sub-floor voxel is therefore a DECISION TO ACCEPT A KNOWN, UNQUANTIFIED
// INACCURACY, and the receipt says so — it must never be justified by "the margin did
// not move", because the margin CANNOT move.
double lattice_subfloor_retention_stress_fraction();

// ★ THE AGGREGATE SUB-FLOOR EXPOSURE CAP — the ceiling on how much of a part may be
// held under the accuracy claim above, SUMMED ACROSS EVERY REGION, as a fraction of
// the printed set. Read this; do NOT hardcode it.
//
// WHY IT EXISTS, and it is not the same question the fraction above answers. That
// one asks "is THIS region quiet enough?". Once retention is evaluated PER REGION, a
// part with eight include regions can have eight of them answer yes independently,
// and the material under the claim multiplies. "Each region qualified individually"
// and "the part is fine" are DIFFERENT STATEMENTS, and nothing in the certificate
// adds them up — see ★★ above: the certification is structurally blind to
// cells-per-member, so no margin measurement, on any number of regions, can show the
// total is safe. A quantity that cannot be bounded by measurement must be bounded by
// POLICY, and this is that bound.
//
// WHERE 0.03 COMES FROM. It is a stated multiple of the ONLY configuration ever
// verified end to end — the maintainer's wall at resolution 128, rung 0.68, where
// the argmax held and the composite margin moved +0.0853 % against a pre-stated
// 0.10 % bound. That run retained 822 of 88,424 printed voxels = 0.930 % of the
// part. 3.0 % is ~3.2x it: room for a part with several genuinely quiet regions,
// far short of "unlimited because every region passed".
//
// ★★★ THIS IS A CEILING ON EXPOSURE, NOT A SAFETY THRESHOLD. No measurement
// supports 3.0 % as safe, and by the blindness above none could. It does not make
// the retained material accurate; it bounds how much of the part is held under a
// claim nothing can check. Over the cap the law retains NOTHING rather than
// retaining as much as fits — partial retention would mean choosing which regions
// to sacrifice, and nothing measures that choice.
double lattice_subfloor_aggregate_cap_fraction();

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

// ★ DOES A STATED PER-REGION DENSITY REFUSE AT THIS CELL? (task
// 2026-08-16-per-sector-density-override, bar R1'.)
//
// Extracted from run_job.cpp's `refuse_unprintable_stated_density` so the
// question can be ASSERTED rather than merely read. The throwing wrapper there
// calls this and does nothing else to decide; it only builds the message.
//
// ★★ THE PROPERTY THAT MATTERS IS AN UNREACHABILITY, NOT A HAPPY PATH:
//
//        stated_relative_density <= 0  =>  ALWAYS false
//
// for EVERY cell size and EVERY extrusion width — including shapes no part in
// the test corpus produces. `<= 0` is core's sentinel for "nothing stated,
// derive", so this is exactly the statement that a job with no override cannot
// be refused by this branch, whatever design the optimizer hands it and whatever
// regions resolve against that design. That is what makes the C0 inertness of
// this task's hoisted pre-solve refusal a proof rather than a sample: a
// byte-diff covers ONE job, this covers all of them.
//
// True means the strut this density produces at `cell_mm` is thinner than the
// profile's extrusion width, i.e. it cannot be printed. NEVER clamped: the
// caller refuses with the number.
bool lattice_stated_density_unprintable(double stated_relative_density,
                                        double cell_mm,
                                        double min_extrudable_width_mm);

// ★ THE PRINTABILITY FLOOR — the SMALLEST cell edge (mm) at which `topo`'s thinnest
// certifiable strut (the one at lattice_rho_min) still prints at the stated minimum
// extrudable width. Below it the lowest-density struts come out under one bead.
//
// ONE LAW, read by everyone: the grading law (grading.hpp) raises a Fixed target to
// it and takes it verbatim as the Auto cell, the dyadic plan (cell_plan.hpp) reports
// it, and the APP BRIDGE serves it to the UI so the cell-size control's lower bound is
// core's number rather than an app-side literal (handoff 2026-08-01-lattice-cell-size-
// sweep, bar R6). Because the strut diameter is exactly linear in cell size, the floor
// is just min_extrudable_width / (diameter at a unit cell).
//
// Throws std::invalid_argument if min_extrudable_width_mm is not finite and > 0.
double lattice_cell_printability_floor_mm(LatticeTopology topo,
                                          double min_extrudable_width_mm);

// ── THE PER-MEMBER CELL DERIVATION (task 2026-08-05-lattice-cell-size-adaptation).
//
// WHY IT EXISTS, AND WHAT IT CORRECTS. The floor above is evaluated at
// lattice_rho_min — the band's LIGHTEST certifiable lattice — because that is the
// density whose strut is thinnest and therefore the one that sets a floor valid for
// ANY density. That makes it the right number for "raise a user's target cell", which
// is what it is used for. It is the WRONG number to answer "how thick must a member be
// before it can hold a lattice", and it was being read that way: N* x that floor is
// 23.0131 mm at a 0.42 mm nozzle, and that conditional figure reached the maintainer
// as an unconditional "you need a 23 mm member". The condition — at the band's LOWEST
// density — was never surfaced.
//
// A member does not have to be latticed at rho_min. Strut diameter is exactly linear
// in cell size and monotone in rho, so a DENSER lattice prints at a SMALLER cell, and
// a smaller cell puts more cells across the same member. Answering per member instead
// of per band collapses the requirement from 23.0131 mm to 5.4748 mm at the same
// nozzle. This function is that answer, and it reports BOTH ends of the admissible
// window rather than picking one — which end a user wants is a mass/accuracy judgement
// nothing here measures.
//
// THE ARITHMETIC, IN FULL. Write phi(rho) = octet_strut_diameter_mm(rho, 1) for the
// measured diameter per unit cell, W for the member width, w for the minimum
// extrudable width and N* for lattice_cells_per_member_min. A (cell S, density rho)
// pair is admissible iff
//     S * phi(rho) >= w        (PRINTABILITY: the strut is at least one bead)
//     W / S        >= N*       (HOMOGENIZATION: enough cells across to certify)
// i.e.  w / phi(rho) <= S <= W / N*. Since phi is increasing, the widest window is at
// the band's top, and the pair set is non-empty iff W >= N* * w / phi(rho_max).
//
// ★ A MEASUREMENT LIMIT THAT IS LOAD-BEARING HERE. phi is measured on rho 0.05..0.60
// and CLAMPED above 0.60, while the certifiable band reaches lattice_rho_max = 0.8999.
// So phi is FLAT on [0.60, rho_max] and a density above 0.60 buys no extra diameter in
// this model. That is the conservative direction — a real strut at rho 0.80 is fatter
// than phi says, so we demand a bigger cell than strictly necessary, never a smaller
// one — but it means `densest_relative_density` below is reported as the LIGHTEST
// density that reaches the frontier cell, not as rho_max, because carrying more mass
// for an identical cell would be a worse answer with no measurement behind it.
struct LatticeCellDerivation {
  // ── the inputs that governed, echoed so a receipt never has to re-derive them ──
  double member_width_mm = 0.0;
  double min_extrudable_width_mm = 0.0;
  double cells_per_member_floor = 0.0;  // N*
  double band_rho_min = 0.0;
  double band_rho_max = 0.0;

  // Is there ANY (cell, rho) pair in the band that fits this member at this nozzle?
  bool feasible = false;

  // ── the arithmetic that decides it (populated whether feasible or not) ──────────
  // The smallest cell at which the band's FATTEST modelled strut still prints:
  // w / phi(rho_max). No certified lattice exists below this cell at any density.
  double min_printable_cell_mm = 0.0;
  // The largest cell this member can homogenize: W / N*.
  double max_homogenizable_cell_mm = 0.0;
  // ★ THE NUMBER A USER ACTS ON WHEN INFEASIBLE: `cells_per_member_floor` x
  // min_printable_cell_mm — the THINNEST member that clears the floor IN FORCE at
  // this nozzle. A member below it cannot meet that floor at any (cell, rho) in the
  // band, and the remedy is a thicker member (or a finer nozzle), not a different
  // cell.
  double min_member_width_mm = 0.0;

  // ── THE TWO FLOORS, ANSWERED SEPARATELY (M8b). `min_member_width_mm` above uses
  // whichever floor the caller put in force; these two are always both reported, so
  // a caller never has to know which question it asked to read the answer.
  //
  //   CERTIFIABLE — lattice_cells_per_member_min x the smallest printable cell. The
  //     thinnest member whose certificate the homogenized tensor can describe.
  //   BUILDABLE   — lattice_percolation_cells_per_member_min x the same cell. The
  //     thinnest member whose strut network is CONNECTED GEOMETRY at all.
  //
  // A member between them is BUILDABLE AND UNCERTIFIABLE: it prints, and the margin
  // over it is out of regime. Reporting only the first collapses that case into
  // "un-latticeable", which it is not — see `feasible_percolation` below.
  double min_member_width_certifiable_mm = 0.0;
  double min_member_width_buildable_mm = 0.0;
  // Which floor produced `feasible` and `min_member_width_mm` — so a message can name
  // the question it answered instead of leaving the reader to guess.
  bool floor_in_force_is_accuracy = true;
  // Does ANY (cell, rho) pair in the band clear PRINTABILITY and PERCOLATION? This is
  // the genuine un-latticeability test. When it is false nothing can be built here at
  // any setting; when it is true but `feasible` is false, the member is buildable and
  // uncertifiable, which is a different verdict with a different remedy.
  bool feasible_percolation = false;
  // The member's span in cells at the smallest printable cell, against each floor.
  // (Same number, two comparisons — reported so a receipt can show the margin.)
  double cells_per_member_at_finest = 0.0;

  // ── THE ADMISSIBLE WINDOW, both ends (zero when infeasible) ────────────────────
  // DENSEST/FINEST end: the smallest admissible cell, at the lightest density that
  // reaches it (see ★ above). Most cells per member, so most homogenization headroom.
  double densest_relative_density = 0.0;
  double densest_cell_size_mm = 0.0;
  double densest_strut_diameter_mm = 0.0;
  double densest_cells_per_member = 0.0;
  // LIGHTEST/COARSEST end: the largest admissible cell (exactly W / N*, so exactly N*
  // cells across), at the lightest density whose strut still prints there. This is the
  // MINIMUM-MASS certified lattice for this member.
  double lightest_relative_density = 0.0;
  double lightest_cell_size_mm = 0.0;
  double lightest_strut_diameter_mm = 0.0;
  double lightest_cells_per_member = 0.0;
};

// Derive the admissible (cell, density) window for ONE member of measured width
// `member_width_mm` at a stated `min_extrudable_width_mm`. `cells_per_member_floor`
// <= 0 takes lattice_cells_per_member_min(topo) — the caller passes its own only to
// report a what-if, never to relax the shipped floor on a certified path.
//
// PURE ARITHMETIC on core's own measured constants: no grid, no field, no state, and
// deterministic. A member width of +infinity (voxel.hpp's "thicker than we measured"
// sentinel) is feasible with max_homogenizable_cell_mm = +infinity and the coarsest
// end pinned to the finest, which is the honest reading — nothing bounds the cell
// from above, so the two ends coincide at the printability frontier.
//
// Throws std::invalid_argument if `member_width_mm` is not > 0 (NaN included), if
// `min_extrudable_width_mm` is not finite and > 0, or if the topology has no measured
// band (lattice_rho_min returns 0 for a non-certifiable topology).
LatticeCellDerivation lattice_derive_cell_for_member(
    LatticeTopology topo, double member_width_mm,
    double min_extrudable_width_mm, double cells_per_member_floor = 0.0);

// The LIGHTEST relative density in `topo`'s certifiable band whose strut at cell edge
// `cell_size_mm` is at least `min_extrudable_width_mm` across. Returns the band floor
// when even that prints, and a negative value when NO density in the band does — the
// caller must test, because there is no in-band answer to hand back. Exact inverse of
// octet_strut_diameter_mm on the piecewise-linear measured table, so
// octet_strut_diameter_mm(result, cell) >= min width holds by construction wherever
// the result is non-negative.
double lattice_min_density_for_strut(LatticeTopology topo, double cell_size_mm,
                                     double min_extrudable_width_mm);

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

// One MEASURED row of the embedded library, at the library's own measurement basis
// (kLibraryEs = 3500 MPa). `rho` is the row's relative density; C11/C12/C44 are the
// homogenized constants lattice_cubic_tensor interpolates between.
struct LatticeResolvedRow {
  double rho = 0.0;
  double C11 = 0.0, C12 = 0.0, C44 = 0.0;
};

// The RESOLVED rows of `topo`'s table — the contiguous validated block, i.e. exactly
// the rows lattice_cubic_tensor interpolates and the rows the band
// [lattice_rho_min, lattice_rho_max] spans. Returned at the LIBRARY basis
// (Es = kLibraryEs); a caller wanting another solid modulus scales by Es/3500, which
// is what lattice_cubic_tensor itself does (effective stiffness is exactly linear in
// the solid modulus). Empty for a topology with no validated cubic tensor (the
// tetragonal variants) — the same "refuse" signal lattice_topology_certifiable gives.
//
// WHY THIS IS PUBLIC: the multiscale material model (lattice_material.hpp) fits a
// C1-continuous curve THROUGH these rows so the optimizer can steer on the measured
// physics. It reads them from HERE rather than transcribing them, so a table change
// moves the fit automatically and the two cannot drift (the probe that prototyped the
// model, handoff 2026-07-31-multiscale-lattice-feasibility, transcribed them into a
// harness header and needed a pinning test to catch drift; production does not).
std::vector<LatticeResolvedRow> lattice_resolved_rows(LatticeTopology topo);

// The solid Young's modulus the embedded library was measured at (PLA, materials.json).
// Rows returned by lattice_resolved_rows are on this basis.
double lattice_library_youngs_modulus();

// The relative density (solid volume fraction) of ONE `topo` unit cell of edge
// `cell_mm` filled with cylindrical struts of radius `strut_radius_mm` — the map
// from the PRINTED geometry a job declares (cell size + uniform strut radius) to
// the `rho` the tensor library above is keyed on (lattice certification E2E,
// handoff 2026-07-29-lattice-certification-e2e).
//
// It is computed on the LIBRARY'S OWN BASIS: the single octet cell is voxelized at
// the resolution PR 198 measured the library at (kLatticeLibraryVpc = 48 voxels
// per cell edge) with the identical strut distance field, and rho is the solid
// voxel fraction. This is the exact forward of the calibrate_octet_r inversion
// PR 198 used to place each library row, so a query at a printed radius lands on
// the same rho scale the tensor rows carry — the two cannot drift. Deterministic
// (fixed voxel sweep, no RNG/threads); rho in (0, 1). Depends only on the RATIO
// strut_radius_mm / cell_mm (the field scales with the cell), so it is cell-size
// invariant. Throws std::invalid_argument if cell_mm or strut_radius_mm is not
// finite/> 0, or if the radius is so large the cell fills solid (rho would be 1).
//
// NOTE (carried, not hidden): the production generator (lattice_gen.cpp) meshes
// each strut as an n=8 prism, a printable inner approximation of the cylinder this
// uses; the ~1-2 % polygon-vs-circle area gap sits well inside octet's ±10 %
// resolution caveat (C6) and does not move the library row a query interpolates.
double octet_relative_density(double cell_mm, double strut_radius_mm);

// The resolution (voxels per cell edge) the octet tensor library was measured at,
// and the basis octet_relative_density voxelizes on so a printed radius maps onto
// the same rho scale the library rows carry (PR 198, vpc48).
constexpr int kLatticeLibraryVpc = 48;

// Thrown by analyze_fixed_design when a LatticePosture asks to certify a relative
// density OUTSIDE the trustworthy library band [lattice_rho_min, lattice_rho_max]
// (lattice certification E2E bar E5). The certification REFUSES rather than certify
// against a clamped or extrapolated tensor — the band is a hard gate at
// certification, not only at generation. `rho`, `rho_min`, `rho_max` carry the
// offending value and the band read from core so the caller can report both.
struct LatticeDensityOutOfBand : std::runtime_error {
  double rho, rho_min, rho_max;
  LatticeDensityOutOfBand(double rho_, double lo, double hi, const std::string& msg)
      : std::runtime_error(msg), rho(rho_), rho_min(lo), rho_max(hi) {}
};

// Thrown by lattice_cubic_tensor (and thus analyze_fixed_design) when a posture asks
// to certify a topology the homogenized library does NOT carry a validated cubic
// tensor for — the tetragonal variants (Bccz/Fccz/Reentrant) or any topology with no
// rows. The gate REFUSES rather than certify against a wrong-symmetry or neighbour's
// tensor (bar B3). Distinct from LatticeDensityOutOfBand (that one is a valid topology
// at an out-of-band density; this one is a topology the cubic model cannot represent).
struct LatticeTopologyNotCertifiable : std::runtime_error {
  explicit LatticeTopologyNotCertifiable(const std::string& msg)
      : std::runtime_error(msg) {}
};

}  // namespace topopt

#endif  // TOPOPT_LATTICE_HPP
