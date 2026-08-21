#ifndef TOPOPT_ORGANIC_LATTICE_HPP
#define TOPOPT_ORGANIC_LATTICE_HPP

// ★ THE ORGANIC LATTICE — STRUTS TRACED ALONG THE STRESS FIELD
// (task 2026-08-21-organic-lattice, §1.)
//
// The third lattice algorithm. DOUBLED (cell_plan.hpp) and STEPPED
// (lattice_algorithm.hpp) both start from a CELL and fill the part with it. This one
// has no cell at all: it EIGEN-DECOMPOSES the per-voxel stress tensor, TRACES curves
// along the three principal directions, and SPACES those curves by a field. Cell size
// is not an input here — it is an OUTPUT, read off the achieved spacing.
//
// ── WHY, AND THE EVIDENCE THAT IT IS NOT A SPECULATION ──────────────────────────
// Daynes, Feih, Lu & Wei, "Optimisation of functionally graded lattice structures
// using isostatic lines", Materials & Design 127:215-223 (2017),
// doi:10.1016/j.matdes.2017.04.082, measured +101 % STIFFNESS and +172 % STRENGTH
// against a uniform-cell core OF THE SAME DENSITY by grading cell size, aspect ratio
// AND orientation along isostatic lines. The 3D construction is Daynes et al., CMAME
// 354:689-705 (2019), doi:10.1016/j.cma.2019.05.053.
//
// The SPACING mechanism is Jobard & Lefer, "Creating Evenly-Spaced Streamlines of
// Arbitrary Density" (1997): seed the next curve at `d_sep` from an existing one and
// stop tracing when it comes within `d_test`. The spacing is the INPUT and the layout
// falls out of it. CURVY (arXiv:2102.10013) is the same idea with `d_sep` driven by a
// FIELD rather than a global constant, in a 3D-printing context, and that is the form
// used here: `spacing_mm` is per voxel.
//
// ── ★ PRINTABILITY IS NOT AN OPEN QUESTION ON THIS MACHINE ─────────────────────
// The maintainer printed a traced coupon with a 41.78 mm LONGEST UNSUPPORTED RUN,
// supports off, and it came out clean
// (evidence/2026-08-20-lattice-only-grading/r4b_PRINT_RESULT.md). That is a direct
// refutation of the 45-degree overhang rule as a HARD blocker here, which is why the
// clamp below is a PARAMETER that DEFAULTS TO DISARMED and why the 45-degree figure
// survives only as the counterfactual the report is measured against. Re-arming it by
// default would discard the stress alignment that is the entire justification for the
// method, in the name of a constraint this printer demonstrably does not have.
//
// ── ★ DETERMINISTIC, AND THE ORDERS ARE PART OF THE CONTRACT (§5) ──────────────
// `cell_plan.hpp` and the grading law are byte-identical by design; this joins them.
// Every order below is FIXED and stated, there is no RNG, no thread and no sampled
// estimate anywhere:
//   SEED ORDER   — the FIRST seed of a family is the candidate voxel with the largest
//                  |eigenvalue| for that family, ties broken by ASCENDING VOXEL INDEX.
//                  Every later seed comes off a FIFO queue filled by walking an
//                  accepted curve's points in order and offering, at each seed
//                  station, the four transverse offsets (+e_a, -e_a, +e_b, -e_b) in
//                  that order.
//   TRACE ORDER  — families 0,1,2 in that order, each family traced to exhaustion
//                  before the next starts. Each curve is traced FORWARD from its seed
//                  and then BACKWARD, and the two halves are joined back-to-front.
//   THIN ORDER   — DESCENDING curve length, ties broken by ASCENDING curve index, so
//                  the long load paths survive (§1e).
//   CONNECT ORDER— ascending (curve_a, curve_b) with curve_a < curve_b.
// The density rasteriser is a FIXED-STEP quadrature in a fixed traversal order, never
// a sample.

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "topopt/mesh.hpp"   // Vec3
#include "topopt/voxel.hpp"  // VoxelGrid

