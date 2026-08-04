#ifndef TOPOPT_GRADING_HPP
#define TOPOPT_GRADING_HPP

// THE LATTICE GRADING LAW (handoff 2026-07-29-lattice-grading-law).
//
// This is the FRONT-END that turns a stress (or strain-energy) field into a
// printable, certifiable lattice posture — the piece analyze.hpp's LatticePosture
// comment calls "the grading law (separate task)". It maps a per-voxel demand to a
// per-voxel relative density and ONE uniform cell size, then hands back a
// LatticePosture the certification engine (analyze_fixed_design) already consumes.
//
// IT READS ITS LIMITS FROM CORE, IT DOES NOT HARDCODE THEM (bar ★):
//   * the certifiable DENSITY BAND is lattice_rho_min / lattice_rho_max (lattice.hpp)
//   * the CELLS-PER-MEMBER floor is lattice_cells_per_member_min (lattice.hpp)
//   * the LOCAL MEMBER WIDTH is local_member_thickness_mm (voxel.hpp, PR 206)
// When those measurements move, this law moves with them — no rewrite.
//
// THE THREE CONSTRAINTS IT ENFORCES (task requirements 1-3):
//   1. DENSITY is clamped into [rho_min, rho_max]. Every emitted density is
//      certifiable by construction (bar L2).
//   2. CELL SIZE is clamped so cells-per-member (member_width / cell) stays at or
//      above the floor, using the real local member width. A member too thin to hold
//      the floor at a printable cell STAYS SOLID (bar L4) — never a sub-floor lattice,
//      UNLESS the caller explicitly arms sub-floor retention for a region measured to
//      be carrying almost no load (see GradingLawParams below, handoff
//      2026-08-04-subfloor-lattice-unloaded-regions). That opt-in is OFF by default;
//      when it is off this law is bit-identical to the pre-task one. When it is on,
//      the retained voxels are individually flagged, counted and reported, and the
//      certificate over them is out of regime.
//   3. STRUT DIAMETER is checked against the stated minimum extrudable width and
//      REPORTED (min_strut_diameter_mm, any_strut_below_min) — never silently violated.
//
// CELL SIZE: AUTO / FIXED / SWEPT (handoff 2026-08-01-lattice-cell-size-sweep).
//   FIXED (default) — ONE cell for the whole part: the caller's target raised to the
//     printability floor. Exactly the pre-sweep law, byte-for-byte.
//   AUTO — ONE cell, chosen by core with no user number: the printability floor
//     itself, the finest cell every strut still prints at (and therefore the uniform
//     cell that leaves the MOST of the part latticed, since the cells-per-member rule
//     is an upper bound).
//   SWEPT — cell size VARIES with demand across the part, on a dyadic octree between
//     min_cell_size_mm and max_cell_size_mm. cell_plan.hpp owns that law and states
//     why dyadic is the only transition rule that meets at shared nodes; the density
//     grade above is unchanged and the two compose without circularity (density
//     depends on demand alone; cell size depends on density + local member width).
//
// The homogenized tensor is a function of RELATIVE DENSITY, which is a ratio, so it
// is cell-size invariant — measured for this task at 0.000e+00 relative deviation on
// C11/C12/C44 across a 4x cell range (evidence/2026-08-01-lattice-cell-size-sweep/
// c1_scale_invariance.csv). A varying cell therefore costs NOTHING in certification;
// what it changes is which voxels clear the cells-per-member regime, reported per
// level (bar R5).
//
// DETERMINISTIC. Pure arithmetic in a fixed voxel order, no RNG/threads/atomics: the
// same (grid, density, demand, params) always produce a byte-identical field (bar L5).

#include <cstddef>
#include <vector>

#include "topopt/analyze.hpp"    // LatticePosture
#include "topopt/cell_plan.hpp"  // CellSizeMode, CellSizePlan
#include "topopt/lattice.hpp"    // LatticeTopology
#include "topopt/voxel.hpp"      // VoxelGrid

namespace topopt {

// How the law maps demand to (density, cell size). All fields must be positive where
// noted; grade_lattice throws std::invalid_argument otherwise.
struct GradingLawParams {
  LatticeTopology topology = LatticeTopology::Octet;

  // The requested uniform cell edge (mm). The chosen cell is max(this, printability
  // floor) — a target below the floor is raised (and cell_size_floored is set), never
  // used as-is, because it would make the lowest-density strut unprintable. Must be > 0
  // in Fixed mode; IGNORED by Auto (core picks the cell) and by Swept (the ladder ends
  // below do).
  double target_cell_size_mm = 0.0;

  // How the cell size is chosen. Fixed (the default) is the pre-sweep law and the
  // path a legacy caller keeps, byte-for-byte.
  CellSizeMode cell_mode = CellSizeMode::Fixed;

  // SWEPT only: the ends of the dyadic ladder (mm), min > 0 and max >= min. The
  // admissible cells are min * 2^L up to max; a 4 -> 8 mm sweep is two levels. Both
  // ignored in Fixed / Auto mode.
  double min_cell_size_mm = 0.0;
  double max_cell_size_mm = 0.0;

  // The STATED minimum extrudable strut width (mm) — requirement 3, an INPUT the law
  // honours and reports against, not a magic number. The printability floor is set so
  // a strut at rho_min prints at exactly this width; every higher-density strut is
  // fatter. Must be > 0.
  double min_extrudable_width_mm = 0.0;

  // rho = rho_max * (demand / demand_max)^demand_exponent, clamped to the band.
  //   1.0 (default) — fully-stressed grading for a STRESS-like demand (von Mises):
  //     octet strength is ~linear in rho, so rho proportional to stress holds an even
  //     margin.
  //   0.5 — the same stress-proportional grade from a strain-ENERGY demand (u ~ s^2).
  // Must be > 0.
  double demand_exponent = 1.0;

  // The local-member-thickness EDT radius cap (voxels), mirroring analyze.cpp's
  // kWidthAwareThicknessCapVoxels. A member thicker than 2*cap*spacing reads the +inf
  // "thicker than measured" sentinel and always clears the ceiling. Must be >= 1.
  int thickness_cap_voxels = 32;

  // ── MULTISCALE (task multiscale-lattice-to) ────────────────────────────────
  // When non-null, THIS per-voxel field (size grid.voxel_count()) is the relative
  // density the law grades to, INSTEAD of the demand -> density map above.
  // `demand` and `demand_exponent` are then unused for the density; everything
  // else — the band clamp, the cells-per-member floor, the L4 solid fallback, the
  // printability check, the cell plan and the L2 certifiability assertion — is the
  // SAME code on the same terms.
  //
  // WHY IT EXISTS. Under the two-step pipeline the optimizer knew nothing about
  // the lattice, so deriving the lattice density from the stress field afterwards
  // was the only information available. Under MULTISCALE the optimizer has already
  // chosen a relative density per voxel and PAID a compliance objective evaluated
  // at the measured tensor of that density. Re-deriving rho from stress would throw
  // that away and print a different material distribution than the one that was
  // optimized and certified — the same disagreement between the loop and the export
  // that the two-step's failure was made of. So a multiscale run prescribes.
  //
  // The field is used VERBATIM up to the band clamp: a value outside
  // [rho_min, rho_max] is clamped and COUNTED exactly like a demand-derived one
  // (clamped_lo_voxels / clamped_hi_voxels / clamp_flags), never silently accepted.
  // A caller that has already projected onto the feasible set will see zero clamps
  // on the in-band voxels, which is the honest way to show the projection worked.
  // Null (the DEFAULT) is the demand map, byte-for-byte.
  const std::vector<double>* prescribed_relative_density = nullptr;