namespace topopt {

// ── the constants, named so they can be argued with ─────────────────────────────

// Jobard-Lefer's `d_test` as a multiple of `d_sep`: tracing STOPS when the curve comes
// within this fraction of the local separation of another curve of the same family.
// 0.5 is the value Jobard & Lefer report as their default.
inline constexpr double kOrganicTestRatio = 0.5;
// A new seed is offered at this multiple of the local `d_sep`, transverse to the
// parent curve — the "seed at d_sep" half of the same rule.
inline constexpr double kOrganicSeedRatio = 1.0;
// Two curves of DIFFERENT families are joined when their nearest approach is within
// this multiple of the local `d_sep` (§1d). At 1.0 a connector is never longer than
// one separation, which is what keeps the connector population the same scale as the
// curve population rather than a quadratic blow-up.
inline constexpr double kOrganicConnectRatio = 1.0;
// The RK4 step, as a fraction of the local `d_sep`. Small enough that the polyline's
// vertex spacing is well under `d_test` (so a vertex-based proximity query cannot miss
// a crossing by more than half a step), large enough that a curve across a 200 mm part
// is a few hundred points.
inline constexpr double kOrganicStepRatio = 0.35;
// A traced curve shorter than this multiple of the local `d_sep` is discarded as a
// stub: below one separation it is shorter than the gap to its own neighbour and
// carries no span.
// ★ IT IS 1.0 AND NOT 2.0, AND THAT IS MEASURED. At 2.0 a curve had to be twice the
// separation long to survive — and the maintainer's lattice regions are 4 mm-deep face
// slabs, so the family pointing THROUGH the slab produces ~4 mm curves against a ~5.5
// mm threshold and every one of them was discarded. Measured on his part at 2.0:
// curves_per_family = [28, 534, 0]. The third family is exactly the one that braces
// the other two through the thickness, so discarding it is what left 469 of 562 curves
// with no connection at all.
inline constexpr double kOrganicMinLengthRatio = 1.0;

// ★ THE TEXTBOOK OVERHANG GATE, KEPT ONLY AS THE COUNTERFACTUAL. It is NOT the
// default and it is NOT applied unless a caller asks for it: the maintainer's coupon
// printed a 41.78 mm unsupported run clean with supports off, so on this machine the
// 45-degree rule is not the binding limit. Reported against, never imposed.
inline constexpr double kOrganicTextbookOverhangDeg = 45.0;

// ★ THE PERCOLATION FLOOR ON CURVES-PER-MEMBER (§3a/§3b). `cells_per_member` counts
// CELLS across a wall and an organic lattice has no cells; the equivalent is the count
// of CURVES crossing the thinnest section. Below 2 a member is spanned by at most one
// curve of each family, which is a line of struts and not a lattice — nothing crosses
// it, so nothing braces it. This is a BUILDABILITY floor, in the same sense
// `lattice_percolation_cells_per_member_min` is, and NOT an accuracy floor: there is
// no homogenised tensor for a traced lattice, so there is no accuracy claim to floor.
// Material below it is COUNTED and reported OUT OF REGIME, never hidden (§3b).
inline constexpr double kOrganicCurvesPerMemberFloor = 2.0;

// ★ THE DENSITY OF THREE ORTHOGONAL FAMILIES AT SEPARATION d, STRUT DIAMETER t.
// A box of edge d carries one strut of each family through it, so the solid fraction
// is 3 * pi * (t/2)^2 * d / d^3 = 3*pi*t^2 / (4 d^2). Overlaps at the crossings are
// NOT deducted — the same soup basis the generator's volume accounting uses, and it is
// stated at every site that reports a number derived from it.
//
// This is the ONE definition of the spacing/thickness/mass coupling (§2d) and both
// directions of it are here so no caller re-derives half of it. The strut-diameter law
// has already drifted 1.4-1.7x by being re-derived elsewhere.
inline double organic_density_at(double spacing_mm, double strut_diameter_mm) {
  if (!(spacing_mm > 0.0)) return 0.0;
  const double t = strut_diameter_mm;
  return 3.0 * 3.14159265358979323846 * t * t / (4.0 * spacing_mm * spacing_mm);
}
// The inverse: the separation that yields `rho` at strut diameter `t`. This is the law
// that turns the grading field into a SPACING FIELD — tighter where the part works
// harder — which is the CURVY posture: the pattern is expressed by spacing at a
// constant bead, not by thinning struts below what the nozzle can lay.
inline double organic_spacing_for(double rho, double strut_diameter_mm) {
  if (!(rho > 0.0) || !(strut_diameter_mm > 0.0)) return 0.0;
  return 0.5 * strut_diameter_mm *
         std::sqrt(3.0 * 3.14159265358979323846 / rho);
}

// ★ THE STRUT DIAMETER A GIVEN GRID CAN ACTUALLY EXPRESS A GRADE AT.
//
// The obvious default — "the thinnest bead the machine lays" — is the WRONG one, and
// measurably so. Spacing and thickness are coupled through mass (§2d):
// d = (t/2) * sqrt(3 pi / rho). At a 0.42 mm bead the whole certifiable band lands at
// d = 0.68 .. 2.87 mm, and on the maintainer's part the grid spacing is ~1.56 mm — so
// the DENSE half of the band asks for curves closer together than the direction field
// is sampled. Everything there is raised to the resolution floor, the spacing stops
// varying, and the grade disappears: a uniform lattice wearing a graded density.
//
// So the default is derived the other way round: pick t such that the DENSEST lattice
// in the band sits exactly ON the resolution floor — the finest separation this grid
// can express — and let everything lighter open out from there. That is the widest
// achievable window the grid permits, and it is never below the stated minimum
// extrudable width, because printability is user input and outranks it.
inline double organic_default_strut_diameter_mm(double grid_spacing_mm,
                                                double resolution_floor_voxels,
                                                double rho_max,
                                                double min_extrudable_width_mm) {
  const double d_res = std::max(0.0, resolution_floor_voxels) * grid_spacing_mm;
  if (!(d_res > 0.0) || !(rho_max > 0.0)) return min_extrudable_width_mm;
  const double t =
      2.0 * d_res * std::sqrt(rho_max / (3.0 * 3.14159265358979323846));
  return std::max(t, min_extrudable_width_mm);
}

// ── the parameters ──────────────────────────────────────────────────────────────
struct OrganicParams {
  // The build direction (unit, model frame) the overhang cone is measured from.
  Vec3 build_dir{0.0, 0.0, 1.0};

  // ★ §2(a)/§2(b) — THE OVERHANG CONE, APPLIED IN THE TRACING LOOP. The half-angle
  // of the printable cone about +/-build_dir, in DEGREES FROM THE BUILD DIRECTION: a
  // direction is in-cone when |dot(dir, build_dir)| >= cos(angle). When a traced
  // direction leaves the cone it is PROJECTED ONTO THE NEAREST IN-CONE DIRECTION
  // there and then, never re-angled afterwards — a repair pass would discard exactly
  // the stress alignment the method exists for.
  //
  // ★ 0 (THE DEFAULT) DISARMS THE CLAMP, and the reason is measured, not assumed:
  // see the coupon note at the top of this header. 90 also disarms it (the whole
  // sphere is in-cone). Set 45 to reproduce the textbook gate.
  double overhang_angle_deg = 0.0;

  // ★ §2(c) — THE STRUT FLOOR BINDS. The stated minimum extrudable width (mm).
  // ★ 0 MEANS UNSET AND IS REFUSED: printability is USER INPUT, never a default.
  double min_extrudable_width_mm = 0.0;

  // The strut diameter the whole lattice is traced at (mm). 0 => the floor above,
  // i.e. the thinnest bead the user says the machine lays. Constant by design: the
  // grade is expressed through SPACING (CURVY), so the bead never has to thin.
  double strut_diameter_mm = 0.0;

  // The Jobard-Lefer ratios and the integrator step. See the constants above.
  double test_ratio = kOrganicTestRatio;
  double seed_ratio = kOrganicSeedRatio;
  double connect_ratio = kOrganicConnectRatio;
  double step_ratio = kOrganicStepRatio;
  double thin_ratio = kOrganicTestRatio;
  double min_length_ratio = kOrganicMinLengthRatio;

  // How many principal directions to trace. 3 = the full orthogonal set (Daynes).
  int families = 3;

  // Hard bounds so a degenerate field cannot run away. Exceeding either is REPORTED,
  // never silent (`seed_budget_exhausted` / `step_budget_hits`).
  int max_curves = 400000;
  int max_steps_per_curve = 100000;

  // ★ §2(d) — THE SECOND FLOOR ON THE SEPARATION, AND ON A REAL PART IT IS THE ONE
  // THAT BINDS. The tracer integrates a direction field that is only sampled at the
  // VOXEL GRID, so it cannot place curves closer together than the grid can resolve
  // the field they are meant to follow. This is the separation floor as a multiple of
  // the grid spacing; 1.0 (the default) is one voxel. Voxels raised by it are counted
  // in `spacing_raised_for_resolution_voxels`, so the ACHIEVED window R5 reports says
  // WHICH bound bit — printability or resolution — rather than merely how wide it is.
  double resolution_floor_voxels = 1.0;