  // HOW THESE TWO COMPOSE (multiscale x sub-floor retention). A multiscale run
  // prescribes rho and stops using `demand` FOR THE DENSITY — but it still hands
  // in the variant's real von Mises field, and that is what the retention
  // predicate below measures. So retention stays a measurement on a multiscale
  // run, not an assertion. If a caller ever prescribes density AND passes a
  // demand-less field, retention disarms itself rather than reading the resulting
  // 0.0 as "unloaded" (see grade_lattice's part-peak guard).
  // ── SUB-FLOOR RETENTION IN UNLOADED REGIONS ─────────────────────────────────────
  // (handoff 2026-08-04-subfloor-lattice-unloaded-regions)
  //
  // OFF BY DEFAULT, and a job that does not opt in is bit-identical (bar S1). When
  // ARMED, requirement 2's fallback is conditioned rather than removed: a candidate
  // whose member cannot hold the cells-per-member floor is kept as LATTICE — instead
  // of falling back to solid — provided the REGION it belongs to is carrying almost
  // no load. The maintainer's case is a back wall that exists for geometry: it should
  // be latticeable two cells thick, and today it is silently left solid.
  //
  // THE PREDICATE IS REGION-SCOPED AND MEASURED, NEVER DECLARED. The law computes
  //   region peak demand / PART peak demand
  // over the demand field it was handed — the region's peak across the candidate set,
  // the part's peak across every printed voxel, region or not — and arms retention for
  // the whole region only when that ratio is <= `subfloor_stress_fraction_max`. It is
  // measured from the field, so a user cannot assert a region is unloaded; and it is
  // region-scoped, not per-voxel, because that is the shape §10 measured (a REGION at
  // N % of part peak), and a per-voxel test would lattice quiet voxels sitting inside
  // a loaded region, which nothing has measured.
  //
  // WHAT RETENTION NEVER DOES. It never emits a strut under the stated minimum
  // extrudable width (printability is a fact about the printer, not about load), and
  // it never emits a density outside the certifiable band. Both invariants below are
  // asserted for retained voxels exactly as for every other latticed voxel.
  //
  // WHAT IT COSTS. The certificate over retained material is OUT OF REGIME:
  // `analyze_fixed_design` raises `lattice_strut_out_of_regime`, and the GradedField
  // below names WHICH voxels, at what cells-per-member, and at what fraction of peak
  // stress. See lattice.hpp's declaration of the fraction for why the observed
  // margin movement is NOT evidence of accuracy.
  bool retain_subfloor_in_unloaded_regions = false;
  // The ceiling, defaulted to the measured constant. Must be > 0 and <= 1 when armed.
  double subfloor_stress_fraction_max =
      0.0;  // 0 => take lattice_subfloor_retention_stress_fraction() at call time
};

// The law's output: the posture the certification engine consumes, plus a full report
// of what it produced and what it had to leave solid (bars L3 / L4). Every scalar here
// is meant for run_info.
struct GradedField {
  // ── the deliverable: the certification posture ──────────────────────────────────
  LatticePosture posture;  // topology, cell_size_mm, per-voxel mask + relative_density

  // ── provenance: the limits READ FROM CORE (so run_info records what governed) ────
  double band_rho_min = 0.0;           // lattice_rho_min(topology)
  double band_rho_max = 0.0;           // lattice_rho_max(topology)
  double cells_per_member_floor = 0.0; // lattice_cells_per_member_min(topology)

  // ── the chosen cell ─────────────────────────────────────────────────────────────
  // In Fixed / Auto mode this is THE cell for the whole part. In Swept mode it is the
  // COARSEST cell the plan actually used (posture.cell_size_mm carries the same, as
  // the single scalar a legacy reader sees) — the honest per-region numbers are in
  // `cell_plan.levels`, and the per-voxel truth is `posture.cell_size_field`.
  double cell_size_mm = 0.0;
  double printability_floor_mm = 0.0;  // smallest cell that prints the rho_min strut
  bool cell_size_floored = false;      // target was below the floor and got raised
  CellSizeMode cell_mode = CellSizeMode::Fixed;

  // The SWEPT plan (bar R4/R5). In Fixed / Auto mode this is a trivial one-level
  // record of the uniform cell, so every consumer reads the same shape in all three
  // modes and a receipt never has to branch.
  CellSizePlan cell_plan;

  // ── what was produced (L3) ──────────────────────────────────────────────────────
  std::size_t region_voxels = 0;          // candidate voxels (printed AND in region)
  std::size_t latticed_voxels = 0;        // graded to lattice
  std::size_t solid_fallback_voxels = 0;  // L4: too thin for the floor -> stayed SOLID