  // The certifiable density band the emitted per-voxel density is clamped into. Both
  // 0 => no clamp (the raw measured density is returned, which is what a probe wants).
  double rho_min = 0.0;
  double rho_max = 0.0;
};

// ── what one traced curve is ────────────────────────────────────────────────────
struct OrganicCurve {
  int family = 0;                // 0,1,2 = principal direction rank (|lambda| desc)
  std::vector<Vec3> points;      // the polyline, model mm, in trace order
  double length_mm = 0.0;
  double radius_mm = 0.0;        // half the strut diameter
  long long steps = 0;           // RK4 steps taken
  long long clamped_steps = 0;   // ...of which the overhang cone moved
  int connections = 0;           // connectors attached (§1d) — R3's measurement
};

// One connector (§1d / Daynes step 5). Its direction is the CROSS PRODUCT of the two
// curves' tangents at their nearest points BY CONSTRUCTION: the shortest segment
// between two curves is perpendicular to both tangents, which is what the cross
// product is. `cross_deviation_deg` MEASURES that rather than asserting it.
struct OrganicConnector {
  int curve_a = -1, curve_b = -1;  // curve_a < curve_b, indices into `curves`
  Vec3 a{0, 0, 0}, b{0, 0, 0};
  double radius_mm = 0.0;
  double length_mm = 0.0;
  double cross_deviation_deg = 0.0;
};

// ── the report: every number the bars ask for, measured, never predicted ────────
struct OrganicReport {
  // §1(a) the field
  std::size_t candidate_voxels = 0;
  std::size_t degenerate_voxels = 0;   // eigenvalues too close to rank the directions
  double degenerate_fraction = 0.0;
  // ★ §6(d) — THE SWIRL. Where the top two |eigenvalues| are within
  // `kOrganicDegenerateRatio` of each other the principal FRAME is not determined and
  // the eigenvector order can swap between neighbouring voxels. NAMED AND COUNTED
  // here; no combing pass is built (that is a separate question).
  double max_frame_swap_fraction = 0.0;  // fraction of RK4 steps that saw a flip

  // §1(b)/(c) the curves
  std::size_t curves_traced = 0;       // before thinning
  std::size_t curves_kept = 0;         // after thinning
  std::size_t curves_thinned = 0;      // §1(e)
  std::size_t curves_too_short = 0;    // stubs discarded
  std::size_t curves_per_family[3] = {0, 0, 0};
  double curve_length_per_family_mm[3] = {0.0, 0.0, 0.0};
  // ── ★ WHY THE TRACER STOPPED AND WHY A SEED WAS REFUSED ────────────────────
  // Without these a thin lattice is unattributable: "562 curves" says nothing about
  // whether the field ran out, the region ran out, or the separation rule closed the
  // part off. Every half-trace ends for exactly one of these reasons and every seed
  // offered is accounted for, so the two ledgers each sum to their total.
  long long stop_left_region = 0;    // the curve walked out of the candidate set
  long long stop_hit_d_test = 0;     // came within d_test of a same-family curve
  long long stop_no_direction = 0;   // the field had no direction there
  long long stop_step_budget = 0;
  long long seeds_offered = 0;
  long long seeds_outside_region = 0;
  long long seeds_too_close = 0;     // within d_sep of an existing same-family curve
  long long seeds_traced = 0;
  long long total_steps = 0;
  long long step_budget_hits = 0;
  bool seed_budget_exhausted = false;
  double total_curve_length_mm = 0.0;

  // §1(d) the connectors — and R3's answer
  std::size_t connectors = 0;
  double connector_min_length_mm = 0.0;
  double connector_median_length_mm = 0.0;   // full sort, never a sample
  double connector_max_length_mm = 0.0;
  // ★ WHEN THE CROSS-PRODUCT STATEMENT IS VACUOUS, AND IT OFTEN IS. Daynes step 5
  // says the connector runs along the cross product of the two tangents, and for two
  // SKEW curves that is exactly what the shortest segment between them is. But two
  // curves that nearly INTERSECT have no well-defined shortest direction — the
  // separation collapses and any transverse direction is as short as any other. On
  // the axis-aligned probe fixture the two families are coplanar, and the measured
  // deviation is 90 degrees for precisely that reason, not because the connector is
  // wrong: those two curves are already welded by their own strut solids.
  //
  // So the deviation is reported over the connectors where it MEANS something —
  // those longer than the polyline's OWN sampling step, i.e. where the two curves are
  // further apart than the tracer can resolve — and the degenerate population is
  // counted beside it rather than averaged into it.
  std::size_t connectors_shorter_than_strut = 0;  // below the resolution threshold
  std::size_t connectors_cross_measured = 0;
  double max_connector_cross_deviation_deg = 0.0;
  double mean_connector_cross_deviation_deg = 0.0;
  // ★ R3 — "the count of struts with fewer than two connections; the target is zero,
  // and a non-zero count is the finding". A kept curve IS a strut here.
  std::size_t curves_with_fewer_than_two_connections = 0;
  std::size_t curves_with_no_connection = 0;
  std::size_t connected_components = 0;      // over the curve/connector graph
  std::size_t largest_component_curves = 0;
  double largest_component_fraction = 0.0;

  // §2(b) the overhang clamp — R6
  double overhang_angle_deg_used = 0.0;      // 0 => the clamp was DISARMED
  bool overhang_clamp_armed = false;
  long long clamped_steps = 0;
  double clamped_step_fraction = 0.0;
  std::size_t curves_touched_by_clamp = 0;
  double curves_touched_fraction = 0.0;
  // The counterfactual, measured on the SAME traced geometry: what fraction of the
  // emitted segments sit outside a 45-degree cone. This is what R6 reports "at 45"
  // when the clamp itself is disarmed, and it costs no second run.
  double segments_outside_45_fraction = 0.0;
  double segments_outside_default_fraction = 0.0;
  // ★ SPLIT, because the clamp can only reach one of them. A traced step is clamped
  // IN THE LOOP (§2a); a CONNECTOR is the shortest join between two curves and
  // re-angling it would break the join, which is the one thing R3 exists to protect.
  // So a connector is never clamped, and with the clamp armed the residual
  // out-of-cone population is exactly the connectors. Reported separately so that
  // residual is never mistaken for a leaky clamp.
  double curve_segments_outside_45_fraction = 0.0;
  double connectors_outside_45_fraction = 0.0;

  // §2(d) the ACHIEVED spacing window — R5
  double requested_spacing_min_mm = 0.0;
  double requested_spacing_max_mm = 0.0;
  double achieved_spacing_min_mm = 0.0;   // measured nearest-neighbour separation
  double achieved_spacing_max_mm = 0.0;
  double achieved_spacing_median_mm = 0.0;  // full sort, never a sample
  double strut_diameter_mm = 0.0;
  double min_extrudable_width_mm = 0.0;
  std::size_t spacing_raised_for_print_voxels = 0;       // d below the printable floor
  std::size_t spacing_raised_for_resolution_voxels = 0;  // d below one voxel
  double spacing_print_floor_mm = 0.0;       // t * sqrt(3 pi) / 2
  double spacing_resolution_floor_mm = 0.0;  // resolution_floor_voxels * grid spacing

  // §3(a) the CURVE-CROSSING COUNT — R7. Defined as
  //   curves_per_member(x) = member_width_mm(x) / spacing_mm(x)
  // the exact analogue of cells_per_member = W / S, reported under its OWN name.
  double min_curves_per_member = 0.0;
  double median_curves_per_member = 0.0;
  double curves_per_member_floor = kOrganicCurvesPerMemberFloor;
  std::size_t below_curves_per_member_floor_voxels = 0;  // counted OUT OF REGIME
  bool curves_per_member_measured = false;  // false when no width field was supplied

  // the emitted density
  std::size_t latticed_voxels = 0;
  double rho_min_emitted = 0.0;
  double rho_max_emitted = 0.0;
  double rho_median_emitted = 0.0;
  std::size_t rho_clamped_lo_voxels = 0;
  std::size_t rho_clamped_hi_voxels = 0;
  double emitted_volume_mm3 = 0.0;   // soup basis: crossings NOT deducted