  // ── WHY EACH FALLBACK VOXEL FELL BACK (task
  //    2026-08-03-variant-postprocessing-fix, defect 2 / bar F1) ─────────────────
  // `solid_fallback_voxels` is an aggregate, and an aggregate is not an answer:
  // the maintainer's variant 052 reported 10,403 of 10,485 region voxels kept
  // solid with no way to tell which limit bound, and therefore no way to know
  // whether a bigger cell, a different region, or nothing at all would help.
  //
  // There are exactly TWO predicates that can reject a candidate voxel, and they
  // have OPPOSITE remedies — which is precisely why they must not be summed:
  //
  //   MEMBER TOO THIN — width/cell < cells-per-member floor. The member cannot
  //     hold enough cells across to homogenize. A SMALLER cell helps; a bigger one
  //     makes it worse. When the cell is already at the printability floor, NOTHING
  //     helps: the member is simply thinner than floor × n*, and the fix is a
  //     thicker member, i.e. a different optimizer result.
  //   STRUT UNPRINTABLE — the strut this voxel's density would emit is under the
  //     stated minimum extrudable width at every cell available. A BIGGER cell
  //     helps (the strut scales with it); a smaller one makes it worse.
  //
  // The two sum to `solid_fallback_voxels` exactly. On the uniform paths only the
  // first can occur, because the uniform cell is at or above the floor at which the
  // band's lowest density still prints — stated here so a receipt reading
  // `unprintable == 0` is read as "structurally impossible", not "we got lucky".
  std::size_t fallback_member_too_thin = 0;
  std::size_t fallback_strut_unprintable = 0;
  // The member-width distribution over the REJECTED voxels, so a remedy can be
  // sized instead of guessed: the widest member that still failed tells you how far
  // from admissible the best of them was. +inf ⇒ every rejected member exceeded the
  // EDT cap (impossible while any rejection is by width, so a tripwire).
  double fallback_max_member_width_mm = 0.0;
  // How many of `fallback_member_too_thin` could NEVER be latticed at any legal
  // cell — width < n* × printability_floor. A remedy that changes the cell cannot
  // touch these, and offering one would be a guess. (<= fallback_member_too_thin.)
  std::size_t fallback_irrecoverable_by_cell = 0;
  double rho_min_used = 0.0;              // achieved rho band over latticed voxels
  double rho_max_used = 0.0;
  double min_member_width_mm = 0.0;       // thinnest LATTICED member (mm); +inf if all
                                          //   latticed members exceed the EDT cap
  double min_cells_per_member = 0.0;      // at that thinnest member. >= floor ALWAYS,
                                          //   except over voxels sub-floor retention
                                          //   deliberately kept — which is exactly the
                                          //   number that makes analyze_fixed_design
                                          //   raise lattice_strut_out_of_regime.
  double min_strut_diameter_mm = 0.0;     // thinnest emitted strut
  double max_strut_diameter_mm = 0.0;     // fattest emitted strut

  // ── SUB-FLOOR RETENTION — the accepted inaccuracy, NAMED (handoff
  //    2026-08-04-subfloor-lattice-unloaded-regions, bar S2) ────────────────────────
  // Retaining a below-the-floor voxel is a decision to accept an inaccuracy nothing in
  // this codebase can currently quantify (lattice.hpp, ★★). A receipt that only said
  // "out of regime" would bury that; these fields name it. Every one of them is 0 /
  // false / empty when retention is disarmed, which is the default.
  bool subfloor_retention_armed = false;    // the job opted in
  double subfloor_stress_fraction_max = 0.0;  // the ceiling that was in force
  // The MEASURED predicate: this region's peak demand over the PART's peak demand.
  // 1.0 when the candidate set is the whole printed part (there is no "region" to be
  // unloaded relative to), 0.0 when the part carries no demand at all.
  double region_stress_fraction = 0.0;
  bool region_qualified_unloaded = false;   // region_stress_fraction <= the ceiling
  // Candidates whose member could not hold the floor, REGARDLESS of arming — i.e. the
  // voxels retention is about. Reported even when disarmed, so the forecast can say
  // how much is at stake before anyone opts in.
  std::size_t subfloor_candidate_voxels = 0;
  std::size_t subfloor_retained_voxels = 0;  // ...and how many were actually kept
  // Voxels latticed BECAUSE retention was armed but which turned out to clear the
  // floor at their own cell, so they are NOT out of regime and carry no accuracy
  // claim. They exist only on the SWEPT path, where the plan rejects a whole base
  // cell using the thinnest member anywhere inside it: dropping that ceiling for a
  // qualified region lets individual voxels on wider material through legitimately.
  // Reported separately precisely so `subfloor_retained_voxels` stays the exact
  // count of material the certificate is out of regime over.
  std::size_t subfloor_recovered_in_regime_voxels = 0;
  // The regime the retained material actually landed in. min/max over RETAINED voxels
  // only; 0 when none were retained. `subfloor_min_cells_per_member` is the headline
  // number — it is below `cells_per_member_floor` by construction, and how far below
  // is the size of the claim being accepted.
  double subfloor_min_cells_per_member = 0.0;
  double subfloor_max_cells_per_member = 0.0;
  double subfloor_min_strut_diameter_mm = 0.0;
  double subfloor_max_strut_diameter_mm = 0.0;
  // WHICH voxels (bar S2). Grid-indexed, grid.voxel_count(): 1 = this voxel is latticed
  // AND sits below the cells-per-member floor. EMPTY when nothing was retained — which
  // is what keeps a disarmed run byte-identical. This is also what the certifiability
  // invariant below reads: a sub-floor voxel is admissible ONLY if it is flagged here.
  std::vector<char> subfloor_flags;