  // ★ §3(c) — ORGANIC IS AESTHETIC-FIRST, AND THIS SAYS SO ON EVERY RUN.
  // A traced lattice is ANISOTROPIC BY CONSTRUCTION — aligning struts with the
  // principal directions is the whole point, and it is where Daynes' +101 % comes
  // from. The certification library carries exactly ONE CUBIC tensor per topology,
  // as a function of relative density alone. There is no measured tensor for this
  // geometry, so there is nothing to state a structural claim AGAINST. The
  // certificate still RUNS (§3d) — what it certifies is the octet tensor at the
  // emitted density, which does not describe this geometry, and that is exactly what
  // this flag is for.
  bool tensor_out_of_regime = true;
};

struct OrganicLattice {
  std::vector<OrganicCurve> curves;          // KEPT curves only, in trace order
  std::vector<OrganicConnector> connectors;
  // Grid-indexed (grid.voxel_count()). `mask[e] != 0` where the traced geometry put
  // solid into voxel e; `relative_density[e]` is the MEASURED fraction there, clamped
  // into the band when one was supplied.
  std::vector<char> mask;
  std::vector<double> relative_density;
  // Grid-indexed: the separation the tracer actually used at each candidate voxel
  // (mm), i.e. the derived "cell size". 0 off the candidate set.
  std::vector<double> spacing_used_mm;
  OrganicReport report;
};

// ★ THE TRACER (§1). Pure: grid + candidate set + stress tensor + spacing field in,
// curves + connectors + per-voxel density out. It reads no job, writes no file and
// makes no decision the caller did not hand it.
//
//   grid       — the design grid.
//   candidate  — grid-indexed; candidate[e] != 0 marks voxel e traceable. Tracing
//                stops at the boundary of this set (§1b).
//   stress     — flattened grid-indexed (6 * voxel_count), Voigt
//                [xx,yy,zz,xy,yz,zx], TRUE shear, MPa —
//                FixedDesignAnalysis::stress_tensor_field verbatim.
//   spacing_mm — grid-indexed d_sep FIELD (mm). ★ THIS IS THE INPUT the whole method
//                turns on (§1c): cell size is derived from it, not the other way
//                round. Must be > 0 on the candidate set.
//   width_mm   — OPTIONAL grid-indexed local member width (mm), the same field the
//                grading law reads. Null => the curve-crossing count is not measured
//                and `curves_per_member_measured` says so.
//
// Throws std::invalid_argument on a size mismatch, a non-positive spacing on the
// candidate set, `min_extrudable_width_mm` <= 0 (the UNSET refusal, §2c), or a
// non-finite / degenerate build direction.
OrganicLattice trace_organic_lattice(const VoxelGrid& grid,
                                     const std::vector<char>& candidate,
                                     const std::vector<double>& stress,
                                     const std::vector<double>& spacing_mm,
                                     const std::vector<double>* width_mm,
                                     const OrganicParams& params);

// ── the geometry ────────────────────────────────────────────────────────────────
// Emit the traced lattice as swept solids into `sink`, in a FIXED order (curves in
// index order, each polyline segment in order, then connectors in index order), so a
// streaming sink writes a byte-identical file for identical inputs — the same
// discipline generate_lattice holds. Node balls are emitted at every polyline vertex
// and at both ends of every connector, which is what makes the soup a single solid at
// each join.
//
// `boundary`, when non-null, CLIPS every centreline to the allowed region eroded by
// that strut's own radius, exactly as the octet generator does, so the swept SOLID
// stays inside the part rather than just the centreline.
struct OrganicGenStats {
  std::uint64_t triangles = 0;
  std::uint64_t struts = 0;      // emitted segment solids (curve spans + connectors)
  std::uint64_t nodes = 0;
  std::uint64_t clipped_segments = 0;
  std::uint64_t dropped_segments = 0;   // entirely outside the eroded region
  long long uncertified_spans_dropped = 0;  // clip slivers conservatively dropped
  double volume_mm3 = 0.0;              // soup basis; overlaps NOT deducted
  double min_strut_diameter_mm = 0.0;
  double max_strut_diameter_mm = 0.0;
};

class LatticeBoundary;  // topopt/lattice_boundary.hpp

OrganicGenStats generate_organic_lattice(const OrganicLattice& lat,
                                         TriangleSink& sink,
                                         const LatticeBoundary* boundary = nullptr,
                                         int nseg = 8);

}  // namespace topopt

#endif  // TOPOPT_ORGANIC_LATTICE_HPP