  // ── honesty flags ───────────────────────────────────────────────────────────────
  bool any_strut_below_min = false;    // requirement 3: some strut under the min width
                                       //   (false by construction; a tripwire, not a mode)
  bool region_ungradeable = false;     // L4 at region scale: candidates existed but NONE
                                       //   could be graded — the whole region stayed solid

  // ── band-clamp accounting (task lattice-page-core-hookup, H4b) ──────────────────
  // How many LATTICED voxels the demand map placed OUTSIDE the certifiable band
  // before requirement 1's clamp pulled them to an endpoint. A low clamp adds
  // material relative to demand (conservative); a high clamp caps a voxel the
  // demand wanted denser than the band allows — the honest count run_job's graded
  // receipt reports per variant, with fractions and whether clamping decided the
  // verdict. Additive fields: existing callers ignore them.
  std::size_t clamped_lo_voxels = 0;   // raw rho < band_rho_min, clamped UP
  std::size_t clamped_hi_voxels = 0;   // raw rho > band_rho_max, clamped DOWN
  // Per-voxel clamp record (grid-indexed, grid.voxel_count()): 0 = not clamped,
  // 1 = clamped up to rho_min, 2 = clamped down to rho_max. What the
  // clamp-counterfactual certification (run_job) uses to know WHICH voxels to
  // keep solid in the comparison solve.
  std::vector<char> clamp_flags;
};

// Grade `density`'s printed set (optionally restricted to `region`) from the per-voxel
// `demand` field, returning the posture + report.
//
//   grid, density  — the FIXED design; a printed voxel is density > iso.
//   demand         — per-voxel nonnegative demand (grid.voxel_count()); von Mises
//                    stress for fully-stressed grading (demand_exponent 1), or strain-
//                    energy density (demand_exponent 0.5). Off the printed set it is
//                    ignored. All-zero demand -> a uniform rho_min lattice.
//   region         — optional candidate mask (grid.voxel_count()); region[e] != 0 marks
//                    voxel e a lattice candidate. Null -> every printed voxel is a
//                    candidate. A candidate that fails the cells-per-member floor stays
//                    solid regardless (L4).
//   params, iso    — see above; iso is the printed-set threshold (0.5).
//
// Guarantees (bar L2, asserted internally before returning): for EVERY voxel the
// returned posture marks latticed, relative_density is in [rho_min, rho_max] AND
// member_width / cell_size >= cells_per_member_floor. A point the gate cannot certify
// is never emitted. Throws std::invalid_argument on a size mismatch or a non-positive
// param, std::logic_error if the internal certifiability invariant is ever violated.
//
// THE ONE EXCEPTION TO THE FLOOR HALF OF THAT INVARIANT, and it is not a loosening.
// When `retain_subfloor_in_unloaded_regions` is armed, a latticed voxel may sit below
// the cells-per-member floor — but ONLY if it is individually flagged in
// `subfloor_flags`, only in a region whose MEASURED stress fraction cleared the
// ceiling, and the assertion additionally requires that the flagged set and
// `subfloor_retained_voxels` agree exactly and that the region qualified. So the
// invariant is not weakened: an unflagged sub-floor voxel still throws, and the
// admissible set is now stated exactly rather than approximately. The BAND half and
// the printability half are unconditional and untouched — retention never widens
// either.
GradedField grade_lattice(const VoxelGrid& grid,
                          const std::vector<double>& density,
                          const std::vector<double>& demand,
                          const std::vector<char>* region,
                          const GradingLawParams& params, double iso = 0.5);

}  // namespace topopt

#endif  // TOPOPT_GRADING_HPP
